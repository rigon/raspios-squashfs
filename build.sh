#!/bin/bash

WORKDIR="/tmp/raspios-squashfs-build"

set -e

# Check if exactly one argument is provided
if [ "$#" -lt 1 ]; then
    echo "Error: You must supply the source image file."
    exit 1
fi
IMAGE="$1"

# Shift the first argument out
shift
PARAMS_RUN_SCRIPT="$@"

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
mount "${LOOP_DEVICE}p2" "$WORKDIR/rootfs/"
mount "${LOOP_DEVICE}p1" "$WORKDIR/rootfs/boot/firmware/"

mount -t proc proc "$WORKDIR/rootfs/proc"
mount -t sysfs sys "$WORKDIR/rootfs/sys"
mount --bind /dev "$WORKDIR/rootfs/dev"
mount --bind /dev/pts "$WORKDIR/rootfs/dev/pts"

touch "$WORKDIR/rootfs/qemu-aarch64-static"
mount --bind /usr/bin/qemu-aarch64-static "$WORKDIR/rootfs/qemu-aarch64-static"
mkdir "$WORKDIR/rootfs/chroot"
mount --bind chroot/ "$WORKDIR/rootfs/chroot"

echo "Chroot into rootfs..."
chroot "$WORKDIR/rootfs/" /qemu-aarch64-static /bin/bash -c /chroot/run.sh $PARAMS_RUN_SCRIPT

echo "Creating output files..."
umount -lf "$WORKDIR/rootfs/proc"
umount -lf "$WORKDIR/rootfs/sys"
umount -lf "$WORKDIR/rootfs/dev/pts"
umount -lf "$WORKDIR/rootfs/dev"
umount "$WORKDIR/rootfs/qemu-aarch64-static"
rm "$WORKDIR/rootfs/qemu-aarch64-static"
umount "$WORKDIR/rootfs/chroot"
rmdir "$WORKDIR/rootfs/chroot"

mkdir "$WORKDIR/output/"
cp -Rv "$WORKDIR/rootfs/boot/firmware/"* "$WORKDIR/output/"
umount "$WORKDIR/rootfs/boot/firmware/"
mksquashfs "$WORKDIR/rootfs/" "$WORKDIR/output/$NAME.squashfs" -comp xz -Xbcj arm
umount "$WORKDIR/rootfs/"

cat > "$WORKDIR/output/cmdline.txt" << EOF
console=serial0,115200 console=tty1 boot=live live-media-path=/ live-image=$NAME.squashfs
EOF

echo "Creating output ZIP archive $NAME.zip"
OUTDIR="$PWD"
pushd "$WORKDIR/output/"
zip -r "$OUTDIR/$NAME.zip" .
popd

echo "Cleanning up..."
losetup -d "${LOOP_DEVICE}"
rm "$WORKDIR/$NAME.img"
rm -rf "$WORKDIR/output/"*
rmdir "$WORKDIR/rootfs/" "$WORKDIR/output/"
rmdir "$WORKDIR/"
