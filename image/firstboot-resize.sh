#!/bin/bash
# SmartEdge first-boot rootfs resize.
#
# Grows partition 2 + its ext4 filesystem to fill whatever eMMC the image was
# flashed to (8GB / 16GB / 32GB ... - the image ships compact on purpose so a
# single build covers every board size).
#
# Why this is safe where the stock init_resize.sh was not (hardware incident
# 2026-10-12): this is a plain systemd oneshot that runs AFTER local-fs.
#   - no init= override in cmdline, boot never depends on us
#   - no initramfs, no "mount /boot" / fstab assumptions
#   - partition grown with sfdisk + partx -u (BLKPG works on a live partition)
#   - ext4 grown online with resize2fs (mounted root is supported)
#   - no reboot needed; if anything fails we just log and retry next boot
#     (the flag file is only written after full success)
set -u

FLAG=/var/lib/smartedge/.rootfs_resized
log() { echo "[firstboot-resize] $*"; }

[ -e "$FLAG" ] && exit 0

command -v sfdisk    >/dev/null || { log "sfdisk not found";    exit 1; }
command -v resize2fs >/dev/null || { log "resize2fs not found"; exit 1; }

ROOT_PART=$(findmnt -nro SOURCE /) || { log "cannot resolve root source"; exit 1; }
ROOT_BN=$(basename "$ROOT_PART")
DEV=$(lsblk -nro pkname "$ROOT_PART") || { log "cannot resolve parent disk of $ROOT_PART"; exit 1; }
PARTNUM=$(cat "/sys/class/block/$ROOT_BN/partition") 2>/dev/null \
    || { log "no partition number for $ROOT_BN"; exit 1; }

DISK_SECT=$(cat "/sys/class/block/${DEV#/dev/}/size")
P_START=$(cat "/sys/class/block/$ROOT_BN/start")
P_SIZE=$(cat "/sys/class/block/$ROOT_BN/size")
log "root=$ROOT_PART disk=$DEV ($DISK_SECT sectors), part$PARTNUM start=$P_START size=$P_SIZE"

if [ "$((P_START + P_SIZE))" -ge "$DISK_SECT" ]; then
    log "root partition already fills the disk - nothing to do"
    mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
    exit 0
fi

# --- grow the partition (rootfs is the last partition -> extend to disk end) --
# ',+' keeps existing geometry, '+' size = "as much as possible".
# --no-reread: we are running from this partition; partx below informs the
# kernel instead (BLKPG ioctl is legal on a mounted, in-use partition).
echo ',+' | sfdisk -N"$PARTNUM" --no-reread "$DEV" || { log "sfdisk resize FAILED"; exit 1; }
partx -u "$DEV" 2>/dev/null || partprobe "$DEV" 2>/dev/null || true

NEW_SIZE=$(cat "/sys/class/block/$ROOT_BN/size")
log "partition now $NEW_SIZE sectors"
[ "$NEW_SIZE" -gt "$P_SIZE" ] || { log "partition did not grow - aborting"; exit 1; }

# --- grow the filesystem online ----------------------------------------------
resize2fs "$ROOT_PART" || { log "resize2fs FAILED - will retry next boot"; exit 1; }

df -h "$ROOT_PART"
mkdir -p "$(dirname "$FLAG")"
touch "$FLAG"
log "done - rootfs now fills the disk; free space available immediately"
