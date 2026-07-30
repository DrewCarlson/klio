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

So the remaining candidates are what those reductions still omit: the real
`synchronized` is an `expect` with a klio actual rather than a user inline
function, `RecomposerInfoImpl` is reached through an interface-typed collection
in a companion (`_runningRecomposers`), and the getter is annotated. Bisect from
the real file downward rather than building up from a toy — building up has now
cost four attempts and produced no reproduction.

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
