#!/usr/bin/env python3
"""Inventory of the Kotlin stdlib surface klio does NOT provide.

`kotlin.system.measureTimeMillis` shipped in no klio source and was found
only because a perf rig happened to call it. This is the report that would
have caught it: every public top-level declaration upstream declares,
minus every one klio's own sources provide, grouped by package and ranked.

klio's surface is exactly the files it consumes:
  - `CURATED_UPSTREAM_SOURCES` (the vendored upstream subset), and
  - `KLIO_STDLIB_ACTUAL_FILES` (klio-authored actuals/replacements),
both listed in `src/stdlib/stdlib_sources.zig`.

Upstream's surface is every `.kt` under `kotlin/libraries/stdlib`, minus
tests and samples. Platform source sets (jvm/js/wasm/native) are INCLUDED
on purpose: a declaration that exists only there is exactly the case that
needs a klio-authored actual, which is what `measureTimeMillis` needed.

The diff is not meant to reach zero — most of the platform surface is
deliberately out of scope (reflection, JVM interop, JS/Wasm intrinsics).
Rank it, read the top, and record the deliberate omissions.

ACCURACY, measured rather than assumed: this is a static file diff, so a
name klio provides as a RUNTIME BUILTIN rather than a source declaration
shows up as a false positive. Probing six candidates by hand: `Comparator`,
`AssertionError` and `ArithmeticException` all resolve (builtins, false
positives); `appendLine` resolves (present); `Charsets` and
`String.codePointAt` genuinely do not (true gaps, the `measureTimeMillis`
class). So treat the listing as SUSPECTS and confirm before acting —
`--probe <package>` does that automatically, compiling one generated file
per package and keeping only the names klio actually fails to resolve.

  scripts/stdlib-surface-inventory.py [--package kotlin.text] [--limit N]
                                      [--probe kotlin.text] [--json OUT]
"""
import argparse
import collections
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES_ZIG = os.path.join(ROOT, "src/stdlib/stdlib_sources.zig")
UPSTREAM = os.path.join(ROOT, "kotlin/libraries/stdlib")

# Source sets that are tests, samples, or build scaffolding rather than API.
SKIP_DIR = re.compile(r"(^|/)(test|tests|samples|testUtils|benchmarks?)(/|$)")

PKG_RE = re.compile(r"^\s*package\s+([\w.]+)", re.M)
# Public top-level declarations: `fun`, `val`, `var`, `class`, `object`,
# `interface`, `typealias`. Top-level means column 0 (no leading space) —
# members are indented in every upstream file.
DECL_RE = re.compile(
    r"^(?:@\w+(?:\([^)]*\))?\s*)*"          # annotations
    r"(?:public\s+|internal\s+|private\s+)?"  # visibility
    r"(?:expect\s+|actual\s+)?"
    r"(?:inline\s+|infix\s+|operator\s+|suspend\s+|external\s+|tailrec\s+)*"
    r"(fun|val|var|class|object|interface|typealias)\s+"
    r"(?:<[^>]*>\s*)?"                        # type params on fun
    r"(?:[\w.<>?\[\], ]+\.)?"                 # extension receiver
    r"([A-Za-z_]\w*)",
    re.M,
)
NON_PUBLIC = re.compile(r"^\s*(?:internal|private)\s", re.M)


def zig_list(src, name):
    i = src.index(name)
    j = src.index("};", i)
    return re.findall(r'"([^"]+)"', src[i:j])


