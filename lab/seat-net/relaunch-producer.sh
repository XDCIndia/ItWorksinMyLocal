#!/bin/bash
# relaunch-producer.sh — Phase 3: stop the candidate as a follower (SIGTERM,
# by port, bounded wait) and re-exec it with producing flags, family-dispatched.
#
# NEVER SIGKILLs, under any code path -- no `|| kill -9` fallback anywhere. A
# hard kill corrupts an XDPoS node's state DB and it deadlocks on next start.
#
# Finds the running candidate's pid ONLY via `ss -ltnp "sport = :$PORT"`
# (pid_by_port()) -- NEVER a `pgrep` pattern containing a datadir path, which
# can match the caller's own shell (its cwd/args may contain the same path
# string) and kill the wrong process. See README for the full rationale.
#
# PROTECTED_PORTS (env, comma-separated) is refused outright: this script
# must be structurally incapable of stopping a validator or an already-
# minting client. Populate it with every legacy validator RPC/P2P port plus
# any already-seated/minting client's ports (e.g. erigon's) before ever
# running this against a live net.
#
# Config via env (see seat.env.sample): CANDIDATE_FAMILY (geth|erigon|reth),
# CANDIDATE_P2P_PORT, CANDIDATE_RPC_PORT, CANDIDATE_COINBASE,
# PROTECTED_PORTS (comma-separated port list this script refuses to touch),
# RELAUNCH_CMD (the exact command to exec for the family; this script does
# NOT hardcode a binary path/datadir -- the operator supplies the full
# command via RELAUNCH_CMD, this script only adds the family-specific
# producing flags and manages the stop/wait/relaunch lifecycle),
# KEYSTORE_DIR (geth family only -- checked to contain CANDIDATE_COINBASE
# before relaunch), PWFILE (geth family only -- password file for --unlock),
# SIGNER_KEY_FILE (erigon/reth families -- signer key file path),
# STOP_TIMEOUT_SECS (default 30), LOG_FILE (candidate's stdout/stderr target).
#
# Usage: relaunch-producer.sh
set -u
CANDIDATE_FAMILY=${CANDIDATE_FAMILY:?set CANDIDATE_FAMILY (geth|erigon|reth)}
CANDIDATE_P2P_PORT=${CANDIDATE_P2P_PORT:?set CANDIDATE_P2P_PORT}
CANDIDATE_RPC_PORT=${CANDIDATE_RPC_PORT:?set CANDIDATE_RPC_PORT}
CANDIDATE_COINBASE=${CANDIDATE_COINBASE:?set CANDIDATE_COINBASE}
PROTECTED_PORTS=${PROTECTED_PORTS:-}
RELAUNCH_CMD=${RELAUNCH_CMD:?set RELAUNCH_CMD (the base command to exec, without producing flags)}
KEYSTORE_DIR=${KEYSTORE_DIR:-}
PWFILE=${PWFILE:-}
SIGNER_KEY_FILE=${SIGNER_KEY_FILE:-}
STOP_TIMEOUT_SECS=${STOP_TIMEOUT_SECS:-30}
LOG_FILE=${LOG_FILE:-/tmp/relaunch-producer.$$.log}

if [ "$CANDIDATE_FAMILY" = "reth" ] && [ "${I_UNDERSTAND_RETH_MUST_NOT_SEAT:-0}" != "1" ]; then
  echo "FAIL: CANDIDATE_FAMILY=reth is a MUST-NOT-SEAT family (docs/client-readiness.md: #237/#243/#223)." >&2
  echo "      Set I_UNDERSTAND_RETH_MUST_NOT_SEAT=1 only if you are re-running this for diagnostic purposes." >&2
  exit 1
fi

is_protected_port() {
  local port="$1" p
  IFS=',' read -r -a _protected <<< "$PROTECTED_PORTS"
  for p in "${_protected[@]}"; do
    [ "$p" = "$port" ] && return 0
  done
  return 1
}

if is_protected_port "$CANDIDATE_P2P_PORT" || is_protected_port "$CANDIDATE_RPC_PORT"; then
  echo "REFUSING: CANDIDATE_P2P_PORT=$CANDIDATE_P2P_PORT or CANDIDATE_RPC_PORT=$CANDIDATE_RPC_PORT is in PROTECTED_PORTS ($PROTECTED_PORTS)." >&2
  echo "          This script is structurally incapable of relaunching a protected node -- fix your config, do not bypass this." >&2
  exit 1
fi

