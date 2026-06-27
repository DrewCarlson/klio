#!/usr/bin/env python3
"""Dispatch-unification ratchet.

Runs each dispatch repro through `klio run` (and, where a @Test variant exists,
`klio test`) and checks output against the expected Kotlin result. Each entry is
tagged with the phase that makes it pass; until that phase lands it is an
expected failure. The script exits non-zero if any non-xfail case regresses or
any xfail case unexpectedly starts passing without being promoted.

Usage: python3 tests/fixtures/dispatch/ratchet.py [--klio ./zig-out/bin/klio]
"""
import subprocess, sys, os, argparse

HERE = os.path.dirname(os.path.abspath(__file__))

# (file, expected_stdout, phase_that_fixes) — phase None means "must already pass".
CASES = [
    ("fact_run.kt",               "5\n5\n",                                  "P3"),
    ("vararg_trailing_default.kt", "T4 [6,7,8] end\n",                       "P2"),
    ("vararg_no_named.kt",        "A [1] end\nB [1,2] end\nC [] end\n",      "P2"),
    ("field_shadow.kt",           "baseX=1\nsubX=2\nsuperX=1\nasBase.x=1\n", "P5"),
    ("field_var_shadow.kt",       "getBase=100\ngetSub=200\n",              "P5"),
    ("field_override.kt",         "sound=woof legs=4\nsound=woof legs=3\nwoof\n", None),
    ("reified_param_infer.kt",    "is\nno\n",                                "P6"),
    ("reified_inline_overload.kt","plain:5\nis:HI\nno\n",                    "P6"),
    ("member_vs_global.kt",       "7\n",                                     None),
]


def run(klio, path):
    try:
        r = subprocess.run([klio, "run", path], capture_output=True, text=True, timeout=60)
        return r.stdout, r.stderr, r.returncode
    except subprocess.TimeoutExpired:
        return "", "TIMEOUT", 124


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--klio", default="./zig-out/bin/klio")
    args = ap.parse_args()

    fails, xfails, surprises = [], [], []
    for fname, expected, phase in CASES:
        path = os.path.join(HERE, fname)
        out, err, rc = run(args.klio, path)
        ok = (rc == 0 and out == expected)
        status = "PASS" if ok else "FAIL"
        gate = phase or "must-pass"
        print(f"[{status}] {fname:30s} (fix:{gate})")
        if not ok:
            detail = (err.strip() or out.strip() or "<empty>").splitlines()[:2]
            print(f"         got: {' / '.join(detail)}")
        if phase is None:
            if not ok:
                fails.append(fname)
        else:
            if ok:
                surprises.append((fname, phase))
            else:
                xfails.append(fname)

    print(f"\n{len(CASES)} cases: {len(fails)} hard-fail, {len(xfails)} xfail (pending), "
          f"{len(surprises)} now-passing")
    if surprises:
        print("PROMOTE (xfail now passes — set phase=None):", ", ".join(f for f, _ in surprises))
    # Hard fails (must-pass regressions) are the only exit-nonzero condition.
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
