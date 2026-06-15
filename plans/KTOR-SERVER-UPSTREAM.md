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
- [x] **A routing server STARTS, LISTENS, and answers real HTTP** — routing
      resolves (200 for a matched route, 404 for an unknown one, 500 when the
      handler throws) and the matched **handler executes** through the upstream
      pipeline. Reaching this fixed more interpreter bugs (committed):
      - enclosing-class companion resolution (a nested/companion object reads a
        bare name from its enclosing class's superclass companions —
        `RoutingRoot.Plugin` resolving `Call` from `ApplicationCallPipeline`);
      - a declared member property outranks a same-named extension property
        (`val Route.application get() = … is RoutingRoot -> application`,
        which otherwise recursed);
      - receiver-lambda invoke binds the receiver (`handler.invoke(ctx)`);
      - typealias function-type arity counts value params only
        (`RoutingHandler = RoutingContext.() -> Unit` → `Function0`), registered
        before body lowering so the trailing lambda drops its spurious `it`;
      - pack now consumes `io/ktor/server/plugins/OriginConnectionPoint.kt`.
- [ ] **NEXT BLOCKER (response body): `respondText`'s content does not reach
      the engine.** The handler runs and calls `call.respondText(...)`, but the
      send pipeline never reaches `BaseApplicationResponse.respondOutgoingContent`
      → the engine `respondFromBytes` (verified: a throw planted there never
      fires; the response comes back `200 text/plain Content-Length: 0`). The
      `OutgoingContent` is lost/emptied somewhere in the send-pipeline stages
      (Render/Transform → Engine phase) before the `setupSendPipeline`
      `intercept(Engine)` interceptor delivers it to
      `call.attributes[EngineResponseAttributeKey].respondOutgoingContent`.
- [ ] start-path coroutine flakiness: the connector-logging
      `launch { resolvedConnectors().forEach { … } }` + the binding race make
      `start()` intermittently slow to bind; and `destroyBlocking`/
      `cancelAndJoin` on the failure path must resume children parked on
      `await()`.
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
- [x] a real GET routes through the upstream pipeline; the response body
      (`respondText` / `respond(value)`) reaches the engine.
- [x] itest ported to the real ktor server API; the full server itest is green
      (`zig build itest-ktor_server`): GET with path/query/header params + status
      codes, POST raw text, POST typed JSON through ContentNegotiation
      (`receive<User>` deserialize + `respond(value)` serialize), nested routes,
      tailcard `{path...}`, single-segment wildcard `*`, and 404; plus a
      non-blocking `start(wait = false)` server that exits cleanly.
- [ ] Phase 2: audit shim/core + shim/*-serialization for reimplementations.

## Status update

End-to-end, against the real upstream ktor-server-core through the Klio engine:

- Client: `HttpClient().get(url)` returns status + body (verified vs a Python server).
- Root route: `get("/") { call.respondText("…") }` delivers `200` + the body
  with the right `Content-Type`/`Content-Length`.
- Typed JSON: `install(ContentNegotiation) { json() }` + `call.respond(value)`
  serializes through the send pipeline's Render phase to a JSON `TextContent`
  (`application/json`), delivered to the engine.

Interpreter fixes that unblocked the above:
- Bare `call` inside a routing handler resolved to the receiver (a
  `T.() -> R` receiver handler must drop its synthetic `it`; the trailing-lambda
  arity is read from the overload that actually hosts the lambda).
- Extension-overload applicability gate so `install(RoutingRoot, …)` picks the
  generic `Plugin` overload, not a receiver-tight but inapplicable sibling.
- Named arguments honored when constructing a nested class through member
  dispatch (a companion `invoke` diverts `Outer.Nested(x, field = y)` off the
  bare `NewInstance` path); fixes `RouteSelectorEvaluation.Success(…,
  segmentIncrement = 1)` so constant path segments are consumed and non-root
  routes match.
- The server-serialization shim no longer defines a conflicting `respond`/
  `receive` overload; ContentNegotiation hooks the real send pipeline instead.

Routing now fully resolves and the handler runs through the recursive
`handleRoute` unwind — the earlier "park" is gone. Constant, wildcard, and
tailcard selectors all consume their segments and dispatch the handler.

Interpreter fixes that landed the green server itest:
- `when` over a String subject lowers to a switch keyed on string constants;
  the switch comparison now matches String keys by content instead of falling
  through to `else` (`parseConstant("*")` returns the wildcard selector, so
  `/any/*/end` matches a single segment). Pinned: `when_string_subject`.
- Typed `receive<User>()` deserializes (the inline-extension splice threads the
  bound `this` receiver to `receiveNullable`); 1-arg and 2-arg `respond(value)`
  serialize through ContentNegotiation's Render phase.
- The non-blocking server itest calls `embeddedServer` at top level: a bare
  call inside `runBlocking` resolves (correctly, per Kotlin overload rules) to
  the `CoroutineScope.embeddedServer` extension, which parents the application
  job to the `runBlocking` job so it never returns; the top-level overload
  parents to `GlobalScope`, which the run boundary abandons cleanly at exit.

- A bare control/precondition intrinsic (`error`/`check`/`require`/`TODO`/…)
  called in a receiver context — routed through member-or-global dispatch when
  some loaded class declares a same-named member (e.g. the coroutines
  `ErrorCatching.error` extension) — reached `stdlibMemberDispatch`, which
  prepended the enclosing receiver to the intrinsic's value parameter. A bare
  `error("msg")` inside a `runBlocking` CoroutineScope lambda therefore threw
  with the scope's `toString()` instead of `"msg"`. `isToplevelFunction` now
  reports these as top-level non-extensions, so the receiver is never
  prepended. Pinned: `error_in_receiver_context`.
