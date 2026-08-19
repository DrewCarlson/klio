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
| datetime | 450 | 70 | 87% |
| coroutines | 1040 | 150 | 87% |
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
- [ ] B4. coroutines (150) and datetime (70) — the largest absolute masses.

## Suites at zero

`stdlib`, `androidx_collection`, `atomicfu`.

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

      NOT attempted: `prefer_member` governs bare-call preference program
      wide, and `localFnOverloads` deliberately only selects when a name is
      declared twice as a LOCAL fn — the member-extension sibling is invisible
      to it. Changing that rule for one test carries more regression risk than
      it is worth without a full sweep behind it. Do it with the corpus and
      both heavy suites ready to run. `private inner class RC4Key(key:
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

## Traps

- `zig-out/bin/klio` goes stale silently. A pack build against a stale binary
  fails with errors that look like interpreter bugs but are not; the itest
  suites build their own current binary, which is why a suite can pass while
  a hand-run pack build fails. Check the binary's date against recent commits
  before believing a parse error.
- Heavy census suites must be measured **solo**. Concurrent runs skew the
  counts, and compose_plugin's per-class timeout makes it the most sensitive.
