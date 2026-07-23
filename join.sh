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
#   --network NAME       public XDC network to join: mainnet (chainId 50) |
#                        testnet/apothem (chainId 51) | devnet5151 (default).
#                        mainnet/testnet use the vendored public genesis
#                        (genesis/genesis-<net>.json) + public bootnodes
#                        (bootnodes/<net>.list, from XinFinOrg/XinFin-Node) by
#                        default. Works with --client <c> or --client all.
#   --syncmode MODE      snap | fast | full. Default: snap for --network
#                        mainnet/testnet (bounds disk to recent state), full for
#                        devnet5151. Mapped per client (geth/xone --syncmode, besu
#                        --sync-mode, nethermind --Sync.SnapSync/FastSync; erigon +
#                        reth snap/stage-sync by default so they ignore it).
#   --genesis FILE       the target network's genesis.json (overrides --network;
#                        defaults to DEFAULT_GENESIS in network.env -- devnet 5151)
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
#                        honor OLDXDC_BIN / BESU_BIN / RETH_BIN / NETHERMIND_DIST (or PATH)
#                        ahead of both. besu & reth read the geth-format
#                        --genesis natively; erigon loads it directly (v3.5.0+); nethermind
#                        uses its own chainspec.
#   --chain NAME         erigon only: built-in chainspec (xdc | xdc-apothem). Optional
#                        -- erigon v3.5.0+ loads the --genesis file directly.
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
#   --authrpc-port N     authenticated-RPC port (erigon/reth/xone/geth; also
#                        env AUTHRPC_PORT). Per-client default as above.
#                        geth: unlike the others this is a small default
#                        CHANGE, not just an override knob -- geth always
#                        starts an (unused-by-XDPoS) Engine API listener
#                        with no flag to move it off its own hardcoded
#                        127.0.0.1:8551, a collision landmine on any host
#                        already running another geth-family process; it is
#                        now pinned to this per-client-offset default
#                        (10745) unconditionally, same as every other client.
#   --torrent-port N     erigon BitTorrent port (also env TORRENT_PORT).
#   --privapi ADDR:PORT  erigon private API address (also env PRIVAPI).
#   --mcp-port N         erigon MCP port (also env MCP_PORT).
#                        The four flags above (and their env vars) let two
#                        instances of the SAME client run side by side --
#                        otherwise they'd collide on the per-client default.
#   --maxpeers N         cap the max peer count (also env MAXPEERS). Passed
#                        through per client: oldxdc/geth/erigon --maxpeers,
#                        besu --max-peers, reth --max-peers, nethermind
#                        --Network.MaxActivePeers, xone -maxpeers. Omitted
#                        (client's own default applies) unless given --
#                        geth's own default of 25 is unchanged either way.
#   --etherbase ADDR     oldxdc --mine only: block-reward address (also env
#                        ETHERBASE). Omitted (client default) unless given.
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
MINEADDR=""; STATICPEERS=""; NETWORK=""; SYNCMODE=""
# Ports are left empty here and defaulted PER CLIENT after --client is known, so
# oldxdc/geth/erigon joins each get a distinct set (clear of run.sh) and can run
# side by side without conflict. Any explicit flag below wins.
PORT=""; RPCPORT=""; WSPORT=""
# AUTHRPC/TORRENT/PRIVAPI/MCP default PER CLIENT below too, but (unlike PORT/
# RPCPORT/WSPORT above) they also honor a pre-set env var of the same name --
# needed so two instances of the SAME client (e.g. netlab/ running N oldxdc
# nodes) can each get a distinct authrpc/torrent/privapi/mcp port without a
# --flag per instance. A bare `AUTHRPC_PORT=""` here would silently discard
# that env value, so use the "${VAR:-}" no-op-if-set form instead.
AUTHRPC_PORT="${AUTHRPC_PORT:-}"; TORRENT_PORT="${TORRENT_PORT:-}"
PRIVAPI="${PRIVAPI:-}"; MCP_PORT="${MCP_PORT:-}"
# MAXPEERS/ETHERBASE: unset by default (client's own default applies / no
# --etherbase passed) unless a flag or env var provides one.
MAXPEERS="${MAXPEERS:-}"; ETHERBASE="${ETHERBASE:-}"
# ethstats reporting is ON by default (same endpoint as run.sh); --no-ethstats
# disables it, --ethstats SPEC overrides the target.
ETHSTATS="xdc_openscan_stats_2026@stats.xdcindia.com:443"
# nethermind's chainspec name (NETHERMIND_DIST/chainspec/$NM_CONFIG.json via
# --config); env-overridable, defaults to devnet 5151. --nm-config wins over both.
NM_CONFIG="${NM_CONFIG:-xdc-devnet5151}"
while [ $# -gt 0 ]; do
  case "$1" in
    --network)     NETWORK=$2; shift 2;;
    --syncmode)    SYNCMODE=$2; shift 2;;
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
    --authrpc-port) AUTHRPC_PORT=$2; shift 2;;
    --torrent-port) TORRENT_PORT=$2; shift 2;;
    --privapi)     PRIVAPI=$2; shift 2;;
    --mcp-port)    MCP_PORT=$2; shift 2;;
    --maxpeers)    MAXPEERS=$2; shift 2;;
    --etherbase)   ETHERBASE=$2; shift 2;;
    --mine)        MINEADDR=$2; shift 2;;
    --staticpeers) STATICPEERS=$2; shift 2;;
    --ethstats)    ETHSTATS=$2; shift 2;;
    --no-ethstats) ETHSTATS=""; shift;;
    -h|--help)     sed -n '2,96p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done

