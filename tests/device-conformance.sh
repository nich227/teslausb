#!/bin/bash
#
# Read-only conformance check of an installed teslausb device, run over ssh.
#
# The integration suite cannot run on a live device: it treats the filesystem as scratch,
# removing /root/bin and /boot/firmware among other things, because it is written for a
# throwaway container. This asks the same questions of a real device that the suite asks
# of its fixtures, and changes nothing. Every check reads a file, a unit state or a
# command's output.
#
# Usage: tests/device-conformance.sh [host]   (default teslausb.local; SSHPASS or a key)

set -u
HOST="${1:-teslausb.local}"
pass=0; fail=0; skipped=0

ok ()     { pass=$((pass+1));   printf '   ok:   %s\n' "$1"; }
not_ok () { fail=$((fail+1));   printf '   FAIL: %s\n' "$1"; }
skip ()   { skipped=$((skipped+1)); printf '   skip: %s\n' "$1"; }
section () { printf '\n-- %s\n' "$1"; }

# One ssh session per check keeps this simple; the device is on the LAN.
SSHO=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)
# The command string is meant to expand on the device, which is the point of passing it.
# shellcheck disable=SC2029
if [ -n "${SSHPASS:-}" ]
then
  SSHO+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
  remote () { sshpass -e ssh "${SSHO[@]}" "root@$HOST" "$@" 2> /dev/null; }
else
  remote () { ssh "${SSHO[@]}" "root@$HOST" "$@" 2> /dev/null; }
fi

# check "description" "remote command"  : passes when the command exits 0
check () {
  if remote "$2" > /dev/null; then ok "$1"; else not_ok "$1"; fi
}
# check_eq "description" "expected" "remote command"
check_eq () {
  local got; got=$(remote "$3" | tr -d '\r')
  if [ "$got" = "$2" ]; then ok "$1 ($got)"; else not_ok "$1 (expected '$2', got '$got')"; fi
}
# check_grep "description" "pattern" "file"
check_grep () { check "$1" "grep -qE '$2' '$3'"; }

