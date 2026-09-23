#!/usr/bin/env python3
"""Run the corpus under the static site census and the executed dispatch census
and print the totals, so progress on resolution is one command.

Two numbers matter and they answer different questions:

  static   how many SITES in the lowered program name their target, and how
           many re-derive it. Summed over programs: a site that appears in
           every program is counted every time, which is what makes the total
           comparable run to run on a pinned program set.
  executed how many TIMES a site of each class actually ran. A single
           unresolved site in a hot loop outweighs a thousand cold ones.

Usage:
  scripts/site-census-sweep.py [BIN] [--pattern examples/*.kt] [--jobs N]
                               [--timeout S] [--kinds] [--per-program KIND]
                               [--baseline FILE] [--json FILE]

`--baseline FILE` diffs against a previously written `--json` and prints the
delta per kind, which is how a resolution change is reported.

The default binary is the ReleaseSafe harness (`zig build klio-harness`).
"""
import argparse
import concurrent.futures
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SITE_KIND = re.compile(r"^\[site-kind\]\s+(\d+)\s+[\d.]+%\s+(\S+)\s+(\S+)")
SITE_HEAD = re.compile(r"^\[site-census\] coverage=(\S+) funcs=(\d+) walked=(\d+) "
                       r"bodyless=(\d+) unreadable=(\d+) blocks=(\d+) sites=(\d+)")
DISPATCH = re.compile(r"^\[dispatch-stats\]\s+(\d+)\s+[\d.]+%\s+(\S+)")
EXT_FB = re.compile(r"^\[ext-fb\] total=(\d+)")


def is_interactive(path):
    """An example marked `// corpus: interactive` loops until its window is
    closed; it has no exit to wait for and is excluded."""
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
    argv = [binary, "run", path] + extra_args(path)
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    except FileNotFoundError:
        return {"status": "no-binary"}
    out = p.stderr.decode("utf-8", "replace") + p.stdout.decode("utf-8", "replace")
    res = {
        "status": "ok" if p.returncode == 0 else f"rc={p.returncode}",
        "static": {},
        "verdict": {},
        "kind_verdict": {},
        "executed": {},
        "ext_fb": 0,
        "head": None,
    }
    for line in out.splitlines():
        m = SITE_KIND.match(line)
        if m:
            n, verdict, kind = int(m.group(1)), m.group(2), m.group(3)
            res["static"][kind] = res["static"].get(kind, 0) + n
            res["verdict"][verdict] = res["verdict"].get(verdict, 0) + n
            res["kind_verdict"][kind] = verdict
            continue
        m = SITE_HEAD.match(line)
        if m:
            res["head"] = {
                "coverage": m.group(1), "funcs": int(m.group(2)),
                "walked": int(m.group(3)), "bodyless": int(m.group(4)),
                "unreadable": int(m.group(5)), "blocks": int(m.group(6)),
                "sites": int(m.group(7)),
            }
            continue
        m = DISPATCH.match(line)
        if m:
            res["executed"][m.group(2)] = res["executed"].get(m.group(2), 0) + int(m.group(1))
            continue
        m = EXT_FB.match(line)
        if m:
            res["ext_fb"] += int(m.group(1))
    return res


