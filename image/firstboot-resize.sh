#!/bin/bash
# SmartEdge first-boot rootfs resize (v2, 2026-10-12).
#
# Grows partition 2 + its ext4 filesystem to fill whatever eMMC the image was
# flashed to (8GB / 16GB / 32GB ... - the image ships compact on purpose so a
# single build covers every board size).
#
# Design rules (learned the hard way):
#   - plain systemd oneshot AFTER local-fs: boot never depends on us (no
#     init=/initramfs), a failure only means "retry on next boot"
#   - sfdisk needs --force when the partition to grow is MOUNTED (the rootfs
#     we run from is!) - otherwise it asks for confirmation, reads EOF and
#     aborts instantly (hardware failure 2026-10-12, exit within 1 second)
#   - fallback chain if sfdisk is unusable: parted -s, then a raw MBR patch
#   - the log lands on /boot/firmware (FAT, world-readable) so the operator
#     can read it over SSH WITHOUT root
#   - RESIZE_TEST_DEVICE=<part> RESIZE_TEST=1 runs the exact same code path
#     against an arbitrary device (CI selftest) without touching the flag
set -u

FLAG=/var/lib/smartedge/.rootfs_resized
TEST_DEVICE="${RESIZE_TEST_DEVICE:-}"
TEST_MODE="${RESIZE_TEST:-0}"

log() { echo "[$(date '+%F %T')] [firstboot-resize] $*"; }

# --- logging target -----------------------------------------------------------
# /boot/firmware is vfat (default perms make files world-readable): operators
# without root can still fetch the log over SSH.
if [ "$TEST_MODE" = "1" ] || [ -n "$TEST_DEVICE" ]; then
    LOGF=""   # test mode: log to stdout (CI console)
elif mountpoint -q /boot/firmware 2>/dev/null; then
    LOGF=/boot/firmware/firstboot-resize.log
else
    LOGF=/run/firstboot-resize.log
fi
if [ -n "$LOGF" ]; then
    touch "$LOGF" && chmod 644 "$LOGF" && exec >>"$LOGF" 2>&1
fi

log "=== start (pid $$, test=${TEST_DEVICE:-no}) ==="

[ -e "$FLAG" ] && { log "already resized (flag present), exiting"; exit 0; }

SFDISK=/usr/sbin/sfdisk
PARTED=/usr/sbin/parted
PARTPROBE=/usr/sbin/partprobe
RESIZE2FS=/usr/sbin/resize2fs
PARTX=/usr/bin/partx
PYTHON3=/usr/bin/python3

if [ -n "$TEST_DEVICE" ]; then
    ROOT_PART="$TEST_DEVICE"
else
    ROOT_PART=$(findmnt -nro SOURCE /) || { log "FATAL: cannot resolve root source"; exit 1; }
fi
ROOT_BN=$(basename "$ROOT_PART")
DEV=$(lsblk -nro pkname "$ROOT_PART") || { log "FATAL: cannot resolve parent disk of $ROOT_PART"; exit 1; }
PARTNUM=$(cat "/sys/class/block/$ROOT_BN/partition") 2>/dev/null \
    || { log "FATAL: no partition number for $ROOT_BN"; exit 1; }

DISK_SECT=$(cat "/sys/class/block/${DEV#/dev/}/size")
P_START=$(cat "/sys/class/block/$ROOT_BN/start")
P_SIZE=$(cat "/sys/class/block/$ROOT_BN/size")
log "root=$ROOT_PART disk=$DEV ($DISK_SECT sectors), part$PARTNUM start=$P_START size=$P_SIZE"

if [ "$((P_START + P_SIZE))" -ge "$DISK_SECT" ]; then
    log "root partition already fills the disk - nothing to do"
    [ "$TEST_MODE" = "1" ] || { mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; }
    exit 0
fi

dump_diag() {
    log "--- diagnostics begin ---"
    lsblk "$DEV" 2>&1 || true
    [ -x "$SFDISK" ] && "$SFDISK" -d "$DEV" 2>&1 | head -20
    log "--- diagnostics end ---"
}

grow_partition() {
    # method 1: sfdisk. --force is REQUIRED: the partition being grown is the
    # mounted rootfs; without --force sfdisk asks for confirmation, reads EOF
    # from stdin and aborts (hardware-verified 2026-10-12).
    if [ -x "$SFDISK" ]; then
        echo ',+' | "$SFDISK" --force -N"$PARTNUM" --no-reread "$DEV" && return 0
        log "sfdisk method failed (rc=$?) - trying parted"
    else
        log "$SFDISK not present - trying parted"
    fi
    # method 2: parted script mode (no prompt with -s)
    if [ -x "$PARTED" ]; then
        "$PARTED" -s "$DEV" resizepart "$PARTNUM" 100% && return 0
        log "parted method failed (rc=$?) - trying raw MBR patch"
    else
        log "$PARTED not present - trying raw MBR patch"
    fi
    # method 3: raw MBR patch (dos label): rewrite the p<N> entry size so the
    # partition reaches the end of the disk. CHS fields are ignored by modern
    # parsers (and by the kernel's BLKPG update below).
    if [ -x "$PYTHON3" ]; then
        "$PYTHON3" - "$DEV" "$PARTNUM" <<'PYEOF' && return 0
import struct, sys
dev, part = sys.argv[1], int(sys.argv[2])
with open(dev, "r+b") as f:
    mbr = bytearray(f.read(512))
    if mbr[510:512] != b"\x55\xaa":
        sys.exit("not a DOS/MBR disk")
    off = 446 + 16 * (part - 1)
    lba_start = struct.unpack("<I", mbr[off+8:off+12])[0]
    if lba_start == 0:
        sys.exit("empty partition entry")
    total = f.seek(0, 2)
    total //= 512
    if lba_start >= total:
        sys.exit("bad geometry: start=%d total=%d" % (lba_start, total))
    mbr[off+12:off+16] = struct.pack("<I", total - lba_start)
    f.seek(0)
    f.write(mbr)
print("raw MBR patch applied: part%d -> %d sectors" % (part, total - lba_start))
PYEOF
        log "raw MBR method failed (rc=$?)"
    else
        log "$PYTHON3 not present - no method left"
    fi
    return 1
}

grow_partition || { log "FATAL: all partition-grow methods failed"; dump_diag; exit 1; }

# inform the kernel (BLKPG works on a mounted, in-use partition)
"$PARTX" -u "$DEV" 2>/dev/null || { [ -x "$PARTPROBE" ] && "$PARTPROBE" "$DEV" 2>/dev/null; } || true

NEW_SIZE=$(cat "/sys/class/block/$ROOT_BN/size")
log "partition now $NEW_SIZE sectors"
[ "$NEW_SIZE" -gt "$P_SIZE" ] || { log "FATAL: partition did not grow"; dump_diag; exit 1; }

# --- grow the filesystem online (ext4 supports growing a mounted rootfs) ------
if [ -x "$RESIZE2FS" ]; then
    "$RESIZE2FS" "$ROOT_PART" || { log "FATAL: resize2fs failed - will retry next boot"; exit 1; }
else
    log "FATAL: resize2fs missing at $RESIZE2FS"
    exit 1
fi

df -h "$ROOT_PART"
[ "$TEST_MODE" = "1" ] || { mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"; }
log "done - rootfs now fills the disk; free space available immediately"
