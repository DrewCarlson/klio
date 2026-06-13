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

### 4. `with`-subject outer-tower leniency

`with(x) { … }` exposes only `x` itself in kotlinc; the call-side
`outerChainFallback` (`host_call_member.zig` — the surviving half of the
old field-read rescues, whose `getField` side is gone) can still resolve a
name through the subject's outer tower in shapes kotlinc rejects (probes
p0f/p0f2 from the single-resolver work). A leniency, not a wrong value for
valid programs. Recorded as the §4.2 residual in
`execution-architecture.md`; goes away if the call-side fallback is folded
into the single resolver's candidate discipline.

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

### 8. Frame's own `this` is not folded into the receiver-chain carrier

The last §4.2 line item: `frameThisParam`/`callerThisValue` still recover the
frame receiver by param/capture name instead of riding
`Frame.enclosing_this[0]`. Folding it changes `implicitReceiverChain` depth
assumptions across every consumer; the consumer inventory lives in
`execution-architecture.md` §4.2.

### 9. Kept re-entrancy thread-locals

`map_fallback_active`, `iterable_fallback_active`, `call_outer_active`,
`field_outer_active` stay thread-local with run-boundary asserts: each
breaks a recursion that crosses the host→eval→host boundary, which a
parameter cannot follow. Tracked in `guard-inventory.md` (keep rows).

### 12. Active-scope staleness after a resume

The suspend-implicit `coroutineContext` resolves through the threadlocal
active-scope stack, pushed when a coroutine's block starts (`driveRoot`,
`__klio_co_runRoot`, `startBlock`'s undispatched push). A suspension that
resumes later runs under whatever scope the resuming pump has active, so a
cancellable suspension created after a resume can install its
parent-cancellation handle on the pump root's Job instead of its own
coroutine's. Cancellation then over-delivers (preempting via the root)
rather than under-delivering; the d-probe shapes all pass. The exact fix
is a per-activation scope carried in the frame snapshot, not a threadlocal.