# Sync mode. Default: snap for the PUBLIC networks (mainnet/testnet) so a node
# bounds its disk to recent state (~10x smaller than full/archive) and syncs in
# hours; full for devnet5151 (its legacy flat-diff base is validated in full, and
# this preserves the pre-existing devnet behaviour exactly). Override anytime with
# --syncmode snap|fast|full. Applied per-client at launch below: geth/xone
# --syncmode, besu --sync-mode (upper-cased), nethermind --Sync.SnapSync/FastSync;
# erigon and reth already snap/stage-sync by default so they take no extra flag.
if [ -z "$SYNCMODE" ]; then
  case "${NETWORK:-}" in
    mainnet|xinfin|xdc|testnet|apothem) SYNCMODE=snap ;;
    *)                                  SYNCMODE=full ;;
  esac
fi

source ./lib.sh

# Default network target so neither --ip nor --staticpeers is required.
# network.env -> DEFAULT_HOST/DEFAULT_BOOTNODE_PORT/DEFAULT_BOOTNODES/DEFAULT_GENESIS;
# peers.list -> default peers.
[ -f network.env ] && . ./network.env

# --network mainnet|testnet: sync a PUBLIC XDC network using the genesis +
# bootnodes vendored from XinFinOrg/XinFin-Node (genesis/genesis-<net>.json,
# bootnodes/<net>.list). Unset (or devnet5151) keeps the network.env default
# (devnet 5151). Explicit --genesis/--bootnodes/--networkid still win; public
# bootnodes are used by default for mainnet/testnet.
PUB_BOOTNODES_FILE=""
case "${NETWORK:-}" in
  mainnet|xinfin|xdc)
    [ -z "$GENESIS" ]   && GENESIS="genesis/genesis-mainnet.json"
    [ -z "$NETWORKID" ] && NETWORKID=50
    NM_CONFIG="${NM_CONFIG/xdc-devnet5151/xdc-mainnet}"
    PUB_BOOTNODES_FILE="bootnodes/mainnet.list" ;;
  testnet|apothem)
    [ -z "$GENESIS" ]   && GENESIS="genesis/genesis-testnet.json"
    [ -z "$NETWORKID" ] && NETWORKID=51
    NM_CONFIG="${NM_CONFIG/xdc-devnet5151/xdc-testnet}"
    PUB_BOOTNODES_FILE="bootnodes/testnet.list" ;;
  ""|devnet5151|5151|devnet) : ;;
  *) echo "unknown --network '$NETWORK' (expected: mainnet | testnet | devnet5151)" >&2; exit 1 ;;
esac
if [ -n "$PUB_BOOTNODES_FILE" ] && [ -z "$BOOTNODES" ] && [ -f "$PUB_BOOTNODES_FILE" ]; then
  BOOTNODES=$(grep -v '^[[:space:]]*#' "$PUB_BOOTNODES_FILE" | grep enode | paste -sd, -)
  echo "No --bootnodes given; using $(echo "$BOOTNODES" | tr ',' '\n' | grep -c enode) public $NETWORK bootnode(s)"
