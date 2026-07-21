import json, collections

SCRATCH = "/tmp/claude-0/-mnt-data-workspace-go-ethereum/97391504-f466-4896-88be-26413f9290f1/scratchpad"
STAGE = SCRATCH + "/net5151-parity-v2"

base = json.load(open(STAGE + "/genesis-5151-puppeth-base.json"), object_pairs_hook=collections.OrderedDict)
mainnet = json.load(open(SCRATCH + "/mainnet-genesis-github.json"))

# addresses
def addr(role):
    return open(STAGE + f"/keys/{role}/address.txt").read().strip().lower().replace("0x","")

treasury = addr("treasury")
clients = {
    "moderngeth": addr("clients/moderngeth"),
    "erigon": addr("clients/erigon"),
    "xone": addr("clients/xone"),
}

# --- config: rename xdpos -> XDPoS, add full fork feature set ---
cfg = base["config"]
xdpos = cfg.pop("xdpos")
cfg["XDPoS"] = xdpos

# pre-Byzantium: match mainnet's real small block numbers exactly (no staircase needed, already tiny)
cfg["homesteadBlock"] = 1
cfg["eip150Block"] = 2
cfg["eip150Hash"] = "0x0000000000000000000000000000000000000000000000000000000000000000"
cfg["eip155Block"] = 3
cfg["eip158Block"] = 3
cfg["byzantiumBlock"] = 4

# devnet-staircased blocks per task spec (feature set matches mainnet; block numbers deviate, documented)
cfg["constantinopleBlock"] = 4
cfg["petersburgBlock"] = 4
cfg["istanbulBlock"] = 4
cfg["berlinBlock"] = 450
cfg["londonBlock"] = 450
cfg["mergeBlock"] = 450
cfg["shanghaiBlock"] = 450
cfg["eip1559Block"] = 2250
cfg["cancunBlock"] = 3150

# XDC-specific "tip*" behavioural toggles (mirrors current net5151-legacy fleet
# devnet convention; feature set present, block numbers staircased — see parity
# report for the network_constants.go hardcoded-table caveat: only tipSigningBlock
# has an honored genesis override on this binary, the rest are governed by the
# per-chainId table in consensus/XDPoS/network_constants.go regardless of these
# JSON values, unless/until a code change adds an override or a net5151 table entry)
cfg["tip2019Block"] = 1
cfg["tipSigningBlock"] = 4
cfg["tipRandomizeBlock"] = 4
cfg["tipIncreaseMasternodesBlock"] = 4
cfg["denylistBlock"] = 4
cfg["tipXDCXBlock"] = 100
cfg["tipXDCXLendingBlock"] = 100
cfg["tipXDCXCancellationFeeBlock"] = 100
cfg["tipNoHalvingMNRewardBlock"] = 100
cfg["tipXDCXMinerDisableBlock"] = 450
cfg["tipXDCXReceiverDisableBlock"] = 450
cfg["gas50xBlock"] = 450
cfg["tipTRC21FeeBlock"] = 450

# v2: fill in mainnet round-0 ExpTimeoutConfig exactly (puppeth doesn't prompt for it)
cfg["XDPoS"]["v2"]["config"]["expTimeoutConfig"] = {"base": 1.0, "maxExponent": 0}
cfg["XDPoS"]["v2"]["allConfigs"]["0"]["expTimeoutConfig"] = {"base": 1.0, "maxExponent": 0}
cfg["XDPoS"]["v2"]["switchEpoch"] = 2

# --- header fields: gasLimit/difficulty already correct from puppeth (0x47b760 / 0x1) ---
# nonce/mixHash/coinbase already zero-valued to match mainnet convention.

# --- alloc: mirror mainnet system-contract deployments byte-for-byte, replace
# mainnet's pre-mine holder with OUR treasury (same total supply), fund the 3
# client coinbases out of that same envelope so total genesis supply is
# bit-identical to mainnet (37,500,000,000 XDC). ---
mainnet_alloc = mainnet["alloc"]

def strip0x(a):
    return a.lower().replace("0x", "").replace("xdc", "")

m = { strip0x(k): v for k, v in mainnet_alloc.items() }

SYSTEM_CONTRACTS = [
    "0000000000000000000000000000000000000088",  # XDCValidator
    "0000000000000000000000000000000000000089",  # BlockSigner
    "0000000000000000000000000000000000000090",  # Randomize
    "0000000000000000000000000000000000000099",  # (MultiSig/other system contract)
    "746249c61f5832c5eed53172776b460491bdcd5c",   # mirrored deployed contract (matches 0x99's code/storage on mainnet)
]

WEI = 10**18
XDC_88_BALANCE = int(m["0000000000000000000000000000000000000088"]["balance"], 16)  # 30,000,000 XDC — mirror exactly
TOTAL_SUPPLY_WEI = sum(int(v.get("balance", "0x0"), 16) for v in mainnet_alloc.values())  # 37,500,000,000 XDC
CLIENT_FUND_XDC = 1000  # small gas allowance per client coinbase, documented deviation carved OUT of treasury so total supply stays identical to mainnet
CLIENT_FUND_WEI = CLIENT_FUND_XDC * WEI

alloc = collections.OrderedDict()
alloc["0000000000000000000000000000000000000000"] = {"balance": "0x0"}
alloc["0000000000000000000000000000000000000001"] = {"balance": "0x0"}

for scaddr in SYSTEM_CONTRACTS:
    src = m[scaddr]
    entry = {}
    if "code" in src and src["code"]:
        entry["code"] = src["code"]
    if "storage" in src and src["storage"]:
        entry["storage"] = src["storage"]
    bal = int(src.get("balance", "0x0"), 16)
    entry["balance"] = hex(bal)
    alloc[scaddr] = entry

treasury_balance_wei = TOTAL_SUPPLY_WEI - XDC_88_BALANCE - 3 * CLIENT_FUND_WEI
alloc[treasury] = {"balance": hex(treasury_balance_wei)}

for role, a in clients.items():
    alloc[a] = {"balance": hex(CLIENT_FUND_WEI)}

base["alloc"] = alloc

# sanity: recompute total and compare
computed_total = sum(int(v["balance"], 16) for v in alloc.values())
assert computed_total == TOTAL_SUPPLY_WEI, (computed_total, TOTAL_SUPPLY_WEI)

out_path = STAGE + "/genesis-5151-parity-v2.json"
with open(out_path, "w") as f:
    json.dump(base, f, indent=2)
    f.write("\n")

print("wrote", out_path)
print("TOTAL_SUPPLY_WEI", TOTAL_SUPPLY_WEI, "= XDC", TOTAL_SUPPLY_WEI/1e18)
print("treasury balance XDC", treasury_balance_wei/1e18)
print("XDCValidator(0x88) balance XDC", XDC_88_BALANCE/1e18)
print("client fund XDC each", CLIENT_FUND_XDC)
