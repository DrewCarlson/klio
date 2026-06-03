# Pack Completion Roadmap

Goal: take klio's six library packs (`kotlinx.io`, `io.ktor.client`,
`kotlinx.coroutines`, `kotlinx.datetime`, `kotlinx.serialization`,
`kotlinx.atomicfu`) to full real-API support — the API surface a real
developer writes against the published libraries, verified by running
unmodified real-API programs through `klio check` and `klio run`.

This roadmap is built from adversarially-verified probe evidence. Status
labels: **missing** (no surface), **stub** (resolves, returns `Unit` /
unimplemented), **diverged** (resolves to wrong type/shape, klio-only
names, or shadowed by a colliding symbol), **partial** (works for some
inputs / hangs / breaks on the idiomatic form).

Effort key: **S** ≈ <½ day, **M** ≈ 1–2 days, **L** ≈ 3–5 days,
**XL** ≈ 1–2 weeks. Both = needs interpreted-Kotlin (`klioMain` /
include-list) *and* Rust host bindings (`src/lib.rs`).

---

## 1. Current state

| Pack | Verified coverage | Biggest gap | Headline |
|------|------------------:|-------------|----------|
| `kotlinx.io` | ~80% | A few `files/` edges (`Path(dir, name)` builder, `list`) hit separate dispatch bugs; named-arg to an anon-object override | Buffer/Source/Sink read+write+scan (`readString`/`readLine`/byte ops/decimal/hex), ByteString, and the `files/` package (Path + SystemFileSystem create/write/read/append/metadata/delete/mkdirs) all work |
| `io.ktor` | ~60% | HttpStatusCode/Headers types still thin; no plugins beyond ContentNegotiation | Client and server both work end-to-end with serialization-backed JSON, and the pack is split into cargo-style features along its Gradle modules: core (`io.ktor.http`) loads by default; `client`, `server`, `client-serialization`, `server-serialization` are opt-in via `--feature io.ktor/<name>`. Client: `HttpClient { install(ContentNegotiation) { json() } }`, `body<T>()` / `setBody<T>()`, builder DSL. Server: `embeddedServer(CIO, port) { routing { get/post { call.respond/receive<T>() } } }` over a native blocking accept loop. Both smoke-tested against a live socket |
| `kotlinx.coroutines` | ~55% | StateFlow/SharedFlow `collect` and the whole `ChannelFlow` family crash; structured-concurrency exception isolation broken | Launch/async/await/delay/Channel suspend-send/Mutex/Flow basics solid; hot flows, `produce`/`channelFlow`, `select`, supervisor scopes, ChannelResult all broken |
| `kotlinx.datetime` | ~30% | Every `expect` arithmetic/`until`/companion-factory has no actual → returns `Unit`; no `kotlin.time` subsystem | Construction + property access + tz conversion work; date arithmetic, `parse`, `daysUntil`/`periodUntil`, formatting, and the `Month`-enum constructor all stub out |
| `kotlinx.serialization` | ~55% | No `builtins`, no `modules`; polymorphism + descriptor DSL still thin | JSON encode/decode works: `Json.encodeToString` / `decodeFromString` over primitives, nullable, enums, nested `@Serializable`, `List<T>`, `Map<String,T>` at any depth, with `prettyPrint`/`ignoreUnknownKeys` and declaration-order keys. Reflective `KSerializer` round-trip works; collection/map serializers, polymorphism, `SerializersModule` still absent |
| `kotlinx.atomicfu` | ~60% | Atomic arrays shadowed by colliding `kotlin.concurrent.atomics`; no `locks` package | Full scalar atomic surface (Int/Long/Boolean/Ref CAS+RMW+delegation) works; arrays, locks, `SynchronousMutex`, Trace DSL broken |

Coverage % is a rough "fraction of the public API a real program would
reach without hitting a verified gap", anchored to the probe logs.

---

## 1b. Progress & corrections (verified against the binary)

Landed (all on `main`, each verified through the binary / kotlinc-diff
corpus): array `copyInto`/`copyOf`/`copyOfRange`/`fill`, array
`sort`/`sortWith` + `MutableList.reverse` (cascading to `sortedArray` /
`sortDescending` / `reversed` / `sortedDescending`), `String`↔`ByteArray`
UTF-8 (`encodeToByteArray`/`toByteArray`/`decodeToString` + the
`String(ByteArray)` constructor), string concatenation dispatching an
instance's `toString()`, kotlinx.datetime `LocalDate` arithmetic
(`plus`/`minus`/`daysUntil`/`monthsUntil`/`yearsUntil`/`periodUntil` +
navigators), and **named + defaulted constructor arguments** for primary
*and* secondary constructors (was: named/omitted params left Null).

Resolution/dispatch fixes since: **B7 atomicfu arrays** — dropped the
unused `kotlin.concurrent.atomics` array `expect`s so they stop
ambiguating `kotlinx.atomicfu.AtomicIntArray` / `atomicArrayOfNulls`;
**companion-on-actual-class** — an `expect class` superseded by an
`actual` was lifted before the supersession retain, so its bodyless
companion collided with the actual's; now skipped, and
`LocalDate.parse` / `fromEpochDays` work. Also added **LocalTime /
LocalDateTime parse companions** (riding the same fix) and the
**`kotlinx.atomicfu.locks`** package (ReentrantLock / SynchronizedObject
/ synchronized / SynchronousMutex — trivial uncontended shims, no host
bindings, since the runtime is single-threaded).

Still open (needs careful design, not a quick patch):
- **bare 0-arg `println()` inside a receiver lambda prints the receiver**
  (`runBlocking { println() }` → `GlobalScope`). Specific to a host
  *intrinsic* with a 1-arg overload (a module function with the same
  shape resolves correctly): `println` has no module `func_id`, so the
  call lowers to `CallMemberOrGlobal`, and somewhere on that path the
  receiver reaches the 1-arg `println(Any?)` form. Minor (only the
  no-arg form), but lives in the same sensitive bare-call dispatch.
