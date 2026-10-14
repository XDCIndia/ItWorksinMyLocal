# Audit checklist -- geth v1.17.6-xdc.9

External audit findings (F-2026-19xxx) checked against the XDCIndia geth fork.

- **Target:** `~/x1/geth-1176-audit` = `origin/main` `d5b991899` = `v1.17.6-xdc.9`
- **Reference:** `~/XDPoSChain` `68b00c7e5` (canonical legacy client)
- **Checked:** 2026-10-13
- **Method:** code reading only (nothing built or run), except where "Proof" says **test**.
  Only finding *titles* were available, so "Matches title?" compares the code to the
  title, not to the auditor's full write-up.

All paths are relative to `~/x1/geth-1176-audit`. `engine_v2/` = `consensus/XDPoS/engines/engine_v2/`.

## Legend

| Column | Values |
|---|---|
| Matches title? | **Exact** = code does what the title says. **Narrower** = true, but only under a condition, or partly inherited. **Worse** = true and broader than the title. **No** = not as described |
| Origin | **Fork** = our geth only, canonical is correct. **Inherited** = canonical behaves the same. **Mixed** = part of each |
| Proof | **test** = proven by a test we ran. **code** = traced in code, not executed |
| Sev | audit severity / our severity |

## Summary

| Count | |
|---|---|
| 32 | findings (30 listed + 2 "under internal validation") |
| 17 | Exact |
| 10 | Narrower |
| 3 | Worse |
| 2 | No (1 already fixed, 1 claim wrong) |

## Fix first

- [ ] **F-2026-19525** one key = QC/TC (GB9)
- [ ] **F-2026-19466** epoch-switch superset validators
- [ ] **F-2026-19727** zero-price sign-tx dropped
- [ ] **F-2026-19636** full sync batch not linked to head
- [ ] **F-2026-19643** blacklist not applied on import
- [ ] **F-2026-19622** vote latch (GB10)
- [ ] **F-2026-19726** timeout stuck at round-0 period

---

## High

| Done | ID | Title | Sev | Matches title? | Origin | Proof |
|---|---|---|---|---|---|---|
| [ ] | F-2026-19525 | One Masternode Key Can Satisfy A Quorum Or Timeout Certificate | High / Critical | **Worse** | Fork | **test** |
| [ ] | F-2026-19727 | A Zero Price Signing Transaction Keeps That Account Out Of The Block | High / High | **Narrower** | Fork | code |
| [ ] | F-2026-19636 | Full Sync Canonizes A Header Batch That Does Not Extend The Local Head *(under internal validation)* | High / High | Exact | Fork | code |
| [ ] | F-2026-19601 | V2 Proposer Seal Omits Header Fields That Change The Block Hash *(under internal validation)* | High / Med | Exact | Fork | code |

