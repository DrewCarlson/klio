#!/usr/bin/env python3
"""Lenient-arm audit sweep: run the example/fixture corpus with KLIO_OR_AUDIT=1
and account for every runtime `arm=member_lenient` dispatch line.

The lenient extension-dispatch pass is designed residue: it only fires for
names in RESIDUE_NAMES (currently the kotlinx coroutine-internal `dispatch`
member-extensions). This sweep proves that claim empirically.

Usage: scripts/or_audit_sweep.py [--bin BIN] [--timeout S] [--jobs N]
Exit 0 iff every deduped lenient line has a name inside RESIDUE_NAMES.
Programs that fail to run are reported informationally; they are not a gate
failure on their own.
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

# The documented designed-residue set for the lenient arm. Any lenient line
# whose name= field falls outside this set fails the sweep.
RESIDUE_NAMES = {"dispatch"}

SWEEP_GLOBS = [
    "examples/*.kt",
    "tests/fixtures/coroutine_smoke/**/*.kt",
    "tests/fixtures/parity_corpus/**/*.kt",
]

LENIENT_RE = re.compile(
    r"^\[KLIO_OR_AUDIT\] run inst=\S+ name=(\S+) arm=member_lenient\b"
)


def run(binary, path, timeout):
    env = dict(os.environ, KLIO_OR_AUDIT="1")
    try:
        p = subprocess.run(
            [binary, "run", path],
            cwd=ROOT, capture_output=True, timeout=timeout, env=env,
        )
        return p.returncode, p.stderr.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return None, "<timeout>"
    except FileNotFoundError:
        return None, "<binary-not-found>"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "zig-out/bin/klio"))
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--jobs", type=int, default=min(24, os.cpu_count() or 1))
    args = ap.parse_args()

    files = []
    for pat in SWEEP_GLOBS:
        files.extend(glob.glob(os.path.join(ROOT, pat), recursive=True))
    files = sorted(set(files))
    if not files:
        print("no files matched", SWEEP_GLOBS, file=sys.stderr)
        return 2

    def check(f):
        rel = os.path.relpath(f, ROOT)
        rc, stderr = run(args.bin, f, args.timeout)
        deduped = sorted({
            line for line in stderr.splitlines() if LENIENT_RE.match(line)
        })
        names = collections.Counter(
            LENIENT_RE.match(line).group(1) for line in deduped
        )
        return rel, rc, names

    rows = []
    failures = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for rel, rc, names in pool.map(check, files):
            if rc != 0:
                failures.append((rel, rc))
            for name in sorted(names):
                rows.append((rel, name, names[name]))

    rows.sort()
    total = sum(n for _, _, n in rows)
    programs_with_lenient = len({rel for rel, _, _ in rows})
    rogue = sorted({name for _, name, _ in rows if name not in RESIDUE_NAMES})

    print(f"swept {len(files)} programs")
    print(f"deduped lenient lines: {total} across {programs_with_lenient} programs")
    if rows:
        print("per-(program, name):")
        for rel, name, n in rows:
            print(f"  {rel}  name={name}  lines={n}")
    if failures:
        print(f"programs that failed to run ({len(failures)}, informational):")
        for rel, rc in sorted(failures):
            print(f"  {rel}  rc={rc}")
    if rogue:
        print(f"FAIL: lenient names outside residue set {sorted(RESIDUE_NAMES)}: {rogue}")
        return 1
    print(f"OK: all lenient names within residue set {sorted(RESIDUE_NAMES)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
