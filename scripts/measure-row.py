#!/usr/bin/env python3
"""One measured row for plans/resolved-interpreter.md, taken the way its
before row was: every number the done line asks for, in one invocation.

  python3 scripts/measure-row.py [--bin BIN] [--gc-bin BIN] [--home DIR]
                                 [--rounds N] [--only SECTION,...]
                                 [--skip-build] [--fleet-jobs N] [--json OUT]

Run it with nothing else loading the machine; it prints the load average
first. Sections, in order:

  micro       tests/bench/fib.kt, bench_oo.kt, bench_fn.kt and recompose.kt
              (benchRecompose): user CPU, the minimum of N warmed rounds that
              cycle through the four, and benchRecompose's frame loop time
              per frame.
  headline    tests/bench/headline_costs.kt N times (what
              scripts/headline-costs.sh runs): the trivial instruction and the
              cheapest activation, minimum.
  frames      benchRecompose at its 2000 frames and at one frame: activations
              per frame (KLIO_FRAME_COUNT), and on macOS machine instructions
              and cycles per frame (`time -l`, minimum of three), each net of
              the one-frame run.
  throughput  the compose runtime's three throughput-bound tests
              (resumeOnBackgroundThread, derivedStateOfLeak,
              validatePotentialDeadlock), twice each, on runTest's own timeout
              with the fleet's 90 s wall cap as the net: each test's own time
              from its `[test]` line, minimum.
  gc          KLIO_GC_DEBUG's stop-the-world pauses, the runtime/gc-threads
              method: validatePotentialDeadlock alone (runTest's budget
              lifted), the pause sum over the process wall; and the whole
              compose runtime fleet in its grouped children, the pause sum
              over their summed wall. Per kind the median and longest pause,
              and every kind but minor against the 10 ms line.

The first four sections run the ReleaseFast harness (`zig build
klio-harness-fast`, --bin), the gc section the ReleaseSafe harness (`zig build
klio-harness`, --gc-bin), each from a copy taken at the start. The data home is
the repo-local `.klio-local`, refreshed from the tree first
(scripts/refresh-local-packs.sh). --skip-build uses the binaries and the home
as they are.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "tests", "bench")
MICRO = ["fib.kt", "bench_oo.kt", "bench_fn.kt", "recompose.kt"]
THROUGHPUT = [
    "PausableCompositionTests.resumeOnBackgroundThread",
    "CompositionTests.derivedStateOfLeak",
    "RecomposerTests.validatePotentialDeadlock",
]
SECTIONS = ["micro", "headline", "frames", "throughput", "gc"]


def fleet_module():
    spec = importlib.util.spec_from_file_location("compose_fleet", os.path.join(ROOT, "scripts", "compose-fleet.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sh(cmd, env=None, timeout=None):
    return subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)


def build(args):
    print("== build", flush=True)
    r = subprocess.run(["zig", "build", "klio-harness", "klio-harness-fast"], cwd=ROOT)
    if r.returncode != 0:
        sys.exit("measure-row: the harness build failed")
    env = dict(os.environ, KLIO_BIN="zig-out/bin/klio-harness")
    r = subprocess.run(["scripts/refresh-local-packs.sh"], cwd=ROOT, env=env)
    if r.returncode != 0:
        sys.exit("measure-row: refreshing the local packs failed")


def run_env(args, **extra):
    return dict(os.environ, KLIO_HOME=args.home, HOME=args.home, **extra)


TIME_COUNTERS = sys.platform == "darwin"


def timed_run(args, program, env=None):
    """User CPU seconds, stdout and stderr of `BIN run program`; on macOS the
    stderr also carries the run's instructions retired and cycles."""
    time_flags = ["-l", "-p"] if TIME_COUNTERS else ["-p"]
    p = sh(["/usr/bin/time", *time_flags, args.bin, "run", program], env=env or run_env(args), timeout=1800)
    m = re.search(r"^user\s+([0-9.]+)", p.stderr, re.M)
    if p.returncode != 0 or not m:
        tail = (p.stderr.strip().splitlines() or [""])[-1]
        raise RuntimeError(f"{os.path.basename(program)} failed (rc={p.returncode}): {tail}")
    return float(m.group(1)), p.stdout, p.stderr


