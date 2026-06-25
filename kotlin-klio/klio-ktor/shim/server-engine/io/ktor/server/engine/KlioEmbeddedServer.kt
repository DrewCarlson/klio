// klio's `Klio`-engine `embeddedServer` overloads. The klio server transport
// (`__kktor_serve`) is single-threaded: it owns the accept loop and runs each
// request's pipeline on the serving thread. The application's own coroutines
// (the `launch { … }` ktor's `EmbeddedServer.start` fires to log "Responding
// at", any plugin background work) must therefore stay on that one thread too,
// or they run on a `Dispatchers.Default` worker concurrently with the serving
// thread and race on the shared interpreter state.
//
// These overloads — more specific than the upstream generic ones, so they win
// resolution for `embeddedServer(Klio, …)` — parent the application to a
// confined cooperative dispatcher (`Dispatchers.Unconfined`, klio's same-thread
// pump). A coroutine launched from a context that already carries a
// `ContinuationInterceptor` keeps it (see `newCoroutineContext`), so the
// application's launches run cooperatively instead of escaping to the worker
// pool. GlobalScope still parents the application `Job` (so the run boundary
// abandons the daemon serve loop cleanly), only the dispatcher is pinned.

package io.ktor.server.engine

import io.ktor.server.application.Application
import io.ktor.server.application.serverConfig
import io.ktor.server.engine.klio.Klio
import io.ktor.server.engine.klio.KlioServerEngine
import io.ktor.util.logging.KtorSimpleLogger
import kotlinx.coroutines.Dispatchers

public fun embeddedServer(
    factory: Klio,
    port: Int = 80,
    host: String = "0.0.0.0",
    watchPaths: List<String> = listOf(WORKING_DIRECTORY_PATH),
    module: Application.() -> Unit
): EmbeddedServer<KlioServerEngine, KlioServerEngine.Configuration> {
    val connectors: Array<EngineConnectorConfig> = arrayOf(
        EngineConnectorBuilder().apply {
            this.port = port
            this.host = host
        }
    )
    val environment = applicationEnvironment {
        this.log = KtorSimpleLogger("io.ktor.server.Application")
    }
    val applicationProperties = serverConfig(environment) {
        this.parentCoroutineContext = Dispatchers.Unconfined
        this.watchPaths = watchPaths
        this.module(module)
    }
    val config: KlioServerEngine.Configuration.() -> Unit = {
        this.connectors.addAll(connectors)
    }
    return embeddedServer(factory, applicationProperties, config)
}
