#!/bin/bash
# Wipe all node data so the next ./run.sh re-imports keys and re-inits on the
# current genesis. Run this after regenerating genesis or changing .env keys.
for i in 1 2 3 4; do
  rm -rf "./nodes/$i/XDC" "./nodes/$i/XDCx" "./nodes/$i/keystore"
done
echo "Node data wiped. Run ./run.sh to start fresh."
