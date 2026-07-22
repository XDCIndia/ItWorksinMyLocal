#!/bin/bash
# Connect to and sync an EXISTING network as a (non-mining) peer.
# You supply that network's genesis file and one or more bootnode enodes.
#
# Usage:
#   ./join.sh --genesis path/to/genesis.json         # uses default host + peers
#   ./join.sh --genesis g.json --ip 10.0.0.5         # override the host
#   ./join.sh --genesis g.json --bootnodes "enode://KEY@HOST:30301"
#
# Defaults (no --ip / --staticpeers needed): the target host comes from
# network.env (DEFAULT_HOST) and the peers from peers.list -- edit those to
# point at your own network. --ip / --bootnodes / --staticpeers still override.
#
# Flags:
#   --genesis FILE       the target network's genesis.json (defaults to
#                        DEFAULT_GENESIS in network.env -- devnet 5151)
#   --ip IP[:PORT]       just give the target machine's IP -- connects to its
#                        bootnode (shared bootnode.key) at PORT (default 30301).
#                        Simplest way to join a network on another host.
#   --bootnodes LIST     full enode URL(s) to dial, if you have them
#                        (overrides --ip; default: derived from ./bootnode.key)
#   --host IP[:PORT]     alias of --ip
#   --client C           node client: oldxdc (default) | geth | erigon | besu |
#                        nethermind | reth | xone | all. xone is the go-ethereum-
#                        derived XDPoS reference client (XDCIndia/xOneGo). "all"
#                        boots every client at once, each in its own datadir
#                        (nodes/<client>-<type>) with a distinct 100-wide port
#                        block, all joining the same network -- a one-command
#                        cross-client bring-up. Only oldxdc can seal
#                        (--mine); all others join sync-only. All clients default
#                        to a
#                        prebuilt-binary download (binaries.json) for this
#                        platform, falling back to a source build for
#                        oldxdc/geth/erigon if unavailable; BIN_SOURCE=build
#                        (or per-client BIN_SOURCE_<client>=build) forces a
#                        build / skips the download. besu/nethermind/reth also
#                        honor BESU_BIN / RETH_BIN / NETHERMIND_DIST (or PATH)
#                        ahead of both. besu & reth read the geth-format
#                        --genesis natively; erigon converts it; nethermind
#                        uses its own chainspec.
#   --chain NAME         erigon only: use a built-in chainspec instead of --genesis
#   --nm-config NAME     nethermind only: chainspec name to load from
#                        NETHERMIND_DIST/chainspec/NAME.json via --config
#                        (default: xdc-devnet5151; env override: NM_CONFIG)
#   --staticpeers LIST   comma-separated enode URLs to connect directly (erigon
#                        needs these to peer with an XDPoS net; its discv4 doesn't
#                        discover peers through an XDPoSChain bootnode)
#   --networkid N        network id (default: chainId from the genesis)
#   --datadir DIR        where to store this peer's data (default
#                        nodes/<client>-<nodetype>, e.g. nodes/geth-sync)
#   --name NAME          node identity shown to peers/ethstats (default
#                        <client>-v<ver>-<host>-<nodetype>; <host> comes from
#                        MACHINE in network.env/env, else the hostname)
#   --port N             p2p port (per-client default: oldxdc 31413 / geth 31513
#                        / erigon 31613 / … / xone 32013 -- 100 apart, clear of
#                        run.sh and validator ports, no cross-client clash)
#   --rpcport N          JSON-RPC port (oldxdc 9645 / geth 9745 / … / xone 10245)
#   --wsport N           WebSocket port (JSON-RPC port + 1)
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

cd "$(dirname "$0")" || exit 1
# Absolute path to THIS script, resolved after the cd above, so the --client all
# fan-out can re-invoke it reliably however it was started -- `./join.sh`,
# `bash join.sh` (where $0 is a bare "join.sh" not on PATH), or an absolute path.
SELF="$PWD/$(basename "$0")"

