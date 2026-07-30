#!/bin/bash
# freeze.sh — the halt/fork terminal action: miner_stop on every arbiter, then
# STOP. This is not a recovery tool -- it is documented as terminal: freeze
# and REPORT, no recovery spiral (that has burned this program twice).
#
# Use for abort-table rows 10 (validator hash disagreement / fork) and 11
# (chain halt, no new block for > 60s). NEVER for a new-candidate-only
# problem -- use abort.sh for that; freeze.sh touches the VALIDATORS
# themselves and should be reached for only when the live net's own health is
# in question, not the candidate's.
#
# Does NOT stop any process, does NOT wipe any data, does NOT restart
# anything. It only calls the miner_stop JSON-RPC admin method against each
# arbiter -- reversible via miner_start once the operator has diagnosed and
# resolved the underlying issue.
#
# Config via env (see seat.env.sample): RPC_ARBITERS (comma-separated; every
# one of these gets miner_stop), REASON (free-text, printed for the record).
#
# Usage: freeze.sh
set -u
_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$_DIR/../.." && pwd)" || exit 1
# shellcheck source=../../lib-rpc.sh
source "$REPO_ROOT/lib-rpc.sh"

RPC_ARBITERS=${RPC_ARBITERS:?set RPC_ARBITERS (comma-separated arbiter RPC URLs)}
REASON=${REASON:-"(no reason given)"}

echo "=== freeze.sh: FREEZING the net -- REASON: $REASON ==="
echo "This is TERMINAL: freeze and REPORT to the user. Do not attempt a recovery spiral."
echo

IFS=',' read -r -a _arbiters <<< "$RPC_ARBITERS"
fail=0
for url in "${_arbiters[@]}"; do
  echo "-- miner_stop on $url --"
  if lab_rpc_call "$url" miner_stop "[]" >/dev/null 2>&1; then
    echo "PASS: miner_stop accepted by $url"
  else
    echo "FAIL: miner_stop failed or was not accepted by $url (it may already be stopped, or the admin/miner namespace may not be enabled -- check manually)"
    fail=1
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "freeze.sh: all arbiters accepted miner_stop. The net is FROZEN."
else
  echo "freeze.sh: one or more arbiters did NOT confirm miner_stop -- STOP and check manually, do not assume the freeze is complete." >&2
fi
echo "freeze.sh: DID NOT wipe any data, DID NOT restart anything, DID NOT touch the candidate. REPORT this to the user now."
exit "$fail"
