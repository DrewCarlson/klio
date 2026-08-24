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
- [x] Stage 3: call quickening. (The originally-sketched CALL_TAGGED
      switch table and vararg adapter prologue presupposed call ops the
      frozen stream never grew — calls are escapes — so the landed design
      quickens the `.Call` escape itself; the tagged-dispatch and vararg
      ideas fold into the speedup campaign below.)
      Measured note from stage 2: most hot leaf calls (e.g. `fib`'s
      recursion) are served by `leafExprServe` — a reduced executor that
      bypasses `runFrameExec` and therefore the native table entirely
      (only ~63 of ~22k fib activations went native in the stage-2 gate
      program). Direct C-to-C calls between emitted functions replace that
      seam, which is where the real win is.
      v1 LANDED: a `.Call` escape emits `klio_op_call(ctx, block, idx)`
      instead of `klio_op_escape`. The helper is `execArmCall` with its
      three flat parks masked (a new `comptime allow_flat` parameter; the
      interpreter's sites pass true) — i.e. exactly the maintained
      `KLIO_FLAT=0` recursive semantics for this one site: the native
      caller STAYS on the C stack, the callee runs through
      `callFuncFast`/`callFuncTyped`, and a native callee engages its own
      emitted body inside that call's `runFrameExec` (the recursive call
      seam's leaf short-circuit defers to a registered native body — free
      in non-transpiled processes, where the table is empty). Suspension
      is unchanged: the callee's park surfaces as the Suspended err
      result, `raiseStep` + `afterStep` park the caller at (block, idx+1),
      resume is interpreted via idx_pc. Verified: fib recursion runs
      native-to-native (`[native-call]` per site under KLIO_NATIVE_TRACE);
      coroutine/loop/try parity holds.
      Facts the first measurements established:
      - Under the default `fast` profile the LOOP JIT (enabled in
        `klio_rt_run_file`'s profile) still outruns and absorbs hot scalar
        functions before the native tier matters — the JIT probe sits
        above the native check, deliberately.
      - JIT-off benchmark (tight loop + fib(25)): Debug build native
        33.4s vs interpreter 25.2s; ReleaseFast native 2.78s vs
        interpreter 2.71s — a wash. The call-per-op OPAQUE ABI trades the
        stream's inlined switch dispatch for an exported call per op and
        quickened calls pay full frames where the interpreter leaf-serves,
        so the tier is currently perf-NEUTRAL, not a win. The stage-4 road
        to the actual speedup is a frozen scalar "hot view" sub-ABI
        (static-inline header ops over tag + Int/Long/Bool payload
        offsets, constants comptime-checked against `runtime.Value`) so
        the emitted C inlines the hot ops instead of calling them.
- [x] Stage 4: corpus parity + measured speedup. Parity —
      `scripts/transpiler-corpus-check.sh` (parallel, JOBS=8): 293/293
      examples transpile, compile, and match the interpreter byte-for-byte
      (the same interactive/heavy exclusions as the corpus baseline). What
      it took, in order of discovery:
      - **The module must be pinned by artifact, not re-derived.** A fresh
        in-process bake is NOT id-stable across processes (two bakes of
        identical sources order consts differently), so the first cut —
        native binary re-bakes its own image — produced shifted const ids:
        garbage output when in range, index-out-of-bounds when not.
        `klio transpile` now bakes the program's base to `out.klio-image`,
        assembles the emission module from that artifact exactly as
        `run-image` does, and the emitted `main` calls
        `klio_rt_run_image(image, program)`. Programs the image path
        cannot serve (base-name shadows `canExtendBase` rejects) fall back
        to legacy whole-program emission + `klio_rt_run_file` — the
        runtime declines the image path for them the same way.
      - **Guards for whatever still drifts:** registration carries the
        walked module's table sizes (`klio_rt_register_module_check`, a
        PREFIX bound — execution appends synthesized funcs/consts) on top
        of the per-fid fqn guard; a frame on a delegating anonymous-object
        module (its own tiny const pool) or any drifted module runs
        interpreted, never wrong.
      - **Stack headroom.** Lowering deeply-chained sources recurses past
        a default thread stack: the CLI now runs every command on a
        256MB-reserve thread (`main.zig` `runCli`) and both `klio_rt_run_*`
        entries spawn the same — a transpiled binary's C `main` gets only
        the rlimit stack (the kernel ignores GNU_STACK size), and the
        fault only appeared on cold bakes, which warm caches had hidden.
      - Native recursion depth: recursive call serving reverts to the
        flat park past `NATIVE_RECURSE_MAX_DEPTH` (200), and the native
        entry itself declines past that eval depth, so deep chains bound
        the C stack.
      The measurement (rangebench, ReleaseFast, KLIO_JIT=0 both sides,
      identical output): interpreter 14.44s, native tier 14.55s —
      PERF-NEUTRAL, matching the stage-3 bench. The number is honest:
      the milestone delivers total-coverage AOT C with exact interpreter
      semantics and byte parity, NOT yet a speedup.

