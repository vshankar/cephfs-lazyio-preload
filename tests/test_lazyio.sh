#!/usr/bin/env bash
#
# test_lazyio.sh - exercise libceph_lazyio.so across two CephFS kernel mounts
#
# Usage: test_lazyio.sh MOUNT_A MOUNT_B
#
# MOUNT_A and MOUNT_B must be kernel mounts of the same directory of the same
# file system, backed by *different* client instances.  On a single host,
# mount the second one with "-o noshare", otherwise the kernel reuses the
# first client and the MDS sees only one client:
#
#   mount -t ceph <mon>:/ /mnt/a -o name=admin
#   mount -t ceph <mon>:/ /mnt/b -o name=admin,noshare
#
# Writers run on MOUNT_A, readers on MOUNT_B.  The reader keeps the file open
# so the MDS moves the filelock to MIX, which is where lazy I/O matters.
#
# Checks based on the shim's debug log run anywhere.  Checks of the caps the
# MDS actually issued read /sys/kernel/debug/ceph/<fsid>.client<id>/caps and
# need root, a mounted debugfs and getfattr(1); they are skipped otherwise.
#
# Environment:
#   LIB      path to libceph_lazyio.so (default: ../libceph_lazyio.so)
#   HELPER   path to hold_open (default: ./hold_open next to this script)
#   TIMEOUT  seconds to wait for caps/data to settle (default: 15)

set -u