- **kotlinx.io `readByteArray` / `readTo(ByteArray)` — FIXED.** Root was
  overload resolution: `pick_method_overload` accepted a lone same-named
  member without an arity check, so `buffer.readTo(byteArray)` bound the
  inapplicable member `Buffer.readTo(RawSink, byteCount: Long)` (padding
  `byteCount` with Unit) instead of the extension `Source.readTo(
  ByteArray, …)`. Now a lone member is declined when an unsupplied param
  is neither defaulted nor vararg, so the extension wins.
- **Multi-level exception hierarchies — FIXED.** `run_super_ctor_chain`
  resolved each `super(...)` from the *leaf*'s immediate parent, so
  `EOFException : IOException : Exception` (and any 2-level user
  exception) recursed forever and overflowed the stack. That crash also
  hid behind `Buffer.require(byteCount > size)` (throws EOFException) and
  the kotlinx.io read fallbacks. Now resolved from the current class's
  parent; `require(>size)` throws + is catchable, EOFException builds.
- **Exception messages through `super(...)` — FIXED (all paths).**
  Primary-ctor chains (`NotFound : AppError : RuntimeException`),
  secondary-ctor chains (`constructor(m) : super(m)`), and kotlinx.io's
  `IOException` / `EOFException` now all carry their message. Root: a
  kotlin-builtin Throwable's ctors are bodyless expect shells that drop
  the super-args; bind message/cause directly when the chain (primary
  parent-ctor walk *and* `run_super_ctor_chain`) reaches a builtin
  Throwable. Verified byte-identical to kotlinc.
- **kotlinx.io `readString(byteCount)` / `readLine` hang — ROOT-CAUSED and
  the catastrophic part FIXED (commit `resolve unqualified calls against
  receiver members and by declared arity`).** The earlier "bypasses all
  dispatch entry points" note was a measurement error: the depth counter
  never decremented, so it measured cumulative calls, not recursion depth.
  Instrumenting the *global allocator* (custom `GlobalAlloc`, dump
  backtrace past a live/churn threshold) showed the truth — a runaway of
  deep recursion through `call_func → eval_with → run_frame → exec_inst →
  call_func`, each level cloning a `Func`, exhausting memory (RSS, not a
  CPU spin). Two chained root causes:
  1. **Extension-receiver member resolution.** `Source.readString(byteCount:
     Long)` calls `require(byteCount)`. The `Long` argument is incompatible
     with `kotlin.require(value: Boolean)`, so Kotlin binds the receiver
     member `Source.require(Long)`. klio bound the top-level
     `kotlin.require` instead (unqualified calls did not consider the
     extension receiver's members). Fixed: an unqualified call inside an
     extension now resolves against the receiver's members first (merged
     cross-file via `registry.hierarchy_methods`), declining the top-level
     bind so the member-call fallback dispatches on `this`.
  2. **Forward-reference overload resolution.** The stdlib 1-arg
     `require(value)` delegates to the 2-arg `require(value) { … }`
     declared *below* it. At body-lowering the 2-arg sibling was still a
     body-less stub with empty params, so arity matching failed and the
     call bound to the *first* same-named overload — the 1-arg `require`
     itself — baking an infinite self-call. Fixed: the driver records each
     decl's user-param arity in a stub-pass side table
     (`Module::decl_user_params`); the bare-call resolver prefers an
     arity-correct overload over the arity-blind `func_id` fallback.
  Regression test: `extension_member_resolution.rs`. With both fixes the
  OOM hang is gone; `readString(3L)` now runs (errors/segfaults on the
  *next* bugs below instead of exhausting memory).
  `readString(byteCount)`, `readString()`, and `readLine()` all run
  correctly now (regression tests in `kotlinx_io_read.rs`). Three further
  dispatch bugs surfaced once the hang was gone, each fixed in turn:
- **Array constructors prepended the receiver inside an extension —
  FIXED.** `byteArrayOf(…)` (a pure intrinsic with no IR func) called bare
  inside an extension body reached the runtime member-probe, which
  resolved the *top-level* `kotlin.byteArrayOf` with the receiver
  prepended (`byteArrayOf(this, …)`). Fixed: these builders
  (`klio_stdlib::is_array_builder`) dispatch the global intrinsic directly
  with the original args, before the receiver-prepend probe, when the
  receiver does not declare the member.
- **Bare `min`/`max` bound a receiver-extension under the full corpus —
  FIXED.** `lookup_global` suffix-scanned the installed-bindings overlay
  for any key ending in `.{name}` *before* the package-ordered probes;
  with the stdlib defaults in the overlay, bare `min` matched
  `kotlin.DoubleArray.min` and ran `min(a, b)` as `a.min(b)`. Fixed: the
  suffix-scan now runs after `direct_probes`, and the probes order the
  top-level packages (`math`, `comparisons`, `io`) before the
  receiver-extension packages.
- **`b.readLine()` bound the console reader — FIXED.** Member dispatch
  probed `kotlin.io.{name}`, matching the top-level `kotlin.io.readLine`
  (console, not an extension) and dispatching it against the buffer (→
  empty-stdin null). Fixed: those probes are skipped when a genuine
  extension named `name` exists on the receiver's own type chain
  (`fun Source.readLine()` for a `Buffer`).
- **`recv.name(args)` where a user/pack extension's name collides with a
  stdlib intrinsic registered for a *different* receiver** (e.g.
  `LocalDate.until` / `String.until` vs `kotlin.ranges.until`). The
  extension-*receiver*-member case is now handled at lowering (see above);
  the remaining hard case is a qualified `recv.name(args)` where `name` is
  a user extension colliding with a same-name intrinsic on another
  receiver category. klio probes intrinsics speculatively by
  `kotlin.{ranges,collections,text}.{name}` for *any* receiver; a runtime
  guard preferring a matching user extension over-fires. The right fix is
  compile-time extension resolution (target the FuncId in the IR) or
  receiver-category-aware probes.

