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
2. F2 — give `Map` an O(1) hash index (the biggest remaining lever).
3. F3 — trim core dispatch constant factor (return-by-value, hot-prong order).

## Bench suite

`bench/memcompare/{klio,node,py}/` + `run.sh` — collections (object/GC), strings
(string/hashmap), numeric (array). Cross-runtime CPU + RSS comparison; all
workloads share a seeded LCG and print identical checksums.
