#!/bin/bash

/bin/bash

cd /chroot/
cat packages-remove  | sed '/^#/d; /^$/d' | xargs apt remove  -y
cat packages-install | sed '/^#/d; /^$/d' | xargs apt install -y
apt autoremove -y
#apt update && apt upgrade