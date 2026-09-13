#!/bin/bash
#
# Boot a real DietPi VM and check that the first boot does what it should.
#
# The container suite covers the scripts in isolation. This covers the things
# that need an actual boot: DietPi consuming the settings we wrote before first
# boot, doing its first run without asking any questions, running the teslausb
# bootstrap, and leaving the setup driver in charge.
#
# Nothing here needs root on the host. The image is prepared with debugfs inside
# a container, and QEMU runs as you.
#
# Usage:
#   tests/vm/run-vm-test.sh [options]
#
#     --net user          port-forwarded networking (default; works in CI)
#     --net bridge --bridge br0
#                         attach to a host bridge, so the VM gets an address from
#                         your router like a real device would
#     --net macvtap --iface eth0
#                         attach directly to a host interface. The VM is on your
#                         LAN, but the host itself cannot reach it: that is a
#                         macvtap limitation, not a bug.
#     --keep              leave the VM running afterwards and print how to log in
#     --conf FILE         teslausb config to install (default tests/vm/vm-test.conf)
#     --ssh-port N        host port to forward to the VM's SSH (user mode, default 2222)
#     --timeout SECONDS   how long to wait for the boot to finish (default 900)
#     --distro NAME       Bookworm (default) or Trixie
#
# Examples:
#   tests/vm/run-vm-test.sh                       # automated check
#   tests/vm/run-vm-test.sh --keep                # then: ssh -p 2222 root@localhost
#   tests/vm/run-vm-test.sh --net bridge --bridge br0 --keep

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly REPO
readonly CACHE_DIR="${DIETPI_CACHE_DIR:-${TMPDIR:-/tmp}/dietpi-images}"

NET_MODE=user
BRIDGE=""
IFACE=""
KEEP=0
CONF="$SCRIPT_DIR/vm-test.conf"
SSH_PORT=2222
TIMEOUT=900
DISTRO=Bookworm
JUMP_HOST=""
VM_DNS=""
STATIC_IP=""
STATIC_MASK="255.255.255.0"
STATIC_GW=""

while [ $# -gt 0 ]
do
  case "$1" in
    --net)       NET_MODE="$2"; shift 2 ;;
    --bridge)    BRIDGE="$2"; shift 2 ;;
    --iface)     IFACE="$2"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    --conf)      CONF="$2"; shift 2 ;;
    --ssh-port)  SSH_PORT="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --distro)    DISTRO="$2"; shift 2 ;;
    --jump-host) JUMP_HOST="$2"; shift 2 ;;
    --dns)       VM_DNS="$2"; shift 2 ;;
    --static-ip) STATIC_IP="$2"; shift 2 ;;
    --mask)      STATIC_MASK="$2"; shift 2 ;;
    --gateway)   STATIC_GW="$2"; shift 2 ;;
    -h|--help)   sed -n '2,35p' "$0"; exit 0 ;;
    *)           echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

readonly IMAGE_NAME="DietPi_VM-x86_64-${DISTRO}.img.xz"
readonly BASE_URL="https://dietpi.com/downloads/images"
readonly VM_IMAGE="$CACHE_DIR/teslausb-vm.img"
# QEMU boots a throwaway overlay rather than the prepared image, so the image
# stays pristine and every run starts from the same known state.
readonly VM_OVERLAY="$CACHE_DIR/teslausb-vm-run.qcow2"
readonly SERIAL_LOG="${TMPDIR:-/tmp}/teslausb-vm-serial.log"

pass_count=0
fail_count=0
QEMU_PID=""

log ()    { printf '\n==> %s\n' "$*"; }
ok ()     { pass_count=$(( pass_count + 1 )); printf '   ok: %s\n' "$1"; }
not_ok () { fail_count=$(( fail_count + 1 )); printf '   FAIL: %s\n' "$1"; }

