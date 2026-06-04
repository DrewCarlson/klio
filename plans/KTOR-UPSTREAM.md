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
- **Nested object/class name collision with a top-level type (the load-order
  bug).** A nested `object Foo` was lifted to top level under its *bare* name,
  overwriting a same-named true top-level class in the global table (last writer
  wins → source-load-order-dependent). This is why consuming `ContentTypes.kt`
  (nested `object Application`) broke the server's `Application.routing`
  extension: whichever of `ContentType.Application` / the server `class
  Application` lowered last owned the bare name. Fix: `build/lift.rs` mangles a
  nested object whose bare name collides with a true top-level type to
  `Outer$Name` (mirroring the existing `private`-object case) and records the
  outer-body alias; `get_field` on a class receiver resolves `Outer$Name` for a
  qualified `Outer.Name` read; and `lower_receiver` skips the class-name
  shortcut when the enclosing class aliases the name (so a bare `Foo` inside
  `Outer` reaches `Outer$Foo`, not the top-level class). Matches kotlinc:
  top-level keeps the bare name, nested resolves through its qualifier. Covered
  by `corpus/nested_name_collision.kt`.
- **Function-typed property invoked extension-style.** `x.convertTo()` where
  `convertTo: From.() -> To` is a property of the enclosing instance now invokes
  the lambda even when a same-named member extension on a different receiver
  type (`Collection<From>.convertTo()`) also exists — `call_member` had deferred
  to the receiver-incompatible member extension. When no extension candidate's
  declared receiver accepts the actual receiver and a function-typed property of
  that name is reachable (walking the enclosing-`this` chain *and* each
  instance's `outer` links, so it resolves from inside a nested anon object),
  defer to the property. This is `DelegatingMutableSet.next()`'s
  `delegateIterator.next().convertTo()`; it previously hung. Covered by
  `corpus/receiver_lambda_property.kt`.
- **Stdlib collection operators on a user-defined collection.** The builders
  `ArrayList(coll)`/`HashSet(coll)` and `toTypedArray` rejected a class
  implementing Collection/Iterable; a `materialise_iterable_instance` helper
  now drains a user collection through its `iterator()` protocol (via the host),
  so `toList`/`toMutableList`/`toSet`/`map`/`filter`/`count`/`any` (all route
  through `ArrayList(this)`) accept user collections. A bare-package stdlib
  collection extension (the platform `expect` `kotlin.collections.toTypedArray`,
  a no-op `Unit` stub) chosen for a user collection now defers to the Iterable
  fallback (drain + dispatch the type-prefixed intrinsic), so `sorted`/`sortedBy`
  /`toTypedArray` work too. A ctor target redirected from a simple-name-colliding
  interface (synthesised `Map.Entry`) to its concrete class (`CaseInsensitiveMap`'s
  private `Entry`) now populates the instance from the concrete class's primary
  params. Net: ktor's `CaseInsensitiveMap` `keys`/`entries` views iterate fully
  (`sorted`/`toList`/`map`). Covered by `corpus/user_collection_ops.kt` +
  `corpus/user_collection_sorted.kt`.
- **Destructuring a user-defined `Map.Entry`.** `val (k, v) = entry` /
  `forEach { (k, v) -> }` lowers to `component1()`/`component2()`, which matched
  only the native `Value::MapEntry`; on a user instance they fell to the
  `Map.Entry.componentN` extension, which cast the instance to a native map
  (`cast to Map failed`). Resolve `component1`/`component2` on an instance
  implementing `Entry`/`MutableEntry` to its `key`/`value`. Completes
  case-insensitive `StringValues` (`CaseInsensitiveMap`). Covered by
  `corpus/user_map_entry_destructure.kt`.
- **Parent-ctor chaining picks the superclass, not a leading interface.** A
  class may list interfaces before its superclass
  (`HeadersImpl : Headers, StringValuesImpl(...)`); `new_instance` chose the
  parent via `supertype_names.first()` (the interface), so the superclass's
  `super(...)` args were applied to the ctor-less interface and its
  primary-param fields stayed unset (a later init reading such a field saw the
  wrong value — `non-bool in branch`). Select the first non-interface supertype.
  Covered by `corpus/interface_then_superclass.kt`.
- **Trailing-lambda call binding the arity-matching inline fn, not a
  lower-arity same-name member.** `ContentDisposition.Companion.parse(value) =
  parse(value) { v, p -> ContentDisposition(v, p) }` must bind the inherited
  2-arg inline `HeaderValueWithParameters.parse(value, init)`, but
  `prefer_member`/`CallMember` bound the same-companion 1-arg `parse(value)`,
  **dropping the trailing lambda** and recursing. The 2-arg `parse` is
  inline-only (absent from `funcs_by_simple_name` — `cands=[]`), so it is only
  reachable by inlining. The inline-fn arm (`lower/expr.rs`) now also inlines
  when a same-name own member shadows the inline fn *and* the call carries a
  trailing lambda the member can't receive (`want >= 2`, function-typed final
  inline param, no bodied same-name overload of matching arity). The `want >= 2`
  gate keeps a single-lambda HOF (`map { }`, `let { }`) — where the member
  legitimately takes the lambda — on the normal member path. Covered by
  `corpus/inline_fn_member_shadow_trailing_lambda.kt`.
