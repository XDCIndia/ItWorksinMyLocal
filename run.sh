#!/bin/bash
_interupt() {
    echo "Shutdown $child_proc"
    kill -TERM $child_proc
    exit
}

trap _interupt INT TERM

cd "$(dirname "$0")" || exit 1

# --mixed (or MIXED=1 in the environment/.env): also launch a 5th node --
# modern go-ethereum, sync-only (no --mine), joining from genesis alongside
# the 4 legacy oldxdc sealers below. Default is unchanged (4 legacy sealers
# only).
MIXED="${MIXED:-0}"
CHAINID="${CHAINID:-20118}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mixed) MIXED=1; shift;;
    --chainid) CHAINID=$2; shift 2;;
    --build) BIN_SOURCE_oldxdc=build; shift;;
    -h|--help)
      echo "usage: ./run.sh [--mixed] [--chainid N] [--build]"
      echo "  --mixed       also start node 5: modern geth, sync-only, from genesis"
      echo "                (same as MIXED=1 ./run.sh)"
      echo "  --chainid N   chain id (default: 20118; env: CHAINID)"
      echo "  --build       clone XDPoSChain (XDPOS_REPO) and build the oldxdc binary"
      echo "                from source instead of downloading a prebuilt one (same as"
      echo "                BIN_SOURCE_oldxdc=build ./run.sh). Default is download."
      exit 0;;
    *) echo "usage: ./run.sh [--mixed] [--chainid N] [--build]" >&2; exit 1;;
  esac
done

# A non-numeric chain id is accepted by the node binary but produces a network
# nothing else can join -- reject it here rather than at peering time.
case "$CHAINID" in
  ''|*[!0-9]*) echo "run.sh: --chainid must be a positive integer (got '$CHAINID')" >&2; exit 1;;
esac

source ./lib.sh
require_oldxdc

touch .pwd
set -a
# shellcheck disable=SC1091
[ -f .env ] && source .env
set +a

Bin_NAME=XDC
NUM_NODES=4

# Base ports for the whole local net (nodes 1-4 use BASE+1..BASE+4, and when
# --mixed is set node 5 uses BASE+5) -- override to move the entire topology
# off a set of ports already in use on a shared host, e.g.:
#   BASE_P2P_PORT=31302 BASE_RPC_PORT=9544 BASE_WS_PORT=9554 ./run.sh --mixed
BASE_P2P_PORT="${BASE_P2P_PORT:-30302}"
BASE_RPC_PORT="${BASE_RPC_PORT:-8544}"
BASE_WS_PORT="${BASE_WS_PORT:-8554}"
# The bootnode's own port, kept SEPARATE from BASE_P2P_PORT (default 30301,
# unchanged from before BASE_P2P_PORT existed) rather than derived from it --
# join.sh hardcodes 30301 as ITS OWN assumed default when no --bootnodes/--ip
# is given (see join.sh's DEFAULT_BOOTNODE_PORT), so silently tying this to
# BASE_P2P_PORT would break that default-case assumption the moment someone
# customizes BASE_P2P_PORT. Override independently to run two topologies on
# one host without a bootnode-port collision, e.g.:
#   BOOTNODE_PORT=31300 BASE_P2P_PORT=31302 BASE_RPC_PORT=9544 BASE_WS_PORT=9554 ./run.sh --mixed
BOOTNODE_PORT="${BOOTNODE_PORT:-30301}"

# Ensure platform-native binaries exist (builds from XDPoSChain if needed).
ensure_bins
XDC="$XDC_BIN"

# Modern geth binary for node 5 (--mixed only). Never built here -- setup.sh
# (or an explicit `CLIENT=geth ./lib.sh`-style build) must have produced it
# already; resolve it via lib.sh's per-client BIN_DIR unless overridden.
MODERN_GETH_BIN="${MODERN_GETH_BIN:-$_LIB_DIR/bin/geth/$PLATFORM/geth}"
if [ "$MIXED" = 1 ] && [ ! -x "$MODERN_GETH_BIN" ]; then
  echo "run.sh --mixed: modern geth binary not found at $MODERN_GETH_BIN" >&2
  echo "  build it first, e.g.:  (CLIENT=geth; source ./lib.sh; ensure_bins)" >&2
  echo "  or set MODERN_GETH_BIN=/path/to/geth" >&2
  exit 1
fi

