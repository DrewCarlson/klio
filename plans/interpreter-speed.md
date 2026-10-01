# Interpreter speed

klio runs Kotlin in an interpreter, and until it has a JIT again the
interpreter is what users get. The goal of this plan: klio's interpreter
ahead of the JVM's interpreter (`java -Xint`) on every workload, then as
close to the JVM with its JIT as an interpreter can come.

Measured only with the JIT off on both sides (`--jit off`), on the compose
workloads and the operation microbenchmarks:

```sh
zig build klio-harness-fast
bench/compose/run.py --jit off --only hb_list,hb_recompose,hb_canvas,hb_form
bench/compose/run.py --jit off --programs bench/interp/programs --rounds 1
```

## Baseline (2026-09-27, `3ae2432d`)

Compose frames, mean ms, klio against `java -Xint`:

| Workload | klio | JVM -Xint | Multiple |
|---|---:|---:|---:|
| 300 changing texts | 122 | 99.9 | 1.2x |
| 2,000 circles | 20.0 | 9.63 | 2.1x |
| List scroll | 2.99 | 2.32 | 1.3x |
| Form, idle frames | 0.23 | 0.27 | 0.9x |

Operations, ns per loop iteration (`bench/interp/programs/mb_ops.kt`):

| Operation | klio | JVM -Xint | Multiple |
|---|---:|---:|---:|
| counted loop | 36.4 | 8.99 | 4.1x |
| static call | 55.3 | 19.4 | 2.8x |
| virtual call | 88.2 | 31.1 | 2.8x |
| field read | 37.7 | 18.3 | 2.1x |
| object allocation | 108 | 55.9 | 1.9x |
| value class, make and read | 200 | 36.3 | 5.5x |
| value class `==` | 340 | 48.5 | 7.0x |
| `ULong` arithmetic | 236 | 43.8 | 5.4x |
| long arithmetic | 43.0 | 9.16 | 4.7x |
| double arithmetic | 68.1 | 8.53 | 8.0x |
| array read | 46.9 | 8.94 | 5.2x |
| `StringBuilder.append(Int)` | 822 | 249 | 3.3x |
| non-inline lambda call | 77.5 | 219 | 0.4x |
| `HashMap<Int, Int>` get | 124 | 276 | 0.4x |
| string template | 270 | 1383 | 0.2x |

## Work

