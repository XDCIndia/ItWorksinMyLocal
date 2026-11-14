# reth (xdc-reth 2.9.0-dev) cache and memory flags

Source: `xdc-reth node --help` (full output in `raw/reth-node-help.txt`). Defaults as printed by the binary.
**Not applied — reth has not been run again.**

## Most likely cause of the 2.45 GB peak

| Flag | Default | What it does |
|---|---|---|
| `--engine.cross-block-cache-size <MB>` | **4096** | Size of the cross-block execution cache in MB. Its default alone exceeds this 3.7 GB host. |
| `--engine.persistence-threshold <N>` | 50 | Canonical blocks kept in memory before flushing to disk. Explains the 1.6 MB datadir when stopped: blocks were still in memory. |
| `--engine.memory-block-buffer-target <N>` | min(persistence-threshold, built-in target) | Target number of blocks to keep in memory. |
| `--engine.persistence-backpressure-threshold <N>` | max(min, 2 × persistence-threshold) | Blocks that may wait for persistence before the engine stalls. |
| `--engine.disable-state-cache` | off | Turns the state cache off entirely. |
| `--engine.prewarming-threads <N>` | all cores | Parallel prewarming threads; also explains the 660 % CPU peak. |
| `--engine.reserved-cpu-cores <N>` | 1 | Cores left for other processes (the 4 sealers here). |
| `--engine.disable-precompile-cache` | off | Turns the precompile cache off. |
| `--engine.disable-sparse-trie-cache-pruning` | off | Leave off (setting it keeps more trie in memory). |

## Other memory knobs

| Flag | Default | What it does |
|---|---|---|
| `--rpc-cache.max-blocks-bytes` | 2 GiB | RPC block cache cap (0 disables) |
| `--rpc-cache.max-receipts-bytes` | 1 GiB | RPC receipts cache cap |
| `--rpc-cache.max-bals-bytes` | 500 MiB | RPC block-access-list cache cap |
| `--rpc-cache.max-blocks` / `max-receipts` / `max-bals` | 1000 / 500 / 1000 | entry-count limits for the RPC caches |
| `--jit.code-cache-bytes` | 1 GiB | resident compiled-code cache |
| `--tx-channel-memory-limit` | 1 GiB | buffer for tx events from the network |
| `--txpool.pending-max-size` / `basefee-max-size` / `queued-max-size` | 20 / 20 / 20 MB | tx-pool sub-pool sizes |
| `--rpc.evm-memory-limit` | ~4 GiB | EVM memory per RPC call |
| `--db.max-size`, `--db.growth-step` | 8 TB map, — | MDBX map size / growth (virtual, not RSS) |
| `--db.rocksdb-block-cache-size`, `--db.balstore-cache-size` | — | RocksDB block cache, BAL store cache |
| `--full` | off | keep only recent state (pruned node) |

## Proposed capped run (NOT executed — waiting for "go")

```bash
xdc-reth node --chain <genesis> --datadir <dir> ...same network flags as bench2.sh... \
  --engine.cross-block-cache-size 256 \
  --engine.persistence-threshold 8 \
  --engine.memory-block-buffer-target 4 \
  --engine.prewarming-threads 2 \
  --engine.reserved-cpu-cores 2 \
  --rpc-cache.max-blocks-bytes 64MB --rpc-cache.max-receipts-bytes 32MB --rpc-cache.max-bals-bytes 16MB \
  --jit.code-cache-bytes 64000000 \
  --tx-channel-memory-limit 64000000
```

If reth runs with these, the report must label it "reth, reduced caches" — it is then not reth's default configuration.
