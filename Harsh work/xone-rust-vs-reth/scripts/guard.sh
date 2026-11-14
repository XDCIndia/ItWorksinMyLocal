#!/bin/bash
# Safety stop for the benchmark: if swap use passes 6 GB or C: drops under 8 GB,
# send the benchmarked client SIGTERM (never -9) so WSL cannot fill C: and crash again.
while true; do
  sw=$(free -m | awk '/Swap:/{print $3}')
  c=$(df -BG /mnt/c | awk 'NR==2{gsub("G","",$4); print $4}')
  if [ "$sw" -gt 6000 ] || [ "$c" -lt 8 ]; then
    for p in $(pgrep -f 'xone-bench/run-(reth|xone)/data'); do
      echo "GUARD: swap=${sw}MB C:=${c}GB -> SIGTERM pid $p ($(ps -o comm= -p $p))"
      kill -TERM "$p"
    done
    echo "GUARD TRIPPED at $(date -u +%T) swap=${sw}MB C:=${c}GB" >> ~/xone-bench/guard.log
    sleep 60
  fi
  sleep 10
done
