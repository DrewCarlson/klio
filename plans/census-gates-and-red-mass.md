# Census gates and the red mass

Two tracks, one goal: make every census gate honest in both directions, then
drive the tolerated failure mass down.

The predecessor campaign (`conformance-and-hardening.md`, closed) added
failure ceilings to the census suites — but only to the six that run through
`commontest_support.zig`. Its item C3 said "for every census suite" and the
landing commit said "bound every census in both directions". Neither was true:
`stdlib`, `compose_plugin`, and `androidx_collection` predate the shared
helper, have their own bespoke tallies, and counted passes only. This plan
closes that and then attacks what the ceilings expose.

## Track A — every census bounded in both directions (9/9)

A pass-count floor cannot see a regression *inside* the red mass: a change
that turns one failure into a pass while breaking a different test leaves the
floor untouched. Each suite needs a failure ceiling seeded from a measured
solo run.

- [x] A1. `stdlib` — count failures from the child summary line, mirror of
      `passedCount`. Measured solo across both shards: 1024 + 1277 passed,
      **0 failed**, 0 build-blocked. Ceiling seeded at 0: every stdlib case
      that runs, passes, so one new failure is a real regression. (A file that
      cannot produce a summary is counted `build-blocked`, not failed.)
- [x] A2. `compose_plugin` — count `FAILED` lines, mirror of
      `passedLineCount`, with the same streamed-stderr fallback the pass
      counter uses for a class killed mid-run. Deliberately no
      did-not-complete ceiling: DNC here is throughput-bound and varies by
      ~40 between runs, so a DNC gate would be a flake rather than a signal.

      Two solo runs disagree: **1375 passed / 15 failed**, then **1374 / 16**,
      with the total constant at 1390. One test flips. That is a real defect,
      not ceiling noise — and it means a ceiling of 15 would fail the gate
      roughly half the time. Rather than widen the number to cover it, both
      this suite and androidx now *print the names* of failing tests: a bare
      count cannot distinguish a regression from a known-unstable test
      flipping, which is the same "not actionable" argument the suite already
      makes for naming its did-not-complete classes. Identify the unstable
      test, then decide whether the fix is to the test or to the interpreter.
- [x] A3. `androidx_collection` — count `FAILED` lines. **Its ratchet had
      never run.** The sparse-checkout set in
      `scripts/init-androidx-collection-submodule.sh` pulled `commonMain`,
      `nonJvmMain`, and `jbMain` but not `commonTest`, so `TEST_ROOT` did not
      exist and the suite took its `SkipZigTest` path — and a skipped suite
      reads as a pass. Added `commonTest` to the sparse set; 43 test files now
      present and the suite runs for real. First real measurement: **1309
      passed, 15 failed, 9 did not complete** across 39 files — against a
      floor of 560 that had never been enforced. Floor raised 560 -> 1250,
      ceiling seeded at 15, no DNC ceiling (the 1M-iteration stress loops are
      throughput-bound, so which ones beat the per-file timeout varies).
- [x] A4. Negative controls. A ceiling seeded from a measured `0` is only
      trustworthy if the counter can see a non-zero. Each of the three counters
      has a unit test over synthetic child output asserting it counts failures,
      ignores passes, and that the pass parser is not fooled by the failure
      field.

Standing rule: a suite that *skips* is not a suite that *passes*. When a
census cannot find its sources it currently prints and skips, which is right
for a checkout without submodules but silent in a checkout that should have
them. Any new census must state which it is.

## Track B — the red mass

Failures tolerated by the ceilings, worst ratio first:

| suite | passes | failures | conforming |
|---|---|---|---|
| serialization | 57 | 81 | 41% |
| datetime | 457 | 62 | 88% |
| coroutines | 1073 | 141 (+6 DNC) | 88% |
| io | 1182 | 9 | 99% |
| compose_plugin | 1375 | 15 | 99% |
| androidx_collection | 1309 | 15 | 99% |
| atomicfu | 67 | 0 | 100% |
| ktor | 448 | 2 | 99.6% (both upstream skew) |
| stdlib | 2301 | 0 | 100% |

- [ ] B1. **serialization descriptor fidelity.** klio has no serialization
      compiler plugin, so `T.serializer()` resolves to a reflective
      replacement whose descriptor was type-erased: `isElementOptional` was
      hardcoded `false`, `getElementDescriptor` returned a neutral
      placeholder, and `getElementAnnotations` returned `emptyList()`. The
      runtime already carried the answers — `ClassParamDef` has
      `declared_shape`, `default`, and per-property `anchors` — they were
      simply never exposed.

      Landed so far: `__klsx_ctorParamTypes` and `__klsx_ctorParamOptional`
      host helpers, and a `ReflectiveDescriptor` that answers
      `isElementOptional` from the parameter's default and names a real
      primitive descriptor per element (falling back to neutral rather than
      claiming a structure the type-erased path cannot produce).
      Still open: per-element annotations, which need the anchors exposed the
      same way.
- [x] B2. Serialization census taken: **57 passed / 81 failed across 28
      files**. Three files carry 23 of the failures and all three are
      descriptor fidelity: `SerialDescriptorAnnotationsTest` 0/9,
      `SerialDescriptorEqualityTest` 0/7, `SchemaTest` 0/7. Failure shapes:
      `Vm::call_member X on X` 18.5%, `NoSuchElementException: List is empty.`
      11.1%, descriptor-name/serialName mismatches ~10%, `unresolved global`
      6.2%.
