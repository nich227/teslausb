#!/bin/bash
#
# Two DietPi VMs on a private network: the teslausb device, and a NAS to archive
# to.
#
# Why two VMs on their own segment:
#
#   - The archive path is the part your car depends on and nothing tests it. A
#     real NAS cannot be used for that: tests need to fill its disk, cut it off
#     mid-copy and hand it bad credentials.
#   - Earlier VM runs kept tripping over the real LAN (its DNS lives on the QEMU
#     host, which a macvtap guest cannot reach; DHCP quirks; the risk of taking
#     an address that belongs to something else). An isolated segment removes all
#     of that.
#
# Each VM gets two interfaces:
#
#   eth0  QEMU user-mode networking, for apt and DietPi's own first run setup,
#         with SSH forwarded to a port on the host. No LAN exposure.
#   eth1  a private segment shared only by these two VMs, carrying all the
#         archive traffic. 10.99.0.10 is the device, 10.99.0.20 the NAS.
#
# The NAS also checks the device the way a person on the same network would:
# that teslausb.local resolves over mDNS and that its web interface answers.
#
# Usage:
#   tests/vm/lab.sh [--keep] [--archive cifs|rsync] [--timeout SECONDS]
#                   [--fast] [--start-dropbear] [--ap]
#                   [--hostname NAME] [--mdns-name NAME]
#
# Nothing here needs root on the host.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly REPO
readonly CACHE_DIR="${DIETPI_CACHE_DIR:-${TMPDIR:-/tmp}/dietpi-images}"
readonly RUN_DIR="${TMPDIR:-/tmp}/teslausb-lab"

KEEP=0
ARCHIVE=cifs
LOGIN_SHELL=bash
TIMEOUT=1800
DISTRO=Bookworm

while [ $# -gt 0 ]
do
  case "$1" in
    --keep)     KEEP=1; shift ;;
    --shell)    LOGIN_SHELL="$2"; shift 2 ;;
    --archive)  ARCHIVE="$2"; shift 2 ;;
    --timeout)  TIMEOUT="$2"; shift 2 ;;
    --distro)   DISTRO="$2"; shift 2 ;;
    # DietPi's own apt upgrade is included by default: measured, it costs about
    # 35 seconds of a six minute run, which is not worth trading coverage for.
    # Kept as an explicit flag so scripts that passed it still work.
    --dietpi-update) DIETPI_UPDATE=1; shift ;;
    --fast)          DIETPI_UPDATE=0; shift ;;
    # Boot the device with dropbear, as a stock DietPi image does, so teslausb has
    # to replace it with openssh rather than DietPi installing openssh up front.
    --start-dropbear) START_DROPBEAR=1; shift ;;
    # Configure and then actually exercise the access point, using simulated wifi
    # radios so a VM with no wireless hardware can still associate to it.
    --ap)            AP=1; shift ;;
    # Prove the names are configurable rather than only testing the defaults.
    --hostname)      DEVICE_HOSTNAME="$2"; shift 2 ;;
    --mdns-name)     DEVICE_MDNS="$2"; shift 2 ;;
    -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
    *)          echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

readonly IMAGE_NAME="DietPi_VM-x86_64-${DISTRO}.img.xz"
readonly BASE_URL="https://dietpi.com/downloads/images"

# the private segment
readonly LAB_NET_PORT=12480
readonly DEVICE_IP=10.99.0.10
readonly NAS_IP=10.99.0.20
readonly LAB_MASK=255.255.255.0

# ssh forwarded from user-mode networking
readonly DEVICE_SSH_PORT=2230
readonly NAS_SSH_PORT=2231
readonly VM_PASSWORD=teslausb-lab

readonly NAS_HOSTNAME=teslanas
# The defaults teslausb ships with, so an ordinary run tests teslausb.local.
: "${DEVICE_HOSTNAME:=teslausb}"
: "${DEVICE_MDNS:=}"
# What the device should answer to: the mDNS name when set, otherwise the hostname.
LOCAL_NAME="${DEVICE_MDNS:-$DEVICE_HOSTNAME}"
readonly DEVICE_HOSTNAME DEVICE_MDNS LOCAL_NAME

readonly AP_SSID="TESLAUSB LAB AP"
readonly AP_PASS=labdrivefast
readonly AP_ADDRESS=192.168.66.1
readonly SHARE_NAME=teslacam
readonly SHARE_USER=teslausb
readonly SHARE_PASS=archivepass

pass_count=0
fail_count=0
DEVICE_PID=""
NAS_PID=""

log ()    { printf '\n==> %s\n' "$*"; }
step ()   { printf '    %s\n' "$*"; }
ok ()     { pass_count=$(( pass_count + 1 )); printf '   ok: %s\n' "$1"; }
not_ok () { fail_count=$(( fail_count + 1 )); printf '   FAIL: %s\n' "$1"; }

# invoked via trap, so shellcheck cannot see it being called: 0.9.0 calls the body
# unreachable (SC2317), newer versions call the function unused (SC2329)
# shellcheck disable=SC2329,SC2317
cleanup () {
  [ "$KEEP" = 1 ] && return 0
  local pid
  for pid in $DEVICE_PID $NAS_PID
  do
    [ -n "$pid" ] && kill "$pid" 2> /dev/null
  done
}
trap cleanup EXIT

