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
  natives (`src/ktor_client/net.zig`, over the platform layer described under
  Platforms). The selector keeps upstream's design: a selection coroutine on
  `Dispatchers.IO`, a wakeup pipe (a loopback socket pair on Windows), and
  interest and close queues. It waits in `poll` (`WSAPoll` on Windows) rather
  than `pselect`, so there is no `FD_SETSIZE` limit.
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
- **JVM-only modules.** A few upstream files exist only for the JVM because
  they reach `java.*`. klio carries them verbatim under `klioMain`, with a
  `klio.*` class in place of the JVM one: server digest authentication
  (`digest(…)` in `server-auth`, and ktor-http's `DigestAlgorithm.toDigester`)
  hashes through `klio.security.MessageDigest`, the JVM's `MessageDigest`
  surface over the same host digests.

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
| `test-server`                 | `testserver.runTestServer()`: ktor's own test server    | `server-cio` and the plugins it serves     |                                 |

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

`HttpClient()` uses the CIO engine, which the `client-cio` feature
registers. As in upstream's posix build, `HttpClient()` takes the first
engine in ktor's `engines` list, and ktor-client-cio's `@EagerInitialization`
hook adds CIO to it before `main` runs. With only `client-core` enabled,
`HttpClient()` fails with upstream's "Failed to find HTTP client engine
implementation", just as an upstream build with no engine dependency does.
`HttpClient(CIO)` and `HttpClient(KlioClient)`
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
`java.security.KeyStore`. The key is a P-256 ECDSA, Ed25519 or RSA key,
unencrypted, as PKCS#8 (`BEGIN PRIVATE KEY`), SEC 1 for P-256
(`BEGIN EC PRIVATE KEY`) or PKCS#1 for RSA (`BEGIN RSA PRIVATE KEY`). An RSA
key has a 2048- to 4096-bit modulus and an odd public exponent below 2^32,
and signs the handshake with RSA-PSS (SHA-256, or SHA-384 or SHA-512 when
the client takes only those). A chain whose key does not match, or a key in
another form, fails the server's start with a message that says which. Plain `connector { }` entries serve HTTP
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

Limits: server keys are P-256 ECDSA, Ed25519 or RSA, and an RSA key signs
only with RSA-PSS (TLS 1.3 allows nothing else); no client certificates (a server's certificate request is
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
(`klio-census ktor,ktor_network,ktor_client_core,ktor_server_core,ktor_server_cio,ktor_server_tests,ktor_server_plugins,ktor_client_plugins,ktor_client_tests,ktor_shared,ktor_serialization`),
plus klio ports of the JVM tests for the modules that are JVM-only upstream
(CallLogging, Compression). The plan (`plans/ktor-support.md`) lists the
cases that still fail and why.

The client suites call ktor's own test server (ktor-test-server) at
127.0.0.1:8080, which upstream's Gradle build starts before their runs.
The `test-server` feature carries it, and
`klio run --feature io.ktor/test-server tests/fixtures/ktor/test_server.kt`
starts it: the CIO application at 8080, the HTTP and SOCKS proxy test
servers at 8082 and 8083, and the TLS server at 8089, which runs on the
`Klio` engine with the klio test CA's localhost certificate
(`tests/fixtures/tls/server-p256.pem`) where upstream uses Jetty. Upstream's
Netty HTTP/2 server at 8084 is not started, since klio has no HTTP/2 engine.
The census runs the server as the client suites' service (see
`docs/development/testing.md`).

## Platforms

The pack runs on macOS, Linux and Windows from the same Kotlin sources. The
socket natives sit on a platform layer (`src/ktor_client/sock.zig`) that
gives every platform the POSIX meaning the actuals expect.

- **macOS and Linux**: BSD sockets and `poll`. Descriptors are closed on
  exec; SIGPIPE is suppressed per socket on macOS and per send on Linux.
- **Windows**: Winsock 2, started on first use. A descriptor is the socket's
  handle, not inherited by child processes. Failures are reported as the C
  runtime's errno values under their POSIX names (`EAGAIN`,
  `ECONNREFUSED`, ...; `src/ktor_client/winsock.zig` maps each Winsock
  error), so `PosixException` and its subclasses are the same as elsewhere,
  and a started non-blocking connect reads as EINPROGRESS. The selector
  waits in `WSAPoll` and is woken through a connected loopback socket pair.
  Where Windows means something else, the POSIX behavior is kept:
  - `reuseAddress` is accepted and not set. Rebinding a port whose old
    connections are still closing, which the option allows on POSIX, is
    already Windows' default, and Windows' own `SO_REUSEADDR` would let
    another socket take over a port in use.
  - `reusePort = true` fails with ENOPROTOOPT: Windows has nothing like it.
  - A datagram socket does not fail a receive with the ICMP unreachable an
    earlier send provoked, and a datagram longer than the buffer is cut to
    it, as on POSIX.
  - Unix domain sockets need Windows 10 1803 or later and are stream only;
    otherwise creating one fails with EAFNOSUPPORT.
- **Trusted roots** for HTTPS clients come from the system: the System and
  System Roots keychains on macOS, the distribution's CA bundle on Linux
  (`/etc/ssl/certs/ca-certificates.crt` and the other usual places), and
  the ROOT certificate store on Windows. A client that trusts only the
  system roots fails to start with a message when the system has none it
  can read (a container without `ca-certificates`, for example). macOS
  trust settings (certificates an administrator marked untrusted, roots
  added only to a login keychain) are not consulted. On Windows, a root the
  system has not downloaded yet is not in the store; pass it with
  `addTrustedCertificates`.

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-ktor
./zig-out/bin/klio pack install target/packs/io.ktor.klio-pack
```

## Not included yet

- Static file and resource routes (`staticFiles`, `staticResources`), which
  upstream builds on java.io.File and the class path.
- WebSockets inside `testApplication`: upstream's native test engine does not
  support them.
