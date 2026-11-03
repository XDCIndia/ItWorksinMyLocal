#!/bin/bash
# e2e.sh - one command: stand up a net2040-like multi-client network, run every
# client in every sync type it supports, have every seated client MINT, and
# assert the chain is healthy. PASS/FAIL/SKIP matrix per client x syncmode;
# exits non-zero if anything FAILs. Known client bugs (e2e-known-bugs.tsv) are
# SKIP with the reason, never FAIL.
#
# Usage:
#   ./e2e.sh --topology net2040-like [options]
#
#   --topology NAME|FILE  topologies/NAME.json (or a path). net2040-like-5 is the
#                         small one (4 geth + 1 erigon seat, 5 followers).
#   --clients a,b,c       only these clients (bootstrap seats -- startAt 0 -- are
#                         always kept: the chain needs them to exist)
#   --syncmodes m1,m2     only nodes in these sync types (full|fast|snap|archive;
#                         a node with no syncmode counts as full)
#   --mint                keep every non-bootstrap seat as a real minting seat and
#                         assert each produced canonical blocks (see mint tally
#                         below). Without it
#                         those seats are demoted to sync-only followers.
#   --until N|FORK        wait for this height (or fork name, e.g. amsterdam,
#                         london, cancun) before asserting. Default: V2 switch+100.
#   --lag N               max tip lag, blocks (default 20)
#   --window K            mint-tally / cadence window, blocks (default 200)
#   --timeout S           give up waiting for --until after S seconds (default 14400)
#   --expect-genesis H    also require this genesis hash (e.g. 0x8d8ff2e9... for
#                         the vendored net2040 genesis)
#   --include-known-bugs  start nodes that e2e-known-bugs.tsv marks as broken
#                         (default: not started, reported SKIP)
#   --no-up               assert against an already-running topology
#   --keep                leave the network running afterwards
#
# Keys: a seat's key comes from .env (PRIVATE_KEY_n) or, if unset, is generated
# once into nodes/<name>/e2e-keys.env (mode 0600). No key is ever on a command line.
# Run this on a FLEET host, not a small orchestrator box: a full topology is many
# JVM/.NET/Go clients. Everything below the fleet runs under nice.

cd "$(dirname "$0")" || exit 1
ROOT="$PWD"
source ./lib.sh
source ./lib-rpc.sh

TOPO=""; CLIENTS=""; SYNCMODES=""; MINT=0; UNTIL=""; LAG=20; WINDOW=200
TIMEOUT=14400; EXPECT_GENESIS=""; INCLUDE_KNOWN=0; NOUP=0; KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --topology) TOPO=$2; shift 2;;
    --clients) CLIENTS=$2; shift 2;;
    --syncmodes) SYNCMODES=$2; shift 2;;
    --mint) MINT=1; shift;;
    --until) UNTIL=$2; shift 2;;
    --lag) LAG=$2; shift 2;;
    --window) WINDOW=$2; shift 2;;
    --timeout) TIMEOUT=$2; shift 2;;
    --expect-genesis) EXPECT_GENESIS=$2; shift 2;;
    --include-known-bugs) INCLUDE_KNOWN=1; shift;;
    --no-up) NOUP=1; shift;;
    --keep) KEEP=1; shift;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "e2e.sh: unknown flag: $1" >&2; exit 1;;
  esac
done
[ -n "$TOPO" ] || { echo "e2e.sh: --topology is required (see --help)" >&2; exit 1; }
[ -f "$TOPO" ] || TOPO="topologies/${TOPO}.json"
[ -f "$TOPO" ] || { echo "e2e.sh: no such topology: $TOPO" >&2; exit 1; }
NAME=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$TOPO") || exit 1
RUN="$ROOT/nodes/$NAME"
E2E_DIR="$ROOT/nodes/.e2e"; mkdir -p "$E2E_DIR" "$RUN"
TOPO_RUN="$E2E_DIR/$NAME.json"     # filtered copy; its filename stem must equal "name"