for tool in qemu-system-x86_64 qemu-img docker sshpass
do
  command -v "$tool" > /dev/null || { echo "FATAL: $tool is required" >&2; exit 1; }
done

ACCEL=tcg
if [ -r /dev/kvm ] && [ -w /dev/kvm ]
then
  ACCEL=kvm
else
  echo "NOTE: /dev/kvm is not usable; this will be very slow."
fi

# Two labs cannot share the forwarded SSH ports, and a stale pair silently makes
# the new one fail while the checks talk to the old VMs.
for port in "$DEVICE_SSH_PORT" "$NAS_SSH_PORT"
do
  if ss -ltn 2> /dev/null | grep -q ":${port} "
  then
    echo "FATAL: port $port is already in use, so a lab is probably still running." >&2
    echo "       Stop it first: pkill -f '[q]emu-system-x86_64.*teslausb-lab'" >&2
    exit 1
  fi
done

mkdir -p "$RUN_DIR" "$CACHE_DIR"

# ---------------------------------------------------------------------------
# The teslausb config the device is built with. The archive server is the NAS on
# the private segment, so no real NAS can be touched.
# ---------------------------------------------------------------------------
readonly LAB_CONF="$RUN_DIR/lab-teslausb.conf"
case "$ARCHIVE" in
  cifs)
    cat > "$LAB_CONF" <<EOF
export ARCHIVE_SYSTEM=cifs
export ARCHIVE_SERVER=${NAS_IP}
export SHARE_NAME='${SHARE_NAME}'
export SHARE_USER=${SHARE_USER}
export SHARE_PASSWORD='${SHARE_PASS}'
export OS_PASSWORD='${VM_PASSWORD}'
export TESLAUSB_HOSTNAME=${DEVICE_HOSTNAME}
$( [ -n "$DEVICE_MDNS" ] && printf "export TESLAUSB_MDNS_NAME='%s'\n" "$DEVICE_MDNS" )
$( [ "${AP:-0}" = 1 ] && printf "export AP_SSID='%s'\nexport AP_PASS='%s'\nexport AP_IP='%s'\n" \
     "$AP_SSID" "$AP_PASS" "$AP_ADDRESS" )
export UPGRADE_PACKAGES=false
export SKIP_READONLY=true
export SKIP_UDC_CHECK=true
export CAM_SIZE=2G
export MUSIC_SIZE=0
EOF
    ;;
  rsync)
    cat > "$LAB_CONF" <<EOF
export ARCHIVE_SYSTEM=rsync
export ARCHIVE_SERVER=${NAS_IP}
export RSYNC_USER=${SHARE_USER}
export RSYNC_SERVER=${NAS_IP}
export RSYNC_PATH=/srv/${SHARE_NAME}
export OS_PASSWORD='${VM_PASSWORD}'
export TESLAUSB_HOSTNAME=${DEVICE_HOSTNAME}
$( [ -n "$DEVICE_MDNS" ] && printf "export TESLAUSB_MDNS_NAME='%s'\n" "$DEVICE_MDNS" )
$( [ "${AP:-0}" = 1 ] && printf "export AP_SSID='%s'\nexport AP_PASS='%s'\nexport AP_IP='%s'\n" \
     "$AP_SSID" "$AP_PASS" "$AP_ADDRESS" )
export UPGRADE_PACKAGES=false
export SKIP_READONLY=true
export SKIP_UDC_CHECK=true
export CAM_SIZE=2G
export MUSIC_SIZE=0
EOF
    ;;
  *)
    echo "FATAL: unknown archive flavour '$ARCHIVE'" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
if [ ! -s "$CACHE_DIR/$IMAGE_NAME" ]
then
  log "downloading $IMAGE_NAME"
  curl -fsSL --retry 3 -o "$CACHE_DIR/$IMAGE_NAME" "$BASE_URL/$IMAGE_NAME"
fi
log "verifying sha256"
curl -fsSL --retry 3 -o "$CACHE_DIR/$IMAGE_NAME.sha256" "$BASE_URL/$IMAGE_NAME.sha256"
( cd "$CACHE_DIR" && sha256sum -c "$IMAGE_NAME.sha256" )

readonly TEST_KEY="$CACHE_DIR/teslausb-vm-key"
[ -f "$TEST_KEY" ] || ssh-keygen -q -t ed25519 -N "" -C teslausb-lab -f "$TEST_KEY"

