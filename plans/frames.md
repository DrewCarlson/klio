# Frames

A call is the interpreter's most expensive common operation and compose's
largest cost. On a ReleaseFast build with the JIT off, `mb_ops.kt` makes a
static call in 25.3 ns, a member call in 35.8, a virtual call in 39.6, an
interface call in 36.3 and a lambda call in 33.2, against 8.6 for a turn of
an empty loop (`java -Xint` makes a call in about 19). In a sampled
`hb_canvas` run on the same build the call and return ops are 28% of
klio's own time (24% of the process with Skia's drawing), `opCall` the
busiest symbol in the process, and the try region pushes and pops another
3.5%. The loop tier takes calls out of hot loops; compose's time is calls
that stay calls, which only a cheaper call and a JIT that compiles whole
functions reach.

The cost is not the call's work but the frame's bookkeeping, all of it
paid at run time where the JVM pays none:

- an activation taken from a per-thread pool and linked on a collector
  chain, its frame's fifteen fields written at every entry
  (`Frame.enterPooledWindow`), five return fields and the stream loop's
  context (`Ctx.top`, `try_stack`, `func`, `bs`) written and read back;
- a write mark per register write (`RegMask`), one byte stored beside every
  register store, so the collector can tell a written register of an
  unfilled window from garbage;
- the frame's position stored at every call and slow path
  (`Frame.at`), and its span stored at every block's exit (`leaveSpan`,
  three words) and by compiled code at its exits;
- the try stack pushed at every try region's entry (`block_entry`) and
  popped at its exit (`goto_try`), searched on every throw;
- the parameters copied from the caller's argument run into the callee's
  registers (`load_params`), the eval depth counted, the spin counter and
  the edge flags tested on every call.

The JVM knows each of these from where a frame stands: its oop maps say
which slots hold references at a safe point, its line table maps a
bytecode index to a line, its exception table maps it to a handler, and a
frame is a fixed layout on the thread's stack whose caller is the frame
below it. This plan moves klio to the same model: every frame records its
position where it can be observed, and everything else is read from
tables built when the function's code is.

## What stays

- **Kotlin's semantics.** Stack traces name the same frames and the same
  positions (a test comparing a trace's lines sees no change), a throw
  reaches the same handler, `finally` runs on the same flows (normal exit,
  throw, return, non-local and labeled return), a suspension parks and
  resumes the same frames with the same registers on any thread.
- **The JVM's sharing between threads.** Frames are per thread; nothing
  here touches a barrier, a lock or the collector's stop.
- **Precise collection.** At every stop the collector traces exactly the
  values a frame may still read; a register that holds garbage is never
  traced.
- **One engine.** The interpreter remains the correct engine for every
  program; the baseline JIT and the loop tier run on the same frames and
  leave to the interpreter at any op.
- **Every debug knob.** `KLIO_DUMP_FN`, the trace variables, the frame
  and call censuses, `KLIO_GC_VERIFY`/`STRESS`/`POISON` keep working; the
  reclaim backend keeps its filled frames.

## Design

**A frame is known from its position.** A frame records its position
(block and instruction, from which the pc follows) at every op that can
reach a safe point: a call, a host call, an edge whose guard runs, a slow
path that can run Kotlin code or throw. A collection stops a mutator only
at those points (the eval safe points and the blocking brackets host code
enters), so every frame a collector reads stands where it recorded. From
the position:

- *Registers the collector traces* are the registers live there, by the
  liveness of the function's code as its streams run it (a hoisted
  parameter load runs as its block begins, a constant an op carries is in
  no register), a catch's or a finally's reads counting wherever they are
  written. A register live somewhere without being written on
  every path there (a temporary one branch writes and a later merge reads
  on that branch only) is in the function's *entry fill set* and is
  written `Unit` when the frame opens; for almost every function the set
  is empty. A live register is therefore always a value, and the write
  mask goes.
- *The span a stack trace names* is the last `Trace` before the position
  in its block, else the block's entry span (`spanmap.entrySpans`), known
  wherever every path into the block leaves the same one or the block
  opens with its own statement. Only an edge into a block whose
  predecessors leave two spans and which reads one stores it, so almost no
  block exit stores a span.
