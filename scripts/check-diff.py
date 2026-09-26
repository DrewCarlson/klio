#!/usr/bin/env python3
"""Compares `klio check`'s engines with kotlinc, input by input and line by line.

    scripts/check-diff.py [options] [file.kt | dir]...

Runs `klio check --format=json` with the old engine and with `--engine sema`,
and kotlinc 2.4.20 through `scripts/sema-oracle.sh --diagnostics`, over the
inputs (default: examples/*.kt, tests/fixtures/typeck_negative/*.kt and
tests/fixtures/*.kt), then checks the rules the old checker's retirement keeps
(plans/retire-typeck.md):

  1. kept:     an old diagnostic kotlinc also reports at its line has a sema
               diagnostic there with kotlinc's factory.
  2. dropped:  an old diagnostic may go only where kotlinc accepts the line
               (counted by code, not a failure).
  3. matched:  every sema diagnostic has a kotlinc diagnostic of its factory at
               its line.
  4. severity: a matched sema diagnostic has kotlinc's severity.

An input kotlinc cannot compile for want of a library (an import outside
`kotlin.*` and `kotlinx.coroutines`, or of kotlinx-coroutines-test or the
kotlin.test annotations) is taken as valid: it runs under klio and is written
against the upstream library. The exit status is 1 when
rule 1, 3 or 4 fails.

Options:
  --klio PATH          klio binary (default zig-out/bin/klio)
  -j N                 parallel klio checks (default 4)
  --old FILE, --sema FILE, --kotlinc FILE
                       reuse a previous run's results instead of running that
                       side (`--save DIR` writes all three)
  --save DIR           keep old.jsonl, sema.jsonl and kotlinc.tsv in DIR
  --only-kotlinc-judged  leave out the inputs kotlinc cannot judge
  --json               print the summary as JSON
  -n N                 examples listed per failing rule (default 20)

The klio side reads each input's `// Run with: klio run <flags>` line for its
flags; the kotlinc side a `// kotlinc: <flags>` line.
"""
import argparse
import collections
import concurrent.futures
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KOTLINC = os.environ.get("SEMA_ORACLE_KOTLINC", os.path.join(ROOT, "target/parity-cache/kotlinc-2.4.20"))
DEFAULT_INPUTS = ["examples/*.kt", "tests/fixtures/typeck_negative/*.kt", "tests/fixtures/*.kt"]


def header_lines(path, n=12):
    try:
        with open(path, errors="replace") as f:
            return [f.readline() for _ in range(n)]
    except OSError:
        return []


def klio_flags(path):
    for line in header_lines(path):
        m = re.search(r"Run with:\s*klio run\s+(.*)", line)
        if m:
            return [a for a in m.group(1).split() if not a.endswith(".kt") and a != "--"]
    return []


def kotlinc_flags(path):
    for line in header_lines(path):
        m = re.search(r"//\s*kotlinc:\s*(.*)", line)
        if m:
            return m.group(1).split()
    return []


def imports(path):
    out = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                m = re.match(r"\s*import\s+([^\s]+)", line)
                if m:
                    out.append(m.group(1))
    except OSError:
        pass
    return out


# What the pinned kotlinc's lib directory does not have: kotlinx-coroutines-test,
# and the kotlin.test annotations, which kotlin-test-junit maps to JUnit.
UNJUDGED_IMPORTS = ("kotlinx.coroutines.test.", "kotlin.test.Test", "kotlin.test.BeforeTest", "kotlin.test.AfterTest", "kotlin.test.Ignore")


def kotlinc_judges(path):
    """Whether kotlinc has every library the input imports: the stdlib,
    kotlin.test's assertions and kotlinx.coroutines."""
    return all(i.startswith(("kotlin.", "kotlinx.coroutines.")) and not i.startswith(UNJUDGED_IMPORTS) for i in imports(path))


def classpath(path):
    lib = os.path.join(KOTLINC, "lib")
    cp = [os.path.join(lib, "kotlin-test.jar")]
    if any(i.startswith("kotlinx.coroutines.") for i in imports(path)):
        cp.append(os.path.join(lib, "kotlinx-coroutines-core-jvm.jar"))
    return os.pathsep.join(cp)


