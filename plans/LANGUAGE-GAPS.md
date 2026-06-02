# Language & Pack Actuals — outstanding gaps

Living checklist of real correctness gaps surfaced by the language-coverage and kotlinx pack audits. Strip items as they land.

## ✅ Landed

- **Reified type parameters.** `inline fun <reified T>` calls now trigger splicing alongside suspend / non-local-return shapes. The splice binds each reified type-param locally (so `T::class` resolves as a value) and globally via `Inst::StoreGlobal` (so `Inst::InstanceOf { ty: TypeRef "T" }` consults the bound class at runtime). `instance_of` guards against recursion when the type name is already a registered class.
- **Lock-free `LockFreeLinkedListNode`.** Real Sundell-Tsigas port from upstream's `concurrent/src/internal/LockFreeLinkedList.kt` — atomic next/prev pointers, `Removed` marker on `_next`, `correctPrev` helping protocol. klio's atomicfu CAS is observed atomically under contention, so the algorithm is sound across real `Dispatchers.Default` worker threads.
- **`noinline` parameter enforcement.** `try_inline_call` skips the lambda-splice map for `noinline` parameters.
- **`@PublishedApi` visibility.** Confirmed working — inline functions can access `@PublishedApi internal` members on the same class.
- **Data class synthesis.** `copy()` + `componentN()` already work end-to-end.
- **Inline `val` accessors.** `inline val foo: T get() = …` resolves and runs correctly. (`inline get()` / `inline set()` modifiers on `var` accessors are a separate parser feature; not yet supported.)
- **`kotlin.Result` / `ChannelResult` internal-field reads.** Both inline value classes wrapping `Any?` represented as `Value::Result { ok, payload }`; `get_field` returns the payload for the upstream-internal `value` / `holder` slot names.
- **`kotlinx.coroutines.internal` stubs are real.** `ReentrantLock.withLock`, `WorkaroundAtomicReference`, `LocalAtomicInt`, `CommonThreadLocal`, `Synchronized.synchronizedImpl`, `LockFreeLinkedListNode` all hold real exclusion under `Dispatchers.Default`. `systemProp` reads the host env via a new `__kxco_systemProp` Rust binding.
- **kotlinx-datetime placeholders fail loudly.** AST bodies throw `NotImplementedError` if the binding isn't installed.
- **Package-rooted FQN call inside receiver scope.** `kotlin.synchronized(this, block)` inside an extension fn body resolves correctly.
- **atomicfu Atomic\*Array + `update` / `updateAndGet` / `getAndUpdate`.** Confirmed working via composition.

## Inline policy summary

Conservative gate is the right shape for klio today: splice when **suspend** (the body captures the caller's continuation), **non-local-return lambda arg** (the return must target the caller's frame), or **reified type-params** (`T::class` / `is T` need the call-site type argument substituted at splice time). Other inline calls keep the normal call path so the splice graph cannot expand combinatorially through deep Flow / Channel operator chains.

Attempting universal inline expansion was tried and reverted: realistic-coroutines `coroutine_with_finally_cleanup` / `with_timeout_or_null` hang because some specific inline body's splice path mis-coordinates with the cancellation machinery, and the interpreter's Rust-side recursion exceeds even an enlarged stack on Flow operator chains. Re-landing it would need an iterative IR-eval driver + targeted exclusions; deferred until a real need surfaces (Kotlin's spec requires inlining for correctness only in the cases klio already handles).

## Deferred (small)

- **`crossinline` non-local-return diagnostic.** Typeck has `TYPE_CROSSINLINE_PARAM_LEAK` (T0056) for stored/returned values but no check for bare `return` in the lambda body passed to a crossinline parameter. Runtime semantics already match Kotlin (the return targets the caller's frame, which is what `crossinline` forbids).
- **`inline get()` / `inline set()` on `var` accessors.** Parser doesn't accept the `inline` modifier on individual property accessors. `inline val foo get() = …` works because the modifier is on the property declaration.
- **`sealed class` exhaustiveness.** `data class` synthesis and `when` over a known sealed hierarchy work structurally. Real subclass enumeration for `when` over a sealed hierarchy with `else`-less branches is not yet enforced.
- **User `contract { callsInPlace(...) }` blocks.** klio-cfa's `ContractEffect` table is stdlib-only. Wiring user contracts requires per-function contract storage, a parser walk to detect `callsInPlace` in inline-fn bodies, and a new `ContractEffect::CallsInPlace { lambda_arg_idx, kind }` variant.

## Pack-actual residuals

- **kotlinx-io**: `SegmentPool` is a no-op pool, `isWindows` hardcoded `false`, `SystemLineSeparator` hardcoded `"\n"`. Fine until kxco-io paths contend.
- **kotlinx-serialization**: `ReflectiveKSerializer` could have a clearer error when a binding isn't loaded.

## Out of scope here

- Real Pack metadata distribution beyond `~/.klio/packs/` (tracked in `PACK-DISTRIBUTION.md`).
- Loom-style scheduling verification of the new dispatcher (memory-model work in `docs/architecture/memory-model.md`).
