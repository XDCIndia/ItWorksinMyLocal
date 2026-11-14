#!/bin/bash
# Step 2: restart chain 20119's 4 sealers on their EXISTING data and look for corruption.
cd ~/iwiml-20119
set -a; . ./.env; set +a; export IWML_KEYPASS=iwml-20119
T=topologies/net20119.json; R=nodes/net20119
rpc() { curl -s -m 4 -X POST -H 'Content-Type: application/json' --data "{\"jsonrpc\":\"2.0\",\"method\":\"$2\",\"params\":${3:-[]},\"id\":1}" http://127.0.0.1:$1; }
num() { local v; v=$(rpc "$@" | grep -oE '"result":"0x[0-9a-f]+"' | grep -oE '0x[0-9a-f]+'); [ -n "$v" ] && echo $((v)) || echo -1; }

# bootnode (moved to :35200 earlier because xone1 took 35180)
BIN=bin/oldxdc/Linux-x86_64/bootnode
IP=$(ip -4 route get 1 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
nohup "$BIN" -nodekey "$PWD/bootnode.key" -addr "${IP}:35200" > $R/bootnode.log 2>&1 < /dev/null &
echo $! > $R/bootnode.pid
echo "bootnode on ${IP}:35200"

for n in xdc1 xdc2 xdc3 xdc4; do
  cp $R/$n/node.log $R/$n/node.log.before-crash-restart 2>/dev/null
  netlab/node.sh start $T $n 2>&1 | tail -1
done
echo "waiting 90s for sealers to open their databases and resume ..."
sleep 90
declare -A P=([xdc1]=35001 [xdc2]=35021 [xdc3]=35041 [xdc4]=35061)
for n in xdc1 xdc2 xdc3 xdc4; do
  printf '%s head=%s peers=%s\n' $n "$(num ${P[$n]} eth_blockNumber)" "$(num ${P[$n]} net_peerCount)"
done
sleep 20
echo "--- 20s later:"
for n in xdc1 xdc2 xdc3 xdc4; do printf '%s head=%s\n' $n "$(num ${P[$n]} eth_blockNumber)"; done
h=$(num 35001 eth_blockNumber); c=$(( h > 5 ? h - 5 : 0 ))
echo "--- hash at block $c:"
for n in xdc1 xdc2 xdc3 xdc4; do
  printf '%s %s\n' $n "$(rpc ${P[$n]} eth_getBlockByNumber "[\"$(printf 0x%x $c)\",false]" | grep -oE '"hash":"0x[0-9a-f]{64}"' | head -1 | cut -c9-24)"
done
echo "--- corruption signs in logs since restart:"
for n in xdc1 xdc2 xdc3 xdc4; do
  hits=$(grep -ciE 'missing trie node|corrupt|bad block|invalid merkle|head state missing|rewound|Rewinding|panic|fatal' $R/$n/node.log)
  echo "$n: $hits suspicious line(s)"; grep -iE 'missing trie node|corrupt|bad block|invalid merkle|head state missing|rewound|Rewinding|panic|fatal' $R/$n/node.log | head -3 | cut -c1-200
done
free -m | sed -n 2,3p
