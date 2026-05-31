#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$ROOT/build"
OUT_DIR="$ROOT/osboot"
ROOTFS_DIR="$BUILD_DIR/single-rootfs"
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
  local out="$1"

  cat > "$out" <<'EOF_FUSE_HELLO_C'
#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fuse.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef FUSE_ROOT_ID
#define FUSE_ROOT_ID 1
#endif

#ifndef FUSE_HELLO_EPOCH
#define FUSE_HELLO_EPOCH 1704067200ULL
#endif

#define HELLO_INO 2
#define FUSE_BUF_SIZE 131072

static const char hello_name[] = "hello.txt";
static const char hello_text[] =
    "Hello from a real FUSE filesystem inside Farewell Party OS.\n";

static void fill_attr(uint64_t nodeid, struct fuse_attr *attr) {
  memset(attr, 0, sizeof(*attr));
  attr->ino = nodeid;
  attr->uid = 0;
  attr->gid = 0;
  attr->blksize = 512;
  attr->atime = attr->mtime = attr->ctime = FUSE_HELLO_EPOCH;

  if (nodeid == FUSE_ROOT_ID) {
    attr->mode = S_IFDIR | 0555;
    attr->nlink = 2;
  } else {
    attr->mode = S_IFREG | 0444;
    attr->nlink = 1;
    attr->size = sizeof(hello_text) - 1;
    attr->blocks = (attr->size + 511) / 512;
  }
}

