# Cross-Client Compatibility Matrix

**Audit snapshot:** 17 November 2026  
**Target clients:** Erigon, Nethermind, Besu, Reth, Xone

## 1. Status definitions

- **IMPLEMENTED:** implementation was found for the EIP in the inspected client state. This does not by itself mean integrated, production-ready or activated.
- **PARTIALLY IMPLEMENTED:** some code exists, but required protocol, execution, integration or test work is missing.
- **NOT IMPLEMENTED:** the inspected source tree/default branch showed no implementation evidence for the EIP.
- **UNVERIFIED:** source access or inspected artifacts were insufficient to make a definitive implementation claim.

## 2. The 30-combination matrix

| EIP | Erigon | Nethermind | Besu | Reth | Xone |
|---|---|---|---|---|---|
| EIP-8141 | IMPLEMENTED* | UNVERIFIED | NOT IMPLEMENTED† | NOT IMPLEMENTED‡ | UNVERIFIED |
| EIP-8250 | IMPLEMENTED* | UNVERIFIED | NOT IMPLEMENTED† | NOT IMPLEMENTED‡ | UNVERIFIED |
| EIP-8272 | PARTIALLY IMPLEMENTED | UNVERIFIED | NOT IMPLEMENTED† | NOT IMPLEMENTED‡ | UNVERIFIED |
| EIP-7906 | PARTIALLY IMPLEMENTED | UNVERIFIED | NOT IMPLEMENTED† | NOT IMPLEMENTED‡ | UNVERIFIED |
| EIP-8151 | NOT IMPLEMENTED | UNVERIFIED | NOT IMPLEMENTED† | NOT IMPLEMENTED‡ | UNVERIFIED |
| EIP-8298 | NOT IMPLEMENTED | UNVERIFIED | NOT IMPLEMENTED† | NOT IMPLEMENTED‡ | UNVERIFIED |

\* Erigon already had upstream EIP-8141 and EIP-8250 work before this project. The project audited and re-baselined these to newer approved spec revisions. Do not describe the upstream implementation as newly authored by this project.

† Besu status is based on the inspected public default branch only. Private branches or uninspected source repositories may differ.

‡ Reth status is based on the inspected local clone only. Private/vendor repositories may differ.

## 3. Per-client basis

### Erigon

- Repository path: `/home/tanmay/erigon-hegota-audit`
- Baseline: `087aa1c5b637215511b34f7fd402b2922af1568b`
- Branch: `feat/xdc-hegota-six-eips`
- Reported zero commits and an uncommitted working tree at audit time.
- EIP-8141 and EIP-8250 were present upstream before the project's re-baselining work.
- EIP-8272 and EIP-7906 had partial code.
- EIP-8151 and EIP-8298 had research/planning but no implementation evidence.

The 8141/8250 working tree had a reported 47 modified files (+753/-312) and 15 green suite runs at an earlier Stage A checkpoint. The later in-flight 7906 edit made the current tree non-compiling due duplicate `gasCodeCopy` and `gasExtCodeCopy` declarations in `execution/vm/gas_table.go`. See [CLIENT_IMPLEMENTATION_DETAILS.md](CLIENT_IMPLEMENTATION_DETAILS.md).

### Nethermind

The source repository `XDCIndia/nethermind-xdc` was inaccessible/404/private in the inspected context. No local source clone was available for code-level inspection. Therefore all six statuses are **UNVERIFIED**, not NOT IMPLEMENTED.

### Besu

The inspected public repository was `XDCIndia/besu-xdc`, default branch `main` at commit `3021947` (last push reported 24 March 2026). The audit found no Hegotá-specific implementation paths matching the six EIP identifiers or Hegotá/Bogota naming. The status is NOT IMPLEMENTED for the inspected public default branch only; private branches are unknown.

### Reth

The inspected local repository was `/home/tanmay/src/reth-xdc-anil`, associated with `github.com/AnilChinchawale/reth-xdc`. The inspected checkout was detached at `ad704b1`, with `main` at `026925b`, and was described as a Phase 1 XDPoS port. The audit found no Hegotá-specific code in the inspected Rust/Markdown files. Private vendor repositories were inaccessible, so this status applies only to the inspected local codebase.

### Xone

The source repository `XDCIndia/xOneGo` was inaccessible/404/private in the inspected context. The only inspected artifact was a binary, which is not sufficient for a complete source-level audit. Xone is reported to share the GP5 lineage with the reference fork, but that lineage fact does not establish that Hegotá work is present. All six statuses remain **UNVERIFIED**.

## 4. How to read this matrix

This matrix is intentionally conservative. A source repository that cannot be inspected is not marked NOT IMPLEMENTED. Similarly, a code path or partial opcode implementation is not treated as a complete EIP implementation.

The matrix is not a claim that all six EIPs have been implemented across all five clients. It records the implementation evidence available in the audit snapshot.

## 5. Cross-client completion criteria

For a client/EIP cell to move to IMPLEMENTED with high confidence, the project should record:
1. accessible repository and exact commit;
2. pinned EIP revision and XDC adaptation notes;
3. transaction decoding and execution support;
4. required opcode/precompile/state-transition behavior;
5. transaction-pool and RPC behavior where applicable;
6. fork activation/configuration behavior;
7. client-specific tests and cross-client vectors;
8. build/test logs from a clean checkout;
9. integration and validator-import compatibility evidence.