| Id | Item | Status |
|----|------|--------|
| `cells/inline-lambdas` | A `var` a lambda captures lives in a heap cell, even when the lambda is spliced into its caller by an inline call (`forEach`, `repeat`, `let`, compose's `fastForEach`): every read and write of it goes through the cell. A cell that never leaves its own function becomes a register again after lowering; with it, counted loops test at the bottom, a jump into a block only it reaches joins the two, and a copy forwards to its one reader. | done |
| `ops/conversions` | `toLong()` and the other conversions between primitives were native calls, and arithmetic between two types (`Long + Int`, `Byte + Byte`, `Int * Double`) left the fast paths for the generic arm. A conversion is one instruction; a mixed operation converts its narrower operand first, as the JVM's bytecodes do, and a conversion of a constant is folded into it. | done |
| `value/unboxed` | Value classes (`Color`, `Offset`, `Dp`, `TextUnit`, `ULong`) are heap objects: making one allocates, `==` is a virtual `equals` call, reading one is a field load. Done: `==` between two values of one final value class compares their property in place, and a data class's `equals` compares a primitive property with one instruction; a value class over a number outside `kotlin.*` is its number wherever its static type is the class, boxed only where it meets `Any`, a type parameter, a nullable type or a generic signature (`plans/value-classes.md`); a constructor that only answers its value, or only initializes its companion first, is not called. Left: the stdlib's (`Duration`); a value class over a reference (`WriteScope` over `Operations`, 66,000 made per recompose run) is still allocated; `toString`, `hashCode` and a template part box the number to dispatch. | in progress |
| `alloc/one-cell` | An object was two allocations (its cell and its field slots): about 90 ns. Done: its slots are in its cell. Left: the main thread refills its cell cache by popping cells the sweeper freed on another core, a cache miss each, under the class lock; `gc.register` reads the `alloc_perm` thread-local, a call on Darwin, per allocation; `IntArray(4)` costs 108 ns against the JVM interpreter's 68, not yet profiled. | in progress |
| `alloc/cell-size` | An instance's cell holds 192 bytes before its first slot, so a two-field object is 224 bytes (3.5 cache lines) where the JVM's is 24: the collector's header (48: list link, mark, trace and finalize functions, type name, generation, bytes), a refcount (8) the tracing collector does not use for it, a per-cell allocator (16), and `InstanceData` (112: class, a slots slice, the slot lock, class id, `outer` 24, identity 8, `native_state` 32, `stack` 16). Measured: 128 bytes more per instance slows the 300 changing texts 2.9% and nothing else. Done: `outer` (never set) removed, `native_state` and `stack` moved to a record an instance points to only when a binding or a throw needs one; `InstanceData` 48 bytes, a two-field object 160 (the 300 changing texts 58.6 to 57.6 ms with the JIT). A string holds its bytes, and a closure its captures, after the cell in one allocation. To do: one descriptor pointer for trace, finalize and type name, a 32-bit mark, no per-cell allocator, the slot count as a u32 beside trailing slots. | in progress |
| `ops/per-op` | The loop and arithmetic cost 4-8x the JVM interpreter's per operation: fewer ops per statement (jumps to the next block, parameter and constant loads), and cheaper dispatch for the commonest ones. Done: an edge through an empty block goes where that block jumps, a function's parameters load in one op, which a call the stream loop makes performs itself, and an operation whose constant operand only it reads carries the constant in its own op. | in progress |
| `natives/pure` | A native call costs 12 to 30 ns beyond its work (a trace check, a keep-alive push, a borrowed host, the leak tracker's name, argument unpacking, result conversion), and the circles scene makes 22 per circle, most of them arithmetic. Done: `inv`, `Int.hashCode`, the floating-point bit views, `countTrailingZeroBits`, the unsigned types' conversions to floating point, `sin`, `cos` and `sqrt` are instructions. Left: the host calls themselves (Skia's paint and draw) through a slimmer path. | in progress |
| `calls/frame` | A call costs 1.3x to 1.6x the JVM interpreter's (static 25.2 ns against 19.5, virtual 40.9 against 30.2, a virtual getter 34.6 against 21.9). Done: a body's registers are renumbered so that registers share, and a function with a try region starts unfilled, so a window is as wide as the values it holds at once and almost none is filled; a virtual call site keeps the implementations and host functions of two receiver classes; a constructor that only stores its parameters, loads its companion or passes its parameters to its superclass's runs without a frame. Left: the entry's stores and the write mask (see What is left). | in progress |
| `calls/splice` | About 900,000 calls a frame in the 300 changing texts; after the getters, 15 to 20% of the calls go to bodies of at most 20 instructions that call nothing (`IntStack.push`/`pop`, `AtomicReference.get`, `SlotWriter.groupIndexToAddress`). Splicing such a body into its caller removes the call, worth about 3% of a frame. The spliced ops need their own instructions for an escape (`instAt` reads the frame's function) and their own stack-trace frame for a throw. | open |
| `ops/switch` | A `when` over an `Int` lowers to a chain of compare-and-branch ops, 3.25 compares an iteration in `branch_when` (23.6 ns against the JVM interpreter's 14.9, which has `tableswitch`). A switch op over a dense range of constants (a table) or a sparse one (a sorted search) takes one dispatch; a `when` over an enum compares identities with entries it loads first and could switch on the ordinal. | open |
| `gc/young` | A minor collection marks about 11,000 cells at about 130 ns each, and half of its pause is the remembered set (2,500 to 3,000 whole cells and a few ranges of large arrays). A cell tenures on surviving one collection. The 300 changing texts run 67 collections (40 minor, 14 initial marks, 13 remarks), about 5% of the run. A floor of 32 MB or 64 MB instead of 8 MB speeds them 3% and 4% and slows the idle form frames. To do: tenure after more than one survival or by age, a floor that adapts to the collection's cost, and a faster mark. | open |
| `dispatch/layout` | The dispatch function was about 60 KB of machine code, and an edit anywhere in it moved unrelated cases by up to 40% either way: the register allocator placed the values the loop carries (frame, code, pc, block, streams, thread state, try stack, ...) differently each build, and an arm could find `frame` in the wrong register and spill it on its fast path. Done: each op is a function of its own (`src/ir/eval/stream.zig`) that tail-calls the next op's, with the frame, its registers, the code, the pc and the block in argument registers and everything else in a context in memory; slow paths are functions of their own reached through a table the optimizer cannot fold, so no fast path contains a call and none saves registers; a static call, its callee's activation and its return take a path with no call when the pool, the value stack and the window allow it. Left: frame pointers, which put a frame record (three instructions) in most ops; omitting them in the `ir` module measured 2-3% on the compose frames, at the cost of the ir frames in sampled call stacks. | done |
| `strings/builder` | `StringBuilder.append(Int)` cost 3.3x the JVM interpreter's: the builder's length is counted in UTF-16 units from a memo each append dropped, so reading `length` after an append rescanned the buffer. Done: an append carries the memo over. | done |

## Where it stands (2026-09-28, `6262dc47`)

`bench/compose/run.py --jit off --rounds 3`, klio's interpreter against
`java -Xint`, and the same for `bench/interp/programs`
(`target/bench-compose/review-jitoff-*.json`).

| Compose scene | klio | JVM -Xint | Multiple | Baseline klio |
|---|---:|---:|---:|---:|
| 2,000 circles, frame ms | 8.04 | 9.69 | 0.8x | 20.0 |
| 300 changing texts, frame ms | 80.2 | 99.4 | 0.8x | 122 |
| List scroll, frame ms | 2.13 | 2.33 | 0.9x | 2.99 |
| Form, idle frames, frame ms | 0.21 | 0.27 | 0.8x | 0.23 |
| Animation, CPU ms a frame | 4.23 | 5.61 | 0.8x | |
| Long scroll, CPU ms a frame | 4.72 | 4.86 | 1.0x | |

First composition 0.1x to 0.4x the JVM's, launch to first frame 0.3x,
peak footprint 0.2x to 1.0x.

| Operation, ns | klio | JVM -Xint | Multiple | Baseline klio |
|---|---:|---:|---:|---:|
| counted loop | 8.08 | 8.96 | 0.9x | 36.4 |
| static call | 25.2 | 19.5 | 1.3x | 55.3 |
| static call, 5 arguments | 37.0 | 28.8 | 1.3x | |
| member call | 36.9 | 25.6 | 1.4x | |
| virtual call | 40.9 | 30.2 | 1.4x | 88.2 |
| virtual getter | 34.6 | 21.9 | 1.6x | |
| interface call | 37.8 | 25.8 | 1.5x | |
| field read | 10.3 | 18.4 | 0.6x | 37.7 |
| field write | 8.25 | 19.1 | 0.4x | |
| object allocation | 60.3 | 56.8 | 1.1x | 108 |
| `IntArray(4)` | 108 | 68.3 | 1.6x | |
| value class, make and read | 33.2 | 37.5 | 0.9x | 200 |
| value class method | 52.0 | 64.5 | 0.8x | |
| value class `==` | 18.7 | 48.9 | 0.4x | 340 |
| `ULong` arithmetic | 24.0 | 45.4 | 0.5x | 236 |
| lambda call | 40.5 | 221 | 0.2x | |
| boxed `Int` | 12.7 | 11.3 | 1.1x | |
| long arithmetic | 10.5 | 11.0 | 0.9x | 43.0 |
| double arithmetic | 12.8 | 9.48 | 1.3x | |
| `when` over an `Int` | 23.6 | 14.9 | 1.6x | |
| array read | 14.8 | 10.7 | 1.4x | |
| `List.get` | 39.5 | 116 | 0.3x | |
| `HashMap<Int, Int>.get` | 86.9 | 278 | 0.3x | |
| `HashMap` with object keys | 222 | 210 | 1.1x | |
| `StringBuilder` | 129 | 251 | 0.5x | |
| string template | 231 | 1379 | 0.2x | |

Every compose scene runs ahead of the JVM interpreter. Behind it still: every
kind of call (1.3x to 1.6x), a `when` over an `Int` (a chain of compares
where the JVM has `tableswitch`), array reads, double arithmetic and a
primitive array's allocation. The known levers inside the interpreter are
each worth a few percent of a compose frame (see the log): a frame without
its write mask, a smaller instance cell, a younger collection floor,
splicing small callees, a switch op. The JIT is the next step.

### What is left

Behind the JVM interpreter, by operation (the table above):

- **Calls, 1.3x to 1.6x.** In a loop of static calls to `inc(x) = x + 1`,
  the call op takes 40% of the samples and the return 15%. Almost all of
  the call op's time is about 25 back-to-back stores initializing the frame
  (17 fields, the activation's return state, the context) and the parameter
  copy, which also writes a byte of the frame's write mask per parameter.
  The mask (512 bytes in every activation, a byte stored at every register
  write) tells the collector which registers of an unfilled window this
  call wrote. Without its stores a call-heavy loop runs 3.5% (one
  argument) to 8% (five arguments) faster. Replacing it by keeping the
  value stack `Unit` above its top measured slower on every compose scene
  (see the log). What would work: the collector reads a frame's written
  registers from a static analysis of the instruction the frame stands at,
  must-written over the edges and the catch and finally edges; the
  analysis must leave out the writes the stream skips (a constant folded
  into its reader, a fused compare's boolean), and every safepoint must
  record where the frame stands first (the edge guard and the frame loop's
  block start do not yet). Beside it, fields a pooled activation keeps
  neutral across uses (its heap block, pending flow, the allocator and
  thread state) need not be written at every call.
- **`when` over an `Int`, 1.6x.** `ops/switch`.
- **`IntArray(4)`, 1.6x.** `alloc/one-cell`.
- **Array reads 1.4x, double arithmetic 1.3x.** Already one op each;
  the difference is the cost per op (about 2.3 ns for a simple op here, the
  JVM interpreter's template ops less).
- **Object allocation, a boxed `Int` and a `HashMap` with object keys,
  1.1x.** The last calls the key's `hashCode` and `equals`, so it follows
  the calls.

Where a compose frame goes (the 300 changing texts): calls and returns 28%,
field access 9% (the first touch of an instance, not the slot lock),
allocation 7%, copies, constants and branches 11%, the collector's mark 5%.
Each lever inside the interpreter is worth a few percent of that: the write
mask, `alloc/cell-size`, `gc/young`, `calls/splice`, `ops/switch`.

Measuring: `KLIO_CALL_STATS` and `KLIO_FRAME_CENSUS` turn the call hooks on,
which turns frameless calls off, so they count every leaf call as a frame.
Machine-level: `xcrun xctrace record --template 'Time Profiler'`, then
`xctrace export` of the `time-profile` table and each sample's leaf
address (one byte past the instruction) against `xcrun objdump -d` of the
op's address range.

### The JVM with its JIT

The reference for the JIT that follows (`jit-both.json`,
`ops-jvm-jit.json`):

| Compose scene | klio | JVM, JIT on | Multiple |
|---|---:|---:|---:|
| 2,000 circles, frame ms | 8.04 | 2.01 | 4.0x |
| 300 changing texts, frame ms | 80.2 | 7.54 | 10.6x |
| List scroll, frame ms | 2.13 | 0.93 | 2.3x |
| Form, idle frames, frame ms | 0.21 | 0.25 | 0.8x |
| Animation, CPU ms a frame | 4.23 | 4.21 | 1.0x |
| Long scroll, CPU ms a frame | 4.72 | 2.65 | 1.8x |

Every operation in `mb_ops.kt` runs in 1 to 8 ns on the JVM with its JIT
(a static call 2.03, a virtual call 2.15, an allocation 2.60, a field read
1.53, `HashMap<Int, Int>.get` 7.57), except the string template (32.2):
inlined and with the allocations removed, where klio's interpreter takes
8 to 231 ns.

## Log

- 2026-09-27: baseline above. Lambdas, native collections and string
  templates are already ahead of the JVM interpreter; calls, arithmetic,
  field access, allocation and value classes are behind.
- 2026-09-27: registers for cells, rotated counted loops, joined blocks,
  forwarded copies, and a floating-point fast path. Operations against the
  baseline binary, ns: counted loop 36.9 to 15.4, static call 55.8 to 38.4,
  field read 37.9 to 17.5, double arithmetic 69.3 to 25.1, long arithmetic
  43.4 to 21.6, array read 47.3 to 29.0; every case faster. Compose frames,
  ms: 300 changing texts 112 to 108, list 2.91 to 2.74, circles 19.9 to 18.2,
  form 0.22 to 0.22.
- 2026-09-27: conversions as instructions and widened mixed operations.
  Against the previous entry, ns: making a value class and reading it 171 to
  116, its method 258 to 204, its `==` 331 to 262, `ULong` arithmetic 191 to
  168, long arithmetic 21.8 to 19.8, counted loop 15.3 to 14.8.
- Placement: the same operations can run 50% slower in one place than in
  another. In `mb_ops.kt` the double-arithmetic loop took 37.8 ns on one
  build, running the same ops as on the build before, and 25.3 ns on the
  same build with one statement added before it, which moves the loop's
  bytecode and registers. The cause is not yet known. Before crediting or
  blaming a change for one case, move the case and measure again.
- 2026-09-27: an object's slots in its own cell, and value-class `==` in
  place. `bench/interp/programs/mb_ops.kt` now runs each group of cases in a
  function of its own, so a change to one case no longer moves the others.
  Against the previous entry, ns: object allocation 91 to 71, making a value
  class 120 to 95, its `==` 264 to 130, its method 209 to 170. Compose frames,
  ms: 300 changing texts 109 to 105, list 2.76 to 2.69, circles 17.4 to 17.0.
- Measured and dropped: a slab whose cells were all freed, reset to hand out
  runs from its start again. No change in the operations or the compose
  frames (under 1%): the refill takes partly free slabs first, and those still
  pop their free lists.
- The evaluator's code generation still moves unrelated cases: with the
  cases isolated, one build ran the counted loop 24% faster and the static
  call 10% slower than the build before, neither touched by the change.
- Where a circles frame goes (`hb_canvas`, 2,000 circles): about 1,100 ops
  per circle at about 7.7 ns each, against the JVM interpreter's 4.8 us per
  circle. Of the ops: parameter loads 14.6%, constant loads 17%, copies 8%,
  jumps 7%, field reads 9%; about 40 static and 10 virtual calls and 19
  native calls per circle. Each circle makes about 5 `Color` instances and
  one `Offset`.
- 2026-09-27: numeric natives as instructions. `Long.inv()` 35.9 to 20.0 ns
  in a loop, `Float.fromBits` 58 to 24. Compose frames, ms: circles 17.1 to
  15.9, list 2.68 to 2.61, 300 changing texts 102.9 to 100.1.
- 2026-09-27: `==` between two values of one unsigned type compares their
  bits, and a value or data class holding one compares it the same way: the
  circles scene called `ULong.equals` five times per circle. Circles 15.8 to
  15.5 ms. The calls a circle makes, about 60: the colour-space conversion
  `paint.color = color` runs (`toArgb`, `convert`, `connect`) twice, the
  `colorSpace` getter three times with two `IntObjectMap.get`s, four
  component getters of about 120 instructions each. The JVM interpreter runs
  the same code; the difference is klio's cost per op and per call.
- 2026-09-27: every edge (a back edge, a call) read four flags from three
  places; they are now one word, and the periodic checks run out of line.
  Where a static call's time went, with its helpers out of line: the
  dispatch loop 60%, the edge check 10%, opening the activation 8%, entering
  the frame 7%, loading the parameters 4%, closing 7%, finding the callee 3%.
  Static call loop 31 to 30 ns; circles 15.7 to 15.2 ms. A minimal
  interpreter of the same four-op counted loop, with klio's 16-byte values,
  runs it in 9.4 ns, the JVM interpreter's time: klio's simple ops are
  already near what this design allows, and the difference to the JVM is in
  calls, allocation and the value-class and unsigned operations.
- 2026-09-27: the unsigned types' constructors and their `data` are
  instructions. Their operators are inline functions over `data`
  (`ULong(data shl n)`), so each was a slow field read of the host's number
  and a native constructor call; now each is three register ops. `ULong`
  arithmetic 166 to 44 ns, the JVM interpreter's 43.8. Circles 15.2 to 12.6
  ms: `Color` is a `ULong`.
- 2026-09-27: `StringBuilder` appends keep the length memo. A loop appending
  and reading `length` 832 to 232 ns per iteration (the JVM interpreter's
  `append(Int)` alone is 249).
- 2026-09-27: a primitive array's element read takes no lock: the buffer
  never moves once made and an element is at most a word. Array read 28.1
  to 26.1 ns; the rest is the per-op cost.
- 2026-09-27, where the compose frames stand (`bench/compose/run.py --jit
  off`, klio alone, against the baseline's JVM interpreter): 300 changing
  texts 100 ms (JVM 99.9, from klio's 122), circles 12.4 (JVM 9.63, from
  20.0), list 2.58 (JVM 2.32, from 2.99), form 0.23 (JVM 0.27).
- 2026-09-27: an operation whose constant operand only it reads carries the
  constant in its own op, and the constant's load goes (`bin_k`, `cmp_br_k`:
  Int and Long in arithmetic, masks, shifts and compares, Float and Double in
  arithmetic and compares, unsigned numbers in equality). A tenth of the
  circles scene's ops were such loads. Compose frames unchanged within noise
  (circles 12.47 to 12.43 ms, 300 changing texts 98.8 to 99.8, list 2.55 to
  2.59), and the operations moved both ways by up to 40% on cases whose code
  did not change: the register lottery of `dispatch/layout`, measured with
  the CPU counters (Instruments' CPU Counters template, bottleneck and
  discarded-sampling modes).
- 2026-09-28: each op a function of its own, tail-calling the next. Against
  the previous entry's build, ns: counted loop 15.6 to 9.2 (JVM interpreter
  9.0), static call 41.5 to 25.8, virtual call 69.5 to 56.8, interface call
  62.0 to 49.7, field read 17.2 to 11.3, array read 26.3 to 15.1, double
  arithmetic 23.2 to 12.8, lambda call 59.1 to 41.6, string template 247 to
  231; no case slower. Compose frames, ms: circles 12.53 to 12.21, list 2.66
  to 2.56, 300 changing texts 99.7 to 100.3, form 0.22 to 0.22. Along the
  way: an operation with a constant operand is an op per operator, so the
  dispatch picks the operation rather than a switch every such op shares
  (double arithmetic 18.3 to 12.7 ns); two Floats or two Doubles compute and
  compare in the op instead of the instruction's arm (circles 12.9 to 12.3
  ms); an operator no op computes in place (string concatenation, identity,
  ranges) goes straight to its arm.
- Checked: the fast harness and a full `-Doptimize=ReleaseFast` build compile
  the interpreter the same (same `runLoop`, same op handlers), so the
  harness numbers are the release numbers.
- 2026-09-28: a virtual or interface call site keeps the implementations
  of the first two receiver classes it resolves, and a receiver of either
  runs it the way a static call runs its callee. ns: virtual call 57.1 to
  43.2, a virtual getter 47.0 to 35.2, interface call 49.9 to 37.8. Compose
  frames, ms: 300 changing texts 101.8 to 97.2 (JVM interpreter 99.9),
  circles 12.25 to 11.7, list 2.56 to 2.46, form 0.245 to 0.22.
- 2026-09-28: a call whose callee is not shown to write each register
  before reading it fills its window with `Unit` in the call's own path
  (one store per register) instead of the general open: an eighth of the
  circles scene's calls took the general open for it, at about seven times
  a call's cost. And a constant operand of type Long, a Long shifted by a
  constant and an unsigned constant compared for equality compute in the op
  rather than its slow path. Compose frames, ms: 300 changing texts 98.1 to
  95.6, circles 11.76 to 11.35, list 2.47 to 2.45, form 0.22 to 0.235.
- 2026-09-28: each conversion, each numeric function, each `bin` operator
  and the increment, decrement and negation are ops of their own, so the
  dispatch that reaches one picks the operation, where a switch every such
  op shared picked it again (one indirect branch for all sites, which
  mispredicts where sites alternate). ns: counted loop 9.3 to 7.7, `ULong`
  arithmetic 41.1 to 23.5, long arithmetic 11.6 to 10.0, array read 16.2 to
  14.2. Compose frames, ms: circles 11.32 to 11.12, the others unchanged.
- 2026-09-28: null tests and identity tests in place. `p != null` lowered
  to a `Null` constant, an escape to the instruction's arm for `===`, a `!`
  and a branch: four ops, one slow, for Compose's commonest test. A `!` of
  an equality or identity test is now the negated test (lowering), a test
  against a `Null` constant rides in its op like any other constant
  operand, and `===` and `!==` answer a null or two instances in place, so
  the loop's `while (p != null)` is one op. Compose frames, ms: 300 changing
  texts 97.0 to 85.5 (JVM interpreter 99.9), list 2.48 to 2.19 (2.32),
  circles 11.17 to 10.22 (9.63), form 0.22 to 0.21 (0.27).
- 2026-09-28, from a census of the slow paths each op took: every call of
  a function with a try region allocated its try stack at the first push
  and freed it at the return, and took the general close for it (4.35
  million returns in the circles scene); try stacks now allocate from the
  allocator the activation pool uses, and a pooled activation keeps its
  buffer. A Long shifted by a Long, and `==` between two unsigned numbers of
  one type, two Bools or a null, compute in the op. Compose frames, ms:
  circles 10.14 to 10.01, list 2.19 to 2.15, 300 changing texts unchanged.
- Measured and dropped: reading a reference array's element in the op
  under a shared borrow taken without waiting (the circles scene reads 3.6
  million), rather than in its slow path. No change in the compose frames:
  the borrow's two atomic operations cost what the slow path did.
- 2026-09-28: a virtual call whose implementation is a host function
  (`List.get`, `CharSequence.length`, `Any.hashCode` on a boxed number)
  resolved its target twice per call, once to find there was no body and
  again to find the host function. A call site now keeps, per receiver
  class, the host function as well as a body, keyed by the class the
  dispatch itself uses for any receiver with one (numbers, strings, arrays
  and the host collections as well as instances), and calls it straight
  from the op. The 300 changing texts make 1.46 million such calls a run.
  Compose frames, ms: 300 changing texts 85.7 to 84.1, the others
  unchanged.
- 2026-09-28: frames as wide as their live values. Lowering gave each
  temporary, and each inline body it copied in, registers of its own, so
  `Color(red, green, blue, alpha, colorSpace)` (three `floatToHalf` and
  eight `fastCoerceIn` copies) had 684 registers, and a frame of more than
  512 was filled with `Unit` on every call: 24 MB written per circles frame
  for one call per circle. A body of more than 64 registers is now
  renumbered by liveness (`Color` 684 to 12, `GapComposer.end` 639 to 22),
  and a function with a try region is no longer filled on that account: a
  catch or finally starts with what was written where its region began.
  `Unit` fills per run: circles 15.5 million to 0.47 million, 300 changing
  texts 70 million to 1.9 million, list 29 million to 0.41 million. A
  constant still rides in the operation that reads it when its register is
  written again elsewhere, and a parameter still loads at the call. Compose
  frames, ms: circles 10.00 to 9.17 (JVM interpreter 9.63), list 2.15 to
  2.08, 300 changing texts 85.0 to 83.3.
- 2026-09-28: value classes over numbers are their numbers
  (`plans/value-classes.md`). A value is held as the number wherever its
  static type is the class, and boxed where it widens to `Any`, an
  interface, a type parameter or a nullable type; `BoxValue` and
  `UnboxValue` are each the value itself when it is in that form already,
  so a conversion only has to happen where the static type changes. A
  parameter or result takes the number when its override family's root
  declares the class there, as the JVM mangles signatures. ns:
  value class make and read 75 to 36 (JVM interpreter 36.3), method 136 to
  57, `==` 102 to 22 (48.5), float operation 127 to 42. Compose frames,
  ms: circles 9.26 to 8.52, list 2.10 to 2.06, 300 changing texts 83.3 to
  82.2.
- 2026-09-28: a scalar class's constructor that only initializes its
  companion is not called either: `V(x)` loads the companion, which
  initializes it the first time, and is `x`. Compose frames, ms: circles
  8.38 to 8.16, 300 changing texts 80.3 to 79.6, list 2.05 to 2.03.
- 2026-09-28: a constructor that only stores its parameters is run without
  a frame, and that now includes one that first loads its class's companion
  (every class with a companion, and every subclass of one, did) and one
  that first passes its parameters to its superclass's constructor. The
  companion's load is what initializes it, once, at the class's first
  construction; after that the load does nothing, and the stores run alone
  once the companion is built. A superclass constructor runs its own stores
  first, found at the call's site once a first construction has resolved
  it. ns per construction (`Counted(i)`), against the JVM interpreter:
  a class with a companion 65 to 53 (JVM 47, the same as without one), a
  subclass of one 81 to 60 (62). Compose frames unchanged: their hot
  classes have no companion.
- Where the 300 changing texts go now (`sample`, main thread): calls and
  returns about 28% (`call` 10%, `ret` 5%, `vcall` 3.4%, construction and
  host calls the rest), field reads and writes 9%, allocation 7%, copies,
  constants and branches 11%, the collector's marking 5%. About 900,000
  calls a frame; 36% are getters, most of them served without a frame, and
  another 15 to 20% go to bodies of at most 20 instructions that call
  nothing. Every called function has at most 64 registers since the
  renumbering by liveness, 14 to 15 on average.
- Measured and dropped: slot reads and writes without the sequence lock
  (plain copies, in a throwaway build). No change in the compose frames: a
  field read's cost is the first touch of the instance, not the lock.
- Measured: an instance 128 bytes larger slows the 300 changing texts 2.9%
  and nothing else, so taking the unused fields out of an instance's cell
  (192 bytes before its first slot: the collector's header, a per-cell
  allocator and refcount, the rare `outer`, `native_state` and `stack`) is
  worth about as much.
- Measured: the collection floor at 32 MB and 64 MB instead of 8 MB speeds
  the 300 changing texts 3% and 4% and slows the idle form frames (a
  collection lands in the timed frames). A minor collection marks about
  11,000 cells at about 130 ns each, half of its pause the remembered set.
- Measured and dropped: a value stack that holds `Unit` above its top, a
  return putting it back, so a window needs neither a fill nor the write
  mask. Calls got faster (static 25.3 to 24.7 ns, five arguments 36.9 to
  35.4), the compose frames slower (circles 8.05 to 8.39 ms, 300 changing
  texts 79.1 to 81.0, list 2.01 to 2.07): refilling 15 registers at every
  return costs more than the mask's store at each write. Without the mask
  stores and with nothing added, a call-heavy loop is 3.5% to 8% faster;
  what would get that is the collector reading a frame's written registers
  from a static analysis of where the frame stands, which has to leave out
  the writes the stream skips (a constant folded into its reader, a fused
  compare's boolean).
