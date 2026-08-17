/*
 * klio-authored declarations for kotlin.system's timing helpers.
 *
 * The upstream declarations live in a JVM platform file klio does not
 * consume (jvm/src/kotlin/system/Timing.kt), whose bodies read
 * System.currentTimeMillis / System.nanoTime. klio's platform clocks are
 * the two host bindings the kotlin.time actual layer already binds:
 * wall-clock milliseconds backs measureTimeMillis and the monotonic
 * nanosecond reading backs measureNanoTime — the same clock each JVM
 * body reads.
 */
package kotlin.system

import kotlin.contracts.*
import kotlin.time.__klio_time_monotonicNanos
import kotlin.time.__klio_time_systemMillis

/**
 * Executes the given [block] and returns elapsed time in milliseconds.
 *
 * Reads the wall clock, so the result can be zero or negative under a
 * clock adjustment, exactly as on the JVM.
 */
public inline fun measureTimeMillis(block: () -> Unit): Long {
    contract {
        callsInPlace(block, InvocationKind.EXACTLY_ONCE)
    }
    val start = __klio_time_systemMillis()
    block()
    return __klio_time_systemMillis() - start
}

/**
 * Executes the given [block] and returns elapsed time in nanoseconds,
 * measured on the monotonic clock.
 */
public inline fun measureNanoTime(block: () -> Unit): Long {
    contract {
        callsInPlace(block, InvocationKind.EXACTLY_ONCE)
    }
    val start = __klio_time_monotonicNanos()
    block()
    return __klio_time_monotonicNanos() - start
}
