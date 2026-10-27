CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra

libceph_lazyio.so: ceph_lazyio_preload.c
	$(CC) $(CFLAGS) -U_FORTIFY_SOURCE -fPIC -shared -o $@ $< -ldl -pthread

clean:
	rm -f libceph_lazyio.so

.PHONY: clean
