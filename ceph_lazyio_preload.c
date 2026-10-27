/*
 * ceph_lazyio_preload.c - LD_PRELOAD shim that enables CephFS lazy I/O
 *
 * Every successful open of a regular file on a CephFS *kernel* mount gets
 * ioctl(fd, CEPH_IOC_LAZYIO) issued on it.  With lazy I/O the MDS can hand
 * the client CEPH_CAP_FILE_LAZYIO while the file is open on several clients
 * (filelock in MIX), and the kernel client keeps doing buffered writes and
 * cached reads instead of falling back to synchronous OSD I/O.
 *
 * Trade-off: coherency is relaxed.  Other clients see this client's writes
 * only once they are written back (fsync(), close(), or normal dirty page
 * writeback), and this client may read stale data written elsewhere.  That
 * is why, by default, only file descriptors opened for writing are switched
 * to lazy I/O.
 *
 * ceph-fuse/libcephfs do not implement this ioctl; use the client config
 * option client_force_lazyio there instead.  FUSE mounts are skipped here
 * because their statfs type is not CEPH_SUPER_MAGIC.
 *
 * Build:
 *   cc -O2 -Wall -U_FORTIFY_SOURCE -fPIC -shared \
 *      -o libceph_lazyio.so ceph_lazyio_preload.c -ldl -pthread
 *
 * Use:
 *   LD_PRELOAD=/path/to/libceph_lazyio.so ./simulation ...
 *
 * Environment:
 *   CEPH_LAZYIO_PATHS  colon-separated list of directory prefixes; when set,
 *                      only files below one of them are switched to lazy I/O
 *                      (matched against the resolved absolute path).
 *   CEPH_LAZYIO_ALL    if "1", also switch read-only opens to lazy I/O.
 *   CEPH_LAZYIO_DEBUG  if "1", log every decision to stderr.
 *
 * Limitations: does not affect statically linked or setuid binaries (the
 * dynamic loader ignores LD_PRELOAD for those), nor files opened via raw
 * syscall(2) or openat2(2).
 */

#define _GNU_SOURCE
/* fortified open() wrappers in <bits/fcntl2.h> would clash with ours */
#undef _FORTIFY_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/vfs.h>
#include <unistd.h>

/* from the kernel's fs/ceph/ioctl.h and include/uapi/linux/magic.h */
#define CEPH_IOCTL_MAGIC 0x97
#define CEPH_IOC_LAZYIO _IO(CEPH_IOCTL_MAGIC, 4)
#ifndef CEPH_SUPER_MAGIC
#define CEPH_SUPER_MAGIC 0x00c36400
#endif

#define NEEDS_MODE(flags) \
  (((flags) & O_CREAT) || (((flags) & O_TMPFILE) == O_TMPFILE))

/* glibc's _FORTIFY_SOURCE entry points; not declared without fortify */
int __open_2(const char *path, int flags);
int __open64_2(const char *path, int flags);
int __openat_2(int dirfd, const char *path, int flags);
int __openat64_2(int dirfd, const char *path, int flags);

static pthread_once_t config_once = PTHREAD_ONCE_INIT;
static int cfg_all;
static int cfg_debug;
static char **cfg_paths;
static size_t cfg_npaths;

static void load_config(void)
{
  const char *s;

  s = getenv("CEPH_LAZYIO_ALL");
  cfg_all = s && strcmp(s, "1") == 0;
  s = getenv("CEPH_LAZYIO_DEBUG");
  cfg_debug = s && strcmp(s, "1") == 0;

  s = getenv("CEPH_LAZYIO_PATHS");
  if (!s || !*s) {
    return;
  }
  char *dup = strdup(s);
  if (!dup) {
    return;
  }
  size_t n = 1;
  for (const char *p = dup; *p; p++) {
    if (*p == ':') {
      n++;
    }
  }
  cfg_paths = calloc(n, sizeof(*cfg_paths));
  if (!cfg_paths) {
    free(dup);
    return;
  }
  char *save = NULL;
  for (char *tok = strtok_r(dup, ":", &save); tok;
       tok = strtok_r(NULL, ":", &save)) {
    size_t len = strlen(tok);
    /* "/mnt/cephfs/" and "/mnt/cephfs" are the same prefix */
    while (len > 1 && tok[len - 1] == '/') {
      tok[--len] = '\0';
    }
    cfg_paths[cfg_npaths++] = tok;
  }
  /* dup is intentionally kept alive: cfg_paths points into it */
}

