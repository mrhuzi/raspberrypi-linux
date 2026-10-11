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
# cmdline: keep image PARTUUID root=, drop imager leftovers, add CN regdom,
# add first-boot resize via raspi-config's init_resize.sh when available
cmd=$(tr '\n' ' ' < "$BOOT/cmdline.txt")
cmd=$(echo "$cmd" | sed -E 's/ *ds=nocloud;[^ ]*//g')
cmd="$cmd cfg80211.ieee80211_regdom=CN"
if [ -f "$ROOT/usr/lib/raspi-config/init_resize.sh" ]; then
    echo "raspi-config init_resize.sh present -> using it for first-boot resize"
    case "$cmd" in
        *init=*) : ;;
        *) cmd="$cmd init=/usr/lib/raspi-config/init_resize.sh" ;;
    esac
else
    echo "init_resize.sh NOT present -> installing fallback firstboot-resize service"
    install -m 755 "$REPO_ROOT/image/firstboot-resize.sh" \
        "$ROOT/usr/local/sbin/firstboot-resize.sh"
    install -m 644 "$REPO_ROOT/image/firstboot-resize.service" \
        "$ROOT/etc/systemd/system/firstboot-resize.service"
    mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/firstboot-resize.service \
        "$ROOT/etc/systemd/system/multi-user.target.wants/firstboot-resize.service"
fi
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
echo 'avnet:avnet' | chpasswd -R "$ROOT"
if ! grep -q '^sudo:.*avnet' "$ROOT/etc/group"; then
    awk -F: 'BEGIN{OFS=":"} $1=="sudo"{if($4=="")$4="avnet";else $4=$4",avnet"} {print}' \
        "$ROOT/etc/group" > "$ROOT/etc/group.new"
    mv "$ROOT/etc/group.new" "$ROOT/etc/group"
fi

echo "== 10. sanity checks =="
test -f "$BOOT/kernel8.img"
test -f "$BOOT/bcm2710-rpi-custom.dtb"
test -f "$BOOT/dt-blob.bin"
test -f "$BOOT/ssh"
grep -q 'uart0=off' "$BOOT/config.txt"
grep -q 'regdom=CN' "$BOOT/cmdline.txt"
grep -q '^avnet:' "$ROOT/etc/passwd"
grep -q 'avnet' "$ROOT/etc/group"
test -f "$ROOT/etc/systemd/system/multi-user.target.wants/attiny-wdt-feed.service"
test -s "$ROOT/lib/modules/$KVER/modules.dep"

echo "== 11. detach + compress =="
sync
umount -R "$BOOT" "$ROOT"
losetup -d "$LOOP"
trap - EXIT

OUT="smartedge-lite-arm64-$(date +%Y%m%d)-$KVER.img"
mv base.img "$OUT"
XZ_OPT="-T0 -6" xz -T0 -6 "$OUT"
sha256sum "$OUT.xz" > "$OUT.xz.sha256"
ls -la "$OUT.xz" "$OUT.xz.sha256"
echo "IMAGE READY: $WORKDIR/$OUT.xz"
