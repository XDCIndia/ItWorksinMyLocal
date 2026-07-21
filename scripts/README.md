# net5151 parity-v2 — build & operate

Mainnet-parity XDC devnet (chainId 5151). Genesis hash
`0x1cb73cbd5d8fcf31daed56c243d0430112d26d708153d00d08bb132475c4f30d`,
37.5B supply (wei-exact mainnet parity), mainnet alloc + `0x88`/`0x89` XDPoS
system contracts, XDPoS v2 (period 2s, epoch 900, gap 450, V1→V2 @1800),
maxMasternodes 108, eip1559 @2250 (fixed base fee 12.5 gwei), cancun @3150.
Fork *feature set* + constants = mainnet; fork *block numbers* are devnet-staircased.

## Scripts
- `build-genesis.py` — regenerates `../genesis/genesis-5151.json` from the mainnet
  reference (supply/alloc/system-contracts) + the validator set. Deterministic;
  the genesis hash is stable given the same inputs.
- `legacy-bringup.sh` — launch one validator (legacy XDPoSChain binary):
  `legacy-bringup.sh <label> <datadir> <coinbase> <keystore-file> <pw-file> <p2pPort> <httpPort> <authrpcPort> <hostIP>`
  Wipes+inits the datadir from the genesis, then starts it mining (setsid,
  dash-style flags). Keys/passwords are passed in — never embedded.
- `propose-client.py` — onboard a client masternode via SMC `0x88`
  (fund → `uploadKYC` → `propose`). Run with `SEND=1` to broadcast.
  Passwords come from env (`SUPPLY_PW`, `OWNER_PW`); keystores live in the
  operator's vault, **never in this repo**.

## Build the network (4 validators)
1. Generate the genesis (or use the committed `genesis/genesis-5151.json`).
2. Generate/hold 4 validator accounts + a funded treasury + client coinbases
   in a **vault** (keystores + passwords) — not in this repo.
3. On each of 4 hosts, run `legacy-bringup.sh` with that host's validator key.
4. Mesh: `admin_addPeer` each validator's enode (see `../peers.list`) to the others.
5. Chain mints from genesis; crosses the V1→V2 switch at block 1800.

## Onboard client masternodes (modern-geth / erigon / xОne)
Sync the client as a follower, then `SEND=1 SUPPLY_PW=… OWNER_PW=… ./propose-client.py`
from the treasury. The candidate seats at the next epoch (in V2); arm its miner
**only after it is seated**. Client-produced blocks must be format-compatible with
the fleet (V2 BFT block format is; V1 is not — see go-ethereum#1338).
