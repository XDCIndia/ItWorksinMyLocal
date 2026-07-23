#!/bin/bash
# node.sh - per-node lifecycle for a netlab topology instance.
#
#   node.sh start  <topology.json> <nodeId> [--bootnodes LIST] [--genesis FILE]
#   node.sh stop   <topology.json> <nodeId> [--force]
#   node.sh status <topology.json> <nodeId>
#   node.sh logs   <topology.json> <nodeId> [-f|--follow] [-n N]
#   node.sh wipe   <topology.json> <nodeId> [--force]
#   node.sh addr   <topology.json> <nodeId>     # utility: sealer-only, see below
#
# One node = one join.sh invocation, launched/tracked exactly like every
# other wrapper in this repo (nohup + a pidfile), under its own
# nodes/<topoName>/<nodeId>/ datadir (never touches ./nodes/1..4 or
# ./nodes/<client>-<type> -- see netlab/TOPOLOGY.md "Run-state layout").
#
# Graceful-only teardown (D3): `stop` SIGTERMs the tracked pid, polls up to
# 45s, then (still alive) SIGTERMs any child process directly as one more
# nudge and polls a further 5s. SIGKILL happens ONLY behind --force, with an
# explicit corruption warning -- matches the project-wide rule to never
# kill -9 a live XDPoS/reth/nethermind node.
#
# --bootnodes: a `sealer` node derives its own bootnode enode from the
# shared ./bootnode.key (same derivation run.sh uses) unless --bootnodes
# overrides it -- sealers peer with each other through the topology's own
# local bootnode. A `follower` OR `proposer` node has no such fallback:
# fleet.sh gathers the live sealer enodes (admin_nodeInfo) and MUST pass
# them via --bootnodes -- followers/proposers dial sealers directly, never
# each other (D5).
#
# `addr`: sealer/proposer-only utility (not part of the five lifecycle verbs
# above). Ensures this node's validator key (topology's keyRef, an env var
# out of .env) is imported into its keystore -- WITHOUT starting anything --
# and prints the resulting address on stdout, nothing else. This is what
# fleet.sh calls, once per sealer AND once per role=proposer node
# (ItWorksinMyLocal#62), to learn the genesis --signers list *before* any
# genesis exists (the same account-import step `start` performs lazily is
# idempotent, so calling `addr` first and then `start` later never
# double-imports). The import always goes through the oldxdc binary's own
# `account import` (see _ensure_signer_account below) regardless of this
# node's OWN client -- oldxdc/geth/xone all share the identical
# go-ethereum-lineage V3 keystore JSON format, so this is a single neutral,
# always-available way to learn (and, for keystore-reading clients, actually
# seed) the resulting address no matter which client will run here.
#
# role=proposer (ItWorksinMyLocal#62): launched with its CLIENT's own
# sealing flags (see join.sh's per-client branches) using this same derived
# address, plus -- for a client whose sealing flag wants the raw key
# directly rather than an address+keystore (xone's -miner.key) -- the raw
# keyRef value itself, via join.sh's --sealkey.

_NETLAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_NETLAB_DIR/.." && pwd)" || exit 1
TOPO_SH="$_NETLAB_DIR/topo.sh"

# shellcheck source=../lib.sh
source "$REPO_ROOT/lib.sh"
# shellcheck source=../lib-rpc.sh
source "$REPO_ROOT/lib-rpc.sh"

# .env (PRIVATE_KEY_* etc), same convention as run.sh: exported so a
# sealer's keyRef (e.g. PRIVATE_KEY_1) is readable via ${!NODE_KEYREF}.
set -a
[ -f "$REPO_ROOT/.env" ] && . "$REPO_ROOT/.env"
set +a

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") start  <topology.json> <nodeId> [--bootnodes LIST] [--genesis FILE]
       $(basename "$0") stop   <topology.json> <nodeId> [--force]
       $(basename "$0") status <topology.json> <nodeId>
       $(basename "$0") logs   <topology.json> <nodeId> [-f|--follow] [-n N]
       $(basename "$0") wipe   <topology.json> <nodeId> [--force]
       $(basename "$0") addr   <topology.json> <nodeId>
EOF
  exit 1
}

[ $# -ge 3 ] || usage
CMD="$1"; TOPO_FILE="$2"; NODE_ID="$3"; shift 3
case "$CMD" in
  start|stop|status|logs|wipe|addr) ;;
  *) usage ;;
esac
[ -f "$TOPO_FILE" ] || { echo "node.sh: no such topology file: $TOPO_FILE" >&2; exit 1; }

