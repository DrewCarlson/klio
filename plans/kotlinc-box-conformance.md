# kotlinc box-test conformance corpus

The Kotlin compiler's own `compiler/testData/codegen/box` suite is the widest
executable oracle for a Kotlin implementation: 7,351 `.kt` programs at the
pinned `kotlin` submodule revision (build-2.4.10-RC), each declaring
`fun box(): String` that must return `"OK"`. klio runs none of them today: the
`kotlin` submodule is a blobless sparse clone of `libraries/stdlib` and
`libraries/kotlin.test` only (`scripts/init-kotlin-submodule.sh`, CI's
"populate kotlin" step in `.github/workflows/ci.yml`).

Parent plan: `conformance-backlog.md`. Verification practice:
`verification-speed-plan.md` (harness + sweep, census children, ratchets);
gate wiring: `census-gates-and-red-mass.md`.

## Why this corpus

- Every program is small, deterministic, and self-checking; a failure is a
  semantic gap, not a flaky wall.
- It covers the language surface systematically (directories are features:
  `when`, `ranges`, `inlineClasses`, `coroutines`, `delegatedProperty`,
  `smartCasts`, `varargs`, `properties`, `sealed`, `contracts`, ...), so
  failures cluster by mechanism and each root fix closes many at once.
- It is the same oracle kotlinc gates itself on: matching it IS matching
  Kotlin semantics.

## Corpus facts to design against