# A second interface on the private segment, for both VMs. DietPi's dietpi.txt
# only configures one interface, so this goes in as an interfaces.d snippet.
prepare_vm () {
  local role="$1" ip="$2" conf="$3" out="$4"
  # the NAS is a plain DietPi with a share on it, not a second teslausb
  local bootstrap=1 hostname_key="AUTO_SETUP_NET_HOSTNAME=$DEVICE_HOSTNAME"
  if [ "${START_DROPBEAR:-0}" = 1 ]
  then
    # -1 is Dropbear. teslausb's ensure_openssh is then the thing that has to
    # swap it for openssh, which is what the assertions later check.
    hostname_key="$hostname_key
AUTO_SETUP_SSH_SERVER_INDEX=-1"
  fi
  if [ "$role" = nas ]
  then
    bootstrap=0
    hostname_key="AUTO_SETUP_NET_HOSTNAME=$NAS_HOSTNAME"
  fi

  cat > "$RUN_DIR/eth1.conf" <<EOF
# private lab segment, shared only with the other lab VM
auto eth1
iface eth1 inet static
  address ${ip}
  netmask ${LAB_MASK}
EOF

  step "preparing the $role image"
  docker run --rm \
    -v "$CACHE_DIR:/cache" \
    -v "$REPO:/repo:ro" \
    -v "$RUN_DIR:/run-dir" \
    -e "IMAGE_NAME=$IMAGE_NAME" \
    -e "CONF=${conf:-/repo/tests/vm/vm-test.conf}" \
    -e "SSH_PUBKEY=/cache/$(basename "$TEST_KEY").pub" \
    -e "EXTRA_INTERFACES=/run-dir/eth1.conf" \
    -e "TESLAUSB_BOOTSTRAP=$bootstrap" \
    -e "VM_PASSWORD=$VM_PASSWORD" \
    -e "DIETPI_EXTRA_KEYS=$hostname_key" \
    -e "SKIP_DIETPI_UPDATE=$(( 1 - ${DIETPI_UPDATE:-1} ))" \
    -e "OUT_IMAGE=/cache/$(basename "$out")" \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    debian:bookworm-slim \
    bash /repo/tests/vm/inject.sh > "$RUN_DIR/inject-$role.log" 2>&1 || {
      echo "FATAL: preparing the $role image failed; see $RUN_DIR/inject-$role.log" >&2
      tail -20 "$RUN_DIR/inject-$role.log" >&2
      exit 1
    }
}

readonly DEVICE_IMG="$CACHE_DIR/lab-device.img"

if [ "${DIETPI_UPDATE:-1}" = 1 ]
then step "DietPi's own apt upgrade is included in this run"
else step "DietPi's own apt upgrade is skipped (--fast)"
fi
if [ "${START_DROPBEAR:-0}" = 1 ]
then step "the device starts with dropbear, so teslausb has to replace it"
fi

log "preparing the device image"
prepare_vm device "$DEVICE_IP" "/run-dir/$(basename "$LAB_CONF")" "$DEVICE_IMG"

# Boot the device from an overlay so the prepared image stays pristine.
readonly DEVICE_OVL="$RUN_DIR/device.qcow2"
rm -f "$DEVICE_OVL"
qemu-img create -q -f qcow2 -F raw -b "$DEVICE_IMG" "$DEVICE_OVL" > /dev/null

# The NAS is a Debian cloud image driven by cloud-init rather than a second
# DietPi. It has no first run to sit through, and its whole configuration is
# declared in one seed, so it is ready in about a minute instead of ten. See
# prepare-nas-image.sh for why Debian and not Alpine.
log "preparing the NAS image (Debian cloud image, configured by cloud-init)"
readonly NAS_OVL="$RUN_DIR/nas.qcow2"
readonly NAS_SEED="$RUN_DIR/nas-seed.iso"
# env, not a plain assignment prefix: most of these are readonly here, and bash
# refuses "CACHE_DIR=... cmd" for a readonly CACHE_DIR. It printed a complaint and
# ran the script anyway with its own defaults, which happened to match, so the NAS
# was quietly configured from prepare-nas-image.sh's defaults rather than from the
# lab's settings, and the base image went to that script's default cache instead of
# the one the lab was told to use.
env NAS_IP="$NAS_IP" NAS_HOSTNAME="$NAS_HOSTNAME" \
    MAC_NAT="52:54:00:aa:00:20" MAC_PRIVATE="52:54:00:bb:00:20" \
    SHARE_NAME="$SHARE_NAME" SHARE_USER="$SHARE_USER" SHARE_PASS="$SHARE_PASS" \
    ARCHIVE="$ARCHIVE" SSH_PUBKEY="$(cat "$TEST_KEY.pub")" VM_PASSWORD="$VM_PASSWORD" \
    CACHE_DIR="$CACHE_DIR" \
  bash "$REPO/tests/vm/prepare-nas-image.sh" "$NAS_OVL"

# ---------------------------------------------------------------------------
# Boot. The private segment is a QEMU socket link: one VM listens, the other
# connects, and nothing else can reach it.
# ---------------------------------------------------------------------------
boot_vm () {
  local role="$1" ovl="$2" ssh_port="$3" mac_suffix="$4" socket_arg="$5"
  shift 5
  # anything left is passed through, which is how the NAS gets its cloud-init seed
  qemu-system-x86_64 \
    "$@" \
    -machine accel="$ACCEL" \
    -m 1024 \
    -smp 2 \
    -drive "file=$ovl,format=qcow2,if=virtio,cache=writeback" \
    -netdev "user,id=wan,hostfwd=tcp::${ssh_port}-:22" \
    -device "virtio-net-pci,netdev=wan,mac=52:54:00:aa:00:${mac_suffix}" \
    -netdev "socket,id=lab,${socket_arg}" \
    -device "virtio-net-pci,netdev=lab,mac=52:54:00:bb:00:${mac_suffix}" \
    -nographic \
    -serial "file:$RUN_DIR/$role-serial.log" \
    -monitor none \
    &> "$RUN_DIR/$role-qemu.log" &
  echo $!
}

