# Hegotá on XDC — Cross-Client Research and Implementation Record

**Documentation snapshot:** 17 November 2026  
**Prepared for:** technical review  
**Repository destination:** `docs/hegota/` in `XDCIndia/ItWorksinMyLocal`  
**Proposed branch:** `docs/hegota-cross-client-implementation`

> **Status and evidence note:** This documentation consolidates the project audit and worktree evidence reported during the Hegotá review. It is an engineering status record, not a claim that all six EIPs are deployed, active on XDC mainnet, or implemented in all five target clients. The status tables deliberately distinguish implemented, partial, not implemented, and unverified.

## 1. Executive summary

Hegotá is an effort to assess and implement six Ethereum execution-layer proposals in the XDC execution environment, while accounting for XDC-specific execution and XDPoS constraints. The work has three distinct tracks:

1. **XDC Go-Ethereum reference implementation:** the primary reference codebase in which the six EIPs were implemented in separate worktrees.
2. **Five-client compatibility effort:** investigation and implementation work across Erigon, Nethermind, Besu, Reth, and Xone.
3. **Independent validation port:** a separate ethrex/LEVM validation artifact used with the XDC geth reference to compare selected transaction and state-transition behavior.

These tracks must not be conflated. The XDC Go-Ethereum fork is the reference implementation; it is not a sixth target client. ethrex is a validation port; it is not one of the five target clients and is not an XDPoS validator candidate.

### Six EIPs in scope

| EIP | Subject | High-level purpose |
|---|---|---|
| [EIP-8141](https://eips.ethereum.org/EIPS/eip-8141) | Frame Transactions | Native transaction framing and account-abstraction-style validation/execution |
| [EIP-8250](https://eips.ethereum.org/EIPS/eip-8250) | Keyed Nonces | Independent nonce lanes keyed by sender and nonce key |
| [EIP-8272](https://eips.ethereum.org/EIPS/eip-8272) | Recent Roots | Recent block/state-root proofs for freshness-sensitive execution |
| [EIP-7906](https://eips.ethereum.org/EIPS/eip-7906) | Transaction Assertions | Assertions over transaction execution results and state changes |
| [EIP-8151](https://eips.ethereum.org/EIPS/eip-8151) | Restricted ecRecover | Restricts contract-code impersonation through `ecrecover` behavior |
| [EIP-8298](https://eips.ethereum.org/EIPS/eip-8298) | SETCODEFROM | Code adoption/reuse through a dedicated opcode |

### Five target clients

- Erigon
- Nethermind
- Besu
- Reth
- Xone

## 2. Architecture and terminology

### XDC Go-Ethereum reference fork

The reference repository reported in the audit is:

- Path: `/home/tanmay/xdc-fix-work/go-ethereum`
- Go module: `github.com/ethereum/go-ethereum`
- Baseline: `48a77271314293cdf057bc05d2c1624c3645a4d0`
- The checkout has no configured remote in the audited state.
- EIP work was organized into separate worktrees and staged patches rather than one integrated, committed branch.

The reference fork is the implementation baseline used to reason about XDC behavior and generate expected outcomes. A completed EIP worktree does not automatically mean that the change has been merged into a shared release branch, deployed, activated, or adopted by another client.

### Five-client target set

The five clients are the intended cross-client compatibility targets. Their statuses are recorded individually in [CROSS_CLIENT_COMPATIBILITY_MATRIX.md](CROSS_CLIENT_COMPATIBILITY_MATRIX.md).

### ethrex validation port

The ethrex port is a separate validation artifact under the cross-client work area. It was used as a second implementation for selected 8141/8250 vectors. It does not implement XDPoS consensus and is not included in the five-client matrix.

## 3. What the evidence supports

The audit reported six separate EIP worktrees in the XDC Go-Ethereum reference area, with implementation and test evidence for each EIP. The cross-implementation vector run covered **EIP-8141 and EIP-8250 only** and reported 29/29 matching vectors between the selected geth reference and ethrex port.

The 29/29 result is a narrow, valuable result. It is not evidence of:
- all six EIPs passing cross-client vectors;
- all five target clients implementing the six EIPs;
- mixed-client XDPoS sealing, voting, or validator-fleet operation;
- production activation or mainnet readiness;
- independent security audit or production certification.

## 4. Reading this documentation

| Document | Purpose |
|---|---|
| [PROJECT_HISTORY_AND_RESEARCH.md](PROJECT_HISTORY_AND_RESEARCH.md) | Project background, architecture research, scope and XDC-specific constraints |
| [EIP_IMPLEMENTATION_STATUS.md](EIP_IMPLEMENTATION_STATUS.md) | Reference-fork implementation status for each of the six EIPs |
| [CROSS_CLIENT_COMPATIBILITY_MATRIX.md](CROSS_CLIENT_COMPATIBILITY_MATRIX.md) | The 30 EIP/client combinations across the five target clients |
| [CLIENT_IMPLEMENTATION_DETAILS.md](CLIENT_IMPLEMENTATION_DETAILS.md) | Client-by-client evidence and limitations |
| [TESTING_AND_VERIFICATION.md](TESTING_AND_VERIFICATION.md) | Worktree tests, cross-implementation vectors and what they do/do not prove |
| [TECHNICAL_DECISIONS_AND_REMAINING_WORK.md](TECHNICAL_DECISIONS_AND_REMAINING_WORK.md) | Key XDC adaptations, dependencies, risks and next steps |

## 5. Important interpretation rules

1. **Reference implementation is not a target-client implementation.** The XDC Go-Ethereum fork is the reference codebase, not a sixth row in the five-client matrix.
2. **ethrex is not a target client.** It is a separate validation port.
3. **29/29 means the selected 8141/8250 vectors matched in two implementations.** It does not mean five clients were validated.
4. **UNVERIFIED is not NOT IMPLEMENTED.** Nethermind and Xone source access was not sufficient to make a definitive code-level statement.
5. **Partial Erigon work is not complete implementation.** The 8272 and 7906 work was incomplete at the audited checkpoint.
6. **A completed worktree is not a production release.** The reference worktrees were staged/uncommitted in the audited state.
7. **No mainnet activation is claimed.** Fork activation/configuration and validator-fleet readiness remain separate gates.

## 6. Audit snapshot and limitations

This record reflects the audit snapshot available on 17 November 2026. Paths, branch names, staged diffs and test logs are local evidence and should be rechecked before release or implementation handoff. The project still needs a clean integrated build, a reproducible test bundle, complete target-client source access, cross-client execution tests, and validator-fleet compatibility work.

## 7. Suggested review order

For a technical reviewer, read this document first, then the project research, implementation status, client matrix, and test evidence. Finish with the decisions and remaining-work register. The matrix should be treated as the current audited snapshot rather than a promise of future support.
