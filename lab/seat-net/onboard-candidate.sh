#!/bin/bash
# onboard-candidate.sh — Phase 2: uploadKYC + propose() the candidate onto a
# LIVE net, computing the seating checkpoint from the live tip, then verifying
# the receipt landed inside the safe window.
#
# Wraps onboard-net/onboard.py (owner!=coinbase split: OWNER_KEY pays and
# signs, CAND is the proposed candidate/coinbase) rather than reimplementing
# the KYC/propose/isCandidate calls. Reads OWNER_KEY from OWNER_KEY_FILE into
# the environment for the single onboard.py subprocess only -- never echoes
# it, never writes it to a log or to disk anywhere else.
#
# Sequence:
#   1. seat-window.sh picks the next usable checkpoint C (refuses if none).
#   2. onboard.py both  (uploadKYC, wait, propose, wait, isCandidate)
#   3. asserts isCandidate(CAND) == true
#   4. asserts CAND appears in eth_getCandidates
#   5. asserts receipt.blockNumber < C - GAP - SAFETY_MARGIN_BLOCKS, exiting
#      non-zero ("seats at C+EPOCH instead") if not -- see abort table row 2:
#      this is NOT an abort, it just means try again for the next checkpoint.
#
# Config via env (see seat.env.sample): RPC_ARBITERS (first entry used as the
# propose RPC unless RPC override below), CHAIN_ID, SMC, DEPOSIT_WEI,
# GAS_PRICE, OWNER_KEY_FILE, CAND, EPOCH, GAP, SAFETY_MARGIN_BLOCKS, KYC_HASH
# (optional, defaults to onboard.py's own default).
#   RPC   override for the propose/onboard RPC endpoint (default: first of
#         RPC_ARBITERS)
set -u
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_DIR/../.." && pwd)" || exit 1
# shellcheck source=../../lib-rpc.sh
source "$REPO_ROOT/lib-rpc.sh"

RPC_ARBITERS=${RPC_ARBITERS:?set RPC_ARBITERS (comma-separated)}
CHAIN_ID=${CHAIN_ID:?set CHAIN_ID}
SMC=${SMC:-0x0000000000000000000000000000000000000088}
DEPOSIT_WEI=${DEPOSIT_WEI:?set DEPOSIT_WEI}
GAS_PRICE=${GAS_PRICE:-250000000}
OWNER_KEY_FILE=${OWNER_KEY_FILE:?set OWNER_KEY_FILE (path to the owner/payer private key file, never a literal key)}
CAND=${CAND:?set CAND (candidate/coinbase address to propose)}
EPOCH=${EPOCH:-900}
GAP=${GAP:-450}
SAFETY_MARGIN_BLOCKS=${SAFETY_MARGIN_BLOCKS:-100}
KYC_HASH=${KYC_HASH:-}

IFS=',' read -r -a _arbiters <<< "$RPC_ARBITERS"
RPC=${RPC:-${_arbiters[0]}}

[ -f "$OWNER_KEY_FILE" ] || { echo "onboard-candidate: OWNER_KEY_FILE not found: $OWNER_KEY_FILE" >&2; exit 1; }
case "$(stat -c %a "$OWNER_KEY_FILE" 2>/dev/null || stat -f %A "$OWNER_KEY_FILE" 2>/dev/null)" in
  600|400) ;;
  *) echo "WARNING: $OWNER_KEY_FILE is not mode 600/400 -- tighten its permissions" >&2 ;;
esac

echo "=== onboard-candidate.sh: seating window ==="
window_out=$(RPC_ARBITERS="$RPC_ARBITERS" EPOCH="$EPOCH" GAP="$GAP" \
  SAFETY_MARGIN_BLOCKS="$SAFETY_MARGIN_BLOCKS" K=4 "$_DIR/seat-window.sh")
rc=$?
echo "$window_out"
if [ "$rc" -ne 0 ]; then
  echo "onboard-candidate: no usable seating window right now -- try again later" >&2
  exit 1
fi
C=$(printf '%s\n' "$window_out" | tail -1)
GAPBLOCK=$((C - GAP))
echo "chosen checkpoint C=$C  gap_block=$GAPBLOCK"

echo "=== onboard-candidate.sh: uploadKYC + propose($CAND) via onboard.py ==="
OWNER_KEY=$(cat "$OWNER_KEY_FILE")
export RPC CHAIN_ID SMC DEPOSIT_WEI GAS_PRICE CAND OWNER_KEY
[ -n "$KYC_HASH" ] && export KYC_HASH
python3 "$REPO_ROOT/lab/onboard-net/onboard.py" both
rc=$?
unset OWNER_KEY
if [ "$rc" -ne 0 ]; then
  echo "onboard-candidate: onboard.py both FAILED (rc=$rc)" >&2
  exit 1
fi

echo "=== onboard-candidate.sh: verifying ==="

is_cand=$(RPC="$RPC" CAND="$CAND" python3 "$REPO_ROOT/lab/onboard-net/onboard.py" iscandidate 2>&1)
echo "$is_cand"
echo "$is_cand" | grep -q ' = True$' || { echo "FAIL: isCandidate($CAND) did not report True"; exit 1; }
echo "PASS: isCandidate($CAND) == true"

candidates=$(lab_get_candidates "$RPC") || candidates=""
if printf '%s\n' "$candidates" | tr ',' '\n' | grep -qi "^${CAND}$"; then
  echo "PASS: $CAND present in eth_getCandidates ($candidates)"
else
  echo "FAIL: $CAND NOT found in eth_getCandidates ($candidates)"
  exit 1
fi

# ---- receipt height vs safety margin ----
# Re-derive the propose receipt height: onboard.py "both" doesn't print it
# machine-readably, so re-fetch the most recent transaction from CAND/OWNER's
# perspective isn't reliable across clients -- instead read the pending/
# latest nonce-adjacent receipt by re-running propose's tx hash lookup is
# unnecessary: onboard.py already printed "receipt <txh> status=OK
# block=<N>" to stdout during 'both'. This script re-derives the SAME
# information the safe way: read the candidate's current tip (which is at
# or after the propose receipt, since propose was already confirmed above)
# and require it still sits below the gap block minus the safety margin --
# this is a conservative (>=) restatement of "receipt.blockNumber < C - GAP
# - SAFETY_MARGIN_BLOCKS" using the already-confirmed head as an upper bound
# on the receipt height.
head_after=$(lab_block_number "$RPC" 2>/dev/null) || head_after=""
if [ -z "$head_after" ]; then
  echo "FAIL: could not read head after propose to bound the receipt height"
  exit 1
fi
limit=$((GAPBLOCK - SAFETY_MARGIN_BLOCKS))
if [ "$head_after" -lt "$limit" ]; then
  echo "PASS: propose confirmed with head=$head_after < C-GAP-SAFETY_MARGIN_BLOCKS=$limit -- seats at C=$C"
else
  echo "FAIL: propose confirmed too late (head=$head_after >= C-GAP-SAFETY_MARGIN_BLOCKS=$limit) -- seats at C+EPOCH=$((C + EPOCH)) instead, not C=$C. Do not attempt to force it; re-plan."
  exit 1
fi

echo "onboard-candidate: DONE -- $CAND proposed, confirmed, expected to seat at C=$C"
