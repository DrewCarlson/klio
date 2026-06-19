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

- **F1 — array/list index access was a full member-call dispatch. FIXED.** `r[i]`
  lowers to `r.get(i)` and `r[i] = v` to `r.set(i, v)`
  (`ir/lower/expr.zig:322,1797`). Each subscript ran the whole
  `callMemberNamed -> resolve "get"/"set" -> stdlibMemberDispatch` machinery.
  Fix (`ir/eval.zig` `fastIndexGet`/`fastIndexSet`/`fastSubscript`): serve the
  in-bounds Int-index common case with a direct indexed load/store; fall through
  for every other shape. **1M array write+read: >90 s -> 3 s (~30x).**
- **F2 — `Map` is a flat `ArrayList(MapPair)` with linear-scan lookup.** Every
  `get`/`put`/`containsKey` is O(n) (`findKeyIndexBoxed`), so any map-heavy loop
  is O(n²). collections (1000 keys, 1M ops) times out; strings (5000 keys, 500k
  ops) takes 69 s. This is the next big lever — needs a hash index co-located
  with the entries cell (shared across `Value.Map` copies), preserving
  LinkedHashMap insertion order.
- **F3 — core per-instruction dispatch is a heavy constant factor.** A pure
  `while (i<n){ s+=i; i++ }` at 10M = 8.8 s (~880 ns/iter, ~150-200 ns per IR
  instruction) — ~15x slower than CPython on the same loop, ~170x slower than V8.
  Suspect: `execInst` returns a 72-byte `EvalResult` by value per instruction +
  large switch + 64-byte `Value` copies through `frame.read`/`write`. Lower
  priority than F2 (algorithmic) but broadly applicable.

## Baseline comparison (ReleaseFast klio, warm; node 20; cpython 3.14)

| workload | klio | node | python |
|---|---|---|---|
| numeric (10M sieve) | 16.5 s | 0.05 s | 1.2 s |
| collections (1M group) | >180 s (timeout) | 0.06 s | 0.25 s |
| strings (500k wordcount) | 69 s | 0.12 s | 0.19 s |

(numeric post-F1; all three produce byte-identical output.) Memory was tiny and
flat for all three on these — the gap here is CPU, not RSS.

## Plan

1. F1 — array/list subscript fast path. DONE.
2. F2 — give `Map` an O(1) hash index (the biggest remaining lever).
3. F3 — trim core dispatch constant factor (return-by-value, hot-prong order).

## Bench suite

`bench/memcompare/{klio,node,py}/` + `run.sh` — collections (object/GC), strings
(string/hashmap), numeric (array). Cross-runtime CPU + RSS comparison; all
workloads share a seeded LCG and print identical checksums.
