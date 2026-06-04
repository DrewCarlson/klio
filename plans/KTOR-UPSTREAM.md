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

## Status

Foundation + Layer-0 groundwork started. Layers 0–1 are mechanical once the
actuals exist; Layer 2 (Pipeline runtime) is the gating interpreter work for the
full client/server. The shim remains in place until each layer's upstream
replacement is validated, so functionality does not regress mid-migration.