# Known-bug status per client/syncmode, resolved here (lib.sh) and handed to the
# filter/asserter as a TSV: client<TAB>syncmode<TAB>SKIP|ok<TAB>ref reason.
KB="$E2E_DIR/$NAME.known.tsv"; : > "$KB"
for c in $(printf '%s\n' $JOIN_ALL_CLIENTS | grep -v '^geth4$'); do
  for m in full fast snap archive; do
    st=$(client_syncmode_status "$c" "$m")
    case "$st" in SKIP*) printf '%s\t%s\tSKIP\t%s\n' "$c" "$m" "${st#SKIP }" >> "$KB" ;; esac
  done
done

# --- 1. filtered topology ----------------------------------------------------
python3 - "$TOPO" "$TOPO_RUN" "$CLIENTS" "$SYNCMODES" "$MINT" "$INCLUDE_KNOWN" "$KB" <<'PY' || exit 1
import json, sys
src, dst, clients, syncmodes, mint, incl, kb = sys.argv[1:8]
clients = [c for c in clients.split(",") if c]; syncmodes = [m for m in syncmodes.split(",") if m]
known = {}
for l in open(kb):
    c, m, _, why = l.rstrip("\n").split("\t", 3)
    known[(c, m)] = why
d = json.load(open(src))
out, skipped = [], []
for n in d["nodes"]:
    sm = n.get("syncmode") or "full"
    boot = n.get("role") == "sealer" and not n.get("startAt")
    why = known.get((n["client"], sm)) or known.get((n["client"], "*"))
    if why and incl != "1" and not boot:
        skipped.append({"id": n["id"], "client": n["client"], "syncmode": sm, "why": why}); continue
    if not boot:
        if clients and n["client"] not in clients: continue
        if syncmodes and sm not in syncmodes: continue
    if n.get("role") == "sealer" and not boot and mint != "1":
        n = dict(n, role="follower"); n.pop("keyRef", None)   # sync-only without --mint
    out.append(n)
if not any(n["role"] == "sealer" for n in out):
    sys.exit("e2e.sh: no seat left after filtering (need the startAt-0 bootstrap seats)")
d["nodes"] = out
json.dump(d, open(dst, "w"), indent=1)
json.dump(skipped, open(dst + ".skipped", "w"))
print("e2e.sh: topology %s: %d node(s) kept, %d skipped as known-bug" % (d["name"], len(out), len(skipped)))
PY

# --- 2. keys ------------------------------------------------------------------
KEYS="$RUN/e2e-keys.env"
set -a; [ -f .env ] && . ./.env; set +a
for ref in $(python3 -c "import json,sys;print(' '.join(n['keyRef'] for n in json.load(open(sys.argv[1]))['nodes'] if n.get('keyRef')))" "$TOPO_RUN"); do
  [ -n "${!ref:-}" ] && continue
  if [ -f "$KEYS" ] && grep -q "^$ref=" "$KEYS"; then :; else
    ( umask 077; printf '%s=%s\n' "$ref" "$(openssl rand -hex 32)" >> "$KEYS" )
  fi
done
# shellcheck source=/dev/null
[ -f "$KEYS" ] && { set -a; . "$KEYS"; set +a; }
export IWML_KEYPASS="${IWML_KEYPASS:-iwml-e2e}"

# --- 3. up ---------------------------------------------------------------------
_down() { [ "$KEEP" = 1 ] || nice -n 10 netlab/fleet.sh down "$TOPO_RUN" --force >/dev/null 2>&1; }
trap '_down' EXIT
if [ "$NOUP" != 1 ]; then
  nice -n 5 netlab/fleet.sh up "$TOPO_RUN" --wipe || { echo "e2e.sh: FAIL: bring-up failed" >&2; exit 1; }
fi
GEN="$RUN/genesis.json"
[ -f "$GEN" ] || { echo "e2e.sh: FAIL: no genesis at $GEN" >&2; exit 1; }

