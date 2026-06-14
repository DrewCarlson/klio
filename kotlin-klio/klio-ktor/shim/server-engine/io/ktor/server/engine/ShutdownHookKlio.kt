// klio `actual`s for the engine shutdown hook (the native version installs a
// posix signal handler via cinterop; klio's serve loop is abandoned at the
// run boundary instead, so no hook is needed).

package io.ktor.server.engine

internal actual val SHUTDOWN_HOOK_ENABLED: Boolean = false

internal actual fun EmbeddedServer<*, *>.platformAddShutdownHook(stop: () -> Unit) {}
