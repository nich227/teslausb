#!/bin/bash
#
# Unit tests for run/teslausb-ap-channel.sh.
#
# The script is driven entirely through `iw`, so each case puts a fake iw on PATH
# that replays a recorded scan and a chosen association state. Nothing here needs
# a radio, a root shell, or the real device.
#
# The scan fixture is a trimmed capture from the actual device, so the expected
# winner is a real answer rather than one invented to match the code.
#
# Usage: tests/ap-channel-test.sh [-v]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT="$SCRIPT_DIR/../run/teslausb-ap-channel.sh"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

pass_count=0
fail_count=0
pass () { pass_count=$(( pass_count + 1 )); printf '  ok   %s\n' "$1"; }
fail () {
  fail_count=$(( fail_count + 1 ))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check () { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi; }

if [ ! -x "$SCRIPT" ]
then
  echo "FATAL: $SCRIPT not found or not executable"
  exit 1
fi

# --- fixture ---------------------------------------------------------------
# assoc_freq: a frequency to report as the client's association, or "none".
# scan: name of a scan fixture generator.
setup_fixture () {
  local assoc_freq="$1" scan_body="$2"
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/bin"

  # A fake iw covering the four forms the script uses: dev, link, info, scan.
  cat > "$FIX/bin/iw" <<EOF
#!/bin/bash
case "\$*" in
  "dev")
    printf 'phy#0\n\tInterface ap0\n\t\ttype AP\n\tInterface wlan0\n\t\ttype managed\n'
    ;;
  "dev wlan0 link")
    if [ "$assoc_freq" = "none" ]
    then
      echo "Not connected."
    else
      printf 'Connected to aa:bb:cc:dd:ee:ff (on wlan0)\n\tSSID: Test\n\tfreq: $assoc_freq\n'
    fi
    ;;
  "dev ap0 info")
    printf '\tInterface ap0\n\t\tchannel 6 (2437 MHz), width: 20 MHz\n'
    ;;
  "dev wlan0 scan")
    cat "$FIX/scan.txt"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$FIX/bin/iw"
  "$scan_body" > "$FIX/scan.txt"
}

# One loud neighbour on channel 6, nothing else: 11 should win as it is furthest
# from the interference.
scan_busy_on_6 () {
  cat <<'EOF'
BSS aa:bb:cc:dd:ee:01(on wlan0)
	freq: 2437
	signal: -35.00 dBm
	SSID: Loud
EOF
}

# Trimmed capture from the device: crowded low channels, quieter top end.
scan_real_capture () {
  cat <<'EOF'
BSS aa:bb:cc:dd:ee:01(on wlan0)
	freq: 2412
	signal: -70.00 dBm
	SSID: A
BSS aa:bb:cc:dd:ee:02(on wlan0)
	freq: 2417
	signal: -38.00 dBm
	SSID: B
BSS aa:bb:cc:dd:ee:03(on wlan0)
	freq: 2417
	signal: -39.00 dBm
	SSID: C
BSS aa:bb:cc:dd:ee:04(on wlan0)
	freq: 2437
	signal: -45.00 dBm
	SSID: D
BSS aa:bb:cc:dd:ee:05(on wlan0)
	freq: 2437
	signal: -49.00 dBm
	SSID: E
BSS aa:bb:cc:dd:ee:06(on wlan0)
	freq: 2462
	signal: -80.00 dBm
	SSID: F
EOF
}

# Everything on 11, so a low channel should win instead.
scan_busy_on_11 () {
  cat <<'EOF'
BSS aa:bb:cc:dd:ee:01(on wlan0)
	freq: 2462
	signal: -30.00 dBm
	SSID: Loud
EOF
}

# 5GHz neighbours must be ignored: the AP is hw_mode=g.
scan_only_5ghz () {
  cat <<'EOF'
BSS aa:bb:cc:dd:ee:01(on wlan0)
	freq: 5180
	signal: -30.00 dBm
	SSID: Fast
EOF
}

run_script () { ( PATH="$FIX/bin:$PATH"; "$SCRIPT" "$@" 2>/dev/null ); }

echo "channel choice when the radio is free"

setup_fixture none scan_busy_on_6
# 1 and 11 are both five channels from 6, so both are outside the overlap window
# and score zero. Either is a correct answer; what matters is that the choice is
# not on top of the loud neighbour or within its overlap.
got=$(run_script best)
if [ -n "$got" ] && [ "$got" -ge 1 ] && [ "$got" -le 11 ] 2>/dev/null &&
   [ "$(( got > 6 ? got - 6 : 6 - got ))" -gt 4 ]
