#!/bin/bash
#
# Integration tests. Runs INSIDE a container built from the official DietPi
# container image (see tests/docker/), so the scripts execute against a real
# DietPi userland: real bash, real findmnt, real pgrep, real coreutils, at the
# real teslausb paths (/backingfiles, /mutable).
#
# Two things are necessarily faked, because a container cannot provide them:
#   * /sys/class/udc  - sysfs is read-only, so the gadget state directory is
#                       pointed elsewhere with UDC_DIR.
#   * systemctl       - systemd is not running as PID 1 here, so a stub on PATH
#                       records the calls the installer makes.
# Everything else is the real thing.
#
# Usage: tests/integration-test.sh   (normally invoked by run-integration-tests.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO="$SCRIPT_DIR/.."

pass_count=0
fail_count=0

start_case () { printf '\n-- %s\n' "$1"; }

ok () {
  pass_count=$(( pass_count + 1 ))
  printf '   ok: %s\n' "$1"
}

not_ok () {
  fail_count=$(( fail_count + 1 ))
  printf '   FAIL: %s\n' "$1"
}

assert_eq () {
  if [ "$1" = "$2" ]
  then ok "$3"
  else not_ok "$3 (expected '$2', got '$1')"
  fi
}

assert_file () {
  if [ -f "$1" ]
  then ok "$2"
  else not_ok "$2 (missing $1)"
  fi
}

assert_no_file () {
  if [ -e "$1" ]
  then not_ok "$2 ($1 should not exist)"
  else ok "$2"
  fi
}

assert_grep () {
  if grep -q -- "$1" "$2" 2> /dev/null
  then ok "$3"
  else not_ok "$3 ('$1' not found in $2)"
  fi
}

banner () { printf '\n=== %s ===\n' "$1"; }

# ===========================================================================
banner "environment"
# ===========================================================================
printf 'DietPi:  %s\n' "$(sed -n 's/^G_DIETPI_VERSION_CORE=\(.*\)/\1/p' /boot/dietpi/.version 2>/dev/null).$(sed -n 's/^G_DIETPI_VERSION_SUB=\(.*\)/\1/p' /boot/dietpi/.version 2>/dev/null)"
printf 'Debian:  %s\n' "$(cat /etc/debian_version 2>/dev/null)"
printf 'bash:    %s\n' "${BASH_VERSION}"

# ===========================================================================
banner "DietPi platform assumptions"
# ===========================================================================
# teslausb targets Raspberry Pi OS. On DietPi the setup needs manual help, and
# these checks pin the assumptions the watchdog itself depends on so a DietPi
# upgrade that breaks them shows up here rather than in the car.

start_case "the base really is DietPi"
assert_file /boot/dietpi/.version "DietPi version file present"
if [ -d /boot/dietpi ]
then ok "DietPi payload present"
else not_ok "no /boot/dietpi: this is not a DietPi image"
fi

start_case "commands the watchdog relies on exist in a bare DietPi"
# DietPi ships a minimal package set, so anything the watchdog calls has to be
# verified rather than assumed.
for cmd in bash awk date stat cat head grep printf findmnt pgrep journalctl sync
do
  if command -v "$cmd" > /dev/null || type -t "$cmd" | grep -q builtin
  then ok "$cmd available"
  else not_ok "$cmd is MISSING from a bare DietPi install"
  fi
done

start_case "watchdog log and state do not live under DietPi's RAM log"
# DietPi's dietpi-ramlog mounts /var/log as tmpfs and flushes it, so anything
# written there is lost on reboot. The watchdog's cooldown state must survive a
# reboot or it would be free to reboot in a loop.
# shellcheck disable=SC2016  # matching the literal ${LOG:-...} in the source
log_default=$(sed -n 's/^readonly LOG="\${LOG:-\(.*\)}"/\1/p' "$REPO/run/usb-link-watchdog.sh")
# shellcheck disable=SC2016  # matching the literal ${STATE:-...} in the source
state_default=$(sed -n 's/^readonly STATE="\${STATE:-\(.*\)}"/\1/p' "$REPO/run/usb-link-watchdog.sh")
assert_eq "${log_default#/var/log}" "$log_default" "log path is outside /var/log (is $log_default)"
assert_eq "${state_default#/var/log}" "$state_default" "state path is outside /var/log (is $state_default)"
case "$state_default" in
  /mutable/*) ok "cooldown state is on the persistent /mutable partition" ;;
  *)          not_ok "cooldown state is at $state_default, which may not persist" ;;
esac

start_case "packages a DietPi install needs for teslausb setup"
# Documented so the gap is visible; teslausb's setup expects these to exist and
# a bare DietPi has none of them. Missing ones are reported, not failed, because
# the watchdog does not need them.
for pkg in wpasupplicant dnsmasq hostapd dosfstools
do
  if dpkg-query -W -f='${Status}' "$pkg" 2> /dev/null | grep -q "install ok installed"
  then ok "$pkg installed"
  else printf '   note: %s not installed (teslausb setup on DietPi needs it)\n' "$pkg"
  fi
done

# ===========================================================================
banner "the port to DietPi"
# ===========================================================================

# Stubs used throughout: systemd is not PID 1 in here, so systemctl is recorded
# rather than executed.
STUBS=/tmp/stubs
mkdir -p "$STUBS" /lib/systemd/system /etc/systemd/system /root/bin
cat > "$STUBS/systemctl" <<'EOF'
#!/bin/bash
# Record every call. Answer queries the way a container with no systemd would:
# nothing is enabled or active unless a test says otherwise.
echo "systemctl $*" >> /tmp/systemctl.calls
for arg in "$@"; do
  case "$arg" in
    is-enabled|is-active|is-failed)
      [ -e "/tmp/systemctl.enabled.${*: -1}" ] && exit 0
      exit 1
      ;;
  esac
done
exit 0
EOF
chmod +x "$STUBS/systemctl"
export PATH="$STUBS:$PATH"

# Line coverage. bash does not take PS4 from the environment, so the tracing is
# switched on through BASH_ENV, which a non-interactive bash sources before it
# runs the script. tests/coverage.sh reads the resulting markers.
readonly TRACE_DIR="${TRACE_DIR:-/tmp/teslausb-coverage}"
readonly COV_INIT=/tmp/coverage-init.sh
cat > "$COV_INIT" <<'EOF'
if [ -n "${COV_TRACE:-}" ]
then
  exec 9>> "$COV_TRACE"
  BASH_XTRACEFD=9
  PS4='+COV:${BASH_SOURCE##*/}:${LINENO}:'
  set -x
fi
EOF

trace_bash () {
  if [ -n "${COVERAGE:-}" ]
  then
    mkdir -p "$TRACE_DIR"
    local out
    out="$TRACE_DIR/$(basename "$1").$$.$RANDOM.trace"
    BASH_ENV="$COV_INIT" COV_TRACE="$out" bash "$@"
  else
    bash "$@"
  fi
}

# teslausb used to target Raspberry Pi OS. These cases cover the pieces that
# replaced the Raspberry-Pi-OS-specific machinery.

start_case "setup refuses to run on anything that is not DietPi"
# Drive the guard directly: the check is the first thing setup-teslausb does.
guard=$(sed -n '/^if \[ ! -f \/boot\/dietpi\/\.version \]/,/^fi$/p' "$REPO/setup/pi/setup-teslausb")
if [ -n "$guard" ]
then
  ok "platform guard present in setup-teslausb"
  # with the marker present (this image) the guard must fall through
  if ( eval "$guard" ) > /dev/null 2>&1
  then ok "guard passes on DietPi"
  else not_ok "guard rejected a real DietPi image"
  fi
  # and reject when the marker is missing
  out=$( ( eval "${guard//\/boot\/dietpi\/.version//nonexistent/dietpi-version}" ) 2>&1 )
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q "not DietPi" <<< "$out"
  then ok "guard stops with a clear message when DietPi is absent"
  else not_ok "guard did not reject a non-DietPi system (rc=$rc, out=$out)"
  fi
else
  not_ok "no DietPi platform guard found in setup-teslausb"
fi

start_case "no Raspberry Pi OS leftovers in the setup scripts"
# Comments may still mention these (explaining what replaced them), so strip the
# file:line: prefix and ignore commented lines.
for pattern in raspbian legacy.raspbian userconf-pi dhcpcd /etc/rc.local wpa_supplicant.conf.sample
do
  hits=$(
    grep -rn --include='*.sh' --include='setup-teslausb' -F -- "$pattern" \
      "$REPO/setup" "$REPO/run" 2> /dev/null |
      sed 's/^[^:]*:[0-9]*://' |
      grep -v '^[[:blank:]]*#' || true
  )
  if [ -n "$hits" ]
  then
    not_ok "'$pattern' is still used in the setup scripts: $(head -1 <<< "$hits")"
  else
    ok "no '$pattern' code references"
  fi
done

start_case "the UDC check can only be bypassed deliberately"
# QEMU has no USB device controller, so without a bypass setup stops before doing
# anything. It must stay fatal by default, because a real device that cannot
# present a drive is useless.
udc_fn=$(sed -n '/^function check_udc/,/^}/p' "$REPO/setup/pi/verify-configuration.sh")
assert_grep "SKIP_UDC_CHECK" "$REPO/setup/pi/verify-configuration.sh" "a named bypass exists"
if grep -q 'SKIP_UDC_CHECK:-false' <<< "$udc_fn"
then ok "it defaults to off, so real hardware still stops"
else not_ok "the bypass does not default to off"
fi
# drive the function both ways with an empty /sys/class/udc stand-in
run_udc_check () {
  (
    # called by the eval'd check_udc below
    # shellcheck disable=SC2329
    setup_progress () { echo "$*"; }
    # shellcheck disable=SC2317
    eval "${udc_fn/\/sys\/class\/udc//tmp/emptyudc}"
    check_udc
  ) 2>&1
}
mkdir -p /tmp/emptyudc
if out=$(run_udc_check) && [ -z "$out" ]
then not_ok "the check passed with no UDC and no bypass"
else ok "stops when there is no UDC: $(head -1 <<< "$out" | cut -c1-40)..."
fi
out=$(SKIP_UDC_CHECK=true run_udc_check)
if grep -q "continuing anyway" <<< "$out"
then ok "continues with SKIP_UDC_CHECK=true, and warns"
else not_ok "the bypass did not take effect: $out"
fi
if grep -q "cannot present a USB drive" <<< "$out"
then ok "and says what that means"
else not_ok "the warning does not explain the consequence"
fi

