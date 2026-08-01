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

### Eager mode is a STUB, measured

Before treating "open the channel" as the work, here is what eager
currently buys for the thing it exists to enable. Executed dispatch on the
same compose test, eager off against eager on:

    call_static             6.63%  ->  6.67%
    call_member_resolved    0.05%  ->  0.05%
    call_member_virtual    31.63%  -> 31.70%
    call_virtual_slot       0.21%  ->  0.21%

Turning eager on moves static dispatch by 0.04 percentage points. Per
call SITE it is the same story: bound 6.21% -> 6.73%, and the
`no_receiver_type` share gets WORSE (72.3% -> 75.5%).

The reason is the channel's payload, not its plumbing:

    pub const EagerTypeHead = struct { name: []const u8, nullable: bool };
    pub const EagerParamShape = struct { has_receiver: bool, arity: u16 };

Typeck computes full `Type` values — generic arguments, variance,
nullability, function shapes — and discards nearly all of it at the
boundary. A head is not a type. The `minOrNull` defect proves the cost: for
a generic receiver a head-only answer is worse than none, so lowering must
DECLINE it, which removes exactly the container receivers that dominate
real code.

So the obvious build-out is to widen `EagerTypeHead` to carry a full type,
generic arguments included. **That was tried and REVERTED, and the result
relocates the whole problem.**

The widening itself worked: `EagerTypeHead` carried nested arguments, with
an `args_complete` flag distinguishing "no arguments" from "arguments
unknown", so the blanket decline-all-generics rule became the precise one.
Then the audit counted what it actually delivered:

    fills (eager supplied a usable type):   311   — ALL non-generic (String)
    skips (arguments unknown):            3,800   — Array, Continuation,
                                                    CancellableContinuationImpl, ...

Zero generic fills. `no_receiver_type` did not move (72.25%). And two
stdlib tests REGRESSED, because where typeck did supply arguments they
were wrong:

    CollectionTest.plusCollectionInference   Expected <[[s], [a]]>, actual <[[s], a]>
    GroupingTest.countEach                   expected a Grouping receiver

The first picked `plus(element)` over `plus(collection)`; the second lost a
`Grouping` receiver. Both are the hazard `argDeclTypeRef`'s own comment
warned about, now realized: with full arguments, typeck's WRONG arguments
get trusted. Net: zero measurable gain, two regressions. Reverted.

**The transport is not the bottleneck. Typeck's generic inference is.**
It does not know an `Array`'s element type at 3,800 sites, and where it
does claim to know, it is sometimes wrong. Widening the channel only
changes which of those two failures you get.

So the real Phase 1 is a typeck project, not a plumbing one: substitute
type arguments through call sites, propagate them from declarations, and
get `plusCollectionInference` / `countEach` right as the first two
regression tests for it. Only then does re-widening the channel pay, and
only then can `no_receiver_type` fall.


## Scratch homes in /tmp are the single biggest source of false regressions

Two of them, both found in the same session, both of which had already cost
real diagnosis time inside the interpreter:

  - `/tmp/klio_itest_stdlibtest_home` — the commontest sweep's home. Without
    the kotlin.test pack every test in every file reports `unresolved global
    assertEquals`. `scripts/commontest-sweep.py` now installs it and refuses to
    sweep when it cannot find one.
  - `/tmp/klio_itest_compose_plugin_home` — the compose home. It needs FIVE
    packs (atomicfu, kotlin.test, coroutines, androidx.collection, the runtime
    engine) in dependency order; with only some installed the run reports
    `unresolved reference runTest` and `unresolved reference atomic` from a
    pack's own klioMain sources. `scripts/compose-install-packs.sh` rebuilds
    and installs all five.

The shape to recognise: a failure reported by EVERY test, or an unresolved
reference to a name that obviously exists, is evidence about the environment.
Check the home's `packs/` before forming any hypothesis about the compiler.
Both of these presented as compiler bugs and neither was.

Also fixed: `scripts/compose-test.sh` baked `kotlinx_coroutines_test_default_timeout=10s`
and ignored an outer value, so the two background-thread tests
(`markInvalidFromBackgroundThread`, `resumeOnBackgroundThread`, which need
~15s and ~47s) always failed and were reported as a regression once already.
It now honours an outer override.

## RESOLVED: `unresolved global assertEquals` was a missing pack, not the interpreter

The sweep intermittently reported whole files failing every case with
`unresolved global assertEquals` / `assertTrue` / `assertSame`. `UuidTest` was
the first file it was noticed on, and it was chased through nine wrong
diagnoses (image cache, star imports, missing sources, `ULong` constants, the
`Uuid` class, a nested `Clock`, path dependence, intermittency, a cross-half
file interaction) before being attributed to a disagreement between the cold
stdlib-assembly path and the baked-image path.

That attribution was wrong. The cause is trivial: `assertEquals` and friends
come from the **kotlin.test pack installed in the sweep's child HOME**
(`/tmp/klio_itest_stdlibtest_home`), and that home's `packs/` directory was
empty. With the pack installed the same binary on the same files passes —
`UuidTest` 21/21, `ContinuationInterceptorKeyTest` 4/4.

Everything that made it look like an interpreter bug follows from that one
fact. It presented as a RESOLUTION failure rather than an assertion mismatch
because the symbols genuinely were not there. It looked INTERMITTENT because
the child home is scratch: whatever populates it (a `stdlib_commontest` itest
run) fixes it, and anything that clears `/tmp` breaks it again. It looked
path-dependent because a file that happens not to call `assertEquals` is
unaffected. And the earlier "deleting the child home changes nothing" check
was worthless, since deleting it leaves the pack exactly as absent as before.

`scripts/commontest-sweep.py` now installs the pack when it is missing and
refuses to sweep when it cannot find one, so a silently unpopulated home can
never be read as a mass regression again.

The lesson worth keeping: a failure reported by EVERY test in a file is
evidence about the environment, not about the code under test. Nine
hypotheses were spent inside the interpreter on a fault that a single `ls` of
the child home would have shown.

## Inventory: everything that is still not statically bound

The end goal is FULL static dispatch — a bytecode VM and a Kotlin-to-C
transpiler both need every call site to name its target at compile time, with
the only permitted exceptions being language features deliberately omitted
(advanced reflection and anything else that is dynamic by definition). This
section is the running ledger of what remains, so the tail can be worked through
deliberately instead of rediscovered.

Current census — `scripts/dispatch-census.sh`, cold cache, pinned file set:

    total 6,538 member call sites
      146   2.23%  bound_static     <- direct FuncId call
    3,563  54.50%  bound_virtual    <- method slot, no name lookup
    ------------------------------
    2,012  30.77%  no_receiver_type
      451   6.90%  resolver_declined
      246   3.76%  no_class_id
      120   1.84%  nullable_or_generic

Statically bound: 3,709 of 6,538 (56.7%), from 150 (2.34%) at the start of this
round. The TOTAL shrinks as bare calls that were member sites become
statically bound extension calls and leave the member census entirely.

And on the examples set (`scripts/dispatch-census-examples.sh`), which has the
concrete types the stdlib's own generic containers do not:

    total 68,568
     1,453   2.12%  bound_static
    42,680  62.24%  bound_virtual
    ------------------------------
    16,346  23.84%  no_receiver_type
     3,697   5.39%  resolver_declined
     3,114   4.54%  no_class_id
     1,278   1.86%  nullable_or_generic

Statically bound: 44,133 of 68,568 (64.4%), from 27,098 (37.4%).

The earlier 9,755-site census in this document was taken on a different file
set and at an unknown cache state; do not compare against it. Use the script.

### The remaining `no_receiver_type` mass, measured

`KLIO_DISPATCH_STATS` now reports why local typing declined, and
`KLIO_LI_NAMES` names the callees that yield nothing:

    [localinit] 2,228 total
                  350  no_initializer     <- loop var, lambda param, destructure
                1,346  no_return_type
                  532  derived

    initializers that yield no type, by callee:
        908  iterator          <- bare call
         88  .iterator
         72  listIterator
         66  .getOrPut
         34  toMutableList
         30  createFrom

**The `iterator` bucket is CLOSED.** `staticCallReturnTypeRef` refused outright
when `enclosingHasMemberNamed` held — backwards, because that condition means
the bare call IS a member of the implicit receiver written without `this.`, and
the receiver resolution right below it is what answers such a call. Worth +134.

It took a probe to find, and the probe's value was in what it did NOT print:
two changes aimed at this bucket (teaching bare calls to lend a return type,
then lifting the `res.confidence` guard) moved nothing, and `[bareret]` was
silent, which proved the receiver fallback was never reached rather than
reached-and-declining. Reasoning from the two null results alone would have
pointed at the resolution; the silence pointed at the guard above it.

    [localinit] 1,346 -> 1,254 no_return_type,  532 -> 624 derived

What is left in that census, by callee: `.iterator` 88, `listIterator` 72,
`.getOrPut` 66, `toMutableList` 34, `createFrom` 30 — a long tail rather than
another block.

**The stdlib set said "long tail". The EXAMPLES set said otherwise, and it was
right.** Re-run on the examples, the same census reads:

    9,458  iterator          <- still, and by two orders of magnitude
      770  .getOrPut
      408  toMutableList
      271  .iterator

So the `iterator` bucket was never closed; only the stdlib set's copy of it was
small enough to look closed. The cause found by `KLIO_BARERET=iterator` — the
trace's whole value again being WHERE it stopped, 10,088 exits at one guard:

    [bareret] iterator shadowed local=true localfn=false outer=false

The shape is `val iterator = iterator()`, and the guard is
`staticCallReturnTypeRef`'s "a name bound to a local is not a top-level call".
Correct at a call site, wrong here: `localInitTypeRef` re-asks about the
INITIALIZER from a later point in the block, where the local it defines is
already bound — so the local shadowed the very call that produced it. Kotlin
does not bring a local into scope until after its own initializer, so the name
must resolve past it.

Fixed by recording, at the declaration, whether the name was free there
(`local_init_name_free`, written before the bind, which is the initializer's
own scope) and suppressing only that one name while its own initializer is
typed. The flag is what makes it exact: `val f = f()` where `f` names an
enclosing local of function type must still decline, and does.

    stdlib   2,369 -> 3,121 bound   (34.6% -> 45.6%)
    examples 27,100 -> 36,876 bound (37.4% -> 50.9%)

This is the same defect as the "later local captured an earlier bare write"
entry at the end of this document: a scope query that knows the name but not
the point in the block. Any third instance is likely to be the same shape.

### `no_initializer` — 350 locals, one of three shapes done

A loop variable is now typed from the iterable's sole type ARGUMENT, so
`for (i in items)` over a `List<Item>` binds `i.show()`. It is worth NOTHING on
the pinned stdlib set, whose iterables are generic, and the parity fixture is
where it shows — verified by building both ways.

That leaves the other two shapes, and both need the same thing the loop
variable needed, from a different source:

  - a LAMBDA parameter: its type is the corresponding parameter of the
    function-typed parameter it binds to, which `argLambdaParamTypes` already
    computes for the arity/receiver stamp.
  - a DESTRUCTURED component: `componentN()`'s declared return type on the
    element type, which the loop rule above now has in hand.

    **LANDED, and the collision below is fixed.** A data class's `componentN`
    accessors are now real declarations, lowered from the primary-constructor
    properties with each property's declared type as the return type, so
    member resolution finds them and no extension is consulted. Both
    destructuring forms (`val (a, b) = x` and `for ((a, b) in xs)`) then type
    each name from that accessor, via `nullaryMemberReturnTypeRef`.

    Two things had to be right and only the second is obvious. The accessor
    must be registered with `registerMemberDecl` — `resolveMemberCall` reads
    the owner-scoped overload index, NOT the class's method list, so appending
    to `methods` alone left the class with three methods and no candidates. And
    a return type that comes back as the owner's own type PARAMETER (`Pair`
    written without arguments answers `component1 -> K`) names no class and is
    refused; `KLIO_COMP_TRACE` shows both outcomes.

    Worth +2 sites on examples and 0 on the stdlib set — the value is the
    correctness fix, not the census. The original report:

    **BLOCKED, and by a correctness bug rather than by typing.** Destructuring
    a DATA CLASS in a `for` loop fails at run time on the committed tree:

        data class Entry(val key: String, val item: Item)
        for ((k, it) in listOf(Entry("a", Item("x")))) { … }
        -> runtime error: Vm::get_field `value` on `Entry`

    DIAGNOSED. `value` is `kotlin.collections.Map.Entry`'s field, and the
    stdlib declares

        public inline operator fun <K, V> Map.Entry<K, V>.component2(): V = value

    A user class named `Entry` is picking up that extension. Bisected by
    renaming the class — `Entry` -> `Rec` makes the same program run — which is
    NOT the fix and must never be, per this project's root-cause rule; it only
    identifies the collision. Reduced further: `e.component1()` works and
    `e.component2()` fails, because `component1` falls through to the
    data-class auto-member while `component2` is intercepted by the Map.Entry
    extension first.

    The mechanism is `Module.staticTypeHead`, which buckets an extension by
    `applicability.simpleName(name)` — so `Map.Entry` indexes under `Entry`
    and every user `Entry` matches it. That is the same simple-name identity
    defect as the `Double.equals` / `String.equals` collision fixed earlier in
    this campaign, and as the `expect`/`actual` sibling scan before it. It is
    the third instance.

