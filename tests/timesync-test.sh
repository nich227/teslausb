#!/bin/bash
#
# Unit tests for run/teslausb-timesync.sh, the if-up.d hook that steps the clock
# when a client network appears.
#
# WHY IT EXISTS: no RTC on this hardware, so at boot the clock holds whatever
# fake-hwclock saved at the last shutdown. ntpsec disciplines rather than steps, so
# until it catches up everything logged carries a stale timestamp and
# archiveloop.log reads out of order, which cost real debugging time.
#
# Each case runs the real hook with sntp, ntpdig, logger and timeout stubbed on
# PATH, so nothing touches the clock or the network.
#
# Usage: tests/timesync-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly HOOK="$SCRIPT_DIR/../run/teslausb-timesync.sh"

pass_count=0
fail_count=0
pass () { pass_count=$(( pass_count + 1 )); printf '  ok   %s\n' "$1"; }
fail () {
  fail_count=$(( fail_count + 1 ))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check () { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi; }

[ -x "$HOOK" ] || { echo "FATAL: $HOOK not found or not executable"; exit 1; }

# run_hook <iface> <mode> <sntp-exit> [ntpdig-exit]
run_hook () {
  local iface="$1" mode="$2" sntp_rc="$3" ntpdig_rc="${4:-1}"
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/bin"
  cat > "$FIX/bin/sntp" <<EOF
#!/bin/bash
echo "sntp \$*" >> "$FIX/calls"
exit $sntp_rc
EOF
  cat > "$FIX/bin/ntpdig" <<EOF
#!/bin/bash
echo "ntpdig \$*" >> "$FIX/calls"
exit $ntpdig_rc
EOF
  # timeout must run the stub, not swallow it.
  cat > "$FIX/bin/timeout" <<'EOF'
#!/bin/bash
shift
exec "$@"
EOF
  cat > "$FIX/bin/logger" <<EOF
#!/bin/bash
echo "\$*" >> "$FIX/logger"
EOF
  chmod +x "$FIX/bin"/*
  : > "$FIX/calls"
  : > "$FIX/logger"
  (
    PATH="$FIX/bin:$PATH"
    IFACE="$iface" MODE="$mode" \
    TESLAUSB_TIMESYNC_FOREGROUND=1 \
    SYNC_LOG="$FIX/synclog" \
    "$HOOK"
  )
  HOOK_RC=$?
}

echo "acts for a client interface"
run_hook wlan0 start 0
check "exits 0" "0" "$HOOK_RC"
if grep -q "sntp -S time.google.com" "$FIX/calls"
then pass "steps the clock with -S against the first server"
else fail "steps the clock with -S against the first server" "calls: $(cat "$FIX/calls")"
fi
check "stops after the first success" "1" "$(wc -l < "$FIX/calls" | tr -d ' ')"
if grep -q "stepped the clock" "$FIX/logger"
then pass "says so in the log"
else fail "says so in the log" "logger: $(cat "$FIX/logger")"
fi
rm -rf "$FIX"

echo
echo "ignores interfaces that mean nothing"
for iface in ap0 lo; do
  run_hook "$iface" start 0
  check "$iface: exits 0" "0" "$HOOK_RC"
  check "$iface: no time server contacted" "0" "$(wc -c < "$FIX/calls" | tr -d ' ')"
  rm -rf "$FIX"
done
# The access point coming up says nothing about reaching the internet.
run_hook "" start 0
check "empty IFACE: does nothing" "0" "$(wc -c < "$FIX/calls" | tr -d ' ')"
rm -rf "$FIX"

echo
echo "only on the way up"
run_hook wlan0 stop 0
check "MODE=stop: exits 0" "0" "$HOOK_RC"
check "MODE=stop: no time server contacted" "0" "$(wc -c < "$FIX/calls" | tr -d ' ')"
rm -rf "$FIX"

echo
echo "falls through the tools and servers"
run_hook wlan0 start 1 0
if grep -q "^ntpdig -S time.google.com" "$FIX/calls"
then pass "tries ntpdig when sntp fails"
else fail "tries ntpdig when sntp fails" "calls: $(cat "$FIX/calls")"
fi
rm -rf "$FIX"

run_hook wlan0 start 1 1
if grep -q "129.6.15.28" "$FIX/calls"
then pass "moves on to the second server when the first fails"
else fail "moves on to the second server when the first fails" "calls: $(cat "$FIX/calls")"
fi
check "still exits 0, so ifup is never held up by a failure" "0" "$HOOK_RC"
if grep -q "could not reach a time server" "$FIX/logger"
then pass "reports the failure rather than staying silent"
else fail "reports the failure rather than staying silent" "logger: $(cat "$FIX/logger")"
fi
rm -rf "$FIX"

echo
echo "matches the servers archiveloop already uses"
loop="$SCRIPT_DIR/../run/archiveloop"
for server in time.google.com 129.6.15.28; do
  if grep -q "$server" "$loop" && grep -q "$server" "$HOOK"
  then pass "$server is used by both, so there is one set of choices"
  else fail "$server is used by both" "archiveloop=$(grep -c "$server" "$loop") hook=$(grep -c "$server" "$HOOK")"
  fi
done

echo
echo "setup installs it as an if-up.d hook"
setup="$SCRIPT_DIR/../setup/pi/setup-teslausb"
if grep -q "copy_script run/teslausb-timesync.sh /etc/network/if-up.d" "$setup"
then pass "installed into /etc/network/if-up.d"
else fail "installed into /etc/network/if-up.d"
fi
if grep -q "chmod 755 /etc/network/if-up.d/teslausb-timesync" "$setup"
then pass "and made executable, or ifupdown would skip it"
else fail "and made executable"
fi

echo
printf 'passed: %d  failed: %d\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ] || exit 1