start_case "the pi-gen image pipeline is gone"
assert_no_file "$REPO/pi-gen-sources/pi-gen-config" "pi-gen config removed"
if [ -d "$REPO/pi-gen-sources" ]
then not_ok "pi-gen-sources still exists"
else ok "pi-gen-sources removed"
fi
assert_file "$REPO/dietpi/Automation_Custom_Script.sh" "DietPi bootstrap script present"
assert_file "$REPO/dietpi/dietpi.txt.sample" "dietpi.txt sample present"
assert_file "$REPO/dietpi/teslausb_setup_variables.conf.sample" "config sample moved to dietpi/"

start_case "the dietpi.txt sample sets what the bootstrap depends on"
for key in AUTO_SETUP_AUTOMATED=1 AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1 AUTO_SETUP_NET_HOSTNAME=
do
  assert_grep "$key" "$REPO/dietpi/dietpi.txt.sample" "sample sets $key"
done
# every AUTO_SETUP_/CONFIG_ key in the sample must be one DietPi actually reads,
# otherwise the instructions silently do nothing
unknown=""
while read -r key
do
  grep -q "^#\?${key}=" /boot/dietpi.txt || unknown="$unknown $key"
done < <(grep -oE '^(AUTO_SETUP|CONFIG|SURVEY)_[A-Z0-9_]+' "$REPO/dietpi/dietpi.txt.sample" | sort -u)
if [ -z "$unknown" ]
then ok "every key in the sample exists in DietPi's own dietpi.txt"
else not_ok "sample references keys DietPi does not have:$unknown"
fi

start_case "the setup service is a valid unit that runs the setup driver"
assert_file "$REPO/setup/pi/teslausb-setup.service" "unit file present"
assert_grep "ExecStart=/root/bin/first-boot.sh" "$REPO/setup/pi/teslausb-setup.service" \
  "unit runs the setup driver"
assert_grep "ConditionPathExists=!/teslausb/TESLAUSB_SETUP_FINISHED" \
  "$REPO/setup/pi/teslausb-setup.service" "unit is skipped once setup has finished"
install -m 755 "$REPO/setup/pi/first-boot.sh" /root/bin/first-boot.sh
cp "$REPO/setup/pi/teslausb-setup.service" /lib/systemd/system/
if command -v systemd-analyze > /dev/null
then
  out=$(systemd-analyze verify /lib/systemd/system/teslausb-setup.service 2>&1)
  if grep -q "teslausb-setup" <<< "$out"
  then not_ok "systemd-analyze complained: $out"
  else ok "systemd accepts the unit"
  fi
else
  ok "systemd-analyze not present, skipped"
fi

start_case "the setup driver leaves networking to DietPi"
if grep -q "wpa_supplicant.conf" "$REPO/setup/pi/first-boot.sh" &&
   grep -v '^\s*#' "$REPO/setup/pi/first-boot.sh" | grep -q "wpa_supplicant.conf"
then
  not_ok "the setup driver still writes wpa_supplicant.conf"
else
  ok "no wpa_supplicant.conf handling in the setup driver"
fi
if grep -qE '^\s*(nmcli|iwconfig|wpa_cli)' "$REPO/setup/pi/first-boot.sh"
then not_ok "the setup driver still drives the wifi adapter"
else ok "the setup driver does not touch the wifi adapter"
fi

start_case "the access point path stops instead of fighting DietPi's network stack"
out=$(
  cd "$REPO/setup/pi" &&
  AP_SSID=test AP_PASS=supersecret bash ./configure-ap.sh 2>&1
)
rc=$?
if [ "$rc" -ne 0 ] && grep -q "NetworkManager" <<< "$out"
then ok "refuses to configure an AP without NetworkManager"
else not_ok "expected a NetworkManager complaint, got rc=$rc: $out"
fi

start_case "packages DietPi lacks are bootstrapped by setup"
# The list used to live in pi-gen's 00-packages and was baked into the image.
pkg_list=$(sed -n '/^readonly TESLAUSB_PACKAGES=(/,/^)/p' "$REPO/setup/pi/setup-teslausb")
if [ -n "$pkg_list" ]
then
  ok "setup carries an explicit package list"
  for pkg in xfsprogs dosfstools exfatprogs dos2unix autofs nginx fcgiwrap python3-pip avahi-daemon libnss-mdns
  do
    if grep -qE "^\s+${pkg}\s*$" <<< "$pkg_list"
    then ok "$pkg is bootstrapped"
    else not_ok "$pkg is missing from the package list"
    fi
  done
  # and they really are absent from a bare DietPi, which is why this is needed
  absent=0
  while read -r pkg
  do
    dpkg-query -W -f='${Status}' "$pkg" 2> /dev/null | grep -q "install ok installed" || absent=$(( absent + 1 ))
  done < <(grep -oE '^\s+[a-z0-9][a-z0-9.+-]+$' <<< "$pkg_list" | tr -d ' ')
  if [ "$absent" -gt 0 ]
  then ok "$absent of them are indeed missing from a bare DietPi"
  else not_ok "expected a bare DietPi to be missing some of these packages"
  fi
else
  not_ok "no package list found in setup-teslausb"
fi

start_case "the hostname is advertised over mDNS, so teslausb.local resolves"
# setup restarts avahi-daemon after changing the hostname. Raspberry Pi OS had it
# installed by default; DietPi does not, so it has to be in the package list or
# the name silently never resolves.
assert_grep "systemctl restart avahi-daemon" "$REPO/setup/pi/setup-teslausb" \
  "setup restarts avahi after the hostname change"
if grep -qE "^\s+avahi-daemon\s*$" <<< "$pkg_list"
then ok "avahi-daemon is installed by setup"
else not_ok "avahi-daemon is restarted but never installed"
fi
if dpkg-query -W -f='${Status}' avahi-daemon 2> /dev/null | grep -q "install ok installed"
then not_ok "unexpected: avahi-daemon is already in this DietPi image"
else ok "confirmed absent from a bare DietPi, which is why it must be installed"
fi

start_case "DietPi-RAMlog is removed before the root filesystem is made read-only"
# Reproduce DietPi's ramlog setup, then run just that part of the read-only
# script and check it cleans up. dietpi-software is stubbed because it needs a
# full DietPi runtime.
cp /etc/fstab /tmp/fstab.bak
grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab || \
  echo "tmpfs /var/log tmpfs size=50M,noatime,lazytime,nodev,nosuid" >> /etc/fstab
cat > "$STUBS/dietpi-software" <<'EOF'
#!/bin/bash
echo "dietpi-software $*" >> /tmp/dietpi-software.calls
EOF
chmod +x "$STUBS/dietpi-software"
mkdir -p /tmp/fakedietpi
cp "$STUBS/dietpi-software" /tmp/fakedietpi/dietpi-software
rm -f /tmp/dietpi-software.calls
(
  set -uo pipefail
  # called by the function eval'd in below
  # shellcheck disable=SC2329
  log_progress () { echo "ro: $*"; }
  # point the function at the stub instead of the real dietpi-software
  eval "$(sed -n '/^function remove_dietpi_ramlog/,/^}/p' "$REPO/setup/pi/make-root-fs-readonly.sh" |
          sed 's|/boot/dietpi/dietpi-software|/tmp/fakedietpi/dietpi-software|g')"
  remove_dietpi_ramlog
) > /tmp/ramlog.log 2>&1
if grep -q "dietpi-software uninstall 103" /tmp/dietpi-software.calls 2> /dev/null
then ok "removed through dietpi-software so DietPi's state stays consistent"
else not_ok "did not call 'dietpi-software uninstall 103' (log: $(cat /tmp/ramlog.log))"
fi
if grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab
then not_ok "DietPi's /var/log tmpfs entry is still in /etc/fstab"
else ok "the /var/log tmpfs entry was removed from /etc/fstab"
fi
if [ -d /var/log ]
then ok "/var/log is left as a real directory"
else not_ok "/var/log is missing"
fi
cp /tmp/fstab.bak /etc/fstab

start_case "removing DietPi-RAMlog is a no-op when it is not in use"
sed -i '/[[:blank:]]\/var\/log[[:blank:]]/d' /etc/fstab
rm -f /tmp/dietpi-software.calls
(
  set -uo pipefail
  # called by the function eval'd in below
  # shellcheck disable=SC2329
  log_progress () { echo "ro: $*"; }
  eval "$(sed -n '/^function remove_dietpi_ramlog/,/^}/p' "$REPO/setup/pi/make-root-fs-readonly.sh" |
          sed 's|/boot/dietpi/dietpi-software|/tmp/fakedietpi/dietpi-software|g')"
  remove_dietpi_ramlog
) > /tmp/ramlog2.log 2>&1
if [ -e /tmp/dietpi-software.calls ]
then not_ok "called dietpi-software even though RAMlog was not in use"
else ok "did nothing"
fi
assert_grep "not in use" /tmp/ramlog2.log "said so"
cp /tmp/fstab.bak /etc/fstab

# ===========================================================================
banner "setup driver: first-boot.sh"
# ===========================================================================
# This is what replaced /etc/rc.local. It runs before teslausb exists, so
# everything it reaches for is stubbed: reboot, curl, the setup script itself,
# and dos2unix (which a bare DietPi does not have).

