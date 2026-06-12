// klio `actual` for the ktor-client engine `ioDispatcher` expect. The posix
// actual binds a background thread pool; klio's host transport is a
// blocking synchronous call (`__kktor_request`), so engine I/O dispatches
// on the inline `Unconfined` dispatcher and runs on the calling thread for
// the duration of the request.

package io.ktor.client.engine

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

internal actual fun ioDispatcher(): CoroutineDispatcher = Dispatchers.Unconfined
