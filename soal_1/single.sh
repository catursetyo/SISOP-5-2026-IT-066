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
    "$ROOTFS_DIR/root" \
    "$ROOTFS_DIR/var/lib/party/repo" \
    "$ROOTFS_DIR/var/lib/party/installed"

  chmod 0755 "$ROOTFS_DIR" \
    "$ROOTFS_DIR/bin" \
    "$ROOTFS_DIR/dev" \
    "$ROOTFS_DIR/proc" \
    "$ROOTFS_DIR/sys" \
    "$ROOTFS_DIR/etc" \
    "$ROOTFS_DIR/var" \
    "$ROOTFS_DIR/var/lib" \
    "$ROOTFS_DIR/var/lib/party" \
    "$ROOTFS_DIR/var/lib/party/repo" \
    "$ROOTFS_DIR/var/lib/party/installed"
  chmod 1777 "$ROOTFS_DIR/tmp"
  chmod 0700 "$ROOTFS_DIR/root"

  cp "$BUSYBOX_BIN" "$ROOTFS_DIR/bin/busybox"
  "$BUSYBOX_BIN" --list | while read -r applet; do
    [ "$applet" = "busybox" ] && continue
    ln -sf busybox "$ROOTFS_DIR/bin/$applet"
  done

  cat > "$ROOTFS_DIR/bin/party" <<'EOF_PARTY'
#!/bin/sh
DB_DIR=/var/lib/party
REPO="${PARTY_REPO:-file:///var/lib/party/repo}"

usage() {
  cat <<EOF_USAGE
party package manager

usage:
  party list
  party installed
  party install <package>
  party remove <package>

Set PARTY_REPO to file://, http://, or https:// repository path.
HTTPS downloads use wget --no-check-certificate.
EOF_USAGE
}

repo_path_for() {
  pkg="$1"
  case "$REPO" in
    file://*) printf '%s/%s.tar\n' "${REPO#file://}" "$pkg" ;;
    http://*|https://*) printf '%s/%s.tar\n' "${REPO%/}" "$pkg" ;;
    *) printf '%s/%s.tar\n' "${REPO%/}" "$pkg" ;;
  esac
}

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "party: install/remove requires root" >&2
    exit 1
  fi
}

fetch_package() {
  pkg="$1"
  out="$2"
  src="$(repo_path_for "$pkg")"

  case "$REPO" in
    http://*|https://*) wget --no-check-certificate -O "$out" "$src" ;;
    *) cp "$src" "$out" ;;
  esac
}

