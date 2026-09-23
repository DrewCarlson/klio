#!/usr/bin/env python3
"""Compare a class's field layout against the two things that must agree with it:
what construction produces, and what the class declaration says.

`represent/class-layout` in plans/resolved-interpreter.md replaced a field
layout discovered during construction with one fixed per class, and
`represent/publish-layout` moved that layout into the module so a lowering can
read it. Both moves are only safe while the orders agree, so this is the audit
that proves they do.

  KLIO_HOME=$PWD/.klio-local scripts/layout_audit_sweep.py [BIN] [--pattern ...]

Output: the divergence kinds, then the classes behind each, most frequent
first. `no-layout` rows are classes that cannot have a static layout at all —
interfaces, anonymous objects, function-local classes — and are expected.
`extra`, `missing` and `misordered` are construction disagreeing with the
layout; `published-*` and `unpublished` are the published table disagreeing
with the class-declaration walk. All of those are the work.
"""
import argparse
import collections
import concurrent.futures
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROW = re.compile(
    r"^\[KLIO_LAYOUT_AUDIT\] class=(\S+) kind=(\S+)(?: why=(\S+))?"
    r"(?: slot=(\d+) want=(\S+) got=(\S+))? divergent=1"
)
TOTAL = re.compile(r"^\[layout-audit\] classes_agreed=(\d+) classes_divergent=(\d+)")


def is_interactive(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for _ in range(12):
                line = f.readline()
                if not line:
                    break
                if re.search(r"//\s*corpus:\s*interactive", line):
                    return True
    except OSError:
        pass
    return False


def extra_args(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for _ in range(12):
                line = f.readline()
                if not line:
                    break
                m = re.search(r"Run with:\s*klio run\s+(.*)", line)
                if m:
                    return [a for a in m.group(1).split() if not a.endswith(".kt")]
    except OSError:
        pass
    return []


def run_one(binary, path, timeout, env):
    try:
        p = subprocess.run([binary, "run", path] + extra_args(path), cwd=ROOT,
                           capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return None, [], (0, 0)
    except FileNotFoundError:
        return None, [], (0, 0)
    out = p.stderr.decode("utf-8", "replace")
    rows, totals = [], (0, 0)
    for line in out.splitlines():
        m = ROW.match(line)
        if m:
            rows.append((m.group(2), m.group(1), m.group(3), m.group(5), m.group(6)))
            continue
        m = TOTAL.match(line)
        if m:
            totals = (int(m.group(1)), int(m.group(2)))
    return p.returncode, rows, totals


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", nargs="?", default=os.path.join(ROOT, "zig-out/bin/klio-harness"))
    ap.add_argument("--pattern", default="examples/*.kt")
    ap.add_argument("--jobs", type=int, default=min(12, os.cpu_count() or 1))
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--kind", help="list every class for this divergence kind")
    args = ap.parse_args()

    files = [f for f in sorted(glob.glob(os.path.join(ROOT, args.pattern))) if not is_interactive(f)]
    if not files:
        print("no files matched", args.pattern, file=sys.stderr)
        return 2
    env = dict(os.environ, KLIO_LAYOUT_AUDIT="1")

    by_kind = collections.Counter()
    classes = collections.defaultdict(collections.Counter)
    agreed_classes, divergent_classes = set(), set()
    failed = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(run_one, args.binary, f, args.timeout, env): f for f in files}
        for fut in concurrent.futures.as_completed(futs):
            rc, rows, _ = fut.result()
            if rc != 0:
                failed.append(os.path.relpath(futs[fut], ROOT))
            for kind, cls, why, want, got in rows:
                label = f"{kind}:{why}" if why else kind
                by_kind[label] += 1
                classes[label][cls] += 1
                divergent_classes.add(cls)

    print(f"programs={len(files)} nonzero_exit={len(failed)}")
    print(f"classes with a divergence: {len(divergent_classes)}")
    print()
    for label, n in by_kind.most_common():
        print(f"  {n:>8}  {label}")
    if args.kind:
        print()
        print(f"classes reporting {args.kind}:")
        for cls, n in classes[args.kind].most_common():
            print(f"  {n:>6}  {cls}")
    else:
        for label, _ in by_kind.most_common():
            print()
            print(f"top classes for {label}:")
            for cls, n in classes[label].most_common(args.top):
                print(f"  {n:>6}  {cls}")
    if failed:
        print()
        print(f"{len(failed)} program(s) did not exit 0:", " ".join(sorted(failed)[:10]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
