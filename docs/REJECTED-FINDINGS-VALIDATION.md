# Rejected findings -- validation evidence

Two external audit findings were rejected for submission. This document records the
original claim, the code, the commands we ran, and the evidence for each decision.

- **Target:** `~/x1/hunt-main` = `origin/main` `39323acd4` = `v1.17.8-xdc.13`
- **Audited baseline:** `~/x1/geth-1176-audit` `d5b991899` = `v1.17.6-xdc.9`
- **Reference:** `~/x1/canon-4c0295a97` = XDPoSChain `v2.9.2-testnet`,
  `~/x1/canon-68b00c7e5` = `v2.7.1`
- **Checked:** 2026-10-14
- **Method:** code reading plus tests that we ran. Test output is copied as printed.
- **Test worktree:** `~/x1/hunt-test` (isolated; no production code was changed)

## Summary

| ID | Original severity | Decision | Basis | Proof |
|---|---|---|---|---|
| F-2026-19725 | Info | **Already fixed** (not a false positive) | The stable sort existed and was removed by `e0354d66b` on 2026-09-30 | test |
| F-2026-19609 | Medium | **Intended behavior** (inherited from canonical) | Fork and canonical are functionally identical; canonical documents the design | code |

> **One correction.** `docs/AUDIT-v1.17.6-CHECKLIST.md` records F-2026-19725 as
> "**No** (claim wrong)" and "not reproduced". **That verdict is wrong.** The audit
> described real code. The checklist examined `engine_v2/engine.go`, which never used
> a stable sort, and missed `eth/hooks/engine_v2_hooks.go`, which did. GitHub #1474
> ("already fixed by PR #1396") is the correct classification. Section 1 gives the
> evidence. The rejection decision does not change -- the finding still must not be
> filed as a new bug -- but the reason does.

---

## 1. F-2026-19725 -- Protector ranking uses a stable sort on equal stake

### 1.1 The original claim

From `docs/audit-issues/32-F-2026-19725.md` (severity Info):

- Ranking uses a stable sort on equal stake.
- Tie order must match canonical for consensus.

The local draft already disputed the premise: its **What** section says
"Ranking uses xdc_sort.Slice, an unstable quicksort."

### 1.2 What the code actually does

There are **two** stake-ranking paths. The checklist only looked at the first.

**Path A -- `consensus/XDPoS/engines/engine_v2/engine.go` (never stable).**
Uses `xdc_sort.Slice`, the frozen Go-1.18 quicksort, which is unstable. Present at the
audited baseline and on current main.

```
$ cd ~/x1/geth-1176-audit
$ git show d5b991899:consensus/XDPoS/engines/engine_v2/engine.go | \
    grep -n 'SortStableFunc\|SliceStable\|sort.Slice\|xdc_sort'
18:   xdc_sort "github.com/ethereum/go-ethereum/common/sort"
1241: xdc_sort.Slice(cs, func(i, j int) bool {
1330: xdc_sort.Slice(cs, func(i, j int) bool {
1949: xdc_sort.Slice(cs, func(i, j int) bool {
```

**Path B -- `eth/hooks/engine_v2_hooks.go` (was stable).**
`GetSigningTxCountTiered` built the protector and observer tiers from
`state.GetCandidates(parentState)` and ranked them with `slices.SortStableFunc`.
This is exactly what the audit described.

### 1.3 The fix, and when it landed

Commit `e0354d66b` -- *"params, consensus, core/vm, eth/hooks: port XDPoSChain
v2.9.1-testnet parity"*, AnilChinchawale, **2026-09-30**, PR #1396, port of
XDPoSChain #2612. It deleted the whole candidate-ranking block:

```
$ git show e0354d66b -- eth/hooks/engine_v2_hooks.go | grep -B9 -A3 'SortStableFunc'
-               candidates := state.GetCandidates(parentState)
-               var ms []utils.Masternode
-               for _, candidate := range candidates {
-                       if candidate != (common.Address{}) {
-                               v := state.GetCandidateCap(parentState, candidate)
-                               ms = append(ms, utils.Masternode{Address: candidate, Stake: v})
-                       }
-               }
-               slices.SortStableFunc(ms, func(a, b utils.Masternode) int {
-                       return b.Stake.Cmp(a.Stake)
-               })
```

The tiers now come from the epoch snapshot, which is already stake-sorted at the gap
block. The same commit added `engine_v2/standbynodes_test.go` (104 lines).

The audit report is dated **2026-10-13**, so the audited tree predates this fix.
That is why the finding is real but no longer present.

### 1.4 Validation steps and results

**Step 1 -- no stable sort remains in any XDC consensus or reward path.**

```
$ cd ~/x1/hunt-main
$ grep -rn 'SortStableFunc\|SliceStable' consensus/XDPoS eth/hooks --include=*.go \
    | grep -v _test | wc -l
0
$ grep -rn 'xdc_sort.Slice' consensus/XDPoS eth/hooks --include=*.go \
    | grep -v _test | wc -l
4
```

