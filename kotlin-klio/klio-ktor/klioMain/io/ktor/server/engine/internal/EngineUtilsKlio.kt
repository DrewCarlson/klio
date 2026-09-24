// klio `actual` for the engine's hostname escape. The JVM and posix actuals
// rewrite the `0.0.0.0` wildcard only on Windows, which klio never runs on,
// so the host is used as written.

package io.ktor.server.engine.internal

internal actual fun escapeHostname(value: String): String = value