setup_driver_env () {
  rm -f /tmp/reboot.calls /tmp/curl.calls /tmp/setup.calls
  rm -rf /teslausb /tmp/bootpart
  mkdir -p /tmp/bootpart
  ln -sfn /tmp/bootpart /teslausb
  rm -f /root/teslausb_setup_variables.conf /root/bin/setup-teslausb

  cat > "$STUBS/reboot" <<'EOF'
#!/bin/bash
echo rebooted >> /tmp/reboot.calls
exit 0
EOF
  cat > "$STUBS/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> /tmp/curl.calls
# emulate a successful download into the -o target
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && echo "#!/bin/bash" > "$out"
[ -e /tmp/curl.should.fail ] && exit 22
exit 0
EOF
  cat > "$STUBS/dos2unix" <<'EOF'
#!/bin/bash
exit 0
EOF
  cat > "$STUBS/sntp" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$STUBS/reboot" "$STUBS/curl" "$STUBS/dos2unix" "$STUBS/sntp"
}

install_fake_setup () {
  # a setup-teslausb that reports success or failure on demand
  cat > /root/bin/setup-teslausb <<'EOF'
#!/bin/bash
echo "setup ran" >> /tmp/setup.calls
[ -e /tmp/setup.should.fail ] && exit 1
touch /teslausb/TESLAUSB_SETUP_FINISHED
exit 0
EOF
  chmod +x /root/bin/setup-teslausb
}

run_driver () {
  ( trace_bash "$REPO/setup/pi/first-boot.sh" ) > /tmp/driver.log 2>&1
  DRIVER_RC=$?
  return 0
}

start_case "creates the /teslausb symlink when it is missing"
setup_driver_env
rm -rf /teslausb
install_fake_setup
touch /boot/TESLAUSB_SETUP_FINISHED
run_driver
if [ -L /teslausb ]
then ok "/teslausb is a symlink"
else not_ok "/teslausb was not created (log: $(cat /tmp/driver.log))"
fi
assert_eq "$(readlink /teslausb)" "/boot" "points at the DietPi boot partition"
rm -f /boot/TESLAUSB_SETUP_FINISHED

start_case "does nothing once setup has finished"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
run_driver
assert_eq "$DRIVER_RC" 0 "exits 0"
assert_no_file /tmp/setup.calls "setup was not re-run"
assert_no_file /tmp/reboot.calls "did not reboot"

start_case "runs setup when the finished marker is absent"
setup_driver_env
install_fake_setup
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
run_driver
assert_file /tmp/setup.calls "setup was run"
assert_file /tmp/bootpart/TESLAUSB_SETUP_STARTED "started marker written"
assert_file /tmp/reboot.calls "rebooted afterwards"

start_case "moves a config left on the boot partition to /root"
setup_driver_env
install_fake_setup
echo "export ARCHIVE_SYSTEM=none" > /tmp/bootpart/teslausb_setup_variables.conf
run_driver
assert_file /root/teslausb_setup_variables.conf "config moved to /root"
assert_no_file /tmp/bootpart/teslausb_setup_variables.conf "removed from the boot partition"

start_case "a config with Windows line endings works without dos2unix installed"
# DietPi does not ship dos2unix, and this script runs with -e: before the fix it
# died here with the config already moved off the boot partition.
setup_driver_env
install_fake_setup
mv "$STUBS/dos2unix" /tmp/dos2unix.away
printf 'export ARCHIVE_SYSTEM=none\r\nexport TESLAUSB_HOSTNAME=teslausb\r\n' \
  > /tmp/bootpart/teslausb_setup_variables.conf
run_driver
assert_file /root/teslausb_setup_variables.conf "config still moved to /root"
if grep -q $'\r' /root/teslausb_setup_variables.conf
then not_ok "carriage returns were left in the config"
else ok "line endings stripped without dos2unix"
fi
assert_grep "stripping CRLF line endings directly" /tmp/driver.log "said what it did"
assert_file /tmp/setup.calls "setup still ran"
mv /tmp/dos2unix.away "$STUBS/dos2unix"

start_case "dos2unix is used when it is available"
setup_driver_env
install_fake_setup
cat > "$STUBS/dos2unix" <<'EOF'
#!/bin/bash
echo "dos2unix $*" >> /tmp/dos2unix.calls
sed -i 's/\r$//' "$1"
EOF
chmod +x "$STUBS/dos2unix"
rm -f /tmp/dos2unix.calls
printf 'export ARCHIVE_SYSTEM=none\r\n' > /tmp/bootpart/teslausb_setup_variables.conf
run_driver
assert_file /tmp/dos2unix.calls "used dos2unix"

start_case "waits for the network before fetching the setup script"
# On DietPi nothing necessarily waits on network-online.target, so the driver has
# to check for itself.
setup_driver_env
rm -f /root/bin/setup-teslausb
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
cat > "$STUBS/ip" <<'EOF'
#!/bin/bash
# no route the first time, then a route
if [ -e /tmp/ip.called ]; then exit 0; fi
touch /tmp/ip.called
exit 1
EOF
chmod +x "$STUBS/ip"
rm -f /tmp/ip.called
export NETWORK_WAIT_SECONDS=30
run_driver
assert_grep "waiting up to 30s for the network" /tmp/driver.log "waited"
assert_grep "network came up after" /tmp/driver.log "noticed when it came up"
assert_file /tmp/curl.calls "then fetched the setup script"

start_case "carries on if the network never appears, rather than hanging forever"
setup_driver_env
rm -f /root/bin/setup-teslausb
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
printf '#!/bin/bash\nexit 1\n' > "$STUBS/ip"
chmod +x "$STUBS/ip"
export NETWORK_WAIT_SECONDS=5
run_driver
assert_grep "still no route to the network after 5s" /tmp/driver.log "gave up and said so"
assert_file /tmp/curl.calls "still tried to fetch"
unset NETWORK_WAIT_SECONDS
rm -f "$STUBS/ip"

start_case "runs run_once and renames it"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
cat > /tmp/bootpart/run_once <<'EOF'
#!/bin/bash
touch /tmp/run_once.ran
EOF
run_driver
assert_file /tmp/run_once.ran "run_once executed"
assert_file /tmp/bootpart/ran_once "renamed to ran_once"
assert_no_file /tmp/bootpart/run_once "run_once no longer present"
rm -f /tmp/run_once.ran

start_case "a broken config file is reported instead of being sourced blindly"
setup_driver_env
install_fake_setup
printf 'this is (not valid bash\n' > /root/teslausb_setup_variables.conf
run_driver
assert_grep "Error in" /tmp/driver.log "reported the bad config"
assert_no_file /tmp/setup.calls "did not continue into setup"

start_case "downloads setup-teslausb when it is not present yet"
setup_driver_env
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
rm -f /root/bin/setup-teslausb
run_driver
assert_file /tmp/curl.calls "fetched the setup script"
assert_grep "setup/pi/setup-teslausb" /tmp/curl.calls "fetched from the right path"

start_case "a failed download is reported and does not reboot"
setup_driver_env
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
rm -f /root/bin/setup-teslausb
touch /tmp/curl.should.fail
run_driver
assert_grep "Failed to retrieve setup script" /tmp/driver.log "explained the failure"
assert_no_file /tmp/reboot.calls "did not reboot"
rm -f /tmp/curl.should.fail

start_case "a failing setup run does not reboot into a loop"
setup_driver_env
install_fake_setup
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
touch /tmp/setup.should.fail
run_driver
assert_file /tmp/setup.calls "setup was attempted"
assert_no_file /tmp/reboot.calls "did not reboot after the failure"
rm -f /tmp/setup.should.fail

start_case "says so when there is no config at all"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
run_driver
assert_grep "no config file found" /tmp/driver.log "reported the missing config"

start_case "mentions the sample when only the sample is present"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
touch /tmp/bootpart/teslausb_setup_variables.conf.sample
run_driver
assert_grep "sample file is present" /tmp/driver.log "pointed at the sample"

start_case "prefers /boot/firmware when the image splits the boot partition"
setup_driver_env
install_fake_setup
mkdir -p /boot/firmware
cp /etc/fstab /tmp/fstab.driver.bak
echo "/dev/mmcblk0p1 /boot/firmware vfat defaults 0 2" >> /etc/fstab
rm -rf /teslausb
touch /boot/firmware/TESLAUSB_SETUP_FINISHED
run_driver
assert_eq "$(readlink /teslausb)" "/boot/firmware" "symlinked to /boot/firmware"
cp /tmp/fstab.driver.bak /etc/fstab
rm -rf /boot/firmware

start_case "remounts the root filesystem read-write when teslausb is already installed"
setup_driver_env
install_fake_setup
cat > /root/bin/remountfs_rw <<'EOF'
#!/bin/bash
echo remounted >> /tmp/remount.calls
EOF
chmod +x /root/bin/remountfs_rw
rm -f /tmp/remount.calls
echo "export ARCHIVE_SYSTEM=none" > /tmp/bootpart/teslausb_setup_variables.conf
run_driver
assert_file /tmp/remount.calls "asked for a writeable root before touching it"
rm -f /root/bin/remountfs_rw

start_case "creates /root/bin when it does not exist"
setup_driver_env
mv /root/bin /root/bin.saved
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
run_driver
if [ -d /root/bin ]
then ok "/root/bin created"
else not_ok "/root/bin was not created"
fi
rm -rf /root/bin
mv /root/bin.saved /root/bin

start_case "warns when there is no config but setup has not finished"
setup_driver_env
install_fake_setup
run_driver
assert_grep "Setup appears not to have completed" /tmp/driver.log "warned about the missing config"

start_case "staged sources are used instead of downloading from GitHub"
# Without this, setup fetches the published tarball and quietly tests whatever is
# on GitHub rather than the working tree.
setup_driver_env
install_fake_setup
mkdir -p /boot/teslausb-local /tmp/srcstage/setup/pi
printf '#!/bin/bash\necho "staged setup ran" >> /tmp/setup.calls\ntouch /teslausb/TESLAUSB_SETUP_FINISHED\n' \
  > /tmp/srcstage/setup/pi/setup-teslausb
