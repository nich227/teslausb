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

start_case "the access point does not need DietPi's network stack replaced"
# It used to require NetworkManager and refuse without it. It now runs hostapd on
# a second virtual interface, so DietPi keeps managing the client connection.
assert_eq "$(grep -c nmcli "$REPO/setup/pi/configure-ap.sh" || true)" 0 "nothing calls nmcli"
assert_grep "hostapd" "$REPO/setup/pi/configure-ap.sh" "hostapd runs the access point"

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
  eval "$(sed -n '/^function dietpi_software/,/^}/p;/^function remove_dietpi_ramlog/,/^}/p' "$REPO/setup/pi/make-root-fs-readonly.sh" |
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
  eval "$(sed -n '/^function dietpi_software/,/^}/p;/^function remove_dietpi_ramlog/,/^}/p' "$REPO/setup/pi/make-root-fs-readonly.sh" |
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

start_case "clears a soft-blocked radio through sysfs when rfkill is absent"
# DietPi does not ship rfkill and this runs before there is any network, so there
# is no way to install it. The unblock has to work through the kernel's own
# interfaces. Both directories are taken from the environment so this can point
# them at a fixture.
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
rm -f /teslausb/WIFI_ENABLED /boot/dietpi-wifi.txt
rm -rf /tmp/rfkill-sys /tmp/rfkill-saved
mkdir -p /tmp/rfkill-sys/rfkill0 /tmp/rfkill-sys/rfkill1 /tmp/rfkill-saved
echo wlan > /tmp/rfkill-sys/rfkill0/type
echo 1 > /tmp/rfkill-sys/rfkill0/soft
echo bluetooth > /tmp/rfkill-sys/rfkill1/type
echo 1 > /tmp/rfkill-sys/rfkill1/soft
echo 1 > /tmp/rfkill-saved/0:phy0:wlan
echo 1 > /tmp/rfkill-saved/1:hci0:bluetooth
export RFKILL_SYSFS_DIR=/tmp/rfkill-sys RFKILL_SAVED_DIR=/tmp/rfkill-saved
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
assert_eq "$(cat /tmp/rfkill-sys/rfkill0/soft)" "0" "cleared the wlan soft block"
assert_eq "$(cat /tmp/rfkill-sys/rfkill1/soft)" "1" "left the bluetooth radio alone"
assert_eq "$(cat /tmp/rfkill-saved/0:phy0:wlan)" "0" \
  "cleared systemd's saved wlan state, which is restored on the next boot"
assert_eq "$(cat /tmp/rfkill-saved/1:hci0:bluetooth)" "1" \
  "left systemd's saved bluetooth state alone"

start_case "uses the rfkill command when it is installed"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
rm -f /teslausb/WIFI_ENABLED /boot/dietpi-wifi.txt /tmp/rfkill.calls
cat > "$STUBS/rfkill" <<'EOF'
#!/bin/bash
echo "rfkill $*" >> /tmp/rfkill.calls
exit 0
EOF
chmod +x "$STUBS/rfkill"
rm -rf /tmp/rfkill-sys /tmp/rfkill-saved
mkdir -p /tmp/rfkill-sys /tmp/rfkill-saved
echo 1 > /tmp/rfkill-saved/0:phy0:wlan
export RFKILL_SYSFS_DIR=/tmp/rfkill-sys RFKILL_SAVED_DIR=/tmp/rfkill-saved
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
EOF
run_driver
assert_grep "rfkill unblock wifi" /tmp/rfkill.calls "asked rfkill to unblock wifi"
assert_eq "$(cat /tmp/rfkill-saved/0:phy0:wlan)" "0" \
  "and still wrote the saved state, which rfkill does not touch"
rm -f "$STUBS/rfkill"

start_case "an empty saved-state directory does not create a file named after the glob"
setup_driver_env
install_fake_setup
touch /tmp/bootpart/TESLAUSB_SETUP_FINISHED
rm -f /teslausb/WIFI_ENABLED /boot/dietpi-wifi.txt
rm -rf /tmp/rfkill-sys /tmp/rfkill-saved
mkdir -p /tmp/rfkill-sys /tmp/rfkill-saved
export RFKILL_SYSFS_DIR=/tmp/rfkill-sys RFKILL_SAVED_DIR=/tmp/rfkill-saved
cat > /root/teslausb_setup_variables.conf <<'EOF'
export SSID='MyNetwork'
export WIFIPASS='sekrit pass'
EOF
run_driver
assert_no_file '/tmp/rfkill-saved/*:wlan' "no file created from the unmatched glob"
assert_eq "$(find /tmp/rfkill-saved -mindepth 1 | wc -l)" "0" "saved-state directory is still empty"
unset RFKILL_SYSFS_DIR RFKILL_SAVED_DIR
rm -rf /tmp/rfkill-sys /tmp/rfkill-saved

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
  # DietPi's own scripts live here on images where /boot is the real thing, and the
  # script uses their presence to tell that from a firmware partition.
  mkdir -p /tmp/bootfs/dietpi
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

start_case "OpenSSH is asked for whatever the image or the user said"
# teslausb standardises on OpenSSH. Dropbear (-1) is not a working choice here,
# because the rsync archive backend shells out to ssh and dropbear ships dbclient
# instead, so a dropbear request is overridden rather than honoured.
for chosen in -1 -2
do
  fake_boot_partition
  sed -i "s/^AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0/AUTO_SETUP_CUSTOM_SCRIPT_EXEC=0\nAUTO_SETUP_SSH_SERVER_INDEX=$chosen/" /tmp/bootfs/dietpi.txt
  run_prepare /tmp/bootfs /tmp/my.conf
  assert_eq "$(sed -n '/^[[:blank:]]*AUTO_SETUP_SSH_SERVER_INDEX=/{s/^[^=]*=//p;q}' /tmp/bootfs/dietpi.txt)" \
    "-2" "asked for OpenSSH when the image said $chosen"
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
banner "EncryptedClips: the second tree recent Tesla software writes"

# Recent Tesla software records into TeslaCam/EncryptedClips/{Recent,Saved,Sentry}Clips as
# well as the classic three folders. Until the archive code knew about it, everything the car
# put there was never archived and never cleaned up, and with --remove-source-files never
# touching the folder it would quietly fill the cam disk. No car here writes it yet, so this
# builds the tree Tesla documents and pushes it through the same code paths a real one takes:
# the snapshot linking in make_snapshot.sh, then the find that archiveloop builds its archive
# list from, taken verbatim from archiveloop so the two cannot drift apart.

enc_env () {
  rm -rf /tmp/enc
  mkdir -p /tmp/enc/snap/TeslaCam /tmp/enc/mutable/TeslaCam
  # the shape of a cam disk: classic and encrypted, each with an event holding two clips
  local base
  for base in "" "EncryptedClips/"
  do
    mkdir -p "/tmp/enc/snap/TeslaCam/${base}RecentClips" \
             "/tmp/enc/snap/TeslaCam/${base}SavedClips/2026-09-18_10-00-00" \
             "/tmp/enc/snap/TeslaCam/${base}SentryClips/2026-09-18_11-00-00"
    echo clip > "/tmp/enc/snap/TeslaCam/${base}RecentClips/2026-09-18_09-59-00-front.mp4"
    echo clip > "/tmp/enc/snap/TeslaCam/${base}SavedClips/2026-09-18_10-00-00/2026-09-18_09-59-00-front.mp4"
    echo '{}' > "/tmp/enc/snap/TeslaCam/${base}SavedClips/2026-09-18_10-00-00/event.json"
    echo clip > "/tmp/enc/snap/TeslaCam/${base}SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4"
    echo '{}' > "/tmp/enc/snap/TeslaCam/${base}SentryClips/2026-09-18_11-00-00/event.json"
  done
}

# make_snapshot.sh's two linking functions, lifted out because the script refuses to be
# sourced and takes a lock on the real snapshots directory when run. /mutable is redirected
# into the fixture.
run_snapshot_links () {
  {
    echo 'log () { :; }'
    sed -n '/^function linksnapshotfiletorecents {$/,/^}$/p' "$REPO/run/make_snapshot.sh"
    sed -n '/^function make_links_for_snapshot {$/,/^}$/p' "$REPO/run/make_snapshot.sh"
  } | sed 's|/mutable/TeslaCam|/tmp/enc/mutable/TeslaCam|g' > /tmp/enc/links.sh
  # shellcheck disable=SC1091
  ( source /tmp/enc/links.sh && make_links_for_snapshot /tmp/enc/snap /tmp/enc/final ) \
    > /tmp/enc/snapshot.log 2>&1
  return 0
}

# archiveloop's archive-list find, lifted from archive_teslacam_clips with its variables
run_archive_find () {
  local -a savedclipsopt sentryclipsopt trackmodeclipsopt recentclipsopt
  savedclipsopt=("-path" "./SavedClips/*" "-o" "-path" "./EncryptedClips/SavedClips/*")
  sentryclipsopt=("-o" "-path" "./SentryClips/*" "-o" "-path" "./EncryptedClips/SentryClips/*")
  trackmodeclipsopt=("-o" "-path" "./TeslaTrackMode/*")
  if [ "${1:-false}" = "true" ]
  then
    recentclipsopt=("-o" "-path" "./RecentClips/*" "-o" "-path" "./EncryptedClips/RecentClips/*")
  fi
  (cd /tmp/enc/mutable/TeslaCam && find . \( \( "${savedclipsopt[@]}" "${sentryclipsopt[@]}" \
    "${trackmodeclipsopt[@]}" "${recentclipsopt[@]}" \) -type l \) -a -fprintf /tmp/enc/sentry_files '%P\n')
  sort -o /tmp/enc/sentry_files /tmp/enc/sentry_files
}

# The links point at the snapshot's eventual mount, which does not exist yet when they are
# made, so they dangle by design: test for the link, not for what it points at.
assert_link () {
  if [ -L "$1" ]
  then ok "$2"
  else not_ok "$2 (no symlink at $1)"
  fi
}

start_case "snapshot links are made for the encrypted tree, mirroring the classic one"
enc_env
run_snapshot_links
assert_link /tmp/enc/mutable/TeslaCam/EncryptedClips/SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4 \
  "an encrypted Sentry clip is linked into its event folder"
assert_link /tmp/enc/mutable/TeslaCam/EncryptedClips/SavedClips/2026-09-18_10-00-00/2026-09-18_09-59-00-front.mp4 \
  "and an encrypted Saved clip"
assert_link /tmp/enc/mutable/TeslaCam/EncryptedClips/RecentClips/2026-09-18/2026-09-18_09-59-00-front.mp4 \
  "and an encrypted Recent clip goes into its day folder"
assert_link /tmp/enc/mutable/TeslaCam/SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4 \
  "while the classic tree is linked as before"
if [ -L /tmp/enc/mutable/TeslaCam/EncryptedClips/SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4 ]
then
  target=$(readlink /tmp/enc/mutable/TeslaCam/EncryptedClips/SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4)
  assert_equals "/tmp/enc/final/TeslaCam/EncryptedClips/SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4" \
    "$target" "the link points at the final mount, not the temporary one"
else
  not_ok "the encrypted Sentry link is a symlink"
fi

start_case "the archive list includes the encrypted clips"
run_archive_find false
assert_grep "^EncryptedClips/SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4$" /tmp/enc/sentry_files \
  "an encrypted Sentry clip is queued for archiving"
assert_grep "^EncryptedClips/SentryClips/2026-09-18_11-00-00/event.json$" /tmp/enc/sentry_files \
  "along with its event.json"
assert_grep "^EncryptedClips/SavedClips/2026-09-18_10-00-00/2026-09-18_09-59-00-front.mp4$" /tmp/enc/sentry_files \
  "and an encrypted Saved clip"
assert_grep "^SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4$" /tmp/enc/sentry_files \
  "with the classic clips still there"
assert_no_grep "RecentClips/" /tmp/enc/sentry_files \
  "and no Recent clips of either kind, since ARCHIVE_RECENTCLIPS is off by default"

