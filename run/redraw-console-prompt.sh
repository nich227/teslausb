#!/bin/bash

# Make the console shell print a fresh prompt.
#
# The autologin shell draws its prompt as soon as it starts, and boot messages then
# land on the console on top of it. readline only draws a prompt when it begins
# reading a line, so what is left on screen is a banner with nothing to type at, even
# though the shell is alive and will run whatever is typed. A keypress fixes it, and a
# device in a glovebox has no keyboard to provide one.
#
# Pushing a newline into the terminal's input queue is the same as pressing Enter: the
# shell accepts an empty line and prints a new prompt. Sending SIGWINCH does not work,
# which was worth learning the hard way.
#
# This is cosmetic. It must never fail a boot.

[ -c /dev/tty1 ] || exit 0
# pgrep cannot filter by controlling terminal, so ps it is
# shellcheck disable=SC2009
ps -t tty1 -o comm= 2> /dev/null | grep -q bash || exit 0

python3 - <<'PY' 2> /dev/null || true
import fcntl, termios
try:
    with open('/dev/tty1', 'w') as tty:
        fcntl.ioctl(tty, termios.TIOCSTI, '\n')
except Exception:
    pass
PY

exit 0
