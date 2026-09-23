#!/usr/bin/env python3
"""Name the lowering arms that emit unresolved instructions.

`KLIO_EMIT_CENSUS=1` counts every instruction pushed into a block whose site
census verdict is `unresolved`, keyed by the return address of `FuncBuilder.push`
— that is, by the lowering arm that emitted it. The per-gate `[lower-sites]`
counters answer for the one gate that calls them; this answers for every
emitter, including the arms that never ask a gate at all.

  KLIO_EMIT_CENSUS=1 klio run prog.kt 2> emit.txt
  scripts/emit_census_symbolize.py zig-out/bin/klio-harness emit.txt

Addresses slide with the load address, so the dump carries one anchor symbol
and this reads the static address of the same symbol out of the binary.
"""
import argparse, bisect, collections, re, subprocess, sys

HEAD = re.compile(r"^\[emit-census\] total=(\d+) distinct=(\d+) anchor (\S+)=0x([0-9a-f]+)", re.M)
ROW = re.compile(r"^\[emit-census\]\s+(\d+)\s+(\S+)\s+0x([0-9a-f]+)$", re.M)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("dump")
    ap.add_argument("--top", type=int, default=40)
    ap.add_argument("--kind", help="only this site kind")
    args = ap.parse_args()
    text = open(args.dump, errors="replace").read()
    head = HEAD.search(text)
    if not head:
        print("no [emit-census] header in", args.dump, file=sys.stderr)
        return 2
    total, _distinct, anchor_name, anchor_addr = head.group(1), head.group(2), head.group(3), int(head.group(4), 16)

    syms = []
    for line in subprocess.run(["nm", "-n", args.binary], capture_output=True, text=True).stdout.splitlines():
        m = re.match(r"^([0-9a-f]+) [tT] (.*)$", line)
        if m:
            syms.append((int(m[1], 16), m[2].lstrip("_")))
    if not syms:
        print("no symbols in", args.binary, file=sys.stderr)
        return 2
    addrs = [a for a, _ in syms]
    static = next((a for a, n in syms if n.endswith(anchor_name)), None)
    if static is None:
        print(f"anchor {anchor_name} not found in {args.binary}", file=sys.stderr)
        return 2
    slide = anchor_addr - static

    folded = collections.Counter()
    by_kind = collections.Counter()
    for n, kind, addr in ROW.findall(text):
        if args.kind and kind != args.kind:
            continue
        n = int(n)
        st = int(addr, 16) - slide
        i = bisect.bisect_right(addrs, st) - 1
        name = syms[i][1] if i >= 0 else f"0x{st:x}"
        folded[(kind, name)] += n
        by_kind[kind] += n

    shown = sum(by_kind.values())
    print(f"emitted unresolved instructions: {shown} (dump total {total})")
    print()
    for kind, n in by_kind.most_common():
        print(f"  {n:>10}  {kind}")
    print()
    print("by emitting arm:")
    for (kind, name), n in folded.most_common(args.top):
        print(f"  {n:>10}  {kind:<26} {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
