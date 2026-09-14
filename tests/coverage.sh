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
    dietpi/Automation_Custom_PreScript.sh
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
# Work out which lines bash can actually report as executed, and group the lines
# of a single logical command together.
#
# bash traces simple commands, and for a command spread over several lines it
# reports the line where the command *finishes*. So a continuation group is
# emitted as one colon-joined unit, counted once, and covered if any of its lines
# was reported. These never appear at all and are not counted:
#   - blank lines and comments
#   - block structure (fi/done/else/esac/braces/then/do), including terminators
#     carrying a redirection
#   - function definition headers
#   - here-document bodies and their terminators
#   - case patterns and ;;& / ;& fallthroughs
countable_lines () {
  awk '
    function strip(s) { sub(/^[[:blank:]]+/, "", s); sub(/[[:blank:]]+$/, "", s); return s }
    function flush() {
      if (group != "") { print group; group = "" }
    }
    {
      line = $0
      s = strip(line)

      if (in_heredoc) {
        if (s == heredoc_tag) { in_heredoc = 0 }
        next
      }

      if (continued) {
        group = group ":" NR
        if (s !~ /\\$/) { continued = 0; flush() }
        next
      }

      if (match(line, /<<-?[[:blank:]]*[\x27"]?[A-Za-z_][A-Za-z0-9_]*[\x27"]?/)) {
        tag = substr(line, RSTART, RLENGTH)
        gsub(/^<<-?[[:blank:]]*/, "", tag)
        gsub(/[\x27"]/, "", tag)
        heredoc_tag = tag
        in_heredoc = 1
      }

      if (s == "" || s ~ /^#/) next
      if (s == "fi" || s == "done" || s == "else" || s == "esac" || s == "}" || s == "{" || \
          s == "then" || s == "do" || s == ";;" || s == ";&" || s == ";;&" || s == "))" || s ~ /^\)/) next
      if (s ~ /^(done|fi|esac|\})[[:blank:]]*([0-9]*[<>&]|\|)/) next
      if (s ~ /^function[[:blank:]]/ || s ~ /^[A-Za-z_][A-Za-z0-9_]*[[:blank:]]*\([[:blank:]]*\)/) next
      # a case pattern: something ending in ) with no command before it
      if (s ~ /^[^(){};&]*\)$/ && s !~ /=/) next

      group = NR
      if (s ~ /\\$/) { continued = 1; next }
      flush()
    }
    END { flush() }
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
  while IFS= read -r group
  do
    lines=$(( lines + 1 ))
    covered=0
    for n in ${group//:/ }
    do
      if grep -qx "${base}:${n}" "$executed" 2> /dev/null
      then
        covered=1
        break
      fi
    done
    if [ "$covered" = 1 ]
    then
      hit=$(( hit + 1 ))
    else
      missed="$missed ${group%%:*}"
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
