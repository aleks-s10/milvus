#!/bin/bash
# Runs in the builder image with an extracted Milvus image at /x (milvus tree) and /root-fs listing.
cd /x
B=bin/milvus
echo "== go build info"; go version -m $B > /out/go-version-m.txt 2>&1
grep -E '^\s+build\s' /out/go-version-m.txt | grep -E 'tags|GOEXPERIMENT|CGO_ENABLED|GOFIPS'
echo "modules: $(grep -cE '^\s+dep\s' /out/go-version-m.txt)  etcd/server mod: $(grep -c 'go.etcd.io/etcd/server' /out/go-version-m.txt)  woodpecker: $(grep -E 'zilliztech/woodpecker' /out/go-version-m.txt | awk '{print $3, $4, $5}' | tr '\n' ' ')"
go tool nm $B > /tmp/gn 2>/dev/null
cnt() { grep -cE "$1" /tmp/gn; }
echo "go symbols: etcd/server=$(cnt 'go\.etcd\.io/etcd/server') bcrypt=$(cnt 'x/crypto/bcrypt\.') pbkdf2=$(cnt 'pbkdf2\.') boring=$(cnt 'crypto/internal/boring\.') x_chacha20=$(cnt 'x/crypto/chacha20') x_md4=$(cnt 'x/crypto/md4') md5=$(cnt ' crypto/md5\.') rc4=$(cnt ' crypto/rc4\.') des=$(cnt ' crypto/des\.') fipsonly=$(cnt 'crypto/tls/fipsonly') fipsstrict=$(cnt 'util/fips\.(strict|Strict)')"
echo "== native libraries (rust crypto / tls / misc)"
printf '%-40s %8s %6s %6s %6s %6s %6s %6s %6s %6s %6s\n' file symtab rustls ring awslc webpki reqwest chacha osslsys s2n sodium
for f in lib/*.so* lib/*.a bin/milvus; do [ -L "$f" ] && continue; [ -f "$f" ] || continue
  { nm -a "$f"; nm -D "$f"; } 2>/dev/null > /tmp/n
  r=(rustls '_ZN4ring|\$LT\$ring\.\.|ring_core_' aws_lc webpki reqwest chacha20 openssl_sys ' s2n_' ' (sodium_init|crypto_generichash)')
  line=$(printf '%-40s %8s' "$(basename $f)" "$(wc -l </tmp/n)"); tot=0
  for p in "${r[@]}"; do c=$(grep -ciE "$p" /tmp/n); tot=$((tot+c)); line="$line $(printf '%6s' $c)"; done
  [ $tot -gt 0 ] || [[ "$f" == *milvus_core* || "$f" == *milvus-storage* || "$f" == *tantivy* ]] && echo "$line"
done
echo "== OpenSSL in image"
ls -la lib/ | grep -E 'libssl|libcrypto|ossl' | awk '{print $NF}' | tr '\n' ' '; echo
for m in lib/ossl-modules/*.so; do echo "$m: $(strings -a $m | grep -m1 -E '^3\.[0-9]+\.[0-9]+$') sha256=$(sha256sum $m | cut -c1-16)"; done
for l in lib/libcrypto.so.3; do [ -f $l ] && strings -a $(readlink -f $l) | grep -m1 -E '^OpenSSL 3'; done
ls configs/ssl 2>/dev/null
echo "== python in image: $(ls /x-root/usr/bin 2>/dev/null | grep -cE '^python3')  pyudf dir: $(ls -d lib/pyudf 2>/dev/null)"
echo SCAN-DONE
