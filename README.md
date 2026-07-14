# Local XDPoS (DPoS) Network — "It Works in My Local"

A self-contained 4-node local [XDPoS](https://github.com/XinFinOrg/XDPoSChain)
delegated-proof-of-stake network. The required binaries are bundled in `bin/`,
so you don't need the XDPoSChain source tree to run it.

## What's included

```
bin/XDC          node binary (v2.7.1-stable, darwin-arm64)
bin/bootnode     discovery bootnode
bin/puppeth      genesis wizard (patched — see "The puppeth fix" below)
run.sh           build-if-needed, import keys, init, start bootnode + 4 nodes
gen-address.sh   generate fresh keypairs (private key + address)
gen-genesis.sh   generate genesis.json via puppeth using flags
reset.sh         wipe node data (for a clean re-init)
genesis/         genesis.json (chainId 20118, 4 masternodes seeded)
bootnode.key     fixed bootnode private key
.env.sample      template for the 4 masternode private keys
```

> The bundled binaries are macOS/arm64. On another platform, run
> `REBUILD=1 ./run.sh` (needs the XDPoSChain source at the path in `run.sh`).

## Quick start

```bash
# 1. generate 4 fresh masternode keys -> .env
./gen-address.sh 4 --env

# 2. build a genesis seeded with those keys (use the --signers line it prints)
./gen-genesis.sh --signers <addr1>,<addr2>,<addr3>,<addr4>

# 3. reset any old chain data
./reset.sh

# 4. launch the bootnode + 4 mining nodes
./run.sh
```

Confirm it's producing blocks (and crossing the epoch boundary at 900):

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

## Scripts

### `gen-address.sh [N] [--env]`
Generates `N` random keypairs (default 4). Prints each private key + address,
plus copy-paste blocks for `.env` and for `gen-genesis.sh --signers`.
`--env` writes the keys straight to `./.env`.

### `gen-genesis.sh [flags]`
Drives `bin/puppeth` non-interactively to produce `genesis/genesis.json`.
All flags optional (defaults match the local setup). Addresses accept
`0x` / `xdc` / bare-hex.

| Flag | Meaning (default) |
|------|-------------------|
| `--chainid N` | chain / network id (20118) |
| `--signers a,b,c` | masternode addresses |
| `--owner ADDR` | masternode owner |
| `--reward N` | block reward (5000) |
| `--v2block N` | v2 consensus switch block (2700) |
| `--epoch N` / `--gap N` | epoch length (900) / checkpoint gap (450) |
| `--foundation ADDR` / `--foundation-owners a,b` | foundation wallet / multisig |
| `--team-owners a,b` / `--swap ADDR` / `--prefund a,b` | governance / funding |
| `--network NAME` / `--out FILE` | puppeth net name / output path |

### `run.sh`
Uses `bin/`; rebuilds only if a binary is missing or `REBUILD=1`. Imports the
`.env` keys, inits each node against `genesis/genesis.json`, starts the local
bootnode, then 4 mining nodes. Each node advertises this machine's LAN IP
(`--nat extip`) and a per-host `--identity`, and connects to the local bootnode.

### `reset.sh`
Wipes `nodes/*/XDC`, `nodes/*/XDCx`, `nodes/*/keystore`. Run after changing
genesis or `.env` keys.

## Network details

- **chainId / networkid:** 20118 (must not be 50/51/551 — those force the
  built-in mainnet/testnet/devnet genesis)
- **consensus:** XDPoS, period 2s, epoch 900, gap 450, v2 switch block 2700
- **nodes / ports:**

  | node | datadir | p2p | ws | rpc |
  |------|---------|-----|----|-----|
  | 1 | nodes/1 | 30303 | 8555 | 8545 |
  | 2 | nodes/2 | 30304 | 8556 | 8546 |
  | 3 | nodes/3 | 30305 | 8557 | 8547 |
  | 4 | nodes/4 | 30306 | 8558 | 8548 |

## The puppeth fix

Stock `puppeth` in this XDPoSChain build corrupts the genesis: its storage
exporter RLP-decoded each already-decoded storage word, truncating every
masternode address in the `XDCValidator` (`0x88`) `candidates[]` array (e.g.
`0xbd29…` → `0x00`). `getCandidates()` then returned garbage and the chain
**stalled at the first epoch boundary (block 900)**. The bundled `bin/puppeth`
stores the word verbatim, so the masternodes are seeded correctly and the epoch
transition succeeds. (Fix lives in `cmd/puppeth/wizard_genesis.go`.)

## Notes

- `.env` holds **throwaway devnet private keys** — never reuse them anywhere
  real. `.env` is git-ignored.
- Nodes report to the `ethstats` endpoint configured in `run.sh`
  (`STATS_SECRET`). Change it if you don't want a shared dashboard.