- **`Range + Range` / `Range + element` concatenate via `Iterable.plus`.** A
  range is an `Iterable`, so `('a'..'z') + ('A'..'Z')` is the stdlib `plus`
  (a `List`), not numeric `+`; klio threw `BinOp::Add on Range`. The collection
  `plus`/`minus` dispatch now includes `Value::Range`, and `iterable_items`
  (the drain helper) + `coll_list_plus`/`coll_list_minus` expand a `Range`/
  `Sequence`/`Array` argument. `Codecs.URL_ALPHABET` (`('a'..'z') + ('A'..'Z')
  + ('0'..'9')`) needs this. Covered by `corpus/range_plus_concat.kt`
  (kotlinc byte-parity).
- **Top-level stdlib function call inside a receiver lambda.** A bare
  `listOf(...)` / `setOf(...)` / `mapOf(...)` inside `with(r) { … }` /
  `buildString { … }` lowers its callee to `LoadFromThisOrGlobal`, which probes
  `get_field(receiver, "listOf")` first. `get_field`'s stdlib-property probe
  matched `kotlin.collections.listOf` (a *function*) and auto-invoked it as a
  one-arg property getter (`listOf(receiver)`), yielding a collection the call
  site then tried to invoke (`call_value on List`). `get_field` now skips the
  property probe when the name is a `klio_stdlib::is_toplevel_function`, so the
  read falls through to the global where the call binds the function and applies
  the real arguments. Covered by `corpus/toplevel_fn_in_receiver_lambda.kt`
  (kotlinc byte-parity).
- **Default argument that reads the extension receiver.** A default arg like
  `fun String.f(end: Int = length)` (`length` = `this.length`) lost `this` when
  the default thunk ran via the named-argument fill path — the thunk binds
  `this` as a leading param, but the bare `length` lowered to
  `LoadFromThisOrGlobal` (whose capture slot is empty in a thunk) and escaped to
  an unresolved global. The Path lowering now reads `this.length` whenever
  `this` is genuinely bound (`b.resolve("this")` is `Some`) even in a param
  thunk; a non-extension thunk never binds `this`, so it keeps the global probe.
  ktor's `String.decodeURLQueryComponent(end: Int = length, …)` needs this.
  Covered by `corpus/default_arg_reads_receiver.kt` (kotlinc byte-parity).
- **Bare extension call binds the receiver-matching overload.** A bare call
  to a same-named extension inside an extension body now binds the overload
  whose `this`-param type matches the enclosing receiver — `takeWhile` inside
  `fun Source.forEach` binds `Source.takeWhile`, not the arity-equal stdlib
  `CharSequence.takeWhile`. The `FuncBuilder` carries the enclosing extension's
  declared receiver type (`recv_ty`, set from `Function.receiver_type`); the
  forward-reference stub now seeds the real receiver type on its implicit
  `this` param (was a `kotlin.Unit` placeholder) so the candidate's receiver
  type is stable even before its body lowers; and bare-call resolution prefers
  a candidate matching `recv_ty` when the arity-only pick doesn't. Covered by
  `corpus/bare_ext_call_receiver_match.kt` (kotlinc byte-parity).