# invoked via trap
# shellcheck disable=SC2329
cleanup () {
  if [ -n "$QEMU_PID" ] && kill -0 "$QEMU_PID" 2> /dev/null
  then
    if [ "$KEEP" = 1 ]
    then
      return 0
    fi
    kill "$QEMU_PID" 2> /dev/null
    wait "$QEMU_PID" 2> /dev/null
  fi
}
trap cleanup EXIT

# --- prerequisites ---------------------------------------------------------
for tool in qemu-system-x86_64 docker sshpass
do
  command -v "$tool" > /dev/null || { echo "FATAL: $tool is required" >&2; exit 1; }
done

ACCEL=tcg
if [ -r /dev/kvm ] && [ -w /dev/kvm ]
then
  ACCEL=kvm
else
  echo "NOTE: /dev/kvm is not usable, falling back to emulation. This will be slow."
fi

# --- ICMP, which DietPi's first run insists on -----------------------------
# DietPi-Update checks connectivity with 'ping -4nc 1 -W 10 9.9.9.9' and refuses
# to continue without it. QEMU's user-mode networking can only carry ICMP if the
# host allows unprivileged ping sockets, so check now rather than letting the
# boot fail several minutes in with a confusing DietPi error.
if [ "$NET_MODE" = user ]
then
  read -r ping_lo ping_hi < /proc/sys/net/ipv4/ping_group_range
  my_gid=$(id -g)
  if [ "$ping_lo" -gt "$ping_hi" ] || [ "$my_gid" -lt "$ping_lo" ] || [ "$my_gid" -gt "$ping_hi" ]
  then
    cat >&2 <<EOF

FATAL: this host does not allow unprivileged ICMP, so the VM would have no
       working ping. DietPi's first run setup checks connectivity with ping and
       gives up without it, so the boot would fail part way through.

       net.ipv4.ping_group_range is "$ping_lo $ping_hi" and your gid is $my_gid.

       Either allow it:

         sudo sysctl -w net.ipv4.ping_group_range="0 2147483647"

       (revert with: sudo sysctl -w net.ipv4.ping_group_range="$ping_lo $ping_hi")

       or use LAN networking, which does not go through QEMU's user-mode stack:

         $0 --net bridge --bridge br0
         $0 --net macvtap --iface <interface>

EOF
    exit 1
  fi
fi

# --- the config the VM will be built with ----------------------------------
[ -f "$CONF" ] || { echo "FATAL: $CONF does not exist" >&2; exit 1; }
CONF="$(cd "$(dirname "$CONF")" && pwd)/$(basename "$CONF")"
VM_PASSWORD=$( ( set +u; # shellcheck disable=SC1090
                 source "$CONF" 2> /dev/null; printf '%s' "${OS_PASSWORD:-dietpi}" ) )
VM_HOSTNAME=$( ( set +u; # shellcheck disable=SC1090
                 source "$CONF" 2> /dev/null; printf '%s' "${TESLAUSB_HOSTNAME:-teslausb}" ) )

# --- DNS for LAN modes -----------------------------------------------------
# A macvtap guest cannot reach its own host. If the LAN's DNS server happens to
# be that host, the VM ends up with no resolver and DietPi's first run setup
# gives up. Default to the LAN gateway, which is reachable either way.
if [ -z "$VM_DNS" ] && [ "$NET_MODE" != user ]
then
  VM_DNS=$(ip route show default 2>/dev/null | awk '/via/ {print $3; exit}')
  VM_DNS="${VM_DNS:-1.1.1.1}"
  echo "   pointing the VM's DNS at $VM_DNS (override with --dns)"
fi

# --- a static address, which avoids racing DHCP ----------------------------
# DietPi's first run setup checks connectivity before its DHCP lease
# necessarily exists: ifupdown-wait-online completes in under two seconds while
# dhclient starts later, so DietPi-Update can report "Network is unreachable",
# terminate, and then wait for someone to confirm a retry on the console. A
# static address removes the race and makes the VM's address predictable.
DIETPI_EXTRA_KEYS=""
if [ -n "$STATIC_IP" ]
then
  STATIC_GW="${STATIC_GW:-$(ip route show default | awk '/via/ {print $3; exit}')}"
  VM_DNS="${VM_DNS:-$STATIC_GW}"
  DIETPI_EXTRA_KEYS="AUTO_SETUP_NET_USESTATIC=1
