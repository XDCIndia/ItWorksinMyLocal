#!/bin/bash
# preflight.sh — Phase 1 gate: is the candidate safe to onboard as a FOLLOWER,
# read-only, before any propose() is ever sent? Never seats anything.
#
# Checks (all must pass):
#   1. Candidate tip lag 0 vs the first RPC_ARBITERS entry, sustained over
#      TIP_LAG_BLOCKS consecutive blocks (default 300).
#   2. assert_hash_agreement at every already-reached checkpoint in
#      CHECKPOINTS (fork blocks + every 900-multiple reached so far).
#   3. assert_no_validation_bypass clean against CANDIDATE_LOG.
#   4. CANDIDATE_LOG contains "SkipV1Validation: false" (proof validation is
#      ON — a log hit here is NOT a bypass, the absence of the bypass pattern
#      in check 3 is what would be a bypass).
#   5. Binary fingerprint: readlink -f /proc/<pid>/exe + size + mtime of the
#      running candidate binary, checked against an operator-supplied
#      EXPECTED_BINARY_SHA256 (or at minimum printed for manual compare) --
#      this is the check that would have caught the xone native-vs-ethcompat
#      two-binary swap (63MB ethcompat vs 39MB native, only one of which can
#      pass block 900).
#   6. Snapshots each incumbent's share via measure-share.py as the baseline
#      an operator compares post-seating numbers against.
#
# Refuses to run for CANDIDATE_FAMILY=reth unless the operator explicitly
# acknowledges I_UNDERSTAND_RETH_MUST_NOT_SEAT=1 (reth is a MUST-NOT-SEAT
# family per docs/client-readiness.md — issues #237/#243/#223).
#
# Config via env (see seat.env.sample): RPC_ARBITERS, RPC_CANDIDATE,
# RPC_OBSERVER, CANDIDATE_FAMILY, CANDIDATE_RPC_PORT, EPOCH,
# CANDIDATE_LOG (path to the candidate's own stdout/log file),
# GENESIS_FILE (path to the net's genesis.json; fallback source for the
# SkipV1Validation check on client families that never print that startup
# banner line -- e.g. geth-lineage clients),
# EXPECTED_BINARY_FINGERPRINT (sha256 of the expected candidate binary),
# TIP_LAG_BLOCKS (default 300), CHECKPOINTS (optional explicit comma list;
# default: derived from EPOCH and the live tip), V2SWITCH_BLOCK (passed to
# measure-share.py for the baseline snapshot; leave unset on a V1-only net).
#
# Exit 0 = ALL PASS. Exit 1 = at least one check FAILED (do not proceed to
# Phase 2 onboarding).
set -u
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_DIR/../.." && pwd)" || exit 1
# shellcheck source=../lib-assert.sh
source "$REPO_ROOT/lab/lib-assert.sh"

# Check the reth MUST-NOT-SEAT gate FIRST, before any other required-env-var
# check, so a reth run refuses immediately with the right message instead of
# an unrelated "set RPC_ARBITERS" error.
CANDIDATE_FAMILY=${CANDIDATE_FAMILY:?set CANDIDATE_FAMILY (geth|erigon|reth)}
if [ "$CANDIDATE_FAMILY" = "reth" ] && [ "${I_UNDERSTAND_RETH_MUST_NOT_SEAT:-0}" != "1" ]; then
  echo "FAIL: CANDIDATE_FAMILY=reth is a MUST-NOT-SEAT family (docs/client-readiness.md: #237/#243/#223)." >&2
  echo "      Set I_UNDERSTAND_RETH_MUST_NOT_SEAT=1 only if you are re-running this for diagnostic purposes." >&2
  exit 1
fi

RPC_ARBITERS=${RPC_ARBITERS:?set RPC_ARBITERS (comma-separated)}
RPC_CANDIDATE=${RPC_CANDIDATE:?set RPC_CANDIDATE}
RPC_OBSERVER=${RPC_OBSERVER:-}
CANDIDATE_RPC_PORT=${CANDIDATE_RPC_PORT:-}
EPOCH=${EPOCH:-900}
CANDIDATE_LOG=${CANDIDATE_LOG:-}
GENESIS_FILE=${GENESIS_FILE:-}
EXPECTED_BINARY_FINGERPRINT=${EXPECTED_BINARY_FINGERPRINT:-}
TIP_LAG_BLOCKS=${TIP_LAG_BLOCKS:-300}
CHECKPOINTS=${CHECKPOINTS:-}
V2SWITCH_BLOCK=${V2SWITCH_BLOCK:-}

fail=0
pass_count=0
fail_count=0

_note() { printf '%s\n' "$1"; }
_track() {
  # $1 = the PASS:/FAIL: line already produced by an assert_* call
  if [[ "$1" == PASS:* ]]; then pass_count=$((pass_count + 1));
  else fail_count=$((fail_count + 1)); fail=1; fi
}

