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

The host binding (`crates/klio-ktor-client/src/lib.rs`) wires the
shim into [`ureq`](https://docs.rs/ureq): blocking, single-thread,
TLS via rustls. A request returns a flat
`Array<String>` shaped `[status, body, contentType, k1, v1, k2, v2, …]`
that the shim rebuilds into `HttpResponse`. Returning primitives
from native bindings avoids the cost (and bugs) of constructing
Kotlin class instances directly from Rust.

### Replacing the engine

Any crate that calls `HostBindings::register(
"io.ktor.client.engine.__kktor_request", my_fn,
)` shadows the default engine. To wire it in, add the crate to
`klio-cli`'s `merged_host_bindings()` *after* `klio_ktor_client::host_bindings()`
— later registrations win. Common motivations:

- Swapping to async via `reqwest` + a thread-pool runtime.
- Routing through an in-memory mock during tests.
- Intercepting for logging or distributed tracing.

The engine contract is the
`fn(&mut CallCtx) -> Result<Value, RuntimeError>` shape every
host binding shares; arguments are `[method, url, body, headers]`
and the return is the flat string array described above.

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
cargo run -q -p klio-cli -- pack build crates/klio-ktor-client
cargo run -q -p klio-cli -- pack install target/packs/io.ktor.client.klio-pack
```

## What is not included

- Server-side ktor (engines, routing).
- Streaming / SSE bodies.
- WebSocket support.
- Pluggable engines beyond `ureq`. The slot is there if you want to
  swap in `reqwest`/`hyper` — wire a new crate into
  `merged_host_bindings()` and adjust the binding manifest.
