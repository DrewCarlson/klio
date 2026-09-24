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

## On the sema pipeline

`klio test` runs the sema pipeline by default now (`--legacy-pipeline` or
`KLIO_SEMA_PIPELINE=0` is the old one), so these are the censuses as they
run. The floors are the old path's counts above.

| Suite | Passed | Failed | Floor | What is left |
|-------|-------:|-------:|------:|--------------|
| kotlinx.coroutines core | 1299 | 0 | 1299 | none |
| kotlinx.atomicfu | 67 | 0 | 67 | none |
| kotlinx.coroutines test | 73 | 0 | 73 | none (two upstream `@Ignore`s skipped) |
| androidx.collection | 1841 | 0 | 1841 | none |
| io.ktor | 461 | 3 | 464 | a lambda passed through `listOf` for an extension function type gets no candidate (sema), `SuspendFunctionGunTest` x3 |
| kotlinx.io | 1191 | 0 | 1191 | none |
| kotlinx.datetime | 519 | 0 | 519 | none |
| kotlinx.serialization core | 138 | 0 | 138 | none |
| kotlinx.serialization json | 747 | 0 | 747 | none |
| Compose UI | 452 | 0 | 452 | none |
| Compose runtime (plugin) | 1393 | 11 | 1385 | see below |

**Compose runtime on the sema pipeline** (the itest shards run one at a
time, before the wall-cap fix below; the classes were re-run one child
each after it):

| Tests | Cause |
|-------|-------|
| `MutableVectorTest.sortWith` | Sema: a SAM-constructor argument (`Comparator { p0, p1 -> p0 - p1 }`) passed to a member of `Box<T>` takes its type argument from the lambda body instead of the expected `Comparator<T>`. |
| `SnapshotStateListTests.concurrentGlobalModifications_addAll`, `concurrentMixingWriteApply_addAll_removeRange`, `concurrentMixingWriteApply_addAll_clear`, `SnapshotStateMapTests.concurrentMixingWriteApply_clear` | Throughput. All four pass with the tests' 30 s `runTest` timeout raised. The old path served `PersistentVectorBuilder.addAll`/`removeRange` and the persistent map mutators from host code by name (`vm/persistent_list_mut.zig`, `persistent_map_mut.zig`); the sema pipeline runs the upstream Kotlin, whose `removeRange` is `AbstractMutableList`'s one-`remove`-per-element walk: a removeRange round is 22.6 s against 1.8 s, one map round 4.1 s of the 30 s budget for ten. Those natives are try-then-fall-back-to-the-body serves of members with Kotlin bodies (one, `removeRange`, not declared by the builder at all), which the bridge has no binding for. |
| `CompositionTests.derivedStateOfLeak` | Throughput (31 300 recompositions); recorded, not chased. |
| `CompositionTests` x4, `PausableCompositionTests.rememberObserverThrashing` | Fixed: poisoned by `derivedStateOfLeak`'s wall-cap hard abort, which left the test thread inside the composition's snapshot. The wall cap now throws a catchable timeout up to three times before it hard-aborts, so a test that catches one still ends through its own `finally` blocks. |

