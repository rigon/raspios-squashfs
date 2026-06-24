#!/bin/bash

/bin/bash

apt-get update

# Add/remove the desired packages in the final build
PACKAGES=$(cat packages | sed '/^#/d; /^$/d' | sort -u)
INSTALLED=$(apt-mark showmanual | sort -u)
readarray -t TO_INSTALL < <(comm -13 <(echo "$INSTALLED") <(echo "$PACKAGES"))
readarray -t TO_REMOVE < <(comm -23 <(echo "$INSTALLED") <(echo "$PACKAGES"))

# Add live-boot to allow booting from squashfs
sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf
apt-get upgrade -y live-boot+ "${TO_INSTALL[@]/%/+}" "${TO_REMOVE[@]/%/-}"
sed -i 's/^MODULES=most/MODULES=dep/' /etc/initramfs-tools/initramfs.conf

apt-get autoremove --purge -y
# apt-get upgrade -y

/bin/bash

apt clean
rm -rf /var/lib/apt/lists/*
rm /boot/initrd.img-* /boot/vmlinuz-*

# Override fstab
cat > /etc/fstab << EOF
# /dev/mmcblk0p1  /boot/firmware  vfat    defaults  0 0
proc            /proc           proc    defaults  0 0
tmpfs           /tmp            tmpfs   defaults  0 0
EOF