OPT_BOOTNODES=""; OPT_GENESIS=""; OPT_FORCE=0; OPT_FOLLOW=0; OPT_LINES=50
while [ $# -gt 0 ]; do
  case "$1" in
    --bootnodes) OPT_BOOTNODES=$2; shift 2;;
    --genesis)   OPT_GENESIS=$2; shift 2;;
    --force)     OPT_FORCE=1; shift;;
    -f|--follow) OPT_FOLLOW=1; shift;;
    -n)          OPT_LINES=$2; shift 2;;
    *) echo "node.sh: unknown flag: $1" >&2; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# _node_resolve: runs topo.sh print once, extracts this node's row + the
# topology-level meta, and shell-`eval`s them into TOPO_*/NODE_* variables.
# Single source of truth for ports/paths -- nothing here re-derives the
# portBase+i*20 math itself.
# ---------------------------------------------------------------------------
_node_resolve() {
  local out
  out="$("$TOPO_SH" print "$TOPO_FILE")" || return 1
  local assigns
  assigns="$(printf '%s\n' "$out" | python3 -c "
import sys

node_id = sys.argv[1]
meta = {}
rows = []
header = None
for line in sys.stdin:
    line = line.rstrip('\n')
    if line.startswith('# '):
        k, _, v = line[2:].partition('=')
        meta[k] = v
    elif header is None:
        header = line.split('\t')
    else:
        rows.append(dict(zip(header, line.split('\t'))))
row = next((r for r in rows if r.get('id') == node_id), None)
if row is None:
    sys.stderr.write('node.sh: no such node id in topology: %s\n' % node_id)
    sys.exit(1)


def shq(s):
    return \"'\" + s.replace(\"'\", \"'\\\\''\") + \"'\"


for k, v in meta.items():
    print('TOPO_%s=%s' % (k.upper(), shq(v)))
for k, v in row.items():
    print('NODE_%s=%s' % (k.upper(), shq(v)))
" "$NODE_ID")" || return 1
  eval "$assigns"
  NODE_DIR="$REPO_ROOT/$NODE_DATADIR"
  NODE_PIDFILE="$NODE_DIR/node.pid"
  NODE_LOGFILE="$NODE_DIR/node.log"
  NODE_METAFILE="$NODE_DIR/meta.env"
  GENESIS_FILE="${OPT_GENESIS:-$REPO_ROOT/nodes/$TOPO_NAME/genesis.json}"
}

_node_resolve || exit 1

# ---------------------------------------------------------------------------
# _pid_alive <pid>: true if that pid exists.
# ---------------------------------------------------------------------------
_pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

_read_pid() { [ -f "$NODE_PIDFILE" ] && cat "$NODE_PIDFILE" 2>/dev/null; }

# ---------------------------------------------------------------------------
# _ensure_signer_account: idempotent. Imports NODE_KEYREF's env value into
# this node's keystore if it doesn't already hold an account, else reads
# the existing one back. Prints the resulting 0x-prefixed address on stdout
# (only), everything else (including ensure_bins' own progress messages)
# is routed to stderr so callers can safely capture stdout. Valid for role
# sealer OR proposer (ItWorksinMyLocal#62) -- both need an address derived
# from their keyRef before genesis exists; a follower has no keyRef at all.
# ---------------------------------------------------------------------------
_ensure_signer_account() {
  case "$NODE_ROLE" in
    sealer|proposer) ;;
    *) echo "node.sh: ${NODE_ID}: not a sealer/proposer (role=$NODE_ROLE)" >&2; return 1 ;;
  esac
  local key="${!NODE_KEYREF:-}"
  [ -n "$key" ] || { echo "node.sh: ${NODE_ID}: keyRef '$NODE_KEYREF' is not set in the environment (check .env)" >&2; return 1; }

  local xdc
  if [ -n "${OLDXDC_BIN:-}" ] && [ -x "$OLDXDC_BIN" ]; then
    xdc="$OLDXDC_BIN"
  else
    ensure_bins >&2
    xdc="$XDC_BIN"
  fi

  mkdir -p "$NODE_DIR" || return 1
  touch "$REPO_ROOT/.pwd"

  local addr
  if [ -d "$NODE_DIR/keystore" ] && [ -n "$(ls -A "$NODE_DIR/keystore" 2>/dev/null)" ]; then
    addr=$("$xdc" account list --datadir "$NODE_DIR" 2>/dev/null | head -n 1 | grep -oE '\{[0-9a-fA-Fxdc]+\}' | tr -d '{}')
  else
    addr=$("$xdc" account import --password "$REPO_ROOT/.pwd" --datadir "$NODE_DIR" <(echo "$key") 2>/dev/null \
      | grep -oE '\{[0-9a-fA-Fxdc]+\}' | tr -d '{}')
  fi
  [ -n "$addr" ] || { echo "node.sh: ${NODE_ID}: could not determine a wallet address (check keyRef '$NODE_KEYREF')" >&2; return 1; }
  # Normalise to a canonical 0x-prefixed address regardless of which branch
  # above produced it: `account import`'s "Address: {xdc...}" and `account
  # list`'s "Account #0: {...}" (no prefix at all) format the hex
  # differently, so strip either an "xdc" or "0x" prefix (if present) and
  # re-add "0x" uniformly.
  addr=$(printf '%s' "$addr" | sed -E 's/^0[xX]//; s/^xdc//')
  addr="0x${addr}"
  printf '%s\n' "$addr"
}