static void debug(const char *fmt, ...)
{
  char buf[PATH_MAX + 128];
  va_list ap;
  int len;

  if (!cfg_debug) {
    return;
  }
  len = snprintf(buf, sizeof(buf), "ceph_lazyio[%d]: ", (int)getpid());
  va_start(ap, fmt);
  len += vsnprintf(buf + len, sizeof(buf) - len, fmt, ap);
  va_end(ap);
  if (len >= (int)sizeof(buf)) {
    len = sizeof(buf) - 1;
    buf[len - 1] = '\n';
  }
  /* raw write(2): stdio could recurse or interleave badly */
  ssize_t r = write(STDERR_FILENO, buf, len);
  (void)r;
}

static int fd_path(int fd, char *buf, size_t size)
{
  char link[64];
  ssize_t len;

  snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
  len = readlink(link, buf, size - 1);
  if (len < 0) {
    return -1;
  }
  buf[len] = '\0';
  return 0;
}

static int path_allowed(const char *path)
{
  if (!cfg_paths) {
    return 1;
  }
  for (size_t i = 0; i < cfg_npaths; i++) {
    const char *prefix = cfg_paths[i];
    size_t len = strlen(prefix);
    if (strcmp(prefix, "/") == 0) {
      return 1;
    }
    /* match whole path components only: /mnt/a must not match /mnt/ab */
    if (strncmp(path, prefix, len) == 0 &&
        (path[len] == '\0' || path[len] == '/')) {
      return 1;
    }
  }
  return 0;
}

static void maybe_lazyio(int fd)
{
  struct statfs sfs;
  struct stat st;
  char path[PATH_MAX] = "?";
  int saved_errno = errno;
  int fl;

  if (fd < 0) {
    return;
  }
  pthread_once(&config_once, load_config);

  /* cheapest filter first: most opens are not on CephFS */
  if (fstatfs(fd, &sfs) < 0 ||
      (unsigned long)sfs.f_type != CEPH_SUPER_MAGIC) {
    goto out;
  }
  fl = fcntl(fd, F_GETFL);
  if (fl < 0 || (fl & O_PATH)) {
    goto out;
  }
  if (!cfg_all && (fl & O_ACCMODE) == O_RDONLY) {
    goto out;
  }
  if (fstat(fd, &st) < 0 || !S_ISREG(st.st_mode)) {
    goto out;
  }
  if (cfg_paths || cfg_debug) {
    if (fd_path(fd, path, sizeof(path)) < 0) {
      strcpy(path, "?");
    }
    if (!path_allowed(path)) {
      debug("fd %d %s: outside CEPH_LAZYIO_PATHS, skipped\n", fd, path);
      goto out;
    }
  }
  if (ioctl(fd, CEPH_IOC_LAZYIO) < 0) {
    debug("fd %d %s: CEPH_IOC_LAZYIO failed: %s\n", fd, path,
          strerror(errno));
  } else {
    debug("fd %d %s: lazy I/O enabled\n", fd, path);
  }
out:
  errno = saved_errno;
}

static void *real(const char *sym)
{
  void *fn = dlsym(RTLD_NEXT, sym);
  if (!fn) {
    /* nothing sensible to fall back to; fail like a missing libc symbol */
    char msg[128];
    int len = snprintf(msg, sizeof(msg),
                       "ceph_lazyio: dlsym(%s) failed\n", sym);
    ssize_t r = write(STDERR_FILENO, msg, len);
    (void)r;
    abort();
  }
  return fn;
}

/*
 * Resolve the next definition once per symbol.  Concurrent first calls may
 * both run dlsym(); they store the same value, so the race is benign.
 */
#define REAL(type, name)                                   \
  static type real_##name;                                 \
  if (!real_##name) {                                      \
    real_##name = (type)real(#name);                       \
  }