- *The handlers a throw reaches* are the block's try context: the try
  stack a simulation of every block's pushes and pops finds at its entry,
  the same on every path for structured code. A function where two paths
  disagree keeps the run-time try stack; every other function pushes and
  pops nothing. The flow a `finally` paused (a return, a rethrow, an
  unwind) stays a per-frame record made only when a finally runs with one.
- *The position a suspension parks at* is already how snapshots and
  resumption work (`FrameSnapshot.block`/`inst_idx`, `suspendLiveRegs`).

**One stack of frames.** A thread's frames live on its value stack, each
a small header followed by its registers:

```
header   caller's frame, the caller's resume position and destination
         register, the function's streams (its function and module), the
         closure (its captures), the parameter view, the paused finally
         flow (null in almost every frame), the frame's own position
regs     n_locals values
```

A call writes its position into its own header, pushes the callee's
header and registers above the caller's window, writes the arguments
into the callee's parameter registers, and jumps; a return writes its
value to the caller's destination register and pops. There is no
activation object, pool, `Ctx.top` chain or collector frame chain: the
collector, a stack capture and a suspension walk the headers. A live park
copies a frame (header, registers, its argument area) into a heap block,
and resuming pushes it back onto whatever thread resumes it. The stack is
one virtual range per thread, reserved once and committed as it grows,
so a push is a compare and an add and never a segment switch; its end is
the depth bound a `StackOverflowError` reports.

**Calls in compiled code.** Compiled code uses the same frames: a
compiled caller pushes a compiled callee's frame itself and branches to
its code, a return branches back, with no handler between; leaving
compiled code at any op leaves a frame the interpreter reads as its own.
The optimizing tier, which today compiles innermost loops, then compiles
whole functions: its code keeps values in machine registers and a call
out writes only the registers the callee's frame and the caller's live
map need.

## Stages

