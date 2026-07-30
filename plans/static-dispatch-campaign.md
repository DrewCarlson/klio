# Static dispatch campaign

## Standing constraint: no simple-name resolution

Every resolution this campaign adds or touches must key on a FULLY
QUALIFIED name. Simple-name keys have repeatedly produced silent wrong
answers across the project, and this campaign's whole premise — binding
calls at lower time — is worthless if the binding can be wrong.

Where a simple-name lookup genuinely helps (a short local class, an
unambiguous top-level), it must be ISOLATED so no other class or
top-level function can pollute it: a scoped index, not a global map.

The defect found while opening the type channel is the canonical example.
`typeck`'s class table is `classes: std.StringHashMap(ClassInfo)` keyed by
SIMPLE name, so `androidx.compose.runtime.composer.gapbuffer.SlotTable`
and `androidx.compose.runtime.composer.linkbuffer.SlotTable` overwrote
each other; every lookup answered with whichever registered last. That
made `read`'s parameter look like a receiver lambda
(`SlotTableReader.() -> T` instead of `(reader: SlotReader) -> T`), which
suppressed the lambda's implicit `it`, which produced 8 hard
unresolved-reference errors in a valid program. One simple-name map, four
layers of consequence.

The interim fix records the collision and answers NOTHING for an
ambiguous simple name — a wrong answer is worse than none, because it
feeds the eager evidence channel and disproves valid candidates
downstream. The durable fix is package-keyed class resolution in typeck,
and it is a prerequisite for trusting receiver types in phase 1 rather
than an optional cleanup.


Goal: bind every call at lowering time, so the runtime never resolves a
member by name. That retires the dispatch ladders and the memoization
layered over them, and it is the prerequisite a bytecode VM needs — a
packed instruction stream cannot fall back to a name walk.

Everything below is measured on `PausableCompositionTests.resumeOnBackgroundThread`
(rob) with the ReleaseFast harness, via `KLIO_DISPATCH_STATS=1`.

## Where dispatch goes today

78.3M call-form instructions execute per run:

| form | count | share |
|---|---|---|
| `call_member_virtual` (name-based) | 64.80M | **82.8%** |
| `call_value` | 4.76M | 6.1% |
| `call_static` | 4.69M | 6.0% |
| `call_member_or_global` | 3.70M | 4.7% |
| `call_member_resolved` | 43K | **0.06%** |
| `call_virtual_slot` | 61K | **0.08%** |

The two static mechanisms that already exist — the `resolved` FuncId bake
and the `CallVirtual` method slot — fire on **0.14% of calls combined**.

The 64.80M name-based member dispatches account fully as:

| tail | count | share of member calls |
|---|---|---|
| `member_flat_prepare` (cache hit -> flat activation) | 29.08M | 44.9% |
| `member_fast_subscript` (`a[i]` served inline) | 19.86M | 30.7% |
| `member_ladder` (full name walk) | 15.28M | 23.6% |
| `member_range_iter` | 0.58M | 0.9% |

So the prize splits in two: 29.1M calls that a runtime cache already
resolves monomorphically (pure waste — lowering could have baked them),
and 15.3M that walk the ladder every time.

`member_fast_subscript` at 19.9M is worth noting separately: those are
`get`/`set` member calls that `fastSubscript` serves inline. They should
not be `CallMember` instructions at all — lowering has an `Index`
instruction for exactly this.

## Why static binding covers only 6.2% of sites

`lowerResolvedMemberCall` is the right mechanism and already does the
right thing: a final/private target becomes `Call(FuncId)`, an overridable
one becomes `CallVirtual(MethodSlotId)`. Per-site census over the same
run (`[lower-sites]`):

| outcome | sites | share |
|---|---|---|
| declined: **no receiver type** | 18,986 | **72.3%** |
| declined: resolver could not pick | 3,749 | 14.3% |
| declined: no ClassId for the type name | 1,679 | 6.4% |
| bound -> `CallVirtual` | 984 | 3.8% |
| bound -> static `Call` | 646 | 2.5% |

