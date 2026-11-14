# xOne-Rust vs reth on private XDC chain 20119 (1,800 blocks)

Date: 2026-11-13/14 · Author: Harsh Gaikwad · Status: **xOne complete, reth incomplete**

## TL;DR

| | xOne-Rust | reth |
|---|---|---|
| Synced the 1,800-block range | ✅ in 1.9 s | ❌ stopped at block 163 |
| Block hashes match sealers (900, 1800) | ✅ YES / YES | not reached |
| Peak RAM | 76 MB | 2,454 MB (more than the host had free) |

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

| Metric (1,800 blocks) | xOne-Rust | reth — INCOMPLETE, swapping-affected |
|---|---|---|
| Range completed | 0 → 1800 ✅ | 0 → 163 only (9 %) ❌ |
| Time to reach block 1800 | 1.9 s (first block after 0.2 s) | not reached; stopped after ~3 min |
| Sync speed | **960 blocks/s** (blocks 188→1800 in 1.7 s) | ~6 blocks/s for 0→153 (incl. startup), then **~0.06 blocks/s** for 153→163 while swapping |
| Peak RSS | **76 MB** | **2,454 MB** |
| Steady RSS (following tip) | 76 MB | n/a (never reached steady state; median 2,168 MB during the run) |
| Disk (datadir) | 68 MB | 1.6 MB (state not yet persisted when stopped) |
| CPU while syncing (100 % = one core) | median 88 %, peak 102 % | median 244 %, peak 660 % |
| CPU while following tip | ~0 % | n/a |
| Block time p50 / p99 | sync: **0.95 / 1.38 ms** per block (128-block batches) · live: **12 / 18 ms** | **3.1 / 31,626 ms** (single-block imports, n = 163; the p99 is swap stalls) |
| Hash match block 900 | YES | not reached |
| Hash match block 1800 | YES | not reached |

## (c) Caveats — read before quoting these numbers

- **Small sample.** 1,800 mostly-empty blocks (a few transactions each), one run per client,
  one machine. It shows behaviour on a light private chain, not mainnet performance.
- **xOne used a patched genesis.** The chain's own genesis is rejected by xOne (issues 2–4).
  The patch only adds values oldxdc already uses implicitly, and the matching hashes support
  that, but the clients did not read byte-identical genesis files.
- **reth is incomplete.** Default settings did not fit in 3.7 GB; its figures are partial and
  swapping-affected. Its 3.1 ms p50 (before memory ran out) suggests per-block execution is
  not the bottleneck — memory is.
- **Not like-for-like builds.** xOne was built from source here; reth is the published prebuilt.
- **Different import paths.** xOne imports in 128-block batches during sync; reth logs one
  block at a time through its engine. Per-block sync times are therefore computed differently.
- An earlier xOne run on the previous incarnation of chain 20119 (5,239 blocks, 2 s sampling)
  measured 354 blocks/s; the coarse sampling understated the rate, which is why this run uses 0.2 s.

## What the numbers show (so far)

- xOne-Rust is very light on this chain: ~76 MB RAM and under one core, because it keeps
  state in memory with flat segment files and executes blocks in batches.
- reth's defaults are sized for mainnet-scale state (large caches and preallocated buffers),
  so on a 3.7 GB host its memory, not its execution speed, is the limit.
- **No speed verdict yet** between the two: that needs reth running without swapping.

## Next steps

1. Rerun reth with its cache/memory flags capped (list in `reth-memory-flags.md`), or on a
   machine with ≥ 8 GB free RAM, on the same 1,800-block range.
2. Reduce WSL swap to 4 GB (proposal in `wslconfig-proposal.md`) so a starving process cannot fill C:.

## Files

- `raw/run-xone/` — summary, samples.csv, node.log (the 1,800-block run)
- `raw/run-xone-try1/` — first 1,800-block run (2 s sampling, rate unmeasurable)
- `raw/run-reth/` — summary, samples.csv, node.log.gz (incomplete run)
- `raw/build/` — xOne build logs, attempt 1 (libclang failure) and attempt 2 (success)
- `raw/xone-genesis-refusals/` — the two refused xOne starts (issues 2 and 3)
- `raw/sealer-crash-evidence.txt` — corruption lines from the 4 sealers after the crash
- `scripts/` — bench2.sh, analyze.py, patchgen.py, run-both.sh, guard.sh, check-sealers.sh, wipe-20119.sh
- `genesis-20119-xone.json` — the patched genesis copy xOne used
