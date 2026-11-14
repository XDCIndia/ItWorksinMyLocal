"""Median and range across the repeated xOne 1,800-block runs (run-xone-r1..r3)."""
import re, statistics as st
X = "/home/harsh/xone-bench"
keys = {
    "time_to_1800_s": r"reached_target_after_s: ([0-9.]+)",
    "blocks_per_s": r"sync_blocks_per_s: ([0-9.]+)",
    "peak_rss_mb": r"peak_rss_mb: (\d+)",
    "steady_rss_mb": r"rss_mb_median_steady: (\d+)",
    "disk_mb": r"disk_mb: (\d+)",
    "cpu_sync_pct": r"cpu_pct_median_sync: (\d+)",
    "sync_p50_ms": r"batched sync.*p50=([0-9.]+)",
    "sync_p99_ms": r"batched sync.*p99=([0-9.]+)",
    "live_p50_ms": r"single-block imports.*p50=([0-9.]+)",
    "live_p99_ms": r"single-block imports.*p99=([0-9.]+)",
    "hash_900": r"hash_match_block_900: (\w+)",
    "hash_1800": r"hash_match_block_1800: (\w+)",
}
runs = []
for i in (1, 2, 3):
    s = open("%s/run-xone-r%d/summary.txt" % (X, i)).read()
    runs.append({k: (re.search(p, s).group(1) if re.search(p, s) else None) for k, p in keys.items()})
print("| Metric (1,800 blocks) | run 1 | run 2 | run 3 | median | range |")
print("|---|---|---|---|---|---|")
for k in keys:
    vals = [r[k] for r in runs]
    if k.startswith("hash"):
        print("| %s | %s | | |" % (k, " | ".join(vals)))
        continue
    nums = [float(v) for v in vals]
    fmt = (lambda x: "%.0f" % x) if max(nums) >= 50 else (lambda x: "%.2f" % x)
    print("| %s | %s | **%s** | %s–%s |" % (k, " | ".join(fmt(n) for n in nums), fmt(st.median(nums)), fmt(min(nums)), fmt(max(nums))))
