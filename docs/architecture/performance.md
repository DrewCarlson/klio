# Performance: profiles, JIT, and GC

klio bundles its performance controls into one profile, selected with
`--opt <profile>` on any command or the `KLIO_OPT` environment
variable. The profile is resolved once at process start
(`src/runtime/perf.zig`) and gates two independent subsystems: the
JIT tiers and the memory backend.

## Profiles

| Profile | Loop JIT | Function JIT | Memory backend    |
|---------|----------|--------------|-------------------|
| `fast`  | on       | on           | tracing GC        |
| `safe`  | off      | off          | tracing GC        |
| `off`   | off      | off          | never-free arena  |

- `klio run` defaults to `fast`.
- `klio test` defaults to `safe`: test programs are dispatch-heavy
  rather than loop-heavy, so the JIT's per-block tracking costs more
  than it saves there.
- Aliases are accepted: `full`/`on` for `fast`, `balanced` for
  `safe`, `none`/`interp` for `off`.

```sh
klio run --opt safe program.kt
KLIO_OPT=off klio run program.kt
```

Granular environment variables override individual fields on top of
the profile, mainly for diagnosis: `KLIO_JIT` (loop tier),
`KLIO_FUNC_JIT` (function tier; implies the loop tier), and
`KLIO_RECLAIM` (`gc`, `arena`, `smp`, `debug`).

## The JIT

The `jit` module (`src/jit/`) is a tiered native compiler. The
compilation logic lives in `src/ir/jit_loop.zig` and is
architecture-neutral: it programs a fixed-role register machine
against an emitter API, and the backend is selected at comptime per
target:

- **x86-64** (`src/jit/jit.zig`) — System V calling convention.
- **AArch64** (`src/jit/arm64.zig`) — mirrors the x86-64 emitter API
  method-for-method (AAPCS64), so Apple Silicon and other ARM64
  hosts get native code, not a fallback.

Two tiers exist. The **loop tier** compiles hot loop bodies; the
**function tier** compiles whole functions, including native
recursion, and rides on the loop tier. Executable memory is managed
W^X — pages are never writable and executable at once, using
`MAP_JIT` and per-thread write protection on macOS.

The JIT is strictly additive: any IR shape the compiler does not
support falls back to the interpreter with identical semantics. The
parity and stdlib-commontest suites are the gate that the compiled
and interpreted paths agree.

## The garbage collector

The `runtime.gc` module (`src/runtime/gc.zig`) implements KGC: a
precise, stop-the-world, non-moving, tracing mark-sweep collector
over the runtime object heap (`ObjRef`/`ControlBlock` cells).

- Memory is freed by **reachability**, not reference counts, so
  reference cycles are collected and a missing retain or extra
  release is harmless.
- Marking is epoch-based: a cell is marked iff its stamp equals the
  current collection epoch, so no clear pass is needed.
- Roots are supplied by registered providers (VM frames, globals,
  coroutine state, host-binding state); the object graph's out-edges
  are discovered by comptime duck-typed dispatch on each payload
  type.
- The collection trigger threshold is tunable with
  `KLIO_GC_THRESHOLD_KB` (default 8 MB floor);
  `KLIO_GC_HIST` prints a per-collection live-cell histogram.

Under `--opt off` the collector is not installed and the process
uses a never-free arena — useful for short-lived scripts and for
isolating GC effects when debugging.

The full design, including the root-completeness analysis, is in
`plans/GC.md`; the JIT design record is `plans/JIT-DESIGN.md`.

## The stdlib image cache

Independent of the profile, `klio run` bakes the lowered stdlib (and
selected packs) to a content-addressed image under `~/.klio/cache`
on first use and extends it with just the user program on later
runs, cutting startup to a few hundred milliseconds. See the
[CLI tour](../getting-started/cli.md) for the cache keys and
`KLIO_STDLIB_IMAGE` / `KLIO_TRACE_STDLIB_IMAGE` controls.
