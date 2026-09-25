// klio actuals for the ui engine's expects the desktop answers from the JVM
// (Actual.jvmAndAndroid.kt): the wall clock and the class comparison.
package androidx.compose.ui

import kotlin.time.Clock

internal actual fun currentTimeMillis(): Long = Clock.System.now().toEpochMilliseconds()

internal actual fun areObjectsOfSameType(a: Any, b: Any): Boolean = a::class == b::class