**`kotlinx.io.files` implemented.** `Path` + `SystemFileSystem` backed by
host `std::fs` (`__kxio_*` bindings). create/write/read/append/metadata/
delete/mkdirs/exists/readLine all work through the real binary + installed
pack. Implementing it surfaced and fixed three general interpreter gaps:
mixed Int/Long ranges, `expect val` supersession by an `actual`, and
interface-declared default args filled for an anonymous-object override.
Three edge bugs remain (each general, not files-specific):
- **`Path(base: Path, vararg parts)` builder.** Its body `Path(base.toString(),
  *parts)` — the pack-lowered `base.toString()` returns the default
  `Type@hash` rather than the `actual` override, although `base.toString()`
  in user code and inside other klioMain methods dispatches correctly. So
  `Path(dir, name)` drops the dir's real text. Workaround in the `list`
  override (build via `Path(dir.toString(), name)`); user code should use
  `Path("$dir/$name")` until fixed.
- **`SystemFileSystem.list`.** A `copyCount` field-read on a `String`
  surfaces (the io pack's `KlioCopyTracker` / Segment copy-tracker), a
  Segment-sharing bug triggered by list's `map`-over-host-`List<String>`
  after a sink. Other list-free file ops are unaffected.
- **Named arg to an anonymous-object override.** `fs.sink(p, append=true)`
  drops the named value before the anon dispatch (arrives as `[p]`, not
  `[p, true]`); positional `fs.sink(p, true)` works. The anon method lives
  in a per-object sub-module that `call_member_named`'s class-hierarchy
  reorder walk does not cover.

Re-verifying the top blockers against `target/release/klio` corrected
two of them and root-caused a third.

- **B1 is a misdiagnosis — `klio check` is *slow*, not hung.** A trivial
  `fun main(){}` takes ~15 s under `check`; importing kotlinx.io ~29 s;
  kotlinx.coroutines ~44 s. `check` re-resolves and re-typechecks the
  entire pack source corpus on every invocation, so the audit's short
  per-probe timeouts read slowness as an infinite loop. `klio run` skips
  the resolver/typeck pass entirely (straight to IR build), which is why
  it never hangs. The real B1 work is **incremental/cached pack
  resolution for `check`**, not a deadlock fix. (Bad imports are still
  not diagnosed — `run` silently ignores them, `check` exits 0 — that is
  the real B2.)

- **B8 is root-caused and fixed.** The cause was broader than "ByteArray
  copy no-op": the stdlib declares `copyInto` / `copyOf` / `copyOfRange`
  / `fill` as `expect fun` with no klio `actual`, so every one silently
  no-opped on *all* array types — and `String.encodeToByteArray` /
  `toByteArray` and `ByteArray.decodeToString` were missing the same
  way. Added host intrinsics for the whole family (signed + unsigned
  primitive arrays + `Array<T>`) in `klio-stdlib`. **Verified fixed:**
  `Buffer.write(ByteArray)` + `readString`, `readAtMostTo(ByteArray)`,
  `encodeToByteString`, `ByteString.decodeToString`/`substring`/
  `toByteArray`, and the bulk array ops themselves. Covered by
  `klio-stdlib` unit tests, `klio-parity/tests/array_bulk_ops.rs`, the
  `array_bulk_copy` corpus entry, and `examples/array_bytes.kt` (the
  corpus + example are byte-identical to `kotlinc`).

- **B8 follow-on: array `sort` / `reverse` family fixed.** The same
  `expect`-with-no-`actual` no-op class hid the entire in-place sort
  surface: `Array<T>.sort()` / primitive `sort()` / `sort(from, to)` and
  `Array<T>.sortWith(comparator)` all silently no-opped, and
  `MutableList.reverse()` did nothing — which in turn broke the
  interpreted `Array.reversed()` / `IntArray.sortedDescending()` bodies
  (`copyOf().apply { sort() }.reversed()`). Added host actuals for
  `array.sort`/`sortWith` (natural order + user `Comparable` via the
  host-aware `compareTo` path that `List.sorted` uses) and
  `MutableList.reverse`. One fix each cascaded to `sortedArray`,
  `sortDescending`, `sortedArrayDescending`, `reversed`, and
  `sortedDescending`. Covered by unit + parity tests and the
  `array_bulk_copy` corpus entry (byte-identical to `kotlinc`).

New, narrower gaps surfaced while landing B8 (next, not yet fixed):

- **Named arguments no-op on intrinsic / `expect` calls.** `copyInto(b,
  destinationOffset = 1, startIndex = 0, endIndex = 3)` silently does
  nothing while the positional form works — klio doesn't bind named args
  to a host-bound/`expect` signature, so the call falls to the no-op
  `expect` body. Language-wide; kotlinx-io's internal calls are
  positional, so the hot path is unaffected.
- **`Buffer.readByteArray()`** trips `BinOp::GreaterEq on Unit` inside
  `Buffer.request(byteCount)` (`require(byteCount >= 0)`, `byteCount`
  arriving as `Unit`) — a Long-parameter / Buffer-internals bug distinct
  from the copy intrinsics.
- **`String(ByteArray)` constructor** still returns blanks (the
  ByteArray-taking `String` constructor path, separate from
  `decodeToString`).
- **Parity-harness vs binary resolution divergence for kotlinx-io.** The
  parity harness loads kotlinx-io from source; its package-internal
  `minOf(Int, Int)` adapter resolves differently there than in the
  binary's pre-built pack (the `Buffer.write` round-trip works under
  `klio run` but not the from-source harness). Worth a dedicated fix so
  the harness mirrors the binary.

---

## 2. Cross-cutting blockers (ranked by leverage)

These are interpreter / pack-infrastructure defects whose fixes each
unblock work across multiple packs. They are the highest-value targets.

