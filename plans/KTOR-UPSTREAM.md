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

**Remaining — async interceptor suspension (one precise blocker).** When an
interceptor suspends at a real point mid-`proceed` (`delay`), the suspension
crosses the intrinsic-host boundary: `invoke_callable` (and
`invoke_callable_with_this`, the path `call_value_with_this` uses) maps
`EvalError::Suspended(state)` through its `other =>` arm to
`RuntimeError::Type("coroutine suspended …")` — a fatal error — because the
`IntrinsicHost` trait's `RuntimeError::Suspend(i64)` can't carry the captured
`SuspendState` frames. So a suspending callback invoked via the intrinsic-host
path can't park. The fix: invoke the (receiver-bound) interceptor through the
main `eval_with_captures` path, which propagates `EvalError::Suspended` with
frames natively (it already drives `runBlocking`/`launch`); i.e. give
`call_value_with_this` a frame-preserving path that sets up the receiver
(this-capture + receiver-label, as `invoke_callable_with_this` does) but runs
on the main evaluator instead of the intrinsic host. Then `DISABLE_SFG=true` +
the `io.ktor.util` deps let the cores consume upstream.

**Undispatched-start semantics (alternative, if keeping `SuspendFunctionGun`).** Root cause:
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

## Open blockers (next, in order)

1. **Receiver-lambda *property* invoked extension-style.**
   `DelegatingMutableSet.next()` does `delegateIterator.next().convertTo()`,
   where `convertTo: From.() -> To` is the wrapper's lambda property invoked
   with the entry as receiver. A broad `call_member` fallback for this
   misrouted coroutine method calls to same-named captured lambdas (broke
   mm9/mm10 conformance) and was reverted — it needs a precise resolution
   (the lambda is the *enclosing* instance's property, reached via the anon
   object's outer `this`; resolve at lowering or with the current method's
   `this` in scope, not via a blanket global-lambda lookup). Gates iterating
   the wrapper views (keys/entries/values all use the same shape).
2. **ktor-http remainder** — `Headers`/`Parameters`/`Url`/`URLBuilder`/codecs,
   once (1) lands.
3. **Layer 2 — Pipeline runtime** (`Pipeline`/`PipelineContext`/`SuspendFunctionGun`
   + `createPlugin`/`EventDefinition`), the spine of both cores.
4. **Cores on upstream**, engine staying klio-side.

## Status

The protocol foundation is consuming real upstream and the general fixes it needs
are landing. The remaining path is a deliberate multi-step program: the Map
key-equality change, then the ktor-http remainder, then the Pipeline runtime for
the cores. The shim stays in place so client/server keep working until each
layer's upstream replacement is validated.