**F-2026-19525** -- `engine_v2/utils.go:199` (verifyQC) and `engine_v2/timeout.go:352` (verifyTC) call
`UniqueSignatures` (`utils.go:631`), which dedupes by signature bytes, not by signer. One key can
make many valid signatures (different nonces) and fill any threshold.
*Worse than title:* the local vote pool (`vote.go:272`) and timeout pool (`timeout.go:134-150`) have the
same flaw, and `a98_dedup_test.go:76` asserts the buggy behaviour. Canonical dedupes by recovered
address (`RecoverUniqueSigners`). Same as backlog GB9.
*Fix exists, NOT merged:* commit `381717dd4` (2026-07-07, "dedup QC/TC signatures by address, reject
high-S (#1074)") on `origin/fix/1074-qctc-address-dedup` routes verifyQC/verifyTC through
`RecoverUniqueSigners` + low-S check, with tests (`a99_qctc_malleability_test.go`). It is not an ancestor
of `origin/main`; v1.17.6 still calls `UniqueSignatures` at `utils.go:199` / `timeout.go:352`. Branch is
based on xdc.7 (`c9df0c0ee`), so it needs a rebase. The A.98 comment at `utils.go:192-198` claiming
canonical dedupes by bytes is wrong. The fix does not cover the local vote/timeout pools.
*Release history:* every tagged release is vulnerable -- v1.17.3-xdc.1, v1.17.4-xdc.1..7, v1.17.5-xdc.8
(`f39bb0769`) and v1.17.6-xdc.9 all use `UniqueSignatures`. Address dedupe was on the main line only
2026-05-23 (`c40a66f70`, B5) to 2026-06-11, when A.98 (`3865710d7`) switched it to byte dedupe; never tagged.

**F-2026-19727** -- signing txs are built with gasPrice 0 (`contracts/utils.go:239`). The miner uses the
upstream price heap (`core/txpool/txorder/ordering.go:42-43,110-113`), which drops a tx below the base
fee *and the rest of that account*. Canonical commits special txs first, outside the heap
(`miner/worker.go:943-1012`).
*Narrower:* only once the fee market is active (mainnet 98,800,200 / Apothem 71,550,000).
Confirm with: a geth-minted block after that height with no 0x89 txs.

**F-2026-19636** -- `eth/sync_xdc.go:2219 -> 2300 -> 2354`: headers from the fastest peer go straight into
`InsertChain`. No check that `headers[0].ParentHash == head`. `writeBlockAndSetHead` then reorgs
(`core/blockchain.go:1978-1981`). A malicious peer can force reorgs; on V1 heights in bulk mode the
branch can be forged outright (see extra E1).

**F-2026-19601** -- V2 seal hash (`engine_v2/engine.go:246-271`) does not cover `WithdrawalsHash`,
`BlobGasUsed`, `ExcessBlobGas`, `ParentBeaconRoot`, `RequestsHash`, but `Header.Hash()` does, and nothing
requires them to be nil. Anyone can make a different-hash twin of a sealed block.
*Our severity Med:* no authority is forged and execution can't change. Separate, inherited:
high-s signature malleability gives another twin.

## Medium

| Done | ID | Title | Sev | Matches title? | Origin | Proof |
|---|---|---|---|---|---|---|
| [ ] | F-2026-19466 | Epoch Switch Full Verification Trusts Header Validators When They Are A Superset Of The Local Set | Med / Med-High | Exact | Fork | code |
| [ ] | F-2026-19468 | Epoch Switch Full Verification Trusts Header Fields When The V2 Snapshot Is Missing | Med / Med | **Worse** | Fork | code |
| [ ] | F-2026-19463 | Snapshot Heal Imports New V2 Headers Without Leader Turn Enforcement | Med / Med | Exact | Fork | code |
| [ ] | F-2026-19622 | A Vote That Completes A Certificate Latches The Next Round | Med / Med | Exact | Fork | **test** |
| [ ] | F-2026-19726 | Round Timeout Uses The Round Zero Period | Med / Med | Exact | Fork | code |
| [ ] | F-2026-19643 | Block Import Does Not Apply The Address Blacklist | Med / Med-High | Exact | Fork | code |
| [ ] | F-2026-19723 | Bulk Sync Canonizes A Block Whose State Root Does Not Match Execution | Med / Med | Exact | Fork | code |
| [ ] | F-2026-19460 | Verified BFT Forwarding Can Exhaust Node Through Unbounded Goroutines | Med / Med | Exact | Fork | code |
| [ ] | F-2026-19457 | Destination Only Special Transactions Skip The Tip Check And The Slot Cap | Med / Med | **Narrower** | Mixed | code |
| [ ] | F-2026-19458 | A Compiled Ethstats Secret Authenticates Default Node Reporting | Med / Low-Med | Exact | Fork | code |
| [ ] | F-2026-19608 | Header Verification Accepts A Future Round With No Timeout Certificate | Med / Low | **Narrower** | Inherited | code |
| [ ] | F-2026-19609 | The Vote Lock Is The Parent Certificate, So A Certified Block Is Not Locked | Med / Info | **Narrower** | Inherited | code |

**F-2026-19466** -- `engine_v2/verifyHeader.go:264-280`: if the header lists a superset of our masternodes,
`masterNodes = validatorsAddress` -- *even with fullVerify on*. The sealer of an epoch-switch block can
add addresses it controls to the next set (possible >2/3 takeover). Canonical requires an exact match
(`ErrValidatorsNotLegit`). Worst finding that hits a healthy node.

**F-2026-19468** -- `engine_v2/verifyHeader.go:171-186`: missing snapshot is non-fatal; masternodes are
then read from the header being verified, so the compare at `:216` checks the header against itself.
*Worse than title:* even a non-masternode can pass. Only right after checkpoint / no-state recovery.

**F-2026-19463** -- `engine_v2/verifyHeader.go:378-390`: leader mismatch only warns when `!fullVerify`.
`CheckpointSyncNoStateActive` is persisted and cleared only by snap heal, which is off by default
(`XDC_SNAP_HEAL`), so fast-synced nodes can stay in this mode at the tip.

**F-2026-19622** -- `engine_v2/vote.go:208` runs the vote handler (which can reach QC and `setNewRound(R+1)`)
*before* `highestVotedRound = currentRound` at `:223`, so R+1 is latched and the node skips its next vote.
Canonical latches first. Regression from b342d028d (#1330). Same as GB10.

**F-2026-19726** -- timer is built from `AllConfigs[0]` (`engine_v2/engine.go:146,156`). `UpdateParams`
(`:217-229`) is never called. Mainnet: geth 30s vs canonical 60s from round 17,579,700.
Canonical calls it each checkpoint (`cmd/XDC/main.go:374`).
*Check:* could relate to GB5 (unexplained block gaps).

**F-2026-19643** -- `common.IsInBlacklist` only called in `core/txpool/legacypool/legacypool.go:622,625`.
Missing in `core/state_processor.go` (canonical `:96-104, 176-184`) and in the miner (canonical
`miner/worker.go:953,958,1063,1069`). A block canonical rejects, geth accepts -> chain split.

**F-2026-19723** -- `core/blockchain.go:2589-2598`: on state-root mismatch in bulk mode, sets
`CheckpointSyncNoState`, persists it (`:618-621`), and canonizes. All later blocks skip execution;
only a full resync recovers.

**F-2026-19460** -- `eth/bft/handler.go:152,187,221` spawn `go func(){ b.broadcastCh <- vote }()` per
verified message; no seen-message cache in the fork. Canonical has `knownVotes/knownTimeouts/knownSyncInfos`
LRUs and a blocking send. Any peer can replay public votes.

**F-2026-19457** -- `core/types/transaction.go:712-719` decides "special" by destination only.
Slot-cap skip at `legacypool.go:930-931` is fork-only; tip skip is inherited.
*Narrower:* half is inherited from canonical.

**F-2026-19458** -- `cmd/utils/flags.go:2472-2473` hardcodes `stats.xdcindia.com:443` /
`xdc_openscan_stats_2026`; `cmd/geth/config.go:296-309` registers ethstats on every XDPoS node; reported
name includes public IP from `ipinfo.io` (`flags.go:2477`). No opt-out flag. Mainly a privacy leak.

**F-2026-19608** -- `engine_v2/verifyHeader.go:101` only checks `round > qcRound`.
*Narrower:* identical in canonical, and honest nodes won't vote (`vote.go:330`), so the block is orphaned.

**F-2026-19609** -- `engine_v2/utils.go:349` locks on the certified block's parent QC.
*Narrower:* this is the normal chained-HotStuff 2-chain lock, identical in canonical. Not a bug.
Side note: geth's `processQC` returns nil on a missing header (`:333-339`); canonical errors.

## Low

| Done | ID | Title | Sev | Matches title? | Origin | Proof |
|---|---|---|---|---|---|---|
| [ ] | F-2026-19602 | V1 Checkpoint Extra Replaces The Signer Set And Authorizes That Sealer | Low / Low-Med | **Worse** | Fork | code |
| [ ] | F-2026-19462 | V1 Checkpoint Validator Verification Never Rejects Populated Validators Field | Low / Low | Exact | Fork | code |
| [ ] | F-2026-19614 | V1 Full Seal Logs The M2 Co-Sign And Does Not Reject It | Low / Low | Exact | Fork | code |
| [ ] | F-2026-19621 | V1 Checkpoint Penalties Are Outside The Seal And Never Checked | Low / Low | **Narrower** | Mixed | code |
| [ ] | F-2026-19641 | NewBlock Imports A V1 Extension Without Recovering The Seal | Low / Low | **Narrower** | Fork | code |
| [ ] | F-2026-19640 | A Sealed Sign-Slot Block Submits A Second Signing Transaction | Low / Low | **Narrower** | Fork | code |
| [ ] | F-2026-19642 | Bulk Sync Accepts A V2 Block Dated In The Future | Low / Low | **Narrower** | Mixed | code |
| [ ] | F-2026-19724 | A Non-Mainnet Insert Error Clears Bulk Sync Away From The Tip | Low / Low | Exact | Fork | code |
| [ ] | F-2026-19469 | Quorum Certificate Forensics Is Never Invoked After processQC | Low / Low | Exact | Fork | code |
| [ ] | F-2026-19596 | Timeout Certificates Count Penalized Signers Toward The Active Set Quorum | Low / Low | Exact | Inherited | code |
| [ ] | F-2026-19612 | Timeout Gap Number Selects The Signer Set Independently Of The Round Epoch | Low / Low | Exact | Inherited | code |
| [ ] | F-2026-19467 | Block Gas Accounting Does Not Bound BlockSigners Transactions | Low / Low | **Narrower** | Mixed | code |
| [ ] | F-2026-19459 | Empty Transaction Dispatch Imports Unsigned TradingState Payloads Without Nonce | Low / Info | **Narrower** | Inherited | code |
| [x] | F-2026-19644 | Apothem Protector Rewards Use Stake From The Payout Block | Low / -- | **No** (already fixed) | -- | code |

Note: in the fork, `engine_v1/engine.go` is **dead code**. The live V1 path is `consensus/XDPoS/xdpos.go`
plus `eth/hooks/hooks.go`. Fix V1 findings there.

**F-2026-19602** -- `xdpos.go:931-961` overwrites the parent snapshot's signers with the checkpoint's own
list; `verifySeal` then reads that list. Any key can seal a checkpoint naming itself.
*Worse than title:* also writes the forged list into `checkpointCache[n]` (`xdpos.go:1773`), keyed by
number only, which can poison the canonical chain. Canonical rejects (`ErrInvalidCheckpointSigners`).

**F-2026-19462** -- `eth/hooks/hooks.go:69-91` only logs on mismatch, and `HookValidator` (`:52-55`) returns
the header's own field, so it can never mismatch. Canonical returns `ErrInvalidCheckpointValidators`.

**F-2026-19614** -- `xdpos.go:1065-1084`: every M2 mismatch is `log.Warn` + `return nil`. Canonical returns
`ErrFailedDoubleValidation` (mainnet only; canonical skips it on testnets).

**F-2026-19621** -- penalties not in the seal (`xdpos.go:200-245`) is inherited; not checking them
(`xdpos.go:867-893`, `errInvalidCheckpointPenalties` declared at `:146`, never returned) is fork-only.

**F-2026-19641** -- `eth/handler_eth.go:185-271` -> `InsertChain` -> `verifyHeaderLightV1` (`xdpos.go:586-680`),
which has no ecrecover. *Narrower:* only while bulk sync / no-state is on; at the tip the seal is checked.

**F-2026-19640** -- `miner/xdpos_worker.go:839` signs our own block, then the chain-head hook (`:237-239`,
`:958-993`) signs it again with nonce+1. *Narrower:* V2-era blocks only; wastes space, no reward gain.

**F-2026-19642** -- `engine_v2/verifyHeader.go:46-50`: future-time check only when `fullVerify`.
*Narrower:* canonical has the same gate but applies it to every InsertChain block; ours skips it whenever
the global switch is off.

**F-2026-19724** -- `eth/sync_xdc.go:2205,2369-2376`: `fromBlock` is local head + 1, so the "near tip" guard is
always true; one bad block at head+1 turns bulk mode off on non-mainnet until restart.

**F-2026-19469** -- `ForensicsMonitoring` / `ProcessVoteEquivocation` (`engine_v2/forensics.go:48,401`) are never
called. Canonical calls them at the end of `commitBlocks`. Loss of detection, not safety.

**F-2026-19596** -- `engine_v2/timeout.go:339` checks members against the full candidate pool; threshold uses
the active count. Same in canonical.

**F-2026-19612** -- `engine_v2/timeout.go:323` takes the signer set from the TC's `GapNumber`; threshold from the
round (`:357`). Same in canonical; geth also falls back to the head epoch (`:358-366`).

**F-2026-19467** -- 0x89 txs use zero gas (`core/state_processor.go:714-758`, inherited). Fork miner lacks
canonical's `len(data)>=68` and block-window filter (`miner/worker.go:996-1003`).

**F-2026-19459** -- `core/state_processor.go:770-806` `ApplyEmptyTransaction`, no sender/nonce. Identical in
canonical. *Narrower:* only the historical window, closed at 80,370,900 (mainnet) / 66,825,000 (Apothem).

**F-2026-19644** -- fixed by `e0354d66b` (v2.9.1 parity, #2612): `eth/hooks/engine_v2_hooks.go:855-859` now uses
`GetStandbynodes` at the gap snapshot.

## Informational

| Done | ID | Title | Sev | Matches title? | Origin | Proof |
|---|---|---|---|---|---|---|
| [ ] | F-2026-19471 | FastSync Auto Pin Trusts Compiled Checkpoints Without Quorum Verification | Info / Info | Exact | Fork | code |
| [x] | F-2026-19725 | Protector Ranking Uses A Stable Sort On Equal Stake | Info / -- | **No** (claim wrong) | Same as canonical | code |

**F-2026-19471** -- `eth/ethconfig/auto_pivot_xdc.go:72-82` pins the newest compiled checkpoint without
verifying a QC. Trust root is the release binary / genesis config; no remote attacker.

**F-2026-19725** -- sorting uses `xdc_sort.Slice` (unstable quicksort) at `engine_v2/engine.go:1241,1330,1949`,
the same as canonical. Order on ties must match canonical for consensus, so do not change it alone.

---

## Extra issues found (not in the audit)

| Done | ID | Issue | Evidence | Proof |
|---|---|---|---|---|
| [ ] | E1 | V1 bulk-sync path skips the seal check entirely, so any peer can forge V1-era headers. This is what makes 19723 / 19636 / 19641 reachable by a plain peer | `consensus/XDPoS/xdpos.go:527,549-550` | code |
| [ ] | E2 | Forged V1 checkpoint poisons `checkpointCache`, keyed by number only | `xdpos.go:1773,1783-1788` | code |
| [ ] | E3 | Fork does not route 0x91 / 0x94 txs to `ApplyEmptyTransaction` like canonical; full sync from genesis may diverge if any exist in the window | canonical `core/state_processor.go:236-241` | code (medium confidence) |
| [ ] | E4 | `processQC` returns nil on a missing proposed header without advancing the round; canonical errors | `engine_v2/utils.go:333-339` | code |
| [ ] | E5 | Data race in `eth/sync_xdc.go:450` (peer map ranged without lock) still present in 1.17.6; six more unlocked ranges at 543, 737, 753, 1476, 2028, 2897 | backlog GB4 | crash observed |

## Tests to write (would turn "code" into "test")

- [ ] 19466: `calcMasternodes` returns N, header lists N+1, `fullVerify=true` -> expect no error today
- [ ] 19727: miner with base fee set and a 0-price 0x89 tx -> expect tx missing from block today
- [ ] 19636: answer a header request with a sibling branch from head-5 -> expect reorg today
- [ ] 19643: import a block with a blacklisted sender past `BlackListHFNumber` -> expect accepted today
- [ ] 19726: `timeoutWorker` duration after a round past 17,579,700 -> expect 30s today
- [ ] 19601: seal a V2 header, set `WithdrawalsHash`, verify -> expect pass with a new hash
- [ ] 19468: delete gap snapshot, non-masternode signs epoch-switch header listing itself -> expect pass

---

## Existing GitHub issues (checked 2026-10-13 against all 906 issues and PRs)

Note: on 2026-10-13 (09:39-11:33 UTC) 229 issues were closed as *not planned*, with no comment. The repo has 0 open issues after that.

| Group | Findings | Existing issue / PR |
|---|---|---|
| Already reported, closed *not planned* today, still unfixed | F-19525 | #1074 (FLAW-052), PR #1302 open (certificates only) |
| | F-19726 | #1312 |
| | F-19460 | #273 (dedupe LRU half only) |
| | F-19640 | #1243 |
| | E5 | #1069 (FLAW-042), #1228 |
| Reported before, earlier fix did not cover this part | F-19643 | #484 / #292, PR #342 (txpool only) |
| | F-19622 | #1330 (its fix b342d028d caused this regression) |
| | F-19469 | #483, PR #327 (stubs removed, never called) |
| | F-19471 | #1011 / #1029, PRs #1012 / #1033 open |
| | E4 | PR #1321 open (processQC round advance) |
| No new issue needed | F-19644 (fixed by #1393), F-19725 (not reproduced), F-19609 (by design) | |
| Never reported (24) | F-19727, 19636, 19601, 19466, 19468, 19463, 19723, 19457, 19458, 19608, 19602, 19462, 19614, 19621, 19641, 19642, 19724, 19596, 19612, 19467, 19459, E1, E2, E3 | none (19463/19723/19724 relate to #1294 / #1333) |

### Filed on GitHub 2026-10-13 (account Ike-weber, 11-section format)

- **New:** F-19466 #1404, E1 #1405, E2 #1406, E3 #1407, E4 #1408, F-19457 #1409, F-19458 #1410, F-19459 #1411,
  F-19462 #1412, F-19463 #1413, F-19467 #1414, F-19468 #1415, F-19596 #1416, F-19601 #1417, F-19602 #1418,
  F-19608 #1419, F-19612 #1420, F-19614 #1421, F-19621 #1422, F-19636 #1423, F-19641 #1424, F-19642 #1425,
  F-19723 #1426, F-19724 #1427, F-19727 #1428
- **Reopened + comment:** F-19525 #1074, F-19726 #1312, F-19460 #273, F-19640 #1243, E5 #1069, F-19643 #484,
  F-19622 #1330, F-19469 #483, F-19471 #1029
- **Reopened as fix record:** F-19644 #1393 (fixed by e0354d66b / PR #1396; close after review)
- **Not filed:** F-19725 (not reproduced), F-19609 (by design)
