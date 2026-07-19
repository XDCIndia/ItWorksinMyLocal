#!/bin/bash
# Generate genesis/genesis.json via the bundled (bug-fixed) puppeth using flags.
#
# Puppeth has no genesis flags of its own (only --network); this wrapper feeds
# its interactive wizard from the flags below. Addresses may be given with or
# without a 0x / xdc prefix; lists are comma-separated. All flags are optional
# and default to the current local 4-masternode setup.
#
# Usage:
#   ./gen-genesis.sh
#   ./gen-genesis.sh --chainid 12345 --signers 0xAAAA...,0xBBBB... --owner 0xCCCC...
#
# Flags:
#   --network NAME            puppeth network name (default localdpos)
#   --chainid N               chain / network id (default 20118)
#   --owner ADDR              owner of the masternodes
#   --signers a,b,c           masternode/sealer addresses (>=1)
#   --reward N                block reward (default 5000)
#   --v2block N               v2 consensus switch block (default 2700)
#   --epoch N                 blocks per epoch (default 900)
#   --gap N                   blocks before checkpoint (default 450)
#   --foundation ADDR         foundation wallet
#   --foundation-owners a,b   foundation multisig confirmers
#   --team-owners a,b         team multisig confirmers
#   --swap ADDR               swap wallet (55m fund)
#   --prefund a,b             pre-funded accounts
#   --out FILE                output path (default genesis/genesis.json)

NETWORK=localdpos
CHAINID=20118
OWNER=518075434a104652c5C469BDC04521EA638008Fb
SIGNERS=Bd29914857fBc1c3fA6EE10cc4708B89534878d5,76fBfFd7ac5D53F7A81d45c41E3036068FF8Ba36,d3d1a36F577a4673d6Eb9A96e46C02b365E29Cb3,20aDa917619f7dEA50C8f44d00E4450336543831
REWARD=5000
V2BLOCK=2700
EPOCH=900
GAP=450
FOUNDATION=65290e6eE7ecD267852832e3D1e1211Be42DF33A
FOUNDATION_OWNERS=F7dC23CF42AE8Bf1225e9D411E566eA1484554dd,5cDdE6F2bE1e5E464749104aF42753D6c8Bff42C
TEAM_OWNERS=5cDdE6F2bE1e5E464749104aF42753D6c8Bff42C,F7dC23CF42AE8Bf1225e9D411E566eA1484554dd
SWAP=b49a187961E310fBEa9071975fAe9F497fD3A938
PREFUND=29E07C0905FECcD3b4a35A0C3Ea86c48cbEa893E
OUT=genesis/genesis.json

while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK=$2; shift 2;;
    --chainid) CHAINID=$2; shift 2;;
    --owner) OWNER=$2; shift 2;;
    --signers) SIGNERS=$2; shift 2;;
    --reward) REWARD=$2; shift 2;;
    --v2block) V2BLOCK=$2; shift 2;;
    --epoch) EPOCH=$2; shift 2;;
    --gap) GAP=$2; shift 2;;
    --foundation) FOUNDATION=$2; shift 2;;
    --foundation-owners) FOUNDATION_OWNERS=$2; shift 2;;
    --team-owners) TEAM_OWNERS=$2; shift 2;;
    --swap) SWAP=$2; shift 2;;
    --prefund) PREFUND=$2; shift 2;;
    --out) OUT=$2; shift 2;;
    -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown flag: $1" >&2; exit 1;;
  esac
done

norm() { echo "$1" | sed -E 's/^0[xX]//; s/^xdc//'; }
emit_list() { local IFS=,; for a in $1; do norm "$a"; done; echo; }  # addresses + blank terminator

cd "$(dirname "$0")" || exit 1
source ./lib.sh
require_oldxdc
ensure_bins
PUPPETH="$PUPPETH_BIN"
rm -rf "$HOME/.puppeth/$NETWORK" "$NETWORK.json"

{
  echo "$NETWORK"      # network name
  echo 2               # menu: Configure new genesis
  echo 3               # consensus: XDPoS
  echo                 # block time (default 2)
  echo "$REWARD"       # masternode reward
  echo "$V2BLOCK"      # v2 switch block
  echo; echo; echo     # v2 timeout period / sync threshold / QC proportion (defaults)
  norm "$OWNER"        # masternodes owner
  emit_list "$SIGNERS" # signers + terminator
  echo "$EPOCH"        # blocks per epoch
  echo "$GAP"          # blocks before checkpoint
  norm "$FOUNDATION"   # foundation wallet
  emit_list "$FOUNDATION_OWNERS"
  echo                 # foundation required (default 2)
  emit_list "$TEAM_OWNERS"
  echo                 # team required (default 2)
  norm "$SWAP"         # swap wallet
  emit_list "$PREFUND"
  echo "$CHAINID"      # chain id
  echo 2               # menu: Manage existing genesis
  echo 2               # submenu: Export genesis configuration
  echo                 # file (default <network>.json)
} | "$PUPPETH" >/tmp/gen-genesis.log 2>&1

if [ -f "$NETWORK.json" ]; then
  mkdir -p "$(dirname "$OUT")"
  cp "$NETWORK.json" "$OUT"
  # Record the role -> address mapping so network-info.sh can label accounts.
  {
    echo "NETWORK=$NETWORK"
    echo "CHAINID=$CHAINID"
    echo "OWNER=$(norm "$OWNER")"
    echo "FOUNDATION=$(norm "$FOUNDATION")"
    echo "FOUNDATION_OWNERS=$FOUNDATION_OWNERS"
    echo "TEAM_OWNERS=$TEAM_OWNERS"
    echo "SWAP=$(norm "$SWAP")"
    echo "PREFUND=$PREFUND"
    echo "SIGNERS=$SIGNERS"
  } > network-roles.env
  echo "OK: $OUT generated (chainId $CHAINID, network '$NETWORK')"
  echo "Reset node data before restart:  rm -rf ./nodes/*/XDC ./nodes/*/XDCx ./nodes/*/keystore"
else
  echo "FAILED: $NETWORK.json not produced. See /tmp/gen-genesis.log" >&2
  exit 1
fi
