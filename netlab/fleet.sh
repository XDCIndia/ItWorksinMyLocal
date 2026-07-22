#!/bin/bash
# fleet.sh - whole-topology lifecycle: up|down|status|wipe|logs.
#
#   fleet.sh up     <topology.json> [--wipe]
#   fleet.sh down   <topology.json> [--force]
#   fleet.sh status <topology.json>
#   fleet.sh wipe   <topology.json> [--force]
#   fleet.sh logs   <topology.json> [nodeId|bootnode] [-f|--follow] [-n N]
#
# `up` sequence (D5's "hub + staggered + capped" peering model):
#   1. topo.sh print  -> nodes/<name>/topo.resolved.tsv (validates first;
#      hard-errors on any violation -- see netlab/TOPOLOGY.md)
#   2. health.sh preflight (disk/RAM/every resolved port, real bind test)
#   3. node.sh addr for every sealer -> derives (or reuses) each one's
#      keystore address BEFORE any genesis exists
#   4. gen-genesis.sh --signers <those addresses> --out
#      nodes/<name>/genesis.json -- this topology's OWN genesis, never
#      ./genesis/genesis.json
#   5. start this topology's own local bootnode (shared ./bootnode.key,
#      same derivation run.sh uses), at the bootnode_port topo.sh reserved
#      just past the last node's port block
#   6. node.sh start every sealer (they peer with each other through that
#      bootnode); health.sh wait-rpc each
#   7. gather every sealer's live enode via admin_nodeInfo
#   8. node.sh start each follower ONE AT A TIME, in declaration order,
#      --bootnodes = the gathered sealer enodes (comma-joined) -- followers
#      dial sealers directly, never each other (D5) -- gated on
#      health.sh wait-rpc + wait-peers>=1 before starting the next one, with
#      an extra staggerSeconds settle pause from the topology (default 5)
#
# `down` stops in REVERSE declaration order (so followers stop before the
# sealers they depend on), then the bootnode -- all via node.sh's graceful
# stop (SIGTERM -> poll 45s -> SIGKILL only behind --force). `wipe` runs
# `down` first (refusing on a still-running node unless --force, exactly
# like node.sh wipe) then removes nodes/<name>/ entirely.

_NETLAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_NETLAB_DIR/.." && pwd)" || exit 1
TOPO_SH="$_NETLAB_DIR/topo.sh"
NODE_SH="$_NETLAB_DIR/node.sh"
HEALTH_SH="$_NETLAB_DIR/health.sh"

# shellcheck source=../lib.sh
source "$REPO_ROOT/lib.sh"
# shellcheck source=../lib-rpc.sh
source "$REPO_ROOT/lib-rpc.sh"

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") up     <topology.json> [--wipe]
       $(basename "$0") down   <topology.json> [--force]
       $(basename "$0") status <topology.json>
       $(basename "$0") wipe   <topology.json> [--force]
       $(basename "$0") logs   <topology.json> [nodeId|bootnode] [-f|--follow] [-n N]
EOF
  exit 1
}

[ $# -ge 2 ] || usage
CMD="$1"; TOPO_FILE="$2"; shift 2
case "$CMD" in
  up|down|status|wipe|logs) ;;
  *) usage ;;
esac
[ -f "$TOPO_FILE" ] || { echo "fleet.sh: no such topology file: $TOPO_FILE" >&2; exit 1; }
# Absolute path: every helper below (topo.sh/node.sh/health.sh) is invoked
# from various cwds, and this gets embedded in meta files.
TOPO_FILE="$(cd "$(dirname "$TOPO_FILE")" && pwd)/$(basename "$TOPO_FILE")" || exit 1

OPT_WIPE=0; OPT_FORCE=0; OPT_FOLLOW=0; OPT_LINES=50; OPT_TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --wipe)      OPT_WIPE=1; shift;;
    --force)     OPT_FORCE=1; shift;;
    -f|--follow) OPT_FOLLOW=1; shift;;
    -n)          OPT_LINES=$2; shift 2;;
    *)
      if [ -z "$OPT_TARGET" ] && [ "$CMD" = logs ]; then OPT_TARGET="$1"; shift
      else echo "fleet.sh: unknown argument: $1" >&2; exit 1; fi
      ;;
  esac
done

# ---------------------------------------------------------------------------
# _fleet_resolve: topo.sh print once -> TOPO_* meta vars, NODE_IDS (ordered
# array), and per-id lookups (ROLE_OF/RPC_OF associative arrays). node.sh
# reads client (NODE_CLIENT) itself when reporting per-node status/logs, so
# fleet.sh -- which only ever branches on role and dials by rpc port -- has
# no need for its own client lookup.
# Single source of truth -- nothing here re-derives port math or re-checks
# constraints; topo.sh already did both.
# ---------------------------------------------------------------------------
declare -a NODE_IDS
declare -A ROLE_OF RPC_OF