tar -cf /boot/teslausb-local/repo.tar -C /tmp/srcstage setup
rm -f /root/bin/setup-teslausb /tmp/curl.calls
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
run_driver
assert_grep "Using the sources staged in" /tmp/driver.log "used the staged tree"
assert_no_file /tmp/curl.calls "downloaded nothing"
if grep -q "staged setup ran" /tmp/setup.calls 2> /dev/null
then ok "ran the staged setup script"
else not_ok "did not run the staged setup script"
fi
rm -rf /boot/teslausb-local /tmp/srcstage

start_case "a corrupt staged archive falls back to downloading"
setup_driver_env
install_fake_setup
mkdir -p /boot/teslausb-local
echo "this is not a tar file" > /boot/teslausb-local/repo.tar
rm -f /root/bin/setup-teslausb
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
run_driver
assert_grep "could not unpack the staged sources" /tmp/driver.log "noticed and said so"
assert_file /tmp/curl.calls "fell back to fetching"
rm -rf /boot/teslausb-local

start_case "wifi credentials from the teslausb config are handed to DietPi"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
rm -f /teslausb/WIFI_ENABLED /boot/dietpi-wifi.txt
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
export TESLAUSB_HOSTNAME=teslausb
EOF
# stand in for DietPi's wifi tooling
mkdir -p /boot/dietpi/func
for f in dietpi-wifidb dietpi-set_hardware change_hostname
do
  cat > "/boot/dietpi/func/$f" <<EOF
#!/bin/bash
echo "$f \$*" >> /tmp/dietpi-wifi.calls
exit 0
EOF
  chmod +x "/boot/dietpi/func/$f"
done
rm -f /tmp/dietpi-wifi.calls
run_driver
assert_file /boot/dietpi-wifi.txt "wrote DietPi's wifi credential file"
assert_grep "aWIFI_SSID\[0\]='MyNetwork'" /boot/dietpi-wifi.txt "SSID recorded in DietPi's format"
assert_grep "aWIFI_KEY\[0\]='sekrit pass'" /boot/dietpi-wifi.txt "passphrase recorded"
assert_grep "aWIFI_KEYMGR\[0\]='WPA-PSK'" /boot/dietpi-wifi.txt "key management set"
assert_grep "dietpi-wifidb 1" /tmp/dietpi-wifi.calls "asked DietPi to apply the credentials"
assert_grep "wifimodules enable" /tmp/dietpi-wifi.calls "enabled the wifi modules"
assert_file /tmp/bootpart/WIFI_ENABLED "marked wifi as configured"
assert_file /tmp/reboot.calls "rebooted to bring wifi up"
if [ "$(stat -c %a /boot/dietpi-wifi.txt)" = "600" ]
then ok "credential file is not world readable"
else not_ok "credential file mode is $(stat -c %a /boot/dietpi-wifi.txt), expected 600"
fi

start_case "makes the root writeable before writing the wifi credentials"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
cat > /root/bin/remountfs_rw <<'EOF'
#!/bin/bash
echo remounted >> /tmp/remount.calls
EOF
chmod +x /root/bin/remountfs_rw
rm -f /tmp/remount.calls
for f in dietpi-wifidb dietpi-set_hardware change_hostname
do
  printf '#!/bin/bash\nexit 0\n' > "/boot/dietpi/func/$f"
  chmod +x "/boot/dietpi/func/$f"
done
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
EOF
run_driver
assert_file /tmp/remount.calls "remounted the root read-write first"
assert_file /boot/dietpi-wifi.txt "then wrote the credentials"
rm -f /root/bin/remountfs_rw

start_case "wifi is configured only once"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED /tmp/bootpart/WIFI_ENABLED
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
EOF
rm -f /tmp/dietpi-wifi.calls
run_driver
assert_no_file /tmp/dietpi-wifi.calls "DietPi's wifi tooling was not called again"
assert_no_file /tmp/reboot.calls "did not reboot again"

start_case "no wifi variables means DietPi's own network config is left alone"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
echo "export ARCHIVE_SYSTEM=none" > /root/teslausb_setup_variables.conf
rm -f /tmp/dietpi-wifi.calls
run_driver
assert_no_file /tmp/dietpi-wifi.calls "did not touch the network"
assert_grep "skipping wifi setup" /tmp/driver.log "said why"

start_case "falls back gracefully when DietPi's wifi tooling is missing"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
mv /boot/dietpi/func/dietpi-wifidb /tmp/wifidb.saved
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
EOF
run_driver
assert_grep "dietpi-wifidb not found" /tmp/driver.log "said what was missing"
assert_no_file /tmp/bootpart/WIFI_ENABLED "did not claim wifi was configured"
mv /tmp/wifidb.saved /boot/dietpi/func/dietpi-wifidb

start_case "reports it when DietPi cannot apply the credentials"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
cat > /boot/dietpi/func/dietpi-wifidb <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x /boot/dietpi/func/dietpi-wifidb
cat > /boot/dietpi/func/dietpi-set_hardware <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x /boot/dietpi/func/dietpi-set_hardware
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
export TESLAUSB_HOSTNAME=othername
EOF
cat > /boot/dietpi/func/change_hostname <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x /boot/dietpi/func/change_hostname
run_driver
assert_grep "could not apply the wifi credentials" /tmp/driver.log "reported the failure"
assert_grep "could not enable the wifi modules" /tmp/driver.log "reported the module failure"
assert_grep "could not change the host name" /tmp/driver.log "reported the hostname failure"
# still proceeds, so a bad wifi tool does not brick setup
assert_file /tmp/bootpart/WIFI_ENABLED "carried on regardless"

start_case "adds the DietPi wifi flag when the key is absent entirely"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
for f in dietpi-wifidb dietpi-set_hardware change_hostname
do
  printf '#!/bin/bash\nexit 0\n' > "/boot/dietpi/func/$f"
  chmod +x "/boot/dietpi/func/$f"
done
cp /boot/dietpi.txt /tmp/dietpi.txt.bak2
grep -v '^AUTO_SETUP_NET_WIFI_ENABLED=' /boot/dietpi.txt > /tmp/dietpi.trimmed
cp /tmp/dietpi.trimmed /boot/dietpi.txt
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
EOF
run_driver
assert_grep "AUTO_SETUP_NET_WIFI_ENABLED=1" /boot/dietpi.txt "appended the flag"
cp /tmp/dietpi.txt.bak2 /boot/dietpi.txt

start_case "AUTO_SETUP_NET_WIFI_ENABLED is turned on so DietPi keeps wifi up"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
rm -f /teslausb/WIFI_ENABLED
printf 'AUTO_SETUP_NET_WIFI_ENABLED=0\n' > /boot/dietpi.txt.test
cp /boot/dietpi.txt /tmp/dietpi.txt.bak
printf 'AUTO_SETUP_NET_WIFI_ENABLED=0\n' > /boot/dietpi.txt
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
EOF
run_driver
assert_grep "AUTO_SETUP_NET_WIFI_ENABLED=1" /boot/dietpi.txt "flipped the DietPi wifi flag on"
cp /tmp/dietpi.txt.bak /boot/dietpi.txt

# ===========================================================================
banner "pre-boot configuration: tools/prepare-boot-partition.sh"
# ===========================================================================
# This is what keeps teslausb plug and play: one config file on the boot
# partition, everything else generated from it before the first boot.

fake_boot_partition () {
  rm -rf /tmp/bootfs
  mkdir -p /tmp/bootfs
  # a minimal but realistic dietpi.txt
  cat > /tmp/bootfs/dietpi.txt <<'EOF'
AUTO_SETUP_AUTOMATED=0
AUTO_SETUP_GLOBAL_PASSWORD=dietpi
AUTO_SETUP_NET_WIFI_ENABLED=0
AUTO_SETUP_NET_HOSTNAME=DietPi
AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0
SURVEY_OPTED_IN=-1
EOF
}

run_prepare () {
  ( trace_bash "$REPO/tools/prepare-boot-partition.sh" "$@" ) > /tmp/prepare.log 2>&1
  PREPARE_RC=$?
  return 0
}

start_case "generates every pre-boot file from the teslausb config"
fake_boot_partition
cat > /tmp/my.conf <<'EOF'
export SSID='HomeNet'
export WIFIPASS='hunter2hunter2'
export WIFI_COUNTRY=NL
export TESLAUSB_HOSTNAME=teslausb-model3
export ARCHIVE_SYSTEM=none
EOF
run_prepare /tmp/bootfs /tmp/my.conf
assert_eq "$PREPARE_RC" 0 "exits 0"
assert_file /tmp/bootfs/teslausb_setup_variables.conf "teslausb config copied to the boot partition"
assert_file /tmp/bootfs/Automation_Custom_Script.sh "DietPi bootstrap copied"
if [ -x /tmp/bootfs/Automation_Custom_Script.sh ]
then ok "bootstrap is executable, which DietPi requires"
else not_ok "bootstrap is not executable"
fi
assert_grep "AUTO_SETUP_AUTOMATED=1" /tmp/bootfs/dietpi.txt "first boot is unattended"
assert_grep "AUTO_SETUP_CUSTOM_SCRIPT_EXEC=1" /tmp/bootfs/dietpi.txt "bootstrap will be run"
assert_grep "AUTO_SETUP_NET_HOSTNAME=teslausb-model3" /tmp/bootfs/dietpi.txt "hostname taken from the config"
assert_grep "AUTO_SETUP_NET_WIFI_ENABLED=1" /tmp/bootfs/dietpi.txt "wifi enabled for the first boot"
assert_grep "AUTO_SETUP_NET_WIFI_COUNTRY_CODE=NL" /tmp/bootfs/dietpi.txt "country code taken from the config"
assert_file /tmp/bootfs/dietpi-wifi.txt "DietPi wifi credentials written"
assert_grep "aWIFI_SSID\[0\]='HomeNet'" /tmp/bootfs/dietpi-wifi.txt "SSID written"
assert_grep "aWIFI_KEY\[0\]='hunter2hunter2'" /tmp/bootfs/dietpi-wifi.txt "passphrase written"
if [ "$(stat -c %a /tmp/bootfs/dietpi-wifi.txt)" = "600" ]
then ok "credentials are not world readable"
else not_ok "credential file mode is $(stat -c %a /tmp/bootfs/dietpi-wifi.txt)"
fi

