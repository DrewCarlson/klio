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
- [ ] Stage 2: block emitter, hello.kt parity
- [ ] Stage 3: call quickening, CALL_TAGGED table, vararg prologue
- [ ] Stage 4: corpus parity + measured speedup
