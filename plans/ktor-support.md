# Ktor support

The goal: the Ktor client and server cores fully working on klio, HTTPS/TLS
on both sides, the important plugins, and each module's upstream commonTest
suite passing. klio ships Ktor 3.5.2 as the `io.ktor` pack
(`kotlin-klio/klio-ktor`), one feature per upstream Gradle module.

## Approach

Upstream sources run verbatim wherever klio can run them. klio writes an
actual only where no non-JVM upstream actual works, which in practice means
where upstream reaches the platform through cinterop.

- **Sockets.** ktor-network's common and nonJvm sets run verbatim, and so do
  its posix files that are plain Kotlin (the selector manager, event records,
  socket base). The cinterop-bound posix/nix files have klio copies under
  `klioMain/io/ktor/network` that keep upstream's structure and call host
  natives (`src/ktor_client/net.zig`, `__kknet_*`). The selector is
  upstream's nix design (a selection coroutine on `Dispatchers.IO`, a wakeup
  pipe, MPSC interest and close queues) over `poll` instead of `pselect`.
- **Engines.** ktor-client-cio and ktor-server-cio run verbatim over the
  sockets. `HttpClient()` defaults to CIO. The `Klio` server engine and the
  `KlioClient` client engine stay as names; the server one is the CIO
  backend plus HTTPS connectors, which upstream CIO refuses.
- **TLS.** A sans-IO TLS 1.3 engine in Zig (`src/ktor_tls`), memory to
  memory like the JVM's SSLEngine, over std.crypto primitives only. The
  Kotlin side pumps records between the socket channels and the engine, the
  architecture of upstream's JVM TLS session.
