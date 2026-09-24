#!/usr/bin/env python3
"""Sort the differences between a sema dump and the kotlinc oracle into causes.

    scripts/sema-oracle-triage.py [-n N] [--json] oracle.tsv sema.tsv [sema.unresolved.tsv]

Pairs the two dumps the way scripts/sema-oracle-diff.py does, then assigns every
difference to a cause by rule, under one of three owners:

    sema     the analysis resolved differently (or not at all)
    dump     representation: the two sides agree on the declaration but print it
             differently; tools/sema-oracle/README.md ("The sema side") lists the
             ones the dump already corrects
    oracle   kotlinc answered for the JVM, not the common stdlib KLIO implements

A target difference no narrower rule matches is `different declaration`. The
optional third input is `klio sema --unresolved` output; with it, a site kotlinc
resolved and sema reported unresolved is attributed to the census reason.

scripts/sema-oracle-compare.sh writes all three inputs with `-o DIR`.
"""

import argparse
import collections
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("sema_oracle_diff", os.path.join(HERE, "sema-oracle-diff.py"))
diff = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(diff)


def load_unresolved(path):
    sites = collections.defaultdict(list)
    if not path:
        return sites
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.rstrip("\n").split("\t", 4)
            if len(cols) < 4:
                continue
            sites[cols[0]].append((int(cols[1]), int(cols[2]), cols[3], cols[4] if len(cols) > 4 else ""))
    return sites


class Source:
    """Byte ranges of the compared files, for rules that read the syntax."""

    def __init__(self, root):
        self.root = root
        self.cache = {}

    def before(self, path, offset, n=40):
        data = open_bytes(self, path)
        return data[max(0, offset - n):offset].decode("utf-8", "replace")

    def span(self, path, start, end):
        return open_bytes(self, path)[start:end].decode("utf-8", "replace")


def open_bytes(src, path):
    key = ("b", path)
    if key not in src.cache:
        full = path if os.path.isabs(path) else os.path.join(src.root, path)
        try:
            src.cache[key] = open(full, "rb").read()
        except OSError:
            src.cache[key] = b""
    return src.cache[key]


def callable_parts(target):
    """`owner.name|recv|params` -> (owner, name, recv, params); locals and markers -> None."""
    if ":" in target.split("|")[0] and not target.startswith("local:"):
        return None
    head, _, rest = target.partition("|")
    recv, _, params = rest.partition("|")
    if "." in head.rsplit("/", 1)[-1]:
        owner, _, name = head.rpartition(".")
    else:
        owner, name = (head.rpartition("/")[0], head.rpartition("/")[2]) if "/" in head else ("", head)
    return owner, name, recv, params


JVM_OVERLOAD = re.compile(r"^kotlin/io/print(ln)?\|\|kotlin/(Int|Long|Short|Byte|Double|Float|Char|Boolean|CharArray|String)$")
JVM_OWNER = re.compile(r"^(java/|kotlin/text/StringBuilder\.toString\||kotlin/collections/(MutableList|List|Collection|MutableCollection)\.(add|contains|indexOf|equals|remove)\|)")
NULLABLE_RECV = re.compile(r"\|[^|]+\?\|")
PRIMITIVE = re.compile(r"^kotlin/(Int|Long|Short|Byte|Double|Float|Char|Boolean|String|UInt|ULong|UShort|UByte)$")


