# CPU / EFFICIENCY CAMPAIGN

Goal: drive klio interpreter throughput up the same way the memory campaign drove
RSS down — measure, attribute to a hot path, root-cause, fix, re-verify. No
symptom hiding; match Kotlin semantics exactly.

## THE big fix — `Value.release` ungated under GC (systemic O(n²))

`Value.release` was NOT gated on `reclaimEnabled()` (unlike `retain`). Under the
default tracing GC (reclaim off), it still ran refcount teardown: releasing a
collection whose `strongCount` reads 1 (counts are never decremented under GC, so
they read as their init value) walked and released EVERY element. Every member
call releases its borrowed receiver (`CallMember` prong's deferred
`recv.release`), so a call on an N-element list/map/set did O(N) work — `.add` in
a loop was O(n²), `last()`/`first()` O(n) each. Found with a SIGPROF sampler
(internal `clockMonotonicNanos` is useless for profiling — it spins up a
`std.Io.Threaded` per call). Fix: gate `release` to a no-op under reclaim-off,
the exact dual of `retain`. List build 5013→506 ms (60k); collections benchmark
timeout→12.9 s. This was the dominant CPU bug for all default-mode programs.

Lesson: under GC, `retain`/`release` must BOTH be no-ops. A one-sided gate turned
every value drop into a deep O(size) walk.

## Baseline (ReleaseFast, warm image)

- Empty `for i in 0 until 1_000_000 { s += i }` loop: **< 1 s**. Raw loop +
  integer arithmetic dispatch is fine.
- `BooleanArray(1_000_000)` 1M writes + 1M reads: **> 90 s (timed out)**. ~20k
  array element ops/sec.
- 1M / 10M sieve: minutes (dominated by the array access above).

Node/python do these in well under a second; the gap is multiple orders of
magnitude and localized to specific interpreter paths, not raw loop speed.

## Findings

- **F1 — array/list index access was a full member-call dispatch. FIXED.** `r[i]`
  lowers to `r.get(i)` and `r[i] = v` to `r.set(i, v)`
  (`ir/lower/expr.zig:322,1797`). Each subscript ran the whole
  `callMemberNamed -> resolve "get"/"set" -> stdlibMemberDispatch` machinery.
  Fix (`ir/eval.zig` `fastIndexGet`/`fastIndexSet`/`fastSubscript`): serve the
  in-bounds Int-index common case with a direct indexed load/store; fall through
  for every other shape. **1M array write+read: >90 s -> 3 s (~30x).**
- **F2 — `Map` linear-scan lookup. FIXED.** Was a flat `ArrayList(MapPair)`;
  every `get`/`put`/`containsKey` O(n). `MapStore` now carries a chained hash
  index over the keys (lazy above a small-map threshold, incremental on put,
  rebuilt after removal; non-hashable keys fall back to scan), preserving
  LinkedHashMap order. The hot lookups (`get`/`getOrPut`/`getOrElse`/
  `getOrDefault`/`getValue`/`containsKey`/`put`) route through `MapStore.find`.
  strings 69→8.4 s.
- **F4 — `iterableItems` snapshots the whole list/set per call** (`snapshotItems`
  = full `dupe`), used by ~39 ops (`last`, `first`, `map`, `filter`, `forEach`,
  …). Makes O(1) ops O(n) and any such op in a loop O(n²). Fix pending: read
  under borrow for the non-callback ops; only snapshot when a user callback runs
  mid-iteration.
- **F3 — core per-instruction dispatch is a heavy constant factor.** A pure
  `while (i<n){ s+=i; i++ }` at 10M = ~9-10 s (~900 ns/iter, ~150-200 ns per IR
  instruction) — ~15x slower than CPython on the same loop, ~170x slower than V8.
  Reordering the `BinOp` prong to fast-path two plain scalars straight to
  `applyBinop` (skipping the ~6 operator-overload/collection/concat checks) was
  MEASURED to be neutral-to-slightly-negative — the cost is not the BinOp branch
  count but the per-instruction machinery itself: `execInst` returns a 72-byte
  `EvalResult` by value per instruction, the big `switch (inst.*)`, and 64-byte
  `Value` copies through `frame.read`/`write`. A real win needs a dispatch-loop
  rework (shrink/elide the per-inst return value, inline the hottest prongs into
  `runFrameInner`, possibly a narrower `Value`), not local prong tweaks. Deferred:
  larger, GC/ownership-sensitive surgery.

