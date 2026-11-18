# EIP Implementation Status — XDC Go-Ethereum Reference

**Audit snapshot:** 17 November 2026  
**Codebase:** `/home/tanmay/xdc-fix-work/go-ethereum`  
**Reported baseline:** `48a77271314293cdf057bc05d2c1624c3645a4d0`

> This document describes the six EIP worktrees in the XDC Go-Ethereum reference area. It does not claim that the changes are integrated into one release branch, deployed, activated, or implemented in the five target clients.

## 1. Summary

| EIP | Reference worktree | Reported implementation status | Test evidence reported |
|---|---|---|---|
| 8141 | `frame-tx-8141` | Implementation work reported complete | 49+ tests |
| 8250 | `frame-tx-8250` | Implementation work reported complete | 31 new tests; 8141 suite retained |
| 8272 | `eip-8272-recent-roots` | Implementation work reported complete | 41 top-level test functions |
| 7906 | `eip-7906-assertions` | Implementation work reported complete | 25 core tests plus 9 type subtests; about 98 in-EVM assertions |
| 8151 | `eip-8151-ecrecover` | Implementation work reported complete | 6 VM tests (28 subtests) and 1 block-level test (5 subtests) |
| 8298 | `eip-8298-setcodefrom` | Implementation work reported complete | 35 test functions |

The counts above are reported worktree audit counts. They should be reproduced from the actual worktrees and test logs before being used as release certification.

## 2. EIP-8141 — Frame Transactions

**Worktree:** `frame-tx-8141`  
**Branch:** `feat/eip-8141-frame-transactions`  
**Baseline:** `48a7727`

Reported implementation milestones M1–M10 were completed between 28 and 29 October 2026. The work included:
- transaction type and signer support;
- frame execution engine and settlement;
- seven frame-related opcodes;
- receipt consensus/storage/wire/RPC handling;
- transaction-pool admission;
- eth/69 wire compatibility fix;
- activation design decisions D1–D4;
- M10 independent audit and four reported fixes:
  - VERIFY-to-precompile dispatch ordering;
  - EIP-7594 blob cap handling;
  - pool reservation using the maximum of relevant floor values;
  - overflow-safe fee arithmetic.

Reported targeted tests: 49+.

**Important follow-up:** the later cross-client vector run found a G1 atomic-batch terminator issue. The fix was reported in the cross-client validation worktree and patch, not yet confirmed applied to the completed 8141 worktree. Therefore the worktree's final state needs reconciliation before it is treated as the exact final reference.

## 3. EIP-8250 — Keyed Nonces

**Worktree:** `frame-tx-8250`  
**Branch:** `feat/eip-8250-keyed-nonces`  
**Base:** `48a7727` plus the reported EIP-8141 M10 patch.

Reported implementation items:
- dual-form payload decoding;
- consume-on-APPROVE behavior;
- keyed nonce state gas;
- BAL integration;
- TXPARAM selectors `0x0D`–`0x10`;
- hard Bogota fork gate;
- keyed transaction-pool side-pool.

Reported tests: 31 new tests (16 engine, 8 types, 7 pool); the 49 EIP-8141 tests were reported unchanged. A 26-row normative matrix was also reported.

**Important follow-up:** the same G1 atomic-batch terminator fix was reported in the cross-client validation worktree. Confirm whether the fix has been reviewed and applied to this worktree.

## 4. EIP-8272 — Recent Roots

**Worktree:** `eip-8272-recent-roots`  
**Branch:** `feat/eip-8272-recent-roots`

Reported implementation items:
- constants, bytecode and derivations;
- deployment sheet and address verification;
- exact reproduction of a reference vector;
- canonical VERIFY recognition;
- transaction-pool grammar and stateful admission;
- dependency tracking, reorg handling and slot advancement;
- activation-flip eviction;
- miner pre-inclusion handling;
- permission tracer.

Reported deployment address:
`0x8272D9679689Ea2f307140CdF9002D27dC00Ffff`

Reported deployment transaction hash prefix/suffix:
`0x56c2adbb…e5875272`

Reported tests: 41 top-level test functions, including core, types, transaction-pool and legacy-pool coverage.

## 5. EIP-7906 — Transaction Assertions

**Worktree:** `eip-7906-assertions`  
**Branch:** `feat/eip-7906-tx-assertions`

Reported implementation items:
- ASSERT frame mode 3;
- TXTRACE opcode `0xb6`;
- EVENTDATACOPY opcode `0xb7`;
- lazy transaction state-diff derivation from the journal;
- assertion-failure semantics;
- BAL interactions.

The possible EIP-8253 storage-wipe edge was considered and deliberately omitted from the implementation scope. APPROVE was reported as prohibited in ASSERT mode.

Reported tests: 25 core tests (13 subtests), 9 types subtests and approximately 98 in-EVM assertions.

## 6. EIP-8151 — Restricted ecRecover

**Worktree:** `eip-8151-ecrecover`  
**Branch:** `feat/eip-8151-account-code-ecrecover`  
**Base:** pure `48a7727` baseline.

Reported implementation items:
- stateful precompile dispatch;
- cold/warm access gas behavior;
- raw-code and exact-delegation checks;
- BAL read discipline.

Reported gas totals: 6100 cold and 3200 warm, including a 3000 base component.

Reported tests: 6 VM tests (28 subtests) and 1 block-level test (5 subtests).

## 7. EIP-8298 — SETCODEFROM

**Worktree:** `eip-8298-setcodefrom`  
**Branch:** `feat/eip-8298-setcodefrom`

Reported implementation items:
- opcode `0xA7`;
- staged in-handler charging;
- hash-only code adoption using `SetCodeHashReference` and journal handling;
- CREATE/CREATE2 code-deposit skip behavior;
- BAL three-element `CodeChange`;
- regenerated codec;
- transaction-pool eviction behavior;
- EIP-8151 migration-arc test.

Reported canonical base tree:
`c77ff3c11c6a679781fe1dcb1bb37589ac377334`

Reported tests: 35 test functions.

## 8. Worktree and integration status

The audit described the EIP work as staged in separate worktrees, not as one integrated and committed release. The reference repository itself was reported with no configured remote. The worktrees and patch checkpoints are therefore the evidence of implementation progress; they are not a published XDC client release.

Before an integrated release:
1. reconcile the G1 terminator fix into the appropriate 8141/8250 source worktrees;
2. re-run all six EIP test suites from clean worktrees;
3. run a full integrated build and test set;
4. verify the exact frozen specification snapshots;
5. review cross-EIP interactions and activation configuration;
6. publish commit hashes, patch hashes and reproducible logs.
