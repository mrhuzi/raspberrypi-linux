#!/usr/bin/env bash
# Build the SmartEdge Lite eMMC image:
#   official Raspberry Pi OS Lite (arm64, Trixie, pinned release)
#   + SmartEdge kernel 6.18.55-v8+ + custom DTB + Avnet boot firmware
#   + attiny-wdt feeder + avnet user + first-boot rootfs resize
#
# Environment:
#   ARTDIR  - directory with the unpacked kernel build artifact
#             (kernel8.img, bcm2710-rpi-custom.dtb, overlays/, modules.tar.gz)
#   WORKDIR - scratch directory (runner temp)
#   PRE_EXPAND_GIB - optional. When set (integer), the image is pre-expanded
#             to this many GiB at build time (e.g. 14 for a 16GB eMMC board).
#             Default: unset -> compact image (~2.9GB) that grows to fill
#             whatever eMMC it is flashed to via firstboot-resize.service
#             (online grow, no init=, no initramfs, no reboot).
#
# Must run as root on an Ubuntu Actions runner (needs loop devices).
set -euo pipefail

: "${ARTDIR:?ARTDIR not set}"
: "${WORKDIR:?WORKDIR not set}"
case "${PRE_EXPAND_GIB:-}" in
    '') ;;
    *[!0-9]*) echo "PRE_EXPAND_GIB must be an integer number of GiB"; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# ---- pinned base image -------------------------------------------------------
BASE_URL="https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-10-06"
IMG="2026-10-06-raspios-trixie-arm64-lite.img.xz"
IMG_SHA256="483db18a48da399b5b7022ffae9a07bc6d99daab30e593aedac09b69ff422843"

cd "$WORKDIR"

echo "== 1. download + verify base image =="
curl -sSL -o base.img.xz "$BASE_URL/$IMG"
echo "$IMG_SHA256  base.img.xz" | sha256sum -c -
xz -d -k -T0 base.img.xz