## Baseline comparison (ReleaseFast klio, warm; node 20; cpython 3.14)

| workload | klio start | klio now | node | python |
|---|---|---|---|---|
| numeric (10M sieve) | 16.5 s | 15.9 s | 0.05 s | 1.0 s |
| collections (1M group) | >180 s (timeout) | 12.9 s | 0.06 s | 0.25 s |
| strings (500k wordcount) | 69 s | 8.4 s | 0.12 s | 0.18 s |

(all three produce byte-identical output.) Memory tiny and flat — the gap is CPU.
After F1 (array subscript) + F2 (map index) + the release-gate fix, collections
and strings dropped 14–21×. numeric is now the worst relative gap (no maps/
collections — pure loop + array), bound by the F3 per-instruction constant factor.

## Plan

1. F1 — array/list subscript fast path. DONE.
2. F2 — `Map` O(1) hash index. DONE.
3. release-gate under GC (the dominant systemic O(n²)). DONE.
4. probe-FQN stack buffers (kill per-call allocPrint churn). DONE.
5. member-resolution cache — memoize `(type,name,args-empty)→intrinsic` on the
   shared `ProgramImage`, skipping the per-call probe build + ~6 `lookupIntrinsic`
   borrows. DONE. numeric 14.5→9.4s, strings 7.9→6.7s.
6. stack-buffer dispatch args — `prependReceiver` heap-allocated per call; stack
   buffer for small arities. DONE. collections 12.5→10.6s.
7. slim per-instruction return — `execInst` returned an ~80-byte `EvalResult` by
   value per instruction (its `.ok` always the ignored `.Unit`); now a 1-byte
   `Step{cont,raised}` with control-flow errors stashed on `frame.step_err`.
   DONE. numeric 9.4→8.3s.
8. **F5 — primitive arrays are 64× too big (NEW, MEASURED).** `BooleanArray`/
   `IntArray`/… are stored as `ArrayList(Value)` — 64 bytes per element. A
   `BooleanArray(10M)` is ~1.2 GB (measured numeric peak RSS = 1231 MB; node's
   `Uint8Array(10M)` is 10 MB). Catastrophic for any primitive-array code: huge
   alloc + zero + GC-trace. FIX: a packed primitive backing (real `[]u8/i32/f64`
   …) behind `Value.Array` when `prim != null`; `fastIndexGet/Set` + the array
   intrinsics box/unbox at the boundary; GC traces nothing (no `Value`
   out-edges). Large (threads through ~30 array intrinsics) but the single
   highest-value remaining change for array workloads — memory AND cpu.
9. F4 — `iterableItems` snapshot copies the whole list per call. PENDING (makes
   `last`/`first` O(n); low value — only hurts those-in-loops).
10. F3 — core per-instruction constant factor (~150-200 ns/IR-inst). After the
   slim return, the residual is the `execInst` call itself + 64-byte `Value`
   copies through `frame.read`/`write` + the `switch (inst.*)`. The pure mod loop
   is ~780 ns/iter. Closing to node (a JIT) needs a bytecode-VM/register-machine
   rewrite; within a few× of CPython needs shrinking `Value` (64→~16B by boxing
   the rare large variants) + computed-goto/labeled-switch dispatch. Large,
   separate efforts.

## Tried and reverted (don't re-attempt)

- **Borrowing the intrinsic host instead of cloning** (`makeIntrinsicHost` does 11
  `clone()` + 11 `deinit()` refcount atomics per intrinsic dispatch). Switching to
  the non-owning `VmIntrinsicHost.borrowed(SharedHandles.fromHost(self))` sped
  strings 6.5→5.7s BUT **broke concurrency** (ktor channel `Truncated`, a
  ConcurrentMap thread-hammer integer-overflow panic): a worker thread's intrinsic
  host must hold its own refs so the shared handles outlive the call independent of
  the spawning thread. The clones are load-bearing. A conditional clone (only when
  worker threads exist) is possible but subtle/risky — left.