# DATADIR empty here means "use the default convention" (nodes/<client>-<type>),
# computed once the client is known; an explicit --datadir always wins.
GENESIS=""; BOOTNODES=""; NETWORKID=""; DATADIR=""; NAME=""; HOST_IP=""; CHAIN=""
MINEADDR=""; STATICPEERS=""
# Ports are left empty here and defaulted PER CLIENT after --client is known, so
# oldxdc/geth/erigon joins each get a distinct set (clear of run.sh) and can run
# side by side without conflict. Any explicit flag below wins.
PORT=""; RPCPORT=""; WSPORT=""
AUTHRPC_PORT=""; TORRENT_PORT=""; PRIVAPI=""; MCP_PORT=""
# ethstats reporting is ON by default (same endpoint as run.sh); --no-ethstats
# disables it, --ethstats SPEC overrides the target.
ETHSTATS="xdc_openscan_stats_2026@stats.xdcindia.com:443"
# nethermind's chainspec name (NETHERMIND_DIST/chainspec/$NM_CONFIG.json via
# --config); env-overridable, defaults to devnet 5151. --nm-config wins over both.
NM_CONFIG="${NM_CONFIG:-xdc-devnet5151}"
while [ $# -gt 0 ]; do
  case "$1" in
    --genesis)     GENESIS=$2; shift 2;;
    --chain)       CHAIN=$2; shift 2;;
    --nm-config)   NM_CONFIG=$2; shift 2;;
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
    -h|--help)     sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done

source ./lib.sh

# Default network target so neither --ip nor --staticpeers is required.
# network.env -> DEFAULT_HOST/DEFAULT_BOOTNODE_PORT/DEFAULT_BOOTNODES/DEFAULT_GENESIS;
# peers.list -> default peers.
[ -f network.env ] && . ./network.env

# Default the genesis from network.env (DEFAULT_GENESIS) when --genesis is omitted,
# so a plain `./join.sh` joins the configured network (devnet 5151) with no flags.
if [ -z "$GENESIS" ] && [ -n "$DEFAULT_GENESIS" ] && [ -f "$DEFAULT_GENESIS" ]; then
  GENESIS="$DEFAULT_GENESIS"
  echo "No --genesis given; using default genesis $GENESIS (from network.env)"
fi

# Prefer explicit DEFAULT_BOOTNODES (real masternode enodes) over deriving one from
# bootnode.key: devnet 5151's masternodes live on four separate hosts with their own
# node keys, so a key-derived enode would carry the wrong node id and fail to dial.
if [ -z "$BOOTNODES" ] && [ -z "$HOST_IP" ] && [ -n "$DEFAULT_BOOTNODES" ]; then
  BOOTNODES="$DEFAULT_BOOTNODES"
  echo "No --ip/--bootnodes given; using $(echo "$BOOTNODES" | tr ',' '\n' | grep -c enode) default bootnode(s) from network.env"
fi

if [ -z "$HOST_IP" ] && [ -z "$BOOTNODES" ] && [ -n "$DEFAULT_HOST" ]; then
  HOST_IP="${DEFAULT_HOST}:${DEFAULT_BOOTNODE_PORT:-30301}"
  echo "No --ip/--bootnodes given; using default host $HOST_IP (from network.env)"
fi
if [ -z "$STATICPEERS" ] && [ -f peers.list ]; then
  STATICPEERS=$(grep -v '^[[:space:]]*#' peers.list | grep enode | paste -sd, -)
  [ -n "$STATICPEERS" ] && echo "Using $(echo "$STATICPEERS" | tr ',' '\n' | grep -c enode) default peer(s) from peers.list"
fi

