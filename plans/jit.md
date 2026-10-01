# JIT

klio's interpreter runs ahead of the JVM's interpreter on every compose
scene (`plans/interpreter-speed.md`), and 2.3x to 10.6x behind the JVM with
its JIT: circles 8.04 ms against 2.01, 300 changing texts 80.2 against 7.54,
list 2.13 against 0.93, form 0.21 against 0.25; every operation in
`mb_ops.kt` runs in 1 to 8 ns on the JVM with its JIT where klio takes 8 to
231. The goal: klio with its JIT reasonably comparable to the JVM with its
JIT across the compose scenes and the operations, then both tiers refined.

The old JIT compiled the old interpreter's instructions and was archived
(`archive/jit/`, `docs/design/JIT-DESIGN.md`). Its executable-memory code
carries over; its emitters were a two-operand register machine shaped for
scalar loops, and its compilers targeted a frame and an instruction set that
no longer exist.

Measured with the JIT on and off on both sides:

```sh
zig build klio-harness-fast
bench/compose/run.py --jit both --only hb_list,hb_recompose,hb_canvas,hb_form
bench/compose/run.py --jit both --programs bench/interp/programs --rounds 1
```

## Principles

- **The interpreter is the semantics.** Compiled code shares the stream
  loop's frames, registers, activations and handler protocol. Every
  compiled op either runs exactly its handler's fast path or tail-calls its
  handler, which runs the op from the start; so every slow path, call,
  return, throw, safepoint, suspension and diagnostic stays the
  interpreter's, and a compiled function can hand back to the interpreter at
  any op boundary with nothing to reconstruct.
- **Correct before fast.** Every stage runs the whole gate with every
  function compiled at its first entry (`KLIO_JIT_THRESHOLD=0`) and matches
  the interpreter's output, and the JIT off (`KLIO_JIT=0`, `--opt safe`)
  stays the interpreter unchanged.
- **Portable.** AArch64 (macOS, Linux, Android, iOS) and x86-64 (macOS,
  Linux, Windows) have backends; any other target builds and interprets.
  The AArch64 backend's tests run on macOS and on Linux in Docker, the
  x86-64 backend's on this Mac under Rosetta; Windows is cross-built.

## Design

