# Raspberry Pi OS - Squashfs

Build a squashfs version of [Raspberry Pi OS](https://www.raspberrypi.com/software/operating-systems/):

- Run the system live
- Clean bad configurations on reboot
- Better performance running off an SD card
- Manage system configurations
- Switch easily between OS versions
- More predictable and reproducible upgrades

The image is customized with Docker: the official image is imported as a base
image, customized with a regular `Dockerfile`, and exported as a squashfs
archive ready to boot with [live-boot](https://manpages.debian.org/live-boot).


## Requirements

- Docker with [buildx](https://docs.docker.com/build/buildx/)
- ARM64 emulation when the host isn't ARM64 (e.g. `docker run --privileged --rm tonistiigi/binfmt --install arm64`)
- `xz`, `unzip`, `tar`, `losetup`, `ssh`
- `sqfstar` (from `squashfs-tools` 4.6 or newer)
- `sudo` access (only used to mount the source image during import)


## Quick start

Download a 64-bit (arm64) OS image from the
[official download page](https://www.raspberrypi.com/software/operating-systems/)
(all releases are also listed at
[downloads.raspberrypi.com](https://downloads.raspberrypi.com/raspios_lite_arm64/images/)),
then:

```sh
cp Dockerfile.example Dockerfile
cp packages-trixie.conf.example packages.conf    # or packages-bookworm.conf.example
./raspios-squashfs.sh build <image.img.xz|image.zip>
```

The result is written to `out/<build_name>.tar`, where the build name defaults
to the source file name without its extension.


## Usage

```
Usage: ./raspios-squashfs.sh <command> [options] [arguments]

Commands:
  import <image.img.xz|image.zip>   Import an official image as base image
                                    (uses sudo to mount the image)
  image                             Build the customized image from Dockerfile
  export                            Create the output archive from the image
  build <image.img.xz|image.zip>    Import, build docker image and export output archive
  deploy                            Deploy the built image to a running target over SSH

Options:
  -a <arg>         Build arg, repeatable: NAME=value, or NAME alone to take
                   the value from the environment
  -b <image>       Base image name (default: raspios-base)
  -B <tag>         Base image tag (default: the source file name, or latest
                   when no source file is given)
  -d <[user@]host> SSH target for deployment, also deploys after exporting
  -f <file>        Dockerfile to build from (default: Dockerfile)
  -I               Re-import the base image even when it already exists
  -n <name>        Name of the build and exported archive (default: the source filename)
  -o <dir>         Output directory (default: out)
  -p <file>        List of packages to install/remove (default: packages.conf)
  -t <image>       Built image name (default: raspios)
  -h               Show this help
```


## Installation

You can install it by simply running:

```sh
sudo install -m755 raspios-squashfs.sh /usr/local/bin/raspios-squashfs
```

The script uses the current directory as the build context, so it can be
installed on `PATH` and run from any project directory:

```sh
cd ~/my-pi && raspios-squashfs build <path_image_file>
```


## Examples

```sh
IMG=2025-10-01-raspios-trixie-arm64-lite.img.xz

# Build (the first run imports the base image, later runs reuse it)
raspios-squashfs build $IMG

# Custom build name, and a build argument taken from the environment
PASSWD=secret raspios-squashfs build -n my-pi -a PASSWD $IMG

# Build and deploy to a running Pi
raspios-squashfs build -n my-pi -d pi@my-pi.local $IMG

# Re-deploy an existing archive without building
raspios-squashfs deploy -n my-pi -d pi@my-pi.local

# Run the steps individually
raspios-squashfs import $IMG
raspios-squashfs image -n my-pi
raspios-squashfs export -n my-pi
```

## Output

The archive `out/<build_name>.tar` contains:

- the boot files (contents of `/boot/firmware`)
- `<build_name>.squashfs` with the root filesystem
- `cmdline.txt` configured to boot the squashfs with live-boot

To install it, just extract the archive to the SD Card (FAT32 partition).

The kernel command line enables live-boot `persistence`, so a
partition labeled `persistence` (with a `persistence.conf`) can be used to
keep selected paths across reboots.


## Deploy over SSH

With `-d [user@]host`, the archive is streamed to a Pi that is already running
a squashfs system built by this script. It is unpacked onto the live medium
(`/run/live/medium`) and the Pi is rebooted into the new version. The remote
user needs `sudo` rights.


## Customization

### Packages

Package changes are driven by `packages.conf` (see the comments in the example
files). Each line is one change; anything not listed is left untouched:

```
+package    install (or keep) the package
-package    remove the package
```

`live-boot` is always installed.

### Dockerfile

For anything beyond installing/removing packages, edit the `Dockerfile` (start
from `Dockerfile.example`). It is appended verbatim to the generated recipe and
must start with `FROM base`, the stage that already has the package changes
applied. Common uses: setting the hostname, enabling services, creating users.

Build arguments are passed with `-a`. Note that build args are visible in
`docker history` of the built image (but not in the exported squashfs).

### Files

To drop files into the image, place them in the project directory mirroring
their target paths - e.g. `etc/hostname` or `home/pi/.bashrc`. The whole
project directory is copied into the root filesystem, merging into existing
directories and overwriting files. Project files such as `Dockerfile`,
`packages.conf`, `out/` and `README.md` are excluded via `.dockerignore`.