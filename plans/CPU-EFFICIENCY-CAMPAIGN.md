# CPU / EFFICIENCY CAMPAIGN

Goal: drive klio interpreter throughput up the same way the memory campaign drove
RSS down — measure, attribute to a hot path, root-cause, fix, re-verify. No
symptom hiding; match Kotlin semantics exactly.

## Native stack frames (ziglang/zig#23475) — measured 2026-07-13

Zig does not reclaim block-scoped stack allocations: a function's frame is the
SUM of every block's locals, not the max. That hits the interpreter hard because
its hot functions are giant switches and they RECURSE.

Frames in the ReleaseFast binary:

| frame | function |
| --- | --- |
| 26,720 B | `eval.execInst` (per-instruction dispatcher) |
| 18,376 B | `host_call_member.callMemberInnerStatic` |
| 16,584 B | `Value.isRuntimeType` |
| 14,136 B | `host_instances.buildObject` |

**Measured cost: ~21 KB of native stack per interpreted call.** With
`KLIO_MAX_EVAL_DEPTH` lifted, the native stack faults between 8k and 16k Kotlin
frames on the 256 MB `INTERPRET_STACK_SIZE`. The default depth cap (10000) is
therefore *calibrated to the frame size* — that is why the stack is 256 MB.

**It costs stack DEPTH, not throughput.** Reserving stack is one `sub %rsp`, and
pages are only touched where written: shrinking a hot predicate's frame from
16 KB to 0 moved the object-traversal benchmark 1.532s → 1.521s, i.e. not at all.

Fixed: `objcell.raceJitterEnabled` reserved a **16 KB** frame on EVERY call —
`procEnvironHas`'s `[16384]u8` read buffer was inlined into a cached predicate
that the objcell hot paths call constantly. The cold probe is `noinline` now.

### The recursion path is NOT what the symbol table suggests

Ranking functions by their `sub %rsp` prologue is **misleading**: it ranks every
comptime instantiation, including ones never on the hot path. `execInst` looks
like the worst offender (26,720 B) and outlining its 30 arms changes the recursion
ceiling by **nothing** — twice measured. Once a function is JIT'd (the default
`fast` profile enables `jit_func`), the recursive call runs native code ->
`LoopTramp.call` -> `callFunc`, and **`execInst`/`runFrameInner` are not on the
path at all**. A frame-pointer walk at depth proves it; a stack probe in
`runFrameInner` never even fires.

Ground truth comes from two measurements, not from the binary:
- `KLIO_STACK_PROBE` (a frame-pointer walk at a fixed eval depth) — the exact
  frames and their sizes.
- Bisecting the max recursion depth — 256 MB / depth = bytes per interpreted call.

Counter-intuitively the func JIT *halves* the stack: `KLIO_FUNC_JIT=0` drops the
ceiling from 15.3k to 7.4k (34.7 KB/level interpreted vs 17.6 KB/level JIT'd).

**Done:** outlined the trampoline's BULKY non-call sites (field write, subscript,
value call, map get/set) out of `LoopTramp.call` — the frame that actually stays
live across the recursion.

| | max depth | bytes/level | obj-traversal |
| --- | --- | --- | --- |
| before | 15,281 | 17,566 B | 1.510 s |
| after | **17,062** (+11.6%) | **15,732 B** (-12%) | 1.528 s (+1.2%) |

The three TINY hot sites (object move, null test, field read) stay INLINE — they
fire once per JIT'd loop iteration, and outlining them too cost ~3% throughput for
no extra depth. The outlined helper is tag-gated so a member/func site does not
pay a call just to be told the site is not one of its kinds.

**Remaining frames on the path** (Debug frame-walk, innermost first): `callFunc`
8,864 B, `evalWithCapturesChained` 6,272 B, `composableEval` 5,408 B (paid on
EVERY call, even non-composable), `maybeRunHotFunc` 2,944 B. Same treatment
applies; each costs ~1% throughput for ~10% depth, so it is a real trade, not a
free win.

Tried and reverted (do not re-attempt):

- `matchesAny(name, comptime candidates)` to fold the 49 `&.{…}` literals into
  `.rodata`. Does NOT shrink `isRuntimeType`: the 16 KB is the accumulation of
  many small per-arm temporaries, not the literals.
