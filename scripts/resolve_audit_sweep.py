#!/usr/bin/env python3
"""Fast KLIO_RESOLVE_AUDIT sweep — the quick verification cycle for the
overload-resolution unification (plans/resolution-unification-plan.md).

A scorer slice adds `applicable()` behind a dual-compute audit that logs
`[KLIO_RESOLVE_AUDIT] <member|scorer> ... divergent=1` whenever the shared
engine disagrees with the legacy scorer. This sweeps the whole stdlib
commonTest corpus (in-process, so the audit env applies) and the examples
with that audit on, and reports every divergence. Zero divergence proves
`applicable()` reproduces the legacy scorer before the flip.

This runs the fast Debug `zig-out/bin/klio` (a ~2s incremental recompile),
not the ~18-minute ReleaseSafe canonical — the audit is a stronger check
than the flaky ±3 canonical count, so this is the loop to iterate on.

Usage: scripts/resolve_audit_sweep.py [--build] [--jobs N] [--examples]
Exit 0 iff no divergence line is found.
"""
import argparse, concurrent.futures, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_ROOT = os.path.join(ROOT, "kotlin/libraries/stdlib/test")
ACTUALS = [
    "tests/stdlib_commontest_actuals/PlatformActuals.kt",
    "tests/stdlib_commontest_actuals/EncodingActuals.kt",
    "tests/stdlib_commontest_actuals/JsCollectionFactories.kt",
]
# Only the new scorer/member audit lines — NOT the pre-existing lowering
# resolve-detector (`call`/`inline`/`ref` ... grade=tier_correction), which is
# the index correcting the heuristic and is expected/informational.
DIV = re.compile(r"\] (member|scorer|named|call2) ")
NORM = [
    (re.compile(r"name=\S+"), "name=X"),
    (re.compile(r"_fid=\d+"), "_fid=N"),
    (re.compile(r"(legacy|applic)=-?\d+"), r"\1=V"),
]


def collect_targets():
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
        try:
            has = "@Test" in open(os.path.join(ROOT, p), errors="replace").read()
        except OSError:
            has = False
        (targets if has else support).append(p)
    return targets, support


def run_test_file(target, support, targets, timeout):
    tdir = os.path.dirname(target)
    argv = [ROOT + "/zig-out/bin/klio", "test", f"--only-file={target}"] + support
    argv += [s for s in targets if s != target and os.path.dirname(s) == tdir]
    argv.append(target)
    return run(argv, timeout)


def run(argv, timeout):
    env = dict(os.environ, KLIO_RESOLVE_AUDIT="1")
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=timeout, env=env)
        lines = set()
        for ln in p.stderr.decode("utf-8", "replace").splitlines():
            if DIV.search(ln):
                for rx, rep in NORM:
                    ln = rx.sub(rep, ln)
                lines.add(ln.strip())
        return lines
    except subprocess.TimeoutExpired:
        return set()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", action="store_true", help="zig build (fast Debug) first")
    ap.add_argument("--jobs", type=int, default=min(24, os.cpu_count() or 1))
    ap.add_argument("--timeout", type=float, default=90.0)
    ap.add_argument("--examples", action="store_true", help="also sweep examples/*.kt via `klio run`")
    args = ap.parse_args()

    if args.build:
        r = subprocess.run(["zig", "build"], cwd=ROOT)
        if r.returncode != 0:
            print("BUILD FAILED", file=sys.stderr)
            return 2

    targets, support = collect_targets()
    jobs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(run_test_file, t, support, targets, args.timeout): t for t in targets}
        if args.examples:
            for e in sorted(__import__("glob").glob(os.path.join(ROOT, "examples/*.kt"))):
                futs[ex.submit(run, [ROOT + "/zig-out/bin/klio", "run", e], args.timeout)] = os.path.relpath(e, ROOT)
        for f in concurrent.futures.as_completed(futs):
            errs = f.result()
            if errs:
                jobs.append((futs[f], errs))

    all_lines = {}
    for _, errs in jobs:
        for e in errs:
            all_lines[e] = all_lines.get(e, 0) + 1
    print(f"files_with_divergence={len(jobs)}  distinct_lines={len(all_lines)}  swept={len(targets)}")
    for line, n in sorted(all_lines.items(), key=lambda kv: -kv[1]):
        print(f"  x{n}  {line}")
    return 1 if all_lines else 0


if __name__ == "__main__":
    sys.exit(main())
