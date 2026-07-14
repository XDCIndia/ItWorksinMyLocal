#!/bin/bash
# One-command, end-to-end bring-up:
#   (optionally generate fresh keys) -> derive signers from .env ->
#   generate genesis seeded with them -> wipe node data -> launch the network.
#
# Usage:
#   ./setup.sh            # use the keys already in .env
#   ./setup.sh --new      # generate 4 fresh keys into .env first
#   ./setup.sh --new 4    # generate N fresh keys into .env first
#
# The signer set is derived dynamically from .env, so genesis, the imported
# accounts, and the miners always match -- no hardcoded addresses.

set -e
WORK_DIR=$PWD
XDC="$WORK_DIR/bin/XDC"

NEW=0; N=4
while [ $# -gt 0 ]; do
  case "$1" in
    --new) NEW=1; shift; case "$1" in [0-9]*) N=$1; shift;; esac;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "usage: ./setup.sh [--new [N]]" >&2; exit 1;;
  esac
done

[ "$NEW" = 1 ] && bash ./gen-address.sh "$N" --env
[ -f .env ] || { echo ".env not found -- run: ./setup.sh --new" >&2; exit 1; }

# Derive signer addresses from the .env private keys (dynamic).
export $(grep -E '^PRIVATE_KEY_[0-9]+=' .env | xargs)
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

bash ./gen-genesis.sh --signers "$SIGNERS"
bash ./reset.sh
bash ./run.sh
