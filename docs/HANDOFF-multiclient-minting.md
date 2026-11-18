# Handoff: getting every client to validate and mint blocks

Status as of 2026-08-01. Written so someone can pick this up cold.

---

## 1. Where things actually stand

Two different capabilities get conflated. Keep them apart:

| capability | meaning | who can do it today |
|---|---|---|
| **follow** | receive blocks, execute them, agree on the state root | geth, geth4, besu, oldxdc, erigon\* |
| **mint** | be seated in the validator set and *produce* blocks | **oldxdc only** |

\* erigon follows, but wedges permanently at an epoch switch — see §4.

Nothing except `oldxdc` can mint. `join.sh --mine` is documented oldxdc-only
(`join.sh:158`), and the other clients join sync-only. Verified: starting a
non-oldxdc client on a seated coinbase produces no blocks at all.

**Do not treat "all clients at tip" as evidence of correctness.** On a chain
whose only traffic is the periodic zero-gasPrice `sign()` calls, three clients
agreed on 933 consecutive blocks while computing fees wrongly the whole time.
See §3 and issue #192.

---

## 2. The bug that this handoff exists because of

XDPoS headers carry `Coinbase = 0x0`. The real producer is recoverable only by
ecrecovering the 65-byte seal in `extraData`. Canonical XDPoSChain never reads
`header.Coinbase` for fees:

```go
// XDPoSChain core/evm.go:38 — author == nil during block validation
beneficiary, _ = chain.Engine().Author(header)   // -> ecrecover of the seal
Coinbase: beneficiary                            // core/evm.go:52
// core/state_transition.go:401
st.state.AddBalance(st.evm.Context.Coinbase, gasUsed * effectiveTip)
```

A client that credits `header.Coinbase` instead burns every fee to the zero
address. It still agrees on every zero-gasPrice transaction, because
`AddBalance(x, 0)` is a no-op whichever `x` you pick — so the bug is invisible
until the first fee-paying transaction.

**How to verify the reference behaviour yourself, without reading any client
source.** Ecrecover the signer of each fee-paying block, sum its fees, and
compare to its live balance. On chainId 7171 this matched to the wei:

```
0x6d62f524...  sealed 934 + 938   predicted 66,831,000,000,000   actual identical
0xdb9833bd...  sealed 936         predicted 16,995,000,000,000   actual identical
zero address                                                     0
```

That single check is the fastest way to tell whether a client's fee accounting
is right, and it works against any client over plain RPC.

---

## 3. Per-client state

