#!/bin/bash
# net5151 uniform LEGACY (XDPoSChain v2.7.0-devnet) validator bring-up on fresh genesis 0x51b4dfba.
# Legacy binary has NO xdcSyncer bulk-sync miner gate and ratchets gas normally.
# usage: legacy-bringup.sh <label> <datadir> <addr> <keystore_src> <pw_src> <p2pport> <httpport> <authport> <hostip>
set -uo pipefail
LABEL="$1"; DD="$2"; ADDR="$3"; KS="$4"; PW="$5"; P2P="$6"; HTTP="$7"; AUTH="$8"; HOSTIP="$9"
XDC=/root/xdc-devnet50501/bin/XDC
GEN=/root/net5151-geth/genesis-5151.json
LOG="/root/net5151-geth/${LABEL}.log"
[ -x "$XDC" ] || { echo "FATAL $LABEL: legacy binary missing: $XDC"; exit 1; }
[ -f "$KS" ] || { echo "FATAL $LABEL: keystore missing: $KS"; exit 1; }
[ -f "$PW" ] || { echo "FATAL $LABEL: password missing: $PW"; exit 1; }
rm -rf "$DD"; mkdir -p "$DD/keystore"; cp "$KS" "$DD/keystore/"; cp "$PW" "$DD/pw.txt"
GH=$("$XDC" --datadir "$DD" init "$GEN" 2>&1 | grep -oE "0x[0-9a-f]{64}" | head -1); echo "$LABEL init hash=$GH"
setsid "$XDC" --datadir "$DD" --networkid 5151 --syncmode full --gcmode archive \
  --port "$P2P" --nodiscover --maxpeers 25 --nat extip:"$HOSTIP" \
  --http --http-addr 127.0.0.1 --http-port "$HTTP" --http-api eth,net,web3,admin,debug,miner,XDPoS \
  --authrpc-port "$AUTH" \
  --mine --miner-etherbase "$ADDR" --unlock "$ADDR" --password "$DD/pw.txt" \
  --ethstats "${LABEL}:xdc_openscan_stats_2026@stats.xdcindia.com:443" \
  --verbosity 3 </dev/null >"$LOG" 2>&1 &
PID=$!
sleep 6
if kill -0 "$PID" 2>/dev/null; then echo "$LABEL LAUNCHED pid=$PID addr=$ADDR p2p=$P2P http=$HTTP"; else echo "$LABEL DIED — tail:"; tail -10 "$LOG"; fi
