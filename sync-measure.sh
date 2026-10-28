#!/usr/bin/env bash
# sync-measure.sh -- measure how long a node takes to sync and how much disk it
# uses. Works for any client that answers eth_blockNumber / eth_syncing (geth,
# xone, erigon, reth, besu, nethermind, oldxdc). Polls the node's RPC and the
# size of its datadir, writes one CSV row per poll, and prints a summary when
# the node reaches the tip (and, for geth-xdc snap/fast nodes, when the post-
# sync history backfill finishes).
#
# Usage:
#   ./sync-measure.sh --rpc http://127.0.0.1:9645 --datadir nodes/geth-sync
#   ./sync-measure.sh --rpc URL --datadir DIR --log DIR.log --until history
#   ./join.sh --network mainnet --client geth --syncmode snap --measure
#
# Flags:
#   --rpc URL         node JSON-RPC endpoint (default http://127.0.0.1:9645)
#   --datadir DIR     node datadir to size (required)
#   --log FILE        node log; lets geth-xdc report the history backfill
#   --out FILE        CSV output (default DIR/sync-measure.csv)
#   --interval SECS   poll interval (default 60)
#   --until tip|history  stop at the tip (default), or after the geth-xdc
#                     history backfill completes (needs --log)
#   --pid PID         stop when this process exits (join.sh passes the node)
#   --label TEXT      free-text label written into the summary
#   --since EPOCH     count time from this unix time (default: now), for a
#                     node that was started before the measurer
#
# CSV columns: utc, elapsed_s, head, current, highest, syncing (1/0),
#   datadir_mb, ancient_mb, phase (state|blocks|tip|history|done)
# The summary is printed and also appended to DIR/sync-measure.summary.
#
# Portability: bash 3.2 (macOS) and Linux; needs only curl, du, date.

set -u
RPC="http://127.0.0.1:9645"; DIR=""; LOG=""; OUT=""; INTERVAL=60; UNTIL=tip; PID=""; LABEL=""; SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rpc)      RPC=$2; shift 2;;
    --datadir)  DIR=$2; shift 2;;
    --log)      LOG=$2; shift 2;;
    --out)      OUT=$2; shift 2;;
    --interval) INTERVAL=$2; shift 2;;
    --until)    UNTIL=$2; shift 2;;
    --pid)      PID=$2; shift 2;;
    --label)    LABEL=$2; shift 2;;
    --since)    SINCE=$2; shift 2;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done
[ -n "$DIR" ] || { echo "--datadir is required" >&2; exit 1; }
case "$UNTIL" in tip|history) ;; *) echo "--until must be tip or history" >&2; exit 1;; esac
[ "$UNTIL" = history ] && [ -z "$LOG" ] && { echo "--until history needs --log" >&2; exit 1; }
OUT=${OUT:-$DIR/sync-measure.csv}
SUMMARY="${OUT%.csv}.summary"
mkdir -p "$DIR"

# rpc METHOD -> raw JSON response body (empty on transport error)
rpc() {
  curl -s -m 10 -X POST "$RPC" -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":[],\"id\":1}" 2>/dev/null
}
# hexfield JSON NAME -> decimal value of "NAME":"0x.." (empty if absent)
hexfield() {
  local h
  h=$(printf '%s' "$1" | grep -oE "\"$2\":\"0x[0-9a-fA-F]+\"" | head -1 | grep -oE '0x[0-9a-fA-F]+')
  [ -n "$h" ] && printf '%d' "$h"
}
# size_mb PATH -> megabytes used under PATH (0 if missing)
size_mb() {
  [ -e "$1" ] || { echo 0; return; }
  du -sk "$1" 2>/dev/null | awk '{printf "%d", $1/1024}'
}
# ancient dir of a geth-style datadir, if any
ancient_dir() {
  local d
  for d in "$DIR/geth/chaindata/ancient" "$DIR/XDC/chaindata/ancient" "$DIR/chaindata/ancient"; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
}
fmt_dur() { printf '%dh%02dm%02ds' $(( $1 / 3600 )) $(( $1 % 3600 / 60 )) $(( $1 % 60 )); }