AUTO_SETUP_NET_STATIC_IP=$STATIC_IP
AUTO_SETUP_NET_STATIC_MASK=$STATIC_MASK
AUTO_SETUP_NET_STATIC_GATEWAY=$STATIC_GW
AUTO_SETUP_NET_STATIC_DNS=$VM_DNS"
  echo "   pinning the VM to $STATIC_IP (mask $STATIC_MASK, gateway $STATIC_GW, dns $VM_DNS)"
fi

# --- an SSH key for the checks ---------------------------------------------
# Injected into the image, so logging in needs no password and works the same
# whether we reach the VM directly or through a jump host.
readonly TEST_KEY="$CACHE_DIR/teslausb-vm-key"
mkdir -p "$CACHE_DIR"
if [ ! -f "$TEST_KEY" ]
then
  ssh-keygen -q -t ed25519 -N "" -C "teslausb-vm-test" -f "$TEST_KEY"
fi

# --- image -----------------------------------------------------------------
mkdir -p "$CACHE_DIR"
if [ ! -s "$CACHE_DIR/$IMAGE_NAME" ]
then
  log "downloading $IMAGE_NAME"
  curl -fsSL --retry 3 -o "$CACHE_DIR/$IMAGE_NAME" "$BASE_URL/$IMAGE_NAME"
fi
log "verifying sha256"
curl -fsSL --retry 3 -o "$CACHE_DIR/$IMAGE_NAME.sha256" "$BASE_URL/$IMAGE_NAME.sha256"
( cd "$CACHE_DIR" && sha256sum -c "$IMAGE_NAME.sha256" )

if pgrep -f "[q]emu-system-x86_64.*$(basename "$VM_OVERLAY")" > /dev/null
then
  echo "FATAL: a VM from a previous run is still using $VM_OVERLAY." >&2
  echo "       Stop it first: pkill -f '[q]emu-system-x86_64.*$(basename "$VM_OVERLAY")'" >&2
  exit 1
fi

log "preparing the VM image (this is where prepare-boot-partition.sh runs)"
docker run --rm \
  -v "$CACHE_DIR:/cache" \
  -v "$REPO:/repo:ro" \
  -e "IMAGE_NAME=$IMAGE_NAME" \
  -e "CONF=/repo/${CONF#"$REPO"/}" \
  -e "SSH_PUBKEY=/cache/$(basename "$TEST_KEY").pub" \
  -e "VM_DNS=$VM_DNS" \
  -e "DIETPI_EXTRA_KEYS=$DIETPI_EXTRA_KEYS" \
  -e "HOST_UID=$(id -u)" \
  -e "HOST_GID=$(id -g)" \
  debian:bookworm-slim \
  bash /repo/tests/vm/inject.sh || {
    echo "FATAL: preparing the VM image failed" >&2
    exit 1
  }

# --- a throwaway overlay to boot from --------------------------------------
rm -f "$VM_OVERLAY"
qemu-img create -q -f qcow2 -F raw -b "$VM_IMAGE" "$VM_OVERLAY" > /dev/null

