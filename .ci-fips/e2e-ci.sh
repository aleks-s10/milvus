#!/bin/bash
# Fork test branch only. Smoke test of the integrated strict image on the runner (x86-64):
# PBKDF2, OpenSSL tokenizer TLS (ChaCha/X25519 refused), Lindera + BM25, storage v3 Parquet and tiered
# storage on Azurite over HTTPS, embedded etcd refused. Usage: e2e-ci.sh <image>
set -u; IMG=$1; R=$PWD/.ci-fips; OUT=${E2E_OUT:-$R/logs/e2e}; mkdir -p $OUT; C=$R/certs; mkdir -p $C; N=ci-e2e
cd $C
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7 -keyout ca.key -subj /CN=ci-ca -out ca.pem -addext basicConstraints=critical,CA:TRUE 2>/dev/null
mk(){ openssl req -new -newkey rsa:2048 -nodes -keyout $1.key -subj /CN=$2 -out $1.csr 2>/dev/null; printf "subjectAltName=DNS:$2\nextendedKeyUsage=serverAuth\n">$1.ext; openssl x509 -req -sha256 -days 7 -in $1.csr -CA ca.pem -CAkey ca.key -CAcreateserial -extfile $1.ext -out $1.pem 2>/dev/null; }
mk server tokenizer.test; mk azurite azurite; cat /etc/ssl/certs/ca-certificates.crt ca.pem > bundle.pem; chmod 644 *; cd - >/dev/null
docker network create $N >/dev/null
RUST=rust:1.85.0-bookworm
srv() { n=$1; p=$2; shift 2; docker run -d --name $n --network $N --network-alias tokenizer.test -v $R/tt-server-bin:/b:ro -v $C:/certs:ro $RUST /b/tt-server --addr 0.0.0.0:$p --cert /certs/server.pem --key /certs/server.key "$@" >/dev/null; }
srv ci-s1 18443 --min 1.3 --tls13 TLS_AES_128_GCM_SHA256
srv ci-s2 18444 --min 1.3 --tls13 TLS_CHACHA20_POLY1305_SHA256
srv ci-s4 18446 --groups X25519
docker run -d --name ci-etcd --network $N --network-alias etcd -e ETCD_ADVERTISE_CLIENT_URLS=http://etcd:2379 -e ETCD_LISTEN_CLIENT_URLS=http://0.0.0.0:2379 -e ALLOW_NONE_AUTHENTICATION=yes milvusdb/etcd:3.5.5-r2 >/dev/null
docker run -d --name ci-azurite --network $N --network-alias azurite -v $C:/c:ro mcr.microsoft.com/azure-storage/azurite:3.37.0 azurite-blob --blobHost 0.0.0.0 --blobPort 10000 --skipApiVersionCheck --loose --cert /c/azurite.pem --key /c/azurite.key >/dev/null
sleep 8
AZ='DefaultEndpointsProtocol=https;AccountName=devstoreaccount1;AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;BlobEndpoint=https://azurite:10000/devstoreaccount1;'
docker volume create ci-pip >/dev/null
docker run --rm --network $N -e REQUESTS_CA_BUNDLE=/c/bundle.pem -v $C:/c:ro -v ci-pip:/root/.local python:3.12-slim bash -c "pip install --user -q azure-storage-blob 'pymilvus>=2.6' 2>&1 | tail -1; python -c \"from azure.storage.blob import BlobServiceClient as B; B.from_connection_string('$AZ').create_container('milvus-v3'); print('container created over https')\""
if [ "${GDB:-0}" = 1 ]; then RUNMODE="--user root --cap-add=SYS_PTRACE --security-opt seccomp=unconfined -v $R/milvus-gdb.sh:/gdb.sh:ro --entrypoint bash $IMG /gdb.sh"; else RUNMODE="$IMG milvus run standalone"; fi
CORE="--ulimit core=-1 -v /tmp/cores:/tmp/cores -e GOTRACEBACK=crash${MILVUS_GODEBUG:+ -e GODEBUG=$MILVUS_GODEBUG}"
docker run -d --name ci-milvus $CORE --network $N --network-alias milvus -e ETCD_ENDPOINTS=etcd:2379 -e DEPLOY_MODE=STANDALONE -e USE_AZURITE=true -e "AZURE_STORAGE_CONNECTION_STRING=$AZ" -e SSL_CERT_FILE=/certs/bundle.pem \
  -v $R/user.yaml:/milvus/configs/user.yaml:ro -v $C:/certs:ro -v $C/bundle.pem:/etc/ssl/certs/ca-certificates.crt:ro $RUNMODE >/dev/null
for i in $(seq 120); do docker logs ci-milvus 2>&1 | grep -q 'Proxy successfully started\|Proxy wait for' && break; sleep 3; done; sleep 25
docker run --rm --network $N -e REQUESTS_CA_BUNDLE=/c/bundle.pem -v $C:/c:ro -v $C:/certs:ro -v ci-pip:/root/.local -v $R:/e python:3.12-slim python /e/${SMOKE:-smoke.py} 2>&1 | tee $OUT/smoke.txt | grep -E '^(OK|FAIL|RESULT)' | cut -c1-200
# Diagnostics: how the Milvus container ended up, and memory on the runner.
echo "milvus state: $(docker inspect ci-milvus --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} err={{.State.Error}} finished={{.State.FinishedAt}}' 2>&1)"
free -m | head -3; sudo dmesg 2>/dev/null | grep -iE "oom|killed process|segfault" | tail -5
docker logs ci-milvus 2>&1 | tail -15 | cut -c1-240
docker logs ci-milvus > $OUT/milvus.log 2>&1
PID=$(docker exec ci-milvus sh -c 'pidof milvus || pgrep milvus' | head -1); docker exec ci-milvus sh -c "grep -E 'ossl-modules|libssl|libcrypto' /proc/$PID/maps | awk '{print \$NF}' | sort -u" | tee $OUT/maps.txt
grep -E 'OpenSSL FIPS mode|FIPS strict' $OUT/milvus.log | head -2
for s in 1 2 4; do docker logs ci-s$s > $OUT/server$s.log 2>&1; echo "s$s: $(grep -m1 HANDSHAKE $OUT/server$s.log | cut -c1-110)"; done
E=$(grep -cE 'panic|\[ERROR\]' $OUT/milvus.log); echo "panic/ERROR lines: $E"; grep -E 'panic|\[ERROR\]' $OUT/milvus.log | head -5 | cut -c1-240
docker run -d --name ci-embed --network $N -e DEPLOY_MODE=STANDALONE -e ETCD_USE_EMBED=true $IMG milvus run standalone >/dev/null; sleep 30
docker logs ci-embed > $OUT/embed.log 2>&1; EMB=$(grep -c 'embedded etcd is not supported in this build' $OUT/embed.log); echo "embedded etcd refused: $EMB"
docker rm -f ci-etcd ci-azurite ci-milvus ci-embed ci-s1 ci-s2 ci-s4 >/dev/null 2>&1
grep -qE '^(RESULT|STRESS) PASS' $OUT/smoke.txt && [ "$E" = 0 ] && [ "$EMB" -ge 1 ]