static int write_all(int fd, const void *buf, size_t len) {
  const char *p = buf;
  while (len > 0) {
    ssize_t n = write(fd, p, len);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

static int reply_raw(int fd, uint64_t unique, int error, const void *payload,
                     size_t payload_len) {
  char out[FUSE_BUF_SIZE];
  struct fuse_out_header *hdr = (struct fuse_out_header *)out;

  if (sizeof(*hdr) + payload_len > sizeof(out)) {
    errno = EOVERFLOW;
    return -1;
  }

  memset(out, 0, sizeof(*hdr) + payload_len);
  hdr->len = (uint32_t)(sizeof(*hdr) + payload_len);
  hdr->error = error ? -error : 0;
  hdr->unique = unique;

  if (payload_len > 0 && payload != NULL) {
    memcpy(out + sizeof(*hdr), payload, payload_len);
  }

  return write_all(fd, out, hdr->len);
}

static int reply_ok(int fd, uint64_t unique) {
  return reply_raw(fd, unique, 0, NULL, 0);
}

static int reply_err(int fd, uint64_t unique, int error) {
  return reply_raw(fd, unique, error, NULL, 0);
}

static int add_dirent(char *buf, size_t limit, size_t *pos, const char *name,
                      uint64_t ino, uint32_t type, uint64_t next_off) {
  size_t namelen = strlen(name);
  size_t reclen = FUSE_DIRENT_ALIGN(FUSE_NAME_OFFSET + namelen);
  struct fuse_dirent *de;

  if (*pos + reclen > limit) {
    return 0;
  }

  de = (struct fuse_dirent *)(buf + *pos);
  memset(de, 0, reclen);
  de->ino = ino;
  de->off = next_off;
  de->namelen = (uint32_t)namelen;
  de->type = type;
  memcpy(de->name, name, namelen);
  *pos += reclen;
  return 1;
}

static void handle_init(int fd, const struct fuse_in_header *in,
                        const void *payload) {
  const struct fuse_init_in *init_in = payload;
  struct fuse_init_out out;

  memset(&out, 0, sizeof(out));
  out.major = FUSE_KERNEL_VERSION;
  out.minor = init_in->minor < 31 ? init_in->minor : 31;
  out.max_readahead = init_in->max_readahead;
  out.max_background = 16;
  out.congestion_threshold = 8;
  out.max_write = 65536;
  out.time_gran = 1;

  reply_raw(fd, in->unique, 0, &out, sizeof(out));
}

static void handle_lookup(int fd, const struct fuse_in_header *in,
                          const char *name) {
  struct fuse_entry_out out;

  if (in->nodeid != FUSE_ROOT_ID || strcmp(name, hello_name) != 0) {
    reply_err(fd, in->unique, ENOENT);
    return;
  }

  memset(&out, 0, sizeof(out));
  out.nodeid = HELLO_INO;
  out.generation = 1;
  out.entry_valid = 1;
  out.attr_valid = 1;
  fill_attr(HELLO_INO, &out.attr);
  reply_raw(fd, in->unique, 0, &out, sizeof(out));
}

static void handle_getattr(int fd, const struct fuse_in_header *in) {
  struct fuse_attr_out out;

  if (in->nodeid != FUSE_ROOT_ID && in->nodeid != HELLO_INO) {
    reply_err(fd, in->unique, ENOENT);
    return;
  }

  memset(&out, 0, sizeof(out));
  out.attr_valid = 1;
  fill_attr(in->nodeid, &out.attr);
  reply_raw(fd, in->unique, 0, &out, sizeof(out));
}

static void handle_open(int fd, const struct fuse_in_header *in, uint64_t fh) {
  struct fuse_open_out out;

  memset(&out, 0, sizeof(out));
  out.fh = fh;
  reply_raw(fd, in->unique, 0, &out, sizeof(out));
}

static void handle_read(int fd, const struct fuse_in_header *in,
                        const struct fuse_read_in *read_in) {
  size_t text_len = sizeof(hello_text) - 1;
  size_t offset = (size_t)read_in->offset;
  size_t size = read_in->size;

  if (in->nodeid != HELLO_INO) {
    reply_err(fd, in->unique, EISDIR);
    return;
  }

  if (offset >= text_len) {
    reply_raw(fd, in->unique, 0, "", 0);
    return;
  }

  if (size > text_len - offset) {
    size = text_len - offset;
  }

  reply_raw(fd, in->unique, 0, hello_text + offset, size);
}

static void handle_readdir(int fd, const struct fuse_in_header *in,
                           const struct fuse_read_in *read_in) {
  char entries[1024];
  size_t pos = 0;
  size_t limit = read_in->size < sizeof(entries) ? read_in->size : sizeof(entries);
  uint64_t off = read_in->offset;

  if (in->nodeid != FUSE_ROOT_ID) {
    reply_err(fd, in->unique, ENOTDIR);
    return;
  }

  if (off < 1) {
    add_dirent(entries, limit, &pos, ".", FUSE_ROOT_ID, DT_DIR, 1);
  }
  if (off < 2) {
    add_dirent(entries, limit, &pos, "..", FUSE_ROOT_ID, DT_DIR, 2);
  }
  if (off < 3) {
    add_dirent(entries, limit, &pos, hello_name, HELLO_INO, DT_REG, 3);
  }

  reply_raw(fd, in->unique, 0, entries, pos);
}

static void handle_statfs(int fd, const struct fuse_in_header *in) {
  struct fuse_statfs_out out;
  (void)in;

  memset(&out, 0, sizeof(out));
  out.st.blocks = 1;
  out.st.files = 2;
  out.st.bsize = 512;
  out.st.namelen = 255;
  out.st.frsize = 512;
  reply_raw(fd, in->unique, 0, &out, sizeof(out));
}

static int mount_fuse(const char *mountpoint) {
  int fd;
  char opts[256];

  mkdir(mountpoint, 0755);

  fd = open("/dev/fuse", O_RDWR | O_CLOEXEC);
  if (fd < 0) {
    perror("open /dev/fuse");
    return -1;
  }

  snprintf(opts, sizeof(opts), "fd=%d,rootmode=40000,user_id=0,group_id=0", fd);
  if (mount("fuse_hello", mountpoint, "fuse", MS_NOSUID | MS_NODEV, opts) < 0) {
    perror("mount fuse");
    close(fd);
    return -1;
  }

  return fd;
}

static int serve_loop(int fd) {
  char buf[FUSE_BUF_SIZE];

  for (;;) {
    ssize_t n = read(fd, buf, sizeof(buf));
    struct fuse_in_header *in = (struct fuse_in_header *)buf;
    void *payload = buf + sizeof(*in);

    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == ENODEV || errno == EIO) {
        return 0;
      }
      perror("read /dev/fuse");
      return 1;
    }

    if ((size_t)n < sizeof(*in)) {
      continue;
    }

    switch (in->opcode) {
    case FUSE_INIT:
      handle_init(fd, in, payload);
      break;
    case FUSE_LOOKUP:
      handle_lookup(fd, in, (const char *)payload);
      break;
    case FUSE_GETATTR:
      handle_getattr(fd, in);
      break;
    case FUSE_OPENDIR:
      handle_open(fd, in, 1);
      break;
    case FUSE_READDIR:
      handle_readdir(fd, in, (const struct fuse_read_in *)payload);
      break;
    case FUSE_OPEN:
      if (in->nodeid == HELLO_INO) {
        handle_open(fd, in, 2);
      } else {
        reply_err(fd, in->unique, EISDIR);
      }
      break;
    case FUSE_READ:
      handle_read(fd, in, (const struct fuse_read_in *)payload);
      break;
    case FUSE_STATFS:
      handle_statfs(fd, in);
      break;
    case FUSE_ACCESS:
    case FUSE_FLUSH:
    case FUSE_RELEASE:
    case FUSE_RELEASEDIR:
      reply_ok(fd, in->unique);
      break;
    case FUSE_FORGET:
      break;
    case FUSE_DESTROY:
      reply_ok(fd, in->unique);
      return 0;
    default:
      reply_err(fd, in->unique, ENOSYS);
      break;
    }
  }
}

