# kotlinx-coroutines upstream-runtime campaign — plan

## Goal

`crates/klio-parity/tests/coroutine_smoke/{cs1..cs4}.kt` byte-identical
on the **real upstream `kotlinx-coroutines-core` commonMain runtime**
(`JobSupport` / `AbstractCoroutine` / concrete `launch`/`async`/`delay`
/ `CoroutineContext`), with the bespoke `klioMain/.../Runtime.kt`
builders retired. "Full and correct kotlinx.coroutines on klio's
(JVM-faithful, real-threaded) concurrency model."

## Status

- **11 interpreter/stdlib gaps fixed, committed, gate-green,
  regression-covered** (`f9b016f`→`59ea178`, table below).
- **Gaps #12 and #13 fixed** (pending gate-green commit), each with
  an isolated reproduction and one shared kotlinc-byte-identical
  parity regression
  (`corpus/superctor_companion_and_referential_identity.kt`):
  - **#12 — real root cause (the original "operator-`plus`
    mis-resolution" hypothesis was wrong).** A bare companion-object
    name used as a *superclass-constructor delegation argument*
    (`class D : AbstractCoroutineContextElement(Key)` where `Key` is
    `D`'s `companion object Key`) did not resolve to the class's own
    companion. `parent_ctor_args` thunks were lowered with no
    owner/own-member scope, so the bare `Key` fell through to the
    global-class step and bound to the unrelated
    `CoroutineContext.Key` interface. Result: `d.key === cn.key`,
    collapsing `plus` to its argument.
  - **#13 — referential identity.** `===` / `!==` lowered
    identically to `==` / `!=`, so `this === other` inside
    `CombinedContext.equals` dispatched the user `equals` and
    recursed until stack overflow. Added a real
    `BinOp::IdentEq/IdentNeq` + `Value::reference_eq` (pointer
    identity, never dispatches `equals`).
- With #12+#13 fixed, **roadmap item 2's first sub-gap already
  passes**: `context[ContinuationInterceptor]` and polymorphic-key
  lookup resolve correctly through the composed `CombinedContext`
  (both `d + cn` and `cn + d` orderings), verified at the
  `kotlin.coroutines` stdlib level without the flip.
- Not done: cs1 not yet re-driven under the flip to byte-identical
  (next: `createCoroutineUnintercepted().intercepted()` →
  `DispatchedContinuation` → `isDispatchNeeded`/`dispatch`, then
  `scheduleResumeAfterDelay` virtual-time wakeups); cs2–cs4
  unverified; bespoke `Runtime.kt` not retired.

## Reproduction harness

Flip the pack to the real upstream runtime, then drive cs1:

```sh
# from repo root
cd crates/klio-kotlinx-coroutines
# restore the 8 platform expect-actuals removed in 8970914
git checkout 8970914~1 -- $(git show 8970914 --stat --name-only --format= \
  | grep 'klioMain.*\.kt' \
  | grep -E 'ContextActuals|Debug.kt|Exceptions.kt|FlowExceptions|Atomics|Concurrent|Misc|StackTraceRecovery')
git restore --staged klioMain
# remove the bespoke/curated klioMain so only expect-actuals remain
rm -f klioMain/kotlinx/coroutines/Runtime.kt \
      klioMain/kotlinx/coroutines/RunnableActual.kt \
      klioMain/kotlinx/coroutines/DebugActual.kt \
      klioMain/kotlinx/coroutines/ExceptionsActual.kt
# klio.toml: full upstream commonMain (NO include filter) + klioMain
printf '[library]\nid = "kotlinx.coroutines"\nversion = "1.11.0"\nabi = 1\nimplicit_packages = []\nauto_bindings = true\n\n[[source]]\nroot = "upstream/kotlinx-coroutines-core/common/src"\n\n[[source]]\nroot = "klioMain"\n\n[[deps]]\nid = "stdlib"\n' > klio.toml
cd ../..
cargo test -q -p klio-parity --test coroutine_smoke --release -- --nocapture
```

**Always revert the flip** (`git checkout -- crates/klio-kotlinx-coroutines`
+ `git clean -fdq crates/klio-kotlinx-coroutines/klioMain`) before
running/committing interpreter fixes: the fixes keep the *shipped*
bespoke gate green independently, and the flipped klio.toml/klioMain
must never be committed until the campaign completes.

`klio_parity::run_with_packs` is the harness; an ad-hoc probe is a
1-line test `crates/klio-parity/tests/<x>.rs`:
`#[test] fn p(){ println!("OUT=[{}]", klio_parity::run_with_packs(std::path::Path::new("/tmp/kt/x.kt")).unwrap()); }`

## Closed gaps (committed, gate-green, regression-covered)

| Commit | Gap |
|---|---|
| `f9b016f` | top-level `const` initializers driven before non-const |
| `7266fb6` | superclass body-prop inits use their own super-ctor args |
| `3f18dff` | `kotlin.arrayOfNulls` builtin |
| `6c9ec79` | top-level property initialized on demand when read early |
| `5db2001` | parity harness surfaces embedded stdlib sources |
| `5862840` | hierarchy member fn over shadowing value (CallValueOrMember) |
| `f66b5ed` | invocability decides shadowed call at runtime |
| `d2af1a5` | explicit-receiver member over shadowing local (CallMemberOrValue) |
| `07d6bd4` | parse leading annotation on a function expression body |
| `07687fe` | `kotlin.Result` is a builtin for the incompatible-receiver guard |
| `59ea178` | `Any` methods on the `kotlin.Unit` singleton |
| `4de539e` | bare companion in superclass-ctor delegation arg binds to own companion; `===`/`!==` are referential (no `equals` dispatch) |
| `246270f` | bare class/interface name in value position resolves to its companion (qualifier heads keep the class value) |
| `e9c35c6` | a lone same-named member is dispatched only when arg-applicable, so a narrowing overload (`CoroutineDispatcher.plus(CoroutineDispatcher)`) no longer shadows the inherited `CoroutineContext.plus` for a non-matching arg |

Each shipped with an isolated kotlinc-byte-identical parity corpus
regression; full 75-suite workspace gate green at every commit.

## Correct architecture (resolved)

klio is JVM-faithful multithreaded (real OS threads, loom-verified
`Arc<AdaptiveCell>` publication, real `Dispatchers.Default`/`IO`
worker pools via `__kxco_dispatch`/`__kxco_dispatchIo`, park/unpark
via `__kxco_parkSlot`/`__kxco_resumeSlot`, virtual clock via
`__kxco_delayMillis`/`__kxco_currentTimeMillis`). There is **no
architectural blocker**. `concurrency.md` was stale and has been
corrected.

**Important scoping correction (supersedes the original "mirror all
of `jvm/src` EventLoop subsystem" framing):** the flip sources only
`upstream/.../common/src`. Upstream's `runBlocking` lives in
`concurrent/src` (NOT loaded), so cs1's `runBlocking` is klio's
*native* cooperative host driver (`kotlinx.coroutines.runBlocking`
→ `run_blocking` in `crates/klio-kotlinx-coroutines/src/lib.rs`),
**not** upstream `runBlockingImpl`/`EventLoop`. Therefore a full
`jvm/src` `EventLoop`/`DefaultExecutor`/`runBlockingImpl` port is
**not** required for cs1. The real path is:

1. Fix the chain of isolatable interpreter gaps (#12, …) so
   upstream's concrete `launch`/`async`/`delay`/`JobSupport` run
   correctly on the consumed commonMain.
2. Ensure the coroutine context carries a klio-cooperative
   `ContinuationInterceptor` (a `CoroutineDispatcher`-that-is-also-
   `Delay` over `__kxco_*`), so upstream `launch` dispatches the
   child cooperatively (not inline) and `delay` suspends/resumes in
   klio virtual-time order. Inject it via `newCoroutineContext`
   (klioMain `ContextActuals.kt`) and/or klio-native `run_blocking`.

The unfilled platform `expect`s (`Dispatchers`, `DefaultDelay`,
`EventLoopImplPlatform`, `createEventLoop`, `nanoTime`,
`DefaultExecutor`, `platformAutoreleasePool`, `newFixedThreadPoolContext`,
`runBlockingImpl`) are tolerated by klio in uninvoked paths today
(cs1 runs without them). They only need minimal `klioMain` actuals
**if/when** a cs1–cs4 path actually reaches them; do not pre-build
the whole `jvm/src` mirror speculatively.

## cs1 is byte-identical under the flip ✅ — current blocker: cs2

**cs1_launch_delay passes byte-identical on the real upstream
runtime** (full `JobSupport`/`AbstractCoroutine`/`launch`/`delay`/
`CoroutineContext` + the klioMain cooperative `KlioDispatcher`).
Achieved by the #16/#18/#19 + stdlib batch below. The
`coroutine_smoke` failure has moved to **cs2_async_await**:
`not yet implemented: Vm::get_field 'onCancelling' on
'kotlin.Nothing'` (JobSupport `notifyHandlers(list, cause) {
it.onCancelling }` — a node-list element resolves to a
`kotlin.Nothing`; gap #20, next).

### Batch pending gate-green commit (cs1 enabler)

Interpreter/stdlib fixes (flip-independent, keep shipped gate green):
- **#16 — member beats same-named top-level extension at an
  unqualified call.** lower.rs `needs_this` bare-extension path now
  routes through `CallMember{receiver=this,name}` (full klio
  resolution: receiver member → builtin/stdlib intrinsic →
  best-by-receiver extension fallback) instead of a direct `Call` to
  one `func_id`. Kills the `resumeCancellableWith ↔
  resumeCancellableWithInternal` recursion **and** fixes the two
  previously-latent corpus tests
  (`result_member_over_samename_extension.kt`,
  `ext_receiver_incompat_redispatch.kt`) — `kotlin.Result`/
  `StringBuilder` receivers now correctly hit their intrinsics
  (the earlier `CallMemberOrValue`+`LoadGlobal` idea was superseded;
  **no `Result.holder`/`StringBuilder.out` accessors needed**).
  Restricted to the plain arg-shape (defaulted-middle-param
  trailing-lambda routing keeps the direct `Call`). Regression:
  `member_beats_toplevel_extension_unqualified.kt`.
- **#18 — extension-property/member read mis-flattened to a dotted
  FQN inside a lambda.** The `Expr::Member` `collect_dotted_fqn`
  guard now requires `(is_pkg_root(head) || !b.is_lambda_body())`
  (matching the three call-site guards), so
  `resumeMode.isCancellableMode` inside `withContinuationContext {}`
  resolves as `this.<field>` + Int extension prop, not global
  `resumeMode.isCancellableMode`. Regression:
  `ext_prop_on_field_in_lambda.kt`.
- **#19 — `super.<property>` in a getter.** `Expr::Member` with an
  `Expr::Super` receiver now emits a 0-arg `CallSuper`; `call_super`
  resolves a super property getter (and falls back to the receiver's
  backing field for a stored base val). Fixes
  `AbstractCoroutine.isActive get() = super.isActive` (was lowering
  to `this.isActive` → `__get_AbstractCoroutine_isActive`
  self-recursion). Regression: `super_property_getter_dispatch.kt`.
- **stdlib `createCoroutineUnintercepted`/
  `startCoroutineUninterceptedOrReturn` (receiver form).**
  `{ receiver.block() }` (lowered as `call_member(receiver,"block")`
  → "call_member `block` on StandaloneCoroutine") changed to
  `{ block(receiver) }` so the `suspend R.() -> T` value is invoked
  with the receiver. `crates/klio-stdlib/kotlin-coroutines/Intrinsics.kt`.

Files: `crates/klio-ir/src/lower.rs`,
`crates/klio-interp-ir/src/lib.rs`,
`crates/klio-stdlib/kotlin-coroutines/Intrinsics.kt`, + 3 new corpus
regressions. Revert flip before committing; flip/KlioRuntime.kt/
ContextActuals/klio.toml stay uncommitted until builder retirement.

### Gap #20 (cs2, next)

`JobSupport.notifyHandlers(list, cause) { it.onCancelling }` — `it`
(a `JobNode`/`LockFreeLinkedListNode` list element) resolves to
`kotlin.Nothing` so `it.onCancelling` (a `JobNode` open `Boolean`
prop) fails. Investigate klio's lock-free linked-list node traversal
in `JobSupport`/`LockFreeLinkedList` under the flip (the node list
is built by `invokeOnCompletion`/`InvokeOnCompletion`); the empty/
head sentinel or the `forEach`/cast yields `Nothing`. Trace with the
`eval_with_captures` depth/dump infra; isolate; fix; gate-green
commit + regression; continue cs2→cs3→cs4.

## Resolved — gap #16+#17 (member beats top-level extension + Result.holder; coupled, pending gate-green commit)

With #15 committed (`e9c35c6`), re-drove cs1 under the flip + the
documented cooperative dispatcher. **`d + cn` no longer collapses**
— the injected `KlioDispatcher` now survives `newCoroutineContext`'s
`combined + KlioDispatcher` and the `AbstractCoroutine`
`parentContext + this`, so cs1 proceeds *past* the dispatcher-drop
into the now-reachable upstream dispatch path
(`intercepted()` → `DispatchedContinuation` →
`resumeCancellableWith` → `isDispatchNeeded`/`dispatch`, and the
`CombinedContext` graph). It now **stack-overflows** — traced (depth trace, as for #13) to an
infinite mutual recursion **`resumeCancellableWithInternal`
(id 1659) ↔ `resumeCancellableWith` (id 1660)**.

**Root cause (gap #16 — member-over-extension after smart-cast, the
#5/#7/#9 family).** Upstream `intrinsics/Cancellable.kt`:
`internal fun <T> Continuation<T>.resumeCancellableWithInternal(r)
= when (this) { is DispatchedContinuation -> resumeCancellableWith(r);
else -> resumeWith(r) }` and the public extension
`fun <T> Continuation<T>.resumeCancellableWith(r) =
resumeCancellableWithInternal(r)`. Inside
`resumeCancellableWithInternal`, with `this` smart-cast to
`DispatchedContinuation`, the unqualified `resumeCancellableWith(r)`
must bind to the **`DispatchedContinuation` member**
`resumeCancellableWith` (the dispatch-or-inline logic). klio instead
binds it to the **top-level `Continuation.resumeCancellableWith`
extension** (whose body is `= resumeCancellableWithInternal(r)`) →
`Internal → ext → Internal → …` unbounded. klio must prefer a
member of the (smart-cast) receiver type over a same-named top-level
extension at an unqualified call inside an extension-fn body.

**Fix direction.** In the call-resolution path for an unqualified
call whose receiver is `this` smart-cast to a type that has a
member of that name, the member must win over a top-level extension
of the same name (mirrors fixed gaps #5/#7/#9 —
`CallValueOrMember`/`CallMemberOrValue`/invocability). Likely no
flip needed to isolate: a top-level `fun T.f()` extension that calls
an `internal fun T.g()` which, after `when(this){ is Sub -> f() }`
smart-cast, must call `Sub.f()` (a member) not the extension.
Investigate the IR lowering of an unqualified call inside an
extension body where the smart-cast receiver type declares a member
of that name. Ship as its own gate-green commit + isolated parity
regression; revert flip before committing; then continue the cs1
chain (further isolatable gaps expected along
`isDispatchNeeded`/`dispatch`/`scheduleResumeAfterDelay`).

## Resolved — gap #15 (committed `e9c35c6`; the *real* original #12)

With #12/#13/#14 committed (gate-green), re-drove cs1 under the flip
+ the documented cooperative dispatcher. cs1 still prints
`start, child, after launch, end` (child inline). Root-caused fully
via the flip probe (post #14, all `plus` sub-ops verified correct:
`d.key === ContinuationInterceptor`, `cn.key === CoroutineName`,
`d.minusKey(CoroutineName) === d` (not Empty), `d[CI] === d`,
`d.minusKey(CI) === Empty`, `CoroutineName is
AbstractCoroutineContextKey` false; a hand-written `fold` mirroring
`plus` returns the correct `d`). Yet `d + cn` **and** `d.plus(cn)`
both return `cn`.

**Root cause (gap #15 — the original gap-#12 "operator-`plus`
mis-resolution" hypothesis, now precisely pinned).** `d + cn` →
`call_member(d, "plus", [cn])` → the BFS hierarchy walk
(`crates/klio-interp-ir/src/lib.rs` ~5072) visits `D` (no `plus`)
then `CoroutineDispatcher`, whose **own** `plus` is the deprecated
`public operator fun plus(other: CoroutineDispatcher):
CoroutineDispatcher = other` (upstream `CoroutineDispatcher.kt`).
`pick_method_overload` (`lib.rs` ~890) has a fast path: **a single
candidate is returned unconditionally (~line 898) with no arity or
argument-type applicability check**. So `plus(other:
CoroutineDispatcher)` is dispatched for the `CoroutineName` argument
`cn` (which is *not* a `CoroutineDispatcher`); its body returns
`other` → `d + cn == cn`, dropping the dispatcher. The walk never
reaches the applicable interface-default
`CoroutineContext.plus(CoroutineContext)`. Same family as #6/#7/#9
(name-based resolution choosing a wrong same-named member).

Confirmed reachable inline only via the flip probe so far; it
**isolates with no flip** as: a base interface with a default
`operator fun plus(c: Base): Base = …`, a subclass declaring a
*narrower* `operator fun plus(s: Sub): Sub = s`, and a third
`Base` element `e` that is not a `Sub`; `sub + e` must use the
interface default (klio wrongly uses `Sub.plus`, returning `e`).
Build that as the isolated parity regression.

**Fix direction.** `pick_method_overload`'s single-candidate fast
path must not bypass applicability: a candidate whose arity doesn't
fit, or whose declared parameter type the runtime argument provably
is **not** an instance of, must be rejected (return `None`) so the
BFS continues to the next supertype and reaches
`CoroutineContext.plus`. High risk: this fast path is the universal
instance-method dispatch shortcut — prior method-resolution
tightenings regressed the 75-suite gate and were reverted. Make the
rejection *conservative* (only reject on a definite mismatch:
concrete user class/interface param vs a value that is definitively
not that type and not `Any`/generic/`null`; never reject on
generics, lambdas, nullables, numerics, or unknowns) and run the
**full** gate incl. `datetime_smoke` + conformance + the 333-file
parity sweep before commit. After #15, re-drive cs1 (cooperative
dispatcher wiring is documented and verified-correct once the
dispatcher survives `+`); expect further isolatable gaps along
`DispatchedContinuation`/`dispatch`/`scheduleResumeAfterDelay`.

## Earlier blocker — gap #14 (resolved, committed `246270f`)

With #12+#13 committed, cs1 under the flip runs end-to-end (no
errors/overflow) but still prints `start, child, after launch, end`
(child inline) vs expected `start, after launch, child, end`.

Traced the full cs1 dispatch chain:
- A klio-cooperative dispatcher (`CoroutineDispatcher`+`Delay` over
  `__kxco_spawn`/`__kxco_delayMillis`) injected via klioMain
  `newCoroutineContext` when the context has no
  `ContinuationInterceptor` **is** placed in the child context
  (`injected[ContinuationInterceptor] != null` confirmed at the
  injection site).
- But `intercepted()` (klio stdlib `kotlin-coroutines/Intrinsics.kt`,
  body is correct: `interceptor?.interceptContinuation(this) ?: this`)
  sees `this.context` == just `StandaloneCoroutine@..` — the
  dispatcher was lost. `AbstractCoroutine`'s
  `val context = parentContext + this` collapsed to `this`, dropping
  `parentContext` (which held the dispatcher). So
  `context[ContinuationInterceptor]` is null → no
  `DispatchedContinuation` → child resumes inline.

Root cause = **gap #14**, same family as #12: a bare class/interface
name that has a `companion object`, used as a *value*, resolves to
the class object instead of the companion. `CoroutineDispatcher :
AbstractCoroutineContextElement(ContinuationInterceptor),
ContinuationInterceptor` passes the bare `ContinuationInterceptor`
(an external interface whose companion `object Key` is the intended
`CoroutineContext.Key`) as its `key`; klio binds the interface
**class object**, not the companion, so the polymorphic-key path
(`this.key === key`, `key is AbstractCoroutineContextKey`,
`minusPolymorphicKey`) in `CoroutineContext.plus` misfires and
`d + cn` collapses to `cn` (dispatcher dropped). #12's fix only
covered the class's *own* companion in a super-ctor thunk; this is
the general case and reproduces with **no flip**:

```kotlin
import kotlin.coroutines.*
interface Marker { companion object Key : CoroutineContext.Key<Nothing> }
fun main() {
    val a: Any = Marker
    println(a === Marker.Key)   // klio: false  (BUG; Kotlin: true)
    val m = Marker
    println(m === Marker.Key)   // klio: false  (BUG; true)
}
```

Also confirmed via the flip with the real pack (post #12/#13):
`D : CoroutineDispatcher()`, `d + cn` still `=== cn` (true) and
`(d+cn)[ContinuationInterceptor]` null, while `cn + d` is fine.

**Fix direction (REVISED — first attempt reverted, see below).** A
bare identifier resolving to a user class/interface that declares a
`companion object`, used **only in a true terminal value position**,
must yield the companion singleton. It must **not** redirect when the
single-segment Path is the *qualifier head* of a member/call.

*Attempt 1 (reverted):* lower.rs single-segment bare-class step
emitted `LoadGlobal` + `GetField("<class-companion-or-self>")`;
interp-ir `get_field` returned the companion singleton for a
`Value::Class` with a registered companion, else the receiver. This
correctly fixed the isolated repros and kept #12/#13 byte-identical,
but **regressed `datetime_smoke`** (`datetime_smoke_litmus`,
`kotlinx_demo_byte_identical`): `not yet implemented: call_member
'DayBased' on <instance>`. Cause: `Expr::Member` (lower.rs ~2043),
the Call-with-`Member`-callee receiver (~2080/~2166), `MemberRef`
(~1610), and the multi-segment `Expr::Path` (len>1) branch all lower
their **qualifier head** via the *same* single-segment Path path.
`DateTimeUnit.DayBased` then redirected the head `DateTimeUnit` to
its companion, losing the `Value::Class`-receiver semantics
(nested-class `DayBased`, companion-member forwarding). Reverted to
keep the tree at `4de539e` (gate-green); never ship a gate
regression (documented policy).

*Attempt 2 (do this next — mechanical, scoped):*

1. Re-apply attempt-1's two changes verbatim: lower.rs single-segment
   `Expr::Path` known-class step emits `LoadGlobal` +
   `GetField("<class-companion-or-self>")`; interp-ir `get_field`
   handles that sentinel (Value::Class with a registered companion →
   companion singleton; else receiver unchanged). (Diffs are small
   and were verified to fix the repros + keep #12/#13
   byte-identical.)
2. Add ONE shared helper
   `fn lower_receiver(b, receiver: &Expr) -> Reg`: if `receiver` is a
   single-segment `Expr::Path` whose name is not a resolvable
   local/outer and `b.module.class_id(name).is_some()`, emit the
   plain `LoadGlobal name` (the `Value::Class`, *no* sentinel);
   otherwise `lower_expr(b, receiver)`.
3. Replace `lower_expr(b, receiver)` with `lower_receiver(b,
   receiver)` at every *qualifier/receiver* site (the value head of a
   member/call, not a standalone value). Enumerated in
   `crates/klio-ir/src/lower.rs` (line numbers approximate, re-grep
   `lower_expr(b, receiver)`): the `Expr::Member` GetField read
   (~2024), the safe-call `Expr::Member` (~1976), the
   Call-with-`Member`-callee receivers (~2064, ~2148), the
   assignment/SetField `Expr::Member` targets (~1611, ~3508), the
   augmented-assign receiver (~1616, ~3514), the compound-call
   receivers (~3078, ~3137, ~3420), and the `MemberRef` receiver
   (~3611). The multi-segment `Expr::Path` (len>1) head already uses
   `LoadFromThisOrGlobal` (runtime-resolves to the class) and is
   **not** affected — leave it. Construction (`NewInstance`) and
   `X::class` (`ClassLiteral`) are separate — leave them.
4. Ship `crates/klio-parity/tests/corpus/`
   `bare_class_name_is_companion_value.kt` (C default companion, D
   named companion, I interface companion all `=== X.Companion/Named/
   Key`; `object O` and a no-companion class unchanged; `C() is C` /
   `C() !== C()` prove construction still works — all 12 lines
   `true`, kotlinc-identical).
5. Gate: **must** run `datetime_smoke` + `conformance` + the
   333-file `parity` sweep, not just unit suites — attempt 1 passed
   26 unit suites then failed only at `datetime_smoke`
   (`DateTimeUnit.DayBased`). `cargo test --workspace --release`
   covers all; budget ~ a few min for the cached build + conformance
   + parity.

## Resolved — gaps #12 & #13

The original gap-#12 hypothesis ("operator-`plus` mis-resolves to
`EmptyCoroutineContext.plus`") was **wrong**. The BFS hierarchy walk
(`crates/klio-interp-ir/src/lib.rs` ~5050) does correctly select the
interface-default `kotlin.coroutines.CoroutineContext.plus`. The
real defects were two independent interpreter bugs upstream of that:

**Gap #12 — bare companion name in a superclass-ctor delegation
argument.** `class D : AbstractCoroutineContextElement(Key)` (where
`Key` is `D`'s `companion object Key`) stored the *wrong* `key`:
`d.key` resolved to the unrelated `CoroutineContext.Key` interface
(a `Value::Class`), so `d.key === cn.key` was true and `plus`
collapsed to its argument. Cause: `parent_ctor_args` thunks
(`crates/klio-interp-ir/src/build.rs` ~1393) were lowered via
`lower_expr_as_param_thunk` binding only the child's primary-ctor
params — no `owner_class`/`own_members` scope (unlike
`lower_init_block`). A bare `Key` therefore fell through the
bare-identifier ladder to the global-class step and bound the
same-named interface; the no-shadow case (`Marker`) was instead an
`unresolved global`. Fix: `lower_expr_as_param_thunk_scoped` carries
the enclosing class + own-member set; the bare-ident path, in a
param thunk with an owner, resolves an own-companion name to
`GetField(LoadGlobal(owner), name)` (a Class receiver forwards to
its companion singleton in `get_field`). build.rs passes the
companion object's own name + members as `own`.

**Gap #13 — `===` / `!==` were not referential.** `ast_binop`
mapped `IdentEq`/`IdentNeq` to `BinOp::Eq`/`NotEq`, identical to
`==`/`!=`. For `Value::Instance` operands `==` routes through
`call_member(.., "equals", ..)`, so `this === other` inside
`CombinedContext.equals` (`this === other || …`) re-entered
`CombinedContext.equals` forever → stack overflow once #12 let the
real `plus` algorithm run. Fix: new `BinOp::IdentEq/IdentNeq`
(`crates/klio-ir/src/lib.rs`), lowered from `AstBinOp::IdentEq/
IdentNeq`, handled in `eval.rs` *before* the operator/`equals`
dispatch via `Value::reference_eq` (`crates/klio-runtime/src/lib.rs`)
— heap values by backing-cell pointer, value-likes by structural,
never a user `equals`.

**Regression:** `crates/klio-parity/tests/corpus/`
`superctor_companion_and_referential_identity.kt` — a pure-user
program (no pack/flip) exercising both: companion-name binding in a
super-ctor arg with a shadowing top-level `interface Key`, and a
`this === other` guard inside an `equals` override used through
`listOf(...).contains`. Fails pre-fix (wrong booleans / overflow),
kotlinc-byte-identical post-fix.

## Remaining roadmap

1. **Gaps #12 & #13** — DONE (resolved section above). Commit
   gate-green, then re-run cs1 under the flip.
2. **Continue the chain** — roadmap item 2's first sub-gap
   (`context[ContinuationInterceptor]` through the composed
   `CombinedContext`) **already passes** after #12+#13. Next
   expected isolatable gaps along cs1: the
   `createCoroutineUnintercepted().intercepted() →
   DispatchedContinuation.resumeCancellableWith →
   isDispatchNeeded/dispatch` path; then
   `scheduleResumeAfterDelay`/virtual-time wakeups. Fix each as its
   own gate-green commit with an isolated repro + parity regression.
   Provide the klio-cooperative `ContinuationInterceptor`
   (`CoroutineDispatcher`+`Delay` over `__kxco_spawn`/
   `__kxco_delayMillis`) and inject it via `newCoroutineContext`.
3. **cs1 byte-identical**, then repeat for **cs2–cs4**
   (`cs2_async_await`, `cs3_many_launch`, `cs4_suspend_seq`).
4. **Retire bespoke builders** — set `klio.toml` to upstream +
   minimal `klioMain` permanently; delete `Runtime.kt`; update the
   `klio-cli/src/main.rs` source-selection test and
   `run_with_packs`/`embedded_stdlib_sources` wiring; keep
   kotlin.coroutines (stdlib layer) vs kotlinx.coroutines (pack)
   separation; keep #115 co-load fix intact.
5. **Full gate**: `cargo test --workspace --release` (75 suites) +
   byte-identical parity (corpus + examples) + conformance +
   datetime/kotlin_time/coroutine/coroutine_lang smokes + typeck
   corpus_sweep, all green; cross-check every cs against real
   `kotlinc`.

## Determinism note

cs1–cs4 expected outputs are byte-deterministic only under klio's
virtual clock (parity harness runs `TimeMode::Virtual`). Any delay
scheduling must use klio's virtual time (`__kxco_delayMillis` /
`__kxco_currentTimeMillis`), never real wall-clock sleeps, so the
event ordering (`child` @ vt=50 before `main` @ vt=100) is
reproducible.

## Findings log (chronological; later supersedes earlier)

1. Pure-`klioMain` `KlioCoroutineDispatcher` injected by
   `newCoroutineContext` compiles, no shipped-gate regression, but
   does not fix cs1 (child still inline): injection is necessary,
   not sufficient.
2. Eval trace: `newCoroutineContext` runs once and injects the
   dispatcher, but `interceptContinuation`/`dispatch`/
   `scheduleResumeAfterDelay` never run → upstream `intercepted()`
   reads `context[ContinuationInterceptor]` as null.
3. (Superseded by 4.) Polymorphic-key machinery
   (`ContinuationInterceptor.get`, `AbstractCoroutineContextKey`,
   `getPolymorphicElement`, `CombinedContext.get`) is individually
   correct in isolation. Earlier conclusion "intractable composed-
   graph integration, multi-session" was **wrong**.
4. **The dispatch failure decomposes into isolatable single gaps.**
   Root of the null `[ContinuationInterceptor]`: `d + cn` itself
   drops the dispatcher (`(d + cn) === cn`). Hypothesised as
   operator-`plus` mis-resolution; see 5.
5. (Supersedes 4's `plus` hypothesis.) The BFS hierarchy walk picks
   the correct interface-default `CoroutineContext.plus`. `(d + cn)
   === cn` had **two** distinct upstream causes, both fixed:
   **#12** the super-ctor-delegation argument `Key` bound to the
   wrong same-named global (no companion scope on the param thunk),
   so `d.key === cn.key`; **#13** `===` was non-referential and
   dispatched user `equals`, so the now-running real `plus` algorithm
   (`CombinedContext.equals`'s `this === other`) stack-overflowed.
   After both, `context[ContinuationInterceptor]` through the
   composed `CombinedContext` already resolves correctly (roadmap
   item 2's first sub-gap). Expect further isolatable gaps deeper in
   the `intercepted()`/`dispatch`/`scheduleResumeAfterDelay` path.

6. **cs1 dispatch chain fully traced (post #12/#13).** klioMain
   `newCoroutineContext` injecting a cooperative
   `CoroutineDispatcher`+`Delay` (over `__kxco_spawn`/
   `__kxco_delayMillis`) is correct and the dispatcher *is* placed
   in the child context, but **gap #14** (bare
   class/interface-with-companion resolves to the class object, not
   the companion) corrupts `CoroutineDispatcher`'s `key`, so
   `parentContext + this` in `AbstractCoroutine` drops the
   interceptor and the child resumes inline. #14 is the next
   isolatable single gap (no flip needed to repro); fixing it is
   expected to let the already-correct injected dispatcher take
   effect, then continue the chain
   (`DispatchedContinuation`/`dispatch` /
   `scheduleResumeAfterDelay` virtual-time). The flip experiment was
   reverted (uncommitted, per policy); the cooperative dispatcher
   wiring is captured here for fast re-application next session.

## Risk

Touching method/operator resolution or the dispatch path can
regress the shipped 75-suite gate (the earlier `Scheduler.kt` and
the gap-#9 lowering heuristics did, and were reverted). Every gap
fix must: have an isolated repro, ship a kotlinc-byte-identical
parity regression, keep the full gate green, and revert the flip
before committing. Never stub/weaken the gate or fabricate a pass.
