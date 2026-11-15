#!/bin/bash
# Fork test branch only: print a backtrace from any core dump in /tmp/cores, using the image's own binary.
# Usage: core-bt.sh <image> <label>
IMG=$1; L=$2; ls -la /tmp/cores 2>/dev/null
C=$(ls /tmp/cores/core.* 2>/dev/null | head -1); [ -n "$C" ] || { echo "$L: no core dump"; exit 0; }
echo "$L: core $C"
docker run --rm --user root -v /tmp/cores:/tmp/cores:ro --entrypoint bash $IMG -c "apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq gdb >/dev/null 2>&1
  gdb -q -batch -ex 'set pagination off' -ex 'echo === CRASHING THREAD ===\n' -ex bt -ex 'x/4i \$pc' -ex 'info registers rip rsp' \
    -ex 'echo === ALL THREADS (top frames) ===\n' -ex 'thread apply all bt 5' /milvus/bin/milvus $C 2>&1 | grep -v '^\[New LWP' | head -250"
mkdir -p .ci-fips/logs/cores-$L; sudo mv /tmp/cores/core.* .ci-fips/logs/cores-$L/ 2>/dev/null; sudo rm -rf .ci-fips/logs/cores-$L   # cores are large; keep only the backtrace
