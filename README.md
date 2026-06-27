# Raspberry Pi OS - Squashfs

Build a squashfs version of [Raspberry Pi OS](https://www.raspberrypi.com/software/operating-systems/):

- Run the system live
- Clean bad configurations on reboot
- Better performance running of a SD card
- Manage system configurations
- Switch easily between OS versions
- More predictable and reproducible upgrades

## Build

Download the OS image from the official website. Then:

    sudo ./build.sh [-s extra_size] [-o output_dir] <path_image_file>

- `-s extra_size` — grow the rootfs partition by this amount (default `2G`).
- `-o output_dir` — where the output `.zip` is written (default `out/`).

`build.sh` can be installed on `PATH` and run as a system command from any
directory:

    sudo install -m755 build.sh /usr/local/bin/raspios-squashfs
    cd ~/my-pi && sudo raspios-squashfs <path_image_file>
