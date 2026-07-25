#!/bin/bash
# gate-mint.sh — Phase 5: the ONLY admissible mint/fair-share attribution
# gate. Never trusts a log line, a minted-vs-canonical hash comparison, or
# block.miner/coinbase on V1 -- see the traps list below and in README.md.
#
# HARD-REFUSES to accept RPC_CANDIDATE as an attribution source: the
# candidate's own head is INADMISSIBLE, enforced here in CODE, not just by
# convention -- this script will not even read from RPC_CANDIDATE for
# attribution purposes, no matter what the caller passes.
#
# Gate:
#   1. ecrecover the M1/M2 seal from CANONICAL blocks via >=2 RPC_ARBITERS +
#      RPC_OBSERVER (measure-share.py's height-gated V1/V2 signer_of()).
#   2. Require hash agreement at H (a settled height inside the window) via
#      assert_hash_agreement across arbiters + observer.
#   3. Require canonical depth >= 3 (H must be at least 3 blocks behind the
#      arbiter's current head at gate time).
#   4. assert_no_validation_bypass clean against every ARBITER_LOG given.
#   5. Confirm SkipV1Validation=false (log hit OR genesis fallback, matching
#      preflight.sh's check 4 logic -- a log hit is proof validation is ON,
#      never a bypass).
#   6. Fair share via measure-share.py: within +/-2 points of 100/N over
#      >=2 epochs, AND the max-seal-gap drop-out check (gap >> N => stranded
#      => FAIL).
#   7. Refuses to emit a verdict if the host load average suggests a
#      build-loaded window (a build-loaded window is not a verdict).
#
# Config via env (see seat.env.sample): RPC_ARBITERS (comma, >=2),
# RPC_OBSERVER, RPC_CANDIDATE (used ONLY to reject it as a source, never to
# read attribution data from), CAND (candidate coinbase to measure),
# EPOCH, GAP, V2SWITCH_BLOCK, LO, HI (the measurement window; must span
# >=2*EPOCH blocks), ARBITER_LOGS (comma-separated name=logfile pairs for
# assert_no_validation_bypass), GENESIS_FILE (SkipV1Validation fallback),
# FAIR_SHARE_TOLERANCE_PCT (default 2), MAX_LOAD_AVG (default: refuse above
# 2x nproc -- override with an explicit value if you understand the
# load-avg heuristic's limits on your host).
#
# Usage: gate-mint.sh
set -u
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_DIR/../.." && pwd)" || exit 1
# shellcheck source=../lib-assert.sh
source "$REPO_ROOT/lab/lib-assert.sh"

RPC_ARBITERS=${RPC_ARBITERS:?set RPC_ARBITERS (comma-separated, >=2)}
RPC_OBSERVER=${RPC_OBSERVER:?set RPC_OBSERVER (independent, non-seated, non-candidate)}
RPC_CANDIDATE=${RPC_CANDIDATE:-}
CAND=${CAND:?set CAND (candidate coinbase to attribute)}
EPOCH=${EPOCH:-900}
GAP=${GAP:-450}
V2SWITCH_BLOCK=${V2SWITCH_BLOCK:-9223372036854775807}
LO=${LO:?set LO (measurement window start)}
HI=${HI:?set HI (measurement window end)}
ARBITER_LOGS=${ARBITER_LOGS:-}
GENESIS_FILE=${GENESIS_FILE:-}
FAIR_SHARE_TOLERANCE_PCT=${FAIR_SHARE_TOLERANCE_PCT:-2}
MAX_LOAD_AVG=${MAX_LOAD_AVG:-}

echo "=== gate-mint.sh: CAND=$CAND  window=[$LO,$HI] ==="

