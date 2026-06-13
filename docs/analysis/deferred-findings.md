# Deferred findings

Known divergences, leniencies, and tooling gaps that surfaced during the
execution-architecture close-out and the follow-up fixes, verified but
deliberately not fixed in that work. Each entry records the observable
behavior, the mechanism, where the evidence lives, and the fix direction.
Remove entries as they are resolved.

## Runtime divergences from kotlinc

### 3. Tier-5 leniency: unimported cross-package value references and loose-shape calls

An unimported cross-package bare *call* whose index verdict is
`resolved`/`unimported_set`/`type_overload` at tier 5 is an
unresolved-reference diagnostic (kotlinc-faithful). Two shapes still resolve
leniently where kotlinc rejects: value references (`::name` and bare reads)
to tier-5 targets, and loose shapes (default/vararg/trailing-lambda arity)
whose calls the heuristic still binds because the runtime member-redispatch
path can also claim them. Erroring these requires the index to model the
runtime's member-redispatch shapes first. Recorded in
`execution-architecture.md` row 8.

### 4. `with`-subject outer-tower leniency — RESOLVED

`with(x) { … }` exposes only `x` itself in kotlinc; the call-side
`outerChainFallback` could still resolve a name through the subject's outer
tower in shapes kotlinc rejects (probes p0f/p0f2 from the single-resolver
work).

Root-caused to the lowering: a bare call inside a lifted nested/inner
class's method body whose name is a member of the *enclosing* class was
lowered to a plain `CallMember` on this receiver, because the enclosing
class's member names were merged into the method builder's `own_members`.
That plain member call then reached the enclosing member only via the
runtime `outerChainFallback`, which walks ANY receiver Instance's `outer`
links regardless of how it became the receiver — so it also fired for a
`with`/`run`/`apply` subject whose outer tower is not in scope (and even
for an explicit `outer.Inner().describe()`, which kotlinc rejects too).

Fixed by separating the two member sets: a lifted class's enclosing-class
members are now the method builder's `enclosing_members` (members of an
enclosing `this@Outer`, reached only through the implicit-receiver
candidate walk), kept distinct from `own_members` (the receiver's genuine
own/inherited members). An enclosing-member bare call therefore lowers to
`CallMemberOrGlobal`, resolved by the single candidate resolver
(`implicitCandidatesAlloc`): the inner's own `this` then its `outer` links
are searched (dispatch receiver — tower in scope), while a subject brings
only itself (tower NOT in scope). `outerChainFallback` and its
`call_outer_active` guard are deleted (see finding 9). Pinned by
`with_subject_outer_member_call_rejected` (rejection),
`inner_member_calls_outer_member` (positive: the dispatch-receiver tower
keeps resolving), and `backtick_this_param_not_receiver` in
`parity_corpus_pinned.zig`, all kotlinc-verified (kotlinc-jvm 2.3.21).

### 5. Empty containers without a creation-site type argument are unprovable

Resolved for the explicit-type-argument subset: an empty container created
with an explicit type argument on a stdlib creator (`listOf<String>()`,
`emptyList<Int>()`, the set/map/array families) carries that element head
on the value (`Value.List.declared_elem`, stamped by
`runtime.attachDeclaredElemTypes` on both the lowered-func `Call` path and
the intrinsic-value `CallValue` path), so receiver proofs and overload
refinement succeed for it. Pinned by `empty_container_declared_elem` and
the `emptyList` lines of `overload_generic_args`. What remains sanctioned
is the shape where the element type exists only in static inference, which
the runtime value cannot carry without a typechecker: an empty container
typed by its binding (`val xs: List<String> = emptyList()`) or flowing out
of an erased generic call (`fun <T> make(): List<T> = emptyList()`;
`make<String>()` — user-call type args bind reified globals, they do not
stamp returned containers). Under a competing outer member the member
still wins for those two shapes where kotlinc binds the
`List<String>.describe()` extension (probe f5b from the declared-type
dispatch work).

### 6. Forward-referenced top-level property: unannotated reads still observe the initialized value

Resolved for the annotated subset: a forward read of a not-yet-initialized
top-level property with an explicit type annotation returns the declared
type's static-field default (0/false/0.0/NUL/null), matching kotlinc JVM
2.3.21, while the initializer still runs exactly once at its file-order
turn. The carrier is `TypedDefault` on `build.NameFunc` /
`ProgramImage.TopLevelPropInit`, consulted by
`host_impl.pendingTypedDefault` inside the startup-pass window only;
properties whose startup turn already deferred keep on-access driving.
Pinned by the four `forward_read_*` tests in `parity_object_init.zig`. The
remaining boundary is unannotated top-level properties: kotlinc defaults
from the inferred field type, but the VM has no inferred type to default
from, so klio drives the initializer on demand and the forward read
observes the initialized value (side-effect order and once-only init still
match). Pinned (as divergence) by
`forward_referenced_top_level_prop_initializes_once`.

