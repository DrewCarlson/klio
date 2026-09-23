#!/usr/bin/env python3
"""Prove, or disprove, that committing an extension pick at lowering agrees
with the one the runtime's by-name walk serves.

`resolve/extensions` in plans/resolved-interpreter.md wants extension dispatch
decided at lowering. The resolver already ranks candidates and often leaves
exactly one, withholding only because an argument's static type is unknown
(`[no-ext] unknown_args_singleton`). Committing that pick looked safe and was
not: it bound the wrong `toDuration` overload and broke three programs. The
difference between "looked safe" and "is safe" is this sweep.

`KLIO_EXT_AUDIT=1` prints, at lowering, the declaration a commit WOULD name:

    [KLIO_EXT_AUDIT] would name=<n> recv=<head> fqn=<f> argsknown=<0|1> recvrel=<0|1>

and, at run time, the declaration the by-name walk actually serves:

    [KLIO_EXT_AUDIT] ran name=<n> recv=<head> fqn=<f>

Joined on (name, receiver head), a key where the two disagree is a call the
commit would decide differently from the interpreter — exactly the failure the
reverted change shipped. A key the runtime never reaches is unproven, not
proven: it is reported separately.

**The join is one-directional evidence.** The key aggregates every call site
that shares a name and a receiver head, and different sites see different
candidate sets, so a divergence proves a criterion unsound while an absence of
divergence proves nothing.

The per-site rows are what make an absence mean something. Lowering stamps the
pick it withheld on the instruction, the executing member-call arm publishes it,
and whichever extension serve answers compares the two:

    [KLIO_EXT_AUDIT] site name=<n> agree|diverge|not-served lowering=<f> runtime=<f> besttier=<0|1>

`besttier=1` marks the narrower criterion `resolve/extensions` proposes to
commit: the winner is the sole candidate at the best applicability tier and the
receiver head is not a type parameter. The report counts both, so the sweep says
in one run whether the broad criterion is sound, whether the narrow one is, and
how much of the corpus each covers.

  KLIO_HOME=$PWD/.klio-local scripts/ext_audit_sweep.py [BIN] [--pattern ...]

With `KLIO_EXT_AUDIT=cands` the resolver also logs the candidates that
survived its scope, visibility and shape filters, with their tiers, and each
divergence then says whether the runtime's winner was ever a candidate at all.
"That is not a candidate here" and "that is a candidate lowering ranked lower"
are different bugs.

Exit 0 iff no key diverges.
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
WOULD = re.compile(
    r"^\[KLIO_EXT_AUDIT\] would name=(\S+) recv=(\S+) fqn=(\S+) argsknown=(\d) recvrel=(\d) besttier=(\d)"
)
RAN = re.compile(r"^\[KLIO_EXT_AUDIT\] ran name=(\S+) recv=(\S+) fqn=(\S+)")
SITE = re.compile(
    r"^\[KLIO_EXT_AUDIT\] site name=(\S+) (\S+) lowering=(\S+) runtime=(\S+) kind=(\d) in=(\S*)"
)
CAND = re.compile(r"^\[KLIO_EXT_AUDIT\] cand name=(\S+) recv=(\S+) fqn=(\S+) tier=(\d+)")


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


def run_one(binary, path, timeout, env, args_besttier=False):
    try:
        p = subprocess.run([binary, "run", path] + extra_args(path), cwd=ROOT,
                           capture_output=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return None
    except FileNotFoundError:
        return None
    would, ran = collections.defaultdict(set), collections.defaultdict(set)
    cand = collections.defaultdict(set)
    sites = collections.Counter()
    for line in p.stderr.decode("utf-8", "replace").splitlines():
        m = SITE.match(line)
        if m:
            sites[(m.group(1), m.group(2), m.group(3), m.group(4), int(m.group(5)), m.group(6))] += 1
            continue
        m = WOULD.match(line)
        if m:
            if not args_besttier or m.group(6) == "1":
                would[(m.group(1), m.group(2))].add(m.group(3))
            continue
        m = RAN.match(line)
        if m:
            ran[(m.group(1), m.group(2))].add(m.group(3))
            continue
        m = CAND.match(line)
        if m:
            cand[(m.group(1), m.group(2))].add((m.group(3), int(m.group(4))))
    return p.returncode, would, ran, cand, sites


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", nargs="?", default=os.path.join(ROOT, "zig-out/bin/klio-harness"))
    ap.add_argument("--pattern", default="examples/*.kt")
    ap.add_argument("--jobs", type=int, default=min(12, os.cpu_count() or 1))
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--besttier", action="store_true",
                    help="only count a would-commit when the winner is the unique best-tier candidate")
    ap.add_argument("--cands", action="store_true",
                    help="also log the candidate set lowering ranked, so a divergence says\nwhether the runtime's winner was ever a candidate")
    args = ap.parse_args()

    files = [f for f in sorted(glob.glob(os.path.join(ROOT, args.pattern))) if not is_interactive(f)]
    if not files:
        print("no files matched", args.pattern, file=sys.stderr)
        return 2
    env = dict(os.environ, KLIO_EXT_AUDIT="cands" if args.cands else "1")

    would, ran = collections.defaultdict(set), collections.defaultdict(set)
    cand = collections.defaultdict(set)
    sites = collections.Counter()
    nonzero = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(run_one, args.binary, f, args.timeout, env, args.besttier) for f in files]
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            if r is None:
                nonzero += 1
                continue
            rc, w, a, c, si = r
            if rc != 0:
                nonzero += 1
            for k, v in w.items():
                would[k] |= v
            for k, v in a.items():
                ran[k] |= v
            for k, v in c.items():
                cand[k] |= v
            sites.update(si)

    agree, diverge, unproven, ambiguous = [], [], [], []
    for key, picks in sorted(would.items()):
        actual = ran.get(key)
        if actual is None:
            unproven.append((key, picks))
        elif len(picks) > 1:
            ambiguous.append((key, picks, actual))
        elif picks == actual:
            agree.append((key, picks))
        else:
            diverge.append((key, picks, actual))

    print(f"programs={len(files)} nonzero_exit={nonzero}")
    print()
    print("PER SITE (lowering's stamp against the declaration the runtime served)")
    site_diverge = report_sites(sites, args.top)
    print()
    print(f"would-commit keys: {len(would)}   runtime-served keys: {len(ran)}")
    print(f"  agree     {len(agree)}")
    print(f"  diverge   {len(diverge)}")
    print(f"  ambiguous {len(ambiguous)}   (lowering would pick more than one declaration for the key)")
    print(f"  unproven  {len(unproven)}   (the runtime never served this key)")
    for label, rows in (("DIVERGENT", diverge), ("AMBIGUOUS", ambiguous)):
        if not rows:
            continue
        print()
        print(f"{label}:")
        for row in rows[: args.top]:
            key, picks = row[0], row[1]
            actual = row[2]
            print(f"  {key[0]} on {key[1]}")
            print(f"      lowering would: {', '.join(sorted(picks))}")
            print(f"      runtime serves: {', '.join(sorted(actual))}")
            seen = cand.get(key)
            if seen is not None:
                names = {f for f, _ in seen}
                missing = sorted(a for a in actual if a not in names)
                if missing:
                    print(f"      NOT A CANDIDATE at lowering: {', '.join(missing)}")
                else:
                    print("      candidates: " + ", ".join(f"{f}(tier {t})" for f, t in sorted(seen)))
    return 1 if (diverge or ambiguous or site_diverge) else 0


def report_sites(sites, top):
    """Report the per-site rows for both criteria, and return the divergent ones."""
    if not sites:
        print("  no stamped site executed "
              "(the binary predates the stamp, or the corpus reaches none)")
        return []
    for label, want in (
        ("extension, any withheld pick", {0, 1}),
        ("extension, unique best tier and named head", {1}),
        ("member gate, target named and dispatch withheld", {2}),
    ):
        total = collections.Counter()
        for (_n, verdict, _lo, _ru, kind, _fn), n in sites.items():
            if kind not in want:
                continue
            total[verdict] += n
        executed = total["agree"] + total["diverge"]
        served = f"{100.0 * total['agree'] / executed:.2f}%" if executed else "n/a"
        print(f"  {label}:")
        print(f"      agree      {total['agree']}")
        print(f"      diverge    {total['diverge']}")
        print(f"      not-served {total['not-served']}   "
              "(the site resolved as a member, builtin or intrinsic)")
        print(f"      agreement over served sites: {served}")
    rows = sorted(
        ((k, n) for k, n in sites.items() if k[1] == "diverge"),
        key=lambda kv: -kv[1],
    )
    if rows:
        print()
        print("  DIVERGENT SITES:")
        for (name, _v, lowering, served, kind, in_fn), n in rows[:top]:
            print(f"    {name} x{n} kind={kind} in {in_fn}")
            print(f"        lowering would: {lowering}")
            print(f"        runtime serves: {served}")
    # A stamped site the extension walk never answered is the bucket a commit
    # would change the most: lowering names an extension, the runtime binds
    # something else. Naming them is the difference between a number and a list
    # of calls to check.
    unserved = sorted(
        ((k, n) for k, n in sites.items() if k[1] == "not-served"),
        key=lambda kv: -kv[1],
    )
    if unserved:
        print()
        print("  NOT SERVED, by declaration:")
        for (name, _v, lowering, _r, kind, in_fn), n in unserved[:top]:
            print(f"    {name} x{n} kind={kind} in {in_fn}  would bind {lowering}")
    return rows


if __name__ == "__main__":
    sys.exit(main())