T0=${SINCE:-$(date +%s)}
[ -s "$OUT" ] || echo "utc,elapsed_s,head,current,highest,syncing,datadir_mb,ancient_mb,phase" > "$OUT"
tip_at=0; tip_head=0; tip_mb=0; hist_at=0; down=0; seen_up=0

summary() {
  local now el text
  trap '' INT TERM
  now=$(date +%s); el=$(( now - T0 ))
  text=$({
    echo "== sync-measure summary ${LABEL:+($LABEL) }$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "rpc=$RPC datadir=$DIR"
    if [ "$tip_at" -gt 0 ]; then
      echo "time to tip:   $(fmt_dur $(( tip_at - T0 ))) (head $tip_head, datadir ${tip_mb} MB)"
      [ $(( tip_at - T0 )) -gt 0 ] && echo "avg rate:      $(( tip_head / (tip_at - T0) )) blocks/s to tip"
    else
      echo "time to tip:   not reached after $(fmt_dur $el)"
    fi
    [ "$hist_at" -gt 0 ] && echo "history done:  $(fmt_dur $(( hist_at - T0 ))) (datadir $(size_mb "$DIR") MB)"
    echo "final size:    $(size_mb "$DIR") MB (ancient $(size_mb "$(ancient_dir)") MB)"
    echo "csv:           $OUT"
  })
  # Plain writes, not a pipe through tee: a Ctrl-C/timeout that signals the
  # whole process group would kill tee mid-summary.
  printf '%s\n' "$text" >> "$SUMMARY"
  printf '%s\n' "$text"
}
trap 'summary; exit 0' INT TERM

while :; do
  now=$(date +%s)
  head=$(hexfield "$(rpc eth_blockNumber)" result)
  sy=$(rpc eth_syncing)
  if [ -z "$head" ]; then
    down=$(( down + 1 ))
    # Node gone (or never came up): stop after 10 failed polls once seen, 60 before.
    if { [ "$seen_up" = 1 ] && [ $down -ge 10 ]; } || [ $down -ge 60 ]; then
      echo "node RPC unreachable for $down polls; stopping" >&2; summary; exit 1
    fi
  else
    down=0; seen_up=1
    if printf '%s' "$sy" | grep -q '"result":false'; then
      syncing=0; cur=$head; hi=$head
    else
      syncing=1; cur=$(hexfield "$sy" currentBlock); hi=$(hexfield "$sy" highestBlock)
    fi
    phase=blocks
    # Snap/fast keep the head at 0 while they download state.
    [ "$syncing" = 1 ] && [ "$head" = 0 ] && phase=state
    if [ "$syncing" = 0 ] && [ "$head" -gt 0 ]; then
      phase=tip
      if [ "$tip_at" = 0 ]; then tip_at=$now; tip_head=$head; tip_mb=$(size_mb "$DIR"); fi
    fi
    if [ -n "$LOG" ] && [ -f "$LOG" ] && [ "$tip_at" -gt 0 ]; then
      if [ "$hist_at" = 0 ] && grep -qE 'SYNC-06 (snap )?history backfill (already )?complete' "$LOG"; then hist_at=$now; fi
      if [ "$hist_at" = 0 ] && grep -q 'SYNC-06 snap history backfill starting' "$LOG"; then phase=history; fi
    fi
    [ "$hist_at" -gt 0 ] && phase=done
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$(( now - T0 )),$head,${cur:-},${hi:-},$syncing,$(size_mb "$DIR"),$(size_mb "$(ancient_dir)"),$phase" >> "$OUT"
    if [ "$UNTIL" = tip ] && [ "$tip_at" -gt 0 ]; then summary; exit 0; fi
    if [ "$UNTIL" = history ] && [ "$hist_at" -gt 0 ]; then summary; exit 0; fi
  fi
  if [ -n "$PID" ] && ! kill -0 "$PID" 2>/dev/null; then echo "node process $PID exited; stopping" >&2; summary; exit 1; fi
  sleep "$INTERVAL"
done
