#!/usr/bin/env python3
"""Diff a sema resolution dump against the kotlinc oracle, site by site.

Both inputs use the oracle line format (tools/sema-oracle/README.md):

    path <TAB> start <TAB> end <TAB> kind <TAB> target <TAB> dispatch <TAB> extension

Sites are joined on (path, start, end, kind). Several sites may share a key; the
values under a key are compared as multisets. Reported categories:

    only-oracle   kotlinc resolved a site sema did not emit
    only-sema     sema emitted a site kotlinc did not resolve
    target        both resolved the site, to different declarations
    receivers     same declaration, different dispatch/extension receiver origin

By default only paths present in the oracle dump are compared (files kotlinc could
not compile are absent from it). A platform type in an oracle target (`kotlin/String!`)
matches `kotlin/String` or `kotlin/String?` unless --strict-platform is given.

Exit status: 0 when there are no differences, 1 otherwise, 2 on bad input.
"""

import argparse
import collections
import json
import os
import re
import sys

CATEGORIES = ("only-oracle", "only-sema", "target", "receivers")


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


def load(path):
    sites = collections.defaultdict(list)
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 7:
                die(f"{path}:{n}: expected 7 tab-separated columns, got {len(cols)}")
            p, start, end, kind, target, dispatch, extension = cols
            try:
                key = (p, int(start), int(end), kind)
            except ValueError:
                die(f"{path}:{n}: start/end must be integers")
            sites[key].append((target, dispatch, extension))
    return sites


_platform_cache = {}


def target_matches(oracle, sema, strict):
    if oracle == sema:
        return True
    if strict or "!" not in oracle:
        return False
    rx = _platform_cache.get(oracle)
    if rx is None:
        rx = re.compile("".join(r"\??" if ch == "!" else re.escape(ch) for ch in oracle))
        _platform_cache[oracle] = rx
    return rx.fullmatch(sema) is not None


def receiver_matches(oracle, sema):
    """A dispatch or extension receiver: FIR prints an object reached as a
    resolved qualifier (an imported object member, `Obj.x`) as `expr`,
    where sema records the object as an implicit receiver, `obj@Obj`."""
    if oracle == sema:
        return True
    return oracle == "expr" and sema.startswith("obj@")


def pair_up(ovals, svals, strict):
    """Match oracle values to sema values under one key.

    Returns (exact matches, target mismatches, receiver mismatches, oracle leftovers, sema leftovers).
    """
    ovals, svals = list(ovals), list(svals)
    exact = 0
    for o in list(ovals):
        for s in svals:
            if target_matches(o[0], s[0], strict) and receiver_matches(o[1], s[1]) and receiver_matches(o[2], s[2]):
                ovals.remove(o)
                svals.remove(s)
                exact += 1
                break
    receivers = []
    for o in list(ovals):
        for s in svals:
            if target_matches(o[0], s[0], strict):
                receivers.append((o, s))
                ovals.remove(o)
                svals.remove(s)
                break
    n = min(len(ovals), len(svals))
    targets = list(zip(ovals[:n], svals[:n]))
    return exact, targets, receivers, ovals[n:], svals[n:]