- Directives are `// NAME` or `// NAME: value` header comments. Seen in a
  40-file sample of `box/ranges`: `WITH_STDLIB` (37), `FILE: name.kt` (18,
  splits one test into several source files), `LANGUAGE: +Feature` (7),
  `KJS_WITH_FULL_RUNTIME` (6). Others across the corpus: `TARGET_BACKEND`,
  `DONT_TARGET_EXACT_BACKEND`, `IGNORE_BACKEND`, `MODULE: name(deps)`,
  `WITH_COROUTINES` (pulls the framework's coroutine helpers),
  `WITH_REFLECT`, `FULL_JDK`, `JVM_TARGET`, `ASSERTIONS_MODE`.
- Multi-module tests (`MODULE:`) and JVM-only tests (`TARGET_BACKEND: JVM`,
  `FULL_JDK`, `WITH_REFLECT`, anything importing `java.*`) are out of klio's
  model; they are excluded BY DIRECTIVE, never by name.
- The sparse checkout must add `compiler/testData/codegen/box` and the
  helpers the directives reference (`WITH_COROUTINES` helpers live beside
  the corpus under `compiler/testData/codegen/helpers`; confirm the path
  when populating). Blobless clones fetch blobs lazily: the runner must
  never read the corpus through `git show`; populate once.

## Tasks

1. **Populate.** Extend `scripts/init-kotlin-submodule.sh` and the CI
   "populate kotlin" step with the two directories; `scripts/bootstrap.sh
   --packs` stays the one-shot. Exit: `kotlin/compiler/testData/codegen/box`
   present locally and on CI (the CI campaign's rule: populate every
   `update = none` submodule a corpus reads).
2. **Runner.** A census suite `box` (`src/itests/box_conformance.zig`,
   registered in `src/itests/census_main.zig`, driven by
   `zig-out/bin/klio-census box` with `KLIO_ITEST_BIN`) that: parses the
   directives; splits `FILE:` sections into files; selects by directive
   (an allowlist of directives klio honors, a denylist of JVM/JS/module
   ones, every exclusion counted and printed by reason); synthesizes
   `fun main() { val r = box(); if (r != "OK") throw AssertionError(r) }`
   as a trailing file (never edits the test); batches one directory per
   child like the sweep (`--no-batch` for isolation); per-file wall cap;
   names every failure (`[box-fail] dir/file.kt: <first line>`) and every
   exclusion reason. Exit: the suite runs end to end and prints
   `passed / failed / excluded(by reason) / did-not-complete`.
3. **Baseline.** Record the first full census (wall, pass count, exclusion
   census) here; ratchet `BASELINE` to the measured pass count with
   `MAX_FAILED 0`; add the suite to `scripts/stack.sh` and to a CI shard
   with a measured weight (4-core ReleaseSafe seconds ÷ 10). Exit: green
   battery and CI with the box suite standing.
4. **Root-fix by cluster.** Group failures by the first diagnostic or miss
   trace (`KLIO_ERR_TRACE`, `KLIO_MISS_TRACE`, `KLIO_BARE_TRACE`), take the
   largest cluster, root-fix the mechanism (never the test), re-census,
   ratchet up. Every fix ships an `examples/` program with its `.out` and
   README row, as the resolution-residue work did. Exit for this plan:
   every cluster of size ≥ 5 is either root-fixed or carries a verdict
   here (unsupported-by-design with the directive that should exclude it,
   or a named open mechanism with its repro); the residue list is the
   seed of the next campaign.

## Traps (from the stdlib and library censuses)

- A per-file compile that loses its helper files fails for starvation, not
  semantics (`klio-library-100-campaign` keeper): batch per directory.
- The census names must always print; a bare count is undiagnosable.
- Child timeouts must sit ≥ 1.5× the slowest healthy child on a 4-vCPU
  runner; harness Debug builds run ~4× slower (`harnessSlowdown`).
- A renamed or simplified copy of a failing test is for bisecting only;
  the corpus file must pass unmodified.

## Runner facts (2026-09-05)

- Populated: `scripts/init-kotlin-submodule.sh` now lists
  `compiler/testData/codegen/box` and
  `compiler/testData/diagnostics/helpers/coroutines` (the `WITH_COROUTINES`
  helpers: CoroutineUtil, CoroutineHelpers, StateMachineChecker,
  TailCallOptimizationChecker, all `package helpers`); 7,351 `.kt` files in
  174 directories, 36 MB; CI's kotlin cache key carries `-codegen-box`.
- Shape: one child `klio run` per selected test (a warm trivial run is
  0.087 s, so the corpus is minutes on 4 cores), sections written as
  numbered files under `/tmp/klio_itest_box_home/cases/<path>/`, a
  synthesized `__box_main.kt` (`import <pkg>.box` when the box file has a
  package) that throws unless `box() == "OK"` and prints `BOX-OK`; the
  helpers appended for `WITH_COROUTINES`; `OPTIONAL_JVM_INLINE_ANNOTATION`
  replaced by `@JvmInline` under `WORKS_WHEN_VALUE_CLASS`. Runner:
  `src/itests/box_support.zig` (shared by the `box_conformance` itest and
  `klio-census box`). Knobs: `KLIO_BOX_FILTER` (path substring),
  `KLIO_ITEST_JOBS`, `KLIO_BOX_TIMEOUT_MS` (60 s, ×4 on a Debug harness).
- Directive census over the corpus (files): WITH_STDLIB 3,582; LANGUAGE
  1,708 (27 disable a feature → excluded); WORKS_WHEN_VALUE_CLASS 740;
  WITH_COROUTINES 500; MODULE 491; TARGET_BACKEND 272; IGNORE_BACKEND 285;
  WITH_REFLECT 109; CHECK_TYPE_WITH_EXACT 44 (framework helper → excluded);
  Java sections 5; no `box()` 2. Header-only scan (directives before the
  first code line) keeps body comments like `// TODO:` out of selection.
- Ratchet semantics: `BASELINE` = measured pass count (floor),
  `MAX_FAILED` = measured failure count (ceiling with no slack); a new
  failure trips the ceiling even while old ones remain. "MAX_FAILED 0" in
  the goal reads as zero slack, since the first census carries real
  failures by construction.
- Prototype sample (300 random files, before the Zig runner): 207 pass /
  47 fail / 46 excluded; failure shapes: runtime misses (`call_member`,
  `get_field`, unresolved globals), parser gaps (name-based destructuring,
  `for` with destructuring in arrays), assertion mismatches (unsigned
  stepped ranges, IEEE 754 equality, finally ordering).

## Task 3 record — first full census (2026-09-05)

ReleaseSafe harness, 12 workers, 147 s wall: **5,246 passed, 1,105 failed, 20 did
not complete of 6,371 selected; 980 excluded of 7,351 files.** Ratchet:
`BASELINE = 5246`, `MAX_FAILED = 1105` (`src/itests/box_support.zig`).

Exclusion census (by directive): MODULE: 447; TARGET_BACKEND: 263; WITH_REFLECT: 88; CHECK_TYPE_WITH_EXACT: 44; LANGUAGE:-feature: 27; FREE_COMPILER_ARGS: 19; FULL_JDK: 18; IGNORE_BACKEND:ANY: 14; JVM_DEFAULT_MODE: 12; API_VERSION: 10; JVM_TARGET: 9; LAMBDAS: 7; IGNORE_BACKEND_K2:ANY: 6; STRING_CONCAT: 4; USE_OLD_INLINE_CLASSES_MANGLING_SCHEME: 4; ALLOW_KOTLIN_PACKAGE: 3; ASSERTIONS_MODE: 2; NATIVE_STANDALONE: 2; SAM_CONVERSIONS: 1.

Failure shapes (first line of the child's stderr, normalized):

| Count | Shape | Example |
|-------|-------|---------|
| 246 | `runtime error: uncaught kotlin.AssertionError: box() returned …` | `annotations/instances/annotationAnnotationParam.kt` |
| 146 | `runtime error: IR eval: Vm::call_member `_` on `_`` | `associatedObjects/findAssociatedObject.kt` |
| 113 | `<file> error: expected loop variable` | `arrays/forInUnsignedArray/forInUnsignedArrayWithIndex.kt` |
| 92 | `runtime error: IR eval: Vm::get_field `_` on `_`` | `callableReference/adaptedReferences/adaptedVarargFunImportedFromObject.kt` |
| 79 | `runtime error: IR eval: unresolved global `_`` | `callableReference/adaptedReferences/innerConstructorWithVararg.kt` |
| 66 | `runtime error: uncaught kotlin.AssertionError: Expected …` | `annotations/instances/annotationWithTypeParameters.kt` |
| 34 | `<file> error: expected `_`` | `argumentOrder/arguments.kt` |
| 34 | `<file> error: expected property name` | `callableReference/function/genericCallableReferenceWithReifiedTypeParam.kt` |
| 18 | `<file> error: expected expression` | `annotations/spreadOperatorInAnnotationArguments.kt` |
| 17 | `<file> error: expected top-level declaration` | `bridges/propertyAccessorsWithoutBody.kt` |
| 15 | `runtime error: IR eval: Vm::call_value on `_`` | `callableReference/function/local/constructorWithInitializer.kt` |
| 12 | `runtime error: uncaught java.lang.StackOverflowError: Stack overflow: evaluation` | `builtinStubMethods/extendJavaClasses/arrayList.kt` |
| 10 | `runtime error: uncaught kotlin.AssertionError` | `delegatedProperty/optimizedDelegatedProperties/mixedArgumentSizes.kt` |
| 8 | `<file> error: expected newline or `_` between statements` | `contracts/lambdaParameter.kt` |
| 7 | `<file> error: expecte` | `callableReference/adaptedReferences/suspendConversion/inlineWithContextParameterAsAPropertyType.kt` |
| 6 | `<file> error: expected member name` | `extensionFunctions/executionOrder.kt` |

Failures by corpus directory: callableReference 87, controlStructures 76, multiDecl 67, enum 54, ranges 52, delegatedProperty 48, coroutines 39, inlineClasses 37, contextParameters 28, diagnostics 28, annotations 26, casts 25, defaultArguments 25, arrays 23, closures 23, properties 22, evaluate 16, ieee754 16, objects 16, extensionFunctions 15, functions 15, localClasses 14, super 14, typealias 14.

Did not complete: crashes `callableReference/function/innerConstructorFromClass.kt`, `callableReference/function/innerConstructorFromExtension.kt`, `callableReference/function/extensionFunctionWithExtensionInSAMInterface.kt`, `inlineClasses/defaultParameterValues/inlineClassSecondaryConstructorGeneric.kt`, `inlineClasses/secondaryConstructorsInsideInlineClassWithPrimitiveCarrierTypeGeneric.kt`, `functions/nothisnoclosure.kt`, `extensionFunctions/extensionFunctionWithExtensionInSAMInterface.kt`, `ranges/stepped/expression/downTo/maxValueToMinValueStepMaxValue.kt`, `ranges/stepped/expression/rangeTo/minValueToMaxValueStepMaxValue.kt`, `ranges/stepped/expression/until/minValueToMaxValueStepMaxValue.kt`, `ranges/stepped/literal/downTo/maxValueToMinValueStepMaxValue.kt`, `ranges/stepped/literal/rangeTo/minValueToMaxValueStepMaxValue.kt`, `ranges/stepped/literal/until/minValueToMaxValueStepMaxValue.kt`, `super/kt4173_2.kt`; timeouts `controlStructures/breakContinueInExpressions/continueInDoWhile.kt`, `controlStructures/breakContinueInExpressions/inlinedBreakContinue/withReturnValueDoWhileContinue.kt`, `controlStructures/breakContinueInExpressions/pathologicalDoWhile.kt`, `controlStructures/continueInWhen.kt`, `diagnostics/functions/tailRecursion/defaultArgsOverridden.kt`, `inline/loopWithInlinableCondition.kt`.

Cluster reading (Task 4 order): (1) Kotlin 2.4 destructuring syntax —
`[a, b]` positional short form and `(val a, val b = prop)` name-based full
form in `val`, `for`, and lambda parameters (~150 files across
`multiDecl`, `controlStructures`, `arrays`, `ranges`, `nameBasedDestructuring`,
`coroutines`); (2) `box() returned …` assertion mismatches (237, heterogeneous:
per-directory triage); (3) runtime dispatch misses — `call_member` (146),
`get_field` (92), unresolved global (78), `call_value` (14) — mostly
`callableReference`, `enum`, `delegatedProperty`, `contextParameters`;
(4) parser gaps: immediately-invoked lambda arguments `f(b = { … }())` (34),
extension properties on parenthesized function-type receivers
`val (Int.() -> String).baz` (32), annotation spread arguments and empty
`for (…);` bodies (30), accessor-only lines / `by` on its own line /
`x!! infix y` (27), `receiver.(expr)(args)` (6), `label@for` without space,
`context(String) () -> Unit` function types; (5) crashes: six
`…StepMaxValue` progression tests segfault in libc (step arithmetic at
`Long.MAX_VALUE`), four evaluation stack overflows (inline-class secondary
constructors, SAM extension), one RSS-cap abort (`functions/nothisnoclosure.kt`),
`super/kt4173_2.kt`; timeouts: `continue` inside `do-while` / `when` bodies
(five) and `inline/loopWithInlinableCondition.kt`.

## Log

- 2026-09-05: opened.
- 2026-09-05: Task 1 populated; Task 2 runner written (`box_support.zig`,
  `box_conformance.zig`, `klio-census box`); Task 3 first census recorded
  above and the ratchet set.
