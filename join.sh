#!/bin/bash
# Connect to and sync an EXISTING network as a (non-mining) peer.
# You supply that network's genesis file and one or more bootnode enodes.
#
# Usage:
#   ./join.sh --genesis path/to/genesis.json --bootnodes "enode://KEY@HOST:30301"
#
# Flags:
#   --genesis FILE       the target network's genesis.json            (required)
#   --ip IP[:PORT]       just give the target machine's IP -- connects to its
#                        bootnode (shared bootnode.key) at PORT (default 30301).
#                        Simplest way to join a network on another host.
#   --bootnodes LIST     full enode URL(s) to dial, if you have them
#                        (overrides --ip; default: derived from ./bootnode.key)
#   --host IP[:PORT]     alias of --ip
#   --client C           node client: oldxdc (default) or geth. geth joins as
#                        sync-only (it can't seal here); both import blocks.
#   --networkid N        network id (default: chainId from the genesis)
#   --datadir DIR        where to store this peer's data (default ./peer)
#   --name NAME          node identity shown to peers/ethstats (default <host>-sync)
#   --port N             p2p port (default 30303)
#   --rpcport N          JSON-RPC port (default 8545)
#   --wsport N           WebSocket port (default 8546)
#   --mine KEY           also mine, unlocking this address (only if it's a
#                        validator in that genesis; needs the key in .env)
#   --ethstats SPEC      ethstats target (ON by default, same as run.sh). SPEC
#                        is SECRET@HOST:PORT (node name prepended) or a full
#                        NAME:SECRET@HOST:PORT used verbatim.
#   --no-ethstats        disable ethstats reporting
#
# This joins as a read/sync node by default (no mining). It does NOT touch your
# local 4-node network in ./nodes.

_interupt() { echo "Shutdown $child_proc"; kill -TERM $child_proc 2>/dev/null; exit; }
trap _interupt INT TERM

cd "$(dirname "$0")"

GENESIS=""; BOOTNODES=""; NETWORKID=""; DATADIR="./peer"; NAME=""; HOST_IP=""
PORT=30303; RPCPORT=8545; WSPORT=8546; MINEADDR=""
# ethstats reporting is ON by default (same endpoint as run.sh); --no-ethstats
# disables it, --ethstats SPEC overrides the target.
ETHSTATS="xdc_openscan_stats_2026@stats.xdcindia.com:443"
while [ $# -gt 0 ]; do
  case "$1" in
    --genesis)     GENESIS=$2; shift 2;;
    --bootnodes)   BOOTNODES=$2; shift 2;;
    --ip)          HOST_IP=$2; shift 2;;
    --host)        HOST_IP=$2; shift 2;;
    --client)      export CLIENT=$2; shift 2;;
    --networkid)   NETWORKID=$2; shift 2;;
    --datadir)     DATADIR=$2; shift 2;;
    --name)        NAME=$2; shift 2;;
    --port)        PORT=$2; shift 2;;
    --rpcport)     RPCPORT=$2; shift 2;;
    --wsport)      WSPORT=$2; shift 2;;
    --mine)        MINEADDR=$2; shift 2;;
    --ethstats)    ETHSTATS=$2; shift 2;;
    --no-ethstats) ETHSTATS=""; shift;;
    -h|--help)     sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done

source ./lib.sh
ensure_bins
XDC="$XDC_BIN"

[ -f "$GENESIS" ] || { echo "need --genesis <file> (got '$GENESIS')" >&2; exit 1; }

# If no explicit --bootnodes, derive the enode from ./bootnode.key at the given
# IP (--ip/--host, may include :PORT; defaults to this machine's IP:30301).
if [ -z "$BOOTNODES" ]; then
  [ -f ./bootnode.key ] || { echo "need --bootnodes or --ip, or a ./bootnode.key to derive one" >&2; exit 1; }
  # The enode pubkey comes from bootnode.key via any bootnode binary. The geth
  # client has none, so fall back to whichever bootnode binary is built.
  bn="$BOOTNODE_BIN"
  [ -x "$bn" ] || bn=$(ls bin/*/*/bootnode 2>/dev/null | head -1)
  [ -x "$bn" ] || { echo "no bootnode binary to derive the enode; pass --bootnodes, or build the oldxdc client once" >&2; exit 1; }
  target="${HOST_IP:-$(detect_ip)}"
  case "$target" in
    *:*) bhost="${target%:*}"; bport="${target##*:}";;
    *)   bhost="$target";      bport=30301;;
  esac
  BOOTNODES="enode://$("$bn" -nodekey ./bootnode.key -writeaddress)@${bhost}:${bport}"
  echo "Using key-based bootnode: $BOOTNODES"