PINPOINTED to `Value.isRuntimeType`, `src/runtime/value.zig`, the
    `.Instance` branch:

        if (cg.get().isSubtypeOf(a, name)) break :blk true;
        if (lastDotSegment(name)) |simple| {
            scratch.reset();
            if (cg.get().isSubtypeOf(a, simple)) break :blk true;   // <- here
        }

    A QUALIFIED name is a precise identity, and this falls back to its last
    segment, so `isRuntimeType("Map.Entry")` answers true for a user class
    named `Entry`. `receiverCompatibleWithParam` then admits the extension.
    (That function also returns true unconditionally for any `.Instance`
    receiver, so the qualified-name test is the only guard in the path.)

    The fallback cannot simply be deleted: many stdlib classes are registered
    under a SIMPLE name while the query arrives qualified
    (`kotlin.collections.List` against a class registered as `List`), and every
    one of those depends on it. The fix has to distinguish "the query is
    qualified because the class is nested" from "the query is qualified because
    the caller spelled the package", which means comparing the receiver
    hierarchy's FQNs against the query as a suffix rather than comparing last
    segments.

    It is not optional — a user type named after any nested stdlib type
    silently inherits that type's extensions today, and `Entry` is only the
    instance that happened to surface.

    TWO GUARDS WRITTEN AND MEASURED, NEITHER ON THE PATH. Both used the same
    discriminator, which is sound and is the one this codebase already applies
    to pack aliases: a qualifier whose last segment begins with an uppercase
    letter is a CLASS (`Map.Entry`), a lowercase one is a package
    (`kotlin.collections.List`), and only the former makes the simple-name
    fallback wrong.

      1. Refusing the fallback inside `Value.isRuntimeType`'s `.Instance`
         branch. No effect — `receiverCompatibleWithParam` returns true for an
         Instance before ever calling it.
      2. Guarding `receiverCompatibleWithParam` itself so a nested-classifier
         receiver must actually match. Also no effect.

    SELECTION SITE FOUND, and it is not at run time at all. A `callFunc` probe
    over every `component*` name prints NOTHING for this program, and
    `KLIO_EMIT_TRACE='*'` emits no `component2` call either. `Map.Entry`'s
    accessor is declared

        public inline operator fun <K, V> Map.Entry<K, V>.component2(): V = value

    — INLINE, so lowering splices its body straight into the caller and the
    failure is a bare `value` field read on the user's `Entry`. There is no
    call to intercept, which is exactly why two runtime guards changed nothing.

    That vindicates the ORIGINAL diagnosis in this entry: the selection is
    `Module.staticTypeHead` bucketing an extension by
    `applicability.simpleName`, so `Map.Entry` indexes under `Entry`. The fix
    belongs in the lowering-side extension resolution
    (`resolveExtensionCall` / `resolveExtensionCallForArgs`), where the
    uppercase-qualifier discriminator recorded above applies unchanged: an
    extension whose declared receiver is a NESTED classifier must not match a
    receiver that is not that nested type.

    THIRD GUARD, ALSO NOT THE PATH. `Module.staticHeadCompatibility` (the
    `actual_head` / `param_erased_head` comparison in `ir.zig`) was given the
    nested-classifier test: when the param names one, require
    `classIdIsOrExtends` rather than accepting a head match. No effect on the
    reproducer, so either that function is not consulted for this splice or
    `staticTypeClassId` answers null for one side.

    Cost so far: three guards, all revert-only, and the pattern in the misses
    is consistent — each was placed by reading code that LOOKS like the
    decision point instead of by observing the decision. What is actually
    established is narrow and worth stating plainly:

      - the failure is an inline splice of `Map.Entry.component2`, so no call
        is emitted and no runtime dispatch runs (proved by `KLIO_EMIT_TRACE`
        and a `callFunc` probe, both silent)
      - it is a name collision, not a typing bug (proved by renaming the class)
      - it is NOT decided by `Value.isRuntimeType`, `receiverCompatibleWithParam`,
        or `staticHeadCompatibility` (proved by guarding each)

    FOURTH MEASUREMENT: not that splice entry either. A print at
    `inline_call.zig`'s expand entry, for any `component*` name, is also
    SILENT on the reproducer.

    So the body is reaching the caller without going through the call emitter,
    `callFunc`, or the inline-expand entry. The error text is the remaining
    clue and it is specific: `Vm::get_field \`value\` on \`Entry\`` means
    lowering emitted a **GetField named `value`** against the Entry receiver —
    i.e. `Map.Entry.component2`'s one-expression body was folded in by an
    accessor/property fast path rather than expanded as an inline call.

    So the search is: which lowering path turns `e.component2()` into a
    GetField. Twenty `GetField` emitters exist in `lower/expr.zig`; none of the
    obvious ones (the safe-call arm, the `super.<prop>` arm, the this-field
    arms) reads a resolved accessor.

    MEASURED, AND NEGATIVE — the fifth exclusion.
    `resolveCallableExtensionProperty` IS reached for both accessors and it
    MISSES both:

        [extprop] component1 recv_head=Entry is_class=false hit=false
        [extprop] component2 recv_head=Entry is_class=false hit=false

    It passes the bare simple-name head, as suspected, but it is not the
    selector here. That also rules out the whole "member call folded into a
    property read" theory the GetField in the error suggested — the property
    resolution declines.

    Five paths now excluded by experiment: `Value.isRuntimeType`,
    `receiverCompatibleWithParam`, `Module.staticHeadCompatibility`,
    `inline_call`'s expand entry, and `resolveCallableExtensionProperty`. The
    call emits no `Call`/`CallMember`, never reaches `callFunc`, and is not
    inline-expanded — yet a `GetField value` lands on the receiver.

    EMITTERS NAMED. A print on all twenty `GetField` pushes in
    `lower/expr.zig`, gated on the field name, run against the reproducer and
    against the renamed control:

        Entry (fails):  lower/expr.zig 1624, 1903, 2200, 2254, 2374
        Rec   (works):  none

    Five sites, and ZERO of them fire once the collision is removed — so every
    one is downstream of it, not incidental. Line 2374 is the plain member
    property read (`lowerReceiver` then `GetField name`), and 2200 is the
    `hasOwnMember` this-field read; the other three are the same pattern in
    other arms.

    CORRECTION to the reading above. Line 2374 is the FINAL fallback of the
    member-property read and emits `GetField <name>` — for a `component2` read
    it would emit the field `component2`, not `value`. So these five sites are
    not the `component2()` call at all: they are `Map.Entry.component2`'s BODY
    (`value`) being lowered. Which means the accessor body IS getting inlined,
    just not through `inline_call.zig`'s expand entry, and the resolution that
    chose `Map.Entry.component2` happens strictly BEFORE any of them.

    So the five lines are a symptom, not the site — the same mistake as the
    five selector probes, made from the other direction. What the control diff
    does establish is that nothing in this chain fires without the name
    collision, which is worth keeping.

    PROGRAM NARROWED — and this is the artifact worth keeping. Four two-line
    files, one variable each:

        class Entry(val key: String, val num: Int)          e.num           OK
        data class Entry(val key: String, val num: Int)     e.component2()  FAILS
        class Entry(...) { fun component2(): Int = num }    e.component2()  OK
        data class Pairish(...)                             e.component2()  OK

    So the failure needs BOTH: a DATA class — whose `componentN` is synthesized
    at run time in `host_call_member.zig` and therefore has NO IR declaration
    for the member path to find — AND the name `Entry`. An explicitly written
    `component2` fixes it, because a real member wins before the extension
    fallback is ever reached.

    That names the mechanism exactly: the member lookup finds nothing (the
    synthesized accessor is invisible to lowering), the call falls through to
    EXTENSION resolution, and the extension index matches `Map.Entry` to a
    user `Entry` by simple head.

    Two fixes are possible and the first is probably better:

      1. Give a data class's `componentN` a real declaration at lowering, so
         the member path finds it and no extension is consulted. That also
         removes a whole class of collisions rather than this one.

         Located: nothing in lowering knows about data-class members at all —
         the only `is_data` in `lower/decl.zig` is a `= false` initialiser, and
         the synthesis lives entirely in `host_call_member.zig` at run time.
         `collectClassMemberNamesInto` and `collectHierarchyShadowNames`
         (`interp_ir/build.zig`) walk DECLARED members, so `componentN` is
         absent from `class_member_names` and from every per-class shadow set,
         and `resolveMemberCall` walks declarations too. The accessor is
         invisible to all three.

         So the change is to emit `componentN` declarations for a data class's
         primary-ctor properties during class lowering — `decl_sigs` entries
         with the property's declared type as the return type, bodyless, served
         by the existing runtime synthesis. Feeding the name sets alone is NOT
         enough: `resolveMemberCall` consults declarations, not those sets.

         Implementation shape, worked out but not written. The registration
         site is `lower/decl.zig` around line 1046, where each member function
         gets its `decl_sigs` entry; a synthesized accessor needs the same
         three things a real one has:

           - a `FuncId` from `module.nextFuncId()` and a bodyless `Func`
             (`params = [this]`, `return_ty` = the property's declared type,
             `kind = .instance_method`)
           - an entry in the class's `methods` list, so the slot linker sees it
           - a `decl_sigs` record with `has_body = false`

         DONE, and the bodyless risk was avoided by not being bodyless. The
         accessor is synthesized as an `ast.Function` with an expression body
         reading the property (`this.<name>`) and run through
         `lowerMethodWithMemberContext` like any other member, so `decl_sigs`,
         `member_method_fids`, the default-arg bookkeeping and an executable
         body all fall out of the existing path. A hand-written `componentN`
         suppresses the synthesized one, which is what Kotlin does, and the
         run-time synthesis in `host_call_member.zig` then sees a user method
         and stands down on its own.

         Census A/B on both file sets: no movement on either beyond the two
         sites the new bodies themselves add. It is a correctness fix.
      2. Make extension receiver matching FQN-aware for nested classifiers.
         Attempted at `staticHeadCompatibility` twice, including an FQN-suffix
         comparison, with no effect — that function is demonstrably not
         consulted for this match, so find the one that is before trying a
         third time.

    The discriminator is written, correct, and has been staged at five sites
    this call does not reach. It has never been the hard part; locating the arm
    has.

    The uppercase-qualifier discriminator (a qualifier segment beginning with a
    capital is a CLASS, so its simple name is not an identity) is written and
    correct — it has simply been applied at four sites that this call does not
    reach. Once the site is known it drops in unchanged.

    The destructured-component typing sits on top of it and is now landed;
    `data_class_components_are_declared_members` pins the program the collision
    broke, with the name `Entry` unchanged.

    The typing itself was written and measured at ~0 on BOTH censuses (for-loop
    destructuring is rare in the corpora), so it is not landed — there is
    nothing it can be shown to bind while the data-class case cannot execute.

Neither will move the pinned stdlib set for the same reason the loop variable
did not, so BOTH censuses matter from here:

    scripts/dispatch-census.sh           stdlib commontest — generic throughout
    scripts/dispatch-census-examples.sh  the examples corpus — concrete types

