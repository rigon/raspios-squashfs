# syntax=docker/dockerfile:1
# Base image tag is injected by build.sh (raspios-base:<source image hash>)
ARG BASE
FROM ${BASE}

# ============================================================
# Required system prep for squashfs live boot — keep this part
# ============================================================

# Refresh apt according to the running release
RUN . /etc/os-release && case "$VERSION_CODENAME" in \
        buster) \
            sed -i.bak 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
            apt-get update --allow-releaseinfo-change ;; \
        bullseye|bookworm) \
            apt-get update --allow-releaseinfo-change ;; \
        *) \
            apt-get update ;; \
    esac

# live-boot enables booting from squashfs. The initramfs must be generated
# with MODULES=most so it contains squashfs/overlay support; restore
# MODULES=dep afterwards. NOTE: wrap any later kernel upgrade in the same
# MODULES dance, or its initramfs won't boot live.
RUN sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf \
 && apt-get install -y live-boot \
 && sed -i 's/^MODULES=most/MODULES=dep/' /etc/initramfs-tools/initramfs.conf

# ============================================================
# Your customizations go here
# ============================================================

# Packages to install
RUN apt-get install -y --no-install-recommends \
        vim \
        htop

# Packages to remove
RUN apt-get remove --purge -y \
        triggerhappy

# Files to overlay onto the image (paths are relative to the build context,
# and land at the same path in the image)
# COPY files/ /

# Anything else you would put in a customization script
# RUN systemctl enable ssh

# The boot partition lives at /boot/firmware in this image, so boot
# configuration can be customized here too:
# COPY config.txt /boot/firmware/config.txt
# RUN sed -i 's/$/ dtoverlay=disable-bt/' /boot/firmware/config.txt

# ============================================================
# Required finalization — keep this part last
# ============================================================

RUN apt-get autoremove --purge -y && apt-get clean && rm -rf /var/lib/apt/lists/*

# Override fstab: the squashfs is the (read-only) root, /tmp on tmpfs
RUN cat > /etc/fstab << 'EOF'
# /dev/mmcblk0p1  /boot/firmware  vfat    defaults  0 0
proc            /proc           proc    defaults  0 0
tmpfs           /tmp            tmpfs   defaults  0 0
EOF

# Create SSH server keys (preserve server fingerprint between reboots)
RUN ssh-keygen -A
