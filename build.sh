#!/bin/bash

WORKDIR="/tmp/raspios-squashfs-build"

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

OUTDIR="$PWD"
cd "$WORKDIR/"

echo "Mounting partitions using device: $LOOP_DEVICE"
mkdir output/ rootfs/ bootfs/
mount "${LOOP_DEVICE}p1" bootfs/
mount "${LOOP_DEVICE}p2" rootfs/

echo "Copying boot files..."
cp -Rv bootfs/* output/

echo "Creating squashfs of root..."
mksquashfs "rootfs/" "output/$NAME.squashfs" -comp xz

echo "Creating output ZIP archive $NAME.zip"
pushd output/
zip -r "$OUTDIR/$NAME.zip" .
popd

# echo "Cleanning up..."
umount bootfs/
umount rootfs/
losetup -d "${LOOP_DEVICE}"
rm -rf output/*
rmdir bootfs/ rootfs/ output/
rm "$NAME.img"
rmdir "$WORKDIR/"
