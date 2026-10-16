#!/bin/bash

# Look once per boot for a teslausb release newer than this install, and say so.
#
# The result goes to a state file the web interface reads, and when there is a
# release to offer, to the console as well: the device has no screen most of the
# time, but when one is attached, tty1 is where anyone looking will be looking.
#
# NEWER MEANS AHEAD, NOT DIFFERENT: an install from main-dev usually carries
# commits the latest release does not, and offering that release would be offering
# a downgrade. GitHub's compare answers the question directly: the release is only
# offered when it contains this install's commit and more.
#
# The device boots whenever the car wakes, often out of range of any network, and
# the clock has no RTC behind it, so an early attempt can fail on DNS or on TLS
# with a stale date. It keeps trying for a while rather than give up on the first.
#
# With --notice it prints the notice from the last check and touches nothing, for
# the login shell.

set -u

readonly VERSION_FILE="${VERSION_FILE:-/etc/teslausb-version}"
readonly STATE_FILE="${STATE_FILE:-/tmp/teslausb-update.json}"
readonly CONSOLE="${CONSOLE:-/dev/tty1}"
readonly API="${GITHUB_API:-https://api.github.com}"
readonly ATTEMPTS="${ATTEMPTS:-30}"
readonly INTERVAL="${INTERVAL:-60}"

notice () {
  # $1 latest tag, $2 release name, $3 installed commit
  cat << EOF

  ************************************************************************
    A new teslausb release is available: $1 ($2)
    This device runs ${3:0:7}.
    Update from the web interface, or as root run
    TESLAUSB_UPGRADE_REF=$1 /root/bin/setup-teslausb upgrade
  ************************************************************************

EOF
}

if [ "${1:-}" = "--notice" ]
then
  if [ "$(jq -r '.available // false' "$STATE_FILE" 2> /dev/null)" = "true" ]
  then
    notice "$(jq -r .latest "$STATE_FILE")" "$(jq -r .name "$STATE_FILE")" "$(jq -r .current "$STATE_FILE")"
  fi
  exit 0
fi

repo=$(sed -n 's/^repo=//p' "$VERSION_FILE" 2> /dev/null)
commit=$(sed -n 's/^commit=//p' "$VERSION_FILE" 2> /dev/null)

# Without the commit this install came from there is nothing to compare, and a
# notice on every boot that might be wrong is worse than none.
if [ -z "$repo" ] || [ -z "$commit" ]
then
  logger -t teslausb-update-check "no installed commit recorded in $VERSION_FILE, not checking" 2> /dev/null || true
  exit 0
fi

github () {
  curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' "$API/repos/$repo/teslausb/$1"
}

attempt=0
until release=$(github releases/latest) && compare=$(github "compare/$commit...$(jq -r .tag_name <<< "$release")")
do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge "$ATTEMPTS" ]
  then
    logger -t teslausb-update-check "could not reach GitHub after $attempt tries" 2> /dev/null || true
    exit 0
  fi
  sleep "$INTERVAL"
done

latest=$(jq -r .tag_name <<< "$release")
available=false
if [ "$(jq -r .status <<< "$compare")" = "ahead" ]
then
  available=true
fi

# Written whole and then moved, so the web interface never reads half a file.
jq -n --arg checked "$(date -Is)" --arg current "$commit" --arg latest "$latest" \
  --arg name "$(jq -r '.name // ""' <<< "$release")" --arg url "$(jq -r '.html_url // ""' <<< "$release")" \
  --argjson available "$available" \
  '{checked: $checked, current: $current, latest: $latest, name: $name, url: $url, available: $available}' \
  > "$STATE_FILE.tmp" && mv -f "$STATE_FILE.tmp" "$STATE_FILE"

logger -t teslausb-update-check "latest release $latest, installed ${commit:0:7}, update available: $available" 2> /dev/null || true

if [ "$available" = "true" ]
then
  notice "$latest" "$(jq -r '.name // ""' <<< "$release")" "$commit" > "$CONSOLE" 2> /dev/null || true
fi

exit 0
