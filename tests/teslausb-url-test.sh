#!/bin/bash
#
# Unit tests for run/teslausb-url.sh, which prints the URLs the web interface
# answers on and is called from the login tip.
#
# WHY THIS EXISTS: the tip used to print the system hostname, which on a device
# where avahi is told a different name does not resolve at all. Observed: hostname
# Kevster-TeslaUSB, avahi host-name=teslausb, and Kevster-TeslaUSB.local returning
# nothing while teslausb.local answered immediately. The tip therefore sent people
# to a dead name.
#
# Each case runs the real script against a throwaway avahi config, with hostname
# stubbed on PATH. No root and no avahi.
#
# Usage: tests/teslausb-url-test.sh [-v]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SCRIPT="$SCRIPT_DIR/../run/teslausb-url.sh"

pass_count=0
fail_count=0
pass () { pass_count=$(( pass_count + 1 )); printf '  ok   %s\n' "$1"; }
fail () {
  fail_count=$(( fail_count + 1 ))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check () { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi; }

[ -x "$SCRIPT" ] || { echo "FATAL: $SCRIPT not found or not executable"; exit 1; }

# run_url <short-hostname> <addresses> [avahi conf contents]
run_url () {
  local host="$1" addrs="$2" conf="${3:-}"
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/bin"
  cat > "$FIX/bin/hostname" <<EOF
#!/bin/bash
case "\${1:-}" in
  -s) echo "$host" ;;
  -I) echo "$addrs" ;;
  *)  echo "$host" ;;
esac
EOF
  chmod +x "$FIX/bin/hostname"
  local confarg=/nonexistent
  if [ -n "$conf" ]
  then
    printf '%s' "$conf" > "$FIX/avahi.conf"
    confarg="$FIX/avahi.conf"
  fi
  ( PATH="$FIX/bin:$PATH"; AVAHI_CONF="$confarg" "$SCRIPT" )
  # Clean up here rather than in the caller: run_url is invoked inside a command
  # substitution, so anything it assigns is lost to the parent shell.
  rm -rf "$FIX"
}

echo "the name comes from avahi, not the system hostname"
out=$(run_url "Kevster-TeslaUSB" "192.168.68.101" "$(printf '[server]\nhost-name=teslausb\nuse-ipv4=yes\n')")
check "uses the avahi name" "http://teslausb.local or http://192.168.68.101" "$out"
if grep -q "Kevster" <<< "$out"
then fail "does not offer the hostname, which does not resolve" "got: $out"
else pass "does not offer the hostname, which does not resolve"
fi
echo
echo "falls back to the hostname when avahi does not override it"
out=$(run_url "teslausb" "192.168.68.101" "$(printf '[server]\nuse-ipv4=yes\n')")
check "no host-name line: uses the hostname" "http://teslausb.local or http://192.168.68.101" "$out"
out=$(run_url "dashcam" "10.0.0.5" "$(printf '[server]\n#host-name=teslausb\n')")
check "commented host-name is ignored" "http://dashcam.local or http://10.0.0.5" "$out"
out=$(run_url "dashcam" "10.0.0.5")
check "no avahi config at all: uses the hostname" "http://dashcam.local or http://10.0.0.5" "$out"
echo
echo "the name and the hostname may legitimately match"
out=$(run_url "teslausb" "192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')")
check "prints it once, not twice" "http://teslausb.local or http://192.168.68.101" "$out"
echo
echo "picks a usable address"
out=$(run_url "teslausb" "192.168.66.1 192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')")
check "skips the access point subnet" "http://teslausb.local or http://192.168.68.101" "$out"
out=$(run_url "teslausb" "fd73:5747:499d:18e1::1 192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')")
check "skips IPv6, which mDNS no longer publishes" "http://teslausb.local or http://192.168.68.101" "$out"
out=$(run_url "teslausb" "169.254.7.7 192.168.68.101" "$(printf '[server]\nhost-name=teslausb\n')")
check "skips link-local" "http://teslausb.local or http://192.168.68.101" "$out"
out=$(run_url "teslausb" "" "$(printf '[server]\nhost-name=teslausb\n')")
check "no address yet: prints just the name" "http://teslausb.local" "$out"
out=$(run_url "teslausb" "192.168.66.1" "$(printf '[server]\nhost-name=teslausb\n')")
check "only an AP address: prints just the name" "http://teslausb.local" "$out"
echo
echo "the login tip calls it rather than baking a name in"
setup="$SCRIPT_DIR/../setup/pi/setup-teslausb"
# Deliberately single quoted: this is the literal text the tip must contain, and
# expanding it here would defeat the check.
# shellcheck disable=SC2016
if grep -q 'The TeslaUSB web interface is at \\$(/usr/local/bin/teslausb-url)' "$setup"
then pass "the tip calls teslausb-url at login"
else fail "the tip calls teslausb-url at login" "$(grep -n 'web interface is at' "$setup")"
fi
if grep -qE 'web interface is at http://\$\(hostname' "$setup"
then fail "the old baked-in hostname is gone"
else pass "the old baked-in hostname is gone"
fi
if grep -q 'copy_script run/teslausb-url.sh /usr/local/bin' "$setup"
then pass "setup installs the helper"
else fail "setup installs the helper"
fi

echo
echo "the GitHub link points at this fork"
app="$SCRIPT_DIR/../teslausb-www/ui/src/App.tsx"
if grep -q "github.com/nich227/teslausb" "$app"
then pass "App.tsx links to nich227/teslausb"
else fail "App.tsx links to nich227/teslausb" "$(grep -n github.com "$app")"
fi
if grep -q "github.com/marcone/teslausb" "$app"
then fail "no upstream link left in the UI" "$(grep -n marcone "$app")"
else pass "no upstream link left in the UI"
fi

echo
printf 'passed: %d  failed: %d\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ] || exit 1