_fleet_resolve() {
  local out
  out="$("$TOPO_SH" print "$TOPO_FILE")" || return 1
  NODE_IDS=(); ROLE_OF=(); RPC_OF=()

  local assigns
  assigns="$(printf '%s\n' "$out" | python3 -c "
import sys

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


def shq(s):
    return \"'\" + s.replace(\"'\", \"'\\\\''\") + \"'\"


for k, v in meta.items():
    print('TOPO_%s=%s' % (k.upper(), shq(v)))
print('NODE_IDS=(%s)' % ' '.join(shq(r['id']) for r in rows))
for r in rows:
    print('ROLE_OF[%s]=%s' % (shq(r['id']), shq(r['role'])))
    print('RPC_OF[%s]=%s' % (shq(r['id']), shq(r['rpc'])))
")" || return 1
  eval "$assigns"

  RUN_DIR="$REPO_ROOT/nodes/$TOPO_NAME"
  RESOLVED_TSV="$RUN_DIR/topo.resolved.tsv"
  GENESIS_FILE="$RUN_DIR/genesis.json"
  BOOTNODE_PIDFILE="$RUN_DIR/bootnode.pid"
  BOOTNODE_LOGFILE="$RUN_DIR/bootnode.log"
}

_pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

_fleet_node_enode() {
  local url="$1" info
  info=$(lab_rpc_call "$url" admin_nodeInfo "[]") || return 1
  python3 -c "
import json
import sys

print(json.loads(sys.argv[1]).get('enode', ''))
" "$info"
}

