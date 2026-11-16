#!/bin/bash
# Fork test branch only. Builds the repro against the original helper and the two option-3 variants,
# then runs a 60 s PBKDF2 stress and a deliberate C crash with each. Runs inside golang:1.26.9.
set -u
cd "$(dirname "$0")"
command -v python3 >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq python3 >/dev/null; }
export GOEXPERIMENT=boringcrypto CGO_ENABLED=1 GOFLAGS=-buildvcs=false
go mod tidy >/dev/null 2>&1 || { echo "go mod tidy failed"; go mod tidy; exit 1; }
FORK=$(go mod download -json github.com/milvus-io/cgosymbolizer@v0.0.0-20260810014817-f3b338cf6824 | sed -n 's/.*"Dir": "\(.*\)",/\1/p')
for v in orig 3a 3b; do
  rm -rf /tmp/fork-$v; cp -r "$FORK" /tmp/fork-$v; chmod -R u+w /tmp/fork-$v
  [ $v = orig ] || python3 patch.py /tmp/fork-$v/traceback.c $v
  cp go.mod go.mod.bak; go mod edit -replace github.com/ianlancetaylor/cgosymbolizer=/tmp/fork-$v
  go build -o /tmp/repro-$v . 2>&1 | tail -5; mv go.mod.bak go.mod
done
for v in orig 3a 3b; do
  echo "===== variant $v: stress"
  ( cd /tmp && GOGC=10 timeout 120 /tmp/repro-$v; echo "exit=$?" ) 2>&1 | tail -4
  echo "===== variant $v: C crash report"
  ( cd /tmp && GOTRACEBACK=crash timeout 30 /tmp/repro-$v ccrash; echo "exit=$?" ) 2>&1 | grep -E "signal|ccrash|goFrameAboveC|main\.main|PC=|^exit=|traceback.c|\.c:[0-9]+" | head -12
done
echo REPRO-DONE
