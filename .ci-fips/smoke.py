# Integrated 3.0 smoke: PBKDF2 login, OpenSSL tokenizer TLS, Lindera/BM25, storage v3 on Azurite over HTTPS.
import sys, time, random, json, urllib.request, signal
signal.signal(signal.SIGALRM, lambda *a: (print("RESULT FAIL timeout (25 min)", flush=True), sys.exit(2)))
signal.alarm(1500)
from pymilvus import MilvusClient, DataType, Function, FunctionType
from azure.storage.blob import BlobServiceClient
AZ = ("DefaultEndpointsProtocol=https;AccountName=devstoreaccount1;"
      "AccountKey=Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==;"
      "BlobEndpoint=https://azurite:10000/devstoreaccount1;")
results = []
def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"{'OK  ' if ok else 'FAIL'} {name} {detail}", flush=True)
def metrics(pattern):
    body = urllib.request.urlopen("http://milvus:9091/metrics", timeout=10).read().decode()
    out = {}
    for line in body.splitlines():
        if line.startswith("#") or not any(p in line for p in pattern.split("|")):
            continue
        k, v = line.rsplit(" ", 1)
        out[k] = float(v)
    return out

# --- PBKDF2 login
root = MilvusClient("http://milvus:19530", token="root:Milvus")
if "alice" in root.list_users(): root.drop_user("alice")
root.create_user("alice", "Fips-Pass-1234")
try:
    MilvusClient("http://milvus:19530", token="alice:Fips-Pass-1234").list_collections(); check("login with new pbkdf2 user", True)
except Exception as e:
    check("login with new pbkdf2 user", False, str(e)[:200])
try:
    MilvusClient("http://milvus:19530", token="alice:wrong-password").list_collections(); check("wrong password refused", False)
except Exception as e:
    check("wrong password refused", True, str(e)[:120])
root.update_password("alice", "Fips-Pass-1234", "Fips-Pass-5678")
try:
    MilvusClient("http://milvus:19530", token="alice:Fips-Pass-5678").list_collections(); check("login after password update", True)
except Exception as e:
    check("login after password update", False, str(e)[:200])

# --- tokenizer TLS through OpenSSL (strict)
def ana(port):
    return {"tokenizer": {"type": "grpc", "endpoint": f"https://tokenizer.test:{port}", "tls": {"ca_cert": "/certs/ca.pem"}}}
def tok(label, port, expect_ok):
    try:
        r = root.run_analyzer(["hello fips world"], analyzer_params=ana(port)); check(label, expect_ok, f"tokens={str(r)[:120]}")
    except Exception as e:
        check(label, not expect_ok, f"refused: {str(e)[:200]}")
tok("https tokenizer aes-gcm tls1.3", 18443, True)
tok("https tokenizer chacha-only refused", 18444, False)
tok("https tokenizer x25519-only refused", 18446, False)

# --- Lindera download (OpenSSL) + BM25
try:
    r = root.run_analyzer(["東京都に住んでいます"], analyzer_params={"tokenizer": {"type": "lindera", "dict_kind": "ipadic"}})
    check("lindera ipadic download+tokenize", "東京" in str(r), str(r)[:120])
except Exception as e:
    check("lindera ipadic download+tokenize", False, str(e)[:300])
name = "int_bm25"
if root.has_collection(name): root.drop_collection(name)
s = root.create_schema(auto_id=False)
s.add_field("id", DataType.INT64, is_primary=True)
s.add_field("text", DataType.VARCHAR, max_length=512, enable_analyzer=True, enable_match=True, analyzer_params={"tokenizer": {"type": "lindera", "dict_kind": "ipadic"}})
s.add_field("sparse", DataType.SPARSE_FLOAT_VECTOR)
s.add_function(Function(name="bm25", function_type=FunctionType.BM25, input_field_names=["text"], output_field_names=["sparse"]))
ip = root.prepare_index_params(); ip.add_index("sparse", index_type="SPARSE_INVERTED_INDEX", metric_type="BM25")
root.create_collection(name, schema=s, index_params=ip, consistency_level="Strong")
root.insert(name, [{"id": i, "text": f"今日は天気がいいです{i}"} for i in range(50)] + [{"id": 1000, "text": "富士山に登りました"}]); root.flush(name); root.load_collection(name)
r = root.search(name, data=["富士山"], anns_field="sparse", limit=3, output_fields=["id"], search_params={"metric_type": "BM25"})
check("bm25 search (lindera)", r and r[0] and r[0][0]["id"] == 1000, str([h["id"] for h in r[0]]))
q = root.query(name, filter="TEXT_MATCH(text, '富士山')", output_fields=["id"])
check("text-match (lindera)", [x["id"] for x in q] == [1000], str(q))
root.release_collection(name); root.drop_collection(name)

# --- storage v3 Parquet + tiered storage on Azurite over HTTPS
c = MilvusClient("http://milvus:19530", token="root:Milvus")
DIM = 32
NAME = "v3_azurite"
if c.has_collection(NAME):
    c.drop_collection(NAME)
