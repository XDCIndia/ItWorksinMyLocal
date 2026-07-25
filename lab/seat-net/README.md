# seat-net — the runtime-propose seating playbook

Reusable tooling to onboard a client onto a **live** XDPoS net as a masternode
candidate, watch it seat at the correct epoch checkpoint, and prove — or
disprove — that it is producing in fair share, without ever faking a result or
disturbing the incumbents. Extracted from the netv12 seating program
(ItWorksinMyLocal, XDCIndia org).

## The governing rule

**Prove production capability FIRST, seat SECOND.**

This is the one lesson every script here encodes. It comes from erigon's own
history on this net: erigon minted a block, but a pair of defects meant it
never adopted the canonical, M2-co-signed twin of that block as its own head.
`header.Validator` (the M2 co-signer field) is inside `Header.Hash()` but
**outside** `sigHash()` — so a byte-identical block, once co-signed, has a
**different hash** from erigon's own seal-only version of it. Without the fix,
erigon kept its private version as head, drifted onto a fork, signed nothing
while stranded, and was **penalised out of the masternode set** for it. Its
dead slot degraded the live net for every epoch it occupied before that
happened.

The two fixes that closed this (merged upstream, erigon-xdc **#365** — m2
`Validator`-field co-signing — and **#366** — adopt the co-signed twin as
head) are why erigon is seated and minting in fair share on netv12 today
(16.4–16.6% of blocks vs. a 16.7% ideal at N=6, sustained over 300+ blocks with
zero drop-outs). Any client being seated under this playbook needs the
equivalent class of fix **proven in an offline Phase 0 net first** — never on
the live net, never as the first attempt.

## The seating arithmetic

A candidate seats at the next epoch-multiple checkpoint `C` only if its
`propose()` transaction is **mined at a height strictly below the gap block
`C - GAP`** — the epoch-`C` masternode set is elected from the `0x88` XDCValidator
contract's state as of the gap block, not as of `C` itself. Worked from a real
netv12 tip of 5862 (epoch=900, gap=450):

| Checkpoint C | Gap block C-450 | Usable from tip 5862? |
|---|---|---|
| 6300 | 5850 | **NO — already passed** |
| 7200 | 6750 | YES (~888 blocks / ~30 min at 2s/block) |
| 8100 | 7650 | YES |
| 9000 | 8550 | YES |

`seat-window.sh` computes this table from the **live** tip every time it is
run — never trust a stale table, always recompute. It also enforces a
**safety margin** (default 100 blocks, ~3.5 minutes at a 2s period) between
the propose receipt and the gap block: never aim at the last few blocks of a
window.

## Mint-evidence traps (verbatim — memorize these)

- **Never a log line as mint evidence.** A non-seated follower with no signer
  key emitted 685 instances of `"winning self-mined block canonized as head"`
  for ordinary network-imported blocks. A log line proves nothing about
  canonical attribution.
- **Never compare a client's MINTED hash to the canonical hash.** This
  comparison always reads "lost" for a client that co-signs correctly — the
  M2-co-signed twin of a byte-identical block has a different hash by
  construction (see above). A "lost" comparison is not evidence of failure.
