#!/usr/bin/env python3
"""stdlib-commontest sweep driver: per-file pass counts and failed test
names for a given klio binary, with filtering and a one-command dual
eager gate.

Replaces the session-local perfile/perfail scripts: one invocation can run
a single file, a filtered subset, or the full suite, under eager OFF, ON,
or BOTH (diffing the two and reporting divergence).

Each target runs as one `klio test` child with the same argv shape the
itest harness builds: --only-file=<target>, the actuals as support, every
same-directory sibling target for helper resolution, plus cross-directory
providers of imported `test.*` symbols.

Usage:
  commontest-sweep.py BIN                        # full sweep, failures out
  commontest-sweep.py BIN --filter ArraysTest    # one file (substring match)
  commontest-sweep.py BIN --passes               # per-file pass counts
  commontest-sweep.py BIN --eager both           # dual gate in one command
  commontest-sweep.py BIN --jobs 8
Exit: 0 clean; 1 divergence between eager modes (only with --eager both).
"""

import argparse
import concurrent.futures
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_ROOT = os.path.join(ROOT, "kotlin/libraries/stdlib/test")
ACTUALS = [
    "tests/stdlib_commontest_actuals/PlatformActuals.kt",
    "tests/stdlib_commontest_actuals/EncodingActuals.kt",
    "tests/stdlib_commontest_actuals/JsCollectionFactories.kt",
]
# The scratch HOME the stdlib_commontest itest installs the kotlin.test
# pack into; running that suite once populates it. Override with --home.
CHILD_HOME = "/tmp/klio_itest_stdlibtest_home"
TEST_FILTER = None


def default_jobs():
    """Half the cores. Each child is a whole `klio test` process, so the sweep
    is embarrassingly parallel — but wall time is floored by a few
    compute-heavy straggler files, not by worker count, so using every core
    buys almost nothing while saturating the machine for the sweep's whole
    duration. Longest-first scheduling (the timing cache below) keeps the
    tail overlapped at this width. `KLIO_SWEEP_JOBS` or `--jobs` overrides.
    Children also run under `nice -n 10` so even a wide sweep yields to
    interactive work."""
    env = os.environ.get("KLIO_SWEEP_JOBS")
    if env:
        try:
            return max(1, int(env))
        except ValueError:
            pass
    return max(2, (os.cpu_count() or 4) // 2)


TIMES_CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".sweep-times.json")


def load_times():
    try:
        import json
        with open(TIMES_CACHE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_times(times):
    try:
        import json
        with open(TIMES_CACHE, "w") as f:
            json.dump(times, f, indent=0, sort_keys=True)
    except OSError:
        pass


def collect():
    allkt = []
    for dp, _, fns in os.walk(TEST_ROOT):
        if os.sep + "js" in dp + os.sep:
            continue
        for f in fns:
            if f.endswith(".kt"):
                allkt.append(os.path.relpath(os.path.join(dp, f), ROOT))
    allkt.sort()
    support, targets = list(ACTUALS), []
    for p in allkt:
        text = open(os.path.join(ROOT, p), errors="replace").read()
        (targets if "@Test" in text else support).append(p)
    return targets, support


def imported_test_name(line):
    t = line.strip()
    if not t.startswith("import "):
        return None
    rest = t[len("import "):].strip()
    if not rest.startswith("test."):
        return None
    rest = rest.split()[0].rstrip(";")
    dot = rest.rfind(".")
    if dot < 0:
        return None
    name = rest[dot + 1:]
    if not name or name == "*":
        return None
    return name


def _word(line, w):
    return re.search(r"(?<![A-Za-z0-9_])" + re.escape(w) + r"(?![A-Za-z0-9_])", line)


def declares_top_level(content, name):
    kws = ("val", "var", "fun", "class", "object", "interface", "typealias", "enum")
    for line in content.splitlines():
        if not _word(line, name):
            continue
        if any(_word(line, kw) for kw in kws):
            return True
    return False


def build_providers(targets):
    texts = {t: open(os.path.join(ROOT, t), errors="replace").read() for t in targets}
    imported = set()
    for t in targets:
        for line in texts[t].splitlines():
            n = imported_test_name(line)
            if n:
                imported.add(n)
    provider, ambiguous = {}, set()
    for t in targets:
        for n in imported:
            if declares_top_level(texts[t], n):
                if n in provider:
                    ambiguous.add(n)
                else:
                    provider[n] = t
    for n in ambiguous:
        provider.pop(n, None)
    return provider, texts


def cross_dir_providers(target, provider, texts):
    tdir = os.path.dirname(target)
    out, seen = [], set()
    for line in texts[target].splitlines():
        n = imported_test_name(line)
        if not n:
            continue
        pf = provider.get(n)
        if not pf or pf == target or os.path.dirname(pf) == tdir or pf in seen:
            continue
        seen.add(pf)
        out.append(pf)
    return out


def run_one(binary, target, support, targets, provider, texts, eager):
    tdir = os.path.dirname(target)
    argv = [binary, "test", f"--only-file={target}"] + support
    if TEST_FILTER:
        argv.append(f"--filter={TEST_FILTER}")
    argv += [s for s in targets if s != target and os.path.dirname(s) == tdir]
    argv += cross_dir_providers(target, provider, texts)
    argv.append(target)
    argv = ["nice", "-n", "10"] + argv
    env = dict(os.environ, HOME=CHILD_HOME)
    if os.environ.get("KLIO_SWEEP_DEBUG"):
        print("ARGV", "\n".join(argv), file=sys.stderr)
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=900, env=env)
    except subprocess.TimeoutExpired:
        return target, -1, [("__TIMEOUT__", "")]
    passed = None
    m = re.search(rb"(\d+) passed,", p.stdout)
    if m:
        passed = int(m.group(1))
    fails, lines = [], p.stdout.splitlines()
    for i, line in enumerate(lines):
        fm = re.match(rb"\s*(\S+) FAILED", line)
        if fm:
            reason = lines[i + 1].strip().decode(errors="replace")[:160] if i + 1 < len(lines) else ""
            fails.append((fm.group(1).decode(errors="replace"), reason))
    if passed is None:
        return target, -1, fails or [("__NO_SUMMARY__", no_summary_detail(p))]
    return target, passed, fails


