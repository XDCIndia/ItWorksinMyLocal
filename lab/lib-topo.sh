#!/bin/bash
# lib-topo.sh - scenario <-> netlab fleet bridge (ItWorksinMyLocal#46 T2.1).
#
# Thin wrappers around netlab/fleet.sh + netlab/node.sh + netlab/topo.sh so
# lab/ scenarios can drive a declarative topology (topologies/*.json)
# without reaching into netlab/ paths themselves, and so scenario.sh's
# generic per-scenario teardown can tear down ANY topology a scenario
# brought up without needing to know which one:
#
#   topo_up    <topology.json> [--wipe]           # netlab/fleet.sh up, records it
#   topo_down  [<topology.json>] [--force]        # netlab/fleet.sh down; no-arg form is
#                                                  # idempotent teardown-of-everything
#   topo_rpc   <topology.json> <nodeId>            # -> http://127.0.0.1:<rpc> for that node
#   topo_nodes <topology.json> [role]              # -> node ids, one per line, optionally
#                                                   #    filtered to role=sealer|follower
#   topo_stop  <topology.json> <nodeId> [--force]  # netlab/node.sh stop for one node
#
# State: lab/results/active-topologies -- one absolute topology.json path
# per line, appended to by a successful topo_up, removed by topo_down.
# scenario.sh's _run_one calls the no-arg `topo_down` both BEFORE and AFTER
# every scenario, alongside the existing lab_teardown call (same "always
# safe, best-effort, never fails the run" contract) -- so a topology left
# running by a crashed/killed scenario still gets torn down on the very
# next scenario.sh invocation, and a scenario that never touched netlab at
# all (01-11) pays a no-op (missing/empty marker file, nothing to do).
#
# Deliberately does NOT try to guess "the" topology a scenario is using --
# scenario 12 (and anything using this file) must pass the topology.json
# path explicitly to topo_up/topo_rpc/topo_nodes/topo_stop; only the
# teardown-time topo_down gets to omit it, and only because at that point
# "everything this file marked as up" is exactly what needs to go down.

_LIBTOPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_LIBTOPO_DIR/.." && pwd)" || exit 1
LAB_RESULTS_DIR="$_LIBTOPO_DIR/results"
mkdir -p "$LAB_RESULTS_DIR" 2>/dev/null || true

_TOPO_FLEET_SH="$REPO_ROOT/netlab/fleet.sh"
_TOPO_NODE_SH="$REPO_ROOT/netlab/node.sh"
_TOPO_TOPO_SH="$REPO_ROOT/netlab/topo.sh"
_TOPO_ACTIVE_FILE="$LAB_RESULTS_DIR/active-topologies"

# _topo_abspath <file>: absolute path (file must exist).
_topo_abspath() {
  local f="$1"
  [ -f "$f" ] || { echo "lib-topo.sh: no such topology file: $f" >&2; return 1; }
  (cd "$(dirname "$f")" && printf '%s/%s\n' "$(pwd)" "$(basename "$f")")
}

# _topo_mark_up/_topo_mark_down: maintain the active-topologies marker,
# deduped, one absolute path per line.
_topo_mark_up() {
  local abs="$1"
  touch "$_TOPO_ACTIVE_FILE"
  grep -qxF "$abs" "$_TOPO_ACTIVE_FILE" 2>/dev/null || printf '%s\n' "$abs" >> "$_TOPO_ACTIVE_FILE"
}

_topo_mark_down() {
  local abs="$1"
  [ -f "$_TOPO_ACTIVE_FILE" ] || return 0
  grep -vxF "$abs" "$_TOPO_ACTIVE_FILE" > "${_TOPO_ACTIVE_FILE}.tmp" 2>/dev/null
  mv "${_TOPO_ACTIVE_FILE}.tmp" "$_TOPO_ACTIVE_FILE" 2>/dev/null || rm -f "${_TOPO_ACTIVE_FILE}.tmp"
}

