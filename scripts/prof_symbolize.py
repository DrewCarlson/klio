#!/usr/bin/env python3
"""Symbolize a klio PC profile on macOS.

The sampler (KLIO_PROF_ALL=1 KLIO_PROF=<usec> KLIO_PROF_RAW=<n>) prints folded
raw addresses with the phase each sample fell in and, on arm64, the caller's
address from the link register. The in-process symbolizer resolves nothing on
macOS, so this reads that dump, slides the addresses with the anchor the dump
carries, names them through `atos` (falling back to the nearest symbol from
`nm` for code the linker deduplicated) and folds the counts.

  prof_symbolize.py BIN PROF.txt                    top functions, then by phase
  prof_symbolize.py BIN PROF.txt --top 40 --phase-top 8
  prof_symbolize.py BIN PROF.txt --callers 'memcpy'  callers of the matching leaf, by phase

Addresses in the shared cache (libsystem) print as `libsystem 0x...`; they
symbolize only against a live process (`atos -p <pid> <addr>` on any running
klio, the slide being the same for every process of a boot).
"""
import argparse, bisect, collections, re, subprocess

ROW = re.compile(r'^\s+0x([0-9a-f]+)\s+(\d+)(?:\s+(\d+))?(?:\s+0x([0-9a-f]+))?$', re.M)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('binary'); ap.add_argument('prof')
    ap.add_argument('--top', type=int, default=40); ap.add_argument('--phase-top', type=int, default=8)
    ap.add_argument('--callers', help='regex over leaf names; fold the matching samples by caller')
    args = ap.parse_args()
    text = open(args.prof).read()
    anchor = int(re.search(r'anchor handler=0x([0-9a-f]+)', text)[1], 16)
    rows = [(int(a, 16), int(c), int(p) if p else 0, int(cl, 16) if cl else 0) for a, c, p, cl in ROW.findall(text)]
    phases = dict((int(i), n) for i, n in re.findall(r'^\[prof-phase\] (\d+) (.*)$', text, re.M))
    syms = []
    for line in subprocess.run(['nm', '-n', args.binary], capture_output=True, text=True).stdout.splitlines():
        m = re.match(r'^([0-9a-f]+) [tT] (.*)$', line)
        if m: syms.append((int(m[1], 16), m[2].lstrip('_')))
    addrs = [a for a, _ in syms]
    static = next(a for a, n in syms if n == 'prof.handler')
    slide = anchor - static

    def nearest(a):
        if not (0x100000000 <= a < 0x180000000): return 'libsystem ' + hex(a)
        i = bisect.bisect_right(addrs, a - slide) - 1
        return re.sub(r'__anon_\d+', '', syms[i][1]) if i >= 0 else '?'

    wanted = sorted(set(a for a, _, _, _ in rows) | set(cl for _, _, _, cl in rows if cl))
    names = {}
    for i in range(0, len(wanted), 400):
        chunk = wanted[i:i + 400]
        out = subprocess.run(['atos', '-o', args.binary, '-s', hex(slide)] + [hex(a) for a in chunk], capture_output=True, text=True).stdout.splitlines()
        for a, line in zip(chunk, out):
            n = re.sub(r'__anon_\d+', '', re.sub(r' \(in .*$', '', line).strip())
            names[a] = n if n and not n.startswith('<') and not n.startswith('0x') else nearest(a)
    total = sum(c for _, c, _, _ in rows)
    if args.callers:
        leaf = re.compile(args.callers)
        by_caller = collections.Counter(); by_phase = collections.defaultdict(collections.Counter); matched = 0
        for a, c, p, cl in rows:
            if leaf.search(names[a]):
                matched += c; by_caller[names.get(cl, '?')] += c; by_phase[p][names.get(cl, '?')] += c
        print(f"{matched} of {total} samples match /{args.callers}/")
        for n, c in by_caller.most_common(args.top): print(f"{c:6d}  {n}")
        for p, cnt in sorted(by_phase.items(), key=lambda kv: -sum(kv[1].values()))[:args.phase_top]:
            print(f"\n{sum(cnt.values()):5d}  {phases.get(p, '<after last mark>')}")
            for n, c in cnt.most_common(6): print(f"        {c:5d}  {n}")
        return
    by_fn = collections.Counter(); by_phase = collections.Counter(); by_phase_fn = collections.defaultdict(collections.Counter)
    for a, c, p, _ in rows:
        by_fn[names[a]] += c; by_phase[p] += c; by_phase_fn[p][names[a]] += c
    print(f"{total} samples, {len(set(a for a, _, _, _ in rows))} PCs, slide {hex(slide)}")
    for n, c in by_fn.most_common(args.top): print(f"{100 * c / total:6.2f}% {c:6d}  {n}")
    if phases:
        print("\n=== by phase")
        for p, c in by_phase.most_common():
            if c * 200 < total: continue
            print(f"\n{c:5d} {100 * c / total:5.1f}%  {phases.get(p, '<after last mark>')}")
            for n, cc in by_phase_fn[p].most_common(args.phase_top): print(f"        {cc:5d}  {n}")


if __name__ == '__main__':
    main()