| Id | Stage | State |
|----|-------|-------|
| `frames/maps` | Per function a frame map (`src/ir/core/framemap.zig`) built from its code as its streams run it: the entry block's hoisted parameter loads run as the block begins, a constant an op carries writes and reads no register (`Effect`, recorded when the streams are built). Liveness at every position, a position being an instruction or a block's start (`block_start`); a catch's or a finally's reads live wherever they are written, its exception register live from the throw that writes it; the must-written sets and the entry fill set. Positions recorded at every safe point: a call's guard polls in the callee once its parameters are loaded (the arguments a `new` or a lambda passes are then rooted by the callee's frame), an edge's guard at the target block's start, the frame loop's block entry at the block's start or where a resume goes on. `KLIO_FRAME_AUDIT=2` with `KLIO_GC_STRESS_EVERY=32` passes the example corpus (621) and the stdlib commontests (149) with no finding, interpreted and with the JIT and the tier forced. | done |
| `frames/nomask` | The collector traces a frame's registers live where it stands (`Frame.liveSet`), every register of a frame filled whole (a function no map covers, the reclaim backend); an opening frame writes `Unit` to its function's fill set only, computed when its streams are built (`framemap.fillSet`), in place of `defBeforeUse`'s fill-or-nothing. The write mask is gone from the frame, the interpreter's register writes, the baseline's compiled code and the loop tier's exits; a dense suspension snapshot sets the registers not live where the frame stands to `Unit` first, and a sparse one keeps the registers the frame map calls live after the suspension point (which the IR's order got wrong for a parameter load the entry block hoists). Every `mb_ops` row 3 to 7% faster interpreted on ReleaseFast (a static call 25.95 to 24.64 ns, a five-argument call 37.5 to 34.8, a member call 36.2 to 34.1, the loop 8.73 to 8.16), `hb_canvas` 2.3% less CPU. | done |
| `frames/spans` | A frame's span is the last `Trace` before its position, else its block's entry span from a table built with the function's streams (`src/ir/core/spanmap.zig`): the span every path into the block leaves, the block's first statement when it opens with one, or `cur_span` for a block whose paths leave two and which reads one before its first statement. An edge op's span words are what it leaves in the frame for such a target, nothing for every other edge; the block's `end` op carries its last statement, which the frame loop leaves before running a terminator, and a throw or unwind leaves the span where the frame stands before routing to a handler. The baseline and the loop tier store the same words and nothing at their exits; a suspension snapshot keeps `cur_span`. A shadow of the old protocol reported no difference over the corpus (621) and the commontests (149) interpreted. The lowering now gives a loop's header blocks the loop's `Trace` (a `for`'s `hasNext()`/`next()`, a `while`'s condition, a counted loop's step, a `do`-`while`'s condition its own), as kotlinc's line table does (`loop_trace_lines.kt`). Interpreted `mb_ops`: the loop 8.17 to 7.66 ns, field reads and writes 4 to 5% faster, calls within noise. | done |
| `frames/trys` | Per function, the try frames in effect in each block (`src/ir/core/trymap.zig`), found by running the frame loop's pushes and pops (a region's entry, a catch-only join, a finally's disarm and its Goto's pop, an inline return's pops) over every edge and every route to a handler; null when two paths into a block leave different frames, and such a function keeps its try stack as before. A function with known frames has no `block_entry`, its Gotos pop nothing (a finally's and its done block's still check for a pending flow), a return with a finally to run goes to the frame loop, and the frame loop rebuilds the try stack from the block's frames only where a route reads it. A shadow of the kept stack agreed with the known frames wherever a frame stood in a region (184 corpus programs, 18 sweep batches, interpreted and JIT-forced); 12,659 of the 12,660 try functions the examples build have known frames (one in the ktor pack keeps its stack). A try/catch call 38.0 to 30.7 ns, a return through a finally 119 to 115, `hb_canvas` 2.15 to 2.08 s of CPU. | done |
| `frames/record` | A call writes what a pooled activation lacks and no more: the stream loop's context keeps no function or try stack of its own (both follow from its frame), a pooled frame keeps its thread and its unowned parameters, the span is cleared only where the entry block reads it and the try stack only for a function that keeps one (every function without a try region has known, empty try frames), what opening a frame needs of its function is one byte (`FuncStreams.Open`), the parameter loads read the call's own values rather than the frame just written, and the return point's four words are written as two. Interpreted `mb_ops`: a static call 24.2 to 23.6 ns, five arguments 33.6 to 32.3, member 33.6 to 33.0, virtual 37.5 to 36.7, interface 34.5 to 33.8, lambda 31.7 to 30.9. | done |
| `frames/stack` | Frames on the value stack with headers in place of pooled activations. Measured against `frames/record`, not taken: a header on the value stack lands on memory another frame's window last held, so a call would write every field of it, where a pooled activation keeps the fields a return leaves clean and costs four memory operations a call to pop and push. The collector's chain, stack captures and parks stay on activations. | dropped |
| `frames/calls` | The call's own work after `frames/record`, which a sampled static-call loop and `hb_canvas` showed spread over the frame-init store run, the parameter copy, process-wide flag loads and the call op's saved registers. No op calls a function on its fast path now (a function's JIT counter leaves for a cold handler that compiles, `compileEdge`/`compileEntry`), and a call and a return read this thread's copies of the switches that choose their paths (`EvalTls.hooks`/`plain`, `refreshCallMode`) in place of process-wide flags. Interpreted `mb_ops` from `frames/record`: a static call 23.6 to 22.5 ns, virtual 36.7 to 36.2, interface 33.8 to 33.3, the loop 7.6 to 7.3, field reads and writes 5% faster; `hb_canvas` 2.00 to 1.96 s of CPU from the counter alone. Left: `opCall` saves two register pairs for register pressure; a parameter map is the identity only where lowering loads parameters first. | done |
| `frames/jit` | Compiled-to-compiled calls: a compiled caller opens a compiled callee's pooled activation itself and branches to its code, a return branches back, with no handler between. `hb_canvas` compiles 29 functions at the default threshold, so this pays in hot loops, not yet in compose. Done: a static call compiled code does not run in place, to a compiled callee, and a virtual call whose site keeps one class (behind a check of the receiver's class), open the callee's frame from the thread's pool as `openFast` does, with the callee, its window, its parameter map, its fill set and the return point constants, and enter the callee's code (`Gen.directCall`, `Masm.enterCode`); what `openFast` or the call's guards would not take, a receiver of another class, or a callee not compiled yet, leaves for the handler, or for a site that may still take another callee for its count toward compiling again (`KLIO_JIT_DIRECT=0` for the handler alone). `fib(30)` 44 to 32 ms on AArch64 and 81 to 43 under Rosetta, the same through a virtual method 59 to 36. A return compiled in place, measured and not kept: `fib(30)` 32 to 31 ms, `hb_recompose` 1 to 2% slower, its 60 instructions at each return site adding to the instruction-delivery stalls that are 43% of that program's cycles with direct calls and 33% without (`plans/jit.md`). Then the call made small: a site gives the frame its pins and goes with its record (`bc.DirectSite`) to shared code (`directCall`), which opens the frame as `openFast` does and enters the callee's code; a function's calls of itself go to its direct entry, the inline sequence compiled once with the function (`FuncStreams.direct_entry`). Against the sequence at every site, frame ms: `hb_recompose` 44.7 to 43.2, `hb_canvas` 5.07 to 5.00, `hb_list` 1.60 to 1.58; `fib(30)` 32 to 35 ms, the same through a virtual method 36 to 38. An entry for every callee measured no better than a sequence at every site. Then the call reads nothing of either function's streams: L1D-miss sampling on `hb_recompose` put 29% of the program's load misses in `directCall`, on the callee's `FuncStreams`, `Func`, parameter map and entry table and the caller's entry table. The site's record carries the callee's shape (function, code, window, entry pc and block, parameter pairs, compiled entry), filled at compile time or by the first call that finds the callee compiled, and the caller's way back, which the activation keeps for its return (`Activation.ret_code`); records are a cache line aligned, what a call reads in their first two lines. `fib(30)` through the shared code 42 to 34 ms, `hb_recompose` 43.8 to 42.9, `hb_canvas` 5.00 to 4.92. Left: the activation a call fills is about 290 bytes over five lines; sites of two classes, lambda calls. | in progress |
| `frames/methods` | The optimizing tier compiles whole functions: values in machine registers, calls out writing only what the callee and the caller's live map need, exits to the baseline at any op. | open |

Every stage runs the three gates (regular, JIT-forced with the tier off,
tier-forced) on AArch64, the x86-64 unit tests and sweeps under Rosetta,
and reports the measures below against the stage before.

## Measures

- `bench/interp/programs/mb_ops.kt` on a ReleaseFast build, the JIT off and
  on: static, five-argument, member, virtual, interface and lambda calls,
  a virtual getter, and the loop row as the control.
- The compose workloads' CPU time (`bench/compose/programs`), JIT off and
  default.
- The share of the call and try ops in a sampled `hb_canvas` run on a
  ReleaseFast build (28% and 3.5% of klio's own time at the plan).

Baseline (ReleaseFast, JIT off / default): static call 25.3 / 0.8 ns,
five-argument call 37.1 / 0.85, member call 35.8 / 2.5, virtual call
39.6 / 3.1, virtual getter 32.8 / 2.6, interface call 36.3 / 2.9, lambda
call 33.2 / 1.2, loop 8.6 / 0.8. The default column is the loop tier
taking the call's loop whole; the interpreted column is what compose's
calls pay.

## Log

- 2026-09-30: plan, from a sampled `hb_canvas` run and `mb_ops` on a
  ReleaseFast build. A ReleaseSafe build pays another 5% there for a
  thread-local read on every edge and call (`assertNoCellLock` under
  runtime safety); the ReleaseFast release does not.
- 2026-09-30: `frames/maps`. The audit found four places the IR's order is
  not the code's, each a register the maps would have left untraced while
  the frame still needed it: the entry block's parameter loads the streams
  hoist into `load_params` (a later load's register read as dead at a `new`
  before it); a constant a `bin_k` carries (its register never written, so
  live-by-the-IR garbage); a catch's exception register, written by the
  throw before the handler's block-entry safe point; and the instance a
  `new` holds in its destination while the call guard stops the world
  before the constructor's frame exists. The first three are now effects
  the streams record and the maps read; the fourth moved the call's guard
  into the callee, after its parameters load, where its frame roots the
  argument area. Where the guard polls changes nothing a program sees.
- 2026-09-30: `frames/nomask`. The collector traces the registers live
  where a frame stands; the write mask is gone.
- 2026-09-30: `frames/spans`. Spans come from the frame's position and a
  per-function table. Checking against kotlinc showed klio naming the body's
  last statement for a frame in a loop's header (a `for`'s `next()`, a
  `while`'s condition); the loops now carry their own `Trace` there, which
  also leaves most loop headers with a known span.
- 2026-10-01: `frames/jit`, direct calls. The direct call writes the
  frame's words where Zig does not fix their layout (a slice, an optional
  value stack mark, an optional closure, which is no pointer niche but a
  reference and a flag byte), so the JIT checks that layout once as it
  starts (`directLayoutHolds`) and leaves every call to its handler where it
  does not hold. The frame audit under `KLIO_GC_STRESS_EVERY=32` with the
  JIT forced finds nothing over the corpus or the commontests.
- 2026-10-01: `frames/jit`, calls by their record. The instruction-delivery
  stalls were the first half of the call's cost; the second is data. The
  M1's L1D-miss sampling (the CPU Counters template with its counting mode
  set to `l1d_miss_sampling`, samples attributed by PC through the binary's
  slide and `KLIO_JIT_MAP`) put 29% of `hb_recompose`'s load misses in
  `directCall` and 4% each in `opCall` and `opVcall`, against 5% in
  compiled field reads: a call read the callee's streams and function
  across five or six lines, cold for a program with thousands of callees.
  The record now holds what a call reads and the activation the way back;
  the misses that remain are the record's own lines and the activation's.
