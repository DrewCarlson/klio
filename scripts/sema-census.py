#!/usr/bin/env python3
"""The sema census as a gate: every reference in the base source set, in
every installed pack (all of its features) and in the example corpus must
resolve and carry a record, and every body of the base and the packs must
lower from those records.

Usage: scripts/sema-census.py [--klio BIN] [--home DIR] [--open FILE]
                              [--update-open] [-j N]

Three scopes, each through `klio sema`:
  base    `--bodies base --lower` over the stdlib sources and the sema
          actuals.
  pack    per installed pack in DIR/.klio/packs: `--bodies all --lower`
          with every feature the pack declares, over a program importing
          the pack.
  corpus  `--each` over examples/*.kt, and each multi-file example
          directory as one program.

Every site is `<reason> <path:line:col>`: a sema reason, or `lower_<kind>`
for a body that did not lower (`lower_unrecorded`, `lower_bridge`,
`lower_lowering`, `lower_unsupported`) or a bodyless declaration no native
binds (`lower_unbound_native`). A site is reported under the first scope
that reaches it (a pack's sites recur under every pack depending on it). A
site listed in the open file (default tests/sema-census-open.txt) is known
and allowed; any other site fails the gate, and so does a listed site that
no longer occurs, so the list only shrinks. `--update-open` rewrites the
file with what this run measured. An analysis that crashes or prints no
totals fails the gate.
"""
import argparse
import concurrent.futures
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = re.compile(r"^\s+([a-z_]+) (\S+:\d+:\d+): (.*)$")
TOTAL = re.compile(r"\bunresolved=(\d+)")
FAILED = re.compile(r"\bfailed=(\d+)")


def run(cmd, env, timeout=1800):
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout + p.stderr


def sites_of(scope, out, skip_path=None):
    found = []
    for line in out.splitlines():
        m = SITE.match(line)
        if not m:
            continue
        reason, where, detail = m.groups()
        if skip_path and where.startswith(skip_path + ":"):
            continue
        found.append((scope, reason, where, detail))
    return found


def packs(klio, env, home):
    """(library id, [features]) per installed pack."""
    index = os.path.join(home, ".klio", "packs", "index.json")
    try:
        with open(index) as f:
            entries = json.load(f)
    except (OSError, ValueError):
        return []
    out = []
    for e in entries:
        lib = e.get("library_id")
        path = e.get("path")
        if not lib or not path:
            continue
        _, text = run([klio, "pack", "inspect", path], env)
        feats = re.findall(r"^\s+feature ([^:\s]+):", text, re.M)
        out.append((lib, feats))
    return sorted(out)


def census_pack(klio, env, lib, feats, probe_dir):
    probe = os.path.join(probe_dir, lib.replace(".", "_") + ".kt")
    with open(probe, "w") as f:
        f.write("import %s.*\n\nfun main() {}\n" % lib)
    cmd = [klio, "sema", "--bodies", "all", "--lower", "--sites", "100000"]
    for ft in feats:
        cmd += ["--feature", "%s/%s" % (lib, ft)]
    cmd.append(probe)
    _, out = run(cmd, env)
    ok = TOTAL.search(out) is not None
    return ok, out, sites_of("pack:" + lib, out, skip_path=probe)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--klio", default=os.path.join(ROOT, "zig-out/bin/klio-harness"))
    ap.add_argument("--home", default=os.environ.get("KLIO_HOME", os.path.join(ROOT, ".klio-local")))
    ap.add_argument("--open", default=os.path.join(ROOT, "tests/sema-census-open.txt"))
    ap.add_argument("--update-open", action="store_true")
    ap.add_argument("-j", type=int, default=min(8, os.cpu_count() or 4))
    args = ap.parse_args()

    env = dict(os.environ)
    env["KLIO_HOME"] = args.home
    for k in ("KLIO_SEMA_PIPELINE", "KLIO_SEMA_IMAGE", "KLIO_SEMA_TIMING"):
        env.pop(k, None)

    sites = []
    broken = []

    _, out = run([args.klio, "sema", "--bodies", "base", "--lower", "--sites", "100000"], env)
    if not TOTAL.search(out):
        broken.append(("base", out[-2000:]))
    base_sites = sites_of("base", out)
    sites += base_sites
    print("sema-census: base %d" % len(base_sites))

    libs = packs(args.klio, env, args.home)
    if not libs:
        broken.append(("pack", "no installed packs under %s" % args.home))
    with tempfile.TemporaryDirectory() as probe_dir:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.j) as pool:
            futs = {pool.submit(census_pack, args.klio, env, lib, feats, probe_dir): lib for lib, feats in libs}
            for fut in concurrent.futures.as_completed(futs):
                lib = futs[fut]
                ok, out, found = fut.result()
                if not ok:
                    broken.append(("pack:" + lib, out[-2000:]))
                sites += found
                print("sema-census: pack %s %d" % (lib, len(found)))

    singles = sorted(glob.glob(os.path.join("examples", "*.kt"), root_dir=ROOT))
    _, out = run([args.klio, "sema", "--each", "-j", str(args.j), "--sites", "100000"] + singles, env)
    m = FAILED.search(out)
    if not m or int(m.group(1)) != 0:
        broken.append(("corpus", "\n".join(l for l in out.splitlines() if "failed" in l or "panic" in l)[-2000:]))
    corpus_sites = sites_of("corpus", out)
    for d in sorted(glob.glob(os.path.join("examples", "*", ""), root_dir=ROOT)):
        files = sorted(glob.glob(os.path.join(d, "*.kt"), root_dir=ROOT))
        if not files:
            continue
        _, out = run([args.klio, "sema", "--sites", "100000"] + files, env)
        if not TOTAL.search(out):
            broken.append(("corpus " + d, out[-2000:]))
        corpus_sites += sites_of("corpus", out)
    sites += corpus_sites
    print("sema-census: corpus %d" % len(corpus_sites))

    measured = {}
    for scope, reason, where, detail in sites:
        measured.setdefault((reason, where), (scope, detail))
    if args.update_open:
        with open(args.open, "w") as f:
            f.write("# Known unresolved, unrecorded or unlowered sites of scripts/sema-census.py:\n")
            f.write("# <reason> <path:line:col>, then the first scope and the detail after tabs.\n")
            f.write("# The gate fails on any other site and on a listed one that is gone.\n")
            for key in sorted(measured):
                f.write("%s %s\t%s\t%s\n" % (key[0], key[1], measured[key][0], measured[key][1]))
        print("sema-census: wrote %d sites to %s" % (len(measured), args.open))

    known = set()
    if os.path.exists(args.open):
        with open(args.open) as f:
            for line in f:
                line = line.split("\t", 1)[0].strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(" ")
                if len(parts) == 2:
                    known.add(tuple(parts))

    new = sorted(k for k in measured if k not in known)
    gone = sorted(k for k in known if k not in measured)
    for k in new:
        print("NEW  %s %s (%s): %s" % (k[0], k[1], measured[k][0], measured[k][1]))
    for k in gone:
        print("GONE %s %s (remove it from %s)" % (k[0], k[1], os.path.relpath(args.open, ROOT)))
    for scope, text in broken:
        print("BROKEN %s:\n%s" % (scope, text))
    print("sema-census: %d sites, %d known, %d new, %d gone, %d broken" % (len(measured), len(known), len(new), len(gone), len(broken)))
    return 1 if new or gone or broken else 0


if __name__ == "__main__":
    sys.exit(main())
