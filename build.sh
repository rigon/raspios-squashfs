#!/bin/bash

WORKDIR="/tmp/raspios-squashfs-build"
EXTRA_SIZE="2G"   # grow rootfs partition by this amount (e.g. 2G, 512M)
OUTDIR="out"      # output directory


usage() {
    echo "Usage: $0 [-s extra_size] [-o output_dir] <image.img.xz|image.zip>"
}

while getopts ":s:o:h" opt; do
    case "$opt" in
        s) EXTRA_SIZE="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Error: option -$OPTARG requires an argument."; usage; exit 1 ;;
        \?) echo "Error: unknown option -$OPTARG."; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

set -e

# Ensure all required host commands are available
REQUIRED_CMDS="xz truncate parted losetup e2fsck resize2fs mksquashfs zip unzip tar qemu-aarch64-static"
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: missing required command: $cmd"
        exit 1
    fi
done

# The source image must be provided
if [ "$#" -lt 1 ]; then
    echo "Error: You must supply the source image file."
    usage
    exit 1
fi
IMAGE="$1"

# Validate the source image
if [ ! -f "$IMAGE" ]; then
    echo "Error: Source image '$IMAGE' not found."
    exit 1
fi
if [[ "$IMAGE" != *.img.xz && "$IMAGE" != *.zip ]]; then
    echo "Error: Source image '$IMAGE' must be a .img.xz or .zip file."
    exit 1
fi

# Check for root access
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root access. Please run as root or use sudo."
    exit 1
fi

