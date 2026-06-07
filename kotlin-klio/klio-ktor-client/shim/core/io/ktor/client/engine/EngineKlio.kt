// klio `actual` for the ktor-client engine `ioDispatcher` expect. The posix
// actual binds a background thread pool; klio runs single-threaded, so engine
// I/O dispatches on the inline `Unconfined` dispatcher (the request itself is
// driven synchronously through the host `__kktor_request` binding).

package io.ktor.client.engine

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

internal actual fun ioDispatcher(): CoroutineDispatcher = Dispatchers.Unconfined
