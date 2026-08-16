#!/usr/bin/env python3
"""Per-failure census of any library `commonTest` suite.

Reproduces `src/itests/<suite>_commontest.zig` exactly — same packs, same
scratch HOME, same support/target split (a file without `@Test` is passed
as a support source, a file with one is a target) — but records every
FAILED test with its error text instead of only counting passes.

    scripts/commontest-census.py <suite> [--filter SUBSTR] [--jobs N]
                                [--json OUT] [--no-install] [--errors]
                                [--extra-support DIR ...]

The suite config is read straight out of the Zig itest so the census can
never drift from the gate: `.test_roots`, `.packs`, `.scratch_home` and
`.extra_support` are parsed from the `support.runSuite(.{ ... })` literal.

    scripts/commontest-census.py --list      # available suites
"""
import argparse
import collections
import concurrent.futures
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ITESTS = os.path.join(ROOT, "src", "itests")
BIN = os.environ.get("KLIO_ITEST_BIN", "zig-out/bin/klio-harness")


def suites():
    out = []
    for n in sorted(os.listdir(ITESTS)):
        if n.endswith("_commontest.zig") and n != "commontest_support.zig":
            out.append(n[: -len("_commontest.zig")])
    return out


def strip_comments(src):
    return "\n".join(re.sub(r"//.*$", "", ln) for ln in src.splitlines())


def parse_config(suite):
    """Pull test_roots / packs / scratch_home / extra_support out of the Zig itest."""
    path = os.path.join(ITESTS, f"{suite}_commontest.zig")
    if not os.path.exists(path):
        sys.exit(f"no such suite: {suite} (have: {', '.join(suites())})")
    with open(path) as fh:
        src = strip_comments(fh.read())

    def strings_in(field):
        m = re.search(re.escape("." + field) + r"\s*=\s*&\.\{(.*?)\n\s*\}", src, re.S)
        if not m:
            return []
        return re.findall(r'"([^"]*)"', m.group(1))

    packs = []
    m = re.search(r"\.packs\s*=\s*&\.\{(.*?)\n\s*\},\n", src, re.S)
    if m:
        for d, art in re.findall(
            r'\.dir\s*=\s*"([^"]*)"\s*,\s*\.artifact\s*=\s*"([^"]*)"', m.group(1)
        ):
            packs.append((d, art))
    home = re.search(r'\.scratch_home\s*=\s*"([^"]*)"', src)
    baseline = re.search(r"\.baseline\s*=\s*(\d+)", src)
    return {
        "test_roots": strings_in("test_roots"),
        "extra_support": strings_in("extra_support"),
        "packs": packs,
        "scratch_home": home.group(1) if home else f"/tmp/klio_census_{suite}_home",
        "baseline": int(baseline.group(1)) if baseline else 0,
    }


def sh(argv, env, timeout=300):
    return subprocess.run(argv, cwd=ROOT, env=env, capture_output=True,
                          text=True, timeout=timeout)


def install_packs(packs, env):
    for d, artifact in packs:
        for argv in ([BIN, "pack", "build", d], [BIN, "pack", "install", artifact]):
            r = sh(argv, env, timeout=600)
            if r.returncode != 0:
                print(f"pack step failed: {' '.join(argv)}\n{r.stderr[:4000]}",
                      file=sys.stderr)
                sys.exit(1)


def collect_kt(d):
    out = []
    full = os.path.join(ROOT, d)
    if os.path.isfile(full):
        return [d]
    for dirpath, _, names in os.walk(full):
        for n in sorted(names):
            if n.endswith(".kt"):
                out.append(os.path.relpath(os.path.join(dirpath, n), ROOT))
    return sorted(out)


def has_test(path):
    with open(os.path.join(ROOT, path), "r", errors="replace") as fh:
        return "@Test" in fh.read()


# `Class.method FAILED` then an indented error line.
FAILED_RE = re.compile(r"^(\S+) FAILED\s*$")


def shape(msg):
    """Collapse an error message to its shape: backticked payloads to `X`,
    numbers to N, so distinct instances of one mechanism group together."""
    s = re.sub(r"`[^`]*`", "`X`", msg)
    s = re.sub(r"\b\d+\b", "N", s)
    return s.strip()


# Payloads worth histogramming on their own: the identifier a resolution
# failure named. Keyed by the message prefix that introduces it.
SYMBOL_RES = [
    re.compile(r"unresolved (?:global|reference|name|function|type|variable)\s+`([^`]+)`"),
    re.compile(r"unresolved (?:global|reference|name|function|type|variable)\s+(\S+)"),
    re.compile(r"unknown (?:class|type|function|member)\s+`([^`]+)`"),
    re.compile(r"cannot resolve\s+`([^`]+)`"),
]


