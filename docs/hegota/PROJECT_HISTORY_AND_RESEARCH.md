# Project History and XDC Compatibility Research

**Audit snapshot:** 17 November 2026

## 1. Objective

The Hegotá work examines how six Ethereum execution-layer EIPs can be adapted to the XDC execution environment and what would be required for compatible behavior across five execution clients.

The target is not simply to copy Ethereum changes. XDC has its own fork schedule, chain configuration conventions, transaction types, fee behavior, and XDPoS validator operation. A technically correct port must preserve these properties and ensure that every validator-capable client can process the same blocks consistently.

## 2. Scope

The six EIPs are:

1. EIP-8141 — Frame Transactions
2. EIP-8250 — Keyed Nonces
3. EIP-8272 — Recent Roots
4. EIP-7906 — Transaction Assertions
5. EIP-8151 — Restricted ecRecover
6. EIP-8298 — SETCODEFROM

The five clients for compatibility tracking are Erigon, Nethermind, Besu, Reth and Xone.

The XDC Go-Ethereum fork is the reference implementation. ethrex is an independent validation port used for a limited subset of vectors. Neither is an additional member of the five-client matrix.

FOCIL/EIP-7805 is not part of the six-EIP implementation scope documented here.

## 3. Research artifacts reported in the audit

The audit identified the following major research and planning artifacts:

- `FRAME_TRANSACTIONS_GAP_ANALYSIS.md` — frame-transaction gap analysis.
- `HEGOTA_XDC_COMPATIBILITY_REPORT.md` — XDC compatibility assessment.
- `HEGOTA_XDC_IMPLEMENTATION_PLAN.md` — implementation plan.
- EIP-8250 implementation report.
- EIP-8272 report, plan and test evidence.
- EIP-7906 and EIP-8151 plan/report/test evidence.
- `EIP_8298_IMPLEMENTATION_REPORT.md`.
- `XDC_HEGOTA_ARCHITECTURE_COMPATIBILITY_REPORT.md` — reported as a 740-line architecture report covering XDPoS architecture, a wider candidate-EIP inventory and per-EIP compatibility dimensions.
- `arch-audit/` Day 1–Day 5 records, including validator support matrix, mentor decisions, closure readiness, execution plan and validator-fleet/EIP-8141 scope.
- Erigon mission reports: `ERIGON_6_EIPS_PHASE1_AUDIT.md`, `ERIGON_6_EIPS_SPEC_BASELINE.md` and `ERIGON_6_EIPS_PHASE2_IMPLEMENTATION.md`.
- Cross-client Phase 2 documents: `CROSS_CLIENT_PLAN.md`, `CLIENT_MATRIX.md`, `SPEC_AND_DEVIATION_INVENTORY.md`, `VECTOR_GENERATION_PLAN.md`, `COMPATIBILITY_GAPS.md` and `PHASE2_FINAL_REPORT.md`.
- Final cross-client audit documents: `PORT-PLAN.md`, `CROSS_CLIENT_PINNED_CONFIG_AUDIT.md` and `CROSS_CLIENT_MATRIX_SIGNOFF.md`.

These names are recorded as audit-discovered artifacts. The source files themselves should be retained alongside the implementation repository or linked from a later evidence index so a reviewer can inspect their full contents.

## 4. XDC execution and consensus considerations

### 4.1 Fork activation model

The research identified a difference between Ethereum's timestamp-oriented fork activation and XDC's block-height-oriented activation conventions. An EIP port therefore needs an explicit XDC activation rule and must not silently assume Ethereum's fork timestamp model.

The audit also reported:
- Cancun as the live execution-layer fork baseline.
- Prague as not scheduled in the inspected configuration.
- Amsterdam/Bogota-related code paths present in the codebase but not active in XDC configuration at the audited checkpoint.
- Bogota activation fields were reported as nil in the inspected XDC configurations.

These are audit-time observations, not permanent network facts. Chain configuration must be checked again before any activation proposal.

### 4.2 XDPoS validator behavior

The architecture audit reported that XDPoS validators vote only after full block import, with the relevant code path identified as `eth/handler_eth.go:265`.

This creates a critical compatibility condition: any client that is allowed to join the validator set must be able to decode and execute the new transaction type/opcodes before the activation point. A validator that cannot import a block containing an activated feature can stop participating in consensus.

The audit also reported a live validator-fleet observation in which 491/491 reporting mainnet nodes were on the legacy XDPoSChain lineage and no GP5/Erigon/Nethermind/Reth/Besu/Xone validators were observed in that sample. Treat this as a dated netstats observation, not a permanent census.

### 4.3 XDC-specific behavior to preserve

The compatibility work identified XDC-specific execution behavior that should not be overwritten by an Ethereum-default port. Examples include:
- TIPTRC21 fee handling;
- special transaction types;
- BigBalance behavior;
- suppressed EIP-2028 behavior;
- deferred EIP-2929 behavior;
- XDC's fork-activation conventions.

Every EIP port should document whether it changes, depends on, or deliberately preserves each relevant behavior.

## 5. Research-to-implementation approach

The project work was organized around:
1. understanding the EIP's normative semantics and dependencies;
2. recording a frozen specification revision;
3. identifying differences between Ethereum assumptions and XDC behavior;
4. implementing in a dedicated worktree;
5. adding targeted unit, VM, transaction-pool or block-level tests as appropriate;
6. recording patch checkpoints and verification logs;
7. validating selected semantics against a second implementation;
8. separately assessing whether each target client has the required implementation.

A successful reference-fork test does not close the cross-client or validator-fleet gates.

## 6. Frozen specification revisions

The audit reported SHA-256-pinned specification snapshots for:

| EIP | Snapshot SHA-256 (prefix … suffix) |
|---|---|
| 8141 | `03095c47…44b39` |
| 8272 | `fb5856ab…a10ae` |
| 7906 | `fcde21b0…77fea` |
| 8151 | `191a5a2d…48ea` |
| 8298 | `9c05ea1f…4d13` |

The audit notes that the EIP-8250-era payload was handled with the EIP-8141 snapshot and dependency context. Full hashes and the actual snapshot files should be included in the underlying evidence bundle before a formal release. FOCIL/EIP-7805 was deliberately excluded from this six-EIP scope.

## 7. EIP dependency relationships

The reported dependency model is:

- EIP-8250 has a hard dependency on EIP-8141.
- EIP-8272 depends on EIP-8141 and EIP-7843.
- EIP-7906 depends on EIP-8141. A potential EIP-8253 storage-wipe interaction was considered and omitted from the implemented scope.
- EIP-8151 is standalone.
- EIP-8298 is standalone at the base level, with soft relationships to EIP-7906/BAL and the EIP-8151 migration arc.

Dependency assumptions must be rechecked against the exact pinned specification revision before changing implementation behavior.
