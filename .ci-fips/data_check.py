# Insert, index, load, search and delete. Exits non-zero on any wrong result.
import logging, random, sys, time
logging.disable(logging.CRITICAL)
from pymilvus import MilvusClient, DataType
random.seed(7)
c = MilvusClient(uri="https://127.0.0.1:19530", token="root:Milvus", server_pem_path="certs/ca.pem", server_name="localhost")
n = "fips_ci"
s = c.create_schema(auto_id=False)
s.add_field("id", DataType.INT64, is_primary=True)
s.add_field("tag", DataType.VARCHAR, max_length=32)
s.add_field("vec", DataType.FLOAT_VECTOR, dim=64)
c.create_collection(n, schema=s)
N = 20000
rows = [{"id": i, "tag": f"t{i%7}", "vec": [random.random() for _ in range(64)]} for i in range(N)]
for i in range(0, N, 5000):
    c.insert(n, rows[i:i+5000])
c.flush(n)
assert int(c.get_collection_stats(n)["row_count"]) == N, "row count after flush"
ip = c.prepare_index_params()
ip.add_index("vec", index_type="HNSW", metric_type="L2", params={"M": 8, "efConstruction": 64})
ip.add_index("tag", index_type="INVERTED")
c.create_index(n, ip)
for _ in range(300):
    d = c.describe_index(n, "vec")
    if d.get("state") == "Finished" and int(d.get("pending_index_rows", 0)) == 0:
        break
    time.sleep(2)
assert d.get("state") == "Finished" and int(d.get("indexed_rows", 0)) == N, f"index {d}"
c.load_collection(n)
q = random.sample(range(N), 200)
hit = 0
for i in range(0, 200, 50):
    ids = q[i:i+50]
    r = c.search(n, data=[rows[j]["vec"] for j in ids], limit=1, search_params={"params": {"ef": 256}})
    hit += sum(1 for j, h in zip(ids, r) if h and h[0]["id"] == j)
print(f"self-recall at ef=256: {hit}/200")
assert hit >= 170, "self-recall too low"
got = c.query(n, filter="id in [1,2]", output_fields=["tag"], consistency_level="Strong")
assert sorted(x["tag"] for x in got) == ["t1", "t2"], f"query {got}"
c.delete(n, filter="id == 1")
c.release_collection(n); c.load_collection(n)
got = c.query(n, filter="id in [1,2]", output_fields=["id"], consistency_level="Strong")
assert [x["id"] for x in got] == [2], f"after delete {got}"
print("data check OK")