start_case "DietPi's default of 'no SSH server' is corrected"
# The values are counter-intuitive: 0 is none/custom, -1 Dropbear, -2 OpenSSH.
# Images ship with 0, which makes DietPi REMOVE the pre-installed Dropbear during
# its first run, leaving a headless device with no way in at all.
fake_boot_partition
grep -q "AUTO_SETUP_SSH_SERVER_INDEX" /tmp/bootfs/dietpi.txt || \
  echo "AUTO_SETUP_SSH_SERVER_INDEX=0" >> /tmp/bootfs/dietpi.txt
run_prepare /tmp/bootfs /tmp/my.conf
assert_eq "$(sed -n '/^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=/{s/^[^=]*=//p;q}' /tmp/bootfs/dietpi.txt)" \
  "-2" "asked for OpenSSH instead of none"

start_case "SSH is configured even when the key is absent from dietpi.txt"
fake_boot_partition
grep -v AUTO_SETUP_SSH_SERVER_INDEX /tmp/bootfs/dietpi.txt > /tmp/dt && cp /tmp/dt /tmp/bootfs/dietpi.txt
run_prepare /tmp/bootfs /tmp/my.conf
assert_eq "$(sed -n '/^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=/{s/^[^=]*=//p;q}' /tmp/bootfs/dietpi.txt)" \
  "-2" "SSH server index added"

start_case "a real SSH server the user chose is left alone"
for chosen in -1 -2
do
  fake_boot_partition
  sed -i "s/^AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0/AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0\nAUTO_SETUP_SSH_SERVER_INDEX=$chosen/" /tmp/bootfs/dietpi.txt
  run_prepare /tmp/bootfs /tmp/my.conf
  assert_eq "$(sed -n '/^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=/{s/^[^=]*=//p;q}' /tmp/bootfs/dietpi.txt)" \
    "$chosen" "kept the user's choice of $chosen"
done

start_case "existing dietpi.txt settings are preserved"
fake_boot_partition
run_prepare /tmp/bootfs /tmp/my.conf
assert_grep "AUTO_SETUP_GLOBAL_PASSWORD=dietpi" /tmp/bootfs/dietpi.txt "unrelated keys left alone"
assert_grep "SURVEY_OPTED_IN=-1" /tmp/bootfs/dietpi.txt "and so are the rest"

start_case "DietPi's own parser reads back every value we wrote"
# The checks above only prove the text is in the file. These use the exact
# expressions DietPi's scripts use to read dietpi.txt, taken from its source, so
# a value that is present but in a form DietPi would not accept still fails.
fake_boot_partition
run_prepare /tmp/bootfs /tmp/my.conf
dietpi_read () {
  # this is the expression used throughout /boot/dietpi/dietpi-software
  sed -n "/^[[:blank:]]*$1=/{s/^[^=]*=//p;q}" /tmp/bootfs/dietpi.txt
}
assert_eq "$(dietpi_read AUTO_SETUP_CUSTOM_SCRIPT_EXEC)" "1" "DietPi reads the custom script flag as 1"
assert_eq "$(dietpi_read AUTO_SETUP_NET_HOSTNAME)" "teslausb-model3" "DietPi reads the hostname"
assert_eq "$(dietpi_read AUTO_SETUP_NET_WIFI_COUNTRY_CODE)" "NL" "DietPi reads the country code"
assert_eq "$(dietpi_read AUTO_SETUP_SSH_SERVER_INDEX)" "-2" "DietPi reads the SSH server index (OpenSSH)"

start_case "DietPi will not stop for the interactive first run setup"
# dietpi-login line 140 decides this with exactly this expression:
#   grep -q '^[[:blank:]]*AUTO_SETUP_AUTOMATED=1' /boot/dietpi.txt && export G_INTERACTIVE=0
if grep -q '^[[:blank:]]*AUTO_SETUP_AUTOMATED=1' /tmp/bootfs/dietpi.txt
then ok "DietPi's own test for unattended setup passes, so G_INTERACTIVE=0"
else not_ok "DietPi would run its interactive first run setup and wait for input"
fi
# dietpi-software uses a counting form of the same test to enable automation
assert_eq "$(grep -cm1 '^[[:blank:]]*AUTO_SETUP_AUTOMATED=1' /tmp/bootfs/dietpi.txt)" "1" \
  "dietpi-software sees automation enabled"
# and it must not be left at 0 anywhere, which would win depending on order
if [ "$(grep -c '^[[:blank:]]*AUTO_SETUP_AUTOMATED=' /tmp/bootfs/dietpi.txt)" = "1" ]
then ok "the key appears exactly once"
else not_ok "AUTO_SETUP_AUTOMATED appears more than once, so which wins is unclear"
fi

start_case "the login password can be set before first boot"
fake_boot_partition
cat > /tmp/pw.conf <<'EOF'
export OS_PASSWORD='a-better-password'
export ARCHIVE_SYSTEM=none
EOF
run_prepare /tmp/bootfs /tmp/pw.conf
assert_eq "$(sed -n '/^[[:blank:]]*AUTO_SETUP_GLOBAL_PASSWORD=/{s/^[^=]*=//p;q}' /tmp/bootfs/dietpi.txt)" \
  "a-better-password" "DietPi reads the password we set"

start_case "warns when the login password is left at DietPi's default"
fake_boot_partition
run_prepare /tmp/bootfs /tmp/my.conf
assert_grep "still DietPi's default" /tmp/prepare.log "warned about the default password"

start_case "the generated wifi file parses the way DietPi parses it"
# dietpi-wifidb moves /boot/dietpi-wifi.txt to its database and reads these
# arrays out of it, so source it the same way and check what DietPi would see.
fake_boot_partition
run_prepare /tmp/bootfs /tmp/my.conf
(
  declare -a aWIFI_SSID aWIFI_KEY aWIFI_KEYMGR
  # shellcheck disable=SC1091
  source /tmp/bootfs/dietpi-wifi.txt
  printf '%s\n%s\n%s\n' "${aWIFI_SSID[0]}" "${aWIFI_KEY[0]}" "${aWIFI_KEYMGR[0]}"
) > /tmp/wifi-parsed 2>/tmp/wifi-parse-err
if [ -s /tmp/wifi-parse-err ]
then not_ok "DietPi could not parse the file: $(cat /tmp/wifi-parse-err)"
else ok "file parses cleanly as bash, which is how DietPi reads it"
fi
assert_eq "$(sed -n 1p /tmp/wifi-parsed)" "HomeNet" "DietPi would see the SSID"
assert_eq "$(sed -n 2p /tmp/wifi-parsed)" "hunter2hunter2" "DietPi would see the passphrase"
assert_eq "$(sed -n 3p /tmp/wifi-parsed)" "WPA-PSK" "DietPi would see the key management"

start_case "a passphrase with shell metacharacters survives the round trip"
fake_boot_partition
cat > /tmp/meta.conf <<'PYEOF'
export SSID='Net$With`Chars'
export WIFIPASS='p@ss$(rm -rf /)&*|;'
export ARCHIVE_SYSTEM=none
PYEOF
run_prepare /tmp/bootfs /tmp/meta.conf
(
  declare -a aWIFI_SSID aWIFI_KEY
  # shellcheck disable=SC1091
  source /tmp/bootfs/dietpi-wifi.txt
  printf '%s\n%s\n' "${aWIFI_SSID[0]}" "${aWIFI_KEY[0]}"
) > /tmp/wifi-meta 2>/dev/null
# the single quotes are the point: these must stay literal
# shellcheck disable=SC2016
assert_eq "$(sed -n 1p /tmp/wifi-meta)" 'Net$With`Chars' "SSID preserved verbatim"
# shellcheck disable=SC2016
assert_eq "$(sed -n 2p /tmp/wifi-meta)" 'p@ss$(rm -rf /)&*|;' "passphrase preserved verbatim"

start_case "a config with no wifi warns that the device will not come online"
# The device lives in a car, so there is no ethernet to fall back on: a config
# without wifi credentials means DietPi cannot finish its own first boot.
fake_boot_partition
cat > /tmp/nowifi.conf <<'EOF'
export ARCHIVE_SYSTEM=none
EOF
run_prepare /tmp/bootfs /tmp/nowifi.conf
assert_no_file /tmp/bootfs/dietpi-wifi.txt "no wifi credential file written"
assert_grep "AUTO_SETUP_NET_WIFI_ENABLED=0" /tmp/bootfs/dietpi.txt "wifi left off"
assert_grep "will have no network on first boot" /tmp/prepare.log "warned plainly"
assert_grep "has no ethernet" /tmp/prepare.log "explained why that matters in a car"
# still exits 0, so a desk setup over a wired connection is not blocked
assert_eq "$PREPARE_RC" 0 "does not refuse outright"

start_case "refuses to write to something that is not a DietPi boot partition"
rm -rf /tmp/notboot
mkdir -p /tmp/notboot
run_prepare /tmp/notboot /tmp/my.conf
if [ "$PREPARE_RC" -ne 0 ]
then ok "exits non-zero"
else not_ok "wrote to a directory that is not a boot partition"
fi
assert_grep "does not look like a DietPi boot partition" /tmp/prepare.log "explained why"
assert_no_file /tmp/notboot/Automation_Custom_Script.sh "nothing was written"

start_case "rejects a config file with a syntax error"
fake_boot_partition
printf 'export SSID=(unclosed\n' > /tmp/bad.conf
run_prepare /tmp/bootfs /tmp/bad.conf
if [ "$PREPARE_RC" -ne 0 ]
then ok "exits non-zero"
else not_ok "accepted a broken config"
fi
assert_grep "has an error in it" /tmp/prepare.log "explained why"

