// Klio shim for ktor server routing.
//
// `routing { get("/users/{id}") { … } }` collects method+path+handler
// entries on the Application. Each handler is a `RoutingContext.() -> Unit`
// exposing `call`, matching ktor's `get("/x") { call.respond(…) }` shape.
// A path segment of the form `{name}` captures into `call.parameters`. The
// engine looks up the first entry whose method matches and whose pattern
// matches the request path, and runs it.

package io.ktor.server.routing

import io.ktor.server.application.Application

class RoutingContext(val call: io.ktor.server.application.ApplicationCall)

class RouteEntry(
    val method: String,
    val path: String,
    val handler: RoutingContext.() -> Unit,
)

// A matched route plus the path parameters captured from it.
class RouteMatch(
    val route: RouteEntry,
    val parameters: Map<String, String>,
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

    // First route whose method and pattern match `path` (already stripped
    // of any query string), with its captured path parameters.
    fun match(method: String, path: String): RouteMatch? {
        for (r in routes) {
            if (r.method != method) continue
            val params = matchPath(r.path, path) ?: continue
            return RouteMatch(r, params)
        }
        return null
    }
}

// Match a route pattern against a concrete path. Returns the captured
// `{name}` parameters, or null when the pattern does not match. Segments
// are compared after dropping empty (leading/trailing/`/`) segments, so
// `/` matches the empty path and trailing slashes are ignored.
fun matchPath(pattern: String, path: String): Map<String, String>? {
    val pSegs = pattern.split('/').filter { it.isNotEmpty() }
    val aSegs = path.split('/').filter { it.isNotEmpty() }
    if (pSegs.size != aSegs.size) return null
    val params = HashMap<String, String>()
    for (i in pSegs.indices) {
        val ps = pSegs[i]
        val seg = aSegs[i]
        if (ps.length >= 2 && ps[0] == '{' && ps[ps.length - 1] == '}') {
            params[ps.substring(1, ps.length - 1)] = seg
        } else if (ps != seg) {
            return null
        }
    }
    return params
}

fun Application.routing(config: Routing.() -> Unit) {
    val r = this.routing ?: Routing()
    r.config()
    this.routing = r
}
