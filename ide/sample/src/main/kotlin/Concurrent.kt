package dev.klio.sample

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * Suspend functions resolve the same way they do in a Kotlin project: completion
 * inside the [coroutineScope] block knows about [async] and [awaitAll].
 */
suspend fun doubledConcurrently(values: List<Int>): List<Int> = coroutineScope {
    values.map { value -> async { value * 2 } }.awaitAll()
}
