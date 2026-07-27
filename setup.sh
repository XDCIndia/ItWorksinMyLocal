#!/bin/bash
# One-command, end-to-end bring-up:
#   (optionally generate fresh keys) -> derive signers from .env ->
#   generate genesis seeded with them -> wipe node data -> launch the network.
#
# Usage:
#   ./setup.sh                    # use the keys already in .env
#   ./setup.sh --new              # generate 4 fresh keys into .env first
#   ./setup.sh --new 4            # generate N fresh keys into .env first
#   ./setup.sh --chainid 12345  # use a custom chain/network id
#   ./setup.sh --client geth      # build-only: the modern go-ethereum client
#
# Default (no --client, i.e. CLIENT=oldxdc): builds the 4 legacy oldxdc
# sealers AND the modern go-ethereum client, generates genesis, wipes node
# data, then launches the MIXED topology (4 legacy validators + node 5,
# modern geth, sync-only, from genesis -- see run.sh --mixed).
#
# --client geth (passed explicitly) is build-only, as before: it builds the
# modern go-ethereum fork and exits without launching a network.
#
# The signer set is derived dynamically from .env, so genesis, the imported
# accounts, and the miners always match -- no hardcoded addresses.

set -e
cd "$(dirname "$0")"

NEW=0; N=4; CLIENT_EXPLICIT=0; CHAINID=20118
while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW=1; shift; case "$1" in [0-9]*) N=$1; shift;; esac;;
    --client) export CLIENT=$2; CLIENT_EXPLICIT=1; shift 2;;
    --chainid) CHAINID=$2; shift 2;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "usage: ./setup.sh [--new [N]] [--chainid N] [--client oldxdc|geth]" >&2; exit 1;;
  esac
done

# Validate before anything expensive runs: this id is fed to puppeth's chain-id
# prompt, tags the accounts JSON, and becomes the nodes' network id. A junk value
# propagates into all three and only shows up as a broken network at the end.
case "$CHAINID" in
  ''|*[!0-9]*) echo "setup.sh: --chainid must be a positive integer (got '$CHAINID')" >&2; exit 1;;
esac

source ./lib.sh
ensure_bins
XDC="$XDC_BIN"

if [ "$CLIENT_EXPLICIT" = 1 ] && [ "$CLIENT" != oldxdc ]; then
  echo "Built the '$CLIENT' client: $NODE_BIN"
  echo "Launching a local network with '$CLIENT' isn't wired yet — use the"
  echo "default (oldxdc) to run one:  ./setup.sh --new"
  exit 0
fi

# Default (oldxdc) flow ends in the mixed topology, so node 5 needs a modern
# geth binary too. Build it in a subshell so its CLIENT=geth doesn't clobber
# the oldxdc-scoped vars (XDC_BIN, BIN_DIR, ...) this script uses below.
echo "Building the modern geth client (for node 5 in the mixed topology) ..."
( CLIENT=geth; source ./lib.sh; ensure_bins ) || { echo "setup.sh: modern geth build failed" >&2; exit 1; }

[ "$NEW" = 1 ] && bash ./gen-address.sh "$N" --env --chainid "$CHAINID"
[ -f .env ] || { echo ".env not found -- run: ./setup.sh --new" >&2; exit 1; }

# Derive signer addresses from the .env private keys (dynamic).
# shellcheck disable=SC2163  # intentional: $_kv holds a "NAME=VALUE" pair from .env, not a var name
while IFS= read -r _kv; do export "$_kv"; done < <(grep -E '^PRIVATE_KEY_[0-9]+=' .env)
TMP=$(mktemp -d); : > "$TMP/pw"; trap 'rm -rf "$TMP"' EXIT
SIGNERS=""; i=1
while :; do
  var="PRIVATE_KEY_$i"; pk="${!var}"
  [ -z "$pk" ] && break
  a=$("$XDC" account import --password "$TMP/pw" --datadir "$TMP/k$i" <(printf '%s' "$pk") 2>/dev/null \
        | grep -oE 'xdc[0-9a-fA-F]{40}' | head -1 | sed 's/^xdc//')
  SIGNERS="${SIGNERS:+$SIGNERS,}$a"
  i=$((i+1))
done
[ -n "$SIGNERS" ] || { echo "no PRIVATE_KEY_* found in .env" >&2; exit 1; }
echo "Signers from .env: $SIGNERS"

# --skip-v1-validation true: the mixed topology's node 5 (modern geth) needs
# this -- without it, the 4 legacy sealers' per-block v1 double-validation
# "blocksigner" system transactions (0x...89) desync it a few blocks after
# genesis (a gas-accounting mismatch between the modern go-ethereum XDC fork
# and legacy oldxdc on those specific transactions; see gen-genesis.sh's
# --skip-v1-validation doc). Doesn't affect the genesis hash.
bash ./gen-genesis.sh --chainid "$CHAINID" --signers "$SIGNERS" --skip-v1-validation true
bash ./reset.sh
bash ./run.sh --mixed --chainid "$CHAINID"
