#!/bin/bash
# Run the xOne 1,800-block benchmark 3 times, alone, fresh datadir each time; keep raw output per run.
set -e
X=/home/harsh/xone-bench
[ -d $X/run-xone ] && { rm -rf $X/run-xone/data; mv $X/run-xone $X/run-xone-first; }
for i in 1 2 3; do
  echo "=== repeat $i start $(date -u +%T) | other processes: $(pgrep -c -f 'xdc-reth|xone-rust/target|geth|erigon|nethermind|besu') client(s) besides sealers"
  bash $X/bench2.sh xone 1800 > /dev/null 2>&1
  rm -rf $X/run-xone/data            # chain data only
  mv $X/run-xone $X/run-xone-r$i
  grep -E 'reached_target|sync_blocks_per_s|peak_rss|hash_match|block_time_ms' $X/run-xone-r$i/summary.txt
  sleep 15
done