Examples baseline, the platform the plan asked for and now has:

    total 72,412 member call sites
      1,449   2.00%  bound_static
     25,649  35.42%  bound_virtual
     -------------------------
     31,422  43.39%  no_receiver_type
      8,702  12.02%  no_class_id
      3,912   5.40%  resolver_declined
      1,278   1.76%  nullable_or_generic

27,098 of 72,412 (37.4%), against 34.6% on the stdlib set — concrete code binds
better, as it should. Report both numbers for anything aimed at element types;
a change that moves one and not the other is not thereby worthless, and this
document has twice nearly discarded such a change for exactly that reason.

### LANDED: typing a local from its initializer

Kotlin's inferred type for `val x = f()` IS `f`'s return type, and a `var`'s
later assignment must conform to it, so the initializer's type is the local's
type at every use. `localInitTypeRef` feeds the two places that already call
`staticCallReturnTypeRef`, gated on `staticClassifierArgsComplete` — a derived
head whose type arguments are unknown disproves candidates a null type would
have left open.

    bound  1,853 -> 2,140 of 6,929   (30.9%)

A CONSTRUCTOR initializer is derived too, and needs no return type at all:
`val x = Foo()` reaches the census as `no_func`, because the callee resolves to
a class rather than to a function.

It took ten attempts, and the nine that failed all share one shape: they
theorised about WHICH overload was selected without first measuring WHICH CODE
RAN. The probe that ended it is four lines in `callFunc`:

    [whosum] callFunc fqn=kotlin.sequences.sumOf fid=1961 body=true native=false

`body=true` is the whole answer. `Sequence.sumOf` declares five overloads that
differ ONLY in the selector's return type — `(T) -> Double` first, then Int,
Long, UInt, ULong — and Kotlin picks among them by the lambda's INFERRED return
type, which lowering does not have. With a typed receiver the call reached
those Kotlin declarations and the pick fell to declaration order, so
`sumOf { it.length }` ran the Double body and returned 6.0 for a sum of 6.

Registering a host `kotlin.sequences.Sequence.sumOf` did NOT fix it on its own,
because the declaration join at `linkResolvedForms` skips a body-bearing
symbol — the intrinsic was linked for nothing. `intrinsicOverridesBody` now
names the few symbols whose host implementation must serve anyway. This one
qualifies on both counts: it reads the accumulator kind from the first value it
computes, which is the answer Kotlin's typed selection reaches, and
`iterableItemsCtx` drains a host `.Sequence` and an interpreted one alike, so it
covers the same receivers the Kotlin body does.

What NOT to repeat, all measured:

  - rejecting a derived type whose arguments are still the declaration's own
    type parameters — costs 12 sites, fixes nothing (removed once the real
    cause was found)
  - requiring the initializer's callee to be `unique_concrete` — costs 384
  - a `returnTypeAmbiguous` gate on `staticCallReturnTypeRef`: costs 18 scoped
    to the receiver head, breaks `SequenceTest.zipWithNext` scoped
    program-wide, and does not close the failure either way
  - the pipeline lambda's BODY is not a variable: `onEach { }` and
    `onEach { count += it.length }` behave identically

The lesson worth keeping, since it cost nine rounds: when a stdlib call returns
the wrong thing, find out which function executed before reasoning about which
one should have.

### 1. `no_receiver_type` — 6,720 (68.9%). Needs typeck.

Broken down by receiver shape and, for the dominant `Path` shape, by what kind
of name it is:

    4,317  Path      of which  3,513  a live local with no recorded type
                                 356  unknown
                                 283  captured
                                 161  an enclosing class member
    1,709  Call      (a call result)
      286  Binary
      256  Member
      (Index/Unary/Postfix/This/ObjectExpr under 1.5% combined)

Of the 3,513 untyped locals, 2,499 have an initializer whose type cannot be
derived and 1,014 have no initializer recorded at all (loop variable, lambda
parameter, destructured component). Catch parameters USED to be in that last
group and are now typed.

The blocker is generic containers: typeck does not know an `Array`'s or a
`List`'s element type at ~3,800 sites, and a head without arguments is worse
than no answer (it disproves candidates a null receiver type would have
reached). This is the one bucket that genuinely requires a typeck project —
substituting type arguments through call sites and propagating them from
declarations. Everything else below does not.

### 2. `resolver_declined` — needs no typeck. Interface receivers LANDED.

Every deferral reaching the post-target path is `target_known_deferred`: the
resolver has ALREADY identified the declaration and withholds only the dispatch
commitment, because an argument's type is unknown so applicability is unproven.

Promoting those to a real dispatch, guarded by `extCouldApply`, landed first for
class receivers. Interface receivers are now included too, and the whole
`ContinuationInterceptorKeyTest` investigation resolved into a single linker
bug that had nothing to do with the promotion:

**The virtual-slot linker resolved an unqualified parameter type only against
the owner class itself.** A classifier written without a qualifier inside a
nested class names the ENCLOSING class's member, so `Key` in
`CoroutineContext.Element` is `CoroutineContext.Key`. `overridesSlot` compares
an override's parameter types against the base declaration's, so
`ContinuationInterceptor.minusKey(key: CoroutineContext.Key<*>)` and
`CoroutineContext.Element.minusKey(key: Key<*>)` compared unequal, the override
went unrecognised, and `preferredMethodSlotTarget` kept the base. Measured:

    [slot-merge] slot=128 existing=124 incoming=153 -> 124 (minusKey)
    [ovr] cand=153 base=124 name=minusKey/minusKey is_override=true
    [ovr]   type mismatch Key vs Key      <- the two spellings of one type

    before:  DerivedElementWithOldKey slot=128 -> fid=124 Element.minusKey
             CustomInterceptor        slot=128 -> fid=153 ContinuationInterceptor.minusKey
    after:   every class implementing ContinuationInterceptor -> fid=153

`CustomInterceptor` was right all along because it implements
`ContinuationInterceptor` directly, with no intermediate class contributing a
competing inherited entry — which is why `Comparator.compare` never regressed
and looked like a counterexample.

`overrideTypeClassId` now widens outwards along the owner's FQN, matching on
the full `scope.name` so a class sharing only the simple name cannot answer.
The bug was latent before the promotion: without a static virtual binding the
call dispatched by NAME at run time, which walks the receiver's own hierarchy
and finds the override anyway.

The host-backed half is handled where the plan predicted. An interface-typed
value need not be an interpreted `Instance` — a `Sequence` is a generator — so
`invokeVirtualMember` resolves the slot against the value's runtime class and
falls back to the member's name only when that class implements it natively
and there is no body to enter.

Measured cold A/B on one pinned file set (`scripts/dispatch-census.sh`), for
the whole of this session's dispatch work — interface receivers plus the
safe-call binding below:

    before:  bound_static 144  bound_virtual   6  = 150 / 6403   2.34%
             resolver_declined 1670   nullable_or_generic 122
    after:   bound_static 144  bound_virtual 176  = 320 / 6485   4.93%
             resolver_declined 1540   nullable_or_generic 122

+170 statically bound sites, a 113% increase. Full stdlib sweep 117 files / 0
failures, compose 148/148.

A measurement trap found the hard way, and the reason the census script now
clears the cache: **lowering is on demand, so a warm run lowers roughly half
the program.** A warm run of this same set reports total=3519 against a cold
6485, and every bucket scales with it. An earlier A/B in this session compared
a cold "before" against a warm "after" and read a bound_static DROP from 144 to
72 that did not exist. Two censuses are comparable only at the same cache
state; the script clears it so that state is always cold.

The extension guard is now arity-aware: the index records each name's merged
argument-count range (required, total, unbounded for a vararg) and a call whose
count falls outside it cannot select that extension. Worth +4 sites, which is
the honest measure of how much of this bucket was shape conservatism.

**And that closes the bucket as a separate lever.** The 180 sites left are real
Kotlin shadowing pairs, named by `KLIO_PROMO_NAMES`:

      90  Random.nextInt          nargs=1  own_head
      12  ClosedRange.contains    nargs=1  generic_receiver
       8  ArrayList.addAll        nargs=1  declared_super
       6  MutableSet.removeAll    nargs=1  builtin_super
       2  Map.get / Map.containsKey / List.indexOf / Comparable.compareTo …

Each has a member and a same-arity extension of the same name, and Kotlin picks
between them by ARGUMENT TYPE. Nothing about the guard can be tightened
further without that information, so this bucket now waits on the same typeck
work as `no_receiver_type` rather than standing on its own.

### 3. `no_class_id` — 747 (7.7%). Mostly type parameters, now partly solved.

Was 915. All of them were a bare head naming no class, and the heads are
overwhelmingly TYPE PARAMETERS:

    341 C    182 M    132 A    100 T    14 R      <- type parameters (769)
     22 UInt  18 UShort  18 ULong  18 UByte
     16 UByteArray  13 ULongArray  13 UIntArray  12 UShortArray   <- unsigned (~146)

Resolving a type-parameter receiver through its declared upper bound (Kotlin's
own rule) moves 168 sites out of this bucket. They land in `resolver_declined`
rather than binding, because their bounds are interfaces — so this bucket is now
gated on the interface work in section 2, not on anything of its own.

That gate is open now, and the bound rule was still refusing most of its own
work: it used only a `complete` bound record, and `complete` requires the bound
to carry NO type arguments. The stdlib's two dominant parameters are
`C : MutableCollection<in T>` and `M : MutableMap<in K, in V>`, so both were
excluded — 6,590 of the 8,702 sites in this bucket on the examples set, under
the heads `C` (4,456) and `M` (2,134).

The arguments are irrelevant to the question actually being asked. This site
asks only *which class owns a member call on this parameter*, and the answer is
the bound's head. `TypeParamBound` now carries `head_only` alongside `complete`:
true when the record still names one classifier (not nullable, not a function
type, not qualified, not an intersection) even though it dropped the type
arguments. `complete` keeps its old meaning for the negative proofs that need
it; only the owner lookup reads the new flag.

    stdlib   no_class_id 675 -> 187,   bound 3,121 -> 3,537   (45.6% -> 52.2%)
    examples no_class_id 8,702 -> 2,358, bound 36,876 -> 42,284 (50.9% -> 59.2%)

Landed alongside it: a local initialized from a PROPERTY READ now carries the
property's declared type. Only calls, literals and templates were recorded as
initializers, so `val node = coord.layoutNode` left the local untyped even
though `class_prop_type_heads` already knew the answer. `KLIO_TP_HEAD=0` and
`KLIO_MEMBER_INIT=0` turn the two off for an A/B from one binary; both are
pinned by parity fixtures that print the wrong answer when disabled, since
each changes which extension a static receiver type selects.

The property-read initializer also exposed a latent crash, and the A/B is what
found it — `compose_material3_text` segfaulted with the change on and ran with
it off. Following a local's initializer to derive its type can reach back into
that local: `val a = b.x` beside `val b = a.y` walks itself until the stack
ends. The `init != arg` guard only blocked a local reaching itself in ONE step.
Kotlin cannot write the cycle — a local is not in scope before its own
declaration — but lowering asks from a point where every local in the block is
bound, which is the same missing-position defect as the self-name entry above
and as the captured-write entry at the end of this document. THIRD instance;
treat any scope query that takes a name and no position as suspect.

Fixed by tracking the locals whose initializer the walk is inside and refusing
to re-enter one. Pinned by a unit test that overflows the stack without it.

### A bare name in an extension body belonged to the receiver

`KLIO_NORECV_NAMES=unknown` named the receivers behind the `unknown` bucket, and
two names were most of it — `storage` (2,208) and `indices` (484), both with
`owner=<none>`. They are the unsigned array classes, written as top-level
extensions:

    public val UByteArray.indices: IntRange get() = storage.indices

`staticBareReceiverType` searched only the ENCLOSING CLASS for the name's
declared type, and a top-level extension has none, so the search stopped before
it began. A bare name in an extension body is a member of the extension
RECEIVER written without `this.`, so the receiver's class is where to look —
including up its supertype chain.

    stdlib   bound 3,537 -> 3,595   (52.2% -> 53.7%)
    examples bound 42,284 -> 43,039 (59.2% -> 61.1%)

`KLIO_EXT_RECV_PROP=0` turns it off; `bare_name_inside_an_extension_body` pins
it, printing `derived` for a `Base`-declared property when disabled.

### An operator call has a declared return type like any other