- 2026-10-01: `frames/jit`, the call made small. CPU counters put 43% of
  `hb_recompose`'s cycles in instruction delivery with direct calls as
  emitted (130 instructions at each of about 1,000 sites) and 33% with
  every call through its handler; that program ran 3% faster through the
  handler and `hb_canvas` 3.5% slower. Three placements of the same work,
  frame ms against the sequence at every site, six alternating rounds: in
  shared Zig code reading a record, `hb_recompose` 44.7 to 43.1 and
  `hb_canvas` 5.07 to 4.94; in an entry compiled with each callee, no
  better than the sequence (the entries add up over the callees as the
  sites did); in shared code with an entry only for a function's calls of
  itself, 43.2 and 5.00, and `fib(30)` 35 ms where shared code alone
  takes 42. The last is kept.
- 2026-10-01: `frames/calls`, the switches. In `hb_canvas` the loads of
  the process-wide call-hook and collector flags drew 12% of `opCall`'s
  samples and 14% of `opRet`'s; this thread's copies read instead moved
  the virtual and interface rows 2 to 3% and `hb_canvas` not at all: the
  samples were the stalls of the stores before them. `fib(30)`: klio 57 ms
  interpreted and 41 ms with the JIT, the JVM 50 ms with `-Xint` and 2 ms
  with its JIT; compiled code calls through the interpreter's call and
  return (`frames/jit`).