echo "== 2. attach loop device =="
LOOP=$(losetup --find --show -P base.img)
echo "loop: $LOOP"
BOOT=/mnt/img-boot
ROOT=/mnt/img-root
mkdir -p "$BOOT" "$ROOT"
mount "${LOOP}p1" "$BOOT"
mount "${LOOP}p2" "$ROOT"
cleanup() {
    sync
    umount -R "$BOOT" "$ROOT" 2>/dev/null || true
    losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "== 3. boot partition: kernel + DTB + overlays =="
install -m 755 "$ARTDIR/kernel8.img"             "$BOOT/kernel8.img"
install -m 644 "$ARTDIR/bcm2710-rpi-custom.dtb"  "$BOOT/bcm2710-rpi-custom.dtb"
mkdir -p "$BOOT/overlays"
cp -f "$ARTDIR"/overlays/*.dtbo "$BOOT/overlays/" 2>/dev/null || true
# stale initramfs of the stock kernel would break auto_initramfs - remove
rm -f "$BOOT"/initramfs* "$BOOT"/initrd*

echo "== 4. boot partition: Avnet boot firmware (pinned) =="
install -m 644 "$REPO_ROOT/boot-firmware/bootcode.bin" "$BOOT/bootcode.bin"
install -m 644 "$REPO_ROOT/boot-firmware/dt-blob.bin"  "$BOOT/dt-blob.bin"
install -m 644 "$REPO_ROOT/boot-firmware/start.elf"    "$BOOT/start.elf"
install -m 644 "$REPO_ROOT/boot-firmware/fixup.dat"    "$BOOT/fixup.dat"

echo "== 5. boot partition: config.txt (board-proven) + cmdline.txt =="
install -m 644 "$REPO_ROOT/image/config.txt" "$BOOT/config.txt"
# cmdline: keep image PARTUUID root=, drop imager leftovers, add CN regdom.
# Do NOT inject init=/usr/lib/raspi-config/init_resize.sh: that 2022-era script
# does "mount /boot" + "findmnt /boot", but Trixie only has /boot/firmware in
# fstab. mount /boot fails, the script then fails ("Could not expand
# filesystem"), never removes init= from cmdline -> infinite first-boot reboot
# loop with no sshd (seen on hardware 2026-10-12). The stock image expands via
# the "resize" cmdline param handled inside initramfs8, which we deliberately
# drop (wrong kernel modules) - instead the rootfs grows on first boot via
# firstboot-resize.service (step 9: online grow, no init=, no reboot), so one
# compact image fits ANY eMMC size. Optional build-time pre-expansion for a
# known board size: PRE_EXPAND_GIB (step 13).
cmd=$(tr '\n' ' ' < "$BOOT/cmdline.txt")
cmd=$(echo "$cmd" | sed -E 's/ *ds=nocloud;[^ ]*//g')
cmd=$(echo "$cmd" | sed -E 's/ resize( |$)/ /g; s/ +$//')
cmd="$cmd cfg80211.ieee80211_regdom=CN"
printf '%s\n' "$cmd" > "$BOOT/cmdline.txt"

echo "== 6. enable SSH =="
touch "$BOOT/ssh"

echo "== 7. rootfs: kernel modules =="
tar -C "$ROOT" -xf "$ARTDIR/modules.tar.gz"
TARLIST=$(tar -tf "$ARTDIR/modules.tar.gz")
KVER=$(printf '%s\n' "$TARLIST" | grep -oE 'lib/modules/[^/]+' | sort -u | cut -d/ -f3 | head -n 1)
echo "kernel version: $KVER"
# drop the stock kernel's modules to save space and confusion
find "$ROOT/lib/modules" -mindepth 1 -maxdepth 1 -type d ! -name "$KVER" -exec rm -rf {} +
depmod -b "$ROOT" "$KVER"

echo "== 8. rootfs: ATtiny watchdog feeder =="
install -m 755 "$REPO_ROOT/image/attiny-wdt-feed.sh" "$ROOT/usr/local/bin/attiny-wdt-feed.sh"
install -m 644 "$REPO_ROOT/image/attiny-wdt-feed.service" "$ROOT/etc/systemd/system/attiny-wdt-feed.service"
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/attiny-wdt-feed.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/attiny-wdt-feed.service"

echo "== 9. rootfs: first-boot rootfs resize (universal eMMC size) =="
# The image ships compact; firstboot-resize.service grows partition 2 + ext4
# online to fill whatever eMMC (8/16/32GB...) it was flashed to. No init=,
# no initramfs, no reboot; on failure it just retries on the next boot.
install -m 755 "$REPO_ROOT/image/firstboot-resize.sh" \
    "$ROOT/usr/local/sbin/firstboot-resize.sh"
install -m 644 "$REPO_ROOT/image/firstboot-resize.service" \
    "$ROOT/etc/systemd/system/firstboot-resize.service"
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/firstboot-resize.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/firstboot-resize.service"

echo "== 10. rootfs: users (drop stock pi, create avnet as uid 1000) =="
# The stock image ships user pi (uid 1000, nologin shell, locked password).
# Leaving it in place collides with avnet on uid 1000: sudo resolves uid 1000
# to the FIRST passwd entry (pi, locked) so password auth never succeeds, and
# 'useradd -R' silently fails so /home/avnet is never created (hardware-
# verified 2026-10-12). Remove pi completely, then create avnet cleanly.
sed -i '/^pi:/d' "$ROOT/etc/passwd" "$ROOT/etc/shadow" "$ROOT/etc/group"
rm -rf "$ROOT/home/pi" "$ROOT/var/spool/mail/pi"
rm -f "$ROOT/etc/sudoers.d/010_pi-nopasswd"
useradd -R "$ROOT" -u 1000 -m -d /home/avnet -s /bin/bash \
    -c "SmartEdge default user" avnet
if ! grep -q '^avnet:' "$ROOT/etc/passwd"; then
    # fallback: append entries manually
    echo 'avnet:x:1000:1000:SmartEdge default user:/home/avnet:/bin/bash' >> "$ROOT/etc/passwd"
    grep -q '^avnet:' "$ROOT/etc/group" || echo 'avnet:x:1000:' >> "$ROOT/etc/group"
    mkdir -p "$ROOT/home/avnet"
    cp -a "$ROOT/etc/skel/." "$ROOT/home/avnet/"
fi
chown -R 1000:1000 "$ROOT/home/avnet" 2>/dev/null || true
# chpasswd -R invokes the TARGET's PAM (arm64 modules, unloadable on x86 host)
# so it always fails. Write the hash directly instead - host-side, no PAM.
hash=$(openssl passwd -6 avnet)
sed -i "s|^avnet:[^:]*:|avnet:${hash}:|" "$ROOT/etc/shadow"
grep -q "^avnet:${hash}:" "$ROOT/etc/shadow" || { echo "shadow write failed"; exit 1; }
# groups: sudo (admin), adm + systemd-journal (read full journal without root)
for g in sudo adm systemd-journal; do
    if ! grep -q "^${g}:.*avnet" "$ROOT/etc/group"; then
        awk -F: -v g="$g" 'BEGIN{OFS=":"} $1==g{if($4=="")$4="avnet";else $4=$4",avnet"} {print}' \
            "$ROOT/etc/group" > "$ROOT/etc/group.new"
        mv "$ROOT/etc/group.new" "$ROOT/etc/group"
    fi
done
# passwordless sudo for avnet (only real user on the board; makes remote
# diagnostics actually possible - the pi/avnet uid collision taught us that)
echo 'avnet ALL=(ALL) NOPASSWD: ALL' > "$ROOT/etc/sudoers.d/010_avnet-nopasswd"
chmod 440 "$ROOT/etc/sudoers.d/010_avnet-nopasswd"

echo "== 11. sanity checks =="
fail() { echo "SANITY FAIL: $*"; exit 1; }
[ -f "$BOOT/kernel8.img" ] || fail kernel8.img
[ -f "$BOOT/bcm2710-rpi-custom.dtb" ] || fail dtb
[ -f "$BOOT/dt-blob.bin" ] || fail dt-blob.bin
[ -f "$BOOT/bootcode.bin" ] || fail bootcode.bin
[ -f "$BOOT/start.elf" ] || fail start.elf
[ -f "$BOOT/ssh" ] || fail ssh
grep -q 'uart0=off' "$BOOT/config.txt" || fail "config uart0=off"
grep -q 'regdom=CN' "$BOOT/cmdline.txt" || fail "cmdline regdom"
if grep -q 'init=' "$BOOT/cmdline.txt"; then fail "cmdline must not contain init= (first-boot resize trap)"; fi
echo "cmdline.txt: $(cat "$BOOT/cmdline.txt")"
echo "avnet passwd: $(grep '^avnet:' "$ROOT/etc/passwd" || echo MISSING)"
grep -q '^avnet:' "$ROOT/etc/passwd" || fail "passwd avnet"
echo "sudo group: $(grep '^sudo:' "$ROOT/etc/group")"
grep -q 'avnet' "$ROOT/etc/group" || fail "group avnet"
echo "avnet shadow: $(grep -c '^avnet:\$6\$' "$ROOT/etc/shadow") entry"
grep -q '^avnet:\$6\$' "$ROOT/etc/shadow" || fail "shadow hash"
if grep -q '^pi:' "$ROOT/etc/passwd"; then fail "stock pi user still present (uid 1000 collision)"; fi
[ -d "$ROOT/home/avnet" ] || fail "avnet home dir"
[ -f "$ROOT/etc/sudoers.d/010_avnet-nopasswd" ] || fail "avnet sudoers"
[ -x "$ROOT/usr/sbin/sfdisk" ] || fail "sfdisk present (resize dependency)"
[ -x "$ROOT/usr/sbin/resize2fs" ] || fail "resize2fs present (resize dependency)"
[ -x "$ROOT/usr/sbin/parted" ] || fail "parted present (resize fallback)"
# NOTE: use -L (symlink exists) not -f: the link target is an absolute path
# that only resolves on the TARGET filesystem, not on the build host.
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/attiny-wdt-feed.service" ] || fail "wdt unit enable"
[ -f "$ROOT/etc/systemd/system/attiny-wdt-feed.service" ] || fail "wdt unit file"
[ -f "$ROOT/usr/local/sbin/firstboot-resize.sh" ] || fail "firstboot-resize.sh"
[ -f "$ROOT/etc/systemd/system/firstboot-resize.service" ] || fail "firstboot-resize unit"
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/firstboot-resize.service" ] || fail "resize unit enable"
[ -s "$ROOT/lib/modules/$KVER/modules.dep" ] || fail "modules.dep ($(stat -c%s "$ROOT/lib/modules/$KVER/modules.dep" 2>/dev/null || echo missing))"
echo "modules.dep size: $(stat -c%s "$ROOT/lib/modules/$KVER/modules.dep")"
echo "ALL SANITY CHECKS PASSED"

echo "== 12. detach image =="
trap - EXIT
umount "$BOOT"
umount "$ROOT"
losetup -d "$LOOP"
LOOP=""
sync

if [ -n "${PRE_EXPAND_GIB:-}" ]; then
    echo "== 13. optional pre-expand to ${PRE_EXPAND_GIB}GiB =="
    # For a known board size (e.g. PRE_EXPAND_GIB=14 for the 16GB eMMC) the
    # image can be pre-sized so even firstboot-resize has nothing to do.
    # Must stay BELOW the smallest real eMMC that will receive this image -
    # a bigger image simply cannot be flashed to a smaller disk.
    truncate -s $((PRE_EXPAND_GIB * 1024 * 1024 * 1024)) base.img
    LOOP=$(losetup --find --show -P base.img)
    echo "loop: $LOOP (expanded)"
    e2fsck -fp "${LOOP}p2"
    parted -s "$LOOP" resizepart 2 100%
    partprobe "$LOOP" || partx -u "${LOOP}p2"
    resize2fs -f "${LOOP}p2"
    e2fsck -fp "${LOOP}p2"
    dumpe2fs -h "${LOOP}p2" 2>/dev/null | grep -E 'Block count|Block size' || true
    losetup -d "$LOOP"
    LOOP=""
    sync
else
    echo "== 13. pre-expand skipped: compact image - run firstboot-resize selftest =="
    # Reproduce the real first boot as closely as possible: attach the built
    # image, MOUNT p2 (a mounted rootfs is exactly what made sfdisk abort
    # without --force on hardware 2026-10-12), then run the actual unit
    # script in test mode against the loop device.
    command -v sfdisk >/dev/null 2>&1 || apt-get install -y fdisk
    command -v parted >/dev/null 2>&1 || apt-get install -y parted
    command -v resize2fs >/dev/null 2>&1 || apt-get install -y e2fsprogs
    LOOP2=$(losetup --find --show -P base.img)
    echo "selftest loop: $LOOP2"
    mkdir -p /mnt/selftest-root
    mount "${LOOP2}p2" /mnt/selftest-root
    P2_BN=$(basename "${LOOP2}p2")
    BEFORE=$(cat "/sys/class/block/$P2_BN/size")
    RESIZE_TEST_DEVICE="${LOOP2}p2" RESIZE_TEST=1 \
        bash "$REPO_ROOT/image/firstboot-resize.sh" || {
            echo "SELFTEST FAIL: resize script error"; umount /mnt/selftest-root
            losetup -d "$LOOP2"; exit 1; }
    AFTER=$(cat "/sys/class/block/$P2_BN/size")
    DISK2=$(cat "/sys/class/block/$(basename "$LOOP2")/size")
    echo "selftest: part2 $BEFORE -> $AFTER sectors (disk $DISK2)"
    [ "$AFTER" -gt "$BEFORE" ] || { echo "SELFTEST FAIL: partition did not grow"
        umount /mnt/selftest-root; losetup -d "$LOOP2"; exit 1; }
    FS_BLOCKS=$(dumpe2fs -h "${LOOP2}p2" 2>/dev/null | awk -F': *' '/^Block count/{print $2}')
    FS_BS=$(dumpe2fs -h "${LOOP2}p2" 2>/dev/null | awk -F': *' '/^Block size/{print $2}')
    echo "selftest: fs blocks=$FS_BLOCKS block_size=$FS_BS (part2 bytes=$((AFTER * 512)))"
    [ -n "$FS_BLOCKS" ] && [ -n "$FS_BS" ] || { echo "SELFTEST FAIL: dumpe2fs"
        umount /mnt/selftest-root; losetup -d "$LOOP2"; exit 1; }
    EXPECT=$((AFTER * 512 / FS_BS))
    [ "$((FS_BLOCKS * 100))" -ge "$((EXPECT * 99))" ] || {
        echo "SELFTEST FAIL: filesystem did not grow ($FS_BLOCKS / $EXPECT blocks)"
        umount /mnt/selftest-root; losetup -d "$LOOP2"; exit 1; }
    umount /mnt/selftest-root
    losetup -d "$LOOP2"
    echo "SELFTEST PASS: partition + filesystem grew to fill the image"
fi

echo "== 14. compress =="
OUT="smartedge-lite-arm64-$(date +%Y%m%d)-$KVER.img"
mv base.img "$OUT"
XZ_OPT="-T0 -6" xz -T0 -6 "$OUT"
sha256sum "$OUT.xz" > "$OUT.xz.sha256"
ls -la "$OUT.xz" "$OUT.xz.sha256"
echo "IMAGE READY: $WORKDIR/$OUT.xz"