### B1 — Resolver/typeck hangs on an unresolved *member* of a known package
*Unblocks: every pack. Severity: P0.*
Importing a non-existent leaf symbol from a resolvable package prefix
(`import kotlinx.io.bytestring.doesNotExistAtAll`, `import
kotlin.collections.thisDoesNotExistEither`) causes `klio check` **and**
`klio run` to hang forever instead of emitting a diagnostic. Controls
confirm this is specific: an unresolved *whole package* gives clean
`R0003`, a bare unresolved identifier gives `UNRESOLVED_REFERENCE`. This
infinite loop is what masquerades as "Base64/Hex missing" in
`kotlinx.io`, and it sabotages every probe against a partially-stubbed
package. Must be fixed first so all other work produces actionable
diagnostics instead of timeouts. Resolver entry: `crates/klio-resolver/src/lib.rs`
(import resolution around lines 300–360).

### B2 — `klio check` false-negatives on pack-instance member access and member imports
*Unblocks: io.ktor.client, kotlinx.io, kotlinx.serialization (developer trust). Severity: P0.*
Unresolved member *calls* on pack-defined instance types pass `klio
check` silently and only fail at runtime with a generic `IR eval: not
yet implemented: Vm::call_member X on <instance>`. Verified for ktor
`put()`/`parameter()`/`setBody()`/`body()`/`bodyAsChannel()` and a
deliberately-bogus `c.zzzNotAMethod(...)`. Likewise member-imports of
non-existent members from a shim-created package node
(`import io.ktor.http.Headers`, `import io.ktor.client.call.body`) are
accepted. Root cause: member access on a pack-instance value is treated
as an unchecked/unknown receiver during typecheck. Every pack's "klio
check passes silently" note traces here. Typeck entry:
`crates/klio-typeck/src/check.rs`.

### B3 — `kotlin.time` subsystem (Duration / Instant / Clock) is absent
*Unblocks: kotlinx.datetime (Instant arithmetic, DateTimePeriod, DateTimeUnit.duration), kotlinx.coroutines (Duration-typed delays/timeouts the idiomatic way). Severity: P0 for datetime.*
The datetime `klio.toml` explicitly documents this as "the single
blocker for Instant/Clock/DateTimePeriod/DateTimeUnit". `Clock.System.now()`
works today via a host binding, but real `Instant.plus(DateTimePeriod,
TimeZone)` breaks on `toComponents`, and the whole `kotlin.time.Duration`
builder surface (`.seconds`, `.nanoseconds`) is unavailable. A proper
`kotlin.time` shim lets datetime consume upstream `Instant.kt` /
`Clock.kt` / `DateTimePeriod.kt` / `DateTimeUnit.kt` instead of
klio-only `plusPeriod`/`minusPeriod` divergences.

### B4 — `ChannelFlow` / `ProducerScope` context plumbing is broken
*Unblocks: kotlinx.coroutines `produce`, `channelFlow`, `combine`, `zip`, `debounce`, `sample`, `shareIn`, `stateIn`, hot-flow collection. Severity: P0.*
A single mechanism — the channel-coroutine `CoroutineContext` is cast to
the wrong type (`cast to CoroutineContext failed`, `cast to Map failed`,
`cast to DeepRecursiveFunctionBlock failed`) — sinks `produce {}`,
`channelFlow {}`, and every flow operator built on top of them, plus the
`shareIn`/`stateIn` stubs. One fix in the ChannelFlow/select context
machinery cascades to ~10 verified gaps.

### B5 — Structured-concurrency failed-completion state machine crashes
*Unblocks: kotlinx.coroutines CoroutineExceptionHandler, supervisorScope, SupervisorJob, awaitAll, Job.children. Severity: P1.*
Any coroutine that completes exceptionally trips `IllegalStateException:
Job ... is already complete or completing, but is being completed with
CompletedExceptionally[... Exception while trying to handle coroutine
exception]`. The handler is never invoked and siblings never get
isolated. The same broken completion path also double-completes
`Deferred` in `awaitAll`. Fixing the exceptional-completion handshake
unblocks the entire exception/supervision surface.

### B6 — Pack-defined receiver-lambda parameters don't bring receiver members into implicit scope
*Unblocks: io.ktor.client builder DSL (the only idiomatic call form), any pack DSL. Severity: P1.*
A pack-defined extension whose parameter is a receiver-typed lambda
(`HttpRequestBuilder.() -> Unit`) does not put the receiver's members in
implicit scope at the user call site: `client.get(url){ header(...) }`
fails with `UNRESOLVED_REFERENCE header`. Bisected: the *identical*
construct defined in user code works, so the defect is specific to
lambda parameters of pack-loaded functions. Blocks every idiomatic ktor
builder call and any future pack DSL. Resolver/typeck scope handling for
pack-sourced function signatures.

### B7 — Name collision: stdlib `kotlin.concurrent.atomics` shadows `kotlinx.atomicfu`
*Unblocks: kotlinx.atomicfu arrays (AtomicIntArray/AtomicLongArray/AtomicArray/atomicArrayOfNulls). Severity: P1.*
`crates/klio-stdlib/src/pack_builder.rs` line 177 includes
`src/kotlin/concurrent/atomics/AtomicArrays.common.kt`, loading
`@ExperimentalAtomicApi` *expect* classes with no klio actual. An
explicit `import kotlinx.atomicfu.AtomicIntArray` binds to / ambiguates
with the stdlib symbol, yielding `T0004` arity errors, spurious `T0112`
opt-in errors, and `Vm::call_value on Unit` at runtime. Fix is in name
resolution / overload disambiguation (import should win), not in the
atomicfu pack.

### B8 — Systemic ByteArray <-> Segment copy is a no-op
*Unblocks: kotlinx.io bulk byte I/O (`write(ByteArray)`, `readAtMostTo`, `readByteArray`, `encodeToByteString`, `decodeToString`, `substring`). Severity: P0 for io.*
`Buffer.write(ByteArray)` updates `size` but leaves segment bytes zero;
`readAtMostTo(ByteArray)` returns the right count but copies nothing.
This single data-copy bug also breaks `readByteArray()`,
`encodeToByteString()`, `decodeToString()`, and `ByteString.substring()`.
The string write/read path is unaffected, isolating the bug to the
ByteArray copy intrinsic in the IR eval / segment layer.