### 7. Lenient extension-dispatch residue

The lenient pass after the strict receiver-proven walk remains the designed
residue of the strict-then-lenient call policy, now pinned by an on-demand
detector: `python3 scripts/or_audit_sweep.py` runs examples +
coroutine_smoke + parity_corpus (583 programs) under `KLIO_OR_AUDIT=1`,
dedups identical runtime `arm=member_lenient` lines per program, and fails
if any lenient name falls outside the documented residue set (`{dispatch}`).
Current baseline: 10 deduped lenient lines across 10 programs (38 raw
occurrences), all `name=dispatch` — the kotlinx coroutine-internal
`dispatch` member-extensions whose erased receiver the strict prover cannot
model. The sweep is deliberately not wired into `zig build test`; a new
name in the lenient arm trips it and should be triaged as a prover gap,
not widened into the residue set. The readout in
`execution-architecture.md` records the same baseline and counting method.

## Architecture residue

### 8. Frame's own `this` recovered by name — RESOLVED (kind-disciplined, not depth-folded)

`frameThisParam`/`callerThisValue` recovered the frame receiver by scanning
`func.params`/`capture_order` for the literal name `"this"`, with no regard
for whether that param was a *synthesized* dispatch receiver. A user
parameter spelled `this` (`fun probe(\`this\`: Box)`, backticked because
`this` is a hard keyword) was treated as a dispatch receiver, so a bare
`show()` in the body resolved against it — kotlinc rejects (`unresolved
reference 'show'`).

The fold was landed bundled with finding 4, as the validator required. The
realization is the *kind discipline* the chain already uses, not a depth
shift: `ownReceiverEntry` seeds the frame's own receiver onto
`Frame.enclosing_this` only for a synthesized receiver (method / extension
by `func.kind`; constructor / init / local-extension by injection).
`frameThisParam` now consults the same provenance — a new
`Func.has_receiver_param` flag, set wherever the lowerer injects a leading
`this` (method/extension bodies via `implicit_params`, local-extension
lambdas, constructors/init/accessor/default-arg thunks) — instead of a bare
name scan. A user `this` parameter has no synthesized receiver, so
`frameThisParam` returns null and the bare call resolves no implicit
receiver, matching kotlinc. The by-name path and the chain's
`ownReceiverEntry` are now the same kind-gated discipline (one receiver
provenance), so `implicitCandidatesAlloc` and every other consumer keep
their existing depth assumptions — no depth-churn was needed once finding
4's leniency was root-caused in the lowering rather than the runtime
fallback. Pinned by `backtick_this_param_not_receiver` in
`parity_corpus_pinned.zig` (kotlinc-jvm 2.3.21).

The deeper structural ideal — deleting the param/capture recovery entirely
in favor of reading `enclosing_this[0]` — was deliberately NOT taken: with
`has_receiver_param` the two paths now agree by construction, and removing
the by-name recovery would churn `implicitCandidatesAlloc`'s capture-slot
and depth-0 handling for no behavioral gain. The leniency #8 named is
closed; the redundancy is reconciled, not removed.

### 9. Kept re-entrancy thread-locals

`call_outer_active` is DELETED: it guarded exactly the `outerChainFallback`
that finding 4 removed, so it died with that fold (no remaining caller).
`map_fallback_active`, `iterable_fallback_active`, and `field_outer_active`
stay thread-local with run-boundary asserts: each breaks an intra-thread
host materialization / rescue recursion that crosses the host→eval→host
boundary, which a parameter cannot follow (NOT a resolver-order flag, so the
single resolver did not retire them; NOT the finding-12 coroutine-scope
carrier's axis). Tracked in `guard-inventory.md` (O1/B9 keep rows, O2
removed).

### 12. Active-scope staleness after a resume — RESOLVED (over-delivery)

The suspend-implicit `coroutineContext` resolved through the threadlocal
active-scope stack, pushed when a coroutine's block starts (`driveRoot`,
`__klio_co_runRoot`, `startBlock`'s undispatched push). A suspension that
resumed later ran under whatever scope the resuming pump had active, so a
cancellable suspension created after a resume installed its
parent-cancellation handle on the pump root's Job instead of its own
coroutine's, and cancellation over-delivered.