start_case "reports usage when given no arguments"
run_prepare
if [ "$PREPARE_RC" -ne 0 ]
then ok "exits non-zero"
else not_ok "should have refused"
fi
assert_grep "usage" /tmp/prepare.log "printed usage"

start_case "reports a missing boot partition directory"
run_prepare /tmp/definitely-not-here /tmp/my.conf
assert_grep "not a directory" /tmp/prepare.log "explained the problem"

start_case "reports a missing config file"
fake_boot_partition
run_prepare /tmp/bootfs /tmp/definitely-not-a-config
assert_grep "does not exist" /tmp/prepare.log "explained the problem"

# ===========================================================================
banner "DietPi bootstrap: Automation_Custom_Script.sh"
# ===========================================================================
# DietPi runs this once at the end of its own first boot. It must remove
# DietPi-RAMlog, install the setup driver and its unit, and hand over.

bootstrap_env () {
  rm -f /tmp/reboot.calls /tmp/curl.calls /tmp/dietpi-software.calls /tmp/apt.calls
  rm -f /lib/systemd/system/teslausb-setup.service /root/bin/first-boot.sh
  rm -f /tmp/systemctl.calls
  cp /etc/fstab /tmp/fstab.bak
  cat > "$STUBS/apt-get" <<'EOF'
#!/bin/bash
echo "apt-get $*" >> /tmp/apt.calls
exit 0
EOF
  chmod +x "$STUBS/apt-get"
  # the bootstrap calls dietpi-software by absolute path, so shadow it there
  mkdir -p /tmp/fakedietpi
  cat > /tmp/fakedietpi/dietpi-software <<'EOF'
#!/bin/bash
echo "dietpi-software $*" >> /tmp/dietpi-software.calls
exit 0
EOF
  chmod +x /tmp/fakedietpi/dietpi-software
}

run_bootstrap () {
  # redirect the absolute dietpi-software path and the handover to the driver,
  # which is covered by its own cases above
  mkdir -p /tmp/bootstrap
  sed -e 's|/boot/dietpi/dietpi-software|/tmp/fakedietpi/dietpi-software|g' \
      -e 's|^/root/bin/first-boot.sh$|echo handover >> /tmp/handover.calls|' \
      "$REPO/dietpi/Automation_Custom_Script.sh" > /tmp/bootstrap/Automation_Custom_Script.sh
  rm -f /tmp/handover.calls
  ( trace_bash /tmp/bootstrap/Automation_Custom_Script.sh ) > /tmp/bootstrap.log 2>&1
  BOOTSTRAP_RC=$?
  return 0
}

start_case "removes DietPi-RAMlog before anything else"
bootstrap_env
grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab || \
  echo "tmpfs /var/log tmpfs size=50M,noatime,lazytime,nodev,nosuid" >> /etc/fstab
run_bootstrap
assert_grep "uninstall 103" /tmp/dietpi-software.calls "uninstalled DietPi-RAMlog"
cp /tmp/fstab.bak /etc/fstab

start_case "installs the setup driver and enables its unit"
bootstrap_env
run_bootstrap
assert_eq "$BOOTSTRAP_RC" 0 "exits 0"
assert_file /root/bin/first-boot.sh "setup driver downloaded"
if [ -x /root/bin/first-boot.sh ]
then ok "setup driver is executable"
else not_ok "setup driver is not executable"
fi
assert_file /lib/systemd/system/teslausb-setup.service "unit downloaded"
assert_grep "systemctl enable teslausb-setup.service" /tmp/systemctl.calls "unit enabled"
assert_grep "daemon-reload" /tmp/systemctl.calls "systemd reloaded"
assert_file /tmp/handover.calls "handed over to the setup driver"

start_case "uses scripts staged on the boot partition instead of downloading"
# /boot/teslausb-local is how an offline install works, and how the VM test runs
# the working tree rather than whatever is published on GitHub.
bootstrap_env
mkdir -p /boot/teslausb-local
echo "#!/bin/bash" > /boot/teslausb-local/first-boot.sh
echo "# staged unit" > /boot/teslausb-local/teslausb-setup.service
rm -f /tmp/curl.calls
run_bootstrap
assert_grep "using /boot/teslausb-local/first-boot.sh" /tmp/bootstrap.log "used the staged driver"
assert_grep "staged unit" /lib/systemd/system/teslausb-setup.service "used the staged unit"
assert_no_file /tmp/curl.calls "downloaded nothing"
rm -rf /boot/teslausb-local

start_case "installs dos2unix when DietPi does not have it"
bootstrap_env
# hide the stub so the check sees a system without dos2unix
mv "$STUBS/dos2unix" /tmp/dos2unix.hidden 2> /dev/null || true
run_bootstrap
if grep -q "install.*dos2unix" /tmp/apt.calls 2> /dev/null
then ok "installed dos2unix"
else not_ok "did not install dos2unix (apt calls: $(cat /tmp/apt.calls 2>/dev/null))"
fi
mv /tmp/dos2unix.hidden "$STUBS/dos2unix" 2> /dev/null || true

start_case "a failed download stops the bootstrap"
bootstrap_env
touch /tmp/curl.should.fail
run_bootstrap
if [ "$BOOTSTRAP_RC" -ne 0 ]
then ok "exits non-zero"
else not_ok "reported success despite a failed download"
fi
assert_grep "FATAL" /tmp/bootstrap.log "said what went wrong"
assert_no_file /tmp/handover.calls "did not hand over"
rm -f /tmp/curl.should.fail

start_case "defers RAMlog removal when dietpi-software is the one running us"
# DietPi refuses to run a second instance of itself, and this script is normally
# run BY dietpi-software during first run setup, so calling it again cannot work.
bootstrap_env
grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab || \
  echo "tmpfs /var/log tmpfs size=50M,noatime,lazytime,nodev,nosuid" >> /etc/fstab
# Stand in for dietpi-software already running. run_bootstrap rewrites the
# absolute path to the stub, including the path the script looks for, so the fake
# process has to carry that same name.
bash -c 'exec -a /tmp/fakedietpi/dietpi-software sleep 60' &
nested_pid=$!
sleep 0.3
rm -f /tmp/dietpi-software.calls
run_bootstrap
assert_grep "teslausb setup will remove it later" /tmp/bootstrap.log "deferred instead of failing"
assert_no_file /tmp/dietpi-software.calls "did not try to call dietpi-software"
kill "$nested_pid" 2> /dev/null
wait "$nested_pid" 2> /dev/null
cp /tmp/fstab.bak /etc/fstab

start_case "carries on when DietPi-RAMlog cannot be uninstalled"
bootstrap_env
grep -q '[[:blank:]]/var/log[[:blank:]]' /etc/fstab || \
  echo "tmpfs /var/log tmpfs size=50M,noatime,lazytime,nodev,nosuid" >> /etc/fstab
printf '#!/bin/bash\nexit 1\n' > /tmp/fakedietpi/dietpi-software
chmod +x /tmp/fakedietpi/dietpi-software
run_bootstrap
assert_grep "could not uninstall DietPi-RAMlog" /tmp/bootstrap.log "warned about it"
assert_file /root/bin/first-boot.sh "still installed the setup driver"
cp /tmp/fstab.bak /etc/fstab

start_case "carries on when dos2unix cannot be installed"
bootstrap_env
mv "$STUBS/dos2unix" /tmp/dos2unix.hidden2 2> /dev/null || true
printf '#!/bin/bash\necho "apt-get $*" >> /tmp/apt.calls\nexit 1\n' > "$STUBS/apt-get"
chmod +x "$STUBS/apt-get"
run_bootstrap
assert_grep "could not install dos2unix" /tmp/bootstrap.log "warned about it"
mv /tmp/dos2unix.hidden2 "$STUBS/dos2unix" 2> /dev/null || true

start_case "logs to the boot partition where a headless user can read it"
bootstrap_env
run_bootstrap
assert_file /boot/teslausb-headless-setup.log "wrote the headless setup log"

# ===========================================================================
banner "sentry-keeper"
# ===========================================================================
# Holds Sentry Mode on for the archive window, because Sentry is what keeps the
# car awake and the car is what powers the Pi.

start_case "the awake scripts start and stop the keeper"
assert_grep "sentry-keeper.sh &" "$REPO/run/awake_start" "awake_start starts it in the background"
assert_grep "sentry_keeper_pid" "$REPO/run/awake_start" "and records its pid"
assert_grep "kill \"\$(cat /tmp/sentry_keeper_pid)\"" "$REPO/run/awake_stop" "awake_stop stops it"
# it must be stopped before Sentry is disabled, or it can re-arm afterwards
stop_line=$(grep -n "sentry_keeper_pid" "$REPO/run/awake_stop" | head -1 | cut -d: -f1)
# the first actual "turn Sentry off" call, whichever backend it belongs to
disable_line=$(grep -n "set_sentry_mode&sentryMode=false\|command/disable_sentry\|sentry-mode off" \
  "$REPO/run/awake_stop" | head -1 | cut -d: -f1)
if [ -n "$stop_line" ] && [ -n "$disable_line" ] && [ "$stop_line" -lt "$disable_line" ]
then ok "the keeper is stopped before Sentry is disabled"
else not_ok "the keeper is stopped after the disable, so it can race and re-arm"
fi

start_case "the keeper only ever enables Sentry, and only when it is safe"
if grep -v "^[[:blank:]]*#" "$REPO/run/sentry-keeper.sh" | grep -q "disable_sentry"
then not_ok "the keeper can disable Sentry, which is not its job"
else ok "it never disables Sentry (only mentioned in comments)"
fi
assert_grep 'online" == "online"' "$REPO/run/sentry-keeper.sh" "requires the car to be online"
assert_grep 'shift_state" == "P"' "$REPO/run/sentry-keeper.sh" "requires the car to be parked"
assert_grep "MAX_RUNTIME" "$REPO/run/sentry-keeper.sh" "has a runtime cap"

