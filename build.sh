#!/bin/bash

WORKDIR="/tmp/raspios-squashfs-build"

set -e

# Check if exactly one argument is provided
if [ "$#" -ne 1 ]; then
    echo "Error: You must supply the source image file."
    exit 1
fi
IMAGE="$1"

# Check for root access
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root access. Please run as root or use sudo."
    exit 1
fi

NAME=$(basename $IMAGE .img.xz)
echo "Building $NAME"

mkdir -p "$WORKDIR/"
echo "Extracting image file $IMAGE"
xz -c -d "$IMAGE" > "$WORKDIR/$NAME.img"

echo "Detecting partions in $WORKDIR/$NAME.img"
LOOP_DEVICE=$(losetup -f --partscan --show "$WORKDIR/$NAME.img")

echo "Mounting partitions using device: $LOOP_DEVICE"
mkdir "$WORKDIR/rootfs/"
mkdir "$WORKDIR/bootfs/"
mount "${LOOP_DEVICE}p1" "$WORKDIR/bootfs/"
mount "${LOOP_DEVICE}p2" "$WORKDIR/rootfs/"

touch "$WORKDIR/rootfs/qemu-aarch64-static"
mount --bind /usr/bin/qemu-aarch64-static "$WORKDIR/rootfs/qemu-aarch64-static"
mkdir "$WORKDIR/rootfs/chroot"
mount --bind chroot/ "$WORKDIR/rootfs/chroot"

echo "Chroot into rootfs..."
chroot "$WORKDIR/rootfs/" /qemu-aarch64-static /bin/bash -c /chroot/run.sh

umount "$WORKDIR/rootfs/qemu-aarch64-static"
rm "$WORKDIR/rootfs/qemu-aarch64-static"
umount "$WORKDIR/rootfs/chroot"
rmdir "$WORKDIR/rootfs/chroot"

echo "Creating output files..."
mkdir "$WORKDIR/output/"
mksquashfs "$WORKDIR/rootfs/" "$WORKDIR/output/$NAME.squashfs" -comp xz -Xbcj arm
cp -Rv "$WORKDIR/bootfs/"* "$WORKDIR/output/"

echo "Creating output ZIP archive $NAME.zip"
OUTDIR="$PWD"
pushd "$WORKDIR/output/"
zip -r "$OUTDIR/$NAME.zip" .
popd

echo "Cleanning up..."
umount "$WORKDIR/bootfs/"
umount "$WORKDIR/rootfs/"
losetup -d "${LOOP_DEVICE}"
rm "$WORKDIR/$NAME.img"
rm -rf "$WORKDIR/output/"*
rmdir "$WORKDIR/bootfs/" "$WORKDIR/rootfs/" "$WORKDIR/output/"
rmdir "$WORKDIR/"