# ---------------------------------------------------------------------------
# cmd_up
# ---------------------------------------------------------------------------
cmd_up() {
  if [ "$OPT_WIPE" = 1 ]; then
    echo "fleet.sh: --wipe: tearing down and clearing any existing state first..." >&2
    cmd_down --best-effort
    _fleet_resolve || return 1
    rm -rf "$RUN_DIR"
  fi

  _fleet_resolve || return 1
  mkdir -p "$RUN_DIR" || return 1

  echo "fleet.sh: resolving topology '$TOPO_NAME' ($TOPO_NODE_COUNT nodes, $TOPO_SEALER_COUNT sealer)..." >&2
  "$TOPO_SH" print "$TOPO_FILE" > "$RESOLVED_TSV" || return 1
  echo "fleet.sh: wrote $RESOLVED_TSV" >&2

  echo "fleet.sh: preflight..." >&2
  "$HEALTH_SH" preflight "$TOPO_FILE" || { echo "fleet.sh: preflight failed, aborting up" >&2; return 1; }

  # -- sealer addresses, BEFORE any genesis exists --
  local id addrs="" addr
  for id in "${NODE_IDS[@]}"; do
    [ "${ROLE_OF[$id]}" = sealer ] || continue
    addr=$("$NODE_SH" addr "$TOPO_FILE" "$id") || return 1
    echo "fleet.sh: sealer $id -> $addr" >&2
    [ -n "$addrs" ] && addrs="$addrs,$addr"
    addrs="${addrs:-$addr}"
  done
  [ -n "$addrs" ] || { echo "fleet.sh: no sealer addresses resolved" >&2; return 1; }

  # -- genesis (this topology's own, at nodes/<name>/genesis.json) --
  if [ -f "$GENESIS_FILE" ]; then
    echo "fleet.sh: reusing existing $GENESIS_FILE (pass --wipe for a fresh one)" >&2
  else
    echo "fleet.sh: generating genesis (chainId=$TOPO_CHAINID signers=$addrs)..." >&2
    local skip_v1_arg="false"; [ "$TOPO_SKIPV1VALIDATION" = true ] && skip_v1_arg="true"
    # puppeth (via gen-genesis.sh) rejects "--network" names containing a
    # hyphen ("no spaces or hyphens, please") -- every shipped topology name
    # has one (legacy-4, mixed-5, all-clients), so sanitise it here rather
    # than rename the topologies. Confirmed live: an unsanitised hyphenated
    # --network desyncs puppeth's scripted-input wizard entirely (it prints
    # its "no hyphens" rejection, which consumes one of the piped answer
    # lines meant for a later prompt, cascading into unrelated menu errors
    # and eventually an EOF crash before a single genesis field is set).
    local puppeth_network; puppeth_network=$(printf '%s' "netlab_$TOPO_NAME" | tr '-' '_')
    # --timestamp 0x0: puppeth otherwise stamps the live wall-clock time
    # into the header (part of the genesis hash, unlike --period/
    # --skip-v1-validation), which would make two `up --wipe` runs for the
    # SAME topology hash differently every time -- breaking D6's
    # determinism goal (confirmed live: an --skip-v1-validation/--period-only
    # regeneration diffed identical in every field except `timestamp`).
    ( cd "$REPO_ROOT" && ./gen-genesis.sh \
        --network "$puppeth_network" --chainid "$TOPO_CHAINID" --signers "$addrs" \
        --owner "${addrs%%,*}" --foundation "${addrs%%,*}" \
        --foundation-owners "$addrs" --team-owners "$addrs" \
        --swap "${addrs%%,*}" --prefund "${addrs%%,*}" \
        --reward "$TOPO_REWARD" --v2block "$TOPO_V2BLOCK" --epoch "$TOPO_EPOCH" \
        --gap "$TOPO_GAP" --period "$TOPO_PERIOD" --skip-v1-validation "$skip_v1_arg" \
        --timestamp 0x0 \
        --out "$GENESIS_FILE" )
    local gg_rc=$?
    # gen-genesis.sh's underlying puppeth wizard always drops its own
    # "$puppeth_network.json" export next to gen-genesis.sh (i.e. at
    # $REPO_ROOT, regardless of --out) -- a known side effect
    # lab/gen-lab-genesis.sh's own header explicitly documents and avoids
    # by not using puppeth at all. fleet.sh DOES need gen-genesis.sh (for
    # arbitrary per-topology signers/chainId), so it inherits that stray
    # file; clean it up here rather than leaving repo-root state mutated
    # by a topology run (D6 -- instance-scoped state only).
    rm -f "$REPO_ROOT/${puppeth_network}.json"
    [ "$gg_rc" -eq 0 ] || return 1
  fi

  # -- bootnode --
  if _pid_alive "$(cat "$BOOTNODE_PIDFILE" 2>/dev/null)"; then
    echo "fleet.sh: bootnode already running" >&2
  else
    local ip; ip=$(detect_ip)
    echo "fleet.sh: starting bootnode on ${ip}:${TOPO_BOOTNODE_PORT}..." >&2
    nohup "$BOOTNODE_BIN" -nodekey "$REPO_ROOT/bootnode.key" -addr "${ip}:${TOPO_BOOTNODE_PORT}" \
      >"$BOOTNODE_LOGFILE" 2>&1 &
    echo $! > "$BOOTNODE_PIDFILE"
  fi

  # -- sealers --
  for id in "${NODE_IDS[@]}"; do
    [ "${ROLE_OF[$id]}" = sealer ] || continue
    "$NODE_SH" start "$TOPO_FILE" "$id" --genesis "$GENESIS_FILE" || return 1
  done
  for id in "${NODE_IDS[@]}"; do
    [ "${ROLE_OF[$id]}" = sealer ] || continue
    "$HEALTH_SH" wait-rpc "http://127.0.0.1:${RPC_OF[$id]}" 60 || { echo "fleet.sh: sealer $id never came up" >&2; return 1; }
  done

  # -- gather sealer enodes for the followers --
  local sealer_enodes="" e
  for id in "${NODE_IDS[@]}"; do
    [ "${ROLE_OF[$id]}" = sealer ] || continue
    e=$(_fleet_node_enode "http://127.0.0.1:${RPC_OF[$id]}") || { echo "fleet.sh: could not read enode for $id" >&2; return 1; }
    [ -n "$e" ] || { echo "fleet.sh: empty enode for $id" >&2; return 1; }
    [ -n "$sealer_enodes" ] && sealer_enodes="$sealer_enodes,"
    sealer_enodes="${sealer_enodes}${e}"
  done
  echo "fleet.sh: gathered $(echo "$sealer_enodes" | tr ',' '\n' | grep -c enode) sealer enode(s)" >&2

  # -- followers, staggered, gated on peers>=1 --
  for id in "${NODE_IDS[@]}"; do
    [ "${ROLE_OF[$id]}" = sealer ] && continue
    "$NODE_SH" start "$TOPO_FILE" "$id" --genesis "$GENESIS_FILE" --bootnodes "$sealer_enodes" || return 1
    "$HEALTH_SH" wait-rpc "http://127.0.0.1:${RPC_OF[$id]}" 90 || { echo "fleet.sh: follower $id never came up" >&2; return 1; }
    "$HEALTH_SH" wait-peers "http://127.0.0.1:${RPC_OF[$id]}" 1 60 || echo "fleet.sh: WARNING: follower $id still has 0 peers -- continuing anyway" >&2
    sleep "${TOPO_STAGGERSECONDS:-5}"
  done

  echo "fleet.sh: '$TOPO_NAME' is up ($TOPO_NODE_COUNT nodes)" >&2
  cmd_status
}

