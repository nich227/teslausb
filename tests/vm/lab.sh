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

# invoked via trap
# shellcheck disable=SC2329
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
export TESLAUSB_HOSTNAME=teslausb
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
export RSYNC_PATH=${SHARE_NAME}
export RSYNC_PASSWORD='${SHARE_PASS}'
export OS_PASSWORD='${VM_PASSWORD}'
export TESLAUSB_HOSTNAME=teslausb
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
readonly NAS_IMG="$CACHE_DIR/lab-nas.img"

log "preparing both VMs"
prepare_vm device "$DEVICE_IP" "/run-dir/$(basename "$LAB_CONF")" "$DEVICE_IMG"
prepare_vm nas    "$NAS_IP"    ""                            "$NAS_IMG"

# Boot from overlays so the prepared images stay pristine.
readonly DEVICE_OVL="$RUN_DIR/device.qcow2"
readonly NAS_OVL="$RUN_DIR/nas.qcow2"
rm -f "$DEVICE_OVL" "$NAS_OVL"
qemu-img create -q -f qcow2 -F raw -b "$DEVICE_IMG" "$DEVICE_OVL" > /dev/null
qemu-img create -q -f qcow2 -F raw -b "$NAS_IMG" "$NAS_OVL" > /dev/null

# ---------------------------------------------------------------------------
# Boot. The private segment is a QEMU socket link: one VM listens, the other
# connects, and nothing else can reach it.
# ---------------------------------------------------------------------------
boot_vm () {
  local role="$1" ovl="$2" ssh_port="$3" mac_suffix="$4" socket_arg="$5"

  qemu-system-x86_64 \
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
NAS_PID=$(boot_vm nas "$NAS_OVL" "$NAS_SSH_PORT" 20 "listen=127.0.0.1:${LAB_NET_PORT}")
sleep 3
log "booting the device (connecting to the private segment)"
DEVICE_PID=$(boot_vm device "$DEVICE_OVL" "$DEVICE_SSH_PORT" 10 "connect=127.0.0.1:${LAB_NET_PORT}")

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

log "waiting for both VMs to answer (up to ${TIMEOUT}s)"
wait_for nas 120 || { echo "FATAL: the NAS never came up; see $RUN_DIR/nas-serial.log" >&2; exit 1; }
ok "the NAS is up"
wait_for device 120 || { echo "FATAL: the device never came up; see $RUN_DIR/device-serial.log" >&2; exit 1; }
ok "the device is up"

log "letting DietPi finish its own setup on both"
advance_first_run nas || step "the NAS did not reach install stage 2; carrying on"
advance_first_run device || step "the device did not reach install stage 2; carrying on"

if [ "$LOGIN_SHELL" != bash ]
then
  log "setting the login shell to $LOGIN_SHELL on both VMs"
  set_login_shell nas "$LOGIN_SHELL"
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
log "setting up the archive share on the NAS"
# ---------------------------------------------------------------------------
on_nas "DEBIAN_FRONTEND=noninteractive apt-get -qq update" > /dev/null
case "$ARCHIVE" in
  cifs)
    on_nas "DEBIAN_FRONTEND=noninteractive apt-get -qq -y install samba avahi-daemon libnss-mdns curl" > /dev/null
    on_nas "mkdir -p /srv/$SHARE_NAME && chmod 777 /srv/$SHARE_NAME"
    on_nas "id $SHARE_USER || useradd -M -s /usr/sbin/nologin $SHARE_USER"
    on_nas "printf '%s\n%s\n' '$SHARE_PASS' '$SHARE_PASS' | smbpasswd -s -a $SHARE_USER"
    on_nas "cat >> /etc/samba/smb.conf <<'EOF'
[$SHARE_NAME]
   path = /srv/$SHARE_NAME
   browseable = yes
   read only = no
   guest ok = no
   valid users = $SHARE_USER
EOF"
    on_nas "systemctl restart smbd"
    if [ "$(on_nas "systemctl is-active smbd")" = active ]
    then ok "the NAS is serving an SMB share"
    else not_ok "smbd is not running on the NAS"
    fi
    ;;
  rsync)
    on_nas "DEBIAN_FRONTEND=noninteractive apt-get -qq -y install rsync avahi-daemon libnss-mdns curl" > /dev/null
    on_nas "mkdir -p /srv/$SHARE_NAME && chmod 777 /srv/$SHARE_NAME"
    on_nas "cat > /etc/rsyncd.conf <<'EOF'
[$SHARE_NAME]
   path = /srv/$SHARE_NAME
   read only = false
   auth users = $SHARE_USER
   secrets file = /etc/rsyncd.secrets
EOF"
    on_nas "printf '%s:%s\n' '$SHARE_USER' '$SHARE_PASS' > /etc/rsyncd.secrets && chmod 600 /etc/rsyncd.secrets"
    on_nas "systemctl enable --now rsync"
    if [ "$(on_nas "systemctl is-active rsync")" = active ]
    then ok "the NAS is serving an rsync module"
    else not_ok "rsyncd is not running on the NAS"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
log "what the NAS can see of the device"
# ---------------------------------------------------------------------------
# This is the check a person on the same network would make.
mdns=$(on_nas "getent hosts teslausb.local | awk '{print \$1}'")
if [ -n "$mdns" ]
then
  ok "teslausb.local resolves from the NAS (to $mdns)"
  if [ "$mdns" = "$DEVICE_IP" ]
  then ok "and it resolves to the device's private address"
  else not_ok "it resolves to $mdns, not $DEVICE_IP"
  fi
else
  not_ok "teslausb.local does not resolve from the NAS"
fi

if [ "$(on_nas "ping -c1 -W3 teslausb.local > /dev/null 2>&1 && echo yes")" = yes ]
then ok "teslausb.local answers a ping from the NAS"
else not_ok "teslausb.local does not answer from the NAS"
fi

http_code=$(on_nas "curl -s -o /dev/null -m 10 -w '%{http_code}' http://teslausb.local/ 2>/dev/null")
case "$http_code" in
  200|401)
    ok "the web interface answers on http://teslausb.local/ ($http_code)"
    ;;
  *)
    # fall back to the address, to tell a web server problem from a name problem
    http_ip=$(on_nas "curl -s -o /dev/null -m 10 -w '%{http_code}' http://$DEVICE_IP/ 2>/dev/null")
    if [ "$http_ip" = 200 ] || [ "$http_ip" = 401 ]
    then not_ok "the web interface answers on $DEVICE_IP ($http_ip) but not via teslausb.local"
    else not_ok "the web interface did not answer (by name: '$http_code', by address: '$http_ip')"
    fi
    ;;
esac

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
