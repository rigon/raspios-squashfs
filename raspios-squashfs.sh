#!/bin/bash
# Build a read-only, squashfs-based Raspberry Pi OS image using Docker.
#
# Usage: ./raspios.sh <command> [options] [arguments]
#
# Commands:
#   import <image.img.xz|image.zip>   Import an official image as base image
#   build                             Build the customized image
#   export                            Create the output archive
#   rebuild                           build + export
#   all <image.img.xz|image.zip>      import + build + export

set -e -o pipefail

BASE_IMAGE="raspios-base"       # imported base image
IMAGE="raspios"                 # customized image
DOCKERFILE="Dockerfile"         # build recipe
OUTDIR="out"                    # output directory
PACKAGES_CONF="packages.conf"   # package changes applied during build
BUILD_ARGS=()                   # extra --build-arg values for the build
PLATFORM="linux/arm64"
WORKDIR="/tmp/raspios-squashfs-build"

# Colored step message (plain when stdout isn't a terminal)
[ -t 1 ] && STEP_FMT='\033[1;34m==>\033[0m %s\n' || STEP_FMT='==> %s\n'
step() { printf "$STEP_FMT" "$*"; }

usage() {
    cat << EOF
Usage: $0 <command> [options] [arguments]

Commands:
  import <image.img.xz|image.zip>   Import an official image as base image
                                    (uses sudo to mount the image)
  build                             Build the customized image from $DOCKERFILE
  export                            Create the output archive from the image
  rebuild                           build + export
  all <image.img.xz|image.zip>      import + build + export

Options:
  -a <arg>      Build arg, repeatable: NAME=value, or NAME alone to take
                the value from the environment
  -b <image>    Base image name (default: $BASE_IMAGE)
  -f <file>     Dockerfile to build from (default: $DOCKERFILE)
  -n <name>     Build name (default: the image's source name)
  -o <dir>      Output directory (default: $OUTDIR)
  -p <file>     List of packages to install/remove (default: $PACKAGES_CONF)
  -t <image>    Built image name (default: $IMAGE)
  -h            Show this help
EOF
}

# Ensure all required host commands are available
REQUIRED_CMDS="docker xz unzip tar sqfstar losetup"
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: missing required command: $cmd"
        exit 1
    fi
done


# === import base image ===
do_import() {
    local source="$1"

    if [ -z "$source" ]; then
        echo "Error: You must supply the source image file."
        usage
        exit 1
    fi
    if [ ! -f "$source" ]; then
        echo "Error: Source image '$source' not found."
        exit 1
    fi
    if [ -z "$BUILD_NAME" ]; then
        echo "Error: a build name (-n) or a source file must be provided."
        exit 1
    fi

    # Skip base image import if already exists
    if docker image inspect "$BASE_IMAGE:$BUILD_NAME" >/dev/null 2>&1; then
        step "Base image $BASE_IMAGE:$BUILD_NAME already present, skipping import"
        echo "  To re-import, remove it first: docker rmi $BASE_IMAGE:$BUILD_NAME"
        docker tag "$BASE_IMAGE:$BUILD_NAME" "$BASE_IMAGE:latest"
        return
    fi

    # Ask for sudo before doing work
    sudo -v
    
    # Global: this function's scope unwinds before the cleanup trap runs (locals would be empty).
    loop_device=""
    import_dir=$(mktemp -d "$WORKDIR.import.XXXXXX")

    import_cleanup() {
        step "Cleaning up"
        sudo umount "$import_dir/rootfs/boot/firmware" 2>/dev/null || true
        sudo umount "$import_dir/rootfs/" 2>/dev/null || true
        [ -n "$loop_device" ] && sudo losetup -d "$loop_device" 2>/dev/null || true
        rm -rf "$import_dir"
    }
    trap import_cleanup EXIT

    step "Extracting $source"
    local name
    case "$source" in
        *.img.xz)
            name=$(basename "$source" .img.xz)
            xz -c -d "$source" > "$import_dir/$name.img" ;;
        *.zip)
            name=$(basename "$source" .zip)
            unzip -p "$source" "$name.img" > "$import_dir/$name.img" ;;
        *) echo "Error: source image must be a .img.xz or .zip file."; exit 1 ;;
    esac

    step "Mounting partitions"
    loop_device=$(sudo losetup -f --partscan --show "$import_dir/$name.img")
    mkdir -p "$import_dir/rootfs/"
    sudo mount -o ro "${loop_device}p2" "$import_dir/rootfs/"
    sudo mount -o ro "${loop_device}p1" "$import_dir/rootfs/boot/firmware"

    step "Importing as base image $BASE_IMAGE:$BUILD_NAME"
    sudo tar -C "$import_dir/rootfs/" -cf - . \
        | docker import --platform "$PLATFORM" - "$BASE_IMAGE:$BUILD_NAME"
    docker tag "$BASE_IMAGE:$BUILD_NAME" "$BASE_IMAGE:latest"

    import_cleanup
    trap - EXIT
}


