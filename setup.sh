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
#   ./setup.sh --build            # clone XDPoSChain/go-ethereum and build from
#                                  # source instead of downloading prebuilt
#                                  # binaries (same as BIN_SOURCE=build). The
#                                  # default (no --build) downloads a prebuilt
#                                  # binary for every client, including oldxdc.
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
    --build) export BIN_SOURCE=build; shift;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "usage: ./setup.sh [--new [N]] [--chainid N] [--client oldxdc|geth] [--build]" >&2; exit 1;;
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

[ "$NEW" = 1 ] && bash ./gen-address.sh "$N" --env --roles --chainid "$CHAINID"
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

# Seed the genesis with the role accounts gen-address.sh --roles just generated
# (owner, foundation, its confirmers, team confirmers, swap, prefund) instead of
# gen-genesis.sh's built-in defaults. Those defaults are the public XDC
# addresses nobody here holds keys for, which is what left them as
# privateKey: null in the accounts JSON. Reading the addresses back out of that
# JSON keeps it the single source of truth -- no second derivation to drift.
#
# Absent or key-less (an .env from before --roles, or a hand-written one), ROLE_ARGS
# stays empty and gen-genesis.sh falls back to its defaults exactly as before.
ROLE_ARGS=()
_acct_json="accounts/accounts-${CHAINID}.json"
if [ -f "$_acct_json" ]; then
  while IFS= read -r _flag_val; do
    [ -n "$_flag_val" ] && ROLE_ARGS+=("$_flag_val")
  done < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
by = {}
for a in d.get("accounts", []):
    if not a.get("privateKey"):
        continue
    for r in a.get("roles", []):
        by.setdefault(r, []).append(a["address"][2:])
for role, flag in (("owner", "--owner"), ("foundation", "--foundation"),
                   ("foundationOwner", "--foundation-owners"),
                   ("teamOwner", "--team-owners"), ("swap", "--swap"),
                   ("prefund", "--prefund")):
    if by.get(role):
        print(flag); print(",".join(by[role]))
' "$_acct_json" 2>/dev/null)
fi
[ ${#ROLE_ARGS[@]} -gt 0 ] && echo "Seeding genesis with generated role accounts (${#ROLE_ARGS[@]} args from $_acct_json)"

# NOTE: --skip-v1-validation is deliberately NOT passed. It used to be set here
# "because the mixed topology needs it", but it was the direct cause of node 5
# freezing a few blocks in:
#
#   WARN invalid difficulty number=8 have=1 want=4 creator=0x74C5...
#   ERROR ########## BAD BLOCK #########  Error: invalid difficulty
#
# SkipV1Validation exists ONLY in legacy XDPoSChain -- `grep -r SkipV1Validation`
# over the modern go-ethereum XDC fork (v1.17.4-xdc.7) finds nothing at all. So
# setting it made the two clients disagree on the header itself: legacy honours
# it and seals difficulty=1 (engine_v1/engine.go calcDifficulty returns
# big.NewInt(1) under the flag), while modern geth has never heard of the field
# and computes difficulty from the masternode count (=4), then rejects every
# block the sealers produce. Peering and the genesis hash were fine; every
# block simply failed verification.
#
# The gas mismatch it was originally added for is fixed upstream. That symptom
# (+3600 gas/tx on the blocksigner 0x...89 calls) came from the modern client
# INJECTING fork blocks our genesis never declares -- istanbul/berlin/london=0,
# whose EIP-1884/2200/2929 repricing mispriced BlockSigners.sign(). The fork now
# derives a ceiling from the highest fork the genesis actually declares and
# refuses to inherit above it (see core/genesis.go
# forkPatchGenesisAuthoritative, "mispriced ... by +3600 gas per tx"). Our
# genesis declares nothing past byzantiumBlock, which is exactly that case.
#
# Verified with the flag off: 0 "invalid difficulty", 0 "invalid gas used",
# node 5 tracking the sealers block-for-block and agreeing on the block hash.
# Do not re-add it while node 5 is a modern-geth client.
bash ./gen-genesis.sh --chainid "$CHAINID" --signers "$SIGNERS" "${ROLE_ARGS[@]}"
bash ./reset.sh
bash ./run.sh --mixed --chainid "$CHAINID"
