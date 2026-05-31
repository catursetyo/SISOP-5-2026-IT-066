#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
OUT_DIR="$ROOT/osboot"
ROOTFS_DIR="$BUILD_DIR/multi-rootfs"
CPIO_LIST="$BUILD_DIR/multi-initramfs.list"
KERNEL_VERSION="6.1.1"
LINUX_DIR="$BUILD_DIR/linux-$KERNEL_VERSION"
GEN_INIT_CPIO="$LINUX_DIR/usr/gen_init_cpio"
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

ensure_gen_init_cpio() {
  if [ -x "$GEN_INIT_CPIO" ]; then
    return
  fi

  if [ ! -d "$LINUX_DIR" ]; then
    echo "[ERROR] Linux source not found at $LINUX_DIR. Run ./kernel.sh first." >&2
    exit 1
  fi

  echo "[INFO] Building kernel gen_init_cpio helper..."
  make -C "$LINUX_DIR" usr/gen_init_cpio
}

create_rootfs() {
  echo "[INFO] Creating multi-user root filesystem..."
  rm -rf "$ROOTFS_DIR"
  mkdir -p \
    "$ROOTFS_DIR/bin" \
    "$ROOTFS_DIR/etc" \
    "$ROOTFS_DIR/dev" \
    "$ROOTFS_DIR/proc" \
    "$ROOTFS_DIR/sys" \
    "$ROOTFS_DIR/tmp" \
    "$ROOTFS_DIR/root" \
    "$ROOTFS_DIR/home/henn" \
    "$ROOTFS_DIR/home/hann" \
    "$ROOTFS_DIR/home/viii" \
    "$ROOTFS_DIR/home/kids"

  cp "$BUSYBOX_BIN" "$ROOTFS_DIR/bin/busybox"

  cat > "$ROOTFS_DIR/etc/passwd" <<'EOF_PASSWD'
root:x:0:0:root:/root:/bin/sh
henn:x:1001:1001:henn:/home/henn:/bin/sh
hann:x:1002:1002:hann:/home/hann:/bin/sh
viii:x:1003:1003:viii:/home/viii:/bin/sh
kids:x:1004:1004:kids:/home/kids:/bin/sh
EOF_PASSWD

  cat > "$ROOTFS_DIR/etc/group" <<'EOF_GROUP'
root:x:0:
henn:x:1001:henn
hann:x:1002:hann
viii:x:1003:viii
kids:x:1004:kids
g_hann:x:2001:henn,hann
g_viii:x:2002:henn,hann,viii
g_kids:x:2003:henn,hann,viii,kids
EOF_GROUP

  cat > "$ROOTFS_DIR/etc/shadow" <<'EOF_SHADOW'
root:$6$root$88qIngTfAno2d53DALRGCPgvOqyPYEKKsooo4mcHM36NPjfux6SR20CB3ym0fGQmVL37ZHVTK5yHhrx3cknUB/:0:0:99999:7:::
henn:$6$henn$O79yxPQq0UDOwxqfGA7/RsW63BEX7q6A3VlSx7NXL6xSKoQO1bfr/Cjp2q2c/iiA6mHFSd5DMy0Fjc3weknNU1:0:0:99999:7:::
hann:$6$hann$lUcKBNujSuCBOrSI0MaQR6jIbUdVKOo/T8PthYYbba00j9VvQj.nMzwrZJf8QqMAmkwp2yeaaR5uOU6BsSti2/:0:0:99999:7:::
viii:$6$viii$cT87/D7JL4n3C3dv7yFjRnrAVw95vKh.XQvH9dLrUPkgDJiVNFhfnD6al0Ohp6vW2xY/idBVlXd2YqSs1T37l1:0:0:99999:7:::
kids:$6$kids$hGJN497lrfjJZZDHpzyzuMXvzoBkC1xvumXCam8HkipCLHxjs4HdPRpVsXSk14V4detoINx5j1hAP/w4HcukT/:0:0:99999:7:::
EOF_SHADOW

  cat > "$ROOTFS_DIR/etc/securetty" <<'EOF_SECURETTY'
console
ttyS0
tty1
EOF_SECURETTY

  cat > "$ROOTFS_DIR/etc/fstab" <<'EOF_FSTAB'
proc    /proc  proc     defaults  0  0
sysfs   /sys   sysfs    defaults  0  0
devpts  /dev/pts devpts defaults  0  0
tmpfs   /tmp   tmpfs    mode=1777  0  0
EOF_FSTAB

  echo "farewell-multi" > "$ROOTFS_DIR/etc/hostname"
  echo "nameserver 10.0.2.3" > "$ROOTFS_DIR/etc/resolv.conf"

  cat > "$ROOTFS_DIR/etc/profile" <<'EOF_PROFILE'
export PATH=/bin
export SHELL=/bin/sh
export TERM="${TERM:-linux}"
USER="$(id -un 2>/dev/null || whoami 2>/dev/null || echo user)"
export USER
export HOME="${HOME:-/}"
export PS1='\u@\h:\w\$ '

logout() {
  exit 77
}

if [ -z "${FAREWELL_BANNER_SHOWN:-}" ]; then
  export FAREWELL_BANNER_SHOWN=1
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
fi

cd "$HOME" 2>/dev/null || cd /
EOF_PROFILE

  cat > "$ROOTFS_DIR/bin/login_prompt" <<'EOF_LOGIN_PROMPT'
#!/bin/sh
while true; do
  printf "User: "
  IFS= read -r user || exit 0
  [ -n "$user" ] || continue
  export LOGIN_TIMEOUT=0
  exec login "$user"
done
EOF_LOGIN_PROMPT

  cat > "$ROOTFS_DIR/etc/udhcpc.script" <<'EOF_UDHCPC'
#!/bin/sh
case "$1" in
  deconfig)
    ifconfig "$interface" 0.0.0.0 2>/dev/null || true
    ;;
  bound|renew)
    ifconfig "$interface" "$ip" netmask "$subnet"
    if [ -n "$router" ]; then
      route del default 2>/dev/null || true
      route add default gw "$router"
    fi
    : > /etc/resolv.conf
    for ns in $dns; do
      echo "nameserver $ns" >> /etc/resolv.conf
    done
    ;;