def symbol(msg):
    for rx in SYMBOL_RES:
        m = rx.search(msg)
        if m:
            return m.group(1)
    return None


def run_target(target, support, env, timeout):
    argv = [BIN, "test"] + support + [target]
    try:
        r = sh(argv, env, timeout=timeout)
        out = r.stdout
        err = r.stderr
    except subprocess.TimeoutExpired:
        return target, [], [("<TIMEOUT>", "child exceeded %ds" % timeout)], True, ""
    passed, failed, lines = [], [], out.splitlines()
    for i, line in enumerate(lines):
        m = FAILED_RE.match(line.strip())
        if m:
            e = lines[i + 1].strip() if i + 1 < len(lines) else ""
            failed.append((m.group(1), e))
        elif line.strip().endswith(" PASSED"):
            passed.append(line.strip().rsplit(" ", 1)[0])
    incomplete = " passed," not in out
    return target, passed, failed, incomplete, err


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("suite", nargs="?")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--extra-support", action="append", default=[])
    ap.add_argument("--filter", default=None)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 4) - 2))
    ap.add_argument("--json", default=None)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--no-install", action="store_true",
                    help="skip the pack build/install (packs already current)")
    ap.add_argument("--errors", action="store_true",
                    help="also print the per-file stderr of incomplete children")
    args = ap.parse_args()

    if args.list or not args.suite:
        print("suites: " + ", ".join(suites()))
        return
    cfg = parse_config(args.suite)

    env = dict(os.environ)
    env["HOME"] = cfg["scratch_home"]
    os.makedirs(cfg["scratch_home"], exist_ok=True)
    if not args.no_install:
        install_packs(cfg["packs"], env)

    all_kt = []
    for r in cfg["test_roots"]:
        all_kt += collect_kt(r)
    all_kt = sorted(all_kt)
    support = [p for p in all_kt if not has_test(p)]
    targets = [p for p in all_kt if has_test(p)]
    for d in cfg["extra_support"] + args.extra_support:
        support += collect_kt(d)
    if args.filter:
        targets = [t for t in targets if args.filter in t]

    print(f"suite={args.suite} targets={len(targets)} support={len(support)} "
          f"jobs={args.jobs} baseline={cfg['baseline']}")
    results, n_pass, n_fail, incomplete = [], 0, 0, 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(run_target, t, support, env, args.timeout) for t in targets]
        for f in concurrent.futures.as_completed(futs):
            target, passed, failed, inc, err = f.result()
            n_pass += len(passed)
            n_fail += len(failed)
            incomplete += 1 if inc else 0
            if inc and args.errors:
                print(f"\n--- INCOMPLETE {target}\n{err[:2000]}")
            results.append({"file": target, "passed": passed,
                            "failed": [{"test": t, "err": e} for t, e in failed],
                            "incomplete": inc})

    results.sort(key=lambda r: r["file"])
    print(f"\nCENSUS: {n_pass} passed, {n_fail} failed, {incomplete} did not complete"
          f" across {len(targets)} files")

    print("\nPER FILE (pass/fail):")
    for r in results:
        mark = "  INCOMPLETE" if r["incomplete"] else ""
        print(f"  {len(r['passed']):4d}/{len(r['failed']):<4d} "
              f"{os.path.basename(r['file'])}{mark}")

    hist = collections.Counter()
    by_shape = collections.defaultdict(list)
    syms = collections.Counter()
    sym_files = collections.defaultdict(set)
    for r in results:
        for fl in r["failed"]:
            sh_ = shape(fl["err"])
            hist[sh_] += 1
            by_shape[sh_].append(f"{r['file']}::{fl['test']}")
            s = symbol(fl["err"])
            if s:
                syms[s] += 1
                sym_files[s].add(os.path.basename(r["file"]))
    print("\nFAILURE SHAPES (count, share, shape):")
    for s, c in hist.most_common(30):
        print(f"  {c:5d}  {100.0 * c / max(n_fail, 1):5.1f}%  {s[:120]}")
    if syms:
        print("\nUNRESOLVED SYMBOLS (count, symbol, files):")
        for s, c in syms.most_common(60):
            print(f"  {c:5d}  {s:<48s} {', '.join(sorted(sym_files[s])[:4])}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"suite": args.suite, "results": results,
                       "hist": hist.most_common(),
                       "symbols": syms.most_common(),
                       "by_shape": {k: v for k, v in by_shape.items()}}, fh, indent=1)
        print(f"\nwrote {args.json}")


if __name__ == "__main__":
    main()
