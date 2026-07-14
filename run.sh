#!/bin/bash
_interupt() {
    echo "Shutdown $child_proc"
    kill -TERM $child_proc
    exit
}

trap _interupt INT TERM

cd "$(dirname "$0")"
source ./lib.sh

touch .pwd
export $(cat .env | xargs)

Bin_NAME=XDC
NUM_NODES=4

# Ensure platform-native binaries exist (builds from XDPoSChain if needed).
ensure_bins
XDC="$XDC_BIN"

# Machine identity: hostname + LAN IP (advertised to peers so this works across
# machines on the same network, not just localhost).
HOST=$(hostname -s)
IP=$(detect_ip)
echo "Machine: host=$HOST ip=$IP platform=$PLATFORM"

# Import keys + init on first run, otherwise read the existing accounts.
declare -a WALLETS
if [ ! -d ./nodes/1/$Bin_NAME/chaindata ]; then
  for i in $(seq 1 $NUM_NODES); do
    pk_var="PRIVATE_KEY_$i"
    WALLETS[$i]=$("$XDC" account import --password .pwd --datadir ./nodes/$i <(echo ${!pk_var}) | awk -v FS="({|})" '{print $2}')
    "$XDC" --datadir ./nodes/$i init ./genesis/genesis.json
  done
else
  for i in $(seq 1 $NUM_NODES); do
    WALLETS[$i]=$("$XDC" account list --datadir ./nodes/$i | head -n 1 | awk -v FS="({|})" '{print $2}')
  done
fi

VERBOSITY=3
GASPRICE="1"
STATS_SECRET="xdc_openscan_stats_2026"
VERSION=$("$XDC" version 2>/dev/null | awk '/^Version:/{print $2}')
networkid=20118

# Local bootnode enode, built from bootnode.key + this machine's IP so every
# node connects to a bootnode within the network.
BOOTNODE_PUBKEY=$("$BOOTNODE_BIN" -nodekey ./bootnode.key -writeaddress)
BOOTNODE_ENODE="enode://${BOOTNODE_PUBKEY}@${IP}:30301"
echo "Local bootnode: $BOOTNODE_ENODE"

echo Starting the bootnode ...
"$BOOTNODE_BIN" -nodekey ./bootnode.key -addr ${IP}:30301 &
child_proc=$!

echo Starting the nodes ...
for i in $(seq 1 $NUM_NODES); do
  n=$(printf '%02d' $i)
  P2P_PORT=$((30302 + i))   # node1 -> 30303 ... node4 -> 30306
  WS_PORT=$((8554 + i))     # 8555 .. 8558
  RPC_PORT=$((8544 + i))    # 8545 .. 8548
  NODE_NAME="${Bin_NAME}-v${VERSION}-${HOST}-MasterNode-${n}"
  NODE_IDENTITY="${HOST}-MasterNode-${n}"
  ETHSTATS="${NODE_NAME}:${STATS_SECRET}@stats.xdcindia.com:443"
  "$XDC" --bootnodes "$BOOTNODE_ENODE" --syncmode "full" --datadir ./nodes/$i \
    --networkid "${networkid}" --port $P2P_PORT --nat "extip:${IP}" --identity "${NODE_IDENTITY}" \
    --rpc --rpccorsdomain "*" --ws --wsaddr="0.0.0.0" --wsorigins "*" --wsport $WS_PORT \
    --rpcaddr 0.0.0.0 --rpcport $RPC_PORT --rpcvhosts "*" \
    --unlock "${WALLETS[$i]}" --password ./.pwd --mine --gasprice "${GASPRICE}" \
    --targetgaslimit "420000000" --verbosity ${VERBOSITY} \
    --rpcapi admin,db,eth,debug,miner,net,shh,txpool,personal,web3,XDPoS \
    --ethstats "${ETHSTATS}" &
  child_proc="$child_proc $!"
done

wait
