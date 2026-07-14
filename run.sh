#!/bin/bash
_interupt() {
    echo "Shutdown $child_proc"
    kill -TERM $child_proc
    exit
}

trap _interupt INT TERM

touch .pwd
export $(cat .env | xargs)

Bin_NAME=XDC
WORK_DIR=$PWD
PROJECT_DIR="/Users/anilchinchawale/workspace/XDCNetwork/XDPoSChain"
BIN_DIR="$WORK_DIR/bin"
NUM_NODES=4

# Use the binaries shipped in ./bin so we don't depend on the XDPoSChain source
# tree. Rebuild only when a binary is missing or REBUILD=1 is set.
if [ ! -x "$BIN_DIR/$Bin_NAME" ] || [ ! -x "$BIN_DIR/bootnode" ] || [ "$REBUILD" = "1" ]; then
  echo "Building $Bin_NAME and bootnode from $PROJECT_DIR ..."
  cd "$PROJECT_DIR" && make XDC && make bootnode
  cd "$WORK_DIR"
  mkdir -p "$BIN_DIR"
  cp "$PROJECT_DIR/build/bin/$Bin_NAME" "$PROJECT_DIR/build/bin/bootnode" "$BIN_DIR/"
fi
XDC="$BIN_DIR/$Bin_NAME"
BOOTNODE_BIN="$BIN_DIR/bootnode"

# Machine identity: hostname + LAN IP (advertised to peers so this works across
# machines on the same network, not just localhost).
HOST=$(hostname -s)
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$IP" ] && IP="127.0.0.1"
echo "Machine: host=$HOST ip=$IP"

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
