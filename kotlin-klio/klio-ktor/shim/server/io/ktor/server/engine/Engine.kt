// Klio shim for ktor server engine entry points.
//
// `embeddedServer(engine, port) { … }` runs the module lambda to collect
// routes, then `start(wait = true)` hands a per-request dispatch closure to
// the native `__kktor_serve` loop (src/ktor_client/ktor_client.zig).
//
// The native side passes the request as a flat string array
// `[method, path, body, hk1, hv1, …]` (the trailing pairs are request
// headers) and expects the response back as `[status, contentType, body,
// hk1, hv1, …]`. The closure splits the path/query, matches the route table
// (capturing `{name}` path parameters), runs the handler, and flattens the
// collected response.

package io.ktor.server.engine

import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.ApplicationRequest
import io.ktor.server.application.Headers
import io.ktor.server.routing.RoutingContext
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.Dispatchers

internal fun __kktor_serve(
    port: Int,
    dispatch: (Array<String>) -> Array<String>,
): Unit = error("intrinsic io.ktor.server.engine.__kktor_serve not installed")

// Decode one `application/x-www-form-urlencoded` token: `+` -> space and
// `%XX` -> byte. Unparseable escapes are left as-is.
private fun decodeFormComponent(s: String): String {
    if (s.indexOf('%') < 0 && s.indexOf('+') < 0) return s
    val out = StringBuilder(s.length)
    var i = 0
    while (i < s.length) {
        val ch = s[i]
        when {
            ch == '+' -> { out.append(' '); i += 1 }
            ch == '%' && i + 2 < s.length -> {
                val hi = hexDigit(s[i + 1])
                val lo = hexDigit(s[i + 2])
                if (hi >= 0 && lo >= 0) {
                    out.append(((hi shl 4) or lo).toChar()); i += 3
                } else { out.append(ch); i += 1 }
            }
            else -> { out.append(ch); i += 1 }
        }
    }
    return out.toString()
}

private fun hexDigit(c: Char): Int = when (c) {
    in '0'..'9' -> c - '0'
    in 'a'..'f' -> c - 'a' + 10
    in 'A'..'F' -> c - 'A' + 10
    else -> -1
}

private fun parseQuery(query: String): Map<String, String> {
    if (query.isEmpty()) return emptyMap()
    val out = HashMap<String, String>()
    for (pair in query.split('&')) {
        if (pair.isEmpty()) continue
        val eq = pair.indexOf('=')
        if (eq >= 0) {
            out[decodeFormComponent(pair.substring(0, eq))] = decodeFormComponent(pair.substring(eq + 1))
        } else {
            out[decodeFormComponent(pair)] = ""
        }
    }
    return out
}

class ApplicationEngine(val application: Application, val port: Int) {
    // `wait = true` blocks the calling thread in the accept loop; `wait =
    // false` dispatches the loop onto the coroutine worker pool (a daemon
    // that the run boundary abandons) and returns immediately, so the caller
    // can keep going and the process can exit cleanly.
    fun start(wait: Boolean): ApplicationEngine {
        val dispatch: (Array<String>) -> Array<String> = { req -> handle(req) }
        if (wait) {
            __kktor_serve(port, dispatch)
        } else {
            GlobalScope.launch(Dispatchers.IO) {
                __kktor_serve(port, dispatch)
            }
        }
        return this
    }

    private fun handle(req: Array<String>): Array<String> {
        val method = req[0]
        val rawTarget = req[1]
        val body = req[2]

        // Trailing pairs are request headers (keys lowercased for the
        // case-insensitive `Headers` lookup).
        val headerMap = HashMap<String, String>()
        var i = 3
        while (i + 1 < req.size) {
            headerMap[req[i].lowercase()] = req[i + 1]
            i += 2
        }

        val q = rawTarget.indexOf('?')
        val path = if (q >= 0) rawTarget.substring(0, q) else rawTarget
        val query = if (q >= 0) rawTarget.substring(q + 1) else ""

        val match = application.routing?.match(method, path)
            ?: return arrayOf("404", "text/plain", "Not Found")

        val request = ApplicationRequest(
            httpMethod = method,
            uri = rawTarget,
            headers = Headers(headerMap),
            queryParameters = parseQuery(query),
            bodyText = body,
        )
        val call = ApplicationCall(request, match.parameters)
        RoutingContext(call).run(match.route.handler)

        val out = ArrayList<String>()
        out.add(call.response.statusCode.toString())
        out.add(call.response.contentType)
        out.add(call.response.body)
        for (entry in call.response.headers.entries) {
            out.add(entry.first)
            out.add(entry.second)
        }
        return out.toTypedArray()
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