start_case "the keeper exits if it is orphaned"
cat > /tmp/keeper.conf <<'EOF'
export TESSIE_API_TOKEN=token
export TESSIE_VIN=VIN
EOF
rm -f /tmp/keeper.log /tmp/keeper.pid
env SENTRY_KEEPER_INTERVAL=1 SENTRY_KEEPER_PIDFILE=/tmp/keeper.pid \
    SENTRY_KEEPER_LOG=/tmp/keeper.log SETUP_CONF=/tmp/keeper.conf \
    bash "$REPO/run/sentry-keeper.sh" &
keeper_pid=$!
echo "$keeper_pid" > /tmp/keeper.pid
sleep 3
rm -f /tmp/keeper.pid            # simulate awake_stop having cleaned up
sleep 3
if kill -0 "$keeper_pid" 2> /dev/null
then
  not_ok "the keeper kept running after its pid file went away"
  kill "$keeper_pid" 2> /dev/null
else
  ok "the keeper noticed and exited"
fi
assert_grep "pid file gone" /tmp/keeper.log "said why it exited"

start_case "the keeper refuses to run without credentials"
rm -f /tmp/keeper2.log
env SENTRY_KEEPER_LOG=/tmp/keeper2.log SETUP_CONF=/nonexistent \
    TESSIE_API_TOKEN= TESSIE_VIN= bash "$REPO/run/sentry-keeper.sh"
assert_eq "$?" 1 "exits non-zero"
assert_grep "TESSIE_API_TOKEN" /tmp/keeper2.log "said what was missing"

start_case "setup installs the keeper only when Tessie is configured"
keeper_installer=$(sed -n '/^function install_sentry_keeper/,/^}/p' "$REPO/setup/pi/configure.sh")
if [ -n "$keeper_installer" ]
then ok "configure.sh has an installer for it"
else not_ok "nothing installs sentry-keeper"
fi
assert_grep "install_sentry_keeper /root/bin" "$REPO/setup/pi/configure.sh" "and calls it"
if grep -qE "^\s+jq\s*$" <<< "$pkg_list"
then ok "jq is bootstrapped, which both the watchdog and the keeper need"
else not_ok "jq is used to parse Tessie's JSON but never installed"
fi

# ===========================================================================
banner "installer: install_usb_link_watchdog"
# ===========================================================================
# configure.sh is a large script that expects a full teslausb setup, so extract
# just the function under test and drive it with stubs for the helpers it calls
# (copy_script, log_progress) and for systemctl.

run_installer () {
  rm -f /tmp/systemctl.calls
  (
    set -uo pipefail
    # these two are called by the installer function eval'd in below
    # shellcheck disable=SC2329
    log_progress () { echo "log: $*"; }
    # shellcheck disable=SC2329
    copy_script () {
      # mimic setup-teslausb's copy_script: copy, then make executable
      cp "$REPO/$1" "$2/${1##*/}"
      chmod +x "$2/${1##*/}"
    }
    eval "$(sed -n '/^function install_usb_link_watchdog/,/^}/p' "$REPO/setup/pi/configure.sh")"
    install_usb_link_watchdog /root/bin
  )
}

start_case "installs the script, both units, and enables the timer"
rm -f /lib/systemd/system/usb-link-watchdog.* /root/bin/usb-link-watchdog.sh
if ! run_installer > /tmp/installer.log 2>&1
then not_ok "installer exited non-zero: $(cat /tmp/installer.log)"
else ok "installer exited 0"
fi
assert_file /root/bin/usb-link-watchdog.sh "watchdog script installed into /root/bin"
if [ -x /root/bin/usb-link-watchdog.sh ]
then ok "installed script is executable"
else not_ok "installed script is not executable"
fi
assert_file /lib/systemd/system/usb-link-watchdog.service "service unit written"
assert_file /lib/systemd/system/usb-link-watchdog.timer "timer unit written"
assert_grep "ExecStart=/root/bin/usb-link-watchdog.sh" /lib/systemd/system/usb-link-watchdog.service \
  "service ExecStart points at the installed path"
assert_grep "OnUnitActiveSec=5min" /lib/systemd/system/usb-link-watchdog.timer "timer runs every 5 minutes"
assert_grep "WantedBy=timers.target" /lib/systemd/system/usb-link-watchdog.timer "timer is installable"
assert_grep "systemctl enable usb-link-watchdog.timer" /tmp/systemctl.calls "timer enabled"

start_case "systemd accepts the generated units"
if command -v systemd-analyze > /dev/null
then
  out=$(systemd-analyze verify /lib/systemd/system/usb-link-watchdog.timer 2>&1)
  if grep -q "usb-link-watchdog" <<< "$out"
  then not_ok "systemd-analyze complained about our unit: $out"
  else ok "no complaints about usb-link-watchdog units"
  fi
else
  ok "systemd-analyze not present, skipped"
fi

start_case "removes stale hand-installed units from /etc/systemd/system"
# The watchdog was first deployed by hand into /etc/systemd/system; those copies
# would shadow the packaged ones, so the installer has to clear them.
touch /etc/systemd/system/usb-link-watchdog.service /etc/systemd/system/usb-link-watchdog.timer
run_installer > /dev/null 2>&1
assert_no_file /etc/systemd/system/usb-link-watchdog.service "stale service removed"
assert_no_file /etc/systemd/system/usb-link-watchdog.timer "stale timer removed"

start_case "USB_LINK_WATCHDOG=false skips installation"
rm -f /lib/systemd/system/usb-link-watchdog.* /root/bin/usb-link-watchdog.sh
USB_LINK_WATCHDOG=false run_installer > /tmp/installer-off.log 2>&1
assert_no_file /lib/systemd/system/usb-link-watchdog.service "no service unit written"
assert_no_file /lib/systemd/system/usb-link-watchdog.timer "no timer unit written"
if grep -q "systemctl enable" /tmp/systemctl.calls 2> /dev/null
then not_ok "timer was enabled despite being turned off"
else ok "timer not enabled"
fi
if grep -q "systemctl disable" /tmp/systemctl.calls 2> /dev/null
then ok "a previously installed timer is disabled on the way out"
else not_ok "did not disable a previously installed timer"
fi

# reinstate for the cases below
run_installer > /dev/null 2>&1

# ===========================================================================
banner "watchdog against a real teslausb layout"
# ===========================================================================
# Real paths this time: /backingfiles and /mutable actually exist in here, and
# findmnt/pgrep are the real binaries from the DietPi image.
mkdir -p /backingfiles /mutable /mnt/cam /mnt/archive /run/udc/20980000.usb
echo configured > /run/udc/20980000.usb/state
cat > "$STUBS/reboot" <<'EOF'
#!/bin/bash
echo rebooted >> /tmp/reboot.calls
EOF
chmod +x "$STUBS/reboot"

# The watchdog asks Tessie whether the car is recording. Note that the setup
# driver fixture earlier installs its own curl stub for download emulation, so
# this has to be (re)created here rather than with the other stubs.
install_tessie_stub () {
  cat > "$STUBS/curl" <<'EOF'
#!/bin/bash
if [ -e /tmp/tessie_down ]
then
  exit 7
fi
state=$(cat /tmp/dashcam_state 2>/dev/null || echo Recording)
ts=$(( ( $(date +%s) - 30 ) * 1000 ))
printf '{"state":"online","vehicle_state":{"dashcam_state":"%s","timestamp":%s}}' "$state" "$ts"
EOF
  chmod +x "$STUBS/curl"
}
install_tessie_stub

# Runs the watchdog with per-case environment overrides, always through the
# coverage tracing so these paths are counted.
watchdog_env () {
  rm -f /tmp/reboot.calls
  local -a extra=( "$@" )
  local -a base=(
    UDC_DIR=/run/udc
    REBOOT_CMD="$STUBS/reboot"
    RSYNC_LOG=/tmp/rsync.log
    SETUP_CONF=/tmp/none
    BOUNDARY_WAIT_SECS=5
    TESSIE_API_TOKEN=token
    TESSIE_VIN=VIN
  )
  if [ -n "${COVERAGE:-}" ]
  then
    mkdir -p "$TRACE_DIR"
    env "${base[@]}" "${extra[@]}" \
        BASH_ENV="$COV_INIT" COV_TRACE="$TRACE_DIR/usb-link-watchdog.sh.$$.$RANDOM.trace" \
        bash /root/bin/usb-link-watchdog.sh
  else
    env "${base[@]}" "${extra[@]}" bash /root/bin/usb-link-watchdog.sh
  fi
  WD_RC=$?
  return 0
}

watchdog () {
  rm -f /tmp/reboot.calls
  if [ -n "${COVERAGE:-}" ]
  then
    mkdir -p "$TRACE_DIR"
    env UDC_DIR=/run/udc REBOOT_CMD="$STUBS/reboot" \
        RSYNC_LOG=/tmp/rsync.log SETUP_CONF=/tmp/setup.conf \
        BOUNDARY_WAIT_SECS=5 TESSIE_API_TOKEN=token TESSIE_VIN=VIN \
        BASH_ENV="$COV_INIT" COV_TRACE="$TRACE_DIR/usb-link-watchdog.sh.$$.trace" \
        bash /root/bin/usb-link-watchdog.sh
  else
    env UDC_DIR=/run/udc REBOOT_CMD="$STUBS/reboot" \
        RSYNC_LOG=/tmp/rsync.log SETUP_CONF=/tmp/setup.conf \
        BOUNDARY_WAIT_SECS=5 TESSIE_API_TOKEN=token TESSIE_VIN=VIN \
        bash /root/bin/usb-link-watchdog.sh
  fi
  WD_RC=$?
  return 0
}

set_cam_idle () { touch -d "@$(( $(date +%s) - $1 * 60 ))" /backingfiles/cam_disk.bin; }

echo camdata > /backingfiles/cam_disk.bin
rm -f /mutable/usb-link-watchdog.log /mutable/usb-link-watchdog.last-reboot