## Status (vs start of campaign)

| workload | start | now | speedup | python | node |
|---|---|---|---|---|---|
| numeric | 16.5 s | ~8.3 s | 2.0× | 1.0 s | 0.06–0.1 s |
| collections | >180 s (timeout) | ~10.7 s | >17× | 0.25–0.30 s | 0.06 s |
| strings | 69 s | ~6.5 s | 10.6× | 0.18 s | 0.10 s |

numeric also has a **1.2 GB peak RSS** (F5: primitive arrays as boxed `Value`s);
fixing F5 cuts that to ~10 MB and speeds construction/access.

The two systemic O(n²) bugs (ungated `release`, linear-scan `Map`) are fixed —
those were what made map/collection code pathological. Array subscript, probe
churn, member-resolution, and per-call arg allocation fixed too. Remaining gap:
~9× CPython (numeric), ~35–45× (map/string), ~100–200× node. That residual is the
interpreter constant factor (F3) — a tree/register interpreter vs a JIT. Node
parity is not reachable without a bytecode-VM / register-machine + (ultimately)
JIT rewrite; getting within a few× of CPython needs shrinking `Value`/
`EvalResult` + computed-goto dispatch. Both are large, separate architecture
efforts, not bug fixes.

## Bench suite

`bench/memcompare/{klio,node,py}/` + `run.sh` — collections (object/GC), strings
(string/hashmap), numeric (array). Cross-runtime CPU + RSS comparison; all
workloads share a seeded LCG and print identical checksums.

## Profiling tool — `KLIO_PROF`

`src/runtime/prof.zig`: SIGPROF + ITIMER_PROF statistical PC sampler. Records the
interrupted RIP into a signal-safe fixed buffer (one atomic add + one store, no
alloc), symbolizes a by-function histogram at exit (`std.debug` DWARF). `KLIO_PROF=1`
(default 1 kHz) or `KLIO_PROF=<usec>`. ReleaseFast inlines the interpreter core, so
~half the samples land in `<unknown>` (inlined `execInst`/`runFrameInner`); the named
remainder still attributes the constant-factor costs precisely.

## Session — member-dispatch inline cache

Profiling collections (41× CPython, member-call bound) showed the cost was NOT the
two systemic O(n²) bugs (already fixed) but **per-call user-method resolution**:
every `inst.method()` ran `irMethodWalk`, which re-walked the class hierarchy
(linear `classIdByFqn` + class-by-name + method-by-name string scans) and
heap-allocated a work queue + seen-set, *per call*. A method in a 1M-iteration loop
(`rng.next()`) paid full resolution 1M times — `classHasUserMethod`/`classIdByFqn`/
`eqlBytes` dominated the named profile.

Fix (committed, green): an inline cache on `ProgramImage`,
`instance_method_cache: (class identity, method-name ptr) → FuncId`, populated after
an unambiguous resolve and consulted at the top of `irMethodWalk`. Restricted to
**zero-arg calls**: with no args there is no overload/arg-type discrimination
(`pickMethodOverload` declines a sole candidate only by arity or definite arg-type
mismatch — neither applies), so the result is a pure function of the class. Covers
the member-heavy hot path (getters, `next`, `hasNext`, `toString`, `hashCode`).
`irMethodWalk` was split into `resolveInstanceMethod` + `invokeMethodFuncId` so the
cold and cached paths share one invoke tail; the tail now builds the frame arg list
directly (`[receiver]++args` in one alloc) for fully-applied non-vararg calls,
dropping the `prependReceiver` scratch slice. collections ~11.9→~9.9 s, strings
~6.5→~6.3 s. (Bug found + fixed during this: the first cut keyed on arity and
short-circuited the per-instance binding/anon probes — broke ktor ContentNegotiation
content-type, because `anonMethodDispatch` depends on instance state
`__enum_entry_class__`. Zero-arg-only + caching inside the walk after the probes is
the sound form.)

## Measurement note — high variance environment