The gate is its first line: `const ty = declared_ty orelse return .none`.
Nearly three quarters of member call sites decline because the lowerer
does not know the receiver's static type.

## The actual blocker, and it is small

A type-head channel from typeck to the lowerer already exists —
`Module.eagerTypeOf(span)`, consumed additive-only by `argDeclTypeRef`.
It carries **nothing**: `KLIO_TYPEHEAD_AUDIT=1` reports zero fills and
zero disagreements, because `computeEagerCalls` opens with

    if (runtime.getenvSlice("KLIO_EAGER") == null) return null;

With `KLIO_EAGER=1` the channel populates well — 12,628 type heads, 4,978
call resolutions, 1,879 lambda receiver heads, 5,922 param shapes — but
the eager resolver then rejects the compose corpus with **8 errors across
3 files, all one class**: `unresolved reference 'it'`, at lambdas passed
to a member function whose parameter type needs the receiver type to
find:

    slots.read { it.anchor() }                 // SlotTableTests.kt
    table.read { it.anchor(group) }            // SlotTable.kt:3507

`read` is a member of `SlotTable` taking `(SlotReader) -> T`. The
resolver cannot bind `it` without knowing the lambda's arity, cannot know
the arity without resolving `read`, and cannot resolve `read` without the
receiver type — the same missing fact, one layer earlier.

## Phases

**Phase 0 — open the type channel.** Nothing downstream pays off before
this. The blocker is diagnosed to a single mechanism, recorded here in
full because the chain is long and easy to re-derive wrongly:

1. All 8 failures are the shape `var x = slots.read { it.anchor() }`,
   where `read` is `inline fun <T> read(block: (reader: SlotReader) -> T)`.
   The sibling `slots.read { it.nodeCount(0) }` on the same class does NOT
   fail.
2. The error is emitted by LOWERING, not the eager resolver:
   `lambda_body.zig` records `unresolved_local` when `b.it_suppressed` is
   set and an `it` reference resolves nowhere.
3. `suppress_it = lam.implicit_it and expected_arity == 0`, and
   `expected_arity` falls back to typeck's recorded lambda shape
   (`Module.eagerParamShapeOf`) when the AST sources have no answer.
4. `KLIO_OR_AUDIT=1` now tags each decision with the evidence that set the
   arity. Matching the failing body spans against the audit shows
   `src=eager-recv`: typeck recorded `has_receiver = true, arity = 0` for
   `read`'s parameter, which is a plain one-parameter function type with
   NO receiver.
5. `has_receiver` traces to the AST (`convertTypeRefWithTparams` sets
   `receiver_head = ft.receiver`), so typeck resolved `slots.read` to a
   declaration whose parameter IS a receiver lambda — a wrong overload
   pick, which is exactly the "permissive inference" hazard
   `argDeclTypeRef` documents.

A minimal repro does NOT reproduce it: a class with an
`inline fun <T> read(block: (reader: R) -> T)`, a defaulted-parameter
method on `R`, and same-named methods on three classes all run correctly
with `KLIO_EAGER=1`. So the wrong pick needs something else present in
the compose corpus — most likely a competing `read` declaration whose
parameter is a receiver lambda. Finding that competitor is the next step.

### Fixed

The competing declaration was found: TWO classes named `SlotTable` exist,
`…composer.gapbuffer.SlotTable` (whose `read` takes
`(reader: SlotReader) -> T`) and `…composer.linkbuffer.SlotTable` (whose
`read` takes `SlotTableReader.() -> T`). `typeck.classes` is keyed by
SIMPLE name, so the second registration overwrote the first and every
lookup answered with whichever came last.

The fix records the collision (`ambiguous_class_names`) and answers
NOTHING for an ambiguous simple name, via `putClassChecked` /
`classNamed`. With eager on, the 8 unresolved-`it` errors go to 0, and
`klio check` over the examples corpus reports identical error counts with
and without the change — the fix removes wrong answers without adding
diagnostics. The durable fix remains package-keyed class resolution; see
the standing constraint at the top of this document.

### Eager mode is NOT yet ready to become the only mode

