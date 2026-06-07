#!/usr/bin/env python3
"""Compile + test a single Zig module in isolation, wiring its dependency
graph via explicit -M module flags. Lets a porting agent verify one crate
without editing build.zig or pulling in still-broken sibling modules.

Usage: scripts/zigcheck.py <module>            # run `zig test`
       scripts/zigcheck.py <module> --build-only # `zig build-obj` (compile, no run)
"""
import subprocess
import sys

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
    "bench": ["ast", "interp_ir", "lexer", "parity", "parser", "resolver", "runtime", "span", "typeck"],
}


def path(mod):
    return f"src/{mod}/{mod}.zig"


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
    mods = closure(root)

    cmd = ["zig", "build-obj" if build_only else "test"]
    # root module first, named "root"
    for d in GRAPH[root]:
        cmd += ["--dep", d]
    cmd += [f"-Mroot={path(root)}"]
    # every other reachable module
    for m in mods:
        if m == root:
            continue
        for d in GRAPH[m]:
            cmd += ["--dep", d]
        cmd += [f"-M{m}={path(m)}"]
    if build_only:
        cmd += ["-femit-bin=/dev/null"]

    print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