Wall-time variance here is ~15% run-to-run (collections swings ~9.6–11.3 s). Wins
below ~15% cannot be reliably distinguished from noise by single runs; validate with
medians of several runs, and prefer levers whose payoff exceeds the noise floor.
The `run.sh` RSS column reads ~1 MB (the /proc VmHWM sampler does not catch these
short fast processes) — trust the prior campaign's RSS figures, not this column.

## Costed roadmap to close the residual (the three big levers)

The interpreter is at ~CPython class. The remaining gap (numeric ~8× CPython /
~140× node; collections ~40× / ~180×; strings ~33× / ~60×) is constant-factor +
architecture. Three levers, in dependency order:

1. **Value shrink 64 B → ~40 B** (helps ALL general code: every copy, append,
   register write, arg move). Max variant is `List` = 56 B, driven by
   `enum_class: ?StringRef` and the `declared_*` slices. KEY FINDING: Zig 0.16 does
   NOT niche-optimize `?ObjRef` (`?StringRef` = 16 B, not 8) — it adds a separate
   tag word. To shrink: give `enum_class` a niche (store the cell pointer as
   `?*Cell`, 8 B) and box the borrowed `declared_elem`/`declared_key`/`declared_value`
   slices behind one niche'd `?*CollDeclared` pointer. `enum_class` is a GC ref, so
   its trace site must move with it (the risk). ~69 access sites; mechanical but
   touches the GC trace. Expected ~10–25% across all benches.
2. **F5 packed primitive arrays — DONE** (committed, full suite green). The `Array`
   variant is now a union `ArrayStore{ boxed: ValueList, scalars: ObjRef(PrimBuf) }`
   (`PrimBuf` = a flat scalar byte buffer, 1–8 B/elem; GC traces it as a leaf). A
   union (not two fields) so every access site is compiler-flagged — no silent
   "read packed as empty boxed". Element access goes through `ArrayData`
   (`len`/`get`/`set`/`snapshot`/`writeBack`/`deinitStorage`); subscript fast paths
   read/write the scalar buffer in place; constructors build packed directly (zeroed
   buffer = the Kotlin default for every primitive) so a 10M `IntArray` never
   materializes a boxed list. Result on numeric: **peak RSS 1231 MB → 114 MB
   (−91%), wall 8.8 s → 6.6 s min (−24%)** (cache-resident, no per-element
   retain/release). This is also the **prerequisite for a JIT that indexes arrays
   natively** (it can now read a flat `[*]u8`/`[*]i32`, not a 56-byte Value).