fi
[ -n "$NETWORK" ] && [ "$NETWORK" != devnet5151 ] && echo "Target network: $NETWORK (chainId ${NETWORKID:-?}, genesis ${GENESIS:-?})"

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
  [ -n "$MAXPEERS" ]    && shared+=(--maxpeers "$MAXPEERS")
  [ -n "$ETHERBASE" ]   && shared+=(--etherbase "$ETHERBASE")   # only the oldxdc --mine child uses it
  if [ -n "$ETHSTATS" ]; then shared+=(--ethstats "$ETHSTATS"); else shared+=(--no-ethstats); fi
  # Base directory for the per-client chaindata: a custom --datadir wins, else the
  # shared ./nodes tree (clear of run.sh's numbered nodes/1..N local net).
  base="${DATADIR:-nodes}"
  all_pids=()
  # Named function (not an inline single-quoted trap body): shellcheck's
  # dataflow analysis doesn't associate a `for p in ...` loop assignment
  # inside a trap's quoted argument string, so it (falsely) flags `p` as
  # referenced-but-unassigned (SC2154) there. A real function has no such
  # blind spot -- same behavior, clean lint.
  _join_stop_all_clients() {
    echo "[all] stopping ${#all_pids[@]} client(s)..."
    local p
    for p in "${all_pids[@]}"; do kill -TERM "$p" 2>/dev/null; done
    exit 0
  }
  trap _join_stop_all_clients INT TERM
  for c in $ALL_CLIENTS; do
    # Each client's chaindata lands in nodes/<client>-<nodetype> so the six chains
    # never share a datadir. Only oldxdc can seal (--mine); the rest join sync-only.
    nt=sync; [ -n "$MINEADDR" ] && [ "$c" = oldxdc ] && nt=seal
    dd="${base}/${c}-${nt}"
    args=(--client "$c" --datadir "$dd" "${shared[@]}")
    # erigon can't join via a --genesis file (its --chain only resolves built-in
    # names); when the caller didn't pass an explicit --chain, default it to the
    # net5151 built-in chainspec so `--client all` doesn't fail erigon's own
    # early validation. Harmless for the other clients (they ignore --chain).
    [ "$c" = erigon ] && [ -z "$CHAIN" ] && args+=(--chain "${ERIGON_CHAIN:-xdc-net5151}")
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
    # erigon-xdc v3.5.0+ CAN load a genesis FILE via --chain <path> (verified: it
    # writes the custom genesis and computes the correct hash, e.g. net5151
    # 0x96f121). So --chain is optional now: with no --chain we hand erigon the
    # --genesis file directly (issue #9 was an older build that only resolved
    # built-in names). A built-in --chain name (xdc | xdc-apothem) still wins; but
    # do NOT use the built-in xdc-net5151/xdc-devnet5151 names -- their compiled-in
    # genesis is stale (0x11b449 != live 0x96f121) and won't peer. Just need a
    # genesis file when no built-in name is given.
    if [ -z "$CHAIN" ] && [ ! -f "$GENESIS" ]; then
      echo "erigon join needs a genesis: pass --genesis <file> (or a built-in --chain xdc | xdc-apothem)." >&2
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
    # oldxdc/geth/erigon build from the XDPoS source via ensure_bins. BUT the
    # current OLDXDC-master build produces an INCOMPATIBLE genesis for net5151
    # (0x3b622c) vs the live chain (0x96f121), so oldxdc gets 0 peers and never
    # leaves block 0 (issue #33). The
    # masternodes run XDPoSChain v2.7.0-devnet, which computes 0x96f121 from the
    # SAME genesis-5151.json and syncs. So let an operator point --client oldxdc at
    # that binary via OLDXDC_BIN (mirrors BESU_BIN/RETH_BIN); otherwise fall back to
    # the source build (works for geth/erigon; oldxdc needs a v2.7.0-devnet build).
    if [ "$CLIENT" = oldxdc ] && [ -n "$OLDXDC_BIN" ] && [ -x "$OLDXDC_BIN" ]; then
      XDC="$OLDXDC_BIN"
      echo "Using OLDXDC_BIN=$OLDXDC_BIN ($("$XDC" version 2>/dev/null | awk '/^Version/{print $2; exit}'))"
    else
      ensure_bins
      XDC="$XDC_BIN"
    fi ;;
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
  # erigon-xdc v3.5.0+ reads the geth-format --genesis directly via --chain <file>
  # (verified: net5151 -> 0x96f121, full fork schedule, synced to tip). So hand it
  # the ORIGINAL genesis file, not a stripped conversion (the old conversion
  # dropped london/eip1559/cancun fork blocks -> wrong schedule). A built-in
  # --chain NAME still wins, for xdc | xdc-apothem.
  ERC="${CHAIN:-$GENESIS}"
  [ -n "$CHAIN" ] && echo "  erigon built-in chain=$CHAIN" || echo "  erigon genesis-file chain=$ERC (loads directly)"
  echo "  erigon chain=$ERC ports authrpc:$AUTHRPC_PORT torrent:$TORRENT_PORT privapi:$PRIVAPI mcp:$MCP_PORT"
  BN_ARG=""; [ -n "$BOOTNODES" ] && BN_ARG="--bootnodes $BOOTNODES"
  SP_ARG=""; [ -n "$STATICPEERS" ] && SP_ARG="--staticpeers $STATICPEERS"
  [ -z "$STATICPEERS" ] && echo "  note: no --staticpeers given; erigon may not discover XDPoS peers via the bootnode alone" >&2
  MP_ARG=""; [ -n "$MAXPEERS" ] && MP_ARG="--maxpeers $MAXPEERS"
  "$XDC" --datadir "$DATADIR" --chain "$ERC" --discv4 \
    --port "$PORT" --nat "extip:${IP}" $BN_ARG $SP_ARG $MP_ARG \
    --http --http.addr 0.0.0.0 --http.port "$RPCPORT" --http.vhosts "*" \
    --http.corsdomain "*" --http.api eth,net,web3,erigon,debug,txpool \
    --ws --ws.port "$WSPORT" \
    --authrpc.port "$AUTHRPC_PORT" --torrent.port "$TORRENT_PORT" \
    --private.api.addr "$PRIVAPI" --mcp.port "$MCP_PORT" \
    $ETHSTATS_ARG &