The three `SliceStable` uses that remain in the tree are upstream go-ethereum
(`eth/gasprice/feehistory.go`, `core/state_prefetcher.go`,
`core/txpool/blobpool/blobpool.go`) and are not on an XDC consensus path.

**Step 2 -- run the test that the fix commit added.**

```
$ cd ~/x1/hunt-test
$ go test ./consensus/XDPoS/engines/engine_v2/ -run 'Standby|Protector|Observer|Tier' -v
=== RUN   TestGetStandbynodes
=== RUN   TestGetStandbynodes/epoch_switch_on_an_epoch_boundary
=== RUN   TestGetStandbynodes/epoch_switch_on_a_gap-block_number_uses_the_previous_gap_block
=== RUN   TestGetStandbynodes/every_candidate_is_a_masternode
=== RUN   TestGetStandbynodes/missing_snapshot
--- PASS: TestGetStandbynodes (0.00s)
    --- PASS: TestGetStandbynodes/epoch_switch_on_an_epoch_boundary (0.00s)
    --- PASS: TestGetStandbynodes/epoch_switch_on_a_gap-block_number_uses_the_previous_gap_block (0.00s)
    --- PASS: TestGetStandbynodes/every_candidate_is_a_masternode (0.00s)
    --- PASS: TestGetStandbynodes/missing_snapshot (0.00s)
PASS
ok      github.com/ethereum/go-ethereum/consensus/XDPoS/engines/engine_v2  0.035s
```

**Step 3 -- both affected packages are green.**

```
$ go test ./consensus/XDPoS/engines/engine_v2/
ok      github.com/ethereum/go-ethereum/consensus/XDPoS/engines/engine_v2  0.598s
$ go test ./eth/hooks/
ok      github.com/ethereum/go-ethereum/eth/hooks  0.020s
```

### 1.5 Why this supports the decision

The finding described real code that existed when the audit ran. It was removed two
weeks before the report, by a commit whose purpose was canonical parity, and the
replacement path is covered by a passing test. Filing it as a new bug would report an
already-closed defect.

**Decision: do not file. Reason is "already fixed", not "false positive".**

### 1.6 Limitations

- The tie-order equivalence with canonical XDPoSChain is **not** proven by execution.
  We did not build a differential test that feeds equal-stake candidates to both
  clients and compares the resulting order.
- `TestGetStandbynodes` exercises the snapshot-derived tier path. It does not
  specifically assert behavior on equal stake.
- We did not confirm which exact tree the auditor read. The inference that it
  predates `e0354d66b` rests on the report date (2026-10-13) against the commit date
  (2026-09-30) and on the audited baseline tag `v1.17.6-xdc.9`.

---

## 2. F-2026-19609 -- The vote lock is the parent certificate

### 2.1 The original claim

From `docs/audit-issues/16-F-2026-19609.md` (severity Medium):

- `processQC` sets `lockQuorumCert` to the QC inside the certified block header.
- So the lock is on the parent of the certified block, not on the certified block.

The local draft already noted "We found no safety break."

### 2.2 What the code does -- fork

`consensus/XDPoS/engines/engine_v2/utils.go:342-350`:

```go
if proposedBlockHeader.Number.Cmp(x.config.V2.SwitchBlock) > 0 {
        proposedBlockQuorumCert, round, _, err := x.getExtraFields(chain, proposedBlockHeader)
        if err != nil {
                return err
        }
        if x.lockQuorumCert == nil || (proposedBlockQuorumCert != nil &&
            proposedBlockQuorumCert.ProposedBlockInfo.Round > x.lockQuorumCert.ProposedBlockInfo.Round) {
                x.lockQuorumCert = proposedBlockQuorumCert
        }
        // Commit blocks (3-chain rule)
        _, err = x.commitBlocks(chain, proposedBlockHeader, &round, incomingQuorumCert)
```

`getExtraFields` reads the QC carried **inside** the certified block's header. That QC
certifies the parent. So the lock is the parent certificate, exactly as the finding says.

### 2.3 What the code does -- canonical

`~/x1/canon-4c0295a97/consensus/XDPoS/engines/engine_v2/engine.go:1029-1038`:

```go
// 2. Get QC from header and update lockQuorumCert(lockQuorumCert is the parent of highestQC)
proposedBlockHeader := blockChainReader.GetHeaderByHash(incomingQuorumCert.ProposedBlockInfo.Hash)
...
if proposedBlockHeader.Number.Cmp(x.config.V2.SwitchBlock) > 0 {
        // Extra field contain parent information
        proposedBlockQuorumCert, round, _, err := x.getExtraFields(proposedBlockHeader)
        if err != nil {
                return err
        }
        if x.lockQuorumCert == nil ||
            proposedBlockQuorumCert.ProposedBlockInfo.Round > x.lockQuorumCert.ProposedBlockInfo.Round {
                x.lockQuorumCert = proposedBlockQuorumCert
        }
        proposedBlockRound := &round
        // 3. Update commit block info
        _, err = x.commitBlocks(blockChainReader, proposedBlockHeader, proposedBlockRound, incomingQuorumCert)
```

