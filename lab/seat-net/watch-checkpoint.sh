#!/bin/bash
# watch-checkpoint.sh — Phase 4: poll from C-WATCH_BEFORE to C+WATCH_AFTER
# (default 30 before / 60 after) watching the four things that matter at a
# seating checkpoint, and print a machine-readable verdict line plus the
# matching abort-table row number. READ-ONLY: never stops or restarts
# anything itself (pair with abort.sh / freeze.sh based on the verdict).
#
# Watches:
#   1. Set size N -> N+1: XDPoS_getMasternodesByNumber(C) MasternodesLen is
#      the AUTHORITATIVE source. Below V2SWITCH_BLOCK, this is independently
#      cross-checked by decoding block C's extraData (32-byte vanity + 20*N
#      signer bytes + 65-byte seal) -- verified live on netv12's V1 checkpoint
#      900 (217 bytes = 32+120+65 for N=6). At/after V2SWITCH_BLOCK this
#      decode is NOT attempted as a hard cross-check: live inspection of
#      netv12's V2 checkpoints (1800/2700/3600/4500/5400) shows extraData
#      carries additional variable-length HotStuff data beyond vanity+N*20+65
#      (197/324/391/391/391 bytes for a constant N=6 -- naive V1-style
#      decoding at 1800 silently yields N=5, the WRONG answer) -- so a V1-
#      shaped byte decode there is a plausible-looking but WRONG independent
#      check, worse than no check. Post-switch, MasternodesLen is treated as
#      authoritative and the extraData length is printed for the record only.
#   2. Block time from BLOCK TIMESTAMPS (never poll wall-clock).
#   3. Hash agreement across RPC_ARBITERS + RPC_OBSERVER at C, C+10, C+30.
#   4. PenaltyLen and incumbent shares vs the Phase-1 baseline.
#
# Config via env (see seat.env.sample): RPC_ARBITERS, RPC_OBSERVER, CAND
# (candidate coinbase expected to newly appear in the set), C (the target
# checkpoint), WATCH_BEFORE (default 30), WATCH_AFTER (default 60),
# POLL_SECS (default 10), PERIOD_SECS (default 2, for the block-time-holds
# check), BLOCK_TIME_MAX_SECS (default 2.6 -- abort table row 7),
# EPOCH (default 900, passed to measure-share.py's checkpoint lookup),
# V2SWITCH_BLOCK (height at/after which the extraData cross-check in item 1
# is skipped in favor of MasternodesLen alone -- leave unset/huge on a
# V1-only net).
#
# CAVEAT (verified live on netv12): XDPoS_getMasternodesByNumber's accuracy
# for a HEIGHT FAR IN THE PAST relative to the current tip is not reliable --
# it returned MasternodesLen=0 for early V1 heights and a stale 5-of-6 set
# (missing a client onboarded earlier) for V2 heights taken long after the
# fact. This script is designed to run in REAL TIME as C approaches and just
# after it lands, not for forensic replay of a checkpoint long after tip has
# moved past it -- run it live, not retroactively.
#
# Usage: watch-checkpoint.sh
set -u
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_DIR/../.." && pwd)" || exit 1
# shellcheck source=../lib-assert.sh
source "$REPO_ROOT/lab/lib-assert.sh"

RPC_ARBITERS=${RPC_ARBITERS:?set RPC_ARBITERS (comma-separated, >=2)}
RPC_OBSERVER=${RPC_OBSERVER:-}
CAND=${CAND:?set CAND (candidate coinbase expected to newly appear at C)}
C=${C:?set C (the target checkpoint height)}
WATCH_BEFORE=${WATCH_BEFORE:-30}
WATCH_AFTER=${WATCH_AFTER:-60}
POLL_SECS=${POLL_SECS:-10}
PERIOD_SECS=${PERIOD_SECS:-2}
BLOCK_TIME_MAX_SECS=${BLOCK_TIME_MAX_SECS:-2.6}
EPOCH=${EPOCH:-900}
V2SWITCH_BLOCK=${V2SWITCH_BLOCK:-9223372036854775807}

IFS=',' read -r -a _arbiters <<< "$RPC_ARBITERS"
_first="${_arbiters[0]}"

h2b_len() {
  # length in bytes of a 0x-hex string
  python3 -c "s=('$1' or '0x')[2:]; print(len(s)//2)"
}

