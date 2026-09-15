#!/bin/bash -eu

# rsync 3.2.4 made arg protection the default: the remote path is handed to the remote rsync
# over the protocol instead of being parsed by a remote shell. That quietly changed what a
# config means. A space in the path used to have to be escaped, because a shell saw it, and
# an escaped space now arrives literally, so a config that was correct on an older rsync
# archives into a directory with a backslash in its name and leaves the real one alone.
#
# Seen on a device whose recordings had been landing in "Tesla Cam" for months and which
# started a second "Tesla\ Cam" beside it once the rsync version changed underneath it.
# Nobody means that directory, and with args protected there is no shell left for the escape
# to be for, so drop it and say so rather than archive somewhere the owner will not look.
if [[ "$RSYNC_PATH" == *'\ '* ]]
then
  echo "$(date): RSYNC_PATH is '$RSYNC_PATH'. Modern rsync takes that literally, backslashes" \
       "and all, so archiving to '${RSYNC_PATH//\\ / }' instead. Remove the backslashes from" \
       "RSYNC_PATH to silence this." >> /tmp/archive-rsync-cmd.log
  RSYNC_PATH="${RSYNC_PATH//\\ / }"
fi

while [ -n "${1+x}" ]
do
  if ! (rsync -avhRL --timeout=60 --remove-source-files --no-perms --omit-dir-times \
        --stats --log-file=/tmp/archive-rsync-cmd.log --ignore-missing-args \
        --files-from="$2" "$1" "$RSYNC_USER@$RSYNC_SERVER:$RSYNC_PATH" &> /tmp/rsynclog || [[ "$?" = "24" ]] )
  then
    cat /tmp/archive-rsync-cmd.log /tmp/rsynclog > /tmp/archive-error.log
    exit 1
  fi
  shift 2
done