`staticCallReturnTypeRef` answered for `plus` and `minus` and nothing else, and
for indexing it answered nothing at all — so `row[i].tag()` and
`(scale * 3).tag()` reached dispatch with no receiver type. Both are ordinary
member calls: `a[i]` is `a.get(i)`, `a * b` is `a.times(b)`. Added the `Index`
arm and `times`/`div`/`rem`/`rangeTo`/`rangeUntil` to the operator map, and
recorded an indexed read as an initializer so `val held = row[1]` carries
`get`'s return type too.

    stdlib   bound 3,595 -> 3,623   (53.7% -> 54.4%)
    examples bound 43,039 -> 43,056 (61.1% -> 61.5%)

`KLIO_OPERATOR_TY=0` turns it off; `receiver_typed_from_an_operator` pins all
five shapes and prints `derived` for every one of them when disabled.

### An alias keeps its source's type, whatever gave the source one

`val b = a` copied the source's type only when the source had a DECLARED one,
so a local typed by its own initializer instead — a property read, a call's
return type — handed the alias nothing and the chain broke at the first rename.
`KLIO_INIT_KINDS` named the gap rather than guessing at it: over four example
programs the unrecorded initializer kinds are `Path` 626, `Binary` 250, `If` 44,
`This` 26, and nothing else above ten. So the alias was the whole of it.

Recording a `Path` initializer, and following it in `localInitTypeRef` to the
source's own initializer, closes the chain to any depth; the cycle guard added
above is what makes following it safe.

    stdlib   bound 3,623 -> 3,627   (54.4% -> 54.5%)
    examples bound 43,056 -> 43,109 (61.5% -> 61.6%)

`alias_local_keeps_its_source_type` pins three depths and the declared-source
case, and prints `derived` for the first three when the channel is disabled.

### A null check narrows through an `&&` chain and past an early return

Two shapes, one defect, and the same one the `is`-chain entry describes: only a
condition that WAS the whole check narrowed anything.

    if (a != null && b != null) b.tag()      // b stayed nullable
    if (a == null) return; a.tag()           // a stayed nullable

Both matter because a nullable receiver is the ONE case Kotlin reaches a `T?`
extension over a member — so `b.tag()` bound `Base?.tag` where kotlinc binds
`Base.tag`. `narrowNullCheckAll` walks `&&` for the true branch and `||` for
the false one, and `lowerBlock` applies the false-branch facts to the rest of
the block when the guard's then-branch cannot fall through (`exprAlwaysExits`:
return/throw/break/continue, a block ending in one, or an if whose both arms
do).

Worth ZERO on both censuses — neither corpus writes a `T?` extension beside a
member — and kept anyway, because it is a wrong ANSWER rather than a missed
binding. `null_check_through_and_chain` pins all four shapes plus the
unguarded control, and gets three of them wrong when `KLIO_NULL_CHAIN=0`.

### A factory call names a property's type as a constructor does

An un-annotated property took its type head from a CONSTRUCTOR call and from
nothing else, so `val made = newBase()` registered none and every read through
it bound against the runtime class rather than the declared one. Accept a call
to a uniquely-named declaration with a declared return type, which is the same
evidence a constructor gives.

A constructor PARAMETER is the same evidence again — `private val held = start`
beside `class Holder(start: Base)` — and `KLIO_NORECV_NAMES=enclosing_member`
showed it was the WHOLE of that bucket on the examples set: `_start` 104,
`value` 98, `_endInclusive` and `_endExclusive` 52 each, then nothing above
four. The stdlib's ranges and `Lazy` are written that way.

Both are worth ZERO bound sites — the receivers acquire a type and then decline
at the extension guard instead — and both are kept for the same reason as the
null-narrowing entry: `property_typed_from_a_factory_call` and
`property_typed_from_a_ctor_parameter` print `derived` where kotlinc prints
`base`, so each was a wrong ANSWER, not a missed binding. What they do move is
`no_receiver_type` into `resolver_declined` (stdlib 2,271 -> 2,255,
examples 19,207 -> 18,999), which is the bucket the argument-type work unlocks.

### A sole global is the only answer, whatever the receiver context

`[no-recv-call] unique_concrete` counted 175 receivers whose callee names ONE
function with a concrete return type — the census said the type was knowable
and the real path still returned nothing. The cause is the deliberate refusal
just above it: a top-level pick made under a lambda's conservative receiver is
not evidence, so the code falls to the implicit-receiver walk and gives up when
that finds nothing.

The refusal is right in general and wrong when the name has exactly one
declaration program-wide and no enclosing receiver declares a member of it:
there is then nothing else the call could resolve to, whatever the receiver
context is. Used only where the receiver walk has already found nothing, so it
never outranks a real member.

    stdlib   bound 3,627 -> 3,639   (54.5% -> 54.7%)
    examples bound 43,109 -> 43,243 (61.6% -> 61.9%)

### The generic project's first landing: the initializer chain reaches receivers

The first slice of the generic-argument project, and it is two rules, not a
new inference pass:

1. **The receiver walk asks the full chain.** The `Member` and `Index` arms of
   `staticCallReturnTypeRef` typed their receiver from a declared type or a
   call's return type, never from the type a local's own INITIALIZER lends it.
   `val xs = listOf<Base>(...); xs[0]` is that shape, and every generic factory
   writes it. Both arms now go through `recvChainTypeRef` (gate:
   `KLIO_RECV_CHAIN`), which is the same `staticExprTypeRef` chain every other
   consumer already uses.
2. **An explicit type argument is final.** `instantiatedCallReturnType`
   demanded that every value argument EQUAL the bound the pattern had, so
   `listOf<Base>(Derived())` — where the value argument is a strict subtype of
   the written argument — rejected the whole instantiation and left the
   receiver untyped. Kotlin takes a written type argument as final and does
   not infer the parameter from the value arguments at all; the binding now
   carries `explicit` and skips the equality check.

Pinned by `generic_receiver_through_its_initializer`: five shapes (explicit
list, explicit array, inferred, declared, member call), exact kotlinc parity
with the gate on, four of five wrong with it off.

    stdlib   bound 3,639 -> 3,645   (54.7% -> 54.9%)
    examples bound 43,243 -> 43,301 (61.9% -> 62.0%)

`resolver_declined` grew on both sets (405 -> 451, 3,429 -> 3,697): a newly
typed receiver that finds BOTH an applicable member and an applicable
same-arity extension moves into the declined bucket instead of binding. That
is the already-recorded blocked-pair population getting bigger, which is what
every receiver-typing fix does until the argument side of the inference
exists.

### The second slice: a parameter is inferred from every constraint together

Probing today's residue (`KLIO_LI_NAMES` over the census set: bare/member
`iterator` 230, `.getOrPut` 66, `toMutableList` 43) established that the
substitution machinery already works for concrete callers — `getOrPut`,
`toMutableList`, `getValue`, `getOrElse` all type correctly in a plain
`main()`; the stdlib-set misses are generic-caller residue, the stdlib testing
itself. The one WRONG ANSWER left in the family was `getOrDefault`, and it was
two defects stacked:

1. **No declaration existed at all.** On the JVM `getOrDefault` is a member of
   the `Map` builtin (`jvm/builtins/Collections.kt`), which the compiled
   common surface never declares — klio served it purely by name from the
   host table, so no call site could carry its return type. Declared now in
   `kotlin-klio/kotlin-collections/MapActuals.kt` with the JDK's exact
   semantics (a `null` value for a PRESENT key returns as-is, not the
   default). Statically typed sites run the interpreted body; untyped sites
   keep the host member.
2. **`bindCallType` demanded constraint EQUALITY.** With the declaration in
   place, the receiver bound `V=Base` and the value argument `Derived()` then
   had to equal it, so the whole instantiation was rejected and the site
   stayed untyped. Kotlin infers a parameter from every constraint together.
   A subsumed constraint now keeps the subsuming side — `actual ⊆ bound`
   keeps the bound, `bound ⊆ actual` widens the binding, nullability carried
   in both directions — and genuinely unrelated constraints (where kotlinc
   would compute a common supertype neither side names) still refuse rather
   than guess. Gate: `KLIO_BIND_LUB`.

The widen direction also fixes mixed-element factories: `listOf(Derived(),
Base())` now types `List<Base>` in either element order.

Census: UNCHANGED on both sets — the sixth wrong-answer fix this campaign
that is invisible to the census and visible only as kotlinc parity. Pinned by
`generic_argument_from_every_constraint` (gate on: exact parity; off: four
wrong answers of six lines).

### The third slice: a receiver typed by a type parameter reads its full bound

Ranked by `KLIO_LI_NAMES` on the EXAMPLES set, the residue was `.getOrPut`
834, `iterator`/`.iterator` 919 combined, `toMutableList` 442 — and the
getOrPut receivers were all typed `M`, a type parameter (`M : MutableMap<in
K, MutableList<T>>`, the shape `groupByTo` and every grouping helper write).
The call-site gate already resolves a member call on such a receiver through
the parameter's bound, but the bound RECORD keeps only the head name — the
type arguments the return-type instantiation needs were dropped at
declaration lowering.

The builder now keeps the full lowered bound (`type_param_bound_refs`)
beside the string record, and `staticCallReturnTypeRef`'s Member arm
substitutes it when the receiver head names no class. A use-site projection
in the bound (`in K`) is stripped at that boundary: the engine has no
capture conversion, a captured argument behaves as the plain parameter for
deriving a return type, and a projected parameter surviving into a result is
an unresolved name the completeness guards refuse anyway. Gate:
`KLIO_TP_RECV`.

    stdlib   bound 3,645 -> 3,709   (54.9% -> 55.9%)
    examples bound 43,301 -> 44,133 (62.0% -> 63.2%)

The examples gain (-832 `no_receiver_type`) is almost exactly the measured
getOrPut population (834): one channel, one bucket. Pinned by
`receiver_typed_through_its_parameter_bound` — the un-projected and
projected shapes both, exact kotlinc parity with the gate on and a wrong
extension pick with it off.

Still open in the residue, in order: `iterator`/`.iterator` (919 examples /
230 stdlib — the initializer sits in bodies whose implicit receiver carries
no type arguments at all, so instantiation refuses before any bound is
involved), `toMutableList` 442, `nextInt` 182, `lines` 130.

### The fourth slice: a bare call may be an extension of the implicit receiver

The bare-call arm resolved MEMBERS of the implicit receiver but never its
EXTENSIONS, so `toMutableList()` written inside an `Iterable<T>` extension
body found no target at all — and every stdlib body writes that shape. The
arm now falls to `resolveExtensionCall` with the same receiver, members
first exactly as Kotlin orders them, and an applicable-but-unproven member
still wins the deferral. Gate: `KLIO_BARE_EXT`.

    stdlib   2,144 -> 2,044 no_receiver_type, total 6,638 -> 6,538 (56.7% bound)
    examples 18,041 -> 16,762 no_receiver_type, total 69,847 -> 68,568 (64.4% bound)

The arm also serves a receiver head with NO class id at all — `UShortArray`
and the unsigned-array family have extensions but no classes — which moves
their downstream sites from `no_receiver_type` into `no_class_id` (32 stdlib,
416 examples): the receiver is now NAMED, and what those sites wait on is the
unsigned-array types getting a members-by-head answer. The exposing crash was
its own latent bug, fixed separately: `lowerResolvedExtensionCall` read its
resolved-target pointer after receiver lowering, which can append to (and
move) the function table.

The bound sites leave the member census (they are extension calls now), so
the gain shows as the DENOMINATOR shrinking: 100 stdlib and 1,279 examples
sites moved from unresolved-member to statically-bound-extension. Pinned by
`bare_extension_call_in_a_receiver_body`, which reads an element out of the
derived local — the runtime class answers with the gate off.

### Two resolver defects under the iterator residue, and one measured zero

Chasing the iterator population surfaced `.iterator on Set member applicable
but deferred` — a ZERO-ARGUMENT member call on a known receiver head that
still refused to bind. Two independent defects, both fixed and both pinned by
module tests on the Root/Redecl (and generic GRoot/GRedecl) families:

