#!/bin/bash
#
# Unit tests for the package installs that Raspberry Pi OS Lite happened to
# provide and DietPi does not, plus the rfkill-free wifi unblock.
#
# Two kinds of case here:
#
#   - behavioural, for the code with logic in it: unblock_wifi from
#     setup/pi/first-boot.sh and install_required_packages from
#     run/rclone_archive/verify-and-configure-archive.sh. Each function is pulled
#     out of the real file and run against a throwaway fixture with stubs on
#     PATH, so nothing here touches the real system and no root is required.
#     The extraction is asserted, so a rename or a moved function fails loudly
#     rather than silently testing nothing.
#
#   - guard, for the one-line apt-get changes that have no logic to exercise:
#     assert the package is on the install line, and for zip that it is on the
#     unconditional one rather than back inside the music/lightshow branch.
#     These exist to stop a merge quietly dropping a package again.
#
# Usage: tests/package-install-test.sh [-v]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO="$SCRIPT_DIR/.."
readonly FIRST_BOOT="$REPO/setup/pi/first-boot.sh"
readonly RCLONE_CONF="$REPO/run/rclone_archive/verify-and-configure-archive.sh"
readonly CONFIGURE_AP="$REPO/setup/pi/configure-ap.sh"
readonly CONFIGURE_WEB="$REPO/setup/pi/configure-web.sh"

VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

pass_count=0
fail_count=0

for f in "$FIRST_BOOT" "$RCLONE_CONF" "$CONFIGURE_AP" "$CONFIGURE_WEB"
do
  if [ ! -e "$f" ]
  then
    echo "FATAL: $f not found"
    exit 1
  fi
done

pass () { pass_count=$(( pass_count + 1 )); printf '  ok   %s\n' "$1"; }
fail () {
  fail_count=$(( fail_count + 1 ))
  printf '  FAIL %s\n' "$1"
  [ -n "${2:-}" ] && printf '       %s\n' "$2"
}
check () {  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}

# --- extract a function from a script into a sourceable file ----------------
# Guards against silently testing nothing if the function is renamed or moved.
extract_function () {  # extract_function <file> <name> <outfile>
  local file="$1" name="$2" out="$3"
  sed -n "/^function ${name} () {/,/^}/p" "$file" > "$out"
  if ! grep -q "^function ${name} () {" "$out" || ! grep -q '^}' "$out"
  then
    echo "FATAL: could not extract ${name}() from ${file}" >&2
    exit 1
  fi
  bash -n "$out" || { echo "FATAL: extracted ${name}() does not parse" >&2; exit 1; }
}

echo "unblock_wifi (setup/pi/first-boot.sh)"
extract_function "$FIRST_BOOT" unblock_wifi /tmp/pkgtest_unblock.sh

# fixture: two rfkill devices, one wlan and one bluetooth, both soft-blocked,
# plus a saved-state file for wlan
make_rfkill_fixture () {
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/sys/rfkill0" "$FIX/sys/rfkill1" "$FIX/saved" "$FIX/bin"
  echo wlan      > "$FIX/sys/rfkill0/type"; echo 1 > "$FIX/sys/rfkill0/soft"
  echo bluetooth > "$FIX/sys/rfkill1/type"; echo 1 > "$FIX/sys/rfkill1/soft"
  echo 1 > "$FIX/saved/0:phy0:wlan"
  echo 1 > "$FIX/saved/1:hci0:bluetooth"
}

run_unblock () {  # run_unblock <with_rfkill: yes|no>
  local with_rfkill="$1"
  if [ "$with_rfkill" = "yes" ]
  then
    printf '#!/bin/bash\necho "rfkill called: $*" >> "%s/rfkill.calls"\n' "$FIX" > "$FIX/bin/rfkill"
    chmod +x "$FIX/bin/rfkill"
  fi
  (
    PATH="$FIX/bin:/usr/bin:/bin"
    RFKILL_SYSFS_DIR="$FIX/sys"
    RFKILL_SAVED_DIR="$FIX/saved"
    export PATH RFKILL_SYSFS_DIR RFKILL_SAVED_DIR
    # shellcheck disable=SC1091
    source /tmp/pkgtest_unblock.sh
    unblock_wifi
  )
}

# case: no rfkill binary -> sysfs is used, wlan only
make_rfkill_fixture
run_unblock no
check "no rfkill binary: wlan soft cleared via sysfs" "0" "$(cat "$FIX/sys/rfkill0/soft")"
check "no rfkill binary: bluetooth left alone"         "1" "$(cat "$FIX/sys/rfkill1/soft")"
check "no rfkill binary: saved wlan state cleared"     "0" "$(cat "$FIX/saved/0:phy0:wlan")"
check "no rfkill binary: saved bluetooth untouched"    "1" "$(cat "$FIX/saved/1:hci0:bluetooth")"
[ "$VERBOSE" = 1 ] && ls -l "$FIX/sys" "$FIX/saved"
rm -rf "$FIX"

