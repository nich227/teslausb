#!/bin/bash

# Make the console shell print a fresh prompt when boot output has painted over it.
#
# The autologin shell draws its prompt as soon as it starts, and anything written to the
# console afterwards lands on top of it. readline only draws a prompt when it begins
# reading a line, so what is left on screen is output with nothing to type at, even
# though the shell is alive and will run whatever is typed. A keypress fixes it, and a
# device in a glovebox has no keyboard to provide one.
#
# Pushing a newline into the terminal's input queue is the same as pressing Enter: the
# shell accepts an empty line and prints a new prompt. Sending SIGWINCH does not work,
# which was worth learning the hard way.
#
# Run on a repeating timer, because output does not stop at a predictable point: teslausb
# setup writes to the console for several minutes after the first boot, long after any
# one-shot redraw would have happened. To keep that from adding a prompt every time it
# runs, it only acts when the cursor sits at column 0, which means nothing is drawn on
# the current line. A prompt always leaves the cursor to the right of itself, so once one
# is on screen this does nothing at all.
#
# This is cosmetic. It must never fail a boot.

[ -c /dev/tty1 ] || exit 0
[ -c /dev/vcsa1 ] || exit 0

# pgrep cannot filter by controlling terminal, so ps it is
# shellcheck disable=SC2009
ps -t tty1 -o comm= 2> /dev/null | grep -q bash || exit 0

# /dev/vcsa1 starts with four bytes: rows, columns, cursor column, cursor row
cursor_column=$(dd if=/dev/vcsa1 bs=1 skip=2 count=1 2> /dev/null | od -An -tu1 | tr -d ' \n')
[ "${cursor_column:-0}" = 0 ] || exit 0

python3 - <<'PY' 2> /dev/null || true
import fcntl, termios
try:
    with open('/dev/tty1', 'w') as tty:
        fcntl.ioctl(tty, termios.TIOCSTI, '\n')
except Exception:
    pass
PY

exit 0