# pid_by_port <port>: the ONLY sanctioned way this toolset locates a pid.
# NEVER use `pgrep -f <datadir>` -- a datadir path can appear in the
# caller's own shell args/cwd and match the wrong process.
pid_by_port() {
  local port="$1"
  ss -ltnp "sport = :$port" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1
}

echo "=== relaunch-producer.sh: family=$CANDIDATE_FAMILY coinbase=$CANDIDATE_COINBASE ==="

pid=$(pid_by_port "$CANDIDATE_RPC_PORT")
if [ -z "$pid" ]; then
  echo "FAIL: no listening process on RPC port $CANDIDATE_RPC_PORT (ss -ltnp) -- is the candidate running?" >&2
  exit 1
fi
echo "found candidate pid=$pid via port $CANDIDATE_RPC_PORT"

echo "SIGTERM pid=$pid ..."
kill -TERM "$pid" 2>/dev/null
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge "$STOP_TIMEOUT_SECS" ]; then
    echo "FAIL: pid=$pid still alive after ${STOP_TIMEOUT_SECS}s. NOT sending SIGKILL (would corrupt the state DB)." >&2
    echo "      Wait longer and re-run, or investigate manually. This script has NO force-kill path." >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
echo "candidate stopped cleanly after ${waited}s"

echo "=== relaunching as producer ==="
case "$CANDIDATE_FAMILY" in
  geth)
    # covers go-ethereum AND the xone ethcompat build.
    [ -n "$KEYSTORE_DIR" ] || { echo "FAIL: set KEYSTORE_DIR for geth family" >&2; exit 1; }
    [ -n "$PWFILE" ] || { echo "FAIL: set PWFILE for geth family" >&2; exit 1; }
    if ! grep -qi "${CANDIDATE_COINBASE#0x}" "$KEYSTORE_DIR"/* 2>/dev/null; then
      echo "FAIL: $CANDIDATE_COINBASE not found in any keystore file under $KEYSTORE_DIR -- import it first" >&2
      exit 1
    fi
    echo "keystore check OK: $CANDIDATE_COINBASE present under $KEYSTORE_DIR"
    FULL_CMD="$RELAUNCH_CMD --mine --miner.etherbase $CANDIDATE_COINBASE --unlock $CANDIDATE_COINBASE --password $PWFILE"
    ;;
  erigon)
    [ -n "$SIGNER_KEY_FILE" ] || { echo "FAIL: set SIGNER_KEY_FILE for erigon family" >&2; exit 1; }
    echo "REFERENCE ONLY per the seating protocol: erigon is already seated and minting on netv12 -- this path is documented for completeness, not for use against the live net." >&2
    FULL_CMD="$RELAUNCH_CMD --xdc.v1.produce --xdc.v2.produce --xdc.v1.signerkey $SIGNER_KEY_FILE"
    ;;
  reth)
    [ -n "$SIGNER_KEY_FILE" ] || { echo "FAIL: set SIGNER_KEY_FILE for reth family" >&2; exit 1; }
    echo "REFERENCE ONLY per the seating protocol: reth MUST NOT BE SEATED (issues #237/#243/#223)." >&2
    FULL_CMD="XDC_PRODUCE=1 XDC_SIGNER_KEY_FILE=$SIGNER_KEY_FILE $RELAUNCH_CMD"
    ;;
  *)
    echo "FAIL: unknown CANDIDATE_FAMILY=$CANDIDATE_FAMILY (geth|erigon|reth)" >&2
    exit 1
    ;;
esac

echo "exec: $FULL_CMD  (log: $LOG_FILE)"
nohup bash -c "$FULL_CMD" > "$LOG_FILE" 2>&1 &
new_pid=$!
sleep 3
if ! kill -0 "$new_pid" 2>/dev/null; then
  echo "FAIL: relaunched process (pid=$new_pid) died within 3s -- check $LOG_FILE" >&2
  exit 1
fi
echo "relaunched: pid=$new_pid"

listening_pid=$(pid_by_port "$CANDIDATE_RPC_PORT")
if [ "$listening_pid" != "$new_pid" ] && [ -z "$listening_pid" ]; then
  echo "WARNING: no listener yet on RPC port $CANDIDATE_RPC_PORT -- node may still be initializing; check $LOG_FILE" >&2
fi

echo "relaunch-producer: DONE. Verify before C arrives: signer/etherbase reported correctly, tip lag 0, >=5 peers."
echo "  e.g.: tail -50 $LOG_FILE"
