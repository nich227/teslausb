#!/bin/bash

# Step the clock as soon as a client network comes up.
#
# WHY: there is no RTC on this hardware. `hwclock -r` reports "Cannot access the
# Hardware Clock via any known method", so at boot the clock is whatever
# fake-hwclock saved at the last shutdown, and the device is powered from the car's
# USB port, so it boots whenever the car wakes and that saved value can be hours or
# days stale.
#
# ntpsec runs and does correct it, but not immediately: it disciplines the clock
# over minutes rather than stepping it at once. Everything logged in between carries
# the stale timestamp, which makes archiveloop.log read out of order. A real example
# from a single boot, where a block timestamped 21:17 was written after entries
# timestamped 21:50, and the clock only jumped forward when teslausb's own set_time
# ran at the start of an archive cycle:
#
#   Sat 12 Sep 21:50:14: Archiving 153 file(s)
#   ==============================================
#   Sat 12 Sep 21:17:01: Starting archiveloop at 11.00 seconds uptime...
#   ...
#   Sat 12 Sep 22:22:23: Trying to set time...
#   Sat 12 Sep 22:22:23: Time adjusted by 0.210211 seconds
#
# Hours were spent reading those timestamps as real. Stepping the clock when the
# network appears means anything logged after that point is trustworthy.
#
# ONLY FOR CLIENT INTERFACES: the access point interface coming up says nothing
# about reaching the internet, and lo says nothing at all.
#
# The sync runs in the background. ifupdown runs these hooks synchronously, and a
# reachable-but-slow time server would otherwise hold up bringing the network up.
#
# Servers match the ones teslausb's own set_time uses, so there is one set of
# choices rather than two.

set -u

readonly AP_IFACE="${AP_IFACE:-ap0}"
readonly TIME_SERVERS="${TIME_SERVERS:-time.google.com 129.6.15.28}"
readonly SYNC_LOG="${SYNC_LOG:-/dev/null}"

iface="${IFACE:-${1:-}}"

case "$iface" in
  "" | lo | "$AP_IFACE")
    exit 0
    ;;
esac

# ifupdown sets MODE=start for an interface coming up; anything else is not ours.
if [ -n "${MODE:-}" ] && [ "$MODE" != "start" ]
then
  exit 0
fi

sync_clock () {
  local server rc
  for server in $TIME_SERVERS
  do
    for tool in sntp ntpdig
    do
      command -v "$tool" > /dev/null 2>&1 || continue
      # -S steps the clock rather than slewing it, which is the point: a stale
      # fake-hwclock value can be hours out and slewing would take far too long.
      if timeout 20 "$tool" -S "$server" > /dev/null 2>&1
      then
        logger -t teslausb-timesync "stepped the clock from $server after $iface came up" 2> /dev/null || true
        echo "$(date -Is) stepped from $server via $tool on $iface" >> "$SYNC_LOG" 2> /dev/null || true
        return 0
      fi
      rc=$?
      echo "$(date -Is) $tool $server failed rc=$rc" >> "$SYNC_LOG" 2> /dev/null || true
    done
  done
  logger -t teslausb-timesync "could not reach a time server after $iface came up" 2> /dev/null || true
  return 1
}

if [ -n "${TESLAUSB_TIMESYNC_FOREGROUND:-}" ]
then
  # The tests want to observe the result rather than race a background job.
  sync_clock
else
  sync_clock &
fi

exit 0