def _dedup(seq):
    seen, out = set(), []
    for x in seq:
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out


def no_summary_detail(p):
    """Preserve the useful failure seam when a test child aborts."""
    stderr = p.stderr.decode(errors="replace")
    tests = re.findall(r"^\[test\] ([^\n]+)$", stderr, re.MULTILINE)
    last_test = tests[-1] if tests else "none"
    panic = re.search(r"^(?:thread \d+ panic:|KGC:|error:)[^\n]*", stderr, re.MULTILINE)
    reason = panic.group(0) if panic else stderr[-300:].strip().splitlines()[0] if stderr.strip() else "no diagnostic"
    gc_lines = re.findall(r"^\[kgc\][^\n]*", stderr, re.MULTILINE)
    gc = f"; {gc_lines[-1]}" if gc_lines else ""
    poison_lines = re.findall(r"^\[GC-POISON\][^\n]*", stderr, re.MULTILINE)
    poison = f"; {poison_lines[-1]}" if poison_lines else ""
    cell_lines = re.findall(r"^\[field-probe\][^\n]*", stderr, re.MULTILINE)
    cell = f"; {cell_lines[-1]}" if cell_lines else ""
    stdout = p.stdout.decode(errors="replace").strip().splitlines()
    out = f"; stdout={stdout[-1]}" if stdout else ""
    if panic and "panic:" in panic.group(0):
        frames = stderr[panic.end():].strip().splitlines()[:50]
        reason += "\n" + "\n".join(frames)
    return f"exit={p.returncode}; last={last_test}; {reason}{gc}{poison}{cell}{out}"[:12000]


run_dir_times = {}


def run_dir(binary, tdir, dir_targets, support, all_targets, provider, texts, eager):
    """Run EVERY run-target in one directory as a SINGLE `klio test` child:
    compile the directory's files (and cross-dir providers) ONCE, then discover
    tests in each target via repeated `--only-file`. This amortizes the
    per-child sibling re-lowering (~40 files, ~7s) across every file in the
    directory instead of paying it once per file. It matches the canonical
    itest, which likewise compiles all files together and runs their tests in
    one process; the sweep only split per-file for parallelism. Returns the
    directory's aggregate pass count and the flat failed-test list."""
    dir_all = [t for t in all_targets if os.path.dirname(t) == tdir]
    cross = []
    for t in dir_targets:
        cross += cross_dir_providers(t, provider, texts)
    compile_files = _dedup(list(support) + dir_all + cross)
    argv = ["nice", "-n", "10", binary, "test"] + [f"--only-file={t}" for t in dir_targets] + compile_files
    if TEST_FILTER:
        argv.append(f"--filter={TEST_FILTER}")
    env = dict(os.environ, HOME=CHILD_HOME)
    if os.environ.get("KLIO_SWEEP_DEBUG"):
        print("ARGV", "\n".join(argv), file=sys.stderr)
    t0 = time.monotonic()
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=1800, env=env)
    except subprocess.TimeoutExpired:
        return tdir, -1, [("__TIMEOUT__", "")]
    run_dir_times[tdir] = time.monotonic() - t0
    passed = None
    m = re.search(rb"(\d+) passed,", p.stdout)
    if m:
        passed = int(m.group(1))
    fails, lines = [], p.stdout.splitlines()
    for i, line in enumerate(lines):
        fm = re.match(rb"\s*(\S+) FAILED", line)
        if fm:
            reason = lines[i + 1].strip().decode(errors="replace")[:160] if i + 1 < len(lines) else ""
            fails.append((fm.group(1).decode(errors="replace"), reason))
    if passed is None:
        return tdir, -1, fails or [("__NO_SUMMARY__", no_summary_detail(p))]
    return tdir, passed, fails