# --- networking ------------------------------------------------------------
declare -a NETDEV
case "$NET_MODE" in
  user)
    NETDEV=(-netdev "user,id=n0,hostfwd=tcp::${SSH_PORT}-:22" -device "virtio-net-pci,netdev=n0")
    SSH_TARGET="localhost"
    SSH_ARGS=(-p "$SSH_PORT")
    ;;
  bridge)
    [ -n "$BRIDGE" ] || { echo "FATAL: --net bridge needs --bridge NAME" >&2; exit 1; }
    NETDEV=(-netdev "bridge,id=n0,br=$BRIDGE" -device "virtio-net-pci,netdev=n0")
    SSH_TARGET="$VM_HOSTNAME"
    SSH_ARGS=()
    ;;
  macvtap)
    [ -n "$IFACE" ] || { echo "FATAL: --net macvtap needs --iface NAME" >&2; exit 1; }
    [ -n "$STATIC_IP" ] && SSH_TARGET_PINNED="$STATIC_IP"
    tapdev=$(ip -brief link show type macvtap 2>/dev/null | awk '{print $1; exit}')
    tapdev=${tapdev%%@*}
    [ -n "$tapdev" ] || { echo "FATAL: no macvtap interface found. Create one first." >&2; exit 1; }
    tapidx=$(cat "/sys/class/net/$tapdev/ifindex")
    # The guest must use the macvtap's own MAC, otherwise the interface drops
    # the frames it sends and the VM appears to have no network at all.
    tapmac=$(cat "/sys/class/net/$tapdev/address")
    [ -r "/dev/tap${tapidx}" ] && [ -w "/dev/tap${tapidx}" ] || {
      echo "FATAL: /dev/tap${tapidx} is not accessible. It needs to be readable by you:" >&2
      echo "         sudo chown $(id -un) /dev/tap${tapidx}" >&2
      exit 1
    }
    NETDEV=(-netdev "tap,id=n0,fd=3,vhost=off" -device "virtio-net-pci,netdev=n0,mac=$tapmac")
    exec 3<>"/dev/tap${tapidx}" || { echo "FATAL: cannot open /dev/tap${tapidx}" >&2; exit 1; }
    echo "   using $tapdev (mac $tapmac) on $IFACE"
    SSH_TARGET="${SSH_TARGET_PINNED:-}"   # discovered from the boot log if not pinned
    SSH_ARGS=()
    ;;
  *)
    echo "FATAL: unknown --net mode '$NET_MODE'" >&2; exit 1 ;;
esac

# --- boot ------------------------------------------------------------------
rm -f "$SERIAL_LOG"
log "booting DietPi $DISTRO (accel=$ACCEL, net=$NET_MODE)"
qemu-system-x86_64 \
  -machine accel="$ACCEL" \
  -m 1024 \
  -smp 2 \
  -drive "file=$VM_OVERLAY,format=qcow2,if=virtio,cache=writeback" \
  "${NETDEV[@]}" \
  -nographic \
  -serial "file:$SERIAL_LOG" \
  -monitor none \
  &> "${TMPDIR:-/tmp}/teslausb-vm-qemu.log" &
QEMU_PID=$!

# --- wait for the boot to get somewhere ------------------------------------
log "waiting for the first boot to finish (up to ${TIMEOUT}s)"
waited=0
booted=0
while [ "$waited" -lt "$TIMEOUT" ]
do
  if ! kill -0 "$QEMU_PID" 2> /dev/null
  then
    echo "   QEMU exited early; see ${TMPDIR:-/tmp}/teslausb-vm-qemu.log"
    break
  fi
  # the teslausb bootstrap says this once DietPi has handed over
  if grep -q "teslausb bootstrap starting" "$SERIAL_LOG" 2> /dev/null
  then
    booted=1
    break
  fi
  # A VM that never gets a lease will sit here until the timeout with nothing to
  # show for it, so call it out as soon as it is obvious.
  if [ "$waited" -ge 90 ] && [ "$NET_MODE" != user ] &&
     grep -qc "DHCPDISCOVER" "$SERIAL_LOG" 2> /dev/null &&
     ! grep -q "bound to\|DHCPACK" "$SERIAL_LOG" 2> /dev/null
  then
    echo
    echo "FATAL: the VM is not getting a DHCP lease on $IFACE." >&2
    echo "       Its MAC is $(cat "/sys/class/net/$tapdev/address" 2>/dev/null)." >&2
    echo "       Recreating the macvtap gives it a fresh MAC, which usually helps:" >&2
    echo "         sudo ip link del $tapdev" >&2
    echo "         sudo ip link add link $IFACE name $tapdev type macvtap mode bridge" >&2
    echo "         sudo ip link set $tapdev up" >&2
    echo "         sudo chown \$(id -un) /dev/tap\$(cat /sys/class/net/$tapdev/ifindex)" >&2
    break
  fi
  sleep 10
  waited=$(( waited + 10 ))
  printf '   %ss elapsed%s\r' "$waited" "$(
    tail -1 "$SERIAL_LOG" 2> /dev/null | tr -dc '[:print:]' | cut -c1-40 | sed 's/^/  ... /'
  )"