# Machine identity: hostname + LAN IP (advertised to peers so this works across
# machines on the same network, not just localhost).
HOST=$(hostname -s)
IP=$(detect_ip)
echo "Machine: host=$HOST ip=$IP platform=$PLATFORM mixed=$MIXED"

# The chain id the nodes run with and the chainId baked into genesis.json must
# agree. When they don't, nothing here fails loudly: the nodes start, seal, and
# simply never peer (the eth handshake rejects a mismatched network), which
# surfaces much later as an unexplained "peers=0". Assert it up front instead.
# Checked on every run, not just first init -- the re-run path reuses chaindata
# that may have been inited from a *different* genesis than the current one.
if [ -f ./genesis/genesis.json ]; then
  GENESIS_CHAINID=$(python3 -c "import json;print(json.load(open('./genesis/genesis.json'))['config']['chainId'])" 2>/dev/null)
  if [ -n "$GENESIS_CHAINID" ] && [ "$GENESIS_CHAINID" != "$CHAINID" ]; then
    echo "run.sh: --chainid $CHAINID != genesis chainId $GENESIS_CHAINID (./genesis/genesis.json)." >&2
    echo "  The nodes would start but never peer. Regenerate genesis for this id:" >&2
    echo "    ./gen-genesis.sh --chainid $CHAINID --signers <a,b,c> && ./reset.sh" >&2
    echo "  or run with the genesis's own id:  ./run.sh --chainid $GENESIS_CHAINID" >&2
    exit 1
  fi
  [ -n "$GENESIS_CHAINID" ] || echo "run.sh: warning: could not read chainId from ./genesis/genesis.json -- skipping the chain id match check." >&2
fi

# Import keys + init on first run, otherwise read the existing accounts.
declare -a WALLETS
if [ ! -d ./nodes/1/$Bin_NAME/chaindata ]; then
  for i in $(seq 1 $NUM_NODES); do
    pk_var="PRIVATE_KEY_$i"
    WALLETS[$i]=$("$XDC" account import --password .pwd --datadir ./nodes/$i <(echo "${!pk_var}") | awk -v FS="({|})" '{print $2}')
    if [ -z "${WALLETS[$i]}" ]; then
      # `account import` fails (e.g. "account already exists") if the
      # keystore already holds this key even though chaindata is missing --
      # fall back to the already-imported account instead of silently
      # unlocking an empty address (which crashes the sealer at startup
      # with "etherbase must be explicitly specified").
      WALLETS[$i]=$("$XDC" account list --datadir ./nodes/$i | head -n 1 | awk -v FS="({|})" '{print $2}')
    fi
    [ -n "${WALLETS[$i]}" ] || { echo "run.sh: could not determine a wallet address for node $i (check PRIVATE_KEY_$i in .env)" >&2; exit 1; }
    "$XDC" --datadir ./nodes/$i init ./genesis/genesis.json
  done
else
  for i in $(seq 1 $NUM_NODES); do
    WALLETS[$i]=$("$XDC" account list --datadir ./nodes/$i | head -n 1 | awk -v FS="({|})" '{print $2}')
    [ -n "${WALLETS[$i]}" ] || { echo "run.sh: no account found in ./nodes/$i (empty keystore?)" >&2; exit 1; }
  done
fi

# Node 5 (--mixed only): modern geth, sync-only follower, inited from the
# SAME genesis file as nodes 1-4. Its chaindata lives under nodes/5/XDC (the
# modern go-ethereum fork keeps the legacy "XDC" datadir subdirectory name),
# same layout join.sh already assumes for this client.
if [ "$MIXED" = 1 ] && [ ! -d ./nodes/5/XDC/chaindata ]; then
  echo "Initialising node 5 (modern geth) from ./genesis/genesis.json ..."
  "$MODERN_GETH_BIN" --datadir ./nodes/5 init ./genesis/genesis.json
fi

