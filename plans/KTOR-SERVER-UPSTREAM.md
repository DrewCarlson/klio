# Ktor server: consume real upstream (no reimplementation shims)

Goal: the `server` feature of the `io.ktor` pack must consume the **real
upstream `ktor-server-core`** sources verbatim, with klio supplying only
`actual` implementations (for upstream `expect`s) and a server-engine
`actual` over the native `__kktor_serve` transport — mirroring how the
client consumes `ktor-client-core` + `KlioClientEngine`. No klio-authored
reimplementations of ktor types (the old `shim/server` is deleted).

## Architecture (mirrors CIO / the client)

- `embeddedServer(factory, port) { module }` — real upstream entry point.
- `EmbeddedServer` — `expect class`; the `posix` actual `EmbeddedServerNix`
  is pure Kotlin → consume it.
- `ApplicationEngineFactory.create(env, monitor, devMode, config, appProvider)`
  → klio supplies a factory whose engine extends `BaseApplicationEngine`.
- Engine bridge (klio-authored, the one real piece of new code):
  - `KlioApplicationEngine : BaseApplicationEngine` — binds via `__kktor_serve`;
    per request builds a call and runs `pipeline.execute(call)` (which hits
    `EnginePipeline.Call` → `call.application.execute(call)` → routing).
  - `KlioApplicationCall : BaseApplicationCall`
  - `KlioApplicationRequest : BaseApplicationRequest` — `engineHeaders`,
    `engineReceiveChannel` from the native request strings.
  - `KlioApplicationResponse : BaseApplicationResponse` — implement
    `setStatus`, `responseChannel()`/`respondOutgoingContent`, capture
    status+headers+body to hand back to `__kktor_serve`.

## Source curation

Consume under the `server` feature (gated, requires `http`,`events`):
- `upstream/ktor-server/ktor-server-core/common/src/io/ktor/server/**`
  (engine, application, request, response, routing, http, config, util) —
  curated; prune files that don't parse/run in klio as found.
- `posix/src` PURE actuals: `EmbeddedServerNix`, `DefaultTransformNix`,
  `engine/internal/EngineUtilsNix`, `request/ApplicationReceiveFunctions.posix`.
- `nonJvm/src` PURE actuals: `config/ConfigLoaders.nonJvm`,
  `application/ApplicationEnvironment.nonJvm`, `application/Application.nonJvm`,
  `engine/EngineConnectorConfing.nonJvm`, `engine/ApplicationEngineEnvironment.nonJvm`,
  `http/content/DefaultTransform.nonJvm`, `engine/internal/ExceptionUtils.nonJvm`.

klio-author `actual`s (the cinterop / reflect ones the posix/nonJvm sets use
`platform.posix`/`kotlinx.cinterop`/`kotlin.reflect` for) under
`shim/server-engine/` — replacing, NOT consuming, these upstream files:
- `engine/internal/ApplicationUtilsNix` → `availableProcessorsBridge()`,
  `Dispatchers.IOBridge`, `printError()`, `configureShutdownUrl()`.
- `engine/ShutdownHookNative` → `SHUTDOWN_HOOK_ENABLED`, `platformAddShutdownHook`.
- `engine/EnvironmentUtilsNix` / `EnvironmentUtils.nix` (whatever expects they back).
- `application/internal/TypeUtils.nonJvm` → `starProjectedTypeBridge` (no reflect).

## Iterate loop

`klio pack build kotlin-klio/klio-ktor` collects sources (no typecheck);
errors surface at RUN time. Loop: add upstream files + actuals → build →
`klio run --feature io.ktor/server srv.kt` → fix the unresolved-symbol /
missing-actual / parse / interpreter error → repeat. Expect deep interpreter
gaps (full suspend send/receive pipelines, routing tree, OutgoingContent /
ByteWriteChannel response) like the ones fixed for simpler programs.

## Status

- [x] shim/server deleted.
- [x] manifest consumes upstream server-core + curated posix/nonJvm (verified:
      pack builds and a `import io.ktor.server.routing.*` program loads).
