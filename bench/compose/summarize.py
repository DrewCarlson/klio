#!/usr/bin/env python3
"""Summarize bench/compose results: per program, klio against the JVM, and
against an earlier klio run when one is given. A klio-only run compared
with a baseline that has JVM runs takes the JVM numbers from it.

    bench/compose/summarize.py RESULTS.json [MORE.json ...] [--baseline OLDER.json]

Several results files are read as one run, so a JIT-on run and a JIT-off
run of the same build summarize together. Each arm (klio, klio-int, jvm,
jvm-int: -int for the runs with the JIT off) gets a column, and klio's
multiple of the JVM is shown for each mode both ran in.

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


ARMS = ("klio", "klio-int", "jvm", "jvm-int")
PAIRS = (("klio", "jvm"), ("klio-int", "jvm-int"))


def report(results, baseline=None):
    now = by_program(results)
    base = by_program(baseline) if baseline else {}
    # The JVM side does not change with klio: a klio-only run takes the
    # baseline's JVM numbers.
    for prog, arms in now.items():
        for arm in ("jvm", "jvm-int"):
            if arm not in arms and arm in base.get(prog, {}):
                arms[arm] = base[prog][arm]
    present = [a for a in ARMS if any(a in arms for arms in now.values())]
    pairs = [(k, j) for k, j in PAIRS if k in present and j in present]
    compare = bool(base) and "klio" in present
    cols = ["program", "metric"] + (["klio base"] if compare else [])
    for arm in present:
        cols.append(arm)
        if arm == "klio" and compare:
            cols.append("change")
    cols += ["%s/%s" % p for p in pairs]
    rows = []
    for prog in sorted(now):
        arms = now[prog]
        vals = {arm: arms.get(arm) or {} for arm in present}
        b = (base.get(prog) or {}).get("klio") or {}
        keys = (HEADLESS if prog.startswith("hb_") else WINDOW) + MEMORY
        first = True
        for key, label in keys:
            if all(vals[arm].get(key) is None for arm in present):
                continue
            row = [prog if first else "", label]
            first = False
            if compare:
                row.append(fmt(b.get(key)))
            for arm in present:
                v = vals[arm].get(key)
                row.append(fmt(v))
                if arm == "klio" and compare:
                    bv = b.get(key)
                    row.append("%+.0f%%" % (100 * (v - bv) / bv) if v is not None and bv else "-")
            for k, j in pairs:
                kv, jv = vals[k].get(key), vals[j].get(key)
                row.append(("%.1fx" % (kv / jv)) if kv is not None and jv else "-")
            rows.append(row)
        for arm in present:
            if arm not in arms:
                continue
            m = arms[arm]
            if m is None:
                rows.append([prog if first else "", "%s: every run failed" % arm] + [""] * (len(cols) - 2))
            elif m["failed"]:
                rows.append(["", "%s: %d run(s) failed" % (arm, m["failed"])] + [""] * (len(cols) - 2))
    widths = [max(len(str(r[i])) for r in rows + [cols]) for i in range(len(cols))]
    for r in [cols] + rows:
        print("  ".join(str(c).ljust(w) if i < 2 else str(c).rjust(w) for i, (c, w) in enumerate(zip(r, widths))))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("results", nargs="+", help="results files, read as one run")
    ap.add_argument("--baseline", help="an earlier results file to compare klio against")
    a = ap.parse_args()
    results = [r for path in a.results for r in json.load(open(path))]
    baseline = json.load(open(a.baseline)) if a.baseline else None
    report(results, baseline)


if __name__ == "__main__":
    main()
