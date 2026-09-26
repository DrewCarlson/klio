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
  pipe, MPSC interest and close queues) over `poll` instead of `pselect`;
  on Windows a loopback socket pair and `WSAPoll` (see Portability).
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
| ktor-network | `network` | TCP/UDP/Unix over host natives (BSD sockets or Winsock); census `ktor_network` 25/25 |
| ktor-network-tls | `network-tls` | TLS 1.3 sessions over `src/ktor_tls`, client and server |
| ktor-client-core + mock | `client-core`, `client-mock` | whole module; census `ktor_client_core` 93/93 |
| ktor-server-core + test host/base | `server-core`, `server-test-host`, `server-test-base` | whole module, multipart receive; census `ktor_server_core` 147/147 |
| ktor-server-tests | (the plugins it covers) | census `ktor_server_tests` 455/455, with the JVM compression tests ported |
| ktor-client-cio | `client-cio` | verbatim, with its posix loader registering the default `HttpClient()` engine; `KlioClient`; HTTPS; census `ktor_client_cio` 13/13 |
| ktor-server-cio | `server-cio` | verbatim; census `ktor_server_cio` 98/98 |
| server HTTPS | `server-cio` | `Klio` = the CIO engine plus `sslConnector(chainPem, keyPem)`; calls report `https`; `wss` |
| server plugins | `server-*` | 26 modules verbatim; census `ktor_server_plugins` 297/297 |
| compression | `utils`, `server-compression`, `client-encoding` | gzip and deflate over `src/ktor_client/zlib.zig`; example `ktor_compression` |
| WebSocket compression | `websockets` | klio port of the JVM permessage-deflate extension; example `ktor_websocket_deflate` |
| call logging | `server-call-logging` | klio port on `LogLevel` and `klio.logging.MDC`; upstream's JVM CallLoggingTest ported, 20/20 in `ktor_server_plugins` |
| client plugins | `client-*` | 8 modules verbatim; census `ktor_client_plugins` 123 passed, 2 failing, against ktor's test server |
| ktor-client-tests | (the client end to end) | census `ktor_client_tests` 380 passed, 8 failing, over CIO against ktor's test server |
| ktor-test-server | `test-server` | verbatim with klio copies of its JVM files; TLS on `Klio`; the census service for the client suites |
| digest authentication | `server-auth`, `http` | the JVM-only DigestAuth, DigestCredential and `toDigester` verbatim over `klio.security.MessageDigest`; example `ktor_digest_auth` (MD5, SHA-256, qop=auth with Authentication-Info) |
| kotlinx JSON converter | `serialization-kotlinx-json` | census `ktor_serialization` 14/14 |
| shared modules | `call-id`, `resources`, `websockets`, `test-base` | census `ktor_shared` 50/50 |

Open failures, each with its owner:
- `ktor_client_plugins`, 2 cases: ContentEncodingTest testGzipByteArray
  and testDisableDecompression. The test server's `/gzip-precompressed`
  declares the 294 bytes the JVM's zlib makes of its body, and klio's
  deflate (std.compress.flate, level 6) makes 293, so the server rightly
  fails the response. Needs a deflate that matches zlib's output byte for
  byte (ktor).