**Where compiled code runs.** A function that crosses its hotness threshold
(entries plus back edges) is compiled from its streams (`bc.FuncStreams`),
op by op, into one block of native code with an entry at every op. Then the
opcode word of each op in its streams is overwritten with `jit`, one
aligned word store each; the operands stay, since handlers read them. The
`jit` op's handler reads the running function's native entry for its pc
(`c.bs.jit`) and jumps there. Any dispatch into the function after that (an
entry, a return to it, a handler's `next`, the frame loop resuming a block)
lands in native code at that pc, and a frame of the function already
running continues in native code at its next dispatch. A thread that read
the opcode before the store runs the op in the interpreter, which is
equally right.

**What compiled code is.** Native code has the handlers' signature and
calling convention (the context, the frame, its registers, the code, the pc
and the block in argument registers), sets up no stack frame of its own and
keeps nothing in machine registers across an op it hands off. An op it runs
natively falls through to the next op's code or jumps to its target's; an
op it does not, or whose fast path's checks fail, tail-calls that op's
handler with the op's pc, and the handler's `next` dispatches the following
op, whose opcode is `jit`, back into native code. Handlers take the C
calling convention (the System V one on every x86-64 target, Windows
included), so native code and handlers call each other the same way on
every backend.

**What it relies on.** The layout of a `Value` (16 bytes: the payload, then
a tag byte whose upper bits are unspecified), a `Frame`, the context and an
instance's slots, probed and checked at startup; a mismatch turns the JIT
off. Every register write also sets the frame's write mask byte, as `put`
does.

**Tiers.** The baseline tier above is the first and the fallback for every
later one. An optimizing tier then compiles hot functions from the IR into
typed values in machine registers, with inlined callees, and leaves for the
baseline code or the interpreter at an op boundary by writing its values
back to the frame (deoptimization).

**Registers in machine registers (`jit/types`).** A compiled function
keeps its hottest registers of a known kind in machine registers for its
whole code, untagged: a loop's counter, an accumulator, a bound. A kind
is known where every write the function makes to the register produces
it, found by a forward pass over its blocks from what each op makes: a
constant, a parameter's declared non-null primitive type, a field whose
seed is a primitive, a callee's declared return type, arithmetic and
conversions over known kinds. The frame stays the canonical state at every
hand-off: code that leaves for a handler (a failed check, an op that does
not compile, a call that stays a call, a loop's guards) first writes every
pinned register back, payload and tag, and every entry into the code (the
function's, a return into it, the frame loop's `jit` op at any pc) goes
through a stub that loads them, checking each tag, and runs the op in its
handler when one is not the kind (an entry then costs no correctness, only
the compiled path). So a safe point is always outside compiled code, and
the collector reads the frame as it does now. Ops over pinned registers
drop their tag checks and their loads and stores.

**Callees in place.** A callee compiled into its caller writes no frame of
its own. Its code reaches no safepoint (no allocation, no call, no loop
guard that does not leave first), so its registers need no collector root;
its spans are known where it compiles (each block's entry span, when every
path to the block agrees) or kept in a per-level slot the edges into the
block write; registers some path may have written and another not are
filled with `Unit` at its entry, so every exit knows which registers hold
values.

## Stages

| Id | Stage | Exit | Status |
|----|-------|------|--------|
| `jit/memory` | `src/jit/`: a code heap whose chunks are written through one view and run through another (macOS: one `MAP_JIT` mapping with the per-thread write switch; Linux and Android: a memory file mapped twice, else one mapping both ways; Windows: a pagefile section mapped twice), with the instruction cache made coherent after each write; an AArch64 and an x86-64 assembler with labels and a literal pool, so code is position independent. | Encoding tests against the system assembler's bytes (126 AArch64 instructions, 106 x86-64), execution tests on arm64 macOS, x86-64 macOS under Rosetta and aarch64 Linux in Docker; the module cross-builds for Windows (x86-64, aarch64) and riscv64. | done |
| `jit/threaded` | The handlers' C calling convention (System V on every x86-64 target); `bc.opLen`; a hotness count per function at every entry (a call's, the frame loop's) and `KLIO_JIT`, `KLIO_JIT_THRESHOLD`, `KLIO_JIT_STATS`; the `jit` op and patching; every op compiled as a tail call of its own handler (`src/ir/eval/baseline.zig`). | The whole gate green with `KLIO_JIT=1 KLIO_JIT_THRESHOLD=0`: compiled code that only reaches the handlers behaves as the interpreter does. | done |
| `jit/ops` | Native fast paths: constants, copies, parameters, Int, Long and Double arithmetic and compares with tag guards, branches, jumps and edges (the safepoint and edge-flag word), `not`, increments, conversions, field reads (with the slot lock's read protocol), primitive array reads. Done: constants, copies, parameters, jumps and branches with their back-edge guards, fused compare-branches, the constant-operand ops over Int, Long and `null`, Int and Long add, subtract, compare, multiply, bitwise and shifts, increments and negation, `not`, Int-Long conversions, field reads (`src/ir/eval/masm.zig`, a macro assembler both backends implement; `baseline_test.zig`), Float and Double add, subtract, multiply, divide and compares (NaN answers as the interpreter's). A loop edge counts toward compiling as an entry does, so a function entered once compiles in its loop and goes on in compiled code. An entry and a return into a compiled function jump to its code directly. A function most of whose ops would only call their handlers is not compiled (`KLIO_JIT_MIN_NATIVE`, default 70 percent). Then: field stores (the slot sequence's store turn taken with a compare-and-swap, the write barrier's common cases in place), capture loads, value class unboxing and boxing, identity compares, equality with null and between Bools, `inv`, the unsigned types' bit views, String constants, loads of built objects (from the run's state), `is` and `as` through a cache of the last class each op tested (filled where the code leaves), reads and stores of Int, Long and Double arrays, reads of `Array<T>` (under the array's shared lock) and stores into one (under its exclusive lock, where the write barrier has nothing to record), static loads, Boolean `and`, `or` and `xor`. Left: the other conversions, the other primitive arrays. | in progress |
| `jit/calls` | A call whose callee its site's cache holds, when some path through the callee returns in place, runs the callee's code in place: static calls, and virtual calls behind a test of the receiver's class for each of the two classes a site keeps; callees of those callees too, four levels deep. The callee's registers sit in the thread's inline registers; where its code leaves for an op's handler (a failed check, an op that does not compile, a loop's guards), each callee in place gets the frame its call would have opened, holding what it has written, and the op runs there (`inlineExit`); the callee then returns to its caller's next op as any call does. A call site whose cache held nothing when its function compiled counts its runs, and at the threshold the function compiles again, three times at most. A callee's op that does not compile leaves there, which opens the frame the call would have opened, the way the call opens it, so compiling a callee in place costs no more than calling it. Host functions a call runs are compiled as their instructions where they are a few (`Any.hashCode` on an instance, `Long.hashCode`, array sizes, a list's size, element and store, Int and Long rotations and bit counts), from a static call, a virtual call (a list receiver tested by its tag) or a `native` op. Then: a call from compiled code that stays a call opens the callee's activation in compiled code and enters its compiled code directly, and its return goes back the same way. Done: an `Array<T>` element is read with no lock, between two equal even readings of a sequence its writers turn as they take and give back the lock (a list's and an array's cell lock both keep one), since an array's buffer never moves. A list's element is read with no lock too, where the process runs on the slab heap (`objcell.lockfree_reads`): its buffer and length between two equal even readings, the element before a third; memory the heap gives back while the mutators run stays mapped until a reclaim pass has aged it past a stop (`slab.unmapLater`), which no read spans, so a read of a buffer a writer just replaced finds garbage the third reading throws away. `list[i]` with the JIT 14.1 to 4.0 ns (JVM JIT 3.7), interpreted 22.4 to 20.7. | Calls under the JVM interpreter's; compose frames measured. | in progress |
| `jit/host` | Host functions called from compiled code: the hottest as instructions (`jit/calls`), the rest with no generic layers between the op and the stdlib function. Done: hash maps and sets over instances hash and compare a key whose class keeps `Any`'s `hashCode` and `equals` by identity, with no call into the VM and no allocation per lookup; a `native` op or a host virtual call whose native is a stdlib function, or a member that only wraps one, calls it straight from the handler with the host's kept view and no keepalive (the registers root the arguments): a trivial host call 32 to 24 ns. Measured, one layer at a time: the keepalive 3.1 ns, the host view 2.1, the receiver memo 0.5, the leak tracker's names 0.4; the rest is the four nested calls the direct path skips. The interpreter runs the compiled code's intrinsics in place of the host call (`intrinsics.zig`), with a map's get (a scalar key, or an instance whose class keeps `Any`'s members, through the index), a builder's append of a string or a number and its length besides, which compiled code leaves to the handler. A map key's hash is its bits mixed, not Wyhash twice. `HashMap<Int, Int>.get` 63 to 29 ns, with object keys 94 to 28, `StringBuilder.append` 94 to 46. Compiled code calls the interpreter's intrinsics for a map's get and a builder's append and length straight (`Intrinsic.called`), keeping its registers on the stack across the call, with no handler between; a map reads its index under the shared lock where every entry is indexed, and its index is a power-of-two bucket array over the hashes' low bits. A map's lookup takes no lock where a list's read takes none (`lookupNoLock`): the store's arrays between two equal even readings of the sequence its writers now turn, each candidate entry read again before its key is looked through, a number's key compared as read; compiled code calls it straight, past the intrinsics' dispatch. `HashMap<Int, Int>.get` with the JIT 22.3 to 17.0 ns, with object keys 19.0 to 17.7. A builder's length is its length in bytes, read with no lock, while every byte is known ASCII (its header's spare word holds the length it was last known ASCII at), and its appends write numbers' digits two at a time and call straight from compiled code: `StringBuilder` append-and-length 29.6 to 18.2 ns with the JIT, 45.8 to 39.2 interpreted. A list's `add`, a map's `put`, `set` and `size` are intrinsics too, and `new` of a class the host makes calls its constructor's stdlib function straight. Left: the handler itself (a 320-byte frame, the result through memory) for a native that has no intrinsic; a map lookup's own chain of dependent loads (bucket, hash, entry), about half of what is left, in compiled code with no call. | Host collection operations near the JVM JIT's; compose frames measured. | in progress |
| `jit/lambdas` | A lambda call site that sees one lambda function runs its body in place, its captures read from the closure. Done: the closure itself. A lambda made from sema was a table entry (under the table's lock), a names array, a capture store and the cell with a copy of its captures, and each call looked its body up in the table again. A closure's cell now points to its function literal's or reference's record, interned once per module, body and kind (the program's own lambdas found without the lock), and holds its captures after it in the same allocation: making and calling a capturing lambda 290 to 91 ns, a lambda call 36.5 to 33.9. A `callv` site keeps the lambda its calls ran (the function literal's record, its streams and module); the interpreter's call checks the closure's record against it before resolving anything, and compiled code runs the lambda's body in place behind the same check, its capture loads reading the closure's cell; an exit from inside it opens the lambda's frame with its closure and captures. A lambda call 39.9 to 34.7 ns interpreted and 32.2 to 5.3 compiled (JVM JIT 3.5). | `lambda_call` near a static call's cost; compose frames measured. | done |
| `jit/types` | The kind of each register where every path agrees on it, from a forward pass over a function's blocks: a constant's, a parameter's or a callee's declared non-null primitive type, a field whose seed is a primitive, what an arithmetic op or a conversion makes, an instance `new` makes. Compiled ops skip the tag checks the kinds prove, and values stay in machine registers within a block and are written back before any hand-off. Done: the pass (`kinds.zig`) over every path through the root's ops, whether they run compiled or in their handlers, with constants, a parameter's declared primitive type (the bridge names it on the IR parameter; the compiled load checks it), arithmetic, compares, conversions and moves; ops leave out the tag checks and tag stores it proves, and pick an Int or a Long arm alone; an entry into compiled code from outside first checks the kinds the code from there relies on before it writes those registers again (a backward pass over the edges compiled code takes), and runs the op in its handler when one differs. A register's words are read and written whole: this core serves a load from its store buffer only when the load and the store are one size. The same pass finds the registers every path has written, whose write marks compiled code leaves as they are. Each block's entry span comes from the table built with the function's streams (`spanmap.entrySpans`): compiled edges store the span words their op carries, only for a target whose entry span differs by path, and nothing is stored on the way to a handler. On AArch64 a loop keeps its registers of one integer kind throughout in machine registers the handlers' convention leaves free (x7, x8, x13, x4, x5): a loop is the natural loop of the back edges to one head (an edge to a block on the depth-first path to its source, not merely one laid out earlier), and each block is in the region of the innermost loop holding it, so an inner loop keeps its own pins whatever its outer loop's head has not yet written; an edge into a region loads them from the frame, an edge out and every way to a handler writes them back (a tag stays its kind in the frame all along), an entry from outside checks their tags and loads them, and a host call compiled code makes writes them back and loads them again. A template's write of another kind to a pinned register fails the compile, which runs again without pins (`unpinned=` in the stats). A callee compiled in place has kinds of its own, its parameters taking the kinds its call's arguments have (the root relies on those at the call; a callee is only ever entered from its call), so its ops leave out the checks those prove (`known_in_place=` in the stats): a member call 6.99 to 6.83 ns; the chained adds of a five-argument call 7.97 to 8.7, their results now going to memory and straight back with no check between. A loop keeps its temporaries too, registers it writes before it reads them each turn (unwritten at its head on the way in), where the register is live on the way into none of the loop's blocks nor where a catch starts (the IR's liveness), and every op of the loop writing it writes its kind (a kind the pass calls unwritten says only that some path has not written it, and a move of such a register writes what the pass cannot tell): on the way into the loop each one's frame tag is its kind and its write mark set, as the ops writing it would leave them, and an entry from outside before its write sets them rather than checking them; a call's argument run and a `new`'s count as uses when the loop chooses what to keep. With the JIT, ns: static call 3.00 to 2.53, five-argument call 8.8 to 7.6, `list[i]` 3.99 to 3.60, lambda call 3.33 to 3.13, field read 2.46 to 2.33. Left: a field's seed, a callee's return type; a callee's registers in machine registers; pins on x86-64, whose free registers are all the handlers', through callee-saved registers saved at each entry. | Loops of known kinds with no tag checks. | in progress |
| `jit/fields` | A field access is a plain 16-byte load or store, as the JVM's of a field not `@Volatile` is, where the processor copies 16 aligned bytes in one access: no tearing, so no sequence to check. A class with a `@Volatile` property (`kotlin.concurrent.Volatile` or `kotlin.jvm.Volatile`, its own or an ancestor's), the klio atomics' own classes among them, keeps the ordered protocol (the slot sequence, acquire loads, release stores); bit 31 of an instance's sequence says which, set when it is made. A plain store of a reference follows a store-store fence, so an object is seen fully made wherever it is published through a field. Done: AArch64 with LSE2 (a build whose target has it, as every macOS one does), in the interpreter and compiled code. Left: x86-64 with AVX, and AArch64 builds for a baseline processor (Linux), which need the choice made at startup. | Member, virtual and interface calls and field loops near the JVM JIT's. | in progress |
| `jit/opt` | The optimizing tier: typed SSA from the IR of hot functions, small callees inlined (with their frames kept for stack traces and deoptimization), linear-scan register allocation, deoptimization to the baseline code. | Compose frames within reach of the JVM with its JIT. | open |
| `jit/alloc` | Allocation and field writes (the write barrier) in compiled code. Done: `new` of a class whose constructor only stores its parameters bumps the region hole and copies the class's template (`plans/heap.md`), and `new` of a primitive array with a size bumps it with its elements zeroed (`IntArray(4)` 92 to 8.7 ns). An instance takes its identity number the first time something asks (`hashCode`, `toString`, an identity-keyed map), as the JVM takes an identity hash, so `new` touches no counter every allocating thread shares. Then: an instance that never leaves the function (only its fields read, never stored, passed, returned or compared by identity) is not made, its fields' values used in place. | Allocation near the JVM JIT's. | in progress |

## Log

- 2026-09-28: plan. The interpreter's review and the JVM-with-JIT
  reference are in `plans/interpreter-speed.md`.
- 2026-09-28: `jit/memory`. The x86-64 Linux container runs under qemu's
  user emulation here, which crashes on any Zig test binary (a trivial one
  too), so x86-64 is checked by its code under Rosetta and the Linux mapping
  by aarch64 Linux.
- 2026-09-28: `jit/threaded`. With every function compiled at its first
  entry the gate is green but for one corpus program,
  `compose_window_accessibility`, whose output differed once and never in
  32 reruns (16 of them four at a time) and three more corpus runs; the
  Compose window family, which the gate skips on an unchanged tree, passes
  20 of 20 run fresh (`UI_GATE_NO_CACHE=1`). The list scene compiles 4,176
  functions into 1.6 MB and runs 2.13 to 3.48 ms a frame: two jumps more
  per op, before any op runs natively. The handlers' fixed calling
  convention costs the interpreter nothing measurable.
- 2026-09-28: `jit/ops`, first ops. `mb_ops.kt` with the JIT on against
  off (default threshold), ns: counted loop 8.7 to 3.0 (JVM interpreter
  8.96, JVM JIT 1.61), field read 10.9 to 4.1 (1.53), long arithmetic 11.1
  to 3.6 (2.10), `when` over an Int 25.1 to 6.7 (2.12), value class `==`
  19.2 to 8.5, static call 25.8 to 19.7 (19.5 interpreted); calls 1.2x to
  1.35x faster, double arithmetic unchanged. Compose frames barely move
  (list 2.13 to 2.23): their code is mostly calls, and a call from compiled
  code still goes through the interpreter's call and return and a `jit`
  dispatch each way. Compiling is 25 ms for all 4,176 functions of the list
  scene. A function the compiler declined was compiled again at every entry
  until its count was made a stop mark: 123,000 attempts, 17 s, in one run.
- 2026-09-28: `jit/ops`, floats, direct entry and the native share. A
  field read compiled with `ldar` ran 2.4x slower than the handler's plain
  loads on the canvas scene; the build CPU's `ldapr` (Apple's cores have
  it) takes the acquire loads now. Code that is mostly handler calls costs
  more than the interpreter it replaces (code size, two jumps per op), so a
  function compiles only when 70 percent of its ops run natively: canvas
  8.1 to 7.2 ms a frame (JVM interpreter 9.69, JVM JIT 2.01), list 2.06 to
  2.04, recompose unchanged. `mb_ops.kt`, ns: counted loop 3.1 (JVM JIT
  1.61), field read 4.2 (1.53), long arithmetic 3.6 (2.10), double
  arithmetic 7.0 (2.57), `when` over an Int 6.7 (2.12), static call 19
  (JVM interpreter 19.5). Still behind the JVM's interpreter: member,
  virtual and interface calls, a virtual getter, `IntArray` allocation;
  compose frames are calls, handler work and field reads, which the
  optimizing tier and `jit/alloc` address. Open: `compose_material3_icon`
  exited on an abort once with every function compiled and did not recur
  in 60 targeted runs and six corpus runs.
- 2026-09-28: `jit/calls`, callees in place. `mb_ops.kt` with the JIT,
  ns: static call 24.5 to 4.9 (JVM JIT 2.03), five-argument call 26 to
  9.6, member call 35 to 16, virtual call 32 to 20, virtual getter 28 to
  14, interface call 30 to 17. A function compiled during its first loop
  never saw its later loops' call sites run, so their caches were empty and
  nothing was compiled in place; such a site now counts its runs and the
  function compiles again. The list scene compiles nothing that pays: a
  function it calls once a frame reaches 300 entries in the run, and a
  lower threshold makes it slower.
- 2026-09-28: more ops, intrinsics. `KLIO_JIT_CENSUS` counts, as they run,
  the calls compiled code still makes and why: the hottest were host
  functions of a few instructions (`Any.hashCode`, 6.5 million runs in the
  300 changing texts, then array sizes and `Long.hashCode`). Frame ms, JIT
  off against on: 2,000 circles 8.26 to 6.33 (JVM JIT 2.01), 300 changing
  texts 81.3 to 69.5 (7.54), list 2.05 to 2.05 (0.93). What the 300
  changing texts still calls: callees too large to compile in place
  (`ThreadMap.find`, a comparator, `SortedSet.swap`), host functions that
  do real work (`HashMap.put`), getters over `Array<T>` reads. A call that
  stays a call costs about 20 ns (frame, activation, window, write mask),
  ten times a compiled call on the JVM; allocation 56 ns against 2.6.
- 2026-09-28: code layout. CPU counters on the 300 changing texts, JIT
  off against on: useful work 37 to 33 percent of cycles, the back end's
  stalls 36 to 35, speculation lost 16 to 9 (the JIT halves mispredicts),
  and the front end's delivery 10 to 23: the compiled code (5.4 MB for
  about 660 functions, eight times their streams) misses in the
  instruction cache. Compiling fewer functions (thresholds up to 20,000)
  changes nothing, so it is the hot code that is large. The assemblers now
  have a cold section placed after all the hot code: each op's common path
  (Int arithmetic and compares, an instance's type test, an in-range
  parameter, a young instance's field store, an IntArray's element) falls
  through, and its other paths, the fused constant ops' second op and the
  slow stubs go cold; an edge to the op laid out next, and a callee's
  return to the op after its call, fall through. Front-end stalls 23.1 to
  21.9 percent, the 300 changing texts 68.5 to 67.1 ms. A cold template
  emitted while the code is cold already (the op behind a fused constant
  compare) jumps over its out-of-line part: without it the common path
  fell into it, which hung `ktor_compression` with every function
  compiled.
- 2026-09-28: stores of Int, Long and Double arrays, static loads,
  `Float.fromBits`, `Double.fromBits`, `toRawBits`, division and
  remainder by a constant other than 0 (by -1 a negation, which `idiv`
  would trap on). A constructor leaf `new` just made stores its fields
  plainly (no other thread can reach the instance): allocation 58 to 53
  ns compiled, 65 to 57 interpreted. `mb_ops.kt` with the JIT, ns: value
  class make 6.9 (34 interpreted), value class method 9.5 (53), `when`
  over an Int 6.6 (24.5), array read 4.7 (15.4), `ULong` 6.5 (24.2);
  still far from the JVM with its JIT: allocation 53, a lambda call 34,
  `List.get` 34, `HashMap.get` 77 and 213, `StringBuilder` 129, a string
  template 231. Frame ms, JIT off against on: circles 8.24 to 6.25, 300
  changing texts 81.8 to 66.5, list 2.04 to 1.95.
- 2026-09-29: where the 300 changing texts spend the main thread with the
  JIT: compiled code 25 percent, calls that stay calls 16, host functions
  16 (hash map `put`, `remove` and `get` over instance keys 6.4 of it,
  each hashing and comparing its key through a call into the VM and
  allocating its bucket's candidates), allocation 15 (a two-field object
  is 224 bytes, 3.5 cache lines written per `new`; `plans/interpreter-speed.md`
  `alloc/cell-size`), Skia and text 14, handlers of code not compiled 5.5,
  marking 5. Compiled now: stores into `Array<T>` (the exclusive lock by
  compare-and-swap, cleared by an atomic and), Boolean `and`, `or` and
  `xor`, a list's size, element and store, Int and Long rotations and bit
  counts. `list[i]` 35 to 12.9 ns, most of the rest the list's shared lock.
  Frame ms, JIT on: 300 changing texts 67.1 to 65.0 (84.2 off), circles
  6.1 (8.4), list 1.9 (2.1). A lazily decoded function body read on one
  thread while another published it could be seen with its length and
  without its blocks, which crashed `tl_pool_timer_release` about one run
  in thirty with every function compiled; every runtime reader now goes
  through the publication flag.
- 2026-09-29: host calls, strings, closures, instances. A host call whose
  native is a stdlib function, or a member that only wraps one, calls it
  straight from the handler (32 to 22.5 ns for a trivial one; the layers
  it skips measured one at a time: the keepalive 3.1 ns, the host view
  2.1, the receiver memo 0.5, the leak tracker 0.4, the rest four nested
  calls). Hash maps and sets over instances hash and compare an identity
  key with no call into the VM. `x!!` and `lateinit` reads are ops of
  their own. A string template's pieces join in one allocation, and a
  string holds its bytes in its cell (a three-piece template 224 to 129
  ns). A closure points to its function literal's record instead of a
  closure-table slot and holds its captures in its cell (making and
  calling a lambda 290 to 91 ns). An instance carries no field it does not
  use (a two-field object 224 to 160 bytes). Frame ms, JIT on against the
  day's start: 300 changing texts 67.0 to 57.6 (JIT off 83.4 to 80.4),
  circles 6.17 to 5.83, list 2.08 to 2.05. What the 300 changing texts'
  main thread does now: compiled code 27 percent, calls that stay calls
  16, allocation 12, host functions 11, marking 4. More in place does not
  pay: a callee limit of 1,000 words for 250 leaves 20 percent fewer calls
  and exits and the same frame time, since a callee in place leaves its
  code at every call it cannot compile in place, and the frames it then
  needs cost what the call saved.
- 2026-09-29: `jit/fields` on AArch64. With the JIT, ns: member call 16.7
  to 8.9, field write 7.7 to 2.7, field read 4.3 to 3.9, object allocation
  18.6 to 11.4 (JVM JIT 2.3, 1.1, 1.5, 2.7); without it field write 8.9 to
  8.2, the rest level. Virtual and interface calls did not move (14.6 and
  14.3): their time is the dispatch, not the receiver's fields.
- 2026-09-29: `Array<T>` reads with no lock. With the JIT, ns: virtual
  call 14.8 to 10.8, virtual getter 14.2 to 7.3, interface call 14.3 to
  9.2, map get with object keys 27.7 to 24.8; without it, each about 2 ns
  less.
- 2026-09-29: map gets and builder appends called straight from compiled
  code, the map's index read under the shared lock, and a bucket array for
  the index. With the JIT, ns: `StringBuilder.append` 46.0 to 29.6,
  `HashMap<Int, Int>.get` 29.5 to 25.9, with object keys 24.6 to 20.8;
  without it the gets 1 to 2 ns less. What a get with the JIT spends now:
  the index walk 25%, compiled code 33%, the intrinsic's dispatch and the
  lock's release 17%, the lock 6%, key hash and equality 15%.
- 2026-09-29: `jit/types`, the kinds pass and whole-word register
  accesses. With the JIT, ns: loop 3.13 to 2.43, static call 4.94 to 4.26,
  member call 8.94 to 8.1, virtual 10.8 to 10.3, interface 9.36 to 8.75,
  lambda 5.25 to 4.4, `Long` math 3.52 to 2.74, a `when` 6.67 to 5.9, an
  `IntArray` read 4.68 to 3.87, `HashMap<Int, Int>.get` 25.9 to 22.8. The
  kinds alone made a `when` slower (6.7 to 7.9): a one-byte tag store read
  back soon after as an 8-byte word waits for the store to drain, and
  removing the checks between them moved the read closer. Storing the tag
  and a 32-bit payload as whole words helped that and hurt calls (9.7 to
  10.7 for five arguments), since a 4-byte read of an 8-byte store waits
  too; reading every register word whole as well answered both.
- 2026-09-29: write marks and spans out of compiled loops. A register every
  path has written keeps its mark, and a block whose entry span every path
  agrees on gets it stored where the code leaves it, not at each edge.
  With the JIT, ns: loop 2.43 to 2.15, static call 4.21 to 3.85, member
  call 8.07 to 7.45, virtual 10.3 to 9.5, interface 8.8 to 8.1, a field
  read 3.47 to 3.0, object allocation 11.0 to 10.3.
- 2026-09-29: loops keep registers in machine registers (AArch64). With
  the JIT, ns: static call 3.85 to 2.97, member call 7.45 to 6.9, virtual
  9.7 to 8.7, interface 8.2 to 7.05, lambda call 4.14 to 3.43, field read
  2.97 to 2.48, `IntArray` read 3.5 to 3.1; the bare loop (`acc += it`)
  stays at 2.15, its `toLong()` temporary still going through the frame
  and its back edge's guard nine instructions. The JIT-forced gate found
  four ways a pin went wrong: two ways in from outside wrote pins back
  before loading them (an op left to its handler, and a call site compiled
  while empty), each now entered past the write-back; the op a `bin_k`
  prefix's handler runs wrote back pins it never loaded and then ran on
  into the next cold code; and a way in before a loop checked nothing of a
  pinned parameter's kind, so a host function answering an Int for a
  `Long` handle got pinned as a Long. Pins now count as kinds every op of
  their loop relies on, and the ktor handles answer Longs.
- 2026-09-30: a function's share of natively compiled ops counts its loops'
  ops, and a loop was every block between a back edge's target and its
  source, with a back edge any edge to a block laid out earlier: a loop's
  exit block counted, and the exit edge made a loop of its own. The code
  after a `StringBuilder` loop (the timing and the print) sent the function
  to the interpreter, 46 ns an append where compiled it is 18. Loops are
  natural loops of back edges found depth-first, for the share and for
  pins alike.
- 2026-09-30: collections made and filled through intrinsics. A list's
  `add(element)`, a map's `put`, its `set` operator and its `size` are
  intrinsics the interpreter runs in place of the host call and compiled
  code calls straight: a plain mutable list or a map keyed by a value that
  compares by its bits or its text, anything else to the host function.
  `new` of a class the host makes (`ArrayList()`, `HashMap()`,
  `StringBuilder()`) calls the constructor's stdlib function straight, as
  a `native` op calls one, where it took the instruction arm and the
  generic host call. With the JIT, ns (JVM JIT, `java -Xint`): an
  `ArrayList` made and four adds 336 to 121 (0.8 with escape analysis,
  688), a `HashMap` made and two puts 291 to 109 (21, 919), a
  `StringBuilder` made, appended twice and read 206 to 181 (31, 1208);
  interpreted 337 to 160, 294 to 138 and 224 to 190. A pooled activation's
  frame is entered writing only what differs from its last call: static
  calls interpreted 26.4 to 26.0 ns.
- 2026-09-30: what is known of an instance. The kinds pass keeps, for a
  register holding an instance, how many slots it is known to have and
  whether they are plain: a `new` of a class a Kotlin constructor makes
  gives its class's slots and plainness, and a field access that passed its
  checks leaves its receiver known to have the slots it reached. A field
  read then leaves out the slot count check and, for plain slots, the
  sequence's flag; a store of a value that is no reference also its write
  barrier and fence. An entry from outside checks the slot count and the
  flag with the tag. With the JIT, ns: member call 6.88 to 5.99, field read
  2.31 to 2.11.
- 2026-10-01: exits that run often. On the 300 changing texts a callee in
  place left its code about 33,000 times a frame (`KLIO_JIT_CENSUS=all`),
  half at a virtual call it could not run there, each opening the frames
  the calls in place would have had. An exit now counts its runs, and at
  1,000 (`KLIO_JIT_EXITS`) its callee is no longer compiled in place
  anywhere (`FuncStreams.exits_hot`) and the function the code came from
  compiles again, eight times at most for this apart from the three for
  stale call sites; the analysis that refuses a callee none of whose
  paths returns in place then refuses its callers too wherever their way
  back runs through that call. Exits over the run 10.0 million to
  97,000; frame ms, medians of six alternating runs: 300 changing texts
  47.6 to 47.0, circles and list level. With a callee limit of 1,000
  words as well, the texts reach 44.8 but the list and circles lose 2 to
  3%, so the limit stays at 250. CPU counters on the texts put 43% of the
  process's cycles in instruction delivery with direct calls and 33%
  without: the compiled code is bound by its size. A return compiled in
  place (the activation closed, the value written and the caller's code
  entered with no handler) took `fib(30)` 32 to 31 ms and the texts 1 to
  2% the other way, its 60 instructions at every return site against the
  handler's shared ones, and is not kept; nor is a direct call kept only
  in loops and self-recursion, which moved the texts 3% one way and the
  circles 2% the other.