- [x] klio engine actual authored (`shim/server-engine/.../KlioServerEngine.kt`,
      `object Klio : ApplicationEngineFactory`), driving the native
      `__kktor_serve` transport; cinterop actuals authored.
- [x] **An empty `embeddedServer(Klio, port){ }.start()` constructs, starts,
      and BINDS — the server listens on the port end-to-end.** Getting here
      root-caused and fixed a stack of interpreter bugs (all with standalone
      repros + tests, committed):
      - named-argument overload re-resolution + implicit extension receiver
        (`embeddedServer` overload recursion);
      - qualified-supertype linking (`Engine.Configuration :
        ApplicationEngine.Configuration()` inheriting base fields);
      - super-constructor default arguments (`BaseApplicationEngine`'s default
        `pipeline` param);
      - `recv::method` / `::prop` bound-reference args satisfying a
        function-typed parameter;
      - `MutableIterator.remove()` (mergePhases);
      - `MutableCollection.addAll(Array)`; coroutines `addLast(node)` 1-arg;
      - value-call + named-call trailing-lambda binding (`runBlocking { }`,
        `embeddedServer(…){ module }`);
      - receiver-function-value invocation (`application.module()` for a
        `Application.() -> Unit` local);
      - generic extension property on a type-parameter receiver
        (`val <A : Pipeline<*,…>> A.pluginRegistry`).
- [ ] **NEXT BLOCKER (routing): bare companion-member resolution.**
      `RoutingRoot.Plugin.install` does `pipeline.intercept(Call)` where `Call`
      is `ApplicationCallPipeline.ApplicationPhase.Call` (a named-companion
      `val`). klio resolves bare `Call` as a field on the enclosing `Plugin`
      object (`get_field Call on RoutingRoot.Plugin`) instead of the companion
      member reachable through `import io.ktor.server.application.*`. Routing
      setup otherwise progresses deep into the route-tree / pipeline build.
- [ ] also pending in the start path (revealed, not yet hit again): the
      connector-logging `launch { resolvedConnectors().forEach { … } }` +
      `destroyBlocking`/`cancelAndJoin` must complete cleanly (a job-cancel
      that resumes children parked on `await()`); only exercised on the failure
      path, so deferred until routing starts a real request.
- [ ] (superseded) klio engine actual + cinterop actuals authored. SPI:
      - `BaseApplicationResponse` abstract: `setStatus(HttpStatusCode)`,
        `responseChannel(): ByteWriteChannel`, `respondUpgrade(ProtocolUpgrade)`,
        plus a `headers: ResponseHeaders` (abstract `engineAppendHeader`,
        `getEngineHeaderNames`, `getEngineHeaderValues`).
      - `BaseApplicationRequest` abstract: `engineHeaders: Headers`,
        `engineReceiveChannel: ByteReadChannel` (+ `queryParameters`,
        `rawQueryParameters`, `cookies`, `local: RequestConnectionPoint`).
      - `BaseApplicationCall`: `request`, `response`, call `putResponseAttribute()`.
      - Engine: `BaseApplicationEngine` subclass; per request build the call and
        run `pipeline.execute(call)`; read back status/headers/body (the send
        pipeline writes the `OutgoingContent` to `responseChannel()`).
      - cinterop actuals to author (replace upstream *Nix): `ApplicationUtilsNix`
        (`availableProcessorsBridge`, `Dispatchers.IOBridge`, `printError`,
        `configureShutdownUrl`), `ShutdownHookNative`, `EnvironmentUtils*`,
        `application/internal/TypeUtils.nonJvm` (`starProjectedTypeBridge`).
- [ ] a real GET routes through the upstream pipeline (expect interpreter gaps:
      suspend send/receive pipelines, ByteWriteChannel response, routing tree).
- [ ] itest/docs ported to real ktor server API; full suite green.
- [ ] Phase 2: audit shim/core + shim/*-serialization for reimplementations.

This is in progress on a branch; `main` keeps the (to-be-replaced) shim server
so CI stays green until the upstream engine routes a real request.
