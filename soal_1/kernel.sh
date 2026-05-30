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

if grep -Fq 'seq_printf(sf, "%s %u\n", dname, iocg->cfg_weight / WEIGHT_ONE);' block/blk-iocost.c; then
  sed -i \
    -e 's|seq_printf(sf, "%s %u\\n", dname, iocg->cfg_weight / WEIGHT_ONE);|seq_printf(sf, "%s %u\\n", dname, (unsigned int)(iocg->cfg_weight / WEIGHT_ONE));|' \
    -e 's|seq_printf(sf, "default %u\\n", iocc->dfl_weight / WEIGHT_ONE);|seq_printf(sf, "default %u\\n", (unsigned int)(iocc->dfl_weight / WEIGHT_ONE));|' \
    block/blk-iocost.c
fi

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

# avoid openSSL/certificate build error on modern Fedora
./scripts/config --disable MODULES
./scripts/config --disable MODULE_SIG
./scripts/config --disable MODULE_SIG_ALL
./scripts/config --disable MODULE_SIG_FORMAT

./scripts/config --disable KEYS
./scripts/config --disable ASYMMETRIC_KEY_TYPE
./scripts/config --disable X509_CERTIFICATE_PARSER
./scripts/config --disable PKCS7_MESSAGE_PARSER
./scripts/config --disable PKCS8_PRIVATE_KEY_PARSER

./scripts/config --disable SYSTEM_TRUSTED_KEYRING
./scripts/config --disable SECONDARY_TRUSTED_KEYRING
./scripts/config --disable SYSTEM_BLACKLIST_KEYRING
./scripts/config --disable SYSTEM_REVOCATION_LIST
./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

./scripts/config --disable INTEGRITY
./scripts/config --disable IMA
./scripts/config --disable EVM
./scripts/config --disable DEBUG_INFO_BTF
./scripts/config --disable WERROR

make olddefconfig

echo "[INFO] Checking certificate/keyring-related configs..."
grep -E 'WERROR|MODULE_SIG|SYSTEM_TRUSTED|SYSTEM_REVOCATION|SYSTEM_BLACKLIST|ASYMMETRIC|X509|PKCS7|KEYS|INTEGRITY|IMA|EVM' .config || true

make CC="gcc -std=gnu11" HOSTCC="gcc -std=gnu11" -j"$(nproc)" bzImage

cp arch/x86/boot/bzImage "$OUT/bzImage"
cp .config "$ROOT/.config"

echo "[OK] Kernel built: $OUT/bzImage"
