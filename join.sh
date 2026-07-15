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
#   --client C           node client: oldxdc (default) | geth | erigon. geth &
#                        erigon join sync-only. erigon uses --chain, not --genesis.
#   --chain NAME         erigon only: built-in XDC chainspec to join (erigon has
#                        no custom-genesis-file support)
#   --networkid N        network id (default: chainId from the genesis)
#   --datadir DIR        where to store this peer's data (default ./peer)
#   --name NAME          node identity shown to peers/ethstats (default <host>-sync)
#   --port N             p2p port (default 30313 -- clear of ./run.sh's 30303-6)
#   --rpcport N          JSON-RPC port (default 8595 -- clear of run.sh's 8545-8)
#   --wsport N           WebSocket port (default 8596)
#   --mine KEY           also mine, unlocking this address (oldxdc only; needs a
#                        validator key in .env). Ignored by geth/erigon.
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

GENESIS=""; BOOTNODES=""; NETWORKID=""; DATADIR="./peer"; NAME=""; HOST_IP=""; CHAIN=""
# Defaults deliberately avoid a running ./run.sh network on this machine
# (bootnode 30301, p2p 30303-30306, rpc 8545-8548, ws 8555-8558).
PORT=30313; RPCPORT=8595; WSPORT=8596; MINEADDR=""
# erigon-only extra ports (also chosen clear of run.sh and a geth join):
AUTHRPC_PORT=8651; TORRENT_PORT=42079; PRIVAPI=127.0.0.1:9095; MCP_PORT=8653
# ethstats reporting is ON by default (same endpoint as run.sh); --no-ethstats
# disables it, --ethstats SPEC overrides the target.
ETHSTATS="xdc_openscan_stats_2026@stats.xdcindia.com:443"
while [ $# -gt 0 ]; do
  case "$1" in
    --genesis)     GENESIS=$2; shift 2;;
    --chain)       CHAIN=$2; shift 2;;
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
    -h|--help)     sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done

source ./lib.sh

# Validate required inputs BEFORE building (a build can take minutes).
if [ "$CLIENT" = erigon ]; then
  # erigon uses built-in XDC chainspecs (--chain), not a genesis file.
  [ -n "$CHAIN" ] || { echo "erigon join needs --chain <name> (it uses built-in XDC chainspecs, not a custom genesis file)" >&2; exit 1; }
else
  [ -f "$GENESIS" ] || { echo "need --genesis <file> (got '$GENESIS')" >&2; exit 1; }
fi

ensure_bins
XDC="$XDC_BIN"

# If no explicit --bootnodes, derive the enode from ./bootnode.key at the given
# IP (--ip/--host, may include :PORT; defaults to this machine's IP:30301).
# erigon joining a built-in --chain (no --ip) uses that chain's own bootnodes,
# so skip derivation there.
if [ -z "$BOOTNODES" ] && { [ "$CLIENT" != erigon ] || [ -n "$HOST_IP" ]; }; then
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

# Default the network id to the genesis chainId (not used by erigon --chain).
if [ "$CLIENT" != erigon ] && [ -z "$NETWORKID" ]; then
  NETWORKID=$(python3 -c "import json,sys;print(json.load(open('$GENESIS'))['config']['chainId'])" 2>/dev/null)
  [ -n "$NETWORKID" ] || { echo "could not read chainId from $GENESIS; pass --networkid" >&2; exit 1; }
fi

IP=$(detect_ip)
[ -z "$NAME" ] && NAME="$(hostname -s)-sync"

# Initialise the datadir against the genesis (first run only). oldxdc stores
# chaindata under <datadir>/XDC, geth under <datadir>/geth. erigon has no init
# (it derives the chain from --chain), so skip it there.
if [ "$CLIENT" != erigon ]; then
  datasub="XDC"; [ "$CLIENT" = geth ] && datasub="geth"
  if [ ! -d "$DATADIR/$datasub/chaindata" ]; then
    echo "Initialising $DATADIR from $GENESIS ..."
    "$XDC" --datadir "$DATADIR" init "$GENESIS" || exit 1
  fi
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

echo "Joining ($CLIENT) network=${CHAIN:-id $NETWORKID}  bootnodes=$BOOTNODES"
echo "  datadir=$DATADIR  identity=$NAME  ip=$IP  ports p2p:$PORT rpc:$RPCPORT ws:$WSPORT"

if [ "$CLIENT" = erigon ]; then
  # Erigon: --chain (built-in chainspec), sync-only, its own port set.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (erigon join is sync-only)" >&2
  # erigon picks a p2p port per protocol version from --p2p.allowed-ports
  # (default 30303-30307, which clashes with run.sh). Pin them to our range.
  APORTS="$PORT,$((PORT+1)),$((PORT+2)),$((PORT+3)),$((PORT+4))"
  echo "  erigon ports p2p-allowed:$APORTS authrpc:$AUTHRPC_PORT torrent:$TORRENT_PORT privapi:$PRIVAPI mcp:$MCP_PORT"
  BN_ARG=""; [ -n "$BOOTNODES" ] && BN_ARG="--bootnodes $BOOTNODES"
  "$XDC" --datadir "$DATADIR" --chain "$CHAIN" \
    --port "$PORT" --p2p.allowed-ports "$APORTS" --nat "extip:${IP}" $BN_ARG \
    --http --http.addr 0.0.0.0 --http.port "$RPCPORT" --http.vhosts "*" \
    --http.corsdomain "*" --http.api eth,net,web3,erigon,debug,txpool \
    --ws --ws.port "$WSPORT" \
    --authrpc.port "$AUTHRPC_PORT" --torrent.port "$TORRENT_PORT" \
    --private.api.addr "$PRIVAPI" --mcp.port "$MCP_PORT" \
    $ETHSTATS_ARG &
elif [ "$CLIENT" = geth ]; then
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
