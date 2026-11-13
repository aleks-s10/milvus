#!/bin/bash
# Builds the OpenSSL 3.1.2 FIPS provider with the compiler certificate #4985 lists for Ubuntu 22.04.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
V=11.2.0-19ubuntu1
apt-get install -y -qq --no-install-recommends gcc-11=$V cpp-11=$V gcc-11-base=$V libgcc-11-dev=$V libasan6=$V libtsan0=$V make perl curl ca-certificates binutils libc6-dev >/dev/null
gcc-11 --version | head -1
dpkg-query -W -f='${Package} ${Version}\n' gcc-11 cpp-11
grep -E '^VERSION=' /etc/os-release
CC=gcc-11 bash scripts/build_fips_provider.sh "$PWD" 2>&1 | tail -5
SO=internal/core/output/lib/ossl-modules/fips.so
echo "compiler stamp: $(strings -a "$SO" | grep -m2 -E 'GCC: \(' | tr '\n' ';')"
sha256sum "$SO"
grep -E 'conditional-errors|security-checks|tls1-prf-ems-check|drbg-no-trunc-md' configs/ssl/fipsmodule-strict.cnf
