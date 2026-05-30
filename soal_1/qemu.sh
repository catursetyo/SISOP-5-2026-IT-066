#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$ROOT/osboot"

COMMON=(
  qemu-system-x86_64
  -m 512M
  -nographic
  -netdev user,id=net0
  -device e1000,netdev=net0
)

case "${1:-}" in
  --single)
    "${COMMON[@]}" \
      -kernel "$OUT/bzImage" \
      -initrd "$OUT/single.gz" \
      -append "console=ttyS0 rdinit=/init"
    ;;

  --multi)
    "${COMMON[@]}" \
      -kernel "$OUT/bzImage" \
      -initrd "$OUT/multi.gz" \
      -append "console=ttyS0 rdinit=/init"
    ;;

  --all)
    "${COMMON[@]}" \
      -cdrom "$OUT/farewell.iso" \
      -boot d
    ;;

  *)
    echo "usage: $0 --single | --multi | --all"
    exit 1
    ;;
esac
