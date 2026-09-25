# io.ktor

The `io.ktor` pack ships Ktor 3.5.2: the common modules (`io.ktor.utils.io`,
`io.ktor.util`, `io.ktor.http`, `io.ktor.events`), sockets
(`io.ktor.network`), the HTTP **client** and **server** cores, the CIO
engines for both, and the test hosts. It is built from the real upstream Ktor
sources plus klio-authored platform actuals, and it is **opt-in**: installing
the pack registers it, but nothing loads until a program enables a feature.

## How it is built

Upstream sources run verbatim wherever klio can run them. klio writes its own
actual only where upstream's non-JVM actual reaches the platform through
cinterop. In practice that means:

- **Sockets.** ktor-network's common code and its plain-Kotlin posix files
  (the selector manager, event records, socket base) are upstream's. The
  socket calls, `sockaddr` handling and the selector's wait go through host
  natives (`src/ktor_client/net.zig`). The selector keeps upstream's design: a
  selection coroutine on `Dispatchers.IO`, a wakeup pipe, and interest and
  close queues. It waits in `poll` rather than `pselect`, so there is no
  `FD_SETSIZE` limit.
- **Engines.** ktor-client-cio and ktor-server-cio run verbatim over those
  sockets: HTTP/1.1 with chunked and streamed bodies, keep-alive on the server
  and WebSocket upgrade.
- **Platform bridges.** `getenv` (the `KTOR_LOG_LEVEL` logger level and the
  server's `ktor.*` environment properties), message digests (`Digest(name)`
  covers every JVM `MessageDigest` algorithm), the clock, locks and
  `PosixException`'s errno table are host natives too.

## Features

Features mirror Ktor's Gradle modules one for one, named after the artifact
with `ktor-` stripped, all opt-in via `--feature io.ktor/<name>`. Nothing
loads by default. A feature's `requires` carries its module's upstream
dependencies inside Ktor, so enabling a module enables everything it is built
on.

| Feature                       | Surface (`io.ktor.…`)                                   | Requires                                   | Other packs                     |
|-------------------------------|---------------------------------------------------------|--------------------------------------------|---------------------------------|
| `io`                          | `utils.io.*`: byte channels, packets, pools, charsets   |                                            |                                 |
| `utils`                       | `util.*`: collections, pipeline, date, crypto, logging  | `io`                                       |                                 |
| `http`                        | `http.*`: URLs, headers, status, content, cookies       | `utils`                                    |                                 |
| `http-cio`                    | `http.cio.*`: the CIO message parser, multipart reader  | `http`                                     |                                 |
| `events`                      | `events.*`: the event bus                               | `utils`                                    |                                 |
| `sse`                         | `sse.*`: the `ServerSentEvent` model                    | `utils`                                    |                                 |
| `websockets`                  | `websocket.*`: frames, sessions, ping/pong, extensions  | `http`                                     |                                 |
| `serialization`               | `serialization.*`: the `ContentConverter` contract      | `websockets`                               |                                 |
| `websocket-serialization`     | `websocket.serialization.*`: typed frames               | `serialization`                            |                                 |
| `serialization-kotlinx`       | `serialization.kotlinx.*`: the kotlinx converter        | `serialization`                            | `kotlinx.serialization`         |
| `serialization-kotlinx-json`  | `serialization.kotlinx.json.*`: `json()`                | `serialization-kotlinx`                    | `kotlinx.serialization/json-io` |
| `network`                     | `network.*`: TCP, UDP and Unix sockets, the selector    | `utils`                                    |                                 |
| `network-tls`                 | `network.tls.*`: the TLS configuration model            | `network`                                  |                                 |
| `client-core`                 | `client.*`: `HttpClient`, requests, the core plugins    | `http`, `http-cio`, `events`, `sse`, `websocket-serialization` |             |
| `client-cio`                  | `client.engine.cio.*`: the CIO engine, `KlioClient`     | `client-core`, `network-tls`               |                                 |
| `client-mock`                 | `client.engine.mock.*`: `MockEngine`                    | `client-core`                              |                                 |
| `client-content-negotiation`  | `client.plugins.contentnegotiation.*`                   | `client-core`, `serialization`             |                                 |
| `server-core`                 | `server.*`: applications, routing, the pipelines        | `http`, `events`, `serialization`, `websockets` |                            |
| `server-cio`                  | `server.cio.*`: the CIO engine, `Klio`                  | `server-core`, `network`, `http-cio`       |                                 |
| `server-content-negotiation`  | `server.plugins.contentnegotiation.*`                   | `server-core`                              |                                 |
| `server-test-host`            | `server.testing.*`: `testApplication`                   | `client-cio`, `server-core`, `test-dispatcher` |                             |
| `server-test-base`            | `server.test.base.*`: the engine test base              | `server-test-host`, `test-base`            |                                 |
| `test-dispatcher`             | `test.dispatcher.*`: `testSuspend` runners              | `utils`                                    | `kotlinx.coroutines/test`       |
| `test-base`                   | `test.*`: `runTest`, `runTestWithData`                  | `test-dispatcher`                          |                                 |

