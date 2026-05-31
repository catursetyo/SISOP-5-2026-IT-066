#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$ROOT/osboot"

KERNEL="$OUT_DIR/bzImage"
SINGLE_INITRAMFS="$OUT_DIR/single.gz"
MULTI_INITRAMFS="$OUT_DIR/multi.gz"
ISO="$OUT_DIR/farewell.iso"

if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  case "$SOURCE_DATE_EPOCH" in
    ''|*[!0-9]*)
      echo "[ERROR] SOURCE_DATE_EPOCH must be an integer Unix timestamp" >&2
      exit 1
      ;;
  esac
  TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" +%d%m%Y-%H%M%S)"
else
  TIMESTAMP="$(date +%d%m%Y-%H%M%S)"
fi
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
zip -X -j -q "$BACKUP_PATH" \
  "$KERNEL" \
  "$SINGLE_INITRAMFS" \
  "$MULTI_INITRAMFS" \
  "$ISO"

if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  touch -d "@$SOURCE_DATE_EPOCH" "$BACKUP_PATH"
fi

echo "[OK] Backup created: $BACKUP_PATH"