log "booting the NAS (listening on the private segment)"
# The NAS is booted and provisioned before the device exists at all. The device
# runs teslausb setup unattended within a couple of minutes of first boot, and if
# the share is not serving by the time it checks, setup gives up for good. In one
# run samba finished installing at 15:29:29 and the device had already tried, and
# failed, at 15:28:56.
NAS_PID=$(boot_vm nas "$NAS_OVL" "$NAS_SSH_PORT" 20 "listen=127.0.0.1:${LAB_NET_PORT}" \
  -drive "file=$NAS_SEED,media=cdrom,readonly=on")
sleep 3
log "booting the device (connecting to the private segment)"

# ---------------------------------------------------------------------------
# Talking to them
# ---------------------------------------------------------------------------
declare -a SSH_COMMON=(
  -i "$TEST_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
  -o IdentitiesOnly=yes
)

# shellcheck disable=SC2029  # the commands are meant to run in the guest
on_device () { ssh "${SSH_COMMON[@]}" -p "$DEVICE_SSH_PORT" root@localhost "$@" 2> /dev/null; }
# shellcheck disable=SC2029
on_nas ()    { ssh "${SSH_COMMON[@]}" -p "$NAS_SSH_PORT"    root@localhost "$@" 2> /dev/null; }

wait_for () {
  local what="$1" tries="${2:-60}" i
  for (( i = 0; i < tries; i++ ))
  do
    if [ "$what" = device ] && on_device true; then return 0; fi
    if [ "$what" = nas ] && on_nas true; then return 0; fi
    sleep 5
  done
  return 1
}

# DietPi advances its first run setup from /etc/bashrc.d/dietpi.bash, which runs
# dietpi-login for any interactive login shell. The image autologs into tty1 to
# trigger that; driving the same thing over SSH keeps it off the console and lets
# the phases, which reboot in between, be waited on properly.
advance_first_run () {
  local which="$1" i
  for (( i = 0; i < 4; i++ ))
  do
    if [ "$which" = device ]
    then
      ssh "${SSH_COMMON[@]}" -tt -p "$DEVICE_SSH_PORT" root@localhost "bash -lic 'exit'" \
        >> "$RUN_DIR/device-firstrun.log" 2>&1
    else
      ssh "${SSH_COMMON[@]}" -tt -p "$NAS_SSH_PORT" root@localhost "bash -lic 'exit'" \
        >> "$RUN_DIR/nas-firstrun.log" 2>&1
    fi
    sleep 15
    wait_for "$which" 60 || true
    local stage
    if [ "$which" = device ]
    then stage=$(on_device 'cat /boot/dietpi/.install_stage 2>/dev/null')
    else stage=$(on_nas 'cat /boot/dietpi/.install_stage 2>/dev/null')
    fi
    [ "$stage" = 2 ] && return 0
  done
  return 1
}


# Give the development VMs a friendlier login shell if asked.
#
# This deliberately does not change how the harness drives DietPi: DietPi
# triggers its first run setup from /etc/bashrc.d/dietpi.bash, which only bash
# sources, so the automation always calls bash explicitly. The login shell
# affects interactive use only.
set_login_shell () {
  local where="$1" shell="$2" bin
  [ -n "$shell" ] && [ "$shell" != bash ] || return 0

  local runner=on_device
  [ "$where" = nas ] && runner=on_nas

  # DietPi's own first run setup and teslausb setup both use apt, so the lock is
  # often held; wait for it and retry rather than reporting a spurious failure.
  local _attempt
  for _attempt in 1 2 3 4 5 6
  do
    bin=$("$runner" "command -v $shell")
    [ -n "$bin" ] && break
    "$runner" "for i in \$(seq 1 60); do fuser /var/lib/dpkg/lock-frontend > /dev/null 2>&1 || break; sleep 5; done
               DEBIAN_FRONTEND=noninteractive apt-get -qq update > /dev/null 2>&1
               DEBIAN_FRONTEND=noninteractive apt-get -qq -y install $shell > /dev/null 2>&1" > /dev/null 2>&1
    bin=$("$runner" "command -v $shell")
    [ -n "$bin" ] && break
    sleep 20
  done
  if [ -z "$bin" ]
  then
    step "could not install $shell on the $where"
    return 0
  fi

  "$runner" "grep -qxF '$bin' /etc/shells || echo '$bin' >> /etc/shells"
  "$runner" "chsh -s '$bin' root"
  "$runner" "id dietpi > /dev/null 2>&1 && chsh -s '$bin' dietpi"
  step "$where now logs in with $("$runner" 'getent passwd root | cut -d: -f7')"
}

