# Scripts — what each one does

A quick, plain-English cheat-sheet. All are run from this folder, e.g. `./setup.sh`.

| Script | In one line | When you use it |
|--------|-------------|-----------------|
| `setup.sh` | **Does everything** — makes keys, builds the genesis, resets, and starts the network. | The normal way to start. `./setup.sh --new` for a fresh network. |
| `gen-address.sh` | Creates new accounts (private key + address). | When you need fresh keys for nodes. |
| `gen-genesis.sh` | Builds the network's rulebook (`genesis.json`). | When you want to change chain settings/validators. |
| `run.sh` | Starts the bootnode + 4 nodes (assumes keys/genesis exist). | To launch without regenerating anything. |
| `network-info.sh` | Prints a plain summary of the current network. | To review who owns what and the balances. |
| `join.sh` | Connects & syncs an **existing** network (given its genesis). | To add a syncing peer, or join a network on another machine. |
| `reset.sh` | Deletes all node data. | Before starting over with a new genesis or keys. |

---

## A little more detail

### `setup.sh` — the one-command start
Runs the whole flow end to end: generate keys → derive who the validators are →
build the genesis with them → wipe old data → launch the network.
- `./setup.sh` — reuse the keys already in `.env`
- `./setup.sh --new` — generate brand-new keys first
- `./setup.sh --new 4` — generate N new keys

### `gen-address.sh` — make new accounts
Prints, for each account, a **private key** (its secret password) and an
**address** (its public ID), plus ready-to-paste blocks for `.env` and
`gen-genesis.sh`.
- `./gen-address.sh` — 4 accounts
- `./gen-address.sh 1` — one account
- `./gen-address.sh 4 --env` — also save them into `.env`

### `gen-genesis.sh` — build the rulebook
Creates `genesis/genesis.json` (chain id, who can produce blocks, starting
balances). Everything has sensible defaults; override with flags:
- `./gen-genesis.sh` — defaults
- `./gen-genesis.sh --chainid 12345 --signers 0xAAA…,0xBBB…` — custom
- run `./gen-genesis.sh --help` to see all flags

### `run.sh` — just launch
Starts the local bootnode (the "phone book") and 4 mining nodes using the
existing `.env` keys and `genesis.json`. Rebuilds the programs only if they're
missing or you set `REBUILD=1`.

### `network-info.sh` — review the network
Reads the current files and prints a friendly report: chain id, block time, the
validators (marked if **you** hold the key), key roles (owner/foundation/swap),
starting balances, and total supply.
- `./network-info.sh`

### `join.sh` — sync an existing network
Runs a node that **joins another network** (instead of starting your own) and
syncs its blocks. You give it that network's genesis; the bootnode address
defaults to one built from `bootnode.key`.
- `./join.sh --genesis genesis/genesis.json` — join the local network here
- `./join.sh --genesis their.json --host 10.0.0.5` — join a network on host `10.0.0.5`
- `./join.sh --genesis their.json --bootnodes "enode://KEY@HOST:30301"` — explicit
- Joins as read-only/sync by default; add `--mine ADDR` only if that address is
  a validator in the genesis and its key is in `.env`.
- The genesis must exactly match the target network's.

### `reset.sh` — start clean
Erases each node's chain data so the next `run.sh`/`setup.sh` starts from block
zero. Run this after changing the genesis or the keys.
- `./reset.sh`

---

## Typical order

```
./setup.sh --new        # first time: everything in one go
./network-info.sh        # (optional) review what you just created
# ... use the network ...
# Ctrl+C to stop, then:
./reset.sh && ./setup.sh # start over with the same keys
```

For a beginner walkthrough see **SETUP.md**; for full technical detail see **README.md**.
