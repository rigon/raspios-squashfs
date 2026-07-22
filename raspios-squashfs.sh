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

BASE_IMAGE="raspios-base"       # base image, as imported from the official one
IMAGE="raspios"                 # customized image, as built from the Dockerfile
DOCKERFILE="Dockerfile"         # build recipe
OUTDIR="out"                    # output directory
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
  -b <image>    Base image tag (default: $BASE_IMAGE)
  -t <image>    Built image tag (default: $IMAGE)
  -f <file>     Dockerfile to build from (default: $DOCKERFILE)
  -n <name>     Build name, used for the output files (default: built image tag)
  -o <dir>      Output directory (default: $OUTDIR)
  -h            Show this help
EOF
}

# Ensure all required host commands are available
REQUIRED_CMDS="docker xz unzip tar sqfstar losetup sha256sum"
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: missing required command: $cmd"
        exit 1
    fi
done


# === import base image ===
do_import() {
    local source="$1"
    local name

    if [ -z "$source" ]; then
        echo "Error: You must supply the source image file."
        usage
        exit 1
    fi
    if [ ! -f "$source" ]; then
        echo "Error: Source image '$source' not found."
        exit 1
    fi
    case "$source" in
        *.img.xz) name=$(basename "$source" .img.xz) ;;
        *.zip)    name=$(basename "$source" .zip) ;;
        *) echo "Error: Source image must be a .img.xz or .zip file."; exit 1 ;;
    esac

    local dir loop=""
    mount_dir=$(mktemp -d "$WORKDIR.import.XXXXXX")

    import_cleanup() {
        sudo umount "$mount_dir/boot/firmware" 2>/dev/null || true
        sudo umount "$mount_dir" 2>/dev/null || true
        [ -n "$loop" ] && sudo losetup -d "$loop" 2>/dev/null || true
        rm -rf "$mount_dir"
    }
    trap import_cleanup EXIT

    step "Extracting $source"
    case "$source" in
        *.img.xz) xz -c -d "$source" > "$mount_dir/image.img" ;;
        *.zip)    unzip -p "$source" "$name.img" > "$mount_dir/image.img" ;;
    esac

    step "Mounting partitions"
    loop=$(sudo losetup -f --partscan --show "$mount_dir/image.img")
    sudo mount -o ro "${loop}p2" "$mount_dir"
    sudo mount -o ro "${loop}p1" "$mount_dir/boot/firmware"

    step "Importing as base image $BASE_IMAGE"
    sudo tar -C "$mount_dir" -cf - . \
        | docker import --platform "$PLATFORM" - "$BASE_IMAGE"

    import_cleanup
    trap - EXIT
}


# === build customized image ===
do_build() {
    if [ ! -f "$DOCKERFILE" ]; then
        echo "Error: '$DOCKERFILE' not found."
        exit 1
    fi
    if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
        echo "Error: base image '$BASE_IMAGE' not found. Import it first:"
        echo "  $0 import <image.img.xz>"
        exit 1
    fi

    step "Building image $IMAGE from $DOCKERFILE"
    docker buildx build \
        --platform "$PLATFORM" \
        --build-arg BASE="$BASE_IMAGE" \
        -f "$DOCKERFILE" \
        --tag "$IMAGE" \
        --load \
        .
}


# === export output archive ===
do_export() {
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "Error: image '$IMAGE' not found. Build it first:"
        echo "  $0 build"
        exit 1
    fi

    if [ -z "$BUILD_NAME" ]; then
        BUILD_NAME="${IMAGE%%:*}"
        BUILD_NAME="${BUILD_NAME##*/}"
    fi
    step "Exporting $BUILD_NAME"

    local container=""
    export_cleanup() {
        [ -n "$container" ] && docker rm -f "$container" >/dev/null 2>&1 || true
    }
    trap export_cleanup EXIT

    container=$(docker create "$IMAGE" /bin/sh)

    local output="$WORKDIR/output"
    rm -rf "$output"
    mkdir -p "$output"

    step "Collecting boot files"
    docker cp "$container:/boot/firmware/." "$output/"

    step "Creating $BUILD_NAME.squashfs"
    docker export "$container" \
        | tar --delete --wildcards -f - '*boot/firmware/*' \
        | sqfstar -comp xz -Xbcj arm64 -Xdict-size 100% -b 1M \
            "$output/$BUILD_NAME.squashfs"

    cat > "$output/cmdline.txt" << EOF
console=serial0,115200 console=tty1 boot=live live-media-path=/ live-image=$BUILD_NAME.squashfs noprompt noeject persistence
EOF

    step "Creating output archive $OUTDIR/$BUILD_NAME.tar"
    mkdir -p "$OUTDIR"
    tar -C "$output" -cf "$OUTDIR/$BUILD_NAME.tar" .

    step "Cleaning up"
    rm -rf "$output"
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

while getopts ":b:t:f:n:o:h" opt; do
    case "$opt" in
        b) BASE_IMAGE="$OPTARG" ;;
        t) IMAGE="$OPTARG" ;;
        f) DOCKERFILE="$OPTARG" ;;
        n) BUILD_NAME="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Error: option -$OPTARG requires an argument."; usage; exit 1 ;;
        \?) echo "Error: unknown option -$OPTARG."; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

case "$COMMAND" in
    import)  do_import "$1" ;;
    build)   do_build ;;
    export)  do_export ;;
    rebuild) do_build; do_export ;;
    all)     do_import "$1"; do_build; do_export ;;
    help|--help|-h) usage ;;
    *) echo "Error: unknown command '$COMMAND'."; usage; exit 1 ;;
esac
