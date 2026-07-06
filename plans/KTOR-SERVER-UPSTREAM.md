# Ktor server: consume real upstream (no reimplementation shims)

Goal: the `server` feature of the `io.ktor` pack consumes the **real upstream `ktor-server-core`** sources verbatim, with klio supplying only `actual` implementations (for upstream `expect`s) and a server-engine `actual` over the native `__kktor_serve` transport — mirroring how the client consumes `ktor-client-core` + `KlioClientEngine`.

## Completed

- The ktor server consumes real `upstream/ktor-server/**`; the klio engine actual `KlioServerEngine.kt` is present (`object Klio : ApplicationEngineFactory`, driving the native `__kktor_serve` transport, plus the cinterop `actual`s the posix/nonJvm sets require).
- The `ktor_server` e2e itest (`src/itests/ktor_server.zig`) is green end-to-end against the real upstream server-core through the Klio engine: routing (200 matched / 404 unknown / 500 on handler throw), path/query/header params, status codes, `receiveText`, and typed JSON `receive<User>()` / `respond(value)` through ContentNegotiation; nested routes, constant/wildcard `*`/tailcard `{path...}` selectors, and a non-blocking `start(wait = false)` server that exits cleanly.

## Still open

### Start-path coroutine flakiness

The connector-logging `launch { resolvedConnectors().forEach { … } }` plus the binding race make `start()` intermittently slow to bind. On the failure path, `destroyBlocking` / `cancelAndJoin` must resume children parked on `await()`.

### Phase 2 — audit shim/core + shim/*-serialization

`kotlin-klio/klio-ktor/shim/core`, `shim/client-serialization`, and `shim/server-serialization` still exist and are unaudited. Audit them for reimplementations of ktor types that should consume the upstream sources instead of a klio-authored shim.