def merge(into, frm):
    for k, v in frm.items():
        into[k] = into.get(k, 0) + v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", nargs="?", default=os.path.join(ROOT, "zig-out/bin/klio-harness"))
    ap.add_argument("--pattern", default="examples/*.kt")
    ap.add_argument("--jobs", type=int, default=min(12, os.cpu_count() or 1))
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--kinds", action="store_true", help="print every kind, not just the unresolved ones")
    ap.add_argument("--per-program", metavar="KIND",
                    help="list each program's count for one kind, highest first")
    ap.add_argument("--json", metavar="FILE", help="write the totals for a later --baseline diff")
    ap.add_argument("--baseline", metavar="FILE", help="diff the totals against a previous --json")
    ap.add_argument("--ceiling", metavar="FILE",
                    help="fail when any unresolved site kind is ABOVE its recorded count in FILE. "
                         "The resolution ratchet: a kind may fall and may not rise, and a kind "
                         "absent from the ceiling may not appear at all.")
    ap.add_argument("--write-ceiling", metavar="FILE",
                    help="record the current unresolved counts as the ceiling")
    ap.add_argument("--cold", action="store_true",
                    help="clear the bake cache first. A warm sweep counts 23 more "
                         "unresolved sites than a cold one, so a ceiling is only "
                         "comparable against the same state.")
    ap.add_argument("--require-resolved", action="store_true",
                    help="also set KLIO_REQUIRE_RESOLVED=1 and report which programs fail")
    ap.add_argument("--allow-shared-home", action="store_true")
    args = ap.parse_args()

    home = os.environ.get("KLIO_HOME")
    shared = os.path.expanduser("~/.klio")
    if not args.allow_shared_home and (not home or os.path.realpath(home) == os.path.realpath(shared)):
        print("site-census-sweep: KLIO_HOME is unset or the shared ~/.klio; its installed "
              "packs shadow the tree", file=sys.stderr)
        print("  run: KLIO_HOME=$PWD/.klio-local scripts/site-census-sweep.py ...", file=sys.stderr)
        print("  or pass --allow-shared-home to use ~/.klio on purpose", file=sys.stderr)
        return 2

    if args.cold:
        import shutil
        shutil.rmtree(os.path.join(home, ".klio", "cache"), ignore_errors=True)

    files = sorted(glob.glob(os.path.join(ROOT, args.pattern)))
    files = [f for f in files if not is_interactive(f)]
    if not files:
        print("no files matched", args.pattern, file=sys.stderr)
        return 2

    env = dict(os.environ, KLIO_SITE_CENSUS="1", KLIO_DISPATCH_STATS="1")
    if args.require_resolved:
        env["KLIO_REQUIRE_RESOLVED"] = "1"

    static, executed, verdict, kind_verdict = {}, {}, {}, {}
    per_program, per_program_executed, failed, ext_fb = {}, {}, [], 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(run_one, args.binary, f, args.timeout, env): f for f in files}
        for fut in concurrent.futures.as_completed(futs):
            f = futs[fut]
            rel = os.path.relpath(f, ROOT)
            r = fut.result()
            if r["status"] != "ok":
                failed.append((rel, r["status"]))
                if r["status"] in ("timeout", "no-binary"):
                    continue
            merge(static, r["static"])
            merge(executed, r["executed"])
            merge(verdict, r["verdict"])
            kind_verdict.update(r["kind_verdict"])
            ext_fb += r["ext_fb"]
            per_program[rel] = r["static"]
            per_program_executed[rel] = r["executed"]

    site_total = sum(verdict.values())
    print(f"programs={len(files)} ok={len(files) - len(failed)} failed={len(failed)}")
    if site_total:
        for v in ("resolved", "unresolved", "dynamic_by_design"):
            n = verdict.get(v, 0)
            print(f"static {v:<18} {n:>12}  {n * 100.0 / site_total:6.2f}%")
    print()
    # Each `[site-kind]` line carries its own verdict, so the filter reads the
    # census rather than duplicating its table here.
    print("static sites, unresolved only (the column that must reach zero):")
    for kind, n in sorted(static.items(), key=lambda kv: -kv[1]):
        if not args.kinds and kind_verdict.get(kind) != "unresolved":
            continue
        print(f"  {n:>12}  {kind_verdict.get(kind, '?'):<18} {kind}")

    if executed:
        print()
        # An executed total summed over the corpus is NOT a representative
        # workload: a handful of deliberate micro-benchmarks run one site
        # millions of times, and `tailrec_forms.kt` alone was 98% of
        # `load_this_or_global` the first time this was measured. The top
        # contributor is printed beside every total so the number cannot be
        # read as a property of the corpus when it is a property of one loop.
        print("executed dispatches (with the top contributing program and its share):")
        for kind, n in sorted(executed.items(), key=lambda kv: -kv[1]):
            top, top_n = "", 0
            for prog, kinds in per_program_executed.items():
                if kinds.get(kind, 0) > top_n:
                    top, top_n = prog, kinds[kind]
            share = f"{top_n * 100.0 / n:5.1f}%" if n else "    -"
            print(f"  {n:>14}  {kind:<28} {share} {top}")
    if ext_fb:
        print(f"  {ext_fb:>14}  ext_fb_total")

    if args.per_program:
        print()
        print(f"per program, {args.per_program}:")
        ranked = sorted(((p, k.get(args.per_program, 0)) for p, k in per_program.items()),
                        key=lambda kv: -kv[1])
        for p, n in ranked:
            if n == 0:
                break
            print(f"  {n:>8}  {p}")

    if failed:
        print()
        print(f"{len(failed)} program(s) did not exit 0:")
        for rel, st in sorted(failed):
            print(f"  {st:<10} {rel}")

    totals = {"static": static, "executed": executed, "verdict": verdict,
              "kind_verdict": kind_verdict, "ext_fb": ext_fb,
              "programs": len(files), "failed": len(failed)}
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(totals, fh, indent=1, sort_keys=True)
        print(f"\nwrote {args.json}")
    if args.baseline:
        with open(args.baseline) as fh:
            base = json.load(fh)
        print("\ndelta against", args.baseline)
        for section in ("static", "executed"):
            keys = sorted(set(base.get(section, {})) | set(totals[section]))
            for k in keys:
                a, b = base.get(section, {}).get(k, 0), totals[section].get(k, 0)
                if a != b:
                    print(f"  {section:<9} {k:<32} {a:>12} -> {b:>12}  ({b - a:+d})")
    rc = 1 if failed else 0

    # The resolution ratchet. The goal is every unresolved kind at zero, and
    # the only way a campaign that long stays honest is that no kind is ever
    # allowed to grow: a lowering change that re-derives one more target by
    # name fails here the day it lands, not at the next census read.
    unresolved_now = {k: n for k, n in static.items()
                      if kind_verdict.get(k) == "unresolved"}
    if args.write_ceiling:
        with open(args.write_ceiling, "w") as fh:
            json.dump({"programs": len(files), "cold": bool(args.cold),
                       "unresolved": unresolved_now},
                      fh, indent=1, sort_keys=True)
        print(f"\nwrote ceiling {args.write_ceiling} "
              f"({len(unresolved_now)} kinds, {sum(unresolved_now.values())} sites)")
    if args.ceiling:
        with open(args.ceiling) as fh:
            ceil = json.load(fh)
        limits = ceil.get("unresolved", {})
        if ceil.get("cold") != bool(args.cold):
            print(f"\nRATCHET: ceiling was recorded {'cold' if ceil.get('cold') else 'warm'} "
                  f"and this run is {'cold' if args.cold else 'warm'}; a warm sweep counts "
                  f"more unresolved sites than a cold one and the two are not comparable",
                  file=sys.stderr)
            return 2
        if ceil.get("programs") != len(files):
            print(f"\nRATCHET: ceiling was recorded over {ceil.get('programs')} programs, "
                  f"this run saw {len(files)}; counts are summed per program and "
                  f"are not comparable", file=sys.stderr)
            return 2
        # What is stable and what is not, both measured. The TOTAL is exact
        # across cold sweeps of one binary (4 111 230 twice) and moves by 23
        # between cold and warm, because resolution a fresh lowering reaches
        # does not entirely survive the image round-trip — so the ceiling
        # names its cache state and the phase matches it. The per-kind SPLIT
        # drifts by a few even cold, as a trade between two kinds at an
        # unchanged total: six sites move between `call_member_by_name` and
        # `call_new_instance`, which is a classification flipping on whether
        # a class was registered when the site was classified, and that
        # depends on the body pool's shard order.
        #
        # So the total is checked exactly and the split with slack. A real
        # regression moves the total; a shard-order flip does not.
        def slack(limit):
            return max(64, limit // 1000)
        over, under, appeared = [], [], []
        for k, n in sorted(unresolved_now.items()):
            if k not in limits:
                appeared.append((k, n))
            elif n > limits[k] + slack(limits[k]):
                over.append((k, limits[k], n))
            elif n < limits[k]:
                under.append((k, limits[k], n))
        print("\nresolution ratchet against", args.ceiling)
        for k, a, b in under:
            print(f"  fell   {k:<32} {a:>12} -> {b:>12}  ({b - a:+d})")
        for k, n in sorted(unresolved_now.items()):
            if k in limits and limits[k] < n <= limits[k] + slack(limits[k]):
                print(f"  drift  {k:<32} {limits[k]:>12} -> {n:>12}  "
                      f"({n - limits[k]:+d}, within {slack(limits[k])})")
        for k, b in appeared:
            print(f"  NEW    {k:<32} {'':>12}    {b:>12}")
        for k, a, b in over:
            print(f"  ROSE   {k:<32} {a:>12} -> {b:>12}  ({b - a:+d})")
        total_ceil = sum(limits.values())
        total_now = sum(unresolved_now.values())
        if total_now > total_ceil:
            print(f"  TOTAL  {total_ceil:>12} -> {total_now:>12}  "
                  f"({total_now - total_ceil:+d})")
        if over or appeared or total_now > total_ceil:
            print(f"\nRATCHET FAILED: total {total_now} over ceiling {total_ceil}; "
                  f"{len(over)} kind(s) rose past slack, {len(appeared)} appeared. "
                  f"A site that re-derives its target by name may not be added; "
                  f"if the rise is intended, say why and re-record with "
                  f"--write-ceiling.", file=sys.stderr)
            rc = 1
        else:
            print(f"  RATCHET OK: {total_now} unresolved sites, ceiling {total_ceil}"
                  f"{f' ({total_now - total_ceil:+d})' if total_now != total_ceil else ''}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
