# io.ktor

The `io.ktor` pack ships the ktor surface klio supports — the common
modules (`io.ktor.utils.io`, `io.ktor.util`, `io.ktor.http`,
`io.ktor.events`), the HTTP **client**, and an embedded **server** — built
from the real upstream ktor sources plus klio-authored platform actuals. It
is **opt-in**: installing the pack registers it, but nothing loads until a
program enables a feature, because not every program needs the network.

## Features

Features mirror ktor's Gradle module structure — one feature per module,
all opt-in via `--feature io.ktor/<name>`. Nothing loads by default; a
higher-level feature pulls the modules it needs through `requires`, so
enabling the client also enables everything under it.

| Feature                       | Surface (`io.ktor.…`)                         | Requires            |
|-------------------------------|-----------------------------------------------|---------------------|
| `io`                          | `utils.io.*` — `ByteChannel`, locks, charsets | —                   |
| `utils`                       | `util.*` — collections, pipeline, date, log   | `io`                |
| `http`                        | `http.*` — URLs, headers, status, content     | `utils`             |
| `events`                      | `events.*` — the event bus                    | `utils`             |
| `client`                      | `client.*` — `HttpClient` + plugins           | `http`, `events`    |
| `server`                      | `server.*` — `embeddedServer`, routing        | `http`, `events`    |
| `client-serialization`        | `ContentNegotiation { json() }` (client)      | `client`            |
| `server-serialization`        | typed `respond`/`receive` + `json()` (server) | `server`            |

So a bare channel program enables `--feature io.ktor/io`; a client program
enables `--feature io.ktor/client` (which transitively pulls `http`,
`utils`, `io`, and `events`). The `*-serialization` features additionally
pull the `kotlinx.serialization` pack's `json` feature.

## Client

```kotlin
import io.ktor.client.HttpClient
import io.ktor.http.HttpMethod
import kotlinx.coroutines.runBlocking

fun main() {
    val client = HttpClient()
    val resp = runBlocking {
        client.get("https://httpbin.org/get")
    }
    println("status=${resp.status}")
    println("body=${resp.bodyAsText()}")
    client.close()
}
```

Run it with `klio run --feature io.ktor/client program.kt`.

### Engine

The host binding (`src/ktor_client/ktor_client.zig`) wires the shim into a
small blocking HTTP/1.1 transport built on the platform sockets: blocking,
single-thread, modest dependency footprint. A request returns a flat
`Array<String>` shaped `[status, body, contentType, k1, v1, k2, v2, …]`
that the shim rebuilds into `HttpResponse`. Returning primitives from native
bindings avoids the cost (and bugs) of constructing Kotlin class instances
directly from Zig.

Any module that calls `HostBindings.register(
"io.ktor.client.engine.__kktor_request", myFn)` shadows the default engine.
To wire it in, add the module to the CLI's `mergedHostBindings()` *after*
`ktor_client.hostBindings()` — later registrations win (swap the transport,
route through an in-memory mock during tests, intercept for tracing). The
engine contract is the `StdlibFn` shape every host binding shares
(`*const fn (ctx: *CallCtx) Allocator.Error!EvalResult`); arguments are
`[method, url, body, headers]` and the return is the flat string array.

## Server

`embeddedServer(CIO, port) { … }` runs a blocking HTTP/1.1 server on a
single accept loop (the native `__kktor_serve` binding). The module lambda
installs plugins and a `routing { … }` table; each handler runs against an
`ApplicationCall` exposing the request and collecting the response.

```kotlin
import io.ktor.server.engine.embeddedServer
import io.ktor.server.cio.CIO
import io.ktor.server.routing.routing
import io.ktor.server.routing.route
import io.ktor.server.response.respondText
import io.ktor.server.response.respond
import io.ktor.server.request.receiveText
import io.ktor.server.request.receive
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.contentnegotiation.install
import io.ktor.serialization.kotlinx.json.json
import io.ktor.http.HttpStatusCode
import io.ktor.http.ContentType
import kotlinx.serialization.Serializable

@Serializable
data class User(val id: Int, val name: String)

fun main() {
    embeddedServer(CIO, port = 8080) {
        install(ContentNegotiation) { json() }
        routing {
            get("/users/{id}") {
                val id = call.parameters["id"]
                val q = call.request.queryParameters["q"]
                val tag = call.request.headers["X-Tag"]
                call.respondText("id=$id q=$q tag=$tag", status = HttpStatusCode.OK)
            }
            post("/items") {
                val body = call.receiveText()
                call.response.headers.append("X-Made", "yes")
                call.respondText("created:$body", contentType = ContentType.Text.Plain, status = HttpStatusCode.Created)
            }
            post("/users") {
                val u = call.receive<User>()                 // typed JSON in
                call.respond(HttpStatusCode.Created, User(u.id, u.name + "!"))  // typed JSON out
            }
            route("/api/v1") {                                // nested prefix
                get("/ping") { call.respondText("pong") }     // -> /api/v1/ping
            }
            get("/files/{path...}") {                         // tailcard
                call.respondText("file=${call.parameters["path"]}")
            }
        }
    }.start(wait = true)
}
```

Run it with `klio run --feature io.ktor/server-serialization server.kt`
(use `io.ktor/server` if you do not need typed JSON), then drive it:

```sh
curl -i 'http://127.0.0.1:8080/users/42?q=hi' -H 'X-Tag: abc'
curl -i -X POST --data 'widget' http://127.0.0.1:8080/items
curl -i -X POST --data '{"id":7,"name":"Ada"}' http://127.0.0.1:8080/users
```

The handler surface: `call.parameters` (path `{name}` captures),
`call.request.queryParameters`, `call.request.headers` (case-insensitive),
`call.receiveText()` / `call.receive<T>()`, `call.respondText(text,
contentType, status)`, `call.respond(status, value)` (typed JSON),
`call.response.headers.append(name, value)`, and `call.response.status(code)`.

Route patterns support `{name}` (one captured segment), `{name...}` (a
tailcard capturing the rest of the path), and `*` (any one segment, not
captured); `route(prefix) { … }` nests, prepending its prefix to the routes
inside it. The first registered route whose method and pattern match wins.

`start(wait = true)` blocks the calling thread; `start(wait = false)`
dispatches the accept loop onto the coroutine worker pool and returns, so a
program can start the server, do other work, and exit (the daemon serve loop
is abandoned cleanly at the run boundary).

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-ktor
./zig-out/bin/klio pack install target/packs/io.ktor.klio-pack
```

## What is not included

- Streaming / SSE bodies.
- WebSocket support.
- Regex route segments and per-route plugins / interceptors.
- Pluggable client engines beyond the built-in transport. The slot is there
  if you want to swap in another one — wire a new module into
  `mergedHostBindings()` and adjust the binding manifest.
