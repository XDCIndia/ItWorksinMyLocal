#!/bin/bash
# topo.sh - parse/validate a netlab topology JSON -> a normalized node table.
#
# See netlab/TOPOLOGY.md for the full schema and every constraint enforced
# below. Two subcommands:
#
#   topo.sh validate <topology.json>   # exit 0 + "OK: ..." summary, or exit
#                                       # 1 + one "ERROR: ..." line per
#                                       # violation on stderr (collects all
#                                       # of them before exiting, not just
#                                       # the first)
#   topo.sh print    <topology.json>   # validates first (same as above),
#                                       # then emits the resolved node table
#                                       # to stdout: a few "# key=value"
#                                       # topology-level comment lines
#                                       # (name/chainId/epoch/v2block/period/
#                                       # reward/gap/skipV1Validation/
#                                       # portBase/staggerSeconds/
#                                       # bootnode_port/node_count/
#                                       # sealer_count), then a TSV header +
#                                       # one row per resolved (post {A..B}
#                                       # expansion) node: id, client, role,
#                                       # keyref, maxpeers, p2p, rpc, ws,
#                                       # authrpc, torrent, mcp, privapi,
#                                       # datadir. This is exactly what
#                                       # fleet.sh writes to
#                                       # nodes/<name>/topo.resolved.tsv.
#
# ONE hard requirement for `print`'s keyRef check: this process's
# environment must already have .env's PRIVATE_KEY_* vars loaded (topo.sh
# does this itself, sourcing REPO_ROOT/.env if present) -- a topology that
# references a keyRef which isn't actually set fails fast here, before any
# process starts.
#
# Uses inline python3 for the JSON parse/validate/resolve (already a hard
# dependency across this repo -- lab/lib-lab.sh, gen-genesis.sh, etc).
#
# Env-var templating (ItWorksinMyLocal#62 mint-iter): before JSON-parsing a
# topology file, this script substitutes any "${VAR}" / "${VAR:-default}"
# token found ANYWHERE in the raw file text with that variable's value from
# the process environment (the same .env-sourced subshell this script
# already runs in -- see below), falling back to the given default (or "" if
# there is no ":-default" and the var is unset). This is a generic,
# topology-agnostic templating pass, not special-cased to any one field or
# topology -- it runs on the raw text before json.loads, so a placeholder
# can appear either inside a JSON string ("client": "${CAND_CLIENT:-geth}")
# or bare where a JSON literal is expected ("v2block": ${MINT_V2BLOCK:-1800})
# as long as the SUBSTITUTED text is itself valid JSON at that position.
# Lets one topology file (e.g. topologies/mint-iter.json) be re-parameterized
# per run (which client is "the candidate under test", V1-focus vs V2-focus
# v2block) via plain env vars, with zero fleet.sh/node.sh/scenario-side file
# generation or copy-on-write tricks.

_NETLAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_NETLAB_DIR/.." && pwd)" || exit 1

usage() {
  echo "usage: $(basename "$0") validate <topology.json>" >&2
  echo "       $(basename "$0") print    <topology.json>" >&2
  exit 1
}

[ $# -eq 2 ] || usage
MODE="$1"
TOPO_FILE="$2"
case "$MODE" in
  validate|print) ;;
  *) usage ;;
esac

[ -f "$TOPO_FILE" ] || { echo "topo.sh: no such topology file: $TOPO_FILE" >&2; exit 1; }
# Resolve to an absolute path up front: the python step below needs it, and
# it's about to be printed verbatim into error messages.
TOPO_FILE="$(cd "$(dirname "$TOPO_FILE")" && pwd)/$(basename "$TOPO_FILE")" || exit 1