def classify_target(o, s):
    """(owner, cause) for a site both sides resolved, to different declarations."""
    ot, st = o[0], s[0]
    if JVM_OVERLOAD.match(ot) and st.startswith(ot.split("||")[0] + "||"):
        return "oracle", "JVM-only print/println overload"
    if JVM_OWNER.match(ot) and not ot.startswith("java/"):
        return "oracle", "member declared by the JVM class"
    if ot.startswith("java/") or "java/" in ot or ("!" in ot and "!" not in st):
        return "oracle", "Java signature"
    mo = re.match(r"local:([^@]+)@(\d+)(.*)", ot)
    ms = re.match(r"local:([^@]+)@(\d+)(.*)", st)
    if mo and ms and mo.group(1) == ms.group(1) and mo.group(3) == ms.group(3):
        return "dump", "declaration offset"
    if ot.startswith("field:") and not st.startswith("field:"):
        return "dump", "backing field"
    # `local:name@N` alone is a local or parameter; `local:C@N.m||` a member
    # of a local class.
    if ms and ms.group(3) == "" and not (mo and mo.group(3) == "") and ot.endswith("||"):
        op = callable_parts(ot)
        if op and op[1] == ms.group(1):
            return "sema", "constructor parameter resolved where the member property is meant"
    if ot.startswith("local:") and ".<init>|" in ot and st.startswith("object:local:"):
        return "sema", "reference to a local class constructor names the class"
    op, sp = callable_parts(ot), callable_parts(st)
    if not op or not sp:
        return "sema", "different declaration"
    (oo, on, orc, opa), (so, sn, src_, spa) = op, sp
    if on != sn:
        return "sema", "different declaration"
    if on in ("equals", "hashCode", "toString") and oo == "kotlin/Any" and PRIMITIVE.match(so):
        return "oracle", "member the JVM builtin does not declare"
    if on in ("equals", "hashCode", "toString") and so == "kotlin/Any" and orc == "" and src_ == "":
        if oo.startswith("kotlin/"):
            return "sema", "stdlib class's own equals/hashCode/toString missed"
        return "sema", "data/value class generated member missing"
    if NULLABLE_RECV.search("|" + orc + "|") and src_ == "" and so:
        return "sema", "member chosen on a nullable receiver (the nullable extension applies)"
    if orc == "" and oo and NULLABLE_RECV.search("|" + src_ + "|"):
        return "sema", "nullable extension chosen where the member applies"
    if orc == "" and oo and src_ and not so.count("."):
        return "sema", "extension chosen over an applicable member"
    if orc and src_ and orc != src_ and opa != spa and oo == so:
        return "sema", "overload: extension receiver specificity"
    if orc and src_ and orc != src_:
        return "sema", "overload: extension receiver specificity"
    if oo == so and (opa != spa or orc != src_):
        if spa.endswith("...") != opa.endswith("..."):
            return "sema", "overload: vararg vs fixed arity"
        return "sema", "overload: parameter types"
    if oo.startswith("local:<anonymous>") != so.startswith("local:<anonymous>"):
        if so.startswith("local:<anonymous>"):
            return "sema", "anonymous object type leaks through a member's inferred type"
        return "sema", "member of an anonymous object missed"
    if oo != so and opa == spa and orc == src_:
        return "sema", "same member name, different owner (override or delegation)"
    return "sema", "different declaration"


