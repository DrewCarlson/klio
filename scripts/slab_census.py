#!/usr/bin/env python3
"""Summarise a `KLIO_SLAB_CENSUS` report.

    KLIO_SLAB_CENSUS=1 klio run hello.kt 2> census.txt
    python3 scripts/slab_census.py census.txt            # live bytes by phase and file, then the top sites
    python3 scripts/slab_census.py census.txt --churn    # the same for bytes allocated over the run

A site is the allocation's symbolised stack with the allocator's own frames
dropped; the phase is read off the frames (parse, stage, lower, bake, extend,
run, sources).
"""
import re
import sys
from collections import defaultdict

SKIP = ('slab.zig', 'Allocator.zig', 'array_list.zig', 'hash_map.zig', 'arena_allocator.zig', 'mem.zig')


def phase(frames):
    j = ' '.join(frames)
    if 'stdlibSources' in j or 'buildCuratedSources' in j or 'decodeEmbeddedSources' in j:
        return 'sources'
    # A deep parse recursion overflows the captured frames, so the parser's
    # own function names stand in for the job that ran them.
    if 'runParseJob' in j or 'parseUserFiles' in j or 'runParseJobs' in j or frames[0].startswith(('parse', 'callArguments', 'braceTrailingLambda', 'skipModifiers', 'ownedDecls')):
        return 'parse'
    if 'stageBaseEagerCalls' in j or 'computeEagerCalls' in j or 'typeck' in j or 'checkBaseSources' in j:
        return 'stage'
    if 'bakeAndWrite' in j or '@image.zig' in j or 'bake@' in j:
        return 'bake'
    if 'ExtendOwned' in j or 'adoptBuiltForRun' in j:
        return 'extend'
    if 'body_pool' in j or 'buildModule' in j or 'buildStdlibBase' in j or 'stripStdlibBase' in j or 'lower' in j.lower():
        return 'lower'
    if 'runFileIrVm' in j or '/vm/' in j or 'interp_ir.zig' in j:
        return 'run'
    return 'other'


def read(path):
    sites, cur, total = [], None, None
    for line in open(path):
        m = re.match(r'\[census\] live (\d+) bytes in (\d+) allocations \(allocated (\d+) in (\d+)\):', line)
        if m:
            cur = {'live': int(m[1]), 'n': int(m[2]), 'tot': int(m[3]), 'totn': int(m[4]), 'frames': []}
            sites.append(cur)
            continue
        m = re.match(r'(\S+):(\d+):\d+: 0x[0-9a-f]+ in (\S+) \(', line)
        if m and cur is not None:
            f = m[1].split('/')[-1]
            if any(k in f for k in SKIP):
                continue
            cur['frames'].append(f"{m[3]}@{f}:{m[2]}")
        m = re.match(r'\[census\] live (\d+) bytes in (\d+) allocations, (\d+) bytes allocated in all', line)
        if m:
            total = (int(m[1]), int(m[2]), int(m[3]))
    return sites, total


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    churn = '--churn' in sys.argv
    sites, total = read(sys.argv[1])
    key = 'tot' if churn else 'live'
    if total:
        print(f"live {total[0] / 1e6:.1f}MB in {total[1]} allocations; {total[2] / 1e6:.0f}MB allocated in all; listed sites cover {sum(s[key] for s in sites) / 1e6:.1f}MB")
    by = defaultdict(lambda: [0, 0])
    byfile = defaultdict(lambda: [0, 0])
    for s in sites:
        fr = s['frames'] or ['?@?:0']
        p = phase(fr)
        by[p][0] += s[key]
        by[p][1] += s['n'] if not churn else s['totn']
        k = p + ' ' + fr[0].split('@')[1].split(':')[0]
        byfile[k][0] += s[key]
        byfile[k][1] += s['n'] if not churn else s['totn']
    unit = 'churn' if churn else 'live'
    print(f"\n{unit} by phase")
    for k, v in sorted(by.items(), key=lambda kv: -kv[1][0]):
        print(f"{v[0] / 1e6:8.2f}MB {v[1]:8d}  {k}")
    print(f"\n{unit} by phase and file")
    for k, v in sorted(byfile.items(), key=lambda kv: -kv[1][0])[:30]:
        print(f"{v[0] / 1e6:8.2f}MB {v[1]:8d}  {k}")
    print(f"\ntop sites by {unit}")
    for s in sorted(sites, key=lambda s: -s[key])[:30]:
        n = s['totn'] if churn else s['n']
        print(f"{s[key] / 1e6:8.2f}MB {n:7d} x{s[key] // max(n, 1):7d}  " + ' < '.join(s['frames'][:4]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
