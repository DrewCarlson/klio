# io.ktor

The `io.ktor` pack ships Ktor 3.5.2: the common modules (`io.ktor.utils.io`,
`io.ktor.util`, `io.ktor.http`, `io.ktor.events`), sockets and TLS
(`io.ktor.network`, `io.ktor.network.tls`), the HTTP **client** and **server**
cores, the CIO engines for both with HTTPS, the server and client plugins, and
the test hosts. It is built from the real upstream Ktor sources plus
klio-authored platform actuals, and it is **opt-in**: installing the pack
registers it, but nothing loads until a program enables a feature.

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
- **TLS.** Upstream has no TLS session on non-JVM targets. klio's
  ktor-network-tls actuals run TLS 1.3 in klio's own engine
  (`src/ktor_tls`, over Zig's std.crypto) and pump its records between the
  socket's channels, the design of upstream's JVM TLS session.
- **Compression.** Upstream's posix `GZipEncoder` and `DeflateEncoder` are
  the identity encoder. klio's actuals follow the JVM's: the gzip header,
  checksum and trailer are written and checked in Kotlin, and raw DEFLATE and
  CRC-32 are host natives over Zig's `std.compress.flate`
  (`src/ktor_client/zlib.zig`). The output is standard gzip and deflate that
  any decoder reads.
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
| `network-tls`                 | `network.tls.*`: TLS 1.3 sessions over a socket          | `network`                                  |                                 |
| `client-core`                 | `client.*`: `HttpClient`, requests, the core plugins    | `http`, `http-cio`, `events`, `sse`, `websocket-serialization` |             |
| `client-cio`                  | `client.engine.cio.*`: the CIO engine, `KlioClient`     | `client-core`, `network-tls`               |                                 |
| `client-mock`                 | `client.engine.mock.*`: `MockEngine`                    | `client-core`                              |                                 |
| `client-content-negotiation`  | `client.plugins.contentnegotiation.*`                   | `client-core`, `serialization`             |                                 |
| `server-core`                 | `server.*`: applications, routing, the pipelines        | `http`, `events`, `serialization`, `websockets` |                            |
| `server-cio`                  | `server.cio.*`: the CIO engine; `Klio` with HTTPS       | `server-core`, `network-tls`, `http-cio`   |                                 |
| `server-content-negotiation`  | `server.plugins.contentnegotiation.*`                   | `server-core`                              |                                 |
| `server-test-host`            | `server.testing.*`: `testApplication`                   | `client-cio`, `server-core`, `test-dispatcher` |                             |
| `server-test-base`            | `server.test.base.*`: the engine test base              | `server-test-host`, `test-base`            |                                 |
| `test-dispatcher`             | `test.dispatcher.*`: `testSuspend` runners              | `utils`                                    | `kotlinx.coroutines/test`       |
| `test-base`                   | `test.*`: `runTest`, `runTestWithData`                  | `test-dispatcher`                          |                                 |
| `server-test-suites`          | `server.testing.suites.*`: the shared engine suites     | `server-test-base` and the plugins they use |                                |
| `client-test-base`            | `client.test.base.*`: the client test helpers           | `client-core`, `test-base`                 |                                 |

The plugin modules are features too, each requiring the core it plugs into:

- Server: `server-auth`, `server-auth-api-key`, `server-auto-head-response`,
  `server-body-limit`, `server-caching-headers`, `server-call-id`,
  `server-call-logging`, `server-compression`, `server-conditional-headers`,
  `server-cors`, `server-csrf`,
  `server-data-conversion`, `server-default-headers`, `server-di`,
  `server-double-receive`,
  `server-forwarded-header`, `server-hsts`, `server-http-redirect`,
  `server-method-override`, `server-partial-content`, `server-rate-limit`,
  `server-request-validation`, `server-resources`, `server-sessions`,
  `server-sse`, `server-status-pages`, `server-websockets`.
- Client: `client-auth`, `client-bom-remover`, `client-call-id`,
  `client-encoding`, `client-logging`,
  `client-resources`, `client-websockets`. HttpTimeout, HttpRequestRetry,
  DefaultRequest, HttpCookies, HttpRedirect, HttpCache, UserAgent and SSE come
  with `client-core`.
- Shared: `call-id`, `resources`.

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
`stop(gracePeriod, timeout)`. `receiveMultipart()` parses multipart bodies
as the JVM does; upstream's native build refuses them. Engine coroutines run on `Dispatchers.IO`, so a
program can start a server and exit: the run boundary abandons its daemon
tasks.

## HTTPS

The `Klio` server engine serves HTTPS connectors, and the CIO client speaks
HTTPS to any TLS 1.3 server.

```kotlin
import io.ktor.server.engine.embeddedServer
import io.ktor.server.engine.klio.Klio
import io.ktor.server.engine.sslConnector
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.routing

fun main() {
    embeddedServer(Klio, configure = {
        sslConnector(certificateChainPem = CHAIN_PEM, privateKeyPem = KEY_PEM) { port = 8443 }
    }) {
        routing { get("/") { call.respondText("hello over TLS") } }
    }.start(wait = true)
}
```

`sslConnector(certificateChainPem, privateKeyPem)` takes the certificate chain
(the server's certificate first) and its private key as PEM text. It replaces
the JVM's `sslConnector(keyStore, keyAlias, ...)`, which is built on
`java.security.KeyStore`. The key is a P-256 ECDSA or Ed25519 key, unencrypted,
as PKCS#8 (`BEGIN PRIVATE KEY`) or, for P-256, SEC 1 (`BEGIN EC PRIVATE KEY`).
A chain whose key does not match, or a key in another form, fails the server's
start with a message that says which. Plain `connector { }` entries serve HTTP
beside the HTTPS ones. A call on an HTTPS connector reports the `https` scheme
in `request.local` and `request.origin` (so `HttpsRedirect` and URLs built
from the request see it), and WebSocket routes serve `wss://` there. The
`CIO` engine keeps upstream's behavior and refuses HTTPS connectors.

The client verifies the server's certificate chain, its validity and its host
name (DNS names, and IP address entries for an IP literal) against the
operating system's trusted roots. `https { }` in the CIO engine configuration
is ktor's `TLSConfigBuilder`, which klio's actual gives these settings:

| Setting | Meaning |
| --- | --- |
| `serverName` | the name sent as SNI and matched against the certificate (defaults to the request's host) |
| `trustedCertificates` / `addTrustedCertificates(pem)` | PEM certificates a server's chain may end in, besides the system roots |
| `useSystemTrustStore` | whether the operating system's roots are used (default `true`) |
| `insecureAcceptAnyCertificate` | accept any certificate; for tests against an untrusted server only |

```kotlin
val client = HttpClient(CIO) {
    engine { https { addTrustedCertificates(TEST_CA_PEM) } }
}
```

A refused certificate throws `TlsPeerUnverifiedException`; other TLS failures
throw `TlsException`. Both carry the reason and the alert sent or received.
`Socket.tls(context) { ... }` (client) and `Socket.tlsServer(identity, context)`
(server, with a `TlsServerIdentity` from PEM) give the same sessions to raw
ktor-network sockets.

The client speaks TLS 1.3 and, to a server that does not, TLS 1.2 with the
ECDHE suites (AES-GCM or ChaCha20-Poly1305, over X25519, P-256 or P-384),
using the extended master secret whenever the server offers it and refusing
renegotiation. The server speaks TLS 1.3.

Limits: server keys are P-256 ECDSA or Ed25519 (the client verifies RSA
servers too); no client certificates (a server's certificate request is
answered with none); no session resumption or 0-RTT; no TLS 1.2 CBC or RSA
key-transport suites.

## Compression

`server-compression` is upstream's Compression plugin (a JVM-only module
upstream, whose source uses no JVM API): it compresses responses with the
encodings a client accepts and decompresses request bodies. `client-encoding`
is the client's ContentEncoding plugin. Both use the gzip and deflate
encoders from `utils`, which also work directly on byte channels:

```kotlin
val gzipped = GZipEncoder.encode(ByteReadChannel(bytes)).toByteArray()
val plain = GZipEncoder.decode(ByteReadChannel(gzipped)).toByteArray()
```

Compression uses level 6, the JVM's default. Both directions stream: a
decoder writes what each piece of input decodes to as it arrives. A truncated
stream throws `EOFException("Compressed input is incomplete.")`, and a corrupt
one an `IOException` with zlib's message (`invalid block type`, ...), where
the JVM throws `DataFormatException` with the same message.

WebSockets can compress their frames with `WebSocketDeflateExtension`
(permessage-deflate, RFC 7692), installed in the `extensions { }` block of
either side's WebSockets plugin with upstream's options (context takeover,
`compressionLevel`, `compressIf`, `compressIfBiggerThan`,
`maxInflatedFrameSize`). Upstream ships it for the JVM only; klio's port
keeps its negotiation and framing. Each outgoing message is compressed on
its own, which the RFC allows whatever context takeover was negotiated, so
messages that repeat earlier ones compress a little less than on the JVM;
incoming messages are inflated with the peer's window either way.

## Call logging

`server-call-logging` is Ktor's CallLogging plugin with the same DSL
(`level`, `logger`, `filter`, `mdc`, `format`, `clock`,
`disableDefaultColors`, `disableForStaticContent`) and the same messages.
Upstream ships it for the JVM only, typed on slf4j; klio's port uses ktor's
own logging types instead:

| JVM | klio |
| --- | --- |
| `level = Level.INFO` (`org.slf4j.event.Level`) | `level = LogLevel.INFO` (`io.ktor.util.logging.LogLevel`) |
| `org.slf4j.MDC` | `klio.logging.MDC`, with `put`, `get`, `remove`, `clear`, `getCopyOfContextMap`, `setContextMap` |
| `kotlinx.coroutines.slf4j.MDCContext` | `klio.logging.MDCContext` |
| jansi console for the default colors | none needed: the colors are ANSI escape sequences in the message on both |

`logger` is an `io.ktor.util.logging.Logger`, which on the JVM is slf4j's
`Logger`. klio has no logging backend to print MDC entries, so a logger that
wants them reads `MDC.getCopyOfContextMap()`. The MDC entries follow the call
across dispatchers, as `MDCContext` makes them do on the JVM.
`callIdMdc(name)` (`server-call-id`) adds the call id to the MDC; as on the
JVM, `server-call-id` depends on `server-call-logging` for it.

## Testing

`testApplication { … }` (`server-test-host`) runs an application in process
with a client wired to it, and `MockEngine` (`client-mock`) answers client
requests from a handler, as upstream's own test suites use them.

klio runs upstream's commonTest suites for the pack's modules
(`klio-census ktor,ktor_network,ktor_client_core,ktor_server_core,ktor_server_tests,ktor_server_plugins,ktor_client_plugins,ktor_shared,ktor_serialization`),
plus klio ports of the JVM tests for the modules that are JVM-only upstream
(CallLogging, Compression). The plan (`plans/ktor-support.md`) lists the
cases that still fail and why.

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-ktor
./zig-out/bin/klio pack install target/packs/io.ktor.klio-pack
```

## Not included yet

- RSA server keys.
- Static file and resource routes (`staticFiles`, `staticResources`), which
  upstream builds on java.io.File and the class path.
- WebSockets inside `testApplication`: upstream's native test engine does not
  support them.
