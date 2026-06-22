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
klio test path/to/MyTest.kt        # a single file
klio test src/test                 # every .kt under a directory (recursive)
klio test a.kt b.kt                 # several files as one module
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

`klio test` accepts the same `--feature <pack>/<feature>` and `--virtual-time`
options as `klio run`.

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