start_case "ARCHIVE_RECENTCLIPS brings in both kinds of recent clip"
run_archive_find true
assert_grep "^EncryptedClips/RecentClips/2026-09-18/2026-09-18_09-59-00-front.mp4$" /tmp/enc/sentry_files \
  "the encrypted Recent clip is queued"
assert_grep "^RecentClips/2026-09-18/2026-09-18_09-59-00-front.mp4$" /tmp/enc/sentry_files "as is the classic one"

start_case "a car that does not write EncryptedClips is unaffected"
rm -rf /tmp/enc/snap/TeslaCam/EncryptedClips /tmp/enc/mutable/TeslaCam
mkdir -p /tmp/enc/mutable/TeslaCam
run_snapshot_links
run_archive_find false
assert_equals "0" "$(grep -c EncryptedClips /tmp/enc/sentry_files)" "nothing encrypted is listed"
assert_grep "^SentryClips/2026-09-18_11-00-00/2026-09-18_10-59-00-front.mp4$" /tmp/enc/sentry_files \
  "the classic clips are still found"
assert_no_grep "No such file" /tmp/enc/snapshot.log "and the missing folder produces no errors"

start_case "the trigger files are placed in the encrypted folders too"
# archiveloop drops marker files into each folder it archives so the far end can react;
# the encrypted folders are part of what gets archived now, so they get them as well.
# The patterns below are the literal source text, variables and all.
# shellcheck disable=SC2016
assert_grep 'mkdir -p "${triggerdir}/EncryptedClips/SentryClips"' "$REPO/run/archiveloop" \
  "a trigger directory is made for encrypted Sentry"
# shellcheck disable=SC2016
assert_grep 'echo "EncryptedClips/SavedClips/${TRIGGER_FILE_SAVED}" >> "${triggerlist}"' "$REPO/run/archiveloop" \
  "and the Saved trigger is written into the encrypted folder as well as the classic one"

start_case "empty encrypted event folders are cleaned up with the rest"
# shellcheck disable=SC2016
assert_grep '"\$CAM_MOUNT/TeslaCam/EncryptedClips/SentryClips"' "$REPO/run/archiveloop" \
  "the empty-directory sweep covers the encrypted tree"

start_case "the dashboard folds encrypted usage into the category it belongs to"
# An encrypted Sentry event is still a Sentry event. Rather than a fourth slice, each
# encrypted folder is summed into its category, so the pie means the same thing whichever
# way the car is writing.
rm -rf /tmp/cu && mkdir -p /tmp/cu/SentryClips/e1 /tmp/cu/EncryptedClips/SentryClips/e2 /tmp/cu/RecentClips
head -c 3000 /dev/zero > /tmp/cu/SentryClips/e1/a.mp4
head -c 5000 /dev/zero > /tmp/cu/EncryptedClips/SentryClips/e2/b.mp4
head -c 700 /dev/zero > /tmp/cu/RecentClips/c.mp4
sed -e 's|^SRC=.*|SRC=/tmp/cu|' -e 's|^CACHE=.*|CACHE=/tmp/cu.json|' -e 's|^LOCK=.*|LOCK=/tmp/cu.lock|' \
    -e 's|sudo du|du|g' "$REPO/teslausb-www/html/cgi-bin/camusage.sh" > /tmp/cu.sh
rm -f /tmp/cu.json
usage_json=$(bash /tmp/cu.sh | tail -1)
sentry=$(printf '%s' "$usage_json" | sed -n 's/.*"SentryClips":\([0-9]*\).*/\1/p')
recent=$(printf '%s' "$usage_json" | sed -n 's/.*"RecentClips":\([0-9]*\).*/\1/p')
saved=$(printf '%s' "$usage_json" | sed -n 's/.*"SavedClips":\([0-9]*\).*/\1/p')
# du counts directory blocks too, so compare against the same measurement of the folder
# alone rather than against the file size
recent_alone=$(du -sbL /tmp/cu/RecentClips | cut -f1)
assert_equals "$recent_alone" "$recent" \
  "Recent usage is unaffected by an encrypted folder that does not exist"
sentry_alone=$(( $(du -sbL /tmp/cu/SentryClips | cut -f1) + $(du -sbL /tmp/cu/EncryptedClips/SentryClips | cut -f1) ))
assert_equals "$sentry_alone" "$sentry" "and Sentry is exactly the sum of its two folders"
assert_equals "0" "$saved" "a category with neither folder reports zero rather than failing"
assert_equals "3" "$(printf '%s' "$usage_json" | grep -o '"[A-Za-z]*Clips"' | wc -l)" \
  "and the JSON still has exactly the three keys the dashboard expects"

rm -rf /tmp/enc /tmp/cu /tmp/cu.sh /tmp/cu.json /tmp/cu.lock

banner "rsync archiving: the path on the far end"

# rsync 3.2.4 protects args by default, so the remote path is no longer parsed by a shell
# and an escaped space becomes part of the directory name. A config written for an older
# rsync therefore starts archiving into a directory nobody meant, beside the real one,
# which is how a device came to have both "Tesla Cam" and "Tesla\ Cam" on its NAS.
rsync_archive_env () {
  rm -rf /tmp/rsync-args
  mkdir -p /tmp/rsync-args /tmp/clips
  cat > "$STUBS/rsync" << 'STUB'
#!/bin/bash
# record the destination, which is always the last argument
printf '%s\n' "${!#}" >> /tmp/rsync-args/dest
exit 0
STUB
  chmod +x "$STUBS/rsync"
  : > /tmp/clips/list
}

run_archive_clips () {
  ( trace_bash "$REPO/run/rsync_archive/archive-clips.sh" /tmp/clips /tmp/clips/list ) \
    > /tmp/archive-clips.log 2>&1
  ARCHIVE_RC=$?
  return 0
}

start_case "a path with escaped spaces is corrected, not used as it stands"
rsync_archive_env
RSYNC_USER=archiver RSYNC_SERVER=nas RSYNC_PATH='/KevNAS/Tesla\ Cam' run_archive_clips
assert_equals "0" "$ARCHIVE_RC" "archiving still succeeds"
assert_grep "^archiver@nas:/KevNAS/Tesla Cam$" /tmp/rsync-args/dest \
  "rsync is given the path the directory actually has"
assert_no_grep "Tesla..... Cam" /tmp/rsync-args/dest "and not the escaped one"
assert_grep "Remove the backslashes" /tmp/archive-rsync-cmd.log \
  "the log says what it did and how to stop it happening"

start_case "a path with real spaces is passed through untouched"
rsync_archive_env
RSYNC_USER=archiver RSYNC_SERVER=nas RSYNC_PATH='/KevNAS/Tesla Cam' run_archive_clips
assert_equals "0" "$ARCHIVE_RC" "succeeds"
assert_grep "^archiver@nas:/KevNAS/Tesla Cam$" /tmp/rsync-args/dest "the path is unchanged"

start_case "an ordinary path is left completely alone"
rsync_archive_env
rm -f /tmp/archive-rsync-cmd.log
RSYNC_USER=archiver RSYNC_SERVER=nas RSYNC_PATH=/srv/teslausb run_archive_clips
assert_grep "^archiver@nas:/srv/teslausb$" /tmp/rsync-args/dest "passed through"
assert_no_file /tmp/archive-rsync-cmd.log "and nothing is logged about it"

start_case "every pair of arguments is archived"
rsync_archive_env
RSYNC_USER=archiver RSYNC_SERVER=nas RSYNC_PATH=/srv/teslausb \
  bash "$REPO/run/rsync_archive/archive-clips.sh" /tmp/clips /tmp/clips/list \
    /tmp/clips /tmp/clips/list > /dev/null 2>&1
assert_equals "2" "$(wc -l < /tmp/rsync-args/dest)" "two pairs, two transfers"

start_case "a failing transfer is reported with both logs"
rsync_archive_env
printf '#!/bin/bash\necho "rsync: some failure" >&2\nexit 12\n' > "$STUBS/rsync"
chmod +x "$STUBS/rsync"
: > /tmp/archive-rsync-cmd.log
RSYNC_USER=archiver RSYNC_SERVER=nas RSYNC_PATH=/srv/teslausb run_archive_clips
assert_equals "1" "$ARCHIVE_RC" "exits non-zero"
assert_file /tmp/archive-error.log "the error log is written for archiveloop to pick up"

start_case "rsync's partial transfer code is not treated as a failure"
# 24 is "some files vanished before they could be sent", which happens routinely when the
# car is still writing, and must not fail the archive.
rsync_archive_env
printf '#!/bin/bash\nexit 24\n' > "$STUBS/rsync"
chmod +x "$STUBS/rsync"
RSYNC_USER=archiver RSYNC_SERVER=nas RSYNC_PATH=/srv/teslausb run_archive_clips
assert_equals "0" "$ARCHIVE_RC" "treated as success"

rm -f "$STUBS/rsync"

banner "the flashable image: Automation_Custom_PreScript.sh"

# The image can only ask the user to edit the boot partition, because that is the only
# partition Windows and macOS both mount, while DietPi reads its settings from the ext4
# root filesystem. This hook bridges the two, and it has to run before DietPi's own
# network setup or the first boot has no wifi to work with.
#
# /boot belongs to DietPi in this container, so it is snapshotted and put back afterwards.
prescript_env () {
  rm -rf /tmp/pre /boot/teslausb-local /boot/firmware
  mkdir -p /tmp/pre /boot/firmware
  [ -f /tmp/pre-dietpi.txt ] || cp /boot/dietpi.txt /tmp/pre-dietpi.txt
  cp /tmp/pre-dietpi.txt /boot/dietpi.txt
  # This DietPi has no dietpi-wifi.txt of its own, and restoring a file that was never
  # there left one case's credentials lying around for the next one to find.
  if [ -f /tmp/pre-wifi.txt ]
  then
    cp /tmp/pre-wifi.txt /boot/dietpi-wifi.txt
  else
    rm -f /boot/dietpi-wifi.txt
  fi
  rm -f /boot/firmware/teslausb-headless-setup.log
}

stage_repo_tar () {
  mkdir -p /boot/teslausb-local
  tar -C "$REPO" -cf /boot/teslausb-local/repo.tar \
    tools/prepare-boot-partition.sh dietpi/Automation_Custom_Script.sh \
    dietpi/teslausb_setup_variables.conf.sample 2> /dev/null
}

write_image_conf () {
  cat > /boot/firmware/teslausb_setup_variables.conf << CONF
export TESLAUSB_HOSTNAME=teslausb-image
${1:-}
CONF
}

run_prescript () {
  ( trace_bash "$REPO/dietpi/Automation_Custom_PreScript.sh" ) > /tmp/pre.log 2>&1
  PRE_RC=$?
  return 0
}

start_case "a card prepared on a computer needs nothing from this"
prescript_env
run_prescript
assert_equals "0" "$PRE_RC" "exits 0"
assert_grep "nothing to do" /tmp/pre.log "says there is nothing to do"
assert_no_file /boot/firmware/teslausb-headless-setup.log "and writes no log"

start_case "the config the user edited on the boot partition is applied"
prescript_env
stage_repo_tar
write_image_conf "export SSID='Chateau Cathcart'
export WIFIPASS=animalcrackers
export TESLAUSB_TIMEZONE=America/Los_Angeles
export OS_PASSWORD=notthedefault"
run_prescript
assert_equals "0" "$PRE_RC" "exits 0"
assert_grep "found /boot/firmware/teslausb_setup_variables.conf" /tmp/pre.log "finds it on the boot partition"
assert_grep "applied the settings" /tmp/pre.log "and applies them"
assert_grep "^AUTO_SETUP_NET_WIFI_ENABLED=1$" /boot/dietpi.txt "wifi is switched on for DietPi's own setup"
assert_grep "Chateau Cathcart" /boot/dietpi-wifi.txt "the SSID reaches the file DietPi reads"
assert_grep "animalcrackers" /boot/dietpi-wifi.txt "so does the passphrase"
assert_grep "^AUTO_SETUP_NET_HOSTNAME=teslausb-image$" /boot/dietpi.txt "the hostname is applied"
assert_grep "^AUTO_SETUP_TIMEZONE=America/Los_Angeles$" /boot/dietpi.txt "the timezone is applied"
assert_grep "^AUTO_SETUP_GLOBAL_PASSWORD=notthedefault$" /boot/dietpi.txt "and the password, so the device is not on the network with DietPi's default"
assert_equals "600" "$(stat -c %a /boot/dietpi-wifi.txt)" "the credentials are not world readable"
assert_grep "wifi credentials are in place" /tmp/pre.log "and it confirms wifi is ready"
assert_grep "wifi credentials are in place" /boot/firmware/teslausb-headless-setup.log \
  "logging to the boot partition, which is readable from a card reader"