## 2026-08-23: the perf-neutral history EXPLAINED, and the first win

The hot view had NEVER engaged. Both layout probes (`tagOffset`,
`spanProbe`) compared UNDEFINED padding bytes of stack-constructed
values — UB the optimizer lowered to a trap, which killed the fill
thread silently: `usable` stayed 0 in every historic run, so every
kv_ fast path compiled into the emitted C was dead and every op ran
through the exported helpers. That is the whole story behind the
"measured perf-NEUTRAL" stage-4 result. Fixed by zeroing each probe
value's backing bytes before construction.

With the view live, the first fused-loop emitter landed: a BC-stream
recognizer for the lowerer's rotated step-progression shape (entry
check, straight-line body, Eq-snap latch, increment back-edge) emits
one typed C loop over int64 locals — per-op width flags frozen by a
two-round fixpoint prologue so the loop body is branch-invariant and
the C compiler unswitches it; traces move to exits (nothing in a
fused region can throw); the edge guard is strip-mined 1/256 with a
spill-first contract. Measured: a 100M-iteration Int/Long accumulate
runs 122ms native vs 180ms interpreted — the FIRST C-beats-interpreter
result — and rangebench drops 830 -> 535ms with only one of its three
loops fused. Parity: 392/393 with compose_foundation solo-verified
byte-identical (its gate failure is the standing under-load flake).

Yardstick CLOSED (2026-08-24): all three rangebench loops fuse. The
downTo/step recognizer had already widened; the char-range loop's
escape was `c.code` — a dynamic GetField per iteration — now lowered
as `c - NUL` (Char minus Char is Int in Kotlin, subtrahend code zero),
a plain BinOp that stays in the region AND kills the runtime
extension-getter dispatch for every static-Char `.code` read
interpreter-wide. Char rides the fused replay as genre g=4:
klio_hot_layout grew char_off/tag_char (ABI 3 -> 4), the prelude
gained kv_char/kv_set_char, entry reads accept tag_char, the tag
propagation knows Char-Char -> Int and Char +/- Int -> Char (width
always 32-bit; the Eq-snap latch fires at the progression's last
element before any increment could wrap, so int64 replay is exact),
and the spill re-boxes g==4 as Char. Measured: rangebench native
777 -> 501ms vs interpreter 5.28s (10.5x), byte parity; corpus 398/1
where the 1 was the compose_foundation "under-load flake" — ROOT
FOUND: the interpreter side re-lowers (printing lowering warnings to
stderr) while the native binary runs its pinned image (no lowering,
no warning), and the check compared merged channels. The check now
compares stdout byte-strict and stderr with `warning:` lines removed;
compose_foundation passes deterministically — 399/0.

## Speedup campaign round 1 (2026-08-24): the call ceiling, measured

Branchy non-fused code (3M calls to a small classifier): native 4.0s vs
interp 6.7s, and the native profile is ~69% INTERPRETIVE LEAF WALK
(leafRead 24% / leafRunInsts 23% / leafWrite 13% / leafWalk 6%) — the
glue leaf-serves every monomorphic callee, so the callee's own emitted
C never runs (kf_ for the callee: 1.3%). fib(30): native 2.96s vs
interp 3.15s — parity, same reason.

MEASURED-NEGATIVE (tried, reverted): preferring the FRAMED native
callee at the glue's direct-call arm (mirroring the evalWith-entry
preference) — fib 2.96 -> 5.95s, branchy 4.0 -> 8.1s. The frame open +
evalWith prologue costs ~2x more than the interpretive leaf walk saves;
this is the same trade the glue's comment records from the original 3x
fib regression. A frame-per-call route can never win at leaf sizes.

THE DESIGN that can: scalar function replay (`kl_` bodies). Generalize
the fused-loop int64+genre value model from loop regions to WHOLE
function bodies:
- Eligibility (static, emitter-side fixpoint): every op in {trace,
  const_int, scalar const_load, move, load_param, scalar bin/cmp, br,
  jump, ret, direct positional exact-arity calls to fns in the SAME
  eligible set (self-recursion included)}. Such bodies are PURE over
  scalars — no heap refs, no retain/release, no observable effects.
