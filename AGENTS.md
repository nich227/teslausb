# Working in this repository

teslausb turns a single-board computer into the USB drive a Tesla records to. This fork is
the [DietPi](https://dietpi.com/) port of [marcone/teslausb](https://github.com/marcone/teslausb).
The code runs unattended, on a device with no keyboard and no screen, in a car, on a
filesystem that is read-only in normal operation, and it loses power without warning every
time the car sleeps. That is the constraint behind most of what follows.

## The one rule that matters

**DietPi is the only supported base.** Setup refuses to run on anything else. Raspberry Pi
OS support was removed deliberately, including the pi-gen image pipeline, and should not
come back by accident.

## Before you change anything

```
./tests/run-integration-tests.sh
```

That is shellcheck, the unit tests, and an integration suite inside a real DietPi
container, with a line coverage gate. It takes a couple of minutes and needs Docker.

```
COVERAGE=1 SHOW_MISSED=1 ./tests/run-integration-tests.sh   # which lines are uncovered
DISTRO=Trixie ./tests/run-integration-tests.sh              # the other Debian release
./tests/vm/lab.sh                                           # two VMs, ~6 minutes, needs KVM
tools/build-image.sh RPi234-ARMv8 Bookworm                  # a flashable image
```

Coverage is gated at **100% of lines**, not as an aspiration. If a new branch cannot be
reached from a test, that is usually a sign it cannot be reached on a device either.

Lint is pinned to a specific shellcheck (0.11.0) in both the suite and CI, because the
version a runner happens to ship reports a different set of findings: an unpinned 0.9.0
raised about forty false positives that a clean local run knew nothing about. Add new
scripts to `check.sh`, and device scripts to the coverage list in `tests/coverage.sh`.

## What "verified" means here

Claims about the device get checked against the device, or against a real DietPi container,
not against expectations. Several things in this port were only found that way:

- Setup aborted at an unbound variable because `configure.sh` runs under `set -u`, and it
  stopped in a state that looked finished: partitions made, cam disk allocated, scripts
  installed, but a writable root and no service. Anything added to that file must take what
  it needs as a parameter.
- Removing DietPi-RAMlog deletes the `/var/log/nginx` mount point, which failed
  `local-fs.target` and dropped the device into emergency mode with no network and no way
  in. Mounts that can vanish carry `nofail`, and that one is recreated.
- The mass-storage gadget holds the cam disk open, so `/backingfiles` could not be
  unmounted on shutdown until `teslausb.service` learned to release it.
- DietPi ships no Bluetooth firmware, so the Tesla BLE feature could not have worked at
  all; `bluez-firmware` provides the file the kernel asks for.
- Sixteen watchdog tests passed on a workstation and did nothing on a CI runner, because a
  container sees the host's `/proc/uptime` and the watchdog ignores the first twenty
  minutes of a boot.
- apt inside the test image reported every repository as unsigned because `_apt` could not
  write to `/tmp`, which only showed up once the build stopped discarding its output.

If a build or test failure prints a path to a log, print the log. Two CI failures here were
invisible for hours because the reason was written to a file nobody ever read, or to a
stdout that was redirected to `/dev/null`.

## Invariants, and why

- **Never disable or remove the console autologin.** DietPi's first run only starts once
  something logs in, and a device in a glovebox has no keyboard. The drop-in must stay
  named `teslausb-autologin.conf`: DietPi deletes `dietpi-autologin.conf` when its own
  first run fails.
- **`/dietpi_skip_partition_resize` is required**, or DietPi expands the root filesystem
  over the whole card and leaves nothing for the recordings. Note that the same branch in
  `fs_partition_resize.sh` also does DietPi's import of `dietpi.txt` and `dietpi-wifi.txt`
  from the boot partition, so that import never happens here. The flashable image works
  around it with `dietpi/Automation_Custom_PreScript.sh`, which `dietpi-firstboot.bash`
  runs before it configures the network.
- **Two destinations in `tools/prepare-boot-partition.sh`.** `TARGET` is DietPi's `/boot`,
  which is on the root filesystem; `TESLAUSB_TARGET` is the partition `/teslausb` will
  point at. DietPi and teslausb read their configuration from different places and neither
  can be moved.
- **Wifi is not optional.** The device is in a car; there is no ethernet.
- `doc/` matches upstream's file list exactly. Port-specific documentation belongs on
  [the wiki](https://github.com/nich227/teslausb/wiki), not in new files here.
- `tests/docker/Dockerfile` installs `jq` and nothing else. The point of testing against a
  bare DietPi is to catch a dependency the code assumes and DietPi omits, so do not paper
  over one by installing it there.
- Do not add quote awareness to `countable_lines()` in `tests/coverage.sh`.

## Style

Follow the surrounding code; it is consistent and deliberate.

Comments explain **why**, especially when the reason is not visible from the code: which
DietPi behaviour forced this, what broke without it, what the obvious alternative was and
why it does not work. A comment that restates the line above it is noise. A comment
recording that SIGWINCH looks like the answer and is not saves the next person an afternoon.

Do not reference dates, releases or past incidents in comments or commit messages. "Fixed
after the 13 September failure" means nothing in a year; "the gadget holds the cam disk
open, so the unmount fails" is still true.

Commit messages say what changed and why it needed changing, in prose, in the same voice as
the code comments. Keep lint fixes in their own commits.

## Layout

```
dietpi/          the bootstrap DietPi runs, the PreScript hook, and the config sample
setup/pi/        setup, driven by first-boot.sh on the device
run/             what runs in normal operation: archiveloop, the watchdog, the gadget
tools/           prepare-boot-partition.sh for a card, build-image.sh for an image
tests/           unit, integration in a DietPi container, and the two-VM lab
doc/             upstream's documentation, unchanged in shape
```

## Releases

Named as upstream names them: the tag is a version (`v6.0`), the release is dated
(`teslausb-20260914.1`). The `image` workflow builds a flashable image per Debian release
on a tag push, checks each one contains the pieces the first boot depends on, and attaches
them. Images stage the source of the commit they were built from, so a release installs the
version it claims to.

## When working on hardware

The device is reachable over ssh and mDNS once it is up. The root filesystem is read-only:
use `/root/bin/remountfs_rw`, and put it back with `mount -o remount,ro /`. Fixes found on
a device belong back in the repository as their own commits, with tests, rather than living
only on the card.

Two things that have each cost a full boot cycle: the write-protect slider on an SD
adapter, which lets a device boot and write nothing, and assuming a config file is being
read from where you put it rather than where DietPi looks for it.