def micro(args, row):
    print("== micro: user CPU, minimum of %d warmed rounds" % args.rounds, flush=True)
    progs = [os.path.join(BENCH, b) for b in MICRO]
    for p in progs:
        timed_run(args, p)
    users = {b: [] for b in MICRO}
    per_frame = []
    for _ in range(args.rounds):
        for b, p in zip(MICRO, progs):
            user, out, _ = timed_run(args, p)
            users[b].append(user)
            if b == "recompose.kt":
                m = re.search(r"(\d+) us per frame", out)
                if m:
                    per_frame.append(int(m.group(1)))
    for b in MICRO:
        name = b[:-3]
        row[name + "_user_s"] = min(users[b])
        print(f"  {name:12s} {min(users[b]):6.2f} s user (median {statistics.median(users[b]):.2f})")
    if per_frame:
        row["recompose_us_per_frame"] = min(per_frame)
        print(f"  benchRecompose {min(per_frame)} us per frame (frame loop wall, minimum)")


def headline(args, row):
    print("== headline costs: minimum of %d runs" % args.rounds, flush=True)
    prog = os.path.join(BENCH, "headline_costs.kt")
    timed_run(args, prog)
    trivial, activation = [], []
    for _ in range(args.rounds):
        _, out, _ = timed_run(args, prog)
        m = re.search(r"trivial-instruction ([0-9.]+) ns", out)
        if m:
            trivial.append(float(m.group(1)))
        m = re.search(r"cheapest-activation ([0-9.]+) ns", out)
        if m:
            activation.append(float(m.group(1)))
    if trivial:
        row["trivial_instruction_ns"] = min(trivial)
    if activation:
        row["cheapest_activation_ns"] = min(activation)
    print(f"  trivial instruction {min(trivial):.2f} ns, cheapest activation {min(activation):.2f} ns")


def hw_counters(err):
    """Instructions retired and cycles from macOS `time -l`, or None."""
    i = re.search(r"(\d+)\s+instructions retired", err)
    c = re.search(r"(\d+)\s+cycles elapsed", err)
    return (int(i.group(1)), int(c.group(1))) if i and c else None


def frames(args, row):
    """Activations per frame from KLIO_FRAME_COUNT, and the machine
    instructions and cycles per frame, each net of a one-frame run. The
    counter's `insts` counts only the ops that leave the code stream for the
    instruction executor, so it is not reported."""
    print("== frames: benchRecompose per frame, net of a one-frame run (minimum of three each)", flush=True)
    src = open(os.path.join(BENCH, "recompose.kt")).read()
    one = src.replace("const val FRAMES = 2000", "const val FRAMES = 1")
    if one == src:
        print("  skipped: tests/bench/recompose.kt no longer declares `const val FRAMES = 2000`")
        return
    acts, hw = {}, {}
    with tempfile.TemporaryDirectory() as tmp:
        one_path = os.path.join(tmp, "recompose_one.kt")
        open(one_path, "w").write(one)
        runs = ((2000, os.path.join(BENCH, "recompose.kt")), (1, one_path))
        for n, path in runs:
            _, _, err = timed_run(args, path, env=run_env(args, KLIO_FRAME_COUNT="1"))
            m = re.search(r"\[frames\] entries=(\d+) activations=(\d+)", err)
            if not m:
                print(f"  skipped: no [frames] line from the {n}-frame run")
                return
            acts[n] = int(m.group(2))
        # The counters come from runs without the frame counter's increments.
        for _ in range(3):
            for n, path in runs:
                c = hw_counters(timed_run(args, path)[2])
                if c:
                    prev = hw.get(n)
                    hw[n] = c if prev is None else (min(prev[0], c[0]), min(prev[1], c[1]))
    act = (acts[2000] - acts[1]) / 1999
    row["recompose_activations_per_frame"] = round(act)
    line = f"  {act:,.0f} activations per frame"
    if 2000 in hw and 1 in hw:
        ins = (hw[2000][0] - hw[1][0]) / 1999
        cyc = (hw[2000][1] - hw[1][1]) / 1999
        row["recompose_machine_instructions_per_frame"] = round(ins)
        row["recompose_cycles_per_frame"] = round(cyc)
        line += f", {ins:,.0f} machine instructions and {cyc:,.0f} cycles per frame"
    print(line)