# case: rfkill binary present -> it is used, and saved state is still written
make_rfkill_fixture
run_unblock yes
if grep -q "unblock wifi" "$FIX/rfkill.calls" 2>/dev/null
then pass "rfkill binary present: command used"
else fail "rfkill binary present: command used" "no rfkill invocation recorded"
fi
check "rfkill binary present: saved wlan state still cleared" "0" "$(cat "$FIX/saved/0:phy0:wlan")"
rm -rf "$FIX"

# case: empty saved dir must not create a file named literally "*:wlan"
make_rfkill_fixture
rm -f "$FIX"/saved/*
run_unblock no
if [ -e "$FIX/saved/*:wlan" ]
then fail "empty saved dir: no literal glob file created" "created '*:wlan'"
else pass "empty saved dir: no literal glob file created"
fi
check "empty saved dir: still cleared sysfs" "0" "$(cat "$FIX/sys/rfkill0/soft")"
rm -rf "$FIX"

# case: no rfkill devices at all must not error
make_rfkill_fixture
rm -rf "$FIX"/sys/*
if run_unblock no 2>/dev/null
then pass "no rfkill devices: exits cleanly"
else fail "no rfkill devices: exits cleanly" "non-zero exit"
fi
rm -rf "$FIX" /tmp/pkgtest_unblock.sh

echo
echo "install_required_packages (run/rclone_archive/verify-and-configure-archive.sh)"
extract_function "$RCLONE_CONF" install_required_packages /tmp/pkgtest_rclone.sh

run_rclone_install () {  # run_rclone_install <rclone_present: yes|no>
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/bin"
  printf '#!/bin/bash\necho "$*" >> "%s/apt.calls"\n' "$FIX" > "$FIX/bin/apt-get"
  chmod +x "$FIX/bin/apt-get"
  if [ "$1" = "yes" ]
  then
    printf '#!/bin/bash\nexit 0\n' > "$FIX/bin/rclone"
    chmod +x "$FIX/bin/rclone"
  fi
  (
    PATH="$FIX/bin:/usr/bin:/bin"
    export PATH
    # Invoked indirectly by the extracted function, which shellcheck cannot see.
    # shellcheck disable=SC2329
    log_progress () { :; }
    # shellcheck disable=SC1091
    source /tmp/pkgtest_rclone.sh
    install_required_packages
  ) > /dev/null 2>&1
}

run_rclone_install no
if grep -q "install rclone" "$FIX/apt.calls" 2>/dev/null
then pass "rclone missing: apt-get install rclone called"
else fail "rclone missing: apt-get install rclone called" "apt.calls: $(cat "$FIX/apt.calls" 2>/dev/null)"
fi
rm -rf "$FIX"

run_rclone_install yes
if [ -e "$FIX/apt.calls" ]
then fail "rclone already present: no install attempted" "apt.calls: $(cat "$FIX/apt.calls")"
else pass "rclone already present: no install attempted"
fi
rm -rf "$FIX" /tmp/pkgtest_rclone.sh

echo
echo "package guards (one-line apt-get changes)"

ap_line=$(grep -E "apt-get -y install .*hostapd" "$CONFIGURE_AP" | head -1)
for p in iw hostapd dnsmasq iptables
do
  if grep -qE "(^| )$p( |$)" <<< "$ap_line"
  then pass "configure-ap.sh installs $p"
  else fail "configure-ap.sh installs $p" "line: $ap_line"
  fi
done

web_line=$(grep -E "^apt-get -y install nginx" "$CONFIGURE_WEB" | head -1)
if grep -qE "(^| )zip( |$)" <<< "$web_line"
then pass "configure-web.sh installs zip unconditionally"
else fail "configure-web.sh installs zip unconditionally" "line: $web_line"
fi

# zip must not be back inside the music/lightshow/boombox branch, where a
# dashcam-only device never reaches it
if awk '/music_disk.bin/,/^fi$/' "$CONFIGURE_WEB" | grep -q "install zip"
then fail "configure-web.sh does not gate zip behind music disks" "still inside the conditional"
else pass "configure-web.sh does not gate zip behind music disks"
fi

# the web UI really does need zip, so the guard above is meaningful
if grep -rq "zip " "$REPO/teslausb-www/html/cgi-bin/downloadzip.sh" 2>/dev/null
then pass "web UI downloadzip.sh does use zip (guard is meaningful)"
else fail "web UI downloadzip.sh does use zip (guard is meaningful)" "zip not referenced"
fi

echo
echo "cgi-bin scripts are executable"
# fcgiwrap returns 403 for a script it cannot execute, and configure-web.sh copies
# the webroot straight out of the repository, so a cgi script committed without
# the executable bit is a broken endpoint on every install. camusage.sh, and with
# it the Recordings storage panel, was dead this way: the fetch 403'd and the
# panel shimmered forever.
cgi_dir="$REPO/teslausb-www/html/cgi-bin"
if [ -d "$cgi_dir" ]
then
  non_exec=""
  for f in "$cgi_dir"/*.sh
  do
    [ -e "$f" ] || continue
    [ -x "$f" ] || non_exec="$non_exec $(basename "$f")"
  done
  if [ -z "$non_exec" ]
  then
    pass "every cgi-bin script is executable ($(find "$cgi_dir" -name '*.sh' | wc -l) scripts)"
  else
    fail "every cgi-bin script is executable" "not executable:$non_exec"
  fi

  # git tracks only the executable bit, so check the recorded mode too: a local
  # chmod that is never committed would leave the shipped copy broken.
  if command -v git > /dev/null && git -C "$REPO" rev-parse --git-dir > /dev/null 2>&1
  then
    tracked_non_exec=$(git -C "$REPO" ls-files -s teslausb-www/html/cgi-bin |
      awk '$1 != "100755" { print $4 }')
    if [ -z "$tracked_non_exec" ]
    then
      pass "and git records mode 100755 for all of them"
    else
      fail "and git records mode 100755 for all of them" "$(echo "$tracked_non_exec" | tr '\n' ' ')"
    fi
  fi
else
  fail "cgi-bin directory exists" "$cgi_dir not found"
fi

echo
echo "status.sh emits valid JSON"
# Everything on the dashboard comes from this one endpoint, so a stray newline in
# any value takes the whole page down, not just the field that produced it. That
# is how it broke: `iw ... | grep -c '^Station' || echo 0` printed 0 from grep and
# 0 again from the fallback, because grep -c exits 1 when it matches nothing.
status_sh="$REPO/teslausb-www/html/cgi-bin/status.sh"
if [ -e "$status_sh" ]
then
  # No shell fallback may follow a `grep -c`, which already prints 0 on no match.
  if grep -nE 'grep -c[^|]*\|\|[[:space:]]*echo' "$status_sh" > /dev/null
  then
    fail "no 'grep -c ... || echo' that would emit two lines" \
         "$(grep -nE 'grep -c[^|]*\|\|[[:space:]]*echo' "$status_sh")"
  else
    pass "no 'grep -c ... || echo' that would emit two lines"
  fi

  # Run it with a fake iw and ip so the AP branch is exercised, and parse the body.
  fixture=$(mktemp -d)
  mkdir -p "$fixture/bin" "$fixture/net/ap0"
  cat > "$fixture/bin/iw" <<'EOF'
#!/bin/bash
case "$*" in
  "dev ap0 info") printf 'Interface ap0\n\tssid X AE A-XII\n\tchannel 9 (2452 MHz), width: 20 MHz\n' ;;
  "dev ap0 station dump") : ;;   # no stations, the case that broke it
  *) exit 0 ;;
esac
EOF
  chmod +x "$fixture/bin/iw"
  sed -e "s|^readonly IW=.*|readonly IW=$fixture/bin/iw|" \
      -e "s|-d /sys/class/net/ap0|-d $fixture/net/ap0|" \
      "$status_sh" > "$fixture/status.sh"
  chmod +x "$fixture/status.sh"

  out=$( cd / && "$fixture/status.sh" 2>/dev/null )
  body=$(printf '%s\n' "$out" | sed -n '/^{/,$p')
  if printf '%s' "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
  then
    pass "output parses as JSON with no stations associated"
  else
    fail "output parses as JSON with no stations associated" \
         "$(printf '%s' "$body" | tail -6 | tr '\n' '|')"
  fi
  if printf '%s' "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ap_clients")=="0" else 1)' 2>/dev/null
  then
    pass "ap_clients is a single 0, not two lines"
  else
    fail "ap_clients is a single 0, not two lines" \
         "got $(printf '%s' "$body" | python3 -c 'import json,sys; print(repr(json.load(sys.stdin).get("ap_clients")))' 2>/dev/null)"
  fi
  rm -rf "$fixture"
else
  fail "status.sh exists" "$status_sh not found"
fi

echo
printf 'passed: %d  failed: %d\n' "$pass_count" "$fail_count"
[ "$fail_count" -eq 0 ] || exit 1