- ABI: `int kl_<fid>(void *ctx, klio_edge_view *ev, const int64_t *argv,
  const int *argg, int64_t *ret, int *retg, uint32_t depth)` — args and
  result as (value, genre) pairs, locals as C int64s, branches on the
  Bool genre, calls as DIRECT C calls to the callee's kl_.
- Bail contract: return 0 anywhere (non-scalar entry arg, div-by-zero,
  depth cap, edge-guard fire) — purity makes the caller's re-run of the
  call through the existing interpretive leaf path exact, side-effect
  free, and it raises the right exception in the right frame.
- Edge guard: the fused-loop cadence per call entry; GC needs no
  rooting (scalars only).
- Entry: the native glue's direct-call arm tries kl_ first; the
  interpretive leaf-serve stays as the fallback and the non-eligible
  path.

## Speedup campaign round 2 (2026-08-24): scalar function replay LANDED

The design above, built end to end: the emitter classifies pure-scalar
bodies (fixpoint over call targets), emits `kl_<fid>` C functions over
(int64, genre) locals with direct kl_-to-kl_ calls (self/mutual
recursion included), and the native glue's direct-call arm marshals
scalar args, runs kl_, and re-boxes the result — with the pure-bail
contract (`return 0` anywhere: non-scalar input, div/overflow guards,
depth cap 2000, edge-guard fire, unmodeled genre combos) falling back
to the ordinary path, which re-runs the call exactly because only
statically pure bodies register. Runtime: NativeLeafFn +
klio_rt_register_native_leaf (header typedef klio_leaf_fn).

Two equality rules were bought by corpus failures: plain Eq/NotEq
computes only for same-genre or both-signed-numeric pairs (Kotlin
promotes 1 == 1L; Bool/Char-vs-numeric bails); Boxed(Not)Eq bails on
ANY genre mismatch — tag-sensitive across widths AND the framed path
may adopt an Int literal to Long at parameter bind
(generic_literal_long_widening), undecidable locally.

Measured (KLIO_JIT=0): fib(30) 2.96s -> 0.48s (6.2x, now beats the
interpreter 6.6x); branchy 3M-call classifier 4.0 -> 1.9s (3.5x vs
interpreter); rangebench 501 -> 474ms. Corpus 399/0 byte parity;
klsem edge micro (wrap, mixed width, div guards + div0 exception via
bail, bitwise, shift masking, 3000-deep recursion bail, char, bool)
exact.

## Speedup campaign round 3 (2026-08-24): floats and unary ops

Genres 5 (Double, raw bits in the int64 lane) and 6 (Float, low-32
bits): arithmetic with kl_asd/kl_asf promotion (any Double operand ->
double, Float pairs/int mixes -> float, IEEE exactly — no zero guard,
fmod/fmodf for %), relational compares in floating point (NaN false),
plain Eq as the IEEE operator on same-genre floats (never the bit
compare), Boxed(Not)Eq BAILS on any float genre (equals-semantics
bit canonicalization stays with the interpreter). UnOp joined the
replay (Inc/Dec with width wrap incl Char u16 and float +/-1.0; Neg
with the canonical-NaN pin; Plus identity) — `i++` rode the stream as
an escape and its absence made every counting loop body ineligible
(mandel was 143s, fully interpreted). TRAP for the next op class:
admit it in the eligibility scan AND the max-reg scan AND the emission
dispatch — all three switch on the escape's Inst.

Measured: mandel sweep 143s -> 7.5s (19x, parity); the IEEE gauntlet
(Infinity, NaN, -0.0 == 0.0 true, NaN == NaN false, fmod sign, float
mixing) byte-identical. fib/branchy/klsem/flsem parity, sweep 117/0,
corpus 399/0.

## Next: the speedup campaign (open)

The opaque call-per-op ABI trades the stream's inlined switch dispatch
for an exported function call per op, so it cannot beat the stream —
the emitted C must INLINE the hot ops. The road, measure-first:
- A frozen scalar "hot view" sub-ABI in the generated header:
  static-inline C for const_int/move/load_param and the scalar bin/cmp
  fast paths over exposed tag + Int/Long/Bool payload offsets of
  `runtime.Value`, every offset comptime-checked against the real
  struct at klio_rt build time (the Value layout campaign owns those
  offsets; a mismatch must fail the build, not drift).
- Under the GC profile retain/release are no-ops, so a hot-view register
  write is a plain copy; the escape-op boundary keeps full semantics.
- Direct C-to-C calls with a light frame-open helper (the tagged-table /
  vararg-prologue ideas land here if the measurement wants them).
- The loop JIT remains above the native check; the campaign's yardstick
  is rangebench with the JIT off, and the JIT's own numbers (loops
  10-13x) are the ceiling to respect.