# --client all: boot EVERY client at once, each in its own datadir with its
# per-client port offset (already distinct below), all sharing the same genesis +
# bootnodes resolved above. Implemented as a fan-out: re-invoke this same script
# once per client with --client <c>, so each child reuses the full per-client
# setup (binary resolution, genesis init, ethstats, peer harvest) with zero
# duplicated logic. Children run concurrently; Ctrl-C / TERM stops them all.
# A client whose extra inputs are missing (erigon needs --chain; nethermind needs
# a dist) exits with its own hint and is skipped -- the rest keep syncing.
if [ "$CLIENT" = all ]; then
  ALL_CLIENTS="oldxdc geth erigon besu nethermind reth xone"
  # Forward the shared, already-resolved network inputs to every child so they all
  # dial the SAME network (and a child doesn't re-run default resolution).
  shared=()
  [ -n "$GENESIS" ]     && shared+=(--genesis "$GENESIS")
  [ -n "$BOOTNODES" ]   && shared+=(--bootnodes "$BOOTNODES")
  [ -n "$HOST_IP" ]     && shared+=(--ip "$HOST_IP")
  [ -n "$STATICPEERS" ] && shared+=(--staticpeers "$STATICPEERS")
  [ -n "$NETWORKID" ]   && shared+=(--networkid "$NETWORKID")
  [ -n "$CHAIN" ]       && shared+=(--chain "$CHAIN")
  [ -n "$MINEADDR" ]    && shared+=(--mine "$MINEADDR")   # only oldxdc seals; others print "ignored"
  if [ -n "$ETHSTATS" ]; then shared+=(--ethstats "$ETHSTATS"); else shared+=(--no-ethstats); fi
  # Base directory for the per-client chaindata: a custom --datadir wins, else the
  # shared ./nodes tree (clear of run.sh's numbered nodes/1..N local net).
  base="${DATADIR:-nodes}"
  all_pids=()
  trap 'echo "[all] stopping ${#all_pids[@]} client(s)..."; for p in "${all_pids[@]}"; do kill -TERM "$p" 2>/dev/null; done; exit 0' INT TERM
  for c in $ALL_CLIENTS; do
    # Each client's chaindata lands in nodes/<client>-<nodetype> so the six chains
    # never share a datadir. Only oldxdc can seal (--mine); the rest join sync-only.
    nt=sync; [ -n "$MINEADDR" ] && [ "$c" = oldxdc ] && nt=seal
    dd="${base}/${c}-${nt}"
    args=(--client "$c" --datadir "$dd" "${shared[@]}")
    # Distinct ethstats/identity name per client when the user forced one (the
    # per-client default name already embeds the client, so only needed here).
    [ -n "$NAME" ] && args+=(--name "${NAME}-${c}")
    echo "=== [all] launching $c  (datadir $dd) ==="
    bash "$SELF" "${args[@]}" &
    all_pids+=($!)
  done
  echo "[all] launched ${#all_pids[@]} client(s): $ALL_CLIENTS"
  echo "[all] each syncs in ${base}/<client>-<nodetype>; Ctrl-C stops all"
  wait
  exit 0
fi

# Node role: "seal" when this client will mine (oldxdc + --mine), else "sync".
# Drives both the default datadir and the default identity/ethstats name so they
# read consistently (nodes/<client>-<nodetype> <-> <client>-v<ver>-<host>-<nodetype>).
NODETYPE=sync
[ -n "$MINEADDR" ] && case "$CLIENT" in oldxdc) NODETYPE=seal;; esac

# Default datadir: nodes/<client>-<nodetype>, so every client's chaindata lives
# under ./nodes (clear of run.sh's numbered nodes/1..N local net) and different
# clients never share a datadir. An explicit --datadir always wins.
[ -z "$DATADIR" ] && DATADIR="nodes/${CLIENT}-${NODETYPE}"

# Per-client default ports: a 100-wide block per client so all seven join clients
# run side by side with no cross-client clash, in a high band kept clear of
# run.sh's local net (30301, 30303-6, 8545-58), any XDPoS validator ports
# (85xx / 91xx / 99xx / 310xx), and the previous join defaults (83xx/85-86xx/
# 30313+) -- so a `--client all` fan-out won't collide with those or a second run.
case "$CLIENT" in
  geth) O=100;; erigon) O=200;; besu) O=300;; nethermind) O=400;; reth) O=500;; xone) O=600;; *) O=0;;
esac
PORT="${PORT:-$((31413 + O))}"                  # p2p     31413..32013
RPCPORT="${RPCPORT:-$((9645 + O))}"             # http    9645..10245
WSPORT="${WSPORT:-$((RPCPORT + 1))}"            # ws      http+1
AUTHRPC_PORT="${AUTHRPC_PORT:-$((10645 + O))}"  # authrpc 10645..11245
TORRENT_PORT="${TORRENT_PORT:-$((42579 + O))}"  # erigon torrent
MCP_PORT="${MCP_PORT:-$((10653 + O))}"          # erigon mcp
PRIVAPI="${PRIVAPI:-127.0.0.1:$((11645 + O))}"  # erigon private api

