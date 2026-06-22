/*
 * Copyright 2010-2024 JetBrains s.r.o. and Kotlin Programming Language contributors.
 * Use of this source code is governed by the Apache 2.0 license that can be found in the license/LICENSE.txt file.
 */

package kotlin.test

import kotlin.reflect.KClass

/**
 * KLIO actuals for the platform-specific `kotlin.test` declarations. KLIO has no JUnit/TestNG to
 * delegate to, so [lookupAsserter] returns [DefaultAsserter], whose failures the test runner observes
 * as thrown [AssertionError]s.
 */
internal actual fun lookupAsserter(): Asserter = DefaultAsserter

/** Construct an [AssertionError] carrying [cause]. */
internal actual fun AssertionErrorWithCause(message: String?, cause: Throwable?): AssertionError =
    AssertionError(message, cause)

/** Takes the given [block] of test code and does not execute it. */
public actual fun todo(block: () -> Unit) {
    println("TODO at test")
}

/** Asserts that [blockResult] is a failure carrying an exception of [exceptionClass] (or a subclass). */
@PublishedApi
internal actual fun <T : Throwable> checkResultIsFailure(exceptionClass: KClass<T>, message: String?, blockResult: Result<Any?>): T {
    blockResult.fold(
        onSuccess = { v ->
            asserter.fail(messagePrefix(message) + "Expected an exception of ${exceptionClass.simpleName} to be thrown, ${formatResultMessage(v)}")
        },
        onFailure = { e ->
            if (exceptionClass.isInstance(e)) {
                @Suppress("UNCHECKED_CAST")
                return e as T
            }
            asserter.fail(messagePrefix(message) + "Expected an exception of ${exceptionClass.simpleName} to be thrown, but was $e", e)
        }
    )
}
