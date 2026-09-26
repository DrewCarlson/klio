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

A difference one of the rules under "normalizations" below accounts for is
counted by its rule and not as a difference: `normalized` (the two sides model or
anchor the same resolution differently) or `jvm` (kotlinc answers for the JVM
stdlib, klio for the common one). --raw applies none of them.

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


class Source:
    """The compared files' bytes, for rules that read the syntax."""

    def __init__(self, root):
        self.root = root
        self.cache = {}

    def data(self, path):
        if path not in self.cache:
            full = path if os.path.isabs(path) else os.path.join(self.root, path)
            try:
                self.cache[path] = open(full, "rb").read()
            except OSError:
                self.cache[path] = b""
        return self.cache[path]

    def text(self, path, start, end):
        return self.data(path)[start:end].decode("utf-8", "replace")

    def after(self, path, end, n=80):
        return self.data(path)[end:end + n].decode("utf-8", "replace")


# ------------------------------------------------------------ normalizations
#
# A difference a rule below accounts for is not a disagreement. Each rule is one
# known way the two sides print the same resolution differently, in one of two
# classes:
#
#   normalized   representation: sema and kotlinc agree on what runs, and model
#                or anchor it differently
#   jvm          Kotlin-vs-JVM naming: kotlinc answers for the JVM stdlib and
#                its Java classes; klio names the common stdlib's declaration,
#                and puts the JVM-only classes it provides under `klio.*`
#
# A rule decides one site (or one oracle/sema pair of sites). `--raw` turns all
# of them off.

NORMALIZED, JVM = "normalized", "jvm"
RULES = {}


def rule(name, cls):
    def register(f):
        RULES[f.__name__] = (name, cls)
        f.rule = f.__name__
        return f

    return register


def split_target(target):
    """`owner.name|recv|params` -> (owner, name, recv, params); None for locals and markers."""
    head, _, rest = target.partition("|")
    if ":" in head:
        return None
    recv, _, params = rest.partition("|")
    tail = head.rsplit("/", 1)[-1]
    if "." in tail:
        owner, _, name = head.rpartition(".")
    else:
        owner, name = head[: len(head) - len(tail)].rstrip("/"), tail
    return owner, name, recv, params


def simple_name(owner):
    return owner.rsplit("/", 1)[-1].rsplit(".", 1)[-1]


LITERAL_OPS = {"plus", "minus", "times", "div", "rem", "unaryMinus", "unaryPlus"}
# Integer literals without a suffix (decimal, hex, binary), parentheses, signs
# and arithmetic operators, and nothing else.
LITERAL_ARITHMETIC = re.compile(
    r"[\s()+\-*/%]*(?:(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*)(?![.\w])[\s()+\-*/%]*)+"
)


@rule("arithmetic on integer literals, folded", NORMALIZED)
def folded_literal_arithmetic(src, key, o):
    """`1 + 2 * 3`: an operator whose operands are all integer literals is
    evaluated on their integer literal type; sema folds it to the constant and
    records no call, FIR records the `Int` (or `Long`) operator the constant
    is computed with."""
    path, start, end, kind = key
    if kind not in LITERAL_OPS or not re.match(r"kotlin/(Int|Long)\.", o[0]):
        return False
    return LITERAL_ARITHMETIC.fullmatch(src.text(path, start, end)) is not None


QUALIFIED_NAME = re.compile(r"\s*\.\s*([A-Za-z_]\w*|`[^`]+`)")


@rule("object qualifier of a nested classifier", NORMALIZED)
def classifier_path_qualifier(src, key, o, oracle_at):
    """`Obj.Nested`: FIR records the object `Obj` as a qualifier it resolved on
    the way to the nested classifier; sema resolves the whole path to the
    classifier and records the classifier only."""
    path, start, end, kind = key
    if kind != "read" or not o[0].startswith("object:"):
        return False
    m = QUALIFIED_NAME.match(src.after(path, end))
    if not m:
        return False
    at = end + len(src.after(path, end)[: m.start(1)].encode("utf-8"))
    nested = o[0] + "." + m.group(1).strip("`")
    return all(v[0] == nested for v in oracle_at(path, at))


