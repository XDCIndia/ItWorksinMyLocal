#!/bin/bash
# abort.sh — SIGTERM the NEW candidate client ONLY, found by port, so its
# slot frees and heals by penalty at the next checkpoint. NEVER touches the
# legacy validators or an already-minting client (erigon).
#
# This is the abort action referenced by rows 4/5/6/7/8/9 of the abort
# decision table (README.md / docs) -- symptoms where the new client is
# diagnosed as the problem (stranded, forking, rejected, degrading block
# time, penalized). It is NEVER the right action for rows 10/11 (validator
# disagreement / chain halt) -- use freeze.sh for those.
#
# Config via env (see seat.env.sample): CANDIDATE_RPC_PORT (the port to find
# the candidate's pid by), PROTECTED_PORTS (comma-separated; refuses to touch
# any of these even if CANDIDATE_RPC_PORT is accidentally set to one of them),
# STOP_TIMEOUT_SECS (default 30), REASON (free-text, printed for the record).
#
# Usage: abort.sh
set -u
CANDIDATE_RPC_PORT=${CANDIDATE_RPC_PORT:?set CANDIDATE_RPC_PORT}
PROTECTED_PORTS=${PROTECTED_PORTS:-}
STOP_TIMEOUT_SECS=${STOP_TIMEOUT_SECS:-30}
REASON=${REASON:-"(no reason given)"}

is_protected_port() {
  local port="$1" p
  IFS=',' read -r -a _protected <<< "$PROTECTED_PORTS"
  for p in "${_protected[@]}"; do
    [ "$p" = "$port" ] && return 0
  done
  return 1
}

pid_by_port() {
  local port="$1"
  ss -ltnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1
}

echo "=== abort.sh: REASON: $REASON ==="

if is_protected_port "$CANDIDATE_RPC_PORT"; then
  echo "REFUSING: CANDIDATE_RPC_PORT=$CANDIDATE_RPC_PORT is in PROTECTED_PORTS ($PROTECTED_PORTS)." >&2
  echo "          abort.sh is structurally incapable of stopping a protected node." >&2
  exit 1
fi

pid=$(pid_by_port "$CANDIDATE_RPC_PORT")
if [ -z "$pid" ]; then
  echo "nothing listening on port $CANDIDATE_RPC_PORT -- candidate already stopped, or wrong port"
  exit 0
fi

echo "SIGTERM pid=$pid (found via port $CANDIDATE_RPC_PORT)"
kill -TERM "$pid" 2>/dev/null
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge "$STOP_TIMEOUT_SECS" ]; then
    echo "WARNING: pid=$pid still alive after ${STOP_TIMEOUT_SECS}s. NOT sending SIGKILL -- it would corrupt the state DB." >&2
    echo "         Keep waiting and check manually; this script has NO force-kill path." >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done

echo "abort.sh: DID -- SIGTERM'd the new candidate (pid=$pid, port=$CANDIDATE_RPC_PORT), stopped cleanly after ${waited}s."
echo "abort.sh: DID NOT touch -- any legacy validator, any already-seated/minting client (e.g. erigon), or netv12 itself."
echo "Next: let the set heal by penalty at the next checkpoint. Do not re-seat until the cause is fixed and re-proven in Phase 0."