- **Charset encoder actual + ktor-io core consumed.** The klio
  `io.ktor.utils.io.charsets` actual gained `Charset.newEncoder()` /
  `CharsetEncoder.encode(input, from, to)` (returns a kotlinx.io `Buffer` of
  the UTF-8 / ISO-8859-1 bytes) + `newDecoder()` / `CharsetDecoder.decode`,
  matching upstream `CharsetEncoder.encode`. Upstream `io.ktor.utils.io.core`
  `Buffer.kt` (`canRead`) + `ByteReadPacket.kt` (`Source.takeWhile`/`remaining`
  /…) + `Deprecation.kt` are consumed verbatim. Verified: an explicit
  `Charsets.UTF_8.newEncoder().encode(s).takeWhile { … canRead … readByte }`
  drains the encoded bytes correctly.
- **Receiver-lambda bare read resolves an enclosing property over a same-name
  top-level function.** `HeaderValueWithParameters.toString()`'s
  `StringBuilder(size).apply { … parameters.lastIndex … }` reads the enclosing
  `this.parameters` (a `List`), but `Parameters.kt` also declares a top-level
  `fun parameters(builder)`; inside the `apply` receiver lambda `this` is the
  StringBuilder, so `get_field` on it fell through to the global function (a
  `Function` value → `get_field lastIndex on Function`). `get_field` now probes
  the enclosing implicit receiver (`this@Outer`) for a real (non-callable)
  property *before* the top-level lookup when that global is callable — Kotlin's
  rule that an implicit-receiver member outranks a top-level function. The
  legitimate `const`/top-level path is untouched (only adopted when the
  enclosing yields a non-callable). Covered by
  `corpus/receiver_lambda_property_vs_global_fn.kt`.
- **Consumed verbatim:** `io.ktor.util.Text.kt`, the util collection layer
  (`Collections.kt` + a klio `unmodifiable` actual, `DelegatingMutableSet.kt`,
  `CaseInsensitiveMap.kt`, `StringValues.kt`), and the http layer
  (`HttpStatusCode`/`HttpMethod`/`HttpProtocolVersion`/`HttpHeaders`,
  `HttpHeaderValueParser`, `HeaderValueWithParameters`, `ContentTypes`,
  **`Headers`, `Parameters`**, plus the header helpers **`CacheControl`,
  `ContentTypeMatcher`, `HttpMessage`, `LinkHeader`, `RequestConnectionPoint`,
  `Ranges` (`RangeUnits`/`ContentRange`), `ContentRange` (the
  `contentRangeHeaderValue` fn), `RangesSpecifier`**). The hand-written
  `shim/.../ContentType.kt` is deleted. The upstream `ContentType` API (parse /
  withParameter / match / charset / parseHeaderValue), the full
  `Headers`/`Parameters` API, the header helpers, and **`ContentDisposition`**
  (parse / withParameter / `Parameters`) run; client+server smokes pass.
  `Charset`/`Charsets` is a klio actual (name + forName); byte-level
  encode/decode is added with the body layer. Covered end-to-end by
  `tests/ktor_http_value_types.rs`.

## Discovered latent bugs (pre-existing, not blocking ktor-http)

- **Companion-method codegen mis-lowers some `List` extension calls.** A plain
  companion-object method calling certain stdlib list extensions on a local
  (`segs.drop(1)` / `segs.take(1)` where `segs = value.split(...)`) lowers to a
  `CallValue` on the list (`call_value on kotlin.collections.List`). Shape- and
  expression-dependent; reproduces with **no** inline/`expect` involved.
  ktor-http's consumed code does not hit it (`HeaderValueWithParameters.parse`
  passes a `List` *property* through `init`, which works).
- **Typeck rejects named/reordered constructor args.** `corpus_typechecks_clean`
  is red on clean `main`: `Cfg(size = 5)` / `Cfg(on = true, name = "y")`
  (`corpus/ctor_named_default.kt`) report spurious `T0001` mismatches — the
  checker validates named args positionally without honouring the name→param
  reorder. Interpreter runs the program correctly (parity-green); only the
  type-check phase errs.

