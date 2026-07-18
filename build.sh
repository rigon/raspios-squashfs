#!/bin/bash

set -e

WORKDIR="/tmp/raspios-squashfs-build"
OUTDIR="out"                    # output directory
PACKAGES_CONF="packages.conf"   # package list (optional)
CONFIG_SCRIPT="configure.sh"    # configuration script (optional)

# Colored step message (plain when stdout isn't a terminal)
[ -t 1 ] && STEP_FMT='\033[1;34m==>\033[0m %s\n' || STEP_FMT='==> %s\n'
step() { printf "$STEP_FMT" "$*"; }


usage() {
    echo "Usage: $0 [-n build_name] [-o output_dir] [-p packages_file] [-c config_script] [-d [user@]host] <image.img.xz|image.zip>"
}

while getopts ":n:o:p:c:d:h" opt; do
    case "$opt" in
        n) BUILD_NAME="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        p) PACKAGES_CONF="$OPTARG" ;;
        c) CONFIG_SCRIPT="$OPTARG" ;;
        d) DEPLOY_TARGET="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Error: option -$OPTARG requires an argument."; usage; exit 1 ;;
        \?) echo "Error: unknown option -$OPTARG."; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Ensure all required host commands are available
REQUIRED_CMDS="xz losetup mksquashfs unzip tar qemu-aarch64-static ssh sha256sum"
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
IMAGE_PATH="$1"

# Validate the source image
if [ ! -f "$IMAGE_PATH" ]; then
    echo "Error: Source image '$IMAGE_PATH' not found."
    exit 1
fi
if [[ "$IMAGE_PATH" != *.img.xz && "$IMAGE_PATH" != *.zip ]]; then
    echo "Error: Source image '$IMAGE_PATH' must be a .img.xz or .zip file."
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

    set -e

    # Refresh apt according to the running release
    . /etc/os-release
    case "$VERSION_CODENAME" in
        buster)
            # unsupported
            sed -i.bak 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list
            apt-get update --allow-releaseinfo-change
            ;;
        bullseye|bookworm)
            # supported
            apt-get update --allow-releaseinfo-change
            ;;
        *)
            # trixie and newer
            apt-get update
            ;;
    esac

    # Add live-boot to allow booting from squashfs
    sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf
    apt-get upgrade -y live-boot+ "${to_install[@]/%/+}" "${to_remove[@]/%/-}"
    sed -i 's/^MODULES=most/MODULES=dep/' /etc/initramfs-tools/initramfs.conf

    apt-get autoremove --purge -y
    # apt-get upgrade -y
    #/bin/bash

    apt clean
    # systemctl start apt-listchanges.service
    # python3 -m apt_listchanges.populate_database --profile apt

    # rm -rf /var/lib/apt/lists/*
    # rm /boot/initrd.img-* /boot/vmlinuz-*

    # Override fstab
    cat > /etc/fstab << EOF
# /dev/mmcblk0p1  /boot/firmware  vfat    defaults  0 0
proc            /proc           proc    defaults  0 0
tmpfs           /tmp            tmpfs   defaults  0 0
EOF

    # Create SSH server keys (preserve server fingerprint between reboots)
    ssh-keygen -A
}


# === layer functions ===

LAYERS=""
LAYERS_HASH=""

init_layers() {
    local base_path="$1"
    LAYERS="$base_path"
    LAYERS_HASH="$2"
}

layer_id() {
    echo $LAYERS_HASH $@ | sha256sum | cut -c1-12
}

should_build_layer() {
    local id="$1"
    [ ! -d "$WORKDIR/layers/$id" ] || [ -e "$WORKDIR/layers/.$id.building" ]
}

open_layer() {
    local id="$1"
    local path="$WORKDIR/layers/$id/"
    rm -rf "$path"
    mkdir -p "$path" "$WORKDIR/work" "$WORKDIR/merged"
    touch "$WORKDIR/layers/.$id.building"

    mount -t overlay "$id" \
        -o lowerdir="$LAYERS",upperdir="$path",workdir="$WORKDIR/work" \
        "$WORKDIR/merged"
}

