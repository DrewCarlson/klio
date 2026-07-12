# Ktor server: consume real upstream (no reimplementation shims)

Goal: the `server` feature of the `io.ktor` pack consumes the **real upstream `ktor-server-core`** sources verbatim, with klio supplying only `actual` implementations (for upstream `expect`s) and a server-engine `actual` over the native `__kktor_serve` transport — mirroring how the client consumes `ktor-client-core` + `KlioClientEngine`.

## Completed

- The ktor server consumes real `upstream/ktor-server/**`; the klio engine actual `KlioServerEngine.kt` is present (`object Klio : ApplicationEngineFactory`, driving the native `__kktor_serve` transport, plus the cinterop `actual`s the posix/nonJvm sets require).
- The `ktor_server` e2e itest (`src/itests/ktor_server.zig`) is green end-to-end against the real upstream server-core through the Klio engine: routing (200 matched / 404 unknown / 500 on handler throw), path/query/header params, status codes, `receiveText`, and typed JSON `receive<User>()` / `respond(value)` through ContentNegotiation; nested routes, constant/wildcard `*`/tailcard `{path...}` selectors, and a non-blocking `start(wait = false)` server that exits cleanly.

## Still open

### Start-path coroutine flakiness

The connector-logging `launch { resolvedConnectors().forEach { … } }` plus the binding race make `start()` intermittently slow to bind. On the failure path, `destroyBlocking` / `cancelAndJoin` must resume children parked on `await()`.

### Phase 2 — audit shim/core + shim/*-serialization

`shim/core` is audited and restructured. The pure-Kotlin upstream posix actuals are consumed verbatim (`CollectionsNative.kt`, `PlatformUtilsNative.kt`, `ConcurrentMapNative.kt`, `AttributesNative.kt`, and — under a new `upstream/ktor-io/posix/src` source root — `ByteChannel.posix.kt`), replacing the klio reimplementations. The charsets surface is now the real upstream layer (common `Encoding.kt` + posix `CharsetNative.kt`), with klio supplying only the terminal UTF-8/ISO-8859-1 codec actuals (`object Charsets`, `findCharset`, `encodeImpl`, `encodeToByteArrayImpl`, `CharsetDecoder.decode`); this also makes `MalformedInputException`/`TooLongLineException` real declarations (consumed `ByteReadChannelOperations.kt` throws the latter, `DefaultResponseValidation.kt` catches the former — both were missing symbols before). The `ioDispatcher()` actual pairs honestly with the consumed `io.ktor.utils.io.IODispatcher.kt` expect (it was a same-package shadow in `io.ktor.client.engine`); klio keeps `Unconfined` deliberately for the blocking `__kktor_request` transport. The dead `_hex.kt` helper is deleted. What remains in `shim/core` is genuinely cinterop-gated upstream: `DateKlio.kt` (gmtime_r/timegm), `KtorSimpleLoggerKlio.kt` (getenv; KTOR_LOG_LEVEL pinned INFO), `PipelineKlio.kt` (getenv; DISABLE_SFG pinned true), `LocksKlio.kt` (pthread; host-bound ReentrantLock).

`shim/client-serialization` and `shim/server-serialization` are audited: both reimplement vendored upstream modules (ktor-client/ktor-server content-negotiation + ktor-serialization-kotlinx-json) and should be replaced in ONE coordinated swap of both features (they declare the same `io.ktor.serialization.kotlinx.json.json()` FQN on different fake configs). The swap is blocked on the kotlinx.serialization pack growing the real serializer surface upstream `KotlinxSerializationConverter`/`SerializerLookup` compile against: `Json : StringFormat` over the `__klsx_json*` intrinsics, `serializersModule` + `serializerOrNull(KType)`/`getContextual`, and the builtin serializers. Also needed: the ClientSSESession type surface in the ktor-client-core include list, `io/ktor/server/plugins/Errors.kt` in the server-core include, and a decision on `ExperimentalJsonConverter.kt` (imports kotlinx-serialization-json-io, absent from the pack). Until then `Json.decodeToClass` stays as the bridge these two shims ride on.