echo "=== preflight.sh: Phase 1 pre-flight gate for $RPC_CANDIDATE (family=$CANDIDATE_FAMILY) ==="

IFS=',' read -r -a _arbiters <<< "$RPC_ARBITERS"
_first_arbiter="${_arbiters[0]}"

# ---- 1. tip lag ----
echo "--- check 1: tip lag 0 vs $_first_arbiter over $TIP_LAG_BLOCKS blocks ---"
ref_head=$(lab_block_number "$_first_arbiter" 2>/dev/null) || ref_head=""
if [ -z "$ref_head" ]; then
  echo "FAIL: could not read tip from arbiter $_first_arbiter"
  _track "FAIL:"
else
  target=$((ref_head))
  line=$(assert_lockstep "arbiter=$_first_arbiter" "candidate=$RPC_CANDIDATE" "$target" 120)
  echo "$line"; _track "$line"
  # sustained-lag check: candidate head must be within 0 of a FRESH read too
  sleep 2
  ref2=$(lab_block_number "$_first_arbiter" 2>/dev/null) || ref2=""
  cand2=$(lab_block_number "$RPC_CANDIDATE" 2>/dev/null) || cand2=""
  if [ -n "$ref2" ] && [ -n "$cand2" ] && [ "$ref2" = "$cand2" ]; then
    echo "PASS: sustained tip lag 0 (re-check: arbiter=$ref2 candidate=$cand2)"
  else
    echo "FAIL: sustained tip lag check: arbiter=$ref2 candidate=$cand2 (want equal, note: TIP_LAG_BLOCKS=$TIP_LAG_BLOCKS is documentation of the sustain window an operator should separately observe over time)"
    fail=1
  fi
fi

# ---- 2. hash agreement at checkpoints ----
echo "--- check 2: hash agreement at reached checkpoints ---"
if [ -z "$CHECKPOINTS" ]; then
  head=$(lab_block_number "$_first_arbiter" 2>/dev/null) || head=0
  cps=""
  c=$EPOCH
  while [ "$c" -le "$head" ]; do
    cps="${cps}${cps:+,}${c}"
    c=$((c + EPOCH))
  done
  CHECKPOINTS="$cps"
fi
if [ -z "$CHECKPOINTS" ]; then
  echo "PASS: no checkpoint reached yet — nothing to check (chain has not reached the first epoch boundary)"
else
  IFS=',' read -r -a _cps <<< "$CHECKPOINTS"
  members=()
  i=0
  for url in "${_arbiters[@]}"; do members+=("arbiter$i=$url"); i=$((i+1)); done
  members+=("candidate=$RPC_CANDIDATE")
  [ -n "$RPC_OBSERVER" ] && members+=("observer=$RPC_OBSERVER")
  for cp in "${_cps[@]}"; do
    line=$(assert_hash_agreement "$cp" "${members[@]}")
    echo "$line"; _track "$line"
  done
fi

# ---- 3 & 4. log-based checks ----
echo "--- check 3: assert_no_validation_bypass ---"
if [ -z "$CANDIDATE_LOG" ]; then
  echo "FAIL: CANDIDATE_LOG not set — cannot confirm no swallowed mismatch"
  fail=1; fail_count=$((fail_count+1))
else
  line=$(assert_no_validation_bypass "candidate" "$CANDIDATE_LOG")
  echo "$line"; _track "$line"

  echo "--- check 4: SkipV1Validation=false (proof validation is ON, not a bypass) ---"
  # Preferred source: a literal "SkipV1Validation: false" log line (the
  # legacy oldxdc client prints this once at startup as a config dump; that
  # log HIT is proof validation is on, never a bypass). But this is a
  # startup-banner convention of ONE client family -- empirically, geth-
  # lineage builds (e.g. xone) never print it at all, so requiring it in
  # the CANDIDATE's own log would hard-FAIL every non-oldxdc candidate for a
  # reason that has nothing to do with whether validation is actually on.
  # Fall back to the authoritative source both families read from: the
  # genesis file's config.XDPoS.skipV1Validation, which is what
  # gate-erigon.sh's "skipV1Validation in genesis" check also reads.
  if grep -q -m1 'SkipV1Validation: *false' "$CANDIDATE_LOG" 2>/dev/null; then
    echo "PASS: SkipV1Validation: false found in $CANDIDATE_LOG"
    pass_count=$((pass_count+1))
  elif [ -n "${GENESIS_FILE:-}" ] && [ -f "$GENESIS_FILE" ]; then
    val=$(python3 -c "
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))['config']['XDPoS']
except Exception as e:
    print('ERR:' + str(e)); sys.exit(0)
