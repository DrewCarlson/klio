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


## Pre-existing: the e2e/parity in-process suites crash on enum-entry patching

Found by the full gate (which then sat 40+ minutes inside the segfault
handler's DWARF symbolication — `gate.sh` now runs every phase under
`GATE_PHASE_TIMEOUT`, default 1200s, so a hang is a fast RED). Bisected: the
crash reproduces at de72470a, BEFORE this session's commits. Three stacked
mechanisms, all in the enum-entry ctor-arg patch (`vmPrepareInner`):

1. `parity-base-gen` bakes WITHOUT executing, so baked enum instances carry
   only `name`/`ordinal`; the ctor-param fields (`CharCategory.value`,
   `.code`) are deferred to every adopting program's patch loop. The stdlib
   image path is immune because it bakes AFTER a run.
2. `valueFromImage` sizes field buffers at exact capacity in the adoption
   arena, so the patch's first `define` must GROW — freeing an arena buffer
   through the VM slab (`class_states[0xAAAAAAAA]`). LANDED: `InstanceData.
   fields_foreign` + `ensureFieldsOwned` re-buffer on first growth, foreign
   spines skipped at `deinit`/`gcFinalize`, all raw append sites guarded.
   `KLIO_ENUM_INIT_TRACE` prints `[enum-init-append]` when a patch APPENDS
   (a baked field was missing) rather than replaces.
3. STILL OPEN: the parity base cache (`base_cache_max`) shares the adopted
   class defs across per-program Vms, so VM-A's patch writes VM-A-slab
   values into image-lifetime instances; VM-B then releases them with its
   own slab (integer-overflow in the refcount atomic) or reads them after
   VM-A's slab died. The fix is to patch ONCE at ADOPT time with the base
   entry's own arena (values and buffers then share the cache entry's
   lifetime), and make the per-VM loop skip fields that are already
   present — enum ctor args are per-class constants, so skipping is
   semantics-preserving. LANDED as skip-if-present in `vmPrepareInner`
   (the process-global slab means the first Vm's values legitimately
   outlive it while the cached base holds them); the cross-Vm RELEASE
   crash (integer overflow in the refcount atomic) is gone.

STILL RED, and the surviving evidence points at an underlying heap stomp
that PREDATES the campaign (bisected: de72470a crashes identically):
`freeSmall` sees `class_idx=34, len 32` when growing a buffer the SAME Vm
allocated moments earlier — its slab header was overwritten between the
two enum-field defines, i.e. the patch loop is the victim, not the
source. Second shape: a free of already-freed memory (`0xAAAAAAAA`)
under `vm.deinit` at parity.zig:2043.

MEASURED: cache EVICTION is NOT the cause — with `base_cache_max = 0`
(both sites in e2e.zig; the probe was reverted) all three tests still
crash identically. The remaining mechanism, consistent with every
observation: the e2e loop resets ONE run arena per program
(`run_arena.reset(.retain_capacity)`), and `parity.runWithPacks(a, ...)`
builds the per-program Vm on that arena — so the enum-entry patch
writes VALUES evaluated with program N's arena into the CACHED,
program-spanning base instances. Program N+1's reset recycles that
memory under the cached fields; skip-if-present then preserves dangling
values, and any later read/replace/release of them is a use-after-reset
(the slab frames come from deeper layers that wrap the same memory).

The fix shape: patch values must be allocated from the CACHE ENTRY's
arena. Concretely, `prepareWithBase` (which holds both the entry and
its arena) should run the enum ctor-arg patch itself, passing the
entry's arena as the evaluation/definition allocator, and
`vmPrepareInner`'s per-Vm loop keeps only the skip-if-present guard.
An alternative with the same ownership result: deep-copy the evaluated
values into the entry arena before `define`.

One more layer, read from `runFilesInMode`: under a GC run the Vm
allocator is `runtime.slab.allocator` (process-global) and program end
runs `runtime.gc.collect()` under an explicit contract — "Nothing from
the finished program may remain rooted while its compiler arena is
about to be released." The enum patch violates exactly that contract:
it roots program-lifetime GC cells (the `code` STRING values) inside
the cross-program cached base, and the sweep recycles them. So the fix
must produce values OUTSIDE the swept heap: scalars are by-value
(safe); the string fields need `strInit` against the entry arena, and
the field-list buffer likewise. Whether arena-backed cells are safe to
hand to GC-run programs (release/trace paths) must be checked against
how the adopted base's OWN image values already work — they are the
precedent, since baked-in fields live in the entry arena today and GC
programs read them.

Verify with `KLIO_E2E_SHARD=0/8` on the rebuilt binary, then the full
suite, then the whole gate.

The fast loop (harness + sweep + unit modules) structurally cannot see this
path: only the e2e/parity itests run in-process base-image adoption with the
loop JIT forced on. `KLIO_E2E_SHARD=0/16` on a built e2e binary covers it in
under a minute — use it whenever interp_ir/runtime/image internals change.


### e2e recovery status: three allocator bugs fixed, one residual

Fixed and verified by crash-shape elimination (0/3 tests -> 1/3, and the
corpus now runs deep instead of dying on its first program):

1. `vmFromBuilt` MOVED the arena-owned `enum_entry_arg_inits` list into a
   Vm whose GC-run allocator is the slab; teardown freed the arena buffer
   through it (the collapsed `vm.deinit -> rawFree` trace, `0xAAAAAAAA`
   header). It now copies the list with the Vm allocator; managed hashmaps
   were never affected because they remember their own allocator.
2. Base-backed programs patch SHARED cached instances; values now allocate
   from the cache entry's arena (`Vm.patch_allocator`, threaded
   BaseEntry -> PreparedProgram -> runFilesInMode).
3. Whole-program fallbacks own their instances; their patch allocator is
   the run arena (which outlives the Vm), not the slab.

RESIDUAL: one segfault (`0xaaaaaaaaaaaaaaf0` — poisoned pointer read) in
`jit_object_traversal_loop` (jit=true) that needs ~150 prior in-process
programs to manifest — it passes standalone under KLIO_JIT=1. Plus
program-level FAILs (missing fields like `DrawImpl.id`,
`KlioBufferedChannel.closeHandler`; drifted outputs) that the
first-program crash previously MASKED — they need triage against expected
outputs before they can be attributed. The e2e suite has been red since
e7f76632 (the GC test-profile alignment, ~534 commits ago), so these
failures accumulated unseen; `KLIO_E2E_FILTER`/`KLIO_E2E_SHARD` are the
narrowing tools.


### The gate's honest ledger after the recovery (first full read since e7f76632)

