# xOne-Rust vs reth on private XDC chain 20119 (1,800 blocks)

Date: 2026-11-13/14 · Author: Harsh Gaikwad · Status: **xOne complete, reth incomplete**

## TL;DR

| | xOne-Rust (median of 3 runs) | reth |
|---|---|---|
| Synced the 1,800-block range | ✅ in 1.87 s | ❌ stopped at block 163 |
| Block hashes match sealers (900, 1800) | ✅ YES / YES in all 3 runs | not reached |
| Peak RAM | 78 MB | 2,454 MB (more than the host had free) |

reth with **default settings did not fit in this 3.7 GB WSL host**: it ran out of RAM,
started swapping, and stalled. Its numbers below are partial and **swapping-affected**;
they are not a measure of reth's real speed. A fair reth run needs either capped caches or
a bigger machine (see "Next steps").

## Setup

| Item | Value |
|---|---|
| Host | Windows laptop, WSL2 Ubuntu 24.04, 8 cores, 3.7 GB RAM for WSL, 8 GB swap |
| Chain | private XDC chain 20119: 4 oldxdc v2.7.1 sealers, 2 s blocks, V2 switch at block 900, epoch 900 |
| Genesis hash | `0xca872ff060dca60dd0c6b92cb5fa144e26a7a2c7d07dbf21a3d5082632bb74c7` |
| Range measured | **1,800 blocks**: genesis → block 1800 (covers the V2 switch at 900 and the checkpoint at 1800) |
| Method | each client run **alone** (never both at once), fresh datadir, synced from the 4 sealers; then 120 s following the live tip |
| xOne-Rust | `XDCIndia/xOne` @ `07eb9fe`, built here: `cargo build --release --locked -j 2 -p xone`, rustc 1.94.0 |
| reth | `xdc-reth` 2.9.0-dev, the repo's prebuilt binary (`binaries.json`), default settings |
| Sampling | RSS / CPU / head every 0.2 s while syncing, every 2 s when steady; block times from each client's own log |

## (a) Build and run issues log