done
echo

# --- which address did it get? ---------------------------------------------
# DietPi prints the address in its console banner, which is the only way to find
# a macvtap guest from here: the host cannot reach it to ask.
if [ -z "$SSH_TARGET" ]
then
  for _ in $(seq 1 30)
  do
    VM_IP=$(grep -ao 'IP: [0-9.]\{7,15\}' "$SERIAL_LOG" 2> /dev/null | tail -1 | awk '{print $2}')
    [ -n "${VM_IP:-}" ] && break
    sleep 5
  done
  if [ -n "${VM_IP:-}" ]
  then
    SSH_TARGET="$VM_IP"
    echo "   the VM reports address $VM_IP"
  else
    SSH_TARGET="$VM_HOSTNAME"
    echo "   could not find an address in the boot log, trying $VM_HOSTNAME"
  fi
fi

# ===========================================================================
log "checks"
# ===========================================================================
if [ "$booted" = 1 ]
then
  ok "the bootstrap reported itself on the console"
else
  # DietPi runs first run setup on its autologin console, so this is expected to
  # be quiet here; the SSH checks below are what confirm it.
  printf '   note: nothing from the bootstrap on the serial console yet\n'
fi

if grep -qi "DietPi-Software.*first run setup\|Automated setup is in progress" "$SERIAL_LOG" 2> /dev/null
then ok "DietPi ran its first run setup"
else printf '   note: no first run setup banner in the serial log\n'
fi

# The interactive setup asks questions with whiptail; if it did, the log says so.
if grep -qi "Please select\|Choose an option\|whiptail" "$SERIAL_LOG" 2> /dev/null
then not_ok "DietPi appears to have prompted for input"
else ok "DietPi did not prompt for anything"
fi

# --- checks that need to be run inside the VM ------------------------------
# A macvtap guest cannot be reached from its own host, so the checks go through
# another machine on the LAN when --jump-host is given. Authentication uses the
# injected key from here, so the jump host needs no credentials of its own.
declare -a SSH_COMMON=(
  -i "$TEST_KEY"
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
  -o IdentitiesOnly=yes
)
[ -n "$JUMP_HOST" ] && SSH_COMMON+=(-J "$JUMP_HOST")

ssh_vm () {
  # the command is expanded by the remote shell on purpose: the checks below ask
  # about state inside the VM
  # shellcheck disable=SC2029
  ssh "${SSH_COMMON[@]}" "${SSH_ARGS[@]}" "root@$SSH_TARGET" "$@" 2> /dev/null
}

# DietPi advances its first run setup from /etc/bashrc.d/dietpi.bash, which calls
# dietpi-login for any interactive login shell. The image autologs into tty1 to
# make that happen by itself; this drives the same thing over SSH so the test does
# not depend on being able to see or reach that console, and so a stalled
# autologin does not hang the run. Each call advances one phase, and the phases
# reboot, hence the loop.
advance_first_run () {
  local _phase
  for _phase in 1 2 3
  do
    ssh "${SSH_COMMON[@]}" -tt "${SSH_ARGS[@]}" "root@$SSH_TARGET" \
      "bash -lic 'exit'" >> "$FIRSTRUN_LOG" 2>&1
    sleep 20
    wait_for_ssh 40 || true
    [ "$(ssh_vm 'cat /boot/dietpi/.install_stage 2>/dev/null')" = 2 ] && return 0
  done
  return 0
}