# ---------------------------------------------------------------------------
# topo_up <topology.json> [--wipe]
# ---------------------------------------------------------------------------
topo_up() {
  [ $# -ge 1 ] || { echo "topo_up: usage: topo_up <topology.json> [--wipe]" >&2; return 1; }
  local topo_file="$1"; shift
  local abs; abs=$(_topo_abspath "$topo_file") || return 1
  "$_TOPO_FLEET_SH" up "$abs" "$@"
  local rc=$?
  [ "$rc" -eq 0 ] && _topo_mark_up "$abs"
  return $rc
}

# ---------------------------------------------------------------------------
# topo_down [<topology.json>] [--force]
#
# No-arg (or --force-only) form: best-effort teardown of every topology
# recorded in active-topologies -- ALWAYS returns 0 (identical contract to
# lab_teardown), since this is what scenario.sh's generic per-scenario
# teardown calls unconditionally and must never itself fail a run. Entries
# are only cleared from the marker once fleet.sh down actually succeeds on
# them; a failed graceful stop is left in place (with fleet.sh's own
# warning already on stderr) so the NEXT teardown call retries it instead
# of silently forgetting about a still-running node.
#
# Single-topology form: propagates fleet.sh's real exit code, for callers
# (scenario code, an operator) that want to know whether teardown actually
# succeeded.
# ---------------------------------------------------------------------------
topo_down() {
  if [ $# -eq 0 ] || [ "$1" = "--force" ]; then
    local force_args=(); [ "${1:-}" = "--force" ] && force_args=(--force)
    [ -f "$_TOPO_ACTIVE_FILE" ] || return 0
    local abs
    while IFS= read -r abs; do
      [ -n "$abs" ] || continue
      if [ ! -f "$abs" ]; then
        echo "lib-topo.sh: topo_down: '$abs' no longer exists; dropping it from active-topologies" >&2
        _topo_mark_down "$abs"
        continue
      fi
      if "$_TOPO_FLEET_SH" down "$abs" "${force_args[@]}" >&2; then
        _topo_mark_down "$abs"
      else
        echo "lib-topo.sh: topo_down: fleet.sh down failed for '$abs' -- left in active-topologies for the next retry" >&2
      fi
    done < "$_TOPO_ACTIVE_FILE"
    return 0
  fi

  local topo_file="$1"; shift
  local abs; abs=$(_topo_abspath "$topo_file") || return 1
  "$_TOPO_FLEET_SH" down "$abs" "$@"
  local rc=$?
  [ "$rc" -eq 0 ] && _topo_mark_down "$abs"
  return $rc
}

# ---------------------------------------------------------------------------
# topo_rpc <topology.json> <nodeId> -> http://127.0.0.1:<rpc>
# ---------------------------------------------------------------------------
topo_rpc() {
  [ $# -ge 2 ] || { echo "topo_rpc: usage: topo_rpc <topology.json> <nodeId>" >&2; return 1; }
  local topo_file="$1" node_id="$2" abs out
  abs=$(_topo_abspath "$topo_file") || return 1
  out=$("$_TOPO_TOPO_SH" print "$abs") || return 1
  printf '%s\n' "$out" | python3 -c "
import sys

node_id = sys.argv[1]
header = None
for line in sys.stdin:
    line = line.rstrip('\n')
    if line.startswith('# ') or not line:
        continue
    if header is None:
        header = line.split('\t')
        continue
    row = dict(zip(header, line.split('\t')))
    if row.get('id') == node_id:
        print('http://127.0.0.1:%s' % row['rpc'])
        sys.exit(0)
sys.exit(1)
" "$node_id" || { echo "topo_rpc: no such node id '$node_id' in $abs" >&2; return 1; }
}

# ---------------------------------------------------------------------------
# topo_nodes <topology.json> [role] -> node ids, one per line, declaration
# order, optionally filtered to role=sealer|follower.
# ---------------------------------------------------------------------------
topo_nodes() {
  [ $# -ge 1 ] || { echo "topo_nodes: usage: topo_nodes <topology.json> [role]" >&2; return 1; }
  local topo_file="$1" role="${2:-}" abs out
  abs=$(_topo_abspath "$topo_file") || return 1
  out=$("$_TOPO_TOPO_SH" print "$abs") || return 1
  printf '%s\n' "$out" | python3 -c "
import sys

role = sys.argv[1]
header = None
for line in sys.stdin:
    line = line.rstrip('\n')
    if line.startswith('# ') or not line:
        continue
    if header is None:
        header = line.split('\t')
        continue
    row = dict(zip(header, line.split('\t')))
    if role == '' or row.get('role') == role:
        print(row['id'])
" "$role"
}

# ---------------------------------------------------------------------------
# topo_stop <topology.json> <nodeId> [--force]: graceful-only (D3),
# delegates entirely to node.sh stop.
# ---------------------------------------------------------------------------
topo_stop() {
  [ $# -ge 2 ] || { echo "topo_stop: usage: topo_stop <topology.json> <nodeId> [--force]" >&2; return 1; }
  local topo_file="$1" node_id="$2"; shift 2
  local abs; abs=$(_topo_abspath "$topo_file") || return 1
  "$_TOPO_NODE_SH" stop "$abs" "$node_id" "$@"
}
