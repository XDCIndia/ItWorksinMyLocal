#!/bin/bash
# Regenerate genesis/genesis.json using the bundled (bug-fixed) puppeth binary.
#
# The genesis-answers.txt file is the exact, non-interactive puppeth input:
#   line 1        network name
#   masternodes   the "signers" block (bare 40-char hex, no 0x/xdc prefix)
#   blank line    ends each address list; also selects a numeric default
#   last lines    2 / 2 / (blank) -> Manage existing -> Export -> default filename
# Edit genesis-answers.txt to change masternodes / chainId, then run this.
#
# Requires bin/puppeth built from the fixed cmd/puppeth/wizard_genesis.go
# (store storage words verbatim instead of RLP-decoding them, which used to
# truncate masternode addresses and stall the chain at the first epoch).

WORK_DIR=$PWD
PUPPETH="$WORK_DIR/bin/puppeth"
ANSWERS="$WORK_DIR/genesis-answers.txt"

NET=$(head -1 "$ANSWERS" | tr -d '[:space:]')
echo "Generating genesis for network '$NET' ..."
rm -rf "$HOME/.puppeth/$NET" "$NET.json"

"$PUPPETH" < "$ANSWERS" >/tmp/gen-genesis.log 2>&1
# puppeth exits non-zero on stdin EOF after the export; the export file is what matters.

if [ -f "$NET.json" ]; then
  cp "$NET.json" genesis/genesis.json
  echo "OK: genesis/genesis.json regenerated (also kept $NET.json)"
  echo "Reset node data before restarting:  rm -rf ./nodes/*/XDC ./nodes/*/XDCx ./nodes/*/keystore"
else
  echo "FAILED: $NET.json was not produced. See /tmp/gen-genesis.log" >&2
  exit 1
fi
