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
- **Tests.** Upstream commonTest suites registered in
  `src/itests/commontest_support.zig`, one census suite per area; itests with
  in-process loopback servers; examples with deterministic output.

## Status

| Area | Feature | State |
| --- | --- | --- |
| ktor-io, ktor-utils, ktor-http | `io`, `utils`, `http` | whole modules; census `ktor` 464/464 |
| ktor-network | `network` | TCP/UDP/Unix over host natives; census `ktor_network` 24/25 |
| ktor-client-core + mock | `client-core`, `client-mock` | whole module; census `ktor_client_core` 93/93 |
| ktor-server-core + test host/base | `server-core`, `server-test-host`, `server-test-base` | whole module; census `ktor_server_core` 138/147 |
| ktor-client-cio | `client-cio` | verbatim; default `HttpClient()` engine, `KlioClient` |
| ktor-server-cio | `server-cio` | verbatim; `Klio` names it |
| ktor-network-tls | `network-tls` | upstream nonJvm model only (no TLS yet) |
| server TLS | `Klio` engine | not started |

Open failures:
- `ktor_network`: `TCPSocketTest.testAwaitClosedDoesNotDeadLock`. `withTimeout`
  under `limitedParallelism(1)` never resumes its body; the coroutine runtime
  owner has the repro (`wt_limited.kt`).
- `ktor_server_core`: `RegexRoutingTest` x9. The stdlib Regex has no
  `\p{...}` classes, which the regex route selector finds group names with.
  Being added to src/stdlib/implementations/regexp.zig.

Not run from upstream: ktor-network's nix suites (`SelectNixTest`,
`TcpSocketTestNix`, `UdpSocketTestNix`) test the pselect selector and read
descriptors through cinterop, and klio runs neither. The CIO engines'
commonTests need ktor-server-test-suites (server) and the JVM test server
(client); see the work list.

## Work list, in order

1. Done: ktor-network over host sockets; ktor-client-cio and ktor-server-cio
   verbatim; the string-array transports retired; the test hosts; whole
   source sets for io, utils, http, client-core and server-core.
2. Regex `\p{...}` classes in the stdlib engine (unblocks RegexRoutingTest).
3. The CIO engines' own commonTests: ktor-server-cio's needs
   ktor-server-test-suites; ktor-client-cio's needs ktor's test server, whose
   routes are ordinary Ktor server code that can run on klio's CIO server
   once the server plugins it installs are in.
4. ktor-server-tests' commonTest (405).
5. TLS: `src/ktor_tls` engine, client then server; `network-tls` feature;
   PEM `sslConnector(certificateChainPem, privateKeyPem)` on the `Klio`
   engine.
6. Plugins. Client: WebSockets, Auth, Logging, ContentEncoding, Resources,
   CallId (the core plugins HttpTimeout, HttpRequestRetry, DefaultRequest,
   HttpCookies, HttpRedirect, HttpCache, UserAgent, SSE come with
   client-core). Server: StatusPages, DefaultHeaders, CORS, Compression,
   CallLogging, RateLimit, Auth (+ api-key), Sessions, WebSockets, SSE,
   AutoHeadResponse, CachingHeaders, ConditionalHeaders, PartialContent,
   CallId, ForwardedHeader, HSTS, HttpRedirect, BodyLimit, DoubleReceive,
   RequestValidation, Resources, MethodOverride, DataConversion, CSRF.

## Decisions

- Compression: ktor-utils' posix `GZipEncoder`/`DeflateEncoder` are
  `Identity`. klio's actuals compress for real over Zig `std.compress.flate`,
  matching the JVM. The server Compression module is jvm-only upstream but
  imports nothing from java.*, so it is consumed verbatim.
- CallLogging is jvm-only upstream and built on org.slf4j. klio ports it
  under klioMain with the same DSL, typed on `io.ktor.util.logging`; the pack
  docs state the difference.
- `@EagerInitialization` is not supported, so the posix engine loader hook
  (`engines.append(CIO)`) never runs; the default engine is a klio actual.
- `Dispatchers.IO` is a member of klio's `Dispatchers` (as on the JVM), so
  upstream's `import kotlinx.coroutines.IO` in ktor-io's posix
  `IODispatcher.posix.kt` does not resolve; klio's actual returns
  `Dispatchers.IO` directly.

## TLS design and limits

Approved conditions: no new cryptographic primitives (all from std.crypto,
constant-time comparisons from std); byte-for-byte RFC 8448 traces for both
handshakes; in-process interop with std.crypto.tls.Client; manual interop
with the JDK and curl, recorded here; strict parsing where every malformed
input is an alert, with a unit test per alert path and a fuzz-style test of
random and truncated records; certificate verification (chain, hostname,
validity) on by default, with insecure trust only as an explicit, clearly
named opt-in.

First-cut limits: TLS 1.3 only on both sides; ECDSA-P256 and Ed25519 server
keys; no client certificates; no 0-RTT or session tickets.

Follow-ups: a TLS 1.2 client; RSA-PSS server keys (RSA signing over
std.crypto.ff).

## Out of scope for now

- ktor-client-tests (395) needs ktor's JVM test server.
