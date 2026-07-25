#!/bin/bash
# seat-window.sh — PURE ARITHMETIC, no side effects. Reads the live tip from
# an arbiter and prints the next K checkpoints with their gap block, blocks
# remaining, wall-clock estimate, and USABLE/CLOSED verdict.
#
# The seating rule this encodes: a candidate seats at the next EPOCH-multiple
# checkpoint C only if its propose() tx is MINED at a height strictly below
# the gap block C-GAP (the epoch-C masternode set is elected from the 0x88 SMC
# state as of the gap block). A window inside SAFETY_MARGIN_BLOCKS of the gap
# block is treated as CLOSED — never aim at the last few blocks of a window.
#
# Usable standalone as the operator's planning tool, or sourced by
# onboard-candidate.sh to pick C.
#
# Config via env (see seat.env.sample):
#   RPC_ARBITERS         comma-separated RPC URLs (>=1 used; first reachable wins)
#   EPOCH                epoch length in blocks           (default 900)
#   GAP                  gap-block offset before checkpoint (default 450)
#   SAFETY_MARGIN_BLOCKS min blocks of margin required     (default 100)
#   PERIOD_SECS          seconds/block, for wall-clock estimate (default 2)
#   K                    how many upcoming checkpoints to print (default 4)
#
# Exit 0 and print the chosen checkpoint C on the LAST stdout line if a usable
# window exists; exit 1 (printing the table but no usable C) otherwise.
set -u
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_DIR/../.." && pwd)" || exit 1
# shellcheck source=../../lib-rpc.sh
source "$REPO_ROOT/lib-rpc.sh"

RPC_ARBITERS=${RPC_ARBITERS:?set RPC_ARBITERS (comma-separated arbiter RPC URLs)}
EPOCH=${EPOCH:-900}
GAP=${GAP:-450}
SAFETY_MARGIN_BLOCKS=${SAFETY_MARGIN_BLOCKS:-100}
PERIOD_SECS=${PERIOD_SECS:-2}
K=${K:-4}

IFS=',' read -r -a _arbiters <<< "$RPC_ARBITERS"
tip=""
for url in "${_arbiters[@]}"; do
  tip=$(lab_block_number "$url" 2>/dev/null) && [ -n "$tip" ] && break
done
if [ -z "$tip" ]; then
  echo "seat-window: could not read eth_blockNumber from any of: $RPC_ARBITERS" >&2
  exit 1
fi

echo "# live tip = $tip (source: first reachable of $RPC_ARBITERS)"
echo "# epoch=$EPOCH gap=$GAP safety_margin_blocks=$SAFETY_MARGIN_BLOCKS period_secs=$PERIOD_SECS"
printf '%-12s %-16s %-18s %-16s %-10s\n' "checkpoint" "gap_block(C-GAP)" "blocks_from_tip" "wall_clock" "usable"

# first checkpoint strictly above tip
first_c=$(( ((tip / EPOCH) + 1) * EPOCH ))

chosen_c=""
c=$first_c
i=0
while [ "$i" -lt "$K" ]; do
  gapblock=$((c - GAP))
  blocks_to_gap=$((gapblock - tip))
  if [ "$blocks_to_gap" -le 0 ]; then
    verdict="NO — window already closed"
  elif [ "$blocks_to_gap" -lt "$SAFETY_MARGIN_BLOCKS" ]; then
    verdict="NO — inside safety margin ($blocks_to_gap < $SAFETY_MARGIN_BLOCKS)"
  else
    verdict="YES"
    [ -z "$chosen_c" ] && chosen_c="$c"
  fi
  wall_secs=$((blocks_to_gap * PERIOD_SECS))
  wall_min=$(awk -v s="$wall_secs" 'BEGIN{printf "%.1f", s/60}')
  printf '%-12s %-16s %-18s %-16s %-10s\n' "$c" "$gapblock" "$blocks_to_gap" "~${wall_min}min" "$verdict"
  c=$((c + EPOCH))
  i=$((i + 1))
done

if [ -n "$chosen_c" ]; then
  echo "$chosen_c"
  exit 0
else
  echo "seat-window: NO USABLE WINDOW in the next $K checkpoints from tip $tip" >&2
  exit 1
fi