start_case "a config with no wifi is called out rather than passed over"
prescript_env
stage_repo_tar
write_image_conf "export ARCHIVE_SYSTEM=rsync"
run_prescript
assert_equals "0" "$PRE_RC" "still exits 0, since the boot has to finish"
assert_grep "no wifi credentials were written" /tmp/pre.log "warns that there are none"
assert_grep "cannot be reached" /tmp/pre.log "and says what that means for a car device"

start_case "the whole source tree is needed, not just the one script"
# prepare-boot-partition.sh installs files from the repository it finds beside itself, so
# a lone copy in a staging directory would look for the bootstrap in DietPi's /boot/dietpi
# and fail. Staging the tree is what makes it work, and is also what pins the version.
prescript_env
mkdir -p /boot/teslausb-local
tar -C "$REPO" -cf /boot/teslausb-local/repo.tar tools/prepare-boot-partition.sh 2> /dev/null
write_image_conf "export SSID=net
export WIFIPASS=longenough1"
run_prescript
assert_equals "0" "$PRE_RC" "exits 0"
assert_grep "no prepare-boot-partition.sh in the image" /tmp/pre.log \
  "a tree without the bootstrap in it is refused"

start_case "an image with nothing staged says so and boots anyway"
prescript_env
write_image_conf "export SSID=net
export WIFIPASS=longenough1"
run_prescript
assert_equals "0" "$PRE_RC" "exits 0"
assert_grep "wifi cannot be set up here" /tmp/pre.log "explains what it could not do"
assert_grep "whatever it was flashed with" /tmp/pre.log "and what will happen instead"

start_case "a corrupt archive is not fatal either"
prescript_env
mkdir -p /boot/teslausb-local
head -c 512 /dev/urandom > /boot/teslausb-local/repo.tar
write_image_conf "export SSID=net
export WIFIPASS=longenough1"
run_prescript
assert_equals "0" "$PRE_RC" "exits 0"
assert_grep "no prepare-boot-partition.sh in the image" /tmp/pre.log "reports it"

start_case "a config that cannot be applied is reported, and the boot continues"
prescript_env
stage_repo_tar
printf 'export SSID=net\nthis is not shell(\n' > /boot/firmware/teslausb_setup_variables.conf
run_prescript
assert_equals "0" "$PRE_RC" "exits 0 rather than stopping DietPi's first run"
assert_grep "could not apply" /tmp/pre.log "says it could not be applied"
assert_grep "continuing the boot regardless" /tmp/pre.log "and that it is carrying on"

start_case "a config on the root filesystem's own /boot is found too"
# Single partition images, such as the VM one, have no separate FAT partition.
prescript_env
stage_repo_tar
rm -rf /boot/firmware
cat > /boot/teslausb_setup_variables.conf << 'CONF'
export SSID=net
export WIFIPASS=longenough1
CONF
run_prescript
assert_equals "0" "$PRE_RC" "exits 0"
assert_grep "found /boot/teslausb_setup_variables.conf" /tmp/pre.log "looks there as well"
rm -f /boot/teslausb_setup_variables.conf

