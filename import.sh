#!/bin/bash
# Import an official Raspberry Pi OS image as a Docker base image,
# with the boot partition included under /boot/firmware.
# Usage: sudo ./import.sh <image.img.xz|image.zip> [tag]

set -e

# Colored step message (plain when stdout isn't a terminal)
[ -t 1 ] && STEP_FMT='\033[1;34m==>\033[0m %s\n' || STEP_FMT='==> %s\n'
step() { printf "$STEP_FMT" "$*"; }

if [ "$#" -lt 1 ]; then
    echo "Usage: sudo $0 <image.img.xz|image.zip> [tag]"
    exit 1
fi
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root access. Please run as root or use sudo."
    exit 1
fi

IMAGE_PATH="$1"
case "$IMAGE_PATH" in
    *.img.xz) IMAGE_NAME=$(basename "$IMAGE_PATH" .img.xz) ;;
    *.zip)    IMAGE_NAME=$(basename "$IMAGE_PATH" .zip) ;;
    *) echo "Error: source image must be a .img.xz or .zip file."; exit 1 ;;
esac

WORKDIR=$(mktemp -d /tmp/raspios-import.XXXXXX)
LOOP=""

cleanup() {
    umount "$WORKDIR/rootfs/boot/firmware" 2>/dev/null || true
    umount "$WORKDIR/rootfs" 2>/dev/null || true
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT


step "Extracting $IMAGE_PATH"
case "$IMAGE_PATH" in
    *.img.xz) xz -c -d "$IMAGE_PATH" > "$WORKDIR/image.img" ;;
    *.zip)    unzip -p "$IMAGE_PATH" "$IMAGE_NAME.img" > "$WORKDIR/image.img" ;;
esac

step "Mounting partitions"
LOOP=$(losetup -f --partscan --show "$WORKDIR/image.img")
mkdir -p "$WORKDIR/rootfs"
mount -o ro "${LOOP}p2" "$WORKDIR/rootfs"
mount -o ro "${LOOP}p1" "$WORKDIR/rootfs/boot/firmware"

step "Importing as docker image"
TAG="${2:-raspios-base:$(sha256sum "$IMAGE_PATH" | cut -c1-12)}"
echo "    Image tag: $TAG"
tar -C "$WORKDIR/rootfs" -cf - . | docker import --platform linux/arm64 - "$TAG"

echo $TAG