esac
EOF_UDHCPC

  cat > "$ROOTFS_DIR/init" <<'EOF_INIT'
#!/bin/sh
export PATH=/bin
export TERM="${TERM:-linux}"

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs -o mode=1777 tmpfs /tmp 2>/dev/null || chmod 1777 /tmp

[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1 2>/dev/null || true
[ -c /dev/null ] || mknod -m 666 /dev/null c 1 3 2>/dev/null || true
[ -c /dev/ttyS0 ] || mknod -m 660 /dev/ttyS0 c 4 64 2>/dev/null || true
[ -c /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229 2>/dev/null || true

hostname -F /etc/hostname 2>/dev/null || hostname farewell-multi
ifconfig lo up 2>/dev/null || true
ifconfig eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -s /etc/udhcpc.script >/dev/null 2>&1 || true

while true; do
  setsid cttyhack /bin/login_prompt < /dev/ttyS0 > /dev/ttyS0 2>&1
  status=$?
  if [ "$status" -eq 77 ]; then
    continue
  fi
  if [ "$status" -eq 0 ]; then
    echo
    echo "Session exited. Powering off..."
    poweroff -f 2>/dev/null || reboot -f 2>/dev/null || true
    while true; do
      sleep 3600
    done
  fi
  sleep 1
done
EOF_INIT
}

write_cpio_list() {
  echo "[INFO] Writing initramfs manifest..."
  {
    echo "dir / 0755 0 0"
    echo "dir /bin 0755 0 0"
    echo "file /bin/busybox $ROOTFS_DIR/bin/busybox 0755 0 0"
    echo "file /bin/login_prompt $ROOTFS_DIR/bin/login_prompt 0755 0 0"
    "$BUSYBOX_BIN" --list | while read -r applet; do
      [ "$applet" = "busybox" ] && continue
      echo "slink /bin/$applet busybox 0777 0 0"
    done

    echo "dir /dev 0755 0 0"
    echo "nod /dev/console 0600 0 0 c 5 1"
    echo "nod /dev/null 0666 0 0 c 1 3"
    echo "nod /dev/ttyS0 0660 0 0 c 4 64"
    echo "nod /dev/fuse 0666 0 0 c 10 229"
    echo "dir /proc 0755 0 0"
    echo "dir /sys 0755 0 0"
    echo "dir /etc 0755 0 0"
    echo "dir /tmp 1777 0 0"
    echo "dir /root 0700 0 0"
    echo "dir /home 0755 0 0"
    echo "dir /home/henn 0700 1001 1001"
    echo "dir /home/hann 0770 1002 2001"
    echo "dir /home/viii 0770 1003 2002"
    echo "dir /home/kids 0770 1004 2003"

    echo "file /etc/passwd $ROOTFS_DIR/etc/passwd 0644 0 0"
    echo "file /etc/group $ROOTFS_DIR/etc/group 0644 0 0"
    echo "file /etc/shadow $ROOTFS_DIR/etc/shadow 0600 0 0"
    echo "file /etc/securetty $ROOTFS_DIR/etc/securetty 0600 0 0"
    echo "file /etc/fstab $ROOTFS_DIR/etc/fstab 0644 0 0"
    echo "file /etc/hostname $ROOTFS_DIR/etc/hostname 0644 0 0"
    echo "file /etc/resolv.conf $ROOTFS_DIR/etc/resolv.conf 0644 0 0"
    echo "file /etc/profile $ROOTFS_DIR/etc/profile 0644 0 0"
    echo "file /etc/udhcpc.script $ROOTFS_DIR/etc/udhcpc.script 0755 0 0"
    echo "file /init $ROOTFS_DIR/init 0755 0 0"
  } > "$CPIO_LIST"
}

pack_rootfs() {
  need_cmd gzip

  echo "[INFO] Packing initramfs to $OUT_DIR/multi.gz..."
  "$GEN_INIT_CPIO" "$CPIO_LIST" | gzip -9 > "$OUT_DIR/multi.gz"
}

download_busybox
extract_busybox
build_busybox
ensure_gen_init_cpio
create_rootfs
write_cpio_list
pack_rootfs

echo "[OK] Multi-user filesystem built: $OUT_DIR/multi.gz"
