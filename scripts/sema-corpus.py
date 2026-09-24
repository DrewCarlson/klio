#!/usr/bin/env python3
"""Runs the example corpus through `klio run` and compares each program's
stdout with its expected output in tests/corpus/expected.

Usage: scripts/sema-corpus.py [--klio BIN] [-j N] [--timeout S] [--list]
                              [--failures FILE] [--home DIR] [--no-compose]
                              [glob...]

Prints the count of programs that pass, fail with a wrong output, fail
with an error (grouped by the first line of stderr, numbers folded), or
time out. `--list` prints each program's verdict; `--failures FILE` writes
every failing program with its first stderr lines. The packs come from
`--home` (default: the repo-local `.klio-local` when it holds installed
packs, see scripts/install-local-packs.sh); `--no-compose` leaves out the
programs that use Compose or Mosaic.
"""
import argparse
import concurrent.futures
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def header_lines(path, n=12):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return [f.readline() for _ in range(n)]
    except OSError:
        return []


def is_interactive(path):
    return any(re.search(r"//\s*corpus:\s*interactive", l) for l in header_lines(path))


def extra_args(path):
    for line in header_lines(path):
        m = re.search(r"Run with:\s*klio run\s+(.*)", line)
        if m:
            return [a for a in m.group(1).split() if not a.endswith(".kt")]
    return []


def is_compose(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return False
    return "androidx.compose" in text or "com.jakewharton.mosaic" in text


def fold(line):
    line = re.sub(r"\S+\.kt:\d+:\d+", "<site>", line)
    line = re.sub(r"0x[0-9a-fA-F]+", "0xN", line)
    line = re.sub(r"#\d+", "#N", line)
    return re.sub(r"\d+", "N", line)


def run_one(klio, path, timeout, home):
    name = os.path.splitext(os.path.basename(path))[0]
    want_path = os.path.join(ROOT, "tests", "corpus", "expected", name + ".out")
    if not os.path.exists(want_path):
        return name, "no-expected", ""
    with open(want_path, "r", encoding="utf-8", errors="replace") as f:
        want = f.read()
    env = dict(os.environ)
    if home:
        env["KLIO_HOME"] = home
    try:
        p = subprocess.run([klio, "run", path] + extra_args(path), cwd=ROOT,
                           capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return name, "timeout", ""
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace").strip()
    if out == want and p.returncode == 0:
        return name, "pass", ""
    if err:
        return name, "error", err
    if p.returncode < 0:
        return name, "error", "signal %d" % -p.returncode
    return name, "wrong", "exit %d" % p.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--klio", default=os.path.join(ROOT, "zig-out", "bin", "klio"))
    ap.add_argument("-j", type=int, default=min(8, os.cpu_count() or 4))
    ap.add_argument("--timeout", type=float, default=60)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--failures")
    ap.add_argument("--top", type=int, default=25)
    local = os.path.join(ROOT, ".klio-local")
    ap.add_argument("--home", default=local if os.path.isdir(os.path.join(local, ".klio", "packs")) else None)
    ap.add_argument("--no-compose", action="store_true")
    ap.add_argument("globs", nargs="*")
    args = ap.parse_args()
    pats = args.globs or [os.path.join(ROOT, "examples", "*.kt")]
    paths = sorted({p for pat in pats for p in glob.glob(pat)})
    paths = [p for p in paths if not is_interactive(p)]
    if args.no_compose:
        paths = [p for p in paths if not is_compose(p)]
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as ex:
        futs = [ex.submit(run_one, args.klio, p, args.timeout, args.home) for p in paths]
        for fu in concurrent.futures.as_completed(futs):
            results.append(fu.result())
    results.sort()
    counts = {}
    groups = {}
    for name, verdict, detail in results:
        counts[verdict] = counts.get(verdict, 0) + 1
        if verdict == "error":
            first = detail.splitlines()[0] if detail else ""
            groups.setdefault(fold(first), []).append(name)
        if args.list:
            print("%-12s %s" % (verdict, name))
    total = sum(v for k, v in counts.items() if k != "no-expected")
    print("sema pipeline: %d/%d pass" % (counts.get("pass", 0), total))
    for k in ("pass", "wrong", "error", "timeout", "no-expected"):
        print("  %-12s %d" % (k, counts.get(k, 0)))
    if groups:
        print("\nerrors by first stderr line:")
        for key, names in sorted(groups.items(), key=lambda kv: -len(kv[1]))[:args.top]:
            print("  %4d  %s\n        e.g. %s" % (len(names), key[:200], ", ".join(names[:3])))
    if args.failures:
        with open(args.failures, "w") as f:
            for name, verdict, detail in results:
                if verdict in ("pass", "no-expected"):
                    continue
                f.write("== %s: %s\n%s\n" % (name, verdict, "\n".join(detail.splitlines()[:8])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