### B9 — Unimplemented `Vm` member ops surface as internal errors, not Kotlin diagnostics
*Unblocks: developer experience across all packs. Severity: P2 (cross-cutting quality).*
`Vm::get_field X on <instance>`, `Vm::call_member X on KClass`,
`Vm::call_value on Nothing`, `not yet implemented: ...` leak raw
interpreter internals. Two are themselves real feature gaps worth
calling out: member dispatch on a `KClass` value (blocks every datetime
companion factory and `HttpMethod.Trace`) and `get_field` on an
`<instance>` (blocks `Buffer.snapshot`, ByteString members).

---

## 3. Prioritized work plan

Batches are ordered so blockers and P0s land before the features that
depend on them. Within a batch, tasks are independent unless noted.

### Batch 0 — Diagnostics correctness (unblocks all measurement)
The hangs and false-greens make every other batch hard to verify. Do
this first.

- **T0.1 Fix resolver hang on unresolved member of a known package** (B1).
  Approach: parser-or-typeck-fix in `crates/klio-resolver/src/lib.rs`.
  Effort: M. Packs: all.
  Accept: `import kotlinx.io.bytestring.doesNotExistAtAll\nfun main(){println("x")}`
  emits a clean unresolved diagnostic and exits non-zero within 1s (no
  timeout), under both `check` and `run`.
- **T0.2 Make `klio check` flag unresolved member access/imports on pack types** (B2).
  Approach: typeck-fix in `crates/klio-typeck/src/check.rs`.
  Effort: L. Packs: all (esp. ktor).
  Accept: `val c = HttpClient(); c.zzzNotAMethod()` and
  `import io.ktor.client.call.body` (which does not exist) each produce
  an `UNRESOLVED_REFERENCE`/`R0003`-class diagnostic at `check`, not a
  runtime `Vm::call_member` panic.
- **T0.3 Surface `Vm::*`/`not yet implemented` as actionable errors** (B9).
  Approach: rust-binding in interp-ir error formatting.
  Effort: S. Packs: all.
  Accept: a program hitting an unimplemented op prints a message naming
  the unsupported API and exits 1 (no raw `Vm::` internals).

### Batch 1 — kotlinx.io data-copy and termination (P0/P1)
Unblocks the entire bulk-byte and ByteString surface, mostly via one
intrinsic fix.

- **T1.1 Fix ByteArray <-> Segment copy** (B8).
  Approach: rust-binding/both in the segment/IR-eval copy path.
  Effort: M. Pack: kotlinx.io.
  Accept: `Buffer().apply{ write(byteArrayOf(72,101,108,108,111)) }`
  reads back `"Hello"`; `readAtMostTo(ByteArray(4))` fills `dst` with
  `ABCD`; `readByteArray()` returns the bytes (no `BinOp::GreaterEq on
  Unit` error).
- **T1.2 Fix line/decimal/hex scanners that infinite-loop**.
  Approach: interpreted-kotlin in `Utf8.kt` scanning logic (or the IR
  primitive it bottoms out on).
  Effort: M. Pack: kotlinx.io.
  Accept: `readLine()` over `"line1\nline2\n"` returns the two lines
  then null; `readDecimalLong()` over `"7"` returns 7;
  `readHexadecimalUnsignedLong()` over `"ff"` returns 255 — all within
  1s.
- **T1.3 Fix `Buffer.snapshot()` / `get_field head` on instance** (B9).
  Approach: rust-binding (implement `get_field` on instance for the
  internal `head` segment ref) + verify `buildByteString` method-ref
  path.
  Effort: M. Pack: kotlinx.io.
  Accept: `Buffer().apply{writeString("abc")}.snapshot().size` prints 3;
  `"hello".encodeToByteString().size` prints 5;
  `ByteString(72,105).decodeToString()` prints `"Hi"`;
  `ByteString(72,105).substring(0,1).size` prints 1.

### Batch 2 — kotlinx.io filesystem + ByteString codecs (P0/P1)
- **T2.1 Add `kotlinx.io.files` (FileSystem/Path/SystemFileSystem/SystemTemporaryDirectory)**.
  Approach: both — add the upstream `files/` subtree to `klio.toml`
  include + `klioMain` shim + Rust host bindings for fs ops.
  Effort: L. Pack: kotlinx.io.
  Accept: `SystemFileSystem.exists(Path("/tmp/klio_test_file.txt"))`
  runs and prints a Boolean; write-then-read of a temp file round-trips.
- **T2.2 Add public ByteString Base64/Hex surface**.
  Approach: both — include upstream `bytestring/.../Base64.kt`+`Hex.kt`,
  bind the public extensions (`ByteString.toHexString()`,
  `String.hexToByteString()`, `Base64.encodeToByteArray/decodeToByteString`).
  Effort: M. Pack: kotlinx.io. Depends on: B1 (so the missing-import no
  longer hangs).
  Accept: `ByteString(0x01,0x02,0xff.toByte()).toHexString()` prints
  `"0102ff"`.

### Batch 3 — kotlin.time subsystem (P0, cross-pack)
- **T3.1 Build `kotlin.time` shim: Duration + companion builders, Instant, Clock** (B3).
  Approach: both — `klioMain`/stdlib interpreted Kotlin over Rust host
  bindings (monotonic + wall clock, Duration arithmetic).
  Effort: XL. Packs: kotlinx.datetime, kotlinx.coroutines.
  Accept: `(5).seconds + 100.nanoseconds` prints a `Duration`;
  `Clock.System.now()` returns an `Instant`; `Instant.toComponents`
  resolves so datetime's real `Instant.plus(DateTimePeriod, TimeZone)`
  can be wired in T4.4.

### Batch 4 — kotlinx.datetime arithmetic, factories, constructors (P0/P1)
Depends on Batch 3 for the Instant operators; the rest is independent.

