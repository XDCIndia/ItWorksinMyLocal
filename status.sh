#!/bin/bash
# status.sh - Check health of local network nodes and join clients.
# Works with ItWorksinMyLocal layout: run.sh (4 local oldxdc nodes + optional geth node 5)
# and join.sh (sync clients in nodes/<client>-sync).
#
# Usage: ./status.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

rpc_call() {
  local port=$1
  local method=$2
  local params=${3:-[]}
  curl -s -m 2 -X POST "http://localhost:${port}" \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"${method}\",\"params\":${params},\"id\":1}" 2>/dev/null
}

parse_int() {
  local val=$1
  if [[ "$val" == "0x"* ]]; then
    printf '%d' "$val" 2>/dev/null || echo "0"
  else
    echo "$val"
  fi
}

check_rpc() {
  local port=$1
  local block="?" peers="?" syncing="?" chainId="?" status="DOWN"

  local resp
  resp=$(rpc_call "$port" "eth_blockNumber")
  if [ -n "$resp" ] && echo "$resp" | grep -q '"result"'; then
    block=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  fi

  resp=$(rpc_call "$port" "net_peerCount")
  if [ -n "$resp" ] && echo "$resp" | grep -q '"result"'; then
    peers=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  fi

  resp=$(rpc_call "$port" "eth_syncing")
  if [ -n "$resp" ] && echo "$resp" | grep -q '"result"'; then
    syncing=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",False); print("true" if r else "false")' 2>/dev/null || echo "?")
  fi

  resp=$(rpc_call "$port" "eth_chainId")
  if [ -n "$resp" ] && echo "$resp" | grep -q '"result"'; then
    chainId=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  fi

  if [ "$chainId" != "?" ] || [ "$block" != "?" ]; then
    status="UP"
  fi

  printf "  RPC (port %s): block=%s peers=%s syncing=%s chainId=%s status=%s\n" \
    "$port" "$block" "$peers" "$syncing" "$chainId" "$status"
}

check_node() {
  local name=$1
  local port=$2
  local datadir=$3

  echo -e "${CYAN}=== $name ===${NC}"

  # Process check
  local pattern="$datadir"
  local pids=$(pgrep -f -- "$pattern" 2>/dev/null | tr '\n' ' ')
  if [ -n "$pids" ]; then
    echo -e "  Process: ${GREEN}running${NC} (pids: $pids)"
  else
    echo -e "  Process: ${RED}not running${NC}"
  fi

  # Datadir check
  if [ -d "$datadir" ]; then
    echo "  Datadir: $datadir exists"
  else
    echo -e "  Datadir: ${YELLOW}$datadir not found${NC}"
  fi

  check_rpc "$port"
}

print_table_row() {
  printf "%-18s %6s %10s %6s %-10s %-12s %-10s\n" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

print_summary() {
  local name=$1 port=$2 block=$3 peers=$4 syncing=$5 chainId=$6 status=$7
  local block_str="$block"
  [ "$block" = "?" ] && block_str="0"
  print_table_row "$name" "$port" "$block_str" "$peers" "$syncing" "$chainId" "$status"
}

# --- Local nodes ---
echo "=== Local Network Nodes (run.sh / setup.sh) ==="
print_table_row "NAME" "PORT" "BLOCK" "PEERS" "SYNCING" "CHAINID" "STATUS"

LOCAL_BLOCKS=()
LOCAL_CHAINID=""

for i in 1 2 3 4; do
  port=$((8544 + i))
  name="local-oldxdc-$i"
  resp=$(rpc_call "$port" "eth_blockNumber")
  block=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "net_peerCount")
  peers=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "eth_syncing")
  syncing=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",False); print("true" if r else "false")' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "eth_chainId")
  chainId=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")

  [ -n "$LOCAL_CHAINID" ] || LOCAL_CHAINID="$chainId"

  status="DOWN"
  if [ "$chainId" != "?" ] || [ "$block" != "?" ]; then
    status="RUNNING"
  fi
  print_summary "$name" "$port" "$block" "$peers" "$syncing" "$chainId" "$status"
  [ "$block" != "?" ] && LOCAL_BLOCKS+=("$block")
done

# Node 5 (optional modern geth / mixed)
port=8549
name="local-node-5"
resp=$(rpc_call "$port" "eth_blockNumber")
block=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
if [ "$block" != "?" ]; then
  resp=$(rpc_call "$port" "net_peerCount")
  peers=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "eth_syncing")
  syncing=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",False); print("true" if r else "false")' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "eth_chainId")
  chainId=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  status="RUNNING"
  print_summary "$name" "$port" "$block" "$peers" "$syncing" "$chainId" "$status"
  [ "$block" != "?" ] && LOCAL_BLOCKS+=("$block")
else
  print_summary "$name" "$port" "?" "?" "?" "?" "DOWN"
fi

# --- Join clients ---
echo ""
echo "=== Join Clients (join.sh) ==="
print_table_row "NAME" "PORT" "BLOCK" "PEERS" "SYNCING" "CHAINID" "STATUS"

JOIN_BLOCKS=()

clients=(
  "oldxdc:9645"
  "geth:9745"
  "erigon:9845"
  "besu:9945"
  "nethermind:10045"
  "reth:10145"
  "xone:10245"
)

for pair in "${clients[@]}"; do
  client="${pair%%:*}"
  port="${pair##*:}"
  name="join-$client"
  datadir="nodes/${client}-sync"

  resp=$(rpc_call "$port" "eth_blockNumber")
  block=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "net_peerCount")
  peers=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "eth_syncing")
  syncing=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); r=d.get("result",False); print("true" if r else "false")' 2>/dev/null || echo "?")
  resp=$(rpc_call "$port" "eth_chainId")
  chainId=$(echo "$resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(int(d.get("result","0x0"),16))' 2>/dev/null || echo "?")

  status="DOWN"
  if [ "$chainId" != "?" ] || [ "$block" != "?" ]; then
    if [ "$chainId" != "$LOCAL_CHAINID" ] && [ "$LOCAL_CHAINID" != "?" ] && [ "$chainId" != "?" ]; then
      status="WRONG_NET"
    elif [ "$block" != "?" ] && [ "$block" -gt 0 ]; then
      status="RUNNING"
    elif [ "$syncing" = "true" ]; then
      status="SYNCING"
    else
      status="STUCK"
    fi
  fi
  print_summary "$name" "$port" "$block" "$peers" "$syncing" "$chainId" "$status"
  [ "$block" != "?" ] && [ "$status" != "WRONG_NET" ] && JOIN_BLOCKS+=("$block")
done

# --- Summary ---
echo ""
max_local=0
for b in "${LOCAL_BLOCKS[@]}"; do
  [ "$b" -gt "$max_local" ] 2>/dev/null && max_local=$b
done

max_join=0
for b in "${JOIN_BLOCKS[@]}"; do
  [ "$b" -gt "$max_join" ] 2>/dev/null && max_join=$b
done

max_tip=$(( max_local > max_join ? max_local : max_join ))
echo "=== Summary ==="
echo "  Local chainId:    $LOCAL_CHAINID"
echo "  Network tip:      $max_tip"
echo ""
echo "Legend:"
echo "  RUNNING   = At/near tip, not actively syncing"
echo "  SYNCING   = Catching up to network tip"
echo "  STUCK     = RPC up but block 0 or no peers"
echo "  DOWN      = RPC not responding"
echo "  WRONG_NET = Connected to wrong chainId"
