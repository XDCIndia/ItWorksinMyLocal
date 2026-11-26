# Technical Decisions, XDC Adaptations and Remaining Work

**Audit snapshot:** 17 November 2026

## 1. Purpose

This document records technical adaptations reported during the Hegotá work and the major closure items. Values and decisions below are tied to the inspected implementation/specification snapshot. They must be rechecked against the pinned EIP revisions and XDC chain configuration before activation.

## 2. EIP-8141 — Frame Transactions

Reported XDC adaptations:
- use XDC block-height activation conventions rather than assuming Ethereum timestamp activation;
- expiry-verifier behavior supports keyless deployment;
- preserve XDC TIPTRC21 settlement policy; the reported choice was spec-pure;
- coexist with XDC special transaction types;
- include an eth/69 receipt wire compatibility fix;
- pin gas constants to the relevant XDC fork context.

One reported example is `TxValueCost2780 = 4244`, rather than the 6000 value in a specification table. Such differences need a clearly documented derivation and test.

## 3. EIP-8250 — Keyed Nonces

Reported decisions:
- nonce manager address: `0x8250968C12e01A19d6F667b9B2F3b3A4d0e51cB7`;
- empty selector `[]` represents the legacy nonce domain;
- `MAX_NONCE_SEQ` is single-use;
- `KEYED_NONCE_ACCESS_COST` is derived from the XDC fork's Amsterdam cold-storage constant, reported as 13000 because `ColdStorageAccessAmsterdam = 3000`, rather than taking the 2100 value in spec text;
- support dual-form RLP decoding;
- use a keyed transaction-pool side-pool;
- enforce a hard Bogota fork gate;
- keyless deployment is a precondition.

## 4. EIP-8272 — Recent Roots

Reported decisions:
- recent-root contract address: `0x8272D9679689Ea2f307140CdF9002D27dC00Ffff`;
- 8192-slot ring buffers;
- at most 16 tuples;
- canonical VERIFY frame recognition;
- slot derivation uses block/slot number rather than wall-clock time;
- prefix grammar changes apply only to recent-root transactions.

## 5. EIP-7906 — Transaction Assertions

Reported decisions:
- ASSERT frame mode is 3;
- TXTRACE opcode is `0xb6`;
- EVENTDATACOPY opcode is `0xb7`;
- transaction diff is derived lazily from the journal;
- APPROVE is prohibited in ASSERT mode;
- a potential EIP-8253 storage-wipe interaction was resolved by omission; EIP-8253 was not implemented as part of this scope.

## 6. EIP-8151 — Restricted ecRecover

Reported decisions:
- precompile `0x01` behavior becomes stateful;
- cold/warm access totals are 6100/3200, including the 3000 base component;
- return the address only if raw code is empty or exactly matches the 23-byte EIP-7702 delegation indicator;
- precompile-map swap is Bogota-gated.

## 7. EIP-8298 — SETCODEFROM

Reported decisions:
- opcode is `0xA7`;
- source validity checks and static/system halts are required;
- charging is staged;
- CREATE/CREATE2 code-deposit skip behavior is included;
- BAL integration uses a three-element `CodeChange`;
- XDC gas was derived as 11200/8300, with `AccountWriteAmsterdam = 8000` compared with 9000 in spec text;
- transaction-pool eviction of affected ECDSA transactions is required.

## 8. Activation and validator compatibility gates

The project must not treat implementation completion as activation readiness. Before activation:
1. choose and document the exact XDC fork block;
2. verify chain-config behavior across all validator-capable clients;
3. ensure every validator can decode and execute the activated transaction/opcode behavior;
4. test block import and validator voting with the relevant client combinations;
5. verify state-root, receipt-root and block-hash agreement;
6. test reorg, restart, sync and historical block replay;
7. define rollback/disable behavior where technically possible;
8. complete independent review and release procedures.

The XDPoS full-block-import-before-vote behavior makes this a liveness requirement, not merely a feature-parity preference.

## 9. Remaining work register

### Priority 0 — Reference integration and correctness

- Reconcile the G1 atomic-batch terminator fix into the 8141/8250 worktrees after review.
- Resolve the Erigon duplicate gas function declarations and complete missing 7906 wiring.
- Re-run all six EIP test suites from clean worktrees.
- Produce a clean integrated reference build.
- Publish exact commit/patch hashes and reproducible logs.

### Priority 1 — Client source access and implementation

- Obtain authorized source access for Nethermind and Xone.
- Pin and inspect exact Besu and Reth source revisions/branches, including any private vendor branches.
- Complete Erigon 8272 and 7906 protocol/engine/test integration.
- Implement Erigon 8151 and 8298 if still in scope after spec review.
- Plan and implement missing EIPs in Besu, Reth, Nethermind and Xone based on the agreed client rollout strategy.

### Priority 2 — Cross-client conformance

- Extend the vector suite beyond 8141/8250 to 8272, 7906, 8151 and 8298.
- Run the same vectors against each target client that has an implementation.
- Record unsupported vectors explicitly rather than silently skipping them.
- Compare state roots, receipts, gas, logs, transaction-pool behavior and block import results.
- Add cross-client regression tests to CI.

### Priority 3 — XDPoS validator-fleet validation

- Build a controlled mixed-client validator test network.
- Verify that all validator-capable clients import activated blocks before voting.
- Test quorum behavior, offline validators, partitions, restarts and epoch transitions.
- Confirm no client-specific transaction decoding or state transition differences.
- Keep the validator-fleet readiness decision separate from EIP unit-test completion.

### Priority 4 — Release and governance

- Finalize activation heights only after client and validator sign-off.
- Publish a release note and operator migration guide.
- Document RPC, transaction-pool and wallet/tooling compatibility.
- Complete an independent security review.
- Obtain explicit approval before any production configuration or mainnet activation change.

## 10. Final status statement

At the audit snapshot, the XDC Go-Ethereum reference work contained reported implementation work for all six EIPs in dedicated worktrees. Erigon had upstream/re-baselined 8141 and 8250 work, partial 8272 and 7906 work, and no implementation evidence for 8151 and 8298. Besu and Reth were not implemented in the inspected source states; Nethermind and Xone remained unverified because source access was insufficient. The 29/29 cross-implementation validation applied only to EIP-8141 and EIP-8250 across the geth reference and ethrex port.

This is meaningful engineering progress, but it is not evidence of six-EIP implementation across five clients, mixed-client XDPoS validator readiness, production activation or security certification.