#define GET_MODE(flags, mode)                              \
  do {                                                     \
    if (NEEDS_MODE(flags)) {                               \
      va_list ap;                                          \
      va_start(ap, flags);                                 \
      mode = (mode_t)va_arg(ap, int);                      \
      va_end(ap);                                          \
    }                                                      \
  } while (0)

typedef int (*open_fn)(const char *, int, ...);
typedef int (*openat_fn)(int, const char *, int, ...);
typedef int (*open2_fn)(const char *, int);
typedef int (*openat2_fn)(int, const char *, int);
typedef int (*creat_fn)(const char *, mode_t);
typedef FILE *(*fopen_fn)(const char *, const char *);
typedef FILE *(*freopen_fn)(const char *, const char *, FILE *);

int open(const char *path, int flags, ...)
{
  mode_t mode = 0;
  GET_MODE(flags, mode);
  REAL(open_fn, open);
  int fd = real_open(path, flags, mode);
  maybe_lazyio(fd);
  return fd;
}

int open64(const char *path, int flags, ...)
{
  mode_t mode = 0;
  GET_MODE(flags, mode);
  REAL(open_fn, open64);
  int fd = real_open64(path, flags, mode);
  maybe_lazyio(fd);
  return fd;
}

int openat(int dirfd, const char *path, int flags, ...)
{
  mode_t mode = 0;
  GET_MODE(flags, mode);
  REAL(openat_fn, openat);
  int fd = real_openat(dirfd, path, flags, mode);
  maybe_lazyio(fd);
  return fd;
}

int openat64(int dirfd, const char *path, int flags, ...)
{
  mode_t mode = 0;
  GET_MODE(flags, mode);
  REAL(openat_fn, openat64);
  int fd = real_openat64(dirfd, path, flags, mode);
  maybe_lazyio(fd);
  return fd;
}

int __open_2(const char *path, int flags)
{
  REAL(open2_fn, __open_2);
  int fd = real___open_2(path, flags);
  maybe_lazyio(fd);
  return fd;
}

int __open64_2(const char *path, int flags)
{
  REAL(open2_fn, __open64_2);
  int fd = real___open64_2(path, flags);
  maybe_lazyio(fd);
  return fd;
}

int __openat_2(int dirfd, const char *path, int flags)
{
  REAL(openat2_fn, __openat_2);
  int fd = real___openat_2(dirfd, path, flags);
  maybe_lazyio(fd);
  return fd;
}

int __openat64_2(int dirfd, const char *path, int flags)
{
  REAL(openat2_fn, __openat64_2);
  int fd = real___openat64_2(dirfd, path, flags);
  maybe_lazyio(fd);
  return fd;
}

int creat(const char *path, mode_t mode)
{
  REAL(creat_fn, creat);
  int fd = real_creat(path, mode);
  maybe_lazyio(fd);
  return fd;
}

int creat64(const char *path, mode_t mode)
{
  REAL(creat_fn, creat64);
  int fd = real_creat64(path, mode);
  maybe_lazyio(fd);
  return fd;
}

/* glibc's stdio opens files through internal calls that bypass open() */
FILE *fopen(const char *path, const char *mode)
{
  REAL(fopen_fn, fopen);
  FILE *f = real_fopen(path, mode);
  if (f) {
    maybe_lazyio(fileno(f));
  }
  return f;
}

FILE *fopen64(const char *path, const char *mode)
{
  REAL(fopen_fn, fopen64);
  FILE *f = real_fopen64(path, mode);
  if (f) {
    maybe_lazyio(fileno(f));
  }
  return f;
}

FILE *freopen(const char *path, const char *mode, FILE *stream)
{
  REAL(freopen_fn, freopen);
  FILE *f = real_freopen(path, mode, stream);
  if (f) {
    maybe_lazyio(fileno(f));
  }
  return f;
}

FILE *freopen64(const char *path, const char *mode, FILE *stream)
{
  REAL(freopen_fn, freopen64);
  FILE *f = real_freopen64(path, mode, stream);
  if (f) {
    maybe_lazyio(fileno(f));
  }
  return f;
}