- `ktor_client_tests`, 8 cases: CacheLegacyStorageTest x7 (sema: the
  callable reference `plugin::findAndRefresh` in HttpCacheLegacy.kt binds
  HttpCache's private member, which is not visible there, instead of the
  file's private extension, so the legacy storage is never consulted);
  DispatcherTest x1 (coroutines: `Dispatchers.IO.toString()` is not
  "Dispatchers.IO", which upstream native's DefaultIoScheduler returns).
  On the Linux VM PluginsTest.testIgnoreBody fails too, and on macOS it
  passes with little to spare: the server's `"x".repeat(16 MiB)` takes
  11.4 s (`CharArray(n) { c }` at about 0.7 µs a char) and
  `encodeToByteArray` 1.27 s, against the engine's 15 s request timeout
  (interpreter speed, on its after-done list).

Not run from upstream: the suites
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
3. Done: ktor's test server under klio (`test-server`), run by the census
   as the client suites' service; the ktor-client-tests, ktor-client-cio
   and ktor-client-bom-remover suites; the
   `ktor_server_cio`, `ktor_server_tests` and `ktor_server_plugins`
   ratchets at zero failures once the sema fixes landed.
4. A zlib-exact deflate for the test server's precompressed gzip body.
5. Static content (`staticFiles`, `staticResources`, pre-compressed files)
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
- WebSocketDeflateExtension is jvm-only upstream (java.util.zip). klio's
  port keeps the negotiation and RFC 7692 framing and uses two stateless
  natives (`__kkz_deflate_message`, `__kkz_inflate_message`): an outgoing
  message is compressed by a fresh compressor, which the RFC allows whatever
  context takeover says, and an incoming one is inflated after the stream's
  last 32 KB of output, which the extension keeps unless the peer dropped
  its context. Nothing native outlives a call, because an extension has no
  close hook to free it. Zig tests decode RFC 7692's examples (including the
  shared-window "Hello"); manually, a Python client over raw sockets and
  zlib, keeping its compressor's context across messages, talked to the
  klio server in both directions (2026-09-26).
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
- `HttpClient()` is upstream's posix actual: ktor-client-cio's
  `Loader.posix.kt` adds CIO to the `engines` list through
  `@EagerInitialization`, which klio runs before `main`.
- `Dispatchers.IO` is a member of klio's `Dispatchers` (as on the JVM), so
  upstream's `import kotlinx.coroutines.IO` in ktor-io's posix
  `IODispatcher.posix.kt` does not resolve; klio's actual returns
  `Dispatchers.IO` directly.

- ktor's test server (ktor-test-server) is build infrastructure upstream:
  Gradle starts it before the client test runs. The `test-server` feature
  loads its sources verbatim; the eight files that reach the JVM have klio
  copies under klioMain/test/server with only those uses swapped
  (klio.security.MessageDigest, atomicfu, ktor's writer and charset API, the
  platform SelectorManager), and the TLS server at 8089 runs on the Klio
  engine with the klio test CA's certificate instead of Jetty with a
  generated keystore. `io.ktor.testserver.runTestServer()` is the entry
  point, under the pack's id prefix so a program can import it: a program
  selects packs by the prefix of its imports, and `--feature
  io.ktor/test-server` alone does not make a package outside `io.ktor`
  (here `test.server`) importable. That is the pack loader's design, not a
  ktor question, and is tracked outside this plan. The census
  runs `tests/fixtures/ktor/test_server.kt` as the client suites' service
  (commontest_support.zig): the tests name 127.0.0.1:8080, so the port is
  fixed and suites take turns on a lock file; every server binds with
  address reuse so the next suite can start it at once.

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

TLS 1.2 client (`tls12.zig`, the 1.2 states in `session.zig`): one
ClientHello offers 1.3 and 1.2 (supported_versions, the 1.2 ECDHE suites,
ec_point_formats, extended_master_secret, an empty renegotiation_info); a
ServerHello without supported_versions takes the 1.2 path, refusing RFC
8446's downgrade sentinels. Suites: ECDHE_{ECDSA,RSA} with AES-128/256-GCM
and ChaCha20-Poly1305; the PRF is std's P_hash (`hmacExpandLabel`); records
use RFC 5288's explicit GCM nonce (the sequence number) and RFC 7905's
ChaCha20 nonce. ServerKeyExchange signatures: ECDSA with SHA-256/384/512 on
P-256 or P-384 keys, Ed25519, RSA PKCS#1 v1.5 and PSS, all std.crypto. The
extended master secret is used when the server echoes it. A HelloRequest is
answered with a no_renegotiation warning; TLS 1.2 warnings other than
close_notify are ignored. Tests: the PRF against the published SHA-256 and
SHA-384 vectors; the master secret, extended master secret, key block and
Finished values against OpenSSL 3.6's TLS1-PRF KDF; record layout, nonce
and additional data against std's AEADs directly; a scripted TLS 1.2
server (tls12_test.zig) with full handshakes for all six suites, ECDSA,
Ed25519 and RSA keys (RSA signatures pinned from OpenSSL with
tls12-signatures.sh), with and without the extended master secret and with
a certificate request; one test per reachable 1.2 alert; seeded fuzzing of
single corrupted deliveries and random records in the 1.2 states.

TLS 1.2 manual interop, 2026-09-26, macOS: klio's CIO client against
OpenSSL 3.6.3 `s_server -tls1_2` for all six suites (P-256 and RSA-2048
certificates), X25519, P-256 and P-384 key exchange, RSA PKCS#1 and PSS
signatures, extended master secret off, and an Ed25519 certificate; and
against JDK 21.0.11 HttpsServer forced to TLSv1.2 with RSA-2048 and P-256
identities (TLS_ECDHE_{RSA,ECDSA}_WITH_AES_256_GCM_SHA384 as the JDK chose),
GET and a 100 KB POST.

RSA server keys (`rsa.zig`), as approved: PKCS#8 rsaEncryption or PKCS#1
keys, parsed as strict DER (minimal lengths and integers, version 0 only,
nothing trailing), with a 2048- to 4096-bit modulus, any odd e with
3 <= e < 2^32, and 0 < d < n. The TLS 1.3 server signs CertificateVerify
with rsa_pss_rsae_sha256, or _sha384 or _sha512 when the client takes only
those, and refuses a client that takes no RSA-PSS scheme with
handshake_failure. The private operation is `m^d mod n` with std.crypto.ff's
`powWithEncodedExponent` (constant time in d, which is padded to the modulus
length), without the CRT; EMSA-PSS-ENCODE (the one construction written
here) uses a salt of the hash's length from the session's generator; every
signature is checked with `s^e mod n` before it is sent, and an identity is
refused at load if its private exponent fails that check. The key is wiped
with the identity, and the loading copy on every path; PEM buffers are
cleared before they are freed. The client verifies RSA-PSS with `rsa.zig`'s
own EMSA-PSS-VERIFY, which takes every modulus length: std's verifier
asserts when the encoded message is a byte shorter than the modulus (a
3065- or 4089-bit key crashed the client). An adversarial review found
that, three untested constraints and the wiping gaps; all are fixed.
Tests: signatures by 2048-, 2049-, 2050-, 3072- and 4096-bit fixtures for
each hash, verified by this verifier and by std's where it applies; known
answers with a pinned salt computed by `rsa-pss-kat.py` with Python
integers and verified by OpenSSL 3.6, for 2048 bits, 2049 (the encoded
message a byte shorter) and 2050 (seven cleared bits); a flipped bit of d
caught before sending, and an identity with the wrong d refused; d's
padding; each refusal (sizes, exponents, d, multi-prime, non-minimal DER,
PKCS#8 parameters and trailing elements, encrypted traditional keys);
handshakes with each hash choice and the refusal; std.crypto.tls.Client
verifying an RSA server in process and in the `ktor_https` itest; RSA keys
in the PEM corruption fuzzing, whose surviving signatures must verify.

RSA manual interop, 2026-09-26, macOS, `Klio` with RSA-2048 (PKCS#8 and
PKCS#1 keys) and RSA-4096 connectors: OpenSSL 3.6.3 `s_client` verifies all
three with each of rsa_pss_rsae_sha256, _sha384 and _sha512 (peer signature
type rsa_pss_rsae_*) and gets handshake_failure offering only
rsa_pkcs1_sha256; curl 8.7.1 (SecureTransport) and JDK 21.0.11 HttpClient
(GET and a 200 KB POST) against the 2048- and 4096-bit connectors.

Limits: the server is TLS 1.3 only; ECDSA-P256, Ed25519 and RSA (PSS)
server keys; no client certificates; no 0-RTT, session tickets or
resumption; no TLS 1.2 renegotiation, CBC or RSA key-transport suites.

Follow-ups: the Kotlin side could drop its handle table for a NativeBox on
the socket wrapper.

## Portability

The pack must run on macOS, Linux and Windows. Its Kotlin is the same on
all three; the natives carry the differences:
- `src/ktor_client/sock.zig`: the socket layer under `net.zig`, BSD
  sockets and `poll` on POSIX systems and Winsock 2 on Windows, with POSIX
  meaning everywhere. Windows specifics: WSAStartup on first use; the
  descriptor is the SOCKET handle, made non-inheritable (handles fit in 32
  bits; one that did not would be refused, not truncated);
  `winsock.zig` maps each Winsock error to the C runtime's errno value
  under its POSIX name, so `PosixException` subtypes match, and keeps a
  code without a counterpart as itself (all of them are 10000 or more);
  a started non-blocking connect reads as EINPROGRESS; the selector waits
  in `WSAPoll` and wakes through a loopback socket pair whose accepted end
  is checked to be the one connected; a closed socket in a wait is reported
  on its own entry (NVAL), as `poll` does; datagram sockets turn off
  SIO_UDP_CONNRESET and a datagram longer than the buffer is cut to it;
  `reuseAddress` is not set (its POSIX meaning is Windows' default, and
  Windows' SO_REUSEADDR allows taking over a port in use); `reusePort`
  fails with ENOPROTOOPT; there is no SIGPIPE. AF_UNIX works where
  Windows has it (10 1803 and later, stream only) and otherwise fails with
  EAFNOSUPPORT.
- `sync.zig`: pthread mutexes and conditions, or SRW locks and condition
  variables. `env.zig`: the C environment, or the Win32 environment (per-drive
  `=C:` entries are left out of `environ`) and a direct stderr handle.
- Trusted roots: `Bundle.rescan` reads the System and System Roots
  keychains on macOS, the first CA bundle found on Linux
  (`/etc/ssl/certs/ca-certificates.crt`, the Fedora, OpenSUSE and Alpine
  paths, then the certificate directories), and the ROOT system store on
  Windows. A client trusting only the system roots is refused with a
  message when the store could not be read or is empty. Not covered: macOS
  trust settings (admin-distrusted roots, roots only in a login keychain)
  and Windows roots the system has not downloaded yet.
- A TLS session is refused if the system's secure random source fails,
  rather than seeded from a weaker one.

Verified, 2026-09-26:
- macOS (arm64): the unit tests of `ktor_client` (with the socket layer's
  own) and `ktor_tls`, every ktor census, the ktor itests and examples.
- Linux, aarch64 Ubuntu 24.04 in Docker with Zig 0.16.0: `zig build`, the
  harness, the same unit tests, the packs, every ktor census with the same
  counts as macOS (ktor 496, ktor_network 25, ktor_client_core 93,
  ktor_server_core 147, ktor_server_tests 444/11, ktor_server_plugins
  290/7, ktor_client_plugins 81/41, ktor_serialization 14, ktor_shared 50;
  ktor_server_cio hangs on both, as recorded above), the five ktor itests
  and the fourteen ktor examples (how, below).
- Windows: `zig build -Dtarget=x86_64-windows-gnu` reports no errors in the
  ktor files (the ones left are the runtime's and the cli's, owned
  elsewhere). The socket layer, locks, environment and Winsock mapping
  build and link for x86_64 and aarch64 Windows as standalone test
  binaries (with a stub for the runtime's collector hooks), and ktor_tls's
  tests do too. Under Wine 9 (x86_64 Ubuntu 24.04, emulated in Docker;
  wineboot does not finish under that emulation, so the prefix's system32
  is filled with Wine's builtin DLLs, and the test binaries are built
  without libc because the prefix lacks the UCRT API sets) the Winsock
  mapping tests, the environment test and all six socket-layer tests pass
  against Wine's Winsock: a loopback stream with EAGAIN, a refused
  non-blocking connect (EINPROGRESS, then ECONNREFUSED from SO_ERROR after
  WSAPoll), the wakeup pair with NVAL after close, a closed socket's error,
  name resolution and the refusals. Not verified on Windows: anything that
  starts a thread (Wine crashes creating one under that emulation), so the
  locks, the TLS tests and the system store; and klio itself, which does
  not build for Windows until the runtime does.

Linux, how: an image from

```
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils python3 rsync git
RUN curl -fsSL https://ziglang.org/download/0.16.0/zig-aarch64-linux-0.16.0.tar.xz -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1
ENV PATH=/opt/zig:$PATH
```

run with the checkout mounted read-only at its own path (so the source
checkouts' absolute symlinks resolve) and volumes for the work tree and
the Zig cache: `docker run --rm --platform linux/arm64 -v $REPO:$REPO:ro
-v klio-ktor-work:/work -v klio-ktor-zigcache:/root/.cache/zig IMAGE bash
inside.sh`. `inside.sh` rsyncs the worktree to `/work/klio` (without
`.git`, `zig-out`, `.zig-cache`, `.klio-local`, `target`), runs `zig build`
and `zig build klio-harness klio-census`, `scripts/zigcheck.py ktor_tls` and
`ktor_client`, installs the packs with
`PACK_FILTER=klio-kotlin-test,klio-kotlinx-,klio-ktor
scripts/install-local-packs.sh`, then `klio-census` for each ktor suite,
`scripts/zigcheck.py itests --root src/itests/ktor_*.zig`, and each
`examples/ktor_*.kt` against its expected output. With Docker's 8 GB VM the
censuses run two jobs at a time (KLIO_ITEST_JOBS=2); four at once, or a
ReleaseSafe harness build beside other containers, runs out of memory.

## Out of scope for now

- HTTP/2: upstream's test server runs a Netty HTTP/2 server at 8084, which
  klio's test server does not start, since klio has no HTTP/2 engine.
