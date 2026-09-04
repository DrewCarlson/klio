#!/usr/bin/env python3
"""Compile + test a single Zig module in isolation, wiring its dependency
graph via explicit -M module flags. Lets a porting agent verify one crate
without editing build.zig or pulling in still-broken sibling modules.

Usage: scripts/zigcheck.py <module>            # run `zig test`
       scripts/zigcheck.py <module> --build-only # `zig build-obj` (compile, no run)

The `itests` module is special-cased: one `zig test` per file under
src/itests/ (mirroring build.zig's per-file test binaries), because a single
process running every integration test accumulates interpreter heap and trips
the runtime's RSS watchdog. `--root <file>` still runs exactly one shard.
"""
import concurrent.futures
import glob
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
    "compose_pass": ["ast", "span"],
    "runtime": ["ast", "span"],
    "types": ["ast", "diagnostics", "span"],
    "lexer": ["diagnostics", "span"],
    "pack": ["ast", "span", "types"],
    "parser": ["ast", "diagnostics", "lexer", "span"],
    "jit": [],
    "ir": ["span", "ast", "types", "runtime", "diagnostics", "jit", "applicability", "compose_pass"],
    "applicability": ["ir", "span"],
    "stdlib": ["runtime", "pack"],
    "cfa": ["ast", "diagnostics", "lexer", "parser", "span", "types"],
    "resolver": ["span", "ast", "diagnostics", "types", "stdlib"],
    "serialization_pass": ["ast", "span", "lexer", "parser", "diagnostics"],
    "interp_ir": ["ir", "runtime", "ast", "span", "stdlib", "diagnostics", "applicability", "compose_pass", "serialization_pass"],
    "stdlib_pack": ["pack", "stdlib", "stdlib_embedded"],
    # build.zig generates the real embedded pack; isolated checks use the
    # no-bytes stub so the cwd source checkout stays the pack source.
    "stdlib_embedded": [],
    "stdlib_gen": ["pack", "stdlib"],
    "kotlinx_atomicfu": ["runtime", "stdlib"],
    "kotlinx_coroutines": ["runtime", "stdlib"],
    "kotlinx_datetime": ["runtime", "stdlib"],
    "kotlinx_io": ["runtime", "stdlib"],
    "kotlinx_serialization": ["runtime", "stdlib"],
    "compose_runtime": ["runtime", "stdlib"],
    "compose_ui": ["runtime", "stdlib"],
    "ktor_client": ["runtime", "stdlib"],
    "typeck": ["span", "ast", "diagnostics", "resolver", "types", "cfa"],
    "diagnostics_gen": [],
    "cli": ["span", "diagnostics", "lexer", "parser", "resolver", "typeck", "ir", "interp_ir", "ast", "pack", "stdlib", "stdlib_pack", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "compose_runtime", "compose_ui", "ktor_client", "runtime", "types", "test_runner"],
    "test_runner": ["ast", "ir", "runtime", "interp_ir", "span"],
    "parity": ["ast", "interp_ir", "kotlinx_atomicfu", "kotlinx_coroutines", "kotlinx_datetime", "kotlinx_io", "kotlinx_serialization", "compose_runtime", "compose_ui", "lexer", "pack", "parser", "resolver", "runtime", "span", "stdlib", "stdlib_pack", "typeck"],
    "e2e": ["parity", "ir"],
    "itests": ["parity", "typeck", "resolver", "parser", "lexer", "cfa", "runtime", "ast", "span", "diagnostics", "types", "pack", "ir", "interp_ir", "stdlib"],
    "bench": ["ast", "interp_ir", "lexer", "parity", "parser", "resolver", "runtime", "span", "typeck"],
}


# Modules whose root source does not follow the src/<mod>/<mod>.zig pattern.
PATH_OVERRIDES = {
    "stdlib_embedded": "src/stdlib_pack/embedded_stub.zig",
    "applicability": "src/ir/applicability.zig",
    "compose_pass": "src/compose_pass/compose_pass.zig",
}


def path(mod):
    return PATH_OVERRIDES.get(mod, f"src/{mod}/{mod}.zig")


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


def build_cmd(root, root_override, build_only, mods):
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
            # The root module is named "root"; a module that depends on it
            # (e.g. applicability -> ir when `ir` is the root) must alias the
            # import name to that module so the cycle resolves.
            cmd += ["--dep", f"{d}=root" if d == root else d]
        cmd += [f"-M{m}={path(m)}"]
    if build_only:
        cmd += ["-femit-bin=/dev/null"]

    # The real build links libc everywhere (std.c.getenv gates, the CLI's
    # c_allocator), so the isolated check must too. Modules reaching `pack`
    # also need the vendored zstd library for the extern ZSTD_* symbols.
    if "pack" in mods:
        cmd += [ZSTD_LIB]
    cmd += ["-lc"]
    return cmd


def itest_shards():
    """Every integration-test file under src/itests/, one shard each,
    mirroring build.zig's itests_files. itests.zig is the monolithic
    aggregate root; running it as one process trips the RSS watchdog."""
    files = sorted(glob.glob("src/itests/*.zig"))
    return [f for f in files if os.path.basename(f) != "itests.zig"]


def run_itest_shards(build_only, mods, jobs):
    shards = itest_shards()
    if not shards:
        print("error: no shards under src/itests/", file=sys.stderr)
        return 1
    print(f"+ itests: {len(shards)} shards, {jobs} at a time", file=sys.stderr)
    failed = []

    def run_one(shard):
        cmd = build_cmd("itests", shard, build_only, mods)
        p = subprocess.run(cmd, capture_output=True, text=True)
        return shard, p.returncode, p.stdout + p.stderr

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        for shard, rc, output in pool.map(run_one, shards):
            if rc == 0:
                print(f"ok   {shard}", file=sys.stderr)
            else:
                failed.append(shard)
                print(f"FAIL {shard} (rc={rc})", file=sys.stderr)
                sys.stderr.write(output)
    print(
        f"itests: {len(shards) - len(failed)}/{len(shards)} shards passed",
        file=sys.stderr,
    )
    return 1 if failed else 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in GRAPH:
        print("usage: zigcheck.py <module> [--build-only] [--root FILE] [--jobs N]", file=sys.stderr)
        print("modules:", ", ".join(sorted(GRAPH)), file=sys.stderr)
        return 2
    root = sys.argv[1]
    build_only = "--build-only" in sys.argv[2:]
    root_override = None
    jobs = min(4, os.cpu_count() or 1)
    for i, a in enumerate(sys.argv):
        if a == "--root" and i + 1 < len(sys.argv):
            root_override = sys.argv[i + 1]
        if a == "--jobs" and i + 1 < len(sys.argv):
            jobs = max(1, int(sys.argv[i + 1]))
    mods = closure(root)

    if "pack" in mods and not ensure_zstd_lib():
        return 1

    if root == "itests" and root_override is None:
        return run_itest_shards(build_only, mods, jobs)

    cmd = build_cmd(root, root_override, build_only, mods)
    print("+", " ".join(cmd), file=sys.stderr)
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
