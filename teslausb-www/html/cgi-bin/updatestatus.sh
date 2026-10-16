#!/bin/bash
# What the boot-time update check found, and whether an update is running now.
# The check writes its state file only once it has an answer, so a missing file
# means not checked yet: no network since boot, or a check still retrying.
readonly STATE_FILE="${STATE_FILE:-/tmp/teslausb-update.json}"

state=null
if [ -s "$STATE_FILE" ] && jq -e . "$STATE_FILE" > /dev/null 2>&1
then
  state=$(jq -c . "$STATE_FILE")
fi

running=false
if systemctl is-active --quiet teslausb-upgrade 2> /dev/null
then
  running=true
fi

cat << EOF
HTTP/1.0 200 OK
Content-type: application/json

{"state":$state,"running":$running}
EOF