class Locator:
    """Byte offset -> line:col, when the source file is readable."""

    def __init__(self, root):
        self.root = root
        self.cache = {}

    def where(self, path, offset):
        starts = self.cache.get(path)
        if starts is None:
            starts = []
            full = path if os.path.isabs(path) else os.path.join(self.root, path)
            try:
                data = open(full, "rb").read()
                starts = [0] + [i + 1 for i, b in enumerate(data) if b == 0x0A]
            except OSError:
                pass
            self.cache[path] = starts
        if not starts:
            return f"{path}@{offset}"
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return f"{path}:{lo + 1}:{offset - starts[lo] + 1}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("oracle", help="oracle TSV (scripts/sema-oracle.sh output)")
    ap.add_argument("sema", help="sema TSV in the same format")
    ap.add_argument("-n", "--examples", type=int, default=10, help="examples shown per category (default 10)")
    ap.add_argument("--json", action="store_true", help="print a JSON summary instead of text")
    ap.add_argument("--all-paths", action="store_true", help="also compare paths the oracle has no sites for")
    ap.add_argument("--kind", action="append", default=[], help="only compare these kinds (repeatable)")
    ap.add_argument("--exclude-target", metavar="REGEX", help="drop keys whose oracle or sema target matches")
    ap.add_argument("--strict-platform", action="store_true", help="a platform type `T!` must match `T!` exactly")
    ap.add_argument("--root", default=".", help="directory relative paths are resolved against for line:col")
    args = ap.parse_args()

    try:
        oracle = load(args.oracle)
        sema = load(args.sema)
    except OSError as e:
        die(str(e))

    oracle_paths = {k[0] for k in oracle}
    sema_paths = {k[0] for k in sema}
    skipped_paths = sorted(sema_paths - oracle_paths) if not args.all_paths else []
    if not args.all_paths:
        sema = {k: v for k, v in sema.items() if k[0] in oracle_paths}

    kinds = set(args.kind)
    exclude = re.compile(args.exclude_target) if args.exclude_target else None

    def keep(key, vals):
        if kinds and key[3] not in kinds:
            return False
        if exclude and any(exclude.search(v[0]) for v in vals):
            return False
        return True

    counts = {c: collections.Counter() for c in CATEGORIES}
    examples = {c: [] for c in CATEGORIES}
    matched = 0
    loc = Locator(args.root)

    def note(cat, key, detail):
        counts[cat][key[3]] += 1
        if len(examples[cat]) < args.examples:
            examples[cat].append({"where": loc.where(key[0], key[1]), "key": list(key), **detail})

    for key in sorted(set(oracle) | set(sema)):
        ovals = oracle.get(key, [])
        svals = sema.get(key, [])
        if not keep(key, ovals + svals):
            continue
        if not svals:
            for o in ovals:
                note("only-oracle", key, {"oracle": list(o)})
            continue
        if not ovals:
            for s in svals:
                note("only-sema", key, {"sema": list(s)})
            continue
        exact, targets, receivers, o_left, s_left = pair_up(ovals, svals, args.strict_platform)
        matched += exact
        for o, s in targets:
            note("target", key, {"oracle": list(o), "sema": list(s)})
        for o, s in receivers:
            note("receivers", key, {"oracle": list(o), "sema": list(s)})
        for o in o_left:
            note("only-oracle", key, {"oracle": list(o)})
        for s in s_left:
            note("only-sema", key, {"sema": list(s)})

    total = {c: sum(counts[c].values()) for c in CATEGORIES}
    differences = sum(total.values())

    if args.json:
        json.dump(
            {
                "matched": matched,
                "differences": differences,
                "totals": total,
                "by_kind": {c: dict(sorted(counts[c].items())) for c in CATEGORIES},
                "examples": examples,
                "paths_compared": len(oracle_paths),
                "sema_paths_skipped": skipped_paths,
            },
            sys.stdout,
            indent=2,
        )
        print()
    else:
        print(f"compared {len(oracle_paths)} files: {matched} sites match, {differences} differ")
        if skipped_paths:
            print(f"skipped {len(skipped_paths)} sema-only files (not compiled by the oracle; --all-paths to include)")
        for c in CATEGORIES:
            if not total[c]:
                continue
            by_kind = ", ".join(f"{k} {v}" for k, v in counts[c].most_common())
            print(f"\n{c}: {total[c]}  ({by_kind})")
            for ex in examples[c]:
                parts = [f"  {ex['where']} {ex['key'][3]}"]
                if "oracle" in ex:
                    parts.append(f"    oracle: {' | '.join(ex['oracle'])}")
                if "sema" in ex:
                    parts.append(f"    sema:   {' | '.join(ex['sema'])}")
                print("\n".join(parts))
    return 0 if differences == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
