#!/bin/bash
# Step 2b: chain 20119 sealers are corrupted after the disk-full crash -> wipe chain data, restart from genesis.
# Deletes ONLY nodes/net20119 (chain data). Logs are copied out first.
set -e
cd ~/iwiml-20119
set -a; . ./.env; set +a; export IWML_KEYPASS=iwml-20119
T=topologies/net20119.json; R=nodes/net20119
OLDGEN=$(python3 -c 'import json,sys;print(json.dumps(json.load(open(sys.argv[1]))["config"]["chainId"]))' $R/genesis.json)
old_hash=$(curl -s -m 4 -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' http://127.0.0.1:35001 | grep -oE '"hash":"0x[0-9a-f]{64}"' | cut -d'"' -f4)
echo "old genesis hash: $old_hash"

# 1. keep the evidence
K=~/xone-bench/crash-20261113; mkdir -p $K
for d in $R/*/; do n=$(basename $d); [ -f $d/node.log ] && cp $d/node.log $K/$n.node.log; done
cp $R/genesis.json $K/genesis-before-wipe.json
echo "crash logs saved to $K"

# 2. only the 4 sealers may start with the chain: push every follower's startAt out of reach
python3 - $T <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
for n in d["nodes"]:
    if n["role"] == "follower": n["startAt"] = 999999999
json.dump(d, open(p, "w"), indent=1)
print("followers parked (startAt=999999999)")
PY

# 3. stop the broken sealers + bootnode, wipe chain data, start fresh
netlab/fleet.sh down $T 2>&1 | tail -1
netlab/fleet.sh up $T --wipe > ~/xone-bench/fleet-up-after-wipe.log 2>&1
tail -6 ~/xone-bench/fleet-up-after-wipe.log
sleep 20
new_hash=$(curl -s -m 4 -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' http://127.0.0.1:35001 | grep -oE '"hash":"0x[0-9a-f]{64}"' | cut -d'"' -f4)
echo "new genesis hash: $new_hash  ($( [ "$new_hash" = "$old_hash" ] && echo SAME || echo CHANGED))"
for p in 35001 35021 35041 35061; do
  curl -s -m 4 -X POST -H 'Content-Type: application/json' --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:$p | grep -oE '0x[0-9a-f]+' | xargs printf "port $p head=%d\n"
done
