#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
OUT_DIR="$ROOT/osboot"
ISO_ROOT="$BUILD_DIR/iso-root"
ISO_OUT="$OUT_DIR/farewell.iso"
GRUB_EARLY_CFG="$BUILD_DIR/grub-early.cfg"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"

KERNEL="$OUT_DIR/bzImage"
SINGLE_INITRAMFS="$OUT_DIR/single.gz"
MULTI_INITRAMFS="$OUT_DIR/multi.gz"

case "$SOURCE_DATE_EPOCH" in
  ''|*[!0-9]*)
    echo "[ERROR] SOURCE_DATE_EPOCH must be an integer Unix timestamp" >&2
    exit 1
    ;;
esac

export SOURCE_DATE_EPOCH
export LC_ALL=C
export TZ=UTC
umask 022

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

find_grub_mkimage() {
  if command -v grub2-mkimage >/dev/null 2>&1; then
    command -v grub2-mkimage
    return
  fi

  if command -v grub-mkimage >/dev/null 2>&1; then
    command -v grub-mkimage
    return
  fi

  echo "[ERROR] Missing required command: grub2-mkimage or grub-mkimage" >&2
  exit 1
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "[ERROR] Missing required file: $1" >&2
    echo "        Build it first with: $2" >&2
    exit 1
  fi
}

create_iso_tree() {
  echo "[INFO] Creating bootable ISO tree..."
  rm -rf "$ISO_ROOT"
  mkdir -p "$ISO_ROOT/boot/grub/i386-pc" "$ISO_ROOT/boot/grub2"

  cp "$KERNEL" "$ISO_ROOT/boot/bzImage"
  cp "$SINGLE_INITRAMFS" "$ISO_ROOT/boot/single.gz"
  cp "$MULTI_INITRAMFS" "$ISO_ROOT/boot/multi.gz"

  cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF_GRUB'
set timeout=10
set default=0

serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
terminal_input serial
terminal_output serial

menuentry "Farewell Party - Single User Filesystem" {
    linux /boot/bzImage console=ttyS0 rdinit=/init
    initrd /boot/single.gz
}

menuentry "Farewell Party - Multi User Filesystem" {
    linux /boot/bzImage console=ttyS0 rdinit=/init
    initrd /boot/multi.gz
}
EOF_GRUB

  cp "$ISO_ROOT/boot/grub/grub.cfg" "$ISO_ROOT/boot/grub2/grub.cfg"
  find "$ISO_ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
}

pack_iso() {
  local grub_mkimage
  local eltorito_img
  local iso_date
  grub_mkimage="$(find_grub_mkimage)"
  eltorito_img="$ISO_ROOT/boot/grub/i386-pc/eltorito.img"

  need_cmd xorriso
  need_cmd date
  iso_date="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M%S00')"

  cat > "$GRUB_EARLY_CFG" <<'EOF_EARLY_GRUB'
search --file --set=root /boot/grub/grub.cfg
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EOF_EARLY_GRUB
  touch -d "@$SOURCE_DATE_EPOCH" "$GRUB_EARLY_CFG"

  echo "[INFO] Building deterministic GRUB El Torito image..."
  "$grub_mkimage" \
    -O i386-pc-eltorito \
    -C none \
    -c "$GRUB_EARLY_CFG" \
    -o "$eltorito_img" \
    -p /boot/grub \
    iso9660 biosdisk linux normal configfile search serial terminal
  touch -d "@$SOURCE_DATE_EPOCH" "$eltorito_img"

  echo "[INFO] Packing bootable ISO to $ISO_OUT..."
  find "$ISO_ROOT" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
  xorriso -as mkisofs \
    -R \
    -J \
    -V ISOIMAGE \
    -b boot/grub/i386-pc/eltorito.img \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -o "$ISO_OUT" \
    "$ISO_ROOT" \
    --modification-date="$iso_date" \
    --set_all_file_dates "$iso_date" \
    >/dev/null
  touch -d "@$SOURCE_DATE_EPOCH" "$ISO_OUT"
}

mkdir -p "$BUILD_DIR" "$OUT_DIR"

require_file "$KERNEL" "./kernel.sh"
require_file "$SINGLE_INITRAMFS" "./single.sh"
require_file "$MULTI_INITRAMFS" "./multi.sh"

create_iso_tree
pack_iso

echo "[OK] Bootable ISO built: $ISO_OUT"
