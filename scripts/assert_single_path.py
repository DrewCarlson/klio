#!/usr/bin/env python3
"""Dispatch-path oracle: run programs under KLIO_TRACE_PATH=1 and assert the
structured `[PATH]` records prove deterministic, single-path dispatch.

Each record is one terminal dispatch:
  [PATH] fn=<simple> recv=<label> argc=<n> args=<tags> decl=<fqn>[#<fid>] path=<tag>

Assertions, per program:
  1. DETERMINISM — every call shape (fn, recv, argc, args) resolves to exactly
     one declaration (decl). The arg shape is part of the key because Kotlin
     overloads legitimately map one (fn, recv) to several declarations.
  2. SINGLE PATH — every (fn, recv) is handled by exactly one dispatch-path
     group. Grouping rules (mechanism-level, never per-program or per-name):
       * call_value_closure / hof_invoke / coroutine_closure collapse into one
         'closure_body' group: the three closure execution sites are
         behaviorally unified (same body FuncId, same shared-Cell captures,
         same real top-level env) but structurally distinct, and the same
         closure body legitimately reaches all three (direct call, stdlib
         HOF, coroutine driver). A NEW tag appearing in this group is still a
         failure: only the three known sites collapse.
       * A closure-trio record over a NAMED declaration (a function-reference
         wrapper around a top-level fn) joins the direct-call group instead —
         see path_group below.
       * Sub-dispatch tags are excluded: default-arg thunks, ctor/property
         init thunks, top-level property init, and the intrinsic_* native
         terminals all run UNDER a primary dispatch — they are not an
         alternative path for it. Their records still feed assertion 1.
  3. RERUN STABILITY — with --rerun N (default 2) the record set must be
     identical across runs, catching hash-iteration / order-dependent
     resolution flips that byte-identical stdout cannot reveal.

There is no allowlist mechanism: a violation is a dispatch bug to root-cause
(or, if genuinely correct behavior, a documented grouping rule above), never
an exemption.

Usage: scripts/assert_single_path.py [--bin BIN] [--rerun N] [--timeout S]
                                     [--list-fail] [globs...]
Default corpus: examples/*.kt + tests/fixtures/coroutine_smoke/*.kt.
Exit 0 iff every program passes all three assertions (and exits 0 itself).
"""
import argparse
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

RECORD_RE = re.compile(
    r"^\[PATH\] fn=(\S*) recv=(\S+) argc=(\d+) args=(\S+) decl=(\S+) path=(\S+)$"
)

CLOSURE_BODY = {"call_value_closure", "hof_invoke", "coroutine_closure"}

SUB_DISPATCH = {
    "call_func_default_thunk",
    "call_func_named_thunk",
    "default_thunk",
    "member_default_thunk",
    "ctor_thunk",
    "top_level_init",
}


def path_group(tag, fn):
    """The logical dispatch-path group a record's tag belongs to.

    The closure trio collapses to 'closure_body' for anonymous bodies. A
    closure-trio record over a NAMED declaration is a function-reference
    wrapper: the runtime wraps a top-level function in a transparent
    IrClosure value (late-bound global lookup, `::ref`), and executing the
    wrapper runs the named declaration's own lowered body — the same body a
    direct call runs via call_func. Both forms legitimately coexist in one
    program (a statically bound `f(x)` next to `f` flowing as a value), so
    the wrapper joins the direct-call group. No detection is lost: assertion
    1 separately requires both forms to land on the same declaration, and a
    cross-run form flip changes the record set, failing assertion 3.
    """
    if tag in CLOSURE_BODY:
        return "closure_body" if fn == "<lambda>" else "call_func"
    return tag


def fn_identity(fn, decl):
    """The symbol identity a record's assertions key on.

    Named declarations key on the name: the assertions then check that name
    resolution picks one declaration per call shape. Anonymous functions have
    no symbol name — every lambda lowers to fn=<lambda>
    (src/ir/lower/lambda_body.zig), so the name denotes nothing and two
    distinct lambdas sharing a call shape is not a resolution decision. Their
    only identity is the declaration itself; fold it into the key so each
    individual lambda is asserted separately (one decl trivially, and one
    dispatch-path group meaningfully).
    """
    return f"{fn}:{decl}" if fn == "<lambda>" else fn