elif [ "$CLIENT" = geth ]; then
  # Modern geth: dot-notation flags, sync-only (it can't seal here). --maxpeers
  # keeps its long-standing default of 25 unless --maxpeers/env MAXPEERS overrides it.
  #
  # --authrpc.port is a DELIBERATE exception to "defaults unchanged": geth
  # always starts an Engine API (authrpc) listener regardless -- unused by
  # XDPoS ("Engine API started but chain not configured for merge yet") --
  # defaulting to 127.0.0.1:8551 with NO flag to move it. That's a
  # collision landmine on any shared host running more than one geth-family
  # process (run.sh's own --mixed node5 already had to work around exactly
  # this: "commonly already taken by another node ... would otherwise crash
  # node 5 at startup"). Pinning it to AUTHRPC_PORT's already-computed
  # per-client-offset default (here: 10745) just brings geth in line with
  # every OTHER join.sh client, which already gets an explicit, non-default
  # authrpc port unconditionally.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (geth join is sync-only)" >&2
  "$XDC" --datadir "$DATADIR" --networkid "$NETWORKID" --syncmode "$SYNCMODE" \
    --bootnodes "$BOOTNODES" --port "$PORT" --nat "extip:${IP}" --identity "$NAME" --maxpeers "${MAXPEERS:-25}" \
    --http --http.corsdomain "*" --http.addr 0.0.0.0 --http.port "$RPCPORT" --http.vhosts "*" \
    --http.api eth,net,web3,txpool,debug,admin,XDPoS \
    --ws --ws.addr 0.0.0.0 --ws.origins "*" --ws.port "$WSPORT" --ws.api eth,net,web3,XDPoS \
    --authrpc.port "$AUTHRPC_PORT" \
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
  MP_ARG=""; [ -n "$MAXPEERS" ] && MP_ARG="--max-peers=$MAXPEERS"
  # besu expects an upper-case sync mode (SNAP|FAST|FULL); map from $SYNCMODE.
  BESU_SYNC=$(printf '%s' "$SYNCMODE" | tr '[:lower:]' '[:upper:]')
  "$CLIENT_BIN" \
    --genesis-file="$GENESIS" --data-path="$DATADIR" --network-id="$NETWORKID" \
    --sync-mode="$BESU_SYNC" --data-storage-format=BONSAI \
    --p2p-port="$PORT" --p2p-host="$IP" --nat-method=NONE \
    --bootnodes="$BOOTNODES" --static-nodes-file="$DATADIR/static-nodes.json" \
    --rpc-http-enabled=true --rpc-http-host=127.0.0.1 --rpc-http-port="$RPCPORT" \
    --rpc-http-apis=ETH,NET,WEB3,ADMIN,DEBUG,TXPOOL \
    --engine-rpc-enabled=false --min-gas-price=0 --auto-log-bloom-caching-enabled=false \
    $MP_ARG $BESU_ES &
