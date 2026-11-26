# XDPoS / EIP-8141 Devnet Work — Progress Report

**Author:** Aryan (XDCIndia)
**Date:** 2026-11-17
**Status:** Work in progress — this document explains what has been done and verified so far.
Code, drivers, and raw evidence are being prepared for follow-up contributions.

---

## 1. Context

Two threads of work have been running on top of this harness:

1. **XDPoS debugging exercise** — a seeded-bug exercise on the XDPoS v2 consensus
   engine (`vote.go`), extended into running and forensically debugging real
   multi-sealer devnets built with this repo's scripts.
2. **EIP-8141 frame transactions** — implementing and verifying frame
   transactions (type `0x06`) on an XDPoS chain, governed by a phased
   enablement plan, with the harness in this repo used to stand up every test
   network.

All networks below were built from this repo's tooling (4-sealer meshes unless
stated, 2s target block time, XDPoS v2, epoch 900).

## 2. Consensus reliability — two production-grade defects root-caused and fixed

A 4-sealer devnet (hegota-20118, chain id 20118) suffered a reorg storm
(~11s blocks, tip parking 60-70s, receipt status flipping across views) and
competing mints. Both were root-caused from instrumented DEBUG logs:

- **Transport echo loop:** the BFT handler re-broadcast every verified inbound
  message. Fix: seen-hash dedup before re-broadcast
  (`eth/bft/handler.go`).
- **Vote-latch round skew:** the one-vote-per-round latch read the current
  round *after* the locally QC-completing vote had already advanced it, so it
  latched R+1 and refused the round-R+1 candidate (2 votes -> 20s timeout
  certificate). Fix in `engine_v2/vote.go`, plus a proposed-block dedup guard
  for double handler invocation per imported block.

Validated on all 4 sealers: **100/100 blocks at exactly 2s, 0 refusals,
0 timeouts**, then a 3-epoch soak (2994 blocks, 107 min, zero stalls).

## 3. EIP-8141 frame transactions — phased status

- **Phase 1 (reference implementation) — complete.** Frame type `0x06`,
  execution engine in `state_transition.go`, txpool gate + blob rejection,
  wallet-RPC signing support (`types.SignFrameTx`), 6 new tests passing.
- **Phase 2 (cross-client conformance surface) — reference side complete.**
  Canonical frame-tx JSON in the RPC transaction view, `round` in block JSON,
  `eth_getEpochNumbers` RPC, golden vectors pinned with canonical JSON +
  SHA-256, and `cmd/conformcheck` — an independent spec-based checker
  (hand-rolled RLP, no go-ethereum types on the check path) at **16/16 vs all
  vectors + live devnet receipts**.
- **Phase 3 (multi-sealer scenarios) — complete, verified on-chain** on the
  4-sealer net with depth-re-verified canonical receipts: atomic-batch revert
  (frame receipts + storage rollback + skip), exact payment accounting
  (payer delta == gasUsed x effectiveGasPrice to the wei), and sponsored
  payment (payer = approver, sender untouched). Mempool load 20/20 txs in one
  block. Sealer restart/rejoin verified.
- **Phase 4 (pre-activation dry run) — complete.** On a bogotaBlock-1800 dry
  net: pre-gate rejection of frame txs (all sealers), gate inclusion, full
  Phase 3 replay post-gate with byte-identical receipts, and a rollback drill
  proving a pre-fork binary is walled out at the P2P genesis-hash check and
  pool-rejects type-6 txs. Conclusion: no automatic rollback exists at any
  layer — rollback means a coordinated genesis/chain restart.

**EIP-8250 (keyed nonces)** is also implemented on top of 8141
(nonce-manager slots, dedicated keyed pool set, genesis preload) and verified
end-to-end on a devnet: single-use keyed tx mined, sentinel slot written,
sender nonce untouched, replay rejected.

## 4. Networks stood up with this harness

| Network | Purpose | Result |
|---|---|---|
| hegota-20118 | Main 4-sealer fork devnet (RPC 8711-14) | All EIP-8141/8250 verification |
| dry-run net (bogotaBlock 1800) | Phase 4 activation/rollback drill | 4/4 steps pass |
| hg2-2040 | Second lab net, chain id 2040 | 4/4 sealers, 2s steady |
| hg3-20118 | Foreign-client net sealed by XDC 2.7.1 (oldxdc) | v1->v2 switch observed live; join matrix: geth/oldxdc/xone sync to tip hash-identical, erigon syncs via a modern bridge peer, reth syncs with caveats logged, besu stalled mid-sync |

