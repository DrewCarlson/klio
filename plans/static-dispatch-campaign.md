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

    total 6,485 member call sites
      144   2.22%  bound_static     <- direct FuncId call
    1,408  21.71%  bound_virtual    <- method slot, no name lookup
    ------------------------------
    3,886  59.92%  no_receiver_type
      308   4.75%  resolver_declined
      617   9.51%  no_class_id
      122   1.88%  nullable_or_generic

Statically bound: 1,552 of 6,485 (23.9%), from 150 (2.34%) at the start of this
round — a 10x increase.

The earlier 9,755-site census in this document was taken on a different file
set and at an unknown cache state; do not compare against it. Use the script.

### MEASURED, not landed: typing a local from its initializer is worth +253

The largest derivable slice of `no_receiver_type` is a local whose own
declaration recorded no type but whose initializer is a call. Kotlin's inferred
type for `val x = f()` IS `f`'s return type, and a `var`'s later assignment
must conform to it, so the initializer's type is the local's type at every use.
On the pinned set:

    bound_virtual      1408 -> 1661   (+253, a 14% relative gain)
    no_receiver_type   3886 -> 3549

The implementation is four lines — a `localInitTypeRef` helper feeding the two
places that already call `staticCallReturnTypeRef` — and it is NOT landed,
because it reintroduces exactly the pair of failures the earlier return-type
channel hit:

    CollectionTest.plusCollectionInference   Expected <[[s], [a]]>, actual <[[s], a]>
    GroupingTest.countEach                   expected a Grouping receiver

Requiring the derived type's classifier arguments to be complete
(`staticClassifierArgsComplete`) does NOT fix either: the derived types are
already complete (`List args=1`, `Array args=1`, `Iterator args=1`).

**`countEach` is FIXED.** `groupingBy` is an inline extension returning
`object : Grouping<T, K>`, so typing the receiver lets lowering splice that
body and produce a genuine implementation — while klio's terminals
(`eachCount`, `fold`, `reduce`) read `__grouping_src` and `__grouping_key` off
their receiver and rejected anything else. `groupingParts` now falls back to
the interface's own protocol (`sourceIterator()` + `hasNext`/`next`, then
`keyOf`). That is a real bug in its own right: a Kotlin class implementing
`Grouping` could not be aggregated at all, and it is fixed and covered
independently of this lowering change.

`plusCollectionInference` is the one thing still holding the +253 back. Traced
to instruction level, and the picture corrects an earlier reading in this
document — it is NOT a generic-body instantiation problem, and the five
falsified theories recorded further down were all reaching for that:

  - The CALL SITE emits `CallMember name=plusElement` — dynamic — with or
    without the receiver typed. So the runtime chooses between
    `Iterable<T>.plusElement` and `Collection<T>.plusElement` by name.
  - The two bodies lower DIFFERENTLY.
    `Collection<T>.plusElement` binds its `plus(element)` statically and
    correctly: `[emit] Call fqn=kotlin.collections.plus fid=2131 in_fn=plusElement`,
    which `[extkey]` ranks at 100105 over the concatenating overload's 100015.
    `Iterable<T>.plusElement` emits `CallMemberOrGlobal name=plus` — a bare
    call on an implicit receiver, the category section 6 lists as dynamic.
  - At run time that dynamic `plus` sees a `List<List<String>>` receiver and a
    `List<String>` argument, both `Iterable`, and picks the concatenating
    overload. Hence `[[s], a]`.

So the resolver's answer is right in one body and never asked for in the other,
and the call site never commits to either declaration. Two independent things
would each fix it, and both are wanted anyway:

  1. Bind the call site. `[extkey]` at `CollectionTest.kt:531` scores the two
     candidates `{1,1,0,0,60010,…}` and `{1,1,1,0,60010,…}` — they differ at
     index 2, where `Collection` is higher, so the ranking already prefers the
     more specific receiver. It is the EMISSION that is missing, as with the
     member promotion that landed earlier in this round.
  2. Bind `CallMemberOrGlobal` when the implicit receiver is statically known.
     That is section 6's first item and it is worth far more than this one test.

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

### 6. Genuinely dynamic by design

Not counted as failures, but they must be enumerated before "full" means
anything:

  - `CallMemberOrGlobal` — a bare call in a receiver context that could be
    either a member or a top-level function.
  - `LoadFromThisOrGlobal` / `StoreToThisOrGlobal` — the bare-name read/write
    walks over implicit receivers.
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
3. **The typeck generic-argument project — 3,886 sites, 60%.** Now by a wide
   margin the largest remaining piece, and the only one that requires typeck
   work: substituting type arguments through call sites and propagating them
   from declarations, so a `List`'s or an `Array`'s element type is known.
4. `no_class_id` — 617, mostly type parameters whose bounds resolve plus the
   unsigned host primitives that belong to section 5.

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
