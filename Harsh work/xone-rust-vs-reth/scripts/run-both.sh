#!/bin/bash
# wait for chain 20119 to reach the target (+20 margin), then reth alone, then xOne alone
T=2000
blk() { curl -s -m 4 -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:35001 \
  | grep -oE '0x[0-9a-f]+'; }
while :; do h=$(blk); [ -n "$h" ] && [ $((h)) -ge $((T + 20)) ] && break; sleep 30; done
echo "chain at $((h)) -- starting reth $(date -u +%T)"
bash ~/xone-bench/bench2.sh reth $T
echo "=== reth done $(date -u +%T); 30s pause"; sleep 30
bash ~/xone-bench/bench2.sh xone $T
echo "=== xone done $(date -u +%T)"