# Load .env (PRIVATE_KEY_* etc) the same way run.sh/join.sh do, so a
# role=sealer node's keyRef can be checked against the real environment.
( cd "$REPO_ROOT" && set -a && [ -f .env ] && . ./.env; set +a
  exec python3 - "$MODE" "$TOPO_FILE" "$REPO_ROOT" <<'PY'
import json
import os
import re
import sys

mode, topo_path, repo_root = sys.argv[1], sys.argv[2], sys.argv[3]
errors = []


def err(msg):
    errors.append(msg)


# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------
try:
    with open(topo_path) as f:
        raw = f.read()
except OSError as e:
    print("topo.sh: ERROR: cannot read %s: %s" % (topo_path, e), file=sys.stderr)
    sys.exit(1)

_TEMPLATE_RE = re.compile(r'\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}')


def _template_sub(text):
    def repl(m):
        var, default = m.group(1), m.group(2)
        return os.environ.get(var, default if default is not None else "")
    return _TEMPLATE_RE.sub(repl, text)


raw = _template_sub(raw)

try:
    topo = json.loads(raw)
except json.JSONDecodeError as e:
    print("topo.sh: ERROR: %s is not valid JSON: %s" % (topo_path, e), file=sys.stderr)
    sys.exit(1)

if not isinstance(topo, dict):
    print("topo.sh: ERROR: %s: top level must be a JSON object" % topo_path, file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Top-level fields (with defaults)
# ---------------------------------------------------------------------------
name = topo.get("name")
stem = os.path.splitext(os.path.basename(topo_path))[0]
if not name:
    err("missing required field: name")
elif name != stem:
    err("name '%s' must match the filename stem '%s' (%s)" % (name, stem, os.path.basename(topo_path)))

description = topo.get("description", "")

def require_int(field, required=True, default=None):
    if field not in topo:
        if required:
            err("missing required field: %s" % field)
        return default
    v = topo[field]
    if not isinstance(v, int) or isinstance(v, bool):
        err("field '%s' must be an integer (got %r)" % (field, v))
        return default
    return v

chain_id = require_int("chainId")
epoch = require_int("epoch")
v2block = require_int("v2block")
period = require_int("period", required=False, default=1)
reward = require_int("reward", required=False, default=5000)
gap = require_int("gap", required=False, default=450)
port_base = require_int("portBase")
stagger_seconds = require_int("staggerSeconds", required=False, default=5)
skip_v1_validation = bool(topo.get("skipV1Validation", False))

# peering (ItWorksinMyLocal#46 T3.2): "hub" (default) keeps D5's original
# model -- followers dial ONLY the sealers, never each other. "mesh" lets
# fleet.sh also hand each follower every EARLIER-started follower's own
# enode as an additional bootnode (still staggered, still one at a time),
# so followers can peer with each other too -- useful for exercising a
# follower's own peer-management/eviction behavior under a denser graph,
# not just its sync-from-sealer path. Neither value changes how SEALERS
# peer with each other (always through the topology's own bootnode).
peering = topo.get("peering", "hub")
if peering not in ("hub", "mesh"):
    err("field 'peering' must be 'hub' or 'mesh' (got %r)" % peering)

# docs/lab/DESIGN.md's "Documented risks & forbidden knobs" section is
# explicit: "Forbidden: SkipV1Validation / SkipV2Validation -- they disable
# the validation the lab exists to compare." This lab is a
# validation-parity harness (DESIGN.md section 1) -- a topology that ships
# with this genesis flag set true doesn't demonstrate parity, it just turns
# off whichever check the flag guards. Hard-error here (not just document
# it) so a topology JSON can't silently reintroduce the masked-pass finding
# ItWorksinMyLocal#46 was gated on (scenario 12's mixed-5 PASS resting on
# this exact flag).
if skip_v1_validation:
    err("skipV1Validation: true is forbidden (docs/lab/DESIGN.md, "
        "'Documented risks & forbidden knobs') -- it disables the V1 "
        "blocksigner/difficulty validation this lab exists to exercise; "
        "set it to false (or omit the field -- false is the default) and "
        "let any real V1 divergence surface as a scenario result instead "
        "of being masked out of the genesis")

if epoch is not None and epoch != 900:
    err("epoch must be 900 (legacy oldxdc hardcodes EpocBlockRandomize=900 "
        "independent of this genesis field; any other value freezes the "
        "chain at the first checkpoint) -- got %r" % epoch)

if v2block is not None and epoch is not None and epoch != 0 and v2block % epoch != 0:
    err("v2block (%r) must be a multiple of epoch (%r) -- the V1->V2 switch "
        "only happens at a checkpoint boundary" % (v2block, epoch))

if port_base is not None and port_base < 34000:
    err("portBase must be >= 34000 (the framework's reserved port band -- "
        "the live net5151 stack owns 9645-10245, net5050/postgres own "
        "their own range) -- got %r" % port_base)

nodes_raw = topo.get("nodes")
if not isinstance(nodes_raw, list) or not nodes_raw:
    err("missing or empty required field: nodes (must be a non-empty array)")
    nodes_raw = []

# ---------------------------------------------------------------------------
# Node id {A..B} expansion
# ---------------------------------------------------------------------------
RANGE_RE = re.compile(r'^(?P<prefix>.*?)\{(?P<a>\d+)\.\.(?P<b>\d+)\}(?P<suffix>.*)$')

KNOWN_CLIENTS = ("oldxdc", "geth", "erigon", "besu", "nethermind", "reth", "xone")
KNOWN_ROLES = ("sealer", "follower", "proposer")


def expand_node(entry, entry_idx):
    """Yields one or more (id, entry) pairs from a single JSON node entry,
    expanding "prefix{A..B}suffix" ids into prefixA..prefixB copies of the
    same entry (client/role/keyRef/maxpeers all shared -- see
    netlab/TOPOLOGY.md "Id expansion"). A plain id yields itself once."""
    if not isinstance(entry, dict):
        err("nodes[%d]: must be a JSON object" % entry_idx)
        return
    node_id = entry.get("id")
    if not node_id or not isinstance(node_id, str):
        err("nodes[%d]: missing required field: id" % entry_idx)
        return
    m = RANGE_RE.match(node_id)
    if not m:
        yield node_id, entry
        return
    a, b = int(m.group("a")), int(m.group("b"))
    if a > b:
        err("nodes[%d]: id '%s': range {%d..%d} has start > end" % (entry_idx, node_id, a, b))
        return
    for i in range(a, b + 1):
        yield "%s%d%s" % (m.group("prefix"), i, m.group("suffix")), entry


resolved = []  # list of dicts: id, client, role, keyref, maxpeers
seen_ids = set()
for idx, entry in enumerate(nodes_raw):
    for node_id, entry in expand_node(entry, idx):
        if node_id in seen_ids:
            err("duplicate node id after expansion: '%s'" % node_id)
            continue
        seen_ids.add(node_id)

        client = entry.get("client")
        role = entry.get("role")
        keyref = entry.get("keyRef", "")
        maxpeers = entry.get("maxpeers", "")

        if client not in KNOWN_CLIENTS:
            err("node '%s': unknown client '%s' (must be one of: %s)" % (node_id, client, ", ".join(KNOWN_CLIENTS)))
        if role not in KNOWN_ROLES:
            err("node '%s': unknown role '%s' (must be one of: %s)" % (node_id, role, ", ".join(KNOWN_ROLES)))
        if role == "sealer" and client != "oldxdc":
            err("node '%s': role 'sealer' requires client 'oldxdc' (only oldxdc "
                "can seal via join.sh --mine; got client '%s')" % (node_id, client))
        # role=proposer (ItWorksinMyLocal#62 P1/S3): a node under test for
        # client-side sealing/BFT-voting. Its own address gets derived
        # (fleet.sh, via node.sh addr -- the same neutral "XDC account
        # import" every sealer already uses) BEFORE genesis exists and is
        # APPENDED to gen-genesis.sh's --signers, so it lands in genesis
        # extraData AND the seeded 0x88 masternode SMC alongside the real
        # sealers -- see fleet.sh. Restricted to the clients netlab/node.sh +
        # join.sh actually wire a sealing attempt for; the other clients have
        # no sealing-flag path here yet (erigon/besu/nethermind) or seal via
        # role=sealer instead (oldxdc) -- an honest guard, not a capability
        # this harness fakes.
        if role == "proposer" and client not in ("geth", "xone", "reth"):
            err("node '%s': role 'proposer' requires client one of geth|xone|reth "
                "(the clients netlab/node.sh + join.sh wire a sealing attempt for "
                "-- oldxdc seals via role 'sealer' instead; erigon/besu/nethermind "
                "have no sealing-flag path here yet); got client '%s'" % (node_id, client))
        if role in ("sealer", "proposer"):
            if not keyref:
                err("node '%s': role '%s' requires keyRef (name of an env "
                    "var holding the validator private key)" % (node_id, role))
            elif mode == "print" and not os.environ.get(keyref):
                err("node '%s': keyRef '%s' is not set in the environment "
                    "(check .env)" % (node_id, keyref))
        # Was: hard-rejected any chainId != 5151 (nethermind only shipped hand-
        # authored chainspecs, no genesis converter existed -- ItWorksinMyLocal#46
        # open question #2 / xdc-nethermind-private#250). join.sh now auto-
        # converts an arbitrary genesis into a Parity-style chainspec via
        # netlab/nm-chainspec.sh (xdc-nethermind-private#250), so nethermind can
        # at least ATTEMPT to join any chainId topology -- this guard is lifted.
        # Sealing (role=proposer) for nethermind is still refused above (no
        # sealing-flag path wired, and upstream InitBlockProducer is a hard
        # NotSupportedException -- xdc-nethermind-private#224); only
        # role=follower reaches this line for client=nethermind.
        if maxpeers != "" and (not isinstance(maxpeers, int) or isinstance(maxpeers, bool)):
            err("node '%s': maxpeers must be an integer (got %r)" % (node_id, maxpeers))

        resolved.append({
            "id": node_id,
            "client": client or "",
            "role": role or "",
            "keyref": keyref,
            "maxpeers": maxpeers,
        })

sealer_count = sum(1 for n in resolved if n["role"] == "sealer")
proposer_count = sum(1 for n in resolved if n["role"] == "proposer")
if nodes_raw and sealer_count == 0:
    err("topology has no role=sealer node -- nothing to generate/join a chain against")

if errors:
    for e in errors:
        print("topo.sh: ERROR: %s" % e, file=sys.stderr)
    sys.exit(1)

# ---------------------------------------------------------------------------
# Role-based maxpeers defaults (ItWorksinMyLocal#46 T3.1): a node whose JSON
# entry didn't set its own "maxpeers" gets one derived from its ROLE instead
# of silently falling through to whatever the client binary itself defaults
# to (e.g. geth's compiled-in 25) -- which knows nothing about how many
# OTHER nodes this particular topology actually has.
#
# A sealer dials every other sealer through the shared bootnode AND accepts
# a dial from every follower (hub peering, the default) or from every other
# follower too (mesh peering -- see the "peering" field below): its cap must
# hold the whole topology's resolved node count, not a fixed number, or a
# large topology can starve a SEALER's peer slots and reproduce the exact
# peer-starvation regression (scenario 13, all-clients-soak) at the sealer
# end instead of the follower end. MAXPEERS_SLACK leaves room for a human
# operator's own manual admin_addPeer / a debugging RPC client on top of the
# topology's own node count.
#
# A follower, by contrast, only ever needs a small, FIXED number of slots
# (a handful of sealers in hub mode, plus -- in mesh mode -- a handful of
# other followers): capping it independent of N keeps a follower from
# becoming a peer-storm sink candidate itself as the topology grows.
#
# Either default is just that -- a default. An explicit per-node "maxpeers"
# in the topology JSON always wins (checked below).
MAXPEERS_SLACK = 5
FOLLOWER_MAXPEERS_CAP = 15
sealer_maxpeers_default = len(resolved) + MAXPEERS_SLACK
for n in resolved:
    if n["maxpeers"] == "":
        n["maxpeers"] = sealer_maxpeers_default if n["role"] == "sealer" else FOLLOWER_MAXPEERS_CAP

# ---------------------------------------------------------------------------
# Port math (netlab/TOPOLOGY.md "Port math"): portBase + i*20 per resolved
# node (i = zero-based position after expansion, in declaration order); the
# bootnode gets the port just past the last node's block.
# ---------------------------------------------------------------------------
PORT_WIDTH = 20
for i, n in enumerate(resolved):
    base = port_base + i * PORT_WIDTH
    n["p2p"] = base + 0
    n["rpc"] = base + 1
    n["ws"] = base + 2
    n["authrpc"] = base + 3
    n["torrent"] = base + 4
    n["mcp"] = base + 5
    n["privapi"] = "127.0.0.1:%d" % (base + 6)
    n["datadir"] = "nodes/%s/%s" % (name, n["id"])

bootnode_port = port_base + len(resolved) * PORT_WIDTH

# ---------------------------------------------------------------------------
# Cross-topology port-overlap check (ItWorksinMyLocal#62 "port re-band"):
# this topology's own occupied port range is [portBase, bootnode_port] (every
# resolved node's p2p/rpc/ws/authrpc/torrent/mcp/privapi block, plus the
# bootnode just past the last one -- see "Port math" above). Two topologies
# that can each be brought up independently (fleet.sh has no notion of "only
# one topology at a time") must never claim overlapping ranges, or bringing
# both up (even at different times, on the same box) leaves stale listeners
# from one colliding with the other's bind attempts -- confirmed latent
# between mixed-5 (old portBase 34100, 5 nodes -> bootnode at 34200) and
# all-clients (old portBase 34200) before the re-band. Scans every OTHER
# *.json file in the SAME directory as this topology file (sibling
# topologies are expected to live together, e.g. topologies/*.json) and
# best-effort parses just enough of each (portBase + a node count) to
# compute its own range; a sibling that fails to parse that far (not valid
# JSON, missing portBase, whatever) is silently skipped here -- it is not
# this topology's problem, and its OWN `topo.sh validate` run will catch its
# own malformedness. This intentionally does NOT catch a sibling living in a
# DIFFERENT directory (e.g. a scenario-generated scratch topology file
# outside topologies/) -- that is by design: such a file is never meant to
# run concurrently with anything in topologies/ (see mint-iter.json's own
# ${CAND_CLIENT} templating note above), so this check only needs to reason
# about files that actually declare themselves as permanent siblings.
topo_dir = os.path.dirname(topo_path)
try:
    sibling_files = sorted(f for f in os.listdir(topo_dir) if f.endswith(".json"))
except OSError:
    sibling_files = []
for fname in sibling_files:
    fpath = os.path.join(topo_dir, fname)
    if os.path.abspath(fpath) == os.path.abspath(topo_path):
        continue
    try:
        with open(fpath) as f:
            other_raw = _template_sub(f.read())
        other = json.loads(other_raw)
        if not isinstance(other, dict):
            continue
        other_port_base = other.get("portBase")
        if not isinstance(other_port_base, int) or isinstance(other_port_base, bool):
            continue
        other_nodes_raw = other.get("nodes")
        if not isinstance(other_nodes_raw, list):
            continue
        other_count = 0
        for oe in other_nodes_raw:
            if not isinstance(oe, dict):
                continue
            oid = oe.get("id")
            if not isinstance(oid, str):
                continue
            om = RANGE_RE.match(oid)
            if om:
                oa, ob = int(om.group("a")), int(om.group("b"))
                if oa <= ob:
                    other_count += ob - oa + 1
            else:
                other_count += 1
        if other_count == 0:
            continue
        other_bootnode_port = other_port_base + other_count * PORT_WIDTH
        # both ranges are inclusive [start, end]; they overlap iff each
        # starts at or before the other's end.
        if port_base <= other_bootnode_port and other_port_base <= bootnode_port:
            err("portBase %d (this topology's own range %d..%d, %d node(s) + "
                "bootnode) overlaps sibling topology '%s' (%s)'s own range "
                "%d..%d -- give one of them a non-overlapping portBase "
                "(netlab/TOPOLOGY.md 'Port re-band')"
                % (port_base, port_base, bootnode_port, len(resolved),
                   other.get("name", fname), fname, other_port_base, other_bootnode_port))
    except (OSError, json.JSONDecodeError):
        continue

if errors:
    for e in errors:
        print("topo.sh: ERROR: %s" % e, file=sys.stderr)
    sys.exit(1)

if mode == "validate":
    print("OK: %s: %d node(s) (%d sealer, %d proposer, %d follower), chainId=%s portBase=%s bootnode_port=%s"
          % (name, len(resolved), sealer_count, proposer_count,
             len(resolved) - sealer_count - proposer_count, chain_id, port_base, bootnode_port))
    sys.exit(0)

# mode == "print"
meta = [
    ("name", name),
    ("description", description),
    ("chainId", chain_id),
    ("epoch", epoch),
    ("v2block", v2block),
    ("period", period),
    ("reward", reward),
    ("gap", gap),
    ("skipV1Validation", "true" if skip_v1_validation else "false"),
    ("peering", peering),
    ("portBase", port_base),
    ("staggerSeconds", stagger_seconds),
    ("bootnode_port", bootnode_port),
    ("node_count", len(resolved)),
    ("sealer_count", sealer_count),
    ("proposer_count", proposer_count),
]
for k, v in meta:
    print("# %s=%s" % (k, v))

cols = ["id", "client", "role", "keyref", "maxpeers", "p2p", "rpc", "ws", "authrpc", "torrent", "mcp", "privapi", "datadir"]
print("\t".join(cols))
for n in resolved:
    print("\t".join(str(n[c]) for c in cols))
PY
)