Fixed by carrying each parked activation's own scope per-activation, at the
pump level rather than in a threadlocal stack: a suspension unwinds through
Zig without running the Kotlin `finally` that `startBlock` uses to pop its
`__klio_co_pushScope`, so those pushes would otherwise linger on the live
`active_scope_stack` and a sibling resume would read this activation's stale
scope as its own. `park` now captures the scope pushes the activation owns
(the delta above the depth its run segment began at) into the
`ParkedEntry.scope_delta` and removes them from the live stack; on resume
(`pumpLoop`, `driveResumed`, `coroutineDrainToIdle`, `coroutineRunRoot`) the
delta is restored just before the activation runs and the resumed body's own
`finally` pop balances it. The carrier travels cross-pump through
`SlotState`/`PersistedParked` so a dispatcher coroutine that hops pumps keeps
its scope. Pinned by `tl_cancel_sibling_plain` (control),
`tl_cancel_sibling_after_scope` (sibling parks inside `coroutineScope`,
leaving its scope push; cancelling it must not over-deliver to a sibling),
and `tl_cancel_root_not_independent` (cancelling the runBlocking root must
not reach a coroutine on an independent `CoroutineScope(Job())`) in
`parity_threaded_litmus.zig`, all kotlinc-faithful (kotlinc-jvm 2.3.21 +
kotlinx-coroutines).

The carrier is the coroutine-*scope* carrier; it is distinct from the
receiver-resolution chain carrier (`Frame.enclosing_this`) that findings
4/8/9 rode — those landed separately (4 and 8 RESOLVED above, 9's
`call_outer_active` deleted) and were never absorbed by this change.

Residual coroutine divergences surfaced by the #12 probes — all RESOLVED
(each kotlinc-jvm 2.3.21 verified, separate root causes, not in the scope
carrier):

- **`withContext(NonCancellable){}` (and any context-changing `withContext`
  whose dispatcher is unchanged) — RESOLVED**. The original `non-bool in
  branch: kotlin.coroutines.CombinedContext` was not a super-ctor binding
  bug: `withContext`'s undispatched fast path builds an
  `UndispatchedCoroutine`, which the common source declares only as an
  `expect class` (its supertype `ScopeCoroutine<T>` appears with no
  constructor delegation). With no actual, the VM materialised the bare
  expect, so `ScopeCoroutine`/`JobSupport` received the leaf's args and
  `JobSupport._state`'s `if (active)` read a `CombinedContext`. Fixed by
  supplying the klio actual `UndispatchedCoroutine : ScopeCoroutine<T>` in
  `klioMain/.../ContextActuals.kt`. That exposed a second, *general* lowering
  bug (not coroutine-specific): an inline function whose parameter name
  collides with a variable a lambda argument references resolved the
  reference to the inline parameter — `withContext`'s `block` was shadowed by
  `withCoroutineContext`'s `block` param inside the spliced
  `withCoroutineContext(...) { return@sc startUndispatchedOrReturn(coroutine,
  block) }`, re-running the body. Fixed in the inline splice
  (`ir/lower/inline_call.zig` + `ir/build.zig`): a spliced lambda body now
  resolves its free names against the caller's scopes plus the lambda's own
  scopes, skipping the inline fn's parameter scopes
  (`lambda_splice_resolve`). A third, smaller lowering gap was fixed
  alongside: an explicit label on a lambda literal (`sc@ { … }`) is now
  recorded as the lambda's `implicit_label`, and a `LabeledReturn` matches a
  frame's `implicit_label` as well as its name, so a `return@sc` spliced out
  of an inlined argument unwinds to the labelled lambda. Pinned by
  `tl_withcontext_noncancellable` in `parity_threaded_litmus.zig` and the
  non-coroutine `inline_param_shadows_caller` in `parity_corpus_pinned.zig`.
- **`coroutineContext.cancel()` / `coroutineContext[Job]!!.cancel()` —
  RESOLVED**. Both call shapes now find the context's installed Job and
  cancel its children (the #12 scope-carrier work installs the right Job on
  the implicit `coroutineContext`). Pinned by
  `tl_cancel_via_coroutine_context`.
- **independent awaited coroutine kept alive — RESOLVED**. An
  independent-scope coroutine (own `Job`, not in the runBlocking tree) that
  is explicitly awaited completes before the awaiter proceeds even when its
  body parks, while a fire-and-forget daemon stays correctly abandoned (the
  `tl_daemon_*` pins are unchanged). Pinned by
  `tl_independent_awaited_completes`.

## Tooling