| # | Stage | Error | Cause | Fix |
|---|---|---|---|---|
| 1 | xOne build | `failed to run custom build command for mdbx-sys v13.11.0` / `Unable to find libclang` | the MDBX crate generates bindings with `bindgen`, which needs libclang | `sudo apt install -y clang libclang-dev cmake libssl-dev`; rebuild succeeded |
| 2 | xOne run | `genesis: required fork block 'tip2019Block' is absent from the chain config` | xOne requires every XDC fork height to be explicit; legacy genesis omits them and geth/oldxdc fall back to built-in defaults | patched **copy** of genesis with the 10 XDC fork rows oldxdc actually uses for chain 20119 (XDC mainnet values, since 20119 is not 51/551/5151): tip2019=1, tipSigning=3000000, tipRandomize=3464000, tipNoHalvingMNReward / tipXDCX / tipXDCXCancellationFee / tipTRC21Fee=38383838, gas50x=80370000, tipXDCXMinerDisable=80370000, tipXDCXReceiverDisable=80370900 |
| 3 | xOne run | `unknown field 'SwitchEpoch', expected one of 'switchBlock', 'switchEpoch', 'allConfigs'` | legacy puppeth writes `SwitchEpoch` (Go reads JSON keys case-insensitively, xOne's serde does not) | renamed to **lower-case `switchEpoch`**, value kept at 0 (what oldxdc uses) |
| 4 | xOne run | strict parse requires **8 V2 settings** absent from the genesis | xOne's V2 config has no defaults | filled `maxProtectorNodes 0, maxObserverNodes 0, masternodeReward 0, protectorReward 0, observerReward 0, minimumMinerBlockPerEpoch 1, limitPenaltyEpoch 4, minimumSigningTx 0`. xOne only reads these after `tipUpgradePenalty` / `tipProportionalReward`, which this chain never activates, so they are inert; the last two mirror oldxdc's hard-coded constants |
| 5 | verification | — | — | xOne's computed genesis hash = the sealers' block 0, and hashes match at 900 and 1800, so the patched values agree with the chain |
| 6 | environment | Windows C: reached 0 MB, WSL crashed | WSL swap and disk image live on C: and grew during the first reth attempt | freed C: (Docker build cache prune + trim + `diskpart compact`); lowered free-space gate to 8 GB for this run |
| 7 | environment | sealers corrupted after the crash: `Head state missing, repairing chain`, `missing trie Node` | processes killed without shutdown | wiped chain-20119 data only and resynced from genesis (same genesis hash) |
| 8 | reth run | stalled at block 153–163, p99 block time 31.6 s | default settings peak at 2.45 GB RSS, more than the free RAM, causing swap | **stopped** (SIGTERM) to protect the host; marked incomplete |
| 9 | benchmark harness | runner never started; xOne sync rate `nan` | my own bugs: shell quoting emptied a wait condition; 2 s sampling too coarse for a 1.9 s sync | rewrote runner from a plain file; 0.2 s sampling while syncing |

xOne build result: **6 min 02 s wall clock, peak 737 MB RSS, 0 warnings, 19.7 MB binary**
(toolchain install 113 s and crate download 126 s not included). The failed attempt 1
peaked at 504 MB before stopping at `mdbx-sys`. The version string ends in `-dirty` only
because build scripts/logs sat untracked in the clone; no source file was changed.

## (b) Comparison table — 1,800 blocks

xOne figures are the **median (range) of 3 repeat runs** (`raw/run-xone-r1..r3`), each alone
with a fresh datadir. reth is a single, incomplete run.

| Metric (1,800 blocks) | xOne-Rust — median (range), n = 3 | reth — INCOMPLETE, swapping-affected, n = 1 |
|---|---|---|
| Range completed | 0 → 1800 ✅ (3/3) | 0 → 163 only (9 %) ❌ |
| Time to reach block 1800 | **1.87 s** (1.87–2.26) | not reached; stopped after ~3 min |
| Sync speed | **1,006 blocks/s** (860–1,014) ¹ | ~6 blocks/s for 0→153 (incl. startup), then **~0.06 blocks/s** for 153→163 while swapping |
| Peak RSS | **78 MB** (73–78) | **2,454 MB** |
| Steady RSS (following tip) | 78 MB (73–78) | n/a (never reached steady state; median 2,168 MB during the run) |
| Disk (datadir) | 69 MB (69–69) | 1.6 MB (state not yet persisted when stopped) |
| CPU while syncing (100 % = one core) | median 88 % (86–88) | median 244 %, peak 660 % |
| CPU while following tip | ~0 % | n/a |
| Block time p50 / p99, sync | **0.93 / 1.34 ms** (p50 0.92–1.06, p99 1.31–1.44) ² | **3.1 / 31,626 ms** (n = 163; the p99 is swap stalls) |
| Block time p50 / p99, following live tip | 11 / 15 ms (p50 10–11, p99 15–17) | n/a |
| Hash match block 900 | YES (3/3) | not reached |
| Hash match block 1800 | YES (3/3) | not reached |

¹ The whole sync lasts ~1.9 s and the harness samples every 0.2 s, so each blocks/s figure
carries roughly ±10 % timing resolution; the 860 run is within that plus normal variation.
² xOne syncs in 128-block batches, so its per-block sync time is batch time ÷ 128; reth's is
measured per block. See "How each client synced" below.

The first single run that the earlier version of this report used (960 blocks/s, 76 MB,
p99 1.38 ms; `raw/run-xone-first/`) falls inside these ranges.

### How each client synced — read with the table

- **xOne ran as a follower replaying existing blocks.** It dialled the 4 sealers, requested
  headers and bodies for blocks that already existed (`GetBlockHeaders` / `GetBlockBodies` over
  eth/100) in 128-block batches, and **executed every block itself**, refusing any block whose
  state/receipt roots differ from its header. It did not produce blocks and did not use snap sync.
- **reth's path was single-block engine import.** Its log shows, for all 163 blocks it reached,
  `Received new payload from consensus engine` → `Block added to canonical chain`, driven by the
  XDC fork's head forwarder (`XDC: forwarding new canonical head to FCU feeder`). It never
  entered reth's batched staged ("pipeline"/backfill) sync, which upstream reth uses to catch up
  over large gaps. So the two clients were not on the same kind of sync path: batched replay
  vs. one-block-at-a-time engine import.
- **The genesis was patched for xOne.** xOne rejected the chain's own genesis (issues 2–4); it
  ran from `genesis-20119-xone.json`, which adds the XDC fork heights and V2 settings oldxdc
  uses implicitly. reth ran from the chain's original genesis. Both computed the same genesis
  hash, and xOne's hashes matched the sealers at 900 and 1800.
- **No speed ratio between the two clients is claimed.** reth did not complete the range and its
  numbers are dominated by swapping, so "xOne is N× faster than reth" cannot be derived from this
  data. The table records what each client did; a ratio needs a complete reth run.

## (c) Caveats — read before quoting these numbers

- **Small sample.** 1,800 mostly-empty blocks (492 transactions in total, ~0.27 per block),
  3 runs of xOne and 1 incomplete run of reth, one machine. It shows behaviour on a light
  private chain, not mainnet performance.
- **xOne used a patched genesis.** The chain's own genesis is rejected by xOne (issues 2–4).
  The patch only adds values oldxdc already uses implicitly, and the matching hashes support
  that, but the clients did not read byte-identical genesis files.
- **reth is incomplete.** Default settings did not fit in 3.7 GB; its figures are partial and
  swapping-affected. Its 3.1 ms p50 (before memory ran out) suggests per-block execution is
  not the bottleneck — memory is.
- **Not like-for-like builds.** xOne was built from source here; reth is the published prebuilt.
- **Different import paths.** xOne imports in 128-block batches during sync; reth logs one
  block at a time through its engine. Per-block sync times are therefore computed differently.
- **Earlier, separate xOne run (not part of this comparison).** On the previous incarnation of
  chain 20119 (same genesis, wiped after the crash), xOne synced genesis → block 5,239 in 14.9 s.
  With 2 s sampling the timed window was **4,543 blocks (696 → 5,239) in ~13 s = 354 blocks/s**.
  ("354 blocks in 13 s", as it was once quoted, mixes up the rate with the count; it is wrong.)
  The 2 s sampling did **not** understate that rate — an earlier version of this report said it
  did, and that was wrong. Over the same blocks 0–1,800, with the same transaction load (491 vs
  492 transactions), xOne's own log shows **2.71 ms/block of execution then vs 1.00 ms/block
  now**, so the gap (354 vs ~1,006 blocks/s) is in execution, not measurement. The likely cause
  is a busier host at the time (other clients still running on that chain right after the build),
  but this was **not isolated**. Raw data: `raw/earlier-5239-block-run/`.

## What the numbers show (so far)

- xOne-Rust is very light on this chain: ~78 MB RAM (73–78 over 3 runs) and under one core, because it keeps
  state in memory with flat segment files and executes blocks in batches.
- reth's defaults are sized for mainnet-scale state (large caches and preallocated buffers),
  so on a 3.7 GB host its memory, not its execution speed, is the limit.
- **No speed verdict yet** between the two: that needs reth running without swapping.

## Next steps

1. Rerun reth with its cache/memory flags capped (list in `reth-memory-flags.md`), or on a
   machine with ≥ 8 GB free RAM, on the same 1,800-block range.
2. Reduce WSL swap to 4 GB (proposal in `wslconfig-proposal.md`) so a starving process cannot fill C:.

## Files

- `raw/run-xone-r1/`, `raw/run-xone-r2/`, `raw/run-xone-r3/` — the 3 repeat runs (summary, samples.csv, node.log); the table is their median
- `raw/run-xone-first/` — the first single 1,800-block run with 0.2 s sampling
- `raw/run-xone-try1/` — first 1,800-block attempt (2 s sampling, rate unmeasurable)
- `raw/earlier-5239-block-run/` — the separate earlier run on the previous chain incarnation (354 blocks/s)
- `raw/run-reth/` — summary, samples.csv, node.log.gz (incomplete run)
- `raw/build/` — xOne build logs, attempt 1 (libclang failure) and attempt 2 (success)
- `raw/xone-genesis-refusals/` — the two refused xOne starts (issues 2 and 3)
- `raw/sealer-crash-evidence.txt` — corruption lines from the 4 sealers after the crash
- `scripts/` — bench2.sh, analyze.py, patchgen.py, run-both.sh, guard.sh, check-sealers.sh, wipe-20119.sh
- `genesis-20119-xone.json` — the patched genesis copy xOne used