## Open blockers (next, in order)

1. **ktor-http remainder — `Url` / `URLBuilder`.** `Codecs.kt` is **consumed**
   (encode + decode): `encodeURLParameter`/`encodeURLQueryComponent`/
   `encodeURLPath` and `decodeURLPart`/`decodeURLQueryComponent` all run through
   the real pack (verified in `tests/ktor_http_value_types.rs`), backed by the
   charset `newEncoder()`/`encode()` actual + consumed ktor-io core
   (`Buffer.canRead`, `Source.takeWhile`) + five general interpreter fixes
   (`Range + Range`, top-level-fn-in-receiver-lambda, bare-ext receiver-match,
   `this@fn` in a nested receiver lambda, default-arg reads receiver).
   **Probe finding:** adding `Url.kt`/`URLProtocol.kt`/`URLBuilder.kt`/
   `URLParser.kt` to the pack builds and loads — `Url`'s
   `@Serializable(with = UrlSerializer::class)` annotation does **not** block
   consumption (it's tolerated; serialization infra is not needed just to
   construct/use `Url`). The actual blocker is `expect val
   URLBuilder.Companion.origin: String` (used by `private val originUrl =
   Url(origin)` in the companion): a klio `actual val
   URLBuilder.Companion.origin get() = "http://localhost"` is not picked up —
   the bare `origin` mis-resolved to `get_field(companion, "origin")`. **Fixed
   (landed):** `get_field` on a companion instance now also probes
   `extension_props` under the outer class name (the part before `$Companion`),
   so `URLBuilder.Companion.origin` (registered under `URLBuilder`) resolves.
   **Then blocked on** the `port = DEFAULT_PORT` primary-ctor default reading
   `Null` because `URLBuilder.Companion`'s eager `val originUrl = Url(origin)`
   runs at load before the top-level `const val DEFAULT_PORT` global is set —
   **also fixed (landed):** a primary-ctor default that is a bare top-level
   `const val` is resolved from the const registry at construction time.
   **Current blocker (narrowed):** pack load throws `BinOp::LessEq on Int(0)
   and Null` from `__init_block_Url_0` — `Url`'s `require(specifiedPort in
   0..65535)` with `specifiedPort == Null`. The chain is `URLBuilder.Companion`'s
   eager `val originUrl = Url(origin)` → `URLBuilder("http://localhost").build()`
   → `Url(specifiedPort = port)`, where the `URLBuilder`'s `port` is `Null`.
   Instrumentation showed: `get_field` is **never** called for `DEFAULT_PORT`
   (so it's not the parser's `port = DEFAULT_PORT` bare-ref path — the eager
   const-init covers that), and **neither** `new_instance` (the trailing-default
   pass) **nor** `new_instance_named` (the named-reorder const-resolution)
   probe fires for the `port` param — so `URLBuilder()`'s `port` ctor default
   (`= DEFAULT_PORT`) is filled by a *third* construction path. `URLBuilder`
   declares `port` as a `var port: Int = port` body property with a custom
   `set(value) { require(value in 0..65535); field = value }` setter plus
   `applyOrigin()` in `build()`. Next: locate where `URLBuilder()`'s primary-ctor
   param default is applied during body-property / setter construction (it
   bypasses both `new_instance*` default-fill probes) and resolve the
   `DEFAULT_PORT` default there. Then `Url` / `URLBuilder` / `URLParser` consume
   (serialization not required; `origin`, `DEFAULT_PORT`-as-bare-ref, and
   primary-ctor const defaults are already handled).
2. **Layer 2 — Pipeline runtime** (`Pipeline`/`PipelineContext`/`SuspendFunctionGun`
   + `createPlugin`/`EventDefinition`), the spine of both cores.
3. **Cores on upstream**, engine staying klio-side.

## Status

The protocol foundation is consuming real upstream and the general fixes it needs
are landing. The remaining path is a deliberate multi-step program: the Map
key-equality change, then the ktor-http remainder, then the Pipeline runtime for
the cores. The shim stays in place so client/server keep working until each
layer's upstream replacement is validated.
