// Klio shim for ktor server routing.
//
// `routing { get("/x") { … } }` collects method+path+handler entries on
// the Application. Each handler is a `RoutingContext.() -> Unit`; the
// context exposes `call`, matching ktor's `get("/x") { call.respond(…) }`
// shape. The engine looks up the entry by method+path and runs it.

package io.ktor.server.routing

import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall

class RoutingContext(val call: ApplicationCall)

class RouteEntry(
    val method: String,
    val path: String,
    val handler: RoutingContext.() -> Unit,
)

class Routing {
    val routes: ArrayList<RouteEntry> = ArrayList()

    fun get(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("GET", path, handler))
    }

    fun post(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("POST", path, handler))
    }

    fun put(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("PUT", path, handler))
    }

    fun delete(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("DELETE", path, handler))
    }
}

fun Application.routing(config: Routing.() -> Unit) {
    val r = this.routing ?: Routing()
    r.config()
    this.routing = r
}