# Script executed inside the chroot (shipped in via declare -f below)
run_in_chroot() {
    local to_install=($1)
    local to_remove=($2)

    /bin/bash

    apt-get update

    # Add live-boot to allow booting from squashfs
    sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf
    apt-get upgrade -y live-boot+ "${to_install[@]/%/+}" "${to_remove[@]/%/-}"
    sed -i 's/^MODULES=most/MODULES=dep/' /etc/initramfs-tools/initramfs.conf

    apt-get autoremove --purge -y
    # apt-get upgrade -y
    #/bin/bash

    apt clean
    rm -rf /var/lib/apt/lists/*
    rm /boot/initrd.img-* /boot/vmlinuz-*

    # Override fstab
    cat > /etc/fstab << EOF
# /dev/mmcblk0p1  /boot/firmware  vfat    defaults  0 0
proc            /proc           proc    defaults  0 0
tmpfs           /tmp            tmpfs   defaults  0 0
EOF

    # Create SSH server keys (preserve server fingerprint between reboots)
    ssh-keygen -A
}

# Unmount everything bind/virtual-mounted inside chroot
unmount_chroot() {
    umount -lf "$WORKDIR/rootfs/proc" 2>/dev/null || true
    umount -lf "$WORKDIR/rootfs/sys" 2>/dev/null || true
    umount -lf "$WORKDIR/rootfs/dev/pts" 2>/dev/null || true
    umount -lf "$WORKDIR/rootfs/dev" 2>/dev/null || true
    umount "$WORKDIR/rootfs/boot/firmware/" 2>/dev/null || true
    umount "$WORKDIR/rootfs/qemu-aarch64-static" 2>/dev/null || true
    rm "$WORKDIR/rootfs/qemu-aarch64-static" 2>/dev/null || true
}

# Unmount rootfs
unmount_rootfs() {
    umount "$WORKDIR/rootfs/" 2>/dev/null || true
    losetup -l -n -O NAME,BACK-FILE 2>/dev/null | awk -v d="$WORKDIR" '$2 ~ d {print $1}' | xargs -r losetup -d
    rm -rf "$WORKDIR"
}


case "$IMAGE" in
    *.img.xz) NAME=$(basename "$IMAGE" .img.xz) ;;
    *.zip)    NAME=$(basename "$IMAGE" .zip) ;;
esac
echo "Building $NAME"

# Clean possible previous dirty state
if [ -d "$WORKDIR" ]; then
    echo "Cleaning up previous dirty state in $WORKDIR..."
    unmount_chroot
    unmount_rootfs
fi

# Cleanup on errors
cleanup_on_error() {
    unmount_chroot
    unmount_rootfs
    exit 1
}
trap cleanup_on_error ERR INT TERM

mkdir -p "$WORKDIR/"
echo "Extracting image file $IMAGE"
case "$IMAGE" in
    *.img.xz) xz -c -d "$IMAGE" > "$WORKDIR/$NAME.img" ;;
    *.zip)    unzip -p "$IMAGE" "$NAME.img" > "$WORKDIR/$NAME.img" ;;
esac
truncate -s "+$EXTRA_SIZE" "$WORKDIR/$NAME.img"
parted -s "$WORKDIR/$NAME.img" resizepart 2 100%

echo "Detecting partions in $WORKDIR/$NAME.img"
LOOP_DEVICE=$(losetup -f --partscan --show "$WORKDIR/$NAME.img")

echo "Mounting partitions using device: $LOOP_DEVICE"
e2fsck -f "${LOOP_DEVICE}p2"
resize2fs "${LOOP_DEVICE}p2"
mkdir "$WORKDIR/rootfs/"
mount "${LOOP_DEVICE}p2" "$WORKDIR/rootfs/"
mkdir "$WORKDIR/rootfs/boot/firmware/"
mount "${LOOP_DEVICE}p1" "$WORKDIR/rootfs/boot/firmware/"

mount -t proc proc "$WORKDIR/rootfs/proc"
mount -t sysfs sys "$WORKDIR/rootfs/sys"
mount --bind /dev "$WORKDIR/rootfs/dev"
mount --bind /dev/pts "$WORKDIR/rootfs/dev/pts"

touch "$WORKDIR/rootfs/qemu-aarch64-static"
mount --bind /usr/bin/qemu-aarch64-static "$WORKDIR/rootfs/qemu-aarch64-static"

echo "Copying project files into rootfs..."
tar -C "$PWD" \
    --exclude-vcs \
    --exclude=.github \
    --exclude=build.sh \
    --exclude=packages.conf \
    --exclude='customize.sh*' \
    --exclude=README.md \
    --exclude=LICENSE \
    --exclude="$OUTDIR" \
    -vcf - . | tar -C "$WORKDIR/rootfs/" -xf -

echo "Chroot into rootfs..."
readarray -t TO_INSTALL < <(sed -n 's/^+//p' packages.conf | sort -u)
readarray -t TO_REMOVE < <(sed -n 's/^-//p' packages.conf | sort -u)
chroot "$WORKDIR/rootfs/" /qemu-aarch64-static /bin/bash -c "$(declare -f run_in_chroot); run_in_chroot '${TO_INSTALL[*]}' '${TO_REMOVE[*]}'"
if [ -f customize.sh ]; then
    echo "Running customization hook..."
    chroot "$WORKDIR/rootfs/" /qemu-aarch64-static /bin/bash -c "$(cat customize.sh)"
fi

echo "Creating output files..."
mkdir "$WORKDIR/output/"
cp -Rv "$WORKDIR/rootfs/boot/firmware/"* "$WORKDIR/output/"
unmount_chroot
mksquashfs "$WORKDIR/rootfs/" "$WORKDIR/output/$NAME.squashfs" -comp xz -Xbcj arm

cat > "$WORKDIR/output/cmdline.txt" << EOF
console=serial0,115200 console=tty1 boot=live live-media-path=/ live-image=$NAME.squashfs
EOF

echo "Creating output ZIP archive $OUTDIR/$NAME.zip"
mkdir -p "$OUTDIR"
OUTDIR="$(realpath "$OUTDIR")"
rm -f "$OUTDIR/$NAME.zip"
pushd "$WORKDIR/output/"
zip -r "$OUTDIR/$NAME.zip" .
popd

echo "Cleaning up..."
unmount_rootfs
