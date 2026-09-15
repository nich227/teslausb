#!/bin/bash
# Reports whether the root filesystem is mounted read-write (vs read-only).
opts=$(awk '$2=="/"{print $4; exit}' /proc/mounts)
case "$opts" in
  ro*) rw=no ;;
  *) rw=yes ;;
esac

cat << EOF
HTTP/1.0 200 OK
Content-type: application/json

{"rw":"$rw"}
EOF