# Validate required inputs BEFORE building (a build can take minutes).
case "$CLIENT" in
  erigon)
    # erigon requires a built-in chainspec name: its --chain flag only resolves
    # built-in names, and a custom/converted genesis file falls back silently
    # to Ethereum mainnet (see issue #9). Fail loud and early, before any build.
    if [ -z "$CHAIN" ]; then
      echo "erigon join requires a built-in chainspec: --chain xdc | xdc-apothem" >&2
      echo "This erigon-xdc build cannot load a custom/converted genesis file (its --chain" >&2
      echo "only resolves built-in names; a custom genesis would fall back to Ethereum" >&2
      echo "mainnet). See issue #9. To join a custom network, use --client geth instead." >&2
      exit 1
    fi ;;
  nethermind)
    : ;;  # nethermind loads its own chainspec from the dist, not --genesis
  *)
    # oldxdc/geth/besu/reth all consume the geth-format genesis natively.
    [ -f "$GENESIS" ] || { echo "need --genesis <file> (got '$GENESIS')" >&2; exit 1; } ;;
esac

# besu/nethermind/reth are separate toolchains (Java/.NET/Rust) that ensure_bins
# does not build; locate a prebuilt binary (env override, then PATH, then a
# binaries.json download, then a build hint). oldxdc/geth/erigon build from the
# XDPoS source via ensure_bins as before. BIN_SOURCE=build (or the per-client
# BIN_SOURCE_besu/BIN_SOURCE_reth/BIN_SOURCE_nethermind) skips the download and
# goes straight to the "not found" hint below.
case "$CLIENT" in
  besu)
    CLIENT_BIN="${BESU_BIN:-$(command -v besu 2>/dev/null)}"
    if [ ! -x "$CLIENT_BIN" ] && [ "${BIN_SOURCE_besu:-$BIN_SOURCE}" != build ]; then
      download_bins && CLIENT_BIN="$BIN_DIR/besu"
    fi
    [ -x "$CLIENT_BIN" ] || { echo "besu binary not found. Build besu-xdc (XDCIndia/besu-xdc) and set BESU_BIN=/path/to/besu, put 'besu' on PATH, or let this script download it (unset BIN_SOURCE/BIN_SOURCE_besu if you set either to 'build')." >&2; exit 1; } ;;
  reth)
    CLIENT_BIN="${RETH_BIN:-$(command -v xdc-reth 2>/dev/null)}"
    if [ ! -x "$CLIENT_BIN" ] && [ "${BIN_SOURCE_reth:-$BIN_SOURCE}" != build ]; then
      download_bins && CLIENT_BIN="$BIN_DIR/xdc-reth"
    fi
    [ -x "$CLIENT_BIN" ] || { echo "reth binary not found. Build reth-xdc (XDCIndia/reth-xdc) and set RETH_BIN=/path/to/xdc-reth, put 'xdc-reth' on PATH, or let this script download it (unset BIN_SOURCE/BIN_SOURCE_reth if you set either to 'build')." >&2; exit 1; } ;;
  nethermind)
    NM_ON_PATH=$(command -v nethermind 2>/dev/null)
    NETHERMIND_DIST="${NETHERMIND_DIST:-${NM_ON_PATH:+$(dirname "$NM_ON_PATH")}}"
    CLIENT_BIN="$NETHERMIND_DIST/nethermind"
    if [ ! -x "$CLIENT_BIN" ] && [ "${BIN_SOURCE_nethermind:-$BIN_SOURCE}" != build ]; then
      if download_bins && [ -n "$DOWNLOADED_DIST" ]; then
        NETHERMIND_DIST="$DOWNLOADED_DIST"
        CLIENT_BIN="$NETHERMIND_DIST/nethermind"
      fi
    fi
    [ -x "$CLIENT_BIN" ] || { echo "nethermind not found. Build the xdc nethermind dist (XDCIndia/nethermind) and set NETHERMIND_DIST=/path/to/dist (containing ./nethermind and chainspec/$NM_CONFIG.json), put it on PATH, or let this script download it (unset BIN_SOURCE/BIN_SOURCE_nethermind if you set either to 'build')." >&2; exit 1; }
    if [ ! -f "$NETHERMIND_DIST/chainspec/$NM_CONFIG.json" ]; then
      echo "nethermind dist '$NETHERMIND_DIST' is missing chainspec/$NM_CONFIG.json." >&2
      echo "nethermind loads its own Parity-style chainspec matching the target chainId" >&2
      echo "-- it does NOT read the geth-format --genesis -- so joining a custom network" >&2
      echo "needs either a NETHERMIND_DIST that ships a chainspec for it, or --nm-config" >&2
      echo "(env NM_CONFIG) set to a name that's already present. Chainspecs present in" >&2
      echo "'$NETHERMIND_DIST/chainspec/':" >&2
      { ls "$NETHERMIND_DIST/chainspec/" 2>/dev/null || echo "  (directory not found)"; } >&2
      exit 1
    fi ;;
  *)
    ensure_bins
    XDC="$XDC_BIN" ;;