static int run_server(const char *mountpoint) {
  int fd = mount_fuse(mountpoint);
  int rc;

  if (fd < 0) {
    return 1;
  }

  printf("[OK] FUSE filesystem mounted at %s\n", mountpoint);
  fflush(stdout);
  rc = serve_loop(fd);
  umount2(mountpoint, MNT_DETACH);
  close(fd);
  return rc;
}

static int read_hello(const char *mountpoint, char *buf, size_t buf_size) {
  char path[512];
  int fd;
  ssize_t n;

  snprintf(path, sizeof(path), "%s/%s", mountpoint, hello_name);
  fd = open(path, O_RDONLY);
  if (fd < 0) {
    return -1;
  }

  n = read(fd, buf, buf_size - 1);
  close(fd);
  if (n < 0) {
    return -1;
  }
  buf[n] = '\0';
  return 0;
}

static int has_hello_dirent(const char *mountpoint) {
  DIR *dir = opendir(mountpoint);
  struct dirent *de;
  int found = 0;

  if (dir == NULL) {
    return 0;
  }

  while ((de = readdir(dir)) != NULL) {
    if (strcmp(de->d_name, hello_name) == 0) {
      found = 1;
      break;
    }
  }

  closedir(dir);
  return found;
}

static int run_test(const char *mountpoint) {
  pid_t child;
  char text[256];
  int status = 0;
  int ok = 0;

  child = fork();
  if (child < 0) {
    perror("fork");
    return 1;
  }

  if (child == 0) {
    _exit(run_server(mountpoint));
  }

  for (int i = 0; i < 50; i++) {
    if (read_hello(mountpoint, text, sizeof(text)) == 0) {
      ok = 1;
      break;
    }
    usleep(100000);
  }

  if (!ok) {
    fprintf(stderr, "[ERROR] Could not read %s/%s\n", mountpoint, hello_name);
    kill(child, SIGTERM);
    waitpid(child, &status, 0);
    return 1;
  }

  if (has_hello_dirent(mountpoint)) {
    printf("[OK] readdir found %s\n", hello_name);
  } else {
    fprintf(stderr, "[ERROR] readdir did not find %s\n", hello_name);
    ok = 0;
  }

  printf("[OK] read %s/%s: %s", mountpoint, hello_name, text);
  umount2(mountpoint, MNT_DETACH);
  waitpid(child, &status, 0);
  return ok ? 0 : 1;
}

int main(int argc, char **argv) {
  const char *mountpoint = "/tmp/fuse-demo";

  if (argc >= 3) {
    mountpoint = argv[2];
  } else if (argc == 2 && strcmp(argv[1], "--test") != 0 &&
             strcmp(argv[1], "--serve") != 0) {
    mountpoint = argv[1];
  }

  if (argc >= 2 && strcmp(argv[1], "--test") == 0) {
    return run_test(mountpoint);
  }

  if (argc >= 2 && strcmp(argv[1], "--help") == 0) {
    printf("usage: fuse_hello [--test] [mountpoint]\n");
    return 0;
  }

  return run_server(mountpoint);
}
EOF_FUSE_HELLO_C

  touch -d "@$SOURCE_DATE_EPOCH" "$out"
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

if [ "${1:-}" = "--emit-fuse-source" ]; then
  if [ -z "${2:-}" ]; then
    echo "usage: $0 --emit-fuse-source <output.c>" >&2
    exit 1
  fi
  write_fuse_hello_source "$2"
  exit 0
fi

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
[ -c /dev/fuse ] || mknod -m 666 /dev/fuse c 10 229 2>/dev/null || true

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
  mknod -m 666 "$ROOTFS_DIR/dev/fuse" c 10 229 2>/dev/null || true
}

pack_rootfs() {
  need_cmd cpio
  need_cmd gzip

  echo "[INFO] Packing initramfs to $OUT_DIR/single.gz..."
  normalize_rootfs_mtime
  (
    cd "$ROOTFS_DIR"
    find . -print0 \
      | sort -z \
      | cpio --null --reproducible --renumber-inodes -ov --format=newc --owner=0:0 2>/dev/null \
      | gzip -n -9
  ) > "$OUT_DIR/single.gz"
  touch -d "@$SOURCE_DATE_EPOCH" "$OUT_DIR/single.gz"
}

download_busybox
extract_busybox
build_busybox
create_rootfs
pack_rootfs

echo "[OK] Single-user filesystem built: $OUT_DIR/single.gz"
