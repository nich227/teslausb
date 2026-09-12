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
banner "installer: install_usb_link_watchdog"
# ===========================================================================
# configure.sh is a large script that expects a full teslausb setup, so extract
# just the function under test and drive it with stubs for the helpers it calls
# (copy_script, log_progress) and for systemctl.

STUBS=/tmp/stubs
mkdir -p "$STUBS" /lib/systemd/system /etc/systemd/system /root/bin
cat > "$STUBS/systemctl" <<'EOF'
#!/bin/bash
echo "systemctl $*" >> /tmp/systemctl.calls
EOF
chmod +x "$STUBS/systemctl"
export PATH="$STUBS:$PATH"

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

watchdog () {
  rm -f /tmp/reboot.calls
  env UDC_DIR=/run/udc REBOOT_CMD="$STUBS/reboot" bash /root/bin/usb-link-watchdog.sh
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
watchdog
assert_file /tmp/reboot.calls "rebooted"
assert_file /mutable/usb-link-watchdog.log "log written to /mutable"
assert_grep "ACTION" /mutable/usb-link-watchdog.log "logged the action"
assert_file /mutable/usb-link-watchdog.last-reboot "cooldown state written"

start_case "second stall inside the cooldown does not reboot again"
set_cam_idle 45
watchdog
assert_no_file /tmp/reboot.calls "no second reboot"
assert_grep "cooldown" /mutable/usb-link-watchdog.log "logged the cooldown"

start_case "real pgrep sees a running rsync and the reboot is suppressed"
rm -f /mutable/usb-link-watchdog.last-reboot
set_cam_idle 45
# a genuine process named exactly 'rsync', which is what the guard matches
cp /bin/sleep /usr/local/bin/rsync
/usr/local/bin/rsync 30 &
rsync_pid=$!
sleep 0.3
if pgrep -x rsync > /dev/null
then ok "pgrep -x rsync matches the running process"
else not_ok "test setup failed: pgrep does not see the fake rsync"
fi
watchdog
assert_no_file /tmp/reboot.calls "no reboot while rsync runs"
kill "$rsync_pid" 2> /dev/null
wait "$rsync_pid" 2> /dev/null
rm -f /usr/local/bin/rsync

start_case "real findmnt sees a mounted /mnt/cam and the reboot is suppressed"
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

start_case "a missing cam disk is reported, not rebooted through"
rm -f /backingfiles/cam_disk.bin
watchdog
assert_no_file /tmp/reboot.calls "no reboot"
assert_eq "$WD_RC" 1 "exit status 1"
assert_grep "ERROR" /mutable/usb-link-watchdog.log "logged the error"
echo camdata > /backingfiles/cam_disk.bin

# ===========================================================================
printf '\n=== summary ===\n'
printf 'integration: %d passed, %d failed\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ] || exit 1
exit 0
