#!/bin/bash
#
# Line coverage for the bash scripts under test.
#
# There is no coverage tooling in this repo's toolchain, so this uses bash's own
# xtrace: every script run under the test suites is traced with a PS4 that
# records source file and line number, and the executed lines are compared
# against the lines that are actually executable.
#
# "Executable" excludes blank lines, comments, and pure structure (fi/done/else/
# esac/{/}/function headers), because bash never reports those as executed and
# counting them would understate coverage.
#
# Usage: tests/coverage.sh [--min PERCENT] [file ...]
#   With no files, reports on the scripts the suites exercise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO="$SCRIPT_DIR/.."
readonly TRACE_DIR="${TRACE_DIR:-/tmp/teslausb-coverage}"

MIN=0
if [ "${1:-}" = "--min" ]
then
  MIN="$2"
  shift 2
fi

if [ $# -gt 0 ]
then
  TARGETS=("$@")
else
  TARGETS=(
    run/usb-link-watchdog.sh
    setup/pi/first-boot.sh
    dietpi/Automation_Custom_Script.sh
    tools/prepare-boot-partition.sh
  )
fi

if [ ! -d "$TRACE_DIR" ] || [ -z "$(ls -A "$TRACE_DIR" 2> /dev/null)" ]
then
  echo "no traces in $TRACE_DIR; run the test suites with COVERAGE=1 first" >&2
  exit 1
fi

# Collect every "file:line" the traces recorded.
executed=$(mktemp)
# shellcheck disable=SC2016  # the PS4 marker is a literal string in the traces
grep -ho '^+*COV:[^:]*:[0-9]*' "$TRACE_DIR"/* 2> /dev/null |
  sed 's/^+*COV://' |
  sort -u > "$executed"

# Work out which lines bash can actually report as executed. It traces simple
# commands, so these never appear and must not be counted against coverage:
#   - blank lines and comments
#   - pure structure (fi/done/else/esac/braces/then/do)
#   - function definition headers
#   - here-document bodies and their terminators
#   - continuation lines of a command that started earlier
countable_lines () {
  awk '
    function strip(s) { sub(/^[[:blank:]]+/, "", s); sub(/[[:blank:]]+$/, "", s); return s }
    {
      line = $0
      s = strip(line)

      # inside a here-document: skip until the terminator
      if (in_heredoc) {
        if (s == heredoc_tag) { in_heredoc = 0 }
        next
      }

      # continuation of the previous logical line
      if (continued) {
        if (s !~ /\\$/) { continued = 0 }
        next
      }

      # does this line open a here-document?
      if (match(line, /<<-?[[:blank:]]*[\x27"]?[A-Za-z_][A-Za-z0-9_]*[\x27"]?/)) {
        tag = substr(line, RSTART, RLENGTH)
        gsub(/^<<-?[[:blank:]]*/, "", tag)
        gsub(/[\x27"]/, "", tag)
        heredoc_tag = tag
        in_heredoc = 1
        # the line itself still holds a command, so fall through and count it
      } else if (s ~ /\\$/) {
        continued = 1
      }

      if (s == "" || s ~ /^#/) next
      if (s == "fi" || s == "done" || s == "else" || s == "esac" || s == "}" || s == "{" || \
          s == "then" || s == "do" || s == ";;" || s == "))" || s ~ /^\)/) next
      # a block terminator carrying a redirection belongs to the compound
      # command, which bash traces on its opening line instead
      if (s ~ /^(done|fi|esac|\})[[:blank:]]*([0-9]*[<>&]|\|)/) next
      # function headers are not traced
      if (s ~ /^function[[:blank:]]/ || s ~ /^[A-Za-z_][A-Za-z0-9_]*[[:blank:]]*\([[:blank:]]*\)/) next

      print NR
    }
  ' "$1"
}

total_exec=0
total_hit=0
failed=0

printf '%-46s %8s %8s %7s\n' "file" "covered" "lines" "percent"
printf '%s\n' "---------------------------------------------------------------------"

for target in "${TARGETS[@]}"
do
  path="$REPO/$target"
  [ -f "$path" ] || { echo "missing: $target" >&2; continue; }
  base=$(basename "$target")

  lines=0
  hit=0
  missed=""
  while IFS= read -r n
  do
    lines=$(( lines + 1 ))
    if grep -qx "${base}:${n}" "$executed" 2> /dev/null
    then
      hit=$(( hit + 1 ))
    else
      missed="$missed $n"
    fi
  done < <(countable_lines "$path")

  pct=0
  [ "$lines" -gt 0 ] && pct=$(( hit * 100 / lines ))
  printf '%-46s %8d %8d %6d%%\n' "$target" "$hit" "$lines" "$pct"
  if [ -n "${SHOW_MISSED:-}" ] && [ -n "$missed" ]
  then
    printf '    uncovered lines:%s\n' "$missed"
  fi

  total_exec=$(( total_exec + lines ))
  total_hit=$(( total_hit + hit ))
done

printf '%s\n' "---------------------------------------------------------------------"
total_pct=0
[ "$total_exec" -gt 0 ] && total_pct=$(( total_hit * 100 / total_exec ))
printf '%-46s %8d %8d %6d%%\n' "TOTAL" "$total_hit" "$total_exec" "$total_pct"

rm -f "$executed"

if [ "$total_pct" -lt "$MIN" ]
then
  echo
  echo "FAIL: coverage ${total_pct}% is below the required ${MIN}%"
  failed=1
fi

exit "$failed"
