#!/bin/bash
# Reports whether an archive/sync run is currently active, by checking for the
# mounted archive share or a running archive-clips.sh process.
if grep -q ' /mnt/archive ' /proc/mounts 2>/dev/null || pgrep -f 'archive-clips\.sh' > /dev/null 2>&1
then
  archiving=yes
else
  archiving=no
fi

cat << EOF
HTTP/1.0 200 OK
Content-type: application/json

{"archiving":"$archiving"}
EOF