Gate wall time is now ~10 minutes with per-phase attribution. Green: unit,
lambdas_and_dispatch 50/50, inheritance_dispatch 13/13,
extension_resolution 26/26, object_init 35/35, ktor_channel_async,
concurrency_stress, bundle_smoke, and the dual eager sweep (117/0 in BOTH
modes, outputs identical — the eager gate's first clean read).

Red, all pre-dating this session (the suites crashed outright before the
allocator fixes, so these accumulated unseen; every one verified to fail
identically with all four session gates off):

- parity_corpus_pinned 126/134: local_extension_generic_applicability_matrix,
  generic_factory_return_extension (NaN — reproduces in the harness, fast
  loop available), qualified_alias_static_applicability,
  member_factory_constructor_shadow, unimported_object_member_extension,
  member_extension_foreign_field_shadow, backtick_this_param_not_receiver
  (unresolved global `show` — reproduces in the harness),
  tier5_loose_member_redispatch_resolves. These are extension-resolution
  wrong answers — campaign-domain bugs with pinned expected outputs, the
  next concrete work items.
- parity_threaded_litmus 43/44 (1 crash), check_examples 3/4
  (vararg_spread duplicate-declaration), ktor_server 1/2 (expected 200,
  found null), e2e 1/3 (the deep-corpus segfault above plus masked
  program-level failures).


### The pinned NaN failure names the blocked-pair fix precisely

`generic_factory_return_extension`: `arrayOf(a, b).minOrNull()` inside
`fun <T : Comparable<T>> choose(a: T, b: T)`. The receiver derives as
`Array<T>`; the candidates are the total-order
`Array<out T : Comparable<T>>.minOrNull` and the IEEE
`Array<out Double>.minOrNull`. kotlinc EXCLUDES the IEEE overload — a
declared type parameter is not `Double` statically — and uniquely picks
total-order (prints 0.0). klio's extension ranking treats the
param-typed element as a wildcard compatible with BOTH, declines as
ambiguous (`applicable=true target=null`, the blocked-pair shape), and
runtime dispatch picks IEEE from the runtime values (prints NaN).

The fix: in extension-receiver applicability, a receiver type argument
that is a DECLARED TYPE PARAMETER (present in
`actual_type_param_bounds`) DISPROVES a candidate whose corresponding
pattern argument names a concrete classifier the parameter's bound does
not entail. That is Kotlin's own rule, it is exactly what the
`[member-static-bound] T <: Comparable complete=false` context already
carries into resolution, and it attacks the `resolver_declined` mass
(451 stdlib / 3,697 examples) that every receiver-typing fix has been
feeding. Verify against the eight red pinned fixtures — several
(`local_extension_generic_applicability_matrix`,
`tier5_loose_member_redispatch_resolves`) look like the same family.


### LANDED: the type-parameter disproof and the sole-survivor commit

Two halves, separately gated, both required for the NaN fixture:

1. `staticTypeDisproofComplete` (gate `KLIO_TP_DISPROOF`): for the NEGATIVE
   conclusion only, a head-only bound record is fully known — dropped bound
   arguments narrow a bound, never add a supertype — so a failed subtype
   check against a concrete classifier becomes `.incompatible` instead of
   `.unknown`. Applied at the three negative-polarity proof sites; the two
   positive-capable sites keep the strict proof.
2. The sole-survivor commit (gate `KLIO_SOLE_EXT`): when the disproof
   PRUNED at least one competitor and exactly one candidate remains, with a
   receiver carrying explicit type arguments, the survivor commits — kotlinc
   resolves to the only applicable candidate. The pruning-evidence guard is
   load-bearing: without it the sole candidate for a name that never had
   competitors (`indentWidth` inside `trimIndent`) was committed on weak
   receiver evidence and broke the sweep; with it the sweep is green and the
   examples A/B is clean.

`generic_factory_return_extension` prints 0.0 (was NaN) through the
harness. Census UNCHANGED on the stdlib set — the seventh wrong-answer fix
visible only as parity. The pinned itest suite still reports 126/134
through the PARITY pipeline: those failures resolve against base-image
candidate sets and need their own look.


### The seven remaining pinned reds, triaged

- `backtick_this_param_not_receiver` is `checkErr`: kotlinc REJECTS the
  bare `show()` (no implicit receiver in scope) before running; klio defers
  it to a runtime unresolved-global. That is resolution-STRICTNESS work and
  belongs to the resolution-unification plan, not an applicability fix.
- The other six (`local_extension_generic_applicability_matrix`,
  `qualified_alias_static_applicability`, `member_factory_constructor_shadow`,
  `unimported_object_member_extension`, `member_extension_foreign_field_shadow`,
  `tier5_loose_member_redispatch_resolves`) are output mismatches in
  extension/member applicability matrices — campaign-domain, each needs its
  own root-cause pass with the harness where reproducible
  (`local_extension_generic_applicability_matrix` prints 2 of its 5
  expected lines there).


### LANDED: a local extension resolves its receiver's alias

`localOverloadReceiverCouldApply` compared the receiver's DECLARED name
against known classifiers, so an alias head (`Ints = MutableList<Int>`)
matched nothing and fell into the unresolvable-type-parameter escape —
the local overload then applied to a receiver its real type refutes,
and `values.tag()` on an `Ints` picked a `MutableList<String>.tag()`
local. The alias now resolves through `resolveTypeAliasAt` first,
exactly as global extension resolution already did. Pinned suite
127 -> 129 of 134 (this healed `qualified_alias_static_applicability`
too); sweep 117/0, examples A/B clean.


### LANDED: a member shadowing a constructor types its call site

`ctorInitTypeRef` typed any bare capitalized call as the class it names,
but a MEMBER of the enclosing receiver shadows the constructor — the
emission router already decided that (`fun Foo(): Bar` inside Host makes
a bare `Foo()` the member call, and the member RAN) while the derivation
still committed type `Foo`, so `value.tag()` bound `Foo.tag` statically
and executed it against the `Bar` the member returned. The derivation now
applies the router's own shadow rule. Pinned suite 129 -> 130 of 134;
sweep 117/0, examples A/B clean.


### LANDED: a member extension's body sees its dispatch owner's members

A member extension (`class Owner { fun Scope.readState() }`) lowered its
body with an EMPTY enclosing-member set, so a bare `state` the extension
receiver's static type does not declare became a plain field read on the
extension receiver — and a runtime SUBTYPE's unrelated same-named field
captured it (99 where kotlinc reads `this@Owner.state` = 7). The dispatch
owner's members now merge into the enclosing scope, sending the read
through the scoped-getter walk that carries the declaring class. Both the
direct read and the read inside a spliced lambda resolve to the owner.
Pinned suite 130 -> 131 of 134; sweep 117/0, examples A/B clean.


### LANDED: a private member extension stays inside its declaring class

Extension resolution's visibility switch skipped the Private check
entirely for MEMBER extensions, so `PrivateBase`'s private
`String.startsWith` bound inside `PrivateDerived` — inheritance is not
lexical visibility, and kotlinc gives the call to the stdlib candidate.
The rule now requires the caller's lexical family to contain the
declaring class in either nesting direction (which keeps a companion's
privates visible in its enclosing class) and never through inheritance.
Pinned suite 131 -> 132 of 134; sweep 117/0, examples A/B clean.


### LANDED: a generic inline receiver carries the call site's classifier

`T.apply { greet() }` spliced its body with receiver evidence "T" — no
classifier — so a bare call inside the lambda could not see the
receiver's members, and a same-named top-level function captured it
(`lib-lib` where kotlinc dispatches the member: `member-member`). Two
halves: the splice substitutes the CALL SITE's static receiver head when
the declared receiver is the inline fn's own type parameter, and the
member-shadow gate consults the splice receiver when the enclosing
function's own receiver context is empty. Pinned suite 132 -> 133 of
134 — every applicability red is now green; the one remaining red is
`backtick_this_param_not_receiver`, which is resolution-STRICTNESS work
tracked by the resolution-unification plan. Sweep 117/0, examples A/B
clean.


### Closing gate ledger for this round

- unit: GREEN (67/67 build steps, 467 tests) — was broken since 89d7f3bc
  mangled diagnostics_gen's message assignments; restored.
- parity_corpus_pinned: 133/134 — every applicability red fixed this
  round; the last red is the resolution-strictness fixture
  (`backtick_this_param_not_receiver`), tracked by the
  resolution-unification plan.
- dual eager sweep: 117/0 in both modes, identical outputs.
- Six litmus suites fully green (lambdas_and_dispatch,
  inheritance_dispatch, extension_resolution, object_init,
  ktor_channel_async, concurrency_stress, bundle_smoke).
- Still red, all pre-existing and enumerated above: threaded_litmus
  43/44 (one crash), check_examples 3/4 (vararg_spread), ktor_server
  1/2, e2e 1/3 (the in-process jit segfault plus the drift list:
  bounded_typeparam_receiver, channel_invoke_on_close,
  complex_oop_delegation, compose_nodes, compose_path,
  compose_snapshot_flow, delegated_member_named_args, ...).

Campaign standing: stdlib 56.7% bound, examples 64.4%, from 2.34% /
37.4%. The next campaign fronts remain: lambda-receiver evidence (the
iterator mass), the resolver_declined blocked pairs beyond the
type-parameter disproof, and the e2e drift triage now that the suite
runs deep enough to show it.


### IN PROGRESS: bounded_typeparam_receiver — where-bounds don't refute at runtime

`fun <T> T.observe() where T : Node, T : Observer`, called bare inside
`DrawNode.draw()` (a CanvasScope member extension): the runtime receiver
walk invokes `observe` with the innermost candidate (the CanvasScope
receiver, DrawImpl) which fails `T : Node` — kotlinc skips it and binds
the DrawNode. Established so far:

- The registry DOES carry both where-bounds per func
  (`func_type_param_bounds`, populated in interp_ir/build.zig ~2660,
  marked complete=false for multi-bounds) and
  `receiverViolatesTypeParamBound` iterates them ignoring `.complete` —
  data and refuter are both sound.
- The failure reproduces with `KLIO_FLAT=0` (not the flat arm), with no
  `[strictext]` output (not `callMemberStrictExt`), and with no
  `extLocal cand` output under `KLIO_TRACE_RESOLVE=observe` (not the
  ~12940 walk). The frame chain (`KLIO_ERR_TRACE=1`): lambda ->
  DrawNode.draw -> observe with this=DrawImpl.
- ROUTE FOUND (`KLIO_OR_AUDIT`): the call is STATICALLY committed by the
  bare-extension arm — `[ext-static] observe recv=CanvasScope
  target=7029 applicable=true` from `lowerResolvedExtensionCall` →
  `Module.resolveExtensionCall`. The runtime is executing a wrong static
  pin, not making its own choice.
- LANDED toward the fix (inert until the loop reaches it): bound-HEAD
  refutation in `resolveExtensionCall`'s generic branch — a known
  receiver class that provably does not extend a known bound-head class
  is `.incompatible` even when the bound record is marked incomplete
  (multi-bound `where` records), since dropped bound arguments only
  narrow.
- OPEN PUZZLE: a probe placed at the `declaredTypeParamBounds` line
  inside the candidate loop never fired for `observe` even though the
  SAME call returns target=7029 — some earlier guard `continue`s past
  the generic branch for this fid, or the commit comes from a different
  leg of the loop. Next probe: print each candidate fid and the guard it
  exits through for name==observe; one run pins the accepting flow, and
  then the refutation lands on that leg.
- kotlinc's answer for the example: `observed:3:ok`
  (tests/corpus/expected/bounded_typeparam_receiver.out); the DrawNode
  dispatch receiver is the only bounds-satisfying candidate.
- ROOT CAUSE FOUND AND SPLIT: `func_type_param_bounds` was EMPTY at both
  lowering and runtime for `klio run` programs — the interp-build loop
  that fills it (build.zig ~2660) never runs on this path (verified: a
  probe there never fired), so `declaredTypeParamBounds` handed the
  prover the default `T <: kotlin.Any complete=true` record and the
  prover accepted any receiver. Registering the bounds AT HEADER TIME
  fixes the example (`observed:3:ok` verified) when done in the
  interp-build header block — but that same registration also ARMS the
  runtime refuter (`receiverViolatesTypeParamBound`) program-wide for
  the first time, and DurationTest.parseAndFormatInUnits then dies in
  eval recursion (some runtime pick flips to a self-recursive sibling;
  Int-vs-Comparable is NOT the mechanism — `isRuntimeType` handles it).
  LANDED: the decl.zig-side header registration (static resolution
  path, no runtime effect, all suites green). REVERTED pending the
  recursion's root cause: the interp-build header-block registration.
  DONE and bisected to ONE name: with the runtime registration armed,
  ONLY the `contains` records flip behavior — `KLIO_HDR_BOUNDS_SKIP=
  contains` restores DurationTest to 52/52 (it even heals the two
  pre-existing parse failures). The recursion pair is the range
  `contains` family (`<T, R> R.contains(element: T) where R :
  ClosedRange<T>, R : Iterable<T>` and its Comparable twin): arming
  their bounds changes the INNER pick inside the family's own body into
  self-recursion (`Duration.Companion.parse` at Duration.kt:299 x5,595
  frames through the test utils' `in` checks). The registration is
  landed OPT-IN (`KLIO_HDR_BOUNDS=1`, with `KLIO_HDR_BOUNDS_SKIP` and
  `KLIO_HDR_BOUNDS_LIST` as bisect knobs): default off keeps every
  suite green; opted in, `bounded_typeparam_receiver` prints
  `observed:3:ok`. Next: reproduce the contains recursion under the
  opt-in (`KLIO_MISS_TRACE=contains` on the DurationTest argv), find
  which candidate the armed records displace in the runtime ranking,
  fix that, flip the default, and delete the gate.
- NARROWED (`KLIO_REX_TRACE`, per-candidate loop verdicts): the loop
  reaches the generic branch with bounds=1 and
  `staticGenericReceiverApplicable` returns TRUE for the CanvasScope
  receiver even though the single declared bound is `T <: Node`
  (complete=false) and the proof gate should return false. The
  receiver-binding fallback (bindingType miss on the pattern-head param
  now falls back to the actual receiver) did not change the verdict, so
  the accepting leg is INSIDE the prover before/around the per-param
  proof gate — next probe goes inside `staticGenericReceiverApplicable`
  (print the binding table and each param's gate result for
  name==observe) and lands the refutation on whichever leg accepts.


### Armed-refuter recovery: two member-first guards landed, one residual

(1) The bare-member arm blocks the static extension commit when a member
is applicable-but-deferred — matching the explicit path's
member_shadows_extensions. (2) `extensionFnFallbackWalk` defers to a
receiver MEMBER when bound refutation THINNED its candidate set. Armed
DurationTest: all-crashing -> 51/52; unarmed unchanged, suites green.

RESIDUAL (armed-only): the ranges `contains` family — `element != null
&& contains(element)` (Ranges.kt:259/275, InlineOnly so SPLICED) —
kotlinc binds the inner call to the ClosedRange.contains MEMBER; klio's
runtime walk re-picks the extension family on the range receiver. All
emissions are CallMemberOrGlobal (inline_splice_recv_walk /
implicit_this_call_global_fallback, pkg=kotlin.ranges); no static
self-bind. Next: the strict per-candidate walk's sole-candidate return
(~host_call_member.zig:12995) lacks the member-defer the fallback walk
now has — give it the same member-first rule, flip the KLIO_HDR_BOUNDS
default, delete the gate.


Also eliminated: `resolveExtOverloadLocal`'s sole-candidate return now
carries the same thinned+member-first guard (correct regardless) and the
armed residual persists unchanged — so the committing tail for the
spliced ranges `contains` shape is NONE of: the extension fallback walk,
the bare-member static arm, or the strict local overload resolver. The
remaining suspects are the CMG lenient pass and the splice-emitted
`inline_splice_recv_walk` CMG's own candidate list (`cmg.candidates`,
built at lowering — check whether the armed static candidate FILTER
prunes the member-reaching fallback out of that list before runtime ever
walks it).


Eliminated further: the bare-path CMG self-hint (a spliced body's bare
call of its own name no longer carries the enclosing fn as the global
hint — Kotlin binds the receiver's member there) and the flat arm
(KLIO_FLAT=0 unchanged). The armed residual persists, so the committing
route for the spliced ranges `contains` is the
`implicit_this_call_global_fallback` emission arm (34 of the armed
run's contains emissions) — inspect what func/candidates that arm
attaches and whether its runtime tier can reach the receiver member at
all. Armed DurationTest holds at 51/52 with all guards; default-off
keeps every suite green.


Ninth elimination + the decisive datum: the caller-tagged `[fn-entry]`
(now permanent in the trace) proves the loop is `contains#1949 ->
contains#1949` with `this=List`, entered from `assertContains`. The
recursing inner site's emission arm attaches NO func hint
(`implicit_this_call_global_fallback`), so the self-name committed_ext
path never engages there — the new members-only lock (every receiver
disproving a committed target still locks the walk to members) is
landed and principled but does not reach this site. The committing
route produces NO runtime orAudit line, is not the flat arm
(KLIO_FLAT=0 unchanged), not the CNO bounded tier (kind-skip), and not
the three guarded extension tails. Next probe: env-gated route prints
at every commit point inside `callMemberNamedInner` (the ext-cache
serve and each tail) for name==contains — one armed run pins the line,
the member-first rule lands there, then flip KLIO_HDR_BOUNDS and
delete the gate.


Tenth elimination: the by-name ext-cache serves (all three, plus the
new `cacheServesExecutingFrame` guard — a cached resolution never serves
the frame currently executing it, which closes every cache-driven
self-loop categorically) — and the armed residual STILL reproduces. Ten
routes are now guarded or eliminated; the recursion enters through a
commit point inside `callMemberNamedInner`'s remaining ladder (member
fast path? the builtin probe ladder? `userMethodNamed`?) that none of
the instrumented arms cover. The next session instruments
callMemberNamedInner's interior: an env-gated route print before every
`invokeMethodFuncId`/`callFunc`-by-fid line in that fn, one armed run,
and the member-first rule lands on the printed line. Every guard landed
during this hunt is independently Kotlin-true and validated; the
default path has stayed green throughout.


Eleventh and twelfth: the two member method-cache serves at the top of
`callMemberInnerStatic` carry the executing-frame guard, and — the
inert-guard root cause — `hostHasMember` answers FALSE for every
non-Instance receiver, so all member-first guards were blind to host
containers (the exact receivers in the loop). `receiverHasMemberNamed`
now probes the FQN-keyed host table under the value's nominal type and
its builtin supertypes, and the fallback-walk and strict-resolver
guards use it. The armed loop STILL reproduces, so its committing line
sits in a resolver none of the twelve guarded routes cover and none of
the audits print. Do NOT add further blind guards (a categorical
self-fid decline at invokeMethodFuncId would break legitimate by-name
tree recursion); the next session goes straight to route prints before
EVERY invoke in callMemberInnerStatic's remaining ladder (the builtin
probe ladder and irMethodWalk's serves), one armed run, and the fix
lands on the printed line.


Route-print instrumentation landed IN-TREE (`KLIO_ROUTE=<name>`): 15
prints across callMemberInnerStatic's every invoking return, 3 across
the eval CMG tail (overload / committed / by_id+name-fallback). The
decisive armed run: ZERO prints from all 18 points while the loop runs
3,996 frames (`caller=kotlin.collections.contains`), and KLIO_FLAT=0
with every guard in place changes nothing. Both by-name dispatch
ladders and the CMG tail are therefore fully excluded — the recursive
invoker is OUTSIDE them. The one uninstrumented family that can invoke
a fid with a bound receiver is the VIRTUAL-SLOT path
(`invokeVirtualMember`'s non-Instance branch resolving the smart-cast
`contains(element)` site against the host List's class → slot →
target). Next: KLIO_ROUTE-style prints at invokeVirtualMember's commit
points (noinst target serve, callMemberNamed fallback, the slot invoke)
plus [member-static] on the _Collections.kt contains body's inner site
to see whether lowering bound it dispatch=virtual; the fix then follows
the printed line. Fourteen member-first/self-serve guards from this
hunt remain landed and validated.


FINAL NARROWING of the armed contains loop, with the tooling now
in-tree: `[fn-entry]` prints the caller's call-site span
(byte-exact: file 41 offsets 1998-2054 = `if (this is Collection)\n
return contains(element)` in _Collections.kt), and `[cmgsec]` section
markers cover the CMG arm's entry/member-gate/resolution. The armed run
executes the loop 3,996 frames with ZERO CMG-section hits — on the
shared home AND on a fresh bake — so the instruction the bake holds at
that span is NOT CallMemberOrGlobal, and every dynamic-dispatch route
investigated (fourteen guards, eighteen route prints, the flat lane
now honouring KLIO_FLAT) was innocent. Next probe is mechanical: dump
fid 1949's baked instruction stream (the image already serializes it;
a tiny `KLIO_DUMP_FN=<fid>` printer over Func.blocks at adopt) and read
which instruction sits at span 1998 — the fix then lands at that
emission's lowering arm, the default flips, and the gate deletes.


### ARMED-REFUTER ARC RESOLVED: the smart-cast `this` was invisible

The baked instruction dump (`KLIO_DUMP_FN=<fid>`, now in-tree) ended the
hunt: block b1 of `Iterable.contains` held a STATIC `Call` — the armed
sole-survivor rule had bound the smart-cast `contains(element)` to the
enclosing function itself, because `bareStaticRecvHead` never consulted
the `is`-narrow of `this` (`narrowLocal("this", ...)` records it; the
head read only the splice channel). With the narrow consulted — AFTER
the splice hint, so spliced bodies keep their hygiene (the first
ordering broke `UnsignedArraysTest.onEachIndexed`) — the member binds
and armed DurationTest runs 52/52, both pre-existing parse failures
included, and `bounded_typeparam_receiver` prints `observed:3:ok`.

Both levers are staged behind gates with their coupling documented:
- `KLIO_THIS_NARROW` (default OFF): consulting the narrow re-forms bare
  emissions across the stdlib, and DeepRecursiveTest measured 4.3x
  slower wall-clock (1:07 -> 4:49, deterministic, 99% CPU) — the
  emission delta needs the census treatment before this defaults on.
- `KLIO_HDR_BOUNDS` (default OFF) REQUIRES the narrow: armed without it
  the contains loop returns. The armed full sweep additionally shows
  `ArrayDequeTest.clear` recursing — the same shape family, next on the
  roll-out list.

Flip order when resuming: census + perf the narrow's emission delta,
fix ArrayDeque.clear's instance of the shape, then both defaults flip
and the gates delete. Fourteen member-first/self-serve guards, the
route-print and dump tooling, and the caller-span [fn-entry] remain
landed from the hunt.


### ArrayDeque.clear armed recursion: mechanism identified

Repro needs the BATCHED directory compile (33 tests; standalone passes
66/66). Pinned: the loop is the TEST METHOD `ArrayDequeTest.clear`
re-entered from the test's lambda (`fun clear() = testArrayDeque { ...
generateArrayDeque(...).apply { clear() } ... }`), and the runtime
audit shows `run inst=CallMemberOrGlobal name=clear arm=member depth=0`
— the emitted CMG for the bare `clear()` carries NO receiver register
(the capture-path emission), so the innermost implicit candidate is the
CAPTURED TEST INSTANCE and its same-name member (the test method
itself) serves. Kotlin binds the `apply` receiver's member: the
receiver-lambda (`T.()`) must own `this` inside the spliced block.
Minimal repros (adm2/adm3 in the scratchpad shapes: lambda indirection,
same-name enclosing member, generic helper receiver) all BIND CORRECTLY
— the failing delta vs those is still open (candidates: the helper
being a member of the test class, the four-param outer lambda, or the
batched sibling set changing the receiver derivation). Next: [bare-read]
/emission-arm trace on the exact span (file2:3031) in the batched run to
see which emission arm fires and why `this` fails to resolve/bind for
the spliced receiver-lambda there; the fix then lands at that arm.


ArrayDeque armed follow-up, two measured zeros recorded: hinting the
generic receiver-lambda's substituted head (both `orelse spliceRecvTy`
and the isTypeParam-aware variant) did not change the armed verdict —
the failing bare `clear()` sits under NESTED splices (`testArrayDeque
{ ... }`'s lambda splice wraps the `apply { }` splice) and the
hint/receiver channels are restored per layer, so the inner
substitution never survives to the site. Both edits reverted. Next
probe: print `spliceRecvTy`/`spliceHintRecv`/`lambda_splice_resolve`
at the exact site (KLIO_BAREARM extended with the three channel values)
through the nested-splice path in the batched run; the fix belongs at
whichever layer drops the subject's head.


### THE FLIP: bounds refutation and the smart-cast narrow are the default

The armed roll-out list emptied in one stroke: the genuine-narrow gate
(the entry must differ from the frame's own declared receiver) fixed the
ArrayDeque mis-bind AND restored DeepRecursive to 1:03 — the 4.3x
slowdown and the mis-bind were the same defect, the ungated consult
trusting an enclosing method's `this` decl through receiver-less
lambdas. Full armed sweep 117/0, so both defaults flipped:
`KLIO_HDR_BOUNDS` and `KLIO_THIS_NARROW` are ON (`=0` disables for A/B,
per house style; the SKIP/LIST bisect knobs remain).

Verified at the flip: sweep 117/0, pinned 133/134 (the strictness
fixture only), cli 58/58, and the examples A/B shows exactly TWO diffs —
`serial_names` (the known warm-cache artifact) and
`bounded_typeparam_receiver` itself, which is the fix: gates-off
reproduces the old wrong dispatch, default prints kotlinc's
`observed:3:ok`. Stdlib census: member-site total 6,538 -> 6,408 with
no_receiver_type 2,012 -> 1,964 and resolver_declined 451 -> 445 — 130
more sites now resolve statically as extension calls and leave the
member census entirely.


### The e2e drift, triaged out-of-process: five root causes, eight examples recovered

The corpus drift list finally got a fast loop: run every `examples/*.kt`
with expected output through the ReleaseSafe harness against fresh
source-built packs (`scripts/install-local-packs.sh` into `.klio-local`;
KLIO_HOME is the PARENT of `.klio/packs` — passing the `.klio` dir itself
silently loses every pack). 17 of 266 failed out-of-process — all
pre-existing (both flipped defaults off change nothing), five with roots
found and fixed:

1. **A host-implemented member lost to a virtual slot.** The synth channel
   classes list `BufferedChannel` in `supertype_names` for type checks, and
   the campaign's `bound_virtual` emission resolved `invokeOnClose` through
   that supertype into upstream's Kotlin body — which reads fields the
   native channel never materializes (`closeHandler`). The old name-dispatch
   found the host binding first, so this class of failure appeared only
   when a site became statically bound. Fix: in `invokeVirtualMember`, an
   exact-FQN host binding on an ANONYMOUS receiver class is the
   most-derived override and dispatches by name before any slot link.
   Recovered channel_invoke_on_close, compose_snapshot_flow, and (with 2
   below) runtest_channel_resume_order, scope_body_throw_cancels_unstarted_child.

2. **A getter's expression body lowered with no expected type.**
   `collectToFun get() = { collectTo(it) }` declares
   `suspend (ProducerScope<T>) -> Unit`, but the accessor lowering passed
   `expected = null`, so the headerless lambda's shape stayed unknown and
   the runtime receiver-bind ran it as a receiver-lambda: `it` unbound
   (Null), the ProducerScope displaced into `this`. `SendingCollector`
   then stored a null channel and `send` failed on `kotlin.Nothing`. Fix:
   both accessor sites now pass the property's declared type
   (`lowerAccessorExprWithExpected`). Pinned by getter_lambda_param_shape.

3. **`kotlin.io` was an any-member surface.** Its five intrinsics are
   receiver-less top-level functions, yet `anyMemberGlobal` served them
   member-style with the receiver PREPENDED: `with(x) { println() }`
   printed `x`. Removed from `any_member_prefixes`; pinned by
   receiver_scope_zero_arg_println and the flipped unit expectations.

4. **The SAM-candidate arm was blind to builtin-backed deeper receivers.**
   `valueCouldServeName` answered false for every non-Instance value, so
   inside `asFlow`'s block the collector closure swallowed `forEach` and
   the list never iterated. The guard now vouches for builtin values via
   the host-member probe plus `extCouldApply` on the nominal head. Pinned
   by bare_call_through_closure_subject.

5. **An import alias defeated the name-keyed inline table.**
   `import ...unsafeFlow as flow` resolves through the symbol index to an
   inline HEADER STUB (bodyless), and the commit emitted a call that
   entered nothing — `flowOf` returned its own block closure. The commit
   path now splices the registered AST by id, gated to ALIAS calls only
   (call-site name != declared name): ungated, it force-spliced bodies the
   name-keyed path had declined, breaking every compose example on a
   package-private reference re-lowered in a foreign file scope AND
   blowing the stdlib utils batch past the 6GB RSS cap. The narrow gate
   fixed both.

Also fixed on the way: the route-print insertion in the instance-method
cache serve had broken the `cacheServesExecutingFrame` guard bracing (the
guard applied to the print, the invoke ran unconditionally).

Verified: sweep 117/0, pinned 136/137 (+3 pins; the backtick strictness
fixture stays the one red), cli 58/58, corpus drift 249 -> 253 of 266.

The 13 residuals and their shapes: flow_operators' drop/dropWhile emit
through a bare `collect {}` whose receiver evidence needs the OUTER
lambda receiver (`this@drop : Flow`) — the resolver sees only
recv_ty=FlowCollector and defers, and no runtime heuristic can
discriminate (this is the plan's lambda-receiver-evidence channel, now
with a concrete blocking example). complex_oop_delegation
(`medianish` extension through a delegating receiver), compose_path
(arg-shift Div Float/PathSegment), compose_nodes/compose_ui_text/
mosaic_hello (DIFFs), delegated_member_named_args, finally_own_throw,
range_in_range_operator, reified_param_inference,
throwable_suppressed_user_class, vararg_nonfinal (vararg tail loss),
select_on_timeout_loses (timeout), runtest_channel_resume_order advanced
to a comparator-from-bound-reference failure (`compare` on
`$bound_ref$time`).


### An F-bounded local extension vanished at its own call site

complex_oop_delegation's real defect had nothing to do with delegation:
`fun <T : Comparable<T>> List<T>.medianish()` declared INSIDE main was
uncallable. `localTypeParamBounds` records `Comparable<T>` head-only
(`complete=false` — the args are dropped), and
`staticGenericReceiverApplicable` treats an incomplete bound as a failed
proof. Right for the campaign's PROVE callers (never commit on an
unprovable bound), wrong for `localOverloadReceiverCouldApply`: a local
fn has no other server, so refusing the sole candidate turned the call
into a runtime member-miss. Split the mode:
`staticGenericReceiverCouldApply` skips incomplete bounds (kotlinc
already accepted the declaration); prove callers keep declining. Pinned
by local_extension_fbounded_param; complex_oop_delegation matches its
expected output again. Sweep 117/0.


### compose_path: the Iterable fallback ignored the call's arity

The Div-on-PathSegment failure decomposed cleanly with the pack-source
probe recipe: every sub-expression of `max(1, ceil(abs(sweepRad) /
(PI.toFloat() / 2f)).toInt())` evaluated correctly in isolation, and the
literal probe `max(1, 4)` returned `PathSegment(Move, [10, 5])` — the
path's single segment. KlioPath declares `iterator()`, so the runtime
Iterable fallback matched the `kotlin.collections.Iterable.max`
intrinsic BY NAME ALONE, drained the path into a list of segments, and
answered with its largest element — swallowing a two-argument call the
zero-argument collection extension can never mean (the lowering had
resolved kotlin.math.max, but the site emitted deferred CMG in the pack
context and the member walk preempted it). The fallback now requires the
call shape to fit SOME source declaration of the name on
Iterable/List/Collection (`extCouldApply` arity), so `max(1, n)` falls
through to the resolved global. Pinned by iterator_member_global_arity
(behavioral; the deferred-CMG route itself is pinned by compose_path in
the corpus). Drift 253 -> 255; sweep 117/0; pinned 138/139.


### vararg_nonfinal: the value-call packer let a defaulted tail claim positionals

Three vararg packers exist (host_call_func's simple packer, the
reorder-aware named binder, and host_call_value's `nonfinal:` block for
value calls) and only the named binder knew Kotlin's rule: a parameter
AFTER a vararg is fillable positionally only when it cannot default (a
generated slot-exact call) or through trailing-lambda syntax. The value
route — which the bare CMG global tail takes — surrendered the last
positional to `footer: String = "end"` unconditionally, so
`report("A", 1, 2, 3)` printed `A [1,2] 3`. The block now computes the
claiming tail from the defaults table plus the trailing-lambda shape,
and a zero-claim tail packs everything into the vararg and re-pads the
prefix through `padArgsWithDefaults` (the first padding pass ran before
packing and saw four args). Pinned by
vararg_before_defaulted_positional (including the `::report` reference
route); the example matches. Drift 255 -> 256; sweep 117/0.


### range_in_range: the thinned-set member guard deferred to an inapplicable member

The user `operator LongRange.contains(LongRange)` was correctly the
extension fallback's sole survivor (the armed bound refutation thinned
the other eight), but the `defer_to_member` guard — added for the
Iterable.contains self-loop — saw `receiverHasMemberNamed(Range,
"contains")` and stood the pick down, handing the call to the
range-to-list re-dispatch, which compared elements and answered false.
The member surface it deferred to takes an ELEMENT; a Range argument
makes it inapplicable, which is exactly the ladder's existing
`range_in_range` standdown predicate — the guard now carries the same
exclusion. Pinned by range_in_range_user_operator; the example matches.
Sweep 117/0.


### finally_own_throw: the leaf serve skipped finally blocks

`fun returnInFinally() { try { return 1 } finally { return 2 } }`
answered 1 — and a diagnostic `println` in the finally never printed:
`classifyLeafExprBody` rejected bodies with CATCHES but admitted
finally-carrying ones, and the frameless leaf walk has no try-stack, so
the return left the try region without ever entering the finally. The
classifier now rejects `finally != null` blocks too. The eval's own
machinery was correct all along (once framed, a return inside the
finally replaces the pending one). Pinned by
finally_runs_on_return_leaf_shape; the example matches. Sweep 117/0.

KLIO_DUMP_FN now also accepts a function NAME (dumps every func bearing
it) and prints per-block try metadata (catches/finally/sentinel/pop) —
both were needed to see this.


### throwable_suppressed: the statically bound header skipped the Instance arms

`addSuppressed`/`suppressedExceptions` on a USER throwable class: the
member-dispatch arms maintain the hidden `__suppressed__` list on
interpreted instances, but the campaign's static binding routes the
expect-header call straight to the host intrinsic — which handled only
host `.Exception` values and silently no-opped on an Instance. Another
instance of the invokeOnClose class: a site becoming statically bound
exposes an intrinsic that never expected interpreted receivers. Both
intrinsics now serve the `__suppressed__` protocol for Instances.
Pinned by throwable_suppressed_user_instance; the example matches.
Sweep 117/0.


### reified_param_inference: `Any` treated as evidence-refutable

`inline fun <reified T> classify(x: Any, block: (T) -> String)` called
with an Int lost its splice: `inlineEvidenceRejects` counted the
argument's Int evidence against the `Any` parameter as a definite
mismatch (builtin evidence vs a registered non-builtin class), declined
the splice, and the dynamic `is T` ran with T unbound — answering `is`
for every argument. A top-type parameter can never be disproven by
evidence; the check now skips `Any` params. T then solves statically
from the lambda annotation (`{ s: String -> }`), which the unifier
already knew how to do. Pinned by reified_from_lambda_annotation; the
example matches. Sweep 117/0. (`[tbie]` now also prints the index
outcome/pick provenance under KLIO_EF_TRACE.)


### delegated_member_named_args: arg_params died at the by-name fallback

The bound_virtual emission folds named arguments into `arg_params`
(param indices) and deliberately empties `arg_names`. When the slot is
UNLINKED for the receiver class (a `by`-delegating wrapper with no own
override), `invokeVirtualMember` falls back to dispatch by NAME — with
the empty names — so `emit(tag = "b", scale = 2.5f)` re-bound
positionally through the delegate walk and scale's value landed in
`value`. The fallback now derives the names back from the slot root's
declared params before any by-name route runs. Pinned by
delegated_member_named_args_pin; the example matches. Sweep 117/0.


### Drift-triage arc closed at 261/266: the five residuals, each sized

Eleven root causes fixed across the arc (channel host-binding override,
getter expected type, kotlin.io any-member removal, SAM-guard builtin
blindness, alias inline splice, F-bounded local extension, Iterable
fallback arity, vararg defaulted tail, range-in-range defer,
finally-leaf classification, Any evidence, suppressed-exception
intrinsics, virtual-fallback arg_params — plus the guard-bracing
repair). Corpus 249 -> 261 of 266; pinned suite 134 -> 145 (+11 pins,
the backtick strictness fixture stays the one red); sweep 117/0
throughout.

The five residuals, triaged:

- flow_operators (drop/dropWhile): needs the lambda-receiver-evidence
  channel — bare `collect {}` inside drop's flow-lambda sees only
  recv_ty=FlowCollector and defers; the outer `this@drop : Flow`
  receiver is the campaign's named next lever, now with a concrete
  blocking example and a traced resolution ([bare] collect -> NONE).
- select_on_timeout_loses: TIMEOUT in the select machinery, older
  drift, untraced.
- compose_nodes: reorder recreates nodes (nodesCreated 10 vs 7) — a
  recomposition identity/movable-content defect.
- compose_ui_text: layout metrics differ (height 48 vs 68, para y
  offsets) — text measurement.
- mosaic_hello: `appendCodePoint`'s `codePoint.toChar()` appends digit
  codes in the PACK universe only (the 12-line standalone passes) —
  shape B context-dependence, un-minimized.

Tooling landed with the arc: `scripts`-side corpus drift sweep (run
every example with expected output through the harness against
source-built packs — the fast out-of-process e2e loop), KLIO_DUMP_FN by
NAME with per-block try metadata, [extpick]/[vabsorb]/[tbie]-outcome
traces. KLIO_HOME gotcha recorded: it is the PARENT of `.klio/packs`.


### IN PROGRESS: lambda-receiver evidence — the tower exists, the resolver ignores it

Traced to the exact gap. At argument-lambda lowering (expr.zig ~2803)
`collectImplicitReceiverTower(receiver_head)` already builds the full
tower — for drop's flow-lambda that is [FlowCollector, Flow] — and
lambda_body.zig installs it on the body builder
(`setImplicitReceiverTower`). But `pending_lambda_enclosing_recv` is
`receiver_head orelse enclosingRecvTy()`, so the lambda's OWN receiver
becomes both recv_ty and encl_recv ([bare] collect showed
FlowCollector/FlowCollector), and the bare resolver's extension arm
consults only those two heads — the tower's outer entries
(`b.implicit_receiver_tower.items`) are never candidates.

The channel to build (gate: KLIO_TOWER_EXT): in the bare-call arm, when
the innermost receiver head refutes every extension candidate, walk
tower[1..]; if exactly ONE candidate proves applicable to an outer head,
commit it. Two emission options, decide by experiment:

1. FULL static commit with the outer receiver: the lambda's frame
   reaches the outer `this` as a capture (`this@drop` resolution
   exists), so lowerResolvedExtensionCall with receiver =
   resolveCapture("this") at that depth. Strongest form; needs the
   capture-depth plumbing.
2. CHEAPER committed-ext form: emit CMG with committed_ext = the proven
   target (the machinery exists — callMemberMembersOnly walk). The
   runtime candidates walk already carries the outer receiver at
   [1]; the failure is only the SAM arm swallowing at [0]. With a
   committed extension whose declared receiver head a closure candidate
   cannot satisfy, the SAM arm must decline (add that guard) and the
   walk reaches the true receiver.

flow_operators (drop/dropWhile emitting through bare `collect {}`) is
the driving repro; the iterator mass (919 examples sites) is the
census payoff once the channel lands.


### Lambda-receiver channel, refined: option 3 is the real root

Option 2 (committed-ext) dead-ends: `committedExtReceiverProven/
Disproven` cannot discriminate CLOSURE receivers (a raw IrClosure
carries no class), and in the flow walk both the collector AND the
flowOf Flow are closures — the commitment would bind the wrong one or
none. The deeper distortion, confirmed in the traces: flowOf's spliced
`unsafeFlow` body lowers `object : Flow<T> { override collect }` to a
RAW CLOSURE, while drop's identical object (different splice shape)
stays Instance($anon : Flow) — [sam-walk] showed
[0]IrClosure [1]IrClosure [2]Instance($anon$0). If the object-expression
kept its interface identity (Instance with supertype Flow, method
registered), the EXISTING machinery resolves everything:
valueCouldServeName proves `collect` on [1] via the hierarchy, the SAM
arm declines at [0], and the extension fallback binds Flow.collect.

NEXT: find where the inline splice's expression-body context
SAM-collapses a single-method `object : Interface` into a closure
(expr.zig object lowering under splice — compare the two flow-builder
splice sites), and keep the Instance form when the interface is a
NAMED source interface (not a fun-interface conversion). Then re-run
dropmin/flow_operators; the [bare] collect -> NONE static gap (tower
consult, option 1) remains the census lever afterwards.


Standalone repro attempt is NEGATIVE: an inline block-body fn with a
crossinline param returning `object : Box<T> { override fun peek }`
keeps its Instance identity through the splice (`peek` runs, `is Box<*>`
true). The collapse therefore needs the ALIAS-splice context (`import
unsafeFlow as flow` — the by-id splice arm added this arc) or another
pack-context ingredient. Next repro dimension: two-file/pack setup with
the import alias, or probe the REAL flowOf splice with KLIO_DUMP_FN over
the spliced caller to see what instruction the object lowered to
(AstLambda vs NewInstance).


### flow_operators GREEN: the anon object's interface chain was invisible

The closure-collapse theory was wrong — KLIO_DUMP_FN over the spliced
flowOf showed BuildObject, and the walk's [2]Instance($anon$0) WAS the
flowOf Flow. The real gap: `valueCouldServeName`'s Instance arm keyed
`hierarchy_methods` by the class's OWN name only, and an anonymous
object's name says nothing — its `supertype_names` carry the declared
members (`object : Flow<T>` serves `collect` through the interface),
and a runtime-lowered anon registers methods in the per-site table.
The arm now walks the supertype chain through hierarchy_methods and
extCouldApply and probes the anon-method table, so the SAM-candidate
arm declines at the collector closure and the walk reaches the real
Flow. drop/dropWhile emit correctly; flow_operators matches. Pinned by
flow_builder_object_identity. Drift 261 -> 262/266 (compose_nodes,
compose_ui_text, mosaic_hello, select_on_timeout_loses remain); sweep
117/0; pinned 145/146. The [bare] collect -> NONE static gap (the
tower consult) is still the census lever, but no longer blocks
correctness here.


### IN PROGRESS: select_on_timeout_loses — the clause property reads upstream

Diagnosed to the fix point. KLIO_PUMP_DIAG shows the deadlock: the
select parks in UPSTREAM SelectImplementation.waitUntilSelected, the
sender parks on the native rendezvous slot, and the native
`select_recv_waiters` list never gets the select —
`klioRegReceive` (the pack's clause glue) NEVER RUNS ([fn-entry] count
0). `ch.onReceive` resolves through the FIELD walk's supertype chain to
upstream BufferedChannel's member getter (`instance_prop_getters` hop
on the nominal supertype), bypassing the pack's shadowing extension
property `ReceiveChannel<E>.onReceive` in KlioChannelClauses.kt.

Fix point: host_fields' getter chain walk — for an ANONYMOUS receiver
class (a host synth), an extension property keyed on a supertype head
(extension_props / resolveExtensionPropImpl) must outrank a
supertype-walked member getter, mirroring the invokeVirtualMember rule.
The sibling method-side reroute (anonymous receiver + foreign main_func
slot link + no __sam_target__ -> dispatch by name) is implemented in
invokeVirtualMember in this commit — correct but insufficient alone,
since the clause is a PROPERTY read. onSend/onReceiveCatching will
recover with the same fix. interp_ir 117/117 with the reroute in.


Property-side standdown IMPLEMENTED at `resolveInstanceGetter` (an
anonymous receiver's INHERITED member getter stands down when any of
the synth's supertype_names keys an extension property of the name) —
unit gates green, but select STILL HANGS: the serving arm for
`ch.onReceive` is elsewhere. Next probes: the sgetter walk (~1035), the
getter MEMO caches (`sgetterPutGetter` may serve a stale pick before
the walk), and `KLIO_MISS_TRACE=onReceive` with the [sgp]/field-trace
prints to see which arm answers. The klio clause glue's entry
(`klioRegReceive` [fn-entry]) is the ground-truth signal that the read
finally reached the pack's extension property.


Select, narrowed one more level: the clause getter NOW serves the klio
glue (`[getter] __ext_get_ReceiveChannel_onReceive` on
KlioBufferedChannel — the standdown works), yet `klioRegReceive` still
never enters. The remaining break is the REGISTRATION invoke: upstream
`SelectImplementation.register` calls `clause.regFunc(clauseObject,
this, param)` where regFunc is `::klioRegReceive as
RegistrationFunction` — a function REFERENCE cast to a function type,
invoked with 3 args. Probe next: how a stored `::fn` reference invoked
through a cast function type dispatches (KLIO_MISS_TRACE=regFunc showed
`runSafely` misses on kotlin.Function — the reference may be wrapped),
and whether SelectClause1Impl's field read loses the reference.
klioRegReceive [fn-entry] stays the ground-truth signal.


Standalone negative: a `::fn as FnType` reference stored in a class val
and invoked through the cast runs fine. The regFunc break needs the
pack context — next: probe upstream SelectImplementation.register's
actual invoke site with KLIO_CALLVALUE_TRACE / a pack-source print in
Select.kt (the memory's pack-instrumentation recipe), checking whether
`clause.regFunc` reads the stored reference or a mis-resolved member.


### select ROOT FOUND: member defaults-padding beats the file-private extension

Pack-probe chain (all recovered, probes reverted): registration is FINE
(`klioRegReceive` runs — the earlier fn-entry=0 was a closure-wrapper
trace artifact), the send offers (`sel_recv=1`), trySelectInternal
reaches the WAITING arm, the CAS succeeds — and
`cont.tryResume(onCancellation)` printed `<RESUME_TOKEN>`: klio bound
the MEMBER `tryResume(value, idempotent = null, ...)` by padding
defaults for a 1-arg call, where kotlinc binds Select.kt's
FILE-PRIVATE extension `CancellableContinuation<Unit>.tryResume(
onCancellation): Boolean` — the member's `value: T=Unit` cannot accept
the onCancellation argument, so it is inapplicable and the extension
wins. The member's raw token skipped `completeResume`, the select never
resumed (permanent park), and the token failed the `if (...)`
truthiness with the CalleeFailed the bridge swallowed.

The fix, precisely: member-vs-extension applicability for a
DEFAULTS-PADDED member bind — when the member fits only by padding
defaults AND its first bound param's INSTANTIATED type (here `value:
Unit` from the receiver's `CancellableContinuation<Unit>`) refutes the
argument (a nullable function value against Unit), the member is
inapplicable and a same-file extension with EXACT arity takes the
call. Implementable at resolveInstanceMethod's candidate gathering
(instantiated-param refutation) or as the lowering-side commit for the
statically known site. `[seldbg]` probes in channelSend /
selectTrySelect / the invokeMethod bridge (gated, kept) show each stage.
Also revealed: the bridge's non-Throw error swallow hid the real
failure — the gated print stays.


Spec correction after re-reading upstream: the member
`tryResume(value: T, idempotent: Any? = null)` fits the 1-arg call by
plain arity (one default), so defaults-padding is not the
discriminator. The decidable refutation is STATIC: at the call site the
receiver is the smart-cast local `cont: CancellableContinuation<Unit>`,
so the member's `value: T` instantiates to Unit and the argument's
nullable-function type refutes it — kotlinc then binds the file-private
extension. The right home is the campaign's existing
receiver-type-arg substitution in the Member arm (the KLIO_TP_RECV
channel): extend it to refute a member whose SUBSTITUTED param type the
argument's static type disproves, letting the bare/member resolver
commit the same-file extension. The runtime walk alone cannot decide
this (the instance carries no type args). Driving repro:
select_on_timeout_loses, ground truth `dbg-tsi: tryResume=true` +
`got 99`.


Implementation reconnaissance: the receiver-substitution machinery the
fix needs ALREADY EXISTS — `staticMemberArgsCompatibility` projects the
receiver onto the member's owner (`projectTypeToClass`), binds the
class type params, substitutes into each param, and refutes via
`staticArgCompatibility` (a first attempt to duplicate it at the
per-arg level was reverted; tree clean, ir 235/235). So the question is
WHY the pipeline does not refute `tryResume(value: T:=Unit)` against
the nullable-function argument at this site. Three probes, in order:
(1) does `cont.tryResume(...)` even reach `resolveMemberCall` with
`receiver_type = CancellableContinuation<Unit>` when the pack lowers
Select.kt (KLIO_REX_TRACE / a [mev] print at the
staticMemberArgsCompatibility entry for name=tryResume), (2) what
`arg.ty` carries for the `onCancellation` local (authoritative or
stripped), (3) whether `staticArgCompatibility`'s named-vs-named tail
can refute `fn-type vs Unit` at all (it must — Unit is a complete
disproof target). Whichever link is dead is the fix site; ground truth
stays `got 99` on select_on_timeout_loses.


Probe (1) DECISIVE: `KLIO_SMAC_TRACE=tryResume` (the gated print now at
`staticMemberArgsCompatibility` entry) shows the resolver evaluating
tryResume candidates for nargs=3 and nargs=0 sites — but NEVER nargs=1.
The failing call `cont.tryResume(onCancellation)` never reaches
resolveMemberCall's member compatibility at all: lowering defers the
site before candidate evaluation, so the existing substitution/
refutation machinery never gets its chance and the runtime walk picks
the member unrefuted. NEXT: find where the 1-arg site's lowering bails
— `cont` is the cast local `curState as CancellableContinuation<Unit>`
inside trySelectInternal's `when` arm; check whether the member-call
arm's receiver derivation (`recvChainTypeRef`) carries the cast type
and which decline reason fires (lmNote/declineNote around the Member
emission), then let the site reach resolveMemberCall — the machinery
downstream is already correct, and refutation will drop the member for
the file-private extension.


Two fix pieces LANDED (ir 235/235; select still red — VERIFY SWEEP
FIRST next session, these are unswept):

1. A cast initializer types its local: `val cont = curState as
   CancellableContinuation<Unit>` now records the full generic
   reference via setLocalDeclType (stmt.zig un-annotated-val arm), so
   the 1-arg site reaches lowerResolvedMemberCall TYPED
   ([member-static] recv=CancellableContinuation, was <unknown>).
2. A callable argument refutes a non-callable BUILTIN parameter
   (staticArgCompatibility: the func_typed tail and the named-arg path
   both answer .incompatible when the substituted param head is
   Unit/a primitive/String — no lambda converts to those; user classes
   stay unknown for fun-interface SAMs).

REMAINING BREAK: the 1-arg site's resolveMemberCall still answers
`target=80 dispatch=deferred applicable=true` WITHOUT a
[smac] nargs=1 line — the resolution short-circuits before
staticMemberArgsCompatibility (a memo? the shape fast path before the
compat loop?). Find the early path in resolveMemberCall that returns
deferred-applicable for this candidate set and thread the compat check
(or its refutation) through it; then the member drops and the
file-private extension binds. Ground truth: `got 99`, and
select_on_timeout_loses in the corpus sweep.


Third piece LANDED and validated (sweep 117/0, drift 262/266 unchanged,
pinned 145/146): un-annotated `val x = call(...)` locals now record the
callee's DECLARED return type via `staticExprTypeRef` — the same
derivation the destructuring arm trusts — so argument shapes built from
call-typed locals can refute members. With it the select chain stands
at: site typed (cast piece), candidate #79 evaluated with
`CancellableContinuation<Unit>` (smac nargs=1), callable-vs-builtin
refutation armed — and the LAST link is `onCancellation`'s type:
`createOnCancellationAction(select, internalResult) =` has an INFERRED
expression-body return (`onCancellationConstructor?.invoke(...)`), so
the local stays untyped and the member stays .unknown/deferred. The
residual prerequisite is expression-body return inference for that
shape (a safe-call invoke of a nullable function-typed property), or
any equivalent decidable discriminator; everything downstream is
verified ready. select_on_timeout_loses stays the driving repro.


The last link's implementation ladder (three bounded derivations, in
dependency order — each verifiable by the smac/member-static traces):

1. `staticExprTypeRef` grows a safe-invoke arm: `x?.invoke(args)` where
   `x` is a property/local whose DECLARED type is function-typed
   (typealias-resolved) derives the function type's RETURN, nullable.
   `onCancellationConstructor?.invoke(select, internalResult)` then
   types as the returned handler function.
2. Expression-body function decls record their INFERRED return through
   the same derivation at decl time (`fun createOnCancellationAction(
   ...) = <safe-invoke>` gets its function-typed return in decl_sigs)
   — today inferred returns stay Unit-annotated-as-unknown.
3. The n-ary member-call arm of `staticExprTypeRef` (the site's
   `val onCancellation = clause.createOnCancellationAction(a, b)`)
   reads the callee's (now recorded) declared return — verify whether
   the arm already exists for n-ary calls or only nullary
   (`nullaryMemberReturnTypeRef`).

With those, the arg shape carries a Function head, the landed
callable-vs-builtin refutation drops member #79, and the file-private
extension binds: `dbg-tsi: tryResume=true`, `got 99`. All three
downstream pieces (cast typing, call-typed locals, the refutation) are
landed and gate-validated (sweep 117/0, drift 262/266, pinned 145/146).


Ladder progress — four more pieces LANDED and validated (sweep 117/0,
drift 262/266 unchanged, pinned unchanged):

1. `invoke` on a FUNCTION-typed receiver derives the function type's
   return (alias-resolved, safe-call nullable) in
   staticCallReturnTypeRef's Member arm.
2. Expression-body decls with no annotation record their return through
   staticExprTypeRef at decl time (derived_return in decl lowering).
3. `lhs ?: <jump>` types as the lhs stripped of null (staticExprTypeRef
   elvis arm + the un-annotated-val Binary/elvis recording).
4. The bareret channel now treats the OWNER CLASS as the implicit
   receiver head in plain method bodies, and passes the lexical owner
   so PRIVATE members resolve (`findClause` inside trySelectInternal:
   was `no recv head`, now `target=yes`).

The chain now dies at the plan's DOCUMENTED inner-class return blocker:
`findClause` resolves but `instantiatedCallReturnType` yields null for
its `ClauseData?` NESTED-class return ([bareret] findClause return=
<null> — see 'Retried the return-type channel; blocked on an
inner-class receiver walk'). Unblocking nested-class return references
in instantiatedCallReturnType is now the last link for select, shared
with the previously-blocked return-type channel.


Two more links opened, validated (sweep 117/0, drift 262/266
unchanged): a bare owner-head receiver no longer refuses
`instantiatedCallReturnType` when the return never mentions the class's
params (`findClause: ClauseData?` on bare SelectImplementation — the
documented inner-class blocker's common case), and the bareret Member
arm accepts a DEFERRED-but-named target for return typing (the
nullaryMemberReturnTypeRef rule). The chain now reads: clause typed
(`return=ClauseData`), the site targets createOnCancellationAction
(`target ok`), the invoke arm derives `fn-return=Function3` — yet
tryResume#79 STILL resolves `deferred applicable=true`. The one open
question is SUBSTITUTION IDENTITY in staticMemberArgsCompatibility:
the class-param bindings key on MANGLED identities
(`$class$237 1:R` per the member-static-bound prints) while
`f.params[i].ty` may spell the RAW `T`, so `substituteType` misses and
`value: T` never becomes Unit for the refutation. Verify with a print
of the instantiated param at the smac site; if raw-vs-mangled is
confirmed, bind BOTH spellings (raw name + classTypeParamIdentity) in
the bindings list. Everything else in the chain is verified live.


Probe DECISIVE (smac-arg, gated print kept): substitution is CORRECT —
`param=$class$ 50 1:T inst=Unit` — the raw-vs-mangled theory is dead.
The starved side is the ARGUMENT: `arg_ty=-`. The local
`onCancellation` never gets its type because of DECLARATION ORDER:
trySelectInternal lowers BEFORE the nested ClauseData's members, so
createOnCancellationAction's step-2 derived return (Function3, proven
by the invoke-arm print) is not yet recorded when the site derives —
instantiatedCallReturnType reads the target's CURRENT return_ty and
finds the Unit placeholder.

Design (the in-repo precedent is the KLIO_HDR_BOUNDS header pass): a
HEADER-TIME return-derivation pre-pass — before member bodies lower,
walk the class's (and file's) expr-bodied fns and record derived
returns via staticExprTypeRef, exactly as decl lowering now does
inline; bodies then lower against complete return evidence regardless
of order. Alternatively derive ON DEMAND in instantiatedCallReturnType
when the target still carries the placeholder (needs the AST handle —
inline_state.inlineAstById-style registry for expr bodies). Either
unblocks the chain's last inch: arg typed Function3 -> the landed
refutation drops #79 (`inst=Unit` vs Function3) -> the file-private
extension binds -> `got 99`.


Implementation sketch for the ordering pass (mechanism fully known):

- REGISTRY: extend build.zig's stub pass (the loop that already does
  `registerInlineFnId(id, FF(ast.Function).fromPtr(f))` for inline fns
  at ~2563) to also register EXPR-BODIED non-inline fns in a parallel
  `expr_body_asts` table keyed by the header FuncId, via a sibling
  `inline_state.registerExprBodyFn` — same FF mechanism, same lifetime.
- ON-DEMAND DERIVE: in expr.zig's bareret Member arm (and the
  stmt.zig `.Call` local-recording arm), when
  `instantiatedCallReturnType` answers null AND the target's return is
  the undeclared-Unit placeholder, look up the registered AST and run
  `staticExprTypeRef` on its body with a FRESH FuncBuilder seeded
  `setOwnerClass(<target's enclosing class>)` + `setRecvTy` — the
  derivation for `onCancellationConstructor?.invoke(...)` needs only
  the owner-class property channel plus the landed invoke arm. Cache
  the answer into the module func's return_ty so the second consult is
  free (and decl lowering's own step-2 pass stays authoritative).
- VERIFY: smac-arg flips `arg_ty=-` to `arg_ty=Function3` and
  `-> incompatible`; member-static for the 1-arg site loses target=79;
  select prints `got 99`; then sweep + drift + pinned (the standard
  battery), pin select_on_timeout_loses as a parity fixture, and close
  the residual.


The ordering pass is LANDED (validated: sweep 117/0, drift 262/266
unchanged): expression-bodied members with no annotation register under
(owner, name, arity) in the member walk
(`inline_state.registerExprBodyMember` / `exprBodyMemberAst`, exported
through lower.zig), and the bareret Member tail derives the return ON
DEMAND from the registered AST when `instantiatedCallReturnType` finds
the placeholder — with a threadlocal depth guard (od_depth < 3; the
unguarded version segfaulted on mutual body recursion).

The remaining inch moved INSIDE the on-demand derivation: the fresh
FuncBuilder is seeded only setOwnerClass/setRecvTy, so
`onCancellationConstructor` (a CTOR-PROPERTY of ClauseData) does not
resolve through the member-property channel and the body's
`?.invoke(...)` receiver stays untyped — the site still answers
`target=79 deferred applicable=true`. Wire the builder the way
`lowerAccessorExprFull` / `lowerPropertyInitExpr` do: seed
own_members and the declared ctor-param/property TYPES of the owner
class (`setLocalDeclType` for each primary param, as
lowerPropertyInitExpr's declared_params path does) before running
staticExprTypeRef. Then the invoke arm fires (proven live), the local
types Function3, and `inst=Unit` refutes — the verified-ready tail.


Builder seeding LANDED (owner ctor-property types + the fn's own param
types, the lowerPropertyInitExpr pattern; a Member-callee `return=`
trace joined the bareret prints). The site derivation is now PROVEN
LIVE end to end: `[bareret] .createOnCancellationAction on ClauseData
target ok` + `return=Function3`. Yet the runtime still fails
(trySelect err=CalleeFailed) and the 1-arg smac still shows `arg_ty=-`:
the DERIVATION works when probed, but the local's type is absent at
the EMISSION of `cont.tryResume(onCancellation)` in the same body.
The one open disconnect: either the smac nargs=1 line belongs to a
DIFFERENT 1-arg site (Mutex's CancellableContinuationWithOwner wrapper
— check by printing the caller file/span in smac), or the stmt.zig
`.Call` recording arm is not reached for a `val` declared inside a
when-arm block inside `while(true)` (verify with a gated print in the
arm for name=onCancellation). Whichever, the fix is mechanical once
seen. Gates: sweep 117/0, drift 262/266 unchanged.


EBM probe (gated, kept): registration fires in BOTH phases
(`register owner=ClauseData arity=2` twice) and the one lookup that
runs HITS (n=107). The valty <null> therefore belongs to an EARLIER
LOWERING PHASE of the same statement that dies BEFORE the fallback —
its `clause` receiver chain fails upstream (the phase lowers before
class registrations complete, so findClause/ClauseData resolution is
unavailable and the Member arm answers `no receiver type`). Select.kt's
body lowers TWICE in one process (two builds/phases — likely the
dependency-base build then the program build, or the eager pre-pass);
the EXECUTED module keeps the FIRST, untyped lowering. NEXT: identify
the two phases (print b.module identity + a phase tag alongside
[valty]), then either (a) run the class/member registration pre-pass in
the first phase too, or (b) make the kept module the second phase's.
Everything downstream is proven: with the typed lowering, derivation
returns Function3 and the refutation chain is verified ready.


Forward-reference fallbacks LANDED on both branches (validated: sweep
117/0, drift 262/266 unchanged): the pre-pass registry now holds ALL
bodied members, the Member arm serves declared returns or derives
un-annotated expression bodies, and the BARE branch serves declared
returns for same-class forward references (`findClause` below its
caller). Site facts pinned by probes: our `val onCancellation` DOES
enter lowerPropertyDecl (init_tag=Call) and records Function3 in ONE
pass; `val clause = findClause(x) ?: continue` NEVER enters
lowerPropertyDecl (the elvis-jump initializer lowers through a
control-flow arm with no decl-type recording); and the EMITTING pass's
tryResume shape still reads `arg_ty=-`. Next discriminator: a pass
counter printed with [smac]/[valty] to identify the emitting pass, then
either record decl types in the elvis-jump statement arm (find it —
it is not lowerPropertyDecl) or make the emitting pass the recording
one. The refutation fires the moment the shape carries Function3
(`inst=Unit` awaits it).


Alignment probes conclusive on the store/read side: the local RECORDS
Function3 in the emitting pass (valty enter nf=7832 -> Function3), and
EVERY reader channel (strict argDeclTypeRef probe, the lazy Path arm's
localDeclTypeRef) answers Function3 — the guards between (splice-param,
two-segment) do not apply. Yet the [smac] nargs=1 evaluation consumes
arg_ty=- at nf=7832, which EQUALS the post-lowering func count: that
evaluation is most plausibly a RUNTIME re-resolution
(module.resolveMemberCall invoked from the dispatch path with
runtime-built, typeless shapes), not the lowering emission — and no
second nargs=1 smac with a typed arg appears, so the LOWERING's member
resolution for the site either never re-evaluates #79 with the typed
shapes or its result is not what emits. NEXT (one discriminator): tag
[smac] with a lowering-vs-runtime bit (thread a `static` flag or check
ir.eval.currentFrameFunc() != null) — if the untyped evaluation is
runtime-only, the fix is to make the LOWERING commit (find why its
compat pass is absent for the site: possibly the memoized
[member-static] deferred answer from the FIRST pass is CACHED and
served to the second — resolveMemberCall memo keyed without shapes
would explain everything). The memo hypothesis is checkable by
searching resolveMemberCall for a resolve cache and printing hits.