- [ ] B9. **`@SerialName` on a class — BLOCKED on the pack format.**
      `ClassDef` retains annotation NAMES but not their arguments, so
      `@SerialName("MyClass")` is known to be present and its value
      unreachable; the descriptor falls back to the qualified class name.
      That accounts for ~8 failures of the shape
      `Expected <MyClass>, actual <pkg.Outer.WithNames>`.

      Implemented and REVERTED. Adding `annotation_records` to `ClassDef` (and
      `ClassDefImage`) works in a direct `klio run`, but takes the census from
      57 passed to **0 passed / 28 "module initialization failed"** — every
      file dies initializing `BUILTIN_SERIALIZERS`, where
      `String.Companion.serializer()`'s body stops resolving the internal
      `StringSerializer` object.

      Attempted twice, reverted twice. Findings, in the order they were ruled
      out — the later ones are the useful ones:

      1. With the field present but NEVER POPULATED the census is still 0, so
         it is not the record data. `ClassDef`/`ClassDefImage` field order is
         part of the pack wire format (`src/pack/write.zig` walks struct fields
         positionally).
      2. Bumping `FORMAT_VERSION` 2 -> 3 (so stale packs are REJECTED rather
         than misread, which its own doc comment prescribes) did NOT fix it.
         Same failure.
      3. The failure needs the census's SUPPORT files. Bisected to exactly one:
         `PolymorphismTestData.kt`, whose top-level
         `val BaseAndDerivedModule = SerializersModule { ... }` runs during
         module initialization. Every other support file is fine.

      So the real blocker is INITIALIZATION ORDER, not the pack format:
      `BUILTIN_SERIALIZERS` (a top-level val in upstream's `Primitives.kt`) can
      initialize before the internal serializer objects it reads, and
      `String.Companion.serializer()`'s body then misses `StringSerializer`:

          [getfield-miss] name=StringSerializer recv=kotlin.String.Companion

      Any change that perturbs top-level init order exposes it; retaining class
      annotations was merely one such change. Fix the ordering first, then the
      annotation-record plumbing is straightforward (note `annotationRecordFor`
      stores AST-owned slices, so lifetimes want checking, and the layout
      change still needs the FORMAT_VERSION bump).
- [ ] B12. **`whole_source_set` for serialization: tried, net NEGATIVE.**
      Upstream commonTest is one compilation unit, so `shouldFail` — declared
      top-level in `CompilerVersions.kt`, which also carries its own `@Test`s —
      is invisible under the default one-target-per-child model
      ("unresolved global `shouldFail`", 4 failures). `commontest_support`
      already has `.whole_source_set = true` for exactly this (datetime opts in
      for `checkComponents`).

      Enabling it moved the census 57/81 -> **49/89**. It does resolve
      `shouldFail`, but compiling every file together surfaces same-simple-name
      classes declared in different test files — `A` (7 failures), `C` (3),
      `Parametrized` — which klio then fails to tell apart. Reverted.

      The blocker is therefore cross-file simple-name collision handling, not
      the harness model. Note the lowering already has machinery for this (the
      file-mangled `KeyInfo$f352` form), so the fix likely belongs there; once
      it holds, `whole_source_set` should be revisited, since it is what
      kotlinc actually does.
- [ ] B11. **Top-level property initializers, two defects found while
      chasing B9.** A reduced program with a top-level
      `val M = SerializersModule { polymorphic(Base::class, Base.serializer()) { … } }`
      fails outright with `unresolved global BaseAndDerivedModule` — the file's
      own top-level val does not resolve from `main`. Repro kept at
      `scratchpad/initorder.kt`. This is independent of serialization and
      likely worth more than the descriptor work it was blocking.
- [ ] B10. Element descriptors cannot name their types yet. Building one with
      `PrimitiveSerialDescriptor("kotlin.Int", ...)` is rejected upstream
      ("For serial name kotlin.Int there already exists IntSerializer"), and
      taking it from `Int.serializer().descriptor` instead pulls
      `BUILTIN_SERIALIZERS` into top-level module initialization, which fails
      the same way as B9. `isElementOptional` (from the parameter default)
      DID land and works.
- [x] B3. Name the failures. Both bespoke suites now print failing test
      names, which collapsed the counts into roots:

      **compose (15)** — four `FloatingPointEqualityTest` negative-zero cases
      (deterministic) and eleven concurrency cases
      (`SnapshotStateList/Map/Set.concurrent*`, `RecomposerTests`
      deadlock/frame-clock, `PausableCompositionTests.resumeOnBackgroundThread`).
      The concurrency group is where the 15↔16 flip lives.

      **androidx (16)** — nine are the whole of `IndexBasedArrayIteratorTest`,
      four `ArraySetTest`, three the same `emptyObject*Map` shape across
      `ObjectFloat`/`ObjectInt`/`ObjectLong`.
- [x] B5. **Extension properties on a companion object.** Fixed the four
      compose floating-point failures at the root. `class H { private val
      T.Companion.p get() = … }` never resolved, because a companion receiver
      arrives under its mangled runtime class name (`T$Companion$Companion`)
      while the declaration registers under the source-written type
      (`T.Companion`) — and a *private* member extension registers only under
      its owner-qualified key, so the plain pair the companion arms consulted
      did not exist. Both arms now try the source form. Example + corpus pin
      added; unit tests 67/67.
- [x] B6. **Overloaded inline extensions picked by shape, not argument type.**
      Root of androidx's 9-failure `IndexBasedArrayIteratorTest` cluster (plus
      all of `ArraySetTest` and `ObjectFloatTest`). `ArraySet.addAll(Collection)`
      calls a bare `addAllInternal(elements)`; the sibling overload takes an
      `ArraySet`. Same receiver, same arity, different parameter type — the
      splice path resolves by call shape and its documented fallback is the
      first-declared overload, so the ArraySet body was spliced for a List and
      read `.array` off it. Now declines to splice when several overloads fit
      the arity with different parameter types (reified candidates exempt, as
      only splicing can honour those). androidx 16 failures -> 2; ceiling
      15 -> 4.
- [x] B7. **Explicit type arguments now veto a same-named member.** Fixed;
      androidx 2 failures -> 0. A call `f<T>()` cannot be answered by a member
      `fun f()` that declares no type parameters, so it does not shadow a
      same-named top-level generic function. klio bound the member and
      recursed until the eval depth blew. Position-dependent — correct in
      initializer position, recursive in argument position — because the two
      reach different emit paths. Two paths had to learn it: the implicit-this
      route declines, and the unresolved-bare-call fallback commits the
      top-level function. The fact rides in the existing own-member arity mask
      as bit 62 (beside the vararg bit 63) rather than a parallel map,
      following the `ownMemberApplicable` precedent that kotlinc resolves by
      applicability, not by name.

      Side effect worth noting: androidx passes rose 1275 -> 1547 and
      did-not-complete fell 10 -> 5, because the runaway recursion had been
      consuming per-file timeouts. Ceiling 4 -> 0.
