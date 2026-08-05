/*
 * klio-authored declaration for the process exit the interpreter serves.
 *
 * The upstream declaration lives in a JVM platform file klio does not consume,
 * so resolution could reach `exitProcess` only through a runtime name probe.
 * The body never returns — the host terminates the process with `status` — and
 * the `Nothing` return is what lets a call in a `when` branch or an elvis tail
 * type-check the way Kotlin's does.
 */
package kotlin.system

public fun exitProcess(status: Int): Nothing = __klio_exit_process(status)

internal fun __klio_exit_process(status: Int): Nothing =
    throw IllegalStateException("exitProcess($status) is host-served")
