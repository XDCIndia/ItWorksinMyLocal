#!/usr/bin/env python3
"""Onboard erigon as a masternode on net5151: fund -> uploadKYC -> propose.
Replicates the proven geth flow. DRY_RUN builds+signs+verifies, sends nothing.
Run with SEND=1 env to actually broadcast."""
import json, os, sys, time, urllib.request
from eth_account import Account

RPC = "http://127.0.0.1:9551"
CHAIN_ID = 5151
GAS_PRICE = 12_500_000_000            # 12.5 gwei = XDCBaseFee (matches proven txs)
MASTERNODE_SC = "0x0000000000000000000000000000000000000088"
DEPOSIT = 10_000_000 * 10**18         # 10M XDC (0x084595161401484a000000)
FUND_EXTRA = 100 * 10**18             # +100 XDC for gas headroom
VAULT = "/root/net5151-legacy/vault"
SUPPLY_KS = "/root/net5151-legacy/supply-keys/supply1.json"
SUPPLY_PW = os.environ.get("SUPPLY_PW", "")  # set via env; keys live in the vault, never in-repo
PW = os.environ.get("OWNER_PW", "")  # set via env; keys live in the vault, never in-repo
ERIGON_CB = "0x0300d5E22B5E732A7Cd576fFb9C95a43a282202a"  # geth coinbase
OWNER_KS = f"{VAULT}/moderngeth/owner-propose/owner-keystore.json"
KYC_NAME = "moderngeth"
SEND = os.environ.get("SEND") == "1"

def rpc(method, params):
    req = urllib.request.Request(RPC, json.dumps({"jsonrpc":"2.0","method":method,"params":params,"id":1}).encode(),
                                 {"Content-Type":"application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=15))
    if "error" in r: raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]

def load_key(path, pw):
    with open(path) as f: ks = json.load(f)
    return Account.from_key(Account.decrypt(ks, pw))

def nonce(addr): return int(rpc("eth_getTransactionCount", [addr, "latest"]), 16)
def bal(addr):   return int(rpc("eth_getBalance", [addr, "latest"]), 16)

def sign(priv, to, value, data, n, gas):
    tx = {"nonce":n,"gasPrice":GAS_PRICE,"gas":gas,"to":to,"value":value,"data":data,"chainId":CHAIN_ID}
    return Account.sign_transaction(tx, priv).raw_transaction.hex()

def send_wait(raw, label):
    h = rpc("eth_sendRawTransaction", ["0x"+raw if not raw.startswith("0x") else raw])
    print(f"  [{label}] sent tx {h}")
    for _ in range(60):
        rc = rpc("eth_getTransactionReceipt", [h])
        if rc:
            ok = int(rc["status"],16)==1
            print(f"  [{label}] receipt status={'OK' if ok else 'FAIL'} block={int(rc['blockNumber'],16)} gasUsed={int(rc['gasUsed'],16)}")
            if not ok: raise RuntimeError(f"{label} tx reverted")
            return
        time.sleep(2)
    raise RuntimeError(f"{label}: no receipt in 120s")

# --- load / create accounts ---
supply = load_key(SUPPLY_KS, SUPPLY_PW)
print(f"supply  = {supply.address}  bal={bal(supply.address)/1e18:,.2f} XDC")
assert supply.address.lower() == "0x8C92b684577529Fb7dE473f19eAc814eddb7263e".lower()

os.makedirs(os.path.dirname(OWNER_KS), exist_ok=True)
if os.path.exists(OWNER_KS):
    owner = load_key(OWNER_KS, PW)
    print(f"owner   = {owner.address} (existing)")
else:
    owner = Account.create()
    with open(OWNER_KS, "w") as f: json.dump(Account.encrypt(owner.key, PW), f)
    print(f"owner   = {owner.address} (NEW, keystore written)")

cb = ERIGON_CB
print(f"erigon-cb = {cb}  bal={bal(cb)/1e18:,.2f} XDC")

# --- build data payloads ---
name_hex = KYC_NAME.encode().hex()
name_padded = name_hex + "0"*(64-len(name_hex))
kyc_data = ("0xf5c95125"
    + "0000000000000000000000000000000000000000000000000000000000000020"
    + f"{len(KYC_NAME):064x}"
    + name_padded)
propose_data = "0x01267951" + "0"*24 + cb[2:].lower()
print(f"\nKYC data     = {kyc_data}")
print(f"PROPOSE data = {propose_data}")
print(f"PROPOSE value= {DEPOSIT} wei = {DEPOSIT/1e18:,.0f} XDC")

# --- verify not already candidate ---
isc = rpc("eth_call", [{"to":MASTERNODE_SC,"data":"0xd51b9e93"+"0"*24+cb[2:].lower()},"latest"])
print(f"isCandidate(erigon) currently = {int(isc,16)} (expect 0)")

# --- build the 3 signed txs (nonces sequential) ---
sn = nonce(supply.address); on = nonce(owner.address)
fund_amt = DEPOSIT + FUND_EXTRA
fund_raw    = sign(supply.key, owner.address, fund_amt, "0x", sn, 21000)
kyc_raw     = sign(owner.key, MASTERNODE_SC, 0, kyc_data, on, 200000)
propose_raw = sign(owner.key, MASTERNODE_SC, DEPOSIT, propose_data, on+1, 300000)
print(f"\nfund:    supply n={sn} -> owner {fund_amt/1e18:,.0f} XDC")
print(f"kyc:     owner  n={on} uploadKYC('{KYC_NAME}')")
print(f"propose: owner  n={on+1} propose({cb}) value 10M")

if not SEND:
    print("\n== DRY RUN (SEND!=1): nothing broadcast. Signed txs built OK. ==")
    sys.exit(0)

print("\n== SENDING ==")
send_wait(fund_raw, "fund")
print(f"  owner bal now = {bal(owner.address)/1e18:,.2f} XDC")
send_wait(kyc_raw, "kyc")
send_wait(propose_raw, "propose")
isc = rpc("eth_call", [{"to":MASTERNODE_SC,"data":"0xd51b9e93"+"0"*24+cb[2:].lower()},"latest"])
print(f"\nisCandidate(erigon) = {int(isc,16)} (expect 1)")
print(f"owner bal = {bal(owner.address)/1e18:,.2f} XDC  (deposit locked in 0x88)")
print("DONE — erigon proposed. Seats at next epoch boundary (block % 900 == 0).")