def sweep(binary, run_targets, all_targets, support, provider, texts, eager, jobs, batch=True):
    # Sibling context always comes from ALL targets: a `--filter` narrows
    # which files RUN, never which files compile alongside them — a
    # filtered child missing its same-directory siblings loses their
    # helper declarations (`Sortable`, `assertAlmostEquals`) and fails
    # differently than the full suite.
    #
    # `batch` (default) groups run-targets by directory and runs each directory
    # in one child (compile-once). `--no-batch` restores one child per file
    # (per-file hang isolation; slower).
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        if batch:
            by_dir = {}
            for t in run_targets:
                by_dir.setdefault(os.path.dirname(t), []).append(t)
            # Longest-first: a straggler directory started last serializes the
            # whole tail. Prior-run durations (persisted in .sweep-times.json)
            # order the submissions so the heavy directories overlap the rest.
            known = load_times()
            ordered = sorted(by_dir.items(), key=lambda kv: -known.get(kv[0], 0.0))
            futs = {
                ex.submit(run_dir, binary, d, ts, support, all_targets, provider, texts, eager): d
                for d, ts in ordered
            }
            for f in concurrent.futures.as_completed(futs):
                d, passed, fails = f.result()
                results[d] = (passed, fails)
            merged = load_times()
            merged.update(run_dir_times)
            save_times(merged)
        else:
            futs = {
                ex.submit(run_one, binary, t, support, all_targets, provider, texts, eager): t
                for t in run_targets
            }
            for f in concurrent.futures.as_completed(futs):
                target, passed, fails = f.result()
                results[target] = (passed, fails)
    return results


def render(results, show_passes):
    out = []
    for t in sorted(results):
        passed, fails = results[t]
        if show_passes:
            out.append(f"{passed}\t{t}")
        for name, reason in fails:
            out.append(f"{t}\t{name}\t{reason}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("--filter", default=None, help="substring match on target path")
    ap.add_argument("--test-filter", default=None, help="comma-separated test-name filter passed to klio test")
    ap.add_argument("--passes", action="store_true", help="also print per-file pass counts")
    ap.add_argument("--eager", choices=["off", "on", "both"], default="off",
                    help="accepted and ignored; eager is the only pipeline")
    ap.add_argument("--jobs", type=int, default=default_jobs())
    ap.add_argument("--home", default=None, help="child HOME (pack install scratch)")
    ap.add_argument("--no-batch", action="store_true",
                    help="one child per file (per-file hang isolation) instead of "
                         "the default per-directory compile-once batching")
    args = ap.parse_args()
    global TEST_FILTER
    TEST_FILTER = args.test_filter
    if args.home:
        global CHILD_HOME
        CHILD_HOME = args.home

    targets, support = collect()
    if args.filter:
        matched = [t for t in targets if args.filter in t]
        if not matched:
            print(f"no target matches {args.filter!r}", file=sys.stderr)
            return 2
    else:
        matched = targets
    provider, texts = build_providers(targets)

    modes = {"off": [False], "on": [True], "both": [False, True]}[args.eager]
    per_mode = {}
    for eager in modes:
        results = sweep(args.binary, matched, targets, support, provider, texts, eager,
                        args.jobs, batch=not args.no_batch)
        per_mode[eager] = results
        # Eager is the only pipeline; the mode loop is kept so an existing
        # `--eager both` invocation still works (it just runs twice).
        label = "run"
        lines = render(results, args.passes)
        total_fails = sum(len(f) for _, f in results.values())
        print(f"== {label}: {len(matched)} files, {total_fails} failures")
        for line in lines:
            print(line)

    if len(modes) == 2:
        a, b = per_mode[False], per_mode[True]
        divergent = []
        for t in sorted(set(a) | set(b)):
            pa, fa = a.get(t, (None, []))
            pb, fb = b.get(t, (None, []))
            if pa != pb or [n for n, _ in fa] != [n for n, _ in fb]:
                divergent.append(f"{t}: off={pa} passed/{len(fa)} failed, on={pb} passed/{len(fb)} failed")
        if divergent:
            print(f"== RUN-TO-RUN DIVERGENCE ({len(divergent)} files)")
            for d in divergent:
                print(d)
            return 1
        print("== runs identical")
    return 0


if __name__ == "__main__":
    sys.exit(main())
