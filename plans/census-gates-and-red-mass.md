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

## Track C — the perf-era regression sweep (opened 2026-08-31)

THE PROCESS HOLE, recorded first: the five perf campaigns (Aug 22-31)
verified every round with compose gate + stdlib sweep + parity +
examples — the seven LIBRARY censuses never ran, and a week of
interpreter-shared-path changes accumulated ~80 invisible failures
(serialization 1, datetime 9, io 4, androidx_collection 26, coroutines
1, ktor 39; atomicfu clean). STANDING RULE from here: any round that
touches shared interpreter paths (dispatch, fields, lowering, GC)
includes the library census gates in its battery before the round is
called green. `KLIO_CENSUS_NAMES=1` (landed 93d2ad1a) makes a red
census name its failing cases.

- [x] C1. datetime 510/9 -> root-caused and FIXED (93d2ad1a): the
      receiver-formed splice default-on (29e052f5, Aug 24) let a bare
      extension call inside a spliced receiver window pair the
      frame-kind fallback head (the enclosing extension's declared
      receiver) with the SUBJECT via sameReceiver — the strict probe
      then treated `with(period)`'s subject as statically Instant and
      bound Instant.offsetIn to the DateTimePeriod
      (`Vm::get_field epochSeconds on DateTimePeriodImpl`). The
      frame-derived hint now anchors to the frame's own implicit this.
      Bisect trail: harness-fast target absent pre-e2192a48 made the
      first git-bisect skip-blind — bisect scripts must fall back to
      `zig build klio-harness`. 14-line repro kept (towersplice.kt).
- [x] C2. COMPLETE 2026-08-31: the final full stack is ALL ZERO —
      coroutines 1299/0, ktor 450/0, serialization 138/0, datetime
      519/0, io 1191/0, androidx 1841/0, atomicfu 67/0, compose gate
      1390/0/0 (645 ratchet), parity, examples, stdlib sweep 117/0.
      All ~80 perf-era regressions closed via five root commits;
      ceilings never rose. Roots landed so far, each bisected
      to its origin commit and fixed at the mechanism:
      - aeac0ef5 (origin bd2deccf): the no-lambda inline splice stands
        in for OVERLOAD RESOLUTION and may only engage on a lone
        candidate — the sole INLINE overload (plusAssign(element: E))
        swallowed its non-inline List sibling; 26 androidx tests.
      - e7754b8a (origin 41b35ffd): member-inline splices park the
        caller member scope so call-site lambda content sees the
        CALLER's nesteds (a private nested TestException ctor fell to
        runtime member dispatch); io's Unsafe pair.
      - e50f8c3b (origin c44295ee): a declared param type mentioning
        the fn's type params records nothing (KSerializer<T> stamped a
        raw T into the reified channel; subclass() registered nothing);
        serialization single.
      - 7fb58485 (origin fa1dc55c era): receiver_is_owner may only
        trust the splice head when the window BOUND the subject, and
        the implicit-receiver walk probes members-only before imported
        extension properties (Kotlin lexical priority — a class member
        outranks an import; CoroutineScope.job was hijacking an
        enclosing val job through a suspend lambda's ambient this);
        coroutines single.
      All four origins are Aug 24-29 receiver-splice-era commits: the
      splice family's hygiene contract (windows must not let owner
      scope, name-keyed picks, declared spellings, or ambient bindings
      leak across the splice boundary) is the recurring theme — check
      it FIRST for any future splice-era regression.
- [x] C3. FIXED dd134970: a registered 1-2-letter class name falls
      through to the hierarchy proof (a class named `I` is a class, not
      a type parameter); the heuristic keeps serving unrecorded
      type-param shapes. Verified zero-collateral on the
      generics-heaviest suites (androidx 1841/0, coroutines 1299/0).

## Track B — the red mass

Failures tolerated by the ceilings, worst ratio first:

The column on the right is where the campaign opened; the one before it is
the last measurement.

| suite | passes | failures | opened at |
|---|---|---|---|
| serialization | 138 | 0 | 57 / 81 — AT ZERO |
| datetime | 519 | 0 | 457 / 62 — AT ZERO |
| coroutines | 1299 | 0 — AT ZERO | 1073 / 141 (+6 DNC) |
| io | 1191 | 0 | 1182 / 9 |
| androidx_collection | 1841 | 0 | 1309 / 15 |
| atomicfu | 67 | 0 | 67 / 0 |
| ktor | 450 | 0 | 448 / 2 |
| stdlib (sweep) | 117 files | 0 | 2301 / 0 |
| compose_plugin | 1375 | concurrency-group flakes | 1375 / 15 |

