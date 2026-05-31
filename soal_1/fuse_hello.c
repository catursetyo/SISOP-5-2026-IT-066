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
#include <time.h>
#include <unistd.h>

#ifndef FUSE_ROOT_ID
#define FUSE_ROOT_ID 1
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
  attr->atime = attr->mtime = attr->ctime = (uint64_t)time(NULL);

  if (nodeid == FUSE_ROOT_ID) {
    attr->mode = S_IFDIR | 0555;
    attr->nlink = 2;
    attr->size = 0;
    attr->blocks = 0;
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

static void handle_open(int fd, const struct fuse_in_header *in,
                        uint64_t fh) {
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

  memset(&out, 0, sizeof(out));
  out.st.blocks = 1;
  out.st.bfree = 0;
  out.st.bavail = 0;
  out.st.files = 2;
  out.st.ffree = 0;
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
