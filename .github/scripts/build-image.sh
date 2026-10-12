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
#
# Must run as root on an Ubuntu Actions runner (needs loop devices).
set -euo pipefail

: "${ARTDIR:?ARTDIR not set}"
: "${WORKDIR:?WORKDIR not set}"

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
# drop (wrong kernel modules) - so we pre-expand the rootfs at build time
# (step 11) and remove the dead "resize" param here.
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

echo "== 9. rootfs: user avnet (sudo) =="
useradd -R "$ROOT" -u 1000 -m -d /home/avnet -s /bin/bash \
    -c "Raspberry Pi OS" avnet 2>/dev/null || true
if ! grep -q '^avnet:' "$ROOT/etc/passwd"; then
    # fallback: append entries manually
    echo 'avnet:x:1000:1000:Raspberry Pi OS:/home/avnet:/bin/bash' >> "$ROOT/etc/passwd"
    grep -q '^avnet:' "$ROOT/etc/group" || echo 'avnet:x:1000:' >> "$ROOT/etc/group"
    hash=$(openssl passwd -6 avnet)
    echo "avnet:${hash}:2:0:99999:7:::" >> "$ROOT/etc/shadow"
fi
echo 'avnet:avnet' | chpasswd -R "$ROOT" 2>/dev/null || true
# chpasswd -R invokes the TARGET's PAM (arm64 modules, unloadable on x86 host)
# so it always fails. Write the hash directly instead - host-side, no PAM.
hash=$(openssl passwd -6 avnet)
sed -i "s|^avnet:[^:]*:|avnet:${hash}:|" "$ROOT/etc/shadow"
grep -q "^avnet:${hash}:" "$ROOT/etc/shadow" || { echo "shadow write failed"; exit 1; }
if ! grep -q '^sudo:.*avnet' "$ROOT/etc/group"; then
    awk -F: 'BEGIN{OFS=":"} $1=="sudo"{if($4=="")$4="avnet";else $4=$4",avnet"} {print}' \
        "$ROOT/etc/group" > "$ROOT/etc/group.new"
    mv "$ROOT/etc/group.new" "$ROOT/etc/group"
fi

echo "== 10. sanity checks =="
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
# NOTE: use -L (symlink exists) not -f: the link target is an absolute path
# that only resolves on the TARGET filesystem, not on the build host.
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/attiny-wdt-feed.service" ] || fail "wdt unit enable"
[ -f "$ROOT/etc/systemd/system/attiny-wdt-feed.service" ] || fail "wdt unit file"
[ -s "$ROOT/lib/modules/$KVER/modules.dep" ] || fail "modules.dep ($(stat -c%s "$ROOT/lib/modules/$KVER/modules.dep" 2>/dev/null || echo missing))"
echo "modules.dep size: $(stat -c%s "$ROOT/lib/modules/$KVER/modules.dep")"
echo "ALL SANITY CHECKS PASSED"

echo "== 11. pre-expand root partition + filesystem (replaces first-boot resize) =="
# The SmartEdge eMMC is a fixed 16GB part (~14.6GiB). Pre-size the image to
# 14.5GiB (30408704 sectors) - safely below the smallest real 16GB eMMC - and
# grow partition 2 + ext4 to fill it, so the flashed system needs ZERO
# first-boot resize logic (the classic source of unbootable images).
trap - EXIT
umount "$BOOT"
umount "$ROOT"
truncate -s 15569256448 base.img
losetup -d "$LOOP"
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

echo "== 12. compress =="
OUT="smartedge-lite-arm64-$(date +%Y%m%d)-$KVER.img"
mv base.img "$OUT"
XZ_OPT="-T0 -6" xz -T0 -6 "$OUT"
sha256sum "$OUT.xz" > "$OUT.xz.sha256"
ls -la "$OUT.xz" "$OUT.xz.sha256"
echo "IMAGE READY: $WORKDIR/$OUT.xz"
