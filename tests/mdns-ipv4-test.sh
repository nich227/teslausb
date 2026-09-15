#!/bin/bash
#
# Unit tests for configure_mdns_ipv4_only in setup/pi/setup-teslausb.
#
# The function is pulled out of the real script and run against throwaway avahi
# config files, with systemctl and setup_progress stubbed. No root, no avahi.
#
# WHY THIS EXISTS: avahi advertises every address the device has. The IPv6 ones are
# ULAs handed out by the home router, and a router reboot regenerates the prefix. A
# client that prefers IPv6, which iOS does, then holds an address that no longer
# routes and simply hangs, reporting that the site took too long to respond. IPv4
# only removes that, and nothing here needs IPv6.
#
# Usage: tests/mdns-ipv4-test.sh [-v]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly SETUP="$SCRIPT_DIR/../setup/pi/setup-teslausb"

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

[ -e "$SETUP" ] || { echo "FATAL: $SETUP not found"; exit 1; }

# Pull the function out, asserting it was found so a rename cannot silently make
# these tests vacuous.
FN=/tmp/mdns_fn.sh
sed -n '/^function configure_mdns_ipv4_only () {/,/^}/p' "$SETUP" > "$FN"
if ! grep -q '^function configure_mdns_ipv4_only () {' "$FN" || ! grep -q '^}' "$FN"
then
  echo "FATAL: could not extract configure_mdns_ipv4_only() from $SETUP"
  exit 1
fi
bash -n "$FN" || { echo "FATAL: extracted function does not parse"; exit 1; }

# run_on <conf-contents-generator>  -> populates $CONF and $RESTARTS
run_on () {
  WORK="$(mktemp -d)"
  CONF="$WORK/avahi-daemon.conf"
  "$1" > "$CONF"
  RESTARTS="$WORK/restarts"
  : > "$RESTARTS"
  (
    # shellcheck disable=SC1090
    source "$FN"
    # Both are called by the extracted function, which shellcheck cannot see.
    # shellcheck disable=SC2329
    setup_progress () { echo "$*" >> "$WORK/progress"; }
    # shellcheck disable=SC2329
    systemctl () { echo "$*" >> "$RESTARTS"; }
    # Point the function at the fixture instead of /etc.
    eval "$(declare -f configure_mdns_ipv4_only | sed "s|local conf=/etc/avahi/avahi-daemon.conf|local conf=$CONF|")"
    configure_mdns_ipv4_only
  )
}

conf_with_ipv6_yes () {
  printf '[server]\nhost-name=teslausb\nuse-ipv4=yes\nuse-ipv6=yes\n\n[publish]\npublish-hinfo=no\n'
}
conf_with_ipv6_commented () {
  printf '[server]\nhost-name=teslausb\nuse-ipv4=yes\n#use-ipv6=yes\n'
}
conf_without_any_ipv6_line () {
  printf '[server]\nhost-name=teslausb\nuse-ipv4=yes\n\n[publish]\npublish-workstation=no\n'
}
conf_already_no () {
  printf '[server]\nhost-name=teslausb\nuse-ipv4=yes\nuse-ipv6=no\n\n[publish]\npublish-aaaa-on-ipv4=no\n'
}
conf_no_publish_section () {
  printf '[server]\nhost-name=teslausb\nuse-ipv4=yes\nuse-ipv6=yes\n'
}
conf_publish_aaaa_yes () {
  printf '[server]\nuse-ipv6=yes\n\n[publish]\npublish-hinfo=no\npublish-aaaa-on-ipv4=yes\n'
}

echo "turns an enabled use-ipv6 off"
run_on conf_with_ipv6_yes
check "use-ipv6 is now no" "use-ipv6=no" "$(grep '^use-ipv6=' "$CONF")"
check "exactly one use-ipv6 line" "1" "$(grep -c '^use-ipv6=' "$CONF")"
check "use-ipv4 is left alone" "use-ipv4=yes" "$(grep '^use-ipv4=' "$CONF")"
check "host-name is left alone" "host-name=teslausb" "$(grep '^host-name=' "$CONF")"
check "avahi is restarted" "1" "$(grep -c 'restart avahi-daemon' "$RESTARTS")"
# The one that actually keeps clients off IPv6. use-ipv6=no only stops avahi using
# IPv6 as a transport; it keeps answering with the AAAA record over IPv4, which was
# verified on the device with avahi-resolve -6 still returning the IPv6 address.
check "AAAA publication is turned off" "publish-aaaa-on-ipv4=no" \
  "$(grep '^publish-aaaa-on-ipv4=' "$CONF")"
[ "$VERBOSE" = 1 ] && cat "$CONF"
rm -rf "$WORK"

