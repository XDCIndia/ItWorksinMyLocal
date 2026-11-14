"""analyze.py <run dir> <xone|reth> <target>: sync speed, CPU, RSS and per-block time percentiles from raw output."""
import csv, re, statistics as st, sys

out, client, target = sys.argv[1], sys.argv[2], int(sys.argv[3])
rows = list(csv.DictReader(open(out + "/samples.csv")))
sync = [r for r in rows if r["phase"] == "sync"]
steady = [r for r in rows if r["phase"] == "steady"]

first = next((r for r in rows if int(r["head"]) > 0), None)
reach = next((r for r in rows if int(r["head"]) >= target), None)
if first and reach:
    n = int(reach["head"]) - int(first["head"])
    dt = float(reach["t"]) - float(first["t"])
    print("sync_blocks_per_s: %.1f   (blocks %s->%s in %.1fs, timed from first imported block)"
          % (n / dt if dt > 0 else float("nan"), first["head"], reach["head"], dt))
    print("time_to_first_block_s: %.1f" % float(first["t"]))

med = lambda xs: "%.0f" % st.median(xs) if xs else "-"
print("cpu_pct_median_sync: %s   (100 = one full core)" % med([float(r["cpu_pct"]) for r in sync if int(r["head"]) > 0]))
print("cpu_pct_peak_sync: %s" % (max((float(r["cpu_pct"]) for r in sync), default="-")))
print("cpu_pct_median_steady: %s" % med([float(r["cpu_pct"]) for r in steady]))
print("rss_mb_median_steady: %s" % med([int(r["rss_mb"]) for r in steady]))

# per-block processing time from the client's own log
ansi = re.compile(r"\x1b\[[0-9;]*m")
def ms(v, unit):
    v = float(v)
    return {"ns": v / 1e6, "µs": v / 1e3, "us": v / 1e3, "ms": v, "s": v * 1000}[unit]
single, batch = [], []
for line in open(out + "/node.log", errors="replace"):
    line = ansi.sub("", line)
    if client == "reth":
        m = re.search(r"Block added to canonical chain number=(\d+).*elapsed=([0-9.]+)(ns|µs|us|ms|s)\b", line)
        if m: single.append((int(m.group(1)), ms(m.group(2), m.group(3))))
    else:
        m = re.search(r"imported (\d+) blocks .* in ([0-9.]+) (ns|µs|us|ms|s), head (\d+)", line)
        if m:
            k, t, head = int(m.group(1)), ms(m.group(2), m.group(3)), int(m.group(4))
            (single if k == 1 else batch).append((head, t) if k == 1 else (head, t / k))

def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(round(p / 100 * (len(xs) - 1))))]
for label, xs in (("single-block imports", [t for _, t in single]),):
    if xs: print("block_time_ms (%s, n=%d): p50=%.1f p99=%.1f max=%.1f" % (label, len(xs), pct(xs, 50), pct(xs, 99), max(xs)))
if batch:
    xs = [t for _, t in batch]
    print("block_time_ms (batched sync, per block = batch time / batch size, n=%d batches): p50=%.2f p99=%.2f"
          % (len(xs), pct(xs, 50), pct(xs, 99)))
