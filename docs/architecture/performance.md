# Performance: profiles and GC

klio bundles its performance controls into one profile, selected with
`--opt <profile>` on any command or the `KLIO_OPT` environment
variable. The profile is resolved once at process start
(`src/runtime/perf.zig`) and picks the memory backend.

## Profiles

| Profile | Memory backend    |
|---------|-------------------|
| `fast`  | tracing GC        |
| `safe`  | tracing GC        |
| `off`   | never-free arena  |

- `klio run` defaults to `fast`.
- Aliases are accepted: `full`/`on` for `fast`, `balanced` for
  `safe`, `none`/`interp` for `off`.

```sh
klio run --opt off program.kt
KLIO_OPT=off klio run program.kt
```

`KLIO_RECLAIM` (`gc`, `arena`, `smp`, `debug`) overrides the backend on
top of the profile, mainly for diagnosis.

The arm64 function and loop JIT that once compiled the old
interpreter's instructions is kept for reference in `archive/jit/`;
nothing builds it.

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

Raw host scratch is outside the traced object graph. Probe strings, temporary
argument arrays, and discarded dispatch diagnostics therefore have explicit
ownership and must be freed when a fallback consumes or rejects them. The
`KLIO_GC_ALLOC=leaktrack` diagnostic can group outstanding raw allocations by
native stack or by the active intrinsic FQN.

The full design, including the root-completeness analysis, is in
`docs/design/GC.md`.

## The base image cache

Independent of the profile, `klio run` bakes the analyzed and lowered
base (the stdlib and the program's declared packs) to a
content-addressed image, `$KLIO_HOME/.klio/cache/sema-base-<key>.klio-sema`,
on first use, and later runs analyze and lower just the program over
it. The build bakes the stdlib-only image too, with the binary it just
linked, and installs it under `share/klio/cache` beside `bin/klio`; a run
whose own cache misses reads that copy, so a rebuilt klio's first run of
an import-free program is a warm one. A program that pulls packs in keys
its own image and bakes it on its first run. `KLIO_SEMA_IMAGE=0` turns
the cache off; [Cold start](../development/cold-start.md) covers what a
cold run does and how to measure it.
