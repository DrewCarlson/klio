#!/usr/bin/env python3
"""Per-class compose-runtime commontest fleet, mirroring the itest gate.

Runs each test class as its own `klio-harness test <all sources> --filter=<Class>`
child in the same environment the compose_plugin_commontest itest uses
(HOME-scoped data home, capped coroutine-test timeout,
per-test wall cap), and prints a per-class pass/fail summary plus a census of
failure signatures. This is the measurement loop for compose stability: a
one-class check is ~1 min, the full fleet ~10-15 min at 4 jobs, against the
itest's one-shot recompile-everything cost.

Usage:
  python3 scripts/compose-fleet.py [--filter Class] [--jobs N] [--home DIR]

The data home must already hold installed packs (run the itest once, or
`klio-harness pack build/install` the five compose packs into it). Per-class
logs land in .fleet-logs/ (gitignored) for drill-down.
"""

import argparse
import os
import re
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
UPSTREAM = "kotlin-klio/klio-compose-runtime/upstream/compose/runtime"
ROOTS = [
    UPSTREAM + "/runtime-test-utils/src/commonMain/kotlin",
    UPSTREAM + "/runtime/src/commonTest/kotlin",
    UPSTREAM + "/runtime/src/nonEmulatorCommonTest/kotlin",
    "tests/compose_commontest_actuals",
]


def collect_sources():
    srcs = []
    for root in ROOTS:
        for dirpath, _, files in os.walk(os.path.join(REPO, root)):
            for f in sorted(files):
                if f.endswith(".kt"):
                    srcs.append(os.path.relpath(os.path.join(dirpath, f), REPO))
    return sorted(srcs)


def test_classes(srcs):
    classes = []
    for f in srcs:
        stem = os.path.basename(f)[:-3]
        try:
            text = open(os.path.join(REPO, f)).read()
        except OSError:
            continue
        if "@Test" in text and ("class " + stem) in text:
            classes.append(stem)
    return sorted(set(classes))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--filter", help="only classes containing this substring")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--home", default="/tmp/klio_itest_compose_plugin_home")
    ap.add_argument("--timeout", type=int, default=0, help="per-child wall cap (s); 0 = auto (600 per-class, 2400 grouped)")
    ap.add_argument("--per-class", action="store_true",
                    help="one child per class (per-class hang isolation) instead "
                         "of the default grouped children (one lowering per job)")
    args = ap.parse_args()

    if not os.path.isdir(os.path.join(args.home, ".klio", "packs")):
        sys.exit(f"no installed packs under {args.home}/.klio/packs — "
                 "run the compose itest once or pack build/install into it")

    srcs = collect_sources()
    classes = test_classes(srcs)
    if args.filter:
        classes = [c for c in classes if args.filter in c]
    # Grouped mode (default): partition the classes into `jobs` children so
    # the 68-file lowering runs `jobs` times instead of once per class —
    # per-class children spent ~60% of every fleet run re-lowering the same
    # sources. The comma filter selects each group's classes in one child.
    # Round-robin by name keeps the heavy classes spread across groups.
    groups = None
    if not args.per_class and len(classes) > args.jobs:
        groups = [classes[i::args.jobs] for i in range(args.jobs)]
    if args.timeout == 0:
        args.timeout = 2400 if groups is not None else 600
    logdir = os.path.join(REPO, ".fleet-logs")
    os.makedirs(logdir, exist_ok=True)

    env = {
        **os.environ,
        "HOME": args.home,
        "kotlinx_coroutines_test_default_timeout": "10s",
        "KLIO_TEST_WALL_CAP": "90",
        # Bound each child's dispatcher pool: a concurrent-test class
        # otherwise fans out toward the 64-worker ceiling and jobs
        # children multiply into full-machine saturation.
        "KLIO_MAX_WORKERS": "3",
    }

    signatures = Counter()
    totals = Counter()

    def run(cls):
        # `cls` is a class name (per-class mode) or a list (grouped mode).
        members = cls if isinstance(cls, list) else [cls]
        cls = members[0] if len(members) == 1 else ("group-" + members[0])
        log = os.path.join(logdir, cls + ".log")
        with open(log, "w") as out:
            try:
                subprocess.run(
                    ["nice", "-n", "10", "zig-out/bin/klio-harness", "test",
                     *srcs, "--filter=" + ",".join(members)],
                    cwd=REPO, stdout=out, stderr=subprocess.STDOUT,
                    timeout=args.timeout, env=env,
                )
            except subprocess.TimeoutExpired:
                return f"{cls}: TIMEOUT"
        text = open(log, errors="replace").read()
        for m in re.finditer(r"FAILED\n    (.+)", text):
            signatures[m.group(1).strip()[:100]] += 1
        m = re.findall(r"(\d+) tests, (\d+) passed, (\d+) failed, (\d+) skipped", text)
        if m:
            tot, ok, bad, skip = (int(x) for x in m[-1])
            totals.update(total=tot, passed=ok, failed=bad, skipped=skip)
            return f"{cls}: total={tot} passed={ok} failed={bad} skipped={skip}"
        return f"{cls}: NO-SUMMARY"

    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for line in ex.map(run, groups if groups is not None else classes):
            print(line, flush=True)

    print(f"\nfleet: {totals['passed']} passed, {totals['failed']} failed, "
          f"{totals['skipped']} skipped across {len(classes)} classes")
    if signatures:
        print("\nfailure signatures:")
        for sig, n in signatures.most_common(20):
            print(f"  {n:4d}  {sig}")


if __name__ == "__main__":
    main()
