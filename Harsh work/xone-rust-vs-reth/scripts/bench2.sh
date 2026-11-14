#!/bin/bash
# bench2.sh <xone|reth> <TARGET> : run ONE client alone against chain 20119 from genesis.
# Phase 1 "sync": from start until the client's head >= TARGET (fixed block range, same for both clients).
# Phase 2 "steady": 120 s of following the live tip.
# Raw output kept in ~/xone-bench/run-<client>/ : node.log, samples.csv, summary.txt
set -u
C=$1; TARGET=$2
OUT=~/xone-bench/run-$C; rm -rf "$OUT"; mkdir -p "$OUT"
DATA=$OUT/data
ENODES=$(python3 -c 'import json;print(",".join(json.load(open("/home/harsh/iwiml-20119/connect-20119.json"))["enodes"]))')
P2P=37000; RPC=37001; STEADY_SECS=120; MAX_SECS=3600
case $C in
  xone) BIN=~/xone-rust/target/release/xone
        CMD=("$BIN" --override.genesis ~/xone-bench/genesis-20119-xone.json --networkid 20119 --datadir "$DATA"
             --bootnodes "$ENODES" --nodiscover --port $P2P --http --http.addr 127.0.0.1 --http.port $RPC
             --http.api eth,net,web3 --verbosity 3) ;;
  reth) BIN=~/iwiml-20119/bin/reth/Linux-x86_64/xdc-reth
        CMD=("$BIN" node --chain ~/iwiml-20119/nodes/net20119/genesis.json --datadir "$DATA" --port $P2P
             --discovery.port $P2P --disable-discv5-discovery --disable-dns-discovery --trusted-only
             --trusted-peers "$ENODES" --http --http.addr 127.0.0.1 --http.port $RPC --http.api eth,net,web3
             --authrpc.addr 127.0.0.1 --authrpc.port 37003) ;;
  *) echo "usage: $0 xone|reth TARGET"; exit 1;;
esac
rpc() { curl -s -m 3 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" http://127.0.0.1:$1; }
num() { local v; v=$(rpc "$@" | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+'); [ -n "$v" ] && echo $((v)) || echo -1; }
hash_at() { rpc $1 eth_getBlockByNumber "[\"$(printf 0x%x $2)\",false]" | grep -oE '"hash":"0x[0-9a-f]{64}"' | head -1 | cut -d'"' -f4; }

{ echo "client: $C"; echo "binary: $BIN ($(stat -c %s "$BIN") bytes)"
  echo "version: $("$BIN" --version 2>/dev/null | head -1)"
  echo "range: 1,800 blocks (genesis -> block $TARGET)"
  echo "target_block: $TARGET"; echo "chain_tip_at_start: $(num 35001 eth_blockNumber)"
  echo "start: $(date -u +%FT%TZ)"; } > "$OUT/summary.txt"

"${CMD[@]}" > "$OUT/node.log" 2>&1 &
PID=$!; HZ=$(getconf CLK_TCK)
echo "t,phase,head,tip,peers,rss_mb,cpu_pct" > "$OUT/samples.csv"
t0=$(date +%s.%N); last_cpu=0; last_t=$t0; phase=sync; reached=""; peak=0
while kill -0 $PID 2>/dev/null; do
  # sample every 0.2 s while syncing (xOne finishes 1,800 blocks in ~2 s), every 2 s when steady
  if [ "$phase" = sync ]; then sleep 0.2; else sleep 2; fi
  now=$(date +%s.%N); t=$(echo "$now - $t0" | bc)
  rss=$(awk '/VmRSS/{print int($2/1024)}' /proc/$PID/status 2>/dev/null); rss=${rss:-0}; [ "$rss" -gt "$peak" ] && peak=$rss
  cpu=$(awk -v hz=$HZ '{print ($14+$15)/hz}' /proc/$PID/stat 2>/dev/null); cpu=${cpu:-$last_cpu}
  pct=$(echo "scale=1; 100*($cpu - $last_cpu)/($now - $last_t)" | bc); last_cpu=$cpu; last_t=$now
  h=$(num $RPC eth_blockNumber); tip=$(num 35001 eth_blockNumber); pc=$(num $RPC net_peerCount)
  echo "$t,$phase,$h,$tip,$pc,$rss,$pct" >> "$OUT/samples.csv"
  if [ -z "$reached" ] && [ "$h" -ge "$TARGET" ]; then reached=$t; phase=steady; echo "reached_target_after_s: $t" >> "$OUT/summary.txt"; fi
  [ -n "$reached" ] && [ "$(echo "$t - $reached > $STEADY_SECS" | bc)" = 1 ] && break
  [ "$(echo "$t > $MAX_SECS" | bc)" = 1 ] && { echo "TIMEOUT: head=$h after ${MAX_SECS}s" >> "$OUT/summary.txt"; break; }
done
kill -0 $PID 2>/dev/null || echo "EXITED EARLY (see node.log)" >> "$OUT/summary.txt"
end_head=$(num $RPC eth_blockNumber)
for b in 900 1800; do
  m=$(hash_at $RPC $b); s=$(hash_at 35001 $b)
  echo "hash_match_block_$b: $([ -n "$m" ] && [ "$m" = "$s" ] && echo YES || echo "NO (client=$m sealer=$s)")" >> "$OUT/summary.txt"
done
for i in $(seq 1 10); do kill -0 $PID 2>/dev/null || break; kill -TERM $PID; sleep 3; done   # SIGTERM only
{ echo "end_head: $end_head"; echo "peak_rss_mb: $peak"
  echo "disk_mb: $(du -sm "$DATA" 2>/dev/null | cut -f1)"; echo "end: $(date -u +%FT%TZ)"; } >> "$OUT/summary.txt"
python3 ~/xone-bench/analyze.py "$OUT" "$C" "$TARGET" >> "$OUT/summary.txt"
cat "$OUT/summary.txt"