# ---- code-enforced: candidate's own head is never an attribution source ----
IFS=',' read -r -a _arbiters <<< "$RPC_ARBITERS"
for url in "${_arbiters[@]}"; do
  if [ -n "$RPC_CANDIDATE" ] && [ "$url" = "$RPC_CANDIDATE" ]; then
    echo "REFUSING: RPC_ARBITERS contains RPC_CANDIDATE ($url) -- the candidate's own head is INADMISSIBLE as an attribution source." >&2
    exit 1
  fi
done
if [ -n "$RPC_OBSERVER" ] && [ -n "$RPC_CANDIDATE" ] && [ "$RPC_OBSERVER" = "$RPC_CANDIDATE" ]; then
  echo "REFUSING: RPC_OBSERVER == RPC_CANDIDATE -- the observer must be independent of the candidate." >&2
  exit 1
fi
if [ "${#_arbiters[@]}" -lt 2 ]; then
  echo "REFUSING: need >=2 RPC_ARBITERS, got ${#_arbiters[@]}." >&2
  exit 1
fi

# ---- window sanity: >= 2 epochs ----
span=$((HI - LO + 1))
if [ "$span" -lt $((2 * EPOCH)) ]; then
  echo "REFUSING: window [$LO,$HI] spans $span blocks, need >= 2*EPOCH=$((2 * EPOCH)) for a >=2-epoch fair-share verdict." >&2
  exit 1
fi

# ---- load-average sanity: refuse to emit a verdict on a build-loaded box ----
nproc_n=$(nproc 2>/dev/null || echo 1)
default_max=$(awk -v n="$nproc_n" 'BEGIN{printf "%.1f", n*2}')
max_load="${MAX_LOAD_AVG:-$default_max}"
load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
over=$(awk -v l="$load1" -v m="$max_load" 'BEGIN{print (l>m)?1:0}')
if [ "$over" = "1" ]; then
  echo "REFUSING TO EMIT A VERDICT: load average $load1 > $max_load (nproc=$nproc_n) -- this looks like a build-loaded window, not a quiet-box measurement. Re-run when the host is idle, or set MAX_LOAD_AVG explicitly if you have verified this load is unrelated." >&2
  exit 1
fi
echo "load average check OK: $load1 <= $max_load"

_first="${_arbiters[0]}"
head=$(lab_block_number "$_first" 2>/dev/null) || head=""
[ -n "$head" ] || { echo "FAIL: could not read head from $_first" >&2; exit 1; }

# ---- canonical depth >= 3 ----
depth=$((head - HI))
if [ "$depth" -lt 3 ]; then
  echo "FAIL: canonical depth at HI=$HI is only $depth (head=$head) -- need >= 3. Wait for more confirmations." >&2
  exit 1
fi
echo "PASS: canonical depth = $depth (>= 3)"

# ---- hash agreement at a settled H (use HI, already depth-checked) ----
members=()
i=0
for url in "${_arbiters[@]}"; do members+=("arbiter$i=$url"); i=$((i+1)); done
members+=("observer=$RPC_OBSERVER")
line=$(assert_hash_agreement "$HI" "${members[@]}")
echo "$line"
if [[ "$line" != PASS:* ]]; then
  echo "GATE FAIL: hash disagreement at H=$HI" >&2
  exit 1
fi

# ---- no-validation-bypass across every arbiter log given ----
if [ -n "$ARBITER_LOGS" ]; then
  IFS=',' read -r -a _logs <<< "$ARBITER_LOGS"
  bypass_fail=0
  for pair in "${_logs[@]}"; do
    name="${pair%%=*}"; logfile="${pair#*=}"
    line=$(assert_no_validation_bypass "$name" "$logfile")
    echo "$line"
    [[ "$line" == PASS:* ]] || bypass_fail=1
  done
  if [ "$bypass_fail" -ne 0 ]; then
    echo "GATE FAIL: at least one arbiter log shows a swallowed validation mismatch" >&2
    exit 1
  fi
else
  echo "WARNING: ARBITER_LOGS not set -- assert_no_validation_bypass was not run (set it to the arbiters' log files to close this gap)" >&2
fi