then pass "a loud AP on 6 is avoided by more than the overlap window (got $got)"
else fail "a loud AP on 6 is avoided by more than the overlap window" "got $got"
fi
[ "$VERBOSE" = 1 ] && run_script report
rm -rf "$FIX"

setup_fixture none scan_busy_on_11
got=$(run_script best)
if [ "$got" -le 6 ] 2>/dev/null
then pass "a loud AP on 11 pushes the choice down the band (got $got)"
else fail "a loud AP on 11 pushes the choice down the band" "got $got"
fi
rm -rf "$FIX"

setup_fixture none scan_real_capture
check "the recorded capture picks 11, as measured on the device" "11" "$(run_script best)"
rm -rf "$FIX"

setup_fixture none scan_only_5ghz
got=$(run_script best)
if [ -n "$got" ] && [ "$got" -ge 1 ] && [ "$got" -le 11 ] 2>/dev/null
then pass "5GHz neighbours are ignored, a 2.4GHz channel is still chosen (got $got)"
else fail "5GHz neighbours are ignored" "got [$got]"
fi
rm -rf "$FIX"

echo
echo "channel choice when the client pins the radio"

# #channels <= 1: while associated the AP cannot differ from the client, so the
# client's channel must be reported rather than the quietest one.
setup_fixture 2437 scan_busy_on_6
check "reports the client's channel, not the quietest one" "6" "$(run_script best)"
rm -rf "$FIX"

setup_fixture 2412 scan_busy_on_6
check "follows the client onto channel 1" "1" "$(run_script best)"
rm -rf "$FIX"

echo
echo "apply does not fight the client association"

setup_fixture 2437 scan_busy_on_6
out=$(run_script apply)
if grep -q "cannot move" <<< "$out"
then pass "apply declines to move while the client is associated"
else fail "apply declines to move while the client is associated" "output: $out"
fi
if grep -q "change the router" <<< "$out"
then pass "and says where the change has to be made instead"
else fail "and says where the change has to be made instead" "output: $out"
fi
rm -rf "$FIX"

echo
echo "report output"
setup_fixture none scan_real_capture
out=$(run_script report)
if grep -q "free to choose" <<< "$out"
then pass "report says the radio is free when unassociated"
else fail "report says the radio is free when unassociated" "output: $out"
fi
if [ "$(grep -cE '^[0-9]+ ' <<< "$out")" = "11" ]
then pass "report scores all 11 channels"
else fail "report scores all 11 channels" "got $(grep -cE '^[0-9]+ ' <<< "$out") rows"
fi
rm -rf "$FIX"

echo
echo "the radio is scanned once per invocation"
# Found on hardware, not here: report scanned three times, so the channel it
# labelled quietest came from a different scan than the table beside it and the
# two disagreed. A fixture never varies between scans, so only a call count
# catches it.
setup_fixture none scan_real_capture
cat > "$FIX/bin/iw" <<EOF
#!/bin/bash
case "\$*" in
  "dev")            printf 'phy#0\n\tInterface ap0\n\t\ttype AP\n\tInterface wlan0\n\t\ttype managed\n' ;;
  "dev wlan0 link") echo "Not connected." ;;
  "dev ap0 info")   printf '\tInterface ap0\n\t\tchannel 6 (2437 MHz)\n' ;;
  "dev wlan0 scan") echo scan >> "$FIX/scan.count"; cat "$FIX/scan.txt" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FIX/bin/iw"

: > "$FIX/scan.count"
run_script report > /dev/null
check "report scans exactly once" "1" "$(wc -l < "$FIX/scan.count" | tr -d ' ')"

: > "$FIX/scan.count"
run_script best > /dev/null
check "best scans exactly once" "1" "$(wc -l < "$FIX/scan.count" | tr -d ' ')"

# And the label must agree with the table it is printed beside.
out=$(run_script report)
labelled=$(awk '/least interference/ {print $1}' <<< "$out")
lowest=$(awk '/^[0-9]+ /{print $1, $2}' <<< "$out" | sort -k2 -g | head -1 | awk '{print $1}')
check "the channel labelled quietest is the lowest scoring one in the table" "$lowest" "$labelled"
rm -rf "$FIX"

echo
printf 'passed: %d  failed: %d\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ] || exit 1