- A pointer-keyed fast path over `field_read_cache` (ClassDef cell address +
  interned name address, instead of hashing the class FQN and the field name).
  Motivated by ~18% of a method-call profile sitting in `mum`/`eqlBytes` and the
  hashmap internals. It is SLOWER (1.509s → 1.537s on the object-traversal
  benchmark): reading the class address needs an extra instance borrow, whose
  refcount traffic costs more than the string hash it saves. The `mum` samples
  are therefore NOT coming from the field-read memo — find the real source before
  optimizing a hash away.

## Completed

- **Value.release ungated under GC (systemic O(n²)) — FIXED.** `release` was not
  gated on `reclaimEnabled()` (unlike `retain`), so under the default tracing GC
  it still ran refcount teardown: releasing a collection whose `strongCount` reads
  1 walked and released EVERY element, and since every member call releases its
  borrowed receiver, a call on an N-element list/map/set did O(N) work — `.add` in
  a loop was O(n²). Gated `release` to a no-op under reclaim-off, the exact dual of
  `retain` (`value.zig`). This was the dominant CPU bug for all default-mode
  programs (list build 5013→506 ms at 60k; collections timeout→12.9 s).
- **F1 — array/list subscript fast path.** `r[i]`/`r[i] = v` lower to
  `r.get(i)`/`r.set(i, v)`; `fastIndexGet`/`fastIndexSet`/`fastSubscript`
  (`ir/eval.zig`) serve the in-bounds Int-index common case with a direct indexed
  load/store and fall through for every other shape. 1M array write+read >90 s → 3 s.
- **F2 — `Map` O(1) hash index.** `MapStore` carries a chained hash index over the
  keys (lazy above a small-map threshold, incremental on put, rebuilt after
  removal; non-hashable keys fall back to scan), preserving LinkedHashMap order;
  the hot lookups (`get`/`getOrPut`/`getOrElse`/`getValue`/`containsKey`/`put`)
  route through `MapStore.find`. strings 69→8.4 s.
- **F5 — packed primitive arrays.** The `Array` variant is a union
  `ArrayStore{ boxed: ValueList, scalars: ObjRef(PrimBuf) }` (`value.zig`); `PrimBuf`
  is a flat scalar byte buffer (1–8 B/elem, GC-traced as a leaf). Element access
  goes through `ArrayData`; subscript fast paths read/write the scalar buffer in
  place; constructors build packed directly (zeroed buffer = the Kotlin default).
  numeric peak RSS 1231 MB → 114 MB, wall −24%. This is also the prerequisite for a
  JIT that indexes arrays natively.
- **Member-dispatch + overload-resolution inline caches.** An instance-method
  cache on `ProgramImage` (class identity, method-name ptr → FuncId), restricted to
  zero-arg calls (pure function of the class), short-circuits `irMethodWalk` for
  getters/`next`/`hasNext`/`toString`/`hashCode`. `pickOverloadCached`
  (host_call_func.zig) memoizes global generic overload resolution keyed by
  `(module ptr, func id, primitive-arg-type signature)` — a `maxOf`/`minOf` loop
  8.02 → 0.98 s. Both preserve correctness (non-primitive args fall through to the
  live scan).
- **Stage-3 JIT shipped** (`src/ir/jit_loop.zig` + the encoder in `src/jit/`,
  behind `KLIO_JIT`). Hot natural loops (header entered ≥64×) and whole functions
  compile to native x86-64 and AArch64: Int/Long/Double/Float arithmetic +
  comparisons (NaN-correct), `Move`/`Const`/`Not`/`UnOp`, packed-array subscripts
  on the F5 scalar buffer, capture cells, numeric conversions, div/mod with
  Kotlin-correct `INT_MIN/-1` and divide-by-zero deopt, natural-loop finding via
  dominance, and an entry guard + OOB deopt so correctness never depends on the
  static type inference. Long arithmetic 12.4 s → 0.21 s (60×); 1e9 IntArray
  increment 104 s → 1.3 s (79×); numeric sieve 7.0 s → 0.75 s. The full program
  set (examples + corpus + fixtures, 800+ programs) is byte-identical JIT on vs off.
- **Bench suite + profiler.** `bench/memcompare/{klio,node,py}/` + `run.sh` is the
  cross-runtime CPU + RSS harness (all workloads share a seeded LCG, print
  identical checksums). `KLIO_PROF` (`src/runtime/prof.zig`) is a SIGPROF +
  ITIMER_PROF statistical PC sampler that symbolizes a by-function histogram at exit.

