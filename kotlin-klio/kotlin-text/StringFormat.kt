/*
 * klio-authored declaration for `String.Companion.format`.
 *
 * The upstream declaration lives in a JVM platform file klio does not consume.
 * It formats through `String.format`, whose formatting is the host's.
 */
package kotlin.text

public fun String.Companion.format(format: String, vararg args: Any?): String =
    format.format(*args)
