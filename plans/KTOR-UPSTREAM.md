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

## Open blockers (next, in order)

1. **Custom-collection iterator stack.** ktor's `Headers` sits on
   `CaseInsensitiveMap` → `DelegatingMutableSet` → an anonymous
   `MutableIterator` whose `val delegateIterator = delegate.iterator()`
   property-initializer isn't materialized (drain hits `hasNext on Nothing`).
   Needs anonymous-object captured-property-init support; the same stack
   recurs for the keys/entries/values views.
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