s = MilvusClient.create_schema(auto_id=False)
s.add_field("id", DataType.INT64, is_primary=True)
s.add_field("tag", DataType.VARCHAR, max_length=64)
s.add_field("note", DataType.TEXT, nullable=True)
s.add_field("vec", DataType.FLOAT_VECTOR, dim=DIM)
c.create_collection(NAME, schema=s, consistency_level="Strong")
rng = random.Random(7)
N, ROUNDS = 3000, 3
vecs = {}
for r in range(ROUNDS):
    rows = []
    for i in range(N):
        pk = r * N + i
        v = [rng.random() for _ in range(DIM)]
        vecs[pk] = v
        rows.append({"id": pk, "tag": f"t{pk % 10}", "note": f"short text {pk}", "vec": v})
    c.insert(NAME, rows)
    c.flush(NAME)
check("insert+flush", c.get_collection_stats(NAME)["row_count"] == N * ROUNDS, str(c.get_collection_stats(NAME)))

ip = c.prepare_index_params()
ip.add_index("vec", index_type="HNSW", metric_type="L2", params={"M": 16, "efConstruction": 64})
c.create_index(NAME, ip)
c.load_collection(NAME)

def search_ok(label):
    probe = [1234, 4321, 8000]
    res = c.search(NAME, data=[vecs[p] for p in probe], limit=3, output_fields=["tag", "note"], search_params={"ef": 64})
    hits = [r[0]["id"] for r in res]
    note_ok = all(r[0]["entity"]["note"] == f"short text {r[0]['id']}" for r in res)
    check(f"search {label}", hits == probe and note_ok, f"top1={hits}")
    q = c.query(NAME, filter="tag == 't3'", output_fields=["count(*)"])
    check(f"query {label}", q[0]["count(*)"] == N * ROUNDS // 10, str(q))

search_ok("after load")

# Blobs written by this run: Parquet only, no Vortex.
bs = BlobServiceClient.from_connection_string(AZ)
cc = bs.get_container_client("milvus-v3")
names = [b.name for b in cc.list_blobs()]
data = [n for n in names if "/insert_log/" in n or "_data/" in n]
magic = {}
for n in data:
    head = cc.download_blob(n, offset=0, length=4).readall()
    magic[head] = magic.get(head, 0) + 1
print("blobs total", len(names), "data", len(data), "magic", {k.hex(): v for k, v in magic.items()}, flush=True)
print("sample", [n for n in names if "manifest" in n][:2], data[:3], flush=True)
# Manifests and metadata are Avro ("Obj\x01") and JSON; column data must be Parquet, never Vortex.
check("column data is Parquet, no Vortex", magic.get(b"PAR1", 0) > 0 and magic.get(b"VTXF", 0) == 0,
      f"PAR1={magic.get(b'PAR1', 0)} VTXF={magic.get(b'VTXF', 0)} other={ {k.hex(): v for k, v in magic.items() if k not in (b'PAR1', b'VTXF')} }")
check("manifest present (storage v3)", any("manifest" in n for n in names))

# Tiered storage: wait past cacheTtl so cells are evicted, then search again (reload from Azurite).
PAT = "cach|evict|cell"
before = metrics(PAT)
print("cache metric names:", sorted({k.split("{")[0] for k in before})[:40], flush=True)
time.sleep(25)
search_ok("after TTL eviction")
after = metrics(PAT)
delta = {k: after[k] - before.get(k, 0) for k in after if after[k] - before.get(k, 0) != 0}
ev = {k: v for k, v in delta.items() if "evict" in k.lower()}
loads = {k: v for k, v in delta.items() if any(t in k.lower() for t in ("load", "miss", "insert"))}
print("all cache metric deltas", json.dumps(delta)[:1500], flush=True)
print("eviction metric deltas", json.dumps(ev)[:900], flush=True)
print("load/miss metric deltas", json.dumps(loads)[:900], flush=True)
check("cache cells evicted", len(ev) > 0)
check("cells reloaded after eviction", len(loads) > 0)

c.release_collection(NAME)
c.load_collection(NAME)
search_ok("after release+reload")

# A TEXT value above the 64 KiB inline threshold needs a Vortex LOB file.
long_row = {"id": 10**9, "tag": "big", "note": "x" * (70 * 1024), "vec": [0.5] * DIM}
try:
    c.insert(NAME, [long_row]); c.flush(NAME)
    q = c.query(NAME, filter="id == 1000000000", output_fields=["note"])
    got = len(q[0]["note"]) if q else None
    print("long TEXT result:", got, flush=True)
    check("long TEXT (70 KiB) stored", got == 70 * 1024, f"len={got}")
except Exception as e:
    print("long TEXT error:", str(e)[:400], flush=True)
    check("long TEXT (70 KiB) stored", False, "exception: server unavailable means the datanode crashed")

bad = [n for n, ok in results if not ok]
print("RESULT", "PASS" if not bad else "FAIL", f"{len(results)-len(bad)}/{len(results)}", bad)
