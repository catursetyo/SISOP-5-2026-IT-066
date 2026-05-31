#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$ROOT/osboot"

KERNEL="$OUT_DIR/bzImage"
SINGLE_INITRAMFS="$OUT_DIR/single.gz"
MULTI_INITRAMFS="$OUT_DIR/multi.gz"
ISO="$OUT_DIR/farewell.iso"

TIMESTAMP="$(date +%d%m%Y-%H%M%S)"
BACKUP_NAME="farewell_backup_[$TIMESTAMP].zip"
BACKUP_PATH="$OUT_DIR/$BACKUP_NAME"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

require_file() {
  if [ ! -f "$1" ]; then
    echo "[ERROR] Missing required file: $1" >&2
    exit 1
  fi
}

mkdir -p "$OUT_DIR"
need_cmd zip

require_file "$KERNEL"
require_file "$SINGLE_INITRAMFS"
require_file "$MULTI_INITRAMFS"
require_file "$ISO"

if [ -e "$BACKUP_PATH" ]; then
  echo "[ERROR] Backup already exists: $BACKUP_PATH" >&2
  exit 1
fi

echo "[INFO] Creating backup: $BACKUP_PATH"
zip -j -q "$BACKUP_PATH" \
  "$KERNEL" \
  "$SINGLE_INITRAMFS" \
  "$MULTI_INITRAMFS" \
  "$ISO"

echo "[OK] Backup created: $BACKUP_PATH"
