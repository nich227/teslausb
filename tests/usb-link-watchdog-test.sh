#!/bin/bash
#
# Unit tests for run/usb-link-watchdog.sh.
#
# The watchdog reads its paths from the environment (defaulting to the real
# ones), so each case runs it against a throwaway fixture directory with fake
# /proc/uptime, fake /sys/class/udc, a fake cam disk image, and stubs for
# findmnt, pgrep and reboot on PATH. Nothing here touches the real system and
# no root is required.
#
# Usage: tests/usb-link-watchdog-test.sh [-v]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly WATCHDOG="$SCRIPT_DIR/../run/usb-link-watchdog.sh"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

pass_count=0
fail_count=0
current_case=""

if [ ! -x "$WATCHDOG" ]
then
  echo "FATAL: $WATCHDOG not found or not executable"
  exit 1
fi

# --- fixture ---------------------------------------------------------------

# setup_fixture <uptime_mins> <udc_state> <cam_idle_mins>
#   udc_state: "configured", any other string, or "none" for no udc at all
setup_fixture () {
  local uptime_mins="$1" udc_state="$2" cam_idle_mins="$3"

  FIXTURE="$(mktemp -d)"
  mkdir -p "$FIXTURE/backingfiles" "$FIXTURE/mutable" "$FIXTURE/bin" "$FIXTURE/sys/udc"

  printf '%s.00 %s.00\n' "$(( uptime_mins * 60 ))" "$(( uptime_mins * 60 ))" \
    > "$FIXTURE/proc_uptime"

  if [ "$udc_state" != "none" ]
  then
    mkdir -p "$FIXTURE/sys/udc/20980000.usb"
    echo "$udc_state" > "$FIXTURE/sys/udc/20980000.usb/state"
  fi

  echo "cam data" > "$FIXTURE/backingfiles/cam_disk.bin"
  touch -d "@$(( $(date +%s) - cam_idle_mins * 60 ))" "$FIXTURE/backingfiles/cam_disk.bin"

  # stubs: default to "nothing mounted, no rsync running"
  cat > "$FIXTURE/bin/findmnt" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    /*) [ -e "${FIXTURE}/mounted$(echo "$arg" | tr / _)" ] && exit 0 ;;
  esac
done
exit 1
EOF
  cat > "$FIXTURE/bin/pgrep" <<'EOF'
#!/bin/bash
[ -e "${FIXTURE}/rsync_running" ] && exit 0
exit 1
EOF
  cat > "$FIXTURE/bin/reboot" <<'EOF'
#!/bin/bash
echo "reboot called" >> "${FIXTURE}/reboot_calls"
EOF
  # Tessie is asked whether the car is recording. The fixture answers with
  # whatever a test drops in dashcam_state / dashcam_age, or nothing at all,
  # which stands in for the API being unreachable.
  cat > "$FIXTURE/bin/curl" <<'EOF'
#!/bin/bash
[ -e "${FIXTURE}/tessie_down" ] && exit 7
state=$(cat "${FIXTURE}/dashcam_state" 2>/dev/null || echo Recording)
age=$(cat "${FIXTURE}/dashcam_age" 2>/dev/null || echo 30)
if [ "$state" = "malformed" ]; then echo "not json at all"; exit 0; fi
ts=$(( ( $(date +%s) - age ) * 1000 ))
printf '{"state":"online","vehicle_state":{"dashcam_state":"%s","timestamp":%s}}' "$state" "$ts"
EOF
  chmod +x "$FIXTURE/bin/findmnt" "$FIXTURE/bin/pgrep" "$FIXTURE/bin/reboot" "$FIXTURE/bin/curl"
  : > "$FIXTURE/rsync.log"
}

teardown_fixture () {
  [ -n "${FIXTURE:-}" ] && rm -rf "$FIXTURE"
  FIXTURE=""
}

# Runs the watchdog against the fixture. Uses 'env' so every path is expanded
# by this shell rather than by the command prefix being assembled.
run_watchdog () {
  env FIXTURE="$FIXTURE" \
      PATH="$FIXTURE/bin:$PATH" \
      CAM_IMAGE="$FIXTURE/backingfiles/cam_disk.bin" \
      UDC_DIR="$FIXTURE/sys/udc" \
      UPTIME_FILE="$FIXTURE/proc_uptime" \
      LOG="$FIXTURE/mutable/usb-link-watchdog.log" \
      STATE="$FIXTURE/mutable/usb-link-watchdog.last-reboot" \
      REBOOT_CMD="$FIXTURE/bin/reboot" \
      RSYNC_LOG="$FIXTURE/rsync.log" \
      SETUP_CONF="$FIXTURE/setup.conf" \
      BOUNDARY_WAIT_SECS="${BOUNDARY_WAIT_SECS:-10}" \
      TESSIE_API_TOKEN=token TESSIE_VIN=VIN \
      DRY_RUN="${DRY_RUN:-0}" \
      bash "$WATCHDOG"
  WATCHDOG_RC=$?
  return 0
}

# --- assertions ------------------------------------------------------------

start_case () { current_case="$1"; }

ok () {
  pass_count=$(( pass_count + 1 ))
  [ "$VERBOSE" = 1 ] && echo "  ok: $current_case: $1"
  return 0
}

not_ok () {
  fail_count=$(( fail_count + 1 ))
  echo "  FAIL: $current_case: $1"
  return 0
}

assert_rebooted () {
  if [ -e "$FIXTURE/reboot_calls" ]
  then ok "rebooted as expected"
  else not_ok "expected a reboot, none happened (log: $(cat "$FIXTURE/mutable/usb-link-watchdog.log" 2>/dev/null))"
  fi
}

assert_not_rebooted () {
  if [ -e "$FIXTURE/reboot_calls" ]
  then not_ok "unexpected reboot (log: $(cat "$FIXTURE/mutable/usb-link-watchdog.log" 2>/dev/null))"
  else ok "did not reboot"
  fi
}

assert_rc () {
  if [ "$WATCHDOG_RC" = "$1" ]
  then ok "exit status $1"
  else not_ok "expected exit status $1, got $WATCHDOG_RC"
  fi
}

assert_log_matches () {
  if grep -q -- "$1" "$FIXTURE/mutable/usb-link-watchdog.log" 2>/dev/null
  then ok "log contains '$1'"
  else not_ok "log does not contain '$1' (log: $(cat "$FIXTURE/mutable/usb-link-watchdog.log" 2>/dev/null))"
  fi
}

assert_no_log () {
  if [ -s "$FIXTURE/mutable/usb-link-watchdog.log" ]
  then not_ok "expected no log output, got: $(cat "$FIXTURE/mutable/usb-link-watchdog.log")"
  else ok "wrote nothing to the log"
  fi
}

assert_state_written () {
  if [ -s "$FIXTURE/mutable/usb-link-watchdog.last-reboot" ]
  then ok "recorded the reboot timestamp"
  else not_ok "did not record a reboot timestamp"
  fi
}

# --- cases -----------------------------------------------------------------

start_case "healthy: recent writes, gadget configured"
setup_fixture 120 configured 1
run_watchdog
assert_not_rebooted
assert_rc 0
assert_no_log
teardown_fixture

start_case "stalled: no writes for longer than the stall window"
setup_fixture 120 configured 30
echo Unavailable > "$FIXTURE/dashcam_state"
run_watchdog
assert_rebooted
assert_rc 0
assert_log_matches "ACTION"
assert_state_written
teardown_fixture

start_case "just below the stall threshold does not reboot"
setup_fixture 120 configured 14
run_watchdog
assert_not_rebooted
teardown_fixture

start_case "just above the stall threshold reboots"
setup_fixture 120 configured 16
echo Unavailable > "$FIXTURE/dashcam_state"
run_watchdog
assert_rebooted
teardown_fixture

start_case "early boot: stalled but under the minimum uptime"
setup_fixture 5 configured 60
run_watchdog
assert_not_rebooted
assert_rc 0
assert_no_log
teardown_fixture

start_case "uptime just under the minimum does not reboot"
setup_fixture 19 configured 60
run_watchdog
assert_not_rebooted
teardown_fixture

start_case "uptime just over the minimum reboots when stalled"
setup_fixture 21 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
run_watchdog
assert_rebooted
teardown_fixture

start_case "gadget not configured (teslausb owns the gadget)"
setup_fixture 120 not_attached 60
run_watchdog
assert_not_rebooted
assert_rc 0
assert_no_log
teardown_fixture

start_case "no udc directory at all"
setup_fixture 120 none 60
run_watchdog
assert_not_rebooted
assert_rc 0
teardown_fixture

start_case "cam mounted: teslausb owns the image, so idleness means nothing"
setup_fixture 120 configured 60
touch "$FIXTURE/mounted_mnt_cam"
run_watchdog
assert_not_rebooted
assert_no_log
teardown_fixture

start_case "the car is demonstrably recording, so a quiet image is a false alarm"
setup_fixture 120 configured 60
echo Recording > "$FIXTURE/dashcam_state"
echo 30 > "$FIXTURE/dashcam_age"
run_watchdog
assert_not_rebooted
assert_no_log
teardown_fixture

start_case "the car has lost the drive, so a stall reboots even mid-archive"
# This is the case an earlier version got wrong: it skipped whenever rsync was
# alive, and since the upload runs for hours the watchdog never fired at all.
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
touch "$FIXTURE/rsync_running" "$FIXTURE/mounted_mnt_archive"
BOUNDARY_WAIT_SECS=5 run_watchdog
assert_rebooted
assert_log_matches "ACTION"
teardown_fixture

start_case "a stale Recording reading is not trusted as an all-clear"
setup_fixture 120 configured 60
echo Recording > "$FIXTURE/dashcam_state"
echo 4000 > "$FIXTURE/dashcam_age"
run_watchdog
assert_rebooted
assert_log_matches "too stale to trust"
teardown_fixture

start_case "no answer from Tessie: falls back to leaving an archive alone"
setup_fixture 120 configured 60
touch "$FIXTURE/tessie_down" "$FIXTURE/rsync_running"
run_watchdog
assert_not_rebooted
assert_log_matches "dashcam unverified"
teardown_fixture

start_case "no answer from Tessie, and nothing in flight: reboots"
setup_fixture 120 configured 60
touch "$FIXTURE/tessie_down"
run_watchdog
assert_rebooted
assert_log_matches "ACTION"
teardown_fixture

start_case "a malformed Tessie response is treated as no answer"
setup_fixture 120 configured 60
echo malformed > "$FIXTURE/dashcam_state"
touch "$FIXTURE/rsync_running"
run_watchdog
assert_not_rebooted
assert_log_matches "dashcam unverified"
teardown_fixture

start_case "waits for a file boundary before rebooting during a transfer"
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
touch "$FIXTURE/rsync_running"
# a completed file appears shortly after the wait starts
( sleep 6; echo "sent one clip" >> "$FIXTURE/rsync.log" ) &
boundary_writer=$!
BOUNDARY_WAIT_SECS=30 run_watchdog
wait "$boundary_writer" 2> /dev/null
assert_rebooted
assert_log_matches "at file boundary"
teardown_fixture

start_case "reboots anyway if no file boundary arrives in time"
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
touch "$FIXTURE/rsync_running"
BOUNDARY_WAIT_SECS=5 run_watchdog
assert_rebooted
assert_log_matches "no boundary within"
teardown_fixture

start_case "DRY_RUN decides everything but changes nothing"
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
touch "$FIXTURE/rsync_running"
DRY_RUN=1 run_watchdog
assert_not_rebooted
assert_log_matches "DRY_RUN: would reboot now"
if [ -e "$FIXTURE/mutable/usb-link-watchdog.last-reboot" ]
then not_ok "DRY_RUN wrote the cooldown marker"
else ok "DRY_RUN left the cooldown marker alone"
fi
teardown_fixture

start_case "cooldown: stalled again right after a reboot"
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
date +%s > "$FIXTURE/mutable/usb-link-watchdog.last-reboot"
run_watchdog
assert_not_rebooted
assert_rc 0
assert_log_matches "cooldown"
teardown_fixture

start_case "cooldown expired: reboots again"
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
echo "$(( $(date +%s) - 31 * 60 ))" > "$FIXTURE/mutable/usb-link-watchdog.last-reboot"
run_watchdog
assert_rebooted
assert_log_matches "ACTION"
teardown_fixture

start_case "corrupt state file is treated as no previous reboot"
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
echo "not-a-timestamp" > "$FIXTURE/mutable/usb-link-watchdog.last-reboot"
run_watchdog
assert_rebooted
teardown_fixture

start_case "missing cam image reports an error and does not reboot"
setup_fixture 120 configured 60
rm -f "$FIXTURE/backingfiles/cam_disk.bin"
run_watchdog
assert_not_rebooted
assert_rc 1
assert_log_matches "ERROR"
teardown_fixture

start_case "cooldown state is not rewritten when no reboot happens"
setup_fixture 120 configured 1
run_watchdog
if [ -e "$FIXTURE/mutable/usb-link-watchdog.last-reboot" ]
then not_ok "wrote a reboot timestamp without rebooting"
else ok "left the cooldown state alone"
fi
teardown_fixture

start_case "log entries are appended, not truncated"
setup_fixture 120 configured 60
echo Unavailable > "$FIXTURE/dashcam_state"
date +%s > "$FIXTURE/mutable/usb-link-watchdog.last-reboot"
echo "pre-existing line" > "$FIXTURE/mutable/usb-link-watchdog.log"
run_watchdog
assert_log_matches "pre-existing line"
assert_log_matches "cooldown"
teardown_fixture

# --- summary ---------------------------------------------------------------

echo
echo "usb-link-watchdog: $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ] || exit 1