# leave /boot as DietPi had it
prescript_env
rm -rf /boot/teslausb-local /boot/firmware /tmp/pre

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
  # A container sees the host's /proc/uptime, and the watchdog holds off for the first
  # twenty minutes of a boot, so leaving this to the environment means the whole section
  # passes on a workstation that has been up for days and does nothing at all on a CI
  # runner that has been up for two minutes. The cases that care about the gate override
  # it themselves, and a later value in the environment wins over an earlier one.
  printf '86400.00 86400.00\n' > /tmp/watchdog-uptime
  local -a base=(
    UPTIME_FILE=/tmp/watchdog-uptime
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

# The same thing as watchdog_env, but reading the setup conf the cases below write. It
# delegates rather than repeating the environment: the duplicate copy did not have the
# uptime pin, which is how the whole section came to depend on how long the host had
# been up.
watchdog () {
  watchdog_env SETUP_CONF=/tmp/setup.conf
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
banner "what the first boot on real hardware turned up"
# ===========================================================================
# Every one of these was found by installing on a Pi Zero 2 WH rather than in the
# lab, because each depends on hardware or on a full unattended boot.

start_case "the gadget is released so the card can be unmounted"
# The mass storage gadget holds /backingfiles/cam_disk.bin open, so /backingfiles
# stays busy, systemd cannot unmount it, and the shutdown ends with "failed
# unmounting backingfiles.mount" and a cam filesystem to repair next boot.
assert_grep "ExecStop=-/root/bin/disable_gadget.sh" "$REPO/setup/pi/configure.sh" \
  "teslausb.service releases the gadget when it stops"
assert_grep "^ExecStart=/bin/bash /root/bin/archiveloop$" "$REPO/setup/pi/configure.sh" \
  "and still starts archiveloop as before"

start_case "the leftover DietPi RAMlog unit is disabled"
# It redirects its log into /var/lib/dietpi/logs, which is read-only by then, so dash
# exits 2 and every boot ends with a failed unit for no reason.
ramlog_fn=$(sed -n '/^function disable_dietpi_ramlog_units/,/^}/p' "$REPO/setup/pi/make-root-fs-readonly.sh")
: > /tmp/ramlog.progress
rm -f /tmp/systemctl.calls
# the $* and $1 are meant to reach the stub, not expand here
# shellcheck disable=SC2016
printf '#!/bin/bash\necho "systemctl $*" >> /tmp/systemctl.calls\n[ "$1" = is-enabled ] && exit 0\nexit 0\n' > "$STUBS/systemctl"
chmod +x "$STUBS/systemctl"
( # shellcheck disable=SC2329
  log_progress () { echo "$*" >> /tmp/ramlog.progress; }
  eval "$ramlog_fn"
  disable_dietpi_ramlog_units
) && rc=0 || rc=1
rm -f "$STUBS/systemctl"
assert_eq "$rc" 0 "exits 0"
assert_grep "disable dietpi-ramlog_disable.service" /tmp/systemctl.calls "disables the failing unit"
assert_grep "disable dietpi-ramlog.service" /tmp/systemctl.calls "and RAMlog itself"
assert_grep "nothing left to do" /tmp/ramlog.progress "saying why"

start_case "Bluetooth firmware is installed, which DietPi does not ship"
# Without bluez-firmware the kernel asks for brcm/BCM43430A1...hcd, does not find it,
# and the adapter never comes up, so the Tesla BLE feature cannot work. Raspberry Pi
# OS installs it by default, which is why upstream never had to ask for it.
assert_grep "bluez-firmware" "$REPO/setup/pi/configure.sh" "bluez-firmware is installed"
assert_grep "for pkg in bluez bluez-firmware pi-bluetooth" "$REPO/setup/pi/configure.sh" \
  "along with bluez and pi-bluetooth"
assert_grep "^install_bluetooth_support$" "$REPO/setup/pi/configure.sh" \
  "and it runs whether or not the BLE feature is configured"
assert_grep "apt-cache policy" "$REPO/setup/pi/configure.sh" \
  "skipping any package this platform does not have"

start_case "the console logs in after the units that write to it"
# The shell drew its prompt and DietPi's postboot output then landed on top, leaving a
# console with a banner and no prompt: alive, but nothing to type at.
assert_grep "After=dietpi-postboot.service" "$REPO/tools/prepare-boot-partition.sh" \
  "the autologin drop-in is ordered after DietPi's postboot output"

start_case "an attached display is kept awake"
# this section runs before the one that builds it, so make a config to work with
printf 'export SSID=net\nexport WIFIPASS=secret123\n' > /tmp/single.conf
# DietPi ships hdmi_blanking=1, described in its own config.txt as letting the display
# go into standby after ten idle minutes. With no keyboard, nothing wakes it again.
fake_boot_partition
printf 'hdmi_blanking=1\ndisable_splash=1\n' > /tmp/bootfs/config.txt
run_prepare /tmp/bootfs /tmp/single.conf
assert_grep "^hdmi_blanking=0$" /tmp/bootfs/config.txt "an existing 1 is changed to 0"
assert_grep "^disable_splash=1$" /tmp/bootfs/config.txt "leaving the rest of config.txt alone"
assert_eq "$(grep -c "^hdmi_blanking" /tmp/bootfs/config.txt)" 1 "without duplicating the line"

fake_boot_partition
printf 'disable_splash=1\n' > /tmp/bootfs/config.txt
run_prepare /tmp/bootfs /tmp/single.conf
assert_grep "^hdmi_blanking=0$" /tmp/bootfs/config.txt "and it is added when absent"

fake_boot_partition
printf 'hdmi_blanking=0\n' > /tmp/bootfs/config.txt
run_prepare /tmp/bootfs /tmp/single.conf
assert_grep "already 0" /tmp/prepare.log "says nothing needed doing when it is already 0"

fake_boot_partition
run_prepare /tmp/bootfs /tmp/single.conf
assert_eq "$PREPARE_RC" 0 "and a platform with no config.txt is fine"
assert_no_file /tmp/bootfs/config.txt "nothing is created there"

# ===========================================================================
banner "nothing in fstab can strand the device in emergency mode"
# ===========================================================================
# A failed mount fails local-fs.target, and a device in a glovebox with no keyboard
# is then unreachable. Two entries did exactly that: a tmpfs for /var/log/nginx whose
# mount point disappeared with DietPi-RAMlog, and a swap entry pointing at a file
# that had been deleted.

start_case "nginx's mounts cannot fail the boot"
assert_grep "tmpfs /var/log/nginx tmpfs nodev,nosuid,nofail" "$REPO/setup/pi/configure-web.sh" \
  "the log tmpfs carries nofail"
assert_grep "tmpfs /var/lib/nginx tmpfs nodev,nosuid,nofail" "$REPO/setup/pi/configure-web.sh" \
  "so does the cache tmpfs"


start_case "nginx's tmpfs mounts have an explicit mode, so the master can reopen its log"
# Without a mode a tmpfs mounts 1777. Debian's fs.protected_regular=2 then forbids opening
# for write a file in it that you do not own, root included. nginx's master is root and its
# workers are www-data, so once a worker had created error.log the master could not open it,
# every reload and every "nginx -t" failed, and systemctl reported the reload a success while
# the old configuration kept running. Found because a configuration change would not take.
assert_grep "tmpfs /var/log/nginx tmpfs nodev,nosuid,nofail,mode=0755 0 0" "$REPO/setup/pi/configure-web.sh" \
  "the log tmpfs is mounted 0755"
assert_grep "tmpfs /var/lib/nginx tmpfs nodev,nosuid,nofail,mode=0755 0 0" "$REPO/setup/pi/configure-web.sh" \
  "and so is the cache tmpfs"
assert_grep "protected_regular" "$REPO/setup/pi/configure-web.sh" "with the reason recorded beside it"

start_case "encrypted clips: the viewer's key request is forwarded to Tesla from the same origin"
# Tesla's decrypt endpoint sends no CORS headers, so a browser on the device's origin cannot
# call it. nginx forwards one path to it. Only that path, only POST, and only a small body:
# the video is fetched from /TeslaCam/ as usual and decrypted in the browser.
nginx_conf="$REPO/teslausb-www/teslausb.nginx"
assert_grep "location = /tesla/decrypt {" "$nginx_conf" "an exact-match location for the one request"
assert_grep "proxy_pass https://dashcam.tesla.com/api/1/decrypt/batch;" "$nginx_conf" "forwarded to Tesla's batch endpoint"
assert_grep "proxy_http_version 1.1;" "$nginx_conf" "over HTTP/1.1, which Tesla requires (426 otherwise)"
assert_grep "proxy_ssl_server_name on;" "$nginx_conf" "with SNI, so the TLS handshake names the right host"
assert_grep "limit_except POST { deny all; }" "$nginx_conf" "POST only"
assert_grep "client_max_body_size 64k;" "$nginx_conf" "and a body limit far below any video"
assert_grep "proxy_hide_header Set-Cookie;" "$nginx_conf" "Tesla's cookies are not passed back to the browser"
# the config parses; fancyindex is a module the stock image lacks, so it is stubbed
if command -v nginx > /dev/null
then
  sed '/fancyindex/d' "$nginx_conf" > /tmp/nginx-check.conf
  mkdir -p /tmp/nginx-check/www && : > /tmp/nginx-check/htpasswd
  sed -i "s|/var/www/html|/tmp/nginx-check/www|g; s|/etc/nginx/.htpasswd|/tmp/nginx-check/htpasswd|g" /tmp/nginx-check.conf
  printf 'events {}\nhttp { include /tmp/nginx-check.conf; }\n' > /tmp/nginx-check-main.conf
  if nginx -t -c /tmp/nginx-check-main.conf -e /dev/null > /dev/null 2>&1
  then ok "nginx accepts the configuration"
  else not_ok "nginx accepts the configuration ($(nginx -t -c /tmp/nginx-check-main.conf 2>&1 | grep -m1 emerg))"
  fi
  rm -rf /tmp/nginx-check /tmp/nginx-check.conf /tmp/nginx-check-main.conf
else
  note "nginx not installed in this container, config parse skipped"
fi
# and the browser side posts to that same-origin path, never to Tesla directly
assert_grep "export const DECRYPT_URL = 'tesla/decrypt';" "$REPO/teslausb-www/ui/src/teslaDecrypt.ts" \
  "the viewer posts to the proxied path"
assert_no_grep "fetch(\`\${TESLA_DASHCAM_URL}" "$REPO/teslausb-www/ui/src/teslaDecrypt.ts" \
  "and never fetches Tesla's origin directly, which the browser would block"
start_case "the log mount point is recreated once DietPi-RAMlog is gone"
# configure-web.sh makes /var/log/nginx while RAMlog still has a tmpfs on /var/log, so
# the directory goes when RAMlog does. It has to be made again while the root
# filesystem is still writable.
nginx_fn=$(sed -n '/^function restore_nginx_log_mountpoint/,/^}/p' "$REPO/setup/pi/make-root-fs-readonly.sh")
run_restore () {
  : > /tmp/restore.progress
  rm -rf /tmp/varlog && mkdir -p /tmp/varlog
  ( # shellcheck disable=SC2329
    log_progress () { echo "$*" >> /tmp/restore.progress; }
    eval "${nginx_fn//\/var\/log\/nginx//tmp/varlog/nginx}"
    restore_nginx_log_mountpoint
  ) && RESTORE_RC=0 || RESTORE_RC=$?
}
# the path is rewritten in the extracted function, so fstab has to match it
printf 'tmpfs /tmp/varlog/nginx tmpfs nodev,nosuid,nofail 0 0\n' > /tmp/fake_fstab
cp /etc/fstab /tmp/fstab.real 2>/dev/null || true
cp /tmp/fake_fstab /etc/fstab
run_restore
assert_eq "$RESTORE_RC" 0 "exits 0"
assert_eq "$([ -d /tmp/varlog/nginx ] && echo yes)" yes "the mount point is created"
assert_grep "recreating" /tmp/restore.progress "and says why"

start_case "and it does nothing when there is nothing to do"
run_restore
mkdir -p /tmp/varlog/nginx
: > /tmp/restore.progress
( # shellcheck disable=SC2329
  log_progress () { echo "$*" >> /tmp/restore.progress; }
  eval "${nginx_fn//\/var\/log\/nginx//tmp/varlog/nginx}"
  restore_nginx_log_mountpoint
) > /dev/null 2>&1
assert_eq "$(grep -c . /tmp/restore.progress || true)" 0 "silent when the directory already exists"
printf 'tmpfs /tmp tmpfs defaults 0 0\n' > /etc/fstab
run_restore
assert_eq "$([ -d /tmp/varlog/nginx ] && echo yes || echo no)" no \
  "and creates nothing when fstab has no such mount"
[ -f /tmp/fstab.real ] && cp /tmp/fstab.real /etc/fstab

start_case "the systemd journal is kept on /mutable, so a reboot does not erase it"
# On a read-only root the journal lives in RAM and vanishes with the power, which is exactly
# when it was needed: a device that went dark for seven hours left nothing to read but
# archiveloop's log. The function binds a directory on the persistent partition over
# /var/log/journal and caps it, since the partition is small and shared with archive state.
journal_fn=$(sed -n '/^function persist_journal_to_mutable/,/^}/p' "$REPO/setup/pi/make-root-fs-readonly.sh")
rm -rf /tmp/jm && mkdir -p /tmp/jm/mutable /tmp/jm/varlog /tmp/jm/etc/systemd
cp /etc/fstab /tmp/fstab.real 2>/dev/null || true
: > /etc/fstab
: > /tmp/journal.progress
( # shellcheck disable=SC2329
  log_progress () { echo "$*" >> /tmp/journal.progress; }
  fn=${journal_fn//\/mutable\/journal//tmp/jm/mutable/journal}
  fn=${fn//\/var\/log\/journal//tmp/jm/varlog/journal}
  fn=${fn//\/etc\/systemd\/journald.conf.d//tmp/jm/etc/systemd/journald.conf.d}
  eval "$fn"
  persist_journal_to_mutable
) && JOURNAL_RC=0 || JOURNAL_RC=$?
assert_eq "$JOURNAL_RC" 0 "exits 0"
assert_eq "$([ -d /tmp/jm/mutable/journal ] && echo yes)" yes "the directory on /mutable is created"
assert_eq "$([ -d /tmp/jm/varlog/journal ] && echo yes)" yes "and the mount point under /var/log"
assert_grep "^/tmp/jm/mutable/journal /tmp/jm/varlog/journal none bind,nofail,x-systemd.requires=/mutable 0 0$" /etc/fstab \
  "a bind mount ties them together, with nofail so a missing /mutable cannot stop the boot"
conf=/tmp/jm/etc/systemd/journald.conf.d/teslausb.conf
assert_file "$conf" "a journald drop-in is written"
assert_grep "^Storage=persistent$" "$conf" "journald is told to persist, not merely to use a directory if present"
assert_grep "^SystemMaxUse=32M$" "$conf" "capped far below the partition's size"
assert_grep "^SystemMaxFileSize=8M$" "$conf" "in files small enough to rotate often"
assert_grep "^SyncIntervalSec=60s$" "$conf" "with infrequent syncs, since power drops many times a day"
assert_grep "^Compress=yes$" "$conf" "and compressed"
assert_grep "survives a reboot" /tmp/journal.progress "and says what it is doing"

start_case "running it again changes nothing"
( # shellcheck disable=SC2329
  log_progress () { :; }
  fn=${journal_fn//\/mutable\/journal//tmp/jm/mutable/journal}
  fn=${fn//\/var\/log\/journal//tmp/jm/varlog/journal}
  fn=${fn//\/etc\/systemd\/journald.conf.d//tmp/jm/etc/systemd/journald.conf.d}
  eval "$fn"
  persist_journal_to_mutable
)
assert_eq "$(grep -c 'journal' /etc/fstab)" 1 "the fstab entry is not duplicated"
assert_eq "$(grep -c '^Storage=' "$conf")" 1 "nor the drop-in"

start_case "the readonly script calls it alongside the other log fixes"
assert_grep "^persist_journal_to_mutable$" "$REPO/setup/pi/make-root-fs-readonly.sh" "called at the top level"
cp /tmp/fstab.real /etc/fstab 2>/dev/null || true
rm -rf /tmp/jm /tmp/journal.progress

start_case "the swap entry goes with the swap file"
# Deleting /var/swap while DietPi's fstab still points at it fails local-fs.target.
assert_grep "swapoff /var/swap" "$REPO/setup/pi/make-root-fs-readonly.sh" "swap is turned off"
assert_grep "sed -i .*var/swap.*/etc/fstab\|/var/swap\[\[:blank:\]\]" \
  "$REPO/setup/pi/make-root-fs-readonly.sh" "the fstab entry is removed"
assert_grep "dietpi-set_swapfile 0" "$REPO/setup/pi/make-root-fs-readonly.sh" \
  "and DietPi's own tool is used where available, so its records stay straight"
assert_grep "rm -f /var/swap" "$REPO/setup/pi/make-root-fs-readonly.sh" "before the file is deleted"

# ===========================================================================
banner "preparing a card: where each file goes"
# ===========================================================================
# On the Raspberry Pi images the partition a PC can see is not the one DietPi reads.
# DietPi reads /boot, which is on the root filesystem there, while teslausb reads its
# own config from /teslausb, which first-boot.sh points at /boot/firmware when such a
# partition exists. Getting this wrong produced a device that booted into an
# interactive DietPi with no network, and then one that could not find its config.

start_case "a single-partition image keeps everything in the one place"
fake_boot_partition
printf 'export SSID=net\nexport WIFIPASS=secret123\nexport TESLAUSB_HOSTNAME=teslausb\n' > /tmp/single.conf
run_prepare /tmp/bootfs /tmp/single.conf
assert_eq "$PREPARE_RC" 0 "exits 0"
assert_file /tmp/bootfs/teslausb_setup_variables.conf "teslausb's config is here"
assert_file /tmp/bootfs/Automation_Custom_Script.sh "DietPi's hook is here too"
assert_grep "^AUTO_SETUP_AUTOMATED=1$" /tmp/bootfs/dietpi.txt "dietpi.txt is updated in place"
assert_grep "aWIFI_SSID\[0\]='net'" /tmp/bootfs/dietpi-wifi.txt "and the wifi file written"

start_case "a firmware partition sends it looking for the root filesystem"
# The give-away is DietPi's own scripts: present means this is the real /boot, absent
# means it is the FAT partition and the config belongs on the root filesystem.
rm -rf /tmp/fwonly && mkdir -p /tmp/fwonly
cp /tmp/bootfs/dietpi.txt /tmp/fwonly/dietpi.txt
printf 'root=PARTUUID=deadbeef-02\n' > /tmp/fwonly/cmdline.txt
run_prepare /tmp/fwonly /tmp/single.conf
assert_eq "$([ "$PREPARE_RC" != 0 ] && echo nonzero)" nonzero \
  "refuses rather than writing to the wrong partition"
assert_grep "firmware partition\|root filesystem" /tmp/prepare.log \
  "and says it needs the root filesystem"

start_case "the root filesystem is found whichever way the card is laid out"
# /dev/mmcblk0p1 -> p2 on a card reader, /dev/sdb1 -> sdb2 on a USB adapter.
prep_fw_case () {
  # $1: the device findmnt should report, $2: what "findmnt -no TARGET" should do
  rm -rf /tmp/fwmnt /tmp/fakeroot
  mkdir -p /tmp/fwmnt /tmp/fakeroot/boot/dietpi /tmp/fakeroot/etc/systemd/system
  cp /tmp/bootfs/dietpi.txt /tmp/fwmnt/dietpi.txt
  cp /tmp/bootfs/dietpi.txt /tmp/fakeroot/boot/dietpi.txt
  cat > "$STUBS/findmnt" <<EOF
#!/bin/bash
case "\$*" in
  *"--target"*)   echo "$1" ;;
  *"-no TARGET"*) $2 ;;
  *) exit 1 ;;
esac
EOF
  # lsblk answers two questions: which disk a partition is on, and what partitions
  # that disk has. FAKE_PARTS decides the order, which is the whole point: the
  # Raspberry Pi images put the FAT first, boards with a DIETPISETUP partition put
  # it last, and the search has to cope with both.
  cat > "$STUBS/lsblk" <<EOF
#!/bin/bash
case "\$*" in
  *PKNAME*) echo "fakedisk" ;;
  *NAME*)   printf '%s\\n' fakedisk ${FAKE_PARTS:-$1 /dev/teslausb-rootfs} ;;
esac
EOF
  cat > "$STUBS/mount" <<'EOF'
#!/bin/bash
# read-only probes are the search looking for DietPi's root filesystem
case "$*" in
  *"-o ro"*)
    target="${@: -1}"          # the mount point is the last argument
    case "$*" in
      *teslausb-rootfs*) cp -r /tmp/fakeroot/. "$target/" ;;
      *) : ;;                                  # any other partition looks empty
    esac
    echo "probe $*" >> /tmp/mount.calls
    exit 0
    ;;
esac
# MOUNT_FAILS exercises the path where the root filesystem will not mount
[ "${MOUNT_FAILS:-0}" = 1 ] && exit 1
cp -r /tmp/fakeroot/. "$2/"
echo "mount $*" >> /tmp/mount.calls
exit 0
EOF
  printf '#!/bin/bash\nexit 0\n' > "$STUBS/umount"
  chmod +x "$STUBS/findmnt" "$STUBS/mount" "$STUBS/umount" "$STUBS/lsblk"
  rm -f /tmp/mount.calls
}
clear_fw_stubs () { rm -f "$STUBS/findmnt" "$STUBS/mount" "$STUBS/umount" "$STUBS/lsblk" "$STUBS/df"; }
why_prepare_failed () {
  [ "$PREPARE_RC" = 0 ] && return 0
  printf '   rc=%s, last output: %s\n' "$PREPARE_RC" "$(tail -3 /tmp/prepare.log | tr '\n' ' ' | cut -c1-170)"
}

