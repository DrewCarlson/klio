# C transpiler

The milestone the bytecode tier was built toward: ahead-of-time C emission
consuming the FROZEN v1 op stream (`plans/bytecode-vm-plan.md`, "FROZEN v1
spec"), so hot Kotlin compiles to dispatch-free native code while every
construct the emitter does not cover keeps exact interpreter semantics.

## Architecture (decided)

**AOT quickening with the same escape hatch, one level up.** The bytecode
tier replaced per-instruction union dispatch with a dense u32 stream plus
`ESCAPE idx` back into `execInst`. The transpiler replaces the STREAM
INTERPRETER with straight-line C, per block:

- Each lowered function body becomes a C function over the shared frame
  ABI (registers = the existing frame slots; receiver slot 0, packed
  varargs — the layout the stream already froze).
- Dedicated ops (CONST, MOVE, LOAD_PARAM, BIN, NOT, CELL_GET, CELL_SET —
  plus every op quickened later) emit as direct C statements calling the
  SAME leaf helpers the interpreter's arms call, exported behind a C ABI
  (`klio_rt.h`).
- Everything else emits as `klio_escape(frame, idx)` — a call back into
  the embedded interpreter's `execInst` on the ORIGINAL instruction,
  preserving every Step outcome. Suspension/resume enters through the
  existing `idx -> pc` side table; a transpiled function that parks
  resumes exactly like an interpreted one because the coordinates are the
  same.
- CALL_TAGGED's link-time table and the vararg adapter activation (both
  spec'd in the bytecode plan as "transpiler-only") land HERE: the C
  emitter emits the tagged-dispatch table as a switch, and the explicit
  frame layout makes the vararg adapter a static C prologue.

Why this shape: coverage is total from day one (escape = the
interpreter), semantics cannot drift (shared leaf helpers + shared
unwind), and the win lands exactly where the tier's profile said the
time is (dispatch + arm overhead on the hot simple ops). The interpreter
ships as a static library either way, so the deliverable is
`klio build-native file.kt` → `file.c` + `libklio_rt.a` → `cc` → a
standalone binary.

## Stages

1. **Runtime C ABI (`klio_rt.h`)**: export the frame ABI + the leaf
   helpers the dedicated ops call (the BinOp kind helpers, cell get/set,
   const-pool access) + `klio_escape` + program bootstrap (module load,
   image init, main invocation). Prove it with a hand-written C file that
   drives a trivial program end-to-end against the library.
2. **The emitter**: walk a function's blocks, emit C from the u32 stream
   (dedicated ops → statements, ESCAPE → `klio_escape`), block
   transitions as `goto`, the `idx -> pc` map as labels. Gate:
   `examples/hello.kt` transpiled == interpreted output.
3. **Call quickening in C**: static calls (`CALL fid`) as direct C calls
   between emitted functions; CALL_TAGGED's table as a switch; the vararg
   adapter prologue. Gate: the census suite's static-dispatch corpus
   transpiled with parity.
4. **Corpus parity + perf**: the full examples corpus transpiled, output
   parity against the interpreter; the compute bench (rangebench) measured
   native-vs-interpreted — the number that justifies the milestone.

## Status

- [x] Stage 1: runtime C ABI + bootstrap proof — `zig build klio-rt`
      installs `lib/libklio_rt.a` + `include/klio_rt.h`
      (`klio_rt_run_file` / `klio_rt_abi_version`); the hand-written C host
      `tests/transpiler/boot.c` runs `examples/hello.kt` end to end
      (`scripts/transpiler-boot-check.sh`, link with `zig cc` + `-lzstd` —
      the Debug zstd objects carry UBSan references a system cc lacks)
- [x] Stage 2: block emitter, hello.kt parity — `klio transpile <file>
      [-o out.c]` emits every user-script function's bytecode stream as C
      over the `klio_op_*` helpers plus a registration hook and a `main`;
      `zig cc out.c -Izig-out/include -Lzig-out/lib -lklio_rt -lzstd`
      yields a binary with output parity (gate:
      `scripts/transpiler-emit-check.sh`, covering straight-line code,
      fused loops/branches, recursion, try/catch, stdlib escapes;
      coroutine programs verified by hand — a suspend body runs native to
      its park and resumes interpreted at the shared (block, idx)
      coordinates). How it landed:
      - The emitted shape: one `static void kf_<fid>(void *ctx, uint32_t
        entry)` per function; a `switch (entry)` goto-dispatch over the
        compiled blocks (an uncompiled entry returns with outcome `none`,
        handing the block back to the interpreter); per-op calls exactly
        mirroring the stream loop's arms, fused edges as `goto`.
      - The runtime half lives in `ir/eval.zig`: `NativeCtx` carries one
        activation's frame-loop locals plus host-typed glue fn pointers
        (`NativeGlue(H)`) so `execInst`/`execArmBinOp` + `afterStep` run
        with the exact routing the stream uses; `nativeOp*` are the arm
        bodies; klio_rt exports them as `klio_op_*`. The frame loop checks
        a per-fid table once per activation and maps the native outcome
        onto its own exits (`bc_term`/`bc_goto`/unwind-break/return).
      - fids are only meaningful against the module shape the runtime
        rebuilds, so `klio transpile` assembles the module EXACTLY as
        `runFileIrVm` does (the baked-image path first, legacy lowering as
        the fallback) — the first cut emitted from the legacy path and
        every fid missed the image-path runtime by ~1600. Registration is
        fqn-guarded (`klio_rt_register_native(fid, fn, fqn)`): a mismatch
        falls back to interpretation, never the wrong body.
      - `KLIO_NATIVE_TRACE=1` prints `[native] fn=... entry=bN outcome=...`
        per native activation and `[native-miss] fn=... fid=N` for
        user-package functions with no (or a guarded) table entry.
- [ ] Stage 3: call quickening, CALL_TAGGED table, vararg prologue.
      Measured note from stage 2: most hot leaf calls (e.g. `fib`'s
      recursion) are served by `leafExprServe` — a reduced executor that
      bypasses `runFrameExec` and therefore the native table entirely
      (only ~63 of ~22k fib activations went native in the stage-2 gate
      program). Direct C-to-C calls between emitted functions replace that
      seam, which is where the real win is.
      Design pinned (v1): a `.Call` escape emits `klio_op_call(ctx, block,
      idx)` instead of `klio_op_escape`. The helper is `execArmCall` with
      its three flat parks masked (a new `comptime allow_flat` parameter;
      the interpreter's sites pass true) — i.e. exactly the maintained
      `KLIO_FLAT=0` recursive semantics for this one site: the native
      caller STAYS on the C stack, the callee runs through
      `callFuncFast`/`callFuncTyped`, and a native callee engages its own
      emitted body inside that call's `runFrameExec`. Suspension is
      unchanged: the callee's park surfaces as the Suspended err result,
      `raiseStep` + `afterStep` park the caller at (block, idx+1), resume
      is interpreted via idx_pc. What this v1 does NOT yet do: a
      light-frame C-to-C ABI that skips `openActivation` entirely
      (measure first — leafExprServe already serves the pure-leaf tier).
- [ ] Stage 4: corpus parity + measured speedup
