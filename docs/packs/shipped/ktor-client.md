# io.ktor.client

The `io.ktor.client` pack provides a blocking HTTP client. It is
**opt-in** — installing the pack registers the engine, but klio does
not ship the pack pre-cached because not every program needs the
network and TLS dependency tree.

## Surface

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

Available:

| Type / Method                                       | Notes                                                |
|------------------------------------------------------|------------------------------------------------------|
| `HttpClient()`                                       | Constructor; `close()` is a no-op.                   |
| `client.get(url)`                                    | Suspending; returns `HttpResponse`.                  |
| `client.post(url, body)`                             | Suspending; sends a text body.                       |
| `client.request(builder)`                            | Generic dispatcher around `HttpRequestBuilder`.      |
| `HttpRequestBuilder()`                               | `method`, `url`, `body`, `headers`, `header()`, `contentType()`, `accept()`. |
| `HttpMethod.Get()`, `Post()`, …                      | Factory form (eager-init companion val is avoided).  |
| `HttpResponse(status, bodyText, contentType, headers)`| `isSuccess()`, `bodyAsText()`.                       |

## Engine

The host binding (`src/ktor_client/ktor_client.zig`) wires the
shim into a small blocking HTTP/1.1 transport built on the platform
sockets: blocking, single-thread, modest dependency footprint. A
request returns a flat `Array<String>` shaped
`[status, body, contentType, k1, v1, k2, v2, …]` that the shim
rebuilds into `HttpResponse`. Returning primitives from native
bindings avoids the cost (and bugs) of constructing Kotlin class
instances directly from Zig.

### Replacing the engine

Any module that calls `HostBindings.register(
"io.ktor.client.engine.__kktor_request", myFn)` shadows the default
engine. To wire it in, add the module to the CLI's
`mergedHostBindings()` *after* `ktor_client.hostBindings()`
— later registrations win. Common motivations:

- Swapping to a different transport.
- Routing through an in-memory mock during tests.
- Intercepting for logging or distributed tracing.

The engine contract is the `StdlibFn` shape every host binding
shares (`*const fn (ctx: *CallCtx) Allocator.Error!EvalResult`);
arguments are `[method, url, body, headers]` and the return is the
flat string array described above.

## DSL form

`getWith` / `postWith` / `requestWith` accept a builder lambda:

```kotlin
val resp = runBlocking {
    client.getWith("https://httpbin.org/get") {
        accept("application/json")
        header("X-Source", "klio")
    }
}
```

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-ktor-client
./zig-out/bin/klio pack install target/packs/io.ktor.client.klio-pack
```

## What is not included

- Server-side ktor (engines, routing).
- Streaming / SSE bodies.
- WebSocket support.
- Pluggable engines beyond the built-in transport. The slot is there
  if you want to swap in another one — wire a new module into
  `mergedHostBindings()` and adjust the binding manifest.