rm -f /dev/mmcblk9p2 /dev/sdz2
mknod /dev/mmcblk9p2 b 7 201 2> /dev/null || true
mknod /dev/sdz2 b 7 202 2> /dev/null || true

prep_fw_case /dev/mmcblk9p1 "exit 1"
run_prepare /tmp/fwmnt /tmp/single.conf
clear_fw_stubs
why_prepare_failed
assert_eq "$PREPARE_RC" 0 "a card reader device, mmcblk9p1, works"
assert_grep "mounted /dev/teslausb-rootfs" /tmp/prepare.log "and it finds the root filesystem"
assert_grep "firmware partition" /tmp/prepare.log "recognising this is not DietPi's own /boot"
assert_grep "probe .*-o ro" /tmp/mount.calls "by examining the partitions rather than guessing"
assert_file /tmp/fwmnt/teslausb_setup_variables.conf \
  "teslausb's config stays on the partition /teslausb will point at"
assert_no_file /tmp/fwmnt/Automation_Custom_Script.sh \
  "while DietPi's hook does not, since DietPi never reads there"

# The reversed arrangement: DietPi's root comes first and the partition a PC sees is
# the small trailing DIETPISETUP one. Partition arithmetic gets this backwards.
FAKE_PARTS="/dev/teslausb-rootfs /dev/sdz2" prep_fw_case /dev/sdz2 "exit 1"
FAKE_PARTS="/dev/teslausb-rootfs /dev/sdz2" run_prepare /tmp/fwmnt /tmp/single.conf
clear_fw_stubs
assert_eq "$PREPARE_RC" 0 "a trailing DIETPISETUP partition works too"
assert_grep "mounted /dev/teslausb-rootfs" /tmp/prepare.log \
  "finding the root filesystem before it, which arithmetic would have missed"

start_case "a card with no DietPi root filesystem on it is refused"
# Pointing the script at a partition on some unrelated disk should stop it, not have
# it write DietPi's config somewhere arbitrary.
FAKE_PARTS="/dev/not-a-dietpi-disk" prep_fw_case /dev/mmcblk9p1 "exit 1"
FAKE_PARTS="/dev/not-a-dietpi-disk" run_prepare /tmp/fwmnt /tmp/single.conf
clear_fw_stubs
assert_eq "$PREPARE_RC" 1 "exits 1"
assert_grep "could not find DietPi's root filesystem" /tmp/prepare.log "and says what it looked for"

start_case "a root filesystem that is already mounted is used as it is"
prep_fw_case /dev/mmcblk9p1 "echo /tmp/alreadymounted"
rm -rf /tmp/alreadymounted && mkdir -p /tmp/alreadymounted/boot/dietpi
cp /tmp/bootfs/dietpi.txt /tmp/alreadymounted/boot/dietpi.txt
run_prepare /tmp/fwmnt /tmp/single.conf
clear_fw_stubs
assert_eq "$PREPARE_RC" 0 "exits 0"
assert_grep "already mounted at /tmp/alreadymounted" /tmp/prepare.log "says it is reusing the mount"
assert_grep "^AUTO_SETUP_AUTOMATED=1$" /tmp/alreadymounted/boot/dietpi.txt "and writes there"
rw_mounts=$(grep -v -- "-o ro" /tmp/mount.calls 2> /dev/null | grep -c . || true)
assert_eq "${rw_mounts:-0}" 0 "probing read-only but never mounting it read-write itself"

start_case "a root filesystem that will not mount is a clear refusal"
prep_fw_case /dev/mmcblk9p1 "exit 1"
MOUNT_FAILS=1 run_prepare /tmp/fwmnt /tmp/single.conf
clear_fw_stubs
assert_eq "$PREPARE_RC" 1 "exits 1"
assert_grep "could not mount" /tmp/prepare.log "and says so"
assert_grep "needs root, and a Linux machine" /tmp/prepare.log "explaining why it might have failed"

start_case "a root filesystem too small for DietPi's own upgrade is called out"
prep_fw_case /dev/mmcblk9p1 "exit 1"
printf '#!/bin/bash\necho 1048576\n' > "$STUBS/df"   # 1GB, as the images ship
chmod +x "$STUBS/df"
run_prepare /tmp/fwmnt /tmp/single.conf
clear_fw_stubs
assert_eq "$PREPARE_RC" 0 "still finishes, since it is advice not a refusal"
assert_grep "root filesystem is only 1024MB" /tmp/prepare.log "reports the actual size"
assert_grep "resize2fs" /tmp/prepare.log "and gives the commands to grow it"

start_case "the console logs itself in, since a car has no keyboard"
# DietPi's first run only starts when something logs in, and its own autologin
# setting is documented as taking effect only from the second boot.
fake_boot_partition
mkdir -p /tmp/bootfs/../etc/systemd/system 2>/dev/null || true
run_prepare /tmp/bootfs /tmp/single.conf
autologin=$(dirname /tmp/bootfs)/etc/systemd/system/getty@tty1.service.d/teslausb-autologin.conf
if [ -f "$autologin" ]
then
  ok "an autologin drop-in is written"
  assert_grep "agetty --autologin root" "$autologin" "logging in as root on tty1"
  assert_eq "$(grep -c "^ExecStart=$" "$autologin")" 1 "clearing the inherited ExecStart first"
  case "$autologin" in
    *teslausb-autologin.conf) ok "named so DietPi's own failure handling does not delete it" ;;
    *) not_ok "the name would collide with DietPi's own drop-in" ;;
  esac
else
  not_ok "no autologin drop-in was written to $autologin"
fi

start_case "DietPi is stopped from expanding the root over teslausb's space"
marker=$(dirname /tmp/bootfs)/dietpi_skip_partition_resize
assert_file "$marker" "DietPi's own skip-resize marker is created"
printf 'mine\n' > "$marker"
run_prepare /tmp/bootfs /tmp/single.conf
assert_eq "$(cat "$marker")" mine "an existing marker is left alone"

start_case "a root filesystem too small to survive DietPi's own upgrade is called out"
assert_grep "root filesystem is only" "$REPO/tools/prepare-boot-partition.sh" \
  "the script warns about a small root filesystem"
assert_grep "resize2fs" "$REPO/tools/prepare-boot-partition.sh" \
  "and gives the command to grow it"

start_case "the timezone is set when asked for, and left alone when not"
fake_boot_partition
printf 'export SSID=net\nexport WIFIPASS=secret123\nexport TESLAUSB_TIMEZONE=America/Los_Angeles\n' > /tmp/tz.conf
run_prepare /tmp/bootfs /tmp/tz.conf
assert_grep "^AUTO_SETUP_TIMEZONE=America/Los_Angeles$" /tmp/bootfs/dietpi.txt "honours TESLAUSB_TIMEZONE"
fake_boot_partition
run_prepare /tmp/bootfs /tmp/single.conf
assert_eq "$(grep -c "^AUTO_SETUP_TIMEZONE=" /tmp/bootfs/dietpi.txt || true)" 0 \
  "writes nothing when the config does not ask"

start_case "anything staged beside the config is carried onto the card"
fake_boot_partition
rm -rf /tmp/withchime && mkdir -p /tmp/withchime/teslausb-cam-root
cp /tmp/single.conf /tmp/withchime/teslausb_setup_variables.conf
printf 'RIFFfake' > /tmp/withchime/teslausb-cam-root/LockChime.wav
run_prepare /tmp/bootfs /tmp/withchime/teslausb_setup_variables.conf
assert_file /tmp/bootfs/teslausb-cam-root/LockChime.wav "the lock chime is staged for the cam drive"
assert_eq "$(cat /tmp/bootfs/teslausb-cam-root/LockChime.wav)" RIFFfake "intact"

# ===========================================================================
banner "files staged for the root of the cam drive"
# ===========================================================================
# Tesla reads LockChime.wav from the root of the drive for its custom lock sound,
# and a Boombox folder for external speaker sounds. Those are just files on the
# drive, not anything teslausb manages, so rebuilding a card used to lose them and
# the car went back to its stock chime.
seed_fn=$(sed -n '/^function seed_cam_disk_root/,/^}/p' "$REPO/setup/pi/create-backingfiles.sh")

run_seed () {
  # stubs stand in for the loop device: mount succeeds and the copy lands in the
  # mountpoint, which is what the assertions then look at
  : > /tmp/seed.progress
  rm -rf /tmp/camseed /teslausb/teslausb-cam-root
  mkdir -p /tmp/camseed /teslausb/teslausb-cam-root
  "$@" # caller stages files
  ( # shellcheck disable=SC2329
    log_progress () { echo "$*" >> /tmp/seed.progress; }
    # shellcheck disable=SC2329
    first_partition_offset () { echo 4194304; }
    # shellcheck disable=SC2329
    losetup_find_show () { echo /dev/loop-test; }
    # shellcheck disable=SC2329
    losetup () { :; }
    # shellcheck disable=SC2329
    mount () { [ "${SEED_MOUNT_FAILS:-0}" = 1 ] && return 1; return 0; }
    # shellcheck disable=SC2329
    umount () { :; }
    # shellcheck disable=SC2329
    sync () { :; }
    eval "$seed_fn"
    seed_cam_disk_root /tmp/fake_cam_disk.bin
  ) && SEED_RC=0 || SEED_RC=$?
}

: > /tmp/fake_cam_disk.bin

start_case "nothing staged means nothing happens"
run_seed true
assert_eq "$SEED_RC" 0 "exits 0"
assert_eq "$(find /tmp/camseed -mindepth 1 | wc -l)" 0 "copies nothing"
assert_eq "$(grep -c . /tmp/seed.progress || true)" 0 "and says nothing"

start_case "a staged lock chime is put in the drive root"
run_seed sh -c 'printf RIFFfake > /teslausb/teslausb-cam-root/LockChime.wav'
assert_eq "$SEED_RC" 0 "exits 0"
assert_file /tmp/camseed/LockChime.wav "the chime lands in the root of the drive"
assert_eq "$(cat /tmp/camseed/LockChime.wav)" RIFFfake "with its contents intact"
assert_grep "put LockChime.wav in the root of the cam drive" /tmp/seed.progress "says what it did"

start_case "a Boombox folder comes across too, not just single files"
run_seed sh -c 'mkdir -p /teslausb/teslausb-cam-root/Boombox && echo beep > /teslausb/teslausb-cam-root/Boombox/horn.wav'
assert_eq "$(cat /tmp/camseed/Boombox/horn.wav 2>/dev/null)" beep "directories are copied recursively"

