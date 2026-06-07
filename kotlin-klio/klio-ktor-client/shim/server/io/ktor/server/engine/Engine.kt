// Klio shim for ktor server engine entry points.
//
// `embeddedServer(engine, port) { … }` runs the module lambda to collect
// routes, then `start(wait = true)` hands a per-request dispatch closure
// to the native `__kktor_serve` loop (klio-ktor-client/src/lib.rs). The
// closure matches the request against the route table, runs the handler
// with a fresh `RoutingContext`, and returns the response triple.

package io.ktor.server.engine

import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.routing.RoutingContext

internal fun __kktor_serve(
    port: Int,
    dispatch: (Array<String>) -> Array<String>,
): Unit = error("intrinsic io.ktor.server.engine.__kktor_serve not installed")

class ApplicationEngine(val application: Application, val port: Int) {
    fun start(wait: Boolean): ApplicationEngine {
        __kktor_serve(port) { req ->
            val method = req[0]
            val path = req[1]
            val body = req[2]
            val call = ApplicationCall(method, path, body)
            val route = application.routing?.routes?.firstOrNull {
                it.method == method && it.path == path
            }
            if (route != null) {
                val ctx = RoutingContext(call)
                ctx.run(route.handler)
                arrayOf(call.responseStatus.toString(), call.responseContentType, call.responseBody)
            } else {
                arrayOf("404", "text/plain", "Not Found")
            }
        }
        return this
    }

    fun stop() {}
}

fun embeddedServer(
    factory: Any,
    port: Int,
    module: Application.() -> Unit,
): ApplicationEngine {
    val app = Application()
    app.module()
    return ApplicationEngine(app, port)
}
