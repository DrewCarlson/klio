#!/usr/bin/env python3
"""End-to-end corpus oracle: run every examples/*.kt through both the Zig klio
and the Rust klio (the faithfulness reference) and diff stdout.

Usage: scripts/corpus_check.py [--zig BIN] [--rust BIN] [--timeout S] [--list-fail] [glob]
Exit 0 iff every example's Zig stdout matches the Rust reference (or, with
--no-rust, iff every example exits 0).
"""
import argparse
import concurrent.futures
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def run(binary, path, timeout):
    try:
        p = subprocess.run(
            [binary, "run", path],
            cwd=ROOT, capture_output=True, timeout=timeout,
        )
        return p.returncode, p.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        return None, "<timeout>"
    except FileNotFoundError:
        return None, "<binary-not-found>"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zig", default=os.path.join(ROOT, "zig-out/bin/klio"))
    ap.add_argument("--rust", default=os.path.join(ROOT, "target/release/klio"))
    ap.add_argument("--no-rust", action="store_true", help="just check Zig exits 0")
    # 60s: several compose examples legitimately run 3-6s solo and the
    # parallel wall inflates 3-8x under oversubscription; 30s sat exactly on
    # the boundary and the failing SET churned run to run. Jobs capped at 12:
    # the box advertises twice the usable cores (shared CPU budget).
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--jobs", type=int, default=min(12, os.cpu_count() or 1))
    ap.add_argument("--list-fail", action="store_true")
    ap.add_argument("pattern", nargs="?", default="examples/*.kt")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(ROOT, args.pattern)))
    if not files:
        print("no files matched", args.pattern, file=sys.stderr)
        return 2

    def check(f):
        rel = os.path.relpath(f, ROOT)
        zrc, zout = run(args.zig, f, args.timeout)
        if args.no_rust:
            ok = zrc == 0
            detail = f"zig rc={zrc}"
        else:
            rrc, rout = run(args.rust, f, args.timeout)
            ok = zrc == 0 and rrc == 0 and zout == rout
            detail = f"zig rc={zrc} rust rc={rrc} stdout {'==' if zout == rout else '!='}"
        return rel, ok, detail, zout if args.no_rust else (zout, rout)

    passed, failed = 0, []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for rel, ok, detail, out in pool.map(check, files):
            if ok:
                passed += 1
            else:
                failed.append((rel, detail, out))

    print(f"\nCORPUS: {passed}/{len(files)} passed, {len(failed)} failed")
    if args.list_fail:
        for rel, detail, _ in failed:
            print(f"  FAIL {rel}: {detail}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