start_case "the resource forks a Mac leaves behind are ignored"
run_seed sh -c 'printf RIFFfake > /teslausb/teslausb-cam-root/LockChime.wav; printf junk > /teslausb/teslausb-cam-root/._LockChime.wav'
assert_file /tmp/camseed/LockChime.wav "the real file is copied"
assert_no_file /tmp/camseed/._LockChime.wav "the ._ fork is not"

start_case "a chime already on the drive is left alone"
run_seed sh -c 'printf new > /teslausb/teslausb-cam-root/LockChime.wav'
printf 'existing' > /tmp/camseed/LockChime.wav
( # shellcheck disable=SC2329
  log_progress () { echo "$*" >> /tmp/seed.progress; }
  # shellcheck disable=SC2329
  first_partition_offset () { echo 4194304; }
  # shellcheck disable=SC2329
  losetup_find_show () { echo /dev/loop-test; }
  # shellcheck disable=SC2329
  losetup () { :; }
  # shellcheck disable=SC2329
  mount () { return 0; }
  # shellcheck disable=SC2329
  umount () { :; }
  # shellcheck disable=SC2329
  sync () { :; }
  eval "$seed_fn"
  seed_cam_disk_root /tmp/fake_cam_disk.bin
) > /dev/null 2>&1
assert_eq "$(cat /tmp/camseed/LockChime.wav)" existing "a car given a different chime keeps it"
assert_grep "already on the drive" /tmp/seed.progress "and says so"

start_case "a drive that cannot be mounted is reported, not ignored"
run_seed sh -c 'SEED_MOUNT_FAILS=1; printf x > /teslausb/teslausb-cam-root/LockChime.wav'
SEED_MOUNT_FAILS=1 run_seed sh -c 'printf x > /teslausb/teslausb-cam-root/LockChime.wav'
assert_eq "$SEED_RC" 0 "setup carries on"
assert_grep "WARNING: could not mount" /tmp/seed.progress "with a warning"

start_case "and a missing image is not fatal either"
run_seed sh -c 'printf x > /teslausb/teslausb-cam-root/LockChime.wav'
( # shellcheck disable=SC2329
  log_progress () { echo "$*" >> /tmp/seed.progress; }
  eval "$seed_fn"
  seed_cam_disk_root /tmp/definitely-not-here.bin
) > /dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" 0 "exits 0"
assert_grep "no cam drive to seed" /tmp/seed.progress "says there was nothing to seed"
rm -rf /teslausb/teslausb-cam-root /tmp/camseed /tmp/fake_cam_disk.bin

start_case "the seeding runs when the cam drive is made"
assert_grep "seed_cam_disk_root" "$REPO/setup/pi/create-backingfiles.sh" "create-backingfiles calls it"

# ===========================================================================
banner "the name the device answers to"
# ===========================================================================
# The hostname doubles as the mDNS name, because avahi publishes <hostname>.local,
# which is what makes teslausb.local work out of the box. TESLAUSB_MDNS_NAME lets
# the advertised name differ from the machine's own name.
name_fns=$(sed -n '/^function valid_host_label/,/^}/p;/^function configure_mdns_name/,/^}/p' \
  "$REPO/setup/pi/setup-teslausb")

start_case "what counts as a usable name"
( eval "$name_fns"
  for good in teslausb teslausb-Model3 dashcam a a1 "$(printf 'a%.0s' {1..63})"
  do valid_host_label "$good" || { echo "rejected '$good'" > /tmp/label.bad; exit 1; }
  done
  for bad in "" "-teslausb" "teslausb-" "tesla usb" "tesla_usb" "tesla.usb" "$(printf 'a%.0s' {1..64})"
  do valid_host_label "$bad" && { echo "accepted '$bad'" > /tmp/label.bad; exit 1; }
  done
  exit 0 ) && rc=0 || rc=1
assert_eq "$rc" 0 "accepts DNS labels and refuses the rest${rc:+ ($(cat /tmp/label.bad 2>/dev/null))}"
rm -f /tmp/label.bad

run_mdns () {
  # $1: TESLAUSB_MDNS_NAME, $2: starting avahi-daemon.conf content
  : > /tmp/mdns.progress
  rm -f /tmp/systemctl.calls
  mkdir -p /etc/avahi
  printf '%s\n' "$2" > /etc/avahi/avahi-daemon.conf
  printf '#!/bin/bash\necho "systemctl $*" >> /tmp/systemctl.calls\nexit 0\n' > "$STUBS/systemctl"
  chmod +x "$STUBS/systemctl"
  (
    # shellcheck disable=SC2329
    setup_progress () { echo "$*" >> /tmp/mdns.progress; }
    export TESLAUSB_MDNS_NAME="$1"
    eval "$name_fns"
    configure_mdns_name
  ) && MDNS_RC=0 || MDNS_RC=$?
}

start_case "an unset name leaves avahi alone, so .local follows the hostname"
run_mdns "" "[server]"
assert_eq "$MDNS_RC" 0 "exits 0"
assert_eq "$(grep -c "host-name" /etc/avahi/avahi-daemon.conf || true)" 0 "writes no host-name"
assert_no_file /tmp/systemctl.calls "does not restart avahi"

start_case "a name is added to a config that has none"
run_mdns dashcam "[server]
use-ipv6=no"
assert_eq "$MDNS_RC" 0 "exits 0"
assert_grep "^host-name=dashcam$" /etc/avahi/avahi-daemon.conf "sets the advertised name"
assert_grep "^use-ipv6=no$" /etc/avahi/avahi-daemon.conf "leaves the rest of the section alone"
assert_grep "restart avahi-daemon" /tmp/systemctl.calls "restarts avahi so it takes effect"
assert_grep "dashcam.local" /tmp/mdns.progress "says what the device now answers to"

start_case "and replaces one that is already there, commented or not"
run_mdns dashcam "[server]
#host-name=foo"
assert_grep "^host-name=dashcam$" /etc/avahi/avahi-daemon.conf "replaces a commented example"
assert_eq "$(grep -c "host-name" /etc/avahi/avahi-daemon.conf)" 1 "without leaving a duplicate"
run_mdns newname "[server]
host-name=oldname"
assert_grep "^host-name=newname$" /etc/avahi/avahi-daemon.conf "replaces a previous name"
assert_eq "$(grep -c "host-name" /etc/avahi/avahi-daemon.conf)" 1 "without leaving a duplicate"

start_case "setting the same name again changes nothing"
run_mdns dashcam "[server]
host-name=dashcam"
assert_grep "already the .local name\|already " /tmp/mdns.progress "notices it is already set"
assert_no_file /tmp/systemctl.calls "so avahi is not restarted"

start_case "an unusable name is refused rather than written"
run_mdns "not a name" "[server]"
assert_eq "$MDNS_RC" 0 "carries on rather than failing setup"
assert_eq "$(grep -c "host-name" /etc/avahi/avahi-daemon.conf || true)" 0 "writes nothing"
assert_grep "not a usable name" /tmp/mdns.progress "says why"

start_case "the boot partition refuses bad names before first boot"
for bad in "tesla usb" "-nope" "under_score"; do
  fake_boot_partition
  printf 'export TESLAUSB_HOSTNAME=%s\n' "'$bad'" > /tmp/badname.conf
  run_prepare /tmp/bootfs /tmp/badname.conf
  assert_eq "$PREPARE_RC" 1 "refuses hostname '$bad'"
  # run_prepare puts the script's output here
  assert_grep "not a usable name" /tmp/prepare.log "and says why for '$bad'"
done
fake_boot_partition
printf 'export TESLAUSB_HOSTNAME=teslausb-Model3\nexport TESLAUSB_MDNS_NAME=dashcam\n' > /tmp/goodname.conf
run_prepare /tmp/bootfs /tmp/goodname.conf
assert_eq "$PREPARE_RC" 0 "accepts a valid pair"
assert_grep "AUTO_SETUP_NET_HOSTNAME=teslausb-Model3" /tmp/bootfs/dietpi.txt "and passes the hostname to DietPi"

# ===========================================================================
banner "the image architecture advisory"
# ===========================================================================
# DietPi ships one image per instruction set and which one suits a board is not
# obvious: the ARMv7 image is for the Pi 2 Model B v1.1 only, while every 64-bit
# capable board, the Pi Zero 2 W included, is meant to use ARMv8. The ARMv6 image
# boots on all of them, so a poor choice runs rather than failing. teslausb works
# either way, so this advises and never blocks.
arch_fn=$(sed -n '/^function check_image_architecture/,/^}/p' "$REPO/setup/pi/verify-configuration.sh")

run_arch_check () {
  # $1: device tree model, $2: dpkg architecture
  # created empty rather than removed, so "said nothing" is countable
  : > /tmp/arch.progress
  mkdir -p /tmp/fakedt
  printf '%s\0' "$1" > /tmp/fakedt/model
  printf '#!/bin/bash\necho "%s"\n' "$2" > "$STUBS/dpkg"
  chmod +x "$STUBS/dpkg"
  (
    # shellcheck disable=SC2329
    setup_progress () { echo "$*" >> /tmp/arch.progress; }
    # both references to the device tree path, not just the first
    eval "${arch_fn//\/sys\/firmware\/devicetree\/base\/model//tmp/fakedt/model}"
    check_image_architecture
  ) && ARCH_RC=0 || ARCH_RC=$?
  rm -f "$STUBS/dpkg"
}

start_case "a 32-bit image on a 64-bit capable board is flagged"
for model in "Raspberry Pi Zero 2 W Rev 1.0" "Raspberry Pi 4 Model B Rev 1.4" "Raspberry Pi 3 Model B Plus Rev 1.3" "Raspberry Pi 400 Rev 1.0"
do
  run_arch_check "$model" armhf
  assert_eq "$ARCH_RC" 0 "advises without failing on '$model'"
  assert_grep "DietPi recommends DietPi_RPi234-ARMv8" /tmp/arch.progress "names the image DietPi recommends for '$model'"
done

start_case "and the Pi 5 gets its own image named"
run_arch_check "Raspberry Pi 5 Model B Rev 1.0" armhf
assert_grep "DietPi recommends DietPi_RPi5-ARMv8" /tmp/arch.progress "points at the Pi 5 image"

start_case "a 64-bit image on those boards says so and stops there"
run_arch_check "Raspberry Pi Zero 2 W Rev 1.0" arm64
assert_eq "$ARCH_RC" 0 "exits 0"
assert_grep "running the 64-bit userland DietPi recommends" /tmp/arch.progress "confirms the choice"
assert_eq "$(grep -c "NOTE:" /tmp/arch.progress || true)" 0 "and advises nothing"

start_case "ARMv6 boards are left alone, having no 64-bit option"
for model in "Raspberry Pi Zero W Rev 1.1" "Raspberry Pi Model B Plus Rev 1.2"
do
  run_arch_check "$model" armhf
  assert_eq "$ARCH_RC" 0 "exits 0 for '$model'"
  assert_eq "$(grep -c . /tmp/arch.progress || true)" 0 "says nothing about '$model'"
done

start_case "and so is hardware it knows nothing about"
run_arch_check "ROCK Pi 4C Plus" arm64
assert_eq "$(grep -c . /tmp/arch.progress || true)" 0 "no advice for a non-Pi board"

# ===========================================================================
banner "the access point is built on hostapd, not NetworkManager"
# ===========================================================================
# DietPi manages the client connection with ifupdown and wpa_supplicant. The
# access point rides on a second virtual interface on the same radio, run by
# hostapd and dnsmasq, so nothing has to be handed to another network manager and
# no reboot is needed to finish. A device in a car that comes back from that
# reboot without wifi is unreachable, which is the opposite of the point.

