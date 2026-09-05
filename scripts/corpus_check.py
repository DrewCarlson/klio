#!/usr/bin/env python3
"""End-to-end corpus oracle: run every examples/*.kt through both the Zig klio
and the Rust klio (the faithfulness reference) and diff stdout.

Usage: scripts/corpus_check.py [--zig BIN] [--rust BIN] [--timeout S] [--list-fail] [glob]
Exit 0 iff every example's Zig stdout matches the Rust reference (or, with
--no-rust, iff every example exits 0).
"""
import argparse
import re
import concurrent.futures
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def is_interactive(path):
    """An example marked `// corpus: interactive` is a live windowed app
    that loops until the user closes its window (maxFrames = -1); it has
    no exit code to assert and is excluded from the corpus run."""
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
    """An example may document required flags in a header comment:
    `// Run with: klio run --feature X/Y examples/foo.kt`. Honor them."""
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


def run(binary, path, timeout):
    try:
        p = subprocess.run(
            [binary, "run", path] + extra_args(path),
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
    ap.add_argument("--allow-shared-home", action="store_true",
                    help="run against the shared ~/.klio data home (its installed packs shadow the tree)")
    ap.add_argument("pattern", nargs="?", default="examples/*.kt")
    args = ap.parse_args()
    home = os.environ.get("KLIO_HOME")
    shared = os.path.expanduser("~/.klio")
    if not args.allow_shared_home and (not home or os.path.realpath(home) == os.path.realpath(shared)):
        print("corpus_check: KLIO_HOME is unset or the shared ~/.klio; its installed packs shadow the tree",
              file=sys.stderr)
        print("  run: scripts/refresh-local-packs.sh && KLIO_HOME=$PWD/.klio-local python3 scripts/corpus_check.py ...",
              file=sys.stderr)
        print("  or pass --allow-shared-home to use ~/.klio on purpose", file=sys.stderr)
        return 2

    files = sorted(glob.glob(os.path.join(ROOT, args.pattern)))
    if not files:
        print("no files matched", args.pattern, file=sys.stderr)
        return 2
    skipped = [f for f in files if is_interactive(f)]
    if skipped:
        files = [f for f in files if f not in set(skipped)]
        print(f"skipping {len(skipped)} interactive example(s): "
              + " ".join(os.path.relpath(f, ROOT) for f in skipped))

    def check(f):
        rel = os.path.relpath(f, ROOT)
        zrc, zout = run(args.zig, f, args.timeout)
        if args.no_rust:
            ok = zrc == 0
            detail = f"zig rc={zrc}"
            # Output-pin the examples the e2e corpus cannot reach. e2e runs
            # programs through the in-process parity pipeline, which loads a
            # different pack surface than the CLI and takes no `--feature`
            # set: the compose scene examples fail there with `unresolved
            # global application` / `PaddingValues`, and a `--feature`
            # example with `Json`. Their expectations therefore live in
            # tests/corpus/expected-cli/ (a .out under expected/ would make
            # e2e run them and fail), and this runner — which uses the real
            # CLI and honors the documented flags — enforces them.
            stem = os.path.basename(f)[: -len(".kt")]
            exp = os.path.join(ROOT, "tests/corpus/expected-cli", stem + ".out")
            if ok and os.path.exists(exp):
                with open(exp, "r", errors="replace") as fh:
                    want = fh.read()
                if zout != want:
                    ok = False
                    detail = f"zig rc={zrc} output != tests/corpus/expected-cli/{stem}.out"
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