echo
echo "handles a commented-out line"
run_on conf_with_ipv6_commented
check "the commented line becomes the real setting" "use-ipv6=no" "$(grep '^use-ipv6=' "$CONF")"
check "no stray commented copy is left" "0" "$(grep -c '^#use-ipv6' "$CONF")"
rm -rf "$WORK"

echo
echo "adds the setting when the file has none"
run_on conf_without_any_ipv6_line
check "the setting is added" "use-ipv6=no" "$(grep '^use-ipv6=' "$CONF")"
# It must land inside [server], not in a later section where avahi would ignore it.
server_line=$(grep -n '^\[server\]' "$CONF" | cut -d: -f1)
ipv6_line=$(grep -n '^use-ipv6=no$' "$CONF" | cut -d: -f1)
next_section=$(awk 'NR>1 && /^\[/ {print NR; exit}' "$CONF")
if [ "$ipv6_line" -gt "$server_line" ] && { [ -z "$next_section" ] || [ "$ipv6_line" -lt "$next_section" ]; }
then pass "added inside the [server] section, where avahi reads it"
else fail "added inside the [server] section" "server=$server_line ipv6=$ipv6_line next=$next_section"
fi
check "the existing [publish] section survives" "1" "$(grep -c '^\[publish\]' "$CONF")"
rm -rf "$WORK"

echo
echo "handles the [publish] section"
run_on conf_publish_aaaa_yes
check "an existing publish-aaaa-on-ipv4=yes is flipped" "publish-aaaa-on-ipv4=no" \
  "$(grep '^publish-aaaa-on-ipv4=' "$CONF")"
check "exactly one publish-aaaa-on-ipv4 line" "1" "$(grep -c '^publish-aaaa-on-ipv4=' "$CONF")"
check "other publish settings survive" "publish-hinfo=no" "$(grep '^publish-hinfo=' "$CONF")"
rm -rf "$WORK"

run_on conf_no_publish_section
check "a [publish] section is created when absent" "1" "$(grep -c '^\[publish\]' "$CONF")"
check "with the setting in it" "publish-aaaa-on-ipv4=no" "$(grep '^publish-aaaa-on-ipv4=' "$CONF")"
# It has to be under [publish], not left dangling under [server] where avahi
# would ignore it.
pub_line=$(grep -n '^\[publish\]' "$CONF" | cut -d: -f1)
aaaa_line=$(grep -n '^publish-aaaa-on-ipv4=no$' "$CONF" | cut -d: -f1)
if [ "$aaaa_line" -gt "$pub_line" ]
then pass "the setting sits under [publish], where avahi reads it"
else fail "the setting sits under [publish]" "publish=$pub_line aaaa=$aaaa_line"
fi
rm -rf "$WORK"

echo
echo "is idempotent"
run_on conf_already_no
check "already-correct file is unchanged" "use-ipv6=no" "$(grep '^use-ipv6=' "$CONF")"
check "exactly one use-ipv6 line" "1" "$(grep -c '^use-ipv6=' "$CONF")"
# Nothing changed, so there is no reason to bounce avahi and drop the .local name.
check "avahi is not restarted needlessly" "0" "$(grep -c 'restart avahi-daemon' "$RESTARTS")"
rm -rf "$WORK"

echo
echo "survives a missing avahi"
WORK="$(mktemp -d)"
CONF="$WORK/does-not-exist.conf"
RESTARTS="$WORK/restarts"; : > "$RESTARTS"
rc=0
(
  # shellcheck disable=SC1090
  source "$FN"
  # Both are called by the extracted function, which shellcheck cannot see.
  # shellcheck disable=SC2329
  setup_progress () { echo "$*" >> "$WORK/progress"; }
  # shellcheck disable=SC2329
  systemctl () { echo "$*" >> "$RESTARTS"; }
  eval "$(declare -f configure_mdns_ipv4_only | sed "s|local conf=/etc/avahi/avahi-daemon.conf|local conf=$CONF|")"
  configure_mdns_ipv4_only
) || rc=$?
check "returns success rather than failing setup" "0" "$rc"
if grep -qi "avahi is not installed" "$WORK/progress" 2>/dev/null
then pass "and says why"
else fail "and says why" "progress: $(cat "$WORK/progress" 2>/dev/null)"
fi
rm -rf "$WORK"

echo
echo "the call site runs it"
if grep -qE '^configure_mdns_ipv4_only$' "$SETUP"
then pass "configure_mdns_ipv4_only is called, not just defined"
else fail "configure_mdns_ipv4_only is called, not just defined"
fi

rm -f "$FN"
echo
printf 'passed: %d  failed: %d\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ] || exit 1