- [ ] B8. **compose concurrency cluster (11, the last in that suite) — a
      THROUGHPUT problem, not a correctness one.** Diagnosed, not fixed.

      `SnapshotStateList/Map/Set.concurrent*` (7),
      `RecomposerTests.validatePotentialDeadlock`,
      `PausableCompositionTests.resumeOnBackgroundThread` (2). Every one fails
      the same way:

          UncompletedCoroutinesError: After waiting for 1m, the test body did
          not run to completion

      The assertions are fine. `concurrentGlobalModification_add` PASSES in
      50185ms when `kotlinx_coroutines_test_default_timeout` is raised; it
      launches 100 coroutines per round for 100 rounds, so 10,000 dispatches.

      Measured per-operation cost (`scripts`-free repro, no compose involved):

      | operation | cost |
      |---|---|
      | `launch(Dispatchers.Default)` + join | **1556us** each |
      | `yield()` round-trip | **616us** each |

      A JVM dispatch is single-digit microseconds, so this is two to three
      orders of magnitude off, and 10,000 dispatches cannot fit any sane
      timeout. This is the same cost the suite's own comment already flags
      ("the 55s yield cost is worth its own investigation; it is not a
      property of the test").

      Do NOT "fix" these by raising the cap. The suite deliberately sets
      `kotlinx_coroutines_test_default_timeout=10s`, and the recorded
      measurement for 90s was WORSE overall — 1336 passed with the two
      Snapshot classes no longer completing, against 1345 at 10s. The real fix
      is the dispatch path, which is its own campaign.
- [x] B4. coroutines and datetime CENSUSED — this was the missing
      information; neither had been measured before.

      **coroutines: 1073 passed / 141 failed / 6 did not complete across 148
      files.** Shapes: `Vm::call_member X on X` 35.5% (50 — expect a handful
      of dispatch roots, not 50 bugs), `Vm::get_field` 7.8%,
      `unresolved global` 7.8%. Worst files: `CombineTest` 84/28,
      `ChannelUndeliveredElementFailureTest` 0/13, `ParentCancellationTest`
      3/8, `BufferedChannelTest` 4/7, `MergeTest` 8/6.

      **CombineTest's 28 (26 of them one shape) — ROOT FOUND.** A bare call
      to an EXTENSION overload, made from inside an override of an abstract
      member extension, picks a same-named VARARG overload instead. Repro:
      `scratchpad/abstractext.kt`, two tests that differ only in how the
      override delegates:

        - `combine(this, other, transform)` (top-level 3-arg form) PASSES —
          binds `combine#2954`, params=3, correct;
        - `combine(other, transform)` (extension form, receiver implicit)
          FAILS — binds `combine#2963`/`#2968`, params=2, which are
          `combine(vararg flows: Flow<T>, transform: (Array<T>) -> R)`. The
          vararg body then iterates what it thinks is a flow array:
          `Vm::call_member iterator on kotlinx.coroutines.flow.SafeFlow`.

      The right target is `combine#2953`, `kind=top_level_extension`,
      params=3 (receiver + 2). klio prefers the exact-arity plain candidate
      over the receiver-bound extension.

      The discriminator kotlinc uses is available and cheap: the trailing
      lambda has TWO parameters (`{ a, b -> }`), and the vararg overload's
      transform takes ONE (the `Array<T>`), so the vararg candidate is not
      applicable at all. klio already has lambda-arity machinery
      (`fitsTrailingLambda`, `argLambdaBroadMasks`) — the bare-call ranking
      does not consult it here.

      ATTEMPTED AND REVERTED, with two useful eliminations:

      1. The discriminator is NOT a lambda literal's header. In the real code
         the argument is `transform` — the override's own function-typed
         PARAMETER — so any check keyed on `args[li] == .Lambda` never fires.
         The arity is still statically available, from that parameter's
         declared type via `argDeclTypeRefLazy`.
      2. The failing call does not pass through `resolveBareCall`'s
         `cast_pick` pre-picks at all. An additive
         `overloadPickByLambdaArity` there was traced against the real repro:
         every site it sees carries `want=3` or `want=4` (the sibling test's
         3-argument call), never the failing `want=2`. So the 2-argument
         extension call is resolved on a DIFFERENT path — find that path
         first.

      **ROOT CONFIRMED — it is the INLINE SPLICE path, and it connects to
      B15.** The vararg overload is

          public inline fun <reified T, R> combine(
              vararg flows: Flow<T>,
              crossinline transform: suspend (Array<T>) -> R): Flow<R>

      i.e. `inline` with a `reified` type parameter, so the call is resolved
      by the splice path, not by `resolveBareCall` — which is why the
      pre-pick experiment above never saw it. `KLIO_INLINE_PICK=combine`
      against the repro prints

          [ipick] combine n=2 chain0=Flow: recv=-/owner=- recv=-/owner=-

      Two candidates, BOTH receiverless — the two vararg forms. The correct
      target, `Flow<T1>.combine(flow, transform)`, is a plain `public fun`
      and therefore is NOT in the inline candidate set at all. The splice
      picks a vararg by shape and its body iterates `flows`.

      Why B15's `ambiguousByParamTypes` does not catch it: that check
      compares the inline candidates against EACH OTHER, and these two are
      alike; the candidate that should win is absent from the set. Its
      reified exemption is also live here (both varargs declare
      `reified T`), so even a type-based comparison would decline to act.

      The rule that fits: with a receiver in scope (`recv_chain != null`) and
      NO inline candidate declaring a receiver, a same-named non-inline
      extension whose receiver matches the chain should win — decline the
      splice. `inline_state.zig` cannot implement it (it imports only ast,
      decl, span and runtime — no module), so the decline has to sit at a
      CALLER, which has the `FuncBuilder`.

      THIRD ELIMINATION. The decline was implemented at the main splice site
      in `inline_call.zig` (the one that calls `inlineFnAstForRecvExt` with
      `call_shape`/`recv_chain` around line 1405) and traced: it never fires
      for `combine`. So that entry point is not on the failing call's path
      either. `inlineFnAstForRecvExt` IS entered — `[ipick]` prints — so the
      splice decision arrives through one of the OTHER entries:
      `inline_state.zig:497` (`inlineFnAstFor`'s wrapper) or
      `inline_call.zig:856` (the reified-probe helper). Instrument those two
      next; do not re-attempt the 1405 site.

      Paths now ruled out for this bug: `resolveBareCall`'s cast_pick
      pre-picks, and the 1405 splice site.

      For the record, at the site that does reach the pre-picks the candidate
      shapes are exactly as expected: `#2953 nparams=3 base=1 p0=this` (the extension),
      `#2954 nparams=3 base=0 p0=flow`, `#2963`/`#2968 nparams=2 base=0
      p0=flows` (the varargs). So the candidate set is right and only the
      ranking is wrong.

      Plain `combine` calls in every form resolve correctly today
      (`scratchpad/combine.kt` — extension, 3-arg and explicit vararg all
      pass), so whatever changes must not disturb them.

      The 0/13 file looked like one root but is not: under the census's real
      invocation its failures are ordering assertions — `Too few unhandled
      exceptions`, `Should not be reached, 'expect' was not called yet` —
      i.e. kotlinx's `expect(n)` execution-order helper disagreeing with
      klio's scheduling. Behavioural semantics (undelivered-element handlers,
      cancellation ordering), not a mechanical fix. Note the standalone run of
      that file reports `unresolved global runTest` instead, which is a
      harness artefact and NOT the real failure — always census it.

      **datetime: 457 passed / 62 failed across 56 files.** Shapes are spread:
      `exception` 24%, `IllegalStateException: Check failed.` 13%,
      `Vm::call_member` 11%, and 5 cases of
      `Expected DateTimeArithmeticException ... but was
      IllegalArgumentException` (a wrong exception TYPE — likely cheap).
      Two more assert `Expected <UTC>, actual <null>` and
      `Expected <America/New_York>, actual <null>`, so timezone lookup
      returns null — a bounded, concrete cluster worth taking first.
      Worst files: `DateTimeComponentsFormatTest` 7/13,
      `DateTimeComponentsSamples` 15/10, `InstantTest` 23/6,
      `TimeZoneTest` 8/5.

      **CORRECTION — datetime's `LocalDateTime(2008, 1, 1)` failures are a
      KLIO BUG, not upstream skew.** An earlier entry here claimed skew
      because no constructor or top-level factory in the checkout takes three
      arguments. That was wrong: the submodule is pinned at the release tag
      v0.8.0, and `TimeZoneTest.kt:252` declares its own helper —

          private fun LocalDateTime(year: Int, month: Int, day: Int) =
              LocalDateTime(year, month, day, 0, 0)

      so the call binds that private MEMBER function. klio instead reports
      `Vm::call_member invoke on kotlinx.datetime.LocalDateTime.Companion`.

      Root: a private member function named after a class loses a bare call
      when same-named TOP-LEVEL factory functions also exist. Repro:
      `scratchpad/memberfactory2.kt` — with the factories present the call
      fails (`unresolved global Stamp`); delete them
      (`scratchpad/memberfactory.kt`) and the member helper binds correctly.
      kotlinx-datetime declares exactly that combination: two
      `@LowPriorityInOverloadResolution` top-level `LocalDateTime(...)`
      factories beside the class.

      NARROWED FURTHER, and the earlier reading of it was wrong too. Split
      into two tests (`scratchpad/memberfactory3.kt`), the private member
      helper is NOT the problem:

        - the 3-argument call, which binds the private member helper, PASSES;
        - the 5-argument call, which must bind the class constructor or a
          top-level factory, FAILS with the real error.

      So the member helper merely shadows the NAME, and a call whose arity it
      cannot take should fall through to the class. The runtime audit shows
      what happens instead: `arm=member depth=0` misses by arity, then the
      GLOBAL arm resolves the class name to `Companion.invoke` rather than
      constructing the class — `Vm::call_member invoke on Stamp.Companion`.

      Attempted and REVERTED: gating `shadowedByClass`'s
      `enclosingHasMemberNamed` on `callableMemberApplicable(name, nargs)`.
      It has no effect — that helper answers true here, falling back to name
      presence — and the emit stays `class_or_factory_call`.

      PINNED with `KLIO_MISS_TRACE`. The member arm behaves correctly:

          [pmo] `Stamp` decline=oversupply eff_args=5 params=3
          [rim2] collected=1 picked=false args=5
          [extfb] name=Stamp simple-name fids=1 want=6 args: Int Int Int Int Int
          [extfb]  fid=8356 shape-skip nparams=6
          [miss] call_member `Stamp` total miss

      The 3-param member declines on oversupply, as it should. The only
      fallback consulted afterwards is `extfb`, which considers EXTENSIONS
      only — it skips the top-level factory because that is a plain function
      (`params[0].name != "this"`), which is correct for what `extfb` is for.
      Nothing then tries the plain top-level function or the constructor, and
      the call ends as a total member miss that surfaces as
      `Companion.invoke`.

      What is CONFIRMED stops there: the member walk ends in a total miss,
      and the failure surfaces as `call_member invoke on Stamp.Companion`.

      What is NOT confirmed — and an earlier draft of this entry wrongly
      asserted it — is that `CallMemberOrGlobal` has no member-to-global
      fall-through. It does: `exec_call.zig` runs a global arm after the
      member walk ("Overloaded top-level function: select by runtime arg
      types").

      NARROWED to that global arm, with the surrounding logic cleared. A gate
      making `shadowedByClass`'s `enclosingHasMemberNamed` respect
      `callableMemberApplicable(name, nargs)` WAS live this time (an earlier
      attempt tested against a stale harness and looked inert):

          [sbc2] Stamp nargs=3 enclHas=true callableApplicable=true  …
          [sbc2] Stamp nargs=5 enclHas=true callableApplicable=false …

      With it, the 5-argument call stops being shadowed by the 3-argument
      member and the error moves from `call_member invoke on Companion` to
      `unresolved global Stamp`. Following it further: `shadowedByClass`'s
      tail then correctly answers "not shadowed", because the top-level
      factory IS applicable (`required=5, total=6` for a call of 5), so the
      call routes to `CallMemberOrGlobal` — and its GLOBAL arm fails to bind
      that applicable factory.

      So the defect is in the global arm binding a same-named top-level
      factory when a CLASS shares the name. The `shadowedByClass` gate was
      reverted: it is arguably more correct but fixes nothing on its own and
      carries dispatch-wide risk. Fix the global arm first, then re-evaluate
      whether the gate is still wanted.

      Worth at least the three `TimeZoneTest.newYorkOffset*` cases and
      probably more of the 62.

      Timezone lookup itself is FINE and was checked directly: `TimeZone.UTC`,
      `TimeZone.of("UTC")`, `TimeZone.of("America/New_York")` and
      `availableZoneIds` (496 entries, contains New York) all resolve. The
      `Expected <UTC>, actual <null>` failures come from elsewhere, so do not
      start at the tz database.

## Suites at zero

`atomicfu`, `io`.

**`androidx_collection` is NOT at zero, and the gate cannot see it.**
`ValueClassListTest.kt` fails two cases, but in the batched run the file
exceeds the 300s child timeout and is counted as *incomplete* instead — so
`max_failed = 0` passes on a timeout rather than on a clean result. Run it
solo (`--filter ValueClassListTest --jobs 1 --timeout 500`) to see
61 passed / 2 failed. Both reproduce on the pre-change binary, so they
predate the factory-head fix. Any suite whose ceiling is satisfied while a
file times out is reporting a floor, not a result.

**The `stdlib` census and the stdlib sweep measure different surfaces.**
The sweep reports 117 files / 0 failures; the census reports 121 files /
2242 passed / **281 failed**, identical before and after the factory-head
fix. The sweep's green is real but partial — it is not evidence that stdlib
is at zero.

- [x] B16. **combine's `Iterable` overload — coroutines 26 -> 0.** A bare
      call inside an extension can bind a same-named *extension* using the
      enclosing receiver. `combine(listOf(this, other)) { … }` inside a
      `Flow<T1>.combineLatest` override did exactly that: `listOf(...)` had
      no static type, so the binary extension
      `Flow<T1>.combine(flow, transform)` was never disproved and the
      enclosing `this` bound it — passing the list itself as `flow`.
      `combineInternal` then collected a `List`, surfacing as the
      misleading `unresolved global collect` (the miss is a *member* miss on
      `kotlin.collections.List` falling through to a global lookup).
      The argument-shape pass already derived a type for a `.Call` argument
      carrying explicit type arguments; it now also derives one for stdlib
      collection factories, whose names fix their own result head.
      `CombineTest` 86/26 -> 112/0; coroutines census 1075/139 -> 1101/113.

      Bisection that found it: V1 `combine(listOf(this, other))` in a
      generic extension FAILS; V2 hoisting the list to a local passes; V3
      the same call with concrete types FAILS; V4 the same call with the
      flows as plain parameters passes. Generics were irrelevant — the
      discriminator is `listOf(this, …)` written inline as the argument of
      a bare call inside an extension. `KLIO_BARE_TRACE` named the culprit
      outright: `combine#2940 params=3 ext=true`.

      Dead end worth not repeating: `staticArgHead`'s `.Call` arm looks like
      the place to fix this, but all three of its call sites serve LOCAL fn
      overload selection only. A `factoryResultHead` added there is inert
      for module and pack candidates.

- [x] B17. **data/value-class `hashCode` ignored a property's override.**
      The generated `hashCode` folded `valueStructuralHash` — a pure hash
      with no member dispatch — so a property whose class overrides
      `hashCode()` had the override ignored. androidx's
      `value class TestValueClassList(val list: LongList)` must hash as
      `LongList.hashCode()` (walks `_size`); the structural hash read the
      fixed-capacity backing array instead, so `removeAt`/`clear` left it
      unchanged. The sibling `equals` already dispatched through
      `deepValueEquals`, so the two conventions disagreed — that mismatch is
      the tell. `ValueClassListTest` 61/2 -> 62/1. Guarded by
      `examples/value_class_hash_delegation.kt`, whose negative control
      flips 5 of 7 lines when the fix is reverted.

- [x] B18. **serialization 81 -> 71, in two roots.**

      *Primitive element descriptors.* `descriptorForDeclaredType` minted a
      fresh `PrimitiveSerialDescriptor("kotlin.String", …)`. Upstream forbids
      exactly that — `checkNameIsNotAPrimitive` rejects reusing a primitive's
      serial name — so EVERY element of a primitive type threw. Handing back
      the builtin serializers' own descriptors fixed it: 81 -> 76. This also
      un-broke `examples/serial_descriptor_shape.kt`, which was failing on
      main with NO pinned output, so nothing guarded it.

      *Annotation arguments at runtime.* `ClassDef` retained only annotation
      NAMES, so no consumer could read an argument off a class annotation.
      It now carries the resolved records too, through the baked image
      (format 47 -> 48). `@SerialName` on a class replaces the qualified-name
      default: 76 -> 71.

      THE EARLIER ATTEMPT AT THIS FAILED FOR A KNOWABLE REASON. Adding the
      field once took this census 57/81 -> 0/28, and the note then read
      "unpopulated field still 0 => layout". That was right: `ClassDef` is
      baked into the pack IMAGE, so a field addition invalidates every
      installed pack. Bumping `FORMAT_VERSION` (so an old image is REJECTED
      rather than misread) and clearing the suite's scratch home before
      re-censusing makes it land clean.

      Property-level `@SerialName` also reached the descriptor via a new
      `__klsx_ctorParamSerialNames` intrinsic — the descriptor reports WIRE
      names while the declared names keep addressing the instance. On its own
      that moved NO test (every failure in that cluster was class-level), but
      it is correct and JSON encode/decode already honoured it.

      MEASUREMENT TRAP, cost an hour: ktor appeared to regress 448/2 -> 447/3
      and held there over four runs. It is not a regression —
      `WriterReaderTest.testWriterOnCancelled` is flaky under full-suite load
      on BOTH sides (448 and 447 alternate) and passes 3/3 in isolation. The
      apparent stability of the pre-change side was an artifact of running
      with a fresh pack bake each time, which shifts the timing. Baseline a
      suspected regression with the IDENTICAL protocol, `--no-install`
      included, before believing it.

- [x] B19. **A call reached a same-named local instead of the function —
      coroutines 113 -> 104.** Kotlin resolves a call against FUNCTIONS; a
      variable answers one only when its type carries an `invoke` operator.
      klio already proved a local non-invocable when its initializer was a
      literal or a CONSTRUCTOR, but a local initialized by an ordinary CALL
      had no such proof, so it captured the call and was invoked as a value.
      Judged now from the initializer function's declared return type.

      Pure-source repro, no packs involved:

          class Box(val n: Int)
          fun mk(): Box = Box(1)
          fun box(body: () -> Int): Box = Box(body())
          val box = mk()
          box { 7 }        // Vm::call_member `invoke` on `Box`

      kotlinx's flow tests write `val flow = flowOf(...)` beside the
      `flow { … }` builder throughout, which is why this cost them `filter`,
      `merge`, `flatMapLatest` and more. Guarded by
      `examples/local_shadows_function_call.kt`, whose negative control
      throws when the fix is reverted, and which also pins the case that must
      NOT change: a local whose type declares `invoke` still answers the call.

      HOW IT WAS FOUND, after three wrong turns worth not repeating. The
      first framing was "an inline splice resolves a bare name against the
      caller's locals" — WRONG; no splice is involved, a direct builder call
      fails identically. The second was "a local shadows a PACK function",
      which the `val flow = 42` control disproved (a same-named Int local is
      fine) and the pure-source repro above finally killed: it is about the
      INITIALIZER's shape, not the pack. Fixes were attempted at
      `lowerValueInvocation` and at `lowerCallGeneral`'s typed-call arm; both
      were reverted, and probes at each showed neither is reached.

      MEASUREMENT TRAP that cost several cycles: those probes printed nothing
      because `zig build` builds `zig-out/bin/klio` while the repros were run
      on `zig-out/bin/klio-harness`, which was never rebuilt. A probe that
      prints nothing is evidence of a stale binary before it is evidence
      about the code. (`runtime.envOnce` keys are per-name and fine; both
      `KLIO_RLP_TRACE` and `KLIO_SHADOW_TRACE` are already taken, though, so
      a reused key mixes with an existing site's output.)

- [x] B20. **Vararg receiver-lambda literals lost their receiver — datetime
      55 -> 37.** A receiver lambda carries its receiver as a CAPTURE, not a
      parameter (`src/ir/lower/lambda_body.zig:621`), so the call site must
      supply it at invocation. Two recorders compute what that needs — the
      lambda's expected arity and its bound receiver type — and both handled
      only two argument shapes: a trailing lambda with
      `args.len <= params.len`, and `args.len == params.len`. A vararg call
      matches NEITHER, because two arguments never equal one declared
      parameter. Both literals then kept their implicit `it`, the closure
      reported one value parameter, and the VM's rule at
      `host_call_value.zig:2087` — bind the extra leading argument when a
      receiver-carrying closure is called with `n_params + 1` arguments —
      could not fire. `this` stayed whatever the enclosing scope had.

      kotlinx-datetime's `alternativeParsing(vararg others: T.() -> Unit,
      primary: T.() -> Unit)` carries RFC_1123's optional day-of-week and
      alternative offsets, so every such parse failed. Guarded by
      `examples/vararg_receiver_lambdas.kt`, which also pins the
      vararg-plus-trailing-parameter shape; its negative control throws.

      THE EXPERIMENT THAT CRACKED IT, after two earlier attempts stalled:
      two literals against two DECLARED parameters works, the same two
      against a `vararg` fails, and the lambda lowering inputs are IDENTICAL
      on both sides (`rec=Sink params=1 implicit_it=true` for all four). That
      ruled out the lambda and the receiver-type recording — which is exactly
      what both earlier attempts had been fixing — and pointed at the
      INVOCATION. The missing piece was the ARITY recorder, not the receiver
      recorder: without arity 0 the implicit `it` survives and the receiver
      rule is unreachable. Fixing the receiver recorder alone (twice, through
      two different helpers) changed nothing, which is why it read as a
      downstream defect.

      Note: the lowered vararg parameter carries the ELEMENT type directly
      (`Function0`), not a materialized array, so `varargElementRef` is the
      wrong accessor — take the parameter type as-is first.

      Still wrong, separately and pre-existing: assigning a vararg element to
      a typed local first (`val t: Sink.() -> Unit = x; t(s)`) returns an
      empty result rather than throwing. Unchanged by this fix.

- [x] B21. **androidx 1 failed + 1 timeout -> 0/0.** A lambda literal that
      ANNOTATES its parameters states their types, and kotlinc uses them to
      drop a candidate that cannot accept the literal. klio discarded that
      entirely: `ArgShape.lambda_param_types` existed, unpopulated and unread.

      Inside `buildString { … }` the innermost receiver is a StringBuilder, so
      a bare `forEachIndexed { index: Int, element: TestValueClass -> … }`
      bound `CharSequence.forEachIndexed` and then iterated the builder its own
      body was appending to. `ValueClassListTest.string` ran ~330s and died,
      and because the FILE timed out its failures counted as did-not-complete
      — which is how a real failure sat behind a `max_failed = 0` ceiling.

      Two parts, both needed. The ARGUMENT side populates the shape from the
      literal's `param_tys` and refutes a definite mismatch (two different
      builtin scalars, or a scalar against a declared class); that drops the
      CharSequence candidate. The RECEIVER side drops the `Iterable` one:
      inside a receiver lambda the receiver types are not "known" in the
      plain-method-body sense, so the existing `extReceiverPlausible` gate was
      skipped altogether; it now runs there too, disqualifying a candidate
      implausible for EVERY receiver in scope.

      THE RECEIVER RULE MUST STAY GATED on the enclosing class actually
      declaring a member of that name. The ungated version regressed private
      stdlib extensions on `String` called from inside stdlib:

          DurationTest.parseDefaultFailing  Vm::call_member `parseDigits` on `kotlin.String`
          UuidTest.parse                    Vm::call_member `uuidCheckHyphenAt` on `kotlin.String`

      Only the STDLIB SWEEP catches that — all six censuses stayed green
      through it. Any future change to this gate must run the sweep.

      Order of attempts, for anyone extending this: runtime-only refutation in
      the `extfb` tail does nothing here (the pick is made statically);
      argument-side alone moves the pick from `CharSequence` to `Iterable`;
      receiver-side alone cannot drop `CharSequence` (a StringBuilder IS one).
      Both, plus the member-exists gate, is the working combination. Guarded
      by `examples/lambda_param_types_pick_overload.kt`, which also pins the
      case that must NOT change — the CharSequence extension still binds on a
      real StringBuilder receiver.

### Open: cross-test pollution in DateTimeComponentsFormatTest

That one file carries 12 of datetime's 35 failures, and at least SIX of them
are not independent failures — they are victims of an earlier test in the
same file.

Run alone, `testSpecialNamedTimeZones` and `testValidSinglePartTimeZones`
PASS. Run with `testZonedDateTime` they fail:

    testZonedDateTime,testSpecialNamedTimeZones    2 tests, 0 passed, 2 failed
    testErrorHandling,testSpecialNamedTimeZones    2 tests, 1 passed, 1 failed
    testRfc1123,testSpecialNamedTimeZones          2 tests, 2 passed, 0 failed

So `testZonedDateTime` specifically poisons them — `testErrorHandling`, which
also fails, does not. The victims all report `Expected <UTC>, actual <null>`
and friends: a `timeZoneId()` parse that silently yields null.

NOT the trie: `NamedUnsignedIntParser`'s trie is per-instance, built in `init`
and read-only in `consume`, and each `DateTimeComponents.Format { … }` builds
its own.

NOT the parse loop either. A direct repro — greedy parse, then
`testZonedDateTime`'s combined format over all 496 `availableZoneIds`, then
greedy again — reports ZERO failures and the greedy check still works
afterwards. So the trigger is earlier in that test than the loop: the
`format.format { setDateTime(...); setOffset(...); timeZoneId = berlin }`
write, or the `toLocalDateTime()` / `toUtcOffset()` reads before it.

Next step is to bisect `testZonedDateTime` statement by statement against a
following greedy parse. Worth doing before counting datetime's remaining
failures as independent: the true count is lower than 35, and this is one
root, not six.

### Open: an inline MEMBER called bare inside a receiver-lambda

`ValueClassListTest.string` still fails, and it is the reason the file
blows the 300s child timeout — `toString()` runs ~330s solo before dying.
Reduced to a five-line repro:

    class Holder(val n: Int) {
        inline fun eachInline(block: (Int) -> Unit) { for (i in 0 until n) block(i) }
        fun eachPlain(block: (Int) -> Unit) { for (i in 0 until n) block(i) }
        fun f(): String { val sb = StringBuilder(); with(sb) { eachInline { sb.append(it) } }; return sb.toString() }
    }

`eachPlain` in that position works; `eachInline` dies with
`Vm::call_member eachInline on kotlin.text.StringBuilder`. Called bare with
no inner receiver, or with an explicit `this@Holder.`, or through a plain
(receiverless) lambda, it also works — the trigger is precisely a bare call
to an inline MEMBER of an enclosing class where the innermost implicit
receiver is a different type. In androidx the same call is inside
`buildString { … }`, and the spliced `for (i in 0 until _size)` then read
`_size` off the wrong object and looped unbounded (the spin trace shows the
index climbing 24124 -> 32316 -> 40508 at line 353).

Both routes fail: the static path declines to splice, and the runtime
member walk cannot recover, because inline members are not reachable
through its outer-receiver fallback the way `eachPlain` is.

ATTEMPTED AND REVERTED: adding an `inner_recv_not_owner` term to
`bareInlineNeedsSplice` (splice when the innermost receiver is not the
inline member's owner). The gate fires exactly as intended — traced
`owner=Holder recvty=kotlin.text.StringBuilder irno=true tower=2
[kotlin.text.StringBuilder] [Holder]` — and behavior does not change at
all, so the decision is discarded downstream. Note when tracing this that
`bareInlineNeedsSplice` is ALSO called from `inlineResolveAudit`, so two
prints appear per site and only the one carrying a non-empty tower is the
lambda-body context. Next lead is the consumer of
`inlineTargetForBareCall`, not the gate.

- [x] B13. **atomicfu 4 -> 0.** All four were harness artefacts: `C.kt` used
      `D`, `GetArrayElementTest` used `AtomicArrayClass`,
      `SetArrayElementTest` used `IntBox`, each declared in a sibling file
      carrying its own `@Test`s. `.whole_source_set = true` (the mechanism
      datetime already used) fixed all four. Floor 63 -> 67, ceiling 8 -> 0.
- [x] B14. **io 34 -> 9.** Two steps. First, klio supplied the two `expect`s
      kotlinx-io's own tests declare (`tempFileName`,
      `String.asUtf8ToByteArray`) — 21 failures, none of them interpreter
      gaps. `asUtf8ToByteArray` must route to kotlinx-io's own
      `commonAsUtf8ToByteArray()`, NOT the stdlib's `encodeToByteArray()`:
      the stdlib substitutes U+FFFD and these tests assert byte-for-byte on
      deliberately malformed input. Second, an extension namesake no longer
      diverts a bare spread call away from the enclosing member (B15).
- [x] B15. **Extension namesake diverting a bare spread call.** `Utf8Test`
      declares both `assertCodePointDecoded(String, vararg Int)` and
      `Buffer.assertCodePointDecoded(Int, String, Int)`; the latter made the
      former's own `assertEncoded(hex, *codePoints)` look like a global, so
      the spread path skipped its member branch and fell through to a
      first-class value read (`Vm::get_field ... on Utf8Test`). The guard now
      asks for a NON-EXTENSION bare-call candidate, so a genuine top-level
      namesake (`maxOf(a, *rest)`, the case the original guard protected)
      still wins. Spread-forwarding alone and the name clash alone both
      resolve correctly — only the combination failed.
- [ ] B16. **io's last 9.** Seven are lone-surrogate cases in `Utf8Test`
      (`danglingHighSurrogate`, `lowSurrogateWithoutHighSurrogate`,
      `highSurrogateFollowedByNonSurrogate`, `doubleLowSurrogate`,
      `doubleHighSurrogate`), all failing as
      `IndexOutOfBoundsException: index N out of bounds (length N)` — the
      decoder yields MORE code points than the test expects. NOT a
      representation limit. Plus two singles (`rawSourceSample`,
      `unsafeSamples`).

      RULED OUT, each checked directly rather than assumed — do not re-test
      these:
      - String representation. `"\ud800".length == 1` and `code == d800`;
        a real pair splits into `d83d`/`de00`. Lone surrogates round-trip.
      - `Char` range containment. `'\ud800' in '\ud800'..'\udfff'` is true,
        `!in` is false, and a char below the range is excluded.
      - `Int` range containment inside a `when`, which is the shape
        `commonWriteUtf8CodePoint` uses: `0xd800`, `0xdc00`, `0xdfff` all
        select the surrogate branch; `0xd7ff` and `0xe000` fall through to
        the 3-byte branch. Correct.
      - The encoder's branch structure. Replicating
        `commonAsUtf8ToByteArray`'s `when` standalone yields `[63]` (`?`) for
        both a lone high and a lone low surrogate, which is exactly what the
        test expects.

      So the arithmetic and the control flow are right, and the fault is
      further down — in `Buffer`/`UnsafeBufferOperations.writeToTail` (the
      surrogate branch writes through it) or in `readByteArray`. The
      symptom is a 3-byte result where 1 is expected, i.e. the surrogate
      branch's single `?` byte is not what lands in the buffer. Start there.

- [x] B17. **io 9 -> 2: `lastIndex`/`indices` vs `length`.** See the commit;
      the eliminations are recorded there.
- [x] B18. **Classes nested inside a LOCAL class were never registered.**
      `registerClass` synthesised the local class's own ClassDef and lowered
      its methods but never walked `class.members`, so a class declared inside
      a local class was unresolvable — `unresolved global RC4Key` in
      kotlinx-io's `rawSourceSample`, which declares a decrypting source
      inside a test function holding an `inner class` for its cipher key.
      Fixed for BOTH registration paths (captured and uncaptured), plain
      nested and `inner` alike, recursing for deeper nesting.

      The "still fails under `klio test`" note in the commit was WRONG and
      is corrected here: `zig-out/bin/klio-harness` was stale. Rebuilt, the
      same source passes under `test` too. (Second time this trap bit in one
      session — `zig build` does not rebuild the harness; `zig build
      klio-harness` does.)

      `rawSourceSample` now gets PAST registration and fails one layer
      deeper, at B20.
- [x] B20. **A constructor parameter of a class nested in a local class is
      not bound in its `init` block.** FIXED — the init thunks now declare the
      primary params (as the `$super$arg$` thunks already did) and the
      constructor args are threaded to the call. io 2 -> 1.
- [ ] B22. **io's LAST failure: a local extension function shadows a
      same-named member overload it cannot answer.** `unsafeSamples`
      declares a LOCAL `fun Buffer.writeULEB128(data: UIntArray)` whose body
      calls `writeULEB128(data.size.toUInt())` — the class's member extension
      `writeULEB128(value: UInt)`. klio binds the local to ITSELF, so the
      UInt lands in the UIntArray parameter and it recurses until the eval
      depth blows. Repro: `scratchpad/localoverload.kt`, where the same shape
      surfaces one step earlier as `Vm::get_field size on kotlin.Int`.

      The spot is `prefer_member` in `lower/expr.zig`, which is disabled
      whenever `isLocalFn`/`isLocalExtFn` holds — unconditionally, without
      asking whether the local is APPLICABLE to this call. Arity cannot
      discriminate here (both take one argument), so the fix needs the
      argument's static type against the local's declared parameter type.

      ATTEMPTED AND REVERTED. A gate was added at `prefer_member` allowing
      the member to win when the local's declared parameter type provably
      rejects the argument (`localFnParamTys` for the local,
      `staticCallReturnTypeRef` for a call argument like
      `data.size.toUInt()`). It never fires: traced against the real file,
      `localFnRejectsArgs` is not reached at all, because neither
      `isLocalFn(name)` nor `isLocalExtFn(name)` holds at that site. So the
      `prefer_member` decision is NOT where this call is decided either —
      the same lesson as the datetime and CombineTest chases.

      Both pieces the fix needs do exist and are worth reusing when the right
      site is found: `b.localFnParamTys(name)` gives the local's declared
      parameter types, and `static_call_type.staticCallReturnTypeRef(b, expr)`
      gives a call argument's static type. Arity cannot discriminate here —
      both candidates take one argument — so a type comparison is required.

      Paths ruled out for this bug: `prefer_member` in `resolveBareCall`.

      LIVE SITE FOUND, and a second attempt reverted. `KLIO_OR_AUDIT` shows
      the call emitted from `member_or_local_callable` as `CallMemberOrValue`
      with the local as fallback, and the runtime taking `arm=value`. A gate
      was added there (emit a plain `CallMember` when the local's declared
      parameter type rejects the arguments) and traced — it correctly
      declines, because the recorded parameter type MATCHES the argument at
      every site it sees:

          [localshadow] writeULEB128: ah=UInt      ph=UInt
          [localshadow] writeULEB128: ah=UIntArray ph=UIntArray

      CORRECTION — an earlier version of this entry blamed a simple-name
      collision in `local_fn_param_tys`. That was wrong. Instrumenting the
      gate's ENTRY (rather than its verdict) shows it is reached exactly
      twice, once per test method, and both hits are the OUTER calls:

          [gate] writeULEB128 in_fn=writeUleb128      shape_known=true …
          [gate] writeULEB128 in_fn=writeUleb128Array shape_known=true …

      The INNER call — `writeULEB128(data.size.toUInt())` from inside the
      local `Buffer.writeULEB128(UIntArray)` body, the one that recurses —
      never reaches `member_or_local_callable` at all. So that site is not
      where it is decided either, and the param-type table is not implicated.

      Sites now ruled out for this bug: `prefer_member` in `resolveBareCall`,
      and `member_or_local_callable`. Next: instrument the lowering of a bare
      call made from inside a LOCAL EXTENSION's body — that body is lowered
      through its own builder, and whatever emits its calls is the live path.
      `KLIO_OR_AUDIT` reported no emit line for the inner call, so it is
      likely emitted by a site with no audit hook; add one before guessing. `private inner class RC4Key(key:
      String)` reads `key` — a plain parameter, not a property — from an
      `init` block, and klio treats it as a field:
      `Vm::get_field key on RC4Key`. Repro:
      `scratchpad/innerparam2.kt`. This is io's `rawSourceSample`, the last
      failure there besides `unsafeSamples` (a stack overflow).
- [ ] B21. **A nested local class named `Key` collides.** The same repro with
      the class named `Key` fails differently —
      `InstantiationError: Cannot create an instance of an interface: Key` —
      so the name resolves to some other `Key` in scope rather than the
      user's nested declaration. Renaming to a unique name gives B20's error
      instead. Per the project's root-cause rule a user declaration must win
      such a clash, so this is a real bug and NOT to be worked around by
      renaming. Found by accident while reducing B20.
- [ ] B19. Qualified access to a nested class of a local class
      (`Decrypting.Marker()`) fails with
      `Vm::call_member Marker on kotlin.reflect.KClass`. Separate from B18 —
      reaching the same class from INSIDE the local class works. Found while
      writing B18's example.

- [ ] B23. **datetime: `alternativeParsing` formats its ALTERNATIVES once
      there are two or more.** The alternatives are parse-only; only the
      primary block formats. klio emits all of them:

          zero-alt  = M     (correct)
          one-alt   = M     (correct)
          two-alt   = ABM   (should be M)
          three-alt = ABCM  (should be M)

      Repro: `scratchpad/altfmt3.kt`. Real symptom, `testRfc1123`:
      `Expected <… 11:05:30 GMT>, actual <… 11:05:30 UTZGMT>` — the `UT` and
      `Z` parse-alternatives leaking into the formatted output.

      Upstream is correct on both sides:
      `AlternativesParsingFormatStructure.formatter()` returns ONLY
      `mainFormat.formatter()`, and `appendAlternativeParsingImpl` builds each
      alternative in its own `createEmpty()` builder.

      RULED OUT: `createEmpty()` (the sibling `appendOptionalImpl` uses the
      same `createEmpty().also { … }` pattern and formats correctly — the
      `GMT` in that same output comes from it), and generic spread-plus-named
      argument binding (`scratchpad/spreadnamed.kt` reproduces the exact call
      shape — `impl(*alts, mainOne = primary)` — in plain Kotlin and is
      correct at 0, 1, 2 and 3 alternatives).

      So the trigger is narrower than either: it needs the datetime builder's
      shape — a GENERIC receiver-lambda parameter (`ActualSelf.() -> Unit`)
      plus the `as Array<out AbstractDateTimeFormatBuilder<*, *>.() -> Unit>`
      cast that `alternativeParsing` performs before forwarding. Start by
      reproducing THAT, not the plain vararg.

      Also of note: klio warns at the call site that it "may type its lambda
      arguments incorrectly" for an unimported `alternativeParsing` — but the
      failure is identical with the import present, so the warning is a red
      herring here.

      REDUCED TO PURE KOTLIN, no datetime involved
      (`scratchpad/vr_probe.kt`):

          fun f(vararg blocks: Sink.() -> Unit) { … blocks[i](s) … }
          f({ emit("A") })                    // works
          f({ emit("A") }, { emit("B") })     // FAILS

      Invoking an element of a vararg of RECEIVER lambdas passes the wrong
      receiver once the vararg holds two or more: `emit` dispatches but `this`
      inside it is `kotlin.Unit`
      (`Vm::get_field out on kotlin.Unit`). Zero and one element are correct.
      The loop form is irrelevant — indexed, `for`, and `forEach` all fail —
      and a vararg of PLAIN `(Sink) -> Unit` lambdas is correct at every
      count, so it is specific to the receiver form.

      It is a TYPING defect, and an earlier note here calling it an
      invocation defect was wrong. The discriminator:

          val b1: Sink.() -> Unit = { emit("A") }
          val b2: Sink.() -> Unit = { emit("B") }
          f(b1, b2)                        // WORKS
          f({ emit("A") }, { emit("B") })  // FAILS

      Pre-typed variables are fine, so the vararg packing and the invocation
      are both fine. Only the LITERALS fail: they lower with no receiver
      parameter, so `b(s)` passes the receiver into a 0-parameter lambda and
      `this` inside the body is Unit. With one element the literal IS the
      trailing argument, which the existing trailing-lambda recording covers —
      hence the 0/1-correct, 2+-broken boundary.

      So the fix is to give every lambda landing in a receiver-typed vararg
      the declared receiver. A `recordVarargLambdaReceivers` helper doing
      exactly that was written and hooked into all THREE
      `argLambdaBroadMasks` call sites in `expr.zig`; tracing shows it never
      records for the failing call.

      WHY those sites are not reached: `KLIO_RESOLVE_AUDIT` reports

          inline name=f pkg= arity=2 outcome=deferred reason=vararg_only

      The bare call DEFERS because its only candidate is a vararg, so it never
      takes the static-call path where lambda typing happens — and the emit it
      does take produces no `KLIO_OR_AUDIT` line, i.e. a site with no audit
      hook (the same obstacle the CombineTest chase hit).

      THE TYPING APPROACH IS RULED OUT. A `recordVarargLambdaReceivers`
      helper was eventually landed at the right site — `lowerCallGeneral`,
      found by tracing, after `argLambdaBroadMasks`'s three sites and
      `lowerUnresolvedBareCall` were each tried and traced as unreached —
      and made to work end to end:

          [vr] f: params=1 lastvararg=true lastty=Function0 head=Sink
          [vr-rec] f arg0 span=379..392 had=null
          [vr-rec] f arg1 span=394..407 had=null
          [vr-lam] span=379..392 rec=Sink
          [vr-lam] span=394..407 rec=Sink

      `lowerLambda` receives `recorded_recv = Sink` for both literals, which
      makes `receiver_head` non-null and `lambda_has_receiver` true — and the
      program STILL fails with `this` as Unit at run time. So giving the
      literal its receiver TYPE is not what is missing; the defect is
      downstream of that, in how the receiver-lambda closure is built or how
      an element of the vararg array is invoked. Reverted.

      Note for contrast: the working `f(b1, b2)` case shows `rec=null` at
      `lowerLambda` and works anyway, taking its receiver from
      `peekExpected().function.receiver` at the declaration instead. Compare
      the two closures' shapes — that difference is the remaining lead.

      Sites eliminated: the three `argLambdaBroadMasks` call sites,
      `lowerUnresolvedBareCall`, and receiver-type recording as a whole.

## Traps

- `zig-out/bin/klio` goes stale silently. A pack build against a stale binary
  fails with errors that look like interpreter bugs but are not; the itest
  suites build their own current binary, which is why a suite can pass while
  a hand-run pack build fails. Check the binary's date against recent commits
  before believing a parse error.
- Heavy census suites must be measured **solo**. Concurrent runs skew the
  counts, and compose_plugin's per-class timeout makes it the most sensitive.
