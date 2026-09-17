# Every pack suite to 100%

The upstream test suites klio runs, what each one scores today, and what
stands between it and a clean sweep. The counts are the runners' own, taken
on ReleaseSafe (`zig build klio-harness`) at the commit named below; the
static `@Test` totals differ from them because an abstract base class's
cases re-run under each concrete subclass.

## Where the suites stand

Measured 2026-09-17. A suite with no failures is at 100% of what it runs.

| Suite | Runner | Passed | Failed | Gate baseline |
|-------|--------|-------:|-------:|--------------:|
| Kotlin stdlib commonTest | `scripts/commontest-sweep.py` | 2466 | 0 | 2301 |
| androidx.collection | `klio-census androidx_collection` | 1841 | 0 | 1841 |
| Compose runtime (plugin) | `itest-compose_plugin_commontest` | 1402 | 2 | 1385 |
| kotlinx.coroutines core | `klio-census coroutines` | 1299 | 0 | 1299 |
| kotlinx.io | `klio-census io` | 1191 | 0 | 1191 |
| kotlinx.serialization json | `klio-census serialization_json` | 747 | 0 | 747 |
| kotlinx.datetime | `klio-census datetime` | 519 | 0 | 519 |
| io.ktor | `klio-census ktor` | 464 | 0 | 464 |
| Compose UI | `klio-census compose_ui` | 452 | 0 | 452 |
| kotlinx.serialization core | `klio-census serialization` | 138 | 0 | 138 |
| kotlinx.atomicfu | `klio-census atomicfu` | 67 | 0 | 67 |
| kotlinx.coroutines test | `klio test <pack> --test-group test` | 73 | 0 | none yet |

The stdlib `js/` directory stays out: klio is its own runtime and claims
neither the JS backend's tests nor its intrinsics, so `stdlib_commontest`
skips the directory by name and it counts toward nothing.

## What is left

**Compose runtime, two failures, both wall-clock.**

| Test | Behaviour |
|------|-----------|
| `CompositionTests.derivedStateOfLeak` | 31 300 recompositions per composer, ~3.2 ms each |
| `SnapshotStateMapTests.concurrentMixingWriteApply_set` | 8.3 s alone against a 10 s budget; fails under gate load |

Neither is a semantic failure: both produce the right answer given time.
`derivedStateOfLeak` writes the state it reads during composition, so every
frame re-invalidates the scope and each `advance` runs the frame clock's full
5 s of virtual time, 313 frames. A hundred rounds is 31 300 recompositions,
which klio serves in about 100 s against the suite's 10 s.

## What a recomposition costs

Measured on the ReleaseFast harness against a two-node self-invalidating
composition, so the numbers are per recomposer frame:

| Quantity | Value |
|----------|------:|
| Time per recomposition | 3.2 ms |
| Marginal cost of one extra node | 76 µs |
| Static call | 174 ns |
| Member call | 245 ns |
| Stored field read | 22 ns |
| `synchronized` block | 437 ns |

Almost all of it is fixed per-frame cost: widening the composition twentyfold
moved 3.2 ms to 4.6 ms. The native profile finds no hot spot to remove — 35 %
interpreter core, 24 % host dispatch, 19 % string-keyed lookups, 7 % allocation,
7 % thread-local addressing — so the gap is the breadth of interpretation, not
one bad path. Closing `derivedStateOfLeak` needs roughly ten times the
throughput, which is a performance programme rather than a defect fix. Neither
the loop JIT nor the fused tier applies to this shape: both measured flat.

## Where the frame time actually goes

Folded from the macOS sampler's call tree, which is the only instrument that
tells the truth here (see the profiling note in memory). Inclusive shares of one
recomposer frame:

| Path | Share |
|------|------:|
| `getFieldInner`, the field resolution ladder | 16.9% |
| of which running property getter bodies | 11.9% |
| name-keyed side-table lookups and their hashing | 16.7% |
| thread-local addressing (`_tlv_get_addr`) | 6.1% |
| interpreter core (`runFrameExec`, `execInst`) | ~13% |

Per recomposition the frame runs about 1450 activations, 2045 field reads and
890 member dispatches. The split by library is 27% compose, 22% coroutines, 11%
property accessors, 9% lambdas and 31% a stdlib tail, and the single heaviest
function is 4.3% of activations: there is no hot spot, only breadth.

**The largest single lever left is the coroutine context.** `CoroutineContext.
Element.get`, `CombinedContext.get`, `CombinedContext.fold`,
`ContinuationInterceptor.get` and `JobSupport.key` together run about 148
activations per recomposition, roughly 9% of all activations and more once the
field reads inside them are counted. Every one is a fold over a context chain
that the JVM answers in nanoseconds. Serving `CoroutineContext.get` natively,
the way klio already serves much of the stdlib, is the one change with a
double-digit share behind it. It is also the riskiest, since it has to reproduce
`CombinedContext`, `EmptyCoroutineContext` and `AbstractCoroutineContextKey`
exactly against a 1299-test suite.