run_configure_ap () {
  # $1..: environment assignments for the run, e.g. AP_SSID=x
  rm -rf /tmp/aproot
  mkdir -p /tmp/aproot/etc/hostapd /tmp/aproot/etc/dnsmasq.d /tmp/aproot/etc/systemd/system \
           /tmp/aproot/usr/local/bin /tmp/aproot/run
  rm -f /tmp/systemctl.calls /tmp/apt.calls /tmp/ap.progress
  printf '#!/bin/bash\necho "systemctl $*" >> /tmp/systemctl.calls\nexit 0\n' > "$STUBS/systemctl"
  printf '#!/bin/bash\necho "apt-get $*" >> /tmp/apt.calls\nexit 0\n' > "$STUBS/apt-get"
  chmod +x "$STUBS/systemctl" "$STUBS/apt-get"
  # Redirect the absolute paths the script writes into a sandbox, so the test does
  # not scribble on the container.
  sed -e 's|=/etc/|=/tmp/aproot/etc/|g' \
      -e 's|=/usr/local/bin/|=/tmp/aproot/usr/local/bin/|' \
      -e 's|=/run/|=/tmp/aproot/run/|' \
      -e 's|mkdir -p /etc/hostapd /etc/dnsmasq.d|mkdir -p /tmp/aproot/etc/hostapd /tmp/aproot/etc/dnsmasq.d|' \
      "$REPO/setup/pi/configure-ap.sh" > /tmp/configure-ap-sandboxed.sh
  chmod +x /tmp/configure-ap-sandboxed.sh
  ( env "$@" /tmp/configure-ap-sandboxed.sh > /tmp/ap.progress 2>&1 ) && AP_RC=0 || AP_RC=$?
}

start_case "it refuses a configuration that would not work"
run_configure_ap AP_PASS=longenough
assert_eq "$AP_RC" 1 "no AP_SSID: exits 1"
run_configure_ap AP_SSID=teslausb AP_PASS=short
assert_eq "$AP_RC" 1 "too short a passphrase: exits 1"
run_configure_ap AP_SSID=teslausb AP_PASS=password
assert_eq "$AP_RC" 1 "the example passphrase: exits 1"

start_case "it writes a hostapd configuration for the virtual interface"
run_configure_ap AP_SSID='Tesla Cam' AP_PASS=drivefast99 AP_IP=192.168.66.1 WIFI_COUNTRY=NL
assert_eq "$AP_RC" 0 "exits 0"
conf=/tmp/aproot/etc/hostapd/teslausb-ap.conf
assert_grep "^interface=ap0$" "$conf" "runs on ap0, leaving the client interface alone"
assert_grep "^ssid=Tesla Cam$" "$conf" "carries the SSID verbatim, spaces and all"
assert_grep "^wpa_passphrase=drivefast99$" "$conf" "carries the passphrase"
assert_grep "^wpa=2$" "$conf" "WPA2"
assert_grep "^rsn_pairwise=CCMP$" "$conf" "CCMP rather than the weaker TKIP"
assert_grep "^country_code=NL$" "$conf" "honours WIFI_COUNTRY, upper cased"
assert_grep "^ieee80211d=1$" "$conf" "and obeys the regulatory domain when one is known"
assert_eq "$(stat -c %a "$conf")" 600 "the passphrase is not world readable"

start_case "and a dnsmasq configuration that only serves the access point"
dconf=/tmp/aproot/etc/dnsmasq.d/teslausb-ap.conf
assert_grep "^interface=ap0$" "$dconf" "bound to ap0"
assert_grep "^bind-dynamic$" "$dconf" "bind-dynamic, since ap0 appears later than dnsmasq starts"
assert_grep "^dhcp-range=192.168.66.50,192.168.66.150" "$dconf" "hands out addresses in the AP_IP subnet"
assert_grep "option:router,192.168.66.1" "$dconf" "points clients at the device as their router"
assert_grep "^dhcp-leasefile=/mutable/" "$dconf" "keeps leases off the read-only root"
if command -v dnsmasq > /dev/null
then
  dnsmasq --test -C "$dconf" > /tmp/dnsmasq.test 2>&1 && dt=0 || dt=1
  assert_eq "$dt" 0 "dnsmasq itself accepts the file"
fi

start_case "the country code defaults to US, never the placeholder hostapd rejects"
# DietPi's own hotspot writes country_code=00 and hostapd then refuses to start:
# "Invalid country_code '00'".
run_configure_ap AP_SSID=teslausb AP_PASS=drivefast99
assert_grep "^country_code=US$" /tmp/aproot/etc/hostapd/teslausb-ap.conf \
  "US when WIFI_COUNTRY is unset"
run_configure_ap AP_SSID=teslausb AP_PASS=drivefast99 WIFI_COUNTRY=00
assert_grep "^country_code=US$" /tmp/aproot/etc/hostapd/teslausb-ap.conf \
  "and US instead of the 00 placeholder"
run_configure_ap AP_SSID=teslausb AP_PASS=drivefast99 WIFI_COUNTRY=us
assert_grep "^country_code=US$" /tmp/aproot/etc/hostapd/teslausb-ap.conf "a lower case country is accepted"

start_case "a different AP_IP moves the whole subnet"
run_configure_ap AP_SSID=teslausb AP_PASS=drivefast99 AP_IP=10.42.7.1
assert_grep "^dhcp-range=10.42.7.50,10.42.7.150" /tmp/aproot/etc/dnsmasq.d/teslausb-ap.conf \
  "the pool follows AP_IP"
assert_grep "option:router,10.42.7.1" /tmp/aproot/etc/dnsmasq.d/teslausb-ap.conf "so does the router option"

start_case "the service brings the interface up before hostapd"
unit=/tmp/aproot/etc/systemd/system/teslausb-ap.service
up=/tmp/aproot/usr/local/bin/teslausb-ap-up
assert_grep "ExecStartPre=.*teslausb-ap-up" "$unit" "creates the interface first"
assert_grep "ExecStart=/usr/sbin/hostapd .*/run/teslausb-ap.conf" "$unit" "hostapd reads the generated config"
assert_grep "Restart=always" "$unit" "comes back if the client changes channel"
assert_grep "interface add ap0 type __ap" "$up" "adds ap0 to the client's radio"
assert_grep "set power_save off" "$up" "stops either interface sleeping on a shared radio"
assert_grep "install -m 600" "$up" "generates the runtime config on tmpfs, for a read-only root"
assert_grep "MASQUERADE" "$up" "gives access point clients a route out, as shared mode did"
assert_grep "systemctl enable teslausb-ap.service" /tmp/systemctl.calls "enables the service"
assert_grep "install iw hostapd dnsmasq" /tmp/apt.calls "installs what it needs"
assert_eq "$(grep -c "nmcli\|network-manager" "$REPO/setup/pi/configure-ap.sh" || true)" 0 \
  "NetworkManager is not used at all"

start_case "the channel maths matches the client's frequency"
# Both interfaces share one radio and cannot be on two channels, so the access
# point has to follow whatever the client associated on.
chan_from_freq () {
  local freq="$1"
  if [ "$freq" -ge 5000 ]
  then echo $(( (freq - 5000) / 5 ))
  else echo $(( (freq - 2407) / 5 ))
  fi
}
assert_eq "$(chan_from_freq 2412)" 1 "2412 MHz is channel 1"
assert_eq "$(chan_from_freq 2437)" 6 "2437 MHz is channel 6"
assert_eq "$(chan_from_freq 2462)" 11 "2462 MHz is channel 11"
assert_eq "$(chan_from_freq 5180)" 36 "5180 MHz is channel 36"
assert_grep 'freq - 2407' "$up" "the script does the 2.4GHz maths this way"
assert_grep 'freq - 5000' "$up" "and the 5GHz maths this way"

start_case "setup no longer hands the network to NetworkManager"
assert_eq "$(grep -c "ensure_networkmanager_for_ap" "$REPO/setup/pi/setup-teslausb" || true)" 0 \
  "the handover, and its reboot, are gone"

# ===========================================================================
banner "openssh replaces dropbear"
# ===========================================================================
# DietPi ships dropbear. teslausb needs OpenSSH, because its rsync archive backend
# shells out to ssh and dropbear provides dbclient instead.
openssh_fn=$(sed -n '/^function dietpi_software/,/^}/p;/^function package_installed/,/^}/p;/^function ensure_openssh/,/^}/p' \
  "$REPO/setup/pi/setup-teslausb")

run_ensure_openssh () {
  # $1: openssh-server installed already, $2: dropbear-bin installed already
  rm -f /tmp/apt.calls /tmp/systemctl.calls /tmp/dietpi-software.calls /tmp/openssh.progress \
        /tmp/openssh.installed /tmp/dropbear.purged
  # The stubs carry state, so the function sees the world change as it acts: after
  # it installs openssh-server, dpkg-query reports it installed. $3 = "fail" makes
  # the install fail, to exercise the give-up path.
  cat > "$STUBS/dpkg-query" <<EOF
#!/bin/bash
case "\$*" in
  *openssh-server*)
    if [ "$1" = yes ] || [ -f /tmp/openssh.installed ]
    then echo "install ok installed"
    else echo "unknown ok not-installed"
    fi
    ;;
  *dropbear-bin*)
    if [ "$2" = yes ] && [ ! -f /tmp/dropbear.purged ]
    then echo "install ok installed"
    else echo "unknown ok not-installed"
    fi
    ;;
  *) echo "unknown ok not-installed" ;;
esac
exit 0
EOF
  cat > "$STUBS/apt-get" <<EOF
#!/bin/bash
echo "apt-get \$*" >> /tmp/apt.calls
case "\$*" in
  *"install openssh-server"*) [ "${3:-}" = fail ] || touch /tmp/openssh.installed ;;
  *"purge dropbear"*)         touch /tmp/dropbear.purged ;;
esac
exit 0
EOF
  printf '#!/bin/bash\necho "systemctl $*" >> /tmp/systemctl.calls\nexit 0\n' > "$STUBS/systemctl"
  printf '#!/bin/bash\nexit 1\n' > "$STUBS/pgrep"
  # The container has a DietPi layout, so ensure_openssh finds dietpi-software and
  # calls it. Stub it, both to record the call and to keep the real one from
  # waiting on input.
  mkdir -p /boot/dietpi
  printf '#!/bin/bash\necho "dietpi-software $*" >> /tmp/dietpi-software.calls\nexit 0\n' > /boot/dietpi/dietpi-software
  chmod +x /boot/dietpi/dietpi-software
  chmod +x "$STUBS/dpkg-query" "$STUBS/apt-get" "$STUBS/systemctl" "$STUBS/pgrep"
  (
    # called by the extracted function, which shellcheck cannot see
    # shellcheck disable=SC2329
    setup_progress () { echo "$*" >> /tmp/openssh.progress; }
    eval "$openssh_fn"
    ensure_openssh
  ) && ENSURE_RC=0 || ENSURE_RC=$?
  rm -f "$STUBS/dpkg-query" "$STUBS/pgrep"
}

start_case "dropbear is replaced when it is the installed server"
run_ensure_openssh no yes
assert_eq "$ENSURE_RC" 0 "exits 0"
assert_grep "install openssh-server" /tmp/apt.calls "installs openssh-server"
assert_grep "purge dropbear" /tmp/apt.calls "purges dropbear"
assert_grep "disable --now dropbear" /tmp/systemctl.calls "stops dropbear before openssh binds port 22"
assert_grep "enable ssh" /tmp/systemctl.calls "enables the openssh service"
assert_grep "in place of dropbear" /tmp/openssh.progress "says what it is doing"
assert_grep "install 105" /tmp/dietpi-software.calls "asks DietPi for OpenSSH (105)"
assert_grep "uninstall 104" /tmp/dietpi-software.calls "and tells it dropbear (104) is gone"

start_case "and it does nothing when openssh is already alone"
run_ensure_openssh yes no
assert_eq "$ENSURE_RC" 0 "exits 0"
assert_no_file /tmp/apt.calls "installs nothing"
assert_grep "already the only ssh server" /tmp/openssh.progress "says so"

start_case "openssh is still ensured when both are installed"
run_ensure_openssh yes yes
assert_grep "purge dropbear" /tmp/apt.calls "purges dropbear"

start_case "it gives up loudly if openssh cannot be installed"
run_ensure_openssh no yes fail
assert_eq "$ENSURE_RC" 1 "exits 1 rather than carrying on without an ssh server"
assert_grep "STOP: could not install openssh-server" /tmp/openssh.progress "says why"