## 5. Cross-client probes (for the client-matrix decision)

- **erigon v3.5:** accepts the custom genesis and reaches state-root parity
  after materializing two injected genesis accounts, but pre-London XDC
  headers block fork-chain sync — weeks-scale port.
- **reth (xdc-reth 2.2.0):** parses the full XDPoS genesis but diverges on
  header semantics (baseFee/withdrawals/beacon fields) -> genesis-hash
  mismatch walls the wire join — closest candidate, days-scale port.

No porting started; this is gated on the mentor's client-matrix decision.

## 6. Update — 2026-11-21: Apothem client matrix + live EIP demos on hegota-20118

**Apothem testnet (chain id 51) five-client matrix** — all clients launched
from this harness (`join.sh --network apothem`), peers harvested live from a
connected client's `admin_peers` after the 28 public bootnodes saturated
(TOO_MANY_PEERS):

- **xOne:** syncs with `XDC_EXPERIMENTAL_SNAPSYNC=1`; experimental snap
  state-download wedged at ~4h with 0 blocks, node sacrificed for RAM.
- **Geth (XDC fork):** no snap sync on Apothem — full sync ~40 blk/s.
- **Besu (26.7-develop-ddcf744):** two independent defects proven — snap mode
  drops every peer `USELESS_PEER_EXCEEDS_TRAILING_BLOCKS`; full mode rejects
  canonical block 2710 (`Invalid block 2710`, hash verified against public
  RPC). Stopped; bug report owed to XDCIndia/besu-xdc.
- **Erigon:** needs the built-in `--chain xdc-apothem` chainspec (vendored
  genesis panics); syncs ~33 blk/s with live-enode bootnodes+staticpeers.
- **Nethermind:** ships and syncs (~71 blk/s) once bootstrapped with live
  enodes.

All four still-running nodes were wired to **XDC SkyNet**
(skynet.xdcindia.com, Apothem view) with manual registrations named
`aryan-geth` / `aryan-erigon` / `aryan-nethermind`; heartbeats every 30s.
(Gotchas: SkyNet `identify` dedupes by fingerprint and cannot rename — use
manual `/api/v1/nodes/register`; node-id credential bind files must be
chmod 666 before container start, updated in place, never rewritten.)

**Live EIP demos on the untouched 52k-block hegota-20118 net** — the genesis
faucet key (0xa51e034e…8, present in every hegota genome) proved
unrecoverable, and epoch rewards do not land in sealer coinbases on this
fork, so the only spendable funds are sealer signing dust (~0.0177 XDC).
The e2e drivers were patched for dust-scale funding (fund 1→0.004 XDC;
feeCap 100→13 gwei — the pool's upfront check is gasLimit×feeCap and
instantly bankrupted the funded sender; baseFee is pinned at 12.5 gwei):

- **EIP-8250 keyed nonces — PASS (re-verified live):** keyed frame tx
  `0x1a58bf08…bb27` mined block 53074 status=1 gasUsed=130850 (byte-exact
  historical value), nonce-manager slot written to the 0xffff…ffff single-use
  sentinel, account nonce untouched, replay rejected "nonce key 7 already
  used".
  Evidence: `evidence/keyede2e-hegota-2026-11-21.log`.
- **EIP-8141 Phase 3 scenarios (atomic batch, payment accounting, sponsored
  payment) — re-run in progress:** dust-scale patch applied (sender funded
  0.0098 XDC, deploy gas limits 500k→100k, frame gas limits cut ~40%,
  approver pre-funded 0.004 XDC at deploy). First deploy confirmation
  stalled under the net's deep-reorg churn at the time of writing; run to be
  resumed and receipt-re-verified at depth as before.
  Log so far: `evidence/phase3e2e-hegota-dust-2026-11-21.log`.

## 7. What comes next

1. Contribution of the code and drivers behind the above (consensus fixes,
   EIP-8141/8250 implementation, `cmd/conformcheck`, launchers and genomes
   used for the dry-run/hg2/hg3 nets) as follow-up PRs.
2. Activation-config publication — gated on mentor sign-off + the client
   matrix.
3. BAL/EIP-8279 scoping discussion (EIP-7928 block-access-list plumbing and
   the EIP-7623 calldata floor already exist in the base; 8131/8279 are
   absent) before calendar time is committed.

---

*Every claim above is backed by on-chain measurements, instrumented logs, and
receipt-level accounting; the raw evidence accompanies the code contribution.*