if [[ $# -ne 2 ]]; then
  echo "usage: $0 MOUNT_A MOUNT_B" >&2
  exit 2
fi

MNT_A=$(realpath "$1")
MNT_B=$(realpath "$2")
LIB=$(realpath "${LIB:-$(dirname "$0")/../libceph_lazyio.so}")
HELPER=$(realpath "${HELPER:-$(dirname "$0")/hold_open}")
TIMEOUT=${TIMEOUT:-15}
NAME=lazyio-test.$$.$RANDOM
DIR_A=$MNT_A/$NAME
DIR_B=$MNT_B/$NAME
LOGDIR=$(mktemp -d)

PASS=0
FAIL=0
SKIP=0
PIDS=()
CAPS_A=
CAPS_B=

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $*"; SKIP=$((SKIP + 1)); }
die() { echo "ERROR: $*" >&2; exit 2; }

stop_all() {
  if [[ ${#PIDS[@]} -gt 0 ]]; then
    kill "${PIDS[@]}" 2>/dev/null
    wait "${PIDS[@]}" 2>/dev/null
  fi
  PIDS=()
}

cleanup() {
  stop_all
  rm -rf "$DIR_A" "$LOGDIR"
}
trap cleanup EXIT

# wait_until SECONDS CMD... - poll CMD every 0.2s until it succeeds
wait_until() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    if [[ $SECONDS -ge $deadline ]]; then
      return 1
    fi
    sleep 0.2
  done
}

log_has() { grep -q -- "$2" "$1" 2>/dev/null; }

# start_holder MODE FILE LOG [VAR=VALUE...] - run hold_open MODE FILE in the
# background (see hold_open.c) and wait until FILE is open.  VAR=VALUE pairs
# are put in that process's environment (e.g. LD_PRELOAD).
start_holder() {
  local mode=$1 file=$2 log=$3
  shift 3
  env "$@" "$HELPER" "$mode" "$file" </dev/null >/dev/null 2>"$log" &
  PIDS+=($!)
  wait_until "$TIMEOUT" log_has "$log" READY ||
    die "hold_open $mode $file did not start: $(cat "$log")"
}

# start_writer FILE LOG [VAR=VALUE...] - open FILE for append, write, keep open
start_writer() { start_holder w "$@"; }

# start_reader FILE LOG [VAR=VALUE...] - open FILE read-only and keep it open
start_reader() { start_holder r "$@"; }

# debugfs directory of the client instance behind a kernel mount
client_debugfs() {
  local fsid cid
  fsid=$(getfattr --only-values -n ceph.cluster_fsid "$1" 2>/dev/null) || return 1
  cid=$(getfattr --only-values -n ceph.client_id "$1" 2>/dev/null) || return 1
  [[ -r /sys/kernel/debug/ceph/$fsid.$cid/caps ]] || return 1
  echo "/sys/kernel/debug/ceph/$fsid.$cid"
}

# issued_caps DEBUGFS_DIR FILE - caps the client holds on FILE, e.g. "pAsLsXsFrwl"
issued_caps() {
  local ino
  ino=$(stat -c %i "$2") || return 1
  awk -v a="$(printf '0x%x' "$ino")" -v b="$(printf '%x' "$ino")" \
    '$1 == a || $1 == b { print $3; exit }' "$1/caps"
}

# file_caps_have DEBUGFS_DIR FILE LETTER - LETTER is among the issued F caps
file_caps_have() {
  local caps fcaps
  caps=$(issued_caps "$1" "$2") || return 1
  fcaps=$(grep -o 'F[a-z]*' <<<"$caps")
  [[ $fcaps == *"$3"* ]]
}

new_file() {
  local f=$DIR_A/$1
  : >"$f" || die "cannot create $f"
  # make sure mount B can see it before anybody opens it there
  wait_until "$TIMEOUT" test -e "$DIR_B/$1" || die "$1 not visible on $MNT_B"
  echo "$f"
}

#
# Setup and sanity checks
#

[[ -f $LIB ]] || die "$LIB not found; run make first"
[[ -x $HELPER ]] || die "$HELPER not found; run make first"
for m in "$MNT_A" "$MNT_B"; do
  [[ $(stat -f -c %T "$m") == ceph ]] || die "$m is not a CephFS kernel mount"
done
[[ $MNT_A != "$MNT_B" ]] || die "MOUNT_A and MOUNT_B are the same path"

mkdir "$DIR_A" || die "cannot create $DIR_A"
wait_until "$TIMEOUT" test -d "$DIR_B" ||
  die "$DIR_A not visible as $DIR_B; do both mounts expose the same directory?"
[[ $(stat -c %i "$DIR_A") == $(stat -c %i "$DIR_B") ]] ||
  die "$DIR_A and $DIR_B are different directories"

if command -v getfattr >/dev/null; then
  cid_a=$(getfattr --only-values -n ceph.client_id "$MNT_A" 2>/dev/null)
  cid_b=$(getfattr --only-values -n ceph.client_id "$MNT_B" 2>/dev/null)
  if [[ -n $cid_a && $cid_a == "$cid_b" ]]; then
    die "both mounts share $cid_a; remount $MNT_B with -o noshare"
  fi
  CAPS_A=$(client_debugfs "$MNT_A")
  CAPS_B=$(client_debugfs "$MNT_B")
fi
if [[ -z $CAPS_A || -z $CAPS_B ]]; then
  echo "note: debugfs caps not accessible (need root, debugfs, getfattr);" \
    "cap checks will be skipped"
fi

PRELOAD=(LD_PRELOAD="$LIB" CEPH_LAZYIO_DEBUG=1)

#
# Tests
#

# The shim leaves non-CephFS files alone.
log=$LOGDIR/nonceph.log
: >"$LOGDIR/scratch"
env "${PRELOAD[@]}" "$HELPER" -x w "$LOGDIR/scratch" 2>"$log"
if log_has "$log" "ceph_lazyio"; then
  fail "non-CephFS open was touched: $(cat "$log")"
else
  pass "non-CephFS open ignored"
fi

# Writer under the preload, reader on the other mount: the writer's fd is
# switched to lazy I/O and the MDS issues Fl to the writer's client.
f=$(new_file writer-lazy) || exit 2
start_reader "$DIR_B/writer-lazy" "$LOGDIR/t1-reader.log"
start_writer "$f" "$LOGDIR/t1-writer.log" "${PRELOAD[@]}"
if log_has "$LOGDIR/t1-writer.log" "writer-lazy: lazy I/O enabled"; then
  pass "writable open on CephFS gets CEPH_IOC_LAZYIO"
else
  fail "no lazy I/O for writer: $(cat "$LOGDIR/t1-writer.log")"
fi
if [[ -n $CAPS_A ]]; then
  if wait_until "$TIMEOUT" file_caps_have "$CAPS_A" "$f" l; then
    pass "writer client holds Fl ($(issued_caps "$CAPS_A" "$f"))"
  else
    fail "writer client never got Fl ($(issued_caps "$CAPS_A" "$f"))"
  fi
else
  skip "writer Fl cap check"
fi

# With the writer lazy, its data reaches the reader once it is flushed.
sync "$f" 2>/dev/null || sync
if wait_until "$TIMEOUT" grep -qx hello "$DIR_B/writer-lazy"; then
  pass "reader sees lazy writer's data after fsync"
else
  fail "reader does not see writer's data: '$(cat "$DIR_B/writer-lazy")'"
fi
stop_all

# stdio opens bypass the exported open() inside glibc; fopen() is hooked too.
f=$(new_file writer-stdio) || exit 2
start_reader "$DIR_B/writer-stdio" "$LOGDIR/t1s-reader.log"
start_holder fw "$f" "$LOGDIR/t1s-writer.log" "${PRELOAD[@]}"
if log_has "$LOGDIR/t1s-writer.log" "writer-stdio: lazy I/O enabled"; then
  pass "fopen() on CephFS gets CEPH_IOC_LAZYIO"
else
  fail "no lazy I/O for fopen(): $(cat "$LOGDIR/t1s-writer.log")"
fi
stop_all

# Control: same scenario without the preload never yields Fl.
f=$(new_file writer-plain) || exit 2
start_reader "$DIR_B/writer-plain" "$LOGDIR/t2-reader.log"
start_writer "$f" "$LOGDIR/t2-writer.log"
if [[ -n $CAPS_A ]]; then
  if ! wait_until "$TIMEOUT" file_caps_have "$CAPS_A" "$f" w; then
    fail "control writer never got Fw ($(issued_caps "$CAPS_A" "$f"))"
  elif file_caps_have "$CAPS_A" "$f" l; then
    fail "control writer has Fl without the preload ($(issued_caps "$CAPS_A" "$f"))"
  else
    pass "without preload writer has no Fl ($(issued_caps "$CAPS_A" "$f"))"
  fi
else
  skip "control writer cap check"
fi
stop_all

# Read-only opens are left alone by default...
f=$(new_file reader-default) || exit 2
start_writer "$f" "$LOGDIR/t3-writer.log"
start_reader "$DIR_B/reader-default" "$LOGDIR/t3-reader.log" "${PRELOAD[@]}"
if log_has "$LOGDIR/t3-reader.log" "lazy I/O enabled"; then
  fail "read-only open switched to lazy I/O: $(cat "$LOGDIR/t3-reader.log")"
else
  pass "read-only open not switched by default"
fi
if [[ -n $CAPS_B ]]; then
  if file_caps_have "$CAPS_B" "$DIR_B/reader-default" l; then
    fail "default reader holds Fl ($(issued_caps "$CAPS_B" "$DIR_B/reader-default"))"
  else
    pass "default reader has no Fl"
  fi
else
  skip "default reader cap check"
fi
stop_all

# ...unless CEPH_LAZYIO_ALL=1.
f=$(new_file reader-all) || exit 2
start_writer "$f" "$LOGDIR/t4-writer.log"
start_reader "$DIR_B/reader-all" "$LOGDIR/t4-reader.log" "${PRELOAD[@]}" \
  CEPH_LAZYIO_ALL=1
if log_has "$LOGDIR/t4-reader.log" "reader-all: lazy I/O enabled"; then
  pass "read-only open switched with CEPH_LAZYIO_ALL=1"
else
  fail "CEPH_LAZYIO_ALL=1 ignored: $(cat "$LOGDIR/t4-reader.log")"
fi
if [[ -n $CAPS_B ]]; then
  if wait_until "$TIMEOUT" file_caps_have "$CAPS_B" "$DIR_B/reader-all" l; then
    pass "CEPH_LAZYIO_ALL reader holds Fl"
  else
    fail "CEPH_LAZYIO_ALL reader never got Fl" \
      "($(issued_caps "$CAPS_B" "$DIR_B/reader-all"))"
  fi
else
  skip "CEPH_LAZYIO_ALL reader cap check"
fi
stop_all

# CEPH_LAZYIO_PATHS matches whole path components only.
mkdir "$DIR_A/sub" "$DIR_A/subdir"
f=$(new_file sub/match) || exit 2
start_writer "$f" "$LOGDIR/t5-match.log" "${PRELOAD[@]}" \
  CEPH_LAZYIO_PATHS="/nonexistent:$DIR_A/sub/"
if log_has "$LOGDIR/t5-match.log" "sub/match: lazy I/O enabled"; then
  pass "CEPH_LAZYIO_PATHS prefix match"
else
  fail "CEPH_LAZYIO_PATHS did not match: $(cat "$LOGDIR/t5-match.log")"
fi
f=$(new_file subdir/nomatch) || exit 2
start_writer "$f" "$LOGDIR/t5-nomatch.log" "${PRELOAD[@]}" \
  CEPH_LAZYIO_PATHS="$DIR_A/sub"
if log_has "$LOGDIR/t5-nomatch.log" "outside CEPH_LAZYIO_PATHS" &&
  ! log_has "$LOGDIR/t5-nomatch.log" "lazy I/O enabled"; then
  pass "CEPH_LAZYIO_PATHS does not match a sibling with the same prefix"
else
  fail "CEPH_LAZYIO_PATHS mismatch handling: $(cat "$LOGDIR/t5-nomatch.log")"
fi
stop_all

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIP"
[[ $FAIL -eq 0 ]]