@rule("annotation class equals/hashCode/toString", NORMALIZED)
def annotation_members(src, key, o, s):
    """An annotation class's instances compare, hash and print by value. klio
    declares those members on the annotation class; on the JVM the annotation
    proxy implements them and FIR names `Any`'s."""
    op, sp = split_target(o[0]), split_target(s[0])
    if not op or not sp or op[0] != "kotlin/Any" or op[1] not in ("equals", "hashCode", "toString"):
        return False
    if (op[1], op[2], op[3]) != (sp[1], sp[2], sp[3]) or o[1:] != s[1:]:
        return False
    decl = re.compile(rb"\bannotation\s+class\s+" + re.escape(simple_name(sp[0]).encode()) + rb"\b")
    return decl.search(src.data(key[0])) is not None


@rule("inner class constructor through a type alias", NORMALIZED)
def alias_inner_constructor(src, key, o, s):
    """`outer.Alias(x)` for `typealias Alias = Outer<X>.Inner`: FIR's type alias
    constructor takes the outer instance as its extension receiver; sema passes
    the same instance as the inner class constructor's dispatch receiver."""
    path, start, end, kind = key
    if kind not in ("ctor", "ref") or ".<init>|" not in o[0] or o[0] != s[0]:
        return False
    if not (o[1] == "-" and s[2] == "-" and o[2] == s[1] and o[2] != "-"):
        return False
    cls = o[0].split(".<init>|")[0]
    return src.text(path, start, end) != simple_name(cls)


def companion_block(src, path):
    return re.search(rb"\bcompanion\s*\{", src.data(path)) is not None


@rule("member of a companion block", NORMALIZED)
def companion_block_member(src, key, o, s):
    """klio models a `companion { }` block as the class's companion object, so
    its members are `C.Companion`'s, called on the companion; FIR declares them
    on the class itself, with no receiver."""
    op, sp = split_target(o[0]), split_target(s[0])
    if not op or not sp or sp[0] != op[0] + ".Companion" or (op[1], op[2], op[3]) != (sp[1], sp[2], sp[3]):
        return False
    if o[1] != "-" or not (s[1] == "expr" or s[1].startswith("obj@")) or o[2] != s[2]:
        return False
    return companion_block(src, key[0])


@rule("companion block qualifier", NORMALIZED)
def companion_block_qualifier(src, key, s):
    """`C.member` for a member of `C`'s `companion { }` block: sema records the
    companion object it models the block as; FIR has no object to record."""
    path, start, end, kind = key
    if kind != "read" or not s[0].startswith("object:") or not s[0].endswith(".Companion"):
        return False
    cls = s[0][len("object:"): -len(".Companion")]
    return src.text(path, start, end) == simple_name(cls) and companion_block(src, path)


@rule("`suspend { }`", NORMALIZED)
def suspend_lambda(src, key, s):
    """FIR builds `suspend { }` as a suspend lambda with no call; sema resolves
    it to the stdlib's `suspend(block)`, which returns the block."""
    path, start, end, kind = key
    return kind == "call" and s[0].startswith("kotlin/suspend||") and src.text(path, start, end) == "suspend"


@rule("collection literal in an annotation", NORMALIZED)
def annotation_array_literal(src, key, s):
    """`[1, 2]` as an annotation parameter's value: sema resolves it to the array
    factory it stands for (`intArrayOf`, `arrayOf`); FIR builds an array literal
    and records no call."""
    path, start, end, kind = key
    if kind != "call" or not re.match(r"kotlin/(\w*ArrayOf|arrayOf)\|", s[0]):
        return False
    return src.text(path, start, end).startswith("[")


