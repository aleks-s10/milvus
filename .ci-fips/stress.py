# Fork test branch only: hammer the PBKDF2 password paths (create, verify, change) to reproduce
# an intermittent Milvus segfault that so far always follows a password operation.
import sys, time
from pymilvus import MilvusClient
U = "http://milvus:19530"
root = MilvusClient(U, token="root:Milvus")
pw = "Fips-Pass-0000"
if "stress" in root.list_users(): root.drop_user("stress")
root.create_user("stress", pw)
start = time.time()
for i in range(1, 61):
    try:
        MilvusClient(U, token=f"stress:{pw}").list_collections()        # verify (new connection)
        try:
            MilvusClient(U, token="stress:wrong-password").list_collections()
        except Exception:
            pass                                                         # refused, as expected
        new = f"Fips-Pass-{i:04d}"
        root.update_password("stress", pw, new); pw = new                # hash a new password
    except Exception as e:
        print(f"STRESS FAIL at iteration {i} after {time.time()-start:.0f}s: {str(e)[:200]}", flush=True)
        sys.exit(1)
    if i % 10 == 0:
        print(f"stress: {i} iterations ok ({time.time()-start:.0f}s)", flush=True)
print("STRESS PASS 60 iterations", flush=True)