# ---------------------------------------------------------------------------
# cmd_down: reverse declaration order (followers before the sealers they
# depend on), then the bootnode. --best-effort (internal, used by `up
# --wipe`) never returns nonzero -- best-effort cleanup before a fresh up.
# ---------------------------------------------------------------------------
cmd_down() {
  local best_effort=0
  [ "${1:-}" = "--best-effort" ] && best_effort=1
  _fleet_resolve || { [ "$best_effort" = 1 ] && return 0 || return 1; }

  local fail=0 id force_args=()
  [ "$OPT_FORCE" = 1 ] && force_args=(--force)

  local -a reversed=()
  for ((i = ${#NODE_IDS[@]} - 1; i >= 0; i--)); do reversed+=("${NODE_IDS[$i]}"); done

  for id in "${reversed[@]}"; do
    "$NODE_SH" stop "$TOPO_FILE" "$id" "${force_args[@]}" || fail=1
  done

  if [ -f "$BOOTNODE_PIDFILE" ]; then
    local pid; pid=$(cat "$BOOTNODE_PIDFILE")
    if _pid_alive "$pid"; then
      echo "fleet.sh: stopping bootnode (pid $pid, SIGTERM)..." >&2
      kill -TERM "$pid" 2>/dev/null
      local waited=0
      while _pid_alive "$pid" && [ "$waited" -lt 45 ]; do sleep 1; waited=$((waited + 1)); done
      if _pid_alive "$pid"; then
        if [ "$OPT_FORCE" = 1 ]; then
          echo "fleet.sh: WARNING: bootnode (pid $pid) did not stop gracefully -- SIGKILL per --force" >&2
          kill -KILL "$pid" 2>/dev/null
        else
          echo "fleet.sh: bootnode (pid $pid) did not stop within 45s; rerun with --force to SIGKILL" >&2
          fail=1
        fi
      fi
    fi
    rm -f "$BOOTNODE_PIDFILE"
  fi

  [ "$best_effort" = 1 ] && return 0
  return $fail
}

# ---------------------------------------------------------------------------
# cmd_status
# ---------------------------------------------------------------------------
cmd_status() {
  _fleet_resolve || return 1
  local id
  for id in "${NODE_IDS[@]}"; do
    "$NODE_SH" status "$TOPO_FILE" "$id"
  done
  if [ -f "$BOOTNODE_PIDFILE" ] && _pid_alive "$(cat "$BOOTNODE_PIDFILE")"; then
    echo "RUNNING  bootnode  pid=$(cat "$BOOTNODE_PIDFILE")"
  else
    echo "STOPPED  bootnode"
  fi
}

# ---------------------------------------------------------------------------
# cmd_wipe
# ---------------------------------------------------------------------------
cmd_wipe() {
  _fleet_resolve || return 1
  if [ "$OPT_FORCE" != 1 ]; then
    # Refuse if anything is still running -- same contract as node.sh wipe.
    local id running=0
    for id in "${NODE_IDS[@]}"; do
      "$NODE_SH" status "$TOPO_FILE" "$id" >/dev/null 2>&1 && running=1
    done
    if [ -f "$BOOTNODE_PIDFILE" ] && _pid_alive "$(cat "$BOOTNODE_PIDFILE")"; then running=1; fi
    if [ "$running" = 1 ]; then
      echo "fleet.sh: refusing to wipe '$TOPO_NAME' while something is still running; run 'down' first or pass --force" >&2
      return 1
    fi
  else
    cmd_down || return 1
  fi
  rm -rf "$RUN_DIR"
  echo "fleet.sh: wiped $RUN_DIR" >&2
}

# ---------------------------------------------------------------------------
# cmd_logs
# ---------------------------------------------------------------------------
cmd_logs() {
  _fleet_resolve || return 1
  if [ -z "$OPT_TARGET" ]; then
    echo "nodes: ${NODE_IDS[*]}" >&2
    echo "-- bootnode ($BOOTNODE_LOGFILE) --" >&2
    [ -f "$BOOTNODE_LOGFILE" ] && tail -n "$OPT_LINES" "$BOOTNODE_LOGFILE"
    return 0
  fi
  if [ "$OPT_TARGET" = bootnode ]; then
    [ -f "$BOOTNODE_LOGFILE" ] || { echo "fleet.sh: no bootnode log yet" >&2; return 1; }
    if [ "$OPT_FOLLOW" = 1 ]; then tail -n "$OPT_LINES" -f "$BOOTNODE_LOGFILE"; else tail -n "$OPT_LINES" "$BOOTNODE_LOGFILE"; fi
    return 0
  fi
  local follow_args=(); [ "$OPT_FOLLOW" = 1 ] && follow_args=(-f)
  "$NODE_SH" logs "$TOPO_FILE" "$OPT_TARGET" -n "$OPT_LINES" "${follow_args[@]}"
}

case "$CMD" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  wipe)   cmd_wipe ;;
  logs)   cmd_logs ;;
esac
