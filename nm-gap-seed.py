#!/usr/bin/env python3
"""Write the gap-block candidate pools a snap-started nethermind validator needs (XDC_GAP_SNAPSHOT_SEED).
usage: nm-gap-seed.py <out.json> [archive_rpc]   (archive_rpc defaults to https://earpc.apothem.network)

A node that starts from a snap pivot never executes the gap blocks (number % 900 == 450), but with header verification on (producer
mode) every epoch-switch header after the pivot needs the candidate pool of its gap block. This reads the 0x88 validator contract at
each gap block from an archive node over eth_call (getCandidates / getCandidateCap) and writes the file nethermind loads
(Nethermind.Xdc SnapshotManager.LoadSeeds). Covers 5 epochs below the tip up to the tip. Stdlib only."""
import json, sys, urllib.request

out = sys.argv[1]
url = sys.argv[2] if len(sys.argv) > 2 else "https://earpc.apothem.network"
V = "0x0000000000000000000000000000000000000088"
EPOCH, GAP = 900, 450

def rpc(batch):
    r = urllib.request.Request(url, json.dumps(batch).encode(), {"content-type": "application/json", "user-agent": "iwml-join/1"})
    res = json.load(urllib.request.urlopen(r, timeout=120))
    if isinstance(res, list):
        res = sorted(res, key=lambda x: x["id"])
        for x in res:
            if "error" in x: raise SystemExit("archive error: %s" % x["error"])
        return [x["result"] for x in res]
    if "error" in res: raise SystemExit("archive error: %s" % res["error"])
    return res["result"]

def one(method, params): return rpc({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})

tip = int(one("eth_blockNumber", []), 16) - 2
gaps = [g for g in range(tip - 5 * EPOCH, tip + 1) if g % EPOCH == EPOCH - GAP]
seed = []
for g in gaps:
    blk = hex(g)
    raw = one("eth_call", [{"to": V, "data": "0x06a49fce"}, blk])[2:]
    n = int(raw[64:128], 16)
    cands = ["0x" + raw[128 + 64 * i + 24:128 + 64 * (i + 1)] for i in range(n)]
    cands = [c for c in cands if int(c, 16) != 0]
    caps = rpc([{"jsonrpc": "2.0", "id": i, "method": "eth_call", "params": [{"to": V, "data": "0x58e7525f" + "0" * 24 + c[2:]}, blk]}
                for i, c in enumerate(cands)])
    hdr = one("eth_getBlockByNumber", [blk, False])
    seed.append({"number": g, "hash": hdr["hash"], "candidates": [{"address": c, "cap": str(int(v, 16))} for c, v in zip(cands, caps)]})
    print(g, len(cands), "candidates", file=sys.stderr)
json.dump(seed, open(out, "w"))
