#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/build"
OUT="$ROOT/osboot"
KVER="6.1.1"
LINUX="$BUILD/linux-$KVER"

mkdir -p "$BUILD" "$OUT"

cd "$BUILD"

if [ ! -d "$LINUX" ]; then
  wget -nc "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz"
  tar -xf "linux-$KVER.tar.xz"
fi

cd "$LINUX"

make defconfig

# for initramfs boot
./scripts/config --enable BLK_DEV_INITRD
./scripts/config --enable DEVTMPFS
./scripts/config --enable DEVTMPFS_MOUNT
./scripts/config --enable PROC_FS
./scripts/config --enable SYSFS
./scripts/config --enable TMPFS
./scripts/config --enable BINFMT_ELF

# for serial console in QEMU -nongraphic
./scripts/config --enable SERIAL_8250
./scripts/config --enable SERIAL_8250_CONSOLE

# for QEMU networking
./scripts/config --enable NET
./scripts/config --enable INET
./scripts/config --enable PACKET
./scripts/config --enable UNIX
./scripts/config --enable E1000

./scripts/config --enable FUSE_FS

# avoid openSSL/certificate build error on modern fedora
./scripts/config --disable MODULE_SIG
./scripts/config --disable SYSTEM_TRUSTED_KEYRING
./scripts/config --disable SECONDARY_TRUSTED_KEYRING
./scripts/config --disable SYSTEM_BLACKLIST_KEYRING
./scripts/config --disable SYSTEM_REVOCATION_LIST
./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

./scripts/config --disable DEBUG_INFO_BTF

make olddefconfig

# force gcc to use gnu11 instead of c23
make CC="gcc -std=gnu11" HOSTCC="gcc -std=gnu11" -j"$(nproc)" bzImage

cp arch/x86/boot/bzImage "$OUT/bzImage"
cp .config "$ROOT/.config"

echo "[OK] Kernel built: $OUT/bzImage"
