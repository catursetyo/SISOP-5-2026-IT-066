#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
OUT_DIR="$ROOT/osboot"
ISO_ROOT="$BUILD_DIR/iso-root"
ISO_OUT="$OUT_DIR/farewell.iso"

KERNEL="$OUT_DIR/bzImage"
SINGLE_INITRAMFS="$OUT_DIR/single.gz"
MULTI_INITRAMFS="$OUT_DIR/multi.gz"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

find_grub_mkrescue() {
  if command -v grub2-mkrescue >/dev/null 2>&1; then
    command -v grub2-mkrescue
    return
  fi

  if command -v grub-mkrescue >/dev/null 2>&1; then
    command -v grub-mkrescue
    return
  fi

  echo "[ERROR] Missing required command: grub2-mkrescue or grub-mkrescue" >&2
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
  mkdir -p "$ISO_ROOT/boot/grub" "$ISO_ROOT/boot/grub2"

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
}

pack_iso() {
  local grub_mkrescue
  grub_mkrescue="$(find_grub_mkrescue)"

  need_cmd xorriso

  echo "[INFO] Packing bootable ISO to $ISO_OUT..."
  "$grub_mkrescue" -o "$ISO_OUT" "$ISO_ROOT" >/dev/null
}

mkdir -p "$BUILD_DIR" "$OUT_DIR"

require_file "$KERNEL" "./kernel.sh"
require_file "$SINGLE_INITRAMFS" "./single.sh"
require_file "$MULTI_INITRAMFS" "./multi.sh"

create_iso_tree
pack_iso

echo "[OK] Bootable ISO built: $ISO_OUT"