The two systemic O(n²) bugs (ungated `release`, linear-scan `Map`) and the
per-call constant-factor churn (probe FQNs, member resolution, arg allocation) are
fixed; JIT-amenable arithmetic/array/scan loops are now within a small factor of
node.

## Costed roadmap to close the residual (the three big levers)

The interpreter is at ~CPython class. The remaining gap (numeric ~8× CPython /
~140× node; collections ~40× / ~180×; strings ~33× / ~60×) is constant-factor +
architecture. The still-open levers:

1. **Value shrink 64 B → ~40 B** (helps ALL general code: every copy, append,
   register write, arg move). Max variant is `List` = 56 B, driven by
   `enum_class: ?StringRef` and the `declared_*` slices. KEY FINDING: Zig 0.16 does
   NOT niche-optimize `?ObjRef` (`?StringRef` = 16 B, not 8) — it adds a separate
   tag word. `value.zig` still has `declared_elem`/`declared_key`/`declared_value:
   ?[]const u8` un-niched. To shrink: give `enum_class` a niche (store the cell
   pointer as `?*Cell`, 8 B) and box the three borrowed `declared_*` slices behind
   one niche'd `?*CollDeclared` pointer. `enum_class` is a GC ref, so its trace
   site must move with it (the risk). ~69 access sites; mechanical but touches the
   GC trace. Expected ~10–25% across all benches.

2. **F4 — `iterableItems` snapshots the whole list/set per call.** `snapshotItems`
   (`src/stdlib/implementations/collections.zig`) does a full `dupe`, used by ~39
   ops (`last`, `first`, `map`, `filter`, `forEach`, …), making O(1) ops O(n) and
   any such op in a loop O(n²). Fix pending: read under borrow for the non-callback
   ops; only snapshot when a user callback runs mid-iteration. Low value on its own
   (only hurts those-in-loops).

3. **F3 — core per-instruction constant factor (~150-200 ns/IR-inst).** A pure
   `while (i<n){ s+=i; i++ }` at 10M = ~9-10 s (~900 ns/iter) — ~15× slower than
   CPython, ~170× slower than V8. Reordering the `BinOp` prong to fast-path two
   plain scalars was MEASURED neutral-to-slightly-negative: the cost is not the
   branch count but the per-instruction machinery. After the slim per-inst return,
   the residual is the `execInst` call itself + 64-byte `Value` copies through
   `frame.read`/`write` + the `switch (inst.*)`; the pure mod loop is ~780 ns/iter.
   Closing to node (a JIT) needs a bytecode-VM/register-machine rewrite; within a
   few× of CPython needs shrinking `Value` (64→~16B by boxing the rare large
   variants) + computed-goto/labeled-switch dispatch. Large, separate efforts.

Honest bottom line: node/v8 parity for general code is a JIT problem — no
interpreter (CPython included, itself ~15× node here) reaches it. Lever 1 is worth
landing for the broad constant-factor + memory wins; the interpreter-loop rework
(lever 3) is the parity endgame and is multi-step.

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
`get()` path. So list packing is not the lever; the collections gap is the
cumulative alloc + dispatch + GC-pass-over-the-growing-live-set cost, which only an
unboxed-value + native-collection + generational-heap runtime closes. The
`MutableIterator.remove()` write-through example added during the work is kept as
coverage.

## Tried and reverted (don't re-attempt)

- **Borrowing the intrinsic host instead of cloning** (`makeIntrinsicHost` does 11
  `clone()` + 11 `deinit()` refcount atomics per intrinsic dispatch). Switching to
  the non-owning `VmIntrinsicHost.borrowed(SharedHandles.fromHost(self))` sped
  strings 6.5→5.7s BUT **broke concurrency** (ktor channel `Truncated`, a
  ConcurrentMap thread-hammer integer-overflow panic): a worker thread's intrinsic
  host must hold its own refs so the shared handles outlive the call independent of
  the spawning thread. The clones are load-bearing. A conditional clone (only when
  worker threads exist) is possible but subtle/risky — left.

## Measurement note — high variance environment

Wall-time variance here is ~15% run-to-run (collections swings ~9.6–11.3 s). Wins
below ~15% cannot be reliably distinguished from noise by single runs; validate with
medians of several runs, and prefer levers whose payoff exceeds the noise floor.
The `run.sh` RSS column reads ~1 MB (the /proc VmHWM sampler does not catch these
short fast processes) — trust the prior campaign's RSS figures, not this column.
