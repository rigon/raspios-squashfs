#!/bin/bash
# Create the final output archive from a built Docker image. Everything needed
# is inside the image: the rootfs at / and the boot partition at /boot/firmware.
# Usage: ./pack.sh [-n build_name] [-o output_dir] <docker_image>

set -e -o pipefail

WORKDIR="/tmp/raspios-squashfs-build"
OUTDIR="out"                    # output directory

# Colored step message (plain when stdout isn't a terminal)
[ -t 1 ] && STEP_FMT='\033[1;34m==>\033[0m %s\n' || STEP_FMT='==> %s\n'
step() { printf "$STEP_FMT" "$*"; }

usage() {
    echo "Usage: $0 [-n build_name] [-o output_dir] <docker_image>"
}

while getopts ":n:o:h" opt; do
    case "$opt" in
        n) BUILD_NAME="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Error: option -$OPTARG requires an argument."; usage; exit 1 ;;
        \?) echo "Error: unknown option -$OPTARG."; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

# Ensure all required host commands are available
REQUIRED_CMDS="docker sqfstar tar"
for cmd in $REQUIRED_CMDS; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: missing required command: $cmd"
        [ "$cmd" = "sqfstar" ] && echo "(sqfstar ships with squashfs-tools >= 4.5)"
        exit 1
    fi
done

# The Docker image must be provided
if [ "$#" -lt 1 ]; then
    echo "Error: You must supply the Docker image to package."
    usage
    exit 1
fi
IMAGE="$1"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Error: Docker image '$IMAGE' not found. Build it first:"
    echo "  ./build.sh $IMAGE"
    exit 1
fi

# The build name defaults to the image name, without registry or tag
if [ -z "$BUILD_NAME" ]; then
    BUILD_NAME="${IMAGE%%:*}"
    BUILD_NAME="${BUILD_NAME##*/}"
fi
step "Packaging $BUILD_NAME"

# A container is needed to read the image contents; remove it on exit
CONTAINER=""
cleanup() {
    [ -n "$CONTAINER" ] && docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

CONTAINER=$(docker create "$IMAGE" /bin/sh)


# === Output files ===
step "Creating output files"
OUTPUT="$WORKDIR/output"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

step "Collecting boot files from /boot/firmware"
docker cp "$CONTAINER:/boot/firmware/." "$OUTPUT/"

step "Creating $BUILD_NAME.squashfs"
docker export "$CONTAINER" \
    | tar --delete --wildcards -f - '*boot/firmware/*' \
    | sqfstar -comp xz -Xbcj arm64 -Xdict-size 100% -b 1M \
        "$OUTPUT/$BUILD_NAME.squashfs"

cat > "$OUTPUT/cmdline.txt" << EOF
console=serial0,115200 console=tty1 boot=live live-media-path=/ live-image=$BUILD_NAME.squashfs noprompt noeject persistence
EOF

step "Creating output archive $OUTDIR/$BUILD_NAME.tar"
mkdir -p "$OUTDIR"
tar -C "$OUTPUT" -cf "$OUTDIR/$BUILD_NAME.tar" .

step "Cleaning up"
rm -rf "$OUTPUT"
