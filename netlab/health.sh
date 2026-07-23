#!/bin/bash
# health.sh - readiness gates + a preflight check for a netlab topology.
#
#   health.sh wait-rpc    <url> [timeout_s=60]
#   health.sh wait-peers  <url> <minPeers> [timeout_s=60]
#   health.sh wait-block  <url> <N> [timeout_s=120]
#   health.sh preflight   <topology.json> [--min-disk-gb N] [--min-ram-gb N]
#
# wait-* are the gates fleet.sh (T1.5) chains between bring-up steps: "wait
# for a sealer's RPC to answer", "wait for a follower to reach peers>=1
# before starting the next one" (D5's staggered bring-up), etc. Each prints
# a one-line OK/TIMEOUT verdict and exits 0/1 accordingly -- safe to use
# directly in a shell `if` without capturing output.
#
# preflight resolves the topology (via topo.sh print) and hard-checks, all
# BEFORE any process starts:
#   - disk:  free space on the filesystem holding the repo, against
#            --min-disk-gb (default 5)
#   - ram:   available memory, against --min-ram-gb (default 2)
#   - ports: every resolved port (p2p/rpc/ws/authrpc/torrent/mcp/privapi
#            for every node, plus the topology's bootnode port) is checked
#            with a REAL bind() attempt, not just a passive listening-socket
#            scan -- this sandbox's ephemeral port range (32768-60999, see
#            /proc/sys/net/ipv4/ip_local_port_range) overlaps the
#            framework's 34000+ band, so a long-lived process (postgres,
#            a dev server, ...) can transiently hold one of our ports as
#            its own OUTBOUND connection's ephemeral port; `ss -ltn` /
#            `lsof` won't show that as a listener, but bind() still fails.
#            Verified during T1.3's integration test: a fresh oldxdc join
#            crashed twice with "address already in use" on ports `ss`
#            reported as completely free. Because that borrow is
#            split-second, a single bind() sample can itself land in the
#            same transient window and misreport a genuinely-free port as
#            busy (seen live during T2.4/T2.5 acceptance: port 34104 read
#            busy once, free on every immediate retry) -- so the port
#            check is debounced (_port_free_debounced: a few retries with
#            a short backoff before declaring FAIL), which still catches
#            a REAL listener (busy on every attempt) but rides out a
#            one-sample ephemeral-port collision.
#
# Uses lib-rpc.sh directly (topology-independent -- see T0.1) rather than
# lab/lib-lab.sh, so this has no dependency on the fixed lab/ port registry.

_NETLAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_NETLAB_DIR/.." && pwd)" || exit 1
TOPO_SH="$_NETLAB_DIR/topo.sh"

# shellcheck source=../lib-rpc.sh
source "$REPO_ROOT/lib-rpc.sh"

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") wait-rpc    <url> [timeout_s=60]
       $(basename "$0") wait-peers  <url> <minPeers> [timeout_s=60]
       $(basename "$0") wait-block  <url> <N> [timeout_s=120]
       $(basename "$0") preflight   <topology.json> [--min-disk-gb N] [--min-ram-gb N]
EOF
  exit 1
}

