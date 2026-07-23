#!/bin/bash
# lib-assert.sh - named, reusable assertions for lab scenarios
# (ItWorksinMyLocal#46 T2.3).
#
# Each assert_* function:
#   - takes plain positional args (no --flags), so scenario code can call
#     it directly without an argument-parsing dance
#   - echoes EXACTLY ONE line to stdout: "PASS: <reason>" or
#     "FAIL: <reason>" -- same one-line-verdict convention as
#     netlab/health.sh's OK:/FAIL: and oracle.sh's PARITY OK/DIVERGENCE
#   - returns 0 (PASS) or 1 (FAIL) -- never anything else; a malformed call
#     (wrong arg count) is a hard FAIL with a usage reason, not a crash, so
#     a scenario can do `assert_foo ... || { echo "..."; return 1; }`
#     unconditionally without first checking arity itself
#
# Node references are passed as "name=url" pairs throughout (e.g.
# "node1=http://127.0.0.1:34101") so a FAIL's one-line reason can name the
# offending node instead of just its bare RPC URL -- matches
# lib-topo.sh's topo_rpc/topo_nodes output shape, which is what scenario 12
# feeds these functions.
#
# Uses lib-rpc.sh directly (lab_block_hash/lab_wait_block/lab_block_number)
# -- standalone-sourceable, no dependency on lab/lib-lab.sh's fixed-topology
# client registry, same posture as netlab/health.sh (T1.4).

_LIBASSERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_LIBASSERT_DIR/.." && pwd)" || exit 1
# shellcheck source=../lib-rpc.sh
source "$REPO_ROOT/lib-rpc.sh"

# _assert_pass/_assert_fail: the one-line PASS:/FAIL: contract every
# assert_* function below funnels through.
_assert_pass() { printf 'PASS: %s\n' "$1"; return 0; }
_assert_fail() { printf 'FAIL: %s\n' "$1"; return 1; }

# _pair_name "name=url" -> name ; _pair_url "name=url" -> url
_pair_name() { printf '%s' "${1%%=*}"; }
_pair_url()  { printf '%s' "${1#*=}"; }