# === build customized image ===
do_build() {
    if [ -z "$BUILD_NAME" ]; then
        echo "Error: a build name (-n) must be provided."
        exit 1
    fi
    if ! docker image inspect "$BASE_IMAGE:$BUILD_NAME" >/dev/null 2>&1; then
        echo "Error: base image '$BASE_IMAGE:$BUILD_NAME' not found. Import it first:"
        echo "  $0 import <image.img.xz>"
        exit 1
    fi

    # List of packages
    local TO_INSTALL=() TO_REMOVE=()
    if [ -f "$PACKAGES_CONF" ]; then
        readarray -t TO_INSTALL < <(sed -n 's/^+//p' "$PACKAGES_CONF" | sort -u)
        readarray -t TO_REMOVE < <(sed -n 's/^-//p' "$PACKAGES_CONF" | sort -u)
    fi

    step "Building image $IMAGE:$BUILD_NAME"
    docker buildx build \
        --platform "$PLATFORM" \
        --tag "$IMAGE:$BUILD_NAME" \
        --tag "$IMAGE:latest" \
        "${BUILD_ARGS[@]}" \
        --load \
        -f - \
        . <<END_DOCKERFILE
FROM $BASE_IMAGE:$BUILD_NAME AS base

# Override fstab
RUN cat > /etc/fstab << 'EOF'
proc            /proc           proc    defaults  0 0
tmpfs           /tmp            tmpfs   defaults  0 0
EOF

# Refresh apt according to the running release
RUN . /etc/os-release && case "\$VERSION_CODENAME" in \
        buster) \
            sed -i.bak 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
            apt-get update --allow-releaseinfo-change ;; \
        bullseye|bookworm) \
            apt-get update --allow-releaseinfo-change ;; \
        *) \
            apt-get update ;; \
    esac

RUN sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf
RUN apt-get remove --purge --auto-remove -y ${TO_REMOVE[*]}
RUN apt-get install -y live-boot
RUN apt-get install -y ${TO_INSTALL[*]}
RUN apt-get update -y
RUN apt-get autoremove --purge -y && apt-get clean
RUN sed -i 's/^MODULES=most/MODULES=dep/' /etc/initramfs-tools/initramfs.conf

# RUN rm -rf /var/lib/apt/lists/*

COPY . /

# Append verbatim from '$DOCKERFILE'
$(cat "$DOCKERFILE" 2>/dev/null || true)
END_DOCKERFILE
}


# === export output archive ===
do_export() {
    if [ -z "$BUILD_NAME" ]; then
        echo "Error: a build name (-n) must be provided."
        exit 1
    fi
    if ! docker image inspect "$IMAGE:$BUILD_NAME" >/dev/null 2>&1; then
        echo "Error: image '$IMAGE:$BUILD_NAME' not found. Build it first:"
        echo "  $0 build -n $BUILD_NAME"
        exit 1
    fi

    step "Exporting $BUILD_NAME"

    # Global: this function's scope unwinds before the cleanup trap runs (locals would be empty).
    container=""
    export_dir=""
    export_cleanup() {
        step "Cleaning up"
        [ -n "$container" ] && docker rm -f "$container" >/dev/null 2>&1 || true
        [ -n "$export_dir" ] && rm -rf "$export_dir"
    }
    trap export_cleanup EXIT

    container=$(docker create "$IMAGE:$BUILD_NAME" /bin/sh)
    export_dir=$(mktemp -d "$WORKDIR.export.XXXXXX")

    step "Collecting boot files"
    docker cp "$container:/boot/firmware/." "$export_dir/"

    step "Creating $BUILD_NAME.squashfs"
    docker export "$container" \
        | tar --delete --wildcards -f - '*boot/firmware/*' \
        | sqfstar -comp xz -Xbcj arm64 -Xdict-size 100% -b 1M \
            "$export_dir/$BUILD_NAME.squashfs"

    cat > "$export_dir/cmdline.txt" << EOF
console=serial0,115200 console=tty1 boot=live live-media-path=/ live-image=$BUILD_NAME.squashfs noprompt noeject persistence
EOF

    step "Creating output archive $OUTDIR/$BUILD_NAME.tar"
    mkdir -p "$OUTDIR"
    tar -C "$export_dir" -cf "$OUTDIR/$BUILD_NAME.tar" .

    export_cleanup
    trap - EXIT
}


# === Main script ===

if [ "$#" -lt 1 ]; then
    echo "Error: no command specified"
    usage
    exit 1
fi
COMMAND="$1"
shift

while getopts ":a:b:f:n:o:p:t:h" opt; do
    case "$opt" in
        a) BUILD_ARGS+=(--build-arg "$OPTARG") ;;
        b) BASE_IMAGE="$OPTARG" ;;
        f) DOCKERFILE="$OPTARG" ;;
        n) BUILD_NAME="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        p) PACKAGES_CONF="$OPTARG" ;;
        t) IMAGE="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Error: option -$OPTARG requires an argument."; usage; exit 1 ;;
        \?) echo "Error: unknown option -$OPTARG."; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

filename="$1"
if [ -z "$BUILD_NAME" ]; then
    case "$filename" in
        *.img.xz) BUILD_NAME=$(basename "$filename" .img.xz) ;;
        *.zip)    BUILD_NAME=$(basename "$filename" .zip) ;;
    esac
    BUILD_NAME="${BUILD_NAME//[^A-Za-z0-9_.-]/_}"
fi

case "$COMMAND" in
    import)  do_import "$filename" ;;
    build)   do_build ;;
    export)  do_export ;;
    rebuild) do_build; do_export ;;
    all)     do_import "$filename"; do_build; do_export ;;
    help|--help|-h) usage ;;
    *) echo "Error: unknown command '$COMMAND'."; usage; exit 1 ;;
esac
