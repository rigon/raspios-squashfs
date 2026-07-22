#!/bin/bash
# Build the customized image from a Dockerfile, and load it into Docker.
# Usage: ./build.sh [-b base_image] [-f dockerfile] <image_tag>

set -e

DOCKERFILE="Dockerfile"
PLATFORM="linux/arm64"

usage() {
    echo "Usage: $0 [-f dockerfile] <image_tag>"
}

while getopts ":f:h" opt; do
    case "$opt" in
        f) DOCKERFILE="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "Error: option -$OPTARG requires an argument."; usage; exit 1 ;;
        \?) echo "Error: unknown option -$OPTARG."; usage; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi
IMAGE="$1"

if [ ! -f "$DOCKERFILE" ]; then
    echo "Error: '$DOCKERFILE' not found."
    exit 1
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Error: base image '$IMAGE' not found. Import it first:"
    echo "  sudo ./import.sh <image.img.xz> $IMAGE"
    exit 1
fi
# Building arm64 on another architecture needs the emulator registered
if [ "$(uname -m)" != "aarch64" ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "Error: arm64 emulation not registered. Run once:"
    echo "  docker run --privileged --rm tonistiigi/binfmt --install arm64"
    exit 1
fi

docker buildx build \
    --platform "$PLATFORM" \
    --build-arg BASE="$IMAGE" \
    -f "$DOCKERFILE" \
    --tag "$IMAGE" \
    --load \
    .