fi

# Default the network id to the genesis chainId.
if [ -z "$NETWORKID" ]; then
  NETWORKID=$(python3 -c "import json,sys;print(json.load(open('$GENESIS'))['config']['chainId'])" 2>/dev/null)
  [ -n "$NETWORKID" ] || { echo "could not read chainId from $GENESIS; pass --networkid" >&2; exit 1; }
fi

IP=$(detect_ip)
[ -z "$NAME" ] && NAME="$(hostname -s)-sync"

# Initialise this peer's datadir against the target genesis (first run only).
# oldxdc stores chaindata under <datadir>/XDC, geth under <datadir>/geth.
datasub="XDC"; [ "$CLIENT" = geth ] && datasub="geth"
if [ ! -d "$DATADIR/$datasub/chaindata" ]; then
  echo "Initialising $DATADIR from $GENESIS ..."
  "$XDC" --datadir "$DATADIR" init "$GENESIS" || exit 1
fi

# ethstats: prepend the node name unless SPEC already includes one (name:secret@…)
ETHSTATS_ARG=""
if [ -n "$ETHSTATS" ]; then
  case "${ETHSTATS%%@*}" in
    *:*) full="$ETHSTATS";;            # already NAME:SECRET
    *)   full="${NAME}:${ETHSTATS}";;  # just SECRET -> prepend node name
  esac
  ETHSTATS_ARG="--ethstats $full"
  echo "  ethstats: $full"
fi

echo "Joining ($CLIENT) network id=$NETWORKID  bootnodes=$BOOTNODES"
echo "  datadir=$DATADIR  identity=$NAME  ip=$IP  ports p2p:$PORT rpc:$RPCPORT ws:$WSPORT"

if [ "$CLIENT" = geth ]; then
  # Modern geth: dot-notation flags, sync-only (it can't seal here).
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (geth join is sync-only)" >&2
  "$XDC" --datadir "$DATADIR" --networkid "$NETWORKID" --syncmode full \
    --bootnodes "$BOOTNODES" --port "$PORT" --nat "extip:${IP}" --identity "$NAME" --maxpeers 25 \
    --http --http.corsdomain "*" --http.addr 0.0.0.0 --http.port "$RPCPORT" --http.vhosts "*" \
    --http.api eth,net,web3,txpool,debug,XDPoS \
    --ws --ws.addr 0.0.0.0 --ws.origins "*" --ws.port "$WSPORT" --ws.api eth,net,web3,XDPoS \
    $ETHSTATS_ARG &
else
  # oldxdc (XDPoSChain): classic flags; --mine unlocks a validator to also seal.
  MINE_FLAGS=""
  if [ -n "$MINEADDR" ]; then
    touch .pwd
    MINE_FLAGS="--unlock $MINEADDR --password ./.pwd --mine --gasprice 1"
  fi
  "$XDC" --datadir "$DATADIR" --networkid "$NETWORKID" --syncmode full \
    --bootnodes "$BOOTNODES" --port "$PORT" --nat "extip:${IP}" --identity "$NAME" \
    --rpc --rpccorsdomain "*" --rpcaddr 0.0.0.0 --rpcport "$RPCPORT" --rpcvhosts "*" \
    --ws --wsaddr 0.0.0.0 --wsorigins "*" --wsport "$WSPORT" \
    --rpcapi admin,db,eth,debug,miner,net,shh,txpool,personal,web3,XDPoS \
    $MINE_FLAGS $ETHSTATS_ARG &
fi
child_proc=$!
wait