def is_sub_dispatch(tag):
    return tag in SUB_DISPATCH or tag.startswith("intrinsic_")


def run_once(binary, path, timeout):
    """One traced run: (returncode|None, set of record tuples, raw stderr)."""
    env = dict(os.environ, KLIO_TRACE_PATH="1")
    try:
        p = subprocess.run(
            [binary, "run", path],
            cwd=ROOT, capture_output=True, timeout=timeout, env=env,
        )
    except subprocess.TimeoutExpired:
        return None, set(), "<timeout>"
    except FileNotFoundError:
        return None, set(), "<binary-not-found>"
    records = set()
    err = p.stderr.decode("utf-8", "replace")
    for line in err.splitlines():
        m = RECORD_RE.match(line)
        if m:
            records.add(m.groups())
    return p.returncode, records, err


def check_file(binary, path, rerun, timeout):
    """Returns a list of violation strings (empty = pass) and a record count."""
    runs = []
    for i in range(max(1, rerun)):
        rc, records, err = run_once(binary, path, timeout)
        if rc != 0:
            return [f"run {i + 1}: exit {rc}"], 0
        runs.append(records)

    violations = []

    # 3. RERUN STABILITY: every run produced the same record set.
    base = runs[0]
    for i, rs in enumerate(runs[1:], start=2):
        if rs != base:
            gained = sorted(rs - base)
            lost = sorted(base - rs)
            sample = (gained or lost)[0]
            violations.append(
                f"rerun-unstable: run {i} differs from run 1 "
                f"(+{len(gained)}/-{len(lost)} records; e.g. {sample})"
            )
            break

    merged = set().union(*runs)

    # 1. DETERMINISM: one decl per call shape, across all runs.
    by_shape = {}
    for fn, recv, argc, args_tags, decl, tag in merged:
        by_shape.setdefault(
            (fn_identity(fn, decl), recv, argc, args_tags), set()
        ).add(decl)
    for key, decls in sorted(by_shape.items()):
        if len(decls) > 1:
            fn, recv, argc, args_tags = key
            violations.append(
                f"nondeterministic-decl: fn={fn} recv={recv} argc={argc} "
                f"args={args_tags} -> {sorted(decls)}"
            )

    # 2. SINGLE PATH: one path group per (fn, recv), sub-dispatch excluded.
    by_target = {}
    for fn, recv, _argc, _args_tags, decl, tag in merged:
        if is_sub_dispatch(tag):
            continue
        by_target.setdefault((fn_identity(fn, decl), recv), set()).add(path_group(tag, fn))
    for (fn, recv), groups in sorted(by_target.items()):
        if len(groups) > 1:
            violations.append(
                f"multi-path: fn={fn} recv={recv} -> {sorted(groups)}"
            )

    return violations, len(merged)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(ROOT, "zig-out/bin/klio"))
    ap.add_argument("--rerun", type=int, default=2,
                    help="runs per program; record sets must match")
    ap.add_argument("--timeout", type=float, default=60.0)
    ap.add_argument("--list-fail", action="store_true")
    ap.add_argument("patterns", nargs="*",
                    default=["examples/*.kt", "tests/fixtures/coroutine_smoke/*.kt"])
    args = ap.parse_args()

    files = []
    for pat in args.patterns:
        files.extend(sorted(glob.glob(os.path.join(ROOT, pat))))
    if not files:
        print("no files matched", args.patterns, file=sys.stderr)
        return 2

    passed, failed = 0, []
    for f in files:
        rel = os.path.relpath(f, ROOT)
        violations, n = check_file(args.bin, f, args.rerun, args.timeout)
        if not violations:
            passed += 1
            print(f"  ok   {rel} ({n} records)")
        else:
            failed.append((rel, violations))
            print(f"  FAIL {rel}: {violations[0]}")

    print(f"\nSINGLE-PATH: {passed}/{len(files)} passed, {len(failed)} failed "
          f"(rerun={args.rerun})")
    if failed:
        rel, violations = failed[0]
        print(f"first offender: {rel}")
        for v in violations[:10]:
            print(f"  {v}")
        if args.list_fail:
            for rel, violations in failed[1:]:
                print(f"FAIL {rel}:")
                for v in violations[:5]:
                    print(f"  {v}")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