def classify_receivers(o, s, key, src):
    """(owner, cause) for a site resolved to the same declaration through different receivers."""
    path, start, end, kind = key
    od, oe = o[1], o[2]
    sd, se = s[1], s[2]
    target = o[0]
    before = src.before(path, start, 60)
    if re.search(r"super(<[^>]*>)?(@\w+)?\s*\.\s*$", before) and od == "expr" and sd.startswith("this@"):
        return "sema", "super call recorded as an implicit this"
    if target.startswith("enum:") and od == "-" and sd != "-":
        return "sema", "enum entry given a dispatch receiver"
    if kind == "ref":
        if (od, oe) == (se, sd):
            return "sema", "callable reference receiver in the wrong slot"
        if sd == "-" and se == "-":
            return "sema", "callable reference drops its implicit receiver"
    if kind == "ctor" and od != "-" and sd == "-":
        return "sema", "inner class constructor without its outer receiver"
    if od == "expr" and sd == "-":
        return "sema", "object/companion qualifier not recorded as the receiver"
    if od != sd and od != "-" and sd != "-" and od.split("@")[0] == sd.split("@")[0]:
        return "sema", "implicit receiver from a different scope"
    if oe != se and oe != "-" and se != "-":
        return "sema", "implicit receiver from a different scope"
    return "sema", "receiver origin differs"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("oracle")
    ap.add_argument("sema")
    ap.add_argument("unresolved", nargs="?")
    ap.add_argument("-n", "--examples", type=int, default=3, help="examples per cause (default 3)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--root", default=".", help="directory the dump paths are relative to")
    args = ap.parse_args()

    oracle = diff.load(args.oracle)
    sema = diff.load(args.sema)
    unresolved = load_unresolved(args.unresolved)
    src = Source(args.root)
    loc = diff.Locator(args.root)
    oracle_paths = {k[0] for k in oracle}
    sema = {k: v for k, v in sema.items() if k[0] in oracle_paths}

    causes = collections.defaultdict(list)  # (owner, cause) -> [example]
    matched = 0
    only_o, only_s = [], []  # (key, value)

    def note(owner, cause, key, o=None, s=None):
        causes[(owner, cause)].append({"where": loc.where(key[0], key[1]), "kind": key[3], "oracle": o, "sema": s})

    for key in sorted(set(oracle) | set(sema)):
        ovals = list(oracle.get(key, []))
        svals = list(sema.get(key, []))
        # A reference sema recorded more than once.
        counts = collections.Counter(svals)
        ocounts = collections.Counter(ovals)
        for v, n in counts.items():
            extra = n - max(ocounts.get(v, 0), 1)
            for _ in range(max(extra, 0)):
                svals.remove(v)
                note("sema", "duplicate reference (the same site resolved twice)", key, None, v)
        exact, targets, receivers, o_left, s_left = diff.pair_up(ovals, svals, False)
        matched += exact
        for o, s in targets:
            note(*classify_target(o, s), key, o, s)
        for o, s in receivers:
            note(*classify_receivers(o, s, key, src), key, o, s)
        only_o += [(key, o) for o in o_left]
        only_s += [(key, s) for s in s_left]

    # Pair leftovers that differ only in anchor or kind.
    by_path = collections.defaultdict(list)
    for i, (key, s) in enumerate(only_s):
        by_path[key[0]].append(i)
    used = set()
    rest_o = []
    for key, o in only_o:
        path, start, end, kind = key
        hit = None
        for i in by_path[path]:
            if i in used:
                continue
            skey, s = only_s[i]
            if s[0] != o[0]:
                continue
            if skey[1] == start and skey[2] == end and skey[3] != kind:
                hit = (i, "kind", skey, s)
                break
            if skey[3] == kind and skey[1] < end and start < skey[2]:
                hit = (i, "anchor", skey, s)
        if hit:
            i, what, skey, s = hit
            used.add(i)
            if what == "kind":
                note("sema", f"kind differs (oracle {kind}, sema {skey[3]})", key, o, s)
            else:
                note("dump", "anchor differs", key, o, (f"{skey[1]}-{skey[2]}",) + tuple(s))
            continue
        rest_o.append((key, o))

    for key, o in rest_o:
        path, start, end, kind = key
        reason = None
        for a, b, r, detail in unresolved.get(path, []):
            if (a <= start and end <= b) or (start <= a and b <= end):
                reason = r
                break
        if reason:
            note("sema", f"unresolved ({reason})", key, o, None)
        elif o[0].startswith("object:") and kind == "read":
            note("sema", "object/companion qualifier not recorded", key, o, None)
        else:
            note("sema", "site not visited", key, o, None)

    for i, (key, s) in enumerate(only_s):
        if i in used:
            continue
        path, start, end, kind = key
        text = src.span(path, start, end)
        if kind == "equals" and re.search(r"(^\s*null\s*[!=]=)|([!=]=\s*null\s*$)|(^\s*null\s*$)", text):
            note("sema", "`== null` recorded as an equals call", key, None, s)
        elif kind.startswith("component") and text.strip() == "_":
            note("sema", "componentN called for a `_` entry", key, None, s)
        else:
            note("oracle", "no oracle site (sema-only reference)", key, None, s)

    total = collections.Counter()
    for (owner, cause), items in causes.items():
        total[owner] += len(items)

    if args.json:
        out = {
            "matched": matched,
            "by_owner": dict(total),
            "causes": [
                {"owner": owner, "cause": cause, "count": len(items), "examples": items[: args.examples]}
                for (owner, cause), items in sorted(causes.items(), key=lambda kv: (-len(kv[1]), kv[0]))
            ],
        }
        json.dump(out, sys.stdout, indent=2)
        print()
        return 0

    differ = sum(total.values())
    print(f"{matched} sites match, {differ} differ: " + ", ".join(f"{k} {v}" for k, v in total.most_common()))
    for owner in ("sema", "dump", "oracle"):
        rows = [(cause, items) for (ow, cause), items in causes.items() if ow == owner]
        if not rows:
            continue
        print(f"\n== {owner} ({total[owner]})")
        for cause, items in sorted(rows, key=lambda r: -len(r[1])):
            print(f"\n{len(items):6d}  {cause}")
            for ex in items[: args.examples]:
                print(f"        {ex['where']} {ex['kind']}")
                if ex["oracle"]:
                    print(f"          oracle: {' | '.join(ex['oracle'])}")
                if ex["sema"]:
                    print(f"          sema:   {' | '.join(ex['sema'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
