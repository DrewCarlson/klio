package kotlinx.coroutines.internal

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.InternalCoroutinesApi
import kotlinx.coroutines.runBlocking
import kotlin.coroutines.CoroutineContext

@InternalCoroutinesApi
public fun runTestCoroutine(
    context: CoroutineContext,
    block: suspend CoroutineScope.() -> Unit,
) {
    runBlocking(context, block)
}