def compose_test(args, name, extra_env=None, binary=None):
    """Run one compose runtime test in the fleet's environment; its own seconds,
    its status, the output, the process wall."""
    fleet = fleet_module()
    env = dict(os.environ, HOME=args.home, KLIO_TEST_WALL_CAP="90", KLIO_MAX_WORKERS="3")
    env.update(extra_env or {})
    cmd = [binary or args.bin, "test", "--feature", "kotlinx.coroutines/test", *fleet.collect_sources(),
           "--filter==" + name]
    t0 = time.monotonic()
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, timeout=1800)
    wall = time.monotonic() - t0
    text = p.stdout + p.stderr
    m = re.search(r"\[test\] " + re.escape(name) + r" (PASSED|FAILED) (\d+)ms", text)
    if not m:
        return None, "NO-RESULT", text, wall
    return int(m.group(2)) / 1000.0, m.group(1), text, wall


def throughput(args, row):
    print("== throughput tests: runTest's own timeout, 90 s wall cap, minimum of two", flush=True)
    for name in THROUGHPUT:
        times, statuses = [], []
        for _ in range(2):
            secs, status, _, _ = compose_test(args, name)
            statuses.append(status)
            if secs is not None and status == "PASSED":
                times.append(secs)
        short = name.split(".")[-1]
        if times:
            row[short + "_s"] = min(times)
            print(f"  {short:26s} {min(times):7.2f} s  ({', '.join(statuses)})")
        else:
            row[short + "_s"] = None
            print(f"  {short:26s} did not pass ({', '.join(statuses)})")


# Every stop is a `[kgc]` line with its kind (minor, major, and for a
# concurrent major its initial, slice and remark stops) and `pause_us`, the
# raise to the release. `[kgc-sweep]` lines are the sweeper's, off the pause.
KGC = re.compile(r"^\[kgc\] epoch=\d+ kind=(\S+) .*?\bpause_us=(\d+)", re.M)


def pause_table(texts, wall_s):
    """Pauses by kind from `[kgc]` lines, and their share of `wall_s`."""
    by_kind = {}
    for text in texts:
        for kind, us in KGC.findall(text):
            by_kind.setdefault(kind, []).append(int(us))
    total_us = sum(sum(v) for v in by_kind.values())
    major_class = [us for k, v in by_kind.items() if k != "minor" for us in v]
    return {
        "collections": sum(len(v) for v in by_kind.values()),
        "stopped_s": total_us / 1e6,
        "wall_s": wall_s,
        "share_pct": 100.0 * total_us / 1e6 / wall_s if wall_s else None,
        "kinds": {k: {"n": len(v), "median_ms": statistics.median(v) / 1000.0, "max_ms": max(v) / 1000.0}
                  for k, v in sorted(by_kind.items())},
        "major_class": {"n": len(major_class),
                        "max_ms": max(major_class) / 1000.0 if major_class else 0.0,
                        "over_10ms": sum(1 for us in major_class if us > 10_000)},
    }


def print_pauses(label, t):
    share = f"{t['share_pct']:.2f}%" if t["share_pct"] is not None else "?"
    print(f"  {label}: {t['collections']} pauses, {t['stopped_s']:.2f} s stopped of {t['wall_s']:.1f} s "
          f"wall, {share}")
    for k, v in t["kinds"].items():
        print(f"    {k:8s} {v['n']:6d}  median {v['median_ms']:8.3f} ms  longest {v['max_ms']:8.3f} ms")
    mc = t["major_class"]
    print(f"    every kind but minor: {mc['n']}, longest {mc['max_ms']:.2f} ms, over 10 ms: {mc['over_10ms']}")


