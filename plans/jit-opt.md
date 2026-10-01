# JIT: optimized loops

The baseline tier (`plans/jit.md`) compiles every op as a template over the
frame: each op loads its operands from the frame's registers, checks what
it cannot prove, and stores its result back. A loop keeps at most five
integer registers in machine registers (the handlers' calling convention
leaves no more free), and a callee compiled in place keeps its registers in
the thread's inline registers. The member call loop of `mb_ops.kt` is about
85 instructions an iteration where the JVM with its JIT runs about ten.

This tier compiles a hot loop of a compiled function a second time, as one
piece of code over typed values in machine registers, and leaves to the
baseline code wherever it cannot go on. It is the first part of `jit/opt`:
the same machinery then grows past loops.

## Where the code runs

A loop is optimized once it is hot on its own: a per-loop count of back
edges, taken after the baseline compiled its function and after the call
sites in the loop have run (a site whose cache was empty when the baseline
compiled would leave the optimized code every iteration). The baseline's
analyses (kinds, the callees it compiles in place, natural loops) are
computed again for it. Its code is a block of its own; the baseline's code
for the loop stays, whole: it is where the optimized code leaves to.

The loop's head in the baseline code has two labels: the one the loop's
edges reach, which jumps to the optimized entry once there is one (a
patched branch), and the head op's own code, where a failed entry and an
exit to the head go. The entry takes the loop's live registers from the
frame and from the machine registers the baseline pins there, checks the
kinds the optimized code relies on, and leaves to the head's own code when
one differs. Exits and failed entries are counted; past a limit the patched
branch goes back to the baseline head, and the loop may be optimized again
later from what its sites then hold.

The optimized code has a stack frame of its own, with a frame record (x29
and the return address, as a sampler, the late-stop dump and the system's
tools walk them) and the callee-saved registers it uses (x19 to x28, d8 to
d15) saved in it. It keeps the registers compiled code relies on (x0 to x3:
the context, the frame, its registers, the code) as they were, and leaves
x16 to x18 alone. On x86-64 the code pushes the code register (rcx), the
context and the frame (rdi, rsi, which values take: the code keeps their
pointers in its own stack) and the registers a call keeps, then aligns the
stack for its locals: the eval record, the context, the frame and the
values' stack slots. It calls nothing that reaches a safe point, and never
class initialization (that waits in a blocking bracket): host code it calls
(a map's lookup, a list's append) runs as it does from the baseline, with
the frame's registers it reads written first, and holds no list buffer or
length across such a call.

## What it leaves to

Every way out of the optimized code goes to the baseline code at an op of
the root function, through its label in the same code block (not the
function's entry table, which a recompile repoints): the entry at that op,
the stub that checks kinds and loads pins, or for an op left to its handler
the path past the pins' write-back. It leaves:

- the loop's exits, to the op each goes to;
- a check that fails (a tag, a class, a bound, a zero divisor, a hole with
  no room, a class not yet initialized), to the op the check belongs to,
  before anything of that op is done;
- the back edge's guard (the edge flags, and the spin counter the optimized
  code keeps in a register and writes back when it leaves), to the op that
  ends the iteration, which the baseline runs again with its guard.

What an exit writes, before it jumps:

- every root register live at the target op, including those a catch or a
  finally of an enclosing try reads (`ir.regs.Live` with its handled
  registers), payload and tag;
- every root register the kinds show written at the target but not at the
  loop's head, which the baseline's code after it takes as marked
  (`Kinds.written`): a value, or `Unit` where its value is dead, and its
  write mark; a pooled frame's unmarked slots hold an earlier call's values;
- the frame's span where the target block's entry span differs by path
  and the block reads it (`cur_span`, `spanmap.EntrySpan.dyn`), which
  stack traces read;
- the thread's hole cursor, where the optimized code bumps it in a register;
- the spin counter.

A check inside a callee compiled in place, before the callee has done
anything another can see, leaves to the call op itself, which the baseline
runs again whole. After an effect it leaves as the baseline's code for the
callee's op does (`inlineExit`): the callee's frame is made from its
registers, which the exit writes to the thread's inline registers first.
Effects: a store into anything but an instance made in this iteration
(field, array, list, map, builder, static, cell), a host call that changes
a value, taking an identity (the counter is shared). The checks of the
throw-free kind (the eval depth, a class's initialization, a hole's room,
a class test, an intrinsic declining) are placed before the call's effects
where they can be.

