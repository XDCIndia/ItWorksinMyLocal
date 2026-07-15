# Local XDPoS (DPoS) Network — "It Works in My Local"

A self-contained **4-node local [XDPoS](https://github.com/XinFinOrg/XDPoSChain)**
delegated-proof-of-stake network you can spin up in seconds — generate keys,
build a genesis, run 4 mining nodes + a bootnode, and let other machines join.

> **Non-technical?** Start with **[SETUP.md](SETUP.md)** (plain-language guide).
> **Want a script cheat-sheet?** See **[SCRIPTS.md](SCRIPTS.md)**.

## Contents
- [Requirements](#requirements)
- [Choosing a client](#choosing-a-client)
- [Quick start](#quick-start)
- [Everyday commands](#everyday-commands)
- [Generating a genesis](#generating-a-genesis)
- [Joining from another machine](#joining-from-another-machine)
- [What's in this repo](#whats-in-this-repo)
- [Network details](#network-details)
- [Troubleshooting](#troubleshooting)
- [The puppeth fix](#the-puppeth-fix)

---

## Requirements

Works on **macOS** and **Linux / Ubuntu**. Node binaries are **built from source
on first run** and cached under `bin/<client>/<os>-<arch>/` — the source repo
depends on the selected [client](#choosing-a-client) and is cloned automatically
if it isn't already beside this repo (default: the pre-fixed
[`XDCIndia/OLDXDC`](https://github.com/XDCIndia/OLDXDC)).

Install the build toolchain once:

```bash
# Linux / Ubuntu  (Go 1.23+ required — apt's 'golang' is usually too old)
sudo apt update && sudo apt install -y build-essential git
wget https://go.dev/dl/go1.23.4.linux-amd64.tar.gz
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.23.4.linux-amd64.tar.gz
export PATH=$PATH:/usr/local/go/bin        # add to ~/.profile to persist

# macOS
xcode-select --install     # C toolchain; install Go 1.23+ from https://go.dev/dl or `brew install go`
```

Then just run `./setup.sh --new` — it clones the source (if needed) and builds.
`openssl`, `python3`, `curl`, and `bash` are also required (present by default
on both). Force a rebuild anytime with `REBUILD=1`.

**Source options** for the default `oldxdc` client (override the auto-clone with
`XDPOS_REPO=`, or point `XDPOS_DIR=` at an existing checkout):

- **Default — `XDCIndia/OLDXDC`**: already carries the `puppeth` genesis fix and
  matches the version the scripts expect.
- **Upstream** `XinFinOrg/XDPoSChain` pinned to `68b00c7e5`: `lib.sh` auto-applies
  the storage fix at build time (`patch_puppeth`); the pin keeps the wizard
  prompts in sync with `gen-genesis.sh`.

> Why: upstream `puppeth` has a genesis-storage bug (see
> [The puppeth fix](#the-puppeth-fix)) and its wizard prompts have since drifted.
> `OLDXDC` (or the pinned + auto-patched upstream) avoids both.

---

## Choosing a client

Two node clients are selectable with `--client` (or `CLIENT=`):

| Client | Source repo | Binaries | Status |
|--------|-------------|----------|--------|
| `oldxdc` (default) | [`XDCIndia/OLDXDC`](https://github.com/XDCIndia/OLDXDC) (XDPoSChain) | `XDC`, `bootnode`, `puppeth` | full network (run + genesis + join) |
| `geth` | [`XDCIndia/go-ethereum`](https://github.com/XDCIndia/go-ethereum) (GP5) | `geth` | **build only** — run/genesis profile is TODO |

```bash
./setup.sh --new                 # default oldxdc — runs the 4-node network
./setup.sh --client geth         # builds the modern geth client
CLIENT=geth ./gen-address.sh 2   # any script honors CLIENT=…
```

Binaries are kept separate per client under `bin/<client>/<os>-<arch>/`, so the
two never clash. The modern `geth` fork uses a different run model (no separate
bootnode, `--http.*` flags, its own genesis flow); building works today, but
launching a local net with it isn't wired yet.

## Quick start

From this folder, one command brings up a brand-new network (default `oldxdc`):

```bash
./setup.sh --new
```

This: generates 4 fresh keys into `.env` → derives the validator set from them →
builds a matching genesis → wipes old data → starts the bootnode + 4 mining
nodes. Leave the window open (it keeps printing block logs). **Stop with
`Ctrl + C`.**

Check it's producing blocks (in another terminal):

```bash
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545
```

The number after `0x` should climb (a block every ~2s).

Review what you built (validators, roles, balances):

```bash
./network-info.sh
```

---

## Everyday commands

| Goal | Command |
|------|---------|
| Start fresh (new keys) | `./setup.sh --new` |
| Start reusing current `.env` keys | `./setup.sh` |
| Just launch (keys + genesis already exist) | `./run.sh` |
| See the network summary | `./network-info.sh` |
| Wipe chain data (keep keys) | `./reset.sh` |
| Start over after a change | `./reset.sh && ./setup.sh` |
| Generate keys only | `./gen-address.sh 4 --env` |
| Build a genesis only | `./gen-genesis.sh [flags]` |
| Join another network | `./join.sh --genesis g.json --ip <host>` |

Every script supports `-h` / `--help`.

---

## Generating a genesis

`gen-genesis.sh` drives the (bug-fixed) `puppeth` non-interactively. All flags
are optional and default to the local setup. Addresses accept `0x`, `xdc`, or
bare-hex.

```bash
./gen-genesis.sh --chainid 20118 \
  --signers 0xAAA...,0xBBB...,0xCCC...,0xDDD...
```

| Flag | Meaning (default) |
|------|-------------------|
| `--chainid N` | chain / network id (`20118`) |
| `--signers a,b,c` | validator / masternode addresses |
| `--owner ADDR` | masternode owner |
| `--reward N` | block reward (`5000`) |
| `--v2block N` | v2 consensus switch block (`2700`) |
| `--epoch N` / `--gap N` | epoch length (`900`) / checkpoint gap (`450`) |
| `--foundation ADDR` / `--foundation-owners a,b` | foundation wallet / multisig |
| `--team-owners a,b` / `--swap ADDR` / `--prefund a,b` | governance / funding |
| `--network NAME` / `--out FILE` | puppeth net name / output path |

It also writes `network-roles.env` so `network-info.sh` can label accounts.

> **Keep your `genesis.json`.** puppeth stamps a genesis with the current time,
> so an identical one **cannot be regenerated later**. Whoever runs a network
> must save and share that exact `genesis.json` for others to join.

---

## Joining from another machine

Any node started from this repo shares the same `bootnode.key`, so joining just
needs the network's **`genesis.json`** and the host's **IP**:

```bash
# on the second machine (has bin/, bootnode.key, and the network's genesis.json):
./join.sh --genesis genesis.json --ip <HOST_IP>
```

`--ip` builds the bootnode enode for you. Other ways to point it:

```bash
./join.sh --genesis genesis/genesis.json                       # local machine
./join.sh --genesis g.json --ip 10.0.0.5:30301                 # host + custom port
./join.sh --genesis g.json --bootnodes "enode://KEY@HOST:30301" # explicit enode
```

Useful flags: `--networkid` (defaults to the genesis chainId), `--datadir`
(default `./peer`), `--port` / `--rpcport` / `--wsport`, `--name`,
`--mine ADDR` (only if that address is a validator in the genesis and its key is
in `.env`). By default it joins as a **read/sync** node and **reports to the same
ethstats dashboard as `run.sh`**; override with `--ethstats SECRET@HOST:PORT`
(node name auto-prepended) or turn it off with `--no-ethstats`.

`--client geth` joins with the modern go-ethereum client instead (sync-only — it
imports blocks but can't seal). Verified cross-client: a `geth` peer syncs an
`oldxdc`/XDPoSChain network (same genesis hash + protocol handshake):

```bash
./join.sh --client geth --genesis genesis.json --ip <HOST_IP>
```

**Requirements to connect:**
- The **same `genesis.json`** as the target network (a different one → the peer
  is rejected at the handshake).
- The host allows inbound **`30301/udp+tcp`** (discovery) and **`30303/tcp`** (p2p).
- Both machines on the same network (or the host's public IP is reachable).

Print the exact bootnode endpoint to hand out:

```bash
echo "enode://$(./bin/*/bootnode -nodekey ./bootnode.key -writeaddress)@$(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0):30301"
```

---

## What's in this repo

```
bin/<client>/<os>-<arch>/  per-client, per-platform binaries, built on first
                 run (git-ignored): oldxdc -> XDC+bootnode+puppeth, geth -> geth
setup.sh         one-command end-to-end: keys -> genesis -> reset -> run
run.sh           import keys, init, start bootnode + 4 mining nodes
gen-address.sh   generate fresh keypairs (private key + address)
gen-genesis.sh   generate genesis.json via puppeth (flag-driven)
network-info.sh  plain-language summary of the current network
join.sh          connect & sync an existing network (by genesis + IP/enode)
reset.sh         wipe node data for a clean re-init
lib.sh           shared helper: platform detection, IP, build-on-demand
genesis/         genesis.json (chainId 20118, 4 masternodes seeded)
bootnode.key     fixed bootnode private key (shared, so --ip joins work)
.env / .env.sample  the 4 masternode private keys (.env is git-ignored)
```

---

## Network details

- **chainId / networkid:** `20118` (must **not** be `50/51/551` — those force the
  built-in mainnet/testnet/devnet genesis and won't accept a custom one)
- **consensus:** XDPoS — 2s blocks, epoch `900`, gap `450`, v2 switch block `2700`
- **nodes / ports:**

  | node | datadir | p2p | ws | rpc |
  |------|---------|-----|----|-----|
  | 1 | nodes/1 | 30303 | 8555 | 8545 |
  | 2 | nodes/2 | 30304 | 8556 | 8546 |
  | 3 | nodes/3 | 30305 | 8557 | 8547 |
  | 4 | nodes/4 | 30306 | 8558 | 8548 |

- Nodes report to the `ethstats` endpoint set in `run.sh` (`STATS_SECRET`) —
  change it if you don't want a shared dashboard.
- `.env` holds **throwaway devnet keys** — never reuse them anywhere real.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `Permission denied` running a script | `chmod +x *.sh` |
| `address already in use` | a node is still running: `pkill -f bin/XDC`, then retry |
| `incompatible genesis (have … new …)` | old data vs new genesis: `./reset.sh` then start again |
| Blocks stop / stuck at an epoch (e.g. 900) | genesis validators don't match `0x88` — regenerate with `gen-genesis.sh` (see below) |
| A joining peer won't connect | its `genesis.json` must be byte-identical to the target's; check firewall on `30301`/`30303` |
| `networkid` rejected / wrong genesis loads | don't use `50/51/551`; keep `networkid == chainId` |

---

## The puppeth fix

Stock `puppeth` in this XDPoSChain build corrupts the genesis: its storage
exporter RLP-decoded each already-decoded storage word, truncating every
masternode address in the `XDCValidator` (`0x88`) `candidates[]` array (e.g.
`0xbd29…` → `0x00`). `getCandidates()` then returned garbage and the chain
**stalled at the first epoch boundary (block 900)**. The bundled `bin/*/puppeth`
stores the word verbatim, so validators are seeded correctly and the epoch
transition succeeds. Fix: `cmd/puppeth/wizard_genesis.go` in XDPoSChain.
