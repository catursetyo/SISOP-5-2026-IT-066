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
BUSYBOX_SHA256="b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314"
BUSYBOX_DIR="$BUILD_DIR/busybox-$BUSYBOX_VERSION"
BUSYBOX_BIN="$BUSYBOX_DIR/busybox"
BUSYBOX_STAMP="$BUSYBOX_DIR/.farewell-repro-v1"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"

case "$SOURCE_DATE_EPOCH" in
  ''|*[!0-9]*)
    echo "[ERROR] SOURCE_DATE_EPOCH must be an integer Unix timestamp" >&2
    exit 1
    ;;
esac

export SOURCE_DATE_EPOCH
export KCONFIG_NOTIMESTAMP=1
export LC_ALL=C
export TZ=UTC
umask 022

mkdir -p "$BUILD_DIR" "$OUT_DIR"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

download_busybox() {
  need_cmd sha256sum

  if [ -f "$BUSYBOX_ARCHIVE" ]; then
    echo "$BUSYBOX_SHA256  $BUSYBOX_ARCHIVE" | sha256sum -c -
    return
  fi

  need_cmd wget
  echo "[INFO] Downloading BusyBox $BUSYBOX_VERSION..."
  wget -O "$BUSYBOX_ARCHIVE" \
    "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2"
  echo "$BUSYBOX_SHA256  $BUSYBOX_ARCHIVE" | sha256sum -c -
}

extract_busybox() {
  if [ -d "$BUSYBOX_DIR" ]; then
    return
  fi

  echo "[INFO] Extracting BusyBox $BUSYBOX_VERSION..."
  tar -xf "$BUSYBOX_ARCHIVE" -C "$BUILD_DIR"
}

build_busybox() {
  if [ -x "$BUSYBOX_BIN" ] && [ -f "$BUSYBOX_STAMP" ] && ! ldd "$BUSYBOX_BIN" >/dev/null 2>&1; then
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
    rm -f busybox
    make -j"$(nproc)"
    touch -d "@$SOURCE_DATE_EPOCH" busybox .config
    : > "$BUSYBOX_STAMP"
    touch -d "@$SOURCE_DATE_EPOCH" "$BUSYBOX_STAMP"
  )
}

tar_repro() {
  local archive="$1"
  local source_dir="$2"

  tar \
    --sort=name \
    --owner=0 \
    --group=0 \
    --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" \
    --clamp-mtime \
    -cf "$archive" \
    -C "$source_dir" .
}

normalize_rootfs_mtime() {
  find "$ROOTFS_DIR" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
}

write_fuse_hello_source() {
  "$ROOT/single.sh" --emit-fuse-source "$1"
}

build_fuse_demo() {
  local out="$1"
  local source="$BUILD_DIR/fuse_hello.c"
  local cc_bin="${CC:-gcc}"
  local common_flags=(
    -O2
    -Wall
    -Wextra
    -Wdate-time
    -Werror=date-time
    -fno-ident
    "-ffile-prefix-map=$ROOT=."
    "-fdebug-prefix-map=$ROOT=."
    "-DFUSE_HELLO_EPOCH=$SOURCE_DATE_EPOCH"
  )
  local ld_flags=(-Wl,--build-id=none)

  write_fuse_hello_source "$source"
  need_cmd "$cc_bin"
  if ! "$cc_bin" -static "${common_flags[@]}" "${ld_flags[@]}" -o "$out" "$source"; then
    echo "[WARN] Static fuse_hello build failed; falling back to dynamic binary." >&2
    "$cc_bin" "${common_flags[@]}" "${ld_flags[@]}" -o "$out" "$source"
  fi

  strip -s -R .comment -R .note.gnu.build-id "$out" 2>/dev/null || strip -s "$out" 2>/dev/null || true
  touch -d "@$SOURCE_DATE_EPOCH" "$out"
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
    "$ROOTFS_DIR/var/lib/party/repo" \
    "$ROOTFS_DIR/var/lib/party/installed" \
    "$ROOTFS_DIR/home/henn" \
    "$ROOTFS_DIR/home/hann" \
    "$ROOTFS_DIR/home/viii" \
    "$ROOTFS_DIR/home/kids"

  cp "$BUSYBOX_BIN" "$ROOTFS_DIR/bin/busybox"

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
  tar_repro "$ROOTFS_DIR/var/lib/party/repo/hello.tar" "$PARTY_PKG_DIR"

  PARTY_FASTFETCH_DIR="$BUILD_DIR/party-fastfetch"
  rm -rf "$PARTY_FASTFETCH_DIR"
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
  tar_repro "$ROOTFS_DIR/var/lib/party/repo/fastfetch.tar" "$PARTY_FASTFETCH_DIR"

  PARTY_FUSE_DIR="$BUILD_DIR/party-fuse"
  FUSE_DEMO_BIN="$BUILD_DIR/fuse_hello"
  rm -rf "$PARTY_FUSE_DIR"
  mkdir -p "$PARTY_FUSE_DIR/bin"
  build_fuse_demo "$FUSE_DEMO_BIN"
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
  tar_repro "$ROOTFS_DIR/var/lib/party/repo/fuse.tar" "$PARTY_FUSE_DIR"

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
  cat > "$ROOTFS_DIR/etc/os-release" <<'EOF_OS_RELEASE'
NAME="Farewell Party OS"
ID=farewell
PRETTY_NAME="Farewell Party OS"
VERSION_ID="1"
EOF_OS_RELEASE
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
    echo "file /bin/party $ROOTFS_DIR/bin/party 0755 0 0"
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
    echo "dir /var 0755 0 0"
    echo "dir /var/lib 0755 0 0"
    echo "dir /var/lib/party 0755 0 0"
    echo "dir /var/lib/party/repo 0755 0 0"
    echo "dir /var/lib/party/installed 0755 0 0"
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
    echo "file /etc/os-release $ROOTFS_DIR/etc/os-release 0644 0 0"
    echo "file /etc/resolv.conf $ROOTFS_DIR/etc/resolv.conf 0644 0 0"
    echo "file /etc/profile $ROOTFS_DIR/etc/profile 0644 0 0"
    echo "file /etc/udhcpc.script $ROOTFS_DIR/etc/udhcpc.script 0755 0 0"
    echo "file /var/lib/party/repo/hello.tar $ROOTFS_DIR/var/lib/party/repo/hello.tar 0644 0 0"
    echo "file /var/lib/party/repo/fastfetch.tar $ROOTFS_DIR/var/lib/party/repo/fastfetch.tar 0644 0 0"
    echo "file /var/lib/party/repo/fuse.tar $ROOTFS_DIR/var/lib/party/repo/fuse.tar 0644 0 0"
    echo "file /init $ROOTFS_DIR/init 0755 0 0"
  } > "$CPIO_LIST"
}

pack_rootfs() {
  need_cmd gzip

  echo "[INFO] Packing initramfs to $OUT_DIR/multi.gz..."
  normalize_rootfs_mtime
  "$GEN_INIT_CPIO" -t "$SOURCE_DATE_EPOCH" "$CPIO_LIST" | gzip -n -9 > "$OUT_DIR/multi.gz"
  touch -d "@$SOURCE_DATE_EPOCH" "$OUT_DIR/multi.gz"
}

download_busybox
extract_busybox
build_busybox
ensure_gen_init_cpio
create_rootfs
write_cpio_list
pack_rootfs

echo "[OK] Multi-user filesystem built: $OUT_DIR/multi.gz"