esac

# If no explicit --bootnodes, derive the enode from ./bootnode.key at the given
# IP (--ip/--host, may include :PORT; defaults to this machine's IP:30301).
# erigon joining a built-in --chain (no --ip) uses that chain's own bootnodes,
# so skip derivation there.
# besu/nethermind/reth take the validator enodes directly (network.env
# DEFAULT_BOOTNODES / --bootnodes); a key-derived enode would carry the wrong
# node id, so never derive one for them.
if [ -z "$BOOTNODES" ] \
   && [ "$CLIENT" != besu ] && [ "$CLIENT" != nethermind ] && [ "$CLIENT" != reth ] \
   && { [ "$CLIENT" != erigon ] || [ -n "$HOST_IP" ]; }; then
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

# Default the network id to the genesis chainId (erigon --chain <name> needn't).
if [ -z "$NETWORKID" ] && [ -f "$GENESIS" ]; then
  NETWORKID=$(python3 -c "import json,sys;print(json.load(open('$GENESIS'))['config']['chainId'])" 2>/dev/null)
fi
if [ "$CLIENT" != erigon ] && [ -z "$NETWORKID" ]; then
  echo "could not read chainId from $GENESIS; pass --networkid" >&2; exit 1
fi

# erigon can't discover XDPoS peers through the bootnode (its discv4 doesn't
# traverse it), so when joining by --ip/--genesis without explicit --staticpeers
# we borrow a discovering client (oldxdc/geth) to harvest the live peer enodes
# -- the same discovery geth uses -- and hand them to erigon. Gives a simple
# "just an --ip" erigon join.
if [ "$CLIENT" = erigon ] && [ -z "$STATICPEERS" ] && [ -n "$BOOTNODES" ] && [ -f "$GENESIS" ]; then
  STATICPEERS=$(harvest_peers "$GENESIS" "$BOOTNODES" "${NETWORKID:-0}")
  if [ -n "$STATICPEERS" ]; then
    echo "  harvested $(echo "$STATICPEERS" | tr ',' '\n' | grep -c enode) peer(s) from the network"
  else
    echo "  warning: could not harvest peers; erigon may stay at peers=0 (pass --staticpeers)" >&2
  fi
fi

IP=$(detect_ip)
# Dynamic machine name (robust across OSes; fallback if hostname is unset).
HOST=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)
HOST=${HOST:-node}
# Machine label for the node name's <host> token. Prefer an explicit env value
# (MACHINE in network.env or the environment) over the auto-detected hostname, so
# operators can give each host a stable, dashboard-friendly name (e.g.
# MACHINE=frankfurt-1 -> geth-v1.2-frankfurt-1-sync). Falls back to the hostname.
HOST=${MACHINE:-$HOST}
# Default identity/ethstats name: a UNIFORM <client>-v<ver>-<host>-<nodetype>
# across every client (canonical CLIENT token, real node role), so the dashboard
# reads consistently and each name lines up with its nodes/<client>-<nodetype>
# datadir. Only the version LOOKUP differs per client (each --version formats
# differently); the name shape is identical.
if [ -z "$NAME" ]; then
  case "$CLIENT" in
    erigon)     VER=$("$XDC" --version 2>/dev/null | head -1 | awk '{print $NF}') ;;
    # besu prints ONE slash-delimited token "besu/v<ver>/<os>/<jvm>" (no spaces),
    # so awk '$NF' would grab the whole string; extract just the <ver> segment.
    besu)       VER=$("$CLIENT_BIN" --version 2>/dev/null | head -1 | sed -E 's#^besu/v?([^/]+).*#\1#') ;;
    reth)       VER=$("$CLIENT_BIN" --version 2>/dev/null | head -1 | awk '{print $NF}') ;;
    nethermind) VER=$("$CLIENT_BIN" --version 2>/dev/null | grep -oiE '[0-9]+\.[0-9]+[^ ]*' | head -1) ;;
    # xone MUST use --version: its `version` SUBCOMMAND launches a full node
    # (unknown-subcommand -> node boot), which would hang here. "xone v1.0.0 (…)".
    xone)       VER=$("$XDC" --version 2>/dev/null | awk '{print $2}' | sed 's/^v//') ;;
    *)          VER=$("$XDC" version 2>/dev/null | awk '/^Version:/{print $2; exit}') ;;
  esac
  NAME="${CLIENT}-v${VER:-0}-${HOST}-${NODETYPE}"
  # Append the node's IP, then its coinbase if this node mines (--mine). Keeps the
  # <client>-name-type base and extends it, so each node is identifiable on the
  # dashboard by where it runs and (for sealers) which address it mints to. IP
  # dots -> dashes to stay one clean token; coinbase shortened to 0x+8 hex.
  NAME="${NAME}-${IP//./-}"
  [ -n "$MINEADDR" ] && NAME="${NAME}-${MINEADDR:0:10}"
