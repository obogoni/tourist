#!/usr/bin/env python3
"""Latency and throughput from pgbench per-transaction logs.

Usage: analyze.py <result-dir> <app> <script-names,comma-separated> [--from S] [--to S] [--timeline]

Log line: client_id txn_no latency_us script_no epoch_s epoch_us [schedule_lag_us]
--from/--to select a window in seconds from the first transaction of <app>.
--t0 sets that origin explicitly (epoch seconds) to align several apps.
"""
import argparse, glob, sys
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("dir"); ap.add_argument("app"); ap.add_argument("names")
ap.add_argument("--from", dest="start", type=float, default=0)
ap.add_argument("--to", dest="end", type=float, default=1e12)
ap.add_argument("--t0", type=float)
ap.add_argument("--timeline", action="store_true")
a = ap.parse_args()
names = a.names.split(",")

rows = []
for f in glob.glob(f"{a.dir}/{a.app}.[0-9]*"):
    with open(f) as fh:
        for line in fh:
            p = line.split()
            if len(p) < 6 or p[2] == "skipped" or p[2] == "failed":
                continue
            rows.append((int(p[3]), int(p[2]), int(p[4]) + int(p[5]) / 1e6))
if not rows:
    sys.exit(f"no log lines for {a.app} in {a.dir}")
script = np.array([r[0] for r in rows]); lat = np.array([r[1] for r in rows]) / 1000.0
end_t = np.array([r[2] for r in rows])
t0 = a.t0 if a.t0 is not None else end_t.min()
rel = end_t - t0
sel = (rel >= a.start) & (rel < a.end)
span = min(a.end, rel.max()) - max(a.start, rel.min())

def stats(mask):
    l = lat[mask & sel]
    if len(l) == 0:
        return None
    return len(l), len(l) / span, *np.percentile(l, [50, 95, 99]), l.max()

print(f"{a.app}: window {a.start:g}-{min(a.end, rel.max()):.0f}s, {span:.0f}s")
print(f"{'script':<14}{'count':>9}{'ops/s':>9}{'p50 ms':>9}{'p95 ms':>9}{'p99 ms':>9}{'max ms':>9}")
for i, n in enumerate(names):
    s = stats(script == i)
    if s:
        print(f"{n:<14}{s[0]:>9}{s[1]:>9.0f}{s[2]:>9.1f}{s[3]:>9.1f}{s[4]:>9.1f}{s[5]:>9.0f}")
s = stats(np.ones_like(sel))
print(f"{'all':<14}{s[0]:>9}{s[1]:>9.0f}{s[2]:>9.1f}{s[3]:>9.1f}{s[4]:>9.1f}{s[5]:>9.0f}")

if a.timeline:
    print("\nsecond  ops/s   p50 ms   p99 ms   max ms")
    sec = np.floor(rel).astype(int)
    for s_ in range(int(max(a.start, 0)), int(min(a.end, rel.max())) + 1):
        l = lat[sec == s_]
        if len(l):
            print(f"{s_:>6}{len(l):>8}{np.percentile(l, 50):>9.1f}{np.percentile(l, 99):>9.1f}{l.max():>9.0f}")
