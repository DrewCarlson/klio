#!/usr/bin/env python3
"""Summarize bench/compose results: per program, klio against the JVM, and
against an earlier klio run when one is given. A klio-only run compared
with a baseline that has JVM runs takes the JVM numbers from it.

    bench/compose/summarize.py RESULTS.json [--baseline OLDER.json]

Frame times are the median over rounds of each run's own report; memory is
the highest peak of any run; wall time the lowest. A window's launch is the
time from spawning it to its printing its first frame.
"""
import argparse
import json
import re
import statistics
from collections import defaultdict

# (key, label)
HEADLESS = [
    ("mean_ms", "frame ms (mean)"),
    ("p95_ms", "frame ms (p95)"),
    ("setContent_ms", "first composition ms"),
]
WINDOW = [
    ("launch_s", "launch to first frame s"),
    ("fps", "frames a second"),
    ("cpu_ms_per_frame", "CPU ms per frame"),
    ("idle_cpu_pct", "idle CPU %"),
    ("wall_s", "wall s"),
]
MEMORY = [
    ("peak_footprint_mb", "peak footprint MB"),
    ("max_rss_mb", "peak RSS MB"),
]


def printed(run):
    """The key=value numbers a run printed, the last of each key."""
    out = {}
    for _, line in run["lines"]:
        for k, v in re.findall(r"(\w+)=([\d.]+)", line):
            out[k] = float(v)
    return out


def idle_cpu(run):
    """CPU share from 3 s after the first frame to the idle program's end."""
    ff = next((t for t, l in run["lines"] if l.startswith("first_frame_ms")), None)
    done = next((t for t, l in run["lines"] if l.startswith("idle_done")), None)
    if ff is None or done is None:
        return None
    a = [p for p in run["traj"] if p[0] >= ff + 3.0]
    b = [p for p in run["traj"] if p[0] <= done]
    if not a or not b or b[-1][0] <= a[0][0]:
        return None
    return 100 * (b[-1][2] - a[0][2]) / (b[-1][0] - a[0][0])


def metrics(runs):
    """One program's numbers on one runtime, over its successful runs."""
    ok = [r for r in runs if r.get("rc") == 0]
    if not ok:
        return None
    per = defaultdict(list)
    for r in ok:
        p = printed(r)
        for k in ("mean_ms", "p95_ms", "setContent_ms", "fps"):
            if k in p:
                per[k].append(p[k])
        launch = next((t for t, l in r["lines"] if l.startswith("first_frame_ms")), None)
        if launch is not None:
            per["launch_s"].append(launch)
        if "frames" in p and "fps" in p and "user_s" in r:
            per["cpu_ms_per_frame"].append((r["user_s"] + r["sys_s"]) * 1000 / p["frames"])
        ic = idle_cpu(r)
        if ic is not None:
            per["idle_cpu_pct"].append(ic)
    m = {k: statistics.median(v) for k, v in per.items()}
    m["wall_s"] = min(r["wall_s"] for r in ok if "wall_s" in r)
    for k in ("peak_footprint_mb", "max_rss_mb"):
        vals = [r[k] for r in ok if k in r]
        if vals:
            m[k] = max(vals)
    m["runs"] = len(ok)
    m["failed"] = len(runs) - len(ok)
    return m


def by_program(results):
    grouped = defaultdict(lambda: defaultdict(list))
    for r in results:
        grouped[r["program"]][r["arm"]].append(r)
    return {p: {arm: metrics(runs) for arm, runs in arms.items()} for p, arms in grouped.items()}


def fmt(v):
    if v is None:
        return "-"
    if v >= 100:
        return "%.0f" % v
    if v >= 10:
        return "%.1f" % v
    return "%.2f" % v


def report(results, baseline=None):
    now = by_program(results)
    base = by_program(baseline) if baseline else {}
    cols = ["program", "metric"] + (["klio base"] if base else []) + ["klio"] + (["change"] if base else []) + ["jvm", "klio/jvm"]
    rows = []
    for prog in sorted(now):
        arms = now[prog]
        k = arms.get("klio") or {}
        # The JVM side does not change with klio: a klio-only run takes the
        # baseline's JVM numbers.
        j = arms.get("jvm") or (base.get(prog) or {}).get("jvm") or {}
        b = (base.get(prog) or {}).get("klio") or {}
        keys = (HEADLESS if prog.startswith("hb_") else WINDOW) + MEMORY
        first = True
        for key, label in keys:
            kv, jv, bv = k.get(key), j.get(key), b.get(key)
            if kv is None and jv is None:
                continue
            row = [prog if first else "", label]
            first = False
            if base:
                row.append(fmt(bv))
            row.append(fmt(kv))
            if base:
                row.append("%+.0f%%" % (100 * (kv - bv) / bv) if kv is not None and bv else "-")
            row.append(fmt(jv))
            row.append(("%.1fx" % (kv / jv)) if kv is not None and jv else "-")
            rows.append(row)
        for arm, m in arms.items():
            if m is None:
                rows.append([prog if first else "", "%s: every run failed" % arm] + [""] * (len(cols) - 2))
            elif m["failed"]:
                rows.append(["", "%s: %d run(s) failed" % (arm, m["failed"])] + [""] * (len(cols) - 2))
    widths = [max(len(str(r[i])) for r in rows + [cols]) for i in range(len(cols))]
    for r in [cols] + rows:
        print("  ".join(str(c).ljust(w) if i < 2 else str(c).rjust(w) for i, (c, w) in enumerate(zip(r, widths))))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("results")
    ap.add_argument("--baseline", help="an earlier results file to compare klio against")
    a = ap.parse_args()
    results = json.load(open(a.results))
    baseline = json.load(open(a.baseline)) if a.baseline else None
    report(results, baseline)


if __name__ == "__main__":
    main()