def run_klio(binary, path, engine):
    env = dict(os.environ)
    env.setdefault("KLIO_HOME", os.path.join(ROOT, ".klio-local"))
    argv = [binary, "check", "--format=json"] + (["--engine=sema"] if engine == "sema" else []) + klio_flags(path) + [path]
    try:
        p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, errors="replace", timeout=600)
    except subprocess.TimeoutExpired:
        return {"input": path, "rc": "timeout", "diags": []}
    diags = []
    for ln in p.stdout.splitlines():
        try:
            d = json.loads(ln)
        except json.JSONDecodeError:
            continue
        if "range" not in d:
            continue
        if os.path.relpath(os.path.abspath(os.path.join(ROOT, d["file"])), ROOT) != path:
            continue
        diags.append({
            "line": d["range"]["start"]["line"],
            "code": d.get("factory") or d.get("legacy_code") or "",
            "severity": d["severity"],
            "message": d["message"].splitlines()[0][:200],
        })
    return {"input": path, "rc": p.returncode, "diags": diags}


def run_side(binary, paths, engine, jobs, out_path):
    with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
        results = list(ex.map(lambda p: run_klio(binary, p, engine), paths))
    if out_path:
        with open(out_path, "w") as f:
            for r in results:
                f.write(json.dumps(r) + "\n")
    return {r["input"]: r for r in results}


def load_side(path):
    out = {}
    with open(path) as f:
        for ln in f:
            r = json.loads(ln)
            # A saved side holds this script's rows or raw `klio check --format=json` lines.
            r["diags"] = [normalize(d) for d in r["diags"] if "range" in d or "line" in d]
            out[r["input"]] = r
    return out


def normalize(d):
    if "line" in d:
        return d
    return {
        "line": d["range"]["start"]["line"],
        "code": d.get("factory") or d.get("legacy_code") or "",
        "severity": d["severity"],
        "message": d["message"].splitlines()[0][:200],
    }


def run_kotlinc(paths, jobs, out_path):
    groups = collections.defaultdict(list)
    for p in paths:
        if kotlinc_judges(p):
            groups[(tuple(kotlinc_flags(p)), classpath(p))].append(p)
    rows = []
    for (flags, cp), members in sorted(groups.items()):
        argv = [os.path.join(ROOT, "scripts/sema-oracle.sh"), "--diagnostics", "--quiet", "-j", str(jobs), "-cp", cp, *flags, *members]
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, errors="replace")
        if p.returncode != 0:
            sys.stderr.write(p.stderr[-2000:])
            raise SystemExit(f"check-diff: the oracle failed ({p.returncode})")
        rows.extend(ln for ln in p.stdout.splitlines() if ln.strip())
    if out_path:
        with open(out_path, "w") as f:
            f.write("\n".join(rows) + ("\n" if rows else ""))
    return parse_kotlinc(rows, paths)


def parse_kotlinc(rows, paths):
    out = {p: [] for p in paths if kotlinc_judges(p)}
    for ln in rows:
        parts = ln.split("\t")
        if len(parts) < 6:
            continue
        path = os.path.relpath(os.path.abspath(os.path.join(ROOT, parts[0])), ROOT)
        if path not in out:
            continue
        out[path].append({"line": int(parts[1]), "code": parts[4], "severity": parts[3], "message": parts[5][:200]})
    return out


def group_of(path):
    if path.startswith("tests/fixtures/typeck_negative/"):
        return "typeck_negative"
    if path.startswith("tests/fixtures/"):
        return "fixtures"
    return "examples"


