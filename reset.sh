#!/bin/bash
# Wipe all node data so the next ./run.sh re-imports keys and re-inits on the
# current genesis. Run this after regenerating genesis or changing .env keys.
for i in 1 2 3 4; do
  rm -rf "./nodes/$i/XDC" "./nodes/$i/XDCx" "./nodes/$i/keystore"
done
# Node 5 (--mixed only): modern geth, no keys of its own -- just re-init on
# the current genesis.
rm -rf "./nodes/5/XDC"
echo "Node data wiped. Run ./run.sh to start fresh."