[ $# -ge 1 ] || usage
CMD="$1"; shift

# ---------------------------------------------------------------------------
# wait-rpc
# ---------------------------------------------------------------------------
cmd_wait_rpc() {
  [ $# -ge 1 ] || usage
  local url="$1" timeout="${2:-60}" waited=0
  while :; do
    if lab_rpc_call "$url" eth_blockNumber "[]" >/dev/null 2>&1; then
      echo "OK: rpc up at $url (waited ${waited}s)"
      return 0
    fi
    [ "$waited" -ge "$timeout" ] && { echo "TIMEOUT: rpc never came up at $url after ${timeout}s" >&2; return 1; }
    sleep 2; waited=$((waited + 2))
  done
}

# ---------------------------------------------------------------------------
# wait-peers
# ---------------------------------------------------------------------------
cmd_wait_peers() {
  [ $# -ge 2 ] || usage
  local url="$1" min="$2" timeout="${3:-60}" waited=0 n
  while :; do
    n=$(lab_rpc_call "$url" admin_peers "[]" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    d = None
print(len(d) if isinstance(d, list) else 0)
" 2>/dev/null)
    [ -n "$n" ] || n=0
    if [ "$n" -ge "$min" ] 2>/dev/null; then
      echo "OK: $url has $n peer(s) (>= $min, waited ${waited}s)"
      return 0
    fi
    [ "$waited" -ge "$timeout" ] && { echo "TIMEOUT: $url only has $n peer(s) (< $min) after ${timeout}s" >&2; return 1; }
    sleep 2; waited=$((waited + 2))
  done
}

# ---------------------------------------------------------------------------
# wait-block (thin CLI wrapper around lib-rpc.sh's lab_wait_block)
# ---------------------------------------------------------------------------
cmd_wait_block() {
  [ $# -ge 2 ] || usage
  local url="$1" target="$2" timeout="${3:-120}"
  if lab_wait_block "$url" "$target" "$timeout"; then
    echo "OK: $url reached block >= $target"
    return 0
  else
    echo "TIMEOUT: $url did not reach block >= $target after ${timeout}s (at $(lab_block_number "$url" 2>/dev/null || echo '?'))" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
_port_free() {
  # $1: bare port number. Real bind() test (0.0.0.0), not a passive scan --
  # see the file header for why that matters on this sandbox.
  python3 -c "
import socket
import sys

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(('0.0.0.0', int(sys.argv[1])))
    ok = True
except OSError:
    ok = False
s.close()
sys.exit(0 if ok else 1)
" "$1"
}

# _port_free_debounced <port>: the file header already documents that this
# sandbox's ephemeral port range (32768-60999) overlaps our 34000+ band, so
# an unrelated process's OUTBOUND connection can transiently borrow one of
# our ports for a few hundred ms -- a single bind() sample can catch that
# split-second window and misreport a port that is not actually reserved
# by anything as "in use". A GENUINELY held port (another listener bound
# to it) fails every attempt; a transient ephemeral borrow clears within
# a couple of retries. So retry a few times with a short backoff and only
# report busy if every attempt failed.
_port_free_debounced() {
  local port="$1" tries="${2:-3}" delay="${3:-0.2}" i
  for ((i = 0; i < tries; i++)); do
    _port_free "$port" && return 0
    sleep "$delay"
  done
  return 1
}

cmd_preflight() {
  [ $# -ge 1 ] || usage
  local topo_file="$1"; shift
  local min_disk_gb=5 min_ram_gb=2
  while [ $# -gt 0 ]; do
    case "$1" in
      --min-disk-gb) min_disk_gb=$2; shift 2;;
      --min-ram-gb)  min_ram_gb=$2; shift 2;;
      *) echo "health.sh preflight: unknown flag: $1" >&2; return 1;;
    esac
  done
  [ -f "$topo_file" ] || { echo "health.sh: no such topology file: $topo_file" >&2; return 1; }

  local fail=0

  # -- disk --
  local avail_kb avail_gb
  avail_kb=$(df -Pk "$REPO_ROOT" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$avail_kb" ]; then
    avail_gb=$((avail_kb / 1024 / 1024))
    if [ "$avail_gb" -ge "$min_disk_gb" ]; then
      echo "PASS: disk: ${avail_gb}GB free on $(df -P "$REPO_ROOT" | awk 'NR==2{print $NF}') (>= ${min_disk_gb}GB)"
    else
      echo "FAIL: disk: only ${avail_gb}GB free (need >= ${min_disk_gb}GB)" >&2
      fail=1
    fi
  else
    echo "FAIL: disk: could not read free space for $REPO_ROOT" >&2
    fail=1
  fi

  # -- ram --
  local avail_mem_kb avail_mem_gb
  avail_mem_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
  if [ -n "$avail_mem_kb" ]; then
    avail_mem_gb=$((avail_mem_kb / 1024 / 1024))
    if [ "$avail_mem_gb" -ge "$min_ram_gb" ]; then
      echo "PASS: ram: ${avail_mem_gb}GB available (>= ${min_ram_gb}GB)"
    else
      echo "FAIL: ram: only ${avail_mem_gb}GB available (need >= ${min_ram_gb}GB)" >&2
      fail=1
    fi
  else
    echo "FAIL: ram: could not read /proc/meminfo MemAvailable" >&2
    fail=1
  fi

  # -- ports (resolve the topology first) --
  local out
  out="$("$TOPO_SH" print "$topo_file")"
  if [ $? -ne 0 ]; then
    echo "FAIL: topology did not validate/resolve -- see errors above" >&2
    return 1
  fi
  local bootnode_port
  bootnode_port=$(printf '%s\n' "$out" | sed -n 's/^# bootnode_port=//p')
  local ports
  ports=$(printf '%s\n' "$out" | python3 -c "
import sys

header = None
ports = set()
for line in sys.stdin:
    line = line.rstrip('\n')
    if line.startswith('#') or not line:
        continue
    if header is None:
        header = line.split('\t')
        continue
    row = dict(zip(header, line.split('\t')))
    for col in ('p2p', 'rpc', 'ws', 'authrpc', 'torrent', 'mcp'):
        v = row.get(col, '')
        if v:
            ports.add(int(v))
    priv = row.get('privapi', '')
    if ':' in priv:
        ports.add(int(priv.rsplit(':', 1)[1]))
print(' '.join(str(p) for p in sorted(ports)))
")
  [ -n "$bootnode_port" ] && ports="$ports $bootnode_port"

  # Re-scan only the still-busy ports across several passes: an unrelated
  # process's ephemeral-port borrow (see header) can hold a given port of
  # ours for a few seconds at a time (an established connection, not just
  # a one-sample blip -- confirmed live during T2.4/T2.5 acceptance: port
  # 34100 read busy on 20 consecutive single-shot samples ~200ms apart,
  # then cleared), so a handful of quick per-port retries (_port_free_debounced)
  # isn't always enough on its own. Re-running the FULL scan (not
  # per-port-sequential debouncing, which multiplies cost across every
  # port) over up to $port_retry_seconds bounds the worst case while still
  # riding out a multi-second borrow. A port held by a REAL listener stays
  # busy across every pass and correctly still fails at the end.
  local port_retry_seconds="${NETLAB_PREFLIGHT_PORT_RETRY_SECONDS:-20}"
  local pass_sleep=2
  local busy="" p elapsed=0
  for p in $ports; do busy="$busy $p"; done
  while :; do
    local still_busy=""
    for p in $busy; do
      _port_free_debounced "$p" || still_busy="$still_busy $p"
    done
    busy="$still_busy"
    [ -z "$busy" ] && break
    [ "$elapsed" -ge "$port_retry_seconds" ] && break
    sleep "$pass_sleep"
    elapsed=$((elapsed + pass_sleep))
  done
  if [ -z "$busy" ]; then
    echo "PASS: ports: all $(echo "$ports" | wc -w) resolved ports are free"
  else
    echo "FAIL: ports: already in use (bind test):$busy" >&2
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    echo "PREFLIGHT OK"
    return 0
  else
    echo "PREFLIGHT FAILED" >&2
    return 1
  fi
}

case "$CMD" in
  wait-rpc)   cmd_wait_rpc "$@" ;;
  wait-peers) cmd_wait_peers "$@" ;;
  wait-block) cmd_wait_block "$@" ;;
  preflight)  cmd_preflight "$@" ;;
  *) usage ;;
esac
