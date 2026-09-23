#!/usr/bin/env python3
"""Per-site XOrY arm census: does a site ever take more than one arm?

`CallMemberOrGlobal` and its siblings exist because lowering could not decide
between a member of the implicit receiver and a global. A site that only ever
takes one arm is a site lowering could have settled; one that takes both is
either genuinely dynamic or a resolution gap of a different shape. A per-NAME
tally cannot tell them apart, since one name is many sites.
"""
import collections
import concurrent.futures
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROW = re.compile(r"^\[KLIO_OR_AUDIT\] run inst=(\S+) name=(\S+) arm=(\S+) depth=(\S+) recv=(\S+) site=(\S+)")

def interactive(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for _ in range(12):
                line = f.readline()
                if not line: break
                if re.search(r"//\s*corpus:\s*interactive", line): return True
    except OSError: pass
    return False

def run(path):
    env = dict(os.environ, KLIO_OR_AUDIT="1", KLIO_HOME=ROOT + "/.klio-local")
    try:
        p = subprocess.run([sys.argv[1], "run", path], cwd=ROOT, capture_output=True, timeout=180, env=env)
    except Exception:
        return None
    out = collections.defaultdict(set)
    for line in p.stderr.decode("utf-8", "replace").splitlines():
        m = ROW.match(line)
        if m:
            out[(m.group(1), m.group(2), m.group(6))].add(m.group(3))
    return out

files = [f for f in sorted(glob.glob(ROOT + "/examples/*.kt")) if not interactive(f)]
sites = collections.defaultdict(set)
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    for r in ex.map(run, files):
        if r:
            for k, v in r.items(): sites[k] |= v

by_inst = collections.defaultdict(lambda: [0, 0])
arms_seen = collections.Counter()
for (inst, name, _site), arms in sites.items():
    by_inst[inst][0 if len(arms) == 1 else 1] += 1
    if len(arms) == 1: arms_seen[(inst, next(iter(arms)))] += 1
print(f"programs={len(files)} sites={len(sites)}")
print(f"{'instruction':<24} {'one-arm':>8} {'multi':>8}")
for inst, (one, multi) in sorted(by_inst.items(), key=lambda kv: -(kv[1][0] + kv[1][1])):
    print(f"{inst:<24} {one:>8} {multi:>8}")
print()
print("one-arm sites by the arm they always take:")
for (inst, arm), n in arms_seen.most_common(18):
    print(f"  {n:>6}  {inst}.{arm}")
