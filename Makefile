CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra

libceph_lazyio.so: ceph_lazyio_preload.c
	$(CC) $(CFLAGS) -U_FORTIFY_SOURCE -fPIC -shared -o $@ $< -ldl -pthread

tests/hold_open: tests/hold_open.c
	$(CC) $(CFLAGS) -o $@ $<

# make test MOUNT_A=/mnt/a MOUNT_B=/mnt/b
test: libceph_lazyio.so tests/hold_open
	@test -n "$(MOUNT_A)" -a -n "$(MOUNT_B)" || \
		{ echo "usage: make test MOUNT_A=<mnt> MOUNT_B=<mnt>"; exit 2; }
	LIB=$(CURDIR)/libceph_lazyio.so HELPER=$(CURDIR)/tests/hold_open \
		tests/test_lazyio.sh $(MOUNT_A) $(MOUNT_B)

clean:
	rm -f libceph_lazyio.so tests/hold_open

.PHONY: test clean
