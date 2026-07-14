#!/bin/bash
# gen-address.sh - generate fresh XDC keypairs (random private key + address).
#
# Produces, for N accounts: the raw private key and its address, plus
# copy-paste blocks for .env (PRIVATE_KEY_n=...) and for gen-genesis.sh
# (--signers a,b,c). Uses the bundled bin/XDC to derive addresses, so it
# matches exactly what run.sh imports.
#
# Usage:
#   ./gen-address.sh            # 4 keypairs (default, matches the 4-node setup)
#   ./gen-address.sh 1          # a single keypair
#   ./gen-address.sh 4 --env    # also overwrite ./.env with the generated keys

COUNT=4
WRITE_ENV=0
for a in "$@"; do
  case "$a" in
    --env) WRITE_ENV=1;;
    [0-9]*) COUNT=$a;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $a" >&2; exit 1;;
  esac
done

cd "$(dirname "$0")"
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
