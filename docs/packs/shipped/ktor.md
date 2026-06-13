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
    println("success=${resp.isSuccess()}")
    println("ct=${resp.contentType}")
    println("body_starts=${resp.bodyText.substring(0, 32)}")
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

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-ktor
./zig-out/bin/klio pack install target/packs/io.ktor.klio-pack
```

## What is not included

- Streaming / SSE bodies.
- WebSocket support.
- Pluggable client engines beyond the built-in transport. The slot is there
  if you want to swap in another one — wire a new module into
  `mergedHostBindings()` and adjust the binding manifest.
