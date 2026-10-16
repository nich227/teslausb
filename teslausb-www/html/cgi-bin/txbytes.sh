#!/bin/bash
# Reports the bytes transmitted on the wifi interface so far, with a timestamp,
# so the dashboard can show an upload rate while an archive run is in progress.
# Two samples are enough for a rate, and taking the timestamp here rather than
# in the browser keeps request latency out of the measurement.
#
# Only the client interface counts. The device is in a car with no ethernet, so
# everything archived leaves through wlan0, and the access point's ap0 does not
# match 'wl*' and so is not included: its traffic is the viewer, not the archive.
wifidev=$(find /sys/class/net/ -type l -name 'wl*' -printf '%P' -quit)

tx_bytes=0
if [ -n "$wifidev" ] && [ -r "/sys/class/net/$wifidev/statistics/tx_bytes" ]
then
  read -r tx_bytes < "/sys/class/net/$wifidev/statistics/tx_bytes"
fi

cat << EOF
HTTP/1.0 200 OK
Content-type: application/json

{"ms":$(date +%s%3N),"tx_bytes":$tx_bytes}
EOF