# --until: number, or a fork name resolved from the generated genesis (already
# scaled by forksDiv); default = V2 switch + 100.
UNTIL_N=$(python3 - "$GEN" "$UNTIL" <<'PY'
import json, sys
g = json.load(open(sys.argv[1])); u = sys.argv[2]
c = g["config"]
if u == "": print(c["XDPoS"]["v2"]["switchBlock"] + 100)
elif u.isdigit(): print(u)
else: print(c[u + "Block"] + 5)
PY
) || exit 1

# Late nodes (startAt > 0) start themselves as the chain reaches their height.
# They are started in the background so the wait below can run in parallel.
if [ "$NOUP" != 1 ]; then nice -n 5 netlab/fleet.sh late "$TOPO_RUN" > "$RUN/late.log" 2>&1 & LATE_PID=$!; fi

# --- 4. wait + assert ----------------------------------------------------------
python3 - "$RUN" "$GEN" "$UNTIL_N" "$LAG" "$WINDOW" "$TIMEOUT" "$EXPECT_GENESIS" "$TOPO_RUN.skipped" "${LATE_PID:-}" <<'PY'
import glob, json, os, re, sys, time, urllib.request
run, gen, until, lag, window, timeout, expect, skipped_f, late_pid = sys.argv[1:10]
until, lag, window, timeout = int(until), int(lag), int(window), int(timeout)
genesis = json.load(open(gen)); cfg = genesis["config"]; period = cfg["XDPoS"]["period"]

def rpc(port, method, params=None, t=5):
    req = urllib.request.Request("http://127.0.0.1:%s" % port, json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or []}).encode(),
        {"Content-Type": "application/json"})
    try:
        r = json.load(urllib.request.urlopen(req, timeout=t))
        return r.get("result")
    except Exception:
        return None

def head(port):
    v = rpc(port, "eth_blockNumber")
    return int(v, 16) if v else None

def block(port, n):
    return rpc(port, "eth_getBlockByNumber", [hex(n), False], 10)

rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(run, "topo.resolved.tsv")) if not l.startswith("#")]
hdr, rows = rows[0], [dict(zip(rows[0], r)) for r in rows[1:]]
nodes = []
for r in rows:
    addr = ""
    ks = glob.glob(os.path.join(os.path.dirname(run), os.path.relpath(r["datadir"], "nodes"), "keystore", "UTC--*"))
    if ks: addr = "0x" + re.sub(r"^(0x|xdc)", "", ks[0].rsplit("--", 1)[1].lower())   # oldxdc names files xdc<addr>
    nodes.append(dict(id=r["id"], client=r["client"], role=r["role"], sm=r["syncmode"] or "full",
                      start=int(r["startAt"] or 0), port=r["rpc"], datadir=r["datadir"], addr=addr))
sealers = [n for n in nodes if n["role"] == "sealer"]
boots = [n for n in sealers if n["start"] == 0]
for n in boots: n["head"] = head(n["port"]) or 0
ref = max(boots, key=lambda n: n["head"])   # a bootstrap seat can be stuck on a fork; judge against the longest

# ---- wait for the target height (and for late nodes to have been started).
# Late nodes are started by `fleet.sh late` at their startAt, so the target is at
# least the last startAt + a little (otherwise we would stop before they exist).
until = max([until] + [n["start"] + 50 for n in nodes])
t0 = time.time(); last = None; zero_since = time.time(); bounces = 0
topo_file = os.path.join(os.path.dirname(run), ".e2e", os.path.basename(run) + ".json")
while True:
    h = head(ref["port"])
    # A fresh modern chain sometimes never releases its first block (the xdcSyncer
    # genesis gate, a client bug that clears on restart). If nothing has been
    # produced for 8 minutes, bounce the bootstrap seats (at most twice).
    if h:
        zero_since = time.time()
    elif time.time() - zero_since > 480 and bounces < 2:
        bounces += 1; zero_since = time.time()
        print("e2e.sh: chain still at block 0 after 8 min -- restarting the bootstrap seats (attempt %d)" % bounces, flush=True)
        import subprocess
        for n in boots:
            subprocess.call(["netlab/node.sh", "stop", topo_file, n["id"]])
        for n in boots:
            subprocess.call(["netlab/node.sh", "start", topo_file, n["id"], "--genesis", gen])
    if h is not None and h >= until:
        late_done = True
        if late_pid:
            try: os.kill(int(late_pid), 0); late_done = False
            except OSError: pass
        if late_done: break
    if time.time() - t0 > timeout:
        print("e2e.sh: timed out waiting for block %d (head %s)" % (until, h)); break
    if h != last and h is not None and h % 100 == 0: print("e2e.sh: head %d / %d" % (h, until), flush=True)
    last = h; time.sleep(10)
