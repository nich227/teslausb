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

readonly NAS_HOSTNAME=teslanas
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
export RSYNC_PATH=/srv/${SHARE_NAME}
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
  # the NAS is a plain DietPi with a share on it, not a second teslausb
  local bootstrap=1 hostname_key="AUTO_SETUP_NET_HOSTNAME=teslausb"
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
# The NAS is booted and provisioned before the device exists at all. The device
# runs teslausb setup unattended within a couple of minutes of first boot, and if
# the share is not serving by the time it checks, setup gives up for good. In one
# run samba finished installing at 15:29:29 and the device had already tried, and
# failed, at 15:28:56.
NAS_PID=$(boot_vm nas "$NAS_OVL" "$NAS_SSH_PORT" 20 "listen=127.0.0.1:${LAB_NET_PORT}")
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
      # teslausb's rsync backend is rsync over ssh: archive-clips.sh runs
      # rsync ... "$RSYNC_USER@$RSYNC_SERVER:$RSYNC_PATH" and the reachability
      # check falls back to "ssh $RSYNC_USER@host exit". An rsync daemon with a
      # secrets file, which is what this used to set up, is never contacted. So
      # the NAS gets a real account with a home directory instead, and the
      # destination is an absolute path owned by it.
      on_nas "DEBIAN_FRONTEND=noninteractive apt-get -qq -y install rsync avahi-daemon libnss-mdns curl" > /dev/null
      on_nas "id $SHARE_USER > /dev/null 2>&1 || useradd -m -s /bin/bash $SHARE_USER"
      on_nas "mkdir -p /srv/$SHARE_NAME && chown $SHARE_USER:$SHARE_USER /srv/$SHARE_NAME && chmod 755 /srv/$SHARE_NAME"
      if [ "$(on_nas "systemctl is-active ssh")" = active ]
      then ok "the NAS accepts ssh, which is what rsync archiving uses"
      else not_ok "sshd is not running on the NAS"
      fi
      ;;
  esac

}

log "waiting for both VMs to answer (up to ${TIMEOUT}s)"
wait_for nas 120 || { echo "FATAL: the NAS never came up; see $RUN_DIR/nas-serial.log" >&2; exit 1; }
ok "the NAS is up"

log "setting up the archive share on the NAS, before the device needs it"
advance_first_run nas || step "the NAS did not reach install stage 2; carrying on"
[ "$LOGIN_SHELL" != bash ] && set_login_shell nas "$LOGIN_SHELL"
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

# The web interface is put in place by setup, which is still running at this
# point, so a 403 here means "not configured yet" rather than broken. Wait for it
# instead of judging it mid-setup.
http_code=000
for (( i = 0; i < 60; i++ ))
do
  http_code=$(on_nas "curl -s -o /dev/null -m 10 -w '%{http_code}' http://teslausb.local/ 2>/dev/null")
  case "$http_code" in
    200|401) break ;;
  esac
  sleep 20
done
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