So the frame, with the inline registers for callees after an effect, is the
canonical state at every exit, as for the baseline.

## The representation

A loop body becomes an SSA graph in blocks: the root's blocks of the loop
and, at each call the baseline compiles in place, the callee's blocks,
spliced with the arguments bound to the callee's parameters. Values have
machine types: `i32`, `i64`, `f64`, `bool`, `ref` (an instance, a list,
an array: a pointer whose tag is known), and `value` (a 16-byte value of a
tag not known). A register read of a kind the kinds prove is typed; a read
of an unknown kind is a `value`, which a check turns into a typed one.

Checks are nodes that name their exit: `check_tag`, `check_slots`,
`check_plain`, `check_class`, `check_bound`, `check_nonzero`,
`check_depth`, `check_room`. Each exit records the root op it leaves to
and, for that op, which SSA value holds each root register it writes.

## Passes

- A check that another check of the same value dominates goes; a check the
  kinds prove never appears. A check moves to the entry only when it runs
  on every iteration and its value does not change in the loop (the eval
  depth, a class's initialization).
- Common reads within an iteration: a read of a plain field of the same
  instance and slot, with no store to that slot, no call, no read with
  acquire order (an ordered slot, a static) and no intrinsic call between,
  is the first read's value; a store's value is what a read after it of the
  same slot answers. A class with an ordered protocol keeps every access,
  and a store keeps its store-store fence and its order among stores.
- Values that do not change in the loop move to the entry: built objects,
  constants, closure captures, a `val` static; never a `var` static (every
  static is read with acquire order), never a field.
- Dead values go, a `new` whose instance nothing reads among them, and the
  size of an array made in the loop is its length.

## Registers

Linear scan over the loop's values in the blocks' order, with loop-carried
values (the phis at the head) live around the whole loop. On AArch64 integer
and reference values take x19 to x26 and the scratch registers compiled code
does not reserve (14), Doubles v18 to v31; on x86-64 integer and reference
values take rbx, rbp, r12 to r15, rdi and rsi (8), Doubles xmm2 to xmm13.
Where the scan runs out, one of the values held there goes to memory, the
cheapest first (a load per read, a store per making): an entry value is
read from the frame, which holds it unchanged while the loop runs, and
another takes a 16-byte slot of the code's stack, with a register only
where it is made. A parameter in a slot is written there by its edges'
parallel copy, a cycle between two slots broken through a scratch
register. At an exit each value is written to the frame from where it
lives.

## Arithmetic

Int and Long wrap; nothing folds on an assumption of no overflow. `Int.MIN
/ -1` and a Double's conversion to an Int answer as Kotlin's (x86-64 traps
on the first and saturates differently on the second). A compare of Doubles
keeps NaN's answer when a branch is inverted, and IEEE `==` stays apart
from boxed equality.

## Stages

| Id | Stage | State |
|----|-------|-------|
| `opt/graph` | The SSA graph from a loop's root ops and its callees in place, with exits; a printer (`KLIO_JIT_OPT_DUMP`). Done for root ops (`opt/build.zig`, `opt/graph.zig`): each register a variable, the frame's span one too, exits writing what the op they leave to reads (the IR's liveness, what a catch reads) and what the kinds show written there but not at the head; callees in place, each a level of variables past the root's, their constants their own, an exit in a callee leaving to the root's call op while nothing the callee did is seen, and refused past an effect. | done |
| `opt/passes` | Check dominance, common reads, invariant values, dead values. Done: an unbox of a word of its tag goes, constants move to the entry; a new value nothing else reaches (no store, parameter, call or exit takes it) answers a read of its field with what its making stored there and a new array's length with its size, and is not made when nothing is left that reads it; a check a dominating check answered goes (a tag check or unbox of a value checked for the tag, a slot count no more than one checked, plainness checked or proved by the class, a class proved by a check or the taken edge of a test of it). | in progress |
| `opt/regs` | Linear scan, spills, exits' write-backs. General and floating registers, a constant other than a Double's made again where it is read, a parameter's back-edge input given its register; where registers run out, the value held there cheapest in memory goes to memory: an entry value read from the frame at each use, another to a stack slot of the code's own, made in a register and stored there, read from it at each use (at most 128 slots). A value a node's exit writes to the frame keeps its registers apart from the node's own. A parameter whose inputs but the loop's entry values are words of one tag takes those entry values as words of it, checked at the entry. | done |
| `opt/emit` | AArch64 code for the graph, its frame, entry and exits, the patched head; exit counts; `KLIO_JIT_OPT=0` turns the tier off; the code in `KLIO_JIT_MAP` and the dumps. Done: the frame record and saved registers, the entry's kind checks, the exits, the spin counter and edge flags in registers, a compare fused with its branch. The loop's edges from outside and its head's entry go to the code; its own back edges stay in the baseline code once it has left. Exit counts (`KLIO_JIT_OPT_EXITS`) and a check before any code runs that every value read has its registers. Left: the map and dumps. | in progress |
| `opt/ops` | Int, Long and Double arithmetic and compares, field reads and stores, calls in place (static, virtual by class, lambdas), `new` from a template, array and list reads, the called intrinsics. Done: the arithmetic, compares, conversions, increments, field reads and stores, static calls and virtual calls by class in place (a class check per receiver, the depth of the frames they stand for checked at the entry), Int, Long and Double primitive array reads and `Array<T>` reads; `new` of an instance whose constructor only stores its parameters (its template copied into the region hole) and of a primitive array, an array's length, a lambda's body in place behind a test of the closure's record with its captures read from the closure, a cast to Int, Long, Double or Boolean as a check of the value's tag. A register only marked written where an exit leaves writes `Unit` there, so a dead value is kept alive by no exit. The called intrinsics (a map's lookup, store and size, a list's append, a builder's append and length) called straight, the values held across the call in registers a call may change saved around it; a list's element and size read in place; a not-null assertion as a check; Int and Long division and remainder (a divisor not known nonzero checked, its zero leaving to the op, which throws), a Boolean's negation, a compare with null (a tag test; constant for a word), Null and Unit constants, a value class's unbox of its underlying value and box of an instance as the value itself. An op the tier does not take is an exit to the baseline's code for it (up to eight a loop), whose back edge comes back into the loop's code while the loop's gate is open; a loop whose exits back into itself or failed entries spend its budget (512) gives way to the baseline for good. | in progress |
| `opt/stress` | A mode where every Nth check fails, so exits from callees run in the gate. | open |
| `opt/x64` | The x86-64 code (`opt/emit_x64.zig`): every op the AArch64 code takes, fields as one 16-byte access (movdqa, where the processor has AVX; plain slots are off without it and a field's check leaves), no fences (the order x86-64 keeps its loads and stores in), `idiv`'s `MIN_VALUE / -1` and `cvttsd2si`'s out-of-range answers put right, Double compares with NaN's parity. The unit tests run on x86-64 under Rosetta (`KLIO_PLAIN_SLOTS=1`, as Rosetta reports no AVX). A build by Zig's own x86-64 backend (a Debug build on Linux) has no plain slots, its assembler having no form for the 16-byte move, and so no tier. | done |

Every stage runs the whole gate with every function compiled at its first
entry (`KLIO_JIT_THRESHOLD=0`), with the loops' own threshold at its least
and at a moderate one, and in the exit stress mode.

The tier gains little where a loop's time is a host call (`HashMap.get`,
`StringBuilder.append`) or a template's copy (allocation), and nothing for
compose frames, whose time is calls that stay calls: those are the
baseline's and the runtime's to make cheaper.

## Log

- 2026-09-30: plan, and its review: a failed entry must not reach the
  optimized entry again, exits must mark what the baseline takes as
  written and write what a catch reads, a check after a callee's effect
  leaves through the callee's frame, statics are acquire reads and never
  hoisted, and the loop tiers up from its own count once its sites have
  run.
- 2026-09-30: the tier for loops of root ops, behind `KLIO_JIT_OPT=1`. ns an
  iteration, the baseline against the tier: a counted `acc += i` 2.10 to
  0.65, a field store 2.10 to 0.65, a field read into a Long 2.10 to 0.81,
  `d = d * k + c` over Doubles 7.09 to 2.90, `l = l * 31 + i` 2.10 to 1.29
  (its multiply's latency). The JIT-forced gate with the tier on found one
  fault: an exit's registers were taken as live from the instruction
  holding its op rather than from its op on, so a copy just before a back
  edge was left out of the frame and a tail-recursive loop never ended.
- 2026-09-30: callees in place and array reads. ns an iteration, the
  baseline against the tier: a static call 2.60 to 0.70, one of five
  arguments 7.69 to 1.07, a member call 6.02 to 2.44, a virtual call 8.51
  to 3.67, an interface call 7.02 to 3.37, a getter 5.45 to 2.76, an
  `IntArray` read 3.08 to 1.62. The gate with the tier forced found three
  faults: registers an instruction writes were taken from the ops rather
  than the IR, so a call's result was left out of what the loop writes
  and not written back at its exits; a callee's constants were read from
  the root's function; and the tier's switch shared `KLIO_OPT` with the
  performance profile, so `KLIO_OPT=safe` turned it on (it is
  `KLIO_JIT_OPT` now).
- 2026-09-30: allocation, lambdas and casts. ns an iteration, the
  baseline against the tier: `Point(it, 1).x` 7.45 to 0.70 and
  `IntArray(4).size` 5.97 to 0.62 (neither is made), a lambda call 3.10
  to 1.05, a cast of an `Any` holding an Int 9.36 to 0.63. With these a
  loop's invariants outgrew the registers, so an entry value the loop
  reads least is read from the frame instead. The test host makes
  closures over a function literal now, so the lambda path is tested
  where the tier is.
- 2026-09-30: host functions and seldom ops. ns an iteration, the
  baseline against the tier: `map[k]!!` 18.2 to 13.5 (Int keys) and
  17.6 to 13.3 (instance keys), a list read 3.95 to 2.16, a builder's
  append 18.0 to 16.5 (its `setLength` in a branch taken every 4096
  bytes leaves to the baseline and comes back). The rest of a map
  lookup's time is the lookup's own. A loop whose op the tier does not
  take on every turn (a value class's unbox) gives way after its budget,
  and its baseline back edge then pays a load and a branch on the gate:
  the value class cases lose 0.2 to 0.3. A result register the exit of
  its own node reads was one the linear scan could give the node, which
  an array read wrote before it left; exit reads now live through the
  node's write.
- 2026-09-30: checks a dominating check answered go, and a class test
  branches on its compare. A virtual call 3.52 to 3.14. The gate with the
  tier forced found two faults the seldom-op exits exposed: a field store
  had no exit for its write barrier's case (a reference into an old
  instance not remembered), and a block's `block_entry`, which pushes its
  try frame, was read as nothing, so a throw after an exit inside the try
  region found no handler. The store leaves to its op now, and the push
  is an op the loop leaves at.
- 2026-09-30: division, remainders, negation, null compares and value
  classes. ns an iteration, the baseline against the tier: making a value
  class and reading a property 4.62 to 0.84, a value class method 7.78 to
  0.96. Where the kinds know neither operand of an arithmetic op, a word
  the graph already holds for one gives the tag, rather than the Int
  guessed before, which met a Long's word and refused the loop.
- 2026-09-30: stack slots, x86-64, and on by default. Where the linear scan
  runs out of registers, the value held there cheapest in memory goes to
  memory (an entry value to the frame as before, another to a slot of the
  code's own stack), rather than the loop being refused; a test with two
  registers of each set swaps two values between slots. The x86-64 code
  takes every op the AArch64 code takes, with eight value registers (rdi
  and rsi among them, the context and the frame kept in the code's stack).
  With the tier forced, the stdlib commontests pass on both (149 files) and
  compile the same loops (84 over the collections tests), and the examples
  pass on x86-64 under Rosetta but for the 19 that need the Skia shim built
  for it. `klio run` and bundled apps now compile hot code and loops by
  default (`KLIO_JIT=0` or `KLIO_JIT_OPT=0` turns them off); other commands
  interpret unless told. On the way: macOS's `CLOCK_MONOTONIC` counts
  microseconds and steps back one now and then, which panicked a parse
  timing's subtraction once in a gate; the monotonic clock reads the uptime
  clock there, as the JVM does.
- 2026-09-30: the default threshold, 1000 entries and back edges, compiled
  718 functions (9.6 MB of code, 197 ms) of `hb_list`'s one-second startup
  and made it slower than the interpreter. CPU seconds at thresholds 1000,
  3000 and 10000 against the interpreter: `hb_list` 1.05, 0.98, 0.96 against
  0.98; `wb_churn` 7.48, 7.38, 7.20 against 7.14; `wb_anim` 4.74, 4.40, 4.32
  against 6.46; `hb_canvas` 2.30 at each against 5.18; `hb_recompose` 19.8
  against 29.2; `mb_ops` 0.27 at each against 1.83. The default is 10000.