- **T4.1 Supply actuals for date arithmetic `expect`s**: `LocalDate.plus(DatePeriod)`,
  `plus(Long/Int, DateTimeUnit)`, `periodUntil`, `daysUntil`,
  `monthsUntil`, `yearsUntil`, `until`, `minus(LocalDate)`, and the
  `nextOrSame`/`previousOrSame`/`next`/`previous` navigators (they
  delegate to `plus`).
  Approach: both — `klioMain/Actuals.kt` bodies over host calendar
  arithmetic.
  Effort: L. Pack: kotlinx.datetime.
  Accept: `LocalDate(2024,1,1).daysUntil(LocalDate(2024,1,31))` prints
  30; `LocalDate(2024,6,15).plus(DatePeriod(years=1,months=2,days=3))`
  prints `2025-08-18`; `LocalDate(2024,1,1).until(LocalDate(2025,1,1),
  DateTimeUnit.MONTH)` prints 12 (not the stdlib Int `until`).
- **T4.2 Add companion factories**: `LocalDate.parse`/`fromEpochDays`/`orNull`,
  `LocalTime.parse`/`orNull`, `LocalDateTime.parse`/`orNull`.
  Approach: both — add `companion object` to each `klioMain` actual +
  host ISO parse bindings. (Also fixes `Vm::call_member on KClass` for
  these.)
  Effort: M. Pack: kotlinx.datetime.
  Accept: `LocalDate.parse("2024-06-15")` prints `2024-06-15`;
  `LocalTime.parse("14:30:00")` prints `14:30`.
- **T4.3 Fix `Month`-enum delegating-constructor argument bug** (B9-adjacent).
  Root cause: a delegating ctor arg that reads an enum property
  (`: this(year, month.number, day)`) evaluates to `Unit`. This is a
  general interpreter bug (minimal repro `constructor(x:Int,e:E,z:Int):this(x,e.number,z)`).
  Approach: interp-ir fix.
  Effort: M. Packs: kotlinx.datetime (+ language-wide).
  Accept: `LocalDate(2024, Month.JANUARY, 1)` prints `2024-1-1`;
  `LocalDate(2024,6,15).atTime(14,30)` prints the full datetime;
  the minimal delegating-ctor repro runs.
- **T4.4 Replace klio-only `plusPeriod`/`minusPeriod` with upstream `Instant.plus/minus(DateTimePeriod, TimeZone)`**.
  Approach: interpreted-kotlin — consume upstream `Instant.kt`/`DateTimePeriod.kt`
  once B3/T3.1 lands; drop the klio-invented names.
  Effort: M. Pack: kotlinx.datetime. Depends on: T3.1.
  Accept: the real-API probe `inst.plus(DateTimePeriod(months=2,days=3),
  tz).epochSeconds` runs (no `toComponents` failure).
- **T4.5 Fix `LocalDate(year, monthNumber, day)` overload ambiguity at `check`**.
  Root cause: deprecated top-level `LocalDate(Int, Int, Int)` /
  `LocalDate(Int, Month, Int)` overloads in the included upstream file
  make basic construction `T0091`-ambiguous.
  Approach: typeck-fix (overload resolution should prefer the primary
  ctor; deprecated overload should rank lower).
  Effort: M. Pack: kotlinx.datetime.
  Accept: `klio check` on `LocalDate(2024, 6, 15)` exits 0.

### Batch 5 — kotlinx.serialization builtins + descriptors (P0/P1)
- **T5.1 Add `kotlinx.serialization.builtins`**: `ListSerializer`,
  `SetSerializer`, `MapSerializer`, `PairSerializer`, `TripleSerializer`,
  primitive-array serializers, `KSerializer<T>.nullable`,
  `LongAsStringSerializer`, and correct primitive companion serializers
  (`Int.serializer()` must yield `PrimitiveKind.INT`/`kotlin.Int`, not
  the reflective `CLASS` kind).
  Approach: both — include upstream `builtins/`+collection/internal
  framework files; fix the `.serializer()` reflective special-case so
  primitives route to the real serializer.
  Effort: L. Pack: kotlinx.serialization.
  Accept: `ListSerializer(String.serializer()).descriptor.serialName`
  runs; `Int.serializer().descriptor.kind` prints `INT`;
  `String.serializer().nullable.descriptor.isNullable` prints `true`.
- **T5.2 Fix `buildClassSerialDescriptor` / `buildSerialDescriptor` + `element<T>()`** (B9-adjacent).
  Root cause: `SerialDescriptorImpl` construction hits `get_field length
  on kotlin.Nothing` (internal `compactArray`/`withIndex` helper); the
  reified `element<T>()` form also fails on unbound `T`.
  Approach: interp-ir fix + verify reified-generic path.
  Effort: M. Pack: kotlinx.serialization.
  Accept: `buildClassSerialDescriptor("Foo"){}.elementsCount` prints 0;
  a descriptor built with `element<Int>("x")` reports its element.
- **T5.3 Add `kotlinx.serialization.modules`**: `SerializersModule`,
  `EmptySerializersModule`, `SerializersModule { }` DSL,
  `SerializersModuleBuilder`, `serializersModuleOf`.
  Approach: interpreted-kotlin — include upstream `modules/`.
  Effort: M. Pack: kotlinx.serialization.
  Accept: `EmptySerializersModule()` and `serializersModuleOf(String::class,
  String.serializer())` run and print.
- **T5.4 Fix enum + nullable + KType serializer lookup**: `serializer<Color>()`
  must yield `SerialKind.ENUM` with element names; `serializer<String?>()`
  must yield `isNullable=true`; add the `serializer(KType)` and
  `serializer(KClass, List<KSerializer<*>>, isNullable)` overloads; fix
  `ContextualSerializer` (`EMPTY_SERIALIZER_ARRAY` internal dep).
  Approach: both — include `Enums.kt`/`PluginHelperInterfaces.kt`,
  implement `typeOf` intrinsic, extend `klioMain` lookup.
  Effort: L. Pack: kotlinx.serialization. Depends on: reified-generic
  fix shared with T5.2.
  Accept: `serializer<Color>().descriptor.kind` prints `ENUM`;
  `serializer<String?>().descriptor.isNullable` prints `true`;
  `ContextualSerializer(Foo::class)` constructs.

