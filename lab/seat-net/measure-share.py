#!/usr/bin/env python3
"""measure-share.py — the corrected per-signer distribution measurement.

Ported from /data/mint-r3/netv12/measure_share_v2.py (the CORRECTED version).
Do NOT carry over the older measure_share.py's `height % len(masternodes)`
in-turn ordering -- that is the WRONG slot ordering for XDPoS V1. This file
uses PARENT-RELATIVE HOP ordering, which is what calcDifficultyVariable
actually implements: the in-turn signer for block H is the masternode one hop
after the PARENT's sealer (not a fixed function of H alone).

Two things this script gets right that a naive re-implementation would not:

1. In-turn slots computed from parent-relative hop ordering (see above), not
   `height % len(masternodes)`.
2. Every sealer is recovered by ecrecovering the V1 seal out of `extraData`.
   The `miner` field is the ZERO address on XDPoS V1 blocks; NEVER use it as
   an attribution source. This script never consults an RPC-reported "miner"
   / "coinbase" field for attribution -- only the ecrecovered seal.

This script is READ-ONLY. It never sends a transaction and never needs a
private key. It is safe to run against a live net at any time.

This script is height-gated V1/V2 aware, matching the live-verified
_assert_block_miner logic in /data/mint-r3/lab/lib-assert.sh (the one
gate-erigon.sh used to GATE-PROVE erigon's V2 mint at block 4072): below
V2SWITCH_BLOCK a block's seal is recovered from the V1 extraData tail; at or
above it, from the separate `validator` header field per engine_v2/utils.go
(Extra NOT truncated; sigHash additionally covers `validators`/`penalties`).
Falls back V2 -> V1 -> raw miner (only if miner isn't the zero address) so a
misclassified block never silently reports as unrecovered.

Usage:
  measure-share.py <rpc> <lo> <hi> [target_addr] [epoch] [v2switch_block]

  <rpc>          JSON-RPC endpoint to read canonical blocks from. Should be
                 one of the ARBITER RPCs (or an independent observer) --
                 NEVER the candidate's own RPC, which is not an admissible
                 attribution source (see gate-mint.sh, which enforces this
                 in code, not just by convention).
  <lo> <hi>      inclusive block range to measure over.
  [target_addr]  lowercase the share of this address is highlighted for
                 (optional -- if omitted, only the full distribution and
                 in-turn-adoption tables are printed, no single-target line).
  [epoch]        epoch length for locating the checkpoint extraData that
                 carries the authoritative masternode set (default 900).
  [v2switch_block] height at/after which blocks are recovered with V2 signer
                 rules (default: a sentinel so far out every block is
                 treated as V1 -- pass your net's real V2 switch height, e.g.
                 netv12's 1800, or every post-switch block will misreport).

Exit codes: 0 on success. Non-zero (with a message) if the RPC's head does
not yet cover [lo, hi] -- this script REFUSES to silently report a share
over a shorter window than requested (see require_head_covers below).
"""
import json, sys, urllib.request
from collections import Counter, defaultdict

from eth_utils import keccak
from eth_keys.datatypes import Signature

if len(sys.argv) < 4:
    sys.exit(__doc__)

RPC = sys.argv[1]
LO = int(sys.argv[2])
HI = int(sys.argv[3])
TARGET = (sys.argv[4].lower() if len(sys.argv) > 4 and sys.argv[4] else None)
EPOCH = int(sys.argv[5]) if len(sys.argv) > 5 else 900
V2SWITCH = int(sys.argv[6]) if len(sys.argv) > 6 and sys.argv[6] else 9223372036854775807


def rpc(method, params):
    req = urllib.request.Request(
        RPC,
        data=json.dumps({"jsonrpc": "2.0", "method": method,
                         "params": params, "id": 1}).encode(),
        headers={"Content-Type": "application/json"})
    out = json.loads(urllib.request.urlopen(req, timeout=15).read())
    if "error" in out:
        raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]


