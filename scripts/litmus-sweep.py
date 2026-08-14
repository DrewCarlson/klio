#!/usr/bin/env python3
"""Sweep the threaded-litmus fixtures through a klio harness binary.

Fast out-of-process mirror of the `parity_threaded_litmus` itest suite:
each `tests/fixtures/threaded_litmus/*.kt` runs through `<harness> run`
and its stdout is checked against the fixture's leading `//> ` lines
(`//>! ` lines pin a failing run whose error must contain each
substring). Use during iteration instead of rebuilding the itest binary.

Usage: python3 scripts/litmus-sweep.py [harness] [--filter substr]
"""
import subprocess, sys, os, glob

args = sys.argv[1:]
harness = "zig-out/bin/klio-harness"
name_filter = None
i = 0
while i < len(args):
    if args[i] == "--filter":
        name_filter = args[i + 1]
        i += 2
    else:
        harness = args[i]
        i += 1

DIR = "tests/fixtures/threaded_litmus"


def expected(path):
    # `//>` expectation lines may sit at the top of the file or trail it
    # (several litmus programs keep them after `main`); scan every line.
    # The old head-only scan stopped at the first code line, so a
    # bottom-annotated file compared against an empty expectation and
    # failed on every run — tl_yield_cross_thread_teardown read as a
    # permanent "flake".
    out_lines, errs = [], []
    for line in open(path):
        t = line.lstrip(" \t")
        if t.startswith("//>!"):
            errs.append(t[4:].strip())
        elif t.startswith("//>"):
            out_lines.append(t[3:].lstrip(" ").rstrip("\n").rstrip("\r"))
    return "\n".join(out_lines), errs


passed, failed = 0, []
for f in sorted(glob.glob(f"{DIR}/*.kt")):
    if name_filter and name_filter not in os.path.basename(f):
        continue
    exp_out, exp_errs = expected(f)
    try:
        r = subprocess.run([harness, "run", f], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        failed.append((os.path.basename(f), "TIMEOUT"))
        continue
    got = r.stdout.rstrip("\n")
    if exp_errs:
        ok = r.returncode != 0 and all(e in (r.stderr + r.stdout) for e in exp_errs)
    else:
        ok = r.returncode == 0 and got == exp_out
    if ok:
        passed += 1
    else:
        failed.append((os.path.basename(f), f"rc={r.returncode}"))
        # A flake postmortem needs the actual divergence, not just the
        # verdict: print the got-vs-expected tail (and stderr when the
        # exit code is the miss) at failure time.
        print(f"  --- {os.path.basename(f)} got stdout tail:")
        for line in got.splitlines()[-5:]:
            print(f"      {line!r}")
        if exp_errs or r.returncode != 0:
            for line in r.stderr.splitlines()[-5:]:
                print(f"      [stderr] {line!r}")
        print(f"  --- expected:")
        for line in exp_out.splitlines()[-5:]:
            print(f"      {line!r}")

print(f"litmus: {passed}/{passed+len(failed)}")
for name, why in failed:
    print(f"  FAIL {name} ({why})")
sys.exit(1 if failed else 0)