wait_for_ssh () {
  local tries="${1:-30}"
  local i
  for (( i = 0; i < tries; i++ ))
  do
    ssh_vm true && return 0
    sleep 5
  done
  return 1
}

readonly FIRSTRUN_LOG="${TMPDIR:-/tmp}/teslausb-vm-firstrun.log"
rm -f "$FIRSTRUN_LOG"

log "waiting for SSH"
ssh_up=0
for _ in $(seq 1 30)
do
  if ssh_vm true
  then ssh_up=1; break
  fi
  sleep 5
done

if [ "$ssh_up" = 1 ]
then
  ok "SSH is reachable"

  if [ "$(ssh_vm 'cat /boot/dietpi/.install_stage 2>/dev/null')" != 2 ]
  then
    log "advancing DietPi's first run setup (log: $FIRSTRUN_LOG)"
    advance_first_run
  fi

  # what the bootstrap should have done, from its own log on the boot partition
  if ssh_vm 'grep -q "teslausb bootstrap starting" /boot/teslausb-headless-setup.log' 2>/dev/null
  then ok "DietPi ran the teslausb bootstrap"
  else not_ok "the teslausb bootstrap did not run"
  fi
  if ssh_vm 'grep -q "handing over to teslausb setup" /boot/teslausb-headless-setup.log' 2>/dev/null
  then ok "the bootstrap handed over to teslausb setup"
  else not_ok "the bootstrap did not hand over"
  fi

  assert_vm () {
    local desc="$1" cmd="$2" want="$3"
    local got
    got=$(ssh_vm "$cmd")
    if [ "$got" = "$want" ]
    then ok "$desc"
    else not_ok "$desc (expected '$want', got '$got')"
    fi
  }

  assert_vm "the hostname we asked for was applied" "hostname" "$VM_HOSTNAME"
  assert_vm "DietPi finished its own first run setup" "cat /boot/dietpi/.install_stage" "2"
  assert_vm "the teslausb setup driver is installed" "test -x /root/bin/first-boot.sh && echo yes" "yes"
  assert_vm "the setup unit is enabled" \
    "systemctl is-enabled teslausb-setup.service 2>/dev/null" "enabled"
  assert_vm "DietPi-RAMlog is gone from fstab" \
    "grep -c '[[:blank:]]/var/log[[:blank:]]' /etc/fstab || true" "0"
  assert_vm "the teslausb config made it onto the device" \
    "test -f /root/teslausb_setup_variables.conf && echo yes" "yes"

  ip_addr=$(ssh_vm "hostname -I | awk '{print \$1}'")
  printf '   the VM has address: %s\n' "$ip_addr"
else
  not_ok "SSH never came up"
fi

# --- summary ---------------------------------------------------------------
printf '\n=== summary ===\n'
printf 'vm: %d passed, %d failed\n' "$pass_count" "$fail_count"
printf 'serial log: %s\n' "$SERIAL_LOG"

if [ "$KEEP" = 1 ]
then
  # shellcheck disable=SC2029  # the heredoc below is instructions, not commands
  cat <<EOF

The VM is still running (pid $QEMU_PID). To log in:


  ssh ${JUMP_HOST:+-J $JUMP_HOST} ${SSH_ARGS[*]} -i $TEST_KEY root@$SSH_TARGET
  (or with a password: ssh ${SSH_ARGS[*]} root@$SSH_TARGET  #  $VM_PASSWORD)

To watch what it is doing:

  tail -f $SERIAL_LOG

To stop it:

  kill $QEMU_PID
EOF
  trap - EXIT
fi

[ "$fail_count" -eq 0 ] || exit 1
exit 0