- [x] B1. CLOSED 2026-08-31 — no failing test names it (suite 138/0). The per-element-annotations gap remains a QUALITY road, recorded here; reopen only when a test fails on it. Original record: **serialization descriptor fidelity.** klio has no serialization
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
- [x] B9. CLOSED 2026-08-31 — the init-order blocker is GONE (B11's kept repro passes on main) and no failing test needs the annotation records (suite 138/0). The plumbing road (annotation_records + FORMAT_VERSION bump, lifetimes checked) stays recorded for when a test names it. Original record: **`@SerialName` on a class — was BLOCKED on the pack format.**
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
- [x] B12. CLOSED BY RECORD (measured net negative; the blocker is cross-file simple-name collision handling — revisit only with that landed). Original record: **`whole_source_set` for serialization: tried, net NEGATIVE.**
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
- [x] B11. CLOSED 2026-08-31 — the kept repro (initorder.kt) passes on main; the defect died in the Aug-22..31 resolution work. Original record: **Top-level property initializers, two defects found while
      chasing B9.** A reduced program with a top-level
      `val M = SerializersModule { polymorphic(Base::class, Base.serializer()) { … } }`
      fails outright with `unresolved global BaseAndDerivedModule` — the file's
      own top-level val does not resolve from `main`. Repro kept at
      `scratchpad/initorder.kt`. This is independent of serialization and
      likely worth more than the descriptor work it was blocking.
- [x] B10. CLOSED 2026-08-31 — no failing test names it (suite 138/0); quality road recorded with B1. Original record: Element descriptors cannot name their types yet. Building one with
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
- [x] B8. CLOSED 2026-08-31: the cluster PASSES in the current gate (1390/0/0) under the declared per-test wall caps, and the dispatch-cost claim is SUPERSEDED — the 616us/1556us figures were remeasured at ~100-133us/yield (A6 rig + 2026-08-31 re-run); the residue is the recorded compute floor (native-floor campaign Task 4: the suite wall IS vpd). Original record: **compose concurrency cluster (11, the last in that suite) — a
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

### Fixed: a property-reference write was stored under a freed name

Root of `DateTimeComponentsFormatTest` (12 of datetime's 35 failures). Three
earlier readings in this file were wrong and are corrected here: it was neither
a premature free, nor a delegated-property READ fault, nor a lost write. The
write LANDED — under a garbage field name.

**Deterministic oracle** — `KLIO_GC_STRESS=1` collects at every safe point and
makes it certain, so no long loop is needed:

    // scratchpad/g4.kt
    val f = DateTimeComponents.Format { timeZoneId(); chars("]") }
    f.format { timeZoneId = "Europe/Berlin" }        // a prior format IS required
    f.parse("America/New_York]").timeZoneId          // null under stress

**The mechanism.** `boundRefDispatch` reads a callable reference's name from
`__bound_name__`, the bytes of a runtime String on the reference instance, and
passes that slice down to `setField`. `fieldWriteCachePut` stored the slice as
the memo's plain-store key. `DateTimeComponents.timeZoneId` is
`by contents::timeZoneId`, so the `format {}` seeded the memo through the
facade's PER-INSTANCE delegate; once that delegate was collected the entry
pointed at freed memory, and the `parse` stored its value under whatever those
bytes had become. `memberNameCanonical` (the interned copy `memberNameIdentity`
was already making for the memo's KEY) now anchors the stored key too. Census
484 passed / 35 failed -> 492 / 27.

**Method notes worth keeping.** Under `KLIO_GC_STRESS` any diagnostic that
ALLOCATES (`Value.display`, `allocPrint`) shifts the collection schedule and
the failure moves or vanishes; only non-allocating traces (`@tagName`, raw
`[]const u8`, identities) are trustworthy. Instance identities are NOT
comparable across two runs — the counter advances with allocation — and the
three wrong diagnoses all came from comparing them across runs instead of
reading one run's trace end to end. `KLIO_NO_WCACHE` making both repros pass
looked like a smoking gun for the memo LOOKUP and was not one; the fault was
in what the memo stored.

The read/probe memos were audited for the same hazard and are clean — they dupe
into the program allocator (`memberCachePut`, the field-probe cache) or store
only integers.

### Fixed: class delegation skipped interface members with a default body

`class W(d: I) : I by d` forwarded only the members `I` left abstract. A member
`I` gives a default body is inherited like any other implementation, so
resolution reached the interface's own body and ran it against the wrapper.
Kotlin generates a forwarder for every member the class does not override.

The decision is made wherever a call can commit to an inherited target — the
virtual-slot dispatch (where a defaulted member arrives, through the class
hierarchy), the lowering-resolved target, both flat-call preparations, the
named/plain member ladders, and the property read. Each asks whether the
receiver's own CLASS chain declares the name and forwards only when it does
not. Three sources answer that: the runtime `ClassDef`, the module's class
table (the authority on which declaration owns a method), and the anon-method
table — `object : I by d { override … }` is the shape that carries the
override in `kotlinx-io`'s `SourceFactory`, and missing it cost io 13 tests
before the anon arm went in. Guarded by
`examples/interface_delegation_defaults.kt`, which pins both directions.

This was the root of kotlinx-serialization's polymorphic descriptors reporting
no annotations: `ContextDescriptor(original) : SerialDescriptor by original`
answered `SerialDescriptor.annotations`' empty default.

### Fixed: a named class's member extension was unreachable from a dynamic call

`class T { private fun List<Annotation>.getCustom() = … }` bound only
statically. When the call site cannot name the receiver's type — a property
read whose declared type lives in another module — lowering emits a dynamic
call, and the dispatch tail had no arm for it. The anonymous-class equivalent
already had one (`enclosingAnonMemberExtDispatch`); the named case now walks
the same enclosing receiver tower, resolving candidates through the module's
name index and `member_ext_owner_class`. Guarded by
`examples/member_extension_untyped_receiver.kt`.

### Fixed: generic `serializer(...)` and descriptor equality

`@Serializable class Foo<T>` gets `serializer(tSerializer)` from the compiler
plugin upstream; the reflective replacement only answered the zero-argument
form. The dispatch tail now accepts arguments and routes them to
`__klsx_generatedSerializerGeneric`, which pairs them positionally with the
declaration's type parameters — which needs the runtime `ClassDef` to retain
them, so it gained `type_params` (image format 49). `ReflectiveDescriptor` uses
the arguments twice: an element whose declared type IS a type parameter reports
that argument's descriptor, and the arguments join the serial name and the
elements in a real `equals`/`hashCode` (element comparison stops at each
element's serial name and kind, which is what lets a self-referential class be
compared at all).

Descriptors also report the declaration's `@SerialInfo` annotations for every
shape, not just the plain class: enum, object, sealed and polymorphic all have
an annotation-carrying constructor upstream. Enum entries had nowhere to keep
theirs, so `ClassDef.EnumEntry` gained `annotation_records`.

Serialization census 69 passed / 69 failed -> 86 / 52 over these three changes.

### Fixed: a lambda now converts to a fun interface at the call boundary

`flatMapConcat` / `flattenConcat` / `flattenMerge(1)` returned the INNER FLOWS
instead of their elements. The root had nothing to do with flows:

    fun interface Handler { fun handle(v: Int): String }
    fun run(h: Handler) = "" + (h is Handler)
    run { v -> "<$v>" }             // was false
    run(Handler { v -> "<$v>" })    // true

Kotlin converts where the argument is PASSED, so the callee's parameter holds
an instance of the interface. klio passed the raw closure: the constructor
boundary already converted (`host_instances.zig`), the call boundary did not.
`flow.collect { … }` therefore handed `unsafeFlow`'s block a raw closure as its
`FlowCollector` — a bare `emit` still SAM-dispatched, but a bare `emitAll`, an
extension on `FlowCollector`, could not prove its receiver
(`[extfb] strict recv-unproven`) and the miss re-dispatched as `emit`, emitting
each inner flow whole.

Both activation paths now convert — `evalWithCapturesChained` and
`openActivation` — with the callee's fun-interface parameters memoized per
function, so the common answer (none) is one comparison. Coroutines census
1116 passed / 98 failed -> 1121 / 93. Guarded by
`examples/sam_conversion_at_call_boundary.kt`.

**Four earlier attempts, all reverted**, each recorded because they cost real
time: receiver-lambda marks on `BuildObject`; a callable satisfying any
single-abstract-method interface in extension applicability; resolving a
renamed import before the inline candidate lookup; and extending
`callableArgPrefersFunctionExtension` to rank a SAM-converting member below a
function-taking extension. All left the battery green and moved no census
number. The fifth attempt failed for a locatable reason — it hooked `callFunc`,
which a bare call with a trailing lambda never reaches — and moving it to the
activation setup is what worked.

**Still open, same area:** conversion driven by an EXPECTED TYPE rather than a
parameter type. `val hs: List<Handler> = listOf({ v -> … })` leaves the
elements raw closures, so `hs.all { it is Handler }` is false. `listOf`'s
parameter is a `vararg T`, so the parameter-type rule cannot see it.


### Open: `secondFraction(n)` picks the defaulted overload

Three datetime sample tests (`LocalTimeSamples.customFormat`,
`LocalDateTimeSamples.customFormat`, `LocalDateSamples.toStringSample`) fail
with `Check failed.` because a format built with `secondFraction(fixedLength =
3)` prints all nine digits.

`DateTimeFormatBuilder.WithTime` declares BOTH `secondFraction(minLength: Int =
1, maxLength: Int = 9)` and `secondFraction(fixedLength: Int)` (whose default
body delegates to the first). Kotlin binds a one-argument call to the
one-parameter overload; klio binds it to the defaulted pair, so the argument
lands in `minLength` and `maxLength` stays 9.

Reduced as far as it goes:

    LocalTime.Format { hour(); char('.'); secondFraction(3) }.format(t)
    // 08.123456789   want 08.123

  * the POSITIONAL form is wrong on EVERY call;
  * the NAMED form (`fixedLength = 3`) is right for the first two invocations
    of the whole process and wrong from the third on — including at a fresh
    call site, so the flip is global, not per-site;
  * `KLIO_BC=0`, `KLIO_JIT=0`, `KLIO_OPT=off`, `KLIO_COUNTED=0`,
    `KLIO_MEMBER_SITE=0` and `KLIO_FLAT=0` all reproduce it, so it is neither
    the bytecode tier, the loop JIT, nor the call-site memo;
  * `KLIO_NU_TRACE=secondFraction` shows the pick moving from
    `DateTimeFormatBuilder.WithTime.secondFraction#201` (params=2) to
    `AbstractWithTimeBuilder.secondFraction#266` (params=3).

Four user-code models of the shape — plain class, interface with a defaulted
body, a bare call inside a builder receiver lambda, and the full
`FormatBuilder<T, Self>` / nested-interface hierarchy — ALL resolve correctly,
so the trigger is something further into the real builder chain (the private
companion `Builder`, or `AppendableFormatStructure`) rather than the overload
shape alone.

### Fixed: an explicit reified type argument survives a declined splice

    val anns = someDescriptor.annotations       // inferred, cross-module type
    anns.filterIsInstance<P>()                  // returned EVERY element

`filterIsInstance` has three reified candidates (`Iterable`, `Sequence`,
`Array` receivers), and with no static receiver type the pick cannot choose, so
the splice declines. The body then reads its reified parameter from the
process-wide slot the splice writes — still holding whatever an UNRELATED
earlier splice left there.

The call knows its own type arguments, so the declined path now publishes them
under the callee's reified parameter names before dispatching. The remaining
unsoundness of that slot (re-entrancy) is unchanged and still recorded in
[[klio-reified-type-param-global]] terms; this closes the common case where the
argument is written at the call site. Guarded by
`examples/reified_type_arg_without_splice.kt`.

### Fixed: the flow `Vm::call_value on kotlin.Nothing` cluster was a starved harness

The 8 flow failures (FlatMapConcat / FlatMapMerge / FlattenConcat /
FlattenMerge `testFlatMapConcurrency` and friends) were never an
interpreter bug. Every one of those files extends `FlatMapBaseTest`, which
is declared in `FlatMapBaseTest.kt` — a file that carries its own `@Test`
methods and therefore lands in the harness's TARGET list, not its support
list. One target per child meant the subclass compiled with an unresolved
supertype: it lost the inherited members (`expect(value)` inside the
`collect` lambda fell through to `kotlin.test.expect(expected, block)`
with a null `block` — hence `call_value on kotlin.Nothing`) and never ran
the inherited cases at all.

The route to it, for the record: `[cmg-cand]` shows the implicit-receiver
walk reaching `FlattenConcatTest` at ci=2 in BOTH the real run and a
passing reduction, so the candidate list was never the difference.
`missDumpClassChain` is what separated them — `[chain 0]
FlattenConcatTest methods: supers: FlatMapBaseTest parent=false`. The
`parent=false` is the whole story: the supertype name is recorded, the
ClassDef is not, and the walk ends at depth 0.

Two earlier readings of this cluster were wrong and are recorded so they
are not repeated. `JobSupport.notifyCompletion` binding the wrong receiver
was a different failure in the same run, not this one; and `[extfb]
name=notifyHandlers simple-name fids=0` was read as "no dispatchable
registration" when `[extfb]` is the EXTENSION fallback, where zero
candidates is the expected answer for a member. Two lowering changes built
on that misreading (`inlineBodyRecvChain` appending the owner chain;
`bareInlineNeedsSplice` forcing a splice for a private inline member) were
measured — the first census-neutral, the second net −1 (it broke
`JobExtensionsTest.testIsCancelled`, whose `private inline fun
checkException(block)` stops throwing once spliced) — and both reverted.

The fix is in the harness, in both the gate (`commontest_support.zig`) and
the census script: each target now also compiles the transitive closure of
the target files whose top-level declarations it names, with `--only-file`
keeping those files' own cases counted exactly once. The closure is
computed from a column-zero declaration scan plus an identifier scan,
scoped to the target's own package, so it pulls in a base class
(`FlatMapBaseTest`) and a shared helper (`SharedFlowTest`'s
`testSubscriptionByFirstSuspensionInCollect`, `IdFlowTest`'s `Flow<T>.id`)
and nothing else — 34 extra file inclusions across the coroutines suite's
148 targets, none for io / androidx_collection / serialization, one for
ktor. Coroutines census 1124/90 -> 1162/86.

**Whole-source-set is NOT the answer here.** Flipping the suite to
`whole_source_set = true` (compile all 148 test files into every child) is
the more faithful model of a Kotlin compilation unit, and it measures
741 passed / 507 failed — 440 of the failures `Vm::call_member`. That is a
real and large defect surface (compiling the whole test tree together
breaks resolution), but it is a separate campaign; the per-file model plus
the provider closure is what the gate runs today.

### Fixed: a nested class reached from inside a lambda

`Box::i` inside a lambda in `Box`'s declaring class died on `unresolved
global Box` while the identical reference in the method body resolved
(coroutines' `DistinctUntilChangedTest.testDistinctUntilChangedKeySelector`,
whose `private class Box` is nested in the test class). A nested class
lifts to `Holder$Box` and has no binding under its bare simple name; the
`MemberRef` arm that loads a type reference with no IR class id — the arm
for `ULongArray::copyInto` — read the bare name without consulting the
scope rename. It now defers to `lowerReceiver`, which applies the rewrite,
exactly as `lowerReceiver`'s own `aliased` guard does. Guarded by
`examples/nested_class_reference.kt` and a lowering unit test.

### Fixed: a file-private function bound the other file's declaration

Two files in one package each declaring a same-signature `private fun`
mangle per file (`makeIt$f228` / `makeIt$f229`) and each file's bare CALL
rewrites to its own mangled name. Two holes let the other file's
declaration win anyway:

  1. A `::name` reference never applied the rewrite. With no declaration
     left under the bare name, the reference fell through to the
     member-ref-on-`this` branch and missed at run time —
     `Vm::call_member 'createSegment' on SemaphoreImpl`, from kotlinx's
     `val createNewSegment = ::createSegment` inside
     `SemaphoreAndMutexImpl.addAcquireToQueue`, with a second
     `private fun createSegment` in BufferedChannel.kt supplying the
     collision. Four coroutines tests (`FlatMapMerge*`, `FlattenMerge`,
     `MutexTest.testUnconfinedStackOverflow`).
  2. The typeck overload channel recorded a cross-file private pick, which
     `eagerCallTarget` then applied ON TOP of the correctly-mangled
     lowering — `[bare] makeIt$f229 -> makeIt$f228#7481` with a candidate
     list of exactly one entry, `makeIt$f229#7482`. Symptom: a bare call
     bound whichever file was compiled FIRST, in both directions.

`recordResolvedCall` now declines any pick whose declaration is a
top-level `private` in a different file, beside the existing
package-visibility gate. Colliding file-private top-level PROPERTIES were
checked and are already correct.

Guarded end to end by `examples/file_private_collision/` (pinned in
`parity_corpus_pinned`). A synthetic two-file typeck test was written and
DROPPED: the checker records nothing at all for that module, so the test
passed with the gate disabled and proved nothing. Whatever makes the real
program record the cross-file pick is not reproduced by the `Builder`
harness, and the end-to-end pin is the honest guard.

### Fixed: an inferred receiver-function parameter kept no receiver

`driver { fail -> fail() }` against
`child: Scope.(block: Scope.() -> Unit) -> Unit` never marked `fail` a
receiver-lambda param: only ANNOTATED parameter types reached the
classification loop in `lowerLambdaBodyCapturingKindWith`, while the
INFERRED ones (from `pending_lambda_param_types`) were used solely to
record a declared type. A bare `fail()` then ran the block receiverless —
its body could not see the receiver at all — and in coroutine code a
builder inside it attached to the wrong scope: eight
ParentCancellationTest cases lost the failing grandchild to the root
`runBlocking` instead of the `CompletableDeferred` meant to absorb it.
The expected type is now classified too, decoding the receiver out of the
lowered `FunctionN` shape (`[#suspend?] [receiver?] params… ret
[#markers]`). Census 1167 -> 1175.

### Fixed: a function-typed receiver's shape picks the extension overload

`suspend R.() -> T` lowers to `Function0` (its receiver rides in the type
args) and `suspend (P) -> T` to `Function1`. Both are one runtime class,
so the extension walk had nothing to separate a same-named pair declared
on the two shapes and the receiver form won every call. kotlinx's
`block.startCoroutineUninterceptedOrReturn(value, cont)` on a
`suspend (V) -> T` therefore ran the block with `value` bound as `this`
and its value parameter null — so a `flowOn` that only changes the
coroutine NAME (no dispatcher change, the `collectWithContextUndispatched`
fast path) collected through a null collector and died `emit` on
`kotlin.Nothing`. The lenient extension pass now keeps only candidates
whose declared receiver head matches the call's declared head exactly,
when any do. Census 1175 -> 1179.

Still open in the same family: a LOCAL annotated `val f: (String) -> Int`
records its declared head as the parser's `<function>` tag rather than
`Function1`, so the same overload pair still ties for a call on a local.
Only the parameter-typed form (what the library uses) is decided.

### Fixed: the flow builder enforces context preservation

klio's `SafeCollector` actual forwarded every value straight downstream,
on the reasoning that one cooperative scheduler already serializes
emissions. Context preservation is not a thread-safety device though: it
is `flow { }`'s contract, and emitting from a child coroutine or across a
`withContext` must be reported. The actual now runs the shared
`checkContext` on each context change, memoized on the emitting context's
identity. Census 1179 -> 1187 (three `testTransparencyViolation`, five
FlowInvariantsTest, one CancellableTest half).

**No `ensureActive` rides along, and CancellableTest.testCancellable
cannot currently pass whole.** The JVM actual calls
`currentContext.ensureActive()` on the EMITTER's continuation context;
klio's `currentCoroutineContext()` inside `emit` is the COLLECTING
coroutine's. With the check in, `assertEquals(1, sum)` (the
`cancellable()` half) passes and `assertEquals(500500, sum)` (the plain
half, pinning "a flow is not cancellable by default") fails; with it out,
the reverse. Measured both ways: net zero either direction. The unresolved
half is `cancellable()`: upstream's `AbstractFlow` IS a `CancellableFlow`,
so `onEach`'s SafeFlow returns ITSELF from `cancellable()` — which cannot
explain the test expecting different sums from the two collections. A
hand-written `CancellableFlowImpl` equivalent DOES give `sum == 1` in
klio, so the wrapper logic works and the discriminator is which flows
count as already-cancellable. Needs the kotlinc oracle, not more
guessing.

### Fixed: a null channel element is a value

The channel iterator used `__pending__`'s CONTENTS as its "have a value"
sentinel: `hasNext()` re-pulled when the cached element was null, and
`next()` raised "`hasNext()` has not produced an element" for a real null
on a `Channel<T?>` (`listOf(flowOf(1), flowOf(null), flowOf(2)).merge()`).
Both now read the iterator STATE, which every delivery path already sets.
Census 1187 -> 1192.

### Fixed: five datetime roots

- **Extended ISO years.** `LocalDate.parse` rejected a leading `+`, so
  every year past 9999 failed, and `toString` rendered such a year
  unsigned — ambiguous, and not a round trip. ISO leaves 0000..9999
  unsigned at four digits and signs everything outside it, with any zero
  padding allowed on a signed year; the padding is trimmed before
  conversion so a thirty-zero year does not overflow on its digits alone.
- **An ambiguous local time takes the EARLIER offset.** The local-time
  walk advanced to a transition's new offset at `transition + newOffset`,
  which around a fall-back starts an hour before the old offset's local
  end, so the repeated hour bound the SECOND pass. The new offset now
  takes over only once the local time is past the transition under both
  readings — the earlier-offset rule for both the overlap and the gap.
- **Single-digit-hour zone ids.** `TimeZone.of` routed every offset form
  through a parser demanding two hour digits, so `UTC+3`, `+4` and `-9`
  were rejected.
- **Offset identity.** Parsing handed back a fresh `UtcOffset` every time,
  so two spellings of one offset — `Z` against `UtcOffset.ZERO` included —
  differed by identity. Parse now caches per total-second value.
- **Natural ordering for a user `Comparable`.** `compareValues`,
  `compareValuesBy` and the sequence sorts compared only builtin kinds and
  refused everything else, so `sortedBy { it.instant }` on a library value
  type died while `<` on the same values worked. Each dispatches the
  value's own `compareTo` once the builtin table declines. The datetime
  pack also grew upstream's Kotlin TZif reader, which its own tests read a
  zoneinfo blob through.

Datetime census 484/35 at the start of this campaign -> 517 passed, 2
failed. The two left are `DateTimeComponents` shapes: a `set` on
`PropertyAndItsValue` and a `monthNumber` read on the companion.

### Fixed: ktor's own `Char.isLowerCase` was not packed

`URLProtocol`'s scheme check calls `it.isLowerCase()` against ktor's own
`io.ktor.util` extension — `lowercaseChar() == this`, which accepts digits
and punctuation — but `io/ktor/util/Charset.kt` was not in the pack's
include list, so the call fell to the stdlib's letter-only one and every
scheme with a digit or `.+-` was rejected. Ktor census 448/2 -> 450/0
(`WriterReaderTest.testWriterOnCancelled` still flakes under a loaded
census; it passes six times out of six solo).

### Fixed: `+=` on a nested container adds one element

`MutableCollection<in T>.plusAssign` has an element form and an iterable
form, and Kotlin picks by the receiver's declared ELEMENT type: a
`MutableList<List<T>>` takes a `List<T>` as ONE element, because a
`List<T>` is not an `Iterable<List<T>>`. Every klio route — the
`<op>Assign` member call, `CompoundField`, the compound `BinOp` — decided
on the argument's runtime TAG alone and flattened, so
`buildClassSerialDescriptor { element(...) }` produced a descriptor whose
per-element annotation lists were empty and whose reads went out of
bounds. Settled at the assignment's lowering, where the declared types are
in hand; a value whose own element type IS the receiver's keeps
flattening.

### Fixed: a spliced inline extension resolves against its own receiver

Inside an inline splice the frame's `recv_ty` is the CALLER's, so a
spliced extension body resolved its bare calls with no receiver at all and
lost its own receiver's extensions: `serializer(typeOf<T>())` inside
`SerializersModule.serializer()` bound the module-less overload and every
contextual lookup through it reported the class as not serializable. The
splice already carries the spliced declaration's receiver on its own
channel (`spliceRecvTy`, deliberately separate from `recv_ty`); the
bare-call resolution context now consults it when the frame has none.
Serialization census 94 -> 98.

Still open in the same family: a lambda NESTED in a spliced inline
extension body still loses the receiver
(`inline fun R.f(xs) = xs.map { bare(it) }` binds the global where the
non-inline sibling binds `R`'s extension). Setting
`pending_lambda_enclosing_recv` from `spliceRecvTy` was tried and changed
nothing, so the lambda builder takes the receiver from another channel —
the receiver TOWER is the next place to look.

### Root: an unclaimed classifier header dispatched a defaulted member directly

`SerializersModule + SerializersModule` threw
`SerializerAlreadyRegisteredException` for two modules holding the SAME
serializer, and every copied serializer landed as an anonymous PROVIDER.

The chain, established by instrumenting the pack and then the dispatcher:

  * `dumpTo` really takes the `Argless` branch and really passes the
    `ReflectiveKSerializer` — the pick is not the problem;
  * the call `collector.contextual(kClass, serializer)` reached the
    INTERFACE's default body, whose forward is
    `contextual(kClass) { serializer }`. That lambda is the provider the
    scorer then saw, so the overload trace was a consequence, not a cause;
  * lowering resolved the call correctly (`target=624 dispatch=virtual`)
    and then DOWNGRADED it to a direct fid call, because
    `dispatchForTarget` reads a stub owner's all-false modifiers as
    "closed class, final method".

`SerializersModuleCollector` is a stub at that moment: the pack lowers
`SerializersModule.kt` before the collector's own file fills its header, so
`is_interface`/`is_open`/`is_abstract` are still placeholders.
`resolveMemberCall` already answered `virtual` for a stub;
`dispatchForTarget` now agrees. Guarded by an `ir` unit test (the
placeholder shape) and `examples/serializers_module_merge.kt`.

Traps this cost time on: the bake cache in the data home serves a
pre-lowered pack, so `KLIO_EXT_TRACE` printed nothing for pack code until
`.klio-local/.klio/cache` was cleared; and `[pmo-multi]`/`[rim]` describe
only the calls that REACH dispatch — a direct call is invisible there, and
its absence from the trace is the evidence.

### Root: two same-arity overrides on one anonymous class shared a key

With the interface default no longer intercepting, `overwriteWith` failed
with `call_member invoke on ReflectiveKSerializer`: its anonymous collector
declares both `contextual` overloads, `anon_methods` keys them
`name#arity`, and the second registration overwrote the first — so the
virtual slot for the serializer form ran the provider body. Each
declaration now also registers under `name#arity#<n>`, and
`runtimeVirtualOverride` walks those, taking the one whose parameter type
heads are the slot root's.

### Root: `@Serializer(forClass = C::class)` had no body at all

The kotlinx plugin generates that declaration's `descriptor`, `serialize`
and `deserialize` from `C`. klio has no plugin and no fallback, so
`ASerializer.descriptor` was a `get_field` miss. Annotation records now
carry a `ClassRef` argument (the lowering recorded `Foo::class` as
`.Other`), and both the member-call and field misses forward to `C`'s own
serializer. Guarded by `examples/serializer_for_class.kt`.

### Root: a reified type parameter was not solved from its argument

`inline fun <reified T : Any> f(v: T) = T::class` called as `f(42)` left
`T` unbound, so the splice declined and the un-spliced body read a
PROCESS-GLOBAL `T` — unresolved on the first call, and the PREVIOUS call's
answer on every later one (`f(42)` then `f("x")` both printed `Int`).
`inferReifiedTypeArgs` only solved a bare-`T` parameter from a constructor
argument. It now also takes the argument's recorded static type, and for a
generic parameter (`serializer: KSerializer<T>`) unifies against that
recorded type's arguments — which required a local initialized by an
object literal to record its supertype WITH type arguments, the only place
an anonymous object's type arguments are written. Guarded by
`examples/reified_from_argument.kt`.

### Root: the plugin surface a `@Serializable` declaration names for itself

Five roots behind the serialization lookups, each its own mechanism:

  * `X.Companion` on a class value missed. A `@Serializable` class has no
    DECLARED companion — the plugin writes it — so the class value stands in
    for it, exactly as a bare `X` in value position does.
  * `Data.Named.serializer()` asked the COMPANION for a serializer. The
    companion is not the `@Serializable` declaration; its owner is.
  * `@Serializable(with = Custom::class)` was ignored, so a declaration that
    names its own serializer got a reflective one. Annotation records now
    carry the class literal, `__klsx_customSerializer` reads it, and an
    object answers its singleton while a class is constructed.
  * A `@Serializer(forClass = C::class)` declaration is written with NO
    supertype; the plugin makes it a `KSerializer<C>`. It now carries that
    supertype, which is what `is KSerializer` and the lookups' `as` read.
    Its generated body reads C's REFLECTIVE shape — going through C's own
    `@Serializable(with = …)` names this declaration right back, which
    recursed until the stack died.
  * A reified type parameter with no arguments to solve from, called inside
    a splice that binds exactly one reified name, takes that binding
    (`EnumSerializer(serialName, enumValues())`).

### Root: a reified type argument lost its nullability

`filterIsInstance<Int?>()` dropped the nulls: the `?` was stripped at three
places, each its own root —

  * `internTypeArgsScoped` stamped the head without the `?`;
  * an `is T` check in a spliced body left the parameter NAME for the
    runtime, which resolves it through the bound CLASS VALUE — and a class
    value cannot carry nullability. The lowering now substitutes the
    enclosing splice's reified binding (nullability and all) into the
    `InstanceOf`; a full generic spelling contributes its head. First cut
    substituted the full spelling and broke `ChannelFactoryTest` /
    `CombineParametersTest` (`assertIs<BufferedChannel<*>>` on
    `BufferedChannel<*>` matched nothing) — heads only;
  * a LAMBDA inside the spliced body (`filter { it is R }`, the
    `Flow.filterIsInstance` shape) lowered with no reified context at all.
    The splice's substitutions now travel into lambda bodies via
    `pending_lambda_reified_names`.

Also: a nested reified inline call whose type parameter is spelled the SAME
as the enclosing splice's binds it lexically (`filterIsInstanceTo(
ArrayList<R>())` inside `filterIsInstance`). Guarded by
`examples/reified_nullable_type_argument.kt`.

### Root: a reified parameter solved from a class-typed argument's supertype

`contextual(serializer)` with a `ThirdPartyBoxSerializer<Item>` argument
left `T` unbound: the argument's recorded static type is the head
`ThirdPartyBoxSerializer`, and nothing read that class's
`KSerializer<ThirdPartyBox<S>>` supertype. `unifyParamAgainstArg` now binds
a `KSerializer<T>` parameter's `T` from the argument's declared-type class
supertype list, heads only (`T := ThirdPartyBox` — the head is all
`T::class` / `is T` can read; the inner `S` is the class's own parameter
with no binding at the site). The argument resolves as a local's recorded
type or an enclosing class's member-property head (the test holds these as
`protected val`s read from inside the builder lambda).
ContextualGenericsTest 0/3 -> 3/0.

### Root: body properties were not serialized at all

The kotlinc plugin serializes every BACKING-FIELD property — constructor
ones first, then body properties in declaration order, skipping delegated
and `@Transient` ones. klio's reflective serializer walked only the primary
constructor, so a class carrying state in its body serialized none of it
(`CustomPropertyAccessorsTest` both cases; several SchemaTest shapes).

The pieces:

  * `PropertyDef` now records `has_backing` (kotlinc's rule, including the
    accessor-reads-`field` scan — shared walkers added to `ast`) and
    `type_head` (declared, or inferred from a literal initializer). Image
    format bumped to 50.
  * Five intrinsics: `__klsx_bodyPropNames` / `SerialNames` / `Types` /
    `HasInit` and `__klsx_setField` (a direct backing-field write, the
    generated deserializer's shape — custom setters are bypassed).
  * `ReflectiveKSerializer` appends the body elements to its descriptor
    (optional = has-initializer), encodes them in order, and on decode
    writes each seen value to the backing field — EXCEPT properties with no
    initializer, whose only assignment is an `init` block that must win
    (`deferredInit` keeps `initial6`). `@Transient` is checked on every
    anchor, not just `property`.
  * Element decode routes through the TYPED hooks (`decodeStringElement`
    -> `decodeString`) by declared head; `decodeValue()` alone throws on a
    format that only overrides the typed surface — which is every
    AbstractDecoder-based test format.
  * `__klsx_paramAnnotations` indexes continue into the body properties.

serialization 110 -> 116 net (8 fixed incl. both CustomPropertyAccessors,
nullability + external-class lookups; 0 new). Guarded by
`examples/serializable_body_properties.kt`.

### Root: element descriptors stopped at the primitives

`SchemaTest` 1 -> 6/7 and both `SerialDescriptorSpecificationTest` cases,
five mechanisms:

  * `descriptorForDeclaredType` now parses the rendered generic type:
    `List<Int>` is a `ListLikeDescriptor` over Int's primitive descriptor
    (built with `listSerialDescriptor`/`set`/`map`), recursively, and a
    user-class head resolves through the new `__klsx_classByName`.
  * A generic class element (`stringBox: Box<String>`) reports the
    PARAMETRIZED serializer's descriptor: the type arguments' serializers
    are minted from the rendered names and passed to
    `__klsx_generatedSerializerGeneric`.
  * A plain (unannotated) enum class still serializes — kotlinc generates
    enum serializers on demand — so element resolution goes through
    `__klsx_serializerForElementClass`, which falls to the ungated
    reflective build for enums.
  * `getElementIndex` answers `UNKNOWN_NAME` (-3), and the element
    accessors throw `IndexOutOfBoundsException` out of range, per the
    SerialDescriptor contract.
  * A nested private object DELEGATING through a sibling nested object's
    member (`object HolderDescriptor : SerialDescriptor by
    StaticHolder.userDefinedHolderDescriptor`) resolved `StaticHolder`
    globally and missed: the delegate thunk now lowers scoped to its class
    (`lowerExprAsParamThunkScoped`), so the enclosing-class walk resolves
    the sibling.

### Root: `@Transient` constructor properties stayed elements

kotlinc removes them from the whole surface. Every ctor-walk intrinsic now
skips them (`ctorParamTransient`, all five anchors), and — since a skipped
middle parameter breaks positional construction — `deserialize` constructs
by NAME through a new `construct_named` host hook backed by
`newInstanceNamed`, binding only the DECODED elements so every unbound
parameter takes its declared default. Body-prop `@Transient` checks every
anchor too (`@Target(PROPERTY)` resolution cannot be assumed).

### Roots: the last serialization stretch (132 -> 136, 2 open)

  * `subclass(C::class)` picked the SERIALIZER overload: same arity, both
    reified, registration order decided. `CallShape.arg0_class_literal` now
    breaks the tie toward the `KClass`-first-param candidate
    (`pickKClassParam`), and `unifyParamAgainstArg` solves `KClass<T>` from
    a class-literal argument and `KSerializer<T>` from a companion
    serializer-factory argument (`PolyDerived.serializer()` names its type
    in the receiver). Both otherwise reached the runtime with `T` reading
    the PROCESS-GLOBAL left by a sibling splice — the "B already
    registered" cross-test corruption.
  * `KClass.toString()` renders the QUALIFIED name (`class kotlin.Any`),
    as the common/native surface does; the polymorphic-collision message
    tests read it.
  * A member-extension override on a CLASS TYPE PARAM receiver
    (`C.collectionSize` in `CollectionSerializer<E, C, B>`) was refused by
    the lenient extension pass when the call-site hint spelled another
    class's type parameter that collides with a real class name (upstream
    names one `Collection`). A class-type-param receiver now accepts any
    static hint.
  * `@MetaSerializable`, `@Polymorphic` (declaration and property),
    interface elements as OPEN polymorphic, element descriptors/serializers
    resolved OWNER-SCOPED (`__klsx_classByName(name, owner)` — a global
    simple-name lookup landed on the wrong `Attitude`), nullable primitives
    through their serializers (`Boolean?` decoded `false` from a null),
    string/char elements through the TYPED encode hooks, primitive-array
    and `Array<T>` element serializers, and per-element serializers made
    LAZY (a self-referential `Node(next: Node?)` recursed at construction).
  * Integer literals ADOPT the declared type at the constructor boundary:
    `Sensor(7, 12, arrayOf(1, 2, 3))` with `Short`/`Long`/`Array<Byte>`
    properties stores the declared primitives (`adoptDeclaredNumeric`,
    generalizing the old Long-only retag). kotlinc does this at compile
    time; `contentEquals` against a decoded array agreed once it landed.
    Still missing: the same adoption for a plain LOCAL binding
    (`val a: Array<Byte> = arrayOf(1, 2)` still holds Ints).

The final two: a PARAMETRIZED named companion's `serializer(typeArg)` routes
to the OWNER declaration exactly as the zero-arg form does (the generic
`__klsx_generatedSerializerGeneric` branch gained the companion-owner
fallback), and a collection of a TYPE PARAMETER (`list: List<T>`) reports
the structural descriptor around the SUPPLIED argument's descriptor.

**serialization is AT ZERO: 138/0** (campaign opened at 57 passed / 81
failed).

### Root: the delivery-to-dispatch cancellation window (coroutines 1271 -> 1280)

An element handed to a parked waiter is not DELIVERED until the waiter's
coroutine dispatches. A cancel landing in that window must intercept the
element and run `onUndeliveredElement`; klio's channel completed the
cancellation watcher at delivery-SCHEDULE time, making the cancel
invisible, and the element sat in `chan_pending_resume` until the
dispatched task delivered it to a dead coroutine. Four pieces:

  * `resumeWaiterNormal` keeps the watcher ARMED for the dispatched routes
    (codes 1 and 3); `chanResumeNow` completes it on actual delivery.
  * `channelCancelWaiter`'s not-in-queue tail takes the pending resume:
    the element (unwrapped from a `receiveCatching` ChannelResult; read
    back from the iterator's `__pending__` via the new `chan_iter_pending`
    slot->iterator map for `hasNext`) runs the handler, a failing handler
    reports unhandled, and the slot resumes with the cancellation.
  * Select RECEIVE clauses carry `onCancellationConstructor` (mirroring
    `BufferedChannel`'s): a value handed to a select then cancelled before
    dispatch runs the handler via `callUndeliveredElement`, with the
    handler exposed by the new `__kxco_chanUndeliveredHandler` intrinsic.
  * A select-parked SENDER cancelled while waiting never sent its element:
    `__kxco_chanSelectRemoveSender` now reports whether a still-parked
    waiter was removed, and the disposal handle runs the handler for it.

Closed the whole `ChannelUndeliveredElementFailureTest` (13/0) plus
BroadcastTest lazy-close, FlowOn, Zip and a StateFlow case. Guarded by
`examples/channel_cancel_before_dispatch.kt`.

### Roots: datetime to ZERO (519/0)

  * A property reference's `get`/`set` members were unimplemented:
    `boundRefDispatch` now serves them, bound/unbound decided by ARITY
    (`T::prop` may capture the class OR its companion stand-in, so the
    captured value's tag cannot decide). Guarded by
    `examples/property_reference_get_set.kt`.
  * A LOCAL (function-body) class's method taking its class's own TYPE
    PARAMETER (`set(target: Target)` in `class PropertyAndItsValue<Target,
    Value>`) was refuted by the anon-method disproof reading `Target` as a
    nominal class: the runtime-synthesized ClassDef now carries the
    declared `type_params`, and the disproof skips a param typed by one
    (resolved through the method's `this` param's class).

### Root: the closure chain lacked the creator's own receiver

`ReceiveChannel.toList() = buildList { consumeEach(::add) }` dispatched
`consumeEach` on the MutableList. Two mechanisms:

  * A closure's enclosing-receiver snapshot (`captureChainAlloc`) copied
    only the frame's pushed chain — the creating function's OWN receiver
    (`this`, params[0] of an extension or member) lives in the params and
    was never part of the lexical scope the lambda carried. It is now
    appended innermost.
  * With the channel in the chain, the STRICT extension pass still refused
    it: `receiverImplementsHead`'s name walk crosses host-synth classes
    (`KlioBufferedChannel -> BufferedChannel -> Channel -> ReceiveChannel`)
    through the ClassTable's simple-name entries and broke mid-chain. The
    walk now falls back to `instanceOf` — the same authoritative subtype
    answer `is` uses.

Guarded by `examples/builder_lambda_outer_receiver.kt`. Coroutines
`ChannelsTest` 9/0.

### Root: a compound assign on a captured parameter boxed it

`destination += transform(element)` inside `Flow.associateTo`'s collect
lambda filled a PRIVATE copy — the caller's map stayed empty. The
assigned-in-lambdas scan counted compound-assign targets as writes, so the
parameter was boxed into a fresh cell; and the compound-assign lowering's
`path_is_val` refused the `plusAssign` dispatch for a name that is both
locally resolvable and known-outer. Both directions fixed: parameters (and
lambda/splice params) box only on REBINDS
(`namesAssignedInLambdasRebindsOnly` — a parameter can never be reassigned
in Kotlin, so `dest += e` can only mean `dest.plusAssign(e)`), and a
captured immutable dispatches `<op>Assign`. A captured written `var` still
boxes via `computeBoxedVars`. Guarded by
`examples/compound_assign_captured_parameter.kt`. Coroutines
`ToMapCollectionSamplesTest` green; 1269 -> 1271.

### Root: a bare spread call dropped the implicit receiver

`constructSerializerForGivenTypeArgs(*serializers.toTypedArray())` inside a
`KClass` extension bound `this = IntSerializer` — the first spread element —
and every parametrized serializer lookup (`Box<Int>`, `Box<SealedI>`, the
whole `serializer<Generic<T>>()` family) answered "not found".
`lowerCallSpread`'s bare-name arms resolved the name to a global fn value
and invoked it with only the flattened args; an EXTENSION target's receiver
slot then swallowed the first element. Both arms (bounded candidates and
`funcIdForSpreadCall`) now route an extension pick as a member-form
dispatch on the resolved `this`. Guarded by
`examples/extension_spread_implicit_receiver.kt`.

Debug note: the `BinOp.* on null` family now dumps the frame chain under
`KLIO_ERR_TRACE`, which is what located both this and the next root.

### Root: an anon-object site baked in its first receiver's storage layout

`object : Iterator { var left = count }` in a `Sized` extension property:
built first under a receiver STORING `count`, `bareCaptureResolvable`
answered "resolvable from the captured `this`'s fields" and the site
(a per-SITE cache) skipped lowering the init thunk. The next receiver —
`count` a custom getter with no backing field — then constructed with
`left = null`. The resolvability decision is now site-static: direct
captures only; anything else always gets the thunk, whose dynamic member
read serves fields and getters alike. This was the
`SerialDescriptor.elementDescriptors` iterator, so it broke descriptor
walks order-dependently. Guarded by
`examples/anonymous_object_receiver_shapes.kt`.

### Root: `@MetaSerializable` did nothing

An annotation itself annotated `@MetaSerializable` marks its targets
serializable and is retained on the descriptor.
`__klsx_isSerializable` now consults the annotation DECLARATIONS' own
annotations, and `annotationIsSerialInfo` keeps meta-serializable
annotation instances on the descriptor. Class-literal annotation arguments
(`root = String::class`) ride the ClassRef record. MetaSerializableTest
0/3 -> 3/0. Guarded by `examples/meta_serializable_annotation.kt`.

### Root: constructSerializerForGivenTypeArgs dropped its arguments

klio's actual ignored the vararg serializers, so a parametrized descriptor
had no type-argument substitutions (`Box<SealedI>`'s `boxed` element read
CLASS instead of SEALED). It now routes through
`__klsx_generatedSerializerGeneric` when arguments are present.

serialization 124 -> 132 across these four.

### Root: a vararg ctor param typed as its ELEMENT in property inits

`class C(vararg names: String) { val items = names.toList() }` died with
`get_field length on kotlin.Array`: the property-init thunk's declared-type
seed recorded `names: String`, so `toList()` picked the CharSequence
extension. A vararg parameter's VALUE is an Array; the seed now types it
so. Exercised by `examples/anonymous_object_receiver_shapes.kt`'s
`Computed(vararg names: String)`.

### Root: a class literal answered the builtin of the same simple name

`object Target` beside `kotlin.annotation.Target`: `Target.tag` read the
user's object but `Target::class` answered `kotlin.annotation.Target`, so
`Target::class == (Target as Any)::class` was false and every registry keyed
by the class literal missed. The `::class` arm resolved through the
simple-name index, which holds whichever class registered last; it now
resolves by the reference's own file and package first. Guarded by
`examples/class_literal_builtin_name.kt` (`Target`, `Retention`,
`Deprecated`).

### Root: an anonymous object's `is` stopped at its direct supertypes

`object : KSerializer<Int> by … {}` answered `is KSerializer` true and
`is SerializationStrategy` FALSE, so `getPolymorphic`'s
`as? SerializationStrategy<T>` returned null for a registration that was
really there. A runtime-synthesized class records supertype NAMES and never
fills the resolved `interfaces` handles `interfaceChainMatches` walks, so
the direct-name test was the whole answer. The names are now resolved to
their declarations and walked transitively. Guarded by
`examples/anonymous_object_supertypes.kt`.

### Fixed: `onUndeliveredElement`

`Channel(capacity) { … }` accepted the handler and dropped it on the
floor, so an element the channel took but never delivered was lost
silently. It now runs for every such element, matching upstream case by
case:

  * a DROP_OLDEST eviction, from `send` AND `trySend`;
  * a DROP_LATEST drop, from `send` only — `trySend` leaves that to its
    caller (upstream's `isSendOp`);
  * a `send` to a closed channel; a `trySend` to one reports nothing,
    because it returns a failed result instead of accepting the element;
  * a cancelled parked `send`;
  * the whole buffer plus every parked sender when the channel is
    CANCELLED. A plain `close` reports nothing — the buffer stays
    receivable.

The handler is identified by SHAPE, not position: the native `Channel(...)`
factory sees the arguments as the user wrote them, so a callable in any
slot is the handler while a capacity is numeric and a `BufferOverflow` is
an enum entry. A handler that throws is wrapped in
`UndeliveredElementException` with the original as its cause, as upstream's
`callUndeliveredElementCatchingException` does, and surfaces at the drop /
cancel site. Coroutines census 1192 -> 1203.

Still open in that file: the seven `runTest(unhandled = …)` cases, where
the wrapped exception must reach `handleCoroutineException` as an
UNHANDLED coroutine exception rather than surface at the call site.

### Fixed: a `yield()` loop starved every timer (the four WithTimeout files)

`WithTimeoutTest`, `WithTimeoutOrNullTest` and their Duration siblings each
blow the 300s child timeout, taking four whole files with them. Reduced to:

    runBlocking {
        val j = launch { delay(100); fired = true }
        while (!fired) { yield() }        // never terminates
    }

and equivalently `withTimeout(100) { while (true) { yield() } }`, which is
`WithTimeoutTest.testYieldBlockingWithTimeout` verbatim. `withTimeout` over
a plain `delay` DOES fire, so the timeout machinery works; what fails is
the clock.

The mechanism is exact: klio's pump runs `runBlocking` on the VIRTUAL
clock, and `coroutines.zig`'s timer step only advances `virtual_now` when
the earliest timer is in the FUTURE. `yield()` suspends with `Suspend = 0`,
i.e. a timer at the current instant, so an infinite yield loop keeps
ready-now work available forever and the clock never reaches the delay's
deadline.

That first reading was WRONG about the mode, and the correction is the
whole fix. `klio test` runs `.Wall`, not `.Virtual`; the pump does arm due
Wall deadlines every turn (`armDueWallTimers`, whose doc comment already
named this exact hazard). What starved was the PUMP: `[PUMP] resumeInline`
showed every `yield()` resuming inline and never returning to the pump
loop, because a Kotlin-level DISPATCHED resume is exempt from the per-turn
inline cap. Arming from the inline-resume gate as well — where the existing
ready-queue check then sends the resume behind the timer that just came due
— fixes it. All four files go fully green: census 1204 -> 1259 passed,
44 -> 40 failed, 6 -> 2 incomplete, and the 300s child timeouts are gone.

### Fixed: four more coroutine roots

- **A vararg sibling wins when the container parameter is disproved.** The
  inline-target index resolves by NAME and ARITY, and
  `combine(vararg flows: Flow<T>, transform)` and
  `combine(flows: Iterable<Flow<T>>, transform)` are both arity 2. A single
  `Flow` argument only fits the vararg one, but the index cannot see that,
  so the container overload was spliced and its body iterated the flow
  itself. Census +2.
- **Non-callable evidence follows a local's static TYPE.** It was recorded
  only for a literal initializer or a definite non-function annotation, so
  `val flow = flowOf(1, 2)` still swallowed the next `flow { … }` — and,
  because that evidence set is what nested lambdas inherit, so did every
  capture of it. Derived from the initializer's static type now (a class
  declaring no `invoke`, no `invoke` extension applicable), gated on a
  same-named bare-call candidate existing. Census +4 across
  `CancellableTest` and `FlatMapLatestTest`.
- **A run with no matching cases prints its summary.** A file whose only
  `@Test` methods live on an ABSTRACT class contributes no cases but DID
  run; printing just "no tests found" left the harness scoring it as a
  child that never reported. Incomplete 2 -> 0.
- **A bound callable reference names its function supertypes.**
  `receiver::method` built a synthetic instance whose class named no
  supertypes, so `is Function0<*>` was false.

### Root: a member call on a bound reference invoked it

`s::produce` is a `$bound_ref$produce` synthetic instance. A member call on
it that was not `invoke` — `f.asFlow()`, or any extension declared on a
function type — returned the BOUND METHOD's result instead of binding the
extension: `(() -> T).asFlow()` on `source::produce` yielded an `Int`, so
`FlowOnTest`'s three cases died on `flowOn`/`size` over a `kotlin.Int`.

Two roots, both in `host_call_member.zig`:

1. `boundRefDispatch`'s tail forwarded EVERY unknown member name to the
   bound member. It now declines when an extension declared on a function
   type is in scope for the name (`invoke`/`call` keep forwarding — those
   are the reference's own surface), so the ordinary member/extension walk
   runs.
2. With the walk reached, the extension fallback kept eight lenient
   `asFlow` survivors and picked `Iterable<T>.asFlow()` — the flow body
   then called `iterator()` on the reference (`get_field entries on
   $bound_ref$produce`). `receiverDefinitelyNotParam` disproved nominal
   receiver types for `.IrClosure`/`.BoundMethod` only. A bound reference
   is a function value carried as an Instance, so the same rule applies to
   it: `isBoundReference` now feeds the callable-receiver arm.

`FlowOnTest` 15/3 -> 17/1 (the survivor is a distinct
`CancellationException`-vs-`IllegalStateException` shape). Guarded by
`examples/bound_callable_reference.kt`, which now declares
`(() -> T).twice()`, `(() -> Int).label()` and a same-named
`Iterable<T>.label()` and asserts each binds its own receiver.

### Open: `BufferedChannelTest` reaches into upstream's channel internals

7 failures read `bufferEnd` on `KlioBufferedChannel`. The tests cast the
channel to upstream's `BufferedChannel` and call
`checkSegmentStructureInvariants()`, which walks the segment list of a data
structure klio replaces with a native channel. Closing this means running
upstream's real `BufferedChannel.kt` instead of the native one — the same move
the snapshot-core port made — not weakening the test.

### Open: compose examples segfault under GC stress

`GC_STRESS=1 scripts/gc_stress_examples.sh` reports SIGSEGV (rc=139) on
`compose_ui.kt`, `compose_ui_lazy.kt` and `compose_ui_click.kt`, and the
120s timeout (rc=124) on `compose_foundation_lazy.kt`,
`compose_multiwindow.kt`, `compose_window.kt` and `compose_ui_dashboard.kt`.
The segfaults survive the field-write-memo fix, so they are a separate root.
Everything else in the corpus passes under stress.

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
- [x] B16. CLOSED 2026-08-31 — io at 1191/0; the surrogate family died in the era's fixes (the ruled-out list stands for future readers). Original record: **io's last 9.** Seven are lone-surrogate cases in `Utf8Test`
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
- [x] B22. CLOSED 2026-08-31 — io at 1191/0. Original record: **io's LAST failure: a local extension function shadows a
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
- [x] B21. CLOSED 2026-08-31 — datetime at 519/0. Original record: **A nested local class named `Key` collides.** The same repro with
      the class named `Key` fails differently —
      `InstantiationError: Cannot create an instance of an interface: Key` —
      so the name resolves to some other `Key` in scope rather than the
      user's nested declaration. Renaming to a unique name gives B20's error
      instead. Per the project's root-cause rule a user declaration must win
      such a clash, so this is a real bug and NOT to be worked around by
      renaming. Found by accident while reducing B20.
- [x] B19. CLOSED 2026-08-31 — datetime at 519/0. Original record: Qualified access to a nested class of a local class
      (`Decrypting.Marker()`) fails with
      `Vm::call_member Marker on kotlin.reflect.KClass`. Separate from B18 —
      reaching the same class from INSIDE the local class works. Found while
      writing B18's example.

- [x] B23. CLOSED 2026-08-31 — datetime at 519/0. Original record: **datetime: `alternativeParsing` formats its ALTERNATIVES once
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

- [x] B24. **Upstream-channel cutover + the internal `Segment` namesake.**
      `hostBindings()` no longer registers the native
      `kotlinx.coroutines.channels.Channel` factory by default, so upstream's
      `Channel(...)` (BufferedChannel / ConflatedBufferedChannel) serves;
      `KLIO_NATIVE_CHANNEL=1` restores the native factory for A/B. Coroutines
      1280/19 -> 1292/7 (BufferedChannelTest 7 and the undelivered-element
      family land with upstream's own implementation). The cutover exposed a
      resolution root: `kotlinx.coroutines.internal.Segment` (internal)
      collides with kotlinx.io's public `Segment` in the combined image, so
      the internal classifier is package-mangled — and every cross-package
      reference that legally reaches it through an import of its declaring
      package (ChannelSegment's supertype, sync/Semaphore's SemaphoreSegment,
      `is Segment` type refs) silently bound the PUBLIC namesake instead: the
      inherited-member walk then missed `cleanPrev`/`_prev` (ktor 450 -> 419
      under the cutover). Fix: `importedPkgTypeRename` — rename resolution
      follows wildcard/named imports of the declaring package — applied in
      `populateClassSupertypes` (IR supertype identity), the runtime ClassDef
      `supertype_names`, and `scopeTypeRename` (general type refs). Also
      `classByNamePreferring`: the three inherited-member hierarchy walks in
      `host_call_member.zig` resolve a simple-name supertype by longest
      common FQN prefix with the referencing class (`WalkItem.hint`), so a
      name-chain fallback can never cross into another package's namesake.
      Example: `examples/channel_segment_namesake.kt`. ktor back to 450/0
      under the cutover; all other suites held.

- [x] B25. **Aliased-import inline splice picked the namesake — flows were
      never uncancellable.** `CancellableTest.testCancellable`: a plain
      operator chain must NOT stop at a mid-collect cancel (500500), only
      `.cancellable()` must (1). klio returned SafeFlow from `onEach` because
      Transform.kt's `transform { ... }` — an ALIASED import of
      `unsafeTransform` — resolved correctly in the indexed bare-call path
      (`[bare] transform -> unsafeTransform#2876`) but the INLINE body pick
      is name-keyed (`inlineFnAstForRecv("transform")`) and its
      receiver-narrowed answer (the public safe `transform`) PREEMPTS the
      index's exact pick in `inlineTargetForBareCall`. The splice therefore
      expanded the safe body (`Call flow#2776` visible in
      `dump-ir --func onEach`), wrapping every operator chain in SafeFlow
      and making it cancellable. Fix: unalias the inline lookup name — when
      the call-site file's renamed import denotes an inline declaration, the
      candidate-table lookup uses the TARGET's declared leaf name
      (`inline_nm`); the indexed resolution keeps the source name (it
      already handles renamed imports). Example:
      `examples/flow_cancellable_operator.kt`.

- [x] B26. **Invoke convention: a receiver-typed lambda PARAMETER shadows
      the receiver's same-named member.** `flow.emit(1)` inside SharedFlowTest's
      inline `testSubscriptionByFirstSuspensionInCollect(flow, emit: T.(Int) ->
      Unit)` must invoke the local `emit` (Kotlin resolves the nearer local
      scope), not `MutableStateFlow`'s own member `emit` — the member bound and
      the collector never saw the pre-assert yield. New arm in
      `lowerCallGeneral` next to the existing `this.f(x)` case: a qualified
      call whose name is a RECEIVER-typed inline-lambda param splices the
      lambda with the qualifier as its receiver (plain `(Int) -> Unit` params
      stay with the member — inapplicable to a qualified call).
      Repro: scratchpad/sfyield2.kt.

- [x] B27. **`flow {}` chains are cancellable again.** klio's SafeCollector
      actual had deliberately dropped the per-emit `ensureActive()` on the
      wrong theory that plain flows are never cancellable; the truth (settled
      by B25) is that only the UNSAFE builders skip the check — the safe
      `flow {}`/`transform {}` DO ensureActive on the collecting context, and
      `cancellable()` exists for the unsafe operator chains. Restored in
      klioMain SafeCollector.emit.

- [x] B28. **Qualified suspend-intrinsic property call:**
      `kotlin.coroutines.coroutineContext.cancel()` lowered as ONE dotted
      global (`unresolved global kotlin...cancel`) while the plain read
      worked. The `kotlin.math.PI.toFloat()` property-prefix split in
      `lowerFqnGlobalCall` only consults the top-level-property registry,
      which has no row for the compiler-intrinsic property; the prefix is now
      special-cased so the call lowers as LoadGlobal(prefix) + CallMember.
      This was the actual IdFlowTest×2 blocker ("Exception was expected but
      none produced" — the cancel() never ran).

- [x] B29. **Compose regression from B24, fixed: the runtime name domain
      must understand file-mangles.** Linking `Operation.Downs : Operation$f83`
      correctly (B24's populate rename) let the inherited-member walk ascend
      into the mangled base, where `receiverDefinitelyNotParam` could no
      longer prove `InsertSlotsWithFixups` is not an `OperationArgContainer`
      (that name resolves to NO class — both declarations are mangled) — the
      walk then bound the member-EXTENSION `executeWithComposeStackTrace` with
      the dispatch receiver in the extension-receiver slot, and every
      compose/mosaic example died with `unresolved global getObject`.
      Fix: `stripFileMangle` (`X$f12` -> `X`) + `anyFileMangledVariant` in
      host_call_member — the classes-map presence check accepts a mangled
      variant, and every chain comparison (argDefinitelyNotParamType walk,
      class_super_names tailMatch, receiverImplementsHead) also matches a
      chain entry's source spelling.

- [x] B30. **The dynamic member bail carries an unsafe-cast receiver's
      declared type.** `(this as Flow<T>).catch(action)` in the deprecated
      `SharedFlow.catch` stub lowered to a plain dynamic CallMember with no
      static evidence when a batch sibling (test-utils' reified
      `LaunchFlowBuilder.catch`) pushed the site off the direct path — the
      runtime extension pick then re-bound the SharedFlow stub on the
      runtime receiver and self-recursed to stack overflow (the batch-only
      onSubscriptionThrows failures). The bail now stamps `declared_recv`
      from the cast, and the extension-selection filter excludes the
      subtype-declared candidate, exactly as kotlinc resolves through the
      cast. Both onSubscriptionThrows tests pass in-batch.

- [x] B31. **Suspending inline-builder lambdas never cross the host
      boundary.** `ReceiveChannel.toList()` = `buildList { consumeEach(::add) }`
      — the builder lambda SUSPENDS per element, but the call lowered to the
      native `__klio_buildList` intrinsic, which invokes the lambda across a
      non-suspending seam: the suspension was dropped
      ("[SUSPEND-LOST] ... activation dropped", the last census failure).
      Two-part fix: (1) `argLambdaMaySuspend` — the bare-inline splice gate
      also splices when an argument lambda contains a call with any suspend
      declaration (an inline lambda inherits the caller's suspend
      capability), so `buildList` expands through its source chain; (2) the
      klio `buildListInternal` actuals are pure Kotlin
      (`ArrayList<E>().apply(builderAction)`, the upstream JVM shape) so the
      spliced chain bottoms out in interpreted code that parks normally.
      Example: `examples/suspending_build_list.kt`. Coroutines 1299/0 — EVERY census suite at zero.

- [x] B32. **SAM conversion had timing-dependent identity.** The
      compose_plugin gate regressed on `CompositionTests.funInterface_isMemoized`:
      `samConvertActivationArgs` wraps a lambda argument into a fun-interface
      instance based on a direct-mapped per-func mask cache, so a cache
      eviction between two compositions wrapped the SECOND `TestMemoizedFun`
      argument and not the first — `remember { compute }` held the raw
      closure and the recompose compared it against a fresh wrapper (the
      pre-session pass was itself eviction-order luck). `equals` dispatched
      ON the wrapper routes into the wrapped lambda, so the fix makes
      equality see through the wrapper: `Value.samTargetOf` +
      `structuralEq` unwraps either side, and the eval `==` arm
      short-circuits SAM wrappers to structural equality before the member
      dispatch. The plugin gate returned to its 1375 baseline (remaining
      failures = the known concurrency group, inflated under battery load).
      Also: the gate itest now prints the failing names BEFORE the baseline
      expect, so a red gate is actionable.

- compose_plugin standing (2026-08-22): 1375/15-under-load (baseline 1375,
  MAX_FAILED 11 sized for solo runs; the concurrency group flips more under
  8-way census load — measure the gate SOLO).

- [x] B33. **Native channel machinery DELETED.** The upstream cutover held
      through every gate, so the `KLIO_NATIVE_CHANNEL` lever and the whole
      native FIFO went away rather than rotting behind a flag:
      `ChannelState`/`Deque`, the factory and all channel member bindings,
      the waiter/watcher lifecycle (`armChannelCancel`, `channelCancelWaiter`,
      `resumeWaiterNormal`, `chanResumeNow`), the select bridge intrinsics,
      the iterator machinery, the registry's channel fields + GC root, the
      `KlioChannelClauses.kt` select glue and KlioRuntime.kt's
      `__kxco_chan*` declarations, and the `KLIO_CHAN_DIAG` knob
      (src/kotlinx_coroutines 3073 -> 757 lines). Upstream `BufferedChannel`
      carries its own select clauses and cancellation, so nothing replaces
      them. The host-synth supertype arms for the Klio channel classes went
      too; general synth/anon dispatch mechanisms stay (comments no longer
      cite the deleted classes as their motivating example).

## Traps

- `zig-out/bin/klio` goes stale silently. A pack build against a stale binary
  fails with errors that look like interpreter bugs but are not; the itest
  suites build their own current binary, which is why a suite can pass while
  a hand-run pack build fails. Check the binary's date against recent commits
  before believing a parse error.
- Heavy census suites must be measured **solo**. Concurrent runs skew the
  counts, and compose_plugin's per-class timeout makes it the most sensitive.


## Track D — ratchet audit after CI green (opened 2026-09-05)

CI runs every census on the ReleaseSafe harness now (`ci-green.md`), so a
baseline is only a gate if it sits at the measured pass count. Audit
every suite's baseline against its current count and ratchet the ones
with slack. Parent plan: `green-main-backlog.md`.

- [x] `stdlib_commontest`: passes 2301 (1024 + 1277 across the two
      shards, `MAX_FAILED = 0`), baseline was 2150 — 151 tests of slack.
      `BASELINE = 2301` (2026-09-05); the sharded coarse minimum follows
      the proportional rule already in the runner.
- [x] every other suite, audited against CI run 33953220015 (`gh run view
      33953220015 --log` prints every summary): coroutines 1299 vs
      baseline 1297 → ratcheted to 1299; exact already: androidx 1841,
      atomicfu 67, compose_ui 452, datetime 519, io 1191, ktor 450,
      serialization 138, json 747; plugin gate 1385 = 1390 − MAX_FAILED
      (intentional, see the runner comment).
- [ ] record the ratchet rule in `ci-green.md`: a baseline moves UP with
      the count; it moves down only with a root-caused record.
