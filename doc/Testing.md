# Testing

Three layers, fastest first. All of them run on a normal Linux machine with Docker
and QEMU; none of them need a Pi or a car.

| Layer | What it proves | Time |
| --- | --- | --- |
| unit | the watchdog's decisions, in isolation | seconds |
| integration | the setup scripts against a real DietPi filesystem | ~2 minutes |
| lab | a device installs itself and archives a clip to a NAS | ~6 minutes |

## Everything at once

```
./tests/run-integration-tests.sh
```

That runs shellcheck over every script, the unit tests, and the integration suite
inside a DietPi container, then checks line coverage. Coverage is gated: the run
fails below `COVERAGE_MIN`, which is 100.

Useful variables:

```
COVERAGE=1 SHOW_MISSED=1 ./tests/run-integration-tests.sh   # list uncovered lines
COVERAGE_MIN=100 ./tests/run-integration-tests.sh           # the gate CI uses
```

## Unit tests

```
./tests/usb-link-watchdog-test.sh
```

The watchdog decides whether to reboot a device whose USB link has stalled, which
is a decision worth being sure about: rebooting mid-archive loses footage, and not
rebooting a wedged device loses all of it. Every environment dependency is
overridable, so the tests drive it through each dashcam state, uptime, cooldown and
file-boundary case without touching the system.

## Integration suite

```
docker build -f tests/docker/Dockerfile -t teslausb-test:bookworm tests/docker
docker run --rm --cap-add=SYS_ADMIN --security-opt apparmor=unconfined \
  -e COVERAGE=1 teslausb-test:bookworm
```

The container is built from the official DietPi container image, so the scripts run
against DietPi's real layout: its `dietpi.txt`, its `/boot/dietpi` tooling, its
package state. The suite covers the boot partition preparation, the bootstrap, the
platform gate, wifi handling, the access point configuration, the openssh switch,
and the watchdog and keeper installers.

`tests/docker/build-dietpi-base.sh` builds the base images (`bookworm` and
`trixie`) from DietPi's published containers, verifying their checksums.

## The lab

```
./tests/vm/lab.sh                      # cifs, the default
./tests/vm/lab.sh --archive rsync      # rsync over ssh
./tests/vm/lab.sh --ap                 # also exercise the access point
./tests/vm/lab.sh --start-dropbear     # make teslausb replace dropbear
./tests/vm/lab.sh --keep --shell zsh   # leave the VMs up to poke at
```

Two VMs on a private segment that nothing else can reach:

- **the device**, an official DietPi image with nothing but a config file on its
  boot partition, which installs itself exactly as a real one does. Its disk is a
  sparse 40G file, because setup refuses to install with less than 32GiB of
  unpartitioned space.
- **the NAS**, a Debian cloud image configured by cloud-init, serving SMB or ssh.

A run asserts, among other things, that DietPi's first boot completes, that setup
partitions the disk and builds the backing files, that openssh replaced dropbear,
that `teslausb.local` resolves and answers from another machine, that the web
interface responds, and that a clip seeded into `SavedClips` arrives on the NAS
intact.

With `--ap`, `mac80211_hwsim` provides two simulated radios: the access point runs
on one and a client associates from the other, completing a WPA2 handshake, taking
a DHCP lease and fetching the web interface over that link.

`--keep` leaves both VMs running; the summary prints how to reach them.

### What the lab cannot cover

- **The USB gadget.** QEMU has no UDC, so the device cannot present itself as a
  drive. Setup's check for one is bypassed in the lab, deliberately and only there.
- **Real wifi association to a real access point.** The simulated radios cover the
  software; antennas and drivers are hardware.
- **rclone, nfs and the `none` archive backends.** Only cifs and rsync are driven
  end to end.

## CI

| Workflow | Runs |
| --- | --- |
| `tests.yml` | unit and integration, on every push |
| `lab.yml` | the lab, on anything touching setup, run, tools, dietpi or tests/vm; also nightly |
| `ui.yml` | typecheck and Prettier for the web UI |
| `shellcheck.yml` | shellcheck |

The lab needs nested virtualisation. GitHub's Linux runners have `/dev/kvm` but do
not make it group-accessible, so the workflow adds a udev rule and fails early if
KVM is still unusable, rather than falling back to emulation and timing out.