# ---------------------------------------------------------------------------
# cmd_start
# ---------------------------------------------------------------------------
cmd_start() {
  local existing_pid
  existing_pid="$(_read_pid)"
  if _pid_alive "$existing_pid"; then
    echo "node.sh: ${NODE_ID}: already running (pid $existing_pid)" >&2
    return 0
  fi

  [ -f "$GENESIS_FILE" ] || {
    echo "node.sh: ${NODE_ID}: genesis not found at $GENESIS_FILE" >&2
    echo "  run 'netlab/fleet.sh up $TOPO_FILE' first, or generate it directly:" >&2
    echo "  ./gen-genesis.sh --chainid $TOPO_CHAINID --out nodes/$TOPO_NAME/genesis.json ..." >&2
    return 1
  }

  mkdir -p "$NODE_DIR" || return 1

  local bootnodes="$OPT_BOOTNODES"
  local seal_addr="" seal_key=""
  if [ "$NODE_ROLE" = sealer ]; then
    seal_addr="$(_ensure_signer_account)" || return 1
    if [ -z "$bootnodes" ]; then
      # Sealers peer with each other through this topology's own local
      # bootnode (./bootnode.key, same derivation run.sh uses), at the
      # dedicated bootnode_port topo.sh reserved just past the last node's
      # port block -- fleet.sh must have started it (cmd_status below will
      # just report a connection failure if not; this does not start one).
      local ip pubkey
      ip=$(detect_ip)
      pubkey=$("$BOOTNODE_BIN" -nodekey "$REPO_ROOT/bootnode.key" -writeaddress)
      bootnodes="enode://${pubkey}@${ip}:${TOPO_BOOTNODE_PORT}"
    fi
  elif [ "$NODE_ROLE" = proposer ]; then
    # role=proposer (ItWorksinMyLocal#62): same address derivation as a
    # sealer, but no local-bootnode fallback -- a proposer is not part of
    # the trusted quorum peering through the topology's own bootnode.key; it
    # dials the sealers directly, exactly like a follower (fleet.sh gathers
    # and passes their enodes via --bootnodes). seal_key carries the RAW
    # keyRef value too (not just the derived address) for a client whose own
    # sealing flag wants the raw private key directly instead of an
    # address+keystore (xone's -miner.key -- see join.sh's --sealkey).
    seal_addr="$(_ensure_signer_account)" || return 1
    seal_key="${!NODE_KEYREF:-}"
    [ -n "$bootnodes" ] || {
      echo "node.sh: ${NODE_ID}: proposer nodes need --bootnodes (fleet.sh gathers the" >&2
      echo "  live sealer enodes via admin_nodeInfo and passes them here, same as a" >&2
      echo "  follower -- a proposer is not a sealer and has no local-bootnode" >&2
      echo "  fallback; see ItWorksinMyLocal#62)." >&2
      return 1
    }
  else
    [ -n "$bootnodes" ] || {
      echo "node.sh: ${NODE_ID}: follower nodes need --bootnodes (fleet.sh gathers the" >&2
      echo "  live sealer enodes via admin_nodeInfo and passes them here -- see D5 in" >&2
      echo "  ItWorksinMyLocal#46)." >&2
      return 1
    }
  fi

  # ethstats reporting (ItWorksinMyLocal#62 harness fix A): OFF by default --
  # a topology opts in via its own "ethstats": true field (topo.sh print's
  # TOPO_ETHSTATS meta), or any topology can be forced on ad-hoc via
  # NETLAB_ETHSTATS=1 in the environment, without editing the JSON. When
  # enabled, this node reports to stats.xdcindia.com (join.sh's own default
  # ETHSTATS target/secret, xdc_openscan_stats_2026 -- unchanged, not
  # duplicated here) under the name "xdclabs-<TOPO_NAME>-<NODE_ID>" so the
  # whole fleet is identifiable (and groupable) on the public dashboard;
  # when disabled, --no-ethstats is passed exactly as before. Soak/
  # persistent topologies (legacy-4, mixed-5, all-clients) ship with
  # "ethstats": true; the mint-iter* gate topologies deliberately do NOT --
  # mint-iter runs churn (wiped/rebuilt every gate iteration) and would
  # just flap on the public stats page. See netlab/TOPOLOGY.md.
  local node_name="${TOPO_NAME}-${NODE_ID}"
  local ethstats_flag=(--no-ethstats)
  if [ "${TOPO_ETHSTATS:-false}" = "true" ] || [ "${NETLAB_ETHSTATS:-0}" = "1" ]; then
    node_name="xdclabs-${TOPO_NAME}-${NODE_ID}"
    ethstats_flag=()
  fi

  local args=(--genesis "$GENESIS_FILE" --client "$NODE_CLIENT" --datadir "$NODE_DIR"
    --networkid "$TOPO_CHAINID" --port "$NODE_P2P" --rpcport "$NODE_RPC" --wsport "$NODE_WS"
    --authrpc-port "$NODE_AUTHRPC" --torrent-port "$NODE_TORRENT" --mcp-port "$NODE_MCP" --privapi "$NODE_PRIVAPI"
    --bootnodes "$bootnodes" --name "$node_name" "${ethstats_flag[@]}")
  [ -n "$NODE_MAXPEERS" ] && args+=(--maxpeers "$NODE_MAXPEERS")
  if [ "$NODE_ROLE" = sealer ]; then
    args+=(--mine "$seal_addr" --etherbase "$seal_addr")
  elif [ "$NODE_ROLE" = proposer ]; then
    # role=proposer (ItWorksinMyLocal#62): --mine/--etherbase carry the
    # derived address (used by oldxdc/geth-style --unlock sealing); --sealkey
    # additionally carries the raw keyRef value for a client whose own
    # sealing flag wants the raw private key directly (xone's -miner.key) --
    # join.sh's per-client branches pick whichever of these their own client
    # actually needs and ignore the rest (see join.sh's per-client notes for
    # what each client attempts today, and what remains blocked-upstream).
    args+=(--mine "$seal_addr" --etherbase "$seal_addr")
    [ -n "$seal_key" ] && args+=(--sealkey "$seal_key")
  fi

  echo "node.sh: starting ${NODE_ID} (${NODE_CLIENT}, ${NODE_ROLE}) rpc=http://127.0.0.1:${NODE_RPC} p2p=${NODE_P2P}" >&2
  # Invoke join.sh by ABSOLUTE path as a single simple command (no `cd &&
  # nohup ... &` subshell chaining, no nested subshell at all) so `$!`
  # unambiguously names join.sh's own pid -- join.sh itself does `cd
  # "$(dirname "$0")"` as its first line, so the absolute path here is all
  # it needs to resolve everything relative to REPO_ROOT correctly. (An
  # earlier `( cd ... && nohup ... & echo $! )` version recorded the WRONG
  # pid -- a parent of the real join.sh process, already reaped by the time
  # `stop` used it -- exactly the kind of silent-no-op-teardown bug D3
  # exists to prevent; verified fixed by an actual start/status/stop cycle,
  # not just reasoning about it.)
  nohup "$REPO_ROOT/join.sh" "${args[@]}" >"$NODE_LOGFILE" 2>&1 &
  echo $! > "$NODE_PIDFILE"

  {
    echo "NODE_ID=$NODE_ID"
    echo "CLIENT=$NODE_CLIENT"
    echo "ROLE=$NODE_ROLE"
    echo "TOPOLOGY=$TOPO_NAME"
    echo "BOOTNODES=$bootnodes"
    echo "GENESIS=$GENESIS_FILE"
    echo "RPC=http://127.0.0.1:${NODE_RPC}"
    echo "STARTED_AT=$(date -u +%FT%TZ)"
  } > "$NODE_METAFILE"

  echo "node.sh: ${NODE_ID}: started (pid $(cat "$NODE_PIDFILE"))" >&2
}

