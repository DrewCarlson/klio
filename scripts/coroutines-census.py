#!/usr/bin/env python3
"""Per-failure census of the kotlinx-coroutines commonTest suite.

Reproduces `src/itests/coroutines_commontest.zig` exactly — same packs,
same scratch HOME, same support/target split (a file without `@Test` is
passed as a support source, a file with one is a target) — but records
every FAILED test with its error text instead of only counting passes.

  scripts/coroutines-census.py [--extra-support DIR ...] [--filter SUBSTR]
                               [--jobs N] [--json OUT]

`--extra-support DIR` adds every .kt under DIR to the support set of every
target, which is how the `kotlinx.coroutines.testing` (TestBase) surface
gets in front of the child.
"""
import argparse
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEST_ROOT = "kotlin-klio/klio-kotlinx-coroutines/upstream/kotlinx-coroutines-core/common/test"
HOME = "/tmp/klio_coroutines_census_home"
PACKS = [
    ("kotlin-klio/klio-kotlin-test", "target/packs/kotlin.test.klio-pack"),
    ("kotlin-klio/klio-kotlinx-atomicfu", "target/packs/kotlinx.atomicfu.klio-pack"),
    ("kotlin-klio/klio-kotlinx-coroutines", "target/packs/kotlinx.coroutines.klio-pack"),
]
BIN = os.environ.get("KLIO_ITEST_BIN", "zig-out/bin/klio-harness")


def sh(argv, env, timeout=300):
    return subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout)


def install_packs(env):
    for d, artifact in PACKS:
        for argv in ([BIN, "pack", "build", d], [BIN, "pack", "install", artifact]):
            r = sh(argv, env)
            if r.returncode != 0:
                print(f"pack step failed: {' '.join(argv)}\n{r.stderr[:2000]}",
                      file=sys.stderr)
                sys.exit(1)


def collect_kt(d):
    out = []
    for dirpath, _, names in os.walk(os.path.join(ROOT, d)):
        for n in sorted(names):
            if n.endswith(".kt"):
                out.append(os.path.relpath(os.path.join(dirpath, n), ROOT))
    return sorted(out)


def has_test(path):
    with open(os.path.join(ROOT, path), "r", errors="replace") as fh:
        return "@Test" in fh.read()


# `Class.method FAILED` then an indented error line.
FAILED_RE = re.compile(r"^(\S+) FAILED\s*$")


def shape(msg):
    """Collapse an error message to its shape: backticked payloads to `X`,
    numbers to N, so distinct instances of one mechanism group together."""
    s = re.sub(r"`[^`]*`", "`X`", msg)
    s = re.sub(r"\b\d+\b", "N", s)
    return s.strip()


def run_target(target, support, env):
    argv = [BIN, "test"] + support + [target]
    try:
        r = sh(argv, env, timeout=300)
        out = r.stdout
    except subprocess.TimeoutExpired:
        return target, [], [("<TIMEOUT>", "child exceeded 300s")], True
    passed, failed, lines = [], [], out.splitlines()
    for i, line in enumerate(lines):
        m = FAILED_RE.match(line.strip())
        if m:
            err = lines[i + 1].strip() if i + 1 < len(lines) else ""
            failed.append((m.group(1), err))
        elif line.strip().endswith(" PASSED"):
            passed.append(line.strip().rsplit(" ", 1)[0])
    return target, passed, failed, False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extra-support", action="append", default=[])
    ap.add_argument("--filter", default=None)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) - 2))
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    env = dict(os.environ)
    env["HOME"] = HOME
    os.makedirs(HOME, exist_ok=True)
    install_packs(env)

    all_kt = collect_kt(TEST_ROOT)
    support = [p for p in all_kt if not has_test(p)]
    targets = [p for p in all_kt if has_test(p)]
    for d in args.extra_support:
        support += collect_kt(d)
    if args.filter:
        targets = [t for t in targets if args.filter in t]

    print(f"targets={len(targets)} support={len(support)} jobs={args.jobs}")
    results, n_pass, n_fail, timeouts = [], 0, 0, 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(run_target, t, support, env) for t in targets]
        for f in concurrent.futures.as_completed(futs):
            target, passed, failed, timed_out = f.result()
            n_pass += len(passed)
            n_fail += len(failed)
            timeouts += 1 if timed_out else 0
            results.append({"file": target, "passed": passed,
                            "failed": [{"test": t, "err": e} for t, e in failed],
                            "timeout": timed_out})

    print(f"\nCENSUS: {n_pass} passed, {n_fail} failed, {timeouts} timed out"
          f" across {len(targets)} files")

    hist = collections.Counter()
    by_shape = collections.defaultdict(list)
    for r in results:
        for fl in r["failed"]:
            sh_ = shape(fl["err"])
            hist[sh_] += 1
            by_shape[sh_].append(f"{r['file']}::{fl['test']}")
    print("\nFAILURE SHAPES (count, share, shape):")
    for s, c in hist.most_common(25):
        print(f"  {c:5d}  {100.0 * c / max(n_fail, 1):5.1f}%  {s[:110]}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"results": results,
                       "hist": hist.most_common(),
                       "by_shape": {k: v for k, v in by_shape.items()}}, fh, indent=1)
        print(f"\nwrote {args.json}")


if __name__ == "__main__":
    main()
