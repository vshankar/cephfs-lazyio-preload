/*
 * hold_open - open a file the way an application would, then keep it open
 *
 * Usage: hold_open [-x] MODE FILE
 *
 *   MODE  r   open(O_RDONLY)
 *         w   open(O_WRONLY|O_APPEND), write "hello\n"
 *         fw  fopen("a"), write "hello\n" and fflush()
 *   -x    exit right after opening (and writing) instead of waiting
 *
 * Prints READY to stderr once the file is open, then sleeps until killed.
 * The test runs this under LD_PRELOAD so the shim sees real open()/fopen()
 * calls from a C program.
 */

#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const char data[] = "hello\n";

static int usage(const char *prog)
{
  fprintf(stderr, "usage: %s [-x] r|w|fw FILE\n", prog);
  return 2;
}

int main(int argc, char **argv)
{
  int exit_now = 0;
  int argi = 1;
  const char *mode, *path;

  if (argi < argc && strcmp(argv[argi], "-x") == 0) {
    exit_now = 1;
    argi++;
  }
  if (argc - argi != 2) {
    return usage(argv[0]);
  }
  mode = argv[argi];
  path = argv[argi + 1];

  if (strcmp(mode, "r") == 0) {
    if (open(path, O_RDONLY) < 0) {
      perror(path);
      return 1;
    }
    fprintf(stderr, "READY\n");
  } else if (strcmp(mode, "w") == 0) {
    int fd = open(path, O_WRONLY | O_APPEND);
    if (fd < 0) {
      perror(path);
      return 1;
    }
    fprintf(stderr, "READY\n");
    if (write(fd, data, sizeof(data) - 1) != sizeof(data) - 1) {
      perror("write");
      return 1;
    }
  } else if (strcmp(mode, "fw") == 0) {
    FILE *f = fopen(path, "a");
    if (!f) {
      perror(path);
      return 1;
    }
    fprintf(stderr, "READY\n");
    if (fputs(data, f) == EOF || fflush(f) == EOF) {
      perror("fputs");
      return 1;
    }
  } else {
    return usage(argv[0]);
  }

  if (!exit_now) {
    pause();
  }
  return 0;
}
