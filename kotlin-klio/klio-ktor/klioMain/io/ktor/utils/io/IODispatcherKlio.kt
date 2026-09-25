// klio `actual` for the ktor-io `ioDispatcher()` expect, upstream's posix
// actual: engines and the socket layer run their I/O on `Dispatchers.IO`.
// Upstream imports the native-only `kotlinx.coroutines.IO` extension; klio's
// `Dispatchers` declares `IO` as a member, as the JVM does.

package io.ktor.utils.io

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

public actual fun ioDispatcher(): CoroutineDispatcher = Dispatchers.IO