echo "=== device conformance: $HOST ==="
remote true || { echo "cannot reach $HOST over ssh"; exit 1; }
# single quotes on purpose: the substitutions run on the device
# shellcheck disable=SC2016
echo "  $(remote 'echo "$(hostname): $(grep PRETTY /etc/os-release | cut -d\" -f2), DietPi $(sed -n s/G_DIETPI_VERSION_CORE=//p /boot/dietpi/.version).$(sed -n s/G_DIETPI_VERSION_SUB=//p /boot/dietpi/.version), up $(cut -d. -f1 /proc/uptime)s"')"

section "the platform is what the port supports"
check "the base is DietPi" "test -f /boot/dietpi/.version"
check "and Debian 12 or 13" "grep -qE '^VERSION_ID=\"1[23]\"' /etc/os-release"
check "setup finished" "test -f /teslausb/TESLAUSB_SETUP_FINISHED"
check "/teslausb points at the boot partition" "test -L /teslausb && test -f /teslausb/teslausb_setup_variables.conf -o -f /root/teslausb_setup_variables.conf"

section "services"
check_eq "teslausb is active" "active" "systemctl is-active teslausb"
check_eq "no failed units" "0" "systemctl --failed --no-legend --plain | wc -l"
check_eq "the setup unit is enabled, and skips itself once finished" "enabled" "systemctl is-enabled teslausb-setup.service"
check_grep "the setup unit runs the setup driver" "first-boot.sh" "/lib/systemd/system/teslausb-setup.service"
check_grep "teslausb.service releases the gadget on stop" "^ExecStop=-/root/bin/disable_gadget.sh" "/lib/systemd/system/teslausb.service"
check_eq "the usb-link watchdog timer is active" "active" "systemctl is-active usb-link-watchdog.timer"
check_grep "and fires every five minutes" "OnUnitActiveSec=5min" "/lib/systemd/system/usb-link-watchdog.timer"
check_eq "the hardware watchdog is armed by PID 1" "RuntimeWatchdogUSec=15s" "systemctl show -p RuntimeWatchdogUSec"
check_eq "and the kernel confirms it is running" "active" "cat /sys/class/watchdog/watchdog0/state"
check_eq "DietPi's RAMlog units are disabled" "0" "systemctl list-unit-files --state=enabled --no-legend dietpi-ramlog* | wc -l"

section "filesystem"
check_eq "the root filesystem is read-only" "ro" "findmnt -no OPTIONS / | cut -d, -f1"
check_eq "/backingfiles is xfs" "xfs" "findmnt -no FSTYPE /backingfiles"
check_eq "/mutable is mounted" "/mutable" "findmnt -no TARGET /mutable"
check "the cam disk exists" "test -f /backingfiles/cam_disk.bin"
check "no swap file is left behind" "! test -e /var/swap && ! grep -q swap /etc/fstab"
check_grep "nginx's log tmpfs carries nofail" "/var/log/nginx tmpfs .*nofail" "/etc/fstab"
check_grep "and an explicit mode, so the master can reopen its log" "/var/log/nginx tmpfs .*mode=0755" "/etc/fstab"
check_eq "the log tmpfs really is 0755" "755" "stat -c %a /var/log/nginx"
check "so nginx -t passes" "nginx -t"
check "the DietPi skip-resize marker did its job: root is not the last partition" "test \"\$(lsblk -no NAME /dev/mmcblk0 | tail -1 | tr -d ' ├─└')\" != mmcblk0p2"

section "network and names"
check_eq "OpenSSH serves ssh" "active" "systemctl is-active ssh"
check "and dropbear is gone" "! systemctl is-active dropbear && ! command -v dropbear"
check "openssh-client is present, for the rsync archive" "command -v ssh"
check_eq "avahi is active" "active" "systemctl is-active avahi-daemon"
check_grep "avahi publishes IPv4 only for the .local name" "^use-ipv6=no" "/etc/avahi/avahi-daemon.conf"
# read the value here and pass it plainly, rather than quoting through ssh three layers deep
archive_server=$(remote "sed -n 's/^export ARCHIVE_SERVER=//p' /root/teslausb_setup_variables.conf" | tr -d "\"'\r")
if [ -n "$archive_server" ]
then check "the archive at $archive_server is reachable" "/root/bin/archive-is-reachable.sh $archive_server"
else skip "the archive is reachable (no ARCHIVE_SERVER in the config)"
fi
check "the archive ssh key is in place" "test -f /root/.ssh/id_ed25519"
check_grep "RSYNC_PATH carries no escaped spaces" "^export RSYNC_PATH='[^\\\\]*'\$" "/root/teslausb_setup_variables.conf"
check "the clock is stepped when a client network comes up" "test -x /etc/network/if-up.d/teslausb-timesync"

section "hardware"
check "a real USB device controller is present" "ls /sys/class/udc | grep -q ."
check "the gadget is bound to the cam disk" "grep -q cam_disk.bin /sys/kernel/config/usb_gadget/teslausb/functions/mass_storage.*/lun.*/file"
check "Bluetooth firmware is installed" "dpkg-query -W bluez-firmware"
check "and the adapter is up" "hciconfig hci0 | grep -q 'UP RUNNING'"
check_grep "an attached display is kept awake" "^hdmi_blanking=0" "/boot/firmware/config.txt"
check "console autologin is in place, under the name DietPi will not delete" "test -f /etc/systemd/system/getty@tty1.service.d/teslausb-autologin.conf"

section "packages DietPi does not ship, installed by setup"
for pkg in xfsprogs dosfstools exfatprogs dos2unix autofs nginx fcgiwrap avahi-daemon libnss-mdns rsync openssh-client zip jq
do
  check "$pkg" "dpkg-query -W --showformat='\${db:Status-Status}' $pkg | grep -q installed"
done

section "the web interface"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://$HOST/")
if [ "$code" = 200 ]; then ok "answers on http://$HOST/ (200)"; else not_ok "answers on http://$HOST/ (got $code)"; fi
check "index.html is served with no-cache" "curl -sI http://127.0.0.1/ | grep -qi 'cache-control: no-cache'"
check "the hashed assets are served immutable" "curl -sI \"http://127.0.0.1/\$(curl -s http://127.0.0.1/ | grep -oE 'assets/index-[^\"]+\\.js' | head -1)\" | grep -qi immutable"
check "the cgi scripts are executable" "test -x /var/www/html/cgi-bin/status.sh"
check_eq "the status cgi answers" "200" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/cgi-bin/status.sh"
check "cam usage reports the three categories" "curl -s http://127.0.0.1/cgi-bin/camusage.sh | grep -q '\"SentryClips\"'"

section "encrypted recordings"
check "archiveloop covers the EncryptedClips tree" "grep -q 'EncryptedClips/SentryClips' /root/bin/archiveloop"
check "the snapshot links cover it" "grep -q 'EncryptedClips' /root/bin/make_snapshot.sh"
check "cam usage folds it into the categories" "grep -q 'EncryptedClips' /var/www/html/cgi-bin/camusage.sh"
check_eq "the key request is forwarded to Tesla (Tesla's own 401 comes back)" "401" \
  "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1/tesla/decrypt -H 'Content-Type: application/json' -d '{\"items\":[]}' --max-time 20"
check_eq "and only POST is accepted" "403" "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/tesla/decrypt"
check "the viewer bundle carries the player" "grep -lq 'tesla/decrypt' /var/www/html/assets/Viewer-*.js"

section "archiving state"
check "archiveloop has logged" "test -s /mutable/archiveloop.log"
check "and reports no archive errors in its last hundred lines" "! tail -100 /mutable/archiveloop.log | grep -q 'Error during archiving'"

printf '\n=== conformance: %d passed, %d failed, %d skipped ===\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