1. **A redeclaration chain scored as an overload tie.** `Set.iterator`
   overrides `Collection.iterator` overrides `Iterable.iterator`; all three
   reach the candidate list, score identically, and the equal score set
   `tied` — which defers. Redeclarations of one virtual family are not a
   tie: the override relation now picks the overriding declaration, and a
   genuine tie between unrelated members still defers.
2. **A bare receiver head turned a zero-argument call unknown.** The
   receiver's type arguments exist to instantiate PARAMETER types, but the
   projection ran before looking at the arguments — of which there were
   none — so an unprojectable bare `Set` marked `iterator()` unknown and
   the site deferred.

Census: UNCHANGED on both sets. The deferral sat on type-DERIVATION queries,
not on emitted call sites, so fixing it feeds later channels rather than
binding sites today.

**Measured zero, twice: head-only receiver evidence.** A slice that let a
local's derived type commit with a known head but unresolved arguments
(member binding only, extensions kept strict) measured zero on both sets, was
reverted, was re-tried after the resolver fixes above unblocked its feed, and
measured zero again. The mechanism: the population it targets sits in lambda
bodies where `bareStaticRecvHead` has NO answer at all (`with(xs) { iterator()
}` — `no recv head`), so there is nothing to commit head-only. A trace-reading
lesson is recorded with it: `[bareret] ... return=Iterator` prints only the
type's NAME — those 403 derivations were complete `Iterator<T>` answers
already committed by the strict channel, not bare heads. The iterator
residue's real prerequisite is RECEIVER EVIDENCE FOR LAMBDA BODIES — the
lambda's receiver type from its callee's signature and argument — which is
the eager-mode question, not another syntactic channel.

**And the regression the first slice exposed was a real dispatch bug.** With receivers of
type `MutableList` newly typed, `reversed.remove("c")` on an `asReversed()`
view bound through `MutableList.remove`'s own virtual slot — and that slot,
being a REDECLARATION of `MutableCollection.remove`, was linked to the
bodyless interface header in every class that inherited its implementation
from `AbstractMutableCollection` under the base declaration's slot. The
host-linked header then rejected the interpreted receiver at runtime
(`MutableList.remove requires a List receiver`). The same shape sat latent
under `MutableSet.remove`, reachable without any widening through a DECLARED
`MutableList` local. Fixed at the linker (`unifyRedeclaredSlots`), not by
narrowing the widening: see the commit
`ir: a redeclared interface slot reaches the inherited body`.

### Measured dead ends, all three with the reason

Recorded so none is retried. Each was built, measured on BOTH file sets, and
reverted at zero.

  0. **A Boolean result for the comparison and logical operators.** `a < b`,
     `a in b`, `a && b` all yield `Boolean` with no resolution needed, and the
     `Binary` receivers are 178 of the stdlib bucket. Returning it directly
     moved nothing in either census AND nothing into `no_class_id` either,
     which means those receivers are not those operators — the remaining
     `Binary` mass is `Elvis` and `Assign`, whose type is the operand's, not
     the operator's. Reverted.

  1. **A cast initializer lending its type.** `val n = x as Node` records
     nothing, so the local goes untyped even though `argDeclTypeRefLazy`
     already reads a cast's target type when the cast is the argument itself.
     Adding `.As` to the recorded initializer kinds moved 0 sites: casts as
     initializers are simply rare in both corpora.

  2. **The splice hint as the bare-receiver owner.** The `storage` sites
     (2,392, the largest single name in the `unknown` bucket) have
     `owner=<none>` and `recv=UByteArray`, so the extension-receiver fallback
     above should have answered them. It does not, and the reason is upstream
     of lowering: `unsigned/src/kotlin/UByteArray.kt` is not in
     `stdlib_sources.zig` at all — only `_UArrays.kt`, which holds the
     EXTENSIONS, is compiled. The class that declares `storage` has no IR
     declaration, so no property type head exists to find. Nor would binding
     help: `storage` is a `ByteArray`, itself a host builtin with no vtable.
     These sites belong to the host-symbol category, exactly as the unsigned
     scalars in section 3 do.

  3. **A type-aware extension guard.** `extCouldApply` merges its candidates'
     arities per (receiver head, name), which loses per-declaration signatures
     — so it can only ever answer on argument COUNT. Rebuilding the index to
     store candidate FuncIds and asking `applicability.applicable` per
     candidate makes it able to answer on argument TYPES as well. Built, and
     it rejected NOTHING: `[promo-blocked]` reads identically to the digit
     across all four sub-buckets.

     Extending it further, so a LITERAL argument disproves a candidate
     (`rnd.nextInt(1)` cannot mean `Random.nextInt(range: IntRange)`), rejected
     nothing either — and a per-candidate probe says why. Over a whole cold
     stdlib lowering, ZERO of the guard's queries carry a literal argument at
     all, and the ones that carry a declared type carry a broad one:

         [extlit] f5611 params=1 IntRange  | lit=- ty=-
         [extlit] f2522 params=1 Collection| lit=- ty=Iterable
         [extlit] f2624 params=1 T         | lit=- ty=Short

     Read them in order: the `nextInt` sites pass a local with no type at all;
     the `addAll` sites pass an `Iterable` against a `Collection` parameter,
     where the extension GENUINELY could apply because an Iterable need not be
     a Collection; the third's parameter is a type variable, which nothing
     disproves. So the blocked pairs are real ambiguities, not conservatism —
     the guard is already answering correctly and there is nothing left in it
     to tighten. Reverted; the bucket moves only when the ARGUMENTS acquire
     types, which is the same typeck work `no_receiver_type` waits on.

### Measured dead end: the bound fallback in the Member arm

`staticCallReturnTypeRef`'s `.Member` arm resolves its owner without the
type-parameter bound fallback, and `KLIO_BARERET=getOrPut` showed all 834 of its
sites exiting there with `on M no target`. Adding the fallback moved ZERO sites
on both file sets, and the reason is not plumbing: `M : MutableMap<K, V>` makes
`getOrPut` return `V`, the caller's own type parameter, which names no class
either. The bound record drops the bound's ARGUMENTS, so nothing downstream can
substitute them. Reverted. This bucket needs real generic-argument inference —
it is the typeck project, not a missing lookup.

The unsigned types (`UInt`, `ULongArray`, …, ~146 sites) are NOT a registration
gap, and calling them "probably easy" was wrong. `unsigned/src/kotlin/UInt.kt` is
not in `stdlib_sources.zig` at all — only `UIntRange.kt`, `ULongRange.kt` and
`UProgressionUtil.kt` are compiled. `UInt` is a host-implemented primitive
(`staticBuiltinConcrete` lists every unsigned type alongside `Int` and `Boolean`),
so there is no IR class to name and no vtable to index. Giving them a `ClassId`
would be inventing one.

These sites therefore belong to the host-member category in section 5, not to
`no_class_id` in any actionable sense. They cannot be bound by better type
information; they need a binding form that names a HOST SYMBOL directly. That is
the same requirement the C transpiler has, so the two should be designed
together rather than separately.

### 4. `nullable_or_generic` — safe calls LANDED; the rest is correct.

A nullable receiver type refused the whole site. Half of that was wrong: a
SAFE call's member runs on the branch where the receiver has already been
tested for null, which is exactly the receiver a member declaration expects.
The safe-call arm now attempts a static binding there and hands over the
register it already lowered, so the receiver expression is evaluated once.

What remains in this bucket is CORRECT to decline. For a non-safe `x.f()` on a
nullable `x`, an extension declared on `T?` is the only thing that can make the
call compile at all, and such an extension outranks a member. Binding the
member there would change which declaration runs. The 122 sites left on the
pinned set are that shape.

Note the counting: the safe-call sites were never in this bucket, because the
safe-call arm did not reach the census at all. Converting them RAISED the site
total (6403 -> 6485) rather than draining `nullable_or_generic`.

### 5. Host-backed members — LANDED. 1,226 sites bound.

`classifierReceiverAbi` marks the classifiers whose values the runtime
represents natively — `Int`, `String`, `ArrayList`, `StringBuilder`,
`Iterator`, and about 120 more. A numeric slot cannot index a vtable on such a
value, so lowering discarded the resolver's `.virtual` verdict at every site
with one of those as its static receiver:

    if (owner.is_value or owner.is_stub or ast_type_args.len != 0 or
        owner.receiver_abi != .instance) return .deferred;

That was 1,226 of the 1,540 declines, and it covered the most ordinary work in
the language — `ArrayList.add` (375), `StringBuilder.append` (128),
`Int.toLong` (74), `Iterable.iterator` (27).

**The slot is the right emission regardless of representation.** The receiver's
representation is a RUNTIME property; the slot names a declaration.
`invokeVirtualMember` resolves it against an interpreted receiver's own class,
so a user class implementing `Iterator` still gets its override, and against
the runtime class of a host-backed value otherwise.

Three defects had to be fixed for that to hold, each surfaced by the sweep
rather than predicted:

  - A slot with no entry for the receiver's class raised
    `virtual method slot is not linked`. It now dispatches by the member's
    name. A slot is a static hint, and when the runtime cannot honour it the
    site should behave as it did before it was bound, not fail.
  - The same for a slot resolving to a declaration with no body, no linked host
    symbol, and no SAM callable.
  - `invokeMethodFuncId` entered a frame for a bodyless declaration even when
    that declaration was linked to a host symbol, turning the call into an
    empty frame (`virtual method target is not executable` from
    `GroupingTest`). It now routes those through the call path that consults
    the linkage. This was a latent bug, not one this change introduced — it
    only became reachable once these slots bound.

**And the host symbol is now reached by FuncId, not by name.** A slot resolved
against a host-backed receiver's runtime class was only used when its target
had a Kotlin body; every native member fell through to `callMemberNamed`, so
the slot identified the declaration and the runtime matched it by string
anyway. A bodyless declaration linked to a host symbol is executable AS that
symbol (`DeclSig.host_symbol` -> `ProgramImage.resolved_native` ->
`src/stdlib/implementations.zig`, a static table of 1,578 `{fqn, StdlibFn}`
entries), so it dispatches by FuncId. On one collections file that is 1,163
calls per run reaching their implementation with no name compare
(`KLIO_NOINST_TRACE`).

That table is also exactly what a C transpiler emits: one entry per host
symbol, and a call site that names its entry.

Landing it exposed three latent name-keyed defects in how a bodyless
declaration is linked to an executable form, all of the same shape — identity
by SIMPLE NAME:

  - The same-package sibling scan settled `kotlin.Double.equals` with
    `kotlin.String.equals`. A receiver-formed header now only accepts a sibling
    declared by the same owner.
  - The bare-name map did the same, carrying `equals` to the package-level
    string form. That map names top-level functions and cannot settle a member
    header at all.
  - The sibling redirect ran BEFORE the declaration's own linked symbol. Its
    own implementation outranks another class's same-named one.

The package guard already in that code was added for this exact shape in
another guise. Simple-name identity keeps producing the same bug.

Remaining in this family: 98 `virtual_owner_stub` and 30 `virtual_owner_value`.
A stub class is declaration-only and a value class has no instance identity, so
both need the host-symbol route above rather than a slot.

The unsigned types from section 3 (`UInt`, `ULongArray`, ~146 sites) belong
here too: host primitives with no IR class.

### 6. `CallMemberOrGlobal` — 2,436 sites, and what actually blocks them

`CallMemberOrGlobal` exists because a bare name in a receiver context could be
a member of an implicit receiver or a top-level function. Where nothing in the
receiver chain declares the name and no extension of it fits the call, only the
top-level reading remains, and the site has a static target.

Emission census on the collections file set (`KLIO_OR_AUDIT`):

    2436  unresolved_bare_call
     628  implicit_this_call_global_fallback
     548  bare_call_member_shadowable
    1420  bare_ctor_shadowed_by_class      <- NewInstance, already static

The receiver-side guards are NOT the blocker. Measured over those sites, the
breakdown of why a static bind was refused is:

    2329  receiver class declares the name, and an extension fits
    1889  nothing declares it, but an extension fits
     124  nothing declares it and no extension fits  <- should have bound
    4926  the scoped candidate set was EMPTY
      10  the scoped candidate set held exactly one declaration

`boundedCallCandidates` answers null at nearly every one of these sites, and
`KLIO_BCC_WHY` says why:

    5403  no-visible-tier    <- candidates exist, none is a top-level function
     488  no-candidates
     265  no-arity-match

