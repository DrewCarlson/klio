// klio `actual`s for ktor-server-core's platform bridges, upstream's posix
// `ApplicationUtilsNix.kt` with the processor count and the stderr write
// going through the host instead of cinterop.

package io.ktor.server.engine.internal

import io.ktor.server.config.ApplicationConfig
import io.ktor.server.engine.EnginePipeline
import io.ktor.util.__kktor_available_processors
import io.ktor.util.__kktor_print_error
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

internal actual fun availableProcessorsBridge(): Int = __kktor_available_processors()

internal actual val Dispatchers.IOBridge: CoroutineDispatcher
    get() = Dispatchers.IO

internal actual fun printError(message: Any?) {
    __kktor_print_error(message?.toString() ?: "null")
}

internal actual fun configureShutdownUrl(config: ApplicationConfig, pipeline: EnginePipeline) {
    config.propertyOrNull("ktor.deployment.shutdown.url")?.getString()?.let { _ ->
        error("Shutdown url is not supported on native")
    }
}
