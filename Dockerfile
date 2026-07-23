# syntax=docker/dockerfile:1
# Base image ref is injected by raspios-squashfs.sh (raspios-base:<source name>)
ARG BASE=raspios-base:latest
FROM ${BASE}

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

ARG TO_INSTALL=""
ARG TO_REMOVE=""
RUN sed -i 's/^MODULES=dep/MODULES=most/' /etc/initramfs-tools/initramfs.conf && \
    apt-get upgrade -y live-boot+ $TO_INSTALL $TO_REMOVE && \
    sed -i 's/^MODULES=most/MODULES=dep/' /etc/initramfs-tools/initramfs.conf

RUN apt-get autoremove --purge -y && apt-get clean
# && rm -rf /var/lib/apt/lists/*

# Override fstab
RUN cat > /etc/fstab << 'EOF'
# /dev/mmcblk0p1  /boot/firmware  vfat    defaults  0 0
proc            /proc           proc    defaults  0 0
tmpfs           /tmp            tmpfs   defaults  0 0
EOF

# Create SSH server keys (preserve server fingerprint between reboots)
RUN ssh-keygen -A