### Batch 6 — kotlinx.serialization JSON (P0, high developer value)
- **T6.1 Add `kotlinx.serialization.json` format module**: `Json`,
  `Json { }` config, `encodeToString`/`decodeFromString`,
  `JsonElement`/`JsonObject`/`JsonArray`/`JsonPrimitive`.
  Approach: both — JSON is a separate upstream artifact; vendor it (or a
  `klioMain` JSON encoder/decoder over the existing
  AbstractEncoder/AbstractDecoder) + Rust host JSON if needed.
  Effort: XL. Pack: kotlinx.serialization. Depends on: T5.1, T5.2.
  Accept: `@Serializable data class P(val x:Int, val y:String);
  Json.encodeToString(P(1,"hi"))` prints `{"x":1,"y":"hi"}` and
  `decodeFromString<P>(...)` round-trips. (This is also the precondition
  for ktor ContentNegotiation `json()`.)

### Batch 7 — kotlinx.coroutines ChannelFlow + structured concurrency (P0/P1)
- **T7.1 Fix the ChannelFlow/ProducerScope context casting** (B4).
  Approach: rust-binding/interp-ir fix in the channel-coroutine context
  plumbing.
  Effort: L. Pack: kotlinx.coroutines.
  Accept: `produce { send(1); send(2); send(3) }` iterates 1,2,3;
  `channelFlow { send(1); send(2) }.collect{}` works; `combine`, `zip`,
  `debounce`, `sample` over `flowOf` produce correct output.
- **T7.2 Fix exceptional-completion state machine** (B5).
  Approach: interp-ir/coroutine-runtime fix.
  Effort: L. Pack: kotlinx.coroutines.
  Accept: `CoroutineExceptionHandler` is invoked on a thrown child;
  `supervisorScope`/`SupervisorJob` isolate a failing child so the
  sibling runs; `awaitAll(d1,d2,d3)` returns `[1,2,3]` without double-
  complete.
- **T7.3 Fix hot-flow `collect`**: `MutableStateFlow`/`StateFlow` (stack
  overflow) and `MutableSharedFlow`/`SharedFlow` (suspension-as-type-
  error).
  Approach: interp-ir fix (suspension/recursion in the collect loop).
  Effort: L. Pack: kotlinx.coroutines.
  Accept: collecting `MutableStateFlow(0).take(3)` while mutating
  `.value` prints the values; `MutableSharedFlow` emit/collect works.
- **T7.4 Fix `shareIn`/`stateIn`** (depend on T7.1).
  Approach: interpreted-kotlin once ChannelFlow works.
  Effort: M. Pack: kotlinx.coroutines. Depends on: T7.1.
  Accept: `flowOf(1,2,3).shareIn(this, SharingStarted.Eagerly, 1)` and
  `.stateIn(...)` no longer throw `UnsupportedOperationException`.

### Batch 8 — kotlinx.coroutines channels, select, lazy, children (P1)
- **T8.1 Make `trySend`/`tryReceive` return `ChannelResult<T>`** (not raw Bool).
  Root cause: `crates/klio-kotlinx-coroutines/src/lib.rs` `channel_try_send`
  returns `Value::Bool`.
  Approach: both — host returns a `ChannelResult` value class;
  `klioMain` declares it with `isSuccess`/`isFailure`/`isClosed`/
  `getOrNull`/`getOrThrow`.
  Effort: M. Pack: kotlinx.coroutines.
  Accept: `ch.trySend(5).isSuccess` prints `true`;
  `ch.tryReceive().getOrNull()` prints the value.
- **T8.2 Make `isClosedForSend`/`isClosedForReceive`/`isEmpty` real `val` getters**.
  Root cause: registered as method bindings on synthetic `KlioChannel`
  with no Kotlin `val` declaration, so property access returns the
  function value.
  Approach: both — declare them as `val` in `klioMain` over the host
  bindings.
  Effort: S. Pack: kotlinx.coroutines.
  Accept: `val b: Boolean = ch.isClosedForSend` prints a Boolean.
- **T8.3 Implement `select { }` clauses**: `Deferred.onAwait`, `Job.onJoin`,
  `Channel.onReceive`/`onSend`.
  Approach: both — wire the select-clause members in the runtime.
  Effort: L. Pack: kotlinx.coroutines.
  Accept: `select<Int>{ d1.onAwait{it}; d2.onAwait{it} }` returns the
  first-completing value.
- **T8.4 Implement `CoroutineStart.LAZY` + `Job.start()`**.
  Approach: interp-ir/runtime fix.
  Effort: M. Pack: kotlinx.coroutines.
  Accept: `launch(start=CoroutineStart.LAZY){...}` does not run until
  `job.start()`, then `join()` completes.
- **T8.5 Implement `Job.children` parent-child tracking**.
  Approach: runtime fix.
  Effort: M. Pack: kotlinx.coroutines. Depends on: T7.2.
  Accept: `coroutineContext[Job]!!.children.count()` returns the live
  child count.
- **T8.6 Fix `withContext(NonCancellable)` and `flowOn` emit-context loss**.
  Approach: interp-ir fix — treat `NonCancellable` as a proper context
  element; preserve the `flow{}` emit receiver across `flowOn`.
  Effort: M. Pack: kotlinx.coroutines.
  Accept: `withContext(NonCancellable){...}` runs in a cancelled
  finally block; `flow{emit(1)}.flowOn(Dispatchers.Default).collect{}`
  prints (no unbound `emit`).

### Batch 9 — ktor receiver-lambda DSL + core types (P0/P1)
- **T9.1 Fix pack-defined receiver-lambda implicit scope** (B6).
  Approach: resolver/typeck-fix.
  Effort: L. Pack: io.ktor.client (+ all pack DSLs).
  Accept: `client.get(url){ header("X","y"); accept("application/json") }`
  resolves and runs without explicit `this.`.