The `no-visible-tier` names settle it — `isEmpty` (793), `get` (322),
`contains` (86), `sort` (71), `append` (65), `toList`, `apply`. These are
MEMBERS and EXTENSIONS. `lowestVisibleGlobalTier` skips anything whose
`declarationKind` is not `.plain`, so it correctly reports that the site has no
top-level reading at all.

**So an earlier note in this document was wrong, and is corrected here: this is
not a gap in the pack-provided candidate index.** These bare calls really are
member calls on an implicit receiver, written without `this.`. Their static
answer is a MEMBER bind against the implicit receiver's type — the same
resolution the explicit-receiver path already performs — and it needs that
receiver's type.

The obvious slice was built and MEASURED, and it does not pay: wiring
`bareStaticRecvHead(b)` into `resolveMemberCall`, handing over the `this`
register through the same `ReceiverState` the safe-call binding uses. Result on
the pinned set:

    census total   6485 -> 7477   (the bare sites now enter the census)
    bound_virtual  1408 -> 1426   (+18)
    no_class_id     617 -> 1583   (+966)

Of the ~992 bare-member sites the arm actually reaches, 966 have an unsigned
array receiver (`UByteArray`, `UIntArray`, `ULongArray`, `UShortArray`) — the
host primitives with no IR class, section 5's category — and only 26 resolve at
all. Naming the head by FQN rather than by unique simple name changed nothing;
the heads already resolve (`kotlin.CharSequence`, `kotlin.Array`,
`kotlin.String`).

The gap between 5,403 and ~992 is sites where `b.resolve("this")` is null: the
receiver is a CAPTURE, not a bound parameter. So the real prerequisite for this
family is reaching a captured implicit receiver statically, which is the
`*OrGlobal` capture-slot problem this document describes elsewhere — not
receiver typing.

Not landed. Do not rebuild it without first fixing the captured-receiver reach.

### 7. Genuinely dynamic by design

  - `LoadFromThisOrGlobal` / `StoreToThisOrGlobal` — the bare-name read/write
    walks over implicit receivers. Same shape as section 6 and blocked on the
    same index.
  - `invoke` on a function value, and SAM conversion.
  - Reflection (`::member`, `KClass`) — the one category intended to stay
    dynamic and to be omitted where it cannot be.

### Ordering for the sweep

1. ~~Host-backed receivers~~ — LANDED, 1,226 sites, including the host-symbol
   dispatch itself. What is left is the 128 stub/value sites, which need the
   same route from a receiver representation that has no runtime class to look
   the slot up against.
2. ~~Tighten `extCouldApply`~~ — DONE and closed. The arity filter landed; the
   180 sites left are genuine member/extension shadowing pairs that need
   argument types, so they fold into item 3.
3. **Reach a CAPTURED implicit receiver statically (section 6).** The bare
   member-call bind is built and measured at +18 without it, because the
   receiver is a capture at ~4,400 of the sites. This is the prerequisite for
   the whole `*OrGlobal` family.
4. **The typeck generic-argument project — 3,886 sites, 60%.** The largest
   remaining piece and the only one that requires typeck work: substituting
   type arguments through call sites and propagating them from declarations, so
   a `List`'s or an `Array`'s element type is known. Note that +253 of it is
   already reachable without any of that — see the local-initializer entry
   above, which needs only the `plusElement` emission fixed.

Nullable receivers (section 4) are done as far as they should go: safe calls
bind, and the rest is correct to decline.

### Measured: what is actually missing is a call's return type

The widening argument above ends at "typeck's generic inference is the
bottleneck." That was inferred from the widening's own audit. Measuring the
`no_receiver_type` bucket directly gives a different and much more actionable
answer, and it does not implicate generic inference at all.

Census on the collections/comparisons file set (`KLIO_DISPATCH_STATS`, the
`[no-recv]` / `[no-recv-path]` / `[no-recv-init]` / `[no-recv-call]` tags):

    [lower-sites] total=6958   bound_static 150 (2.16%)  bound_virtual 6 (0.09%)
                               no_receiver_type 5091 (73.17%)

    receiver SHAPE of the untyped sites (total 6720)
        4317  64.24%  Path          <- a plain name
        1709  25.43%  Call          <- a call result
         286   4.26%  Binary
         256   3.81%  Member
        (Index/Unary/Postfix/This/ObjectExpr all under 1.5%)
        eager-has-head=1110  eager-no-head=5610

    what KIND of name the Path receivers are
        3513  local_no_decl_type   <- a LIVE local whose type was never recorded
         356  unknown
         283  captured
         161  enclosing_member

    of those 3513 locals
        2499  init_yields_no_type
        1014  no_init_recorded     <- loop var, lambda param, destructured, catch

So 3513 of 6720 untyped receivers (52%) are locals that lowering has in scope
and simply has no type for, and 2499 of those have an initializer whose type
it cannot derive. Classifying every call in that position (the 2499
initializers plus the 1709 direct `Call` receivers) against the strict
condition "does one declaration fix the return type":

         715  unique_concrete      <- a declaration-backed answer exists
        1237  ambiguous_return     <- same-named declarations disagree
         770  no_func
        1476  not_simple_callee    <- `x.foo()`, needs its own receiver first
          10  unique_unresolvable

`argDeclTypeRefLazy` has channels for a LOCAL function's return type, a
function-typed parameter, and a constructor call. It has NO channel for an
ordinary function's declared return type. That is the gap: 715 sites where the
answer is written in the declaration and nothing asks for it, and 1237 more
where the answer exists once the call is resolved against its argument shapes,
which the module resolver already knows how to do.

This reframes Phase 1. The rule to implement is:

**a call expression's static type is the declared return type of the
declaration the call resolves to.**

That is ordinary Kotlin resolution, not generic inference. It needs no
instantiation-specific evidence, so it does not touch the
identity-by-position hazard that blocks the type-head widening, and it is
what unblocks the `not_simple_callee` sites too: once a local's type is
known, `x.foo()` has a receiver type and can resolve, whose return type types
the next local, and so on. The buckets feed each other.

Sequencing note: implement it through the FQN-aware resolution path. The
census above counts candidates with `funcsBySimpleName`, a SIMPLE-NAME map,
which is exactly the trap that has produced repeated wrong answers in this
codebase; it is acceptable for bounding an opportunity and unacceptable for
deciding a binding.

### Attempted: the return-type channel. Not landed, and why

The rule the census points to was implemented — a call's static type is the
declared return type of the declaration `resolveBareCallIndexed` picks — and it
is NOT committed. Two findings from the attempt, both worth having before
anyone builds it again.

**`Func.return_ty` is ambiguous, and it bit immediately.** A function with an
expression body and no annotation gets `Unit` as a PLACEHOLDER
(`lower/decl.zig`, `interp_ir/build.zig`: `if (f.return_type) |rt| … else
typeUnit()`). Trusting it answered `Unit` for `h2`, `normalizeCapacity`,
`slotAddressOf`, `messagePrefix` and dozens more across androidx.collection and
the compose runtime — all of which return Int/Long/String — and broke every
compose suite at once. `Func.return_ty_declared` now records the distinction and
its doc comment says so; that flag IS committed, on its own, so the next
consumer of `return_ty` cannot repeat this.

**Even with that fixed, the channel breaks compose, and the cause is not the
channel.** Every remaining answer it supplied was individually defensible
(`Job() -> CompletableJob`, `currentSnapshot() -> Snapshot`, `mapCapacity() ->
Int`). What fails is `EffectsTests` and friends with `unresolved global
stateLock`. `KLIO_BARE_TRACE=stateLock` shows the deciding site:

    [bare-read] stateLock in=- known_global=false own=false encl=false
                splice_recv=- owner=Recomposer$RecomposerInfoImpl

Inside the nested `RecomposerInfoImpl`, `hasEnclosingMember("stateLock")` is
FALSE — lowering does not know the enclosing `Recomposer` declares it — so the
read takes the `GetField` on the nested class's own `this`, misses, and that
arm's fallback goes straight to the GLOBAL without consulting the enclosing
receiver chain. Better receiver types elsewhere change which of several
`stateLock` sites executes, and this one is already wrong.

So the blocker for the channel is a nested-class scope gap in bare-name reads,
not the channel's own answers. Fix `hasEnclosingMember` for a nested class's
outer properties (or make that arm's miss continue through the implicit
receivers instead of jumping to the global, which is the read-side mirror of the
`StoreToThisOrGlobal.recv` fix) and re-attempt. Do not re-attempt before that.

**Correction on the payoff.** An earlier draft of this section claimed the
channel bound +46 extra sites. That compared against a baseline captured from a
DIFFERENT build; a back-to-back measurement shows the current tree already
reports `bound_static 196` on the same file set WITHOUT the channel, so the
channel's gain was never measured at all. Measure against the same binary
before any number justifies the work — the same discipline the verification
playbook demands for timings applies to counters.

### FIXED: a placeholder `actual` shadowed klio's own renderer

`kotlin-klio/kotlin-internal/ThrowableActuals.kt` defined

    public actual fun Throwable.stackTraceToString(): String = this.toString()
    public actual fun Throwable.printStackTrace() { println(this) }

under a header comment reading "KLIO has no host stack-trace machinery". That
comment was stale: `throwableStackMember` in `host_call_member.zig` renders
frames, cause and suppressed through `formatThrowable`, and it is what served
these calls. It served them only because nothing could RESOLVE to the
placeholder while receivers were untyped. Type a receiver and resolution binds
the stub, and the trace silently loses its `Caused by:` chain while `cause`
itself stays correct.

The file is removed from `stdlib_sources.zig`'s embedded list and deleted, so
the host implementation serves every case. Reimplementing the renderer in Kotlin
was rejected: it walks internal stack/cell state and would drift on indentation
and circular-reference handling, and one implementation beats two.

That unblocked the first increment. **Catch-parameter typing is now landed** —
two lines at the handler's `bind` in `lowerTry`, recording the type that is
always written in the source. Pinned by
`tests/fixtures/parity_corpus/catch_param_static_type.kt`, which asserts both
halves: the handler's member call binds, and the trace still renders cause,
both suppressed sections, and the suppressed count.

Dead ends recorded so they are not retried. Two mechanisms were asserted and
disproved before the real one: a lost `addSuppressed` (`suppressedExceptions.size`
is 1 either way), and a bodyless `expect` entered as an interpreted frame,
disproved by a probe inside the resolver —

    [expectprobe] fid=5562 is_expect=false hasBody=true ds_has_body=true ast_body=true

`hasBody=true`; nothing about it was bodyless. That probe also showed
`Func.is_expect` is never set for a real `expect` declaration, so any guard
written in terms of it is inert. A guard phrased as "decline a static bind when
the target has no body" was tried too and is dangerous: instrumented it catches
`Collection.iterator`, `Iterator.hasNext` and `CoroutineContext.fold` — abstract
members that must keep binding to a virtual slot.

**The pattern to expect from every remaining increment.** Supplying better
static type information does not introduce these failures; it makes previously
unreachable implementations reachable. Four times now the fix has been in the
thing that became reachable, never in the code that supplied the type. Budget
the rest of this campaign on that basis: each new source of receiver types will
surface another stub or placeholder, and the failure will look like a regression
in the increment.

### Retried the return-type channel; blocked on an inner-class receiver walk

Re-attempted with the two guards the earlier failure taught (`return_ty_declared`,
so the `Unit` placeholder can never be read as a fact, plus a fully-concrete
requirement on the declared return type) and with the `ThrowableActuals` stub
gone. The stdlib sweep is CLEAN — 117 files, 0 failures, where the first attempt
regressed two collection tests — so those guards fixed what they were for.

Compose still fails, all suites, on `unresolved global stateLock`. The channel
is reverted; the diagnosis is one step further along and is the next thing to do.

`KLIO_BARE_TRACE=stateLock` gives the SAME four rows with and without the
channel:

    [bare-read] stateLock in=- known_global=false own=false encl=false
                splice_recv=- owner=Recomposer$RecomposerInfoImpl
    [bare-read] stateLock in=performInsertValues ... encl=true owner=Recomposer
    [bare-read] stateLock in=recompositionRunner ... encl=true owner=Recomposer
    [bare-read] stateLock in=runRecomposeAndApplyChanges ... encl=true owner=Recomposer