@rule("parenthesized invoke callee", NORMALIZED)
def parenthesized_invoke(src, okey, o, skey, s):
    """`(f)(x)`: kotlinc anchors the implicit `invoke` on its callee expression,
    parentheses included; the parser keeps no node for the parentheses, so sema
    anchors inside them."""
    if okey[3] != "invoke" or skey[3] != "invoke" or okey[0] != skey[0]:
        return False
    if not (okey[1] < skey[1] and skey[2] < okey[2]):
        return False
    if not (o[0] == s[0] and receiver_matches(o[1], s[1]) and receiver_matches(o[2], s[2])):
        return False
    outer = src.text(okey[0], okey[1], okey[2]).strip()
    inner = src.text(skey[0], skey[1], skey[2]).strip()
    while outer.startswith("(") and outer.endswith(")") and outer != inner:
        outer = outer[1:-1].strip()
    return outer == inner


PRINT_OVERLOAD = re.compile(r"kotlin/io/print(ln)?\|\|kotlin/(Int|Long|Short|Byte|Double|Float|Char|Boolean|CharArray|String)$")


@rule("JVM print/println overload", JVM)
def jvm_print_overload(src, key, o, s):
    """`println(1)`: the JVM stdlib overloads `print`/`println` per primitive;
    the common one declares `println(Any?)`."""
    return PRINT_OVERLOAD.match(o[0]) is not None and s[0].startswith(o[0].split("||")[0] + "||")


@rule("Java class or signature", JVM)
def java_signature(src, key, o, s):
    """The same callable, where kotlinc answers with a Java declaration: a Java
    class (`java/lang/Thread.join`, which klio provides as `klio/Thread.join`;
    a Java static, which klio declares on the class's companion), a Java
    parameter type (`java/lang/ClassLoader?`, `java/nio/charset/Charset`), or a
    platform type (`MutableCollection!`)."""
    op, sp = split_target(o[0]), split_target(s[0])
    if not op or not sp or op[1] != sp[1] or "java/" in s[0]:
        return False
    return "java/" in o[0] or ("!" in o[0] and "!" not in s[0])


# Classes that are Java classes on the JVM (`actual typealias`), mapped to the
# Kotlin name the oracle prints.
JVM_MAPPED = {
    "kotlin/text/StringBuilder", "kotlin/Throwable",
    "kotlin/collections/ArrayList", "kotlin/collections/HashMap", "kotlin/collections/HashSet",
    "kotlin/collections/LinkedHashMap", "kotlin/collections/LinkedHashSet",
}
# JVM classes that override members their klio superclass declares.
JVM_OVERRIDES_SUPER = {
    "kotlin/collections/LinkedHashMap": "kotlin/collections/HashMap",
    "kotlin/collections/LinkedHashSet": "kotlin/collections/HashSet",
}
COLLECTION_INTERFACE = re.compile(r"kotlin/collections/(Mutable)?(List|Collection|Set|Map|Iterable)$")


@rule("member of a JVM class", JVM)
def jvm_class_member(src, key, o, s):
    """A member a JVM class declares where the common stdlib does not:
    `StringBuilder.toString()` and `HashMap.equals` (the common classes
    inherit `Any`'s), a member
    klio provides as an extension (`StringBuilder.setCharAt`,
    `Throwable.stackTrace`), and the members of `AbstractMutableList` and its
    kin, which on the JVM is `java.util.AbstractList` and FIR names by the
    Kotlin interface it maps to (`Any` for `equals`) where the common class
    declares them itself. `LinkedHashMap.entries` is also one: the JVM class
    overrides it, klio's inherits `HashMap`'s."""
    op, sp = split_target(o[0]), split_target(s[0])
    if not op or not sp or op[1] != sp[1]:
        return False
    (oo, on, orc, opa), (so, sn, src_, spa) = op, sp
    if JVM_OVERRIDES_SUPER.get(oo) == so and orc == src_ and opa == spa and o[1:] == s[1:]:
        return True
    if oo in JVM_MAPPED and orc == "":
        if so == "kotlin/Any" and src_ == "" and opa == spa:
            return True
        if src_ == oo and opa == spa and o[1] == "expr" and s[2] == "expr":
            return True
    if so.startswith("kotlin/collections/Abstract") and orc == src_ == "" and opa == spa:
        return COLLECTION_INTERFACE.match(oo) is not None or oo == "kotlin/Any"
    return False