Three points decide the finding:

1. The two implementations are **functionally identical**: same source for the QC,
   same round-monotonicity guard, same assignment, same following `commitBlocks` call.
2. Canonical **documents the behavior as the design**, in its own comment:
   *"lockQuorumCert is the parent of highestQC"*, and *"Extra field contain parent
   information"*. This is not an accident that both clients share.
3. The structure is the standard chained-HotStuff arrangement: a **two-chain lock**
   with a **three-chain commit**. `commitBlocks` carries the commit rule.

Verified against `v2.7.1` (`68b00c7e5`) as well as `v2.9.2`; the assignment is the same.

### 2.4 Validation steps and results

```
$ grep -n 'lockQuorumCert' ~/x1/hunt-main/consensus/XDPoS/engines/engine_v2/utils.go
344:    proposedBlockQuorumCert, round, _, err := x.getExtraFields(chain, proposedBlockHeader)
348:    if x.lockQuorumCert == nil || (proposedBlockQuorumCert != nil && ...
349:            x.lockQuorumCert = proposedBlockQuorumCert

$ grep -rn 'lockQuorumCert *=' ~/x1/canon-4c0295a97/consensus/XDPoS/engines/engine_v2/*.go
.../engine.go:1036:   x.lockQuorumCert = proposedBlockQuorumCert

$ cd ~/x1/hunt-test && go test ./consensus/XDPoS/engines/engine_v2/
ok      github.com/ethereum/go-ethereum/consensus/XDPoS/engines/engine_v2  0.598s
```

**No new test was written for this finding, on purpose.** A test can show what the
fork does; it cannot show that the behavior is *intended*. The evidence that settles
the question is the line-for-line match with canonical plus canonical's own comment.
Writing a fork-only test would add no information.

### 2.5 The one real difference, which is a separate finding

On a missing proposed block header:

- Fork (`utils.go:333-339`): logs `log.Warn` and returns `nil`.
- Canonical (`engine.go:1032`): returns an error.

This is tracked separately as **E4** (`docs/audit-issues/37-E4.md`) and GitHub
**#1408**. It does not change the lock semantics and is not part of this finding.

The fork also adds a `proposedBlockQuorumCert != nil` guard that canonical lacks.
That makes the fork stricter, not weaker.

### 2.6 Why this supports the decision

The behavior is identical to canonical, is documented by canonical as intended, and
matches the published chained-HotStuff design. Changing it in this fork alone would
split the chain. The correct route for any change is upstream.

**Decision: do not file as a fork bug. Classify as intended behavior, inherited.**

### 2.7 Limitations

- Safety is argued from the structure, **not proven**. We did not model-check the
  two-chain lock / three-chain commit rule, and we did not run an adversarial
  devnet scenario that attempts a safety violation.
- The audit supplied only the finding title and short text to us. If the auditor's
  full write-up contains a concrete attack path, it was not available for this review
  and would need to be re-checked against it.
- We compared against `v2.7.1` and `v2.9.2`. Canonical now also tags
  `v2.9.3-testnet`, which we did not diff.

---

## 3. Where these findings are recorded

| Location | Entry | Action taken |
|---|---|---|
| `docs/audit-issues/00-tracking.md` | both, as unchecked submission items | **moved** to a "Not for submission" section with a pointer here |
| `docs/audit-issues/16-F-2026-19609.md` | prepared issue draft | kept, not deleted |
| `docs/audit-issues/32-F-2026-19725.md` | prepared issue draft | kept, not deleted |
| `docs/AUDIT-v1.17.6-CHECKLIST.md` | lines 103, 150, 226, 231, 274, 286 | left unchanged; the 19725 rationale is corrected here, in section 1 |
| GitHub #1468 (F-2026-19609) | **open** | not touched -- needs a decision, see below |
| GitHub #1474 (F-2026-19725) | closed, COMPLETED | already correct |
| GitHub #1430 tracker | both listed in the delta comment of 2026-10-14 | not touched |

### Open point for GitHub

Both findings were already filed on 2026-10-14, before this review.
**#1474 (19725) is closed as COMPLETED, which matches our conclusion.**
**#1468 (19609) is still open.** Its own body already records the verdict as
"CONFIRMED (inherited from canonical, protocol-level)". If the team accepts section 2,
#1468 should be closed as not-planned with a link here, in the same way #1419 was
closed for F-2026-19608. **No GitHub change has been made.**