Measured 2026-09-24 on the packs branch rebased on `c0ec677a`. What moved
them there: the VM allocating on the process allocator, so the collector
frees (io's `AbstractSourceTest`, 744 cases, had run past the RSS cap);
natives reading a user `Map`'s `entries` through the well-known slot table
(json's `JsonObject` is a `Map` by delegation); and the serialization pass
generating code that resolves from the top level of its file: nested
annotation classes, enums and defaults spelled by path, unbounded
`serializer()` type parameters as the plugin declares them, bounded
serializers instantiated at `Nothing`, generic classes constructed at the
serializer's type parameters, `with = PolymorphicSerializer`, a `forClass`
serializer keeping its own members and supertype, and collection
serializers cast to the declared type. Datetime closed with sema's integer
literal arithmetic and sealed-constructor visibility, serialization with
the annotation class's implicit constructor and class literals typed at
once.

The Compose, material3 and Mosaic examples (50, and three interactive
windows checked by `KLIO_SKIA_DUMP` screenshots) run the same on both
pipelines, windows included, pixel for pixel. What they needed on this one:
an increment or compound assignment through `?.` stopping at a null
receiver (`parent?.globallyPositionedObservers++`), a receiver that may be
null reading the extension declared on its nullable type
(`RowColumnParentData?.weight`), and `fun f() = @Composable { ... }`
keeping its annotation.

On the old path serialization json reads 733/14 (`hasInterfaceContextualSerializers`
read on a `MutableList`); the pack changes above do not move it, and the
old path is going away.

The coroutines test group's two skipped cases are upstream `@Ignore`s.
`klio test <pack> --test-group <g>` runs the group's roots with the group's
features requested of the project's pack on this pipeline too, and
`klio-census androidx_collection` runs that suite the way the itest does.

The coroutines suite holds 1299/0 with `KLIO_GC_THRESHOLD_KB=256`. Under
`KLIO_GC_STRESS_EVERY=25` seven heavy files run past the census's child
timeout; none crashes.

**io.ktor, seven failures on this pipeline:**

| Tests | Cause |
|-------|-------|
| `ByteReadChannelOperationsTest.testReadPacketBig`, `ReadLineTest` "exceeding limit after several buffers" | Sema types a constant expression over integer literals (`8192 * 2`) as `Int`; kotlinc gives it an integer literal type, so it becomes `Long` against a `Long` parameter or type variable. |
| `SuspendFunctionGunTest` x3 | Sema finds no applicable candidate for a lambda passed through a generic call whose expected element type is an extension function type: `G(listOf({ _ -> }))` for `List<String.(Int) -> Unit>`. |
| `CaseInsensitiveMapTest` x2 | A host entry's `equals` reads the other entry's `key` and `value` as fields by name; ktor's entry exposes `value` through a getter. |

What the new path needed, each a general fix rather than a coroutines one:

- **A resumed coroutine's frames were unrooted while its value was made.** A
  host `Result` becomes the base's `Result` instance before the resumed code
  reads it, and the constructors that runs are safe points. The host did it
  after the pump had taken the activation out of its parked table and before
  `resumeContinuation` rooted the frames; a collection there swept a SharedFlow
  collector's registers. `KLIO_GC_STRESS=1` over a SharedFlow with two
  collectors reproduced it in twenty lines; the old path never converts.
- **Every two instances of one data class were equal to the host.** The
  bridge's class defs listed no constructor properties, and the host's
  structural equality compares by them, so `MutableSet.remove` took the first
  element of the class and a map's entries all showed the first value.
  Calling the class's `equals` slot from the host is the end state.
- **A closure's `toString` invoked the closure** through the host's by-name
  member call; it now answers as kotlinc does without kotlin-reflect. A
  suspend lambda still prints the plain lambda's form where kotlinc prints
  `Function1<kotlin.coroutines.Continuation<? super kotlin.Unit>, ...>`, and
  `println` of a closure goes through the host's display, which prints
  `{ir-closure#N}`.
- **An interface member a grandparent class implements had no vtable entry**
  (`DeferredCoroutine.getCompletionExceptionOrNull`).

## What is left

**kotlinx.coroutines core, one failure on the old path.**
`TimeoutTest.testSharedFlowCancelledNoTimeout` fails with `call_value on
kotlin.Nothing`, deterministically and in isolation. It predates the interpreter
pass below — the binary built from the commit before it fails the same way — so
it arrived with an earlier commit in this campaign. The frame chain reaches
`withDelaySkipping`'s `get(ContinuationInterceptor)` on a `RunningInRunTest`
context; the read misses as a member and the bare-name fallback is what needs
following next. It passes on the sema pipeline, as does
`JobExtensionsTest.testIsCancelled`, the old path's second failure today.

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

## Where the time is, measured four ways

The four instruments disagree, and the disagreement is the finding.

**Self time by subsystem** is the only measure that cannot double-count, and it
is flat:

| Subsystem | Share |
|-----------|------:|
| call and frame machinery | 22% |
| instruction execution (walker, bytecode, leaf, fused tiers) | 21% |
| host dispatch and resolution | 14% |
| name-keyed table probes and hashing | 13% |
| allocation, collection, object cells | 10% |
| everything else | 20% |

**The opcode sampler** says `Call` holds 67.6% — but the opcode tag is set at
`execInst` entry and a callee served by the leaf or fused tier never sets its
own, so a call's tag covers every body those tiers run. It ranks, it does not
apportion.

**The Kotlin-function sampler** says `KlioContinuation.resumeWith` holds 44% on
two activations per recomposition. That is the same leak: everything the resume
subtree runs outside a framed body bills to it. Resumes replay about four frames
each, which is the normal unwind depth, not a pathology.

**Child attribution over the call tree** is useless on the recursive spine —
every wrapper reports 0.34% self and 99.66% "child" — but it is exact off the
spine, and there it showed the field-read arm is 61% running getter BODIES,
27.6% the resolution ladder, and 10.8% its own fast path.

The lesson for the next pass: rank with the samplers, apportion with self time,
and never let a percentage from a nested instrument justify a change.

## What a call costs, and why it does not fuse

`execArmCall` runs 904 static calls per recomposition. 47% reach the fused plan
that pushes the callee's frame directly; the rest take a tail that allocates an
argument run, resolves names, builds a type-argument list and re-checks the
overload. The declines are now censused (`KLIO_DISPATCH_STATS`):

| Decline | Share of static calls |
|---------|----------------------:|
| callee's plan ineligible | 31% |
| named or type arguments at the site | 5% |
| same-name, same-arity peers | 4.5% |
| argument count is not the plan's arity | 0.8% |

`KLIO_FASTPLAN_TRACE=*` names the ineligible callees, and they are led by
`isFull`, `__klioMonitorEnter`/`Exit`, `hash`, `countTrailingZeroBits`, `max`
and `unbox` — targets the link settled on a native binding, which have no body
to enter.

The bytecode tier now covers fifteen opcodes: constants, moves, unary and binary
operators, a site-claimed field read, and control flow. Calls, constructions,
global loads and lambdas still escape to the generic arm — and measuring the two
opcodes added here showed that escaping is not what costs (see "The bytecode
tier is not where the time is").

## Leads measured and rejected

Recorded because the measurement is the finding. All four looked right and none
of them paid.

- **Threaded dispatch for the bytecode stream.** The textbook interpreter
  optimisation: instead of one shared back edge whose indirect branch every
  opcode funnels through, give each arm its own jump to the next opcode's arm,
  so each gets its own predictor entry. Zig's labelled-switch `continue`
  expresses it directly, and a sentinel op at the end of each unfused stream
  removes the bound check the shared back edge was doing. It measures **12%
  SLOWER** on a tight integer loop and flat on the recompose benchmark. Apple
  Silicon's indirect predictor already handles the shared dispatch, and
  replicating the jump-table load at fifteen sites costs more in code size than
  the prediction was costing. The technique is a win on hardware with a weaker
  BTB; on this target it is a regression, and it is the reason the stream keeps
  its single `while` back edge.
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
- **Serving a link-settled native binding from the call instruction**, sparing
  the four host layers and the argument-run allocation between the instruction
  and a function with no body. It fires on 33 000 calls per advance and measures
  neutral, with the discriminator free (a flag in the plan word the site already
  loads) or charged (a hash probe per call). The layers are not the cost.
- **Letting a fully-applied call to a defaulted function fuse.** A call that
  supplies every parameter runs no thunk and fills nothing, and the plan already
  records the full arity, so excluding default-bearing functions outright was
  costing every composable its fast plan. It adds 1 262 fused calls per advance
  and measures neutral.
- **Serving a static call's linked native binding from the call instruction**
  and **collapsing the activation seam's four tier probes onto the memos each
  already keeps on the `Func`**. Both neutral. The seam and the host layers are
  not the cost.
- **Hoisting the field-read guard above the resolution arms**, the order a
  specializing bytecode VM uses: compare the claimed class, then load the slot,
  with the builtin-field shapes and the companion sentinel as the deopt path.
  It measures -0.3% and BREAKS FIVE compose tests. The one thing it skips is the
  enclosing-`this` push, which is documented as keeping the caller's receiver
  reachable "while the property resolves" — and something observes that entry
  during what is otherwise a pure slot read. Placing the serve LATER — after the
  builtin shapes and the companion sentinel, before only the push — is worse
  still: 31 failures, most of `PausableCompositionTests`, which is far outside
  the shard's noise band and so is certainly a real break. The six-failure
  reading for the first placement is NOT certain: on a loaded machine one binary
  gave 6 then 7 failures while another gave 6 then 2, so shard counts only
  discriminate when the machine is quiet. What is established is that a
  specialised field read cannot skip the preamble wholesale, which also blocks a
  `GetField` bytecode op until the coupling is found.

## A change can be correct, faster, and still fail the gate

Two changes in this pass were semantically clean — every test they were accused
of breaking passes standalone on the accused binary — measured faster, and still
made shard 1 fail deterministically:

- hoisting the field-read guard above the resolution preamble (-0.3%)
- stopping the leaf tier from re-attempting a body that keeps abandoning (-2.0%)

For the second, the shard ran 428/6 and 427/7 against 433/1 and 432/2 for the
committed binary, interleaved, at SIMILAR or faster child wall times — 144 s and
153 s against 155 s and 437 s. So it is not a budget cut and not machine noise:
the change shifts timing inside the child, which runs its coroutine workers
uncapped, and exposes a latent concurrency sensitivity in tests like
`avoidsThrashingTheSlotTable` and `rememberObserverThrashing`.

That sensitivity is the real defect and it is worth finding: it is currently
absorbing perf work that is otherwise correct. Until it is, the rule is that a
perf change must hold shard 1 interleaved against the committed binary, and
standalone passes do not clear it.

## The frameless tier runs only what it can finish

The tier that executes a body without a Frame has three verdicts: fusable,
partial and declined. A PARTIAL body ran its fusable prefix in the walker and
then materialised a Frame to finish — paying the tier's entry, which is about a
tenth of a member call, and then the frame it was meant to avoid.

Measured against the baseline binary, with the tier entered only for bodies it
can run to completion:

| Benchmark | Change |
|-----------|-------:|
| recomposition | **-2.9%** |
| wide composition | **-3.4%** |
| object construction | -1.3% |
| monomorphic member call | +0.6% |
| bare activation | +0.2% |

Turning the tier OFF entirely is worth more on compose (-3.4%) but costs a tight
monomorphic call loop 5.3%, so the tier earns its place on the bodies it
finishes and only those. Two call sites allowed materialisation, the recursive
seam and the flat-call loop; changing one and not the other reads as a 0.3%
nothing, which is how this was missed the first time.

## The frameless tier, and why the workload cannot reach it

The interpreter has four tiers. Measured on a bare one-parameter activation
(`scratchpad/probe/ProbeAct.kt`, 292 ns against a 118 ns empty loop):

| Quantity | Value |
|----------|------:|
| One activation, simplest possible | 174 ns |
| The fused walker, per instruction | ~19 ns |
| The fused walker's entry | ~25 ns |

So the frameless tier is roughly ten times cheaper per instruction than the
framed path — and a recomposer frame runs 79% of its activations framed anyway.
`KLIO_FUSE_DECLINE=1` names every activation the tier turns away and why:

| Gate | Share of declines |
|------|------------------:|
| the body's classification | 96% |
| a partial body with no materialize allowed | 2.3% |
| argument count not the declared arity | 2.1% |

and the classification declines are led, per advance, by
`AtomicArray.get` (16 962), `CoroutineContext.Element.get` (13 305),
`atomic` (9 914), `ChannelSegment.getState` (9 422),
`ContinuationInterceptor.get` (7 021) and `CombinedContext.get` (6 360).

Two of the classifier's rules were tested against that census and neither paid:

- **A defaulted parameter is a hard decline.** `fusedExecOpt` only enters when
  the call supplied every parameter, so no thunk can run and nothing is filled;
  the rule looked redundant and the compose pass gives every composable a marker
  default. Removing it changed the fused counts by three activations in two
  million. The composables are declined earlier, by something else.
- **A generic signature is a hard decline** — `bareTypeVarHead` on the return
  type or any parameter — which is exactly what shuts out the coroutine-context
  family, since `get` returns `E?`. The rule reads as belt-and-braces, because
  `as T` and `is T` are guarded per instruction and no other fusable op reads a
  type argument. Removing it admitted 84 500 activations and made things
  slightly WORSE, and full fusion fell from 535 778 to 415 211: the newly
  admitted bodies classify as partial rather than fusable, and their callers
  lose their own full-fusion verdict through the `.Call` arm. The rule is
  load-bearing through the recursive classification, not just its own decline.

## The bytecode tier is not where the time is

The tier now carries a field read (`gf_site`) and a unary operator (`un`)
alongside its constants, moves and binary operators. Both were built to the
shape a specialising VM uses: the stream tries the guarded fast helper, and on a
miss takes the instruction's own arm through `afterStep`, exactly as `bin` does.
Both are correct and both are nearly free:

| Change | Recompose benchmark | Tight integer loop |
|--------|--------------------:|-------------------:|
| `gf_site`, serving 2.45 M of 4.5 M field reads inline | -0.3% | — |
| `un`, removing the escape from every `i++` | -0.2% | 0% |
| `shouldAbandon` reordered off the threadlocal | -0.1% | -11% |

The `un` row is the finding. Removing a whole `execInst` dispatch from the
innermost loop of a 40-million-iteration counting loop changed that loop by
**zero**, which settles what an escape costs: the union switch is a jump table
and the arm call is a call, and together they are lost in the noise of the work
the instruction does. The `gf_site` row says the same thing from the other side
— it moved 2.45 M reads off the generic arm and bought 0.3%, which is 8 ns a
read, which is the dispatch and nothing else.

So widening the tier further — a call opcode, a global load, a construction —
buys about one percent in total, not the order of magnitude the goal needs. The
tier is worth having and it is now built out to the instructions that actually
escape in hot code, but it is finished as a lever.

The `shouldAbandon` row is a separate, real finding about branch cost.
`fusedEdgeGuard` runs on every branch and every back edge, and it led with
`thread_abandonable`, a threadlocal — so on Darwin every branch the evaluator
took made a `_tlv_get_addr` call. Testing the plain global `abandon_requested`
first is semantically identical (`A and (B or C)` either way) and cuts a tight
loop by 11%. It moves compose by 0.1%, because compose is call-bound rather than
branch-bound, which is itself the point: the same change is worth two orders of
magnitude more to one workload than the other.

## Where a recomposition's 2 811 µs goes

One `benchRecompose` run: 1 881 recompositions in 5 289 ms, so 2 811 µs each.
Per recomposition the interpreter runs 1 510 activations, 7 900 dispatch events
and 5 110 instructions the generic arm executes. Sampler self time buckets as:

| Area | Share of self time |
|------|-------------------:|
| The frame walker and the fused/leaf tiers | 36% |
| The VM host dispatch layers (`vm/*`, `exec_call`) | 30% |
| Name hashing and hash-map probes | 15.6% |
| Allocation and free | 6.4% |
| `ObjRef` borrow | 3.0% |

The hashing share is the one that does not belong. It is name lookups — strings
hashed at run time to find a member, a class, a global or a property — and it is
diffuse: the `(class, member)` registry probes alone come from twelve distinct
callers with no dominant one (`lookupPairFuncHop` 39 samples, then
`objectSingletonForMember`, `memberExtOverridesFor`, `materializeInstance`,
`delegatedPropRegistered`, `instanceField` at 15 to 18 each). There is no hot
spot to fix; the design re-hashes names on every operation.

## Only 8% of activations run frameless

`KLIO_FUSE_DECLINE=1` over `benchRecompose`: 2 627 816 declines against
2 840 440 activations.

| Gate | Declines |
|------|---------:|
| `classify` (the static verdict is 2) | 2 011 977 |
| `partial-no-materialize` (verdict 4, which now runs framed) | 574 676 |
| `arity` | 41 158 |

The functions declining most are one-line accessors, and they decline on their
*signature*, not their body: `fusedClassify` rejects any function whose return
type or any parameter type is a bare type variable, because `as T` / `is T`
consults a reified context the frameless walker does not carry. So
`kotlinx.atomicfu.AtomicArray.get` (118 212 activations),
`kotlin.coroutines.CoroutineContext.Element.get` (92 073),
`kotlinx.atomicfu.atomic` (66 896), `ChannelSegment.getState` (52 538),
`ContinuationInterceptor.get` (48 277), `CombinedContext.get` (43 866),
`Symbol.unbox` (21 929) and `kotlin.also` (19 714) all pay a full frame to read
one field — and the body-level `Cast`/`InstanceOf` guards next to the signature
check already cover the case the signature check exists for.

Relaxing that gate is worth bounding before building it. Two functions with the
same trivial body, one generic and one not, cost 388 ns and 303 ns per call
against a 101 ns empty loop — so the frame is worth about 85 ns of a 290 ns
activation. Converting every decline would be roughly 4% of the benchmark. Real,
and not the goal.

## What one activation costs, and what came off it

A probe that makes eight calls per loop iteration, so loop overhead is a tenth
of the sample, put a fully fusable static activation at **189 ns**. Sampling it
gave the first breakdown of an activation that is not confounded by compose:

| Area | Share | ns |
|------|------:|---:|
| The caller's frame loop running the `Call` | 18% | 35 |
| The frameless tier: entry plus the body's own instructions | 26% | 50 |
| The flat loop | 11% | 20 |
| `execArmCall` | 4% | 8 |
| Identified machinery (carrier, safepoint, keepalive, seam probes, lookups) | 22% | 42 |

The machinery row is what a flattened activation does not pay, and the largest
single item in it was the argument carrier: every call acquired a pooled
`ArrayList`, copied the argument registers into it, handed it to a flat-call
request, and let the activation seam ask whether the body could run frameless.

**The static-call shortcut removes all of that.** A callee whose memoized
verdict says fully fusable runs straight from the caller's register run: a stack
copy, no carrier, no flat request, no second pass through the seam. The values
stay the caller's and its registers keep them reachable, which is exactly how
the frameless tier's own call arm already borrows them.

| Probe | Before | After |
|-------|-------:|------:|
| Static activation (eight calls per iteration) | 191 ns | 118 ns |
| One-parameter call in a loop | 307 ns | 224 ns |
| Generic one-parameter call in a loop | 395 ns | 217 ns |

Two things had to be right for it to pay. The verdict byte is read **first**:
an ungated version copied arguments and probed the tier for every callee, and
since most of them decline, compose came out 0.6% slower. And the enclosing-`this`
push had to move above the carrier so both paths share it.

The generic row comes from a second change. `fusedClassify` declined any function
whose return type or any parameter type was a bare type variable, which is a
syntactic proxy ("short uppercase name") for "this body might consult reified
type information". The precise concern is `as T` / `is T`, and the Cast and
InstanceOf instructions are already guarded for exactly that two lines below;
the argument side is covered too, because `fusedRun` applies the same
`coercePlanFor` widening the framed entry does, type-variable peer rule included.
Dropping the signature gate lets 216 000 more activations per benchmark run
frameless and halves a generic call.

## Every lever now converges on the same constraint

Both changes are large on their probes and **neutral on compose**, and the
reason is one number: only about 8% of activations are fully fusable, so a
frameless activation getting 38% cheaper reaches very little of the workload.

What it did change is the value of converting the rest. The gap between a
fusable body and a declining one was 91 ns; it is now **179 ns**, because only
one side got cheaper. At 2.4 M declines per benchmark run that is ~8.9% of
compose, against the ~4% the same lever was worth before. The bound moved
because the floor moved.

The blocker is `CallMember`, by a wide margin, and it is a keystone rather than
one more item: the frameless tier declines any body containing a dynamic member
call, which is most real bodies, and a body that declines also stops every
caller whose `Call` site would otherwise fuse transitively. The gate's stated
reason is performance ("fused-first execution never stamps the site memos"),
not correctness, and the memos are reachable from the tier since it holds the
instruction pointer. The risk is the shape it creates: a body admitted as fully
fusable that meets something the arm cannot serve returns `error.Materialize`
mid-run, which pays the tier's entry AND the frame it then opens, and that trade
already measured as a 2.9% loss. Admitting `CallMember` therefore has to come
with an arm complete enough that materialising stays rare.

## What a ten-fold would take

`derivedStateOfLeak` allows about 320 µs per recomposition against 2 811 µs
today, so the budget is ~210 ns per activation against ~1 860 ns. Every lever
measured in this pass is worth single digits, and they are independent, so they
do not compound into an order of magnitude:

| Lever | Measured or bounded |
|-------|--------------------:|
| Finishing the bytecode tier | ~1% |
| Making every declined body frameless | ~8.9% |
| Everything landed, cumulative, on compose | 9.5% |
| The same work on a call-heavy program | 38-45% |

The order of magnitude is in the two numbers the levers do not touch: **~25 ns
for a trivial register-to-register integer instruction** (a bytecode VM spends 2
to 5) and the cheapest possible activation, now **118 ns** where a bytecode VM
spends 20 to 50. Three
changes would move those floors, and all three are re-architecture:

1. **Resolve every call and field access to a slot or `FuncId` at link time** so
   the steady state never consults a name. The site memos approximate this, but
   the generality they fall back to is structured into every path, so even a hit
   pays for the miss's shape — and 15.6% of self time is still name hashing.
2. **Collapse the host dispatch layers.** A static call crosses `execArmCall`,
   `callFunc`, `callFuncNamed`, `callFuncTyped`, `callFuncTypedInner` and the
   activation seam; a member call crosses a comparable stack. That is 30% of
   self time, and serving a link-settled native binding from the instruction
   measured neutral, so it is the *shape* of the layers rather than their count.
3. **Flatten the activation**: register windows in one contiguous stack rather
   than a per-activation list plus a host round-trip per call.

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