# let late followers catch up: wait (bounded) until every live node is within lag
for _ in range(60):
    hs = [head(n["port"]) for n in nodes]; top = max([x for x in hs if x is not None] or [0])
    if all(x is not None and top - x <= lag for x in hs if x is not None): break
    time.sleep(5)

res = {}   # node id -> list of (check, status, detail)
def add(n, check, ok, detail=""):
    res.setdefault(n["id"], []).append((check, "PASS" if ok is True else "FAIL" if ok is False else ok, detail))

alive = {}
for n in nodes:
    n["head"] = head(n["port"]); alive[n["id"]] = n["head"] is not None
rh = ref["head"]
g0 = {n["id"]: (block(n["port"], 0) or {}).get("hash") for n in nodes}
rg = g0[ref["id"]]
if expect and rg != expect:
    add(ref, "genesis-expected", False, "%s != %s" % (rg, expect))

# fork heights from the generated genesis (what the ladder actually is)
forks = sorted({(cfg[k], k[:-5]) for k in cfg if k.endswith("Block") and isinstance(cfg[k], int)
                and cfg[k] > 4 and cfg[k] < 999999999
                and k[:-5] in ("london", "eip1559", "cancun", "prague", "osaka", "amsterdam", "gas2500x", "dynamicGasLimit")})
forks.insert(0, (cfg["XDPoS"]["v2"]["switchBlock"], "v2switch"))
refh = {}
def ref_hash(hgt):
    if hgt not in refh: refh[hgt] = (block(ref["port"], hgt) or {}).get("hash")
    return refh[hgt]

# ---- mint tally over the last `window` blocks of the reference chain.
# XDPoS headers carry a zero coinbase (the author is in the seal), so the RPC
# `miner` field is usually 0x0. Evidence of minting is therefore the seat's own
# log: lines naming a block it produced (geth "minted block", oldxdc "Successfully
# sealed", erigon "self-mined", ...) whose number AND hash match the canonical chain
# in the window. `miner` is used too whenever the client does report it.
lo = max(1, (rh or 0) - window + 1); miners = {}; canon = {}
for b in range(lo, (rh or 0) + 1):
    blk = block(ref["port"], b) or {}
    canon[b] = (blk.get("hash") or "").lower()
    m = (blk.get("miner") or "").lower()
    miners[m] = miners.get(m, 0) + 1