# ---------------------------------------------------------------------------
# cmd_stop: SIGTERM -> poll 45s -> SIGTERM any child -> poll 5s -> (--force
# only) SIGKILL with a corruption warning. Never escalates to SIGKILL
# without --force.
# ---------------------------------------------------------------------------
cmd_stop() {
  local pid; pid="$(_read_pid)"
  if ! _pid_alive "$pid"; then
    echo "node.sh: ${NODE_ID}: not running" >&2
    rm -f "$NODE_PIDFILE"
    return 0
  fi

  echo "node.sh: stopping ${NODE_ID} (pid $pid, SIGTERM)..." >&2
  kill -TERM "$pid" 2>/dev/null
  local waited=0
  while _pid_alive "$pid" && [ "$waited" -lt 45 ]; do sleep 1; waited=$((waited + 1)); done

  if _pid_alive "$pid"; then
    echo "node.sh: ${NODE_ID}: still alive after 45s; nudging any child process..." >&2
    local child
    for child in $(pgrep -P "$pid" 2>/dev/null); do kill -TERM "$child" 2>/dev/null; done
    waited=0
    while _pid_alive "$pid" && [ "$waited" -lt 5 ]; do sleep 1; waited=$((waited + 1)); done
  fi

  if _pid_alive "$pid"; then
    if [ "$OPT_FORCE" = 1 ]; then
      echo "node.sh: WARNING: ${NODE_ID} (pid $pid) did not stop gracefully -- SIGKILL per --force (state DB corruption risk)" >&2
      kill -KILL "$pid" 2>/dev/null
      for child in $(pgrep -P "$pid" 2>/dev/null); do kill -KILL "$child" 2>/dev/null; done
      sleep 1
    else
      echo "node.sh: ${NODE_ID} (pid $pid) did not stop within 45s; refusing to SIGKILL (state corruption risk)." >&2
      echo "  rerun with --force to SIGKILL anyway." >&2
      return 1
    fi
  fi

  rm -f "$NODE_PIDFILE"
  echo "node.sh: ${NODE_ID}: stopped" >&2
}

