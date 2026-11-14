#!/bin/bash
# bench.sh <xone|reth> : run ONE client against chain 20119 from genesis, alone, and measure it.
# Output: ~/xone-bench/<client>/{samples.csv,summary.txt,node.log}
set -u
C=$1
OUT=~/xone-bench/$C; rm -rf "$OUT"; mkdir -p "$OUT"
DATA=$OUT/data
GEN=~/iwiml-20119/nodes/net20119/genesis.json
ENODES=$(python3 -c 'import json;print(",".join(json.load(open("/home/harsh/iwiml-20119/connect-20119.json"))["enodes"]))')
P2P=37000; RPC=37001
STEADY_SECS=120; MAX_SECS=2400

case $C in
  xone)
    BIN=~/xone-rust/target/release/xone
    # xOne refuses a genesis without explicit XDC fork rows: use the patched copy (patchgen.py)
    CMD=("$BIN" --override.genesis ~/xone-bench/genesis-20119-xone.json --networkid 20119 --datadir "$DATA" --bootnodes "$ENODES"
         --nodiscover --port $P2P --http --http.addr 127.0.0.1 --http.port $RPC --http.api eth,net,web3 --verbosity 3) ;;
  reth)
    BIN=~/iwiml-20119/bin/reth/Linux-x86_64/xdc-reth
    CMD=("$BIN" node --chain "$GEN" --datadir "$DATA" --port $P2P --discovery.port $P2P
         --disable-discv5-discovery --disable-dns-discovery --trusted-only --trusted-peers "$ENODES"
         --http --http.addr 127.0.0.1 --http.port $RPC --http.api eth,net,web3
         --authrpc.addr 127.0.0.1 --authrpc.port 37003) ;;
  *) echo "usage: $0 xone|reth"; exit 1;;
esac

rpc() { curl -s -m 3 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":[],\"id\":1}" http://127.0.0.1:$1 | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+'; }
num() { local v; v=$(rpc "$@"); [ -n "$v" ] && echo $((v)) || echo -1; }

{
echo "client: $C"
echo "binary: $BIN ($(stat -c %s "$BIN") bytes)"
echo "version: $("$BIN" --version 2>/dev/null | head -1)"
echo "start_tip: $(num 35001 eth_blockNumber)"
echo "start: $(date -u +%FT%TZ)"
} > "$OUT/summary.txt"

"${CMD[@]}" > "$OUT/node.log" 2>&1 &
PID=$!
HZ=$(getconf CLK_TCK)
echo "t,head,tip,peers,rss_mb,cpu_pct" > "$OUT/samples.csv"
t0=$(date +%s.%N); last_cpu=0; last_t=$t0; caught=""; peak=0
while kill -0 $PID 2>/dev/null; do
  sleep 2
  now=$(date +%s.%N); t=$(echo "$now - $t0" | bc)
  rss=$(awk '/VmRSS/{print int($2/1024)}' /proc/$PID/status 2>/dev/null); rss=${rss:-0}
  [ "$rss" -gt "$peak" ] && peak=$rss
  cpu=$(awk -v hz=$HZ '{print ($14+$15)/hz}' /proc/$PID/stat 2>/dev/null); cpu=${cpu:-0}
  pct=$(echo "scale=1; 100*($cpu - $last_cpu)/($now - $last_t)" | bc); last_cpu=$cpu; last_t=$now
  h=$(num $RPC eth_blockNumber); tip=$(num 35001 eth_blockNumber); pc=$(num $RPC net_peerCount)
  echo "$t,$h,$tip,$pc,$rss,$pct" >> "$OUT/samples.csv"
  if [ -z "$caught" ] && [ "$h" -gt 0 ] && [ $((tip - h)) -le 2 ]; then caught=$t; echo "caught_up_after_s: $t at block $h" >> "$OUT/summary.txt"; fi
  if [ -n "$caught" ] && [ "$(echo "$t - $caught > $STEADY_SECS" | bc)" = 1 ]; then break; fi
  if [ "$(echo "$t > $MAX_SECS" | bc)" = 1 ]; then echo "TIMEOUT: did not catch up in ${MAX_SECS}s (head=$h tip=$tip)" >> "$OUT/summary.txt"; break; fi
done
alive=1; kill -0 $PID 2>/dev/null || alive=0
[ $alive = 0 ] && echo "EXITED EARLY (see node.log)" >> "$OUT/summary.txt"
end_head=$(num $RPC eth_blockNumber)
hash_mine=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf 0x%x $((end_head-5)))\",false],\"id\":1}" http://127.0.0.1:$RPC | grep -oE '"hash":"0x[0-9a-f]{64}"' | head -1)
hash_ref=$(curl -s -m 3 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$(printf 0x%x $((end_head-5)))\",false],\"id\":1}" http://127.0.0.1:35001 | grep -oE '"hash":"0x[0-9a-f]{64}"' | head -1)
# polite stop: SIGTERM only
for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 $PID 2>/dev/null || break; kill -TERM $PID; sleep 3; done
{
echo "end_head: $end_head"
echo "same_hash_as_sealer_at_$((end_head-5)): $([ -n "$hash_mine" ] && [ "$hash_mine" = "$hash_ref" ] && echo YES || echo "NO ($hash_mine vs $hash_ref)")"
echo "peak_rss_mb: $peak"
echo "disk: $(du -sh "$DATA" 2>/dev/null | cut -f1)"
echo "end: $(date -u +%FT%TZ)"
} >> "$OUT/summary.txt"
python3 - "$OUT" <<'PY' >> "$OUT/summary.txt"
import csv, sys, statistics as st
rows = list(csv.DictReader(open(sys.argv[1] + "/samples.csv")))
caught = None
for r in rows:
    if int(r["head"]) > 0 and int(r["tip"]) - int(r["head"]) <= 2: caught = float(r["t"]); break
sync = [r for r in rows if caught is None or float(r["t"]) <= caught]
steady = [r for r in rows if caught is not None and float(r["t"]) > caught]
if caught and sync:
    first = next((r for r in sync if int(r["head"]) > 0), None)
    if first:
        n = int(sync[-1]["head"]) - int(first["head"]); dt = float(sync[-1]["t"]) - float(first["t"])
        print("sync_blocks_per_s: %.1f  (%d blocks in %.0fs, after first block)" % (n / dt if dt else 0, n, dt))
f = lambda xs: "%.0f" % st.median(xs) if xs else "-"
print("cpu_pct_median_sync: " + f([float(r["cpu_pct"]) for r in sync]) + "   (100 = one full core)")
print("cpu_pct_median_steady: " + f([float(r["cpu_pct"]) for r in steady]))
print("rss_mb_median_steady: " + f([int(r["rss_mb"]) for r in steady]))
PY
cat "$OUT/summary.txt"