@rule("companion of a klio JVM class", JVM)
def klio_companion_qualifier(src, key, s):
    """`Thread.currentThread()`: a Java static member, which klio declares on
    the companion of its `klio.*` class; sema records the companion it is
    called on."""
    return key[3] == "read" and re.match(r"object:klio/[\w/.]+\.Companion$", s[0]) is not None


@rule("JVM factory for a Native constructor", JVM)
def jvm_factory_constructor(src, okey, o, skey, s):
    """`CancellationException(message, cause)`: the JVM class has no such
    constructor, so kotlinc calls the factory function named after the class;
    on Native, as in klio, the class declares the constructor, and it outranks
    the factory, which is `@LowPriorityInOverloadResolution`."""
    if okey[:3] != skey[:3] or okey[3] != "call" or skey[3] != "ctor" or o[1:] != s[1:]:
        return False
    fn, _, orest = o[0].partition("|")
    ctor, _, srest = s[0].partition("|")
    if not ctor.endswith(".<init>") or orest != srest or not orest.startswith("|"):
        return False
    return simple_name(ctor[: -len(".<init>")]) == simple_name(fn)


PAIR_RULES = (annotation_members, alias_inner_constructor, companion_block_member,
              jvm_print_overload, java_signature, jvm_class_member)
ORACLE_ONLY_RULES = (folded_literal_arithmetic,)
SEMA_ONLY_RULES = (companion_block_qualifier, suspend_lambda, annotation_array_literal, klio_companion_qualifier)
MOVED_RULES = (parenthesized_invoke, jvm_factory_constructor)