register_layer() {
    local id="$1"
    LAYERS="$WORKDIR/layers/$id/:$LAYERS"
    LAYERS_HASH="$id"
}

mount_layers() {
    mkdir -p "$WORKDIR/merged"
    # Read-only overlay of the full layer stack (no upperdir = read-only mount).
    mount -t overlay squash -o lowerdir="$LAYERS" "$WORKDIR/merged"
}

close_layers() {
    umount -lf "$WORKDIR/merged"
    rm -rf "$WORKDIR/work" "$WORKDIR/merged"
}

commit_layer() {
    local id="$1"
    rm "$WORKDIR/layers/.$id.building"
    close_layers
}


# === chroot functions ===

mount_chroot() {
    local root="$1"
    mount -t proc proc "$root/proc"
    mount -t sysfs sys "$root/sys"
    mount --bind /dev "$root/dev"
    mount --bind /dev/pts "$root/dev/pts"
    touch "$root/qemu-aarch64-static"
    mount --bind /usr/bin/qemu-aarch64-static "$root/qemu-aarch64-static"
}

umount_chroot() {
    local root="$1"
    umount -lf "$root/qemu-aarch64-static" 2>/dev/null || true
    rm -f "$root/qemu-aarch64-static"
    umount -lf "$root/dev/pts" 2>/dev/null || true
    umount -lf "$root/dev" 2>/dev/null || true
    umount -lf "$root/sys" 2>/dev/null || true
    umount -lf "$root/proc" 2>/dev/null || true
}

run_chroot() {
    local root="$1"; shift
    local rc=0

    mount_chroot "$root"
    chroot "$root" /qemu-aarch64-static /bin/bash -c "$*" || rc=$?
    umount_chroot "$root"

    return $rc
}

# Unmount rootfs
unmount_all() {
    close_layers 2>/dev/null || true
    umount "$WORKDIR/bootfs/" 2>/dev/null || true
    umount "$WORKDIR/rootfs/" 2>/dev/null || true
    losetup -l -n -O NAME,BACK-FILE 2>/dev/null | awk -v d="$WORKDIR" '$2 ~ d {print $1}' | xargs -r losetup -d
    # rm -rf "$WORKDIR"
}


# === Main script ===

case "$IMAGE_PATH" in
    *.img.xz) IMAGE_NAME=$(basename "$IMAGE_PATH" .img.xz) ;;
    *.zip)    IMAGE_NAME=$(basename "$IMAGE_PATH" .zip) ;;
esac
if [ -z "$BUILD_NAME" ]; then
    BUILD_NAME="$IMAGE_NAME"
fi
step "Building $BUILD_NAME"

# Clean possible previous dirty state
if [ -d "$WORKDIR" ]; then
    step "Cleaning up previous dirty state in $WORKDIR..."
    unmount_all
fi

# Cleanup on errors
cleanup_on_error() {
    unmount_all
    exit 1
}
trap cleanup_on_error ERR INT TERM

mkdir -p "$WORKDIR/"
step "Extracting image file $IMAGE_PATH"
case "$IMAGE_PATH" in
    *.img.xz) xz -c -d "$IMAGE_PATH" > "$WORKDIR/$IMAGE_NAME.img" ;;
    *.zip)    unzip -p "$IMAGE_PATH" "$IMAGE_NAME.img" > "$WORKDIR/$IMAGE_NAME.img" ;;
esac

step "Detecting partions in $WORKDIR/$IMAGE_NAME.img"
LOOP_DEVICE=$(losetup -f --partscan --show "$WORKDIR/$IMAGE_NAME.img")

step "Mounting partitions using device $LOOP_DEVICE"
mkdir -p "$WORKDIR/rootfs/" "$WORKDIR/bootfs/"
mount "${LOOP_DEVICE}p1" "$WORKDIR/bootfs/"
mount "${LOOP_DEVICE}p2" "$WORKDIR/rootfs/"
init_layers "$WORKDIR/rootfs/" $(layer_id $(sha256sum "$IMAGE_PATH"))


