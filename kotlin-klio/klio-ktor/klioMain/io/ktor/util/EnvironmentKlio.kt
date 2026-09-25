// The process environment for klio's ktor actuals, where upstream's posix
// sources call `platform.posix.getenv` through cinterop. Bound to the host
// native in src/ktor_client/ktor_client.zig; null when the variable is unset.

package io.ktor.util

internal fun __kktor_getenv(name: String): String? = null

internal fun __kktor_setenv(name: String, value: String) {}

internal fun __kktor_unsetenv(name: String) {}

internal fun __kktor_environ(): Array<String> = emptyArray()

/** The number of processors available to the process. */
internal fun __kktor_available_processors(): Int = 1

/** Writes [message] to the standard error stream, as posix `fprintf(stderr)`. */
internal fun __kktor_print_error(message: String) {}