def compare(paths, old, sema, kotlinc, only_judged):
    stats = collections.defaultdict(collections.Counter)
    fails = collections.defaultdict(list)
    dropped = collections.Counter()
    for path in paths:
        judged = path in kotlinc
        if only_judged and not judged:
            continue
        g = group_of(path)
        st = stats[g]
        st["inputs"] += 1
        st["kotlinc judged"] += judged
        o = old.get(path, {"rc": "missing", "diags": []})
        s = sema.get(path, {"rc": "missing", "diags": []})
        for tag, r in (("old", o), ("sema", s)):
            if r["rc"] not in (0, 1):
                st[tag + " aborts"] += 1
                fails["abort " + tag].append(f"{path}: rc {r['rc']}")
        k = kotlinc.get(path, [])
        k_at = collections.defaultdict(list)
        for d in k:
            k_at[d["line"]].append(d)
        s_at = collections.defaultdict(list)
        for d in s["diags"]:
            s_at[d["line"]].append(d)
        st["kotlinc diagnostics"] += len(k)
        st["old diagnostics"] += len(o["diags"])
        st["sema diagnostics"] += len(s["diags"])
        for d in o["diags"]:
            here = [x for x in k_at[d["line"]] if x["severity"] == d["severity"]]
            if not here:
                st["old dropped (kotlinc accepts)"] += 1
                dropped[d["code"]] += 1
                continue
            if any(x["code"] in {y["code"] for y in here} for x in s_at[d["line"]]):
                st["old kept"] += 1
            else:
                st["old lost"] += 1
                want = ",".join(sorted({x["code"] for x in here}))
                fails["1 kept"].append(f"{path}:{d['line']}: {d['code']} -> kotlinc {want}; sema has {','.join(x['code'] for x in s_at[d['line']]) or 'nothing'}")
        if not judged:
            # Taken as valid, but kotlinc cannot say: listed, not failed.
            st["sema on unjudged inputs"] += len(s["diags"])
            for d in s["diags"]:
                fails["unjudged"].append(f"{path}:{d['line']}: {d['code']} ({d['message']})")
            continue
        for d in s["diags"]:
            match = [x for x in k_at[d["line"]] if x["code"] == d["code"]]
            if not match:
                st["sema unmatched"] += 1
                other = ",".join(sorted({x["code"] for x in k_at[d["line"]]}))
                fails["3 matched"].append(f"{path}:{d['line']}: {d['code']} ({d['message']})" + (f"; kotlinc {other}" if other else "; kotlinc accepts"))
                continue
            st["sema matched"] += 1
            if not any(x["severity"] == d["severity"] for x in match):
                st["sema wrong severity"] += 1
                fails["4 severity"].append(f"{path}:{d['line']}: {d['code']} is {d['severity']}, kotlinc {match[0]['severity']}")
        for line, ks in k_at.items():
            codes = {x["code"] for x in s_at[line]}
            for x in ks:
                if x["code"] not in codes:
                    st["kotlinc only"] += 1
    return stats, fails, dropped


def main():
    ap = argparse.ArgumentParser(add_help=True, usage=__doc__)
    ap.add_argument("inputs", nargs="*")
    ap.add_argument("--klio", default=os.path.join(ROOT, "zig-out/bin/klio"))
    ap.add_argument("-j", type=int, default=4)
    ap.add_argument("--old")
    ap.add_argument("--sema")
    ap.add_argument("--kotlinc")
    ap.add_argument("--save")
    ap.add_argument("--only-kotlinc-judged", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-n", type=int, default=20)
    a = ap.parse_args()

    paths = []
    for spec in a.inputs or DEFAULT_INPUTS:
        full = os.path.join(ROOT, spec)
        if os.path.isdir(full):
            found = glob.glob(os.path.join(full, "**/*.kt"), recursive=True)
        else:
            found = glob.glob(full)
        paths.extend(os.path.relpath(p, ROOT) for p in found)
    paths = sorted(set(paths))
    if not paths:
        raise SystemExit("check-diff: no inputs")
    save = a.save
    if save:
        os.makedirs(save, exist_ok=True)

    old = load_side(a.old) if a.old else run_side(a.klio, paths, "old", a.j, save and os.path.join(save, "old.jsonl"))
    sema = load_side(a.sema) if a.sema else run_side(a.klio, paths, "sema", a.j, save and os.path.join(save, "sema.jsonl"))
    if a.kotlinc:
        with open(a.kotlinc) as f:
            kotlinc = parse_kotlinc([ln.rstrip("\n") for ln in f], paths)
    else:
        kotlinc = run_kotlinc(paths, a.j, save and os.path.join(save, "kotlinc.tsv"))

    stats, fails, dropped = compare(paths, old, sema, kotlinc, a.only_kotlinc_judged)
    failed = any(fails[k] for k in ("1 kept", "3 matched", "4 severity"))
    if a.json:
        print(json.dumps({"groups": stats, "failures": {k: len(v) for k, v in fails.items()}, "dropped": dropped, "ok": not failed}, indent=2, sort_keys=True))
    else:
        for g in ("examples", "typeck_negative", "fixtures"):
            if g not in stats:
                continue
            print(f"== {g}")
            for k, v in sorted(stats[g].items()):
                print(f"  {k:32} {v}")
        print("old diagnostics dropped where kotlinc accepts, by code:", ", ".join(f"{c} {n}" for c, n in dropped.most_common()))
        for rule in sorted(fails):
            print(f"== rule {rule}: {len(fails[rule])}")
            for line in fails[rule][: a.n]:
                print("   " + line)
        print("check-diff:", "FAIL" if failed else "ok")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
