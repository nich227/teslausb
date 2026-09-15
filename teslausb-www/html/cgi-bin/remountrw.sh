#!/bin/bash
# Enables read-write mode on the root filesystem (teslausb is read-only by
# default). There is no supported "remount read-only" while running, so to
# return to read-only the user reboots the Pi.
sudo /root/bin/remountfs_rw > /dev/null 2>&1
result=$?
opts=$(awk '$2=="/"{print $4; exit}' /proc/mounts)
case "$opts" in
  ro*) rw=no ;;
  *) rw=yes ;;
esac

cat << EOF
HTTP/1.0 200 OK
Content-type: application/json

{"rw":"$rw","result":"$result"}
EOF