class Normalizer:
    """Applies the rules above; `off` makes every lookup miss."""

    def __init__(self, root, oracle, off=False):
        self.src = Source(root)
        self.off = off
        self.oracle_by_start = collections.defaultdict(list)
        for key, vals in oracle.items():
            self.oracle_by_start[(key[0], key[1])].extend(vals)

    def oracle_at(self, path, start):
        return self.oracle_by_start.get((path, start), [])

    def pair(self, key, o, s):
        if self.off:
            return None
        return next((r.rule for r in PAIR_RULES if r(self.src, key, o, s)), None)

    def oracle_only(self, key, o):
        if self.off:
            return None
        if classifier_path_qualifier(self.src, key, o, self.oracle_at):
            return classifier_path_qualifier.rule
        return next((r.rule for r in ORACLE_ONLY_RULES if r(self.src, key, o)), None)

    def sema_only(self, key, s):
        if self.off:
            return None
        return next((r.rule for r in SEMA_ONLY_RULES if r(self.src, key, s)), None)

    def moved(self, okey, o, skey, s):
        if self.off:
            return None
        return next((r.rule for r in MOVED_RULES if r(self.src, okey, o, skey, s)), None)

    def pair_leftovers(self, only_o, only_s):
        """Pairs an oracle-only site with a sema-only one a rule says is the same
        site at another anchor. Returns (pairs, oracle rest, sema rest)."""
        by_path = collections.defaultdict(list)
        for i, (key, s) in enumerate(only_s):
            by_path[key[0]].append(i)
        used, pairs, rest_o = set(), [], []
        for okey, o in only_o:
            hit = None
            for i in by_path[okey[0]]:
                if i in used:
                    continue
                skey, s = only_s[i]
                r = self.moved(okey, o, skey, s)
                if r:
                    hit = (i, r)
                    break
            if hit:
                used.add(hit[0])
                pairs.append((hit[1], okey, o, only_s[hit[0]]))
            else:
                rest_o.append((okey, o))
        rest_s = [x for i, x in enumerate(only_s) if i not in used]
        return pairs, rest_o, rest_s


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
    ap.add_argument("--raw", action="store_true", help="apply no normalization rule")
    ap.add_argument("--root", default=".", help="directory relative paths are resolved against")
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
    by_rule = collections.Counter()
    rule_examples = collections.defaultdict(list)
    matched = 0
    loc = Locator(args.root)
    norm = Normalizer(args.root, oracle, off=args.raw)

    def note(cat, key, detail):
        counts[cat][key[3]] += 1
        if len(examples[cat]) < args.examples:
            examples[cat].append({"where": loc.where(key[0], key[1]), "key": list(key), **detail})

    def accounted(r, key, detail):
        by_rule[r] += 1
        if len(rule_examples[r]) < args.examples:
            rule_examples[r].append({"where": loc.where(key[0], key[1]), "key": list(key), **detail})

    only_o, only_s = [], []
    for key in sorted(set(oracle) | set(sema)):
        ovals = oracle.get(key, [])
        svals = sema.get(key, [])
        if not keep(key, ovals + svals):
            continue
        exact, targets, receivers, o_left, s_left = pair_up(ovals, svals, args.strict_platform)
        matched += exact
        for cat, pairs in (("target", targets), ("receivers", receivers)):
            for o, s in pairs:
                detail = {"oracle": list(o), "sema": list(s)}
                r = norm.pair(key, o, s)
                if r:
                    accounted(r, key, detail)
                else:
                    note(cat, key, detail)
        only_o += [(key, o) for o in o_left]
        only_s += [(key, s) for s in s_left]

    moved, only_o, only_s = norm.pair_leftovers(only_o, only_s)
    for r, okey, o, (skey, s) in moved:
        accounted(r, okey, {"oracle": list(o), "sema": [f"{skey[1]}-{skey[2]}"] + list(s)})
    for key, o in only_o:
        r = norm.oracle_only(key, o)
        if r:
            accounted(r, key, {"oracle": list(o)})
        else:
            note("only-oracle", key, {"oracle": list(o)})
    for key, s in only_s:
        r = norm.sema_only(key, s)
        if r:
            accounted(r, key, {"sema": list(s)})
        else:
            note("only-sema", key, {"sema": list(s)})

    total = {c: sum(counts[c].values()) for c in CATEGORIES}
    differences = sum(total.values())
    by_class = collections.Counter()
    for r, n in by_rule.items():
        by_class[RULES[r][1]] += n

    if args.json:
        json.dump(
            {
                "matched": matched,
                "normalized": by_class[NORMALIZED],
                "jvm": by_class[JVM],
                "differences": differences,
                "totals": total,
                "by_kind": {c: dict(sorted(counts[c].items())) for c in CATEGORIES},
                "rules": {r: {"rule": RULES[r][0], "class": RULES[r][1], "count": n} for r, n in by_rule.most_common()},
                "examples": examples,
                "rule_examples": rule_examples,
                "paths_compared": len(oracle_paths),
                "sema_paths_skipped": skipped_paths,
            },
            sys.stdout,
            indent=2,
        )
        print()
    else:
        print(
            f"compared {len(oracle_paths)} files: {matched} sites match, "
            f"{by_class[NORMALIZED]} normalized, {by_class[JVM]} Kotlin-vs-JVM naming, {differences} differ"
        )
        if skipped_paths:
            print(f"skipped {len(skipped_paths)} sema-only files (not compiled by the oracle; --all-paths to include)")
        for cls, title in ((NORMALIZED, "normalized"), (JVM, "Kotlin-vs-JVM naming")):
            rows = [(r, n) for r, n in by_rule.most_common() if RULES[r][1] == cls]
            if rows:
                print(f"\n{title}: {by_class[cls]}")
                for r, n in rows:
                    print(f"  {n:6d}  {RULES[r][0]}")
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
