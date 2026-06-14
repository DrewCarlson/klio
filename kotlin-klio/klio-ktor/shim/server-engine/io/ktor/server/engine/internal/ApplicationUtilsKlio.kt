// klio `actual`s for the engine's platform bridges (the cinterop `*Nix`
// versions use kotlinx.cinterop / platform.posix, which klio does not run).

package io.ktor.server.engine.internal

import io.ktor.server.config.ApplicationConfig
import io.ktor.server.engine.EnginePipeline
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

internal actual fun availableProcessorsBridge(): Int = 4

internal actual val Dispatchers.IOBridge: CoroutineDispatcher
    get() = Dispatchers.IO

internal actual fun printError(message: Any?) {
    println(message?.toString() ?: "null")
}

internal actual fun configureShutdownUrl(config: ApplicationConfig, pipeline: EnginePipeline) {}