## Leads measured but not taken

- **A default argument that is a literal costs a whole activation.** The filler
  runs the parameter's thunk through the evaluator, so `f(a)` against
  `f(a, b = 2, c = 3)` costs 582 ns where `f(a, 5, 6)` costs 228 ns. Serving a
  one-constant thunk from `trivialInitServe` instead brings it to 247 ns, which
  is the whole gap. That change is NOT in the tree: it turned eight compose
  tests red because the memo it reuses publishes `triv_init_state` before
  `triv_init_val` with no ordering, so a second thread reads the new state
  against the old value and serves const 0. The memo needs to be one atomic
  word, or the two writes need a release, before this can land. Compose itself
  did not move, so the win is for default-heavy library code.
- **The member call-site memo is skipped whenever a call carries named
  arguments**, and the compose pass threads `$composer`/`$changed` by name on
  every composable call, so no composable call site can claim its memo. A call
  whose only names are that trailing pair, in declaration order, is positional
  by construction and could take the memo.

## Fixed on the way to the count

- **Steady-state paths allocated through the page allocator.** Interning an
  instance layout, parking and resuming a coroutine and registering a monitor
  each went to `page_allocator`, which maps 16 KB and makes a syscall for any
  size: 4.3% of on-CPU time in mmap and munmap. They take `smp_allocator` now.
- **The field-read memo was filled but never read.** `instanceField` re-walked
  the delegate chain, re-resolved the getter and re-scanned the slots on every
  read, then wrote back the entry it could have answered from: 46 253 reads over
  651 distinct answers in a single advance.
- **`synchronized` serialized every thread on one table mutex.** Finding the
  monitor took a process-global spin lock and a hash lookup, reading its owner
  took a second spin lock, and the exit repeated both. Four threads taking four
  DIFFERENT locks still queued behind the table. A monitor is now a single
  atomic owner word with a re-entry count only its owner touches, the thread
  caches its own id and the monitor it last resolved, and `synchronized`
  resolves once for both halves: 215 ns to 105 ns per block on that shape, and
  three compose tests that had been timing out now finish.
- **A defaulted `@Composable` parameter recomputed its default on every
  recomposition.** The prologue resolved the absent-argument marker inline, so
  a restart evaluated the default afresh; resolving it in the restart lambda
  instead traded that for a worse fault, since the restart then passed a real
  value where the first composition passed the marker and the `changed` probe
  wrote a slot the first pass never wrote. The body now opens its execute
  branch with the runtime's own `startDefaults` group, and which slots the
  caller left empty travels in the free third bit of each `$changed` triple —
  a bit the skip calculus does not read and `updateChangedFlags` carries
  through — so the threaded ABI is still the `$composer`/`$changed` pair. A
  default that is a literal, a `null` or a plain name re-evaluates to the same
  value, so it keeps the cheaper one-shot prologue.
- **The typecheck worker pool raced on the checker's shared tables.** A
  local `fun`, class or object inside a body registers itself in `fns` /
  `classes`, which every worker shares, so two declaring bodies on two
  threads grew one map under the other's reader and the reader took a
  `FnSig` field that had never been written: a segfault at
  `0xaaaaaaaaaaaaaaaa` (Zig's undefined fill) inside
  `checkCrossinlineArgReturns`. It cost datetime 13 of its 56 files and
  every compose-runtime child under fleet load. A declaring body now checks
  on the main thread at its own position, the same rule the lowering body
  pool already follows, and the walk behind both predicates is one shared
  `ast.declBodiesDeclare`.
- **The compose runtime suite never asked for `kotlinx.coroutines/test`.**
  Its mock composition fixtures drive `runTest`, which the module split put
  behind that feature. The itest, `compose-fleet.py` and `compose-test.sh`
  all pass it now — including the two `RecomposerTests` jobs, which build
  their own trimmed argv and were failing all eleven of their cases.
- The per-failure census script (`scripts/commontest-census.py`) could not
  read the three suites that predate `commontest_support` (stdlib,
  androidx_collection, compose_plugin) or any suite whose config lives in
  the shared table, so it reported them as having no tests. It now reads
  both shapes, follows `UPSTREAM ++ "/tail"` roots, and passes each suite's
  `extra_args` (a `--feature`) to its children.

## Running a suite

```sh
zig build klio-harness                                  # once
KLIO_ITEST_BIN=zig-out/bin/klio-harness zig-out/bin/klio-census <suite>
KLIO_ITEST_BIN=zig-out/bin/klio-harness \
  python3 scripts/commontest-census.py <suite> --errors  # per-failure detail
python3 scripts/commontest-sweep.py zig-out/bin/klio-harness   # stdlib
python3 scripts/compose-fleet.py --jobs 6                      # compose runtime
scripts/compose-test.sh <FilterSubstring>                      # one compose test
KLIO_HOME=$PWD/.klio-local zig-out/bin/klio test \
  kotlin-klio/klio-kotlinx-coroutines --test-group test        # coroutines test
```
