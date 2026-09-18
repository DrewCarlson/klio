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
| kotlinx.coroutines core | `klio-census coroutines` | 1298 | 1 | 1299 |
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

**kotlinx.coroutines core, one failure.**
`TimeoutTest.testSharedFlowCancelledNoTimeout` fails with `call_value on
kotlin.Nothing`, deterministically and in isolation. It predates the interpreter
pass below — the binary built from the commit before it fails the same way — so
it arrived with an earlier commit in this campaign. The frame chain reaches
`withDelaySkipping`'s `get(ContinuationInterceptor)` on a `RunningInRunTest`
context; the read misses as a member and the bare-name fallback is what needs
following next.

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
| Time per recomposition | 3.0 ms |
| Marginal cost of one extra node | 76 µs |
| Activations | 1450 |
| Field reads | 1750, of which 240 miss every site route |
| Member-call arms | 1670 |
| Instructions the frame loop executes | 5500 |

Almost all of it is fixed per-frame cost: widening the composition twentyfold
moved 3.2 ms to 4.6 ms. Per executed operation the interpreter runs about 56 ns,
which is bytecode-interpreter territory and a hundred times what a JIT would
spend on the same work. Closing `derivedStateOfLeak` needs roughly ten times the
throughput; nothing short of compiling hot bodies to native code reaches that,
and the loop JIT does not apply, since this shape is calls rather than loops.

## How a change here is measured

The numbers above and every claim below come from an interleaved A/B on **user
CPU milliseconds**: two saved harness binaries, alternating on the same
benchmark, three or four rounds, minima compared. A single wall-clock run on
this machine varies by ±5%, which is larger than nearly every real change —
measured that way, a whole batch of plausible improvements summed to 0.2%.

The macOS sampler is still the only instrument that shows *where* the time is,
but its self time is not proportional to elapsed time for small leaf functions:
`_tlv_get_addr` held 6.7% of samples and removing nearly all of it moved CPU
time by about nothing. Profile shares point at where to look. They do not
measure what a change is worth.

Microbenchmarks matter alongside the real workload, because a change can help
one and hurt the other. `scratchpad/probe/ProbeHot.kt` times a monomorphic
member-call loop and a construction loop; a hand-rolled string hash that made
member calls 5.6% faster was caught making construction 3.4% slower.

## Where the frame time actually goes

Folded from the sampler's call tree. Inclusive shares of one recomposer frame,
after the pass below:

| Path | Share |
|------|------:|
| `runFrameExec`, the instruction loop itself | 10% |
| name-keyed table probes and their hashing | 10% |
| running property getter bodies | 7% |
| allocation and collection | 4% |
| thread-local addressing | 2% |

The split by library is 27% compose, 22% coroutines, 11% property accessors, 9%
lambdas and 31% a stdlib tail, and the single heaviest function is 4.3% of
activations: there is no hot spot, only breadth.

## What this pass removed

Each measured by the A/B above, against the commit before it:

- **`implementationApplicable` scanned all 1615 stdlib entries** by FQN to find
  one of the 37 that carry an applicability predicate, on every installed-binding
  probe: **2.3%**.
- **`std.fmt` built the member tails' probe keys.** A two-string join pulled in
  the writer, its buffer and its drain; the bytes are joined directly now,
  together with the anonymous-object method table's keys: **0.8%**.
- **The field-read memo refused every pack class.** Its key is the class cell's
  address, so it is sound while that cell cannot be freed and reused, and the
  test for that was "the class is in the main module". `AtomicInt.value`, the
  busiest field read in the frame at forty reads per recomposition, could never
  be memoized. With the condition the invariant actually needs, slow field reads
  fell from 308 to 240 per recomposition and their cost from 229 µs to 155 µs:
  **0.7%**.
- **A scoped getter's memo was written under one name and read under another**,
  so the walk never saw the entry it had just recorded: **0.4%**.
- **`companionWithMember` re-ran a substring search** over the receiver's class
  name on every call, to decide something that is a property of the class.
- **The binding cache keyed on each argument's class**, so a compare-and-set over
  changing state missed every time and rebuilt its whole probe list. It keys on
  the argument shapes, which is what applicability actually reads.
- **A closure call copied its argument run and names** into fresh lists only to
  pass them straight on.
- **Per-thread state off the thread-local block**, and one hash for every
  name-keyed table with a pointer-first equality and a scope chain that hashes
  once instead of once per level.

Together, against the same baseline binary: **6.6%** off a recomposition, 6.6%
off a monomorphic member call and 0.9% off an object construction. Three compose
tests that had been timing out under fleet load now pass, and the gate holds its
1402/2.

## Leads measured and rejected

Recorded because the measurement is the finding. All four looked right and none
of them paid.

- **A hand-rolled short-string hash.** Fewer instructions than Wyhash, worse
  distribution: at the tables' load factor the extra probing cost more than the
  mixing saved. Construction 3.4% slower.
- **A lower load factor for the name tables.** 80% down to 40% is worth 2.4% of
  a recomposer frame when the program has the machine to itself, and costs more
  than that when it does not: under the gate's thirteen concurrent children the
  wider tables slowed the longest job by 12% and cut five tests off the end of
  its budget. Alone it is a win; in the gate it is a loss, and the gate is what
  ships. This is also why a change is not believed until it has run the gate:
  the recompose benchmark said +2.4% and the gate said five regressions.
- **A per-thread pointer-keyed class-def cache**, to skip the class table's
  string hash. Flat on the recomposer, negative on construction.
- **A per-class "has a delegate slot" verdict**, to skip a field scan on every
  field read. 0.7% slower: the instance was already in cache and the table was
  not.
- **Serving an object-valued global from the leaf evaluator**, to spare a frame
  for the coroutine state getters that compare against sentinel singletons.
  Neutral — the global read it saves costs three map probes and a scope-chain
  walk of its own.
- **Hashing a `(class, member)` pair in one pass** over a joined stack buffer
  instead of hashing each name and mixing. 1.1% slower: the copy costs more than
  the hash's second setup.

The pattern: klio's hot path is cache-resident, so adding a lookup table to
avoid a short scan loses, and removing work the operation did not need wins.

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
- **Getter bodies are 7% of a frame and the leaf evaluator declines most of
  them.** `KLIO_LEAF_TRACE=*` names each decline: an extension property whose
  receiver is a `Long` (the channel's packed counters), an `AtomicRef` array
  `get`, an enum entry read through a scoped name. Each is a distinct small
  extension to the leaf walker.
- **The coroutine context.** `Element.get`, `CombinedContext.get`,
  `CombinedContext.fold`, `ContinuationInterceptor.get` and `JobSupport.key`
  together run about 148 activations per recomposition. `key` is read across ten
  element classes at one site, which is the megamorphic shape klio serves worst.

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
