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
#                        erigon join sync-only. All accept --genesis (erigon
#                        converts it to its own format automatically).
#   --chain NAME         erigon only: use a built-in chainspec instead of --genesis
#   --staticpeers LIST   comma-separated enode URLs to connect directly (erigon
#                        needs these to peer with an XDPoS net; its discv4 doesn't
#                        discover peers through an XDPoSChain bootnode)
#   --networkid N        network id (default: chainId from the genesis)
#   --datadir DIR        where to store this peer's data (default ./peer)
#   --name NAME          node identity shown to peers/ethstats (default <host>-sync)
#   --port N             p2p port (per-client default: oldxdc 30313 / geth 30323
#                        / erigon 30333 -- clear of run.sh, no cross-client clash)
#   --rpcport N          JSON-RPC port (oldxdc 8595 / geth 8605 / erigon 8615)
#   --wsport N           WebSocket port (oldxdc 8596 / geth 8606 / erigon 8616)
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
MINEADDR=""; STATICPEERS=""
# Ports are left empty here and defaulted PER CLIENT after --client is known, so
# oldxdc/geth/erigon joins each get a distinct set (clear of run.sh) and can run
# side by side without conflict. Any explicit flag below wins.
PORT=""; RPCPORT=""; WSPORT=""
AUTHRPC_PORT=""; TORRENT_PORT=""; PRIVAPI=""; MCP_PORT=""
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
    --staticpeers) STATICPEERS=$2; shift 2;;
    --ethstats)    ETHSTATS=$2; shift 2;;
    --no-ethstats) ETHSTATS=""; shift;;
    -h|--help)     sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done

source ./lib.sh

# Per-client default ports (offset by client) so oldxdc/geth/erigon joins never
# clash with each other or with a running ./run.sh (30301, 30303-6, 8545-8, 8555-8).
case "$CLIENT" in geth) O=10;; erigon) O=20;; *) O=0;; esac
PORT="${PORT:-$((30313 + O))}"
RPCPORT="${RPCPORT:-$((8595 + O))}"
WSPORT="${WSPORT:-$((8596 + O))}"
AUTHRPC_PORT="${AUTHRPC_PORT:-$((8651 + O))}"
TORRENT_PORT="${TORRENT_PORT:-$((42079 + O))}"
MCP_PORT="${MCP_PORT:-$((8653 + O))}"
PRIVAPI="${PRIVAPI:-127.0.0.1:$((9095 + O))}"

# Validate required inputs BEFORE building (a build can take minutes).
if [ "$CLIENT" = erigon ]; then
  # erigon: a built-in --chain name, or a --genesis file (loaded generically
  # via erigon's genesis-file chainspec support).
  [ -n "$CHAIN" ] || [ -f "$GENESIS" ] || { echo "erigon join needs --genesis <file> or --chain <built-in-name>" >&2; exit 1; }
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
# Dynamic machine name (robust across OSes; fallback if hostname is unset).
HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)
HOST=${HOST:-node}
# Default ethstats/identity name mirrors run.sh's "<client>-v<version>-<host>-…"
# so all clients (oldxdc/geth/erigon) read consistently on the dashboard.
if [ -z "$NAME" ]; then
  if [ "$CLIENT" = erigon ]; then
    VER=$("$XDC" --version 2>/dev/null | head -1 | awk '{print $NF}')
  else
    VER=$("$XDC" version 2>/dev/null | awk '/^Version:/{print $2; exit}')
  fi
  NAME="${NODE_NAME_BIN}-v${VER:-0}-${HOST}-sync"
fi

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
  # Erigon (sync-only). --chain takes a built-in name OR a genesis file (the
  # merged genesis-file chainspec support). XDPoS peers via discv4; discovery
  # through an XDPoSChain bootnode doesn't populate erigon, so masternode enodes
  # are usually needed via --staticpeers.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (erigon join is sync-only)" >&2
  if [ -n "$CHAIN" ]; then
    ERC="$CHAIN"                       # built-in chainspec name
  else
    # Convert the XDPoSChain-format genesis to erigon's format (reads the real
    # xdpos params incl. v2.switchBlock; defaults fill anything missing).
    mkdir -p "$DATADIR"; ERC="$DATADIR/erigon-genesis.json"
    python3 - "$GENESIS" "$ERC" <<'PY'
import json, sys
g = json.load(open(sys.argv[1])); C = g["config"]
x = C.get("XDPoS") or C.get("xdpos") or {}
v2 = x.get("v2", {}); c = v2.get("config") or {}
def g2(d, *ks, d_=None):
    for k in ks:
        if k in d: return d[k]
    return d_
ct = g2(c, "certificateThreshold", "certThreshold", d_=0.667)
xdpos = {"period": x.get("period", 2), "epoch": x.get("epoch", 900), "gap": x.get("gap", 450),
  "reward": x.get("reward", 0), "rewardCheckpoint": x.get("rewardCheckpoint", x.get("epoch", 900)),
  "foudationWalletAddr": x.get("foudationWalletAddr", "0x" + "0"*40),
  "v2": {"switchBlock": v2.get("switchBlock", 0), "certThreshold": ct,
    "allConfigs": {"0": {"maxMasternodes": g2(c, "maxMasternodes", d_=108), "switchRound": 0,
      "certificateThreshold": ct, "timeoutSyncThreshold": g2(c, "timeoutSyncThreshold", d_=3),
      "timeoutPeriod": g2(c, "timeoutPeriod", d_=10), "minePeriod": g2(c, "minePeriod", d_=2)}}}}
cfg = {"chainName": "join-erigon", "chainId": C["chainId"], "consensus": "xdpos",
  "homesteadBlock": C.get("homesteadBlock", 0), "eip150Block": C.get("eip150Block", 0),
  "eip155Block": C.get("eip155Block", 0), "eip158Block": C.get("eip158Block", 0),
  "byzantiumBlock": C.get("byzantiumBlock", 0), "xdpos": xdpos}
gen = {"config": cfg, "nonce": g.get("nonce", "0x0"), "timestamp": g["timestamp"],
  "extraData": g["extraData"], "gasLimit": g["gasLimit"], "difficulty": g.get("difficulty", "0x1"),
  "coinbase": g.get("coinbase", "0x" + "0"*40), "mixHash": g.get("mixHash", "0x" + "0"*64),
  "alloc": g["alloc"]}
json.dump(gen, open(sys.argv[2], "w"))
PY
    echo "  converted $GENESIS -> $ERC (erigon genesis format)"
  fi
  echo "  erigon chain=$ERC ports authrpc:$AUTHRPC_PORT torrent:$TORRENT_PORT privapi:$PRIVAPI mcp:$MCP_PORT"
  BN_ARG=""; [ -n "$BOOTNODES" ] && BN_ARG="--bootnodes $BOOTNODES"
  SP_ARG=""; [ -n "$STATICPEERS" ] && SP_ARG="--staticpeers $STATICPEERS"
  [ -z "$STATICPEERS" ] && echo "  note: no --staticpeers given; erigon may not discover XDPoS peers via the bootnode alone" >&2
  "$XDC" --datadir "$DATADIR" --chain "$ERC" --discv4 \
    --port "$PORT" --nat "extip:${IP}" $BN_ARG $SP_ARG \
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
