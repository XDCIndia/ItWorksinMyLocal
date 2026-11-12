# Apothem validator addresses

Public addresses of the per-client Apothem (chainId 51) validators. Addresses only: **keys are not in this repo**. They are held by the operator (root-only on our hosts).

| Client | Validator (coinbase) | Owner (staker) | Status |
|---|---|---|---|
| geth | 0x11C3637D2848ebdC190d56d8b81348c21446E866 | 0x5eca17cd31964f436c420a2092dc1c3bfc4b15dd | staked masternode, active (minting) |
| erigon | 0xa34e91459A95965a812c0585FD5b1D74d77ed013 | 0x4DdfF6D16cd303bd12397Df30Cc45bAd825429Df | to be proposed |
| reth | 0x1E870937601Fc462513e1B8708b21ceb08F8ec47 | 0x61569991412F7bEd482Aa59e1b7C1AE6E2C82BE1 | to be proposed |
| besu | 0x610279C76cBf6ac02E3410A3B1a588Ad14c43724 | 0xD77F76E5DBbEB4F6d404e14e4e26c6852F3218c4 | to be proposed |
| nethermind | 0x1a56B4Eb82410bf6c9aF800B2834a351c5166CCD | 0xf5217cEeBEC77FC2b9bAbD2F298c20b6069a3BdB | to be proposed |
| xone | 0x68a20B568D8058d1498f5308719D1a139C4C7f5a | 0xffd83c1CA48a321309E5C03Dc1cfDf19b290c542 | to be proposed |

`xone-rs` (xOne, Rust, `XDCIndia/xOne`) is **not** a validator: follower only; syncs from genesis; validator mode not yet supported. `join.sh --client xone-rs --mine` fails with that message, and it has no key above. `xone-ts` (xOneTS, TypeScript, `XDCIndia/xOneTS`) is likewise follower only and refuses `--mine`.

Owner and coinbase are deliberately different, and unique per client, so rewards are trackable per client. Rewards accrue to the owner. Never reuse an owner across clients.

Latest releases running as live Apothem validators: geth v1.17.10-xdc.21, xOneGo v1.4.7, nethermind v1.36.0-xdc.3, erigon-xdc v3.8.1-xdc.2, reth v2.9.0-xdc.4, besu v26.11-xdc.4. join.sh pins these.

## How to propose

A candidate becomes a masternode through the validator contract at `0x0000000000000000000000000000000000000088`. The **owner** account sends `propose(<coinbase>)` (payable) to it with value of at least `minCandidateCap`. Rewards accrue to the owner.

Facts read from the 0x88 contract on Apothem:

- `minCandidateCap` = 10,000,000 TXDC (`10000000000000000000000000` wei)
- `candidateWithdrawDelay` = 1,296,000 blocks

Both are deploy-time parameters; re-read before proposing:

    cast call 0x0000000000000000000000000000000000000088 "minCandidateCap()(uint256)" --rpc-url https://erpc.apothem.network

The candidate enters the masternode set at the next epoch switch after it ranks in by stake (epoch = 900 blocks, the set is taken at the gap block before the switch). Check with `XDPoS_getMasternodesByNumber` or the contract's `getCandidates()`.

## How to run

    ./join.sh --network testnet --client <c> --mine <addr> --keystore <dir> --password-file <file> --i-understand-single-signer

erigon needs a raw hex key file; join.sh derives it from the keystore into a 0600 file in the datadir (or pass `--keyfile FILE`). A non-geth producer on testnet raises `--maxpeers` to 50 and uses `bootnodes/testnet-static.list`, since it needs about 27+ canonical peers to collect votes.

## Single-signer rule

One key, one running producer, ever. The same validator key must never produce on two nodes at once (double-sign). Before starting a producer for an address, fully stop any existing producer for it, on every host. join.sh refuses `--mine` on testnet/mainnet without `--i-understand-single-signer` for this reason.

## Producer notes per client

- nethermind: start it as a follower first and let it reach the tip, then restart with `--mine` on the same `--datadir` (a validator-mode node does not follow the chain from behind). join.sh sets `Sync.NonValidatorNode=false` for `--mine`. A pivot-synced datadir has no candidate snapshots for the gap blocks near its pivot, so export `XDC_GAP_SNAPSHOT_SEED=<file>` (JSON `[{number, hash, candidates:[{address, cap}]}]`, one entry per gap block, `number` = 450 mod 900, read from the 0x88 contract at that block on an archive node, zero-cap candidates dropped); without it the node logs "No masternodes in epoch" and stalls. A candidate that is not yet in the masternode set logs "Skipped voting (not in masternode set)" until its epoch switch.
- besu: the validator key is passed as `-Dxdpos.validator.*` JAVA_OPTS (join.sh does this for `--mine`); the node also emits gasless sign txs for its address.

Datadir: join.sh uses one datadir per client. If `nodes/<client>-<role>` does not exist but the other role's does (`-sync` vs `-seal`), it reuses that one, so a synced follower becomes a producer (or back) without a fresh sync from block 0. Pass `--datadir` to choose explicitly. Never run two processes on one datadir: stop the follower before starting the producer.