`commontest-sweep.py --eager both` (the dual gate; it runs both modes and
reports divergence per directory) shows eager FAILING three tests that
pass with it off:

    kotlin/libraries/stdlib/test/numbers: off=113/0, on=110/3
    kotlin/libraries/stdlib/test/time:    off=81/0,  on=80/1

- `NaNTotalOrderTest.listTMinOrNull` and `sequenceTMinOrNull`:
  `minOrNull()` returns `NaN` where `0.0` is expected. A comparison
  selected against the wrong static type — NaN total-order handling
  differs between the boxed and primitive comparison paths.
- `DurationTest.parseAndFormatInUnits`:
  `Vm::get_field 'length' on 'kotlin.Array'`. `kotlin.Array` has `size`,
  not `length`, so eager picked a declaration returning `Array` where the
  correct one returns `String`. The read is inside the stdlib's own
  `kotlin.time.Duration` implementation, not the test; the test's
  `vararg representations: String` (an `Array<String>` inside) plus
  `withIndex()` destructuring is the likely source of the confusion —
  element type mistaken for container type.

Both are wrong-static-type defects, the same family as the `SlotTable`
collision. Until they are fixed the `KLIO_EAGER` flag and the non-eager
branches must stay: deleting the working path while the replacement fails
real tests would be trading correctness for tidiness. The removal is
tracked as its own step below.

**Phase 0b — retire non-eager.** Preconditions, all measured, none
optional: `--eager both` clean across the stdlib sweep; every compose
suite green under eager; the coroutine repros intact under eager. Then
delete the `KLIO_EAGER` gate in `computeEagerCalls`, the non-eager
branches it guards, and the `--eager` mode switch in the sweep (it
becomes the only mode, so a dual gate has nothing to compare).

Two candidate fixes for the `it` defect, in preference order (kept for
the record; the first was taken):

- Fix the overload pick in typeck so `read` resolves to the member on
  `SlotTable`. Correct at the source, and it is the same defect that
  will mis-answer receiver types in phase 1.
- Failing that, refuse to suppress `it` on typeck evidence when the body
  contains a bare `it` and no enclosing lambda supplies one. Suppressing
  the binding a body demonstrably needs can only ever be wrong; kotlinc
  rejects a genuine `() -> R` lambda that reads `it`, so no valid program
  depends on the current behaviour.

Narrowing eager trust to receiver shapes was tried and does NOT work —
the wrong answer is the one claiming a receiver.

**Phase 1 — widen the receiver-type answer.** With the channel open,
re-measure `[lower-sites]`. The 72.3% `no_receiver_type` bucket is the
number to drive down; the 6.4% `no_class_id` and 14.3%
`resolver_declined` buckets get their own passes afterwards.

**Phase 2 — lower `a[i]` as `Index`.** 19.9M `member_fast_subscript`
dispatches should never reach the member arm.

**Phase 3 — retire the runtime caches.** Once `[dispatch-stats]` shows
`member_ladder` and `member_flat_prepare` near zero, the TL and shared
dispatch caches (`tl_method_cache`, `tl_ext_cache`, `tl_resolve_cache`,
`tl_perm_cache`, `ext_method_cache`, the member-resolve memos) have no
remaining callers and come out. Measure after removing them: they cost
real time on every miss.

**Phase 4 — bytecode VM.** Only meaningful once dispatch is static. Note
the measurements already recorded in `interpreter-performance-plan.md`:
widening `Inst` from 120 to 200 bytes cost 0%, and adding a whole extra
call per instruction cost 0%. A denser encoding and a tighter dispatch
loop are therefore NOT where the win is — the win in phase 4 is that a
statically bound call needs no resolution at all, which phases 0-3
deliver on their own. Treat the re-encoding as optional cleanup, not as
a performance change, unless a fresh measurement says otherwise.

## Instrumentation

`KLIO_DISPATCH_STATS=1` prints both censuses at run end: `[dispatch-stats]`
(executed call forms and member sub-tails) and `[lower-sites]` (static-gate
coverage per call site). Both are free when off — rob measures 43.3-43.7s
with them compiled in against a 43.8-44.2s baseline.