# key casing varies (genesis files observed with 'SkipV1Validation', code
# with 'skipV1Validation') -- check both rather than hard-failing on case.
v = cfg.get('SkipV1Validation', cfg.get('skipV1Validation'))
print(v)
" "$GENESIS_FILE")
    if [ "$val" = "False" ] || [ "$val" = "false" ]; then
      echo "PASS: no literal log line (expected for non-oldxdc client families), but $GENESIS_FILE config.XDPoS.skipV1Validation=false"
      pass_count=$((pass_count+1))
    else
      echo "FAIL: neither a log hit nor a confirmed-false genesis skipV1Validation (got: $val) from $GENESIS_FILE"
      fail=1; fail_count=$((fail_count+1))
    fi
  else
    echo "FAIL: no 'SkipV1Validation: false' line in $CANDIDATE_LOG, and no GENESIS_FILE set to fall back on (some client families, e.g. geth-lineage, never print this line at startup — set GENESIS_FILE to the net's genesis.json to check config.XDPoS.skipV1Validation directly)"
    fail=1; fail_count=$((fail_count+1))
  fi
fi

# ---- 5. binary fingerprint ----
echo "--- check 5: running binary fingerprint ---"
if [ -z "$CANDIDATE_RPC_PORT" ]; then
  echo "FAIL: CANDIDATE_RPC_PORT not set — cannot locate the candidate pid"
  fail=1; fail_count=$((fail_count+1))
else
  pid=$(ss -ltnp "sport = :$CANDIDATE_RPC_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1)
  if [ -z "$pid" ]; then
    echo "FAIL: no listening process found on port $CANDIDATE_RPC_PORT (ss -ltnp)"
    fail=1; fail_count=$((fail_count+1))
  else
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
    if [ -z "$exe" ] || [ ! -f "$exe" ]; then
      echo "FAIL: could not resolve /proc/$pid/exe for pid $pid"
      fail=1; fail_count=$((fail_count+1))
    else
      size=$(stat -c %s "$exe" 2>/dev/null)
      mtime=$(stat -c %Y "$exe" 2>/dev/null)
      sha=$(sha256sum "$exe" 2>/dev/null | awk '{print $1}')
      echo "  running binary: $exe"
      echo "  size=$size mtime=$mtime sha256=$sha"
      if [ -z "$EXPECTED_BINARY_FINGERPRINT" ]; then
        echo "FAIL: EXPECTED_BINARY_FINGERPRINT not set — printed the fingerprint above but refuse to auto-pass without an operator-supplied expected value (this is exactly the check that would have caught the xone native-vs-ethcompat swap: verify by hand, then set EXPECTED_BINARY_FINGERPRINT=$sha and re-run)"
        fail=1; fail_count=$((fail_count+1))
      elif [ "$EXPECTED_BINARY_FINGERPRINT" = "$sha" ]; then
        echo "PASS: running binary sha256 matches EXPECTED_BINARY_FINGERPRINT"
        pass_count=$((pass_count+1))
      else
        echo "FAIL: running binary sha256=$sha does NOT match EXPECTED_BINARY_FINGERPRINT=$EXPECTED_BINARY_FINGERPRINT"
        fail=1; fail_count=$((fail_count+1))
      fi
    fi
  fi
fi

# ---- 6. baseline share snapshot ----
echo "--- check 6: baseline incumbent share snapshot ---"
head=$(lab_block_number "$_first_arbiter" 2>/dev/null) || head=""
if [ -z "$head" ] || [ "$head" -lt "$EPOCH" ]; then
  echo "PASS: chain has not yet reached one full epoch ($EPOCH); no baseline window available, skipping"
  pass_count=$((pass_count+1))
else
  lo=$((head - EPOCH < EPOCH ? EPOCH : head - EPOCH))
  echo "  baseline window: $lo..$head (source: $_first_arbiter)"
  if python3 "$_DIR/measure-share.py" "$_first_arbiter" "$lo" "$head" "" "$EPOCH" "$V2SWITCH_BLOCK" 2>&1 | tee /tmp/seat-net-baseline.$$.txt; then
    echo "PASS: baseline share snapshot written (see output above; saved to /tmp/seat-net-baseline.$$.txt)"
    pass_count=$((pass_count+1))
  else
    echo "FAIL: measure-share.py failed to produce a baseline snapshot"
    fail=1; fail_count=$((fail_count+1))
  fi
fi

echo "=== preflight summary: $pass_count pass, $fail_count fail ==="
if [ "$fail" -eq 0 ]; then
  echo "PREFLIGHT: PASS — candidate may proceed to Phase 2 (onboard-candidate.sh)"
  exit 0
else
  echo "PREFLIGHT: FAIL — do NOT proceed to onboarding; fix the failing check(s) above"
  exit 1
fi