# The device's teslausb setup reaches its archive check on its own schedule, and
# if the share is not serving by then it gives up with "no working combination
# of vers and sec". So the share is set up before the device is nudged into
# starting setup at all.
setup_archive_share () {
  # cloud-init already applied all of this from the seed: the account, the share
  # directory, samba or sshd, and avahi. What is left is to wait for it to finish
  # and check the result, rather than installing anything over ssh.
  local ready=no
  local i
  for (( i = 0; i < 60; i++ ))
  do
    if [ "$(on_nas "test -e /run/nas-ready && echo yes" 2> /dev/null)" = yes ]
    then
      ready=yes
      break
    fi
    sleep 10
  done

  if [ "$ready" = yes ]
  then ok "cloud-init finished configuring the NAS"
  else not_ok "cloud-init did not finish on the NAS; see the serial log"
  fi

  if [ "$(on_nas "test -d /srv/$SHARE_NAME && echo yes")" = yes ]
  then ok "the share directory exists"
  else not_ok "there is no /srv/$SHARE_NAME on the NAS"
  fi

  case "$ARCHIVE" in
    cifs)
      if [ "$(on_nas "systemctl is-active smbd")" = active ]
      then ok "the NAS is serving an SMB share"
      else not_ok "smbd is not running on the NAS"
      fi
      ;;
    rsync)
      # teslausb's rsync backend is rsync over ssh: archive-clips.sh runs
      # rsync to "$RSYNC_USER@$RSYNC_SERVER:$RSYNC_PATH" and the reachability
      # check falls back to "ssh $RSYNC_USER@host exit", so what matters is that
      # sshd is up and the account exists. An rsync daemon is never contacted.
      if [ "$(on_nas "systemctl is-active ssh")" = active ]
      then ok "the NAS accepts ssh, which is what rsync archiving uses"
      else not_ok "sshd is not running on the NAS"
      fi
      if [ "$(on_nas "id $SHARE_USER > /dev/null 2>&1 && echo yes")" = yes ]
      then ok "the archive account exists on the NAS"
      else not_ok "there is no $SHARE_USER account on the NAS"
      fi
      ;;
  esac
}

log "waiting for both VMs to answer (up to ${TIMEOUT}s)"
wait_for nas 120 || { echo "FATAL: the NAS never came up; see $RUN_DIR/nas-serial.log" >&2; exit 1; }
ok "the NAS is up"

log "setting up the archive share on the NAS, before the device needs it"
setup_archive_share
DEVICE_PID=$(boot_vm device "$DEVICE_OVL" "$DEVICE_SSH_PORT" 10 "connect=127.0.0.1:${LAB_NET_PORT}")
wait_for device 180 || { echo "FATAL: the device never came up; see $RUN_DIR/device-serial.log" >&2; exit 1; }
ok "the device is up"

log "letting DietPi finish its own setup on the device"
advance_first_run device || step "the device did not reach install stage 2; carrying on"

if [ "$LOGIN_SHELL" != bash ]
then
  log "setting the login shell to $LOGIN_SHELL on the device"
  set_login_shell device "$LOGIN_SHELL"
fi

# ---------------------------------------------------------------------------
log "the private segment"
# ---------------------------------------------------------------------------
if [ "$(on_nas "ping -c1 -W3 $DEVICE_IP > /dev/null 2>&1 && echo yes")" = yes ]
then ok "the NAS can reach the device over the private segment"
else not_ok "the two VMs cannot see each other on the private segment"
fi
if [ "$(on_device "ip -brief addr show eth1 | grep -c $DEVICE_IP")" = 1 ]
then ok "the device has its private address"
else not_ok "the device is missing its private address"
fi

# ---------------------------------------------------------------------------
log "what the NAS can see of the device"
# ---------------------------------------------------------------------------
# This is the check a person on the same network would make. Avahi registers
# asynchronously, and the device is still going through setup here, so give the
# name a while to appear rather than asking once. A run where the device had to
# swap dropbear for openssh reported both of these as failures purely because it
# was asked thirty seconds too early.
mdns=""
for (( i = 0; i < 30; i++ ))
do
  mdns=$(on_nas "getent hosts ${LOCAL_NAME}.local | awk '{print \$1}'")
  [ -n "$mdns" ] && break
  sleep 10
done
if [ -n "$mdns" ]
then
  ok "${LOCAL_NAME}.local resolves from the NAS (to $mdns)"
  if [ "$mdns" = "$DEVICE_IP" ]
  then ok "and it resolves to the device's private address"
  else not_ok "it resolves to $mdns, not $DEVICE_IP"
  fi
else
  not_ok "${LOCAL_NAME}.local does not resolve from the NAS"
fi

pinged=no
for (( i = 0; i < 12; i++ ))
do
  if [ "$(on_nas "ping -c1 -W3 ${LOCAL_NAME}.local > /dev/null 2>&1 && echo yes")" = yes ]
  then
    pinged=yes
    break
  fi
  sleep 10
done
if [ "$pinged" = yes ]
then ok "${LOCAL_NAME}.local answers a ping from the NAS"
else not_ok "${LOCAL_NAME}.local does not answer from the NAS"
fi

# The web interface is put in place by setup, which is still running at this
# point, so a 403 here means "not configured yet" rather than broken. Wait for it
# instead of judging it mid-setup.
http_code=000
for (( i = 0; i < 60; i++ ))
do
  http_code=$(on_nas "curl -s -o /dev/null -m 10 -w '%{http_code}' http://${LOCAL_NAME}.local/ 2>/dev/null")
  case "$http_code" in
    200|401) break ;;
  esac
  sleep 20
done
case "$http_code" in
  200|401)
    ok "the web interface answers on http://${LOCAL_NAME}.local/ ($http_code)"
    ;;
  *)
    # fall back to the address, to tell a web server problem from a name problem
    http_ip=$(on_nas "curl -s -o /dev/null -m 10 -w '%{http_code}' http://$DEVICE_IP/ 2>/dev/null")
    if [ "$http_ip" = 200 ] || [ "$http_ip" = 401 ]
    then not_ok "the web interface answers on $DEVICE_IP ($http_ip) but not via ${LOCAL_NAME}.local"
    else not_ok "the web interface did not answer (by name: '$http_code', by address: '$http_ip')"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
