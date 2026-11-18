# Client Implementation Details and Audit Evidence

**Audit snapshot:** 17 November 2026

## 1. Erigon

### Repository and branch

- Path: `/home/tanmay/erigon-hegota-audit`
- Baseline: `087aa1c5b637215511b34f7fd402b2922af1568b`
- Branch: `feat/xdc-hegota-six-eips`
- The audit reported zero commits on the branch and uncommitted working-tree changes.

### EIP-8141 and EIP-8250

Upstream Erigon already contained EIP-8141 and EIP-8250 work before this project, reportedly merged through PR #25243 at commit `2e2fea3e29`, with devnet-1 pins `af3a7802` and `e3285064`.

The project work audited and re-baselined those implementations to newer approved revisions:
- 8141: aggregate max-fee model, signature-hash length commitment, TXPARAM `0x04` as MAX_FEE, removal of TXPARAM `0x05`/`0x06`, EIP-8037 legacy-share charging, and pool/RPC/ethbackend denomination.
- 8250: `[]` legacy selector, key-0 ordinary behavior, single-use MAX_NONCE_SEQ and pricing exemption.

Target revisions reported:
- 8141: `dc5d5fa688`
- 8250: `1a086d5c67`

No XDC chain-config activation values were added; the mission rule was to leave production configurations untouched.

The audit reported 47 modified files (+753/-312) for the shared 8141/8250 delta and 15 suite runs green at an earlier Stage A checkpoint. However, the later in-flight 7906 work made the current tree non-compiling. The current tree must not be represented as green.

### EIP-8272

Partial implementation was reported in `execution/types/recent_roots.go` (156 lines), including constants, derivations and predicates. Required wiring and tests were missing.

### EIP-7906

Partial work was reported:
- opcode registrations;
- `execution/vm/tx_trace.go` (241 lines);
- `execution/state/tx_diff.go` (229 lines).

Missing pieces included ASSERT frame mode, jump-table wiring, protocol/engine integration and tests. The audit identified duplicate `gasCodeCopy` and `gasExtCodeCopy` declarations in `execution/vm/gas_table.go`, causing a build failure in the audited working tree.

### EIP-8151 and EIP-8298

No implementation code, semantic markers or tests were found beyond research/planning at the audit checkpoint.

### Erigon mission revisions

The audit reported pinned target revisions:
- 8141: `dc5d5fa688`
- 8250: `1a086d5c67`
- 8272: `5e32ce9abb`
- 7906: `9099f412d2`
- 8151: `af5ea76669`
- 8298: `f4a9f9655e`

These are mission revision identifiers, not proof that all six implementations are complete.

## 2. Nethermind

The source repository was not accessible in the audit environment. The local Net2040 workspace contained binaries, but binary presence is not a substitute for source inspection or EIP conformance tests. No implementation conclusion should be inferred from those binaries.

**Required next step:** obtain authorized source access, pin the exact commit, inspect EIP-specific code and run the conformance suite. Until then, all six cells remain UNVERIFIED.

## 3. Besu

The inspected public default branch was `XDCIndia/besu-xdc` at `3021947`. The audit found no Hegotá-specific paths or code references for the six EIPs in that inspected branch. Generic `MessageFrame` and RLP frame references were unrelated and should not be counted as EIP-8141 support.

Private branches were not inspected. The matrix therefore records NOT IMPLEMENTED for the inspected public default branch, with that limitation attached.

## 4. Reth

The inspected local checkout was `/home/tanmay/src/reth-xdc-anil`, associated with `AnilChinchawale/reth-xdc`. It was a Phase 1 XDPoS port, with no Hegotá implementation evidence found in the inspected `.rs` and `.md` files. Vendor repositories that might contain additional work were inaccessible.

The matrix status applies to the inspected local checkout only.

## 5. Xone

The source repository was inaccessible. The inspected binary was reported as xOneGo v1.4.7. The audit noted that Xone shares GP5 lineage with the XDC Go-Ethereum reference, but the binary is opaque and cannot establish whether the six EIPs are implemented.

The matrix therefore records all six EIPs as UNVERIFIED.

## 6. Separate reference and validation artifacts

### XDC Go-Ethereum

The six dedicated worktrees are detailed in [EIP_IMPLEMENTATION_STATUS.md](EIP_IMPLEMENTATION_STATUS.md). They form the reference implementation record, not the five-client target matrix.

### ethrex

The ethrex port is a separate validation artifact used to compare selected EIP-8141/8250 behavior with the reference geth implementation. It is not a production target client or XDPoS validator candidate.

## 7. Audit discipline

Before changing any client status:
- record the exact repository URL and commit;
- state whether the inspected source is public, private, local or binary-only;
- preserve command output and logs;
- distinguish upstream code from project-authored changes;
- do not infer feature support from shared ancestry or binary version alone.