fi
# ethstats/identity names must not contain URL-breaking characters -- some client
# --version strings (notably besu's "besu/vX/os/jvm") contain '/', which breaks the
# ethstats "name:secret@host" URL parsing -- so normalise to [A-Za-z0-9._-].
NAME=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9._-' '-')

# Initialise the datadir against the genesis (first run only). oldxdc and the
# GP5 geth fork both store chaindata under <datadir>/XDC and need an explicit
# init. erigon (derives from --chain), besu/reth (write genesis on first launch),
# and nethermind (loads its own chainspec) do their own thing, so skip init there.
case "$CLIENT" in
  oldxdc|geth|"")
    if [ ! -d "$DATADIR/XDC/chaindata" ]; then
      echo "Initialising $DATADIR from $GENESIS ..."
      "$XDC" --datadir "$DATADIR" init "$GENESIS" || exit 1
    fi ;;
esac

# ethstats: prepend the node name unless SPEC already includes one (name:secret@…)
ETHSTATS_ARG=""; full=""; ES_NAME=""; ES_SECRET=""; ES_HOSTPORT=""
if [ -n "$ETHSTATS" ]; then
  case "${ETHSTATS%%@*}" in
    *:*) full="$ETHSTATS";;            # already NAME:SECRET
    *)   full="${NAME}:${ETHSTATS}";;  # just SECRET -> prepend node name
  esac
  ETHSTATS_ARG="--ethstats $full"
  # Split NAME:SECRET@HOST:PORT into pieces -- reth and nethermind want the parts
  # separately and a wss:// scheme rather than geth's bare NAME:SECRET@host:port.
  ES_NAME="${full%%:*}"; _es_rest="${full#*:}"; ES_SECRET="${_es_rest%%@*}"; ES_HOSTPORT="${_es_rest#*@}"
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
    --http.api eth,net,web3,txpool,debug,admin,XDPoS \
    --ws --ws.addr 0.0.0.0 --ws.origins "*" --ws.port "$WSPORT" --ws.api eth,net,web3,XDPoS \
    $ETHSTATS_ARG &
elif [ "$CLIENT" = besu ]; then
  # besu-xdc (sync-only). Reads the geth-format genesis natively via --genesis-file
  # (no translation). Needs BOTH --bootnodes and --static-nodes-file: bootnodes are
  # only used for initial discovery, and besu drops the validators as "UselessPeer"
  # after capability negotiation unless they are pinned via static-nodes.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (besu join is sync-only)" >&2
  [ -n "$BOOTNODES" ] || { echo "besu join needs peers: set DEFAULT_BOOTNODES in network.env or pass --bootnodes" >&2; exit 1; }
  mkdir -p "$DATADIR"
  python3 -c "import json,sys;print(json.dumps([e for e in sys.argv[1].split(',') if e]))" "$BOOTNODES" > "$DATADIR/static-nodes.json"
  BESU_ES=""; [ -n "$full" ] && BESU_ES="--ethstats=$full"
  "$CLIENT_BIN" \
    --genesis-file="$GENESIS" --data-path="$DATADIR" --network-id="$NETWORKID" \
    --sync-mode=FULL --data-storage-format=BONSAI \
    --p2p-port="$PORT" --p2p-host="$IP" --nat-method=NONE \
    --bootnodes="$BOOTNODES" --static-nodes-file="$DATADIR/static-nodes.json" \
    --rpc-http-enabled=true --rpc-http-host=127.0.0.1 --rpc-http-port="$RPCPORT" \
    --rpc-http-apis=ETH,NET,WEB3,ADMIN,DEBUG,TXPOOL \
    --engine-rpc-enabled=false --min-gas-price=0 --auto-log-bloom-caching-enabled=false \
    $BESU_ES &
