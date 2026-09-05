# Language & Pack Actuals — outstanding gaps

## Completed

All tracked language gaps are closed. The earlier "landed" set (reified type parameters, the lock-free `LockFreeLinkedListNode` port, `noinline` enforcement, `@PublishedApi` inline access, data-class synthesis, inline `val` accessors, `kotlin.Result` / `ChannelResult` internal-field reads, the real `kotlinx.coroutines.internal` exclusion stubs, kotlinx-datetime loud placeholders, atomicfu array/update ops) plus the four previously-deferred items are all done:

- crossinline bare-`return` diagnostic → `checkCrossinlineArgReturns` emits T0056 (`src/typeck/check/expr_calls.zig`).
- `inline get()` / `inline set()` on `var` accessors → `scanAccessorModifiers` (`src/parser/members.zig`).
- sealed `when` exhaustiveness → `sealedLeafSubclasses` + "'when' expression must be exhaustive" (`src/typeck/check/narrowing.zig`).
- user `contract { callsInPlace(...) }` → user-inline-contract registry (`src/cfa/analyses/contracts.zig`).

## Open

None recorded. The last two (bare factory vs value-class constructor,
Char range endpoints) closed 2026-09-05 in `resolution-residue-campaign.md`:
inside the class the constructor wins when the argument types fit, else the
same-named factory (`examples/value_class_factory_over_ctor.kt`); ranges
render and contain their element type (`examples/char_range_endpoints.kt`).

## Pack-actual residuals

- **kotlinx-io**: `SegmentPool` is a no-op pool, `isWindows` is hardcoded `false`, and `SystemLineSeparator` is hardcoded `"\n"` (`kotlin-klio/klio-kotlinx-io/klioMain/kotlinx/io/Actuals.kt`). Fine until kxco-io paths contend.
- **kotlinx-serialization**: `ReflectiveKSerializer` could raise a clearer error when its binding isn't loaded.

## Out of scope here

- Real pack metadata distribution beyond `~/.klio/packs/` (tracked in `PACK-DISTRIBUTION.md`).
- Loom-style scheduling verification of the dispatcher (memory-model work in `docs/architecture/memory-model.md`).
