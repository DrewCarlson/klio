# kotlin-test library + test runner infrastructure

## Goal

Give KLIO a `kotlin.test` library and a test runner so that:

1. End users can write `@Test` functions with `kotlin.test` assertions and run them.
2. KLIO's own packs (stdlib, kotlinx) can execute their upstream `commonTest`
   sources through the interpreter.

The first validation target is the **stdlib `commonTest` suite**
(`kotlin/libraries/stdlib/test/`). Running Kotlin's own standard-library tests
through KLIO is the bootstrapping check for the whole project: it exercises the
interpreter against the same assertions the language authors use.

## Pieces

### 1. `kotlin.test` pack (`kotlin-klio/klio-kotlin-test/`)

`kotlin.test` is not part of the sparse `kotlin` submodule checkout (only
`stdlib` is present), so the common API is authored here, matching the upstream
public surface.

- `commonMain/kotlin/test/Asserter.kt` — `Asserter` interface,
  `AsserterContractViolation`, `DefaultAsserter` (throws `AssertionError`),
  `assertEquals`-style contract.
- `commonMain/kotlin/test/Assertions.kt` — the public assertion functions
  (`assertEquals`, `assertTrue`, `assertFalse`, `assertNull`, `assertNotNull`,
  `assertSame`, `assertNotSame`, `assertNotEquals`, `assertFails`,
  `assertFailsWith`, `assertContains`, `assertContentEquals`, `assertIs`,
  `assertIsNot`, `expect`, `fail`, `todo`) delegating to `asserter`.
- `klioMain/kotlin/test/Annotations.kt` — `Test`, `Ignore`, `BeforeTest`,
  `AfterTest` annotation classes.
- `klioMain/kotlin/test/Lookup.kt` — `asserter` provider + `currentStackTrace`.
- `klio.toml` — library id `kotlin.test`, depends on `stdlib`, no host bindings.

The pack is loaded by the same import-prefix mechanism as the kotlinx packs
(`kotlin.test.*` imports pull it in). It is not implicitly imported.

### 2. Annotation retention (ast -> IR -> runtime)

Annotations are parsed today but dropped before runtime. Plumb the resolved
annotation FQNs onto:

- `ir.Func.annotation_names` (new field, mirrors `ClassDef.annotation_names`).
- `runtime ClassDef.annotation_names` (field exists, currently always empty).

Names are resolved to FQNs through the file's imports during lowering so the
runner matches `kotlin.test.Test` rather than a bare `Test` that could collide.

### 3. Test runner (`src/test_runner/`) + `klio test`

A subsystem module outside the core pipeline. Given test sources, it:

- Builds the module like `run` (lex -> parse -> resolve -> typeck -> IR).
- Discovers `@Test` functions (top-level and in classes), honouring `@Ignore`,
  running `@BeforeTest`/`@AfterTest` around each.
- Instantiates the enclosing class via its no-arg constructor per test.
- Executes each test, catching `AssertionError`/exceptions as failures.
- Prints Gradle/Kotlin-style per-test results + a summary; exits non-zero on
  any failure.

`klio test <files|dir>` dispatches to it.

## Status

- [x] kotlin.test pack authored + loadable — upstream common referenced via the
      `kotlin-klio/klio-kotlin-test/upstream` symlink into the `kotlin` submodule;
      `klioMain` holds only the actuals (annotations, `lookupAsserter`,
      `AssertionErrorWithCause`, `todo`, `checkResultIsFailure`).
- [x] annotation retention plumbed (`ir.Func` / `runtime.ClassDef` annotation FQNs)
- [x] test_runner + `klio test` — discovers `@Test`/`@Ignore`/`@BeforeTest`/
      `@AfterTest`, fresh instance per test, Gradle-style report, non-zero exit.
- [x] runner itest: `src/itests/stdlib_commontest.zig` runs a curated set of
      upstream stdlib commonTest files through a child `klio test`.
- [~] stdlib commonTest subset green (bootstrap proof), expanding monotonically.
      Passing today (referenced in place from the submodule): `utils/HashCodeTest`,
      `collections/IteratorsTest`, `collections/HashMapCompactTest`, `utils/LazyTest`,
      `utils/TODOTest`, `numbers/BuiltinCompanionTest`, `time/TestTimeSourceTest`,
      `ranges/ProgressionLastElementTest`, `properties/delegation/lazy/LazyValuesTest`,
      `comparisons/BooleanOrderingTest`.
      Grow the `PASSING` list in the itest as the interpreter closes the gaps below.

## Interpreter fixes surfaced while bootstrapping

- Parser/lexer: nullable-receiver callable references (`Any?::toString`,
  `Array<*>?::contentToString`); `?::` lexing (vs elvis `?:`); nullable-receiver
  function types (`T?.() -> R`).
- Top-level computed `val` (getter-only) now resolves and re-evaluates per read
  (the `kotlin.test` `asserter` property).

- Reified `T::class.<member>(...)` for a builtin type bound the constructor
  intrinsic instead of the `.Class` value (so `isInstance` mis-dispatched) —
  fixed by carrying the resolved class id on the reified binding's `LoadGlobal`.

- `assertFailsWith<T>` / `assertIs<T>` for a builtin: an inline call with a
  defaulted leading param plus a trailing lambda mapped the lambda to the
  defaulted param, leaving a required param unfilled, so the splice was declined
  and the reified class id was lost. Fixed by applying Kotlin's trailing-lambda
  argument mapping in `tryInlineCallWithTypeArgs`.

- `Boolean.compareTo` had no host binding and the common declaration is bodyless,
  so it recursed; added the `kotlin.Boolean.compareTo` binding.

### Open (each blocks more of the stdlib commonTest suite)

- `klio run` (baked stdlib-image path) does not register top-level computed-val
  getters, so the pack `asserter` is unresolved when a program is run via the
  image fast-path. `klio test` (legacy build path) is unaffected, so the proof
  is not blocked; the image path should carry `top_level_prop_getters`.
- `Boolean.compareTo` recurses without terminating (e.g. `comparisons/
  BooleanOrderingTest`).
- Other per-file gaps surface as the `PASSING` list grows (enum entries,
  unsigned math, string builder, abstract list).
