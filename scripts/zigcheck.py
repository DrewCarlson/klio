#!/usr/bin/env python3
"""Compile + test a single Zig module in isolation, wiring its dependency
graph via explicit -M module flags. Lets a porting agent verify one crate
without editing build.zig or pulling in still-broken sibling modules.

Usage: scripts/zigcheck.py <module>            # run `zig test`
       scripts/zigcheck.py <module> --build-only # `zig build-obj` (compile, no run)
"""
import os
import subprocess
import sys

# Installed by `zig build` / `zig build zstd-lib` from the vendored zstd C
# sources. Any module whose dep-closure includes `pack` declares the ZSTD_*
# symbols extern (src/pack/zstd.zig); linking this static lib + libc satisfies
# them, matching what build.zig attaches to the pack module.
ZSTD_LIB = "zig-out/lib/libzstd.a"

# module -> direct (non-dev) dependencies. Mirrors build.zig mod_list.
GRAPH = {
    "span": [],
    "diagnostics": ["span"],
    "ast": ["span"],
    "runtime": ["ast", "span"],
    "types": ["ast", "diagnostics", "span"],
    "lexer": ["diagnostics", "span"],
    "pack": ["ast", "span", "types"],
    "parser": ["ast", "diagnostics", "lexer", "span"],
    "ir": ["span", "ast", "types", "runtime", "diagnostics"],
    "stdlib": ["runtime", "pack"],
    "cfa": ["ast", "diagnostics", "lexer", "parser", "span", "types"],
    "resolver": ["span", "ast", "diagnostics", "types", "stdlib"],
    "interp_ir": ["ir", "runtime", "ast", "span", "stdlib", "diagnostics"],
    "stdlib_pack": ["pack", "stdlib"],
    "stdlib_gen": ["pack", "stdlib"],
    "kotlinx_atomicfu": ["runtime", "stdlib"],
    "kotlinx_coroutines": ["runtime", "stdlib"],
    "kotlinx_datetime": ["runtime", "stdlib"],
    "kotlinx_io": ["runtime", "stdlib"],
    "kotlinx_serialization": ["runtime", "stdlib"],
    "ktor_client": ["runtime", "stdlib"],
    "typeck": ["span", "ast", "diagnostics", "resolver", "types", "cfa"],
    "diagnostics_gen": [],
    "cli": ["span", "diagnostics", "lexer", "parser", "resolver", "typeck", "interp_ir", "ast", "pack", "stdlib", "stdlib_pack", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "ktor_client", "runtime", "types"],
    "parity": ["ast", "interp_ir", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "lexer", "pack", "parser", "resolver", "runtime", "span", "stdlib", "stdlib_pack", "typeck"],
    "e2e": ["parity"],
    "itests": ["parity", "typeck", "resolver", "parser", "lexer", "cfa", "runtime", "ast", "span", "diagnostics", "types", "pack", "ir", "interp_ir"],
    "bench": ["ast", "interp_ir", "lexer", "parity", "parser", "resolver", "runtime", "span", "typeck"],
}


def path(mod):
    return f"src/{mod}/{mod}.zig"


def ensure_zstd_lib():
    """Make sure the vendored zstd static library is installed, building it
    via the dedicated `zig build zstd-lib` step if it is missing."""
    if os.path.exists(ZSTD_LIB):
        return True
    print(f"+ zig build zstd-lib  (missing {ZSTD_LIB})", file=sys.stderr)
    rc = subprocess.call(["zig", "build", "zstd-lib"])
    if rc != 0 or not os.path.exists(ZSTD_LIB):
        print(f"error: could not produce {ZSTD_LIB}", file=sys.stderr)
        return False
    return True


def closure(root):
    seen, order = set(), []
    stack = [root]
    while stack:
        m = stack.pop()
        if m in seen:
            continue
        seen.add(m)
        order.append(m)
        for d in GRAPH[m]:
            if d not in seen:
                stack.append(d)
    return order


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in GRAPH:
        print("usage: zigcheck.py <module> [--build-only]", file=sys.stderr)
        print("modules:", ", ".join(sorted(GRAPH)), file=sys.stderr)
        return 2
    root = sys.argv[1]
    build_only = "--build-only" in sys.argv[2:]
    root_override = None
    for i, a in enumerate(sys.argv):
        if a == "--root" and i + 1 < len(sys.argv):
            root_override = sys.argv[i + 1]
    mods = closure(root)

    cmd = ["zig", "build-obj" if build_only else "test"]
    # root module first, named "root"
    for d in GRAPH[root]:
        cmd += ["--dep", d]
    cmd += [f"-Mroot={root_override or path(root)}"]
    # every other reachable module
    for m in mods:
        if m == root:
            continue
        for d in GRAPH[m]:
            cmd += ["--dep", d]
        cmd += [f"-M{m}={path(m)}"]
    if build_only:
        cmd += ["-femit-bin=/dev/null"]

    # Modules reaching `pack` need the vendored zstd library to satisfy the
    # extern ZSTD_* symbols; modules that don't are linked exactly as before.
    if "pack" in mods:
        if not ensure_zstd_lib():
            return 1
        cmd += [ZSTD_LIB, "-lc"]

    print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