start_case "a dietpi-software that never returns cannot stall setup"
# dietpi-software waits indefinitely in an environment without systemd. An
# interrupted test run left five of them running for hours, each stuck on
# "uninstall 104", so every call now has a closed stdin and a deadline.
assert_grep "timeout .*DIETPI_SOFTWARE_TIMEOUT" "$REPO/setup/pi/setup-teslausb" \
  "the calls are bounded by a timeout"
assert_grep "< /dev/null" "$REPO/setup/pi/setup-teslausb" "and cannot wait on input"
assert_eq "$(grep -c "^ *dietpi_software " "$REPO/setup/pi/make-root-fs-readonly.sh")" 2 \
  "the readonly script's two calls go through the same helper"

rm -f /tmp/apt.calls /tmp/systemctl.calls /tmp/openssh.progress /tmp/openssh.installed /tmp/dropbear.purged
printf '#!/bin/bash\nsleep 300\n' > /boot/dietpi/dietpi-software
chmod +x /boot/dietpi/dietpi-software
started=$(date +%s)
run_ensure_openssh_hanging () {
  cat > "$STUBS/dpkg-query" <<'DQ'
#!/bin/bash
case "$*" in
  *openssh-server*) [ -f /tmp/openssh.installed ] && echo "install ok installed" || echo "unknown ok not-installed" ;;
  *dropbear-bin*)   [ -f /tmp/dropbear.purged ] && echo "unknown ok not-installed" || echo "install ok installed" ;;
  *) echo "unknown ok not-installed" ;;
esac
exit 0
DQ
  cat > "$STUBS/apt-get" <<'AG'
#!/bin/bash
echo "apt-get $*" >> /tmp/apt.calls
case "$*" in
  *"install openssh-server"*) touch /tmp/openssh.installed ;;
  *"purge dropbear"*)         touch /tmp/dropbear.purged ;;
esac
exit 0
AG
  printf '#!/bin/bash\necho "systemctl $*" >> /tmp/systemctl.calls\nexit 0\n' > "$STUBS/systemctl"
  printf '#!/bin/bash\nexit 1\n' > "$STUBS/pgrep"
  chmod +x "$STUBS/dpkg-query" "$STUBS/apt-get" "$STUBS/systemctl" "$STUBS/pgrep"
  (
    # shellcheck disable=SC2329
    setup_progress () { echo "$*" >> /tmp/openssh.progress; }
    export DIETPI_SOFTWARE_TIMEOUT=2
    eval "$openssh_fn"
    ensure_openssh
  ) && HANG_RC=0 || HANG_RC=$?
  rm -f "$STUBS/dpkg-query" "$STUBS/pgrep"
}
run_ensure_openssh_hanging
elapsed=$(( $(date +%s) - started ))
assert_eq "$HANG_RC" 0 "it still finishes"
if [ "$elapsed" -lt 60 ]
then ok "and gives up on dietpi-software quickly (${elapsed}s, not the 300s it was sleeping)"
else not_ok "it waited ${elapsed}s for a hanging dietpi-software"
fi
assert_grep "install openssh-server" /tmp/apt.calls "falls back to apt for the install"
assert_grep "purge dropbear" /tmp/apt.calls "and still removes dropbear"
assert_grep "WARNING: dietpi-software could not" /tmp/openssh.progress "and says dietpi-software did not manage it"
if pgrep -f "[d]ietpi-software" > /dev/null
then not_ok "a dietpi-software process was left behind"
else ok "no dietpi-software process is left behind"
fi

start_case "the boot partition asks DietPi for openssh, never dropbear"
assert_grep "set_dietpi_key AUTO_SETUP_SSH_SERVER_INDEX -2" "$REPO/tools/prepare-boot-partition.sh" \
  "forces the OpenSSH index"
assert_eq "$(grep -c 'AUTO_SETUP_SSH_SERVER_INDEX=-2' "$REPO/dietpi/dietpi.txt.sample")" 1 \
  "and the shipped sample asks for it too"

# ===========================================================================
banner "the package list covers what DietPi does not ship"
# ===========================================================================
start_case "an ssh client is installed for rsync archiving"
# DietPi ships dropbear, which gives dbclient but not ssh, ssh-keygen or
# ssh-keyscan. teslausb's rsync backend is rsync over ssh and its reachability
# check falls back to "ssh user@host exit", so without openssh-client archiving
# fails with "ssh: command not found".
assert_grep "^  openssh-client$" "$REPO/setup/pi/setup-teslausb" "openssh-client is in TESLAUSB_PACKAGES"
assert_grep "^  rsync$" "$REPO/setup/pi/setup-teslausb" "and rsync itself"

start_case "the archive backends that need helpers have them"
assert_grep "^  cifs-utils$\|apt-get -y install hping3 cifs-utils" \
  "$REPO/run/cifs_archive/verify-and-configure-archive.sh" "cifs-utils is installed for the cifs backend"

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

banner "the clock is stepped when a client network comes up"
# ===========================================================================
# There is no RTC on this hardware, so at boot the clock holds whatever
# fake-hwclock saved at the last shutdown, and the device boots whenever the car
# wakes. ntpsec disciplines rather than steps, so anything logged before it
# catches up carries a stale timestamp and archiveloop.log reads out of order.
# This runs the real if-up.d hook in the container, with the time tools stubbed.

timesync_env () {
  rm -rf /tmp/tsroot
  mkdir -p /tmp/tsroot/bin
  cat > /tmp/tsroot/bin/sntp <<'EOF'
#!/bin/bash
echo "sntp $*" >> /tmp/tsroot/calls
exit "${SNTP_RC:-0}"
EOF
  cat > /tmp/tsroot/bin/ntpdig <<'EOF'
#!/bin/bash
echo "ntpdig $*" >> /tmp/tsroot/calls
exit "${NTPDIG_RC:-1}"
EOF
  cat > /tmp/tsroot/bin/timeout <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
  cat > /tmp/tsroot/bin/logger <<'EOF'
#!/bin/bash
echo "$*" >> /tmp/tsroot/logger
EOF
  chmod +x /tmp/tsroot/bin/*
  : > /tmp/tsroot/calls
  : > /tmp/tsroot/logger
}

run_timesync () {
  # $1 iface, $2 mode
  ( PATH="/tmp/tsroot/bin:$PATH" \
    IFACE="$1" MODE="$2" \
    TESLAUSB_TIMESYNC_FOREGROUND=1 \
    SYNC_LOG=/tmp/tsroot/synclog \
    trace_bash "$REPO/run/teslausb-timesync.sh" ) > /tmp/tsroot/out 2>&1
  TS_RC=$?
}

start_case "a client interface coming up steps the clock"
timesync_env
run_timesync wlan0 start
assert_eq "$TS_RC" 0 "exits 0"
assert_grep "sntp -S time.google.com" /tmp/tsroot/calls "stepped with -S, not slewed"
assert_grep "stepped the clock" /tmp/tsroot/logger "recorded that it happened"

start_case "the access point interface is ignored"
# ap0 coming up says nothing about reaching the internet.
timesync_env
run_timesync ap0 start
assert_eq "$TS_RC" 0 "exits 0"
assert_eq "$(wc -c < /tmp/tsroot/calls)" 0 "no time server was contacted"

start_case "loopback and an empty interface are ignored"
timesync_env
run_timesync lo start
assert_eq "$(wc -c < /tmp/tsroot/calls)" 0 "lo: nothing contacted"
timesync_env
run_timesync "" start
assert_eq "$(wc -c < /tmp/tsroot/calls)" 0 "empty IFACE: nothing contacted"

start_case "an interface going down is ignored"
timesync_env
run_timesync wlan0 stop
assert_eq "$(wc -c < /tmp/tsroot/calls)" 0 "MODE=stop: nothing contacted"

start_case "it falls through tools and servers, and never breaks ifup"
timesync_env
( export SNTP_RC=1 NTPDIG_RC=0; run_timesync wlan0 start )
timesync_env
SNTP_RC=1 NTPDIG_RC=0 run_timesync wlan0 start
assert_grep "ntpdig -S" /tmp/tsroot/calls "tries ntpdig when sntp fails"
timesync_env
SNTP_RC=1 NTPDIG_RC=1 run_timesync wlan0 start
assert_eq "$TS_RC" 0 "exits 0 even when every server fails"
assert_grep "129.6.15.28" /tmp/tsroot/calls "moved on to the second server"
assert_grep "could not reach a time server" /tmp/tsroot/logger "said so"

start_case "by default it syncs in the background, so ifup is not held up"
# ifupdown runs these hooks synchronously. A reachable but slow time server would
# otherwise delay bringing the network up, so the default path forks.
timesync_env
( PATH="/tmp/tsroot/bin:$PATH" IFACE=wlan0 MODE=start \
  SYNC_LOG=/tmp/tsroot/synclog \
  trace_bash "$REPO/run/teslausb-timesync.sh" ) > /tmp/tsroot/out 2>&1
assert_eq "$?" 0 "returns immediately with 0"
for _ in 1 2 3 4 5 6 7 8 9 10
do
  [ -s /tmp/tsroot/calls ] && break
  sleep 1
done
assert_grep "sntp -S" /tmp/tsroot/calls "the background job still did the work"
rm -rf /tmp/tsroot

banner "the login tip points at a name that resolves"
# ===========================================================================
# avahi publishes <host-name>.local, which is not always the system hostname: a
# device whose hostname is Kevster-TeslaUSB can answer only to teslausb.local, and
# the tip used to print the hostname, sending people to a name with no record.

url_env () {
  rm -rf /tmp/urlroot
  mkdir -p /tmp/urlroot/bin
  cat > /tmp/urlroot/bin/hostname <<EOF
#!/bin/bash
case "\${1:-}" in
  -s) echo "$1" ;;
  -I) echo "$2" ;;
  *)  echo "$1" ;;
esac
EOF
  chmod +x /tmp/urlroot/bin/hostname
  if [ -n "${3:-}" ]
  then
    printf '%s' "$3" > /tmp/urlroot/avahi.conf
    URL_CONF=/tmp/urlroot/avahi.conf
  else
    URL_CONF=/nonexistent
  fi
}

run_url () {
  ( PATH="/tmp/urlroot/bin:$PATH" AVAHI_CONF="$URL_CONF" \
    trace_bash "$REPO/run/teslausb-url.sh" )
}

start_case "the avahi name wins over the system hostname"
url_env "Kevster-TeslaUSB" "192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')"
out=$(run_url)
assert_eq "$out" "http://teslausb.local or http://192.168.68.101" "prints the resolvable name"
if grep -q Kevster <<< "$out"
then not_ok "does not offer the hostname, which has no record"
else ok "does not offer the hostname, which has no record"
fi

start_case "without an avahi override it uses the hostname"
url_env "dashcam" "10.0.0.5" "$(printf '[server]\n#host-name=teslausb\n')"
assert_eq "$(run_url)" "http://dashcam.local or http://10.0.0.5" "commented host-name is ignored"
url_env "dashcam" "10.0.0.5"
assert_eq "$(run_url)" "http://dashcam.local or http://10.0.0.5" "no avahi config at all"

start_case "it picks an address a reader can actually use"
url_env "teslausb" "192.168.66.1 192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')"
assert_eq "$(run_url)" "http://teslausb.local or http://192.168.68.101" "skips the access point subnet"
url_env "teslausb" "192.168.66.1" "$(printf '[server]\nhost-name=teslausb\n')"
assert_eq "$(run_url)" "http://teslausb.local" "only an AP address: name only"
# mDNS no longer publishes AAAA, so offering an IPv6 address here would send a
# reader somewhere the name deliberately does not point.
url_env "teslausb" "fd73:5747:499d:18e1::1 192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')"
assert_eq "$(run_url)" "http://teslausb.local or http://192.168.68.101" "skips IPv6"
url_env "teslausb" "169.254.7.7 192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')"
assert_eq "$(run_url)" "http://teslausb.local or http://192.168.68.101" "skips link-local"
url_env "teslausb" "" "$(printf '[server]\nhost-name=teslausb\n')"
assert_eq "$(run_url)" "http://teslausb.local" "no address at all: name only"
rm -rf /tmp/urlroot

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
