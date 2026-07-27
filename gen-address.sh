#!/bin/bash
# gen-address.sh - generate fresh XDC keypairs (random private key + address).
#
# Produces, for N accounts: the raw private key and its address, plus
# copy-paste blocks for .env (PRIVATE_KEY_n=...) and for gen-genesis.sh
# (--signers a,b,c). Uses the bundled bin/XDC to derive addresses, so it
# matches exactly what run.sh imports.
#
# Every run also writes the generated keypairs to a per-network JSON file,
# accounts/accounts-<chainid>.json, mapping each account to its address and
# private key (keyed by the chain/network id, so different networks keep
# separate account files). Override the id with --chainid, the path with
# --out. This file holds private keys -- accounts/ is gitignored.
#
# Usage:
#   ./gen-address.sh                   # 4 keypairs (default, matches the 4-node setup)
#   ./gen-address.sh 1                 # a single keypair
#   ./gen-address.sh 4 --env           # also overwrite ./.env with the generated keys
#   ./gen-address.sh 4 --chainid 12345   # tag the accounts JSON with chain id 12345
#   ./gen-address.sh 4 --out keys.json     # write the accounts JSON to a custom path

COUNT=4
WRITE_ENV=0
CHAINID=20118
ACCOUNTS_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --env) WRITE_ENV=1; shift;;
    --chainid) CHAINID=$2; shift 2;;
    --out) ACCOUNTS_OUT=$2; shift 2;;
    [0-9]*) COUNT=$1; shift;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[ -n "$ACCOUNTS_OUT" ] || ACCOUNTS_OUT="accounts/accounts-${CHAINID}.json"

cd "$(dirname "$0")" || exit 1
source ./lib.sh
ensure_bins
XDC="$XDC_BIN"
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

TMP=$(mktemp -d); PW="$TMP/pw"; : > "$PW"
trap 'rm -rf "$TMP"' EXIT

privs=(); addrs=()
for i in $(seq 1 "$COUNT"); do
  p=$(openssl rand -hex 32)
  a=$("$XDC" account import --password "$PW" --datadir "$TMP/k$i" <(printf '%s' "$p") 2>/dev/null \
        | grep -oE 'xdc[0-9a-fA-F]{40}' | head -1 | sed 's/^xdc//')
  privs+=("$p"); addrs+=("$a")
  printf 'Key %d\n  private : %s\n  address : 0x%s\n  xdc     : xdc%s\n\n' "$i" "$p" "$a" "$a"
done

echo "# ---- paste into .env ----"
for i in $(seq 1 "$COUNT"); do echo "PRIVATE_KEY_$i=${privs[$((i-1))]}"; done
echo
sig=$(IFS=,; echo "${addrs[*]}")
echo "# ---- gen-genesis.sh signers ----"
echo "./gen-genesis.sh --signers $sig"

if [ "$WRITE_ENV" = "1" ]; then
  { for i in $(seq 1 "$COUNT"); do echo "PRIVATE_KEY_$i=${privs[$((i-1))]}"; done; } > .env
  echo
  echo "Wrote $COUNT keys to ./.env"
fi

# Persist the keypairs as JSON, keyed by network id: each account's address
# (0x + xdc forms) and private key. Built with python3 so values are always
# valid JSON. Holds private keys -- keep out of version control (accounts/ is
# gitignored).
mkdir -p "$(dirname "$ACCOUNTS_OUT")"
CHAINID="$CHAINID" ACCOUNTS_OUT="$ACCOUNTS_OUT" \
PRIVS="$(IFS=,; echo "${privs[*]}")" ADDRS="$(IFS=,; echo "${addrs[*]}")" \
python3 -c '
import json, os
privs = os.environ["PRIVS"].split(",")
addrs = os.environ["ADDRS"].split(",")
accounts = [
    {
        "index": i + 1,
        "address": "0x" + a,
        "xdc": "xdc" + a,
        "privateKey": p,
    }
    for i, (a, p) in enumerate(zip(addrs, privs))
]
out = {"chainId": int(os.environ["CHAINID"]), "accounts": accounts}
with open(os.environ["ACCOUNTS_OUT"], "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
'
echo "Wrote $COUNT accounts (chain id $CHAINID) to ./$ACCOUNTS_OUT"
