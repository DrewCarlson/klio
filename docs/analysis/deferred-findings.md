# Deferred findings

Known divergences, leniencies, and tooling gaps that surfaced during the
execution-architecture close-out and the follow-up fixes, verified but
deliberately not fixed in that work. Each entry records the observable
behavior, the mechanism, where the evidence lives, and the fix direction.
Remove entries as they are resolved.

## Runtime divergences from kotlinc

### 1. Runtime overload dispatch is blind to generic arguments, function shapes, and suspend

`type_overload` sets whose signatures differ only inside generic arguments
(`pick(List<Int>)` vs `pick(List<String>)`), function-type components
(`call((Int)->Int)` vs `call((String)->String)`), or `suspend` are correctly
deferred to runtime dispatch by the index, but `pickOverload` then selects by
declaration order: klio prints `pick(List<Int>)` where kotlinc resolves by
type and prints `pick(List<String>)`. Lowering has carried the full declared
`TypeRef` (generic args, function shapes, suspend, variance) since the
signature-identity work, so the scorer has the declared side available; what
it lacks is element-type knowledge on the runtime value. Fix direction: a
declared-type-aware scorer that uses runtime element knowledge where the
value carries it and falls back to kotlinc's most-specific rules otherwise.
Repro shapes: the b4/verify8 probes from the resolution review (same-arity
generic and function-shape overload pairs called with disambiguating
arguments).

### 2. Explicit-receiver named-argument dispatch picks a type-incompatible extension over the member

`tests/fixtures/parity_corpus/named_arg_member_over_extension.kt` fails:
`userMethodNamed` scoring admits an extension whose receiver type does not
match instead of the receiver's own member. Not part of the *OrGlobal family
(explicit receiver), so the single-resolver work did not absorb it. The
strict receiver-proof machinery (`receiverImplementsType` plus the
strict-then-lenient pass in `host_call_member.zig`) is the natural mechanism
to reuse in the named-overload scorer.

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

`with(x) { … }` exposes only `x` itself in kotlinc; klio's host-internal
`getField` rescues (`outerChainFallback`) can still resolve a name through
the subject's outer tower in shapes kotlinc rejects (probes p0f/p0f2 from
the item-7 work). A leniency, not a wrong value for valid programs.
Recorded as the §4.2 residual in `execution-architecture.md`; goes away if
the field-read rescues are folded into the single resolver's candidate
discipline.

### 5. Empty-container generic-arg proofs are unprovable

`listOf<String>()` carries no runtime element knowledge, so a
`List<String>`-receiver extension cannot be receiver-proven; under a
competing outer member the member wins where kotlinc binds the extension.
Sanctioned divergence of the strict-then-lenient design — the prover cannot
know erased element types. Would be subsumed by declared-type plumbing on
values (same root as finding 1).

### 6. Forward-referenced top-level property reads the initialized value, not the pre-init default

kotlinc reads a not-yet-initialized top-level property's typed default
(`0`/`null`); klio drives the initializer on demand, so the read observes
the initialized value. Side-effect order and once-only initialization match
kotlinc; only the read-before-init value differs. Exact fidelity needs
per-property typed defaults, which the VM lacks type information for.
Pinned (as current behavior) by
`forward_referenced_top_level_prop_initializes_once`.

### 7. Lenient extension-dispatch residue

The lenient pass after the strict receiver-proven walk decides 8 dispatches
across the corpus, all kotlinx-internal `dispatch` member-extensions with
erased receivers — the designed residue. The KLIO_OR_AUDIT readout in
`execution-architecture.md` tracks the count; growth is a regression signal.

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

## Tooling

### 10. `klio run` resolves the kotlin/ stdlib checkout relative to the working directory

Running the binary from outside the repo silently loses stdlib inline
functions (`run`, `let`) and fails with `unresolved global` — it masqueraded
as nondeterminism during the object-init work. Needs robust resource
discovery (binary-relative or configured path) or at minimum a diagnostic
naming the missing stdlib root.

### 11. `zigcheck.py itests` hits the RSS watchdog

The script's monolithic itests mode builds every integration test into one
compilation and exceeds the 6GB cap; the sharded `zig build test` (one
binary per itest file) is the real gate. Either shard the script's itests
mode the same way or drop that mode.