| client | follows? | mints? | blocker |
|---|---|---|---|
| oldxdc | yes | **yes** | — |
| geth / geth4 | yes | no | geth4 has no darwin artifact |
| besu | yes | no | needs host Java 21 (bundled JRE is linux/amd64) |
| erigon | yes | no | permanent MDBX wedge at epoch switch — erigon-xdc#378 |
| xone | **fixed** | no | fee bug fixed (xOneGo#717); now blocked at block 1800 |
| reth | no | no | state-root mismatch at 936 — **not root-caused** |
| nethermind | no | no | `GetTipTRC21FeeBlock` returns 0 for unregistered chainIds |

### xone — FIXED, XDCIndia/xOneGo#717
`feeRecipient := header.Coinbase` in `pkg/core/execution/processor.go`. Fix adds
a leaf package `consensus/xdcseal` that ecrecovers the signer.

The helper had to be a *new leaf package*, and that constraint is not obvious:
`core/execution -> consensus/xdpos` is an import cycle (via `core/block`, and
only `go vet` surfaces it — `go build` does not), and `core/types` cannot host
it either because `crypto` imports `core/types`. Anyone tempted to "just import
it" will hit both walls in that order.

Verified: passes 934, zero `block_root_mismatch`, and xone now reports the same
signer balance as the sealer.

### nethermind — identified, NOT fixed
`XdcConstants.GetTipTRC21FeeBlock` returns **0** for unregistered chainIds, so
TIPTRC21Fee is treated as active from genesis and the fee is routed to the
signer's registered *owner* from the 0x88 contract. The reference falls through
to the mainnet default 38,383,838, which block 934 is far below, so it credits
the signer directly. Fix: match the reference fallback.

### reth — NOT root-caused
Fee handling is correct; it ecrecovers, and it *agrees* on block 934. It fails
at 936, a contract call:

```
got      0x58f3a2e7ca8a97bf07ba112d31915362f15edc76e3501057b4bac8fb3381dae5
expected 0x49e4a3471f5ddba8ba0534f2ced08a0db8f28d82f9cce63088b1cb07f0570b55
```

EIP-2028 calldata gas was the leading theory and does not obviously hold: 934
has 0 bytes calldata (identical gas either schedule — which is *why* reth agrees
there), 936 has 100 bytes (676-gas difference), but the genesis declares
`istanbulBlock: 0` and reth's `unregistered_private_istanbul_active` reads that
exact key. Narrowed, not solved.

---

## 4. The epoch-switch problem (blocks minting more than anything else)

Two independent clients fail at the **same** epoch-switch block, 1800, where the
validator set grew 4 -> 5:

- **erigon**: `MDBX_EKEYMISMATCH` in the bodies stage during the unwind, 17,009
  repeats, permanently wedged. Unrecoverable in place; only a datadir wipe
  fixes it. (erigon-xdc#378)
- **xone**: `block_invalid` on `0xe65e36ea...` — a *different* signature from
  its fee bug, and only visible once the fee bug was fixed.

Two clients failing at the same block is unlikely to be coincidence. Until
epoch-switch handling is solid across clients, **seating a non-oldxdc validator
will destabilise the network**, so §5 has to come after this is fixed.

### A live footgun worth knowing

`propose()` seats a **coinbase address**, not a running node. If you propose and
do not start a node for that coinbase before the next epoch switch, the network
seats a validator that does not exist and degrades — measured: block time went
from 2.00s to 7.97s, with 20s gaps, and a second sealer stopped producing
entirely because rotation could not make progress. It recovers the moment you
start a node on that coinbase (verified: back to 2.00s, 5/5 producers even).

`lab/propose-masternode.sh` should warn about this. It currently prints the
seating block as though that were the finish line.

---

## 5. Future approach: getting all clients to mint

Ordered so each step is verifiable before the next.

**Step 0 — make "all clients follow" true and *provable*.**
Fix reth and nethermind (§3), then erigon and xone at the epoch switch (§4). Do
not start on minting before this: a client that cannot validate a block it
receives certainly cannot produce one.

Prove it with a fee-paying, contract-calling workload — not an idle chain. The
existing `lab/oracle.sh` compares hashes; extend it per **#192** so it also
compares `stateRoot` / `receiptsRoot` / `gasUsed` field-by-field and probes
state (`eth_getBalance` at height). Add the ecrecovered-signer fee check from §2
as a standing assertion — it is cheap, universal, and it is precisely the check
that would have caught this bug on day one.

**Step 1 — decide what "mint" requires per client.**
For each non-oldxdc client, answer in writing before coding:
- can it *sign* an XDPoS V1 seal (15-field clique-style sigHash) and a V2 seal?
- can it produce the epoch-switch header — the 197-byte extraData carrying the
  ordered validator list?
- does it implement the turn/rotation rule, including `Signed recently, must
  wait for others`?
- does it credit the block reward at the epoch checkpoint identically?

Any "no" is a work item. Expect V2/HotStuff to be the expensive one.

**Step 2 — mint on a two-client net first.**
oldxdc + one candidate, 2 sealers only. Simplest rotation, easiest to debug.
Assert: both produce ~50% of blocks, all followers agree on every hash, and the
fee check in §2 holds for both signers.

**Step 3 — mixed minting, one client at a time.**
Add one new minting client per epoch, never two at once, so any regression is
attributable. Watch the epoch switch specifically — it is where everything has
broken so far.

**Step 4 — make it a standing test.**
A scenario under `lab/scenarios/` that boots a mixed-minting net, runs
fee-paying traffic across at least two epoch switches, and asserts per-signer
fair share plus full hash agreement. Without this, step 3 regresses silently.

---

## 6. How to reproduce any of this

```sh
./setup.sh --new --all --chainid <id> --network <name>   # ~10 clients, no source build
# wait past one epoch (block 900+), then:
./lab/propose-masternode.sh --rpc http://localhost:8545  # funds, uploadKYC, proposes
# start a sealer on the new coinbase BEFORE the next switch (see §4 footgun):
./join.sh --client oldxdc --mine <coinbase> --etherbase <coinbase> --datadir ./nodes/mn1 ...
```

Host prerequisites that fail *quietly* — both now in the README, both cost real
debugging time:
- **~12 GB free disk.** Below it, nethermind initialises, prints its banner and
  shuts down *gracefully with no error line*.
- **Java 21+ on PATH.** Otherwise besu is skipped; its bundled JRE is
  linux/amd64.

Two tooling notes: `lab/oracle.sh:186` uses `declare -A`, which fails on macOS
bash 3.2 (the repo's own `check-portability.sh` bans that construct but does not
scan `lab/`). And erigon takes `--torrent-port`, `PRIVAPI` and `MCP_PORT` from
fixed defaults, so two erigons on one host always collide — set them explicitly.

---

## 7. Open issues

| issue | subject |
|---|---|
| ItWorksinMyLocal#194 | the divergence, root cause, per-client status |
| ItWorksinMyLocal#192 | cross-client validation testing — the systemic gap |
| ItWorksinMyLocal#188 | oldxdc does not register the `personal` RPC namespace |
| erigon-xdc#378 | permanent MDBX wedge at epoch switch |
| erigon-xdc#372 | SIGSEGV in `Accumulator.ChangeStorage` during unwind |
| xOneGo#717 | the fee fix (open PR) |

---

## 8. What I would not trust without re-checking

- **reth's root cause.** Genuinely unknown. Do not build on the EIP-2028 theory.
- **nethermind's fix.** The owner-vs-signer difference was traced in source but
  never executed; the specific validator-owner mapping for chainId 7171 was not
  confirmed.
- **besu and erigon's fee correctness.** They follow the chain, so they are
  *probably* right, but neither was code-checked. Run the §2 balance check
  against them — it takes a minute and turns an inference into a measurement.