def gc(args, row):
    """The gc-threads method: the ReleaseSafe harness, the pause sum over the
    process wall for validatePotentialDeadlock alone (runTest's budget lifted,
    so a slow collector shows as time rather than a failure), and over the
    summed wall of the fleet's grouped children."""
    print(f"== gc pauses: KLIO_GC_DEBUG on {os.path.basename(args.gc_bin)}", flush=True)
    name = "RecomposerTests.validatePotentialDeadlock"
    secs, status, text, wall = compose_test(args, name, {
        "KLIO_GC_DEBUG": "1", "KLIO_HOME": args.home, "KLIO_TEST_WALL_CAP": "1200",
        "kotlinx_coroutines_test_default_timeout": "900s"}, binary=args.gc_bin)
    t = pause_table([text], wall)
    t["test_s"], t["status"] = secs, status
    row["gc_validatePotentialDeadlock"] = t
    print_pauses(f"validatePotentialDeadlock ({status}, test {secs} s)", t)

    logdir = os.path.join(ROOT, ".fleet-logs")
    env = dict(os.environ, KLIO_GC_DEBUG="1")
    cmd = [sys.executable, "scripts/compose-fleet.py", "--jobs", str(args.fleet_jobs), "--home", args.home,
           "--bin", args.gc_bin, "--allow-stale"]
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
    walls = [float(m.group(1)) for ln in lines for m in [re.search(r"wall=([0-9.]+)s", ln)] if m]
    names = [ln.split(":")[0] for ln in lines if re.search(r"wall=[0-9.]+s", ln)]
    texts = []
    for n in names:
        try:
            texts.append(open(os.path.join(logdir, n + ".log"), errors="replace").read())
        except OSError:
            pass
    summary = next((ln for ln in lines if ln.startswith("fleet:")), "fleet: no summary")
    t = pause_table(texts, sum(walls))
    t["summary"] = summary
    row["gc_fleet"] = t
    print_pauses(f"fleet ({summary[7:]}; wall summed over {len(walls)} children)", t)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--bin", default=os.path.join(ROOT, "zig-out", "bin", "klio-harness-fast"),
                    help="the binary for micro, headline, frames and throughput (default the ReleaseFast harness)")
    ap.add_argument("--gc-bin", default=os.path.join(ROOT, "zig-out", "bin", "klio-harness"),
                    help="the binary for the gc section (default the ReleaseSafe harness)")
    ap.add_argument("--home", default=os.path.join(ROOT, ".klio-local"))
    ap.add_argument("--rounds", type=int, default=5)
    ap.add_argument("--only", default=",".join(SECTIONS))
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--fleet-jobs", type=int, default=4)
    ap.add_argument("--json", help="also write the row as JSON here")
    args = ap.parse_args()
    args.home = os.path.abspath(args.home)
    only = [s.strip() for s in args.only.split(",") if s.strip()]
    for s in only:
        if s not in SECTIONS:
            sys.exit(f"measure-row: unknown section {s}; one of {', '.join(SECTIONS)}")

    head = sh(["git", "rev-parse", "--short", "HEAD"]).stdout.strip()
    dirty = bool(sh(["git", "status", "--porcelain", "--", "src", "kotlin-klio"]).stdout.strip())
    load = os.getloadavg()
    print(f"measure-row: {head}{' (dirty)' if dirty else ''}, binaries {os.path.relpath(args.bin, ROOT)} "
          f"and {os.path.relpath(args.gc_bin, ROOT)}, home {os.path.relpath(args.home, ROOT)}")
    print(f"load average {load[0]:.2f} {load[1]:.2f} {load[2]:.2f} on {os.cpu_count()} cores"
          + ("  (busy: numbers will read high)" if load[0] > 2 else ""))
    if not args.skip_build:
        build(args)

    row = {"commit": head, "dirty": dirty, "binary": os.path.relpath(args.bin, ROOT),
           "gc_binary": os.path.relpath(args.gc_bin, ROOT), "load": load[0]}
    # Run copies: a rebuild while the row runs would otherwise swap a binary
    # under it.
    with tempfile.TemporaryDirectory() as snap:
        for attr in ("bin", "gc_bin"):
            path = os.path.abspath(getattr(args, attr))
            if not os.access(path, os.X_OK):
                sys.exit(f"measure-row: no binary at {path}")
            copy = os.path.join(snap, attr + "-" + os.path.basename(path))
            shutil.copy2(path, copy)
            setattr(args, attr, copy)
        for s in SECTIONS:
            if s in only:
                try:
                    globals()[s](args, row)
                except (RuntimeError, subprocess.TimeoutExpired) as e:
                    print(f"  {s}: {e}")
                    row[s + "_error"] = str(e)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(row, f, indent=2)
        print(f"row written to {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
