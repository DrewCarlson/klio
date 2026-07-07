# Testing Kotlin with KLIO

KLIO ships the common `kotlin.test` API and a test runner so programs can be
verified the same way they are on Kotlin/JVM, Kotlin/JS, and Kotlin/Native.

## Writing tests

Annotate functions with `@Test` and assert with `kotlin.test`:

```kotlin
import kotlin.test.Test
import kotlin.test.BeforeTest
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class CalculatorTest {
    private lateinit var calc: Calculator

    @BeforeTest
    fun setUp() { calc = Calculator() }

    @Test
    fun adds() {
        assertEquals(4, calc.add(2, 2))
    }

    @Test
    fun rejectsDivideByZero() {
        assertFailsWith<IllegalArgumentException> { calc.div(1, 0) }
    }
}

@Test
fun topLevelTestsWorkToo() {
    assertEquals("ok", compute())
}
```

Supported annotations: `@Test`, `@Ignore`, `@BeforeTest`, `@AfterTest`. A fresh
instance of the enclosing class is created for each `@Test` method (JUnit
semantics): `@BeforeTest` methods run before it, `@AfterTest` methods after.

The full common assertion surface is available: `assertEquals`,
`assertNotEquals`, `assertTrue`, `assertFalse`, `assertNull`, `assertNotNull`,
`assertSame`, `assertNotSame`, `assertContains`, `assertContentEquals`,
`assertIs`, `assertIsNot`, `assertFails`, `assertFailsWith`, `expect`, `fail`.

## Running tests

```
klio test                          # the project in the current directory
klio test path/to/MyTest.kt        # a single file
klio test src/test                 # every .kt under a directory (recursive)
klio test a.kt b.kt                 # several files as one module
klio test kotlin-klio/klio-kotlinx-io   # a project (its klio.toml [[test]] sets)
```

Each test prints `PASSED`, `FAILED` (with the failure message), or `SKIPPED`
(for `@Ignore`), followed by a summary. The process exits non-zero if any test
fails, so `klio test` slots directly into CI.

```
CalculatorTest.adds PASSED
CalculatorTest.rejectsDivideByZero PASSED
topLevelTestsWorkToo PASSED

3 tests, 3 passed, 0 failed, 0 skipped
```

### Project mode

Given a directory that carries a `klio.toml` manifest with `[[test]]` source
sets, `klio test <dir>` (or `klio test` with the manifest in the current
directory) builds+installs the project's pack, then composes its active test
sources into **one module** and runs them. Whole-module composition resolves
cross-file references correctly — running the same files individually breaks
cross-file resolution and mis-counts. `[[test]]` sets can be feature-scoped;
`--all` (default) runs core + every feature module, `--feature <name>` narrows
to core + the named feature(s). See [Authoring a pack](packs/authoring.md) for
the `[[test]]` manifest schema.

### Runner options

- `--filter <substring>` — run only tests whose `Class`, `Class.method`, or
  file name contains the substring.
- `--format <plain|json>` — `plain` (default) is the human-facing per-test list
  plus summary; `json` emits a machine-readable object
  (`{"total":N,"passed":P,"failed":F,"skipped":S,"tests":[{"name","outcome","detail"}]}`)
  for CI ratchets.
- `--list` — print the discovered `@Test` names without running any.
- `--isolate [--timeout <s>]` — an opt-in debugging mode that runs **each test in
  its own sub-process** with a per-test wall-clock timeout (default 60s), so a
  test that hangs is pinpointed as `TIMEOUT` and one that crashes as `CRASH`,
  instead of taking the whole suite down. The default single in-process run is
  faster; reach for `--isolate` only to locate a bad test.
- `--all` / `--feature <pack>/<feature>` — select which feature modules'
  sources and tests are active.
- `--virtual-time` — deterministic virtual time for coroutines (as in `klio run`).

```
klio test kotlin-klio/klio-kotlinx-io --filter ByteStringTest --format json
klio test kotlin-klio/klio-kotlinx-datetime --isolate --timeout 5   # find the hang
```

## The `kotlin.test` pack

`kotlin.test` is a normal KLIO pack (`kotlin-klio/klio-kotlin-test`). Its
public API is the upstream common source, referenced directly from the `kotlin`
submodule; KLIO supplies only the platform actuals (the annotation classes and
the asserter that reports failures by throwing `AssertionError`). Build and
install it like any pack:

```
klio pack build kotlin-klio/klio-kotlin-test
klio pack install target/packs/kotlin.test.klio-pack
```

Because the API is the real upstream `kotlin.test`, a KLIO pack's own upstream
`commonTest` sources run unmodified through `klio test`.
