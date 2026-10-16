#!/bin/bash
# Start an upgrade to the release the boot-time check offered.
#
# The tag comes from the check's state file, which only root writes, and never from
# the request, so the most a caller can do is ask for the update the device itself
# found. POST only, so a link or a prefetch cannot start one.
#
# The upgrade runs as its own systemd unit rather than as a child of this script:
# it stops nginx and replaces the web root partway through, which would take down
# anything fcgiwrap started. The unit name doubles as the lock, since systemd will
# not start a second unit with the same name.
#
# It is refused while an archive runs. The upgrade kills archiveloop without the
# awake_stop that ends a run, which would leave the car held awake and Sentry on.
readonly STATE_FILE="${STATE_FILE:-/tmp/teslausb-update.json}"

reply () {
  # $1 status line, $2 json body
  cat << EOF
HTTP/1.0 $1
Content-type: application/json

$2
EOF
  exit 0
}

if [ "${REQUEST_METHOD:-}" != "POST" ]
then
  reply "405 Method Not Allowed" '{"started":false,"reason":"POST only"}'
fi

tag=$(jq -r 'select(.available == true) | .latest' "$STATE_FILE" 2> /dev/null)
if ! [[ "$tag" =~ ^v[0-9]+(\.[0-9]+)*$ ]]
then
  reply "409 Conflict" '{"started":false,"reason":"no update is available"}'
fi

if systemctl is-active --quiet teslausb-upgrade 2> /dev/null
then
  reply "409 Conflict" '{"started":false,"reason":"an update is already running"}'
fi

if grep -q ' /mnt/archive ' /proc/mounts 2> /dev/null || pgrep -f 'archive-clips\.sh' > /dev/null 2>&1
then
  reply "409 Conflict" '{"started":false,"reason":"an archive is running; try again when it finishes"}'
fi

if ! sudo systemd-run --unit=teslausb-upgrade --collect --setenv=TESLAUSB_UPGRADE_REF="$tag" \
  /root/bin/setup-teslausb upgrade > /dev/null 2>&1
then
  reply "500 Internal Server Error" '{"started":false,"reason":"could not start the update"}'
fi

reply "200 OK" "{\"started\":true,\"tag\":\"$tag\"}"