- **Plugins.** Every server and client plugin module whose sources klio can
  run is a feature over its upstream source sets; klio supplies only what
  Gradle generates (default-headers' `KTOR_VERSION`) or cinterop provides
  (the sessions deferral switch, read from the environment).
- **Tests.** Upstream commonTest suites registered in
  `src/itests/commontest_support.zig`, one census suite per area; itests with
  in-process loopback servers; examples with deterministic output.

## Status

| Area | Feature | State |
| --- | --- | --- |
| ktor-io, ktor-utils, ktor-http, ktor-http-cio | `io`, `utils`, `http`, `http-cio` | whole modules; census `ktor` 496/496 |
| ktor-network | `network` | TCP/UDP/Unix over host natives; census `ktor_network` 24/25 |
| ktor-network-tls | `network-tls` | TLS 1.3 sessions over `src/ktor_tls`, client and server |
| ktor-client-core + mock | `client-core`, `client-mock` | whole module; census `ktor_client_core` 93/93 |
| ktor-server-core + test host/base | `server-core`, `server-test-host`, `server-test-base` | whole module, multipart receive; census `ktor_server_core` 147/147 |
| ktor-server-tests | (the plugins it covers) | census `ktor_server_tests` 444 passed, 11 failing, with the JVM compression tests ported |
| ktor-client-cio | `client-cio` | verbatim; default `HttpClient()` engine, `KlioClient`; HTTPS |
| ktor-server-cio | `server-cio` | verbatim; census `ktor_server_cio` 4 (the engine suite waits on the pool timer fix) |
| server HTTPS | `server-cio` | `Klio` = the CIO engine plus `sslConnector(chainPem, keyPem)`; calls report `https`; `wss` |
| server plugins | `server-*` | 26 modules verbatim; census `ktor_server_plugins` 274 passed, 23 failing |
| compression | `utils`, `server-compression`, `client-encoding` | gzip and deflate over `src/ktor_client/zlib.zig`; example `ktor_compression` |
| call logging | `server-call-logging` | klio port on `LogLevel` and `klio.logging.MDC`; upstream's JVM CallLoggingTest ported, 20/20 in `ktor_server_plugins` |
| client plugins | `client-*` | 7 modules verbatim; census `ktor_client_plugins` 122/122 |
| kotlinx JSON converter | `serialization-kotlinx-json` | census `ktor_serialization` 13 passed, 1 failing |
| shared modules | `call-id`, `resources`, `websockets`, `test-base` | census `ktor_shared` 50/50 |

Open failures, each with its owner:
- `ktor_network`: `TCPSocketTest.testAwaitClosedDoesNotDeadLock`. `withTimeout`
  under `limitedParallelism(1)` never resumes its body (coroutine runtime).
- `ktor_server_cio`: CIOEngineTest.kt does not finish. A cancelled `delay` or
  disposed `withTimeout` gate keeps its pool worker pumping until the timer
  would have fired, so after a few tests the IO pool is out of workers and
  each server stop waits about 10 s (coroutine runtime; repro
  `pooldelay.kt`, JVM prompt, klio 10 to 20 s).
- `ktor_server_plugins`, 19 cases: RateLimitTest x12 (the same pool timers:
  each request's cancelled refill `delay` holds a worker);
  ServerSentEventsTest heartbeat x3 (`client.sse` inside `withTimeout` never
  enters its block); AuthorizeHeaderParserTest x3 (sema: an `assertIs`
  contract's `T` is not substituted at the call, so the smart cast is
  `HttpAuthHeader & T`); OAuth2Test.testApplicationState x1 (the
  serialization pass names framework types by simple name, and the test
  file's `io.ktor.util.*` brings its own `Encoder`); DependencyInjectionTest
  x4 (sema: a constructor reference resolves to the `provide(KClass)`
  member x2, a reified `provideDelegate` is not inferred from the
  property's type, and the `assertIs` contract).
- `ktor_server_tests`, 11 cases: HSTSTest x8 (sema: a lambda typed from the
  other side of `?:` loses a nested `run` receiver, so HSTS's default
  filter has no body and every call hangs to runTest's timeout);
  SessionTest x3 (sema: a reified type argument inferred from a sibling
  argument is `Any`).
- `ktor_serialization`: `testRegisterCustomFlow`. The JSON extension that
  streams a `Flow` registers through an `@EagerInitialization` property,
  which klio does not run (reported; the runtime fix would also retire the
  engine-loader actual).

Not run from upstream: the suites that need ktor's JVM test server
(ktor-client-cio, ktor-client-bom-remover, ktor-client-tests); the ones
for kotlinx.html and the other formats (html-builder, htmx, cbor, protobuf,
xml), which the pack does not ship; and ktor-network's nix suites
(`SelectNixTest`, `TcpSocketTestNix`, `UdpSocketTestNix`), which test the
pselect selector and read descriptors through cinterop, neither of which
klio runs.

## Work list, in order

1. Done: ktor-network over host sockets; ktor-client-cio and ktor-server-cio
   verbatim; the test hosts; whole source sets for io, utils, http,
   client-core and server-core; regex `\p{...}` classes; the server and client
   plugin modules and their suites; TLS 1.3 on both sides with HTTPS on the
   `Klio` engine; gzip and deflate over `std.compress.flate` with the
   server Compression module and the client's ContentEncoding; CallLogging;
   WebSockets over ws and wss (example `ktor_websockets`), with HTTPS calls
   reporting the `https` scheme.
2. ktor-server-tests' commonTest (405), and klio ports of its JVM
   CompressionTest and CompressionAcceptEncodingTest.
3. When the coroutine runtime fixes land: raise `ktor_network` to 25/0, set
   the `ktor_server_cio` ratchet from CIOEngineTest.kt, and recount the
   RateLimit and SSE cases.
4. Static content (`staticFiles`, `staticResources`, pre-compressed files)
   over kotlinx-io files instead of java.io.File.

## Decisions

- Compression: ktor-utils' posix `GZipEncoder`/`DeflateEncoder` are
  `Identity`. klio's actuals (`klioMain/io/ktor/util/ContentEncodersKlio.kt`)
  port the JVM's EncodersJvm.kt and Deflater.kt: the gzip container and its
  checks stay in Kotlin with the JVM's messages, and raw DEFLATE (level 6,
  the JVM default) and CRC-32 are natives over Zig `std.compress.flate`
  (`__kkz_*`). std's decompressor pulls its input from a reader, so each
  inflater runs it on a thread of its own over a reader that waits for the
  next input; an input call returns once everything given was used, with the
  output of every completed symbol, so decoding streams like the JVM's. Zig tests cover round trips, a stream from `gzip -n`, and
  truncated and corrupt input; Python's zlib reads klio's output. The server
  Compression module is jvm-only upstream but imports nothing from java.*,
  so it is consumed verbatim. ktor-client-encoding's `shouldDecode` comes
  from its nonDarwinPosix set: klio's engines pass bodies through as sent.
- CallLogging is jvm-only upstream and built on org.slf4j. klio ports
  CallLogging.kt, CallLoggingConfig.kt and MDCEntryUtils.kt under klioMain
  with the same DSL and messages; the hooks and the MDC provider run
  verbatim. The level is `LogLevel`, the MDC is `klio.logging.MDC` (per
  thread, keyed by the thread's name) and `klio.logging.MDCContext` is the
  ThreadContextElement from kotlinx-coroutines-slf4j. The default colors are
  written as the escape sequences jansi produces. Upstream's JVM
  CallLoggingTest runs as a klio port under `klioTest` (the platform types
  swapped; the context switches go to `Dispatchers.Default` and `.IO`
  because klio's kotlinx.coroutines has no `newSingleThreadContext`).
  `server-call-id` requires `server-call-logging`, mirroring the JVM
  module's dependency for `callIdMdc`.
- `@EagerInitialization` is not supported, so the posix engine loader hook
  (`engines.append(CIO)`) never runs; the default engine is a klio actual.
- `Dispatchers.IO` is a member of klio's `Dispatchers` (as on the JVM), so
  upstream's `import kotlinx.coroutines.IO` in ktor-io's posix
  `IODispatcher.posix.kt` does not resolve; klio's actual returns
  `Dispatchers.IO` directly.

## TLS design and limits

The engine (`src/ktor_tls`) is sans-IO: a session takes the peer's bytes,
queues its own and returns decrypted application data. Natives in
`src/ktor_client/tls.zig` hand Kotlin a session handle (`__kktls_*`); the
klio actuals in `klioMain/io/ktor/network/tls` pump records between a
socket's channels and the session and wrap the socket (`openTLSSession` for
the client, `Socket.tlsServer` for the server). The `Klio` server engine is
upstream's CIOApplicationEngine with an HTTPS accept loop that runs each
connection's handshake before its request pipeline.

Approved conditions, and how each is met:
- No new cryptographic primitives: AEADs, SHA-2, HMAC, HKDF (with std's
  `hkdfExpandLabel`), X25519, P-256/P-384 ECDH, ECDSA, Ed25519 and RSA
  verification are std.crypto's; Finished values compare in constant time.
- Byte-for-byte RFC 8448 traces for both handshakes: section 3 and section 5
  (HelloRetryRequest), client and server, every record equal to the trace.
  Hooks pin what the trace chose and this engine would choose itself: the
  randoms, the ephemeral keys, the ClientHello and EncryptedExtensions
  extension blocks, the HelloRetryRequest cookie, and the server's RSA-PSS
  signature (this engine does not sign with RSA).
- In-process interop with std.crypto.tls.Client: a unit test over loopback
  TCP (the std client verifies the chain and host name), and the
  `ktor_https` itest (std client against the `Klio` engine in a child klio,
  requiring the server's close_notify). std's client refuses Ed25519 servers
  (its CertificateVerify check maps no key type to ed25519), so those runs
  use the P-256 identity.
- Strict parsing: every length and field is checked; a malformed input is an
  alert, never a crash. std's certificate parser trusts the lengths it reads,
  so certificates pass a checked walk of the same elements first. One test
  per reachable alert path (scripted peers derive the keys and send
  encrypted messages); the unreachable guards are an exhausted sequence
  number (tested by setting it), a failed signature and a clamped X25519 key.
  Seeded fuzzing feeds random records, single corrupted deliveries (flip,
  truncate, insert, drop, duplicate, split) of a real handshake, and
  corrupted certificates and keys; 20,000 iterations each run clean.
- Verification on by default: chain to the system roots or configured PEM
  anchors, validity, host name (DNS and IP address entries).
  `insecureAcceptAnyCertificate` is the explicit opt-in.

Manual interop, 2026-09-26, macOS:
- curl 8.7.1 (LibreSSL 3.3.6) against `Klio` HTTPS with `--cacert`: P-256
  works. Its Ed25519 connector refuses LibreSSL 3.3.6, which offers no
  ed25519 signature scheme (handshake_failure, as intended).
- OpenSSL 3.6.3 `s_client`: both connectors (P-256 and Ed25519 signatures),
  all three suites, X25519/P-256/P-384 key exchange, verification OK; a
  TLS 1.2-only client gets protocol_version.
- JDK 21.0.11 HttpClient (TLSv1.3, trust store with the test CA) against both
  connectors: GET and a 200 KB POST.
- klio's CIO client against JDK 21 HttpsServer: an RSA-2048 chain (RSA
  certificate signatures, RSA-PSS CertificateVerify) and the P-256 identity,
  with TLS_AES_256_GCM_SHA384 as the JDK chose, GET and a 100 KB POST.
- klio's client with the operating system roots (157 on macOS) refuses the
  test CA's server with unknown_ca.

First-cut limits: TLS 1.3 only on both sides; ECDSA-P256 and Ed25519 server
keys; no client certificates; no 0-RTT or session tickets.

Follow-ups: a TLS 1.2 client; RSA-PSS server keys (RSA signing over
std.crypto.ff); the Kotlin side could drop its handle table for a NativeBox
on the socket wrapper.

## Out of scope for now

- ktor-client-tests (395) needs ktor's JVM test server.
