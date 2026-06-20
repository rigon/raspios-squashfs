#!/bin/bash

/bin/bash

apt update

# Add live-boot to allow booting from squashfs
sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf
apt-get install -y live-boot
sed -i 's/^MODULES=most/MODULES=dep/' /etc/initramfs-tools/initramfs.conf

cd /chroot/
cat packages-remove  | sed '/^#/d; /^$/d' | xargs apt remove  -y
cat packages-install | sed '/^#/d; /^$/d' | xargs apt install -y
#apt update && apt upgrade
apt-get clean && apt-get autoremove --purge -y
rm -rf /var/lib/apt/lists/*
rm /boot/initrd.img-* /boot/vmlinuz-*

# Override fstab
cat > /etc/fstab << EOF
# /dev/mmcblk0p1  /boot/firmware  vfat    defaults  0 0
proc            /proc           proc    defaults  0 0
tmpfs           /tmp            tmpfs   defaults  0 0
EOF

/bin/bash
