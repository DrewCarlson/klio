# Rebuilding ktor on upstream commonMain

Goal: replace the hand-written ktor shim with **consumption of real upstream
ktor `commonMain`** (vendored submodule, pinned 3.2.0), keeping ktor's Gradle
module structure (mapped to pack features), and writing klio-side **actuals +
Rust intrinsics only for the low-level platform code** (charsets, crypto, dates,
locks, byte channels, the HTTP socket engine). This mirrors how the kotlinx
packs already work.

## Foundation (done)

- `crates/klio-ktor-client/upstream` — ktor submodule, pinned to `3.2.0`.
- Recon of each module's `commonMain` consumability (klio parser + deps + expects).
- Runtime fix: a bare call `name()` whose own member is a same-named *property*
  now resolves to a top-level `fun name()` — real upstream `HttpStatusCode` runs.

### General interpreter / stdlib fixes landed (unblock broader consumption)

Surfaced while making `kotlin.io.encoding.Base64` (a precondition for ktor
`basicAuth` and the codecs) run end to end. Each is a root-cause fix with a
regression test:

- **Companion that extends its enclosing class** (`class C { companion object
  Default : C() }`, exactly `Base64`'s shape) no longer infinite-loops on a bare
  top-level call inside a member: the companion-fallback supertype walk skipped
  forwarding to a singleton whose identity *is* the receiver.
- **Nested lambda inherits the enclosing receiver-lambda's `this`.** A lambda
  inside `apply`/`with`/`buildString` (or an extension-receiver lambda) that
  referenced `this` collapsed it to `Unit`; `resolve_capture` now forwards the
  receiver through the enclosing builder's capture slot. Fixes the idiomatic
  `IntArray(n).apply { src.forEachIndexed { i, s -> this[i] = s } }` (Base64's
  decode-table build).
- **Bodyless `expect` overloads are no longer selected.** `minOf`/`maxOf`'s
  primitive overloads are `expect inline` with no klio actual (the real impl is
  a host intrinsic); overload resolution in member/lambda context picked the
  empty expect. `overload_score` now declines bodyless candidates and
  `call_named_overload` defers to the intrinsic.
- **stdlib actuals:** `Base64` platform helpers; `Array.contentEquals` /
  `contentToString` (were no-op `Unit`).

### ktor-client request members (shim, real shipping path)

`put`/`delete`/`patch`/`head`/`options` (+ `*With` builder DSL), `parameter`,
`bearerAuth`, `basicAuth` (now that Base64 works), and `HttpMethod.Connect/Trace`.

## Module map (measured against klio)

| module | parse-clean | expects (need actuals) | key runtime blockers |
|--------|-------------|------------------------|----------------------|
| ktor-io | 43/43 | 30 (Charset/encoder, locks, ByteOrder, Pool) | charset machinery, sync primitives, kotlinx.io integration |
| ktor-utils | 53/53 | 36 (Attributes, Crypto sha1/nonce, GMTDate/getTimeMillis, GZip/Deflate, PlatformUtils) | Pipeline + SuspendFunctionGun, atomicfu collections, typeOf reflection |
| ktor-http | 56/57 | 0 | a few suspend bodies (OutgoingContent, Multipart), Charset ext fns |
| ktor-client-core | 62/86 | 0 | Pipeline (25 files), Attributes (11), createPlugin/EventDefinition (5) |
| ktor-server-core | 60/88 | 25 | Pipeline (45+), createPlugin (33), EventDefinition (18) |
| ktor-serialization-kotlinx-json | 3/3 | 1 (deserializeSequence) | Flow-based serialize; ContentConverter framework |

Dependency order: **ktor-io → ktor-utils → ktor-http → {client-core, server-core} → serialization-kotlinx-json**.

## Staged plan (bottom-up; each layer ships validated)

- **Layer 0 — low-level actuals (the directive's "low-level code").** klioMain
  `actual`s + Rust intrinsics for: ktor-io charsets (map onto klio's UTF-8
  strings), `ByteOrder`/byte-reversal, `SynchronizedObject`/`ReentrantLock`,
  `Pool`; ktor-utils `Attributes`, `GMTDate`/`getTimeMillis`, `sha1`/
  `generateNonce`, `PlatformUtils`, `StringValues`. Curated `[[source]]` pulls
  the parse-clean upstream files; klioMain supplies only the `expect` actuals.
- **Layer 1 — ktor-http (protocol).** 0 expects; consume the curated 36-file
  surface (ContentType, HttpStatusCode, HttpMethod, HttpHeaders, Url/URLBuilder,
  Parameters/Headers, codecs, parsing) on real upstream once Layer 0 lands.
- **Layer 2 — Pipeline + plugin runtime (the spine).** Make
  `io.ktor.util.pipeline.Pipeline` / `PipelinePhase` / `PipelineContext` /
  `SuspendFunctionGun` and `createPlugin`/`EventDefinition` run in klio. This is
  the largest interpreter lift and is required by both cores.
- **Layer 3 — client-core / server-core on upstream.** Consume the curated
  commonMain; the actual socket/HTTP engine stays klio-side (Rust intrinsics:
  `__kktor_request` via ureq, `__kktor_serve` via TcpListener) as the platform
  `actual`s — which is exactly the low-level boundary.
- **Layer 4 — ktor-serialization-kotlinx-json** on upstream over the existing
  serialization pack's `json` feature.

Features stay one-per-Gradle-module (`client`, `server`, `client-serialization`,
`server-serialization`, …), so consumers opt in exactly as today.

## Progress

Real upstream now runs in klio (validated as multi-file programs): `HttpStatusCode`
(incl. `fromValue`), `HttpMethod`, and `ContentType` (incl. `parse`, `match`,
`withCharset`) — consumed verbatim from `ktor-http/common/src`, with a small
klioMain `Charset` actual (the genuinely low-level piece).

General interpreter fixes landed along the way (each helps all programs):
- bare call resolves to a top-level `fun` over a same-named property
  (`HttpStatusCode.allStatusCodes`);
- `String.equals` returns `Bool`, incl. the `ignoreCase` form, named or positional;
- `key in map` over a user `Map` type routes to `containsKey`.

## More general fixes landed (toward ktor-http Headers)

- **Map key equality honors the key's `equals`/`hashCode`.** get/containsKey/put/
  remove invoke the key's `equals` for instance keys (builtin keys keep the fast
  structural path) — ktor's `CaseInsensitiveString` header keys now match.
- **Stdlib Map extensions over user Map types.** `forEach`/`any`/`map`/… on a
  user class implementing `Map` materialize via its `entries` and re-dispatch
  (the Map analogue of the iterable fallback) — `StringValues` does
  `values.forEach { }` over a custom map.

More fixes landed: anonymous-object property initializers over captures are
now evaluated (`val inner = src.iterator()`), so `DelegatingMutableSet`'s
anonymous iterator constructs; and `entries`/`size` over the wrapper work.

## Pipeline runtime (phase 2) — recon + progress

The big remaining lift: consume the real upstream `io.ktor.util.pipeline.*`
(`Pipeline`/`PipelineContext`/`SuspendFunctionGun` + `PipelinePhase`/
`PhaseContent`, ~1050 lines) so client/server cores run on upstream and the
request-member shims delete. `SuspendFunctionGun` is the coroutine state
machine; it drives the low-level **manual-continuation** API directly:
`suspendCoroutineUninterceptedOrReturn`, `Continuation.intercepted()`,
storing a `Continuation` and resuming it by hand (`resumeRootWith`/
`addContinuation`), `startCoroutineUninterceptedOrReturn`, plus a
`pipelineStartCoroutineUninterceptedOrReturn` `expect` needing a klio actual.

**Landed:** the first hard prerequisite — an object expression created
inside an inline function (the `kotlin.coroutines.Continuation(ctx) { … }`
factory) whose members reference the captured crossinline parameter of the
*same name* (`override fun resumeWith(r) = resumeWith(r)`) now binds the
captured param instead of self-recursing into the member (was an infinite
loop). Fixed at lowering for both bare calls and reads of an anon-object
capture name.

**Landed (continued):**
- Anon-object getter capture (`override val context get() = context`) — the
  getter is lowered as a `$get$<name>` anon method inside the capture window
  and invoked through `call_member` on read, so a getter reading a closed-over
  outer resolves. This made the `Continuation(ctx){}` factory work, which
  unblocked the **low-level manual-continuation API**: `startCoroutine`,
  `Continuation(ctx){}.resumeWith`, `suspendCoroutineUninterceptedOrReturn`
  with a hand-stored continuation all work now.
- Receiver-lambda-with-value-param coroutine overloads
  (`(suspend R.(P) -> T).startCoroutineUninterceptedOrReturn(receiver, p,
  completion)` / `createCoroutineUnintercepted`) — the `PipelineInterceptor`
  shape. A faithful `SuspendFunctionGun` port now threads the subject through
  the interceptor chain correctly (`A got start` / `B got start-A` / …).

**Landed — synchronous `SuspendFunctionGun` works.** The `lastSuspensionIndex`
underflow was a general interp bug: prefix `++field` / `--field` on a bare
instance field never wrote back (it rebound a local; only postfix had the
SetField-on-this branch). Fixed. A faithful `SuspendFunctionGun` port now runs
a synchronous interceptor chain end to end (`A got start` → `B got start-A` →
`C got start-A-B`, `final=start-A-B-C`) — the common pipeline path (routing,
headers, content negotiation; I/O suspension lives at the leaves, not in
`proceed`).

**Landed — receiver-lambda value-style invocation.** `block(receiver, p)` /
`block.invoke(receiver, p)` for a `R.(P) -> T` now binds the receiver (was
unbound; only `receiver.block(p)` worked). This is the `DebugPipelineContext`
interceptor-invocation shape (`executeInterceptor.invoke(this, subject)`), so
that context — a plain suspend loop, no manual continuation array — also runs
the synchronous chain. Either context (`SuspendFunctionGun` via the field-
incdec fix, or `DebugPipelineContext` via `DISABLE_SFG=true`) executes the
synchronous pipeline.

**Landed — async interceptor suspension works (pipeline runtime done).** The
suspending-interceptor blocker was the intrinsic-host boundary: a body
suspension routed through `call_value_with_this` → `invoke_callable*` mapped
`EvalError::Suspended(state)` to a fatal `RuntimeError::Type` (the
`IntrinsicHost` `RuntimeError::Suspend(i64)` can't carry `SuspendState`
frames). Fixed: the receiver-lambda value-invoke now binds the receiver into a
fresh closure value's `this` capture and re-runs on the **main
`eval_with_captures` path**, which propagates `Suspended` with frames natively.
A `DebugPipelineContext`-shaped runner (plain proceed-nested suspend loop,
`ic.invoke(this, subject)`) now executes a chain with a **suspending
interceptor that parks at `delay` and resumes mid-chain**, with post-`proceed`
continuation work, end to end:
`A in start → B in start-A → B resumed → C in start-A-B → A out start-A-B-C →
final=start-A-B-C` (regression test `pipeline_context_smoke`). So the pipeline
runtime is functional via `DebugPipelineContext` (`DISABLE_SFG=true`) — no
`SuspendFunctionGun`/undispatched-start needed.

**Remaining — consume the upstream Pipeline files (dep plumbing).** With the
execution engine working, wire the real files in: provide the `DISABLE_SFG`
actual (`= true`), a `pipelineStartCoroutineUninterceptedOrReturn` actual (so
`SuspendFunctionGun.kt` still resolves even though unused), the `io.ktor.util`
deps (`Attributes`, `KtorDsl`, `StackWalkingFailed`) + `kotlinx.atomicfu`
refs, and `CoroutineScope` (PipelineContext's supertype); then switch the
cores onto upstream `Pipeline`/`PipelineContext` and delete the request-member
shims.

**Undispatched-start semantics (only if `SuspendFunctionGun` is ever forced on).** Root cause:
`SuspendFunctionGun.loop` calls `startCoroutineUninterceptedOrReturn(...)` and
expects the JVM contract — run the interceptor *up to its first suspension*
and **return `COROUTINE_SUSPENDED` as a value** (the parked continuation
resumes `completion` later), or return the result if it completed. klio's
model instead *parks the whole activation* and unwinds to the nearest driver,
so a suspending interceptor never returns `COROUTINE_SUSPENDED` to `loop`, and
the synchronous nesting double-drives the continuation stack. The fix is a new
host primitive — an **undispatched-start driver** that runs `body()` and
returns `COROUTINE_SUSPENDED` on first park (persisting the parked activation
via the existing `PERSISTED_PARKED` path and wiring `completion` to its
eventual completion), else returns the value. `startBlock` in
`kotlin-coroutines/Intrinsics.kt` would route to it. This must integrate with
the cooperative `drive_root` without regressing `runBlocking`/`launch`.

**Then:** `io.ktor.util` deps (`Attributes`, `KtorDsl`, `StackWalkingFailed`)
+ `kotlinx.atomicfu` refs in the pipeline files; the `DISABLE_SFG` and
`pipelineStartCoroutineUninterceptedOrReturn` actuals; switch the cores onto
upstream and delete the request-member shims.

## Landed (general fixes that unblock upstream consumption)

- **Inline builders from a pack consumer.** `buildString`/`buildList`/
  `buildSet`/`buildMap` are `inline fun`s in the stdlib; a pack consumer sees
  only a bodyless forward stub at lower time, so an arity-aware bind is
  unavailable and the bare-name path picked the 1-arg overload's body and
  invoked the `capacity` argument. They are now in the implicit-alias set so a
  bare reference resolves to the host intrinsic actual (`buildString(capacity,
  block)` accepted). `Text.kt`'s `escapeHTML`/`toLowerCasePreservingASCIIRules`
  depend on this.
- **`StringBuilder.append(CharSequence, startIndex, endIndex)`** appended its
  three args in turn instead of the subrange; routed to the range append.
- **`List(size){init}` / `MutableList(size){init}` factories.** `List` is also
  a registered interface, so a bare `List(n){…}` lowered to `NewInstance(List)`
  and threw "Cannot create an instance of an interface". `new_instance` now
  builds the list directly when the interface name is `List`/`MutableList` and
  the args are `(Int, (Int)->T)`. `StringValuesImpl.init` needs this.
- **Floating-point range membership.** `x in lo..hi` with a range *literal*
  lowers to `lo <= x && x <= hi` (`< hi` for `..<`) — kotlinc's `in` intrinsic
  form — which supports `Double`/`Float` endpoints that the integer
  `Value::Range` cannot represent (`HeaderValue.quality`'s `it in 0.0..1.0`).
  `Float` comparisons widen to `Double` (lossless) since only `Float`
  *arithmetic* had explicit arms.
- **Consumed verbatim:** `io.ktor.util.Text.kt`. The util collection layer
  (`Collections.kt` + a klio `unmodifiable` actual, `DelegatingMutableSet.kt`,
  `CaseInsensitiveMap.kt`, `StringValues.kt`) and the http header/content-type
  layer (`HttpHeaderValueParser.kt`, `HeaderValueWithParameters.kt`,
  `ContentTypes.kt`) load and the full `ContentType` API runs (parse /
  withParameter / match / charset / parseHeaderValue), but consuming them is
  blocked on (1) and (2) below — held back from `klio.toml` until fixed.

## Open blockers (next, in order)

1. **Consuming `ContentTypes.kt` breaks the server program's `routing`
   resolution** ("unresolved global `routing`"). Bisection is exact: adding
   `ContentTypes.kt` to the pack is the sole trigger (util + `HttpHeaderValueParser`
   + `HeaderValueWithParameters` all load with `routing` intact; the full
   `ContentType` API — parse / withParameter / match / charset / parseHeaderValue
   — runs correctly when invoked directly). The first hypothesis was a bare
   simple-name collision between the nested `object Application` (inside
   `ContentType`, `io.ktor.http`) and the server's `class Application`
   (`io.ktor.server.application`), shadowing the `Application.routing` extension
   receiver. **That hypothesis is not confirmed:** minimal pack repros — a
   nested `object Application` beside a top-level `class Application` + a
   `routing` extension + a `T.()->Unit` builder HOF, even with a companion
   `object { val Any; fun parse }`, several sibling nested objects, and a
   `HeaderValueWithParameters` superclass — all resolve `routing` fine, *including*
   an exact `embeddedServer(engine, port) { … }`-shaped builder. The one
   structural axis the repros do **not** mirror: ktor splits `Application`
   (`io.ktor.server.application`), `routing` (`io.ktor.server.routing`),
   `embeddedServer` (`io.ktor.server.engine`) and `CIO` (`io.ktor.server.cio`)
   across separate packages and pack *features*, all wildcard-imported by the
   program, while the repros keep them in one package. A repro that *does* mirror
   that split (distinct `application`/`routing`/`engine`/`cio` packages in a
   feature + a core nested `object Application`, all wildcard-imported) **still
   resolves `routing` correctly**. So structure alone does not trigger it — the
   cause is specific content in the real 429-line `ContentTypes.kt` (or an
   interaction with the other loaded real ktor files). Next step: binary-search
   `ContentTypes.kt` against the real pack (add half its declarations, rebuild,
   test `routing`) to pin the exact construct, then resolve it. Per CLAUDE.md the
   eventual fix is in resolution, never by renaming the upstream type. Gates
   `ContentTypes.kt` (and thus replacing the divergent `shim/.../ContentType.kt`).
2. **Receiver-lambda *property* invoked extension-style.**
   `DelegatingMutableSet.next()` does `delegateIterator.next().convertTo()`,
   where `convertTo: From.() -> To` is the wrapper's lambda property invoked
   with the entry as receiver. Iterating a `CaseInsensitiveMap`/`StringValues`
   view (`entries`/`keys`/`values`) hangs. A broad `call_member` fallback for
   this misrouted coroutine method calls to same-named captured lambdas (broke
   mm9/mm10 conformance) and was reverted — it needs a precise resolution
   (the lambda is the *enclosing* instance's property, reached via the anon
   object's outer `this`; resolve at lowering or with the current method's
   `this` in scope, not via a blanket global-lambda lookup). Gates iterating
   the wrapper views.
3. **ktor-http remainder** — `Headers`/`Parameters`/`Url`/`URLBuilder`/codecs,
   once (1)+(2) land.
4. **Layer 2 — Pipeline runtime** (`Pipeline`/`PipelineContext`/`SuspendFunctionGun`
   + `createPlugin`/`EventDefinition`), the spine of both cores.
5. **Cores on upstream**, engine staying klio-side.

## Status

The protocol foundation is consuming real upstream and the general fixes it needs
are landing. The remaining path is a deliberate multi-step program: the Map
key-equality change, then the ktor-http remainder, then the Pipeline runtime for
the cores. The shim stays in place so client/server keep working until each
layer's upstream replacement is validated.