def h2b(s):
    s = s or '0x'
    return bytes.fromhex(s[2:] if s.startswith('0x') else s)


def require_head_covers(hi):
    """Refuse to measure a window the node cannot fully serve.

    Without this, a HI above the current head silently yields a SHORT window
    and the share percentages below would be computed over fewer blocks than
    asked for -- which is exactly how a fair-share number gets quietly
    misreported.
    """
    head = int(rpc("eth_blockNumber", []), 16)
    if head < hi:
        sys.exit(f"REFUSING TO MEASURE: head={head} < requested HI={hi}. "
                 f"Wait for the chain to reach {hi} (or pass HI<={head}).")
    return head


def rlp_bytes(b):
    if len(b) == 1 and b[0] < 0x80:
        return b
    if len(b) <= 55:
        return bytes([0x80 + len(b)]) + b
    lb = len(b).to_bytes((len(b).bit_length() + 7) // 8 or 1, 'big')
    return bytes([0xb7 + len(lb)]) + lb + b


def rlp_int(v):
    if v == 0:
        return rlp_bytes(b'')
    return rlp_bytes(v.to_bytes((v.bit_length() + 7) // 8, 'big'))


def rlp_list(items):
    p = b''.join(items)
    if len(p) <= 55:
        return bytes([0xc0 + len(p)]) + p
    lb = len(p).to_bytes((len(p).bit_length() + 7) // 8 or 1, 'big')
    return bytes([0xf7 + len(lb)]) + lb + p


def recover(mh, sig):
    if len(sig) != 65:
        return None
    r = int.from_bytes(sig[0:32], 'big')
    s = int.from_bytes(sig[32:64], 'big')
    v = sig[64]
    try:
        pub = Signature(vrs=(v, r, s)).recover_public_key_from_msg_hash(mh)
    except Exception:
        return None
    return '0x' + keccak(pub.to_bytes())[-20:].hex()


def _common_fields(b):
    return (h2b(b['parentHash']), h2b(b.get('sha3Uncles', '0x')), h2b(b['miner']),
            h2b(b['stateRoot']), h2b(b['transactionsRoot']), h2b(b['receiptsRoot']),
            h2b(b['logsBloom']), int(b['difficulty'], 16), int(b['number'], 16),
            int(b['gasLimit'], 16), int(b['gasUsed'], 16), int(b['timestamp'], 16),
            h2b(b['mixHash']), h2b(b['nonce']))


def signer_v1(b):
    """ecrecover the V1 seal: last 65 bytes of extraData over the sigHash
    (header RLP with the 65-byte seal stripped from extraData). NEVER use
    b['miner'] for attribution -- it is the zero address on XDPoS V1."""
    extra = h2b(b['extraData'])
    if len(extra) < 65:
        return None
    sig = extra[-65:]
    parent, uncle, coinbase, root, txroot, rroot, bloom, diff, num, gl, gu, ts, mix, nonce = _common_fields(b)
    items = [
        rlp_bytes(parent), rlp_bytes(uncle), rlp_bytes(coinbase), rlp_bytes(root),
        rlp_bytes(txroot), rlp_bytes(rroot), rlp_bytes(bloom), rlp_int(diff),
        rlp_int(num), rlp_int(gl), rlp_int(gu), rlp_int(ts),
        rlp_bytes(extra[:-65]), rlp_bytes(mix), rlp_bytes(nonce),
    ]
    if b.get('baseFeePerGas'):
        items.append(rlp_int(int(b['baseFeePerGas'], 16)))
    return recover(keccak(rlp_list(items)), sig)


def signer_v2(b):
    """ecrecover the V2 (post-switch, HotStuff) seal: engine_v2/utils.go
    sigHash -- extraData is NOT truncated (no seal embedded in it); the
    signature lives in the separate `validator` header field, and the hash
    additionally covers `validators`/`penalties`. Height-gated by V2SWITCH,
    not by whether `validator` happens to be populated -- some oldxdc builds
    stamp a non-empty `validator` field on EVERY block including V1 ones, so
    "validator present => V2" is a false heuristic (see
    /data/mint-r3/lab/lib-assert.sh's _assert_block_miner comment)."""
    sig = h2b(b.get('validator', '0x'))
    if len(sig) != 65:
        return None
    parent, uncle, coinbase, root, txroot, rroot, bloom, diff, num, gl, gu, ts, mix, nonce = _common_fields(b)
    items = [
        rlp_bytes(parent), rlp_bytes(uncle), rlp_bytes(coinbase), rlp_bytes(root),
        rlp_bytes(txroot), rlp_bytes(rroot), rlp_bytes(bloom), rlp_int(diff),
        rlp_int(num), rlp_int(gl), rlp_int(gu), rlp_int(ts),
        rlp_bytes(h2b(b['extraData'])), rlp_bytes(mix), rlp_bytes(nonce),
        rlp_bytes(h2b(b.get('validators', '0x'))), rlp_bytes(h2b(b.get('penalties', '0x'))),
    ]
    if b.get('baseFeePerGas'):
        items.append(rlp_int(int(b['baseFeePerGas'], 16)))
    return recover(keccak(rlp_list(items)), sig)


def signer_of(b):
    """Height-gated V2 -> V1 -> raw-miner-if-nonzero fallback. Never returns
    the zero address as if it were a real answer."""
    addr = None
    try:
        num = int(b['number'], 16)
    except Exception:
        num = None
    if num is not None and num >= V2SWITCH:
        addr = signer_v2(b)
    if not addr:
        addr = signer_v1(b)
    if not addr:
        m = (b.get('miner') or '').lower()
        if m and m != '0x0000000000000000000000000000000000000000':
            addr = m
    return addr


def masternodes_from_checkpoint(cp):
    """Authoritative on-chain signer set from the epoch CHECKPOINT header's
    extraData (Clique-style layout: 32-byte vanity, 20 bytes per masternode,
    65-byte seal). XDPoS_getMasternodesByNumber is only a cross-check -- it
    returns an empty list before the first checkpoint."""
    b = rpc("eth_getBlockByNumber", [hex(cp), False])
    if not b:
        return []
    extra = h2b(b['extraData'])
    body = extra[32:-65]
    if len(body) % 20 != 0 or not body:
        return []
    return ['0x' + body[i:i + 20].hex() for i in range(0, len(body), 20)]


def main():
    HEAD = require_head_covers(HI)
    print(f"# node head={HEAD}, window fully covered")

    cp = (LO // EPOCH) * EPOCH
    masternodes = masternodes_from_checkpoint(cp) if cp > 0 else []
    if masternodes:
        print(f"# masternode set read from epoch checkpoint block {cp} extraData")
    else:
        print(f"# no masternode set in checkpoint {cp} extraData")
    try:
        mn_rpc = [a.lower() for a in
                  rpc("XDPoS_getMasternodesByNumber", [hex(LO)])["Masternodes"]]
        if mn_rpc:
            print(f"# XDPoS_getMasternodesByNumber cross-check: {len(mn_rpc)} nodes, "
                  f"same set={sorted(mn_rpc) == sorted(masternodes)}, "
                  f"same order={mn_rpc == masternodes}")
            if not masternodes:
                masternodes = mn_rpc
    except Exception as e:
        print(f"# XDPoS_getMasternodesByNumber unavailable ({e})")

    rows = []
    for h in range(LO - 1, HI + 1):     # start one early so LO has a known parent
        b = rpc("eth_getBlockByNumber", [hex(h), False])
        if not b:
            continue
        sg = signer_of(b)
        rows.append((h, (sg or '').lower(), int(b['difficulty'], 16),
                     int(b['timestamp'], 16),
                     len(h2b(b.get('validator', '0x')))))

    window = [r for r in rows if LO <= r[0] <= HI]
    parent_of = {r[0]: r for r in rows}

    print(f"range {LO}..{HI}  blocks={len(window)}")
    print(f"masternodes ({len(masternodes)}): " +
          (", ".join(masternodes) if masternodes else "UNKNOWN"))

    tally = Counter(r[1] for r in window)
    tot = sum(tally.values())
    print("\n--- per-signer distribution (ecrecovered seal, height-gated V1/V2) ---")
    for s, c in tally.most_common():
        tag = "   <-- TARGET" if TARGET and s == TARGET else ""
        print(f"  {s or '<unrecovered>'}  {c:5d}  {100.0*c/tot:6.2f}%{tag}")

    ideal = 100.0 / len(masternodes) if masternodes else None
    if TARGET:
        er = tally.get(TARGET, 0)
        print(f"\nTARGET share = {er}/{tot} = {100.0*er/tot:.2f}%"
              + (f"   ideal = {ideal:.2f}% (1/{len(masternodes)})" if ideal else ""))

    # ---- in-turn slots by PARENT-RELATIVE HOP ordering ----
    max_gap = {}
    if masternodes:
        idx = {a: i for i, a in enumerate(masternodes)}
        M = len(masternodes)
        designated = defaultdict(list)
        won = Counter()
        last_seal_height = {}
        for (h, sg, d, ts, vlen) in window:
            p = parent_of.get(h - 1)
            if not p or p[1] not in idx:
                continue
            expect = masternodes[(idx[p[1]] + 1) % M]
            designated[expect].append(h)
            if sg == expect:
                won[expect] += 1
            if sg in idx:
                gap = h - last_seal_height.get(sg, h)
                max_gap[sg] = max(max_gap.get(sg, 0), gap)
                last_seal_height[sg] = h
        print("\n--- in-turn adoption by hop ordering (in-turn = 1 hop after parent's sealer) ---")
        for a in masternodes:
            n = len(designated[a])
            if not n:
                print(f"  {a}   0 designated slots")
                continue
            tag = "   <-- TARGET" if TARGET and a == TARGET else ""
            gap = max_gap.get(a, 0)
            gap_tag = "  ** STRAND WARNING (gap >> set size) **" if gap > 3 * M else ""
            print(f"  {a}  designated={n:5d}  won={won[a]:5d}  "
                  f"adoption={100.0*won[a]/n:6.2f}%  max_seal_gap={gap}{gap_tag}{tag}")
        if TARGET:
            n = len(designated[TARGET])
            if n:
                print(f"\nTARGET IN-TURN ADOPTION = {won[TARGET]}/{n} = "
                      f"{100.0*won[TARGET]/n:.2f}%")
                print(f"TARGET max_seal_gap = {max_gap.get(TARGET, 0)} "
                      f"(set size = {M}; a gap much larger than {M} means it stranded)")

    # ---- difficulty cross-check (V1-only: diff=6 == sealer believed it was
    # in-turn; V2/HotStuff blocks are QC-based and typically carry a constant
    # difficulty, so this pair reading 0/0 in a fully-V2 window is expected,
    # not a bug) ----
    d6 = [r for r in window if r[2] == 6]
    print(f"\ndiff=6 (in-turn, V1-only) canonical blocks: {len(d6)}/{len(window)}")
    d5 = [r for r in window if r[2] == 5]
    print(f"diff=5 (out-of-turn cover, V1-only) canonical blocks: {len(d5)}/{len(window)}")

    # ---- m2 Validator field presence (the co-sign fix's observable) ----
    vpresent = sum(1 for r in window if r[4] == 65)
    print(f"\nblocks carrying a 65-byte m2 `validator` field: {vpresent}/{len(window)}")

    # ---- block time ----
    if len(window) > 1:
        span = window[-1][3] - window[0][3]
        print(f"\nnet block time = {span/(len(window)-1):.2f} s/block "
              f"(span {span}s over {len(window)-1} intervals, from BLOCK TIMESTAMPS)")


if __name__ == "__main__":
    main()
