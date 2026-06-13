// klio `actual` for the `io.ktor.utils.io` ByteChannel development-mode
// flag (the JVM actual reads a system property; klio reports off, like
// the default posix/web platforms).

package io.ktor.utils.io

internal actual val DEVELOPMENT_MODE: Boolean = false
