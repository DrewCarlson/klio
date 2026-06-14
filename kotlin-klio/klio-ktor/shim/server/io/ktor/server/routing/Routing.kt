// Klio shim for ktor server routing.
//
// `routing { route("/api") { get("/users/{id}") { … } } }` collects
// method+path+handler entries on the Application. `route(prefix) { … }`
// nests: the prefix is prepended to every route registered in its block
// (and to further nested `route`s). A handler is a `RoutingContext.() ->
// Unit` exposing `call`; the engine runs the first entry whose method
// matches and whose pattern matches the request path.
//
// Path patterns support three segment kinds beyond literals:
//   - `{name}`     captures one segment into `call.parameters["name"]`
//   - `{name...}`  a tailcard: captures the rest of the path (slash-joined)
//   - `*`          matches any one segment without capturing

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
    private var prefix: String = ""

    // Join the current `route { }` prefix with a handler/sub-route path.
    private fun full(path: String): String {
        val head = prefix.trimEnd('/')
        val tail = if (path.startsWith("/")) path else "/$path"
        return head + tail
    }

    fun get(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("GET", full(path), handler))
    }

    fun post(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("POST", full(path), handler))
    }

    fun put(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("PUT", full(path), handler))
    }

    fun delete(path: String, handler: RoutingContext.() -> Unit) {
        routes.add(RouteEntry("DELETE", full(path), handler))
    }

    // Nest a group of routes under a shared path prefix.
    fun route(path: String, block: Routing.() -> Unit) {
        val saved = prefix
        prefix = full(path)
        this.block()
        prefix = saved
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
// `{name}` / `{name...}` parameters, or null when the pattern does not
// match. Segments are compared after dropping empty (leading/trailing/`/`)
// segments, so `/` matches the empty path and trailing slashes are ignored.
fun matchPath(pattern: String, path: String): Map<String, String>? {
    val pSegs = pattern.split('/').filter { it.isNotEmpty() }
    val aSegs = path.split('/').filter { it.isNotEmpty() }
    val params = HashMap<String, String>()
    var i = 0
    while (i < pSegs.size) {
        val ps = pSegs[i]
        // Tailcard `{name...}` captures every remaining segment.
        if (ps.length >= 5 && ps.startsWith("{") && ps.endsWith("...}")) {
            val name = ps.substring(1, ps.length - 4)
            params[name] = if (i < aSegs.size) aSegs.subList(i, aSegs.size).joinToString("/") else ""
            return params
        }
        if (i >= aSegs.size) return null
        val seg = aSegs[i]
        when {
            ps.length >= 2 && ps[0] == '{' && ps[ps.length - 1] == '}' ->
                params[ps.substring(1, ps.length - 1)] = seg
            ps == "*" -> {} // any single segment, not captured
            ps != seg -> return null
        }
        i += 1
    }
    // Every pattern segment consumed; the path must be too.
    if (i != aSegs.size) return null
    return params
}

fun Application.routing(config: Routing.() -> Unit) {
    val r = this.routing ?: Routing()
    r.config()
    this.routing = r
}