elif [ "$CLIENT" = reth ]; then
  # reth-xdc (sync-only). Reads the geth-format genesis natively via --chain <file>.
  # Peers via trusted-only (its discv4/v5 doesn't traverse an XDPoS bootnode), and
  # its --ethstats wants a wss:// URL, not geth's bare host:port.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (reth join is sync-only)" >&2
  [ -n "$BOOTNODES" ] || { echo "reth join needs peers: set DEFAULT_BOOTNODES in network.env or pass --bootnodes" >&2; exit 1; }
  mkdir -p "$DATADIR"
  RETH_ES=""; [ -n "$full" ] && RETH_ES="--ethstats ${ES_NAME}:${ES_SECRET}@wss://${ES_HOSTPORT}"
  MP_ARG=""; [ -n "$MAXPEERS" ] && MP_ARG="--max-peers $MAXPEERS"
  # reth now achieves strict net5151 state parity natively: it applies the
  # TIPSigning 0x89 wipe and the net5151 calldata-gas / basefee-floor corrections,
  # so its own state root matches the header across the V1->V2 switch at 1800 with
  # NO state-root masking. (XDCIndia/reth main >= 22adb15, PRs #247/#249/#242 --
  # the earlier XDC_ENABLE_STATE_ROOT_BYPASS is gone.) Point RETH_BIN at a build
  # of main; older bypass-based builds are no longer needed.
  "$CLIENT_BIN" node --chain "$GENESIS" --datadir "$DATADIR" \
    --port "$PORT" --discovery.port "$PORT" \
    --disable-discv5-discovery --disable-dns-discovery --trusted-only \
    --nat "extip:${IP}" --trusted-peers "$BOOTNODES" \
    --http --http.addr 127.0.0.1 --http.port "$RPCPORT" --http.api eth,net,web3,admin,debug \
    --authrpc.addr 127.0.0.1 --authrpc.port "$AUTHRPC_PORT" \
    $MP_ARG $RETH_ES &
elif [ "$CLIENT" = nethermind ]; then
  # nethermind-xdc (sync-only). Loads its own Parity-style chainspec that ships in
  # the dist ($NETHERMIND_DIST/chainspec/$NM_CONFIG.json) via --config; it does
  # NOT read the geth-format genesis. nethermind resolves configs/ and chainspec/
  # relative to CWD, so cd into the dist first. WebSocketsPort must be set explicitly
  # (the config hardcodes 8549; a clash aborts the whole JSON-RPC stack silently).
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (nethermind join is sync-only)" >&2
  [ -n "$BOOTNODES" ] || { echo "nethermind join needs peers: set DEFAULT_BOOTNODES in network.env or pass --bootnodes" >&2; exit 1; }
  mkdir -p "$DATADIR"
  # Resolve the datadir to an ABSOLUTE path BEFORE the `cd "$NETHERMIND_DIST"`
  # below: nethermind is launched from inside the dist (to resolve configs/ and
  # chainspec/), so a relative --Init.BaseDbPath would land inside the dist dir
  # (e.g. <dist>/nodes/<client>-sync) instead of here -- and silently reuse a
  # stale DB there, ignoring the intended (and chainspec-fresh) datadir.
  NM_DATADIR="$(cd "$DATADIR" && pwd)"
  WS_PORT=$((RPCPORT + 1))
  NM_ES=""; [ -n "$full" ] && NM_ES="--EthStats.Enabled true --EthStats.Name $ES_NAME --EthStats.Secret $ES_SECRET --EthStats.Server wss://${ES_HOSTPORT}/api"
  MP_ARG=""; [ -n "$MAXPEERS" ] && MP_ARG="--Network.MaxActivePeers $MAXPEERS"
  # nethermind sync mode is config-driven (no --syncmode). Map $SYNCMODE to its
  # Sync.* toggles: snap => SnapSync (+FastSync), fast => FastSync; full => neither
  # (its default, which is what devnet5151 has always used -> unchanged there).
  NM_SYNC=""
  case "$SYNCMODE" in
    snap) NM_SYNC="--Sync.SnapSync true --Sync.FastSync true" ;;
    fast) NM_SYNC="--Sync.FastSync true" ;;
  esac
  # net5151: disable nethermind peer persistence. With it ON, the DB-loaded copies
  # of the validator node IDs register in the peer pool BEFORE the static-config
  # entries, so those nodes never land in _staticPeers; once the validators drop
  # nethermind as UselessPeer (they do, on the legacy XDPoS base), nethermind never
  # reconnects -- 0 peers, "Waiting for peers..." forever, stalled behind tip.
  # IsPeersPersistenceOn is NOT exposed as a CLI arg in this build, so patch it into
  # the dist config before launch (idempotent). Verified live: nethermind then holds
  # the validators and stays on-tip. Underlying nethermind fix: xdc-nethermind #249.
  python3 - "$NETHERMIND_DIST/configs/$NM_CONFIG.json" <<'PY'
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p))
    cfg.setdefault("Network", {})["IsPeersPersistenceOn"] = False
    json.dump(cfg, open(p, "w"), indent=2)
    print("  nethermind: set Network.IsPeersPersistenceOn=false in %s" % p)
