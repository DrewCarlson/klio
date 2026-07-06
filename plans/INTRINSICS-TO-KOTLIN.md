# Intrinsics → common Kotlin migration plan

Many Rust/Zig intrinsics have pure-Kotlin upstream definitions and only exist as intrinsics because of historical bring-up. Where possible the interpreter should consume the real common Kotlin definitions so the language surface stays in sync with upstream without per-bump patches. The precedent: `kotlin.time` / `kotlin.coroutines` ship from upstream commonMain via `CURATED_UPSTREAM_SOURCES`, and the `List` / `MutableList` size-init factories ship from a curated `.kt`.

## Completed

- **Tier 1 — universal utilities.** Scope functions (`let`/`run`/`apply`/`also`/`with`/`takeIf`/`takeUnless`/`repeat`) and preconditions (`require`/`check`/`requireNotNull`/`checkNotNull`) now ship from curated upstream Kotlin: `CURATED_UPSTREAM_SOURCES` in `src/stdlib/stdlib_sources.zig` lists `src/kotlin/util/Standard.kt` and `src/kotlin/util/Preconditions.kt`. The inline `try`/`finally` double-run bug that had blocked `use` was fixed (synthesized finally-done sentinel + inline-return finally replay).
- **Tier 2 — utility-dependent.** String emptiness/blankness predicates plus the `Lazy<T>` interface, `lazy { … }` / `lazyOf(v)`, and the `Lazy<T>.getValue` operator that routes `val x by lazy { … }` through the Lazy instance. Ships via `kotlin-util/LazyActuals.kt`, appended to `KLIO_STDLIB_ACTUAL_FILES` in `src/stdlib/stdlib_sources.zig`.

## Tier 3 — architecture-blocked (≈150 intrinsics)

Iterable/Collection/Map extension functions: `filter`, `map`, `fold`, `zip`, `drop`, `take`, `chunked`, `windowed`, `flatMap`, …

The bodies themselves *do* express in pure Kotlin against klio's existing `for (x in this)` + `dest.add(x)` surface (verified end-to-end on a reverted pilot). These remain Zig intrinsics in `src/stdlib/implementations/collections.zig`.

The blocker is **dispatch, not the bodies**: klio's bare-call resolution is a name-keyed lookup with no receiver-type awareness. The upstream `kotlinx-coroutines-core` pack defines `Flow<T>.forEach` / `.map` / `.filter` / `.filterNotNull` / `.any` / `.all` / `.none` / `.count` (some real, some `Migration.kt` `noImpl()` deprecation stubs), all reachable as top-level extensions in the global func index. A `forEach { … }` inside an inline-spliced lambda body (including the pack's own `Iterable<T>.asFlow() = flow { forEach { emit(it) } }`) resolves by name with no receiver-type awareness. Adding an `Iterable<T>` overload of any of those names introduces an ambiguous candidate set and the bare call picks the wrong one (the pack's `Flow<T>.forEach` stub → `noImpl()` throw, observed on the `cs5_flow_builder` coroutine smoke test).

The fix is genuine receiver-type-aware overload resolution at the IR build / bare-call overload seed: the call-site already has the receiver type in scope; it just isn't consulted before the name-keyed lookup returns. Worthwhile long-term refactor, not a single-PR change.

## Correctly kept as intrinsic (~800)

- Numeric/bitwise ops on primitive `Int`/`Long`/etc.
- `kotlin.math` transcendentals (`sqrt`, `sin`, `exp`, …).
- I/O (`print`, `println`, `readLine`).
- Threading / sync (`synchronized`, `Thread.sleep`, `Thread.currentThread`).
- Platform clocks (system-millis, monotonic-nanos).
- Exception constructors (instantiate the runtime exception value).
- Collection indexing / mutation on the native-backed containers.
- Char classification (`isDigit`, `isLetter`, `isWhitespace`).

## Per-migration checklist

1. Drop a curated `.kt` source (the upstream definition verbatim, or the smallest viable excerpt) under the curated-source tree (e.g. `src/kotlin/<topic>/`) or a klio actual under `kotlin-<topic>/`.
2. Register it: append the path to `CURATED_UPSTREAM_SOURCES` (upstream verbatim) or `KLIO_STDLIB_ACTUAL_FILES` (klio actual) in `src/stdlib/stdlib_sources.zig`.
3. Delete the corresponding intrinsic entry in `src/stdlib/implementations/…` and any now-unused impl fn.
4. Rebuild the stdlib image.
5. `zig build test-all` + parity sweep.
6. Run a sample program that exercises the migrated surface end-to-end through `klio run`.
