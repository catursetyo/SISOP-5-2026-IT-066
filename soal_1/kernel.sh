#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
OUT_DIR="$ROOT/osboot"
KERNEL_VERSION="6.1.1"
KERNEL_SHA256="a3e61377cf4435a9e2966b409a37a1056f6aaa59e561add9125a88e3c0971dfb"
KERNEL_ARCHIVE="$BUILD_DIR/linux-$KERNEL_VERSION.tar.xz"
LINUX_DIR="$BUILD_DIR/linux-$KERNEL_VERSION"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"

case "$SOURCE_DATE_EPOCH" in
  ''|*[!0-9]*)
    echo "[ERROR] SOURCE_DATE_EPOCH must be an integer Unix timestamp" >&2
    exit 1
    ;;
esac

export SOURCE_DATE_EPOCH
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-farewell}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-party}"
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-1}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%d %H:%M:%S')}"
export KCONFIG_NOTIMESTAMP=1
export LC_ALL=C
export TZ=UTC
umask 022

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

mkdir -p "$BUILD_DIR" "$OUT_DIR"

need_cmd sha256sum
need_cmd wget
need_cmd tar
need_cmd make
need_cmd gcc
need_cmd date

cd "$BUILD_DIR"

if [ ! -f "$KERNEL_ARCHIVE" ]; then
  echo "[INFO] Downloading Linux $KERNEL_VERSION..."
  wget -O "$KERNEL_ARCHIVE" \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KERNEL_VERSION.tar.xz"
fi

echo "$KERNEL_SHA256  $KERNEL_ARCHIVE" | sha256sum -c -

if [ ! -d "$LINUX_DIR" ]; then
  echo "[INFO] Extracting Linux $KERNEL_VERSION..."
  tar --delay-directory-restore -xf "$KERNEL_ARCHIVE"
fi

cd "$LINUX_DIR"

if grep -Fq 'seq_printf(sf, "%s %u\n", dname, iocg->cfg_weight / WEIGHT_ONE);' block/blk-iocost.c; then
  sed -i \
    -e 's|seq_printf(sf, "%s %u\\n", dname, iocg->cfg_weight / WEIGHT_ONE);|seq_printf(sf, "%s %u\\n", dname, (unsigned int)(iocg->cfg_weight / WEIGHT_ONE));|' \
    -e 's|seq_printf(sf, "default %u\\n", iocc->dfl_weight / WEIGHT_ONE);|seq_printf(sf, "default %u\\n", (unsigned int)(iocc->dfl_weight / WEIGHT_ONE));|' \
    block/blk-iocost.c
fi

if [ -f "$ROOT/.config" ]; then
  echo "[INFO] Using tracked kernel config: $ROOT/.config"
  cp "$ROOT/.config" .config
else
  echo "[INFO] No tracked .config found; creating defconfig baseline..."
  make defconfig
fi

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

# keep kernel release/build metadata deterministic
./scripts/config --set-str LOCALVERSION ""
./scripts/config --disable LOCALVERSION_AUTO
./scripts/config --set-str BUILD_SALT ""

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
echo "[INFO] Reproducible kernel metadata:"
echo "       KBUILD_BUILD_TIMESTAMP=$KBUILD_BUILD_TIMESTAMP"
echo "       KBUILD_BUILD_USER=$KBUILD_BUILD_USER"
echo "       KBUILD_BUILD_HOST=$KBUILD_BUILD_HOST"

make CC="gcc -std=gnu11" HOSTCC="gcc -std=gnu11" -j"$(nproc)" bzImage

cp arch/x86/boot/bzImage "$OUT_DIR/bzImage"
touch -d "@$SOURCE_DATE_EPOCH" "$OUT_DIR/bzImage"

if [ "${UPDATE_CONFIG:-0}" = "1" ]; then
  echo "[INFO] Updating tracked kernel config: $ROOT/.config"
  cp .config "$ROOT/.config"
  touch -d "@$SOURCE_DATE_EPOCH" "$ROOT/.config"
fi

echo "[OK] Kernel built: $OUT_DIR/bzImage"
