# teslausb

## Intro

Raspberry Pi and other [SBCs](## "Single Board Computers") can emulate a USB drive, so can act as a drive for your Tesla to write dashcam footage to. Because the SBC has full access to the emulated drive, it can:

- automatically copy the recordings to an archive server when you get home
- hold both dashcam recordings and music files
- automatically repair filesystem corruption produced by the Tesla's current failure to properly dismount the USB drives before cutting power to the USB ports
- serve up a web UI to view or download the recordings
- retain more than one hour of RecentClips (assuming large enough storage)

This video (not mine) has a nice overview of teslausb and how to install it:

[![teslausb intro and installation](http://img.youtube.com/vi/ETs6r1vKTO8/0.jpg)](http://www.youtube.com/watch?v=ETs6r1vKTO8 "teslausb intro and installation")

If you are interested in having more detailed information about how TeslaUsb works, have a look into the [wiki](https://github.com/marcone/teslausb/wiki).

## Prerequisites

### Assumptions

- You park in range of your wireless network.
- Your wireless network is configured with WPA2 PSK access.
- You are running [DietPi](https://dietpi.com/) on the device. DietPi is the only supported OS; Raspberry Pi OS is not supported.

### Hardware

Required:

- [A Raspberry Pi or other SBC that supports USB OTG](https://github.com/marcone/teslausb/wiki/Hardware), with a [DietPi image](https://dietpi.com/#download) available for it.
- A Micro SD card, at least 64 GB in size, and an adapter (if necessary) to connect the card to your computer.
- Cable(s) to connect the SBC to the Tesla (USB A/Micro B cable for the Pi Zero, USB A/C cable for the Pi 4 and 5, other SBCs vary)

Optional:

- A case and/or cooler for the SBC. For the Raspberry Pi 4 I like the ["armor case"](https://www.amazon.com/s?k=Raspberry+Pi+4+Armor+Case) (available with or without fans), which appears to do a good job of protecting the Pi while keeping it cool.
- USB Splitter if you don't want to lose a front USB port. [The Onvian Splitter](https://www.amazon.com/gp/product/B01KX4TKH6) has been reported working by multiple people on reddit. Some SBCs require separate power and data connection, so may require a splitter or a USB hub to connect to the car.

## Installing

Flash a [release image](https://github.com/nich227/teslausb/releases), edit `teslausb_setup_variables.conf` on the partition that appears in your file manager, and boot it. That partition is the one Windows and macOS both mount, so this needs no Linux machine. There is an image per Debian release, Bookworm and Trixie.

The alternative is to flash an official [DietPi image](https://dietpi.com/#download) and run `tools/prepare-boot-partition.sh` against the card, which needs a Linux machine and is what you want if you are building from a branch. Either way the device installs itself on first boot with no keyboard and no screen, and either way the [one step setup instructions](doc/OneStepSetup.md) are the place to start. For SBC-specific hardware notes, the [upstream wiki](https://github.com/marcone/teslausb/wiki/Installation) still applies.

### What differs from the Raspberry Pi OS builds

- **There is no `pi` user.** Log in as `root` or `dietpi`, with the password you set as `OS_PASSWORD`.
- **SSH is OpenSSH.** DietPi ships dropbear, which teslausb replaces: the rsync archive backend runs rsync over ssh, and dropbear provides no `ssh` client at all.
- **The access point runs on hostapd**, alongside the normal wifi connection rather than instead of it, and needs no NetworkManager.
- **Wifi is required, not optional.** The device lives in a car with no ethernet, so DietPi cannot finish its own first boot without working credentials.
- **The console often shows boot output rather than a prompt.** The shell is running and will do whatever you type; the first keypress draws the prompt. A console that looks dead this way is not.

## Testing

`./tests/run-integration-tests.sh` runs shellcheck, the unit tests, and an
integration suite inside a real DietPi container, with a line coverage gate.
`./tests/vm/lab.sh` goes further: it installs a device from scratch in a VM and
archives a clip to a second VM acting as a NAS, in about six minutes. Both run on a
normal Linux machine with Docker and QEMU. See the [wiki](https://github.com/nich227/teslausb/wiki/Testing) for the detail.

`tools/build-image.sh <board> <Bookworm|Trixie>` builds a flashable image for any DietPi
board without needing root.

## Contributing

You're welcome to contribute to this repo by submitting pull requests and creating issues.
For pull requests, please split complex changes into multiple pull requests when feasible, and follow the existing code style.

## Meta

This repo contains steps and scripts originally from [this thread on Reddit](https://www.reddit.com/r/teslamotors/comments/9m9gyk/build_a_smart_usb_drive_for_your_tesla_dash_cam/)

Many people in that thread suggested that the scripts be hosted on GitHub but the author didn't seem interested in making that happen, so GitHub user "cimryan" hosted the scripts on GitHub with the Reddit user's permission.
