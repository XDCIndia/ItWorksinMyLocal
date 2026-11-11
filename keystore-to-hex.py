#!/usr/bin/env python3
"""Write the raw hex private key of a geth-format keystore account to a 0600 file.

usage: keystore-to-hex.py KEYSTORE_DIR ADDRESS PASSWORD_FILE OUT_FILE
       keystore-to-hex.py new KEYSTORE_DIR PASSWORD_FILE ADDRESS_FILE

`new` creates a fresh validator key as a standard v3 keystore (scrypt, geth
parameters) with a random password written to PASSWORD_FILE (0600), the address
to ADDRESS_FILE, and prints ONLY the address. The key and password are never printed.

erigon's --xdc.v1.signerkey wants a hex key file, not a keystore. The key is
only ever written to OUT_FILE (created 0600); it is never printed. Needs
python3 + openssl (AES-CTR); scrypt is in hashlib, the MAC check is a small
built-in keccak-256 so a wrong password fails here instead of yielding junk.
"""
import glob, hashlib, json, os, subprocess, sys

def keccak256(data):
    rc = [1,0x8082,0x800000000000808a,0x8000000080008000,0x808b,0x80000001,0x8000000080008081,0x8000000000008009,
          0x8a,0x88,0x80008009,0x8000000a,0x8000808b,0x800000000000008b,0x8000000000008089,0x8000000000008003,
          0x8000000000008002,0x8000000000000080,0x800a,0x800000008000000a,0x8000000080008081,0x8000000000008080,
          0x80000001,0x8000000080008008]
    rot = [[0,36,3,41,18],[1,44,10,45,2],[62,6,43,15,61],[28,55,25,21,56],[27,20,39,8,14]]
    M = (1 << 64) - 1
    rl = lambda x, n: ((x << n) | (x >> (64 - n))) & M if n else x
    def f(A):
        for r in range(24):
            C = [A[x][0]^A[x][1]^A[x][2]^A[x][3]^A[x][4] for x in range(5)]
            D = [C[(x-1)%5] ^ rl(C[(x+1)%5], 1) for x in range(5)]
            A = [[A[x][y]^D[x] for y in range(5)] for x in range(5)]
            B = [[0]*5 for _ in range(5)]
            for x in range(5):
                for y in range(5):
                    B[y][(2*x+3*y)%5] = rl(A[x][y], rot[x][y])
            A = [[B[x][y] ^ ((~B[(x+1)%5][y]) & B[(x+2)%5][y]) for y in range(5)] for x in range(5)]
            A[0][0] ^= rc[r]
        return A
    data = bytearray(data) + b"\x01"
    data += b"\x00" * ((-len(data)) % 136)
    data[-1] |= 0x80
    A = [[0]*5 for _ in range(5)]
    for off in range(0, len(data), 136):
        for i in range(17):
            A[i%5][i//5] ^= int.from_bytes(data[off+8*i:off+8*i+8], "little")
        A = f(A)
    return b"".join(A[i%5][i//5].to_bytes(8, "little") for i in range(4))

def main(ks, addr, pwfile, out):
    addr = addr.lower().replace("0x", "").replace("xdc", "")
    pw = open(pwfile, "rb").read().rstrip(b"\r\n")
    for path in sorted(glob.glob(os.path.join(ks, "*"))):
        try:
            j = json.load(open(path))
        except Exception:
            continue
        if str(j.get("address", "")).lower().replace("0x", "").replace("xdc", "") == addr:
            break
    else:
        sys.exit("keystore-to-hex: no keystore file for %s in %s" % (addr, ks))
    c = j.get("crypto") or j.get("Crypto")
    kp = c["kdfparams"]; salt = bytes.fromhex(kp["salt"])
    if c["kdf"] == "scrypt":
        dk = hashlib.scrypt(pw, salt=salt, n=kp["n"], r=kp["r"], p=kp["p"], dklen=kp["dklen"], maxmem=2**31 - 1)
    elif c["kdf"] == "pbkdf2":
        dk = hashlib.pbkdf2_hmac("sha256", pw, salt, kp["c"], kp["dklen"])
    else:
        sys.exit("keystore-to-hex: unsupported kdf %s" % c["kdf"])
    ct = bytes.fromhex(c["ciphertext"])
    if keccak256(dk[16:32] + ct).hex() != c["mac"].lower():
        sys.exit("keystore-to-hex: wrong password for %s" % path)
    key = subprocess.run(["openssl", "enc", "-d", "-aes-128-ctr", "-K", dk[:16].hex(), "-iv", c["cipherparams"]["iv"]],
                         input=ct, capture_output=True, check=True).stdout
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(key.hex() + "\n")
    os.chmod(out, 0o600)

def secp256k1_pub(d):
    P = 2**256 - 2**32 - 977
    N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    G = (0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
         0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8)
    def add(a, b):
        if a is None: return b
        if b is None: return a
        if a[0] == b[0] and (a[1] + b[1]) % P == 0: return None
        l = (3 * a[0] * a[0] * pow(2 * a[1], -1, P) if a == b else (b[1] - a[1]) * pow(b[0] - a[0], -1, P)) % P
        x = (l * l - a[0] - b[0]) % P
        return (x, (l * (a[0] - x) - a[1]) % P)
    r, q = None, G
    while d:
        if d & 1: r = add(r, q)
        q = add(q, q); d >>= 1
    return r

def new_key(ks, pwfile, addrfile):
    import secrets, time, uuid
    N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
    d = 0
    while not 0 < d < N:
        d = int.from_bytes(secrets.token_bytes(32), "big")
    x, y = secp256k1_pub(d)
    addr = keccak256(x.to_bytes(32, "big") + y.to_bytes(32, "big"))[12:].hex()
    pw = secrets.token_urlsafe(24).encode()
    salt, iv = secrets.token_bytes(32), secrets.token_bytes(16)
    dk = hashlib.scrypt(pw, salt=salt, n=262144, r=8, p=1, dklen=32, maxmem=2**31 - 1)
    ct = subprocess.run(["openssl", "enc", "-aes-128-ctr", "-K", dk[:16].hex(), "-iv", iv.hex()],
                        input=d.to_bytes(32, "big"), capture_output=True, check=True).stdout
    j = {"address": addr, "version": 3, "id": str(uuid.uuid4()),
         "crypto": {"cipher": "aes-128-ctr", "ciphertext": ct.hex(), "cipherparams": {"iv": iv.hex()},
                    "kdf": "scrypt", "kdfparams": {"dklen": 32, "n": 262144, "p": 1, "r": 8, "salt": salt.hex()},
                    "mac": keccak256(dk[16:32] + ct).hex()}}
    os.makedirs(ks, mode=0o700, exist_ok=True)
    os.chmod(ks, 0o700)
    def w(path, text):
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f: f.write(text)
    w(pwfile, pw.decode() + "\n")
    w(os.path.join(ks, "UTC--%s--%s" % (time.strftime("%Y-%m-%dT%H-%M-%S.000000000Z", time.gmtime()), addr)), json.dumps(j))
    w(addrfile, "0x" + addr + "\n")
    print("0x" + addr)

if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "new":
        new_key(*sys.argv[2:]); sys.exit(0)
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
