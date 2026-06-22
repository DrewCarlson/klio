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
- [ ] runner unit/itests + corpus
- [ ] stdlib commonTest subset green (bootstrap proof), expanding monotonically

## Interpreter fixes surfaced while bootstrapping

- Parser/lexer: nullable-receiver callable references (`Any?::toString`,
  `Array<*>?::contentToString`); `?::` lexing (vs elvis `?:`); nullable-receiver
  function types (`T?.() -> R`).
- Top-level computed `val` (getter-only) now resolves and re-evaluates per read
  (the `kotlin.test` `asserter` property).

### Open

- Reified `T::class.<member>(...)` member dispatch is broken: `assertFailsWith<T>`
  and `assertIs<T>` route through `T::class.isInstance(...)`, which mis-dispatches
  (returns the class value instead of invoking the member). Fix required before the
  stdlib commonTest proof (heavy `assertFailsWith` usage).
