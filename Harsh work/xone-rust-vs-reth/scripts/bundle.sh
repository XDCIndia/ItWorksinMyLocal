#!/bin/bash
# Collect raw logs + scripts into the Windows-side report folder (no chain data dirs).
set -e
B=/mnt/c/Users/harsh/itworks-assignment/xone-vs-reth
X=/home/harsh/xone-bench
mkdir -p $B/raw/run-xone $B/raw/run-xone-try1 $B/raw/run-reth $B/raw/build/attempt1-libclang-fail $B/raw/build/attempt2-success $B/raw/xone-genesis-refusals $B/scripts
cp $X/run-xone/{summary.txt,samples.csv,node.log} $B/raw/run-xone/
cp $X/run-xone-try1/{summary.txt,samples.csv,node.log} $B/raw/run-xone-try1/
cp $X/run-reth/{summary.txt,samples.csv} $B/raw/run-reth/
gzip -c $X/run-reth/node.log > $B/raw/run-reth/node.log.gz
cp /home/harsh/xone-rust/build-logs/attempt1/* $B/raw/build/attempt1-libclang-fail/
cp /home/harsh/xone-rust/build-logs/{summary.txt,build-xone.log,time.txt,toolchain.log} $B/raw/build/attempt2-success/
cp $X/xone-run1-genesis-refused/node.log $B/raw/xone-genesis-refusals/run1-tip2019Block.log
cp $X/xone-run2-switchepoch-refused/node.log $B/raw/xone-genesis-refusals/run2-SwitchEpoch.log
cp $X/reth-node-help.txt $B/raw/
{ echo "# Corruption lines from the 4 sealers after the 2026-11-13 disk-full crash (full logs not committed: 127 MB)"
  for n in xdc1 xdc2 xdc3 xdc4; do echo "== $n"
    grep -E 'Head state missing|Rewound blockchain|missing trie|corrupt' $X/crash-20261113/$n.node.log | tail -5; done
} > $B/raw/sealer-crash-evidence.txt
cp $X/genesis-20119-xone.json $B/
for f in bench2.sh analyze.py patchgen.py run-both.sh guard.sh; do cp $X/$f $B/scripts/; done
cp /mnt/c/Users/harsh/itworks-assignment/{check-sealers.sh,wipe-20119.sh} $B/scripts/
cp $B/REPORT.md $X/REPORT.md
du -sh $B; find $B -type f | sed "s|$B/||" | sort