- 2026-09-30: `frames/calls`, first part. A function's JIT counter
  compiled it with a plain call from the op that counted (a loop's back
  edge, a call's entry), so every op holding that inlined path saved its
  callee-saved registers on every run: `opCmpBr`, a loop's test, saved
  five pairs. The count now leaves for a cold handler that compiles and
  goes on (`compileEdge`, `compileEntry`), and the branch ops keep only
  their frame record. Interpreted `mb_ops`: the loop 7.54 to 7.19 ns,
  field reads and writes 5% faster, a static call 22.96 to 22.39, member
  32.9 to 31.9; `hb_canvas` 2.00 to 1.96 s of CPU. `opCall` and `opVcall`
  still save two pairs for register pressure alone.
- 2026-09-30: `frames/stack` dropped, from the `frames/record` profile. In
  `hb_canvas` the call and return ops are 23% of the process (half of
  klio's own time), with no instruction of `opCall` above 10% of its
  samples. The same profile found sema reading `KLIO_SEMA_TRACE` and
  `KLIO_CHECK_PACKS` from the environment for every call it resolved and
  every pack reference it checked (1.6% of the run); read once now,
  `hb_canvas` 2.06 to 2.02 s of CPU.
- 2026-09-30: `frames/record`. `opNew` saves six register pairs and 0x380
  bytes of stack on every `new`, the leaf path included, because the
  constructor call it inlines needs them: its leaf path wants an op of its
  own (plans/interpreter-speed.md).
- 2026-09-30: `frames/trys`. A return through a finally still goes
  through the frame loop and the pending-flow record (119 ns a call);
  known frames make its routing static too, for a later stage.