elif [ "$CLIENT" = reth ]; then
  # reth-xdc (sync-only). Reads the geth-format genesis natively via --chain <file>.
  # Peers via trusted-only (its discv4/v5 doesn't traverse an XDPoS bootnode), and
  # its --ethstats wants a wss:// URL, not geth's bare host:port.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (reth join is sync-only)" >&2
  [ -n "$BOOTNODES" ] || { echo "reth join needs peers: set DEFAULT_BOOTNODES in network.env or pass --bootnodes" >&2; exit 1; }
  mkdir -p "$DATADIR"
  RETH_ES=""; [ -n "$full" ] && RETH_ES="--ethstats ${ES_NAME}:${ES_SECRET}@wss://${ES_HOSTPORT}"
  "$CLIENT_BIN" node --chain "$GENESIS" --datadir "$DATADIR" \
    --port "$PORT" --discovery.port "$PORT" \
    --disable-discv5-discovery --disable-dns-discovery --trusted-only \
    --nat "extip:${IP}" --trusted-peers "$BOOTNODES" \
    --http --http.addr 127.0.0.1 --http.port "$RPCPORT" --http.api eth,net,web3,admin,debug \
    --authrpc.addr 127.0.0.1 --authrpc.port "$AUTHRPC_PORT" \
    $RETH_ES &
elif [ "$CLIENT" = nethermind ]; then
  # nethermind-xdc (sync-only). Loads its own Parity-style chainspec that ships in
  # the dist ($NETHERMIND_DIST/chainspec/$NM_CONFIG.json) via --config; it does
  # NOT read the geth-format genesis. nethermind resolves configs/ and chainspec/
  # relative to CWD, so cd into the dist first. WebSocketsPort must be set explicitly
  # (the config hardcodes 8549; a clash aborts the whole JSON-RPC stack silently).
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (nethermind join is sync-only)" >&2
  [ -n "$BOOTNODES" ] || { echo "nethermind join needs peers: set DEFAULT_BOOTNODES in network.env or pass --bootnodes" >&2; exit 1; }
  mkdir -p "$DATADIR"
  WS_PORT=$((RPCPORT + 1))
  NM_ES=""; [ -n "$full" ] && NM_ES="--EthStats.Enabled true --EthStats.Name $ES_NAME --EthStats.Secret $ES_SECRET --EthStats.Server wss://${ES_HOSTPORT}/api"
  ( cd "$NETHERMIND_DIST" && ./nethermind \
    --config "$NM_CONFIG" \
    --Init.BaseDbPath "$DATADIR" \
    --Network.P2PPort "$PORT" --Network.DiscoveryPort "$PORT" \
    --JsonRpc.Port "$RPCPORT" --JsonRpc.WebSocketsPort "$WS_PORT" --JsonRpc.Host 127.0.0.1 \
    --Network.StaticPeers "$BOOTNODES" \
    $NM_ES ) &
elif [ "$CLIENT" = xone ]; then
  # xone-native (XDCIndia/xOneGo): go-ethereum-derived XDPoS client with
  # single-dash flags. Sync-only join here -- it recognises XDPoS from the genesis
  # (config-driven) and inits from -override.genesis on a fresh datadir. Sealing
  # needs a raw -miner.key, which a sync join doesn't carry, so --mine is noted.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (xone join is sync-only; sealing needs -miner.key)" >&2
  mkdir -p "$DATADIR"
  XONE_ES=""; [ -n "$full" ] && XONE_ES="-ethstats $full"
  "$XDC" -override.genesis "$GENESIS" -networkid "$NETWORKID" -syncmode full \
    -datadir "$DATADIR" -port "$PORT" -discovery.port "$PORT" -nat "extip:${IP}" \
    -bootnodes "$BOOTNODES" \
    -http -http.addr 0.0.0.0 -http.port "$RPCPORT" -http.vhosts "*" \
    -http.api eth,net,web3,admin,debug,txpool,XDPoS \
    -authrpc.port "$AUTHRPC_PORT" \
    $XONE_ES &
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