log "waiting for teslausb setup to finish on the device"
# ---------------------------------------------------------------------------
# Setup partitions the disk, builds the backing files and configures the archive,
# so nothing below can be tested until it has run to the end. It reboots on the
# way, hence the reconnects.
setup_done=0
for (( i = 0; i < 100; i++ ))
do
  wait_for device 12 || continue
  if [ "$(on_device 'test -e /boot/TESLAUSB_SETUP_FINISHED && echo yes')" = yes ]
  then
    setup_done=1
    break
  fi
  sleep 15
done

if [ "$setup_done" = 1 ]
then
  ok "teslausb setup finished"
else
  printf '   setup has not finished; last log line: %s\n' \
    "$(on_device 'tail -1 /boot/teslausb-headless-setup.log' | cut -c1-100)"
  # If it gave up on the archive, the share may simply not have been serving yet.
  if on_device "grep -q 'no working combination' /boot/teslausb-headless-setup.log"
  then
    step "it gave up on the archive; the share is serving now, so running setup again"
    on_device "nohup /root/bin/setup-teslausb > /tmp/setup-retry.log 2>&1 &" > /dev/null
    for (( i = 0; i < 80; i++ ))
    do
      sleep 15
      wait_for device 12 || continue
      if [ "$(on_device 'test -e /boot/TESLAUSB_SETUP_FINISHED && echo yes')" = yes ]
      then
        setup_done=1
        break
      fi
    done
  fi
  if [ "$setup_done" = 1 ]
  then ok "teslausb setup finished on the second attempt"
  else not_ok "teslausb setup did not finish; skipping the archive checks"
  fi
fi