def decls_in(path):
    """(package, {names}) for one file; public top-level declarations only."""
    try:
        with open(path, "r", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return None, set()
    m = PKG_RE.search(text)
    pkg = m.group(1) if m else "<none>"
    names = set()
    for line in text.splitlines():
        if not line or line[0].isspace():
            continue                      # not top-level
        if NON_PUBLIC.match(line):
            continue                      # internal/private are not surface
        d = DECL_RE.match(line)
        if d:
            names.add(d.group(2))
    return pkg, names


def collect(paths, base):
    out = collections.defaultdict(set)
    for rel in paths:
        pkg, names = decls_in(os.path.join(base, rel))
        if pkg:
            out[pkg] |= names
    return out


def confirm(args, gaps):
    """Compile one file referencing every suspect in a package and keep only
    the names klio reports unresolved. Turns the listing from suspects into
    confirmed gaps."""
    import subprocess
    import tempfile
    names = gaps.get(args.probe, [])
    if not names:
        print(f"{args.probe}: no suspects")
        return
    # The reference must sit in `main`'s body: a bare `run { X }` in an
    # unreferenced function is not resolved by `check` (measured — it
    # reported nothing for names that genuinely do not exist), while a
    # plain reference inside `main` reports each one.
    lines = [f"import {args.probe}.*", "", "fun main() {"]
    for n in names:
        lines.append(f"    println({n})")
    lines.append("}")
    with tempfile.NamedTemporaryFile("w", suffix=".kt", delete=False,
                                     dir="/tmp") as fh:
        fh.write("\n".join(lines) + "\n")
        probe_path = fh.name
    r = subprocess.run([args.bin, "check", probe_path], cwd=ROOT,
                       capture_output=True, text=True, timeout=600)
    blob = r.stdout + r.stderr
    unresolved = sorted({m for m in re.findall(
        r"unresolved (?:global|reference) `([^`]+)`", blob, re.I)} & set(names))
    print(f"{args.probe}: {len(names)} suspects -> "
          f"{len(unresolved)} CONFIRMED unresolved")
    for n in unresolved:
        print("   ", n)
    os.unlink(probe_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--package", help="restrict to one package")
    ap.add_argument("--limit", type=int, default=20)
    ap.add_argument("--json")
    ap.add_argument("--probe", metavar="PKG",
                    help="confirm a package's suspects by compiling references "
                         "to them and keeping only the unresolved")
    ap.add_argument("--bin", default="zig-out/bin/klio-harness")
    args = ap.parse_args()

    if not os.path.isdir(UPSTREAM):
        print(f"upstream stdlib checkout missing at {UPSTREAM}; "
              f"run scripts/bootstrap.sh", file=sys.stderr)
        return 2

    zig = open(SOURCES_ZIG).read()
    curated = zig_list(zig, "CURATED_UPSTREAM_SOURCES")
    actuals = zig_list(zig, "KLIO_STDLIB_ACTUAL_FILES")
    klio_dir = os.path.join(ROOT, re.search(
        r'KLIO_STDLIB_DIR = "([^"]+)"', zig).group(1)) \
        if re.search(r'KLIO_STDLIB_DIR = "([^"]+)"', zig) else ROOT

    have = collect(curated, UPSTREAM)
    for pkg, names in collect(actuals, klio_dir).items():
        have[pkg] |= names

    upstream_files = []
    for dp, _, ns in os.walk(UPSTREAM):
        rel_dir = os.path.relpath(dp, UPSTREAM)
        if SKIP_DIR.search(rel_dir):
            continue
        for n in ns:
            if n.endswith(".kt"):
                upstream_files.append(
                    os.path.relpath(os.path.join(dp, n), UPSTREAM))
    theirs = collect(upstream_files, UPSTREAM)

    gaps = {}
    for pkg, names in theirs.items():
        missing = names - have.get(pkg, set())
        if missing:
            gaps[pkg] = sorted(missing)

    total_have = sum(len(v) for v in have.values())
    total_them = sum(len(v) for v in theirs.values())
    total_gap = sum(len(v) for v in gaps.values())
    print(f"klio provides {total_have} public top-level names across "
          f"{len(have)} packages")
    print(f"upstream declares {total_them} across {len(theirs)} packages")
    print(f"NOT provided: {total_gap} names in {len(gaps)} packages\n")

    if args.probe:
        confirm(args, gaps)
        return 0

    if args.package:
        names = gaps.get(args.package, [])
        print(f"{args.package}: {len(names)} missing")
        for n in names:
            print("   ", n)
    else:
        print(f"top {args.limit} packages by missing-name count:")
        for pkg, names in sorted(gaps.items(),
                                 key=lambda kv: -len(kv[1]))[: args.limit]:
            sample = ", ".join(names[:6])
            print(f"  {len(names):5d}  {pkg}")
            print(f"         {sample}{' …' if len(names) > 6 else ''}")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(gaps, fh, indent=1, sort_keys=True)
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