- **Never use `block.miner` / coinbase for attribution on XDPoS V1.** V1 is
  Clique-derived and deliberately zeroes Coinbase; the real signer is
  recovered by ecrecovering the seal in `extraData`. Canonical attribution
  uses `Engine().Author` (equivalent to this toolset's `signer_of()`), never
  the raw RPC field.
- **A `SkipV1Validation: false` log hit is proof validation is ON, not a
  bypass.** Do not treat the presence of this string as suspicious; its
  *absence when it should be there*, or an explicit `true`, is the actual
  red flag.

The only admissible attribution method (implemented in `gate-mint.sh` /
`measure-share.py`): ecrecover the seal from **canonical** blocks via **>=2
legacy arbiters + one independent observer**; the candidate's **own head is
inadmissible** (enforced in code — `gate-mint.sh` refuses to run if
`RPC_ARBITERS` or `RPC_OBSERVER` contains `RPC_CANDIDATE`). Require hash
agreement at H, canonical depth >= 3, `assert_no_validation_bypass` clean, and
`SkipV1Validation` confirmed false.

## The abort decision table

| # | Symptom | Action |
|---|---|---|
| 1 | Phase 0 offline proof fails any check (esp. "own head != canonical head after minting") | **Do not enter Phase 1.** Not-ready; fix code, re-prove offline. No live-net attempt. |
| 2 | `propose` receipt lands at height >= gap block `C-GAP` | Not an abort. Not seated at C. Leave the net alone, recompute for `C+EPOCH`, keep it a follower. |
| 3 | At checkpoint C, `MasternodesLen` did not grow N->N+1 | Not an abort. Propose missed the window or KYC/deposit failed. Verify `isCandidate` + `eth_getCandidates`, stay a follower, re-plan. |
| 4 | Set grew to N+1 but the new client seals nothing for > 3x the set size in blocks | **ABORT**: `abort.sh` (SIGTERM by port). Dead slot degrading block time. Diagnose offline. |
| 5 | New client mints, but its own head diverges from canonical (the #1347 signature) | **ABORT IMMEDIATELY** — the erigon strand-and-get-penalised path. `abort.sh` before it drifts further. |
| 6 | Legacy validators log `invalid merkle root` / header verification failure on the new client's blocks | **ABORT**: `abort.sh`. State-root or fee-credit divergence (the xone #691 class). Fix offline. |
| 7 | Block time degrades beyond ~2.6s sustained (from block timestamps) | **ABORT** the new client first — it's the only new variable. Re-measure. |
| 8 | `PenaltyLen` non-zero and contains the NEW client | **ABORT**: `abort.sh`. It stranded. Do not re-seat until fixed and re-proven in Phase 0. |
| 9 | `PenaltyLen` non-zero and contains an INCUMBENT, or erigon's share drops below 14% | **ABORT the new client immediately** (it's the only change). Never touch erigon or the validators. Then REPORT. |
| 10 | Validators disagree on the hash at any height (fork) | **FREEZE**: `freeze.sh` (miner_stop on arbiters), then REPORT. No recovery spiral. |
| 11 | Chain halts (no new block for > 60s) | **FREEZE** + REPORT. Do not restart, wipe, or SIGKILL. |
| 12 | A validator or an already-minting client looks unhealthy | **Do nothing to it.** REPORT and escalate to the user. Never SIGKILL a valid validator. |
| 13 | Tempted to use a validation bypass, forced canonization, self-certification, or a clock change to make a gate pass | **STOP. Task failure.** Report the honest negative result. |

`watch-checkpoint.sh` prints the matching row number in its verdict line.

## The binary-fingerprint check, and why it exists

On netv12, the at-tip "xone" process running on port 37486 was the **63 MB
ethcompat build** (a geth-fork consensus binary pinned via a `replace`
directive that had drifted **900 commits stale**), while a separate **39 MB
native build** of the same client could not even verify past block 900. Two
binaries, same client name, wildly different consensus behavior. Never assume
the process listening on the port you expect is the binary you just fixed —
`preflight.sh` requires an `EXPECTED_BINARY_FINGERPRINT` (a sha256, proven in
Phase 0) and refuses to auto-pass without one; it prints
`readlink -f /proc/<pid>/exe`, size, and mtime so the operator can compare by
hand the first time.

## Files

| file | phase | what it does |
|---|---|---|
| `seat.env.sample` | — | every parameter, documented, **zero hardcoded keys/addresses/ports/chain IDs**. Copy to `seat.env` (gitignored). |
| `seat-window.sh` | 2 | pure arithmetic: next K checkpoints from the **live** tip, gap block, usable/closed. No side effects. |
| `preflight.sh` | 1 | tip-lag-0, hash agreement at reached checkpoints, no-validation-bypass, `SkipV1Validation=false`, binary fingerprint, baseline share snapshot. |
| `onboard-candidate.sh` | 2 | wraps `onboard-net/onboard.py`'s owner!=coinbase split: picks `C` via `seat-window.sh`, sends `uploadKYC`+`propose`, verifies `isCandidate`+`eth_getCandidates`, asserts the receipt landed before the safety margin. |
| `relaunch-producer.sh` | 3 | SIGTERM the follower **by port** (never a pgrep-on-datadir pattern), bounded wait, **no SIGKILL path anywhere**, re-exec with the family's producing flags. `PROTECTED_PORTS` refuses validators/erigon outright. |
| `watch-checkpoint.sh` | 4 | polls `C-30..C+60`: set size growth (RPC + extraData cross-check, V1 only — see caveat below), block time from timestamps, hash agreement, `PenaltyLen`. Prints a verdict + abort-table row. Read-only. |
| `gate-mint.sh` | 5 | the attribution gate: ecrecovers from arbiters+observer (candidate's own head **hard-refused** in code), hash agreement, canonical depth >=3, no-bypass, `SkipV1Validation=false`, fair-share + max-seal-gap. Refuses to verdict on a build-loaded box. |
| `measure-share.py` | 5 | the corrected per-signer distribution: parent-relative hop ordering (not `height % len(masternodes)` — that's the wrong slot ordering measure_share.py used), height-gated V1/V2 seal ecrecovery, max-seal-gap drop-out signal. |
| `abort.sh` | any | SIGTERM the NEW client only, by port, `PROTECTED_PORTS`-enforced. Prints what it did and deliberately did not touch. |
| `freeze.sh` | any | `miner_stop` on every arbiter for the halt/fork case. Terminal: freeze and report, no recovery spiral. |
| `docs/client-readiness.md` | — | living per-client verdict + blocker-issue table, so the next operator doesn't re-derive it. |

## Typical flow

```bash
cp seat.env.sample seat.env   # fill in, never commit
set -a; source seat.env; set +a

# Phase 0 happens OFFLINE, on a throwaway net -- not scripted here (see the
# 5551/5152-pattern devnets referenced in docs/client-readiness.md).

# Phase 1
./preflight.sh                       # must exit 0 before proceeding

# Phase 2
./seat-window.sh                     # see the live table, confirm your target C
./onboard-candidate.sh               # uploadKYC + propose, verified

# Phase 3 (only after Phase 2 confirms, before C arrives)
./relaunch-producer.sh

# Phase 4 (run through the checkpoint transition)
CAND=$CAND C=<chosen checkpoint> ./watch-checkpoint.sh

# Phase 5 (after >=2 epochs of canonical depth past C)
./gate-mint.sh
```

If anything goes wrong, consult the abort table above; `abort.sh` and
`freeze.sh` are the only two remediation actions this toolset performs, and
each refuses outright to touch a protected node.

## Known limitations (be honest about these)

- `XDPoS_getMasternodesByNumber(<height>)`'s accuracy for a height **far in
  the past** relative to the current tip is not reliable (verified live: it
  returned `MasternodesLen=0` for early V1 heights queried retroactively, and
  a stale 5-of-6 set for V2 heights queried long after the fact — even though
  the client in question had genuinely been part of the set by then). Run
  `watch-checkpoint.sh` **live**, as `C` approaches — not as forensic replay
  long after tip has moved past it.
- The V1-style `extraData` byte-decode (`32-byte vanity + 20*N + 65-byte
  seal`) is **only valid pre-V2-switch**. Verified live on netv12: a V2
  checkpoint's `extraData` carries additional variable-length HotStuff data,
  and naively applying the V1 formula there silently returns a plausible but
  **wrong** count (5 instead of the real 6, at checkpoint 1800). Past
  `V2SWITCH_BLOCK`, this toolset treats `XDPoS_getMasternodesByNumber` as
  authoritative and does not attempt an independent byte-decode.
- `diff=6`/`diff=5` in `measure-share.py`'s output are V1-only in-turn/
  out-of-turn signals; V2/HotStuff blocks are QC-based and typically carry a
  constant difficulty (verified: `0x1` on every netv12 V2 block sampled), so
  those two lines reading `0/N` in a fully-V2 window is expected, not a bug.

## Hard rules (a violation fails the task)

- Never fake a mint, a share number, or a test result.
- Never use a validation bypass (`skipV1Validation` or equivalent), forced
  canonization, self-certification, or clock manipulation.
- Never SIGKILL. SIGTERM only, and locate the pid **by port**
  (`ss -ltnp "sport = :PORT"`) — a `pgrep` pattern containing a datadir path
  can match the caller's own shell and kill the wrong process.
- Never disturb a seated/minting incumbent or a legacy validator.
- Never seat a client that cannot provably produce (Phase 0 first, always).
- Keys stay local (`OWNER_KEY_FILE` is a path, never a literal in any
  committed file); public block RLP/hashes in test fixtures are fine.