if [ "$setup_done" = 1 ]
then
  # ---------------------------------------------------------------------------
  log "the configured names"
  # ---------------------------------------------------------------------------
  if [ "$(on_device hostname)" = "$DEVICE_HOSTNAME" ]
  then ok "the device's hostname is $DEVICE_HOSTNAME"
  else not_ok "the hostname is '$(on_device hostname)', expected $DEVICE_HOSTNAME"
  fi
  if [ -n "$DEVICE_MDNS" ]
  then
    if [ "$(on_device "grep -c '^host-name=$DEVICE_MDNS\$' /etc/avahi/avahi-daemon.conf")" = 1 ]
    then ok "avahi advertises the separate name $DEVICE_MDNS"
    else not_ok "avahi was not told to advertise $DEVICE_MDNS"
    fi
  fi

  # ---------------------------------------------------------------------------
  log "openssh is the only ssh server"
  # ---------------------------------------------------------------------------
  # teslausb standardises on OpenSSH: the rsync archive backend shells out to ssh,
  # which dropbear does not provide.
  for role in device nas
  do
    if [ "$role" = device ]
    then state=$(on_device "dpkg-query -W -f='\${Status}' openssh-server 2>/dev/null | grep -c 'ok installed'; dpkg-query -W -f='\${Status}' dropbear-bin 2>/dev/null | grep -c 'ok installed'")
    else state=$(on_nas "dpkg-query -W -f='\${Status}' openssh-server 2>/dev/null | grep -c 'ok installed'; dpkg-query -W -f='\${Status}' dropbear-bin 2>/dev/null | grep -c 'ok installed'")
    fi
    have_openssh=$(printf '%s\n' "$state" | sed -n 1p)
    have_dropbear=$(printf '%s\n' "$state" | sed -n 2p)
    if [ "$have_openssh" = 1 ]
    then ok "the $role runs openssh"
    else not_ok "the $role has no openssh-server"
    fi
    if [ "${have_dropbear:-0}" = 0 ]
    then ok "and no dropbear on the $role"
    else not_ok "dropbear is still installed on the $role"
    fi
  done

  # ---------------------------------------------------------------------------
  log "the archive path, end to end over $ARCHIVE"
  # ---------------------------------------------------------------------------
  if [ "$(on_device 'test -e /backingfiles/cam_disk.bin && echo yes')" = yes ]
  then ok "the cam backing file exists"
  else not_ok "there is no cam backing file"
  fi

  if [ "$ARCHIVE" = rsync ]
  then
    # doc/SetupRSync.md has the user copy the device's key to the archive host
    # themselves, before archiving can work. This is that step.
    on_device "mkdir -p /root/.ssh && chmod 700 /root/.ssh
               [ -f /root/.ssh/id_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519" > /dev/null
    device_pub=$(on_device "cat /root/.ssh/id_ed25519.pub")
    on_nas "install -d -m 700 -o $SHARE_USER -g $SHARE_USER /home/$SHARE_USER/.ssh
            printf '%s\n' '$device_pub' >> /home/$SHARE_USER/.ssh/authorized_keys
            chown $SHARE_USER:$SHARE_USER /home/$SHARE_USER/.ssh/authorized_keys
            chmod 600 /home/$SHARE_USER/.ssh/authorized_keys" > /dev/null
    on_device "ssh-keyscan -H $NAS_IP >> /root/.ssh/known_hosts 2>/dev/null" > /dev/null
    if [ "$(on_device "ssh -o BatchMode=yes -o ConnectTimeout=10 $SHARE_USER@$NAS_IP true && echo yes")" = yes ]
    then ok "the device can reach the NAS over ssh as $SHARE_USER"
    else not_ok "the device cannot ssh to the NAS, so rsync archiving cannot work"
    fi
  fi

  # Stand in for the car writing footage. There is no USB gadget in a VM, so the
  # clips go straight into the backing file instead of arriving over USB.
  # Named the way the car names them, under an event folder, because the snapshot
  # step links clips per event directory.
  clipdir="2026-09-13_18-00-00"
  clip="${clipdir}-front.mp4"
  on_device "mkdir -p /tmp/camseed" > /dev/null
  if [ "$(on_device "/root/bin/mountimage /backingfiles/cam_disk.bin /tmp/camseed rw && echo mounted")" = mounted ]
  then
    ok "mounted the cam image to seed it"
    on_device "mkdir -p /tmp/camseed/TeslaCam/SavedClips/$clipdir && \
               head -c 2097152 /dev/urandom > /tmp/camseed/TeslaCam/SavedClips/$clipdir/$clip && \
               sync" > /dev/null
    seeded=$(on_device "ls -l /tmp/camseed/TeslaCam/SavedClips/$clipdir/$clip | awk '{print \$5}'")
    on_device "umount /tmp/camseed" > /dev/null
    if [ "$seeded" = 2097152 ]
    then ok "seeded a 2MB clip into SavedClips"
    else not_ok "could not seed a clip (size reported: '$seeded')"
    fi
  else
    not_ok "could not mount the cam image"
  fi

  # Make sure nothing is already on the share, so what we find later is ours.
  on_nas "rm -rf /srv/$SHARE_NAME/*" > /dev/null

  # Clips are archived from a snapshot, not from the live cam mount, and a
  # snapshot is normally taken when the car disconnects. Restarting the service is
  # the honest equivalent here: archiveloop snapshots what it finds on startup,
  # exactly as it would on a device that booted with footage already on the disk.
  # Without this the cycle runs and archives nothing, because the only snapshot
  # predates the clip.
  log "restarting archiveloop so it snapshots the seeded clip"
  on_device "systemctl restart teslausb" > /dev/null
  sleep 20

  log "forcing an archive cycle"
  # force_sync is teslausb's own way in: it pretends the archive went away and
  # came back, which makes archiveloop run a cycle.
  on_device "timeout 150 /root/bin/force_sync.sh" > /dev/null 2>&1 &
  force_pid=$!

  found=0
  for (( i = 0; i < 40; i++ ))
  do
    sleep 15
    if [ "$(on_nas "find /srv/$SHARE_NAME -name '$clip' | head -1")" != "" ]
    then
      found=1
      break
    fi
  done
  wait "$force_pid" 2> /dev/null

  if [ "$found" = 1 ]
  then
    ok "the clip arrived on the NAS over $ARCHIVE"
    landed=$(on_nas "find /srv/$SHARE_NAME -name '$clip' -printf '%s' | head -1")
    if [ "$landed" = 2097152 ]
    then ok "and it arrived intact (2MB)"
    else not_ok "it arrived with size '$landed', expected 2097152"
    fi
    printf '   on the NAS: %s\n' "$(on_nas "find /srv/$SHARE_NAME -name '$clip'" | head -1)"
    # the archive log is the other half of what was asked for
    if [ "$(on_device 'test -s /mutable/archiveloop.log && echo yes')" = yes ]
    then ok "archiveloop wrote a log"
    else not_ok "archiveloop left no log"
    fi
    if on_device "grep -qi 'archiv' /mutable/archiveloop.log"
    then ok "and the log mentions archiving"
    else not_ok "the log does not mention archiving"
    fi
  else
    not_ok "the clip never arrived on the NAS"
    printf '   archiveloop log: %s\n' "$(on_device 'tail -3 /mutable/archiveloop.log 2>/dev/null' | tr '\n' ' ' | cut -c1-160)"
  fi
fi

if [ "${AP:-0}" = 1 ] && [ "$setup_done" = 1 ]
then
  # ---------------------------------------------------------------------------
  log "the access point, with simulated radios"
  # ---------------------------------------------------------------------------
  # There is no wireless hardware in a VM, so mac80211_hwsim provides two virtual
  # radios that can hear each other. One carries teslausb's access point, the
  # other associates to it as a client would. That exercises hostapd, the WPA2
  # handshake, dnsmasq's DHCP and reaching the web interface over the AP link.
  if [ "$(on_device "modprobe mac80211_hwsim radios=2 && echo yes" 2>&1 | tail -1)" = yes ]
  then
    ok "simulated wifi radios are available"

    # The service was enabled during setup but had no radio to start on.
    on_device "systemctl restart teslausb-ap.service" > /dev/null 2>&1 || true
    sleep 15

    if [ "$(on_device "systemctl is-active teslausb-ap.service")" = active ]
    then ok "the access point service is running"
    else
      not_ok "the access point service did not start"
      printf '   %s\n' "$(on_device "journalctl -u teslausb-ap -n3 --no-pager" | tr '\n' ' ' | cut -c1-150)"
    fi

    if [ "$(on_device "iw dev ap0 info > /dev/null 2>&1 && echo yes")" = yes ]
    then ok "ap0 exists on the same radio as the client interface"
    else not_ok "ap0 was not created"
    fi

    if [ "$(on_device "ip -o -4 addr show ap0 | grep -c '$AP_ADDRESS'")" = 1 ]
    then ok "ap0 has the configured address $AP_ADDRESS"
    else not_ok "ap0 does not have $AP_ADDRESS"
    fi

    # teslausb puts ap0 on the same radio as its client interface, which is the
    # whole point of the arrangement, so the interface used to test against it has
    # to be on the other simulated radio. Whichever radio hostapd took, pick a
    # wifi interface that is not on it.
    client_if=$(on_device "ap_phy=\$(cat /sys/class/net/ap0/phy80211/name 2>/dev/null)
      for d in /sys/class/net/wlan*
      do
        [ -e \"\$d/phy80211/name\" ] || continue
        [ \"\$(cat \$d/phy80211/name)\" = \"\$ap_phy\" ] && continue
        basename \"\$d\"
        break
      done")
    if [ -n "$client_if" ]
    then ok "a separate radio ($client_if) is available to associate from"
    else not_ok "no radio outside the access point's own to test from"
    fi

    # A client to associate with. The device itself has no wpa_supplicant, because
    # this lab device is on ethernet and DietPi only installs it for wifi, so this
    # is test scaffolding rather than something teslausb needs.
    on_device "DEBIAN_FRONTEND=noninteractive apt-get -qq -y install wpasupplicant" > /dev/null 2>&1
    if [ "$(on_device "command -v wpa_supplicant > /dev/null && echo yes")" = yes ]
    then ok "a wifi client is available to test with"
    else not_ok "could not install wpasupplicant to test the access point with"
    fi

    # Associate the second radio, the way a phone in the car would.
    associated=$(on_device "
      cat > /tmp/lab-client.conf <<'WPA'
network={
  ssid=\"$AP_SSID\"
  psk=\"$AP_PASS\"
}
WPA
      # -x, not -f: matching the full command line would match this very command,
      # which contains the words wpa_supplicant and the interface name, and kill
      # the shell running it.
      pkill -x wpa_supplicant > /dev/null 2>&1 || true
      ip link set $client_if up
      # setsid so logind does not take the daemon down with this ssh session, since
      # the checks that follow arrive on a later connection.
      setsid wpa_supplicant -B -D nl80211 -i $client_if -c /tmp/lab-client.conf -f /tmp/lab-wpa.log
      for i in \$(seq 1 20)
      do
        if iw dev $client_if link | grep -q 'Connected to'
        then echo associated; break
        fi
        sleep 2
      done")
    if [ "$(printf '%s' "$associated" | tail -1)" = associated ]
    then ok "a client associated to the access point over WPA2"
    else
      not_ok "no client could associate"
      printf '   %s\n' "$(on_device "tail -3 /tmp/lab-wpa.log" | tr '\n' ' ' | cut -c1-150)"
    fi

    # DHCP, without letting the client rewrite this machine's routing: the lease
    # is what proves dnsmasq answered over the AP link.
    on_device "dhclient -1 -sf /bin/true -lf /tmp/lab-dhcp.leases $client_if > /dev/null 2>&1 || true" > /dev/null
    client_mac=$(on_device "cat /sys/class/net/$client_if/address")
    leased=$(on_device "grep -A6 'lease' /tmp/lab-dhcp.leases 2>/dev/null | awk '/fixed-address/ {print \$2}' | tr -d ';' | tail -1")
    case "$leased" in
      192.168.66.*)
        ok "dnsmasq handed the client $leased over the access point"
        ;;
      *)
        not_ok "the client got no address from the access point (got '${leased:-nothing}')"
        ;;
    esac
    if [ "$(on_device "grep -c '$client_mac' /mutable/teslausb-ap.leases 2>/dev/null")" != 0 ]
    then ok "and recorded the lease on the writable partition"
    else not_ok "no lease was recorded in /mutable/teslausb-ap.leases"
    fi

    # Finally, reach the web interface the way someone in the car would.
    if [ -n "${leased:-}" ]
    then
      http=$(on_device "ip addr add $leased/24 dev $client_if 2>/dev/null
                        curl -s -o /dev/null -m 10 -w '%{http_code}' http://$AP_ADDRESS/ 2>/dev/null")
      case "$http" in
        200|401) ok "the web interface answers over the access point ($http)" ;;
        *)       not_ok "the web interface did not answer over the access point (got '$http')" ;;
      esac
    fi
  else
    not_ok "mac80211_hwsim is not available, so the access point cannot be tested here"
  fi
fi

# ---------------------------------------------------------------------------
log "summary"
# ---------------------------------------------------------------------------
printf 'lab: %d passed, %d failed\n' "$pass_count" "$fail_count"
printf 'logs: %s\n' "$RUN_DIR"

if [ "$KEEP" = 1 ]
then
  cat <<EOF

Both VMs are still running.

  device: ssh -i $TEST_KEY -p $DEVICE_SSH_PORT root@localhost
  NAS:    ssh -i $TEST_KEY -p $NAS_SSH_PORT root@localhost
  (password: $VM_PASSWORD)

  serial: $RUN_DIR/device-serial.log
          $RUN_DIR/nas-serial.log

  stop:   kill $DEVICE_PID $NAS_PID
EOF
  trap - EXIT
fi

[ "$fail_count" -eq 0 ] || exit 1
exit 0
