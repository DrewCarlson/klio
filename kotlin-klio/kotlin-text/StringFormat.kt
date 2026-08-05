/*
 * klio-authored declaration for `String.Companion.format`.
 *
 * The upstream declaration lives in a JVM platform file klio does not consume,
 * so resolution could reach the formatter only through a runtime name probe.
 * The formatting itself is host-served, and this declaration is what puts the
 * callable in the symbol table where the scope walk can see it.
 */
package kotlin.text

public fun String.Companion.format(format: String, vararg args: Any?): String =
    __klio_string_format(format, args)

internal fun __klio_string_format(format: String, args: Array<out Any?>): String = format
