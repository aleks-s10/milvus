# usage: pw_check.py create | verify. Exits non-zero on any wrong result.
import logging, sys
logging.disable(logging.CRITICAL)
from pymilvus import MilvusClient
U, K = "https://127.0.0.1:19530", dict(server_pem_path="certs/ca.pem", server_name="localhost")
def ok(u, p):
    try:
        MilvusClient(uri=U, token=f"{u}:{p}", **K).list_collections(); return True
    except Exception:
        return False
r = MilvusClient(uri=U, token="root:Milvus", **K)
if sys.argv[1] == "create":
    r.create_user("legacy_bcrypt", "LegacyPass123!")
    sys.exit(0)
assert ok("legacy_bcrypt", "LegacyPass123!"), "bcrypt login after switch"
assert not ok("legacy_bcrypt", "nope12345"), "bcrypt wrong password"
r.create_user("pb_user", "PbkdfPass123!")
assert ok("pb_user", "PbkdfPass123!"), "pbkdf2 login"
assert not ok("pb_user", "wrong12345"), "pbkdf2 wrong password"
r.update_password("pb_user", "PbkdfPass123!", "NewPbkdf456!")
assert ok("pb_user", "NewPbkdf456!") and not ok("pb_user", "PbkdfPass123!"), "pbkdf2 change"
r.update_password("legacy_bcrypt", "LegacyPass123!", "Rotated789!")
assert ok("legacy_bcrypt", "Rotated789!") and not ok("legacy_bcrypt", "LegacyPass123!"), "bcrypt rotate"
print("password check OK")