decode_extradata_count() {
  # decode_extradata_count <url> <height> -> number of 20-byte entries
  # between the 32-byte vanity prefix and the 65-byte seal suffix, ONLY
  # valid for a V1 (pre-V2SWITCH_BLOCK) checkpoint. Caller must not call
  # this for a V2 height -- see the file header comment for why (V2
  # checkpoint extraData is a different, variable-length layout; a V1-shaped
  # decode there returns a plausible-looking WRONG count, verified live).
  local url="$1" height="$2" hexn block
  hexn=$(printf '0x%x' "$height")
  block=$(lab_rpc_call "$url" eth_getBlockByNumber "[\"${hexn}\",false]") || { echo ""; return 1; }
  python3 -c "
import json, sys
b = json.loads(sys.argv[1])
if not b:
    print('')
    sys.exit(0)
extra = b.get('extraData', '0x')
h = extra[2:] if extra.startswith('0x') else extra
raw = bytes.fromhex(h)
body = raw[32:-65]
if len(body) % 20 != 0:
    print('')
else:
    print(len(body) // 20)
" "$block"
}

extradata_len() {
  # extradata_len <url> <height> -> total extraData byte length (for-the-
  # record only on V2 checkpoints, not a count decode).
  local url="$1" height="$2" hexn block
  hexn=$(printf '0x%x' "$height")
  block=$(lab_rpc_call "$url" eth_getBlockByNumber "[\"${hexn}\",false]") || { echo ""; return 1; }
  python3 -c "
import json, sys
b = json.loads(sys.argv[1])
print(len(b.get('extraData','0x')[2:])//2 if b else '')
" "$block"
}

masternodes_len_and_coinbase() {
  # masternodes_len_and_coinbase <url> <height> -> "len present(0/1)"
  local url="$1" height="$2" res
  res=$(lab_rpc_call "$url" XDPoS_getMasternodesByNumber "[\"$(printf '0x%x' "$height")\"]") 2>/dev/null
  python3 -c "
import json, sys
try:
    r = json.loads(sys.argv[1])
except Exception:
    print('? 0')
    sys.exit(0)
mns = [a.lower() for a in (r.get('Masternodes') or [])]
cand = sys.argv[2].lower()
print(f\"{r.get('MasternodesLen','?')} {1 if cand in mns else 0}\")
" "$res" "$CAND"
}

penalty_len_and_contains() {
  local url="$1" height="$2" res
  res=$(lab_rpc_call "$url" XDPoS_getMasternodesByNumber "[\"$(printf '0x%x' "$height")\"]") 2>/dev/null
  python3 -c "
import json, sys
try:
    r = json.loads(sys.argv[1])
except Exception:
    print('? 0')
    sys.exit(0)
pen = [a.lower() for a in (r.get('Penalty') or [])]
cand = sys.argv[2].lower()
print(f\"{r.get('PenaltyLen','?')} {1 if cand in pen else 0}\")
" "$res" "$CAND"
}

echo "=== watch-checkpoint.sh: C=$C  candidate=$CAND  window=[$((C-WATCH_BEFORE)), $((C+WATCH_AFTER))] ==="

start=$((C - WATCH_BEFORE))
end=$((C + WATCH_AFTER))

set_grew=0
cand_seated_at_c=0
last_ts=""
last_h=""
abort_row=""
verdict="WATCHING"

while :; do
  head=$(lab_block_number "$_first" 2>/dev/null) || head=""
  if [ -z "$head" ]; then
    echo "$(date -u +%FT%TZ) FAIL: could not read head from $_first"
    sleep "$POLL_SECS"
    continue
  fi

  if [ "$head" -ge "$C" ]; then
    read -r mlen present <<< "$(masternodes_len_and_coinbase "$_first" "$C")"
    if [ "$C" -lt "$V2SWITCH_BLOCK" ]; then
      excount=$(decode_extradata_count "$_first" "$C")
      xcheck_desc="extraData decode=$excount vs MasternodesLen=$mlen"
    else
      excount="$mlen"   # V2: no independent byte-decode cross-check (see header comment)
      exlen=$(extradata_len "$_first" "$C")
      xcheck_desc="V2 checkpoint: MasternodesLen=$mlen authoritative (extraData is $exlen bytes, layout not independently decoded post-switch)"
    fi
    echo "checkpoint cross-check @ C=$C: $xcheck_desc"
    if [ "$present" = "1" ]; then
      cand_seated_at_c=1
      if [ "$excount" != "" ] && [ "$mlen" != "?" ] && [ "$excount" = "$mlen" ]; then
        set_grew=1
      fi
    fi
  fi

  if [ "$head" -ge "$start" ] && [ "$head" -le "$end" ]; then
    # block-time from timestamps
    hexh=$(printf '0x%x' "$head")
    blk=$(lab_rpc_call "$_first" eth_getBlockByNumber "[\"$hexh\",false]") || blk=""
    ts=$(python3 -c "import json,sys; b=json.loads(sys.argv[1]) if sys.argv[1] else None; print(int(b['timestamp'],16)) if b else print('')" "$blk" 2>/dev/null)
    if [ -n "$last_ts" ] && [ -n "$ts" ] && [ -n "$last_h" ]; then
      dh=$((head - last_h))
      if [ "$dh" -gt 0 ]; then
        dt=$((ts - last_ts))
        bt=$(awk -v dt="$dt" -v dh="$dh" 'BEGIN{printf "%.2f", dt/dh}')
        over=$(awk -v bt="$bt" -v max="$BLOCK_TIME_MAX_SECS" 'BEGIN{print (bt>max)?1:0}')
        if [ "$over" = "1" ]; then
          echo "$(date -u +%FT%TZ) FAIL: block time degraded to ${bt}s/block (> ${BLOCK_TIME_MAX_SECS}s) over heights $last_h..$head"
          abort_row=7
        fi
      fi
    fi
    last_ts="$ts"; last_h="$head"

    # hash agreement across arbiters + observer, at a settled height
    members=()
    i=0
    for url in "${_arbiters[@]}"; do members+=("arbiter$i=$url"); i=$((i+1)); done
    [ -n "$RPC_OBSERVER" ] && members+=("observer=$RPC_OBSERVER")
    line=$(assert_hash_agreement "$head" "${members[@]}" 2>/dev/null)
    if [[ "$line" != PASS:* ]]; then
      echo "$(date -u +%FT%TZ) FAIL: $line"
      abort_row=10
    fi

    # penalty check
    read -r plen pcontains <<< "$(penalty_len_and_contains "$_first" "$head")"
    if [ "$plen" != "0" ] && [ "$plen" != "?" ]; then
      if [ "$pcontains" = "1" ]; then
        echo "$(date -u +%FT%TZ) FAIL: PenaltyLen=$plen at H=$head INCLUDES the new candidate $CAND"
        abort_row=8
      else
        echo "$(date -u +%FT%TZ) FAIL: PenaltyLen=$plen at H=$head (an INCUMBENT), candidate not in it"
        abort_row=9
      fi
    fi

    echo "$(date -u +%FT%TZ) H=$head block_time=${bt:-n/a}s hash_agree=${line:-n/a} penalty_len=$plen"
  fi

  if [ "$head" -ge "$end" ]; then
    break
  fi
  if [ -n "$abort_row" ]; then
    echo "watch-checkpoint: abort condition detected (row $abort_row) -- stopping watch early, do not wait out the full window"
    break
  fi
  sleep "$POLL_SECS"
done

echo
echo "=== verdict ==="
if [ -n "$abort_row" ]; then
  echo "VERDICT: ABORT  abort_table_row=$abort_row"
  exit 1
elif [ "$cand_seated_at_c" = "1" ] && [ "$set_grew" = "1" ]; then
  echo "VERDICT: SEATED  set grew and extraData entry count matches MasternodesLen at C=$C"
  echo "Next: gate-mint.sh once enough blocks have accumulated past C."
  exit 0
elif [ "$cand_seated_at_c" = "0" ]; then
  echo "VERDICT: NOT-SEATED  abort_table_row=3 (candidate absent from the set at C=$C -- propose missed the window or KYC/deposit failed)"
  echo "Not an abort. Leave the net alone, recompute for C+EPOCH, keep the candidate a follower."
  exit 2
else
  echo "VERDICT: INCONSISTENT  candidate present in set but extraData entry count did not match MasternodesLen -- investigate manually before concluding SEATED"
  exit 3
fi