list_available() {
  case "$REPO" in
    http://*|https://*)
      echo "party: remote listing is not available; install by package name"
      ;;
    file://*) repo_dir="${REPO#file://}" ;;
    *) repo_dir="$REPO" ;;
  esac

  [ -n "${repo_dir:-}" ] || return 0
  found=0
  for pkg in "$repo_dir"/*.tar; do
    [ -e "$pkg" ] || continue
    basename "$pkg" .tar
    found=1
  done
  [ "$found" -eq 1 ] || echo "party: no packages available"
}

list_installed() {
  found=0
  for pkg in "$DB_DIR"/installed/*.list; do
    [ -e "$pkg" ] || continue
    basename "$pkg" .list
    found=1
  done
  [ "$found" -eq 1 ] || echo "party: no packages installed"
}

install_package() {
  need_root
  pkg="${1:-}"
  if [ -z "$pkg" ]; then
    usage
    exit 1
  fi

  mkdir -p "$DB_DIR/installed"
  if [ -f "$DB_DIR/installed/$pkg.list" ]; then
    echo "party: $pkg is already installed"
    return 0
  fi

  archive="/tmp/party-$pkg-$$.tar"
  list="/tmp/party-$pkg-$$.list"

  if ! fetch_package "$pkg" "$archive"; then
    rm -f "$archive" "$list"
    echo "party: package not found: $pkg" >&2
    exit 1
  fi

  if ! tar -tf "$archive" >/dev/null 2>&1; then
    rm -f "$archive" "$list"
    echo "party: invalid package archive: $pkg" >&2
    exit 1
  fi

  tar -tf "$archive" | sed 's#^\./##' | grep -v '^$' | grep -v '/$' > "$list"
  if ! tar -xf "$archive" -C /; then
    rm -f "$archive" "$list"
    echo "party: failed to install: $pkg" >&2
    exit 1
  fi

  cp "$list" "$DB_DIR/installed/$pkg.list"
  rm -f "$archive" "$list"
  echo "[OK] installed $pkg"
}

remove_package() {
  need_root
  pkg="${1:-}"
  if [ -z "$pkg" ]; then
    usage
    exit 1
  fi

  list="$DB_DIR/installed/$pkg.list"
  if [ ! -f "$list" ]; then
    echo "party: $pkg is not installed" >&2
    exit 1
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rm -f "/$path"
  done < "$list"

  rm -f "$list"
  echo "[OK] removed $pkg"
}

case "${1:-}" in
  list) list_available ;;
  installed) list_installed ;;
  install) shift; install_package "${1:-}" ;;
  remove) shift; remove_package "${1:-}" ;;
  -h|--help|help|"") usage ;;
  *)
    echo "party: unknown command: $1" >&2
    usage
    exit 1
    ;;
esac
EOF_PARTY
  chmod 0755 "$ROOTFS_DIR/bin/party"

  need_cmd tar
  PARTY_PKG_DIR="$BUILD_DIR/party-hello"
  rm -rf "$PARTY_PKG_DIR"
  mkdir -p "$PARTY_PKG_DIR/bin"
  cat > "$PARTY_PKG_DIR/bin/hello" <<'EOF_HELLO'
#!/bin/sh
echo "Hello from a package installed by party."
EOF_HELLO
  chmod 0755 "$PARTY_PKG_DIR/bin/hello"
  tar --owner=0 --group=0 --numeric-owner -cf \
    "$ROOTFS_DIR/var/lib/party/repo/hello.tar" \
    -C "$PARTY_PKG_DIR" .

  PARTY_FASTFETCH_DIR="$BUILD_DIR/party-fastfetch"
  rm -rf "$PARTY_FASTFETCH_DIR"
  FASTFETCH_BIN="$(command -v fastfetch || true)"
  if [ -n "$FASTFETCH_BIN" ] && [ -x "$FASTFETCH_BIN" ] && command -v ldd >/dev/null 2>&1; then
    mkdir -p "$PARTY_FASTFETCH_DIR/bin"
    cp "$FASTFETCH_BIN" "$PARTY_FASTFETCH_DIR/bin/fastfetch"
    ldd "$FASTFETCH_BIN" | while IFS= read -r dep; do
      lib=""
      set -- $dep
      if [ "${2:-}" = "=>" ] && [ -n "${3:-}" ]; then
        lib="$3"
      elif [ -n "${1:-}" ]; then
        lib="$1"
      fi
      case "$lib" in
        /*) ;;
        *) continue ;;
      esac
      [ -n "$lib" ] || continue
      [ -f "$lib" ] || continue
      mkdir -p "$PARTY_FASTFETCH_DIR$(dirname "$lib")"
      cp -L "$lib" "$PARTY_FASTFETCH_DIR$lib"
    done
  else
    mkdir -p "$PARTY_FASTFETCH_DIR/bin"
    cat > "$PARTY_FASTFETCH_DIR/bin/fastfetch" <<'EOF_FASTFETCH'
#!/bin/sh
host="$(hostname 2>/dev/null || echo unknown)"
kernel="$(uname -sr 2>/dev/null || echo unknown)"
arch="$(uname -m 2>/dev/null || echo unknown)"
uptime_s="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
mem_total="$(awk '/MemTotal/ {print int($2/1024) " MiB"}' /proc/meminfo 2>/dev/null || echo unknown)"
mem_free="$(awk '/MemAvailable/ {print int($2/1024) " MiB"}' /proc/meminfo 2>/dev/null || echo unknown)"
user="$(whoami 2>/dev/null || id -un 2>/dev/null || echo user)"
root_use="$(df -h / 2>/dev/null | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"

cat <<EOF_INFO
    ______                    ____             __
   / ____/___  ________     / __ \____ ______/ /___  __
  / /_  / __ \/ ___/ _ \   / /_/ / __ \`/ ___/ __/ / / /
 / __/ / /_/ / /  /  __/  / ____/ /_/ / /  / /_/ /_/ /
/_/    \____/_/   \___/  /_/    \__,_/_/   \__/\__, /
                                               /____/
User:         $user@$host
OS:           Farewell Party OS
Kernel:       $kernel
Architecture: $arch
Shell:        ${SHELL:-/bin/sh}
Uptime:       ${uptime_s}s
Memory:       $mem_free available / $mem_total total
Root FS:      ${root_use:-unknown}
EOF_INFO
EOF_FASTFETCH
    chmod 0755 "$PARTY_FASTFETCH_DIR/bin/fastfetch"
  fi
  tar --owner=0 --group=0 --numeric-owner -cf \
    "$ROOTFS_DIR/var/lib/party/repo/fastfetch.tar" \
    -C "$PARTY_FASTFETCH_DIR" .

  PARTY_FUSE_DIR="$BUILD_DIR/party-fuse"
  FUSE_DEMO_BIN="$BUILD_DIR/fuse_hello"
  rm -rf "$PARTY_FUSE_DIR"
  mkdir -p "$PARTY_FUSE_DIR/bin"
  if [ ! -x "$FUSE_DEMO_BIN" ] || [ "$ROOT/fuse_hello.c" -nt "$FUSE_DEMO_BIN" ]; then
    need_cmd gcc
    if ! gcc -static -O2 -Wall -Wextra -o "$FUSE_DEMO_BIN" "$ROOT/fuse_hello.c"; then
      gcc -O2 -Wall -Wextra -o "$FUSE_DEMO_BIN" "$ROOT/fuse_hello.c"
    fi
  fi
  strip -s "$FUSE_DEMO_BIN" 2>/dev/null || true
  cp "$FUSE_DEMO_BIN" "$PARTY_FUSE_DIR/bin/fuse_hello"
  if ldd "$FUSE_DEMO_BIN" > "$BUILD_DIR/fuse_hello.ldd" 2>/dev/null; then
    while IFS= read -r dep; do
      lib=""
      set -- $dep
      if [ "${2:-}" = "=>" ] && [ -n "${3:-}" ]; then
        lib="$3"
      elif [ -n "${1:-}" ]; then
        lib="$1"
      fi
      case "$lib" in
        /*) ;;
        *) continue ;;
      esac
      [ -n "$lib" ] || continue
      [ -f "$lib" ] || continue
      mkdir -p "$PARTY_FUSE_DIR$(dirname "$lib")"
      cp -L "$lib" "$PARTY_FUSE_DIR$lib"
    done < "$BUILD_DIR/fuse_hello.ldd"
  fi
  cat > "$PARTY_FUSE_DIR/bin/fuse-test" <<'EOF_FUSE_TEST'
#!/bin/sh
exec /bin/fuse_hello --test "${1:-/tmp/fuse-demo}"
EOF_FUSE_TEST
  chmod 0755 "$PARTY_FUSE_DIR/bin/fuse_hello" "$PARTY_FUSE_DIR/bin/fuse-test"
  tar --owner=0 --group=0 --numeric-owner -cf \
    "$ROOTFS_DIR/var/lib/party/repo/fuse.tar" \
    -C "$PARTY_FUSE_DIR" .

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
  cat > "$ROOTFS_DIR/etc/os-release" <<'EOF_OS_RELEASE'
NAME="Farewell Party OS"
ID=farewell
PRETTY_NAME="Farewell Party OS"
VERSION_ID="1"
EOF_OS_RELEASE
  echo "nameserver 10.0.2.3" > "$ROOTFS_DIR/etc/resolv.conf"

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

hostname -F /etc/hostname 2>/dev/null || hostname farewell-single
ifconfig lo up 2>/dev/null || true
ifconfig eth0 up 2>/dev/null || true
udhcpc -i eth0 -q -n -s /etc/udhcpc.script >/dev/null 2>&1 || true

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
  chmod 0755 "$ROOTFS_DIR/etc/udhcpc.script"

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
