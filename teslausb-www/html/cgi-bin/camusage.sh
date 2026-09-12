#!/bin/bash
# Per-category TeslaCam usage for the dashboard pie chart.
#
# Performance:
#  - Sizes are summed from the source symlink tree (/mutable/TeslaCam) with `du -L`,
#    which is ~4x faster than du'ing the cttseraser FUSE mount (no userspace
#    passthrough per file).
#  - Results are cached in /tmp with a short TTL. A fresh cache is returned
#    instantly; a stale cache is returned immediately and refreshed in the
#    background (stale-while-revalidate), so the pie only ever blocks on the very
#    first run after boot.
CACHE=/tmp/camusage.json
LOCK=/tmp/camusage.lock
SRC=/mutable/TeslaCam
TTL=300

emit() {
  cat << HDR
HTTP/1.0 200 OK
Content-type: application/json

$1
HDR
}

compute() {
  local r s v
  r=$(sudo du -sbL "$SRC/RecentClips" 2>/dev/null | cut -f1)
  s=$(sudo du -sbL "$SRC/SentryClips" 2>/dev/null | cut -f1)
  v=$(sudo du -sbL "$SRC/SavedClips" 2>/dev/null | cut -f1)
  printf '{"RecentClips":%s,"SentryClips":%s,"SavedClips":%s}' "${r:-0}" "${s:-0}" "${v:-0}"
}

if [ -f "$CACHE" ]; then
  emit "$(cat "$CACHE")"
  age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
  if [ "$age" -ge "$TTL" ]; then
    # Refresh in the background (detached so fcgiwrap doesn't reap it).
    # The quote-juggling below deliberately expands $LOCK/$SRC/$CACHE in the
    # parent shell before the child sees them.
    # shellcheck disable=SC2016
    setsid bash -c '
      exec 9>"'"$LOCK"'"
      flock -n 9 || exit 0
      r=$(sudo du -sbL "'"$SRC"'/RecentClips" 2>/dev/null | cut -f1)
      s=$(sudo du -sbL "'"$SRC"'/SentryClips" 2>/dev/null | cut -f1)
      v=$(sudo du -sbL "'"$SRC"'/SavedClips" 2>/dev/null | cut -f1)
      printf "{\"RecentClips\":%s,\"SentryClips\":%s,\"SavedClips\":%s}" "${r:-0}" "${s:-0}" "${v:-0}" > "'"$CACHE"'.tmp"
      mv "'"$CACHE"'.tmp" "'"$CACHE"'"
    ' >/dev/null 2>&1 </dev/null &
  fi
  exit 0
fi

# First run after boot: compute synchronously, cache, return.
result=$(compute)
echo "$result" > "$CACHE"
emit "$result"
