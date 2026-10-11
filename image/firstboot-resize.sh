#!/bin/sh
# SmartEdge first-boot rootfs resize (fallback when raspi-config's
# init_resize.sh is not present in the image).
set -e

DEV=$(findmnt -n -o SOURCE /)          # e.g. /dev/mmcblk0p2
PARENT=${DEV%p*}                        # /dev/mmcblk0
ROOTSZ=$(blockdev --getsize64 "$DEV")
DISKSZ=$(blockdev --getsize64 "$PARENT")

# already grown beyond 90% of the disk -> nothing to do, remove self
if [ "$ROOTSZ" -ge $((DISKSZ * 90 / 100)) ]; then
    systemctl disable firstboot-resize.service || true
    rm -f /etc/systemd/system/multi-user.target.wants/firstboot-resize.service
    exit 0
fi

parted -s "$PARENT" resizepart "${DEV##*p}" 100%
resize2fs "$DEV"

systemctl disable firstboot-resize.service || true
rm -f /etc/systemd/system/multi-user.target.wants/firstboot-resize.service
