# CPU / EFFICIENCY CAMPAIGN

Goal: drive klio interpreter throughput up the same way the memory campaign drove
RSS down — measure, attribute to a hot path, root-cause, fix, re-verify. No
symptom hiding; match Kotlin semantics exactly.

## Baseline (ReleaseFast, warm image)

- Empty `for i in 0 until 1_000_000 { s += i }` loop: **< 1 s**. Raw loop +
  integer arithmetic dispatch is fine.
- `BooleanArray(1_000_000)` 1M writes + 1M reads: **> 90 s (timed out)**. ~20k
  array element ops/sec.
- 1M / 10M sieve: minutes (dominated by the array access above).

Node/python do these in well under a second; the gap is multiple orders of
magnitude and localized to specific interpreter paths, not raw loop speed.

## Findings

- **F1 — array/list index access is a full member-call dispatch.** `r[i]` lowers
  to `r.get(i)` and `r[i] = v` to `r.set(i, v)` (`ir/lower/expr.zig:322,1797`).
  Each subscript therefore runs the whole `callMemberNamed -> resolve "get"/"set"
  -> stdlibMemberDispatch -> dispatchIntrinsic` machinery (string name compares,
  registry lookups, argument marshalling) instead of a direct indexed load/store.
  This is THE dominant cost for any array/loop-heavy program.

## Plan

1. Fast-path array/list subscript get/set so it bypasses member dispatch — either
   a dedicated IR op emitted when the receiver is a subscriptable builtin, or a
   short-circuit at the top of the call execution path. Measure the win.
2. Re-profile; attribute the next hot path (likely member dispatch generally,
   boxing, or GC safepoints) and repeat.

## Bench suite

`bench/memcompare/{klio,node,py}/` — collections (object/GC), strings
(string/hashmap), numeric (array). Reused as the cross-runtime CPU comparison.
