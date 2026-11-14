#!/bin/bash
# Add the repeat runs, the first single run and the earlier 5,239-block run to the report bundle.
set -e
B=/mnt/c/Users/harsh/itworks-assignment/xone-vs-reth
X=/home/harsh/xone-bench
rm -rf $B/raw/run-xone            # superseded name: that run is now raw/run-xone-first
for d in run-xone-first run-xone-r1 run-xone-r2 run-xone-r3; do
  mkdir -p $B/raw/$d; cp $X/$d/{summary.txt,samples.csv,node.log} $B/raw/$d/
done
mkdir -p $B/raw/earlier-5239-block-run
cp $X/xone/{summary.txt,samples.csv,node.log} $B/raw/earlier-5239-block-run/
cp $X/bench.sh $B/scripts/bench-v1-2s-sampling.sh
cp $B/REPORT.md $X/REPORT.md
du -sh $B; ls $B/raw
