#!/bin/bash
#
# Runs INSIDE the extraction toolbox container (see build-dietpi-base.sh).
#
# Turns /cache/$IMAGE_NAME (a DietPi container disk image) into
# /cache/dietpi-rootfs.tar. The ext4 root partition is read with debugfs
# rather than mounted, so this needs no loop device and no privileges beyond
# being root inside the container.

set -euo pipefail

: "${IMAGE_NAME:?IMAGE_NAME must be set}"

apt-get -qq update
apt-get -qq install -y --no-install-recommends xz-utils e2fsprogs fdisk > /dev/null

cd /tmp
echo "decompressing $IMAGE_NAME"
xz -dc "/cache/$IMAGE_NAME" > disk.img

sectorsize=$(sfdisk -d disk.img | sed -n 's/^sector-size:[[:space:]]*\([0-9]*\).*/\1/p')
: "${sectorsize:=512}"

# Pick the largest Linux partition (MBR type 83 or the GPT Linux filesystem
# GUID); on the container images there is only one, but do not rely on that.
# sfdisk -d pads its values ("start=        2048"), so match on the whole line.
best=0
start=""
size=""
while IFS= read -r line
do
  s=$(printf '%s' "$line" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  z=$(printf '%s' "$line" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  if [ -z "$s" ] || [ -z "$z" ]
  then
    continue
  fi
  if [ "$z" -gt "$best" ]
  then
    best="$z"
    start="$s"
    size="$z"
  fi
done < <(sfdisk -d disk.img | grep -E 'type=(83|0FC63DAF-8483-4772-8E79-3D69D8477DE4)')

if [ -z "${start:-}" ] || [ -z "${size:-}" ]
then
  echo "FATAL: could not locate a Linux partition" >&2
  sfdisk -d disk.img >&2
  exit 1
fi
echo "root partition: start=${start} size=${size} sectors of ${sectorsize} bytes"

dd if=disk.img of=root.img bs="$sectorsize" skip="$start" count="$size" status=none
rm -f disk.img

mkdir -p /tmp/rootfs
if ! debugfs -R "rdump / /tmp/rootfs" root.img 2> /tmp/debugfs.log
then
  cat /tmp/debugfs.log >&2
  exit 1
fi
rm -f root.img

# 'rdump /' creates a directory named after the source root inside the target.
if [ ! -d /tmp/rootfs/etc ]
then
  inner=$(find /tmp/rootfs -maxdepth 2 -type d -name etc -print -quit)
  if [ -n "$inner" ]
  then
    mv "$(dirname "$inner")" /tmp/rootfs.real
    rm -rf /tmp/rootfs
    mv /tmp/rootfs.real /tmp/rootfs
  fi
fi

if [ ! -d /tmp/rootfs/etc ]
then
  echo "FATAL: no /etc in the extracted rootfs" >&2
  find /tmp/rootfs -maxdepth 2 >&2
  exit 1
fi

tar -C /tmp/rootfs -cf /cache/dietpi-rootfs.tar .
echo "rootfs tar: $(du -h /cache/dietpi-rootfs.tar | cut -f1)"
