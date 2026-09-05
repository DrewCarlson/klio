# Language & Pack Actuals — outstanding gaps

## Completed

All tracked language gaps are closed. The earlier "landed" set (reified type parameters, the lock-free `LockFreeLinkedListNode` port, `noinline` enforcement, `@PublishedApi` inline access, data-class synthesis, inline `val` accessors, `kotlin.Result` / `ChannelResult` internal-field reads, the real `kotlinx.coroutines.internal` exclusion stubs, kotlinx-datetime loud placeholders, atomicfu array/update ops) plus the four previously-deferred items are all done:

- crossinline bare-`return` diagnostic → `checkCrossinlineArgReturns` emits T0056 (`src/typeck/check/expr_calls.zig`).
- `inline get()` / `inline set()` on `var` accessors → `scanAccessorModifiers` (`src/parser/members.zig`).
- sealed `when` exhaustiveness → `sealedLeafSubclasses` + "'when' expression must be exhaustive" (`src/typeck/check/narrowing.zig`).
- user `contract { callsInPlace(...) }` → user-inline-contract registry (`src/cfa/analyses/contracts.zig`).

## Open (owned by `resolution-residue-campaign.md`)

- **Bare factory vs value-class constructor**: `Color(0xFFFF0000)` inside `Color`'s own companion binds the `Color(ULong)` constructor instead of `fun Color(Long)`; kotlinc resolves by argument type. Task 1 there.
- **Char ranges expose Int endpoints**: `('a'..'c').toString()` prints `97..99` and `.first` is an `Int`; kotlinc keeps `Char`. Task 2 there.

## Pack-actual residuals

- **kotlinx-io**: `SegmentPool` is a no-op pool, `isWindows` is hardcoded `false`, and `SystemLineSeparator` is hardcoded `"\n"` (`kotlin-klio/klio-kotlinx-io/klioMain/kotlinx/io/Actuals.kt`). Fine until kxco-io paths contend.
- **kotlinx-serialization**: `ReflectiveKSerializer` could raise a clearer error when its binding isn't loaded.

## Out of scope here

- Real pack metadata distribution beyond `~/.klio/packs/` (tracked in `PACK-DISTRIBUTION.md`).
- Loom-style scheduling verification of the dispatcher (memory-model work in `docs/architecture/memory-model.md`).
