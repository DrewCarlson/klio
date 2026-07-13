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


def default_jobs():
    """One child per core, less a couple for the driver and the OS. Each child is
    a whole `klio test` process (its own stdlib load), so the sweep is
    embarrassingly parallel and the old fixed 6 left most of a big box idle."""
    return max(2, (os.cpu_count() or 4) - 2)


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
    argv += [s for s in targets if s != target and os.path.dirname(s) == tdir]
    argv += cross_dir_providers(target, provider, texts)
    argv.append(target)
    env = dict(os.environ, HOME=CHILD_HOME)
    if eager:
        env["KLIO_EAGER"] = "1"
    else:
        env.pop("KLIO_EAGER", None)
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
        return target, -1, fails or [("__NO_SUMMARY__", p.stderr[-160:].decode(errors="replace"))]
    return target, passed, fails


def sweep(binary, run_targets, all_targets, support, provider, texts, eager, jobs):
    # Sibling context always comes from ALL targets: a `--filter` narrows
    # which files RUN, never which files compile alongside them — a
    # filtered child missing its same-directory siblings loses their
    # helper declarations (`Sortable`, `assertAlmostEquals`) and fails
    # differently than the full suite.
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as ex:
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
    ap.add_argument("--passes", action="store_true", help="also print per-file pass counts")
    ap.add_argument("--eager", choices=["off", "on", "both"], default="off")
    ap.add_argument("--jobs", type=int, default=default_jobs())
    ap.add_argument("--home", default=None, help="child HOME (pack install scratch)")
    args = ap.parse_args()
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
        results = sweep(args.binary, matched, targets, support, provider, texts, eager, args.jobs)
        per_mode[eager] = results
        label = "eager-on" if eager else "eager-off"
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
            print(f"== EAGER DIVERGENCE ({len(divergent)} files)")
            for d in divergent:
                print(d)
            return 1
        print("== eager ON/OFF identical")
    return 0


if __name__ == "__main__":
    sys.exit(main())
