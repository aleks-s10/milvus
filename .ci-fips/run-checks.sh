#!/bin/bash
# usage: run-checks.sh strict|default. Every check must pass; prints a summary and exits non-zero otherwise.
MODE=$1; cd "$(dirname "$0")"; IMG=fipslocal/milvus:ci; mkdir -p logs certs; FAILS=0
check(){ if [ "$2" = "$3" ]; then echo "PASS  $1 ($2)"; else echo "FAIL  $1: got '$2', want '$3'"; FAILS=$((FAILS+1)); fi; }
inimg(){ docker run --rm --entrypoint sh $IMG -c "$1" 2>&1 | grep -v LD_PRELOAD; }
dc(){ docker compose -f compose.yml "$@"; }
up(){ HASHALG=$1 dc up -d >/dev/null 2>&1; for _ in $(seq 1 90); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:9091/healthz)" = 200 ] && { echo up; return; }; sleep 5; done; echo down; }
hash_prefix(){ dc exec -T etcd etcdctl get --prefix by-dev/meta/root-coord/credential/users/$1 2>/dev/null | grep -oE '"encrypted_password":"\$[a-z0-9-]+' | cut -d'$' -f2; }
tls(){ l=$(docker run --rm --network fipsci_default --entrypoint sh $IMG -c "echo | openssl s_client -connect standalone:19530 $1 2>&1 | grep -m1 'Cipher is'" 2>&1 | grep 'Cipher is'); case "$l" in *NONE*) echo refused;; *TLS*|*ECDHE*) echo accepted;; *) echo "no-handshake";; esac; }
docker run --rm --user 0 -v "$PWD/certs:/out" --entrypoint sh $IMG -c 'cd /out; O=/usr/bin/openssl; $O req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 3 -subj /CN=ci-ca 2>/dev/null; echo "subjectAltName=DNS:minio,DNS:standalone,DNS:localhost,IP:127.0.0.1" > ext; $O req -newkey rsa:2048 -nodes -keyout server.key -out s.csr -subj /CN=localhost 2>/dev/null; $O x509 -req -in s.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 3 -extfile ext 2>/dev/null; cp server.pem public.crt; cp server.key private.key; chmod 644 *'
python3 -m venv venv && ./venv/bin/pip -q install pymilvus
echo "== platform"; check "architecture" "$(inimg 'uname -m')" x86_64; inimg 'grep ^VERSION= /etc/os-release'
if [ "$MODE" = strict ]; then
  echo "== provider"; C=/milvus/configs/ssl/openssl-fips-strict.cnf
  P=$(inimg "OPENSSL_CONF=$C openssl list -providers")
  check "fips provider version" "$(echo "$P" | grep -A2 -i fips | grep -m1 version | awk '{print $2}')" 3.1.2
  check "default provider absent" "$(echo "$P" | grep -ci 'default')" 0
  check "md5 refused" "$(inimg "echo x | OPENSSL_CONF=$C openssl dgst -md5 >/dev/null 2>&1; echo \$?")" 1
  check "chacha20 refused" "$(inimg "echo x | OPENSSL_CONF=$C openssl enc -chacha20 -pass pass:x -pbkdf2 >/dev/null 2>&1; echo \$?")" 1
  check "sha256 works" "$(inimg "echo x | OPENSSL_CONF=$C openssl dgst -sha256 >/dev/null 2>&1; echo \$?")" 0
  echo "== refuses to start"
  for t in 'sed -i "s/^module-mac = ../module-mac = 00/" /milvus/configs/ssl/fipsmodule-strict.cnf' 'rm /milvus/configs/ssl/openssl-fips-strict.cnf' 'rm /milvus/lib/ossl-modules/fips.so'; do
    check "fail closed: ${t:0:28}" "$(inimg "$t; timeout 40 milvus run standalone >/dev/null 2>&1; echo \$?")" 1
  done
  echo "== bcrypt then pbkdf2"; check "stack up (bcrypt)" "$(up bcrypt)" up
  ./venv/bin/python pw_check.py create; check "legacy user created" $? 0
  check "legacy hash" "$(hash_prefix legacy_bcrypt)" 2a
  check "stack up (pbkdf2)" "$(up pbkdf2-sha512)" up; sleep 5
  ./venv/bin/python pw_check.py verify; check "password flows" $? 0
  check "changed user hash" "$(hash_prefix pb_user)" pbkdf2-sha512
  check "rotated user hash" "$(hash_prefix legacy_bcrypt)" pbkdf2-sha512
  dc logs standalone > logs/pw.log 2>&1; dc down -v >/dev/null 2>&1; ALG=pbkdf2-sha512; ROOT=pbkdf2-sha512; REFUSE=refused; BC=true
else ALG=bcrypt; ROOT=2a; REFUSE=accepted; BC=false; fi
echo "== fresh install"; check "stack up" "$(up $ALG)" up; dc logs standalone > logs/run.log 2>&1
check "BoringCrypto" "$(grep -m1 -oE 'BoringCrypto (true|false)' logs/run.log | cut -d' ' -f2)" $BC
check "strict banner lines" "$(grep -c 'FIPS strict mode: enabled' logs/run.log)" "$([ $MODE = strict ] && echo 1 || echo 0)"
check "root hash" "$(hash_prefix root)" $ROOT
echo "== proxy TLS"
check "TLS1.3 AES256-GCM" "$(tls '-tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384')" accepted
check "TLS1.3 AES128-GCM" "$(tls '-tls1_3 -ciphersuites TLS_AES_128_GCM_SHA256')" accepted
check "TLS1.2 AES128-GCM" "$(tls '-tls1_2 -cipher ECDHE-RSA-AES128-GCM-SHA256')" accepted
check "TLS1.3 ChaCha20" "$(tls '-tls1_3 -ciphersuites TLS_CHACHA20_POLY1305_SHA256')" $REFUSE
check "TLS1.2 ChaCha20" "$(tls '-tls1_2 -cipher ECDHE-RSA-CHACHA20-POLY1305')" $REFUSE
check "TLS1.3 X25519" "$(tls '-tls1_3 -groups X25519')" $REFUSE
check "TLS1.3 P-256" "$(tls '-tls1_3 -groups P-256')" accepted
echo "== data over TLS"; ./venv/bin/python data_check.py; check "data workflow" $? 0
dc logs standalone > logs/run.log 2>&1; check "ERROR lines" "$(grep -cE '\[ERROR\]' logs/run.log)" 0; check "panic/FATAL" "$(grep -cE 'panic:|\[FATAL\]' logs/run.log)" 0
check "C++ used TLS to storage" "$(grep -m1 -oE 'useSSL=[a-z0-9]+' logs/run.log)" useSSL=true
dc down -v >/dev/null 2>&1
echo "== result: $FAILS failed"; exit $FAILS
