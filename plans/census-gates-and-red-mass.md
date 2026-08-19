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
| serialization | 60 | 78 | 43% |
| datetime | 450 | 70 | 87% |
| coroutines | 1040 | 150 | 87% |
| io | 1150 | 45 | 96% |
| compose_plugin | 1375 | 15 | 99% |
| androidx_collection | 1309 | 15 | 99% |
| atomicfu | 63 | 8 | 89% |
| ktor | 440 | 6 | 99% |
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
- [ ] B4. coroutines (150) and datetime (70) — the largest absolute masses.

## Traps

- `zig-out/bin/klio` goes stale silently. A pack build against a stale binary
  fails with errors that look like interpreter bugs but are not; the itest
  suites build their own current binary, which is why a suite can pass while
  a hand-run pack build fails. Check the binary's date against recent commits
  before believing a parse error.
- Heavy census suites must be measured **solo**. Concurrent runs skew the
  counts, and compose_plugin's per-class timeout makes it the most sensitive.