- **T9.2 Add `io.ktor.http` core types**: `HttpStatusCode` (OK/BadRequest/…),
  `ContentType` (Application.Json/Text.Plain/…), `HttpMethod.Trace`/`Connect`,
  and the immutable multi-value `Headers` interface (with `getAll`).
  Change `HttpResponse.status` to compare against `HttpStatusCode`,
  `contentType` to `ContentType?`, and `headers` to `Headers`.
  Approach: both — model these in the shim; auto-load the pack on
  `io.ktor.http.*` imports (currently keyed only to `io.ktor.client.*`).
  Effort: L. Pack: io.ktor.client.
  Accept: `HttpStatusCode.OK.value` prints 200; `resp.status ==
  HttpStatusCode.OK` typechecks; `import io.ktor.http.HttpMethod` (no
  client import) resolves.
- **T9.3 Add `HttpRequestBuilder` request members**: `parameter(k,v)`,
  `setBody`/`setBody<T>`, `url { host=…; … }` URLBuilder DSL, `headers { append(…) }`
  DSL, `basicAuth`/`bearerAuth`, and `put`/`delete`/`patch`/`head`/`options`
  on `HttpClient`.
  Approach: both.
  Effort: L. Pack: io.ktor.client. Depends on: T9.1 (for the DSL forms).
  Accept: `c.put("https://x").status` runs; `b.parameter("page","1")`,
  `b.setBody("payload")`, `b.bearerAuth("tok")`,
  `b.url{ host="api.example.com" }`, `b.headers{ append("X","y") }` all
  run.

### Batch 10 — ktor plugins + typed body (P0)
- **T10.1 Add the plugin/`install` system**: `HttpClientConfig.install(plugin){ }`,
  `HttpTimeout`, `HttpRetry`, `DefaultRequest`, `Logging`, `UserAgent`.
  Approach: both — model a plugin registry on `HttpClientConfig`.
  Effort: XL. Pack: io.ktor.client. Depends on: T9.1.
  Accept: `HttpClient { install(HttpTimeout){ requestTimeoutMillis = 5000 } }`
  typechecks and runs.
- **T10.2 Add `body<T>()`/`setBody<T>` + ContentNegotiation `{ json() }`**.
  Approach: both — wire generic deserialization through the
  serialization JSON module (T6.1).
  Effort: L. Pack: io.ktor.client. Depends on: T6.1, T10.1.
  Accept: `HttpClient { install(ContentNegotiation){ json() } }` and
  `val u: U = response.body()` deserialize a JSON response into a data
  class.
- **T10.3 Add `bodyAsChannel()` streaming body**.
  Approach: both. Effort: M. Pack: io.ktor.client. (P3 — last.)
  Accept: `response.bodyAsChannel()` returns a readable channel.

### Batch 11 — kotlinx.atomicfu arrays + locks (P1/P2)
- **T11.1 Resolve the atomicfu/stdlib array name collision** (B7).
  Approach: resolver/typeck-fix — an explicit `import kotlinx.atomicfu.X`
  must bind to the atomicfu symbol over the same-named `kotlin.concurrent.atomics`
  expect class.
  Effort: M. Packs: kotlinx.atomicfu (+ resolution-wide).
  Accept: `import kotlinx.atomicfu.AtomicIntArray; AtomicIntArray(5)`
  with `ints[0].value = 42` runs (size=5); `atomicArrayOfNulls<String>(4)`
  works (no `cast to Map` / size=0).
- **T11.2 Add `kotlinx.atomicfu.locks`**: `reentrantLock()`/`ReentrantLock`
  (`lock`/`tryLock`/`unlock`/`withLock`), `SynchronizedObject` +
  `synchronized(lock, block)`, `SynchronousMutex`.
  Approach: both — include `locks/` + `klioMain` shim + host bindings.
  Effort: L. Pack: kotlinx.atomicfu.
  Accept: `reentrantLock().withLock { 42 }` prints 42;
  `synchronized(SynchronizedObject()){ "ok" }` prints `ok`;
  `SynchronousMutex().withLock { "done" }` runs.
- **T11.3 Fix `@file:OptIn` being ignored + `TraceFormat` open-class ctor + lambda-factory hang**.
  Approach: typeck-fix (honor file-target opt-in; resolve the open-class
  no-arg ctor that the inline factory shadows) + interp-ir fix (the
  `object : TraceFormat()` inline-factory path infinite-loops).
  Effort: M. Pack: kotlinx.atomicfu (+ opt-in checker language-wide).
  Accept: `@file:OptIn(...)` satisfies the opt-in requirement;
  `Trace(16, TraceFormat())` typechecks; `TraceFormat { i,e -> "$i/$e" }`
  terminates.

### Out of scope for these packs (file against stdlib)
- `List(n) { init }` size-and-init constructor throws `InstantiationError:
  Cannot create an instance of an interface: MutableList` even with no
  pack import. Blocks idiomatic `List(5){ launch{...} }`. Stdlib gap.

---

## 4. Do-first recommendation

**Start with Batch 0 (diagnostics correctness), then Batch 1 (kotlinx.io
data-copy).**

Batch 0 is the highest-leverage work that exists: the resolver hang (B1)
and `klio check` false-negatives (B2) currently make every other batch
hard or impossible to verify — probes time out instead of failing, and
broken code gets a green light. Fixing them is modest effort (M/L/S) and
immediately makes all subsequent acceptance criteria trustworthy.

Batch 1 then converts a single root cause (the ByteArray<->Segment no-op
copy, B8) into a cascade of fixes: it unblocks `write(ByteArray)`,
`readAtMostTo`, `readByteArray`, `encodeToByteString`, `decodeToString`,
and `ByteString.substring` at once, plus the scanner-termination fix
turns `readLine`/`readDecimalLong`/`readHexadecimalUnsignedLong` from
infinite loops into working APIs. It is the cheapest path to taking a
pack from ~45% to substantially complete, and it does so by fixing
mechanisms (data copy, scanner loops) rather than papering over symptoms.

After those two, the cross-pack blocker **B3 (kotlin.time)** is the next
multiplier — it is the documented single blocker for datetime arithmetic
and a precondition for idiomatic Duration use in coroutines — followed by
**B4 (ChannelFlow)**, which alone unblocks ~10 verified coroutine gaps.