# _pair_addr_norm "0xAbC..." -> "0xabc..." : lowercased, for
# case-insensitive address comparison (every client's own JSON-RPC
# checksums addresses differently -- some lowercase, some mixed-case).
_addr_norm() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# _assert_block_miner <url> <N>: the 0x-prefixed, lowercased address that
# actually SEALED block N -- universal across every client this framework
# brings up (pure eth_getBlockByNumber, no XDPoS_* dependency, matching
# DESIGN.md's "XDPoS_* is diagnostics-only enrichment" rule).
#
# NOT simply the block's own `miner`/coinbase JSON field -- verified LIVE
# against a real oldxdc+geth mint-iter run (ItWorksinMyLocal#62) that this
# field is the ZERO address on every XDPoS V1 block, on every client
# checked (oldxdc AND geth): XDPoS V1 is Clique-derived, and Clique-style
# engines deliberately leave Coinbase unused for identity -- the actual
# signer is recovered by ecrecover()ing the last-65-bytes seal signature in
# the block's `extraData` against the SAME sigHash every XDPoS v1 node
# itself computes to verify a block (consensus/XDPoS/engines/engine_v1/
# utils.go:sigHash+ecrecover in XDCIndia/XDPoSChain -- identical in shape to
# go-ethereum's own consensus/clique/clique.go). Trusting the raw `miner`
# field here would have made EVERY assertion in this file that depends on
# it (assert_mint_accepted's witness quorum, assert_mint_share,
# assert_v1_turn_order) silently see only the zero address forever -- a
# systematic false-negative that would have masked the very thing the mint
# gate exists to detect. V2 (post-switch) blocks are handled the analogous
# way, per engine_v2/utils.go: signature lives in the separate `validator`
# header field (not extraData's tail), and the sigHash additionally covers
# the (untruncated) extraData plus the `validators`/`penalties` fields --
# implemented below but NOT live-verified against a real V2 block in this
# session (no run was driven far enough past a v2block switch to observe
# one); if V2 signer recovery here is ever found wrong, this comment is the
# first place to look.
#
# Falls back to the raw `miner` field only if neither recovery attempt
# succeeds (e.g. a future client that actually populates it, or malformed
# input) -- never silently returns the zero address as if it were a real
# answer. Prints "" (+ nonzero) if the node doesn't have the block yet or is
# unreachable.
_assert_block_miner() {
  local url="$1" n="$2" hexn block
  hexn=$(printf '0x%x' "$n")
  block=$(lab_rpc_call "$url" eth_getBlockByNumber "[\"${hexn}\",false]") || { printf ''; return 1; }
  python3 -c "
import json
import sys

try:
    from eth_utils import keccak
    from eth_keys.datatypes import Signature
except Exception:
    print('')
    sys.exit(0)


def h2b(s):
    s = s or '0x'
    return bytes.fromhex(s[2:] if s.startswith('0x') else s)


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
    nb = v.to_bytes((v.bit_length() + 7) // 8, 'big')
    return rlp_bytes(nb)


def rlp_list(items):
    payload = b''.join(items)
    if len(payload) <= 55:
        return bytes([0xc0 + len(payload)]) + payload
    lb = len(payload).to_bytes((len(payload).bit_length() + 7) // 8 or 1, 'big')
    return bytes([0xf7 + len(lb)]) + lb + payload


def common_fields(b):
    return (h2b(b['parentHash']), h2b(b.get('sha3Uncles', '0x')), h2b(b['miner']),
            h2b(b['stateRoot']), h2b(b['transactionsRoot']), h2b(b['receiptsRoot']),
            h2b(b['logsBloom']), int(b['difficulty'], 16), int(b['number'], 16),
            int(b['gasLimit'], 16), int(b['gasUsed'], 16), int(b['timestamp'], 16),
            h2b(b['mixHash']), h2b(b['nonce']))


def recover(msg_hash, sig):
    if len(sig) != 65:
        return None
    r = int.from_bytes(sig[0:32], 'big')
    s = int.from_bytes(sig[32:64], 'big')
    v = sig[64]
    try:
        pub = Signature(vrs=(v, r, s)).recover_public_key_from_msg_hash(msg_hash)
    except Exception:
        return None
    return '0x' + keccak(pub.to_bytes())[-20:].hex()


def signer_v1(b):
    # engine_v1/utils.go sigHash: header fields with Extra TRUNCATED to drop
    # the trailing 65-byte seal, which is itself the ecrecover signature.
    extra = h2b(b['extraData'])
    if len(extra) < 65:
        return None
    sig = extra[-65:]
    parent, uncle, coinbase, root, txroot, rroot, bloom, diff, num, gl, gu, ts, mix, nonce = common_fields(b)
    items = [rlp_bytes(parent), rlp_bytes(uncle), rlp_bytes(coinbase), rlp_bytes(root),
             rlp_bytes(txroot), rlp_bytes(rroot), rlp_bytes(bloom), rlp_int(diff), rlp_int(num),
             rlp_int(gl), rlp_int(gu), rlp_int(ts), rlp_bytes(extra[:-65]), rlp_bytes(mix), rlp_bytes(nonce)]
    if b.get('baseFeePerGas'):
        items.append(rlp_int(int(b['baseFeePerGas'], 16)))
    return recover(keccak(rlp_list(items)), sig)


def signer_v2(b):
    # engine_v2/utils.go sigHash: Extra is NOT truncated (no seal embedded in
    # it); the signature is the separate 'validator' header field, and the
    # hash additionally covers 'validators'/'penalties'.
    sig = h2b(b.get('validator', '0x'))
    if len(sig) != 65:
        return None
    parent, uncle, coinbase, root, txroot, rroot, bloom, diff, num, gl, gu, ts, mix, nonce = common_fields(b)
    items = [rlp_bytes(parent), rlp_bytes(uncle), rlp_bytes(coinbase), rlp_bytes(root),
             rlp_bytes(txroot), rlp_bytes(rroot), rlp_bytes(bloom), rlp_int(diff), rlp_int(num),
             rlp_int(gl), rlp_int(gu), rlp_int(ts), rlp_bytes(h2b(b['extraData'])), rlp_bytes(mix), rlp_bytes(nonce),
             rlp_bytes(h2b(b.get('validators', '0x'))), rlp_bytes(h2b(b.get('penalties', '0x')))]
    if b.get('baseFeePerGas'):
        items.append(rlp_int(int(b['baseFeePerGas'], 16)))
    return recover(keccak(rlp_list(items)), sig)


raw = sys.argv[1]
try:
    b = json.loads(raw) if raw else None
except Exception:
    b = None
if not b:
    print('')
    sys.exit(0)

addr = None
validator_field = b.get('validator') or ''
if validator_field not in ('', '0x'):
    addr = signer_v2(b)
if not addr:
    addr = signer_v1(b)
if not addr:
    m = (b.get('miner') or '').lower()
    addr = m if m and m != '0x0000000000000000000000000000000000000000' else None
print((addr or '').lower())
" "$block"
}

# ---------------------------------------------------------------------------
# assert_genesis_parity <name1=url1> <name2=url2> [more...]
#
# All given nodes must report the SAME block-0 (genesis) hash. This is the
# documented net5151/#34 failure mode made explicit: a genesis-hash
# mismatch means the affected node was (or will be) rejected at the
# eth/XDPoS handshake and can never sync, no matter what happens
# afterwards -- scenarios should check this FIRST, before anything else.
# ---------------------------------------------------------------------------
assert_genesis_parity() {
  [ $# -ge 2 ] || { _assert_fail "assert_genesis_parity: need >= 2 name=url pairs, got $#"; return 1; }
  local first="$1" first_name first_hash pair name url hash mismatches=""
  first_name=$(_pair_name "$first")
  first_hash=$(lab_block_hash "$(_pair_url "$first")" 0) || first_hash=""
  [ -n "$first_hash" ] || { _assert_fail "genesis parity: could not read block 0 from $first_name"; return 1; }
  shift
  for pair in "$@"; do
    name=$(_pair_name "$pair"); url=$(_pair_url "$pair")
    hash=$(lab_block_hash "$url" 0) || hash=""
    if [ -z "$hash" ]; then
      mismatches="${mismatches}${mismatches:+, }${name}=<unreachable>"
    elif [ "$hash" != "$first_hash" ]; then
      mismatches="${mismatches}${mismatches:+, }${name}=${hash:0:10}"
    fi
  done
  if [ -z "$mismatches" ]; then
    _assert_pass "genesis parity: $first_name + $# more node(s) all agree on ${first_hash:0:10}"
  else
    _assert_fail "genesis mismatch: $first_name=${first_hash:0:10} vs $mismatches"
  fi
}

# ---------------------------------------------------------------------------
# assert_lockstep <refName=refUrl> <peerName=peerUrl> <height> [timeout_s=120]
#
# Waits (up to timeout_s, for EACH of the two) for both the reference and
# the peer to reach <height>, then asserts they compute the SAME block
# hash there -- the reusable form of the pairwise "is this follower still
# in lockstep with the reference" check scenario 11 open-coded per
# checkpoint.
# ---------------------------------------------------------------------------
assert_lockstep() {
  [ $# -ge 3 ] || { _assert_fail "assert_lockstep: usage: assert_lockstep <ref=url> <peer=url> <height> [timeout_s]"; return 1; }
  local ref="$1" peer="$2" height="$3" timeout="${4:-120}"
  local ref_name peer_name ref_url peer_url ref_hash peer_hash
  ref_name=$(_pair_name "$ref"); ref_url=$(_pair_url "$ref")
  peer_name=$(_pair_name "$peer"); peer_url=$(_pair_url "$peer")

  lab_wait_block "$ref_url" "$height" "$timeout" \
    || { _assert_fail "lockstep H=$height: reference $ref_name never reached it (head=$(lab_block_number "$ref_url" 2>/dev/null || echo '?'))"; return 1; }
  lab_wait_block "$peer_url" "$height" "$timeout" \
    || { _assert_fail "lockstep H=$height: $peer_name never reached it (head=$(lab_block_number "$peer_url" 2>/dev/null || echo '?'))"; return 1; }

  ref_hash=$(lab_block_hash "$ref_url" "$height") || ref_hash=""
  peer_hash=$(lab_block_hash "$peer_url" "$height") || peer_hash=""
  if [ -n "$ref_hash" ] && [ "$ref_hash" = "$peer_hash" ]; then
    _assert_pass "lockstep H=$height: $ref_name and $peer_name agree on ${ref_hash:0:10}"
  else
    _assert_fail "lockstep H=$height: $ref_name=${ref_hash:-<miss>} $peer_name=${peer_hash:-<miss>}"
  fi
}

# ---------------------------------------------------------------------------
# assert_hash_agreement <height> <name1=url1> <name2=url2> [more...]
#
# N-way (not reference-vs-one) hash agreement at a single, already-reached
# height. Does NOT wait for anyone to catch up -- callers that need that
# should assert_lockstep or lab_wait_block first. A node missing the block
# yet is a FAIL, not a skip: this is meant to be called only at checkpoints
# the caller has already gated on.
# ---------------------------------------------------------------------------
assert_hash_agreement() {
  [ $# -ge 3 ] || { _assert_fail "assert_hash_agreement: usage: assert_hash_agreement <height> <name1=url1> <name2=url2> [...]"; return 1; }
  local height="$1"; shift
  local first="$1" first_name first_hash pair name url hash mismatches=""
  first_name=$(_pair_name "$first")
  first_hash=$(lab_block_hash "$(_pair_url "$first")" "$height") || first_hash=""
  [ -n "$first_hash" ] || { _assert_fail "hash agreement H=$height: $first_name is missing this block"; return 1; }
  shift
  for pair in "$@"; do
    name=$(_pair_name "$pair"); url=$(_pair_url "$pair")
    hash=$(lab_block_hash "$url" "$height") || hash=""
    if [ -z "$hash" ]; then
      mismatches="${mismatches}${mismatches:+, }${name}=<miss>"
    elif [ "$hash" != "$first_hash" ]; then
      mismatches="${mismatches}${mismatches:+, }${name}=${hash:0:10}"
    fi
  done
  if [ -z "$mismatches" ]; then
    _assert_pass "hash agreement H=$height: all agree on ${first_hash:0:10}"
  else
    _assert_fail "hash agreement H=$height: $first_name=${first_hash:0:10} vs $mismatches"
  fi
}

# ---------------------------------------------------------------------------
# assert_survives_epoch <name=url> [epoch=900] [margin=1] [timeout_s]
#
# Waits for the given node to reach block (epoch+margin) -- i.e. that it is
# still alive and syncing/sealing PAST the checkpoint boundary, not
# permanently stalled at or before it (the modern-geth V1 difficulty stall
# this whole issue is scoped around -- #34, scenario 11). Default timeout
# is a generous 3x(epoch+margin) seconds (period=1s/block assumption) +
# 300s slack; pass timeout_s explicitly for a non-default period.
# ---------------------------------------------------------------------------
assert_survives_epoch() {
  [ $# -ge 1 ] || { _assert_fail "assert_survives_epoch: usage: assert_survives_epoch <name=url> [epoch=900] [margin=1] [timeout_s]"; return 1; }
  local target_pair="$1" epoch="${2:-900}" margin="${3:-1}" timeout="$4"
  local name url target
  name=$(_pair_name "$target_pair"); url=$(_pair_url "$target_pair")
  target=$((epoch + margin))
  [ -n "$timeout" ] || timeout=$((target * 3 + 300))

  if lab_wait_block "$url" "$target" "$timeout"; then
    _assert_pass "survives-epoch: $name reached block $target (epoch=$epoch, margin=$margin) within ${timeout}s"
  else
    _assert_fail "survives-epoch: $name never reached block $target (epoch=$epoch, margin=$margin, head=$(lab_block_number "$url" 2>/dev/null || echo '?')) within ${timeout}s"
  fi
}

# ---------------------------------------------------------------------------
# assert_no_validation_bypass <name> <logfile>
#
# Scans a node's own log for known "swallowed consensus mismatch" markers
# instead of trusting a final hash-agreement PASS at face value.
# ItWorksinMyLocal#46's gate review found scenario 12's mixed-5 node5
# (modern-geth) logging "BlockChain: A.94 auto-recover on ValidateState
# mismatch during bulk sync block=N err=\"invalid gas used ...\"" -- i.e.
# the follower DID detect a genuine per-block consensus divergence from
# the oldxdc producer (the v1 blocksigner gas-cost mismatch #34/this
# scenario exists to surface) and silently patched over it instead of
# rejecting the block, then went on to agree with the producer's hash at
# every later checkpoint anyway. Every assertion above (genesis parity,
# lockstep, hash agreement, survives-epoch) is blind to this: they only
# ever look at CURRENT chain state, never at whether the node arrived at
# that state by validating every block or by quietly recovering from a
# rejected one. DESIGN.md section 1 defines this lab's whole purpose as
# "a follower that rejects a valid block... = a porting bug" -- a follower
# that silently ACCEPTS an invalid one via an internal auto-recover path
# is the same bug wearing a PASS. Call this for every follower's log
# alongside (not instead of) the hash-based assertions; a FAIL here means
# the run's PASS, if any, is not real parity and must not be reported as
# one. Pattern is the exact upstream wording seen in the field; extend it
# if a client's phrasing differs.
# ---------------------------------------------------------------------------
assert_no_validation_bypass() {
  [ $# -ge 2 ] || { _assert_fail "assert_no_validation_bypass: usage: assert_no_validation_bypass <name> <logfile>"; return 1; }
  local name="$1" logfile="$2" hit
  if [ ! -f "$logfile" ]; then
    _assert_fail "no-validation-bypass: $name -- log file not found ($logfile); cannot confirm no mismatch was swallowed"
    return 1
  fi
  hit=$(grep -m1 -iE 'auto-recover on ValidateState mismatch|ValidateState mismatch' "$logfile" 2>/dev/null)
  if [ -n "$hit" ]; then
    _assert_fail "no-validation-bypass: $name's log shows a swallowed consensus mismatch instead of a rejected block: ${hit}"
  else
    _assert_pass "no-validation-bypass: $name's log shows no swallowed ValidateState mismatch"
  fi
}

# ---------------------------------------------------------------------------
# assert_mint_accepted <candAddr> <H> <genesisFile> <witnesses_csv> <hashnodes_csv> <lognodes_csv>
#
# ItWorksinMyLocal#62's anti-masking MINT GATE, as ONE composite assertion:
# a mint at height H by candAddr counts ONLY when ALL FIVE of the following
# hold (the umbrella issue's own wording, condition numbers preserved):
#
#   (1) >=2 OTHER oldxdc validators AND an independent oldxdc observer
#       report block.miner == candAddr at H -- candAddr's OWN node is
#       INADMISSIBLE as a witness. <witnesses_csv> is a "name=url,..." list
#       the CALLER must build from exactly that independent set (>=3
#       entries enforced here; that the set is actually independent
#       oldxdc nodes distinct from the candidate is a topology-level fact
#       this function cannot itself re-derive from just addresses/URLs --
#       do not pass the candidate's own node here).
#   (2) all running clients hash-agree at H -- delegates to
#       assert_hash_agreement over <hashnodes_csv> ("name=url,..." of
#       EVERY running node, candidate included: hash agreement is a
#       structural cross-check, not an admission of the candidate's claim).
#   (3) stays canonical after tip>=H+3, and H+1 parents to H -- waited out
#       and re-checked against the FIRST entry of <hashnodes_csv> as
#       reference.
#   (4) assert_no_validation_bypass passes on EVERY node's log --
#       <lognodes_csv> is "name=logfile,..." for every running node (an
#       accepted-via-auto-recover mint is a FAIL here, never a PASS).
#   (5) skipV1Validation is false -- read directly from <genesisFile>
#       (defense in depth: topo.sh already hard-errors a topology JSON that
#       sets this true, but this assertion re-checks the ACTUAL genesis a
#       run used rather than trusting that upstream check alone).
#
# Collects every failing condition before reporting (same style as the
# other multi-way assertions above), so a FAIL names everything wrong at
# once instead of just the first thing found.
# ---------------------------------------------------------------------------
assert_mint_accepted() {
  [ $# -ge 6 ] || { _assert_fail "assert_mint_accepted: usage: assert_mint_accepted <candAddr> <H> <genesisFile> <witnesses_csv> <hashnodes_csv> <lognodes_csv>"; return 1; }
  local cand="$1" h="$2" genesis="$3" witnesses_csv="$4" hashnodes_csv="$5" lognodes_csv="$6"
  local cand_norm; cand_norm=$(_addr_norm "$cand")
  local fails=""

  # ---- condition (5): skipV1Validation must be false, read from the real genesis ----
  if [ ! -f "$genesis" ]; then
    fails="${fails}${fails:+; }(5) cannot read genesis $genesis to confirm skipV1Validation"
  else
    local skipv1
    skipv1=$(python3 -c "
import json
import sys

try:
    g = json.load(open(sys.argv[1]))
except Exception:
    print('unknown')
else:
    print(bool(g.get('config', {}).get('XDPoS', {}).get('SkipV1Validation', False)))
" "$genesis" 2>/dev/null)
    if [ "$skipv1" != "False" ]; then
      fails="${fails}${fails:+; }(5) genesis SkipV1Validation is not confirmed false (got '$skipv1') -- forbidden, masks V1 validation"
    fi
  fi

  # ---- condition (1): independent witness quorum (>=3) all agree candAddr minted H ----
  local -a wpairs
  IFS=',' read -ra wpairs <<< "$witnesses_csv"
  if [ "${#wpairs[@]}" -lt 3 ]; then
    fails="${fails}${fails:+; }(1) need >=3 independent witnesses (>=2 other validators + 1 oldxdc observer; candidate's own node inadmissible), got ${#wpairs[@]}"
  fi
  local pair name url miner w_mismatches=""
  for pair in "${wpairs[@]}"; do
    name=$(_pair_name "$pair"); url=$(_pair_url "$pair")
    miner=$(_assert_block_miner "$url" "$h") || miner=""
    if [ -z "$miner" ]; then
      w_mismatches="${w_mismatches}${w_mismatches:+, }${name}=<unreachable/no-block>"
    elif [ "$miner" != "$cand_norm" ]; then
      w_mismatches="${w_mismatches}${w_mismatches:+, }${name}=${miner}"
    fi
  done
  [ -n "$w_mismatches" ] && fails="${fails}${fails:+; }(1) witness quorum disagrees at H=$h (expected $cand_norm): $w_mismatches"

  # ---- condition (2): all running clients hash-agree at H ----
  local -a hpairs
  IFS=',' read -ra hpairs <<< "$hashnodes_csv"
  if [ "${#hpairs[@]}" -lt 2 ]; then
    fails="${fails}${fails:+; }(2) need >=2 name=url in hashnodes_csv (every running node, candidate included -- 'agreement' needs at least 2 parties), got ${#hpairs[@]}"
  else
    local hash_out hash_rc
    hash_out=$(assert_hash_agreement "$h" "${hpairs[@]}")
    hash_rc=$?
    [ "$hash_rc" -eq 0 ] || fails="${fails}${fails:+; }(2) ${hash_out#FAIL: }"

    # ---- condition (3): stays canonical -- tip reaches H+3, H+1 parents to H ----
    # reference = the first hashnodes entry; captures H's hash BEFORE
    # waiting so a later reorg-away is detectable as a hash CHANGE, not just
    # a re-read of whatever is canonical by the time we look.
    local ref_url ref_h_hash
    ref_url=$(_pair_url "${hpairs[0]}")
    ref_h_hash=$(lab_block_hash "$ref_url" "$h") || ref_h_hash=""
    local target=$((h + 3))
    if ! lab_wait_block "$ref_url" "$target" "${MINT_CANON_TIMEOUT:-300}"; then
      fails="${fails}${fails:+; }(3) reference $(_pair_name "${hpairs[0]}") never reached tip>=H+3 ($target) to confirm H=$h stayed canonical"
    else
      local now_h_hash blockp1 hp1_parent
      now_h_hash=$(lab_block_hash "$ref_url" "$h") || now_h_hash=""
      if [ -z "$now_h_hash" ] || [ "$now_h_hash" != "$ref_h_hash" ]; then
        fails="${fails}${fails:+; }(3) H=$h hash CHANGED after reaching tip>=H+3 (${ref_h_hash:-<miss>} -> ${now_h_hash:-<miss>}) -- reorged away, not canonical"
      fi
      blockp1=$(lab_rpc_call "$ref_url" eth_getBlockByNumber "[\"$(printf '0x%x' $((h + 1)))\",false]") || blockp1=""
      hp1_parent=$(python3 -c "
import json
import sys

b = json.loads(sys.argv[1]) if sys.argv[1] else None
print(b.get('parentHash', '') if b else '')
" "$blockp1" 2>/dev/null)
      if [ -z "$hp1_parent" ] || [ "$hp1_parent" != "$now_h_hash" ]; then
        fails="${fails}${fails:+; }(3) H+1 does not parent to H=$h (H+1.parentHash=${hp1_parent:-<miss>} vs H.hash=${now_h_hash:-<miss>})"
      fi
    fi
  fi

  # ---- condition (4): no swallowed validation bypass on EVERY running node's log ----
  local -a lpairs
  IFS=',' read -ra lpairs <<< "$lognodes_csv"
  if [ "${#lpairs[@]}" -lt 1 ]; then
    fails="${fails}${fails:+; }(4) need >=1 name=logfile in lognodes_csv"
  else
    local lname lfile bypass_out
    for pair in "${lpairs[@]}"; do
      lname=$(_pair_name "$pair"); lfile=$(_pair_url "$pair")
      bypass_out=$(assert_no_validation_bypass "$lname" "$lfile") || fails="${fails}${fails:+; }(4) ${bypass_out#FAIL: }"
    done
  fi

  if [ -z "$fails" ]; then
    _assert_pass "mint-accepted: $cand_norm minted H=$h -- witness quorum agrees, all clients hash-agree, canonical past H+3, no validation bypass, skipV1Validation=false"
  else
    _assert_fail "mint-accepted: $cand_norm at H=$h -- $fails"
  fi
}

# ---------------------------------------------------------------------------
# assert_mint_share <from> <to> <name=url,...> <addr,...> [tol=0.3]
#
# P9 (reward/block fair-share): over the closed block range [from,to],
# reads each block's `miner` from the FIRST reachable reference in
# <name=url,...> (tries each in order per block -- resilient to any single
# reference being briefly down; this is NOT the hash-agreement check, see
# assert_hash_agreement/assert_mint_accepted condition 2 for that), tallies
# how many blocks each address in <addr,...> minted, and asserts every
# address's share is within relative tolerance `tol` (default 0.3 = 30%) of
# the expected even 1/N share -- NOT an exact-equality check: V1 round-robin
# can legitimately skip a turn (penalty/gap mechanics), so a wide default
# tolerance is deliberate; tighten it for a scenario that wants a stricter
# bound. A miner address NOT in <addr,...> is simply not tallied against any
# bucket (still counted toward the total block count used for the expected
# share), so an unexpected signer doesn't skew the fairness math for the
# addresses actually being checked -- pair this with assert_v1_turn_order
# if "no unexpected signer at all" is also a requirement.
# ---------------------------------------------------------------------------
assert_mint_share() {
  [ $# -ge 4 ] || { _assert_fail "assert_mint_share: usage: assert_mint_share <from> <to> <name=url,...> <addr,...> [tol]"; return 1; }
  local from="$1" to="$2" refs_csv="$3" addrs_csv="$4" tol="${5:-0.3}"
  [ "$to" -ge "$from" ] 2>/dev/null || { _assert_fail "assert_mint_share: to ($to) must be >= from ($from)"; return 1; }

  local -a refpairs addrs
  IFS=',' read -ra refpairs <<< "$refs_csv"
  IFS=',' read -ra addrs <<< "$addrs_csv"
  [ "${#refpairs[@]}" -ge 1 ] || { _assert_fail "assert_mint_share: need >=1 name=url reference"; return 1; }
  [ "${#addrs[@]}" -ge 1 ] || { _assert_fail "assert_mint_share: need >=1 address"; return 1; }

  local -A counts
  local a key
  for a in "${addrs[@]}"; do counts["$(_addr_norm "$a")"]=0; done

  local h pair url miner got total=0 unreachable=0
  for ((h = from; h <= to; h++)); do
    got=""
    for pair in "${refpairs[@]}"; do
      url=$(_pair_url "$pair")
      miner=$(_assert_block_miner "$url" "$h") && [ -n "$miner" ] && { got="$miner"; break; }
    done
    if [ -z "$got" ]; then
      unreachable=$((unreachable + 1))
      continue
    fi
    total=$((total + 1))
    if [ -n "${counts[$got]+x}" ]; then
      counts[$got]=$((counts[$got] + 1))
    fi
  done

  local n=$((to - from + 1))
  [ "$total" -gt 0 ] || { _assert_fail "assert_mint_share H=$from..$to: no readable blocks (all $n unreachable across ${#refpairs[@]} reference(s))"; return 1; }

  local expect; expect=$(python3 -c "print($total/${#addrs[@]})")
  local report="" bad="" c within
  for a in "${addrs[@]}"; do
    key=$(_addr_norm "$a")
    c="${counts[$key]}"
    report="${report}${report:+, }${key:0:10}=$c"
    within=$(python3 -c "
c = $c
expect = $expect
tol = $tol
print('yes' if abs(c - expect) <= tol * expect else 'no')
")
    [ "$within" = "yes" ] || bad="${bad}${bad:+, }${key:0:10}(got $c, want ~${expect} +/-${tol})"
  done

  if [ -z "$bad" ]; then
    _assert_pass "mint-share H=$from..$to: fair share within tol=$tol of expected~${expect} each ($report)$( [ "$unreachable" -gt 0 ] && printf '; %s/%s block(s) unreadable' "$unreachable" "$n")"
  else
    _assert_fail "mint-share H=$from..$to: out of tolerance (tol=$tol, expected~${expect} each): $bad ($report)"
  fi
}

# ---------------------------------------------------------------------------
# assert_v1_turn_order <from> <to> <name=url> <addr,addr,...>
#
# P3 (V1 turn/difficulty correctness), checked WITHOUT hardcoding XDPoS's
# internal round-robin index formula (which reorders per epoch via
# EpocBlockRandomize -- reproducing that exactly here would risk asserting
# a formula rather than the actual observed guarantee): over [from,to], read
# via <name=url>
#   - every miner is one of <addr,...> (an unexpected signer outside the
#     given masternode set is a hard FAIL, not just noise)
#   - no two CONSECUTIVE blocks share the same miner (no immediate repeat --
#     round robin's most basic guarantee)
#   - each successive window of N=len(addr,...) blocks is a clean
#     permutation of the full address set (every signer gets exactly one
#     turn per cycle, not just "eventually fair" in aggregate -- that
#     looser aggregate check is assert_mint_share's job instead)
# A trailing partial window (when (to-from+1) isn't a multiple of N) is
# simply not checked as a window -- its blocks still go through the
# no-repeat/no-unexpected-signer checks above.
# ---------------------------------------------------------------------------
assert_v1_turn_order() {
  [ $# -ge 4 ] || { _assert_fail "assert_v1_turn_order: usage: assert_v1_turn_order <from> <to> <name=url> <addr,addr,...>"; return 1; }
  local from="$1" to="$2" pair="$3" addrs_csv="$4"
  local name url
  name=$(_pair_name "$pair"); url=$(_pair_url "$pair")
  [ "$to" -ge "$from" ] 2>/dev/null || { _assert_fail "assert_v1_turn_order: to ($to) must be >= from ($from)"; return 1; }

  local -a addrs
  IFS=',' read -ra addrs <<< "$addrs_csv"
  local n="${#addrs[@]}"
  [ "$n" -ge 1 ] || { _assert_fail "assert_v1_turn_order: need >=1 address"; return 1; }

  local -A known
  local a
  for a in "${addrs[@]}"; do known["$(_addr_norm "$a")"]=1; done

  local -a window=()
  local h prev="" miner unexpected="" repeats="" bad_windows=""
  for ((h = from; h <= to; h++)); do
    miner=$(_assert_block_miner "$url" "$h") || miner=""
    if [ -z "$miner" ]; then
      _assert_fail "v1-turn-order: $name -- block $h unreadable"
      return 1
    fi
    if [ -z "${known[$miner]+x}" ]; then
      unexpected="${unexpected}${unexpected:+, }$h=$miner"
    fi
    if [ -n "$prev" ] && [ "$miner" = "$prev" ]; then
      repeats="${repeats}${repeats:+, }$h(same signer as $((h - 1)): $miner)"
    fi
    prev="$miner"
    window+=("$miner")
    if [ "${#window[@]}" -eq "$n" ]; then
      local uniq_count; uniq_count=$(printf '%s\n' "${window[@]}" | sort -u | wc -l | tr -d ' ')
      if [ "$uniq_count" -ne "$n" ]; then
        bad_windows="${bad_windows}${bad_windows:+; }[$((h - n + 1))..$h]=$(printf '%s,' "${window[@]}")"
      fi
      window=()
    fi
  done

  local fails=""
  [ -n "$unexpected" ]  && fails="${fails}${fails:+; }unexpected signer(s) outside the given set: $unexpected"
  [ -n "$repeats" ]     && fails="${fails}${fails:+; }immediate repeat(s) (same signer twice in a row): $repeats"
  [ -n "$bad_windows" ] && fails="${fails}${fails:+; }cycle(s) not a clean rotation of all $n signers: $bad_windows"

  if [ -z "$fails" ]; then
    _assert_pass "v1-turn-order: $name H=$from..$to -- clean round-robin over $n signers, no repeats, no unexpected signer"
  else
    _assert_fail "v1-turn-order: $name H=$from..$to -- $fails"
  fi
}