# ---------------------------------------------------------------------------
# cmd_status
# ---------------------------------------------------------------------------
cmd_status() {
  local pid; pid="$(_read_pid)"
  if [ -z "$pid" ]; then
    echo "STOPPED  ${NODE_ID}  (${NODE_CLIENT}/${NODE_ROLE})"
    return 1
  fi
  if ! _pid_alive "$pid"; then
    echo "DEAD     ${NODE_ID}  (${NODE_CLIENT}/${NODE_ROLE})  stale pid=$pid"
    rm -f "$NODE_PIDFILE"
    return 1
  fi
  local url="http://127.0.0.1:${NODE_RPC}" block
  if block=$(LAB_RPC_TIMEOUT=2 lab_block_number "$url" 2>/dev/null); then
    echo "RUNNING  ${NODE_ID}  (${NODE_CLIENT}/${NODE_ROLE})  pid=$pid  rpc=$url  block=$block"
  else
    echo "RUNNING  ${NODE_ID}  (${NODE_CLIENT}/${NODE_ROLE})  pid=$pid  rpc=$url  block=<not up yet>"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# cmd_logs
# ---------------------------------------------------------------------------
cmd_logs() {
  [ -f "$NODE_LOGFILE" ] || { echo "node.sh: no log yet at $NODE_LOGFILE" >&2; return 1; }
  if [ "$OPT_FOLLOW" = 1 ]; then
    tail -n "$OPT_LINES" -f "$NODE_LOGFILE"
  else
    tail -n "$OPT_LINES" "$NODE_LOGFILE"
  fi
}

# ---------------------------------------------------------------------------
# cmd_wipe: refuses on a running node unless --force (which stops it first,
# via the same graceful cmd_stop path -- --force there still only SIGKILLs
# if its own 45s+5s grace fails).
# ---------------------------------------------------------------------------
cmd_wipe() {
  local pid; pid="$(_read_pid)"
  if _pid_alive "$pid"; then
    if [ "$OPT_FORCE" != 1 ]; then
      echo "node.sh: ${NODE_ID}: refusing to wipe a running node (pid $pid); stop it first or pass --force" >&2
      return 1
    fi
    cmd_stop || return 1
  fi
  rm -rf "$NODE_DIR"
  echo "node.sh: ${NODE_ID}: wiped ($NODE_DIR)" >&2
}

# ---------------------------------------------------------------------------
# cmd_addr
# ---------------------------------------------------------------------------
cmd_addr() { _ensure_signer_account; }

case "$CMD" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  logs)   cmd_logs ;;
  wipe)   cmd_wipe ;;
  addr)   cmd_addr ;;
esac