A bare channel program enables `--feature io.ktor/io`. A client enables
`--feature io.ktor/client-cio`, and a server enables
`--feature io.ktor/server-cio`, exactly as a Gradle build adds the engine
artifact. Typed JSON pairs the content-negotiation plugin with the JSON
converter: `--feature io.ktor/client-cio,client-content-negotiation,serialization-kotlinx-json`.

## Client

```kotlin
import io.ktor.client.HttpClient
import io.ktor.client.request.get
import io.ktor.client.statement.bodyAsText

suspend fun main() {
    val client = HttpClient()
    val response = client.get("http://127.0.0.1:8080/hello")
    println("${response.status} ${response.bodyAsText()}")
    client.close()
}
```

Run it with `klio run --feature io.ktor/client-cio fetch.kt`.

`HttpClient()` uses the CIO engine, which is the default engine the
`client-cio` feature supplies. Upstream's posix build finds its default
engine through an `@EagerInitialization` hook in the engine module; klio
initializes top-level properties on first use, as the JVM does, so the engine
module supplies the `HttpClient()` actual instead. With only `client-core`
enabled, `HttpClient()` has no engine, just as an upstream build with no
engine dependency has none. `HttpClient(CIO)` and `HttpClient(KlioClient)`
name the same engine. `KlioClient` is the name klio's engine has always had,
and it configures a `CIOEngineConfig`.

Like upstream CIO on every non-JVM platform, the client gives each request
its own connection (request pipelining is JVM-only).

## Server

```kotlin
import io.ktor.server.cio.CIO
import io.ktor.server.engine.embeddedServer
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing

fun main() {
    embeddedServer(CIO, port = 8080) {
        routing {
            get("/hello/{name}") { call.respondText("Hello, ${call.parameters["name"]}!") }
        }
    }.start(wait = true)
}
```

Run it with `klio run --feature io.ktor/server-cio server.kt`
(`--feature io.ktor/server-cio,server-content-negotiation,serialization-kotlinx-json`
for typed JSON). `embeddedServer(Klio, …)` names the same engine; `Klio` is
the name klio's server engine has always had.

The whole server core is upstream's: routing (path, wildcard, tailcard,
optional and regex segments, method, header, host and port selectors),
application and route-scoped plugins, hooks, the receive and send pipelines,
status pages for unhandled errors, config, and `start(wait = false)` with
`stop(gracePeriod, timeout)`. Engine coroutines run on `Dispatchers.IO`, so a
program can start a server and exit: the run boundary abandons its daemon
tasks.

## Testing

`testApplication { … }` (`server-test-host`) runs an application in process
with a client wired to it, and `MockEngine` (`client-mock`) answers client
requests from a handler, as upstream's own test suites use them.

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-ktor
./zig-out/bin/klio pack install target/packs/io.ktor.klio-pack
```

## Not included yet

- HTTPS and TLS on either side (in progress: a TLS 1.3 engine over Zig's
  std.crypto for the client and the `Klio` server engine).
- The plugin modules beyond content negotiation (WebSockets, Auth, Logging,
  StatusPages, CORS, Compression, CallLogging and the rest).
- WebSockets inside `testApplication`: upstream's native test engine does not
  support them.