# cadence = MEDIAN gap between consecutive blocks in the window (robust to the slow
# first blocks of a fresh chain and to the odd skipped round)
tss = [int((block(ref["port"], b) or {}).get("timestamp", "0x0"), 16) for b in range(max(0, lo - 1), (rh or 0) + 1)] if rh else []
gaps = sorted(b - a for a, b in zip(tss, tss[1:]))
avg = float(gaps[len(gaps) // 2]) if gaps else 0
MINT_RE = re.compile(r"minted block|Successfully sealed|self-mined|produced block|block produced|sealed block|proposed block", re.I)
def canonical_mints(logf):
    got = {}
    if not os.path.exists(logf): return got
    with open(logf, errors="replace") as fh:
        for l in fh:
            if not MINT_RE.search(l): continue
            mn = re.search(r"number=(\d+)", l); mh = re.search(r"hash=(?:0x)?([0-9a-fA-F.]+)", l)
            if not mn or not mh: continue
            num = int(mn.group(1)); c = canon.get(num, "")
            if not c: continue
            h = mh.group(1).lower()
            if (".." in h and c[2:2 + len(h.split("..")[0])] == h.split("..")[0] and c.endswith(h.split("..")[1])) or c[2:] == h:
                got[num] = c
    return got

for n in nodes:
    if not alive[n["id"]]:
        add(n, "running", "SKIP" if n["start"] > (rh or 0) else False,
            "not started (needs block %d, head %s)" % (n["start"], rh) if n["start"] > (rh or 0) else "RPC down"); continue
    add(n, "genesis-hash", g0[n["id"]] == rg, g0[n["id"]] or "")
    behind = (rh or 0) - n["head"]
    add(n, "tip-lag<=%d" % lag, behind <= lag, "head %d, ref %d" % (n["head"], rh))
    for hgt, fname in forks:
        if hgt > min(n["head"], rh): add(n, "parity@" + fname, "SKIP", "block %d not reached" % hgt); continue
        hh = (block(n["port"], hgt) or {}).get("hash")
        add(n, "parity@%s(%d)" % (fname, hgt), hh is not None and hh == ref_hash(hgt), (hh or "")[:12])
    if n["role"] == "sealer":
        logm = canonical_mints(os.path.join(os.path.dirname(run), os.path.relpath(n["datadir"], "nodes"), "node.log"))
        got = len(logm) + miners.get(n["addr"], 0)
        ev = ", ".join("#%d %s" % (k, logm[k][:12]) for k in sorted(logm)[:3])
        add(n, "minted(last %d)" % (rh - lo + 1), got > 0, "%d canonical block(s) by %s e.g. %s" % (got, n["addr"][:10], ev))
    # logs
    logf = os.path.join(os.path.dirname(run), os.path.relpath(n["datadir"], "nodes"), "node.log")
    bad = 0
    if os.path.exists(logf):
        pat = re.compile(r"BAD BLOCK|\bBad block\b(?!s)|(?i:invalid merkle root|invalid difficulty|InvalidStateRoot|HeaderGasUsedMismatch)")   # case-sensitive: "...c47bad blocks=1" is a hash + a count
        with open(logf, errors="replace") as fh: bad = sum(1 for l in fh if pat.search(l))
    add(n, "no-bad-block-logs", bad == 0, "%d hit(s)" % bad)

cad_ok = avg and abs(avg - period) <= period * 0.5
print("\nnetwork: head %s, window %d, distinct RPC miners: %d, median block time %.1fs (period %ds) -> cadence %s" % (
    rh, window, len([m for m in miners if m]), avg, period, "PASS" if cad_ok else "FAIL"))

# ---- matrix
fail = 0 if cad_ok else 1
print("\n%-20s %-11s %-9s %-7s %s" % ("node", "client", "syncmode", "result", "detail"))
for n in nodes:
    checks = res.get(n["id"], [])
    bad = [c for c in checks if c[1] == "FAIL"]
    skip = [c for c in checks if c[1] == "SKIP" and c[0] == "running"]
    status = "FAIL" if bad else "SKIP" if skip else "PASS"
    detail = "; ".join("%s: %s" % (c[0], c[2]) for c in (bad or skip)) or "%d checks; %s" % (len(checks), "; ".join(c[2] for c in checks if c[0].startswith("minted")))
    fail += status == "FAIL"
    print("%-20s %-11s %-9s %-7s %s" % (n["id"], n["client"], n["sm"], status, detail))
for s in json.load(open(skipped_f)):
    print("%-20s %-11s %-9s %-7s %s" % (s["id"], s["client"], s["syncmode"], "SKIP", "known bug: " + s["why"]))
print("\nRESULT: %s" % ("FAIL (%d)" % fail if fail else "PASS"))
sys.exit(1 if fail else 0)
PY
RC=$?
[ -n "${LATE_PID:-}" ] && kill "$LATE_PID" 2>/dev/null
exit $RC