# Genesis-hash agreement check (--mixed only): modern geth and legacy oldxdc
# must compute the SAME genesis hash from the same genesis.json, or geth will
# be rejected at the eth/XDPoS handshake (0 peers, never syncs). Compare them
# up front so a mismatch is obvious immediately rather than discovered as a
# silent "node 5 stuck at peers=0".
if [ "$MIXED" = 1 ]; then
  # --port 0 --nodiscover (+ a throwaway --authrpc.port for geth): these are
  # one-shot local reads of the already-inited genesis block, not real nodes
  # -- keep them off the network entirely so they can't collide with any
  # port already in use on the host (including the P2P ports nodes 1-4/5
  # are about to bind below).
  LEGACY_GENESIS_HASH=$("$XDC" --datadir ./nodes/1 --port 0 --nodiscover --exec 'eth.getBlock(0).hash' console 2>/dev/null | tail -1 | tr -d '"')
  MODERN_GENESIS_HASH=$("$MODERN_GETH_BIN" --datadir ./nodes/5 --port 0 --nodiscover --authrpc.port 0 --exec 'eth.getBlock(0).hash' console 2>/dev/null | tail -1 | tr -d '"')
  echo "Genesis hash (legacy XDC,   node1): ${LEGACY_GENESIS_HASH:-<unavailable>}"
  echo "Genesis hash (modern geth,  node5): ${MODERN_GENESIS_HASH:-<unavailable>}"
  if [ -n "$LEGACY_GENESIS_HASH" ] && [ -n "$MODERN_GENESIS_HASH" ]; then
    if [ "$LEGACY_GENESIS_HASH" = "$MODERN_GENESIS_HASH" ]; then
      echo "Genesis hashes MATCH -- node 5 can peer with the legacy sealers."
    else
      echo "WARNING: genesis hashes DO NOT MATCH -- node 5 will be rejected at handshake (0 peers) and never sync." >&2
    fi
  else
    echo "WARNING: could not read one or both genesis hashes (see above) -- comparison inconclusive." >&2
  fi
fi

VERBOSITY=3
GASPRICE="1"
STATS_SECRET="xdc_openscan_stats_2026"
VERSION=$("$XDC" version 2>/dev/null | awk '/^Version:/{print $2}')
# The node binaries' --networkid is dynamic: setup.sh or the operator can pass CHAINID in the
# environment or --chainid on the command line. All nodes (legacy + modern)
# must share the same value or peering will fail.
networkid="$CHAINID"

# Local bootnode enode, built from bootnode.key + this machine's IP so every
# node connects to a bootnode within the network.
BOOTNODE_PUBKEY=$("$BOOTNODE_BIN" -nodekey ./bootnode.key -writeaddress)
BOOTNODE_ENODE="enode://${BOOTNODE_PUBKEY}@${IP}:${BOOTNODE_PORT}"
echo "Local bootnode: $BOOTNODE_ENODE"

# Pre-flight: every port this topology needs must be free BEFORE anything
# starts. A busy port doesn't stop the run today -- each node is launched into
# the background and never checked, so the one that loses the bind dies alone
# ("Fatal: listen udp :30304: bind: address already in use") while its siblings
# keep sealing. The result is a silently degraded network -- 4 masternodes in
# genesis but only 3 ever sealing -- with nothing in the output saying so.
# Two checkouts of this repo on one host hit this instantly: both default to
# the same BASE_*_PORT range.
ports_in_use() {
  command -v lsof >/dev/null 2>&1 || {
    echo "run.sh: lsof not found -- skipping the port pre-flight check" >&2; return 1; }
  local busy=1 spec p label holder h
  for spec in "$@"; do
    p="${spec%%:*}"; label="${spec#*:}"
    holder=$( { lsof -nP -iTCP:"$p" -sTCP:LISTEN -t 2>/dev/null; lsof -nP -iUDP:"$p" -t 2>/dev/null; } | sort -u | tr '\n' ' ' )
    holder="${holder% }"
    [ -z "$holder" ] && continue
    busy=0
    echo "run.sh: port $p ($label) already in use by PID(s): $holder" >&2
    for h in $holder; do
      echo "          $(ps -p "$h" -o command= 2>/dev/null | cut -c1-96)" >&2
    done
  done
  return $busy
}

PORT_SPECS=("${BOOTNODE_PORT}:bootnode")
for i in $(seq 1 $NUM_NODES); do
  PORT_SPECS+=("$((BASE_P2P_PORT + i)):node $i p2p" "$((BASE_RPC_PORT + i)):node $i rpc" "$((BASE_WS_PORT + i)):node $i ws")
done
if [ "$MIXED" = 1 ]; then
  PORT_SPECS+=("$((BASE_P2P_PORT + 5)):node 5 p2p" "$((BASE_RPC_PORT + 5)):node 5 rpc" \
               "$((BASE_WS_PORT + 5)):node 5 ws" "$((BASE_RPC_PORT + 55)):node 5 authrpc")