# === Install packages ===
step "Installing packages..."
if [ -f "$PACKAGES_CONF" ]; then
    readarray -t TO_INSTALL < <(sed -n 's/^+//p' "$PACKAGES_CONF" | sort -u)
    readarray -t TO_REMOVE < <(sed -n 's/^-//p' "$PACKAGES_CONF" | sort -u)
else
    TO_INSTALL=()
    TO_REMOVE=()
fi
PACKAGES_ID=$(layer_id $(declare -f run_in_chroot) install=${TO_INSTALL[*]} remove=${TO_REMOVE[*]})
if should_build_layer "$PACKAGES_ID"; then
    step "== Building $PACKAGES_ID =="
    open_layer "$PACKAGES_ID"
    run_chroot "$WORKDIR/merged" "$(declare -f run_in_chroot); run_in_chroot '${TO_INSTALL[*]}' '${TO_REMOVE[*]}'"
    commit_layer "$PACKAGES_ID"
fi
register_layer "$PACKAGES_ID"


# === Project files ===
step "Loading project files..."
FILES_ID=$(layer_id $RANDOM $RANDOM $RANDOM)    # TODO: this always create a new ID
if should_build_layer "$FILES_ID"; then
    step "== Building $FILES_ID =="
    open_layer "$FILES_ID"
    tar -C "$PWD" \
        --exclude-vcs \
        --exclude=.github \
        --exclude=build.sh \
        --exclude=README.md \
        --exclude=LICENSE \
        --exclude="$PACKAGES_CONF" \
        --exclude="$CONFIG_SCRIPT" \
        --exclude="$OUTDIR" \
        -vcf - . | tar -C "$WORKDIR/merged/" -xf -
    commit_layer "$FILES_ID"
fi
register_layer "$FILES_ID"


# === Configuration script ===
if [ -f "$CONFIG_SCRIPT" ]; then
    step "Running cconfiguration script..."
    CONFIG_ID=$(layer_id "config:$(cat "$CONFIG_SCRIPT")")
    if should_build_layer "$CONFIG_ID"; then
        step "== Building $CONFIG_ID =="
        open_layer "$CONFIG_ID"
        run_chroot "$WORKDIR/merged" "$(cat "$CONFIG_SCRIPT")"
        commit_layer "$CONFIG_ID"
    fi
    register_layer "$CONFIG_ID"
fi


# === Output files ===
step "Creating output files..."
rm "$WORKDIR/output/$BUILD_NAME.squashfs"
mkdir -p "$WORKDIR/output/"
cp -Rv "$WORKDIR/bootfs/"* "$WORKDIR/output/"
mount_layers
cp -Rv "$WORKDIR/merged/boot/firmware/"* "$WORKDIR/output/"
mksquashfs "$WORKDIR/merged/" "$WORKDIR/output/$BUILD_NAME.squashfs" \
  -wildcards -e "boot/firmware/*" \
  -comp xz -Xbcj arm64 -Xdict-size 100% -b 1M
close_layers

cat > "$WORKDIR/output/cmdline.txt" << EOF
console=serial0,115200 console=tty1 boot=live live-media-path=/ live-image=$BUILD_NAME.squashfs noprompt noeject persistence
EOF

step "Creating output archive $OUTDIR/$BUILD_NAME.tar"
mkdir -p "$OUTDIR"
tar -C "$WORKDIR/output/" -cvf "$OUTDIR/$BUILD_NAME.tar" .

step "Cleaning up..."
unmount_all

if [ -n "$DEPLOY_TARGET" ]; then
    step "Deploying $OUTDIR/$BUILD_NAME.tar to $DEPLOY_TARGET over SSH"
    ssh "$DEPLOY_TARGET" 'set -e; MEDIUM=/run/live/medium;
        sudo mount -o remount,rw "$MEDIUM";
        sudo tar -C "$MEDIUM" -xzf -;
        sudo systemctl reboot' < "$OUTDIR/$BUILD_NAME.tar"
fi
