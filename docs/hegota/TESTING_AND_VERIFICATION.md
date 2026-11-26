# Testing and Verification Record

**Audit snapshot:** 17 November 2026

## 1. Reference-fork test evidence

The audit reported separate EIP worktrees and test evidence in the XDC Go-Ethereum reference area.

| EIP | Reported test evidence |
|---|---|
| 8141 | 49+ targeted tests |
| 8250 | 31 new tests: 16 engine, 8 types, 7 pool; 8141 suite retained |
| 8272 | 41 top-level test functions across core, types, txpool and legacypool |
| 7906 | 25 core tests (13 subtests), 9 types subtests, about 98 in-EVM assertions |
| 8151 | 6 VM tests (28 subtests) and 1 block-level test (5 subtests) |
| 8298 | 35 test functions |

These are reported audit counts. The exact test command, full stdout/stderr, commit or patch SHA and clean-checkout reproduction should accompany a formal test sign-off.

## 2. Cross-implementation validation: 29 vectors

The cross-client validation effort reported exactly two implementations in the 29-vector comparison:
1. XDC Go-Ethereum reference implementation in the `cross-client-geth-final` worktree;
2. separate ethrex/LEVM port.

The reported result was:
- 29 vectors passed;
- 0 failed;
- 0 runner errors;
- 29 compared.

The reported evidence files included:
- `runs/verify-final-29.json`
- `verify-final2-29.json`
- `final-compare.txt`

The comparison included state roots, receipts roots, block gas used, per-receipt status/cumulative gas/gas/logs, and per-frame receipts.

### 2.1 Vector coverage

The 29 vectors covered EIP-8141 and EIP-8250 behavior, including:
- frame static behavior;
- fork gating;
- VERIFY/DEFAULT/SENDER paths;
- code verification for secp256k1, contract and P256 cases;
- sponsorship;
- atomic batches, including a G1 terminator case;
- out-of-gas and reverts;
- unapproved-sender rejection;
- transfers;
- multi-transaction blocks;
- expiry verifier absent-code invalidation;
- keyed nonce single-use;
- sequential two-block keyed nonce behavior;
- 16-key boundary;
- multi-key atomic behavior;
- replay behavior;
- both-direction fork-form gating;
- four legacy-difference regression vectors.

The validation also exercised dependency behavior reported as EIP-8037, EIP-8038, EIP-2780, EIP-7976, EIP-7825, EIP-3529, EIP-7708 and Osaka P256, parameterized to the pinned XDC fork constants.

### 2.2 Negative control

The pristine geth baseline `48a7727` was used as a negative control:
- 25/25 frame vectors were rejected during decode;
- 4/4 legacy vectors passed.

This supports the claim that the tested frame behavior was not already present in the pristine baseline.

### 2.3 What 29/29 proves

The 29/29 result supports a limited statement:

> For the pinned EIP-8141/EIP-8250 semantics and the exercised dependency/fork constants, the selected geth reference and ethrex/LEVM validation port produced matching results across the recorded 29 vectors.

### 2.4 What 29/29 does not prove

It does not prove:
- EIP-8272, EIP-7906, EIP-8151 or EIP-8298 cross-implementation compatibility;
- implementation in Erigon, Nethermind, Besu, Reth or Xone;
- five-client compatibility;
- mixed-client XDPoS sealing, voting or validator-fleet operation;
- production activation or security audit;
- that Ethereum specification gas text is used without XDC fork-specific parameterization.

## 3. G1 atomic-batch terminator issue

The vector work reportedly found a G1 atomic-batch terminator issue on 2 November 2026. A fix was recorded in:
- `cross-client-geth-final`;
- the cross-client sandbox;
- `fix-frame-batch-terminator.patch`.

The audit explicitly noted that the completed 8141 and 8250 worktrees still needed review/application of this fix. It must therefore remain an open reconciliation item until the fix is reviewed, applied where appropriate and the suites are rerun.

## 4. Erigon verification caveat

Erigon's 8141/8250 re-baseline had 15 suite runs green at an earlier Stage A checkpoint. Later 7906 edits left the inspected working tree non-compiling because of duplicate `gasCodeCopy` and `gasExtCodeCopy` declarations in `execution/vm/gas_table.go`.

The earlier green checkpoint should not be presented as the current working-tree build status. A clean build is required after resolving the duplicate declarations and completing missing 7906 integration.

## 5. Reproducibility checklist

For a formal test handoff, preserve:
- exact source commit and patch SHA;
- exact EIP snapshot SHA;
- exact command line and environment;
- full test output and exit status;
- generated vector input and expected output;
- state/receipt comparison artifacts;
- toolchain versions;
- clean-worktree status;
- known failures and baseline comparison.

## 6. Validation status summary

| Validation layer | Audit status |
|---|---|
| Six EIP reference worktrees | Targeted test evidence reported; clean integrated release not established |
| 8141/8250 geth ↔ ethrex vectors | 29/29 reported matching |
| Five-client EIP conformance | Not established |
| Mixed-client XDPoS validator operation | Not established |
| Mainnet activation/readiness | Not established |
| Independent security audit | Not established |
