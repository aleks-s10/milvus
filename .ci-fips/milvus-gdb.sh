#!/bin/bash
# Fork test branch only: run Milvus under gdb and print a backtrace if it crashes.
apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq gdb >/dev/null 2>&1
echo "GDB: $(gdb --version | head -1)"
# gdb turns ASLR off by default; the crash only shows with it on.
exec gdb -q -batch -ex "set pagination off" -ex "set disable-randomization off" \
  -ex "handle SIGURG nostop noprint pass" -ex "handle SIGPIPE nostop noprint pass" -ex "handle SIGPROF nostop noprint pass" \
  -ex run -ex "echo === CRASH BACKTRACE ===\n" -ex bt -ex 'x/4i $pc' -ex "info registers rip" -ex "info sharedlibrary" \
  -ex "thread apply all bt 6" --args milvus run standalone
