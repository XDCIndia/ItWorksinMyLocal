# Proposed .wslconfig change (NOT applied)

File: `C:\Users\harsh\.wslconfig`

Current:
```ini
[wsl2]
# added 2026-11-13 for the net20119 multi-client run (reth/besu/nethermind/erigon OOM'd WSL before)
swap=8GB
```

Proposed:
```ini
[wsl2]
# 2026-11-14: was 8GB. WSL's swap file lives on C:; during the reth run it grew while C: had
# little room and the drive hit 0 MB, crashing WSL. 4GB caps that growth.
swap=4GB
```

Apply (only when approved): edit the file, then `wsl --shutdown` in PowerShell (stop the
sealers cleanly first with `fleet.sh down`, as a shutdown stops every WSL process).

Trade-off: with less swap, a process that outgrows RAM (like default-settings reth) is
killed by the Linux out-of-memory killer sooner instead of swapping. The OOM killer may pick
a sealer, so heavy clients should still only run with capped caches or on a bigger host.
