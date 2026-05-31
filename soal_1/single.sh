#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
OUT_DIR="$ROOT/osboot"
ROOTFS_DIR="$BUILD_DIR/single-rootfs"
BUSYBOX_VERSION="1.36.1"
BUSYBOX_ARCHIVE="$BUILD_DIR/busybox-$BUSYBOX_VERSION.tar.bz2"
BUSYBOX_DIR="$BUILD_DIR/busybox-$BUSYBOX_VERSION"
BUSYBOX_BIN="$BUSYBOX_DIR/busybox"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

download_busybox() {
  if [ -f "$BUSYBOX_ARCHIVE" ]; then
    return
  fi

  need_cmd wget
  echo "[INFO] Downloading BusyBox $BUSYBOX_VERSION..."
  wget -O "$BUSYBOX_ARCHIVE" \
    "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2"
}

extract_busybox() {
  if [ -d "$BUSYBOX_DIR" ]; then
    return
  fi

  echo "[INFO] Extracting BusyBox $BUSYBOX_VERSION..."
  tar -xf "$BUSYBOX_ARCHIVE" -C "$BUILD_DIR"
}

build_busybox() {
  if [ -x "$BUSYBOX_BIN" ] && ! ldd "$BUSYBOX_BIN" >/dev/null 2>&1; then
    return
  fi

  need_cmd make
  need_cmd gcc

  echo "[INFO] Building BusyBox $BUSYBOX_VERSION..."
  (
    cd "$BUSYBOX_DIR"
    make defconfig
    sed -i \
      -e 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' \
      -e 's/^CONFIG_TC=y/# CONFIG_TC is not set/' \
      -e 's/^CONFIG_FEATURE_TC_INGRESS=y/# CONFIG_FEATURE_TC_INGRESS is not set/' \
      -e 's/^CONFIG_WERROR=y/# CONFIG_WERROR is not set/' \
      .config
    make -j"$(nproc)"
  )
}

create_rootfs() {
  echo "[INFO] Creating single-user root filesystem..."
  rm -rf "$ROOTFS_DIR"
  mkdir -p \
    "$ROOTFS_DIR/bin" \
    "$ROOTFS_DIR/dev" \
    "$ROOTFS_DIR/proc" \
    "$ROOTFS_DIR/sys" \
    "$ROOTFS_DIR/etc" \
    "$ROOTFS_DIR/tmp" \
    "$ROOTFS_DIR/root"

  chmod 0755 "$ROOTFS_DIR" \
    "$ROOTFS_DIR/bin" \
    "$ROOTFS_DIR/dev" \
    "$ROOTFS_DIR/proc" \
    "$ROOTFS_DIR/sys" \
    "$ROOTFS_DIR/etc"
  chmod 1777 "$ROOTFS_DIR/tmp"
  chmod 0700 "$ROOTFS_DIR/root"

  cp "$BUSYBOX_BIN" "$ROOTFS_DIR/bin/busybox"
  "$BUSYBOX_BIN" --list | while read -r applet; do
    [ "$applet" = "busybox" ] && continue
    ln -sf busybox "$ROOTFS_DIR/bin/$applet"
  done

  cat > "$ROOTFS_DIR/etc/passwd" <<'EOF_PASSWD'
root:x:0:0:root:/root:/bin/sh
EOF_PASSWD

  cat > "$ROOTFS_DIR/etc/group" <<'EOF_GROUP'
root:x:0:
EOF_GROUP

  cat > "$ROOTFS_DIR/etc/shadow" <<'EOF_SHADOW'
root::0:0:99999:7:::
EOF_SHADOW
  chmod 0600 "$ROOTFS_DIR/etc/shadow"

  cat > "$ROOTFS_DIR/etc/profile" <<'EOF_PROFILE'
export USER="${USER:-root}"
export HOME="${HOME:-/root}"
export SHELL=/bin/sh
export PATH=/bin
export TERM="${TERM:-linux}"
export PS1='\u@\h:\w# '
EOF_PROFILE

  cat > "$ROOTFS_DIR/etc/fstab" <<'EOF_FSTAB'
proc  /proc  proc     defaults  0  0
sysfs /sys   sysfs    defaults  0  0
tmpfs /tmp   tmpfs    mode=1777  0  0
EOF_FSTAB

  echo "farewell-single" > "$ROOTFS_DIR/etc/hostname"

  cat > "$ROOTFS_DIR/init" <<'EOF_INIT'
#!/bin/sh
export PATH=/bin
export USER=root
export HOME=/root
export SHELL=/bin/sh
export TERM="${TERM:-linux}"

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs -o mode=1777 tmpfs /tmp 2>/dev/null || chmod 1777 /tmp

[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null || true
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3 2>/dev/null || true

clear 2>/dev/null || true
cat <<'EOF_BANNER'
 ███████████                                                       ████  ████ 
░░███░░░░░░█                                                      ░░███ ░░███ 
 ░███   █ ░   ██████   ████████   ██████  █████ ███ █████  ██████  ░███  ░███ 
 ░███████    ░░░░░███ ░░███░░███ ███░░███░░███ ░███░░███  ███░░███ ░███  ░███ 
 ░███░░░█     ███████  ░███ ░░░ ░███████  ░███ ░███ ░███ ░███████  ░███  ░███ 
 ░███  ░     ███░░███  ░███     ░███░░░   ░░███████████  ░███░░░   ░███  ░███ 
 █████      ░░████████ █████    ░░██████   ░░████░████   ░░██████  █████ █████
░░░░░        ░░░░░░░░ ░░░░░      ░░░░░░     ░░░░ ░░░░     ░░░░░░  ░░░░░ ░░░░░ 
                                                                              
                                                                              
                                                                              
 ███████████                       █████                                      
░░███░░░░░███                     ░░███                                       
 ░███    ░███  ██████   ████████  ███████   █████ ████                        
 ░██████████  ░░░░░███ ░░███░░███░░░███░   ░░███ ░███                         
 ░███░░░░░░    ███████  ░███ ░░░   ░███     ░███ ░███                         
 ░███         ███░░███  ░███       ░███ ███ ░███ ░███                         
 █████       ░░████████ █████      ░░█████  ░░███████                         
░░░░░         ░░░░░░░░ ░░░░░        ░░░░░    ░░░░░███                         
                                             ███ ░███                         
                                            ░░██████                          
                                             ░░░░░░                           
EOF_BANNER
echo
echo "Welcome, $USER."
echo

cd /root || cd /
if command -v setsid >/dev/null 2>&1 && command -v cttyhack >/dev/null 2>&1; then
  setsid cttyhack sh -l
else
  sh -l < /dev/console > /dev/console 2>&1
fi

echo
echo "Shell exited. Powering off..."
poweroff -f 2>/dev/null || reboot -f 2>/dev/null || true

while true; do
  sleep 3600
done
EOF_INIT
  chmod 0755 "$ROOTFS_DIR/init"

  mknod -m 600 "$ROOTFS_DIR/dev/console" c 5 1 2>/dev/null || true
  mknod -m 666 "$ROOTFS_DIR/dev/null" c 1 3 2>/dev/null || true
}

pack_rootfs() {
  need_cmd cpio
  need_cmd gzip

  echo "[INFO] Packing initramfs to $OUT_DIR/single.gz..."
  (
    cd "$ROOTFS_DIR"
    find . -print0 | cpio --null -ov --format=newc --owner=0:0 2>/dev/null | gzip -9
  ) > "$OUT_DIR/single.gz"
}

download_busybox
extract_busybox
build_busybox
create_rootfs
pack_rootfs

echo "[OK] Single-user filesystem built: $OUT_DIR/single.gz"