except Exception as e:
    sys.stderr.write("  warning: could not patch nethermind config %s: %s\n" % (p, e))
PY
  ( cd "$NETHERMIND_DIST" && ./nethermind \
    --config "$NM_CONFIG" \
    --Init.BaseDbPath "$NM_DATADIR" \
    --Network.P2PPort "$PORT" --Network.DiscoveryPort "$PORT" \
    --JsonRpc.Port "$RPCPORT" --JsonRpc.WebSocketsPort "$WS_PORT" --JsonRpc.Host 127.0.0.1 \
    --Network.StaticPeers "$BOOTNODES" \
    $NM_SYNC $MP_ARG $NM_ES ) &
elif [ "$CLIENT" = xone ]; then
  # xone-native (XDCIndia/xOneGo): go-ethereum-derived XDPoS client with
  # single-dash flags. Sync-only join here -- it recognises XDPoS from the genesis
  # (config-driven) and inits from -override.genesis on a fresh datadir. Sealing
  # needs a raw -miner.key, which a sync join doesn't carry, so --mine is noted.
  [ -n "$MINEADDR" ] && echo "note: --mine ignored (xone join is sync-only; sealing needs -miner.key)" >&2
  mkdir -p "$DATADIR"
  XONE_ES=""; [ -n "$full" ] && XONE_ES="-ethstats $full"
  MP_ARG=""; [ -n "$MAXPEERS" ] && MP_ARG="-maxpeers $MAXPEERS"
  "$XDC" -override.genesis "$GENESIS" -networkid "$NETWORKID" -syncmode "$SYNCMODE" \
    -datadir "$DATADIR" -port "$PORT" -discovery.port "$PORT" -nat "extip:${IP}" \
    -bootnodes "$BOOTNODES" $MP_ARG \
    -http -http.addr 0.0.0.0 -http.port "$RPCPORT" -http.vhosts "*" \
    -http.api eth,net,web3,admin,debug,txpool,XDPoS \
    -authrpc.port "$AUTHRPC_PORT" \
    $XONE_ES &
else
  # oldxdc (XDPoSChain): classic flags; --mine unlocks a validator to also seal.
  # --maxpeers/--etherbase are additive: omitted (client default) unless given.
  MINE_FLAGS=""
  if [ -n "$MINEADDR" ]; then
    touch .pwd
    MINE_FLAGS="--unlock $MINEADDR --password ./.pwd --mine --gasprice 1"
    [ -n "$ETHERBASE" ] && MINE_FLAGS="$MINE_FLAGS --etherbase $ETHERBASE"
  fi
  MP_ARG=""; [ -n "$MAXPEERS" ] && MP_ARG="--maxpeers $MAXPEERS"
  "$XDC" --datadir "$DATADIR" --networkid "$NETWORKID" --syncmode full \
    --bootnodes "$BOOTNODES" --port "$PORT" --nat "extip:${IP}" --identity "$NAME" $MP_ARG \
    --rpc --rpccorsdomain "*" --rpcaddr 0.0.0.0 --rpcport "$RPCPORT" --rpcvhosts "*" \
    --ws --wsaddr 0.0.0.0 --wsorigins "*" --wsport "$WSPORT" \
    --rpcapi admin,db,eth,debug,miner,net,shh,txpool,personal,web3,XDPoS \
    $MINE_FLAGS $ETHSTATS_ARG &
fi
child_proc=$!
wait