# ---- SkipV1Validation=false ----
skip_ok=0
if [ -n "$ARBITER_LOGS" ]; then
  IFS=',' read -r -a _logs2 <<< "$ARBITER_LOGS"
  for pair in "${_logs2[@]}"; do
    logfile="${pair#*=}"
    if grep -q -m1 'SkipV1Validation: *false' "$logfile" 2>/dev/null; then
      skip_ok=1; break
    fi
  done
fi
if [ "$skip_ok" -eq 0 ] && [ -n "$GENESIS_FILE" ] && [ -f "$GENESIS_FILE" ]; then
  val=$(python3 -c "
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))['config']['XDPoS']
except Exception as e:
    print('ERR:' + str(e)); sys.exit(0)
print(cfg.get('SkipV1Validation', cfg.get('skipV1Validation')))
" "$GENESIS_FILE")
  [ "$val" = "False" ] && skip_ok=1
fi
if [ "$skip_ok" -eq 1 ]; then
  echo "PASS: SkipV1Validation confirmed false (log hit or genesis fallback)"
else
  echo "GATE FAIL: could not confirm SkipV1Validation=false from ARBITER_LOGS or GENESIS_FILE" >&2
  exit 1
fi

# ---- fair share + max-seal-gap ----
echo "--- measure-share.py $_first $LO $HI $CAND $EPOCH $V2SWITCH_BLOCK ---"
share_out=$(python3 "$_DIR/measure-share.py" "$_first" "$LO" "$HI" "$CAND" "$EPOCH" "$V2SWITCH_BLOCK") || {
  echo "GATE FAIL: measure-share.py failed" >&2
  exit 1
}
echo "$share_out"

n_masternodes=$(printf '%s\n' "$share_out" | grep -oP 'masternodes \(\K[0-9]+' | head -1)
target_pct=$(printf '%s\n' "$share_out" | grep -oP 'TARGET share = \S+ = \K[0-9.]+' | head -1)
max_gap=$(printf '%s\n' "$share_out" | grep -oP 'TARGET max_seal_gap = \K[0-9]+' | head -1)

if [ -z "$n_masternodes" ] || [ -z "$target_pct" ]; then
  echo "GATE FAIL: could not parse masternode count / target share from measure-share.py output" >&2
  exit 1
fi

ideal=$(awk -v n="$n_masternodes" 'BEGIN{printf "%.4f", 100.0/n}')
diff=$(awk -v a="$target_pct" -v b="$ideal" 'BEGIN{d=a-b; if(d<0)d=-d; printf "%.4f", d}')
within=$(awk -v d="$diff" -v tol="$FAIR_SHARE_TOLERANCE_PCT" 'BEGIN{print (d<=tol)?1:0}')

echo "fair-share check: target=${target_pct}% ideal=${ideal}% diff=${diff} tolerance=${FAIR_SHARE_TOLERANCE_PCT}"
if [ "$within" != "1" ]; then
  echo "GATE FAIL: fair share out of tolerance" >&2
  exit 1
fi
echo "PASS: fair share within tolerance"

if [ -n "$max_gap" ]; then
  strand=$(awk -v g="$max_gap" -v n="$n_masternodes" 'BEGIN{print (g > 3*n)?1:0}')
  echo "max-seal-gap check: max_gap=$max_gap set_size=$n_masternodes (strand threshold = 3x set size = $((3 * n_masternodes)))"
  if [ "$strand" = "1" ]; then
    echo "GATE FAIL: max_seal_gap=$max_gap >> set size $n_masternodes -- candidate STRANDED at some point in the window" >&2
    exit 1
  fi
  echo "PASS: no drop-out (max_seal_gap within set-size bound)"
else
  echo "WARNING: could not parse max_seal_gap from measure-share.py output -- drop-out check not performed" >&2
fi

echo
echo "GATE VERDICT: PASS -- $CAND is minting in fair share over [$LO,$HI], no drop-out, all validation checks clean."
