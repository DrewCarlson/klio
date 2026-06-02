# Intrinsics → common Kotlin migration plan

Today there are ~973 Rust intrinsics registered in
`crates/klio-stdlib/src/implementations.rs`'s `TABLE`. Many of those have
pure-Kotlin upstream definitions and only exist as Rust because of
historical bring-up; we want the interpreter to consume the real common
Kotlin definitions wherever possible so the language surface stays in
sync with upstream without per-bump Rust patches.

The precedent is already in place: `kotlin.time` and `kotlin.coroutines`
ship from upstream commonMain via
`crates/klio-stdlib/src/pack_builder.rs`'s `CURATED_UPSTREAM_SOURCES`,
and the recent `kotlin.collections.List` / `MutableList` size-init
factories ship from `crates/klio-stdlib/kotlin-collections/Builders.kt`.

## Migration tiers

### Tier 1 — universal utilities (≈15 intrinsics, zero hidden deps)

All have pure `public inline fun` upstream bodies that only invoke other
intrinsics already available.

**Scope functions** — `kotlin/util/Standard.kt`
- `kotlin.let`
- `kotlin.run`
- `kotlin.apply`
- `kotlin.also`
- `kotlin.with`
- `kotlin.takeIf`
- `kotlin.takeUnless`
- `kotlin.repeat`

**Preconditions / contracts** — `kotlin/util/Preconditions.kt`
- `kotlin.require`
- `kotlin.check`
- `kotlin.requireNotNull`
- `kotlin.checkNotNull`

**Resource use** — `kotlin/io/Closeable.kt` *(blocked — see Underlying issues)*
- `kotlin.io.use`
- `kotlin.AutoCloseable.use`
- `java.io.Closeable.use` (alias)

### Tier 2 — depend on other utilities (≈7 intrinsics)

- String predicates: `kotlin.String.isBlank`, `isNotBlank`, `isEmpty`,
  `isNotEmpty`, `ifBlank`, `ifEmpty` — depend on char predicates +
  `all`/iteration over `CharSequence`.
- `kotlin.lazy` / `kotlin.lazyOf` — depend on a `Lazy<T>` interface
  declaration and field-stored callables (klio's object model supports
  both, but the migration touches more surface).

### Tier 3 — architecture-blocked (≈150 intrinsics)

Iterable/Collection extension functions: `filter`, `map`, `fold`, `zip`,
`drop`, `take`, `chunked`, `windowed`, `flatMap`, …

Upstream bodies are pure Kotlin (e.g.
`inline fun <T> Iterable<T>.filter(p) = filterTo(ArrayList<T>(), p)`)
but klio's `List`/`Set`/`Map` are Rust-native `Value::List(ObjRef<Vec<Value>>)`.
Porting requires Kotlin-facing wrapper types over those `ObjRef`s, or
exposing upstream `ArrayList`/`HashMap`/`HashSet` against klio's runtime
containers. Worthwhile long-term refactor, not a single-PR change.

## Correctly kept as intrinsic (~800)

- Numeric/bitwise ops on primitive `Int`/`Long`/etc.
- `kotlin.math` transcendentals (`sqrt`, `sin`, `exp`, …)
- I/O (`print`, `println`, `readLine`)
- Threading / sync (`synchronized`, `Thread.sleep`, `Thread.currentThread`)
- Platform clocks (`__klio_time_systemMillis`, `__klio_time_monotonicNanos`)
- Exception constructors (instantiate `Value::Exception`)
- Collection indexing / mutation on the Rust-backed containers
- Char classification (`isDigit`, `isLetter`, `isWhitespace`)

## Per-pack audit

All pack `host_bindings` are appropriately scoped to platform-only
`expect`/`actual` hooks. No redundant reimplementation of pure Kotlin
detected in atomicfu, coroutines, datetime, io, serialization, or
ktor-client.

## Per-migration checklist

1. Drop a curated `.kt` source under `crates/klio-stdlib/kotlin-<topic>/`
   carrying the upstream definition verbatim (or the smallest viable
   excerpt — same pattern as `kotlin-collections/Builders.kt`).
2. Append the path to `KLIO_STDLIB_ACTUAL_FILES` in
   `crates/klio-stdlib/src/pack_builder.rs`.
3. Delete the corresponding `TABLE` entry in
   `crates/klio-stdlib/src/implementations.rs` and any now-unused Rust
   impl fn.
4. Run `cargo build -p klio-stdlib-pack` to force a stdlib rebuild.
5. Run `cargo test --workspace` + parity sweep.
6. Run a sample program that exercises the migrated surface end-to-end
   through `klio run`.

## Underlying issues surfaced during Tier 1

- `inline fun` with two generic type parameters that wraps a
  `try { ... } finally { ... }` block duplicates the `finally`
  body at expansion time. Reproducer is a stripped-down
  `inline fun <T : AutoCloseable, R> T.scoped(block: (T) -> R): R`:
  the body's `close()` runs twice on the no-throw path. Single-
  generic and non-inline forms are unaffected. This blocks
  migrating `kotlin.AutoCloseable.use` to common Kotlin —
  parking it on the intrinsic path until the IR inline lowering
  is fixed.

## Status

- [x] Audit — landed.
- [x] Tier 1 — scope functions + preconditions + `use`. The inline
  `try`/`finally` bug that blocked `use` was fixed in
  `crates/klio-ir/src/eval.rs` (synthesized finally-done sentinel +
  inline-return finally replay).
- [x] Tier 2 — string emptiness/blankness predicates +
  `kotlin.Lazy<T>` interface, `UnsafeLazyImpl`, `InitializedLazyImpl`,
  `lazy { … }`, `lazyOf(v)`, and the `Lazy<T>.getValue` operator
  extension that makes `val x: T by lazy { … }` route through the
  Lazy instance.
- [ ] Tier 3 — Iterable / Collection / Map extension functions
  (`filter`, `map`, `fold`, `zip`, `drop`, `take`, `chunked`,
  `windowed`, `flatMap`, …). Architecture-bound by a different
  constraint than the audit predicted: the bodies themselves
  *do* express in pure Kotlin against klio's existing
  `for (x in this)` + `dest.add(x)` surface (verified end-to-end
  on a pilot at `9cb8563`, reverted at `91d53a6`). The blocker is
  *dispatch*: the upstream `kotlinx-coroutines-core` pack defines
  `Flow<T>.forEach` / `.map` / `.filter` / `.filterNotNull` /
  `.any` / `.all` / `.none` / `.count` (some real, some
  `Migration.kt` `noImpl()` deprecation stubs), all reachable as
  top-level extensions in the global func index. klio's bare-call
  dispatch resolves a `forEach { … }` inside an inline-spliced
  lambda body (including the pack's own
  `Iterable<T>.asFlow() = flow { forEach { emit(it) } }`) through
  `Module::func_id` — a name-keyed lookup with no receiver-type
  awareness. Adding an `Iterable<T>` overload of any of those
  names introduces an ambiguous candidate set and the bare call
  picks the wrong one (specifically the pack's `Flow<T>.forEach`
  stub → `noImpl()` throw, observed on
  `crates/klio-parity/tests/coroutine_smoke/cs5_flow_builder.kt`).
  The fix is genuine receiver-type-aware overload resolution at
  the IR build / `pick_overload` seed for bare calls — the
  call-site already has the receiver type in scope (it just isn't
  consulted before `func_id` returns).
