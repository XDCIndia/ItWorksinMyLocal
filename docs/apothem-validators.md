# Apothem validator addresses

Public addresses of the per-client Apothem (chainId 51) validators. Addresses only: **keys are not in this repo**. They are held by the operator (root-only on our hosts).

| Client | Validator address | Status |
|---|---|---|
| geth | 0x11C3637D2848ebdC190d56d8b81348c21446E866 | staked masternode, active (minting) |
| erigon | 0xa34e91459A95965a812c0585FD5b1D74d77ed013 | to be proposed |
| reth | 0x1E870937601Fc462513e1B8708b21ceb08F8ec47 | to be proposed |
| besu | 0x610279C76cBf6ac02E3410A3B1a588Ad14c43724 | to be proposed |
| nethermind | 0x1a56B4Eb82410bf6c9aF800B2834a351c5166CCD | to be proposed |
| xone | 0x68a20B568D8058d1498f5308719D1a139C4C7f5a | to be proposed |

erigon and reth have no Apothem-mint-proven release yet (join.sh warns when they are used with `--network testnet`).

## How to propose

A candidate becomes a masternode through the validator contract at `0x0000000000000000000000000000000000000088`:
`propose(address)`, sent as a payable call from the funding account, with value at least the contract's `minCandidateCap`.

`minCandidateCap` on Apothem, read from the live contract (`minCandidateCap()`): `10000000000000000000000000` wei = **10,000,000 XDC**. Re-read it before proposing, it is a deploy-time parameter:

    cast call 0x0000000000000000000000000000000000000088 "minCandidateCap()(uint256)" --rpc-url https://erpc.apothem.network

The candidate enters the masternode set at the next epoch switch after it ranks in by stake (epoch = 900 blocks, the set is taken at the gap block before the switch). Check with `XDPoS_getMasternodesByNumber` or the contract's `getCandidates()`.

## How to run

    ./join.sh --network testnet --client <c> --mine <addr> --keystore <dir> --password-file <file> --i-understand-single-signer

erigon/reth take `--keyfile FILE` (raw hex key, mode 0600) instead of a keystore. A non-geth producer on testnet raises `--maxpeers` to 50 and uses `bootnodes/testnet-static.list`, since it needs about 27+ canonical peers to collect votes.

## Single-signer rule

One key, one running producer, ever. The same validator key must never produce on two nodes at once (double-sign). Before starting a producer for an address, fully stop any existing producer for it, on every host. join.sh refuses `--mine` on testnet/mainnet without `--i-understand-single-signer` for this reason.
