/*
 * klio-authored declaration for the console reader the interpreter serves.
 *
 * `readLine` has no Kotlin source in this tree (the upstream declaration is a
 * JVM platform file klio does not consume), so resolution could only reach it
 * through a runtime name probe — the exact hole the no-holes symbol table
 * exists to close. The body is the platform contract: the next line without
 * its terminator, or null at end of input.
 */
package kotlin.io

public fun readLine(): String? = readlnOrNull()