start_case "healthy device with fresh writes is left alone"
set_cam_idle 1
watchdog
assert_no_file /tmp/reboot.calls "no reboot"
assert_eq "$WD_RC" 0 "exit status 0"

start_case "stalled device reboots and logs to the real /mutable log"
set_cam_idle 45
echo Unavailable > /tmp/dashcam_state
watchdog
assert_file /tmp/reboot.calls "rebooted"
assert_file /mutable/usb-link-watchdog.log "log written to /mutable"
assert_grep "ACTION" /mutable/usb-link-watchdog.log "logged the action"
assert_file /mutable/usb-link-watchdog.last-reboot "cooldown state written"

start_case "second stall inside the cooldown does not reboot again"
set_cam_idle 45
echo Unavailable > /tmp/dashcam_state
watchdog
assert_no_file /tmp/reboot.calls "no second reboot"
assert_grep "cooldown" /mutable/usb-link-watchdog.log "logged the cooldown"

start_case "a real running rsync no longer blocks a reboot when the car is gone"
# An earlier version skipped whenever rsync was alive. Since the upload runs for
# hours, that made the watchdog a permanent no-op, so a stall now reboots even
# mid-transfer once the car is confirmed to have lost the drive.
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
echo Unavailable > /tmp/dashcam_state
: > /tmp/rsync.log
cp /bin/sleep /usr/local/bin/rsync
/usr/local/bin/rsync 60 &
rsync_pid=$!
sleep 0.3
if pgrep -x rsync > /dev/null
then ok "pgrep -x rsync matches the running process"
else not_ok "test setup failed: pgrep does not see the fake rsync"
fi
watchdog
assert_file /tmp/reboot.calls "rebooted despite the transfer, after waiting for a boundary"
assert_grep "no boundary within" /mutable/usb-link-watchdog.log "waited for a file boundary first"
kill "$rsync_pid" 2> /dev/null
wait "$rsync_pid" 2> /dev/null
rm -f /usr/local/bin/rsync /tmp/dashcam_state

start_case "the Tessie stub the watchdog cases rely on works"
echo Recording > /tmp/dashcam_state
stub_out=$(curl -s -m 5 -H 'a: b' https://api.tessie.com/x/state 2>&1)
if jq -re '.vehicle_state.dashcam_state' <<< "$stub_out" 2>/dev/null | grep -q Recording
then ok "it answers with parseable JSON"
else not_ok "the stub answered '$(head -c 60 <<< "$stub_out")'"
fi

start_case "a recording car vetoes the reboot, with the real Tessie code path"
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
echo Recording > /tmp/dashcam_state
watchdog
assert_no_file /tmp/reboot.calls "no reboot while the car is recording"
rm -f /tmp/dashcam_state

start_case "credentials are read from the setup conf when not in the environment"
# archiveloop normally exports them, but the timer runs the watchdog directly.
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
echo Recording > /tmp/dashcam_state
cat > /tmp/setup.conf <<'EOF'
export TESSIE_API_TOKEN=from-conf
export TESSIE_VIN=VINFROMCONF
EOF
watchdog_env SETUP_CONF=/tmp/setup.conf TESSIE_API_TOKEN= TESSIE_VIN=
assert_no_file /tmp/reboot.calls "found the credentials and honoured the Recording veto"
rm -f /tmp/setup.conf

start_case "a stale Recording reading is not trusted, and reboots"
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
# a Tessie answer whose reading is far too old to rely on
cat > "$STUBS/curl" <<'EOF'
#!/bin/bash
ts=$(( ( $(date +%s) - 4000 ) * 1000 ))
printf '{"state":"online","vehicle_state":{"dashcam_state":"Recording","timestamp":%s}}' "$ts"
EOF
chmod +x "$STUBS/curl"
watchdog
assert_file /tmp/reboot.calls "rebooted"
assert_grep "too stale to trust" /mutable/usb-link-watchdog.log "said the reading was stale"
install_tessie_stub

start_case "no answer from Tessie leaves an archive in progress alone"
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
touch /tmp/tessie_down
cp /bin/sleep /usr/local/bin/rsync
/usr/local/bin/rsync 30 &
rsync_pid=$!
sleep 0.3
watchdog
assert_no_file /tmp/reboot.calls "no reboot while unverified and archiving"
assert_grep "dashcam unverified" /mutable/usb-link-watchdog.log "said why"
kill "$rsync_pid" 2> /dev/null
wait "$rsync_pid" 2> /dev/null
rm -f /usr/local/bin/rsync /tmp/tessie_down

start_case "DRY_RUN decides everything and changes nothing"
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
echo Unavailable > /tmp/dashcam_state
cp /bin/sleep /usr/local/bin/rsync
/usr/local/bin/rsync 30 &
rsync_pid=$!
sleep 0.3
watchdog_env DRY_RUN=1
assert_no_file /tmp/reboot.calls "did not reboot"
assert_grep "DRY_RUN: would reboot now" /mutable/usb-link-watchdog.log "said what it would have done"
assert_grep "DRY_RUN: rsync active" /mutable/usb-link-watchdog.log "and that it would have waited for a boundary"
assert_no_file /mutable/usb-link-watchdog.last-reboot "left the cooldown marker alone"
kill "$rsync_pid" 2> /dev/null
wait "$rsync_pid" 2> /dev/null
rm -f /usr/local/bin/rsync /tmp/dashcam_state

start_case "waits for a file boundary and proceeds once one appears"
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
echo Unavailable > /tmp/dashcam_state
: > /tmp/rsync.log
cp /bin/sleep /usr/local/bin/rsync
/usr/local/bin/rsync 60 &
rsync_pid=$!
( sleep 6; echo "one clip done" >> /tmp/rsync.log ) &
boundary_writer=$!
sleep 0.3
watchdog_env BOUNDARY_WAIT_SECS=40
assert_grep "at file boundary" /mutable/usb-link-watchdog.log "waited for the file to finish"
wait "$boundary_writer" 2> /dev/null
kill "$rsync_pid" 2> /dev/null
wait "$rsync_pid" 2> /dev/null
rm -f /usr/local/bin/rsync /tmp/dashcam_state

start_case "real findmnt sees /mnt/cam mounted, so teslausb owns the image"
set_cam_idle 45
if mount -t tmpfs -o size=1m none /mnt/cam 2> /dev/null
then
  if findmnt -rn /mnt/cam > /dev/null
  then ok "findmnt sees the mount"
  else not_ok "test setup failed: findmnt does not see /mnt/cam"
  fi
  watchdog
  assert_no_file /tmp/reboot.calls "no reboot while /mnt/cam is mounted"
  umount /mnt/cam
else
  printf '   note: cannot mount inside this container, case skipped\n'
fi

start_case "gadget not configured is not treated as a fault"
echo not_attached > /run/udc/20980000.usb/state
set_cam_idle 45
rm -f /mutable/usb-link-watchdog.last-reboot
watchdog
assert_no_file /tmp/reboot.calls "no reboot"
echo configured > /run/udc/20980000.usb/state

start_case "the uptime gate holds off during early boot"
set_cam_idle 45
rm -f /mutable/usb-link-watchdog.last-reboot
printf '120.00 120.00\n' > /tmp/fake-uptime
watchdog_env UPTIME_FILE=/tmp/fake-uptime
assert_eq "$WD_RC" 0 "exits 0"
assert_no_file /tmp/reboot.calls "no reboot two minutes after boot"

start_case "a missing cam disk is reported, not rebooted through"
rm -f /backingfiles/cam_disk.bin
watchdog
assert_no_file /tmp/reboot.calls "no reboot"
assert_eq "$WD_RC" 1 "exit status 1"
assert_grep "ERROR" /mutable/usb-link-watchdog.log "logged the error"
echo camdata > /backingfiles/cam_disk.bin

# ===========================================================================
banner "configure-web.sh clears the webroot safely"
# ===========================================================================
# A fresh DietPi has an empty /var/www/html, because nginx-common there ships no
# default index page. The clearing step used to pipe find into "xargs -0 rm",
# which exits 123 with "rm: missing operand" when there is nothing to remove, and
# that killed setup outright. Run the real line from the script against an empty
# directory and against a populated one.
start_case "the clearing step survives an empty webroot"
clear_cmd=$(grep -E "^find /var/www/html .* -delete$" "$REPO/setup/pi/configure-web.sh")
assert_eq "$(printf '%s' "$clear_cmd" | grep -c .)" 1 \
  "the script still clears the webroot with find -delete"
assert_eq "$(grep -cE "xargs -0 rm$" "$REPO/setup/pi/configure-web.sh")" 0 \
  "and no longer pipes into a bare xargs rm"

mkdir -p /tmp/emptyroot
( eval "${clear_cmd/\/var\/www\/html//tmp/emptyroot}" ) && rc=0 || rc=$?
assert_eq "$rc" 0 "exits 0 on an empty directory"

start_case "and still removes files and symlinks when there are some"
mkdir -p /tmp/fullroot/sub
touch /tmp/fullroot/index.html /tmp/fullroot/sub/nested.html
ln -sf /tmp/fullroot/index.html /tmp/fullroot/link.html
( eval "${clear_cmd/\/var\/www\/html//tmp/fullroot}" ) && rc=0 || rc=$?
assert_eq "$rc" 0 "exits 0"
assert_no_file /tmp/fullroot/index.html "removed the file"
assert_no_file /tmp/fullroot/link.html "removed the symlink"
assert_no_file /tmp/fullroot/sub/nested.html "removed nested files"
assert_eq "$([ -d /tmp/fullroot/sub ] && echo yes)" yes "kept directories"
rm -rf /tmp/emptyroot /tmp/fullroot

# ===========================================================================
if [ -n "${COVERAGE:-}" ]
then
  banner "coverage"
  export TRACE_DIR
  bash "$REPO/tests/coverage.sh" ${COVERAGE_MIN:+--min "$COVERAGE_MIN"} || fail_count=$(( fail_count + 1 ))
fi

printf '\n=== summary ===\n'
printf 'integration: %d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