fi
if ports_in_use "${PORT_SPECS[@]}"; then
  echo "" >&2
  echo "  Refusing to start: the node that loses the bind would die silently and" >&2
  echo "  leave a degraded network. Stop whatever holds the port(s) above, or move" >&2
  echo "  this whole topology out of the way:" >&2
  echo "    BASE_P2P_PORT=31302 BASE_RPC_PORT=9544 BASE_WS_PORT=9554 ./run.sh$([ "$MIXED" = 1 ] && echo ' --mixed')" >&2
  exit 1
fi

echo Starting the bootnode ...
"$BOOTNODE_BIN" -nodekey ./bootnode.key -addr ${IP}:${BOOTNODE_PORT} &
child_proc=$!

echo Starting the nodes ...
for i in $(seq 1 $NUM_NODES); do
  n=$(printf '%02d' $i)
  P2P_PORT=$((BASE_P2P_PORT + i))   # node1 -> BASE+1 ... node4 -> BASE+4 (default 30303..30306)
  WS_PORT=$((BASE_WS_PORT + i))     # default 8555..8558
  RPC_PORT=$((BASE_RPC_PORT + i))   # default 8545..8548
  NODE_NAME="${Bin_NAME}-v${VERSION}-${HOST}-MasterNode-${n}"
  NODE_IDENTITY="${HOST}-MasterNode-${n}"
  ETHSTATS="${NODE_NAME}:${STATS_SECRET}@stats.xdcindia.com:443"
  "$XDC" --bootnodes "$BOOTNODE_ENODE" --syncmode "full" --datadir ./nodes/$i \
    --networkid "${networkid}" --port $P2P_PORT --nat "extip:${IP}" --identity "${NODE_IDENTITY}" \
    --rpc --rpccorsdomain "*" --ws --wsaddr="0.0.0.0" --wsorigins "*" --wsport $WS_PORT \
    --rpcaddr 0.0.0.0 --rpcport $RPC_PORT --rpcvhosts "*" \
    --unlock "${WALLETS[$i]}" --etherbase "${WALLETS[$i]}" --password ./.pwd --mine --gasprice "${GASPRICE}" \
    --targetgaslimit "420000000" --verbosity ${VERBOSITY} \
    --rpcapi admin,db,eth,debug,miner,net,shh,txpool,personal,web3,XDPoS \
    --ethstats "${ETHSTATS}" &
  child_proc="$child_proc $!"
done

if [ "$MIXED" = 1 ]; then
  echo "Starting node 5 (modern geth, sync-only follower) ..."
  P2P_PORT5=$((BASE_P2P_PORT + 5))   # default 30307
  WS_PORT5=$((BASE_WS_PORT + 5))     # default 8559
  RPC_PORT5=$((BASE_RPC_PORT + 5))   # default 8549
  # Modern geth always starts an authrpc (Engine API) listener even though
  # XDPoS doesn't use it here; it defaults to 127.0.0.1:8551, which is
  # commonly already taken by another node on a shared host and would
  # otherwise crash node 5 at startup ("address already in use"). Give it
  # its own offset, well clear of the BASE+1..BASE+5 range used above.
  AUTHRPC_PORT5=$((BASE_RPC_PORT + 55))
  NODE5_IDENTITY="${HOST}-ModernGeth-05"
  ETHSTATS5="itlocal-modern-geth-${HOST}-05:${STATS_SECRET}@stats.xdcindia.com:443"
  "$MODERN_GETH_BIN" --datadir ./nodes/5 --networkid "${networkid}" --syncmode full \
    --bootnodes "$BOOTNODE_ENODE" --port "$P2P_PORT5" --nat "extip:${IP}" \
    --http --http.addr 0.0.0.0 --http.port "$RPC_PORT5" --http.vhosts "*" --http.corsdomain "*" \
    --http.api eth,net,web3,txpool,debug,admin,XDPoS \
    --ws --ws.addr 0.0.0.0 --ws.origins "*" --ws.port "$WS_PORT5" --ws.api eth,net,web3,XDPoS \
    --authrpc.port "$AUTHRPC_PORT5" \
    --identity "${NODE5_IDENTITY}" --ethstats "${ETHSTATS5}" &
  child_proc="$child_proc $!"
fi

wait