So the channel does not change how `stateLock` LOWERS. It changes which of these
sites executes. The first row is the defective one and it is present on a clean
tree too — inside the private inner class `RecomposerInfoImpl`,
`hasEnclosingMember("stateLock")` is FALSE and `in=-` means it is not in a real
function (a property initializer or a synthesized context). With `own=false` and
`encl=false` the read emits the `LoadFromThisOrGlobal` fallback, whose runtime
walk must climb from the inner instance to the enclosing `Recomposer` through the
class-nesting tower. It does not, so the read falls through to the global and
raises.

That is the same family as the `StoreToThisOrGlobal` capture-slot gap fixed
earlier this campaign: an implicit receiver that lowering knows about statically
but the runtime walk cannot reach.

The source line is
`get() = synchronized(stateLock) { this@Recomposer.errorState.value }` — a
property GETTER (hence `in=-`) on a private inner class, reading a private
outer `val` as the argument of an inline call.

Not yet reproduced standalone. Four reductions were tried and ALL PASS, so the
trigger is none of these on its own; do not retry them:

1. inner class implementing an interface, reading a private outer `val` from a
   property initializer and from a method — prints `L/L`;
2. the same read from a property GETTER, plus one through a `run { }` lambda —
   prints `L/T`;
3. the read as the argument of a user-defined INLINE function taking a lock and
   a lambda, from a getter on a private inner class — prints `T`;
4. the same, with the inner instance constructed in an outer property
   INITIALIZER (`private val cached = Inner()`), mirroring
   `private val recomposerInfo = RecomposerInfoImpl()` — prints `T`.

All four reductions produce the IDENTICAL `[bare-read]` row to the failing
Recomposer site — `in=- own=false encl=false owner=Outer$Inner` — and still
pass, including on a build with the channel applied. So the lowering decision is
not the difference; the runtime behaviour is.

Two more hypotheses tested and DEAD, so they are not retried:

- **Owner-mangled private property.** `stateLock` is `private`, and a private
  property that shadows a supertype's writes an owner-mangled key, which would
  make `hostHasProperty` miss. Ruled out: it is the only declaration of that
  name anywhere in the tree, so nothing triggers mangling.
- **The implicit-receiver site memo.** `LoadFromThisOrGlobal` short-circuits its
  walk on a shape-hash match (`lt.site_cache`), and a colliding MISS entry would
  produce exactly this symptom. Ruled out by a `KLIO_NO_SITE_MEMO` escape that
  forces the full walk: compose fails identically with the memo disabled.

The hard fact to build on came from printing the walk's candidate list
(`[recv-walk]`):

    [recv-walk] stateLock this_idx=0 cands=1
    [recv-walk]   [0] depth=0 kind=Instance

**One candidate.** The enclosing `Recomposer` instance is never in the list, so
the class-nesting tower contributes nothing for the inner class here. That is
the bug, and it is the same family as the `StoreToThisOrGlobal` capture-slot gap
fixed earlier: an implicit receiver that exists but that the runtime walk cannot
reach.

**MECHANISM FOUND** — and it is not the inner class at all. Instrumenting the
real run with `KLIO_CMG_TRACE=stateLock` shows what the walk's innermost
candidate actually is:

    [icand-append] stateLock tag=Instance class=JobImpl subject=false depth=0
    [icand-append] stateLock tag=Instance class=Recomposer subject=false depth=0

A `JobImpl`. The failing read is inside

    private val effectJob = Job(effectCoroutineContext[Job]).apply {
        invokeOnCompletion { … synchronized(stateLock) { … } … }
    }

Once the channel gives `Job(...)` a static type, `apply`'s receiver is known,
the lambda body is spliced with that receiver bound, and the bare `stateLock`
read inside it walks against the JOB. The enclosing `Recomposer` never enters
the candidate list — hence `cands=1` — so the read falls through to the global
and raises.

The cause is in `implicitCandidatesAlloc`, but NOT simply in its
"a supplied direct receiver replaces the frame `this`" rule — read further
before changing that line. A follow-up block already re-adds the frame's own
receiver param after a direct receiver, and it is gated on `consult_param`,
which the `LoadFromThisOrGlobal` arm passes as `true`. So the ordering rule is
not what strands the Recomposer.

Established, by printing the walk's inputs on the real failing run:

    [icand-entry] stateLock direct_this=false entries=1 fnkind=plain fn=<lambda>
    [icand-append] stateLock tag=Instance class=JobImpl subject=false depth=0

`direct_this` is FALSE — no splice receiver is supplied at all, so neither the
"replaces the frame `this`" rule nor the `consult_param` follow-up is involved
(the follow-up never even runs; it is gated on `direct_this != null`). The frame
is a plain lambda, and the enclosing-receiver chain from
`enclosingEntriesAlloc` has exactly ONE entry: the JobImpl.

**That chain is the bug.** The read sits in `invokeOnCompletion { … }`, a lambda
nested inside `Job(...).apply { … }`, inside `Recomposer`'s property
initializer. The chain should be `[JobImpl, Recomposer]` — innermost receiver
first, then the enclosing class instance — and it holds only the JobImpl. The
enclosing class receiver is dropped when a receiver-lambda is entered, so no
ordering change in `implicitCandidatesAlloc` can help: the Recomposer is not in
its input.

The chain entries are not replaced — `pushEnclosing` APPENDS, so the chain
accumulates correctly. The entry is simply never made. `captureChainAlloc`
snapshots the chain when a lambda is created, and at the moment
`invokeOnCompletion { … }` is created inside `Job(...).apply { … }` in
`Recomposer`'s property initializer, the chain holds only the JobImpl the
`apply` splice pushed. The Recomposer was never pushed.

The precedent for the fix is in the same file. `host_instances.zig:3228` runs a
class DELEGATE thunk and does exactly the right thing:

    var inst_v = Value{ .Instance = inst };
    ir.eval.pushEnclosing(&inst_v);
    defer ir.eval.popEnclosing();

with the comment "Make the instance an enclosing receiver for the thunk so the
labeled-this walk finds it." Property-initializer and init-block thunks pass the
instance as their `this` PARAMETER (`try all.append(allocator, inst_value.*)`)
but never push it as an enclosing receiver, so any lambda created inside one
snapshots a chain without it.

**FIXED.** Both the property-initializer and the init-block thunk now push the
instance with `pushEnclosing`/`popEnclosing`, exactly as the delegate thunk did.
Not inside `evalThunk` — an ordinary method already seeds its own receiver and
would gain a duplicate entry. Pinned by
`tests/fixtures/parity_corpus/init_lambda_encloses_instance.kt`, twenty lines
that fail without it with `unresolved global tag`, the same symptom compose
showed.

### And the verdict on the return-type channel: green, and worth nothing

With that fix in place the channel finally passes everything — stdlib sweep
117/0, every compose suite. So the four-attempt chase ended by fixing a real
interpreter bug, which is the useful outcome.

The channel itself is NOT landed, because with it green the census can finally
be read honestly, and it says:

    bound_static 196   (identical to the tree without the channel)

Zero. That is the same answer the original widening audit gave — 311 fills, all
non-generic, 3,800 skips — arrived at from the opposite direction. A call's
declared return type is concrete often enough to be worth measuring and not
often enough to move the number, because the receivers that matter are generic
containers whose element type the declaration does not fix.

So the channel is closed as a direction. What it produced was not static
dispatch coverage but four latent interpreter bugs, three of them now fixed. The
remaining `no_receiver_type` mass needs the element type of generic containers,
which is a typeck project, not a lowering one — the conclusion this document
reached earlier and which the channel work has now confirmed by exhausting the
alternative.

That makes this the third instance of one family, exactly as predicted earlier
in this document: an implicit receiver that exists and that the runtime walk
cannot reach, after `StoreToThisOrGlobal`'s capture slot and
`CallMemberOrGlobal`'s. The fix is the same shape — let the splice receiver be
the innermost candidate while the frame's own `this` continues the chain behind
it — and it is a change to the receiver walk, so it needs the full gate rather
than a spot check.

This also explains why five standalone reductions all passed: every one of them
put the read in an inner class, which was never the trigger. The trigger is a
bare name inside an inline receiver-lambda whose receiver is statically typed,
referring to a member of the ENCLOSING class.

### The largest remaining lever needs no typeck: 834 already-identified targets

`resolver_declined` is the second-largest bucket (1,934 sites, 19.5%) and had
never been broken down. Unlike `no_receiver_type` it needs NOTHING from typeck —
lowering already has the receiver type at every one of these sites. Split by
what the resolver returned (`[decline]`, same `KLIO_DISPATCH_STATS` gate):

    834  100.00%  target_known_deferred

Every single one. The resolver has already IDENTIFIED the declaration and only
withholds the dispatch commitment. Nothing is ambiguous and nothing is
inapplicable. (The count is of sites reaching the post-target path; the rest
return earlier, at `resolved.target orelse ...`.)

They all come from one line in `resolveMemberCall`:

    if (unknown_count == 1) {
        return .{ .target = unknown, .dispatch = .deferred, .applicable = true };
    }

Exactly one candidate exists, but an argument's type is unknown so its
applicability is unproven, and the resolver names the target as expected-type
metadata for the arguments while refusing to dispatch through it.

Set that against the coverage numbers: `bound_virtual` is **9**. There are 834
sites with a proven declaration identity that emit no static binding at all,
against 9 that emit a virtual slot. A virtual slot IS static dispatch — it is a
numeric method index, no runtime name lookup — and it is the correct emission
for a known-but-overridable declaration.

**LANDED.** Promoting a `target_known_deferred` resolution to a real dispatch,
guarded by `extCouldApply` — the conservative, chain-aware "could any extension
of this name serve this receiver" query — binds 78 more sites:

    bound_static      196 -> 274
    resolver_declined 1934 -> 1856

Total statically bound 205 -> 283, a 38% increase, and every one of the 78 binds
as a DIRECT call, the strongest form.

Three wrong turns on the way, each worth not repeating:

1. Unguarded on the receiver's representation: `virtual call receiver is not an
   instance`. A virtual slot indexes an instance vtable; a stub or value class is
   a host-backed value.
2. Excluding stub and value classes: the same for `Sequence`. An INTERFACE
   receiver can hold a host-backed value too — a sequence is a generator, not an
   `Instance`.
3. Excluding interfaces as well: the stdlib sweep went green but
   `CompositionLocalTests` failed with `virtual method slot is not linked for
   receiver class`. The diagnostic named the receiver as `TrieNode` — the SAME
   class that declares the method. The slot was missing because the method is
   not overridable at all, so it never had one.

That third failure is the lesson. The promotion had been assuming `.virtual`,
and virtual is wrong for a final or private method. The resolver already knows
the right answer; it just could not be asked. `Module.dispatchForTarget` now
factors that direct-vs-virtual rule out of `resolveMemberCall` so a promoting
caller reaches the same verdict instead of guessing, and the 78 sites turn out
to be final/private methods that bind directly.

The extension-shadowing risk this guard was written for never materialised in
any of the three rounds.

This bucket is a better next target than the generic-element-type project. That
project is still the answer for the 68% `no_receiver_type` mass, but this one is
a fifth of the sites, is fully diagnosed, and depends on nothing.

### Why re-widening is blocked (superseded theory below — read this first)

Ruled out by experiment: it is NOT instantiation-dependent recordings.
`generic_body_depth` + `types_instantiation_dependent` now exclude every
type recorded inside a generic body (29,517 spans excluded against 9,192
exported on the collections file), and both regressions still fail.

What is actually happening, traced with a temporary `KLIO_ARGTY_TRACE`
probe on `argDeclTypeRef`:

    478  [argty] element -> <none>   (splice_ty=false)

For the spliced `plusElement` body, `argDeclTypeRefLazy` has NO answer for
`element` — and `spliceParamTy("element")` is not set, so the declared-type
channel that exists for exactly this purpose is inactive. With no lazy
answer the eager fill supplies the CALLER's type (`List<String>`), which
makes `plus(elements: Iterable<T>)` applicable and it concatenates.

`bindSpliceParamTy` is called from exactly ONE real splice path
(`inline_call.zig:1699`, the reified/type-args path) plus one special case
in `expr.zig`. `plusElement` declares no reified parameters, so whichever
splice path it takes never binds its parameters' declared types.

That makes the fix concrete: bind splice parameter types on EVERY splice
path, not only the reified one. Then `argDeclTypeRefLazy` answers `T` for
`element`, the eager fill never runs there, and the declared-type rule
below holds by construction rather than by the absence of evidence.

Unverified: the probe never showed `element -> List`, so the exact
expression that carries the caller's type into the `plus` resolution is
still unconfirmed. Confirm that before writing the fix — the binding gap is
established, its causal link to these two tests is not.

### The declared-type rule (still correct, but not the blocker)

The two regressions were diagnosed and they are NOT an inference gap. They
are a rule violation, and the rule matters for every later phase.

`plusElement` is one line:

    public inline fun <T> Iterable<T>.plusElement(element: T): List<T> {
        return plus(element)
    }

Inside that body `element` has the DECLARED type `T`, and Kotlin resolves
`plus(element)` against `T` — matching `Iterable<T>.plus(element: T)`
exactly. Now instantiate `T = List<String>`: the argument is also an
`Iterable`, so `Iterable<T>.plus(elements: Iterable<T>)` becomes
applicable, and that overload CONCATENATES. Hence
`Expected <[[s], [a]]>, actual <[[s], a]>`.

Without the type channel, lowering cannot prove the `Iterable` overload
applies and picks correctly. With it, better information makes resolution
WORSE — because the information is wrong for that position.

The rule: **a generic function's body is resolved once, against its type
PARAMETERS, not against any one call site's instantiation.** Eager evidence
is keyed by span, and a span inside a generic body has as many types as the
function has instantiations. Recording one of them and applying it to the
body is ambiguous by construction — the same defect shape as the
simple-name class map and the compose pass's shared `gen_span`, now in a
third guise: identity by position cannot distinguish one body's many
instantiations.

So re-widening needs the channel to either (a) not record evidence for
expressions inside a generic body, or (b) record it per instantiation and
have lowering ask with the instantiation in hand. (a) is cheap and loses
the coverage inside generic bodies; (b) is the real answer and is a
significant piece of design, because lowering compiles such a body once.

`GroupingTest.countEach` ("expected a Grouping receiver") is unexamined but
almost certainly the same shape — a `Grouping<T, K>` receiver inside a
generic body.

### Five falsified theories, and what the probe still cannot see

The `plusCollectionInference` regression resisted five successive
diagnoses. Recorded so none is retried:

1. *Instantiation-dependent recordings.* Excluding all 29,517 of them
   (`generic_body_depth`) left both regressions failing.
2. *Unbound splice parameter type.* `KLIO_SPLICE_TRACE` shows
   `plusElement entered, params=1` and `bound element: T` — it splices and
   the binding happens.
3. *`argDeclTypeRef` answering wrongly.* `KLIO_ARGTY_TRACE` shows
   `element -> T args=0 splice_ty=true` — the argument resolves correctly.
4. *`param_spec` rewarding an unproven concrete parameter.* Gating it on the
   argument's head being a type parameter was implemented, compiled, passed
   233 ir tests, and changed neither regression. Reverted.
5. *The splice substituting the caller's argument expression.*
   `KLIO_EXTKEY_TRACE` shows the spliced body's call as
   `recv=Collection args=T` picking fid 2837 `plus(element: T)` correctly at
   score 100105 against 100015. And no `recv=List<List<...>>` row exists
   anywhere, so the caller's `List<List<String>>` never reaches a `plus`
   receiver.

Where that leaves it: every `plus` ranking row dumped is individually
DEFENSIBLE. `recv=Collection args=T` picks the element overload;
`recv=List<String> args=List<String>` picks the Iterable overload, which is
correct for the `listOf("a") + listOf("b")` calls elsewhere in the file. The
failing call cannot be identified from receiver/argument type shapes because
several sites share a shape.

The blocking instrumentation gap: `ApplicabilityScope` carries no call
SPAN, so an `[extkey]` row cannot be tied to a source line. Threading a span
through the scope (diagnostic-only, no behavior) is the prerequisite for
going further — with it, the failing line's candidate set and key comparison
can be read directly instead of inferred from shapes. That is a small,
well-defined task and it should be the next thing done.

Cost note for whoever picks this up: five theories, each a full
build-and-validate cycle, all falsified. The probes that produced facts
(`KLIO_SPLICE_TRACE`, `KLIO_ARGTY_TRACE`, `KLIO_EXTKEY_TRACE`) were worth
more than any of the reasoning that motivated them. Build the span-labelled
dump before forming a sixth theory.

### The inference work list

The work list, ranked by how often typeck could not name a type's
arguments (from the `[TYPEHEAD-SKIP]` audit over one compose test):

    1058  MutableList
     880  Iterator
     349  List
     252  Array
     247  MutableVector
     172  SnapshotStateList
      71  MutableScatterSet
      68  Flow

`Iterator` at 880 is mostly `for` loops; `MutableList`/`List` at 1407
combined is the single biggest bucket. These are the ordinary containers,
so the gap is not an exotic corner — typeck is not propagating element
types through the constructs that build and traverse collections. Start
with `listOf`/`mutableListOf` and the `iterator()` chain: whatever fraction
of 2,300+ sites those two cover is the fraction of the receiver-type
bucket that becomes reachable.

### Eager mode is NOT yet ready to become the only mode

`commontest-sweep.py --eager both` (the dual gate; it runs both modes and
reports divergence per directory) shows eager FAILING three tests that
pass with it off:

    kotlin/libraries/stdlib/test/numbers: off=113/0, on=110/3
    kotlin/libraries/stdlib/test/time:    off=81/0,  on=80/1

- `NaNTotalOrderTest.{array,list,sequence}TMinOrNull`: STILL OPEN, and
  the mechanism is the opposite of what the symptom suggests. Eager makes
  lowering resolve LESS, not wrongly. `KLIO_EXT_TRACE=minOrNull` over the
  same file set:

        eager off:  recv=Array target=4432   recv=List target=2098   recv=Sequence target=2463
        eager on:   recv=Array target=null   recv=List target=null   recv=Sequence target=null

  Same receiver head, same implicit owners, same arg count — but under
  eager the static extension pick fails, the call falls back to runtime
  dispatch, and the runtime chooses the IEEE `Iterable<Double>.minOrNull`
  over the total-order `Iterable<T>.minOrNull`, giving NaN instead of 0.0.

  `eagerCallTarget` returns null on a missing entry, so absence is NOT
  being read as a negative answer; the channel is additive as intended.
  The next thing to check is the type ARGUMENTS: `EagerTypeHead` carries
  only `{name, nullable}` — no generic args — so where the eager head
  replaces a richer AST answer, `resolveExtensionCallForArgs` loses the
  element type it needs to choose between `Iterable<T>` and
  `Iterable<Double>`. That would explain a head-only answer defeating a
  pick that AST evidence completes.
- `DurationTest.parseAndFormatInUnits`: **FIXED.** The frame chain named
  it exactly: `representations.toList()` dispatched to
  `kotlin.text.toList` (the `CharSequence` extension, which reads
  `this.length`) with an `Array` receiver. `representations` is a
  `vararg representations: String`, and typeck bound it as the ELEMENT
  type `String` — but Kotlin binds the packed array in the body, so its
  type is `Array<out String>`. `varargParamType` now supplies that
  (keeping the primitive specialisations: `vararg i: Int` is an
  `IntArray`), and the test passes.

Both are wrong-static-type defects, the same family as the `SlotTable`
collision. Until they are fixed the `KLIO_EAGER` flag and the non-eager
branches must stay: deleting the working path while the replacement fails
real tests would be trading correctness for tidiness. The removal is
tracked as its own step below.

### Compose under eager

The stdlib dual gate is clean (`--eager both`: eager ON/OFF identical, 0
failures across 117 files). Compose was not: 14 failures under eager,
green by default. Two causes, one fixed:

- **Extension shadowing (8 tests, FIXED).** A bare call inside an
  extension body has that extension's receiver in scope, so a same-named
  EXTENSION on it out-ranks the top-level declaration typeck's flat
  registry answers with. `fun MockViewValidator.Text(...)` must beat the
  composable `Text` for a bare `Text(...)` written inside
  `fun MockViewValidator.Point(...)`; binding the composable reached the
  composer with no applier (`Vm::get_field 'applier' on 'kotlin.Unit'`).
  `recordResolvedCall`'s existing shadow walk covers MEMBERS only, and an
  extension is not a member. `extension_fn_names` now declines any name
  declared as an extension on any receiver. CompositionTests 139 -> 147,
  MovableContentTests 39 -> 40.

- **Infix `and` on the composer (5 tests, OPEN).** All five remaining
  failures are one cause: `Vm::call_member 'and' on
  'androidx.compose.runtime.GapComposer'`. A bare infix `and` bound to the
  implicit composer receiver instead of its `Int` receiver — the compose
  plugin's `$changed and 0b…` bit tests. `test_remember_in_a_loop` and the
  `movableContentReceiver_{None,One,Two,Three}` family. The frame chain at
  the failure was not captured cleanly; next step is a targeted
  `KLIO_MISS_TRACE=and` run against a single test rather than the suite.

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

**Phase 1 is DONE as far as syntax can take it.** 2.34% -> 54.9% bound on the
stdlib set, 37.4% -> 62.0% on the examples set. Every channel that reads a type
out of the SOURCE has been opened: a local's own initializer (call, constructor,
property read, indexed read, alias chain, operator result), a loop variable, a
destructured component, a lambda parameter, an extension body's receiver, a
type parameter's upper bound, a property's constructor parameter or factory
call, a bare call's sole global. Each is pinned by a fixture that prints the
wrong answer when its channel is switched off.

What remains is NOT more of the same, and six separate measured zeros say so.
Both remaining buckets are blocked on the same missing thing, and the probes
that establish it are recorded below:

  - `no_receiver_type`, still the mass. Its initializers are dominated by
    `getOrPut`, `iterator`, `toMutableList`, `listIterator` — stdlib generics
    whose declared return type is the CALLER's own type parameter. `M :
    MutableMap<K, V>` makes `getOrPut` return `V`, which names no class, and
    the bound record drops the arguments that would substitute it. No lookup
    fixes this; the type arguments have to be inferred.
  - `resolver_declined`, which the last few fixes GREW by moving sites into it.
    Every blocked pair there has an applicable member and an applicable
    same-arity extension, and `[extlit]` shows the arguments carry no
    authoritative type to choose between them.

So the next phase is one project, not two: infer and carry GENERIC ARGUMENTS
through the call graph. It unlocks both buckets at once, and until it exists
every further syntactic channel measures zero — which is what the dead-end list
below is for. Its first slice has landed (the initializer chain reaching
receivers, and explicit type arguments being final — the section above); the
open work list is "The inference work list" below, starting with the
substitution of a caller's own type arguments into a generic member's return
type (`getOrPut` returning `V`).

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

### Fixed alongside this work: a later local captured an earlier bare write

Independent of the receiver-lambda write fix, and on a path that fix does not
touch:

    class Slot { var value: String = "empty" }
    fun main() {
        val a = Slot()
        with(a) { value = "written" }
        println(a.value)          // prints `empty`, kotlinc prints `written`
        var value = "local"
        println(value)
    }

A local declared LATER in the block is already visible to `b.resolve` when the
earlier bare-name write is lowered, so the write takes the rebind arm and
targets the not-yet-declared local instead of the receiver's property. Local
declarations are hoisted for register allocation without carrying their
declaration POSITION, so name resolution inside the block cannot tell "declared
above" from "declared below".

This is the same defect shape as the rest of this document: an answer given from
information that does not identify what is being asked about — here the scope
query knows the name but not the point in the block. It is a silent wrong
answer, not an error.

FIXED. The mechanism was the captured-var analysis, which records which names
need a shared cell for the whole body and carries no declaration position, so
`isBoxed` answered yes at sites that PRECEDE the `var`. The write took the cell
path and the later declaration then overwrote it. Trying to add ordering to the
analysis is the wrong place: the name really is boxed, because a later
reference really does capture it — only the earlier sites are wrong. The fix is
at the use site, which requires the name to be in scope as a local (bound in
this frame, or a capture from an enclosing one) before the cell path applies.
Pinned by `bare_write_var_declared_later`, which exercises both directions in
one program.