3. **JIT stage 3 — native hot loops** (`src/jit/jit.zig` encoder is done + tested:
   ALU, `[base+disp32]` mem, labels, jumps, native-loop proof). The ONLY path to
   node-class on hot loops. Design (matches JIT-DESIGN.md, keeps the "never poke the
   Value union from machine code" rule): detect a hot loop via back-edge counting in
   `runFrameInner` (seam: the `.Branch`/`.Goto` terminator switch); for a compilable
   loop (supported insts only: Int/Long `BinOp`, comparisons, `Move`, `Const`,
   internal branches; later array `Index`/`IndexSet` once F5 lands), unbox the live
   regs Value→i64 into a scratch array **in safe Zig**, run native code over the i64
   scratch (no Value-layout dependency), rebox in Zig on exit, deopt to the
   interpreter on a guard miss. Gate behind `KLIO_JIT` (off → tree stays green) until
   coverage is proven. First increment compiles pure-arithmetic loops; real benches
   need F5 first.

Honest bottom line: node/v8 parity for general code is a JIT problem — no
interpreter (CPython included, itself ~15× node here) reaches it. Levers 1–2 are
worth landing for the broad constant-factor + memory wins; lever 3 is the parity
endgame and is multi-step.

## Stage-3 JIT — DONE (hot loops compile to native; KLIO_JIT)

`src/ir/jit_loop.zig` (+ encoder in `src/jit/jit.zig`), wired into `runFrameInner`
behind `KLIO_JIT` (off by default). A hot natural loop (header entered ≥64×)
compiles to x86-64 and runs natively, eliminating Value boxing, member dispatch,
and per-instruction interpreter overhead.

- **Register model**: each IR register is an i64 slot in a scratch file; emitted
  code uses rax/rcx/rdx scratch per op (no register allocator). The win is from
  killing boxing/dispatch, not from allocation.
- **Supported**: `Const`/`Move`/`BinOp` (Int/Long +,−,*,/,%, comparisons; Int
  results `movsxd`-normalized for 32-bit wraparound; **Double +,−,*,/ and
  comparisons via SSE2**), `Not`, `UnOp` (Neg/Inc/Dec/Plus on integers),
  packed-array subscripts (get/set on the F5 scalar buffer, SIB load/store +
  bounds check; **`DoubleArray` elements move as raw 8-byte `b64`**), capture
  cells (`CellGet`/`CellSet` on a `var` boxed by closure, incl. `Double`),
  `Goto`/`Branch`, `Trace`. Subscripts match both the `CallMember "get"/"set"`
  lowering (how `a[i]` actually lowers) and `Index`/`IndexSet`.
- **Double (f64)**: an f64 IR register keeps its bit pattern in its i64 slot and
  moves in/out with `movsd`; arithmetic is `addsd`/`subsd`/`mulsd`/`divsd`
  (IEEE — `/0.0` yields ±Inf/NaN, no deopt). Comparisons use `ucomisd` with
  NaN-correct `setcc`: `<`/`<=` via operand-swap + `seta`/`setae`, `>`/`>=`
  direct, `==` = `sete && setnp`, `!=` = `setne || setp` — so any comparison with
  NaN is false except `!=` (matches Kotlin). Result on a `DoubleArray` sum/scale
  loop: **8.9 s → 0.30 s (≈30×)**, node-class.
- **Numeric conversions** (`x.toDouble()`/`toLong()`/`toInt()`, which lower to a
  zero-arg `CallMember`): int→double via `cvtsi2sd` (always exact — matches
  Kotlin), and int width changes via a bit copy (i32→i64 no-op; i64→i32 truncates
  at rebox = `Long.toInt`'s low-32 semantics). **double→int is left to the
  interpreter** (`cvttsd2si` clamps differently from Kotlin on NaN/overflow). A
  non-numeric receiver (e.g. `"123".toInt()` string parsing) is typed `unknown`
  and bails. This unblocks mixed int/double loops — `sum += i.toDouble()*0.5`
  goes **11.9 s → 0.21 s (≈57×)**.
- **Capture cells**: a `var` captured by a nested lambda is a boxed `Value.Cell`.
  The loop body's `CellGet`/`CellSet` are compiled by caching the box's scalar in
  the cell register's own slot for the native run (unboxed at entry, written back
  through the box at exit). Sound because no call or GC runs inside a JITted loop,
  so the box is unobserved by anyone else; aliased boxes and cells touched as a
  plain scalar are rejected. This unblocked the numeric sieve's outer prime-scan
  (its `count`/`acc` vars).
- **Div/Mod**: `cqo`+`idiv`; divide-by-zero deopts to the faulting instruction
  (interpreter throws the same `ArithmeticException`); divisor `-1` is
  special-cased to dodge the x86 `INT_MIN/-1` `#DE` while matching Kotlin's
  wrapping result.
- **Types**: whole-function static inference (i32/i64/bool/unit/null); arrays
  specialized on the kind observed at first compile. A runtime entry guard bails
  to the interpreter if a live-in register type / array kind mismatches, so
  correctness never depends on the inference.
- **Loop finding**: natural loop of true back-edges only — the header must
  **dominate** the source (computed as "unreachable from entry while avoiding the
  header"). Without this, an inner loop was widened to include its enclosing
  loop's pre-header, and OSR-entering mid-iteration re-ran the outer prefix
  (the +63 bug). Fixed.
- **Deopt**: an out-of-bounds index returns `(block,inst)` and the interpreter
  resumes at the faulting instruction, throwing identically. Loop blocks in a
  try-region are rejected (deopt resumes mid-block).
- **Results** (`KLIO_JIT=1`, min): 100M-iter Long arithmetic 12.4 s → 0.21 s
  (60×); 1e9 IntArray increment 104 s → 1.3 s (79×); numeric sieve bench 7.0 s →
  0.75 s (9.3×) — both the inner marking loop and the outer prime-scan now JIT
  (capture-cell support unblocked the scan's `count`/`acc`). On the JIT-amenable
  arithmetic/array/scan loops klio is now within a small factor of node.
- **Validated**: full `zig build test` green with the JIT OFF and ON. The e2e
  corpus test runs every example through the native tier (JIT forced on via a
  test-only toggle) and asserts the same checked-in expected output. The full
  program set (examples + corpus + fixtures, 800+ programs) produces byte-
  identical output with the JIT on vs off, including divide-by-zero, `MIN/-1`
  wrap, and OOB deopts.
- **Next coverage** (not blocking): `Float` (f32) arithmetic/arrays (needs the
  `ss` SSE forms + f32↔f64 conversions); sound `Double.toInt()`/`toLong()` (range
  + NaN clamping to match Kotlin); calls via a trampoline (stage 4 —
  collections/strings are call-bound). The harness (guard + deopt + bail) is in
  place.

## collections/strings gap — data-driven analysis (not a quick fix)

The loop JIT makes pure compute/array/scan loops node-class. The residual gap is
the object-graph benches (`collections` ~9.5 s vs node 0.07 s, ~140×). Five
experiments pinpoint the cost as **architectural**, with no incremental win:

- **Slab free-cache** (retain emptied 256 KB slabs instead of `munmap`): no help
  — during the build the live set grows monotonically, so slabs are not emptied/
  refilled. Reverted.
- **Large-region (`>MAX_SMALL`) mmap cache** (a `ValueList` backing is 56 B/elem,
  so a >146-elem list lives on the direct-`mmap` path and `munmap`s on each
  growth doubling): clean min-of-3 A/B showed it *slower* (9.5 → 10.3 s) — the
  mmap/munmap churn is not the bottleneck. Reverted.
- **Dispatch auto-member early-out**: removed `classHasUserMethod` from the hot
  path (confirmed gone from the profile) but wall unchanged — the dispatch chain
  is ~5 % spread, not a dominant cost. Kept (correct cleanup), not a perf win.
- **GC threshold → 1 GB** (GC ~never runs): wall did **not** drop — GC marking is
  not the dominant cost, so a generational GC is not the high-leverage lever.
- **Profile** (`KLIO_PROF`): no single dominant hotspot. ~43 % inlined
  `<unknown>`, then `addOneAssumeCapacity` ~11 % (copying 56 B `Value`s per list
  append), dispatch ~5 %, GC cell init/atomics ~5 %. High `sys` is fresh-growth
  `mmap` as the heap grows to hold 1M retained records.

Conclusion: node's advantage here is the sum of unboxed values + native
collections + a bump-allocated generational heap — i.e. an object-model + GC
rewrite, not a tuning tweak.

**F6 (packed primitive lists) was built and measured — no win; reverted.** The
sound design (shared-backing `ListData` → `ObjRef(ListBuf)`, `ListBuf =
union{ boxed: ArrayList(Value), scalars: PrimBuf }`, upgrade-on-first-add packing,
`MutableIterator.remove` write-through via an `Iterator.list_src`) was implemented
behind a measurement gate. Result: collections best 9.2 s vs 9.5 s baseline —
within noise. Root cause the premise was wrong: a boxed list of a primitive
ALREADY stores its scalars inline in the `ArrayList` (`.Int`/`.Long` are inline
`Value`s, not heap cells), so GC tracing is already ~free per element and packing
only saves minor memcpy bandwidth — offset by per-read boxing on the packed
`get()` path. `addOneAssumeCapacity` (11 % of samples) is call-count + small-copy
overhead, not heap-cell churn. So list packing is not the lever; the collections
gap is the cumulative alloc + dispatch + GC-pass-over-the-growing-live-set cost,
which only an unboxed-value + native-collection + generational-heap runtime
closes. The `MutableIterator.remove()` write-through example added during the work
is kept as coverage.
