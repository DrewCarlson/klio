// klio `actual` for the ktor-io `ioDispatcher()` expect (the engine base
// reads it for its default dispatcher). Upstream's posix actual is
// `Dispatchers.IO`; klio's host transport (`__kktor_request`) is a blocking
// synchronous call, so engine I/O dispatches on the inline `Unconfined`
// dispatcher and runs on the calling thread for the duration of the request.

package io.ktor.utils.io

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

public actual fun ioDispatcher(): CoroutineDispatcher = Dispatchers.Unconfined
