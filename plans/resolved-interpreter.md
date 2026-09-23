### Priced: what actually keeps a frame from being fused

`engine/*` begins with "the tiers cannot collapse until the base path is
fast enough", so the first question is which frames the frameless path is
failing to take and why. Three instruments now answer it, and each one
overturned the reading before it.

**98.3% of frames are for bodies the flattened subset can run end to end** —
`frame_push` 3 555 524 against `frame_push_flattenable` 3 496 841 over the
corpus. So the instruction set is almost never the obstacle. It is a
STATIC classification, though, and reading it as "these frames were
avoidable" would be wrong; it says only that nothing in the body is out of
subset.

**The classify gate is not the obstacle either.** `KLIO_FUSE_DECLINE` puts
`classify` at 4 960 of 5 406 declines on a compose program, which reads as
the whole problem until `KLIO_FUSE_CLASSIFY` splits it: those 4 960 come
from just 959 classifications, memoized per `Func`, and 800 of them are
`block_count`. `FUSED_MAX_BLOCKS` is a bound on classification work, not a
storage limit — the register bank is what is sized — so it was raised 64 ->
4096 and measured: **5 406 frames -> 5 407.** The functions it rejects are
not the ones being called. Reverted to a knob rather than a change.

**The entry gate is not the obstacle.** It excludes a call with a receiver,
a closure, a chain seed or captures, and `engine/member-calls-frameless`
names the receiver case as the keystone. `KLIO_FUSE_GATE` counts which
conjunct turns a call away: **has_receiver 6, is_closure 84,
has_captures 15, and 3 269 OFFERED.** The gate lets almost everything
through.

So of 3 269 calls offered to the tier, 344 fuse. The decline is inside, and
the comment above the gate already names it: `allow_materialize` is false,
because a body the walker cannot finish pays the tier's entry AND the frame
it then opens — measured at the time as a 2.9% loss on a recomposer frame.
The bodies being turned away are the HEAVY ones, verdict 4, which are heavy
because they contain calls the walker cannot serve.

`KLIO_FUSE_HEAVY` then says what makes a body heavy, and the dispatch
cases are counted apart by whether the site names its target:

| | |
|---|---:|
| `call_callee_not_fusable` (transitive) | 128 |
| `call_virtual_slot` | 76 |
| `call_member_by_name` | 68 |
| `call_named_or_typeargs` | 30 |
| `call_member_resolved` | 2 |

`CallVirtual` is the largest dispatch reason that already carries a target,
and the pieces to serve it exist: `prepareVirtualFlatCall` returns a
`FlatCallReq{func, args}`, which is exactly what `fusedExec` takes, and
`loop.zig` already drives the tier that way from a prepared site.

**It still cannot be done as an increment, and the reason is worth writing
down.** `fusedClassify` produces a STATIC verdict, and a virtual call's
target varies with the receiver, so classify cannot prove that every
implementation in a slot family is fusable — nor stay proved, since a class
can be registered while the program runs. Serving these means attempting
the call and bailing when the target turns out not to be fusable, which is
a bail in the middle of a body that has already run. That is precisely the
trade the gate's own comment records as measured: a body the walker cannot
finish pays the tier's entry AND the frame it then opens, a 2.9% loss on a
recomposer frame, which is why `allow_materialize` is false.

So the keystone is not "add a `CallVirtual` arm". It is making a
half-finished body cheap to continue — `fusedMaterializeAndRun` exists but
costs more than it saves — and that is what `engine/full-bytecode` and
`engine/retire-tiers` are for: one representation the engine executes, so
there is no second path to hand a body to and no entry to pay twice. The
three instruments here are the gate that will say when that lands.

### The sole blocker, decomposed

Five instruments agree that `field_read_by_name` is limited by one thing: a
receiver with no class. `KLIO_DISPATCH_STATS` now splits what those
receivers ARE, by expression shape and, for a bare name, by what the name
is — the one distinction a tag breakdown cannot make.

Of 984 untyped receivers on a compose program, 827 are a bare `Path`:

| | |
|---|---:|
| `local_init_untypeable` — a local whose initializer the deriver cannot type | 377 |
| `other` — not a local, a capture or a parameter | 158 |
| `local_no_init` — loop variable, destructured component, catch parameter | 153 |
| `lambda_param` — `it` and its named siblings | 91 |
| `captured` | 48 |
| `Call` 68, `Member` 64, `Index` 14, rest | 146 |

Two of these were surprises worth recording. **`lambda_param` should not
exist**: a parameter has a declared type. Tracing the names says what they
are — `it`, `frame`, `pair`, `slot`, `group`, `item` — every one a LAMBDA
parameter, whose type comes from the callee's expected signature and not
from anything at its declaration, so the deriver has nothing to read. And
`local_no_init` at 153 is the binding forms that record no initializer at
all, which is a different repair from the 377 whose initializer is
recorded and untypeable.

The largest of them, the untypeable local initializer, decomposes once
more. By initializer shape: `Call` 224, `Index` 49, `Binary` 49, `Member`
43, `Path` 11. And running `classifyCallReturn` over those calls — the
same classifier that priced the top-level return fix at 179 -> 3 — gives
`unique_unresolvable` **160**, `not_simple_callee` 58, `no_func` 6.

`unique_unresolvable` means a unique function with a declared return type
whose head cannot become a `ClassId`, which on the receiver side turned out
to be an ambiguous simple name. It is not that here. Printing the heads:
**all 160 are `R`** — a bare type parameter, `ambiguous=false`. The call's
return is generic and its concrete type comes from the instantiation at the
call site, which is what `instantiatedCallReturnTypeScoped` is for and what
it fails to supply for these.

So `resolve/receiver-types` bottoms out in six leaves, and none of them is
a missing wire:

| | |
|---|---:|
| generic return instantiation (`R`) | 160 |
| `other` — a bare name that is no local, capture or parameter | 158 |
| binding forms recording no initializer — loop variable, destructuring, catch | 153 |
| lambda-parameter expected-type propagation | 91 |
| a callee too complex for the return channel | 58 |
| captured | 48 |

Each is a distinct piece of type inference. That is why the eager typeck
channel measured at 0.03 points and why closing this bucket is a compiler
project rather than a plumbing pass — and it is now specified to that
level rather than asserted.

### Measured: the field-read residue has no dominant cause

`field_read_by_name` is the largest unresolved class at 2.0M sites and was
chased three ways, each of which returned a negative worth keeping.

By NAME, corpus-wide, the top targets are `<instance>.value` 3 208,
`<instance>._next` 2 113, `<instance>.$sgetter$$anon$0index` 1 078 —
overwhelmingly `<instance>.X`, the receiver's class unknown at the site,
and no single shape behind them.

By the shared name-canonicalization path: `memberNameIdentity` hashes a
name to a program-lifetime pointer on cached reads, which looked like a
per-read probe on the hottest path. `KLIO_NAMEID_PROBE` prices it at
**2 544 for a whole compose program and 0 for a field-read loop** — it is
reached only on cache fills, and is not a bottleneck.

By the one concrete case big enough to matter, `value` on an atomicfu
receiver, which DID find a real defect: `Node.next()` reading `_next.value`
records `own_cls=AtomicRef`, while `Node.read()` reading `counter.value`
records `<none>` — though the property types as `AtomicInt` either way. The
cause is that **`AtomicInt` is declared by three packages**
(`kotlin.concurrent`, `androidx.compose.ui.platform`, `kotlinx.atomicfu`),
so `uniqueClassIdBySimpleName` declines, while `AtomicRef` is unique and
resolves. The deriver carries a SIMPLE head, and a head that lost its
package can never become a `ClassId`.

That is a real and general defect, and it is also small: splitting
`recv_not_a_class` into "no class has this name" and
`recv_ambiguous_simple` puts the ambiguous share at **91 of 19 486 claim
attempts, 0.47%**. Fixing it means carrying qualified heads through the
deriver, which is worth doing on its own terms and is not what stands
between this bucket and zero.

A fourth pass found the one plumbing gap that was left, by tallying which
EMITTER produces a `GetField` carrying no class: `KLIO_GF_TRACE=*` with
`KLIO_GF_STACK` makes each one name itself. The largest was
`lowerShortInterp` — string interpolation. `"$x"` where `x` is the
enclosing class's own member reads it off `this`, whose class is the
owner, and the arm recorded nothing. Filling it from `ownerClassIdOf`:
unresolved `GetField`s 9 830 -> 9 399, those carrying a class 2 542 ->
2 739, property-slot bindings 820 -> 970.

The tally also corrected itself once: `tryClassReference` looked like the
second-largest classless emitter and is not one — it emits the
`<class-companion-or-self>` sentinel, which `push` binds through `own_kind`
rather than `own_cls`. Counting `own_cls == null` alone overstated the
population until the trace printed the kind too.

With that gap closed the largest remaining emitter is `lowerMember`, which
DOES ask for the receiver's class and is told nothing. So the shape of
`field_read_by_name` is confirmed from two directions — by emitter and by
refusal reason — and it is derivation, not plumbing: `accessor_or_method`
2 147 wants a getter route or a property slot rather than a slot index,
`recv_type_unknown` 984 is the receiver-type fixpoint,
`no_layout_interface` 744 has no storage by definition, `name_absent` 683.
No single change moves it the way the subscript moved member calls.

A fifth pass closed the question from the last direction available.
`accessor_or_method` is the largest of those reasons, and the getter route
is what should answer it, so `KLIO_GETTER_WHY` splits why `getterFor`
finds nothing: `subclass_declares` 613, `chain_end` 319, `plainly_stores`
256, `value_class` 202. Those are not losses — they fall through to
`propSlotOf`, which is exactly the instrument for a property a subclass
answers its own way, and it binds 970.

Counting what the link pass achieves on the sites it can see: of 2 739
unresolved reads carrying a class, 791 bind a getter, 970 a property slot,
545 a companion slot and 13 an open-class slot — **2 319 of 2 739, 85%**.
The machinery is not the gap. The gap is the 6 660 reads that carry no
class at all, which is `resolve/receiver-types` and nothing else.

Four instruments now agree on that: the by-name target census, the
`[no-slot]` refusal census, the per-emitter tally, and this one.

`tryOwnMemberRead` was the last emitter with the same gap the indexed
write and the interpolation had: a read of the owner's own member off
`this`, recording `own_cls` only when the SLOT claim held. The class is the
owner either way, and `linkGetterRoutes` reads `own_cls` to look for a
getter or a property slot — so a read the slot could not answer was not
being offered to the passes that exist for exactly that. Filling it takes
`with_class` 2 739 -> 2 842 and binds **nothing more**: those 103 carry a
class now and `getterFor` and `propSlotOf` both still decline them. Kept
because the fact is true and was absent, recorded as neutral because it
bought nothing.

### A construction stops asking for a class it was handed

`call_new_instance` is the one remaining bucket that is a single mechanism
rather than a tail: the site carries a `ClassId` and the path from it to the
object consulted names. `KLIO_CTOR_NAME_PROBE` prices it exactly —
**three `classDefByName` probes per construction**, 4 500 000 over a
1.5M-construction loop — and `=2` names their callers, because guessing
which of a dozen call sites runs per construction was wrong twice.

Two of the three were the same mistake in different places. The first, at
the top of `newInstance`, turned the id it was handed back into a string to
find the class; `ProgramImage` now carries a `ClassId`-indexed table of
`ClassDef` handles, filled ONE SLOT AT A TIME on demand — an eager fill
costs two probes per class in the program whether or not anything
constructs one, and `inheritance.kt` paid 437 probes for five
constructions before the fill went lazy. The name lookups stay as the
fallback for a class registered while the program runs.

The third was `materializeInstance` looking up the leaf of the constructor
chain by name — the class being constructed, whose def the caller passed
in. The arm even falls back to that def, but only after the probe has run
and failed. Identity is by FQN so a same-simple-name class in another
package cannot be mistaken for it.

**Probes 4 500 000 -> 1** on the construction loop, `inheritance.kt`
437 -> 39, and **12.34 s -> 11.70 s, 5.2%**, alternating runs with no
overlap. A tiny program costs 0.11 s either way.

Then four more of the same mistake, each found by asking the probe who its
callers were rather than guessing — which was wrong twice when guessed. The
chain loop re-derived the CURRENT class from its name when that class is
the parent the previous iteration resolved and was holding. The two passes
over the finished chain reached each entry by name, so `ChainEntry` carries
the `ClassId` its def resolved to, recorded where the entry is built
because the def is in hand there. The parent lookup went by name when the
child's own `ClassDef` can memoize its parent's id — which is what
`super_cid` was added for. And `expandParentSecondaryThisArgs` re-resolved
on its first turn a class its caller had just resolved, so it takes the
handle as a hint.

**Thirteen name probes per chained construction down to zero.** 7 800 002
-> 5 for 600 000 three-deep constructions; the flat loop is 1 for
1 500 000. **13.40 s -> 11.97 s, 10.7%**, three alternating runs with no
overlap.

**`KLIO_CTOR_NAME_AUDIT` reports any construction that consulted a name at
all**, outermost only so a nested one counts in its parent. Filling the
index on first construction left one probe per class — `class=Plain
probes=1` — and "never re-derives by name" is not "re-derives once", so the
index is filled where the program links instead: `vmFromBuilt` is the one
place the module and the class table are both in hand, and it resolves
398 of 398 on a small program.

Two instrument defects surfaced doing it, both the same shape as the ones
before. The counter only incremented under the PROBE knob, so the audit ran
alone and silently measured nothing — the control now is
`KLIO_CTOR_ID_LINK=0`, which puts the fill back on first use and makes the
audit report `class=Plain probes=1` on demand. And the lazy path REBUILT
the table whenever a different module's id arrived, so a layered run had
two modules clearing it against each other: `UnsafeLazyImpl` audited 1 978
times, which reads as one probe per construction and was in fact the table
being destroyed between them.

**7 800 002 name probes -> 2** for 600 000 three-deep constructions,
`inheritance.kt` 437 -> 9, and **13.49 s -> 12.08 s, 10.5%**.

**The compose residue is NOT cross-module, which a measured negative
settled.** The obvious reading of 5 903 probes for 747 constructions was
that a layered run constructs from a pack's module and the single table
cannot serve it, so per-module tables were built — three besides the
program's own, filled lazily. They bought 29 probes of 5 903. The
instrumented table says why: the link fill resolves 1 370 of 1 370, no
construction ever asks for an id past the table's length, and
`classDefById` answers every one. The extra tables were complexity for
nothing and are reverted.

The last machinery probe was the plainest of all of them.
`expandParentSecondaryThisArgs` climbs `this(...)` delegations, and it
resolved the class's def on EVERY turn of that loop — while never
reassigning `class_name` or `class_fqn`, which are its parameters. The loop
walks delegations within ONE class, so every turn asked for the same class
again. Hoisted out of the loop, and taking the caller's handle when it has
one.

**The construction machinery is name-free on every shape tested.** A
deliberately hard one — secondary constructors delegating with `this(...)`,
an `init` block, a defaulted parameter, an interface, three deep — goes
300 007 probes -> **7** for 300 000 constructions. The three-deep primary
chain is 2 for 600 000. The flat class is **0** for 1 500 000.
**14.06 s -> 13.41 s, 4.6%** on the hard shape.

The last name use in the machinery was `firstNonInterfaceSuper`'s
single-fill memo, which resolves supertypes by name — once per class, but
DURING execution, where every other memo this campaign added is built by a
link pass. `primeSuperMemos` fills it in `vmRun` before the program starts.
Per construction the audit is then silent: 300 000 `Leaf` constructions
report once, 600 000 three-deep ones report not at all.

**Two attempts at the cross-module case, both measured negative, and the
second corrected the first's reasoning.** A layered run constructs from a
pack's module, whose ids the program's table does not describe, so
per-module tables were built — three besides the program's own. They were
reverted on a reading of `class_def_by_name_probes`, which was the wrong
instrument: that counter totals every `classDefByName` caller, including
the member-call path. Re-applied and measured with the per-construction
AUDIT instead, they change it by nothing at all — `DispatchedContinuation`
reports 16 either way. The probes a layered construction makes are its ctor
BODY's member calls, traced to `paramTypeIsFunInterface` under
`samParamMask`, and no id table for any module can remove those. Reverted
again, on the right grounds this time.

Two subsystems were still asking a name inside a construction, and both
were asking a question about a CLASS once per construction rather than once
per class.

`samParamMask` fills the SAM parameter mask of the function a constructor
body calls. That is the member-call subsystem's own question and the audit
was blaming the construction for it, so the probe is attributed where it
belongs.

The constructor boundary has its own SAM conversion, and it resolved every
primary parameter's declared type by name on EVERY construction — including
types like `<function>` that name no class and whose lookup could only
miss. `ClassDef.ctor_sam_mask` decides it once. On a compose program that
is **5 874 name probes -> 1 871**; both memos are then primed in `vmRun`
beside the supertype one, and the per-construction audit falls from 23
reports to 5.

`hardctor.kt` — secondary constructors delegating with `this(...)`, an
`init` block, a defaulted parameter, an interface, three deep — audits
**clean**, as do `inheritance.kt` and a 600 000-iteration three-deep loop.
**14.11 s -> 13.38 s, 5.2%.**

`paramAcceptsArg` under `scoreCtorHeads` was the last of them, and it asked
the smallest question of all: does this declared type name a real class at
all? A typealias has no `ClassDef`, so a miss must not reject the
candidate. The answer is a property of the program and it was being asked
per construction, of every declared parameter type. `namesAClass` memoizes
it by the name's identity, guarded by length and the dispatch generation
against a reused address. Compose's audit falls 5 reports -> **2**, and
both of those are that memo's own first fill.

**Where `call_new_instance` actually stands.** Three shapes audit clean:
`hardctor.kt`, `inheritance.kt`, and a 600 000-iteration three-deep loop. A
whole compose program reports twice. The machinery from a `ClassId` to the
object consults no name; what is left is memo fills — once per class, or
once per thread per name — which every other resolved kind in this
campaign also has, with the sole difference that theirs are built by a link
pass and two of these fill lazily because the memo is per-thread and a link
pass cannot reach another thread's copy.

That is the whole of the gap, and it is stated here rather than resolved by
relabelling: the kind stays unresolved until those two are link products
too, or until the standard for "resolved" is written down to admit a
once-per-name fill. Both are decisions to make deliberately, and the audit
measures either one.

Worth recording separately, because it was found by asking the probe who
its callers were rather than guessing: the dominant `classDefByName` caller
on a compose program is not construction at all. It is
`paramTypeIsFunInterface` under `samParamMask`, on the MEMBER-CALL path,
and it is already memoized per thread against the dispatch generation —
6 918 probes against roughly 1.5M member calls is its miss rate, not a
missing memo.

### The write side never asked the receiver anything

With the array subscript total, the largest remaining by-name member calls
are `kotlin.String.get` 5 160 and then `kotlin.IntArray.set` 4 538,
`FloatArray.set` 2 686, `Array.set` 940, `LongArray.set` 492. The `set`
entries are the surprise: the same operation, the same receivers, the same
total path — and none of them resolved.

The probe says why in one line: **`get=4742 get_with_head=4604`,
`set=2034 set_with_head=0`.** Not one indexed assignment carried a static
receiver head, so `linkBuiltinMembers` could never prove the receiver kind.
The lowering arm says it outright in a comment that had been sitting there:
"Unlike the read side, this arm asked the receiver no question at all."
`stmt.storeToIndex` emitted its `CallMember` with `arg_names` and nothing
else, where the read side records the head it already derived.

Deriving the same head on the write side: `set_with_head` 0 -> 1 548, proven
sites 3 968 -> 4 968, static unresolved **5.71% -> 5.50%** on a compose
program, `KLIO_BUILTIN_AUDIT` clean over 585.

`kotlin.String.get` is the next one and it needs the other half of the idea.
A String subscript cannot be made total the way an array can — the UTF-16
walk and its exception are the native's contract and reimplementing them at
the fast path would duplicate semantics. But `kotlin.String.get` IS in the
host table, at a fixed index, so the site can carry that INDEX and a decline
can dispatch it directly. That is the intrinsic id, scoped to what it is
actually for: not naming 1 616 entries at every call, but giving a proven
site a resolved SLOW path so its fast path is allowed to decline.

### A site is resolved when its path cannot decline

`call_member_by_name` was the largest unresolved class, and four hypotheses
about it were wrong before the data settled it. It is not a missing type: the
member-call gate's own census says 84% of what it leaves unresolved has a
KNOWN receiver, and feeding lowering more types is worth 0.03 points
(`KLIO_EAGER_RECV=0` vs `1`) against 0.92 for what follows. It is not a
missing intrinsic id either: of 4 606 unresolved sites carrying a static
receiver head, the 1 616-entry host table answers 234.

The names say what it actually is. 3 800 of the 4 372 misses are
`LongArray.get`, `Array.get`, `IntArray.get`, `FloatArray.get` — the
subscript, which `BuiltinMember` already bound and `fastSubscript` already
serves. They were counted unresolved for one reason: **the path could
decline.** `fastIndexGet` returned null for an index outside the array, and
a decline reaches the by-name walk, so no matter what the site knew, the
runtime could still resolve it by name.

An array with an `Int` index declines for exactly one reason, and that reason
is an exception the walk would raise anyway. Raising it at the fast path
makes the path TOTAL, and a total path is what "resolved" means. The
contract is unchanged to the letter — `IntArray(3)[5]` is still
`ArrayIndexOutOfBoundsException`, `listOf(1,2,3)[9]` still
`IndexOutOfBoundsException`, `"héllo"[1]` still `é`.

String and the scalars are OUT of the proven set, and the audit is why they
are: a String subscript serves only an ASCII in-bounds index and leaves the
UTF-16 walk to the native, so it can legitimately decline.
`KLIO_BUILTIN_AUDIT` reported exactly that — `get op=get recv=String
in=printQuoted`, repeatedly — the first time the set was wider, and reports
nothing over 585 programs now.

**`call_member_by_name` 1 370 610 -> 1 249 716, `call_member_builtin_op`
963 363 -> 1 078 873 and now RESOLVED, static unresolved 6.124% -> 5.208%.**
Most of that is the reclassification of sites the census was already
counting apart — which is the point: the work was making the claim true, not
relabelling it. 115 510 sites are newly bound; 963 363 stopped being able to
fall back.

# A resolved interpreter

klio's interpreter is not slow because its loops are badly written. It is slow
because **the IR it executes is under-resolved, so the runtime re-derives at
every execution what the language decides once at compile time**. The execution
tiers, the per-`Func` verdict bytes, the site memos, the argument-signature
folds and the receiver-chain hashes are all compensation for that.

This plan removes the cause rather than widening the compensation. Every item
here is a correctness and clarity improvement on its own terms: a Kotlin member
call has one meaning, fixed by the declaration site, and an interpreter that
re-decides it per execution can decide it differently. Speed is the consequence.

## The goal

klio's interpreter executes a **fully resolved IR**. Every call, field access
and name reference that Kotlin decides statically is bound at lowering to a
concrete target — a `FuncId`, a class-relative method slot, or a field slot —
and the runtime never re-derives one by name. The machinery that exists today to
compensate for deferred resolution is gone rather than widened: the `XOrY`
instructions, the per-call argument-signature fold, the name-keyed registry
probes on the dispatch paths, the dynamic enclosing-`this` chain, the five
execution tiers with their per-`Func` verdict bytes, and the per-activation
argument carriers and keepalive entries.

What stands in their place: one execution engine over one bytecode
representation; objects with fixed layouts addressed by index; virtual calls
through per-class tables; and activations that are windows into a contiguous
per-thread value stack, rooted by scanning it.

The ordering below is a property of the work rather than a preference. Nothing
is measurable or defensible until the censuses are exhaustive and a mode exists
that refuses to resolve by name. Representation cannot be indexed until sites
carry resolved targets. The tiers cannot collapse until the base path is fast
enough not to need them. The stack rewrite is only tractable once frames have
stopped carrying resolution state.

This is reached **without weakening anything** — the rules under "What must not
weaken" are part of the goal, not a caveat on it. An interpreter that is faster
because it checks less has not reached this goal.

Done is the six conditions under "Done means", holding together.

## The evidence

Measured with the instruments the ratchet added: the static site census
(`KLIO_SITE_CENSUS`), the executed dispatch census (`KLIO_DISPATCH_STATS`),
the emitter census (`KLIO_EMIT_CENSUS`, symbolized by
`scripts/emit_census_symbolize.py`), and the lowering census read from a
**cold cache**, since a warm run loads pre-lowered IR and lowers almost
nothing.

One compose program's 90 836 unresolved sites, by the arm that emitted them:

| Sites | Kind | Emitting arm |
|------:|------|--------------|
| 18 201 | `field_read_by_name` | `paths.tryOwnMemberRead` |
| 17 324 | `field_read_by_name` | `member.lowerMember` |
| 6 318 | `call_new_instance` | `call_general.tryIndexedConstructor` |
| 6 060 | `call_member_by_name` | `expr.lowerIndex` |
| 5 822 | `call_member_by_name` | `member_call.lowerMemberCallFallback` |
| 3 804 | `field_read_by_name` | `paths.tryBareThisRead` |
| 3 776 | `field_write_by_name` | `stmt.storeCombinedToTarget` |
| 2 795 | `name_read_this_or_global` | `paths.emitBareThisOrGlobal` |

**Field reads are 45% of every unresolved site.** They are addressed by
`represent/class-layout` and `represent/field-slots`, and the receiver of the
two largest arms is the enclosing `this`, whose class lowering already knows.

Why the member gate cannot bind, over the same program's 33 660 consultations:

| Reason | Sites | Share |
|--------|------:|------:|
| `no_member_by_name` | 10 063 | 29.90% |
| `bound_static` | 9 584 | 28.47% |
| `bound_virtual` | 9 254 | 27.49% |
| `no_receiver_type` | 2 798 | 8.31% |
| `member_shape_refused` | 565 | 1.68% |
| `no_class_id` | 478 | 1.42% |
| `ambiguous_member` | 307 | 0.91% |
| `resolver_declined` | 228 | 0.68% |
| `super_receiver` | 157 | 0.47% |
| `self_recursive_undecided` | 118 | 0.35% |
| `dynamic_by_design` | 52 | 0.15% |
| `explicit_type_args` | 26 | 0.08% |
| `member_arg_refuted` | 23 | 0.07% |
| `nullable_or_generic` | 7 | 0.02% |

One caveat on that table: a call carrying the compose `($composer, $changed)`
pair consults the gate twice — once as written, once with the pair stripped —
so a composer-shaped site contributes two rows. `[fallback]`, which counts
outcomes rather than consultations, is one row per site.

**The receiver's class simply does not declare the name at 29.90% of sites.**
Kotlin resolves those to extensions, which is why `resolve/extensions` is the
largest resolution item and not `resolve/receiver-types`. The earlier reading
of this table — 45.69% `bound_virtual`, 13.81% `no_receiver_type` — came from
counters that were `threadlocal` while lowering runs on the worker pool, and
from a gate with six exits that recorded nothing.

Executed, over the 575-program corpus: **52.33% of dispatches resolved,
44.71% unresolved**, and `call_member_resolved` runs 6 328 times against
`call_member_virtual`'s 1 175 692 — 0.54% of member calls arrive knowing what
they call. `[ext-fb] total` is 307 833 extension-fallback walks.

**A static total summed over the corpus counts the stdlib image once per
program.** A trivial program's whole-program census is 147 753 sites; a
compose program's is 710 887. So roughly 85 million of the corpus's 116
million sites are the same shared image counted 576 times. That makes the
summed total a poor absolute number and a good *delta*: a change to how the
stdlib lowers shows up multiplied, consistently, on a pinned program set,
which is exactly what the running log uses it for. Absolute shares belong to
a single program's census.

**An executed total summed over the corpus is not a representative workload**,
and the sweep now prints the top contributor and its share beside every one so
it cannot be read as though it were. `load_this_or_global` is 97.6% one
program (`tailrec_forms.kt`), `field_read_host_by_name` 71.3% another
(`jit_char_tag_static_call.kt`), `static_decline_named` 99.2% a third. The
corpus is a correctness set with a handful of deliberate micro-benchmarks in
it; a perf claim belongs on `benchRecompose` and the interleaved A/B in
`plans/pack-suites-to-green.md`, never on these sums. What the sums are good
for is the direction of a delta on a pinned program set, which is how every
number in the running log below is used.

Where the time goes, by sampler self time on `benchRecompose`:

| Area | Share |
|------|------:|
| The frame walker and the frameless/leaf tiers | 36% |
| VM host dispatch layers (`vm/*`, `exec_call`) | 30% |
| Name hashing and hash-map probes | 15.6% |
| Allocation and free | 6.4% |
| `ObjRef` borrow | 3.0% |

The hashing share has no hot spot — twelve callers, none dominant. That is what
a design that re-hashes names per operation looks like from a profiler.

## What we are aiming at

Measured, not estimated: `scripts/headline-costs.sh` runs
`tests/bench/headline_costs.kt`, which takes each number as the difference
between two loops identical but for the thing being timed, so loop overhead,
the clock call and the induction variable cancel.

| Quantity | klio, measured | A no-JIT bytecode VM |
|----------|---------------:|---------------------:|
| Trivial register-to-register integer instruction | **2.10 ns** | 2-5 ns |
| Cheapest activation | **46-51 ns** | 20-50 ns |

Both are already inside the target band, and that is the finding, not a
victory: **it is what the five tiers buy.** The benchmark's loop never reaches
the framed walker — `KLIO_FRAME_COUNT` reports 49 activations and 266
instructions for a run executing billions of both — so these are the fastest
tier's numbers on the shape it is best at. The earlier figures in this table,
~12-25 ns and 117 ns, are not reproducible by this method and were not
measured by it.

That makes them a floor rather than a goal: `engine/retire-tiers` has to hand
one engine a loop like this and come out at the same 2.10 ns and 46 ns, or
the collapse has cost something real. A measurement on compose-shaped code,
where the tiers decline far more often, is the other half and is not taken
yet.

Two traps this benchmark had to survive, both of which produced confident
wrong numbers first:

- `fun identity(x: Int) = x` is spliced at lowering and costs no activation
  at all. The first run measured 1.07 ns and 49 frame pushes for 2.8 million
  intended calls — the interpreter being right and the measurement being
  wrong. The callee is self-recursive now, which blocks the splice while the
  recursive arm never runs.
- A body of `a = a xor i` repeated cancels in pairs, so a folding pass could
  delete exactly what is being timed. It is `a = a + i`.

One recomposition runs 5 110 generic-arm instructions and 1 510 activations. At
the right-hand column that is 26 µs + 60 µs against **2 811 µs today**. The
order of magnitude is there, and none of it needs a JIT.

## What must not weaken

These are hard constraints on every item below, not aspirations.

1. **No test is deleted, skipped, `xfail`ed, renamed around, or weakened.** The
   suite counts in `plans/pack-suites-to-green.md` are floors. A change that
   lowers one is reverted, not documented.
2. **No gate step is removed, shortened, or made non-blocking.** `scripts/gate.sh`
   must be green at the end of every item that lands.
3. **A golden file is re-baked only when the changed value is provably an opaque
   implementation detail**, with the proof written into the commit message (the
   instance-counter rebake in `noncallable_capture_member_fallback` is the
   template: three independent confirmations that the drift predated the change,
   and the program's own assertions unchanged).
4. **Runtime machinery is deleted only when a census proves it unreachable**
   across the whole corpus, never by inspection. "Nothing calls this any more"
   is a measurement, not a reading.
5. **Instruments are added before the change they verify and stay afterwards.**
   An audit that proved a migration is a permanent regression test, not
   scaffolding.
6. **Every replacement path ships with a dual-compute audit** proving it agrees
   with the path it replaces, on the full corpus, before the flip. This is the
   house pattern already: `scripts/resolve_audit_sweep.py` and
   `scripts/or_audit_sweep.py` are the models.
7. **Diagnostics are not casualties.** The tracing knobs in
   `docs/development/debugging.md` keep working; a knob whose subject is deleted
   is removed from the doc in the same commit.

## How a change here is proved

Three instruments, in this order, for every item:

- **A census that can reach zero.** Before changing a resolution path, extend
  the existing audit (`src/ir/lower/expr/audit.zig`, `KLIO_DISPATCH_STATS`) so
  the thing being removed has a counter. The item is done when the counter is
  zero on the whole corpus, not when the code looks right.
- **A dual-compute audit for the flip.** Run old and new side by side, log
  divergence, sweep the corpus, require zero. Then flip, then delete the old
  path, then delete the audit's dual arm but keep its assertion.
- **The gate.** `scripts/gate.sh` green, run with nothing else touching
  `.zig-cache`. Perf claims additionally need the interleaved CPU-time A/B in
  `plans/pack-suites-to-green.md`; the gate outranks any benchmark.

---

# The work

Ordered so that each section unblocks the next. Status values: `todo`,
`doing`, `done`, `blocked: <reason>`.

## The ratchet

Nothing below is measurable or defensible without this, and it changes no
behaviour. Do it first and completely.

| Id | Item | Status |
|----|------|--------|
| `ratchet/site-census` | Every call, field and name site classified, including the `XOrY` instructions and `LoadFromThisOrGlobal`, each with its own counter. `src/ir/site_census.zig` walks the whole lowered module and classifies every instruction and terminator through one switch that is total over `Inst`, so a new instruction cannot enter the IR without a verdict. `KLIO_SITE_CENSUS=1`. | done |
| `ratchet/runtime-census` | A matching runtime census: for each site class, how many executions took the resolved path versus re-derived by name, naming the responsible site. `[dispatch-verdict]` splits the executed census into resolved / unresolved / dynamic over the same verdicts; `[unresolved]` names each site as `<kind> <recv>.<name> @<function>`. | done |
| `ratchet/require-resolved` | `KLIO_REQUIRE_RESOLVED=1` counts every execution of an unresolved site, names the sites, and exits non-zero; `=raise` throws at the site instead of serving it. Every interpreter tier gates on the same classifier — the framed walker, the fused walker, the leaf serve and the bytecode `gf_site` op — and the mode turns the compiler off, since compiled code runs past all four. | done |
| `ratchet/corpus-sweep` | `scripts/site-census-sweep.py` runs the corpus under both censuses and prints the totals, with `--json`/`--baseline` for the delta and `--require-resolved` for the ratchet's pass count. | done |
| `ratchet/baseline` | Recorded in the running log below. | done |

**Exit:** the sweep runs clean, prints a complete classification of every site
and every dispatch, and `KLIO_REQUIRE_RESOLVED=1` fails loudly with an accurate
count of what remains unresolved.

## Resolution

The root change. Each item moves a class of decision out of the runtime and into
lowering, and ends with its census counter at zero.

### How this work is measured, and why it changed

Progress here was being reported as a share of the site census, and that
number moved 4 111 230 -> 3 420 624 without a single piece of machinery
leaving the tree. Every unresolved variant, every one of the 23 producers,
and every consumer arm is still exactly where it was. A census delta is
reversible and says nothing about the end state; a deletion is neither.

**Two rules from here.**

*Progress is a deletion.* An item is done when a variant is gone from
`Inst`, its producers are gone from lowering, and its consumer arms are gone
from the census, the disassembler, the evaluator and cgen. Sites bound is
the means; removed code is the measure.

*The fix belongs where the fact is missing.* A pass that re-derives after
lowering what the emitter should have known is compensation, and the goal
names compensation as the thing to remove. `linkReceiverClasses`,
`linkGetterRoutes`, `linkBuiltinFields` and `linkCtorPicks` recover 58% of
what is emitted unresolved; they exist because lowering emits blind. Adding
a sixth is not progress, and neither is an emitter arm that only queries a
table that was already there.

### The producer side: where the types are missing

The register lattice in `module_regclass.zig` is klio's strongest type
facility, and on the biggest remaining kind it can name only 405 of 2 823
classless member-call receivers. Running it earlier would not help: it is
not late, its INPUTS bottom out. Per program the classless receivers are
written by

| producer | count | what is missing |
|----------|-------|-----------------|
| `LoadParam` | 144 | 136 of them declare a bare type parameter, which names no class |
| `Move` | 173 | the moved register was already unnamed |
| `CallValue` | 139 | a call through a function value has no declared return |
| `LoadGlobal` | 71 | the global's declared type is not carried |

These are the producer-side items, and each one creates type information
that does not exist today rather than re-reading some that does:

1. **A type parameter is its upper bound.** `registry.TypeParamBound` already
   records `head_only` for exactly this reason — its own doc says the bound
   "names the single classifier the parameter is bounded by ... enough to
   answer which class owns a member call on the parameter" — and
   `FuncBuilder.type_param_bounds` carries every parameter in scope, own plus
   the enclosing class's. Nothing consults it when naming a receiver.
2. **A function value's return type.** A `CallValue` through a
   `Function1<A, B>` returns `B`, and the callee register's type argument
   carries it.
3. **A global's declared type.** `LoadGlobal` records the class for an
   object, and nothing for a typed `val`.

### What lowering cannot ask, and has to be given

Resolving `super.f()` turned up a gap that is not about super at all, and it
limits every direct-call binding.

**There is no index from (class, name, arity) to an EXECUTABLE declaration
that lowering can read.** Two tables look like one and neither is:

- `registry.member_method_fids` is a SIGNATURE index. Its writers use
  `getOrPut` and the first writer is the reserved header, so the FuncId it
  returns routinely has no body. That is survivable for a direct call only
  because `linkBodyless` later redirects a bodyless header onto its
  same-owner body sibling, and it is NOT survivable when the declaration has
  no body anywhere: link settles that onto a native instead, and a
  collection native dispatches on the receiver's own class. Binding
  `super<ArrayList>.add` that way re-entered the subclass override and
  recursed until the stack gave out. `decl_sigs.has_body` is the
  discriminator between the two, and it is the only one.
- `Class.methods` DOES hold executable bodies only — and it is filled at the
  end of lowering that class, while bodies lower from a pool. Reading it
  from inside another body is order-dependent, so it cannot be consulted at
  the point a call is emitted.

So the producer to build is an index of executable declarations, populated
where declarations are registered rather than where classes finish, and
stable against the body pool. It is what a direct-call bind needs, it is
what the arity-keyed slot arm is working around with its ambiguity set, and
nothing in the tree offers it today.

### The elimination order

Variants come out by distance to zero, not by site count: a kind with nine
sites and one producer is a deletion this week, and one with nine hundred is
not. On `examples/collections.kt`:

| variant | sites | producers | note |
|---------|-------|-----------|------|
| `type_ctx_load_by_name` | 1 | 1 | |
| `CallSuper` | 2 | 2 | `super.f()` is non-virtual and the language names the target |
| `StoreToThisOrGlobal` | 2 | 1 | |
| `CallMemberOrValue` | 9 | 1 | |
| `CallValueOrMember` | 74 | 5 | needs the splice receiver |
| `call_new_instance` | 295 | 1 | stub classes and ambiguous arities |
| `EnclosingPush`/`Pop` | 458 | 4 | needs 1 and 2 above |
| `CallMemberOrGlobal` | 430 | 8 | needs 1 and 2 above |
| `field_read_by_name` | 528 | 6 | host-backed layouts |
| `call_member_by_name` | 902 | 4 | needs 1, 2 and 3 |

Where the table stands now, by the running log below: `type_ctx_load_by_name`
is gone with its three instructions and the host context stack (a context
parameter is a parameter); `StoreToThisOrGlobal`'s one producer is the walk's
undecided write, and the walk's residuals are what the entries since chase
(`this_rebound_unknown` and `outer_class_declares` gone or nearly, the
shapeless-lambda producers closed, `subject_head_unknown` and
`closure_tower_unknown` next); `QualifiedThis` has a structural replacement
(`LoadOuterThis` and the owner's registers) that answers most of its
producers, the rest carry an audit name. The kinds' corpus-wide counts are
in each entry's census table.

`CallSuper` was listed here as a deletion and it is not one. The
instruction has no resolved form, which is the part that was right: it now
carries `any_default` and `target`, and `call_super_by_name` goes from 6 289
corpus-wide to 2 sites on `examples/compose_todo.kt`. But the variant STAYS.
A non-virtual member call has no other spelling — a slot claim is re-proved
against the receiver's runtime class and a super receiver is always a
subclass, and a native member needs its receiver unwrapped in a way neither
`Call` nor `CallVirtual` does. So for this row the target is the by-name
SITE kind reaching zero, not the union shrinking.

That leaves seven variants on the deletion list, and `EnclosingPush` /
`EnclosingPop` are the only ones that are pure bookkeeping: they carry a
tower that exists solely so `CallMemberOrGlobal`'s runtime walk can rank
receivers. They come out when that walk does, not before.

### The work list, enumerated by the compiler

Counting sites in the census says how much is unresolved; it does not say how
many places have to change. Renaming the seven unresolved variants out of
`Inst` and building answers that exactly, because every producer and every
consumer becomes a compile error:

**49 errors: 23 producers across 10 lowering files, 25 consumers, 1 census read.**

| Variant | Producers | Where |
|---------|-----------|-------|
| `CallMemberOrGlobal` | 7 | `bare_call` 2, `call_general` 3, `call` 1, `emit` 1 |
| `LoadFromThisOrGlobal` | 5 | `paths` |
| `CallValueOrMember` | 5 | `call_general` 3, `local_call` 2 |
| `EnclosingPush` / `EnclosingPop` | 4 | `inline_call` 3, `control` 1 |
| `StoreToThisOrGlobal` | 1 | `stmt` |
| `CallMemberOrValue` | 1 | `member_call` |

The consumers are bookkeeping: `site_census`, `disasm`, the four `eval` arms,
`cgen`, `diag`, `module_props`. None of them holds a decision; they disappear
with the variants.

**The 23 producers share one missing fact.** Each one is guarded by a question
about the implicit receiver that lowering cannot answer:

- `CallMemberOrGlobal` asks whether the implicit receiver declares the name in
  a *callable* form that accepts this arity — `hasBareCallCandidate` is the
  guard, and it declines because the receiver is not identified.
- `LoadFromThisOrGlobal` asks whether a runtime member of the implicit
  receiver shadows a class name — `inReceiverContext` and
  `classRefNeedsReceiverWalk`.
- `CallValueOrMember` asks whether a captured name is shadowed by a member of
  the *spliced* receiver — guarded literally on `b.spliceRecvTy() != null`.
- `EnclosingPush`/`EnclosingPop` exist only to carry that receiver to the
  runtime so the question can be asked there instead.

So the producer to build is one capability, not six: **static identity of the
implicit receiver at every point in a body, including inside a spliced inline
lambda**, and then the resolver's existing `resolveMemberCall` answers the rest.
That collapses 17 of the 23 producers directly and gives the other 6 a class to
ask about.

The ordering that follows:

1. Static implicit-receiver identity. The one new producer.
2. Delete `EnclosingPush`/`EnclosingPop` — with the identity known they carry
   nothing, and the goal names them for removal.
3. Turn each remaining producer's guard into a resolved emit, variant by
   variant, deleting the variant once its producers are gone.
4. The link passes that re-derive these facts after lowering come out as their
   categories become unreachable. They are compensation for emitting blind and
   must not outlive it.

The measurement that justifies this shape: of 9 980 instructions emitted in an
unresolved form on `examples/collections.kt`, 5 823 (58%) are resolved
afterward by link passes re-deriving what the emitter did not know. The
architecture already concedes that lowering emits before it knows. Fixing that
is the work; every pass that patches afterward is the symptom.

### Where the two biggest kinds actually stop

Both reduce to the same structural fact, and it is not about when lowering
runs. **A host-backed classifier carries no interpreted layout and no method
table**, so neither a field slot nor a method FuncId can be claimed against it.

*Field reads.* 1 963 of 2 263 classless receivers name one of the 25
intrinsic classifiers, and the whole category is six property names: `size`,
`lastIndex`, `indices`, `storage`, `length`, `data`. Proving the first three
from the receiver's head took the kind from 1 406 to 528 on
`examples/collections.kt`.

*Member calls.* Of 397 sites whose receiver class is known and whose
hierarchy declares the name, 341 are counted "argument shapes unknown" — but
the hierarchy declares **zero** of them as a method with a signature. The name
is known only from a shadow set or a declared property. They are interface
methods on classifiers with an empty `Class.methods`:
`kotlin.Comparator.compare` 144, `kotlin.CharSequence.get` 126,
`kotlin.collections.List.get` 28, then `MutableList.set`, `MutableMap.get`,
`Collection.add`. The resolved form for these is a **virtual slot on the
interface**, not a FuncId and not a proven builtin — `builtinValueHead` already
records, in the code, that widening it past the array classifiers sends sites
back to the by-name walk, because the runtime's fast serve declines on a
UTF-16 index, an out-of-range subscript or a live backing.

So the next producer is method slots for host-backed interfaces, and it is the
exact counterpart of the field-layout gap.

### The enclosing-this chain is already mirrored statically

`EnclosingPush`/`EnclosingPop` maintain a receiver tower the runtime walks
innermost-first, and the emitter under a tower deliberately withholds a
receiver: "the chain already holds every nested subject in scope order, so
pinning one register inverts Kotlin's innermost-first ranking."

Lowering keeps the same stack. `FuncBuilder.subject_binds` is a list of
`SubjectBind{ reg, head, prior_this }` pushed and popped at exactly the splice
sites that push and pop the runtime tower, and `probe.implicitReceiverOfType`
already walks it innermost-first and returns a register. The static mirror of
the dynamic chain exists; nothing asks it the question the walk is for.

The question it is missing is not "which receiver has type T" but Kotlin's own
rule, "which is the innermost receiver with an APPLICABLE member of this
name". With the arity key that is answerable without argument types:

    implicitReceiverDeclaring(b, name, arity) ?Reg
      subject_binds, innermost first, then the declaration's own receiver or
      owner instance; the first whose class holds an unambiguous
      (head, name, arity) member that no same-named extension could serve.

A hit emits `CallVirtual` on that register. When nothing hits, the site still
falls to the walk. That is the order in which the chain comes out: the
consumers stop needing it before the instructions are deleted.

It reaches `CallMemberOrGlobal` under a tower — the funnel says 46 of 230 bare
calls carry a tower and 87 more sit inside a splice — and then
`EnclosingPush`/`EnclosingPop` themselves, 458 sites per program, which exist
only to carry the tower the runtime walks.

### `CtxLoad` is a calling convention, not a lookup

`type_ctx_load_by_name` reads as the smallest item on the list and is not one.
A `context(Foo) fun bar()` lowers a `CtxLoad(Foo)` at BAR's entry, and the
ambient `Foo` was pushed by the caller's `CtxScope`. The callee cannot name a
register for it, because which register holds the `Foo` is the caller's
property — the scope is dynamic across the call boundary by construction, and
no amount of lowering-side bookkeeping in the callee changes that.

The resolved form is not a better lookup. It is to stop passing context
values out of band: a context parameter IS a parameter, and a context
argument IS an argument. Lowered that way `CtxLoad` and `CtxScope` both leave
the union and the context values ride the ordinary call ABI, which is what
every other parameter already does. 639 sites corpus-wide, four producers.

### A slot claim cannot express a non-virtual read

`super.<prop>` on a STORED property looks like a field read, and rewriting
the site to `GetField{own_cls, own_slot}` takes `call_super_by_name` to zero
on `examples/compose_todo.kt`. It also hangs `examples/super_property_setter.kt`.

The claim on `GetField` is a HINT: the runtime re-proves the receiver IS that
class before it serves the index, and falls back to a by-name read when it
is not. A `super` read's receiver is by definition a SUBCLASS, so the claim
never holds, the fallback dispatches virtually, and it lands on the override
whose getter is the very `super.count` being evaluated. `LoggingCounter`
recurses until the corpus times out.

So the resolved form for a stored-property super read is not a slot claim,
and `CallSuper` cannot leave the union while one exists: nothing else in the
instruction set says "read exactly this class's cell, without dispatch". The
same holds for the call case, where a super call into a host-backed member
is neither a plain `Call` — the native needs its receiver unwrapped — nor a
`CallVirtual`, which re-enters the override.

`CallSuper` is therefore a RESOLVED instruction once it carries a target,
not an XOrY to delete. What must reach zero is `call_super_by_name`, the
by-name SITE kind, and the variant stays as the non-virtual member call the
language requires.

### Not every link pass is blind compensation

Done says no surviving pass may re-derive at link time what an emitter could
have known. `linkGetterRoutes` is the test case and it EARNS its place.

`accessor_or_method` is the largest refusal in the no-slot census — 2 152 of
19 501 claims on `examples/compose_todo.kt` — and the resolved form is the
getter's FuncId rather than a slot index. The emitter has the receiver class
in hand, so the question looks like one it could answer. It cannot: the
accessor Func is created when the DECLARING class's body lowers, bodies
lower from a pool, and a read emitted before that body runs would find
nothing. Binding it in the emitter would succeed or fail by pool order,
which makes the image non-reproducible — strictly worse than deciding once,
afterwards, when every accessor exists.

So criterion 8 is about passes that recover a fact the emitter HAD and
dropped, not about every pass that runs late. `linkGetterRoutes` is named
and justified here. `linkReceiverClasses` and `linkBuiltinFields` are the
ones still to answer for, since a receiver's static class and a builtin
property's head are both known where the instruction is pushed.

### A new bind is a gate change, not a sweep change

Four mis-bindings this session, every one latent until a site bound the slot,
and every one a case the fast loop could not see:

| bind | defect | caught by |
|------|--------|-----------|
| arity-keyed member slot | an arity-matched MEMBER beat an applicable EXTENSION — `Random.nextLong` takes a `LongRange` as one and a `Long` as the other | stdlib sweep |
| simple-name key | answered for a namesake class in another package, binding `clearWatchSet` onto a `ReadonlySnapshot` | corpus |
| slot-bound call | entered a placeholder body past its pack binding, so a held lock granted `tryLock` | parity litmus |
| super label | `@A` treated as a supertype qualifier, so `super@A.foo()` bound `A.foo` and the base's virtual call never ran | **e2e only** |

The last row is the rule. Corpus 585/585 and a clean stdlib sweep passed it;
`itest-e2e` failed it on both jit arms. Binding is exactly where latent
wrongness surfaces, so a change that binds a site is a change that has to
clear `scripts/gate.sh` before it is reported as done — the corpus and the
sweep are the iteration loop, not the verdict.

### Why binding harder at the emit point stopped paying

Five attempts in a row moved between zero and five sites each. They are not
five unrelated misses; they are one fact measured five ways.

**Every unresolved variant is emitted at the END of a chain that has already
tried the resolved routes.** `CallMemberOrValue` is reached precisely when
the member gate declined, so asking the member question again there cannot
answer it. The same holds for `CallMemberOrGlobal`, `CallValueOrMember` and
the this-or-global pair. A new query at the emit point queries evidence that
the arms above it already found wanting.

What the five measurements name, each time, is a missing *description of a
class* rather than a missing lookup:

| attempt | reach | what was actually absent |
|---------|------:|--------------------------|
| type parameter to its bound | 0 | the bound's class has no unambiguous key for the name |
| member arm on `CallMemberOrValue` | 0 | the gate above already failed the same question |
| bare call through the receiver walk | 9, reverted | the receiver, and it bound one wrong |
| unqualified write proved global | 2 of 435 | 262 names ARE declared by the chain; only 15 were not top-level |
| unqualified write to a claimed slot | 5 of 262 | `fieldSlotClaim` finds no cell for 257 of them |

The last row is the sharpest. For 262 writes per program the hierarchy
PROVABLY declares the name — the negative proof succeeds — and the layout
still fixes no slot to write it into, because the property is accessor-backed
or the layout is partial. The evidence for "which class holds this" exists;
the evidence for "and here is the cell or the setter" does not.

So the producer is neither a type nor a lookup. It is **complete, claimable
class descriptions**: a layout that gives accessor-backed properties a slot
or a named setter, and member sets whose `complete` flag is earned rather
than withheld. `ownerChainShadowContains` returns null — "cannot say" — the
moment one level is partial, and it did so for 42 of 435 writes on one
program. One producer, and it is upstream of every emit site that is
currently stuck.

### Measured negatives from this pass

- **Answering "scope complete" for a receiverless body.** 90% of
  `receiverScopeCompletePlain` consultations (11 396 of 12 670) take the
  `owner == null` branch and return "cannot say". Returning "complete and
  empty" instead — which is what a body with no implicit receiver actually is
  — moves **one** site on the corpus. Those consultations come from sites that
  resolve by another route, so the refusal is not what holds them. Probe:
  `KLIO_SCOPE_WHY=1`.
- **The arity key on a bare call, through the receiver walk.** With the
  innermost-first walk in hand the deferred bare call can ask it too, and it
  is worth nine sites and a wrong answer. `takeSnapshot().run { clearWatchSet(c) }`
  bound the enclosing class's declaration onto the snapshot: the ambient
  `this` inside a splice is the spliced receiver, and neither the
  subject-stack fallback nor a splice guard covers every way a body reaches
  that emitter. The walk stays where its receiver is known; the bare emitter
  does not get it. Two guards the failure exposed DID land, and they protect
  the arms that stayed: a declaration found under the simple-name key must
  belong to the head's class or an ancestor, and an extension splice withdraws
  the own-receiver fallback.
- **The arity key on a BARE call, by the receiver alone.** The member-call arm that binds an
  unambiguous (head, name, arity) key pays nothing on `CallMemberOrGlobal`.
  The funnel over 230 sites: 46 have a receiver tower, another 87 are inside a
  splice, and of the 97 left the member table has no entry for the name at
  that arity at all — `lowerUnresolvedBareCall` is reached precisely when the
  name is not a clean own member. So 58% of these sites are the splice and
  tower receiver-identity problem and the rest are not member calls.
- **Teaching the register lattice about literals.** A `Const` receiver names
  its classifier exactly, and adding the arm moves zero sites: those registers
  have more than one writer, so the meet is bottom regardless, and the
  classifier is intrinsic-backed so it carries a head with no class either way.
- **Binding `lastIndex`/`indices` to the stdlib extension getter.** It
  resolves the same 500 sites, and it is the wrong trade: the runtime already
  serves both inline from the receiver's tag, so naming the getter replaces a
  length read with an activation. Proving the builtin gets the census and
  keeps the fast path.

| Id | Item | Status |
|----|------|--------|
| `resolve/extensions` (first) | 29.90% of gate consultations end in `no_member_by_name`: the receiver's class does not declare the name, so Kotlin's answer is an extension. The fallback binds exactly half of what reaches it (`[fallback] extension_bound=5471 by_name=5487`), and `[no-ext]` says why the rest is withheld: 91.34% `no_candidates` (no extension exists — the call is something else), then `unknown_args_singleton` 2 156, `unknown_args` 325, `tied` 259. **A lone ranked candidate is not a sound commit**, and `scripts/ext_audit_sweep.py` now proves it rather than inferring it from three broken tests. `KLIO_EXT_AUDIT=1` logs the declaration a commit would name beside the one the by-name walk actually serves; joined on (name, receiver head) over the corpus: 71 keys agree, **5 diverge**, 1 is ambiguous, and 1 120 are unproven because the runtime never serves them. The divergences are not subtle — `contains` on `IntRange` would bind `androidx.collection.contains` where the runtime serves `kotlin.ranges.contains`, `drawRipples` would bind material's where material3's runs, `forEachIndexed` on `IntArray` would take `kotlin.collections`' over a member extension. Any commit criterion has to drive that column to zero first.

What the divergences say is that the blocker is not the one the counter names. `unknown_args_singleton` reads as "one candidate, and only the argument types are missing", but every divergence is a *scope* disagreement: the runtime's walk reaches a candidate lowering's ranking did not have, or ranks differently — a member extension on `Arrangement`, material3's `drawRipples` over material's, `kotlin.ranges.contains` over `androidx.collection.contains`. And `appendElement` on a type-parameter head shows lowering picking three different declarations for one key, so at those sites the pick is not a function of the key at all. Reconciling lowering's tier ranking with the runtime's `enclosingOwnerSet` + `funcsBySimpleName` walk is the actual work; widening the commit criterion is not.

With `--cands` the audit separates the two failures. Three of the five are *not a candidate at lowering* — the runtime serves a declaration the resolver never collected (material3's `drawRipples`, `compose.foundation.style`'s `isNullOrEmpty`), which is a collection gap. The other two are collected and out-ranked: `kotlin.ranges.contains` sits at tier 65 and `androidx.collection.contains` at 66, and a member extension on `Arrangement` sits at tier 0 against `kotlin.collections.forEachIndexed` at 66. So the ranked set's sole member is routinely not the best-scoped candidate, which is the mechanism behind the reverted change.

One caveat that matters more than the numbers: the join aggregates every call site sharing a name and a receiver head, and different sites see different candidate sets. A divergence therefore proves a criterion unsound; an absence of divergence proves nothing. A "best-tier-unique" criterion measured 0 divergences on one run and 5 on the next from the same tree — the first run raced a concurrent rebuild. **Making the absence mean anything needs a per-site key: lowering stamping its would-be pick on the instruction and the runtime comparing at the moment it serves.** That is the next step, and no commit criterion should land before it.

**The per-site audit is built.** `CallMemberExtra` carries an `audit_pick`
that `emitDeferredMemberCall` stamps under `KLIO_EXT_AUDIT`; the member-call
arm publishes it, and every route that produces a target for that call
compares — the by-name walk, the site memo that replays its verdict, the flat
prepare, both extension caches. One row per executed site, with the enclosing
function on it. It found three things the join could not.

*The criterion was missing a condition the resolver already computed.*
`kotlin.invoke` is `DeepRecursiveFunction<T, R>.invoke`, and the resolver
ranked it the sole best-tier candidate for ordinary closure invokes: 3 402
sites where a commit calls the wrong declaration. The winner's declared
receiver must RELATE to the static one, which the resolver computes for its
own use and the best-tier bit now requires. Every one of those drops out.

*The runtime had a bug the join blamed on lowering.* A null receiver carries no
type, and every nullable-receiver candidate proves equally against null, so the
lenient walk read that as proof and let an arbitrary one outrank the declared
head. `isNullOrEmpty()` on a null `List` ran
`androidx.compose.foundation.style.isNullOrEmpty`, declared on
`StyleAnimations?`. The declared head is the only evidence a null value leaves,
so it decides. That closed the 27 remaining example-corpus divergences.

*The instrument was comparing names.* `kotlin.time.toDuration` is three
declarations under one qualified name, so the comparison read the wrong
overload as agreement. Comparing by identity turned 11 587 silent agreements
into 3 644 divergences at one site. Two klio/kotlinc divergences were under it,
both now fixed: an integer literal scored as evidence for a `Double` parameter,
and the const type deriver could not read `Long.MAX_VALUE`.

Where it stands: over the example corpus the pick names the served declaration
at **11 587 of 11 587** executed sites, and the broad criterion (any withheld
pick) diverges at 3 403 of 23 556 — a decisive measured negative for the broad
form. Over the stdlib tests the narrow criterion is still wrong, at one shape:
`flatten` inside `kotlin.sequences.flatten` is served by
`kotlin.sequences.TransformingSequence.flatten`, **a declaration the resolver's
candidate set does not contain at all**, so committing recurses into the public
overload forever. Requiring a single surviving candidate does not help — there
already is one; it is the wrong one because the set is incomplete.

The `flatten` blocker turned out not to be a collection gap. The member gate
read `(this as TransformingSequence<*, T>).flatten(iterator)` as recursion
because it compared the target's *name* to the enclosing function's and nothing
else, so a member the narrowed receiver declares looked like the extension
containing the call; the member stayed unbound and the extension took it. A
member of the receiver's class is not the top-level declaration being lowered.
The resolver also withholds outright when the winner shares the enclosing
declaration's name, since that is the one shape it cannot tell from recursion.

**The criterion is on.** With it, the pick names the declaration the runtime
serves at 11 587 of 11 587 executed sites over the examples and 690 644 of
690 668 over the stdlib tests. The 24 that differ are `Array<T>.getOrNull`
against the `List` overload the by-name walk serves on a receiver declared
`Array<T>` — lowering is right there and the walk is not, the same escape as
the null receiver, so committing fixes them. On `compose_window.kt` the
fallback binds 39.70% of what reaches it, against 36.80% before.

**The audit population must include the commontest corpus.** The examples
reported zero divergences under a criterion that broke two stdlib tests, and
seeing that needed `KLIO_SWEEP_GREP` on `commontest-sweep.py`. Any future
criterion is measured on both. | doing |
| `represent/getter-route` | **Done, and it names what is left.** `linkGetterRoutes` runs after every class body has lowered — the earliest a read can name a getter, since the getter is a function the body lowering creates — and binds 2 641 reads on a compose program. Two contracts, and the second is the common one: `__get_<Class>_<prop>` bound ZERO of 19 522 on its own, because a read the layout cannot answer is far more often `Int.dp` than a class's own accessor, and `__ext_get_<Head>_<prop>` is where those live. The serve proves the receiver is on the claimed chain first; without that five programs read a property off the wrong object. What the pass cannot bind, by name, says the rest is three different mechanisms rather than one: companion constants (`Color.Unspecified` 683, `Offset.Zero` 172 — the accessor is the companion's and is not under either contract), interface properties (`Composer.skipping` 504, `ProvidableCompositionLocal.current` 291 — implemented per class, so they want a SLOT, which is `represent/vtables`), and builtin members (`List.size` 228 — an intrinsic, not a `FuncId`).  **The contract search was wrong, and correcting it moved the census.** Accessors are not in `func_name_index` — a compose program carries 2 440 `__get_` functions and the index holds none — so the pass scans the function table for the contract name instead. A first attempt at that read the table POSITION as the `FuncId`; the two are unrelated, and `b.area` ran `CoroutineContext.Element.fold`. With `Func.id` the search is right and the bindings it adds need three guards, each of which a program proved: a value class's accessor takes the UNDERLYING value as its receiver, so naming it hands the getter a box and it decodes garbage (`Color.red` read 22 for 50); a class that PLAINLY STORES the property answers from its cell, so the walk must stop there rather than climb; and a strict subclass that redeclares the property can answer it its own way, so an ancestor's accessor is only nameable when the read's proven receiver class is final or `subclass_declares_prop` is empty for it. `Rgb` stores `isSrgb` where its base `ColorSpace` declares `get() = false`, and without the last guard every read of it served that false — which is the divergence `KLIO_GETTER_SERVE=audit` was built to catch, and now reports zero of on the corpus and the stdlib sweep. 1 966 bindings, down from the 2 641 the index route claimed and sound where those were not; `field_read_by_name` 2 919 871 -> 2 845 760 and static unresolved 7.17% -> 7.11%. | done |
| `resolve/receiver-types` | Give lowering the receiver's static type where typeck already knows it. 8.31% of consultations, of which 69% are a bare `Path`; its halves are `local_no_decl_type` (1 095) and `enclosing_member` (408, after the inferred-head pass took it from 729). **This is what `resolve/or-instructions` waits on**, and the XOrY audit priced it: 9 514 of 9 850 gate declines on a compose program are names the lexical owner's hierarchy does not declare at all, so the receiver whose type would settle them is an implicit one lowering cannot name — a lambda subject or an extension receiver, not `this`.

**A top-level function's inferred return is the first slice, and it was a channel that simply stopped at the class boundary.** `declOrderExprBodyReturnTypeRef` types an expression body with no declared return by lowering it in a scratch builder — but it demanded an enclosing class, so it answered for members and not for top-level functions. `internal inline fun h1(hash: Int) = hash ushr 7` in androidx.collection is the shape: one declaration, exact resolution, and `[scrt-target] inferred=-` all the way out, so `h1(hash) and probeMask` had no receiver type and the `and` resolved by name — 1 818 times in one compose run. The owner channel cannot reach a top-level function because its owner is the synthesized per-file class, whose name no call site spells, so the AST is indexed by the header stub's `FuncId` instead. Exactly the declarations that need it are indexed: an expression body with no declared return. The body types with no owner and no receiver, which is what the declaration itself has; an extension is declined outright, since its body reads a receiver this builder cannot name.

`no_receiver_type` 1 792 -> 1 526 on a compose program and its `unique_concrete` bucket 179 -> 3 — the whole set the classifier said a return channel would answer. Over the corpus, `call_member_by_name` 2 358 929 -> 2 345 096 and `call_virtual_slot` +8 725, executed by-name member calls -6 499 virtual and -1 740 static, static unresolved 6.614% -> 6.602%.

**The implicit-receiver read needed a second channel before it was worth anything, and measuring it first is what found the second.** `count.inc()` inside the class that declares `val count: Counter` has no channel at all: the name is not a local, not a call, and nothing types it. The arm — the innermost implicit receiver, then the splice receiver, then the owner's own chain, in Kotlin's order — is a dozen lines and on its own bound ZERO. `enclosing_member` stayed at 377 with it on or off, and the names said why: `_next`, `_prev`, `_state`, `_decision`, `notCompletedCount`, the atomicfu and coroutine internals declared `private val _next = atomic<Any>(this)`. Their type is INFERRED, so `class_prop_type_refs` has no entry and `class_prop_type_heads` covers only literal and constructor initializers. The arm was worth exactly what property-type inference from a call initializer is worth.

So the property's initializer types the same way a function's expression body does: in a scratch builder owned by the declaring class, which is the scope the initializer actually has, with a depth cap for a property whose initializer reads another inferred one. Together the two channels take `no_receiver_type` 1 792 -> 1 179 on a compose program, `enclosing_member` 377 -> 168 and `local_no_decl_type` 687 -> 458. Over the corpus, `call_member_by_name` 2 345 096 -> 2 335 559, `field_read_by_name` 2 540 674 -> 2 532 892, `call_static_id` +6 186, `field_read_slot_claimed` +4 152, static unresolved 6.602% -> 6.586%. `KLIO_IMPLRECV_TY=0` withdraws the receiver arm and `KLIO_PROPTY_TRACE=<prop>` prints what an initializer typed to.

**The channel's first gate RED was a latent wrong answer it had made reachable, not a new one.** `tl_limited_one` died with `kotlinx.atomicfu: argument 1 must be Int/Long`, and the trace named it in one line: `LockFreeTaskQueue._cur init=Call ty=AtomicInt`, where the source is `private val _cur = atomic(Core<E>(capacity, singleConsumer))` — an `AtomicRef`. Lowering had been answering `AtomicInt` for that call all along; nothing consumed the answer until a property read did, and then every access went to the wrong intrinsic. `scalarOverloadUnproven` exists for exactly this and did not fire, for two reasons that were both accidents of the case it was written for: it required the picked overload's RETURN to be a primitive type name, and `AtomicInt` is a class; and it abandoned the whole check on meeting a candidate of a different arity, which `atomic(initial, trace)` is. The rule underneath has nothing to do with primitives — a same-named family that answers a different type per argument type makes any pick with the argument untyped a guess — so the check now skips candidates a one-argument call could not have taken, and proves the pick by asking whether the chosen overload's own parameter is what the argument is. A type parameter that would accept it, a supertype, or an argument typed as something no overload names all withdraw. Withdrawing is the safe direction: it declines to type rather than typing wrongly, and it costs 6.578% -> 6.586%.

The census says where the missing types are, cold, on `compose_window.kt`: 6 604 consultations with no receiver type, of which `Path` 3 929, `Call` 1 277, `Member` 727, `Binary` 469. The `Path` half splits `local_no_decl_type` 2 234, `unknown` 698, `enclosing_member` 571, `captured` 422; and the untyped locals split 1 589 ordinary locals against **645 parameters**.

A parameter with no recorded type is the surprising one, and it is not the function-body path: `recordParamDeclTypes` already writes every declared parameter type from `ctx.f.params`. The 645 are LAMBDA parameters, where `bindAnnotatedParamTypes` covers only the ones written down and `bindInferredParamTypes` needs the callee's expected type — which is resolution. So receiver types and call resolution are mutually recursive here, and the same knot shows up from every side:

- The 645 untyped PARAMETERS are lambda parameters, whose types come from the callee's expected type.
- The 1 277 `Call` receivers are 1 742 `not_simple_callee` — a member call, whose return type needs that member resolved.
- The 571 `enclosing_member` receivers are properties with no recorded type, and the super-chain walk finds a type for **0** of them: they are unannotated declarations whose type the inference pass could not reach from their initializers.

That last one is the clearest statement of the shape. `registerInferredPropertyTypeHeads` already took this bucket from 729 to 408 by inferring from initializers; what is left are initializers whose own type needs resolution. **The remaining resolution work is a fixpoint, not a series of independent lookups** — every unresolved kind is waiting on a type that is waiting on a resolution. An iterate-to-stability pass over declaration types is the shape that breaks it, and it is now built: `registerInferredPropertyTypeHeads` loops until no round learns a new head, with three channels beside the constructor call it already had — a literal or arithmetic fold, a call whose every visible declaration agrees on a DECLARED return, and `Owner.prop` where `Owner` names a classifier.

**It buys 28 sites of 6 604, and that is the finding.** The corpus settles in three rounds. Classifying the initializers the inference still cannot type says why: 5 012 of 6 972 are a `Member`, 806 a `Call`, 454 a `Binary` — and the `Member` receivers are locals, `this` and call results rather than classifiers, so each ad-hoc channel reaches a handful of sites and stops. The builder cannot do this job; it is full expression typing, which is typeck's. `resolve/receiver-types` should READ typeck's inferred declaration types rather than re-derive them — and following that through found the real state of the channel, which is not what it looked like.

**The receiver deriver never consults typeck.** `eagerTypeOf`'s only callers are `inline_call` and `arg_shape`, both about ARGUMENTS; the `no-recv` census was measuring a hypothetical. So the wiring is missing as well as the coverage.

**The coverage is the harder half.** typeck records 97 665 type heads over 1 872 files, and `eagerTypeOf` is asked 375 000 times while lowering one compose program: `no_entry` 354 691, `ok` 20 770, `ambiguous_simple` 2 907. The misses are not a file-numbering fault — 354 354 of them fall in files that DO carry entries — so the map is sparse by expression, at roughly fifty entries per file. Two causes, both in the export rather than in typeck: `eagerHeadOf` keeps only a `String` or a `Generic` head, deliberately dropping primitives because the same map feeds argument applicability where a head lacks literalness; and 45 876 entries were dropped as instantiation-dependent. The second is now kept — a head is `List` under every instantiation of `List<T>`, and a type parameter never yields a head at all — which adds 21 answers and changes nothing else, green on both corpora. The first needs the two consumers separated before a receiver question can have primitives.

Both are now done, and the chain ends somewhere specific. Primitive heads are marked rather than dropped, so the argument reader declines them exactly as before while `eagerRecvTypeOf` serves them; the receiver deriver asks that, last, after every rung that reads a declaration the builder can see. `no_receiver_type` falls 6 604 → 6 361 on a compose program, green on both corpora.

What stops it there is in typeck, not in the export. The checker holds **516 034** spans for that program and the export keeps 215 722; `KLIO_EAGER_AUDIT` now names every dropped variant, and the answer is one of them: **`Unresolved` 285 657**, against `Unit` 32 806, `Function` 21 097, `Nothing` 20 744, `TypeParam` 4 837, `Range` 877. `Type.Unresolved` is a bare tag with no payload — typeck models a plain user class that way and keeps its identity in `expr_class`, which covers 89 715 of those 285 657. So two thirds of the expressions typeck typed carry a user class it did not record the identity of, and no amount of export widening reaches them.

**The next step for this item is in typeck**: record class identity for the expressions it already types as `Unresolved`. Everything downstream — the receiver deriver, the member gate, the XOrY instructions — is waiting behind that one map.

How NOT to do it, measured: `convertTypeRefLossy` is the single place a named type becomes `Unresolved`, so a side channel there paired with the expression's span looks like the whole fix. It is not — `checkExpr` recurses into every sub-expression before the node's own type is computed, so a conversion count taken around `computeExprTy` attributes the subtree's conversions to the parent. Guarding on "exactly one conversion" then fires only for leaves: 255 more class-evidence spans out of 196 000, and one resolved receiver. The attribution has to be per conversion site, not per expression, so `KLIO_EAGER_AUDIT` now also counts the expression KINDS that reach the IR typed `Unresolved` with no class: `Path` 104 763, `Member` 48 900, `Call` 44 618, `Binary` 10 427. `Path` dominating means bare-name reads whose BINDING carries no `class_name`, and two such bindings did have the declared type in hand and passed null anyway — a `catch` binding and an annotated lambda parameter. Both record it now, and both are correct, and together they move `Path` by 192.

Which is the answer, arrived at from the typeck side as well: what is left are bindings with INFERRED types. `Type.Unresolved` could not carry a class through inference because it carried nothing.

**It carries one now.** The tag takes the declared name, filled at `convertTypeRefLossy` — the single place a NAMED type becomes `Unresolved` — and every other construction says `Type.unresolved`, the named form of what they all wrote before. The payload is metadata: equality, subtyping and unification ignore it exactly as they did when the tag was bare, so it cannot change a checking decision. It is borrowed from the AST, which outlives every `Type` built from it; the first attempt duped and freed it and aborted on a non-owned pointer.

Nameless `Unresolved` exports fall 285 657 → 227 790, heads rise 215 895 → 223 939, and `no_receiver_type` 6 361 → 6 258 on a compose program. Gate green.

What remains is what the payload cannot reach: a binding whose type came from no declared `TypeRef` anywhere in its chain. `Path` is still 104 534 of the unattributed spans, and each is a name whose inferred type is genuinely nameless — a lambda parameter typed from a callee, a destructured component, a loop variable. Those need the expected-type flow, which is the same mutual recursion with call resolution the census named at the start.

**One identity channel was missing outright, and it is not inference.** `KLIO_UNRES_KIND` counts the expression kinds that reach the IR typed `Unresolved` with no class, and `This` was 5 731 of them — `this` always knows what it is. typeck recorded the identity from `class_stack`, which holds classes and lambda-with-receiver subjects and nothing else, so `this` in an EXTENSION function body had none. It cannot come off `class_stack` either: that stack decides private-member visibility, and an extension body must not see its receiver's privates. A separate `this_ext_stack`, carrying the `class_stack` depth at the push so the innermost receiver wins, records identity and nothing reads it to make a checking decision — the same discipline the `Unresolved` payload follows. A receiver that names one of the function's own type parameters is skipped, since `fun <T> T.foo()` receives no class. `This` falls 5 731 -> 1 081, type heads rise 224 239 -> 229 854, `no_receiver_type` 6 255 -> 6 209.

The other half of the untyped locals is lambda parameters, and the main lambda path already types them from the expected function type. The scope-function path (`checkLambdaInPlace`) did not: `{ x -> ... }` names what `it` would have been, so a single explicit parameter now takes the binding the scope function supplies. Two sites. The channel is genuinely exhausted at this end — what is left of `local_no_decl_type` is initializers whose own type needs a resolution, which is the fixpoint. | doing |
| `resolve/member-binding` | A typed receiver binds its member call at lowering to a concrete target: a `FuncId` for a final/static member, a class-relative slot for a virtual one. `call_member_resolved` rises, `call_member_virtual` falls. | todo |
| `resolve/overloads` | Overload selection moves entirely to lowering, using the shared `applicable()` engine. The site records the chosen target; `memberSiteSig` and the per-call signature fold over argument values are deleted. | todo |
| `resolve/or-instructions` | `CallMemberOrGlobal`, `CallValueOrMember`, `CallMemberOrValue`, `LoadFromThisOrGlobal` resolve to their definite form at lowering. When each census counter reaches zero across the corpus, delete the instruction, its lowering arm, its interpreter arms in all five tiers, and its host paths. **Measured, per site, by `scripts/or_site_sweep.py`: 3 649 of 3 654 executed XOrY sites take exactly ONE arm** — 2 of `CallMemberOrGlobal`'s 2 640, 1 each of `LoadFromThisOrGlobal`'s, `StoreToThisOrGlobal`'s and `CallMemberOrValue`'s, 0 of `CallValueOrMember`'s. The instructions are a lowering-knowledge gap, not dynamism. The arm they take says which knowledge: 1 784 sites always bind a MEMBER, 751 an overload, and only 35 a global. So the work is not proving that no member can shadow — it is binding the member. Of 2 285 member-arm executions on `compose_window.kt`, 1 783 bind at depth 0, the innermost implicit receiver. The static gate declines them for one reason, and the compile-side audit says which: `hasOwnMember` is the LEXICAL owner's own members, while the runtime walks the whole receiver tower, so `isEmpty`, `append` and `packFloats` report `own=false` and defer while the runtime finds them one hop away. Extending the gate to INHERITED members buys almost nothing, and the compile-side audit says so before the code does: of 9 850 gate declines on that program, 202 have the name anywhere in the lexical owner's hierarchy and 9 514 have it nowhere. The member the runtime binds at depth 0 is a member of a DIFFERENT receiver than the owner's `this` — a lambda subject, an extension receiver, `kotlin.IntArray` for `parentAnchor`. One more measurement says what kind of knowledge is missing. Comparing the declaration the member arm binds against `cmg.func`, the global lowering resolved: they are the same **zero** times out of 2 271. The member walk never lands on the resolved global — it finds a different declaration, on an implicit receiver, and Kotlin ranks that above a top-level function. `parentAnchor` on a `kotlin.IntArray` receiver is the shape: an extension on an implicit receiver whose type lowering does not carry. So the fix is not a wider gate but a resolution-ORDER change — the tower's members and extensions must be consulted before a bare call commits to a global — and that is `resolve/receiver-types` plus the bare-call half of `resolve/extensions`. Reordering alone was tried and measured: asking the tower's member arm before accepting the resolved global converts 15 of 12 287 sites on that program, because the arm is blind for the same reason the gate is. Three measurements now say the same thing — the name is not in the owner's hierarchy, the walk never binds the resolved global, and consulting the tower first changes almost nothing. Blocked on the receiver's static type; the per-site sweep is the oracle when it unblocks. **The blocker is named and measured.** Not receiver types alone: an inline splice binds its receiver as a register of the caller's frame, so a bare call inside a spliced body has an implicit receiver neither `this` nor `EnclosingPush` accounts for. 1 179 of a compose program's 4 287 sites pass every static test for commitment and `KLIO_XORY_AUDIT` refutes them on 20 declarations. Waits on `represent/static-receivers`. | blocked |
| `resolve/member-deferral` | The member gate's `resolver_declined` bucket is **100% `target_known_deferred`** on a compose program — 4 966 sites where the resolver named the declaration and withheld the dispatch — which reads as the purest remaining lever: the answer is in hand and the runtime re-derives it. It is not. The per-site audit judges it as its own criterion (`kind=2`) and it agrees with the served declaration at **126 of 2 272 executions, 5.55%**. The resolver's own comment was right and the census name was not: `unknown_count == 1` names a candidate for RETURN-TYPE derivation, not for dispatch, and `map` inside a lambda diverges 2 005 times on its own. Closed as a measured negative; the deferral is doing real work. | done |
| `resolve/instanceof` | **Done, and it found the class graph was incomplete.** `is T` carried a `TypeRef` and the runtime re-derived the class from its name on every test — 170 417 executions over the corpus, and the single most repetitive entry in what `KLIO_REQUIRE_RESOLVED` reports, because a `when` over a sealed hierarchy is nothing else. The site names the class instead (`InstanceOf.cls`), and the test becomes a binary search of the receiver class's transitive ancestor closure, built once at link time. 2 091 of a compose program's 2 131 sites bind: a simple name through the unique-name index, a written-out one through the FQN index, and neither `is T?` — which admits null — nor `is List<String>`, whose argument is erased. Only an interpreted instance is answered; a host-backed value carries no module class and a wrong `false` there would be a wrong answer, so it falls to the walk.

**`KLIO_ISCHECK_SERVE=audit` found a divergence the corpus could not**: `LeftCompositionCancellationException is CancellationException` answered false by id and true by walk. The cause is not the test. `populateClassSupertypes` resolves each supertype as the class is REGISTERED and silently DROPS one it cannot see yet — a forward reference leaves neither a slot nor a ref — and nothing ever retries, so **111 classes on a compose program record no supertype at all** while the runtime knows their parent. Every pass that walks `supertypes` has been reading a root where there is a chain. The names survive in `registry.class_super_names`, and the ancestor closure reads them beside the slots. Repairing `Class.supertypes` in place was tried first and is wrong: those names are the TRANSITIVE closure, so appending them breaks both the documented parallel with `supertype_refs` and the meaning of `supertypes[0]`, and it broke two coroutine tests. The closure is this pass's own structure and carries neither invariant.

`type_instanceof_by_name` 170 417 -> 4 664 over the corpus, 1 647 649 executions now answered by id, static unresolved 6.84% -> 6.70%, `when_binding.kt` 11 -> 1 by-name resolutions. Audits clean on both sweeps; `examples/type_test_by_class.kt` pins the semantics. **`as T` asks the same question first, and taking the same answer is a measured negative.** Binding it is identical work and prices the same: `type_cast_by_name` 110 484 -> 11 605, static unresolved 6.70% -> 6.61%. It immediately found one rule `is` had not exercised — `Any` is every class's supertype and no class declares it, so the walk over declared supertypes never reached it and `Target as Any` threw a ClassCastException; the closure carries the implicit root now, which the `is` path wanted anyway.

Then `itest-bundle_smoke` threw `cast to KSerializer failed` in the BUNDLE build of a program `klio run` executes correctly. The asymmetry is what made the cast readable as evidence: a missing edge in the ancestor closure makes `is` answer a wrong `false` silently, and makes `as` THROW. The cast was reverted to find out which, and the answer was neither a missing edge nor an incomplete build path — the bundle had NO CLOSURE AT ALL. `linkClassAncestors` runs in the build's link pass; a bundle loads its image and goes, so the table it indexes was never built, and `classIsA` read "no entry" as "not a subtype". The `is` sites were answering false for every user class in a bundle the whole time, with every suite green, because none of them bundles a program that asks. Both halves of the repair are in `resolve/instanceof` now: the closure is rebuilt where the image finishes loading, and `classIsAKnown` returns null for a class the module has no closure for, so an absent table sends the read back to the walk instead of answering from it.

**The cast is served, positive only.** Where the value's class is at or below the named one the cast succeeds and the walk has nothing to add; a `false`, an unanswerable module and a non-instance value all fall through to the existing ladder, which is the only thing that can throw. So a missing ancestor edge can cost the serve and can never turn a passing cast into a raise — the asymmetry that made `as` the more dangerous half is designed out rather than waited out. `type_cast_by_name` 110 484 -> 11 605, 16 299 casts answered by id over the corpus, static unresolved 6.70% -> 6.61%. `KLIO_CAST_SERVE=0` withdraws it and `=audit` reports every cast the id served that the walk would refuse: zero over the corpus and the stdlib sweep. The two bundles that named the problem — the serialization program and `examples/type_test_by_class.kt` — now match `klio run` byte for byte.

(`Cast` kept its class field long enough to learn that `ClassId` fills its integer, so `?ClassId` has no niche and costs eight bytes where the 64-byte union had four — the instruction-size unit test said so before any corpus did.) | done |
| `resolve/no-class-id` | The `no_class_id` (1.42%), `member_shape_refused` (1.68%), `ambiguous_member` (0.91%) and `resolver_declined` (0.68%) buckets, once the larger ones are clear. | todo |
| `resolve/synthesized-sites` | The remaining synthesized operator sites the emitter census names: `set` through `stmt.storeCombinedToIndex` (2 636), the compound-assignment operators in `stmt.lowerAssign` (207), and `call_new_instance`'s constructor overload (6 450 sites, all from `call_general.tryIndexedConstructor`), which records a `ClassId` but no constructor. | todo |
| `resolve/residue` | Whatever is left is either genuinely dynamic (`dynamic_by_design`) or a real gap. Classify every remaining site by name in the running log; `dynamic_by_design` must be a short, justified list. The list the site census carries today is below and is already short. | doing |

**Exit:** `KLIO_REQUIRE_RESOLVED=1` passes the whole corpus and the full gate,
with `dynamic_by_design` the only surviving unresolved class and every member of
it named and justified here.

### `dynamic_by_design`, in full

Six site kinds, 1 401 092 sites over the corpus (1.20%). Each invokes or names
something the program computes, so Kotlin fixes nothing statically and there is
no target to record:

| Kind | Why it is not a gap |
|------|---------------------|
| `call_value` | `f(x)` where `f` is a value. The callee is a register. |
| `call_value_with_this` | The same with a bound receiver. |
| `call_spread_value` | The same through a spread argument list. |
| `call_ctx_value` | A contextual function-type value, invoked positionally. |
| `call_ctx_scope` | The stdlib `context(v..., block)`: `block` is a value. |
| `name_property_ref` | `::name` builds a `KProperty` that carries the name by definition; the name IS the value. |

What is *not* on this list and might be argued onto it: `name_ast_lambda` (a
lambda body still held as syntax) is a deferral, not a design — the resolved
form `name_ast_lambda_resolved` already exists and carries a `FuncId`.
`recv_qualified_this` is a chain search that `represent/static-receivers`
replaces with a register copy. `call_new_instance` names a `ClassId` and not a
constructor, which is a gap.

## Representation

Now that sites carry resolved targets, the data they address can be indexed
rather than searched.

| Id | Item | Status |
|----|------|--------|
| `represent/class-layout` | A per-class slot table computed once at link time. Field declaration order fixed; subclass layouts extend rather than rebuild. | done |
| `represent/publish-layout` | `ir.Class.field_layout` carries the slots a class adds to its superclass's, its capture candidates, its superclass id and the base count; `linkFieldSlots` (`ir/core/module_fields.zig`) composes them into `Module.field_layout`, a flat per-class table, incrementally over a baked base exactly as `linkMethodSlots` does, and the image carries it. `Module.classFieldLayout`/`fieldSlotIndex` are what a lowering reads. Construction now takes the composed table as its layout and keeps the `ClassDef` walk for a class the build cannot describe — one declared in a function body, an object expression's. Oracle: `KLIO_LAYOUT_AUDIT` computes both and reports every disagreement; over the example corpus 10 291 class comparisons, 0 divergent, 0 published-absent. | done |
| `represent/field-slots` | `GetField`/`SetField` carry a slot index resolved at lowering, guarded by a shape word. The name-comparison fallback in the site memo (`sameFieldName`) goes away because there is nothing left to disambiguate. **Open, abstract and interface receivers now claim** — the layout is base-prefixed, so only a subclass that redeclares the name can break the read, and that is a whole-program question. What is left is `accessor_or_method` (a getter route, not a slot), `body_property` (an inherited body slot an intervening class can replace) and `recv_type_unknown` (the receiver-type fixpoint). | doing |
| `represent/field-slots` — reads on `this` | `GetField` carries `own_cls`/`own_slot` when the read is on the enclosing `this` and the name is a declared slot of the owner's published layout — 14 496 of a cold compose build's 41 082 field reads, 35%. Getting there took moving the runtime class defs and the layout publish ahead of body lowering: the table used to be built in `finishModule` from `ctx.classes`, which `buildRuntimeClassDefs` fills, and both ran *after* `lowerClassBodies`, so the layout did not exist at the moment a read was emitted and the first attempt at this claimed zero sites. The claim is a hint, not an index taken on trust.

The runtime serves it: the read is the slot, with no name lookup and no discovery ladder. Four conditions make the claim sound, and each was found by the dual compute rather than reasoned out in advance — the slot must be a plain stored property (a getter's backing slot exists but the read must run the getter, so the layout records plainness per slot); the owner must be final, since an open class can be subclassed and the subclass may override with an accessor; the scope-qualified spelling `sgetterOwner` picks must name the lexical owner, because it walks the enclosing chain and an outer owner's read is a hop off a different instance; and the property must have exactly one cell, because a class that privately shadows or override-cells it has several under owner-mangled keys and the read takes the nearest owner's.

A sixth condition arrived when the claim widened to the other two field-read arms — the bare-`this` read and `recv.x` on a typed receiver — and the count went DOWN: only a **constructor property** may be claimed. A body property's slot holds its seed until its initializer runs, and a read that lands first is answered by the ladder running the initializer, where the claim serves the seed. The corpus had not exercised that on the first arm, which is why the first landing over-claimed; "the sweep was clean" is not "the claim is sound", and only the reason is.

Corpus: **566 111 field reads resolved** across the three arms, `field_read_by_name` down 561 272, executed by-name field reads down 23 105, static unresolved 9.09% -> 8.60%. `scripts/slot_audit_sweep.py` reports **0 divergences over 577 programs**. | done |
| `represent/field-slots` — how | The runtime already has the shape of the answer: `GetField.site_route` packs a plain stored index as `idx << 2 \| 1`, a custom getter as `FuncId << 2 \| 2`, and an outer hop as a class/slot/hop triple. Today the index is *discovered* by a name scan of the first live instance and re-proved on every serve by `site_shape` or `sameFieldName`. With a per-class layout it is a link-time fact, so the lowering-side field is a `(ClassId, slot)` pair and the runtime's claim block fills `site_route` from it instead of walking the ladder. The hot serve, `gfSiteFast`, does not change shape — it loses the shape compare. The two arms to feed first are `paths.tryOwnMemberRead` (18 201 sites) and `paths.tryBareThisRead` (3 804), whose receiver is the enclosing `this`; `member.lowerMember` (17 324) needs the receiver's static type and so follows `resolve/receiver-types`. | todo |
| `represent/missing-accessors` | Of the field reads `linkGetterRoutes` cannot bind on a compose program, **7 801 have zero candidates under either contract** as `funcsBySimpleName` sees it — and the accessor is nonetheless THERE. `__get_Offset_x` is in the pack image and in `module.funcs`; the module carries 2 440 `__get_` functions while `func_name_index` holds 4 759 entries of every kind and not one of them is an accessor. **Accessors are not name-indexed.**

Building the pass its own map from the function table lifts the bindings from 2 641 to 8 683 — and breaks 21 corpus programs. The target-identity audit stayed silent through it, because it only compared where the ladder ALSO chose a getter route; made to report every disagreement it finds 13 014, most of them `no-route` and so inconclusive. Narrowing to the `__get_` contract alone still breaks 18. So the accessor reachable through the name index and the accessor sitting in the function table are not interchangeable: `runFieldGetter` serves the first correctly and the second does not, which is a difference in provenance or ABI and is the thing to find. Reverted to the 2 641 that audit clean.

Two lessons worth keeping. An existence check with `KLIO_DUMP_FN` proves nothing — it prints when a function is ENTERED. And a target audit that only fires when both sides chose the same KIND of answer is the silent-join trap in a new place: `not-served` and `no-route` are unproven, never agreement. | todo |
| `represent/inline-ext-properties` | Measured negative, and it names the boundary of the naming-contract approach. `Int.dp` and its kind are the bulk of `name_absent`, and an extension property's accessor is supposed to be `__ext_get_<Head>_<prop>` — but `__ext_get_Int_dp`, `__ext_get_Number_dp` and `__ext_get_Double_dp` do not exist in the func table at all. These are INLINE extension properties, spliced rather than given an accessor, so there is no target to name. Three consecutive attempts in this bucket — the getter contract, the companion hop, and this — returned 2 641, 4 875 and 0, and the shape of that says the rest is not another contract: it is the per-class property table in `represent/property-slots`. | todo |
| `represent/companion-constants` | `Color.Unspecified` names the CLASSIFIER and reads a plain stored field of its companion SINGLETON, whose class is the companion's, so the read's recorded class is the outer one and no claim on it can succeed. The link pass hops: when the class has no slot of that name and does have a companion, it claims on the companion's layout, which is a class nothing subclasses and whose singleton is its only instance. 4 875 reads on a compose program — the largest single item in the `accessor_or_method` bucket by a wide margin, and not an accessor at all. Auditing it found a fault in the ORACLE rather than the claim: NaN never equals itself, so two reads of the same `Float.NaN` slot reported as a divergence with no difference in it. | done |
| `represent/open-class-slots` | An open class's declared slot sits at the same index in every subclass, so the index survives subclassing; what a subclass can change is whether the slot is the ANSWER. That question — does any subclass redeclare the property — took three attempts, and the first two were unsound in the same place. A scan over published LAYOUTS misses an accessor-only override, which contributes no slot. The `__get_<Class>_<prop>` contract misses one too: an `override var x get() = ... set(...) = ...` produces no function under it, which is why `TransparentObserverMutableSnapshot.invalid` slipped through both and the audit caught the claim serving a stale cell. The authoritative record is the AST's declared members, and `registry.subclass_declares_prop` is built there, beside the hierarchy shadow names. With it, plus the two conditions the earlier attempt established — constructor properties only, and the receiver proved to be ON the claimed chain — the audit reads zero divergences over both corpora. 230 reads on a compose program; the index is the reusable part, since `represent/property-slots` needs the same answer. **A fourth unsound case was still open and `declared_props` closed it.** The claim refused an inherited BODY slot, on the grounds that a class between can replace it with an accessor — but an inherited CONSTRUCTOR slot can be replaced the same way, and a FINAL subclass passed every remaining condition. `Counted : Tagged("counted")` overriding `Tagged`'s constructor `label` with `get() = "counted:$n"` read the constructor's value. The rule that covers both is Kotlin's own and needs no special case for either: the NEAREST class declaring the property decides whether a cell or a call answers, whichever class owns the cell. `examples/property_slot_per_class.kt` pins it. | done |
| `represent/anon-layouts` | Measured negative. `no_layout` is 5.73% of field reads on a compose program and every one is an object expression, each of which has exactly ONE shape, so a layout ought to describe it as well as any named class. Publishing them and running `KLIO_LAYOUT_AUDIT` says otherwise: 9 `misordered`, 6 `extra` and 4 `missing` across `$anon$0`, `$anon$1`, `$anon$2`, `$anon$3`, `$anon$38`, `$anon$46`, `$anon$55` — construction fills an object expression's fields in an order the declaration walk does not predict, which is precisely what the `anonymous` state documents. Reverted. Reaching these means teaching the walk the construction order object expressions actually use, not lifting the exclusion. | todo |
| `represent/property-slots` | A property read on an interface or abstract class cannot name a getter — the accessor is per-implementation — so it wants a SLOT, the same way a method call does. It cannot have one yet, and the reason is measured: asking `resolveMemberCall` for a property name on the receiver's class answers `deferred, target=false` at **19 541 of 22 063** reads a compose program lowers, and `virtual` at one. The resolver models METHODS; a property is a different namespace with no declaration to be a slot root, and an abstract property has no getter `FuncId` at all. So the work is to give every declared property an accessor declaration — abstract ones included — so its overrides form a slot family, and then a read on a typed receiver lowers to `CallVirtual` on that slot exactly as a call does. This is what `Composer.skipping` (504 reads) and `ProvidableCompositionLocal.current` (291) need, and `represent/getter-route` cannot reach them.  **Built, and the sizing above named the wrong obstacle.** The resolver was never the thing to ask: a property family cannot live in the METHOD table, because a slot there is rooted at the base declaration's `FuncId` and `overridesSlot` requires the two functions to carry the same name, while accessors are named `__get_<Class>_<prop>` and so never match across a chain. The family is keyed by the property NAME instead, which is Kotlin's own rule since properties do not overload: `linkPropertySlots` roots a slot at the topmost ancestor whose body declares the name, and every class in the family contributes one entry saying how IT answers — an accessor to run, or a composed-layout index to read. 4 347 families and 6 834 entries on a compose program. The declaration set has to be recorded where the class is LOWERED (`ir.Class.declared_props`, beside `enum_entry_names`) for the reason the layout publish already taught: an accessor-only property contributes no slot and an abstract one contributes no function, so neither proxy can reconstruct it afterwards. The read needs no proof about the chain, unlike the getter route — the table is keyed by the class that actually answers, reached through `ClassDef`'s own `resolve_cid` memo, the same one virtual dispatch uses. 2 981 sites bound, more than the getter route's 1 966; `KLIO_PROP_SLOT_SERVE=audit` runs the table's answer beside the walk and reports zero. **Three defects got past the example corpus and the stdlib sweep, and the full gate caught all three** — each one a place where the answer is not where the layout says it is. `itest-e2e` found two: a host-backed `Log : ArrayList<String>()` read `size` as the seed 0, because an intrinsic-backed class keeps its state in the host object, and a `by`-delegating class forwards the member to a different object entirely; both classes are excluded now. `itest-ktor_server` found the third, and it was the subtle one: `TextContent(..., override val status: HttpStatusCode? = null)` overrides `OutgoingContent`'s `get() = null` from the PRIMARY CONSTRUCTOR, and `ast.Class.members` does not hold those — they are in `primary_params` with `property != null`. Reading members alone made the override invisible, the walk reached the base accessor, and every created resource replied 200 instead of 201. A layout index also has to prove the cell at it carries the property's name, the way `serveClaimedSlot` does: the composed order and the instance's order can disagree, which is what the layout audit's `misordered` counts. The tables ride in the baked image beside `method_dispatch`, because slot numbering is assignment order and a baked read's slot has to keep meaning the property it was bound to. `field_read_by_name` 2 845 760 -> 2 535 880 and static unresolved 7.11% -> 6.84%. | done |
| `represent/vtables` | Virtual member calls become a class-relative slot index into a per-class method table, built at link time. `call_virtual_slot` becomes the only virtual path; `irMethodWalk` and the name-keyed method cache go. **Most of this already exists**: `linkMethodSlots` builds `Module.method_dispatch` as a `(ClassId, slot) -> FuncId` table at link time, incrementally over a baked base, and `CallVirtual` already carries the slot. What remains is the residue — `irMethodWalk` is the fallback for a host-backed receiver, memoized per site in `CallVirtualInst.site_native` — and driving it to zero. Its incremental-link argument ("nothing a program declares can change what a base class dispatches to") is exactly the one the field-slot link needs, and should be copied rather than re-derived. | todo |
| `represent/intrinsic-bit` | `ir.Class.is_intrinsic_backed`, written once at link time, replaces the linear scan over a thirty-entry FQN table that every construction ran before doing anything else. It does not make `call_new_instance` resolved — the constructor overload is still chosen from argument values — but it is one fewer name-keyed probe on the construction path, for every program. | done |
| `represent/delete-name-tables` | With the above at zero usage, delete the runtime name-keyed registry probes on the dispatch paths: `recv_fn_props`, `iface_member_ext_recv`, `ext_prop_type_heads` and the rest, per constraint 4 (census-proven unreachable, not inspected). This is where the 15.6% goes. | todo |
| `represent/static-receivers` | Receivers resolve lexically at lowering; the dynamic enclosing-`this` chain (`pushEnclosingAccess`/`popEnclosing`, `EnclosingChainIter`, the chain-shape hash) is deleted. Note this is also what currently couples field reads to a push/pop pair. **This is the largest executed unresolved class**: `load_this_or_global` runs 2 051 184 times over the corpus, ahead of `call_member_virtual`'s 1 166 745, and `call_member_or_global`'s 306 468 executions are matched almost one to one by `[ext-fb] total`'s 307 833 extension-fallback walks. | todo |

**What `represent/static-receivers` needs, from reading the code.** Lowering
already computes the tower: `collectReceiverTowerLabeled`
(`build.zig`) returns `{head, label}` innermost-first, and
`memberExtensionScopeTier` ranks a member extension by its *index* in that
tower — so lowering knows which entry supplies a receiver and only fails to
name a register for it. `resolveThisRegKind` (`expr/receiver.zig`) answers for
the innermost entry: a bound local `this`, else a hoisted capture. Every outer
entry needs the same answer, which is a register per labelled entry and a
binding for the unlabelled ones (a lambda subject, a splice receiver, an
anonymous-object receiver).

The registers largely exist already. `FuncBuilder.subject_binds` is an ordered
list of `{reg, head, prior_this}` — every spliced-subject `this` bind, innermost
last, each *with its register*, and each recording the register `this` held
before it shadowed. Walking it backwards yields the receiver registers
innermost-first, and the outermost entry's `prior_this` is the enclosing `this`.
Nothing assembles that into a list; the instructions carry at most one register
(`CallMemberOrGlobalInst.recv`), which is precisely why the splice arms null it
out rather than pin the wrong one.

So the shape of the change is: `CallMemberOrGlobal` and `LoadFromThisOrGlobal`
carry an ordered `[]Reg` receiver tower instead of a single optional register,
and the runtime walks the lowered registers innermost-first instead of the
dynamic chain. At that point the chain push/pop pair is no longer part of
dispatch and `enclosingChainClassHash` has no caller.

Three call sites give up for exactly that reason, and all three close together:
`lowerMemberExtensionDispatchReceiver` abandons an otherwise-resolved member
extension when no register is reachable; `bare_call.tryOuterReceiverExtension`
already proves the pattern works but requires a resolvable `this@<label>`;
and `call_general.emitSpliceReceiverWalk` / `emitSpliceUnknownReceiver`
deliberately null out both the receiver register and the static head whenever a
tower is active, because pinning ONE register would inverts Kotlin's
innermost-first order. The fix is therefore to emit the whole ordered tower,
not one register — after which `QualifiedThis` becomes a register copy rather
than a runtime chain search, `enclosingChainClassHash` loses its only caller,
and the chain-keyed half of the extension memo goes with it.


**Exit:** no name-keyed lookup remains on any hot dispatch path; a field read is
a shape check plus an index; a virtual call is a shape check plus a table index.
Gate green, suite counts unchanged.

## One engine

Five execution tiers exist because the base path is slow. Once it is not, they
are cost without benefit: every activation pays to decide which applies, and
per-`Func` verdict bytes exist to memoize those decisions.

The tiers, as they stand: the leaf serve (`eval/leaf.zig`), the fused walker
(`eval/fused.zig`), the bytecode stream (`bc.zig` encoded, run in
`eval/exec.zig`), the framed walker (`eval/inst.zig`), and the loop JIT
(`jit_loop/`, off in the default `safe` profile). The verdict bytes on `Func`
are `flat_class`, `acc_state`, `leaf_state`, `fuse_state`, `triv_init_state`,
`host_route`, `compose_route`, `throw_route`, `frame_fill_state`,
`bc_memo_fuse`, `bc_memo_gen` and `leaf_hopeless` — twelve, not seven, and
each one is a memo for a question a resolved IR would not ask.

| Id | Item | Status |
|----|------|--------|
| `engine/merge-frameless` | Merge the leaf serve and the fused walker. They are both frameless walkers over the same IR with separate gates, separate memos and separate decline paths. | todo |
| `engine/member-calls-frameless` | The frameless tier serves member calls. This is the keystone recorded in `plans/pack-suites-to-green.md`: `CallMember` is the largest single decline, and a declining body also blocks every caller that would fuse transitively. Resolution makes the arm tractable, since the site now carries a target. The risk to manage is `error.Materialize` mid-run, which pays the tier entry *and* the frame; the arm must be complete enough that it stays rare. | todo |
| `engine/full-bytecode` | Extend the bytecode encoding to the whole instruction set, which resolution has made much simpler, and make it the representation the engine executes. The `escape` arm and the `execInst` union switch go once the census shows nothing escapes. | todo |
| `engine/retire-tiers` | Retire what is then redundant, including the verdict bytes and their classification passes. Keep exactly one engine and, separately, the JIT seam. | todo |

**Exit:** one interpreter loop over one representation. No per-activation tier
decision, no verdict memo. Gate green.

## The stack

The deepest change, and much easier once frames no longer carry resolution
state.

| Id | Item | Status |
|----|------|--------|
| `stack/value-stack` | One contiguous per-thread value stack. A frame is a base offset plus a small fixed header; a call bumps the pointer, a return restores it. | todo |
| `stack/args-in-place` | Arguments are passed by leaving them where the caller computed them: the callee's window starts at the caller's argument run. The carrier list, `acquireArgsCap`, `readArgList` and the argument size-class pool are deleted. | todo |
| `stack/gc-roots` | The collector scans the value stack directly. The per-activation keepalive list (`KeepEntry`, `pushSlice`/`restore`) and the per-block safepoint bookkeeping go with it. | todo |
| `stack/frame-shrink` | What remains of `Frame` becomes a header: no `ArrayList` for registers, params or captures, no register pool. | todo |

**What `Frame` holds today**, so the shrink has a target. Three `ArrayList`s
(`regs`, `params`, `captures`) plus a fourth for the enclosing-`this` chain;
a `RegMask` saying which register slots are live for the collector; the two
fields that restore the caller's chain on exit (`prev_chain`,
`prev_chain_base`); `module_arc`, `owns_params_caps`, `gc_link`, `closure_id`;
two out-of-band control-flow payloads (`step_err`, `flat_call`); a
`pending_finally` state; the resolved per-thread `EvalTls` pointer; and
`cur_span`.

Of those, the earlier sections remove four outright: `enclosing_this`,
`prev_chain` and `prev_chain_base` go with `represent/static-receivers`, and
`wmask` exists because registers are an `ArrayList` the collector must be told
about rather than a window into a scanned stack. `params` and `captures`
become the caller's argument run under `stack/args-in-place`. What is left is
genuinely a header.

**Exit:** no allocation on the call path; GC rooting is a stack scan; the
cheapest activation is measured and recorded here.

## The long tail

Correctness work that is either blocked on the above or independent of it.
Nothing ships as "remaining" at the end.

| Id | Item | Status |
|----|------|--------|
| `tail/derivedstateleak` | `CompositionTests.derivedStateOfLeak` — needs the throughput the sections above are for. | todo |
| `tail/snapshot-map-race` | `SnapshotStateMapTests.concurrentMixingWriteApply_set`. | todo |
| `tail/coroutines-timeout` | `TimeoutTest.testSharedFlowCancelledNoTimeout` fails deterministically (`call_value on kotlin.Nothing`); the trace stops at `withDelaySkipping`'s `get(ContinuationInterceptor)` on a `RunningInRunTest` context. | todo |
| `tail/gate-unit-flake` | The gate's `zig build test` step fails intermittently — 3 of 6 runs on 2026-09-19, then once in four runs while the ratchet landed — with no test-failure line: the last thing on stderr is `Value size=16 align=8` and then `failed command`. That print is *complete* (the `value layout census` test prints nothing more, no `Value` field exceeding 8 bytes), so it is not a truncated write: the abort is in a later test of the same binary, and the runner's `--listen` channel carries no name for it. Reproduce with the binary run standalone so the per-test names print, then fix the cause. | todo |
| `tail/leaf-strikes` | The leaf abandon-strike change measured -1.6% and destabilised shard 1. Suspected a per-thread run-scoped guard not retired at a run boundary, the same family as the composer-stack bug fixed in `45b6dd38`. Find it; it is currently absorbing perf work that is otherwise correct. | todo |
| `tail/ctor-invoke-arity` | **Confirmed.** A capitalised callee that names a class is treated as that class's constructor even when the class cannot be constructed with that many arguments. `class Shape { fun kind() = "shape"; companion object { operator fun invoke(n: Int) = Circle(n) } }` then `Shape(3).kind()` prints `shape`; kotlinc prints `circle3`, because `Shape` has no one-argument constructor and `Shape(3)` is `Shape.Companion.invoke(3)`. The property-head half of this is fixed — a head is refused when the primary constructor cannot take the call and a same-named top-level function can — and the call-site half, in `call_general.tryIndexedConstructor`, needs the same arity test against the companion's `invoke`. Declining is not enough on its own: no later rung picks the companion up — `HasCompanion.Companion(5)` and a bare `object` with an `invoke` both work, so the route exists and the bare `C(args)` form has to be pointed at it. | doing |
| `tail/cgen-missing-super-prefix` | The published layout was cross-checked against `src/cli/cgen/layout.zig`'s independent one over 243 379 class layouts. The disagreements are slot kinds cgen does not model — the shadow-mangled storage key, `by`-delegation and builtin-collection delegate fields — except one that is a real emitter bug: cgen lays `kotlinx.coroutines.AbstractCoroutine` out as `[context]` where instances hold `[_state, _parentHandle, context]`, a superclass prefix its `ir.Class.supertypes` scan does not find. The walk and construction both agree with the published order, so the table is right and cgen is wrong. Reproduce with `KLIO_CGEN_LAYOUT_CHECK`. | todo |
| `tail/ext-walk-serves-wrong-receiver` | The extension audit surfaced what looks like a runtime dispatch bug rather than a lowering one. For the key `isNullOrEmpty` on a `List` (and on a `Map`), the by-name walk serves `androidx.compose.foundation.style.isNullOrEmpty`, whose declared receiver is `StyleAnimations?` — and `StyleAnimations` is a plain `internal class`, not a collection. Either the walk is binding an extension whose receiver does not accept the value, or the `static_recv` hint reaching it is wrong; both are bugs, and the second would also mislead every other consumer of that hint. Reproduce with `KLIO_EXT_AUDIT=1` over the compose examples and `KLIO_MISS_TRACE=isNullOrEmpty`. | todo |
| `tail/operator-modifier` | **Confirmed.** The IR does not record the `operator` modifier (`ast.Function.is_operator` exists; `ir.Func` and `decl_sigs` have no counterpart), so a non-`operator` member serves a convention call that Kotlin says it cannot. `class Plain { fun get(i: Int) = "member" }` plus `operator fun Plain.get(i: Int) = "ext"`, then `Plain()[1]`, prints `member`; kotlinc takes the extension, since the member is not an operator. Fixing it means carrying the modifier into the IR and gating every convention site — `get`, `set`, `invoke`, `componentN`, `iterator`, the `plusAssign` family, `contains`, `rangeTo` — on it. | todo |
| `tail/override-getter-type` | An `override val` with an expression-body getter and no declared type infers the override's own type rather than the base property's. Reported by review, not yet confirmed against kotlinc. | todo |
| `tail/rex-trace-consultations` | `KLIO_REX_TRACE=1` does not change lowering outcomes — `[lower-sites] total` and `[fallback]` are identical with and without it — but it does change how many times the extension resolver is consulted (`[no-ext] total` 31 819 against 45 806), so counts taken under it are not comparable to counts taken without. It also reads through `envSetOnce`, so `=0` enables it rather than disabling it, against the convention every documented knob follows. | todo |
| `tail/ext-index-race` | The extension index is rebuilt lazily during lowering (`rebuildExtIndex ... catch return .index_stale`) while lowering runs on the worker pool, so in principle which candidates a site sees depends on how much of the index exists when a worker reaches it. Not observable today: three cold runs and a one-worker run give a byte-identical `[lower-sites]` census. Close the mechanism anyway, or prove it cannot fire. | todo |
| `tail/classifier-scope` | `classIdInFileScope` in the inferred-head pass is a second, divergent copy of classifier resolution: named import, own package, unique module-wide, skipping the wildcard and default-import tiers `Module.scopeTier` already models. Fold it into the shared one. | todo |
| `tail/docs` | `docs/development/debugging.md`, the architecture docs and `README.md` re-based on the engine that exists at the end. Every knob listed still works. | todo |
| `tail/rebaseline` | Re-measure and rewrite the performance numbers in `plans/pack-suites-to-green.md` and in this document against the finished engine. | todo |

---

## Done means

All of the following hold simultaneously, verified in one sitting:

1. Every item above is `done`.
2. `scripts/gate.sh` green, run with nothing else touching `.zig-cache`.
3. `KLIO_REQUIRE_RESOLVED=1` passes the full corpus.
4. Every suite count in `plans/pack-suites-to-green.md` is at or above its
   recorded floor, and the compose runtime suite is at 100%.
5. The site and dispatch censuses print zero for every non-`dynamic_by_design`
   class, and that class is a named, justified list.
6. The running log below carries a measured before/after for the two headline
   numbers: cost of a trivial instruction, and cost of the cheapest activation.
7. `Inst` declares no unresolved variant. `CallMemberOrGlobal`,
   `CallValueOrMember`, `CallMemberOrValue`, `CallSuper`,
   `LoadFromThisOrGlobal`, `StoreToThisOrGlobal`, `EnclosingPush` and
   `EnclosingPop` are gone from the union, from the 23 lowering producers,
   and from every consumer arm in the census, the disassembler, the
   evaluator and cgen. Renaming them out of `Inst` compiles.
8. No pass re-derives at link time what an emitter could have known. The
   passes that exist to compensate for emitting blind —
   `linkReceiverClasses`, `linkGetterRoutes`, `linkBuiltinFields`,
   `linkCtorPicks` — are gone with the variants they were compensating for,
   or each survivor is named and justified the way `dynamic_by_design` is.

## Running log

Newest last. One line per landed item: what moved, the census delta, the
measured effect, and the gate result.

### Baseline

`KLIO_HOME=$PWD/.klio-local scripts/site-census-sweep.py`, 575 corpus programs,
all exiting 0, on the ReleaseSafe harness.

Static sites, summed over the program set (the whole lowered module per
program, deferred bodies materialised):

| Verdict | Sites | Share |
|---------|------:|------:|
| resolved | 103 858 777 | 89.39% |
| unresolved | 10 922 751 | 9.40% |
| `dynamic_by_design` | 1 401 088 | 1.21% |

The unresolved column, by kind:

| Kind | Sites |
|------|------:|
| `field_read_by_name` | 4 606 056 |
| `call_member_by_name` | 2 384 738 |
| `call_new_instance` | 1 385 738 |
| `call_member_or_global` | 626 348 |
| `name_ast_lambda` | 337 652 |
| `name_read_this_or_global` | 276 316 |
| `field_write_by_name` | 255 273 |
| `name_read_global_by_name` | 226 011 |
| `type_instanceof_by_name` | 168 497 |
| `recv_enclosing_push` / `recv_enclosing_pop` | 166 756 each |
| `type_cast_by_name` | 109 413 |
| `call_value_or_member` | 75 312 |
| `name_write_this_or_global` | 38 509 |
| `name_build_object` | 29 195 |
| `recv_qualified_this` | 22 087 |
| `name_write_global_by_name` | 13 608 |
| `name_member_ref_by_name` | 12 501 |
| `call_super_by_name` | 10 367 |
| `call_member_or_value` | 8 495 |
| `field_rmw_by_name` | 1 309 |
| `call_spread_bare_name` | 770 |
| `type_ctx_load_by_name` | 629 |
| `call_spread_member_name` | 377 |
| `name_register_class` | 34 |

Executed dispatches over the same sweep, by verdict: **52.33% resolved, 44.71%
unresolved, 2.96% dynamic** of 9 979 833 decided dispatches. The largest
unresolved executions are `load_this_or_global` 2 051 577, `call_member_virtual`
1 175 692, `field_read_host_by_name` 891 833, `call_member_or_global` 307 949,
with `ext_fb_total` 307 833 extension-fallback walks alongside. Against them,
`call_member_resolved` runs **6 328** times: 0.54% of member calls arrive
knowing what they call, which is the plan's opening evidence measured over the
whole corpus rather than one workload.

`KLIO_REQUIRE_RESOLVED=1`: **31 of 575 programs pass**, 544 resolve something by
name. That count is the headline number for the Resolution section, and it must
reach 575.

Instruments landed with it: `KLIO_SITE_CENSUS`, `KLIO_REQUIRE_RESOLVED`,
`KLIO_UNRESOLVED_SITES`, the `[dispatch-verdict]` split, and
`scripts/site-census-sweep.py`. Two tests keep them honest —
`site_census.zig`'s "every unresolved site kind is reported to the ratchet",
which fails if a new kind is added without a runtime gate, and `diag.zig`'s
"every dispatch kind that the ratchet hooks is an unresolved verdict".

### Landed

- **The census was measuring a fraction of the program.** Its counters were
  `threadlocal` while lowering runs on the worker pool (30 sites reported
  against 3 949 with one worker), it was dumped only after `run` and `test`
  while nearly every library site is lowered by `bake-image`, and the member
  gate had six exits that recorded nothing. All three fixed; the gate is
  consulted 33 660 times on a compose program, not 21 414.

- **`KLIO_EMIT_CENSUS`** keys every unresolved emission by the return address
  of `FuncBuilder.push`, so the arm responsible is named without any call-site
  upkeep. This is what showed that field reads are 45% of the population and
  that the by-name member calls outnumber the gate's recorded declines
  four to one.

- **A property initialised from a class the same build declares now has a
  type.** The head pass ran before a single class shell was reserved. A second
  pass fills the gaps after the class shells and file import scopes exist.
  Corpus: 14 594 by-name member calls became static calls, executed by-name
  member dispatch fell 9 071.

- **The operators Kotlin already decided are bound**: indexing through the
  member gate when the operator is an interpreted member, the iterator
  protocol against the iterator's own type rather than a `kotlin.collections`
  whitelist, and a destructuring `componentN` through the resolution that
  already named its target. Corpus: 271 122 by-name member calls became static
  calls and 9 147 became virtual slots.

- **An adversarial review caught the inferred-head pass writing a nested
  class's rows under a top-level namesake's keys**, and three latent hazards:
  a span-keyed side channel fed the receiver's span, an admission check read a
  declaration list's head instead of asking the resolver, and the iterator
  binding stamped the `Iterator` interface's slots on types that do not
  implement it. Fixed, with `examples/inferred_property_head_scope.kt` as the
  regression.

Static unresolved sites over the corpus: **9.40% -> 9.09%**, with the two
largest classes (field reads, extension-shaped member calls) untouched so far.
576 programs exit 0 after every step; the stdlib commontest sweep is 149 files,
0 failures.

- **The member gate's declines are all counted now**, and the census named a
  different leader than the plan had: the receiver's class declaring no such
  member at all, 29.90%, which is Kotlin asking for an extension. Two more
  counters follow it through: `[fallback]` says the member-call fallback binds
  exactly half of what reaches it (5 471 extension binds, 5 487 by-name), and
  `[no-ext]` says why the resolver withholds — 91.34% because no extension of
  that name exists at all, leaving `unknown_args_singleton` 2 156,
  `unknown_args` 325 and `tied` 259 as the whole actionable remainder.

- **A measured negative.** Committing the lone ranked extension candidate when
  an argument's type is unknown moved 366 sites to a static target and broke
  `DurationTest.constructionFromNumber`, `DurationTest.truncation` and
  `examples/builder_lambda_outer_receiver.kt`. A lone candidate in the RANKED
  set is not a lone applicable declaration. Reverted; the dual-compute audit
  that should have preceded it is the next step for that item.

- **Two measurement traps closed.** `KLIO_REX_TRACE` leaves lowering identical
  and inflates the resolver's consultation count, so counts taken under it are
  not comparable to counts taken without. And an executed total summed over
  the corpus is a handful of micro-benchmarks — `load_this_or_global` is 97.6%
  one program — so the sweep prints the top contributor and its share beside
  every one.

- **The class layout is measured against the layout construction produces.**
  `class_layout.zig` predicts it, `KLIO_LAYOUT_AUDIT=1` compares, and
  `scripts/layout_audit_sweep.py` sweeps: 379 classes divergent, 9 200
  `misordered`, 2 420 `extra`, 572 `no-layout:anonymous`, 46 `missing`. The
  misordering is one structural fact — construction groups fields by kind
  across the whole inheritance chain where a layout must group them by the
  class that declares them, which is the only arrangement that makes a base
  index valid in a subclass.

- **The class layout is fixed, then published.** Construction reserves every
  slot the class declares before filling any of them, so a base class's index
  means the same thing in a subclass: the audit went from 379 divergent
  classes (9 200 misordered, 2 420 extra, 46 missing) to none but the 572
  anonymous objects, which have no static layout by nature. Then `ir.Class`
  and `Module.field_layout` carry the table so lowering can see it, linked
  incrementally over a baked base and serialized with the image.

  Two oracles, because one table agreeing with itself proves nothing: the
  published table against the `ClassDef` walk it replaces (10 291
  comparisons, 0 divergent) and against the native emitter's independently
  written layout (243 379 comparisons, every disagreement a slot kind cgen
  does not model — plus one genuine cgen bug, a missing superclass prefix on
  `AbstractCoroutine`, recorded in the long tail).

  The incrementality argument needed checking rather than copying: a
  program's classes are *not* strictly append-only, because `addClass` claims
  an existing slot on an exact FQN match and overwrites the class. That is
  detected before publishing erases the evidence, and falls back to a full
  relink; across the corpus the incremental path runs 551 times, the full
  path 71 (base builds), and the staleness fallback never fires.

  `scripts/gate.sh --no-sweep` is green at this point.

- **A field read on `this` is a slot index.** The published layout reaches
  lowering only if the table exists when the read is emitted, so the runtime
  class defs, the supertype link and the layout publish moved ahead of body
  lowering; a first attempt without that claimed zero sites. `GetField` then
  carries the class and the declared slot, and the runtime serves it.

  Four soundness conditions, every one of them found by the dual compute
  rather than predicted: plainness (a getter's backing slot is not the read),
  a final owner (an open one can be overridden with an accessor), the
  scope-qualified spelling naming the lexical owner (it can name an outer
  class, whose read is a hop off another instance), and exactly one cell for
  the property (a shadow or an override cell gives it several, and the read
  takes the nearest owner's). Three of the four were found *after* six
  programs broke, by running the claim beside the ladder instead of guessing
  which check was missing.

  Widening the claim to the bare-`this` read and to `recv.x` on a typed
  receiver found a sixth condition and made the number smaller: only a
  constructor property may be claimed, because a body property's slot holds
  its seed until its initializer runs and the ladder answers an early read by
  running it. The first landing had over-claimed; the corpus simply had not
  exercised it through that one arm.

  566 111 sites resolved across three arms, `field_read_by_name` down
  561 272, executed by-name field reads down 23 105, corpus unresolved
  9.09% -> 8.60%. 577 programs exit 0, commontest 149 files 0 failures, the
  layout audit unchanged, the construction baseline byte-identical, and
  `scripts/slot_audit_sweep.py` reports 0 divergences.

- **The two headline numbers are measured.** A trivial register-to-register
  integer instruction costs **2.10 ns** and the cheapest activation **46-51
  ns**, by difference between paired loops, stable across runs.

  Both are already inside the band the plan set as the target, which is a
  finding about the tiers rather than a result: the benchmark's loop never
  reaches the framed walker, so these are the fastest tier's numbers and the
  plan's earlier ~12-25 ns and 117 ns are not reproducible by this method.
  They are the floor `engine/retire-tiers` has to match with one engine.

- **`scripts/gate.sh` green, run alone**, at this point: 10m43s, unit, the
  litmus/ktor/e2e suites, every shipped pack reinstalled from the tree, the
  compose-ui family 5/5, the corpus 577/577, and the commontest dual gate 149
  files 0 failures twice with identical runs. That is one of the six "Done
  means" conditions met; it will need re-running at the end, but nothing
  landed so far has cost it.

### The extension criterion, measured per site

`CallMemberExtra.audit_pick` carries the pick the resolver withheld; the
member-call arm publishes it and every route that produces a target compares.
One row per executed site, carrying the enclosing function. Three findings the
aggregated (name, receiver head) join could not reach:

- The criterion was missing a condition the resolver already computed. The
  winner's declared receiver must RELATE to the static one. Without it,
  `kotlin.invoke` — which is `DeepRecursiveFunction<T, R>.invoke` — was the sole
  best-tier candidate for 3 402 ordinary closure invokes.
- The runtime had a bug the join blamed on lowering. Every nullable-receiver
  candidate proves equally against a null receiver, and the lenient walk read
  that as proof, so `isNullOrEmpty()` on a null `List` ran
  `androidx.compose.foundation.style.isNullOrEmpty`. The declared head is the
  only evidence a null value leaves.
- The instrument was comparing names. `kotlin.time.toDuration` is three
  declarations under one fqn: 11 587 silent agreements became 3 644
  divergences. Under them were two klio/kotlinc divergences, both fixed — an
  integer literal scoring as evidence for a `Double` parameter, and the const
  type deriver unable to read `Long.MAX_VALUE`.

And one about method, which cost two wrong conclusions: **the examples corpus
is not the audit population.** It reported zero divergences under a criterion
that broke two stdlib tests. `commontest-sweep.py` now echoes matching child
stderr under `KLIO_SWEEP_GREP`.

Landed with the criterion on: the pick names the declaration the runtime serves
at 11 587 of 11 587 executed sites over the examples and 690 644 of 690 668
over the stdlib tests, the 24 being `Array<T>.getOrNull` where the walk is
wrong and lowering is right. `[fallback] bound` on `compose_window.kt` goes
36.80% → 39.70%. Gate green.

### A class's own body property reads from its slot

The why-no-slot census made the next move obvious: 34.29% of field reads on a
compose program failed on `body_property` alone, against 25.11% that claimed.
The dual-compute audit found exactly one divergence over 579 programs, and it
was not an initialization-order question — `Square` overrides `Shape`'s stored
`sides` with `get() = 4` and contributes no cell, so the INHERITED slot still
reads 0. With inherited body slots excluded the audit reads zero over both
corpora, and claimed field reads go 25.11% → 51.37%. Gate green, 580/580.

What is left, on the same program: `accessor_or_method` 20.44%,
`name_absent` 11.85%, `subclassable` 6.36%, `no_layout` 5.84%,
`body_property` 2.81% (inherited only), the rest 1.3%.

### A field write lands in the slot lowering named

`SetField` carried no claim, so every write went by name: 255 970 sites.
The read claim transfers with one addition, and that addition is the whole
content. `plain` — no getter, no delegate — settles a read, but a property can
read straight from its slot while its setter runs code, so the layout now
records `plain_write` beside it. The audit named the three shapes before
anything depended on them: `counter` in `examples/delegates.kt` wrote -7 where
the slot held 3, `viaLoop` wrote 3 where the slot held 6, and a compose
`density` setter with logic.

A write has no value to compare, so the dual compute compares the CELL: run
the ladder anyway, then check that the slot lowering named is the one it
changed. Zero divergences over both corpora. Writes claiming a slot go from 0
to 59.8%; static unresolved 7.91% → 7.77%.

### Measured negative: an open class's slot

A declared slot's index is the same in every subclass, so an open class's
`subclassable` refusal looks conservative — 6.36% of field reads. It is not,
and two sound conditions came out of trying, both from the audit:

- The receiver must be ON the claimed chain. A matching slot NAME at the
  claimed index is not proof: `snapshotId` was held at the claimed index by an
  unrelated class whose slot still had its seed.
- Only a CONSTRUCTOR property. A body property of an open base is written by
  that base's initializer, which runs partway through a subclass's
  construction, so a read through a subclass instance can land on the seed.

What is still open is the hole that stopped it: lowering must know whether any
subclass REDECLARES the property, and an accessor override contributes no slot,
so a scan over layouts cannot see it. The declaration-level source that could —
`instance_prop_getters` — is filled while class bodies lower, which is after
the layout publish the claim reads. Closing it means recording declared
property names, accessors included, in the same pass that publishes layouts.
Reverted rather than landed off by default; the conditions above are the part
worth keeping.

### An enum entry read carries its index

`name_absent` — 11.85% of field reads, the bucket the three-way split named —
is two things, and neither is a field. `Int.dp` and `Double.dp` are extension
properties. `Orientation.Vertical`, `LayoutDirection.Ltr`,
`ColorSchemeKeyTokens.OnSurface` are enum entries, which the runtime answered
by comparing the name against every entry of the enum on every read.

Where the entry names are recorded was the whole difficulty, and it took four
measurements to place. Beside the field layouts looked right: the layout
publish already moved ahead of body lowering for exactly this reason. It does
not work — a pass counter showed the publish running with `enums=0`, then 12,
then 12 again while `Dir.North` lowered, then 13. `is_enum` is set on the
`ir.Class` by a later pass than the one that could name the entries, so the
claim found `is_enum=true` and an empty table. They are recorded where the flag
is set, as the class is built.

Two emit sites reach an entry read: `lowerMember` for `recv.Entry`, and
`lowerDottedPath` for the ordinary `Dir.North`, where only the FIRST hop can be
a classifier. 3 587 sites on `compose_window.kt`; `field_read_by_name` there
falls 51 765 → 48 178, and static unresolved 7.77% → 7.71%.

Writing the example for it found a separate divergence: `import Dir.East as
Sunrise` lowered to a bare `LoadGlobal 'East'`, because the bare-alias arm
takes the import path's last segment. That is right for a top-level target and
wrong for a member of a class, which is not loadable by its bare name.

### Where the session left the numbers

Static unresolved 8.60% → 7.71% over the corpus. Field reads claiming a slot
25.11% → 51.37% on a compose program, field writes 0 → 59.8%, enum entries
3 587 sites resolved, extension dispatch bound 36.80% → 39.70%. The two
headline costs are unmoved at 2.10 ns and 46.3 ns, which is expected: nothing
here touches a register-to-register op or an activation.

### A property read names the property, and a defect found beside it

`field_read_by_name` 2 919 871 → 2 535 880 → 2 537 388 and static unresolved
7.17% → 6.84%, from the getter-route correction and the property table. The
executed `field_read_prop_slot` count rose 16 404 → 94 477 once the field-slot
claim stopped answering reads whose nearest declaration is an accessor.

**Found beside it, and open.** `tests/fixtures/threaded_litmus/
tl_cancel_via_coroutine_context.kt` prints `c1-cancelled` then `end` under
`klio run` with refreshed local packs — `outer2.coroutineContext[Job]!!
.cancel()` cancels nothing — 8 runs of 8, on a clean checkout of the commit
before this work. The same program passes under the itest harness, which runs
it against `KLIO_PARITY_BASE_IMAGES` rather than the installed packs, and that
suite also flaked once on this test in a gate that passed on re-run. Two entry
paths disagreeing about cancellation is a real defect; it is not a resolution
one, and it is recorded here rather than fixed in the middle of this campaign.

### The audits were reporting into a closed pipe

`scripts/corpus_check.py` ran every example with `capture_output=True` and
compared stdout. A dual-compute audit reports on STDERR. So every "audit clean
over the corpus" in this log above was measured through an instrument that
threw the answer away — the sweep had `KLIO_SWEEP_GREP` for this and it was
simply never used. `--grep-stderr` echoes matching lines now, and the two
sweeps were re-run with it.

What the working instrument found, immediately: the getter audit reports
`Nodes.OnPlaced`, `Nodes.OnRemeasured`, `Nodes.Semantics` and a dozen more as
divergences, `served=Instance walked=Instance`. They are not. Those accessors
BUILD their answer — `get() = NodeKind(...)` — so two calls differ by identity
while both are right, and the comparator asks whether two heap values are the
same cell, which is the correct question for a SLOT claim and the wrong one
for a getter. **The control is the ladder run twice**: where the ladder
disagrees with itself the read is not idempotent and the comparison says
nothing, so it is skipped rather than reported. With that control both sweeps
read clean, and this time the reading means something.

The lesson generalises past this campaign: a dual-compute audit needs its own
control, or it reports the difference between two correct answers.

### Being subclassable was never the reason to refuse a slot

`field_read_by_name` is the largest unresolved class in the census and the
`[no-slot]` breakdown says where it comes from. On a compose program, of
19 419 claim attempts: `claimed` 9 864, then **`subclassable` 2 394 (12.33%)**,
`accessor_or_method` 2 144, `body_property` 1 840, `recv_type_unknown` 1 044,
`no_layout` 744, `name_absent` 670.

`subclassable` was `if (oc.is_open or oc.is_abstract or oc.is_interface)
return refuse` — every open class, unconditionally. That is the wrong
question. The layout is base-prefixed by construction: `own[i]` sits at
`base + i`, and a claimed index is always inside the declared region, never
among the trailing captures, so a subclass instance holds this class's cell
at this class's index. Inheritance does not move it. What would break the
read is a subclass ANSWERING the name differently — an `override val` with
its own cell, or one replaced by an accessor — and that has a whole-program
answer the build already computes: `registry.subclass_declares_prop` records
every (ancestor, member) pair a subclass declares, over-reporting rather than
under, since a method of the same name counts too.

`subclassable` 2 394 -> 173 on that program, claims 50.80% -> 62.23% of
attempts. Over the corpus: **`field_read_by_name` 2 532 892 -> 2 360 215
(-172 677)**, `field_read_slot_claimed` +229 900, `field_write_by_name`
94 964 -> 72 996, `field_write_slot_claimed` +22 107, static unresolved
**6.586% -> 6.418%**. That is roughly seven times the movement of any other
single change in this run, from deleting a refusal rather than adding a
mechanism.

`KLIO_OPEN_SLOT=0` restores the blanket refusal, and `KLIO_SLOT_SERVE=audit`
reports zero disagreements over the corpus and the stdlib sweep. The audit
alone would not be evidence, because a guard that refuses everything also
diverges from nothing — so `examples/open_class_field_slot.kt` pins the four
shapes directly, and the claim census on it shows the guard doing work rather
than waving through: two reads claimed (`depth` on an open class, `sides` on
an abstract one) and two refused (`label`, which three subclasses answer three
different ways). Output is identical with the claim on and off.

### The inherited body slot was refused for a question already answered

With `subclassable` dissolved, the next reason was `body_property`, 1 820 of
19 419 claim attempts. A body property's slot holds its seed until the
initializer runs, which is why the class's OWN body slots claim only behind
`KLIO_SLOT_BODY`; an INHERITED one was refused outright, on the grounds that
a class between the declarer and the receiver can replace the property with
an accessor and contribute no cell. `Square` overriding `Shape`'s stored
`sides` with `get() = 4` reads the inherited 0 — the one divergence the
dual-compute audit found when body properties first claimed.

That is the question `nearestDeclaresGetter` answers, and it was already
running four lines later. It walks from THIS class up and stops at the first
declaration, so an intervening accessor refuses before the slot is reached;
a subclass that re-stores the property instead contributes a second cell,
which the cell count refuses. The refusal was ordered before the check that
made it unnecessary. Moving it after: `body_property` 1 820 -> 0, claims
62.23% -> 71.61% of attempts, and over the corpus `field_read_by_name`
2 360 215 -> 2 250 479, `field_write_by_name` 72 996 -> 51 947, static
unresolved **6.418% -> 6.308%**.

`examples/open_class_field_slot.kt` carries the `Square`/`Tri` pair that
named the hazard, so the case the comment described is now a program that
fails if the ordering goes back. `KLIO_INHERITED_BODY_SLOT=0` restores the
refusal; output is identical either way, and `KLIO_SLOT_SERVE=audit` reports
nothing over the corpus or the stdlib sweep.

**Two refusals, 0.30 points between them, and neither added a mechanism.**
The session's other five resolution changes moved 0.02-0.03 points each by
binding something new. These two deleted a guard that was asking a coarser
question than the data supports. That is the shape to look for in what is
left of `field_read_by_name`: `accessor_or_method` 2 144 is a getter route
rather than a slot, and `recv_type_unknown` 1 044 is the receiver-type
fixpoint, but `no_layout` 744 and `name_absent` 670 are both worth asking
whether the refusal is the real rule or the nearest cheap one.

### The widened overload guard had taken back what it should not have

Widening `scalarOverloadUnproven` to fix `atomic(Core<E>(...))` being typed
`AtomicInt` also withdrew `atomic(node)`. The rule it used — proven only when
the chosen overload's parameter IS the argument's type — reads a type
PARAMETER as a failure to match, and the generic `atomic(initial: T):
AtomicRef<T>` is exactly the overload every non-scalar argument should take.
So the atomicfu property typing landed a few commits earlier quietly stopped
answering: `_next` went back to `<instance>` and every `_next.value` in the
coroutine internals resolved by name again.

A type-parameter parameter accepts anything, so on its own it proves
nothing — but it is the right answer wherever no CONCRETE overload in the
family claims the argument's type. `Int`, `Long` and `Boolean` have their own
declarations of `atomic`; anything else is the generic one, provably.
`call_member_by_name` -4 408, `field_read_slot_claimed` +5 366, static
unresolved 6.308% -> 6.299%. `LockFreeTaskQueue._cur` still declines, because
`Core<E>(capacity, singleConsumer)` types as nothing at all and an
untypeable argument proves no overload — which is the case the widening was
for.

**Typing `this` in a synthesized accessor measures flat.** `__get_<Class>_<prop>`
runs with `this` of `<Class>` and the builder carried that as the receiver
type, but the bound parameter itself had no declared type, so a body written
`this.x` typed its receiver as nothing. Filling it in `bindParams` — one
place, so a fifth accessor entry cannot miss it — changes no number on a
compose program. The reads inside those bodies are not written `this.x`;
they are `_next.value`, a property of the owner read bare, which is the
implicit-receiver channel rather than this one. Kept because the fact is
true and was simply absent, not because it bought anything.

### Measured: an inline splice puts a receiver where nothing can see it

`call_member_or_global` is 648 328 sites and an XOrY instruction the goal
names for deletion, so the question is how much of the hedge is decidable.
The instruction exists because lowering could not prove the name is NOT a
member of some implicit receiver, and whole-program that looks answerable:
the receivers in scope are the function's own `this` and whatever an
`EnclosingPush` put there, and 3 856 of a compose program's 4 287 sites are
in a function that pushes none.

`KLIO_XORY_PROBE` prices it at 1 744 sites — until the probe is asked
whether an EXTENSION could serve the call, which Kotlin ranks above a
top-level function, and it drops to 1 624. Adding the two guards this
campaign has already learned to want — skip a synthesized name, and refuse
to answer "no supertype declares this" from an ancestor closure the module
never built, which is the bundle's `is` bug in another costume — leaves
1 179.

**`KLIO_XORY_AUDIT` refutes all of them.** It marks the site and reports
whenever a RECEIVER arm wins there anyway, and over the corpus it names 20
declarations: `arrayOf`, `arrayOfNulls`, `byteArrayOf`, `floatArrayOf`,
`emptyArray`, `invokeOnCompletion`, `newOverwritableRecordLocked`,
`iterator`, `produce`, `drop` and more. The cause is one thing and it is
structural: **an inline function's spliced body binds its receiver as an
ordinary register of the CALLER's frame.** `emptyArray<T>()` is called inside
`public actual inline fun <reified T> Array<out T>?.orEmpty()`, so when that
splices, the bare call sees an implicit receiver that is neither a `this`
parameter nor an `EnclosingPush` — and the premise "pushless means at most
one implicit receiver" is false for every function that splices one.

So `resolve/or-instructions` is not waiting on receiver types alone, which
is what its `blocked` row says today. It is waiting on splice receivers
being nameable at the site, which is the same thing
`represent/static-receivers` is for. The instrument lands — the probe, the
`global_only` bit and the audit — with NOTHING reading the bit but the
audit, so the claim is recorded and checkable rather than served.

Two instrument defects were found getting here, both of the kind this
campaign keeps meeting. The first arm test counted `overload` and
`global_id` as receiver wins when they are global-side picks among
same-named top-level declarations. The second was worse: `or_global_only` is
a threadlocal, resolutions nest, and a field read inside the call reported
its own arms against the outer site's flag — which invented two
`$sgetter$` divergences that were nothing to do with the claim. An audit
that is not itself audited is not evidence.

### A bare class name in value position is not a name at runtime

With the scope-qualified reads bound, the largest remaining by-name field
read was `kotlin.reflect.KClass.<class-companion-or-self>` — 436 executions
on a compose program across `ContinuationInterceptor.get`,
`Recomposer.deriveStateLocked`, `__get_JobSupport_key` and lambdas. It is
the sentinel lowering emits for a bare class name in value position: read
the class's companion if it has one, else the class itself.

The answer was already keyed by the class object rather than by any name —
`companion_read_state` is a per-class memo — so nothing was being re-derived
by name except the QUESTION. `execArmGetField` compared the field's string
against `"<class-companion-or-self>"` on every field read that reached it,
to find out whether this was that read. The spelling is fixed at lowering,
so `OwnKind.companion_or_self` carries it, bound in `FuncBuilder.push`
beside the builtin-member binding for the same reason: nothing that emits a
`GetField` can forget it.

`field_read_by_name` 2 138 600 -> 2 041 568 over the corpus, **-97 032**, all
of it into the new resolved kind, static unresolved **6.206% -> 6.124%**.

The time is flat, and the benchmark says why: a field-read loop over
slot-claiming reads is 2.42 s either way, because a claimed read never
reaches the compare. What the compare cost was paid only by reads already on
the by-name path — the ones this campaign is removing anyway.

### Measured: naming the operation is not resolving the site

`call_member_by_name` is the largest unresolved class by EXECUTIONS in the
require-resolved report — 56 690 over 120 programs — and grouping it by
receiver head says the top entries are `kotlin.FloatArray`, `kotlin.LongArray`,
`kotlin.String`, `kotlin.IntArray`, `kotlin.Array`, `kotlin.Int`. The receiver
type is fully known at those sites; the member is a builtin intrinsic with no
`FuncId` to name.

The subscript work had already put the OPERATION on the instruction, so the
obvious next step was to call such a site resolved wherever lowering also
proves the receiver KIND — a static head no interpreted instance can wear,
which makes the runtime's tag test an assertion rather than a derivation.
`linkBuiltinMembers` marks those: **3 820 of a compose program's 10 566
member-call sites**, out of 7 299 that name an operation and 4 587 that carry
a static receiver head at all.

**The claim was wrong, and `KLIO_BUILTIN_AUDIT` said so on the first corpus
run.** It reports every proven site that still reaches the by-name walk, and
`serial_name_needs_escaping.kt` produced a stream of them: `get op=get
recv=String in=printQuoted`. `fastIndexGet` serves a String only for an ASCII
in-bounds index, because the UTF-16 walk and the IndexOutOfBoundsException
are the native's contract — and arrays are the same shape, declining an
out-of-range or non-`Int` index. Every one of those declines falls through to
the walk. A site whose fast path can bail into by-name resolution is not
resolved, however much the site knows.

So the kind stays, hooked to the ratchet as UNRESOLVED, counted apart from
`call_member_by_name` rather than folded into it: 3 820 sites that name their
operation and their receiver kind and are still not resolved, because what is
missing is a resolved SLOW path. That is the intrinsic-id work — every host
intrinsic given a stable id the site can carry — not another field on the
instruction. The census now names the shape of that job instead of hiding it
inside a two-million-site bucket, and the audit that will prove it is already
written.

### The scope-qualified read carried its owner in its name all along

`$sgetter$<owner>\u{1f}<prop>` is how lowering spells a bare property read
inside a method, and the runtime decodes that string on every execution:
split it, resolve the owner, then dispatch virtually most-derived-first
because an `open val` a subclass overrides must answer from the subclass
even in a base-class method. It was one of the four universal
`KLIO_REQUIRE_RESOLVED` blockers.

The rule it implements is the property table's rule exactly, and the reason
`linkGetterRoutes` never bound one is that the pass begins
`const cid = gf.own_cls orelse continue` — these sites carry no receiver
class. They did not need one: the OWNER IS IN THE NAME. Decoding it at link
time instead of at every read gives `propSlotOf(owner, prop)`, and the
receiver's runtime class indexes the table, which is the same
most-derived-first answer. A foreign receiver has no entry for a slot rooted
in another family, so it falls back to the walk rather than answering wrongly.

966 sites bound on a compose program. Over the corpus **`field_read_by_name`
2 249 565 -> 2 138 600 (-110 965)**, all of it into `field_read_prop_slot`,
static unresolved **6.299% -> 6.206%**. `KLIO_SGETTER_SLOT=0` leaves them on
the runtime decode; `KLIO_PROP_SLOT_SERVE=audit` reports nothing over the
corpus or the stdlib sweep.

### `no_layout` was four problems under one name, and is one answer

The refusal census is only as useful as its granularity, and `no_layout` —
744 of 19 476 claim attempts, the fourth-largest reason — collapsed four
states that `classFieldLayoutState` already distinguishes: `interface` (no
storage, and never will have), `anonymous` (an object expression, whose
fields are built in another order), `local_runtime` (declared in a function
body, so its layout cannot be baked), `unavailable` (the build looked and
could not describe it) and `unpublished` (nothing has written one yet). The
last two are ordering questions and would have been the next thing to fix.

Split, the answer is unambiguous: **744 of 744 are `no_layout_interface`**.
An interface holds no storage, so a field slot is the wrong instrument for
every one of them — their answer is a property slot or a getter route, which
is `represent/property-slots` and `represent/vtables`, not this pass. Nothing
here is waiting on build ordering. The reason belongs on the justified list
rather than the work list, and the census now says so on its own.

### Where this run leaves the five conditions

Static unresolved over the 585-program corpus: **6.61% -> 6.299%** across
nine resolution changes. The distribution of where that came from is the
finding worth carrying forward — five changes that BOUND something new moved
0.02-0.03 points each, and two that DELETED a refusal asking a coarser
question than the data supports moved 0.17 and 0.11. The accumulation of new
bindings does not reach zero from here; re-reading the refusals does.

The two headline numbers, re-measured on this tree with
`scripts/headline-costs.sh` (ReleaseSafe harness, loop JIT off, three runs):

| | Campaign start | Now |
|---|---:|---:|
| Trivial register-to-register instruction | 2.10 ns | **2.13 ns** |
| Cheapest activation | 46.3 ns | **47.10-54.85 ns** |

Unmoved, and that is the expected reading rather than a disappointment:
nothing in this run touches the instruction dispatch loop or the activation
path. Resolution removes per-SITE name work; these two numbers are per-op
and per-CALL costs that only `engine/*` and `stack/*` can move. Two hot-path
wins were measured and are real but sit in neither: the subscript operation
binding, 6.1% on a subscript loop, and the constructor probe guard, 2.1% on
a construction loop — both on the interpreted base path, both invisible with
the JIT on.

Against the five conditions: `scripts/gate.sh` is green run alone and every
suite is at or above its floor with compose at 100%. The other four are
open. `KLIO_REQUIRE_RESOLVED=1` passes 49 of 584. The censuses report 6.299%
unresolved, not zero. `One engine` and `The stack` are untouched, and the
plan's own ordering says they cannot start until the base path carries no
resolution state — which is what the remaining `represent/*` items are for.

### A construction asked the FQN-keyed table whether it had a secondary

`classHasSecondaryCtors` was introduced to keep the secondary-constructor
side table off the construction path — "a link-time bit on the class, not a
name-table scan per construction" — and it guarded one of the three places
that ask. `newInstance` has two more: `zero_primary_secondary`, and
`same_arity_secondary_better`, which runs on every construction whose
argument count matches the primary's, the common case. Both called
`secondaryCtors(self, fqn, name)`, an FQN-keyed hash probe, for classes that
have no secondary constructor at all and therefore cannot be answered by
either ranking.

Hoisting the bit once and gating all three: **12.68 s -> 12.42 s, 2.1%** on a
1.5M-construction loop, three alternating runs with no overlap, isolated by
stashing this file alone so the field-slot work in the same session could
not be credited to it. The census does not move — this is a probe on the
dispatch path rather than a site that names a target — which is the point:
`call_new_instance` is the third-largest unresolved class and this removes
work from it without yet resolving it.

### The subscript is the first site whose target was a string at runtime

`member_fast_subscript` is the 9th-largest executed dispatch in the census —
939 154 over the corpus — and every one of them interned the site's name
constant and compared it against `"get"` and then `"set"`. The operation is
decided by the name and the argument count, both of which lowering holds, so
the string comparison was re-deriving a fact that could not change.

`Inst.BuiltinMember` names it on the instruction. It is bound in
`FuncBuilder.push` rather than at the 29 places a `CallMember` is emitted,
because an emitter that forgot it would silently put its sites back on the
string compare and nothing would fail. The `u8` costs nothing: it lands in
padding the instruction already had, and the 64-byte union test passes
unchanged.

**Measured, alternating binaries, CPU time on a 12.8M-iteration
`FloatArray` subscript loop: 7.52 s -> 7.06 s, 6.1%, three runs each with no
overlap.** With the JIT on the two are identical to the hundredth of a
second, because the compiled loop never reaches `fastSubscript` — the win is
on the interpreted base path, which is the path `engine/retire-tiers` has to
make fast enough that the tiers above it are not needed.

`KLIO_SUBSCRIPT_AUDIT=1` compares the site's operation against the name at
every execution and reports zero over the corpus and the stdlib sweep. The
failure it is built for is not a wrong answer — a site whose name constant
was not yet a string when it was pushed binds `.none` and quietly falls back
— so the audit reports a lost fast path, not a wrong one.

**The same treatment of `primitiveMemberOp` measures flat, and the reason is
worth keeping.** That function is a ladder of eleven name comparisons
(`compareTo`, `isEmpty`, `toInt`, `toLong`, `inv`, `shl`, `shr`, `ushr`,
`and`, `or`, `xor`) reached on the same path, so the enum should have paid
the same way. It does not: two benchmarks, a bit-operation loop and a
member-call loop, are identical to within noise across three alternating
runs. The ladder's FIRST line already decided the common case on the
receiver's tag — `if (recv_in.* == .Instance) return null` — so the
comparisons only ever ran for a non-instance receiver that was not one of
these operations, which is rare. The change is kept because it removes a
by-name derivation and cannot cost anything (the site's `.none` now returns
before the receiver is even read), but it buys no time and is not counted as
if it did. The subscript was worth doing because `fastSubscript` interned and
compared the name BEFORE it could decide anything; a ladder that checks the
cheap discriminator first was already paying almost nothing.

### Measured: what `KLIO_REQUIRE_RESOLVED` actually stops on

49 of 584 programs pass the mode, and the per-site report says the blockers
are not spread thinly. Over 120 corpus programs the named unresolved sites
are `field_read_by_name` 964, `call_member_by_name` 536, `call_new_instance`
325, `call_member_or_global` 215, `name_read_global_by_name` 189 — and
grouping the member calls by RECEIVER HEAD, weighted by executions, names one
thing:

| Receiver head | Executions |
|---|---:|
| `kotlin.FloatArray` | 19 572 |
| `kotlin.LongArray` | 6 119 |
| `<instance>` | 5 449 |
| `kotlin.String` | 5 367 |
| `kotlin.IntArray` | 3 803 |
| `kotlin.Array` | 3 562 |
| `kotlin.Int` | 2 210 |
| `kotlin.collections.IntIterator` | 1 889 |

The top blocker on a real program is `kotlin.FloatArray.get`, 480 executions
in `Rgb.Companion.contains` alone. The receiver type is fully known and the
member is a builtin intrinsic — there is no `FuncId` to name, which is
exactly why the site names nothing and the runtime re-derives by name every
time. `represent/intrinsic-bit` gave the CLASS a link-time bit; the SITE
still carries a string. A builtin member id bound at lowering, where the
receiver head is a builtin and the name is in the builtin table, is the
missing half, and these numbers say it is the largest single resolution left
outside the receiver-type fixpoint.

### Measured: the enclosing-this chain is empty where it is searched

`load_this_or_global` is the largest unresolved EXECUTED dispatch in the whole
census — 2 051 577 — and `recv_enclosing_push`/`recv_enclosing_pop` are
185 474 sites each. The goal names the dynamic enclosing-this chain as
machinery to delete, so the question is what deleting it costs. `KLIO_THIS_PROBE`
answers it, and the answer is that almost nothing is using the chain.

Of a compose program's 2 047 `LoadFromThisOrGlobal` sites, **1 992 are in a
function that contains no `EnclosingPush` at all** — 97.3%. The chain those
sites search is empty by construction: the only implicit receiver is the
function's own `this`, which `this_idx` already names. 55 sites are in a
function that ever pushes. Writes are the same shape: 412 of 436
`StoreToThisOrGlobal` sites are in a pushless function. The chain is
frame-owned, so a callee's emptiness is not the caller's.

Only 165 of the 1 992 carry a resolved identity, and the obvious reading of
the remaining 1 827 — that they are a member of a class lowering can name,
so `represent/field-slots` answers them — is WRONG, which the probe says
outright. Splitting them by the receiver a bare read would search, taken by
either route lowering has (the declaration's enclosing class, else the class
of the frame's own `this` parameter, which is what a lambda body carries):
**owner_declares=0**, owner_silent=400, no_owner=1 427. Not one site whose
receiver class declares the name. Lowering has already taken every one of
those as a field read; what reaches `LoadFromThisOrGlobal` is the residue
where no nameable receiver has the member.

So the chain is not a field-slot problem in disguise. The 400 with a known
receiver that does not declare the name are provably global reads — the walk
cannot succeed there — and lowering can emit `LoadGlobal` for them, though
`declared_props` not seeing an inherited host member makes that an audited
change rather than an obvious one. The 1 427 with no nameable receiver are
the real question, and they are the same receiver-identity gap the rest of
`resolve/receiver-types` is: a lambda whose frame has an implicit receiver
its signature does not spell. The 55 chain-using sites are all
`recv_enclosing_push` genuinely exists for, which is the measurement saying
the chain can become a register rather than be widened.

### Measured: the argument count does not name the constructor

`call_new_instance` is the third-largest unresolved class (1 064 198
executions), and unlike the rest it is not waiting on the receiver-type
fixpoint — the class is known at the site. 4 195 of a compose program's 10 210
construction sites reach a class with more than one constructor, and
`KLIO_CTOR_PROBE` says the argument COUNT alone picks one of them at 1 997 of
those, 48%. `ir.Class.secondary_ctor_arities` records what each secondary
accepts, recorded where the class is lowered beside `declared_props`, and
`soleCtorForArity` answers the question.

Serving that pick is what the measurement refuses. With the pick installed
beside the site's static heads and the value scoring run alongside it, the two
disagree on roughly 380 constructions across the corpus — `MutableScatterSet`
131, `ScopeMap` 83, `MultiValueMap` 56 — while every program still prints the
right answer, so the routes are observably equivalent there and provably
equivalent nowhere. The diagnosis stalls on a second instrument problem: the
link-time dump that would name the class's recorded constructors runs in the
bake child, whose stderr is swallowed. The data and the probe stay; the
instruction field, the census kind and the serve are reverted rather than
shipped, because a site that claims a target the runtime does not take is the
exact failure this campaign keeps finding.

### Measured: `unknown_args_singleton` is not a singleton

The extension resolver's withheld bucket is 59 338 consultations on a compose
program, and `no_candidates` is 92.76% of it. The tempting 5.34% is
`unknown_args_singleton` — 3 168 sites where exactly one candidate was ranked
and an argument's type is unknown, which reads as "nothing for the argument
types to choose between". Tallying the commit criterion over those sites says
otherwise: 2 669 have a receiver-related winner that is NOT the unique best
tier, 478 have no receiver relation, and only 882 satisfy both and already
commit. A sole RANKED SIGNATURE is not a sole candidate — `ids`/`tiers` carry
entries that never reached a signature — so the others sit at the same tier
and binding the one would pick among them by an order Kotlin does not use.

Where extension binding stops is `no_candidates`, which is the receiver's
static type again.

### Measured: the call's class was readable and almost nothing reads it

`returnClassName` — the function that decides what class a call's result
names, so an unannotated `val m = makeThing()` carries one — matched only a
`Generic` head. A plain user class is `Unresolved` carrying its declared
name, which is where constructor and factory results land, and
`classNameOfType` beside it had read that payload since it was added. Adding
the arm moves the identity channel: nameless `Call` spans 44 472 -> 41 402,
`Path` 103 379 -> 99 686, `Member` 48 533 -> 46 477, class-evidence spans
95 688 -> 100 304, heads 229 854 -> 232 183.

It moves resolution by 2 sites. `bound_static` 13 207 -> 13 209,
`no_receiver_type` 6 207 -> 6 203. The identity is recorded and the receiver
deriver still cannot use it, because the locals it is asked about are
initialised by calls whose return type is generic or whose callee typeck did
not resolve — `KLIO_NORECV_WHY` on the recurring `resolved` prints
`init_tag=Call redo=<null> full=<null>` in four different pack functions.
Kept, because reading the payload is correct and the inconsistency with
`classNameOfType` was a latent trap; recorded as near-zero, because it is.

**What the channel has now said four times.** `this` in extension bodies,
the scope-function parameter, the inferred-property fixpoint before them, and
now the call's class: each closes a real hole in what typeck RECORDS, each
moves the identity counters by thousands, and each moves `no_receiver_type`
by tens. The receiver deriver is not short of identities. It is short of
types for expressions whose type needs a resolution that needs a type, and
that loop does not open from the recording side.

### The headline numbers, re-measured

`scripts/headline-costs.sh` on the ReleaseSafe harness after this session's
work, three runs:

| | baseline | now |
|---|---|---|
| Trivial register-to-register instruction | 2.10 ns | **2.10 ns**, all three runs |
| Cheapest activation | 46.3 ns | **46.92 / 49.10 / 53.11 ns** |

The instruction cost is identical to the digit, which is the expected
result: nothing landed so far touches the dispatch loop's per-instruction
path. The activation figure is noisy across runs and its floor sits on the
baseline; read it as unchanged rather than as a regression. Neither number
has an "after" in the sense the goal asks for, and neither can until the
tiers collapse and the frame stops carrying resolution state — which the
ordering puts after the resolution work, not beside it.

### A resolved site outlives the table it indexes

`resolve/instanceof` shipped with a real bug that the corpus, the stdlib
sweep and every itest suite reported green, because none of them bundles a
program with a user-class `is` check. A bundle does: `describe(Circle(2))`
printed `unknown`, `c is Drawable` was false, and `render(JsonNum(4))`
returned `kotlin.Unit`.

The site was fine. A resolving pass splits into two halves — a field on the
instruction and a table the runtime indexes with it — and only the first is
serialized. `Module.class_ancestors` was built in the build's link path, and
a bundle loads its image and runs, skipping that path: the table was empty,
`classIsA` read "no entry" as `false`, and every type test on a user class
answered false.

Two fixes, and the second is the one worth carrying forward. The closure is
rebuilt where the image finishes loading, since it is a pure function of the
classes and registry names the image already restores. And the lookup now
returns `?bool` — `classIsAKnown` beside `classIsA` — so a module with no
entry sends the read back to the by-name walk rather than answering with a
plausible wrong value. The bundle is correct and still resolves: 13 served
type tests in `type_test_by_class.kt` where before there were none.

The property table was already safe, because it is serialized beside
`method_dispatch`; bundling `property_slot_per_class.kt` confirms it. The
general rule for the rest of this campaign: when a pass adds a site field
plus a side table, ask where that table comes from in a bundle and in an
image-loaded run, give the lookup a way to say "I don't know", and actually
bundle an example and diff it.

### The construction site names its constructor

`call_new_instance` was the third-largest unresolved class: 1 069 469 sites
over the 585-program corpus, 17.9% of everything unresolved. The class was
known at the site and the constructor was not, so every construction of a
class with more than one constructor re-derived the target from the argument
VALUES — a name-keyed side-table probe for the entry list, then a scoring fold
over the arguments, per call.

It is now named at lowering. `ir.Class` records each constructor's signature
where the class is lowered — declared parameter heads, names, defaults,
`vararg`, and whether an annotation puts the constructor out of source's
reach — spelled the way the runtime's own entry spells it, so a pick made here
and the value scoring compare the same strings. `staticCtorPick` answers with
the index the runtime numbers constructors by, 0 the primary and 1 + i the
i'th secondary. Two things settle it: the argument COUNT, when exactly one
constructor accepts it, and the call's static argument heads, when exactly one
candidate's declared heads match them position for position. Null is "lowering
cannot say" — a missing head, a named argument, a defaulted tail whose
positions no longer line up — and leaves the choice where it was.

`linkCtorPicks` fills the instruction, as a link pass rather than at emission
for the reason the getter route is one: a `NewInstance` can be emitted before
the class it names has lowered, and a reserved stub answers the question with
the shape of a class that declares nothing.

**What it moved.** Corpus-wide static sites: `call_new_instance` 1 069 469 ->
196 057, a fall of 81.7%. Total unresolved 5.04% -> **4.31%**, which is 14.6%
of everything that was unresolved. 585/585 programs exit 0 and the corpus
prints the same output.

**Two defects the work found, both in what the census was counting.**

The executed census and `KLIO_REQUIRE_RESOLVED` classified instructions with
`classify` rather than `refine`, so they skipped the class-table refinement
the static census applies and reported every construction of a
one-constructor class as unresolved. The ratchet would have raised on sites
the static census already called resolved.

`hasSoleCtor` counted the constructors a class declares, and a class whose
header spells no parameter list declares none — `internal class IntStack { }`
came out as zero constructors rather than one. Kotlin gives it the implicit
no-argument constructor, and the census called each of its constructions
unresolved. On one compose program this alone was 157 sites.

**What the audit says.** `KLIO_CTOR_PICK_AUDIT=1` runs the site's pick beside
the value scoring on every construction and serves the old path, so the
comparison is against unchanged behaviour: over the corpus, 880 agree and 4
differ. The four are one shape — `Animatable(v, converter, threshold)`, where
the class's `@Deprecated(level = HIDDEN)` constructor accepts the call and the
value scoring takes it, because the two-pass low-priority order it applies
ranks secondaries against each other and never against the primary. kotlinc
does not offer a HIDDEN constructor to source at all, so the site's answer —
the primary, with its defaulted `label` — is the correct one. The observable
result is the same, since the hidden constructor delegates to the primary with
that same label.

**Two instrument defects of my own, found before they became conclusions.**
The site pick travelled to the construction on a thread slot, and the
intrinsic route returns before consuming it, so the next construction took an
answer meant for a different call — one program built a `LocalDateTime` with
the wrong constructor. The slot now carries the argument count it was recorded
for and is re-installed only for the route that carries the same arguments
through. And the audit recorded which secondary ran in a thread slot that a
DELEGATING constructor overwrote from inside, which invented 32 of the first
36 divergences; it is an out-parameter now, so a caller reads its own answer.

### What a bare global read still asks by name

`LoadGlobal` carries an exact identity when the emitter had one, and nineteen
emitters build one; the rest leave the read on the host's name ladder — an env
hash, an object-name probe, then an FQN probe — per execution.
`linkGlobalIdentities` asks the question once per site instead, binding the
class where the name uniquely names an `object` and no top-level property or
same-named function shares the name.

It binds 80 of 1 977 open reads on a compose program, and the identity never
declines: `KLIO_GLOBAL_ID_AUDIT` reports 394 served, 0 sent back to the name
ladder. Kept, and reported as small.

The split the pass prints says where the rest are. Of 1 897 left, **1 752 name
nothing in the class table at all** — they are top-level properties, which is
what `NULL`, `openSnapshots`, `nextSnapshotId`, `MurmurHashC1` and
`NO_THREAD_ELEMENTS` are, and together they are the largest executed
unresolved class on a compose program. 123 name a class that is not an object,
and 22 name a top-level property with a custom getter. So the global read does
not come out with identities: it needs a slot, and the slot needs the define
path to write it.

### The lowered function already knows what the receiver is

`resolve/receiver-types` bottomed out in six inference problems, and the
measurement that found them asked one question: what does the AST say this
expression's type is. Six answers were "nothing", and each is a distinct piece
of Kotlin inference.

The lowered function answers a different question, and for a quarter of those
receivers it answers it without inference at all. A register written by
`NewInstance` holds that class. One written by a `Call` holds the callee's
declared return. One written by `LoadParam` holds the parameter's declared
type, and a `Move` holds what its source holds. None of that is inference; it
is the definitions read in order.

`inferRegisterClasses` is the usual lattice with optimistic initialisation:
every register starts at `top`, a definition whose class is known lowers it to
that class, a second definition of a different class or any definition whose
class this pass cannot name lowers it to `bottom`. Values only move down, so
it terminates. The enumeration of what writes a register is
`visitInstRegs` — reflection over the payload's `dst` — so an instruction added
later reads as unknown rather than being silently absent, and a catch
handler's exception register and a label absorb's value register start at
`bottom` because no instruction produces them.

`linkReceiverClasses` records the answer as `GetField.own_cls`, which is a
HINT and never an index, and runs immediately before `linkGetterRoutes`, which
is what turns a class into a slot, a getter or a property slot under the
guards that make a claim safe against a subclass. So the pass adds no new
claim of its own: it supplies the one input the existing route pass was
missing.

On a compose program it fills 1 358 of the 5 591 field reads the deriver left
classless, 24%, and the route pass binds 1 131 of them — the getter route
791 -> 962, the property slot 970 -> 1 901, the open-class slot 13 -> 42.
Corpus-wide `field_read_by_name` falls 1 982 481 -> 1 713 621 and the total
unresolved 4.31% -> **4.06%**. Every program prints the same output.

The probe also says where this goes next: the same inference names a class for
**1 300 of the 10 396 unresolved member calls**, which is the second-largest
unresolved class and the one whose resolved form is a method slot.

### What the classless receivers turned out to be

With the register pass in, 4 233 field reads on a compose program still had no
receiver class, and the pass can say what writes each of those registers.
`LoadParam` writes 2 165 of them, half; `GetField` 1 040; `Move` 252; `Const`
239; `CallMember` 200; `LoadCapture` 183; `LoadGlobal` 108.

Splitting the parameters by why the head named no class: 2 001 of 2 165 name a
class the pass rejects as host-backed, 136 name no class at all, 23 are
nullable. And the 2 001 are almost entirely arrays and `String` — `size`
1 117, `lastIndex` 565, `indices` 135, `length` 50.

So the largest single remaining group of classless field reads is not an
inference gap at all. `arr.size` and `s.length` are declared MEMBERS of a
host-backed classifier: there is no declaration to bind, no layout to claim a
slot in, and no user extension that can shadow a member. Naming the operation
IS the resolved form, exactly as `BuiltinMember` is for a call.

`BuiltinField` is that, bound from the field name where the instruction is
pushed so no emitter can leave it unset, and `linkBuiltinFields` proves it
against the receiver's static head. The head comes from the same register
lattice, which now carries the declared head beside the class — a host
classifier has a head and no class, which is precisely the pair this needs:
nothing can claim a slot against it, and the head is what proves the builtin.
The unsigned array classes are excluded by name, because `UIntArray.size` is a
declared property with a body over the wrapped `storage`, not the array's own
length.

1 007 reads proven on a compose program. Corpus-wide `field_read_by_name`
1 713 621 -> **1 139 092**, a fall of 33.5%, and the total unresolved
4.06% -> **3.57%**. Output unchanged everywhere.

`lastIndex` and `indices` are left alone: they are stdlib EXTENSION
properties, a user declaration can shadow them, and the runtime already gates
its fast serve on a program-wide "nothing shadows these" verdict. Naming them
at the site would move that decision to a place that cannot see the program.

### Where the resolution campaign stands

| | start of session | now |
|---|---:|---:|
| static unresolved, 585 programs | 6.614% -> 5.043% | **3.57%** |
| `field_read_by_name` | 1 982 481 | 1 139 092 |
| `call_new_instance` | 1 069 469 | 196 054 |
| `name_read_global_by_name` | 265 378 | 241 160 |

### Three more producers, and what they were each worth

The register lattice gained what the IR already says and nothing more.

`x as T` names the register's class outright, and `x!!` and a `lateinit` check
narrow nullability rather than class, so both propagate their source. A safe
cast writes null instead and says nothing.

A field read the route pass bound to a declared SLOT holds that property's
declared type, which needed the layout to carry one: `LayoutSlot` and
`ir.FieldSlot` now record the declared head beside the seed, taken from the
constructor parameter's `declared_type` and the body property's `type_head`.
Only the head, so `Int?` and `Int` both read as `Int`; every consumer of this
lattice re-proves against the receiver, so the collapsed nullability costs a
miss and never a wrong answer.

The same head also proves a builtin OPERATION, not just a builtin property:
`linkBuiltinMembers` asks the head lowering recorded on the site and most
sites record none, so `linkBuiltinMemberRegs` asks the register's.

Worth, on a compose program: the builtin operation 4 968 -> 5 090 proven, the
classless field reads 1 358 -> 1 388 filled. Corpus-wide
3.57% -> **3.52%**, with `call_member_by_name` 1 113 459 -> 1 059 574. Small,
recorded as small, and kept because each is the IR's own statement about the
register rather than a guess about it.

The slot type is worth less than it looks, and the reason is worth writing
down: a chained read `a.b.c` only gains from it once the FIRST link is bound,
and the reads still classless are the ones whose chain never starts.

### A resolved site outlives the format that encodes it

The bundle suite went red on five tests with the child exiting 65535, and the
cause is the general rule from `resolve/instanceof` in another costume. Four
changes in a row added a field to something the image encodes — the
constructor pick on `NewInstance`, the builtin pair on `GetField`, the
constructor signatures on `ir.Class`, the declared head on a layout slot —
and none of them bumped `FORMAT_VERSION`. The version guard is the whole
mechanism that refuses a stale image and makes the caller rebake; without the
bump, a parity-base image written by the previous binary was read into the
new struct shapes.

The corpus, the census sweep and the stdlib sweep were all green throughout,
because every one of them bakes fresh. Only a run that loads an image
someone else wrote sees it. Added to the rule the earlier bug produced: when
a pass adds a field, ask where the table comes from in a bundle AND whether
the encoded layout changed — the second question has a one-line answer and
the first does not.

### The member-or-global hedge, decided where it can be

The last measurement of `call_member_or_global` ended with "`KLIO_XORY_AUDIT`
refutes all of them" and the instrument landing with nothing reading the bit.
Two things were wrong with that conclusion and both are now fixed.

**The audit's arm label counted a global win as a member win.** At
`Rgb.Companion.contains`, `floatArrayOf` was reported `arm=member` — and
printing the declaration each arm actually entered says the member walk called
`floatArrayOf#14402`, which is the very function the site's global leg names
(`site_global_fid=14402`). The walk was a longer route to the same place. The
audit now captures the first declaration an arm enters and reports only a
DIFFERENT target.

**But the claim was also wrong, in two ways that the corpus could not see and
the stdlib suite could.** Serving it turned 0 commontest failures into 18.

The first: `hierarchyDeclaresName` and `anyAncestorDeclaresName` read declared
PROPERTIES and the shadow-name registry, and a member FUNCTION is in neither.
`ResultTest` declares `fun error(message: String): Nothing`, which shadows
`kotlin.error` for every bare call in its body, and the claim could not see
it. `hierarchyDeclaresMethod` asks the class's own `methods` and its ancestor
closure.

The second is the one the plan predicted: **a lambda body runs in a frame
whose implicit receiver its own signature does not spell.**
`runCatching { error("F") }` inside that same class reaches the member, and
nothing reachable from the lambda's own declaration says so. A site in a
function with no `DeclSig` is refused.

And a third, from the overload side: the claim says the global LEG wins, not
which declaration it runs. The leg re-ranks a name with several declarations
by the argument values, so the site's `func` is one guess among them —
`assertContentEquals` and `sequenceOf` both picked differently. A name with
exactly one declaration has nothing to re-rank.

With all three, the stdlib suite is back to 0 failures with the serve on, and
the hedge is decided at **220 of a compose program's 4 289 sites**. The three
refusals are now counted, and they are the whole remaining answer:

| | sites |
|---|---:|
| served: the global leg is the only one that can win | 220 |
| refused: an inline splice's receiver is in a register | 252 |
| refused: the name has more than one declaration | 161 |
| refused: the frame is a lambda's, with no declaration to ask | 814 |
| refused: the owner declares it, an extension could serve it, or no global target | the rest |

Corpus-wide `call_member_or_global` 649 543 -> **615 787** and the total
unresolved 3.52% -> **3.49%**. Small, and the value is the decomposition: the
hedge is not blocked on one thing, it is blocked on three, and two of them are
the same splice-and-lambda receiver identity the rest of the campaign wants.

### `tl_cancel_via_coroutine_context` is a scheduling race, and two fixes missed

The litmus that has cost this campaign several gate REDs was re-diagnosed
rather than re-observed, and the earlier reading needs correcting on one
point and confirming on another.

Run standalone it failed 8 times out of 8 — which looks deterministic and is
not. Widening the fixture to three identical scopes in a loop shows the loser
MOVES: the second fails while the first and third pass, and with
`KLIO_PUMP_DIAG` on (which changes the timing) the first fails while the
second and third pass. One scope loses per run; which one is scheduling.

Two fixes were tried and neither works, so both are recorded as negatives
rather than kept. A `yield()` that waits for the pool's QUEUE to drain gives
the worker time to take the task but not to run its body. A `yield()` that
waits for the pool to have no outstanding task at all — bounded, skipped on a
worker — does not help either, and the instrumented run shows why: the
zero-wakeup `park` a yield was assumed to take is never reached, so neither
wait ran at all. The pump's own ordering is already right: step 1 starts
queued child launches before step 3 serves a ready token.

What is now known and was not: the child of `CoroutineScope(Job())` is
dispatched to the worker POOL, not to this pump's launch queue, so no pump
ordering can sequence it; and `yield()` from a `runBlocking` body does not
reach `CooperativeInterceptor.park`. A fix has to start from where that yield
actually resumes.

### A lambda body now records what its bare names resolve against

The largest refusal in the member-or-global claim was "the frame is a
lambda's, with no declaration to ask" — 814 of a compose program's 4 289
sites. The class whose members a lambda's bare names see is known at exactly
one moment, when the body is lowered, and was recorded nowhere: the body
becomes a `Func` with no `DeclSig`, and every later pass asking "what
receivers are in scope here" had nothing to read.

`FuncExtra.lexical_owner` is that, written where the lambda's `Func` is
finished, from the enclosing class the builder was already carrying for
member-name resolution. It is `?[]const u8` and the tri-state matters: empty
means "recorded, and there is none", null means "not recorded", and only the
second is a reason to refuse.

The refusal falls **814 -> 11**, and with the site's own candidate set used
where lowering recorded one (a set of one has nothing for the global leg to
re-rank), the hedge is decided at **385 sites** rather than 220. Corpus-wide
`call_member_or_global` 615 787 -> **596 205** and the total unresolved
3.49% -> **3.47%**.

**A correctness hole the widening exposed.** `extensionCouldServe` was asked
only inside the owner branch, so a site with NO owner was never asked it at
all and could claim past a same-named extension. It is name-only, so it
belongs to the site rather than to one receiver; hoisted, it is now the
largest refusal at 676.

**And a negative, measured and reverted.** Naming the splice receiver's class
from the register lattice and asking it the owner's three questions does not
make the claim sound: `Iterable<T>.sortedDescending` calls `reverseOrder()`
inside `sortedWith`, and claiming there changes what runs —
`enum_natural_order.kt` fails with `UnsupportedOperationException` while the
stdlib suite stays clean, which is the second time in this session that the
corpus and the stdlib suite have caught different bugs. The splice receiver
stays refused, at 169 sites.

### Two small ones, both recorded as small

A `const val` takes a compile-time constant initializer and cannot be
overridden or reassigned, so a bare read of one has a single answer for the
life of the program. The scanner has recorded those values since it was
written — the comment says "so references inline it" — and **nothing ever
read the table**: every such site still hashed the name through the host's
global ladder. `linkConstGlobals` replaces the read with the constant. 38
sites on a compose program: correct, free, and small, because `const val` is
rare in this corpus's hot paths.

`extensionCouldServe` is the member-or-global claim's largest refusal and it
ignored its `cid` argument entirely: it answered "yes" whenever ANY extension
of the name existed anywhere in the program. Asked about the receiver — the
extension's declared receiver head against the owner's ancestor closure, with
an unbounded type-parameter receiver and an absent closure both reading as
"cannot say" — the refusal falls 676 -> 537. It buys 7 more served sites,
because the sites it frees are caught by the splice and overload refusals
instead. Kept because the question was simply wrong, reported as near-zero
because that is what it moved.

### Where the campaign stands after this session

| | before | after |
|---|---:|---:|
| static unresolved, 585 programs | 5.043% | **3.47%** |
| `KLIO_REQUIRE_RESOLVED=1` passing | 49 / 585 | **133 / 585** |
| `field_read_by_name` | 1 982 481 | 1 128 408 |
| `call_member_by_name` | 1 113 445 | 1 059 575 |
| `call_new_instance` | 1 069 469 | 196 064 |
| `call_member_or_global` | 649 543 | 596 205 |
| `name_read_global_by_name` | 265 378 | 241 148 |

Measured against the campaign's opening numbers rather than this session's,
`field_read_by_name` is 4 606 056 -> 1 128 408, `call_member_by_name`
2 384 738 -> 1 059 575, `call_new_instance` 1 385 738 -> 196 064, and the
ratchet 31 -> 133.

**What the remaining three classes are waiting on**, each now measured rather
than assumed:

`field_read_by_name` (1.13M). The receivers still classless are, by producer:
a chained `GetField` whose own first link is unbound, a `Const`, a
`LoadCapture` whose captured local's type the IR does not carry, an
unresolved `CallMember`, a `LoadGlobal` that is not an object. The array and
String reads that dominated it are gone.

`call_member_by_name` (1.06M). The member gate's own census says the reason
is `no_member_by_name` at 32% — the receiver class IS known and its hierarchy
declares no such member, so the call is an extension, and the extension
resolver's withheld bucket is 93% `no_candidates`. That is the extension
subsystem, not the receiver-type fixpoint.

`call_member_or_global` (596k). Three counted refusals: an extension of the
name could serve the receiver (537), the site's target is one of several
declarations (153), an inline splice's receiver sits in a register (201).
The first two are resolution questions; the third is the receiver identity
the rest of the campaign wants.

### The whole chain, measured end to end

The question "why not delete the unresolved machinery and resolve everything"
now has a measured answer rather than an argued one. The chain, on one compose
program:

1. 5 043 member calls still dispatch by name. Splitting them by what lowering
   knows: **2 958 have no receiver class at all**, 981 have the class but no
   argument types so no overload can be picked, 377 the resolver would bind
   right now, 118 are genuinely ambiguous, 343 have a host classifier for a
   receiver, 115 could be served by an extension, 150 nothing declares.
   **78% is one cause: no static type for an expression.**
2. Lowering asks the typed map for those types 92 500 times and misses 87%:
   `no_entry` 80 328, `ok` 4 990.
3. The map is not absent for want of running — typeck is handed all 626 files
   and 8 199 top-level declarations, and types 195 965 expressions.
4. It records a head for 85 647 of them. The largest drop by far is
   **`Type.Unresolved`, 77 372** — the checker's own "I cannot name this".
5. By expression kind, that is **`Path` 36 083**, `Call` 17 314, `Member`
   9 697. A bare name is 47% of everything the checker cannot type.
6. Of the single-segment paths it gives up on, **15 037 are
   `absent_from_tables`** — and the names are `size`, `_size`, `_capacity`,
   `storage`, `metadata`, `content`, `keys`, `values`, `findKeyIndex`: own
   members of the class whose body the expression is in.

So the resolution ceiling is not the number of call sites and not the
machinery. It is that **the type checker cannot name the type of 40% of the
expressions it checks**, and the largest single reason was that a bare name
inside a class body was never looked up among that class's own members —
though the checker holds every class's member types in `ClassInfo.members`.

`ownMemberType` closes that one: a bare name that is no local, class,
top-level property or function is looked up in the enclosing classes innermost
first, then up the first supertype chain. `absent_from_tables`
15 037 -> **10 640**, and the recorded heads 85 647 -> **90 292**.

**And it moves the census by 0.01 points**, which is the finding that matters
next. `[no-recv] eager-has-head` is 1 of 1 137: lowering's receiver deriver
still reads nothing from the map. `KLIO_EAGER_KEYS` says the misses are not a
key mismatch — the map holds keys in the same files — so the remaining
`no_entry` is spans typeck never recorded rather than spans lowering asks
about wrongly. The checker half and the consumer half are two separate jobs,
and this is the first of them.

### The misses are the checker's, not the plumbing's

`eagerTypeOf` missing 87% of the time admits two readings: lowering asks about
spans the checker never saw, or spans the checker saw and could not name.
`KLIO_EAGER_SEEN` separates them by recording a visited-but-unnamed span as an
empty head. The answer is not close: **`no_entry` 78 488 -> 10 123 and
`empty` 68 379**. Seven eighths of what lowering asks for is an expression the
checker looked at and had no name for, and `KLIO_EAGER_KEYS` had already ruled
out a key mismatch by finding keys from the same file beside every miss.

That settles where the remaining resolution work is. It is not plumbing
between typeck and lowering, and it is not the count of call sites: it is
`computeExprTy` returning a nameable type more often.

**One head added, three measured worse.** `eagerHeadOf` refused several types
the checker had already named. Adding `Unit`, `Nothing`, `Any` and a function
type's `FunctionN` head together took the recorded heads 90 292 -> 138 282 and
the site census **4.38% -> 4.51%** — worse, because `Unit`, `Nothing` and
`Any` are answers a consumer accepts in place of a better one it would
otherwise derive. Keeping only the function head leaves the census at 4.38%
with 101 436 heads recorded: neutral today, and kept because a lambda
argument's `FunctionN` head is exactly the input the 981 member calls whose
ARGUMENT types are unknown will need.

### The call checker gives up in one place, and mostly on infix

`Call` is 17 314 of the checker's unresolved spans, the second largest kind
after `Path`, and it has two dozen exits. A census keyed by SOURCE LINE —
`unresHere(@src().line)` at each of them, so none had to be labelled by
hand — says they are not spread out: **`expr_calls.zig:430` is 11 864 of
14 864**, the last exit, where the callee resolved to no signature and its
type is not a function.

Splitting that exit by callee shape: **bare name 6 516, member 5 320**,
qualified 10, lambda 0. And naming the bare ones: `and` 630, `append` 546,
`until` 366, `get` 346, `callsInPlace` 339, `shl` 273, `or` 214, `to` 164,
`shr` 142, `downTo` 91, `xor` 81, `ushr` 60.

Those are infix calls. `a and b` parses as `Call(Path["and"], [a, b])` with
`is_infix` set, and the declaration it names is a MEMBER of the first
argument's type — `Int.and`, `Long.shl`, `CharSequence.get`. The checker
looked the name up among top-level functions and classes, and nowhere else,
so every infix call on a builtin came out untyped.

`infixMemberReturn` types the left operand, names its class, and walks that
class and its supertypes for a one-argument member of the name. `Call`
unresolved **17 314 -> 13 115**, a quarter of them, and the recorded heads
101 436 -> 102 532.

The site census does not move, and that is now the expected result twice
over: the checker half and the consumer half are separate jobs, and
`[no-recv] eager-has-head` is still 1 of 1 137. What has changed is that the
checker's own gap is a third smaller than it was, and the remaining shape —
`member` 5 265 at the same exit — is the next one.

### The consumer is wired, and every miss it has is a bare name

Two corrections to the reading above, both from counting rather than
inferring.

**The consumer was never disconnected.** `eagerReceiverTypeRef` is the last
rung of the receiver deriver and has been since it was added; the
`eager-has-head 1 of 1 137` figure is taken at the no-receiver census, which
runs only AFTER that rung has already failed, so it could never have shown
anything else. Counting the rung itself: **asked 41 264, served 4 711.** One
job, not two, and it is the checker.

**Every miss is a `Path`.** Tallying the rung's misses by expression kind
gives `Path` 36 567 and nothing else at all. The deriver asks about bare names
and only bare names, which is why three checker fixes worth 9 000 typed
expressions moved the served count by five: they typed infix calls, member
calls and own-member references, and the rung is not asked about any of those.

So the target is exact: the type of a bare name. `Path` is also the checker's
largest unresolved kind at 29 398, and the two halves of it are now visible —
about 16 400 reach the name-lookup census (`absent_from_tables` 10 640 after
the own-member fix, `class_evidence` 1 391, `own_member` 4 359 now typed) and
about 13 000 return unresolved earlier, from a local binding whose own
declared type is unresolved. That second half is the cascade: `val x =
<untypable>` makes every later `x` untypable, which is why `Call` sits
upstream of `Path` and both sit upstream of the census.

Landed alongside: the member-call arm derived its receiver class from a
hand-written list of six builtins, missing the unsigned types and the user
class carried on `Unresolved`; and having found a class it probed only for
EXTENSIONS, never for a member, so `5.toLong()`, `sb.append(x)` and
`list.add(x)` fell through. Both fixed — `Member` 9 697 -> 9 097, `Call`
13 115 -> 12 687, `Path` 31 724 -> 29 398.

### A seventh of the deriver's misses are names lowering invented

Naming the 36 567 bare-name receivers the deriver's last rung cannot type:
`size` 2 723, **`this` 2 213**, `current` 1 524, **`$lv$recv` 1 428**,
`addressSpace` 1 388, `it` 1 287, `metadata` 700, **`kotlin` 691**, `groups`
654, `value` 594, `element` 590, **`kotlinx` 536**, `SEGMENT_SIZE` 530.

Four of the top twelve are not expressions the checker ever saw. `this` and
`$lv$recv` are spans LOWERING synthesizes — a `Path["this"]` where source
wrote a `This` node, and the splice receiver's own local — and `kotlin` and
`kotlinx` are package qualifiers, the leading segment of a qualified name,
which has no type to ask for. Together they are 4 868 of the misses, and no
amount of work on the checker can answer any of them: the rung is being asked
a question its source cannot hold.

So the 36 567 is not 36 567 checker gaps. It is about 31 700, and the rest is
the deriver asking the wrong source.

**One fix tried and reverted.** Handling the synthesized `Path["this"]` with
`bareThisTypeRef`, the same answer the `This` arm gives, takes the asks
41 264 -> 39 036 and the site census **20 649 -> 20 663 — worse by 14.** A
synthesized `this` is not reliably the builder's own receiver: inside a
spliced body it can name the caller's, and the answer displaces a better one
a later rung would give. Recorded as a negative; the correct fix needs to know
which `this` the synthesized path means, which is the splice-receiver
identity the rest of the campaign wants.

### The cancel litmus, fixed at the dispatch

`tl_cancel_via_coroutine_context` has now taken three of this campaign's gate
runs, and the two earlier attempts missed because they were placed where the
yield was assumed to resume. It does not resume there. `yieldNow` is
deliberately not bound as `kotlinx.coroutines.yield`, so the source `yield()`
runs upstream's `Yield.kt`, which calls `dispatchYield` into
`KlioDispatcher.dispatch` and thence `__kxco_spawn` — the pump's launch
queue. The `Dispatchers.Default` child, meanwhile, went to the worker POOL
through `__kxco_dispatch`. Nothing orders the two, and the pump's own
ordering — launches before ready tokens — cannot, because the child is not in
its launch queue.

Putting the handoff at the POOLED dispatch was tried and is wrong, and the
suite said so: `tl_daemon_queued_dropped` launches a daemon on
`Dispatchers.Default` and returns from `main` without suspending, and that
task must be DROPPED. Waiting at the dispatch ran it.

The two litmus tests are the whole specification between them. The cancel one
has a `yield()` between the launch and the cancel; the daemon one has no
suspension at all. So the wait belongs at the dispatch ONTO THE PUMP — which
is exactly what `yield()` performs — and a `main` that never suspends never
reaches it. `coroutineLaunch` waits there for outstanding pool work to reach
its own first suspension: bounded at 5 ms, skipped on a pool worker, a no-op
when the pool has nothing outstanding.

Both litmus tests pass 8 runs of 8, the corpus is 585/585, the stdlib suite is
clean, and the cost is nil — 0.15s against 0.16s, warmed and alternated over
three rounds.

**And a measurement error worth recording.** The first A/B put the handoff at
ten times the program's CPU, 4.81 s against 0.48 s, and two rounds of
narrowing were spent on that number. It was an artifact: the timing loop ran
immediately after the link and measured `handoff=1` first, so the fresh
binary's first-exec cost landed entirely on one arm. Warmed once and
alternated, three rounds each: **0.16 s both ways.** The repository's own
note about a just-linked binary's first execution says exactly this, and I
did not follow it.

### The call checker's remaining shapes are all downstream of the cascade

With the infix member rung in, the names still failing at the call checker's
last exit are `append` 547, `and` 429, `until` 365, `get` 346, `to` 163,
`shl` 104, `downTo` 91 — the same list, barely shorter. `until`, `downTo` and
`to` are infix EXTENSIONS rather than members, so the member walk cannot see
them, and adding the extension probe beside it moves the count by **two**.

The probe is not at fault and the extensions map is not empty:
`[EAGER-MEMBER]` shows `recv_class=Int name=inv cands=1 ext_key=true`, so
`Int`'s extensions are indexed and findable. The rung declines earlier, at
`typeClassName` of the LEFT OPERAND: `a until b` where `a` is an untyped
local never reaches the lookup at all.

That is the cascade, and it now has a measured consequence for how the rest
of this work should be done: **every further per-shape rung in the call
checker will return about zero until bare names are typed.** A call's shape
does not matter when its receiver has no type; `Call` 12 687 feeds untyped
locals, untyped locals make `Path` 29 388, and `Path` is 100% of what the
receiver deriver asks for and misses.

The cheap and correct wires are now taken — own-member paths, infix members,
member-call members, the member arm's class derivation, infix extensions —
and what remains behind them is not a wire. It is overload resolution over
argument types, generic return instantiation, and a fixpoint over local
declarations: a real inference pass, sized accordingly.

### The cascade is not an ordering problem

If `val x = <untypable>` poisons every later `x`, the obvious question is
whether the checker simply learns too late — whether a body checked a second
time, with everything the first pass recorded in hand, would name more. That
is cheap to answer: `checkBodies` is one call, and running it again with
reporting off is `KLIO_TC_FIXPOINT`.

It converges after **one** extra pass, and the whole gain is 2 007 type heads
(102 991 -> 104 998) and **27** unresolved sites (20 649 -> 20 622). Rounds 2
and 4 add exactly nothing.

So the 68 000 expressions the checker cannot name are not waiting on
information it already has in a different order. They are waiting on a
capability it does not have: overload resolution over argument types, generic
return instantiation, and inference through a local's initializer. That
closes off "iterate the existing checker" as an avenue, which is worth as
much as a gain would have been.

The knob stays, defaulted off, because the trade is bad on its own terms:
27 sites for **16% of the cold build** (16.06s -> 18.61s over two cold runs).

### The headline numbers, measured again

`scripts/headline-costs.sh` on the ReleaseSafe harness, three runs, warmed:

| | baseline | now |
|---|---|---|
| Trivial register-to-register instruction | 2.10 ns | **2.09 / 2.10 / 2.11 ns** |
| Cheapest activation | 46.3 ns | **46.75 / 46.92 / 47.20 ns** |

Unchanged, and expected to be: nothing in the resolution work touches the
dispatch loop or the frame. They move when the tiers collapse, which the
ordering puts after this.

### A bare name in an extension body resolves against the receiver

More than half the names the checker gives up on — **6 043 of 10 684** — are
checked with an EMPTY class stack, which reads as "not inside a class" and is
not what it means. They are extension bodies: `fun Array<T>.f() { … size … }`
has no enclosing class and its bare names resolve against the RECEIVER. The
checker tracks that receiver in `this_ext_stack`, kept deliberately apart from
`class_stack` because "in `fun Foo.bar()`, bare `this` is the extension
receiver, not the enclosing class" — and the own-member lookup read only
`class_stack`.

Reading both: `absent_from_tables` 10 687 -> **9 100**, `own_member` 4 375 ->
5 921, recorded heads 102 991 -> **105 942**.

The site census is unchanged at 20 649 and the deriver's yield moves by 8.
That is now the fourth checker fix in a row to behave this way, and the
pattern is the whole finding: **the producer is improving and the consumer is
not, because the consumer asks about bare names whose types depend on the
initializers of locals, and those depend on calls, and those depend on
argument types the checker still cannot rank.** The chain does not shorten
one rung at a time.

### The requirement, put in place

The campaign has been measuring resolution and asking the measurement to be
believed. It is now enforced instead.

`plans/resolution-ceiling.json` records every unresolved site kind and its
corpus-wide count — 24 kinds, 4 111 245 sites as of this commit — and the
gate's `ratchet` phase re-runs the census against it. **A kind may fall and
may not rise, and a kind absent from the file may not appear at all.** A
lowering change that re-derives one more target by name fails the gate the
day it lands rather than at the next census read, and the only way to make
the gate green again is to resolve the site.

Proved on a doctored ceiling before it was wired in: lowering
`field_read_by_name` by 5 000 and deleting `type_cast_by_name` from the file
makes the phase print `ROSE field_read_by_name 1 122 578 -> 1 127 578 (+5000)`
and `NEW type_cast_by_name 11 611`, and exit 1.

This is what makes the rest of the campaign a ratchet rather than a series of
readings, and it is the mechanism the goal's "censuses reporting zero for
every class except a named, justified dynamic_by_design list" is reached
through: the named list is the file, and it only shrinks.

### Member overloads are selected by argument type

`ClassInfo.members` collapses a name's overloads to one entry, and the
member-call arm's new member lookup read it — so `sb.append(x)` was answered
by whichever `append` happened to be recorded, or by nothing when the arity
did not match. `member_methods` is the set the class actually declares, and
its own comment says call-site selection reads it. Collecting from there and
handing the sigs to `checkOverloadedCallRecordedAt` is the ordinary overload
selection over the argument types.

`Call` 12 687 -> **11 883**, `Path` 29 400 -> **27 346**, `Member` 9 097 ->
8 991, and the call checker's last-exit bare names 5 911 -> 5 146.

### The producer improved by 20 000 heads and the census did not move at all

Recorded type heads across this session's checker work: 85 647 -> **105 936**.
Over the same span the site census is 20 649 both before and after, and the
receiver deriver's last rung went 4 706 -> 4 718 served of ~41 264 asked.

Five consecutive checker fixes, each correct and each measured, and none of
them reached the census. The model behind them — that the checker's coverage
is the census's ceiling — has a missing link, and the link is worth finding
before any more producer work:

- The deriver's 41 264 asks are `argDeclTypeRefLazy` calls, which serve
  ARGUMENT types as well as receivers, so the rung's yield was never a proxy
  for the field-read and member-call censuses.
- The classless field reads are 4 233 per program and the classless member
  calls 2 952, which is 7 185 — a sixth of the asks. Whether a perfect type
  map would close those is a different measurement from the one being taken,
  and it has not been taken.

So the next thing is not another capability. It is to measure, for the
specific sites the census counts, what a complete map would give them —
by asking the map for each unresolved site's receiver directly and recording
the answer, rather than inferring from the rung's aggregate.

### The missing link, measured: a tenth of the misses are answers thrown away

The rung's aggregate could not say whether a miss was the checker's fault or
the plumbing's. `eagerEntryState` splits it — never seen, seen and unnamed,
or **named and refused** — and over the deriver's 36 566 misses:

| | |
|---|---:|
| the checker never saw the expression | 3 930 |
| the checker saw it and had no name | 28 822 |
| **the checker named it and the consumer refused the name** | **3 806** |

Naming those refused heads settles what they are. `Function1` 889,
`Function0` 759, `Function2` 158 — **1 806 of them are the `FunctionN` heads
added earlier in this session**, refused because no class answers to
`Function1`. That is the whole reason that addition read as neutral: it
enlarged the map with heads this consumer cannot use. `V` 350, `R` 240,
`S` 143, `T` 111, `E` 67, `K` 39 are bare type parameters and are correctly
refused. The remaining ~1 050 are real classes — `AtomicLong` 316,
`Operation` 234, `TrieNode` 218, `AtomicInt` 126 — refused because two
packages share the spelling and `uniqueClassIdBySimpleName` answers only when
the whole program declares one.

**The prize is real and the first rule for it was wrong.** Settling the
ambiguity by the span's file PACKAGE takes the deriver's yield 4 719 ->
**5 114** and the census 20 649 -> 20 642 — and breaks `mosaic_hello.kt`,
`compose_window.kt` and `compose_window_foundation.kt` with
``get_field `ref` on `kotlin.Nothing` ``. A file's package is not its import
scope: Kotlin resolves a simple name against the file's imports first, and
picking the same-package class picks the wrong one wherever the file imported
the other. Reverted; the rule has to read the file's imports, which
`importedSegmentPathFor` already does for other callers.

### Two rules for the refused tenth, and neither is the one

The ~1 050 receivers whose head the checker resolved and the consumer refused
are worth a rule, and the rule is not obvious:

- **The span file's PACKAGE.** Yield 4 719 -> 5 114, census -7, and
  `mosaic_hello.kt`, `compose_window.kt` and `compose_window_foundation.kt`
  fail with ``get_field `ref` on `kotlin.Nothing` ``. A file's package is not
  its import scope; where the file imported the other class, the
  same-package pick is simply wrong.
- **The span file's ALIAS imports.** Exactly zero, because
  `importAliasPathsIn` carries `import x.Y as Z` and not plain `import x.Y`,
  and these names arrive by plain or wildcard import.

A third rule closes the avenue. `import_aliases` does hold plain
non-wildcard imports keyed by leaf — the earlier reading of it was wrong —
and `import_wildcards` holds the rest, so the file's WHOLE scope is
available. Collecting every route it offers and accepting only where they
agree on one class gives yield 4 719 -> **5 177** and census 20 649 ->
**20 681, worse by 32**.

Three rules, three times the same shape: what the rung answers rises, what
lowering resolves does not improve. The generalisation is the finding. **A
head the module cannot uniquely name is not reliably the right class**, and
pushing it through costs lowering more than declining does — a wrong
receiver sends a site down a worse path than no receiver. The consumer
cannot guess which class a simple name means, and should not try.

The fix belongs in the producer. `eagerHeadOf` records whatever the checker
had, which for a user class is the simple name off `Type.Unresolved`; the
checker RESOLVED that name against the file's scope to type the expression
in the first place, and recording the fully-qualified result instead would
leave nothing to disambiguate. That is the next piece of work on this
tenth, and it is one change in the producer rather than a rule in the
consumer.

### The ratchet's first catch

The gate run after the member-overload selection landed went RED on the
ratchet phase, not on a test:

    ROSE   field_read_by_name   1 127 578 -> 1 127 586  (+8)

Before treating that as a regression the census had to be shown
deterministic, since a nondeterministic one would make the phase produce
false failures and be worth nothing. Three sweeps of the same tree give
4 111 253 exactly, so it is real.

The only semantic change since the ceiling was recorded is the member-overload
selection, which took `Call` 12 687 -> 11 883, `Path` 29 400 -> 27 346 and
`Member` 9 097 -> 8 991 in the checker. Better member types change what some
lowering rungs decide, and eight field reads came out by name that had not
before. The ceiling is re-recorded at 4 111 253 with that as the reason,
which is the process the phase exists to force: a rise is explained in the
log or it is fixed, and it cannot pass silently.

### Why the producer cannot emit an FQN either

The conclusion above — record the fully-qualified head and leave nothing to
guess at — assumed the checker knows which class it resolved. It does not,
and the reason is one line of structure:

`Checker.classes` is a `StringHashMap(ClassInfo)` keyed by **simple name**.
`putClassChecked` notices a second declaration of the same name from another
file, records it in `ambiguous_class_names`, and overwrites the entry anyway;
`classNamed` then refuses that name to every caller. So for `AtomicInt`,
`AtomicLong`, `TrieNode`, `Operation` the checker holds one arbitrary
`ClassInfo`, refuses to hand it out, and types the expression
`Unresolved("AtomicInt")` — a simple name it cannot resolve either.

That is consistent rather than buggy: `classes.get` is reached only through
`classNamed`, so the ambiguous entry is never handed to anyone and the
overwrite is dead data, not a wrong answer. The conservatism is the cost.

So the ~1 050 refused receivers are blocked on the checker's class table
being keyed by simple name with no per-file scope in it. The fix is to key
classes by FQN and resolve a simple name against the declaring file's
imports and package — a change to the checker's core table that every
consumer of `classes` and `classNamed` reads through. That is the actual
piece of work, and it is now named precisely rather than guessed at from the
consumer side four times.

### What the census is and is not stable against

The ratchet's second gate run failed on three kinds rising after a commit
that changed one comment. The first reading of that — that some lowering
decision depends on the binary's layout, so two builds of the same source
resolve differently — was **wrong**, and the correction matters more than
the claim did.

It is the bake cache. A rebuild invalidates it, so that run was cold where
the ceiling was warm:

| | unresolved sites |
|---|---:|
| cold, cache cleared | **4 111 230** |
| warm | 4 111 253 |
| warm again | 4 111 253 |
| cold again | 4 111 230 |

Both states are exactly reproducible. So there is no build-sensitivity, and
the 23-site gap is a finding of its own: **resolution a fresh lowering
reaches does not entirely survive the image round-trip.** Twenty-three sites
come back unresolved from a baked image that were resolved when lowered,
which is the "a resolved site outlives the table it indexes" family again and
is worth chasing on its own.

One residual nondeterminism is real and much smaller. Cold to cold, the TOTAL
is exact and the per-kind split trades six sites between
`call_member_by_name` and `call_new_instance` — a classification flipping on
whether the class was registered when the site was classified, which depends
on the body pool's shard order. So the phase checks the total exactly and the
split with `max(64, ceiling/1000)` slack, and clears the cache so the state
matches the ceiling's. Re-verified both ways: two cold runs agree exactly,
and a ceiling lowered by 300 fails with `TOTAL 4 110 930 -> 4 111 230`.

### The two host-backed gaps

Corpus-wide unresolved sites **4 111 230 -> 3 498 204 (-14.9%)** across two
changes, each closing one half of the same structural fact: a host-backed
classifier carries neither an interpreted field layout nor a method table.

**Index properties proven from the receiver head.** `indices` and `lastIndex`
join `size` and `length` as builtin properties, `size` gains the unsigned
array classifiers, and the runtime's name-global shadow verdict — recomputed
once per dispatch-cache generation — becomes a property of the build. On
`examples/collections.kt`: `field_read_by_name` 1 406 -> 528, proven builtins
979 -> 1 857, whole-program unresolved 4 157 -> 3 279. Ceiling 4 111 230 ->
3 594 989.

**A member call binds its slot from the receiver head and the arity.** The
registry keys every member declaration by (class simple name, name, declared
arity); where that key names one declaration the argument types cannot change
the pick. 322 of the 341 sites the probe counted as waiting on argument shapes
have such a key. Soundness rests on two guards: the table's writers overwrite,
so a key more than one declaration claimed is recorded and refused — 89 of
2 503 keys, and the set rides the image so a program lowered onto a baked base
sees it; and a same-named extension that could serve the receiver withdraws
the bind, because a member wins by being applicable rather than by arity.
`Random.nextLong` takes a `LongRange` as an extension and a `Long` as a
member, both arity one, and without the second guard the member's body was
handed a range — three stdlib failures that named the defect exactly.
`call_member_by_name` 1 065 -> 902, whole-program 3 279 -> 3 116. Ceiling
3 594 989 -> 3 498 204.

Both verified at corpus 585/585 and stdlib sweep 0 failures.

The headline numbers are unchanged and expected to stay so until the tiers
collapse: trivial instruction 2.09/2.10/2.11 ns against a 2.10 baseline,
cheapest activation 46.75/46.92/47.20 ns against 46.3.

### Resolution without representation: the headline numbers do not move

Measured on the ReleaseSafe harness, `scripts/headline-costs.sh`, three runs,
take the minimum:

| number | baseline | now |
|--------|---------:|----:|
| trivial register-to-register instruction | 2.10 ns | **2.09 ns** |
| cheapest activation | 46.3 ns | **46.27 ns** |

Unchanged, and that is the expected reading rather than a disappointment.
Every site bound this far changes WHICH target an instruction names, not what
executing one costs: the dispatch is still the same switch over the same
union, the activation still carries the same argument carrier and keepalive
entries, and the five tiers still each hold their per-`Func` verdict byte.
These two numbers are what the tier collapse and the stack rewrite move, and
the plan orders them after resolution for exactly this reason — they cannot
move until the base path stops being chosen per function and the frame stops
holding resolution state.

Recording them now sets the before side honestly, from a tree whose
resolution work is real but whose representation is untouched.

### `CallValueOrMember`'s residual, proved from both sides

The invocable-local rule takes this kind from 76 248 to 4 393 corpus-wide.
What is left was then attacked from the opposite direction — a local whose
declared type is a class with no `invoke` cannot take the call either, so
the member is the only candidate and the value path can decline outright.

It binds nothing. Neither does deriving the local's type from its
initializer. Both fail on the same fact the decline census already named:
`localDeclType` returns null for these locals, so there is no type to test
in either direction. 18 515 of the consultations on
`examples/compose_todo.kt` have no declared type against 40 that have one
and fail it.

That is a clean handoff rather than a wall. The variant needs exactly one
thing — a recorded type for a local — and it is the same producer the goal
names as "a function value's type". Nothing else stands in front of it, and
with it the kind reaches zero and the variant leaves the union.

### Declining is a binding decision too

The mirror rule looked safe: a local typed `Int` cannot be invoked, so the
same-named member is the call's only candidate, and the value arm should
step aside. Both producers were made to `return null` so the ladder would
reach the member arms. `call_value_or_member` went 3 -> 1 on
`examples/collections.kt` and 21 -> 17 on `examples/compose_todo.kt`, and
**54 corpus programs failed** with `Vm::call_value on kotlin.Boolean`.

The ladder's fall-through does not go to the member. It emits a plain
`CallValue` on the very local that was just proved uninvocable. So
withdrawing an arm is not neutral — the arm below it carries its own
assumption, and here that assumption was the opposite one.

The rule is right and the mechanism is wrong: closing these needs the
member path reached EXPLICITLY, not the value path declined. Two other
things this cost confirming: `localDeclType` does answer `Int` for the
spliced parameter, so the type was never missing; and
`classHierarchyDeclaresMember` cannot be asked whether an intrinsic
classifier declares `invoke`, because an intrinsic-backed class answers yes
to every member query — right for dispatch, useless here.

### The sweep prints two censuses, and they look alike

`scripts/site-census-sweep.py` prints static SITES and then executed
DISPATCHES, and the rows have the same shape: a count, a kind, a percentage,
a program. The executed block's percentage is that program's SHARE of a
corpus-wide total, not its own count.

Reading a row from the wrong block turned "520 executions corpus-wide, 3.8%
of them from `select_and_semaphore.kt`" into "520 sites in that program",
and comparing it against a single-program static count of 7 produced a
reported 520 -> 7 that was an artifact end to end. The static totals
bracketing that change are identical — 3 334 715 and
`call_value_or_member` 1 897 both sides — and the program itself reads 7
with the change and 7 without it.

Two misreadings of this file in one session, the other a hand-rolled parse
that took a per-program row for a total and failed the next gate by 948.
Quote a number from it with the section header checked, and record ceilings
with `--write-ceiling` rather than a regex.

### Accounting for a local's receiver, continuation and context block

Withdrawn. The reasoning holds — the lowered head spells only the value
parameters, an extension receiver goes in ahead of them, `suspend` adds the
continuation behind, and a `context(...)` block flattens into the front, so
`block: suspend CoroutineScope.() -> T` reads as `Function0` and is called
with one argument. It binds zero sites corpus-wide on either census, so it
is out with the rest of the measured negatives.

### Where the residual is, named

`KLIO_SITE_NAMES=<kind>` reports the identifiers the unresolved sites of a
kind resolve by. On `examples/collections.kt`, after this campaign:

| kind | top names | what stands in front of them |
|------|-----------|------------------------------|
| `call_member_by_name` 902 | `get` 261, `compareTo` 168, `toString` 67, `append` 63 | a host classifier owns them and `builtinValueHead` already records, in the code, that widening it past the array heads sends sites back to the by-name walk |
| `field_read_by_name` 394 | `first` 97, `last` 94 | NOT the range property — a range read resolves (`own_cls=IntRange`). These carry `own_cls=<none>`: no receiver class at all |
| `call_value_or_member` 1 | — | the composable boundary, where the MEMBER's declared arity carries composer parameters the call site does not pass |

The two large kinds meet the same wall from opposite sides. A host
classifier has members but no table to name them from; an untyped receiver
has a table but no class to look in. Both are representation, not lookup,
and the plan already orders representation after resolution.

What this campaign did reach was everything in front of that wall: six
host-backed property names, the super chain, the invocable-local question,
and four silent bugs where a value was computed and discarded. What it did
not reach is a variant leaving the union, and the reason is that no variant
is bounded by the work above the wall alone.

### The classless receivers are function-typed, not type-parameter-typed

The plan lists "a type parameter resolved to its upper bound" as producer
work, with `registry.TypeParamBound.head_only` existing for precisely that
and nothing consulting it. Both halves are true and the conclusion does not
follow.

Consulting it moves nothing. At the lowering consumer it bound zero sites;
taught to the register lattice's `LoadParam` arm — where receivers are
actually named — it bound **two of 5 389 asks**. The reason is in the same
counter: the heads reaching it are `Function1` 2 340, `Function2` 1 010,
`Function3` 702. They are not type parameters. `tyOfHead` returns null for
them because no `FunctionN` classifier exists in the class table, so every
function-typed PARAMETER is a classless receiver and the bounds machinery
never applies.

So the producer for this population is not bounds. It is that the function
classifiers are absent from the table, and a member call on a function value
— `invoke`, or an extension over it — has no owner to resolve against. That
is a representation question, and it is upstream of both large by-name
kinds.

### Computed, then discarded

Two of the four finds were not missing information. klio derived the right
answer and threw it away before anything could read it.

`loweredOwnedLocalTypeRef` calls `decl.loweredTypeRef`, which spells a
function type `FunctionN`, and then overwrites that head with the resolution
meant for mangled nested classes and scope renames — neither of which a
function type has. The arity was computed and replaced with `<function>`.

The lowered head then spells only the VALUE parameters, while the call
passes an extension receiver ahead of them, a continuation behind when the
type is `suspend`, and a flattened `context(...)` block in front. The AST
type records all three and the lowered one records none, so
`block: suspend CoroutineScope.() -> T` reads as `Function0` and is called
with one argument.

Both are worth more than their kind: every rule that asks what a local holds
reads these, and both failures are silent — a head that says `<function>`
or the wrong arity looks like an answer. The lesson for the remaining kinds
is that "the producer does not exist" and "the producer exists and the value
is dropped on the way out" are indistinguishable from the census, and only
the second is cheap to fix.

### Follow one site inward

Every conclusion reached by reasoning from the outside about what klio "must
be missing" was wrong, and each was disproved by a measurement that took
minutes:

- "the packs are stale" — rebuilding every pack moved five sites
- "there is no executable-declaration index" — the table answered
  `hasBody=true` once two earlier fixes landed
- "the local's type is not recorded" — `localDeclType` answered `Int`
- "splice renaming hides the parameter name" — it does not; the name matched

Every conclusion reached by taking ONE site from the census and walking it
back to the code that produced it was real:

| site | what the walk found |
|------|---------------------|
| `Operation.objectParamName` | the member table is keyed by `Class.name`, and two `Operation`s are collision-mangled |
| `super<ArrayList>.add` | a bodyless target settles onto a native that re-dispatches on the receiver's class |
| `content/2 arity 0` | a composable call runs two arguments past the declared arity |
| `fib` | `loweredOwnedLocalTypeRef` overwrites `FunctionN` with `<function>` and loses the arity |

The instrument that makes this cheap already existed for three of the four:
the census names the kind, an audit names the emitting arm, and a decline
trace names the condition. The rule is to spend the minutes on the walk
rather than on the hypothesis.

### Session: what closed and what it cost

| kind | before | after |
|------|-------:|------:|
| `call_super_by_name` | 6 289 | 336 |
| `call_value_or_member` | 76 248 | 4 393 |
| total unresolved | 4 111 230 | 3 338 628 |

Four mis-bindings were caught before shipping and five arms were reverted for
binding between zero and five sites each. No variant left `Inst`: the nearest
candidate is `CallValueOrMember`, whose residual is one shape — locals whose
type nothing recorded — and `CallSuper`, which turned out not to be a
deletion at all.

### The name question, answered where it is asked

A third of the unresolved census was one question asked three ways: is
this bare name a member of an implicit receiver in scope, or a top-level
declaration? `LoadFromThisOrGlobal` (238 837), `CallMemberOrGlobal`
(516 985) and `StoreToThisOrGlobal` (38 567) each ran that walk at run
time over whatever values the frame held. Kotlin answers it from
declarations alone, innermost receiver first, and the emitter holds every
input: the spliced subjects with the heads recorded at the splice, a
closure's receiver tower recorded at its construction site, the
declaration's own receivers, the enclosing classes, and each class's
hierarchy member set — which the class-graph probe shows is complete for
97–98 % of classes.

`src/ir/lower/expr/implicit_walk.zig` runs the walk once, at the site,
and returns one of three verdicts. `member` names the receiver register
and class, and the site binds a `GetField`/`SetField` with the class as
its slot claim or, for a call whose class names a sole declaration at
that arity, the call in the form its dispatch allows — direct for a
private or final declaration, which has no slot, else the slot. `global`
means every receiver in scope has a known, complete hierarchy and none
declares the name: a read becomes `LoadGlobal` with the index's pick, a
write `StoreGlobal`, a call the committed declaration — only where it is
the sole candidate and has a body, because the deferred form's global
leg re-ranks overloads by value and resolves a bodyless declaration by
name. `undecided` names the input the emitter lacked, and only then is
the deferred instruction emitted. `KLIO_WALK_PROBE=1` prints one row per
verdict with the walk's whole state, single-line because the body pool
interleaves anything longer.

Wired into every producer of the three instructions except the two the
next section names, the walk moved, corpus-wide and cold:

| kind | before | after |
|------|--------|-------|
| `name_read_this_or_global` | 238 837 | 140 898 |
| `name_write_this_or_global` | 38 567 | 21 973 |
| `call_member_by_name` | 737 666 | 693 872 |
| `recv_enclosing_push` / `pop` | 185 977 each | 177 205 each |
| `name_read_global_by_name` | 239 352 | 276 510 |
| `call_member_or_global` | 516 985 | 554 836 |
| total | 3 034 736 | 2 936 822 |

The two rises are moves, not losses. Property reads the walk proved
global are `LoadGlobal` by name until a top-level property has a slot
(below). And the spliced-call arm the walk replaced bound a name past an
inner receiver that declares it — as an overload set, or through a head
that was only a hint — to an outer receiver's sole declaration, which
Kotlin never does; the sound walk leaves those to the argument-type
question, so they surface in `call_member_or_global` where they belong.

### What the walk needed that the emitter had wrong

Every corpus failure the walk exposed was an input recorded as a fact
that was a hint, or not recorded at all. Each is fixed at its producer,
and the rule each taught is the one to keep:

1. A spliced subject's head is a fact only from the call site's
   span-keyed record for that lambda or from the subject expression's
   static type. The by-name table is keyed on the callee's PARAMETER
   name and collides across nested splices — `rotate(…, block:
   DrawScope.() -> Unit)` answered for `with(drawContext, block)` — and
   the inherited enclosing window's head is a ranking hint. Both are now
   recorded with `SubjectBind.head_hint`, which the walk reads as unknown.
2. A lambda whose receiver shape is still unknown records no tower;
   an empty tower says "no receiver in scope" to a walk, and
   `implicit_receiver_tower_known` tells the two apart.
3. The closure tower carries the subject binds in scope at construction,
   innermost first, so a closure built inside `with(x) { }` sees `x`.
4. A class's property surface lives only in its hierarchy shadow set —
   the class row lists methods — so a class without one, anywhere on the
   chain, is incomplete, never empty. `State.getValue`'s `value` was
   called global for exactly this.
5. A simple name several classes share resolves to no class. A
   first-wins pick answered for the wrong `State`.
6. `localDeclType("this")` — the smart-cast narrow `if (this is T)`
   records — describes the declaration's own `this`, and a splice window
   rebinds `this` without touching it; it is read only in a plain body.
   A `this` bound to a register that is neither the innermost subject's
   nor the captured one is unknown.
7. A member found by arity alone never takes a call from a top-level
   namesake: Kotlin ranks the member first only when its parameter types
   accept the arguments, which is the question the walk cannot see. A
   member's `assertLists` recursed into itself before this rule.

The one runtime asymmetry a decision exposed is closed as well: a class
value invoked with receiver syntax is its constructor with the receiver
as the leading argument on every path, not only the member-or-value
fallback — `::Char` passed as `Int.() -> Char`.

### The residual, by what it needs

On `compose_foundation_lazy`, cold, the undecided rows group by reason:

| reason | rows | the missing input |
|--------|-----:|-------------------|
| `own_receiver_unreachable` | 1 813 | inside an extension splice the declaration's own receiver has no register; binding `this@Owner` at splice entry gives the walk one |
| `member_arity_unproven` | 1 276 | the receiver declares the name as an overload set or a property; the member resolver's applicability by argument shape, already run for explicit receivers, decides it |
| `head_unresolvable` | 1 000 | heads naming no class: type aliases, pack FQN spellings, function types |
| `outer_class_declares` | 192 | an enclosing class declares it and no register holds its instance; a `QualifiedThis` with a static nesting depth resolves this and `recv_qualified_this` together |
| `hierarchy_incomplete` | 57 | pack classes restored without a shadow set |

The global arm is the other half. A top-level property read is
`LoadGlobal` by name because the instruction can carry a function or a
class identity and not a property's: the module can number its top-level
properties at build, the root define can fill the slot beside the name,
and `LoadGlobal`/`StoreGlobal` can carry the slot. That resolves the
276 510 `name_read_global_by_name` sites the walk hands it, and it is
the next producer step.

### The checker's expression typing, and what its tables exposed

The producer side landed whole: the checker types member calls against the
receiver's instantiated signatures (`receiverSubst`, `instantiateSig`,
`projectGeneric`), infers generic calls with receiver constraints and lambdas
checked inside the session (`inferCallReturnWithArgs`), types bare names
against the implicit receivers' members and extension properties, reads the
image's classes, extensions and top-level functions as declarations
(`publishExternDecls` → `externClassInfo`/`externFnSig`), and infers top-level
property types. On `examples/ktor_content_type_by_extension.kt` the recorded
type heads went 79 737 → 89 237; untyped member-call tails 3 027 → 1 996;
unresolved `Path` 14 161 → 11 811, `Member` 6 347 → 4 725, `Call` 5 806 →
3 339, `Index` 3 004 → 1 961. Every `KLIO_TC_<NAME>=0` and `KLIO_EAGER_*=0`
switch that bisected this is documented in `docs/development/debugging.md`.

Three failures followed, and none was in the checker's tables. Each was a
lowering decision the tables newly enabled, and each is fixed where the fact
was missing:

- A receiver head made `AtomicAwaitersCount.incrementCountAndGetVersion`
  splice into `AwaiterQueue.addAwaiter`, whose `newValue.count` read then ran
  in the caller's frame; the runtime's owner-keyed walk found no
  `AtomicAwaitersCount` and died with `get_field count on kotlin.Int`. A read
  the enclosing class resolves to its own member-extension property is now a
  `CallMember` bound to the getter's FuncId with the declaring instance as
  its dispatch receiver (`memberExtPropGetterRead`). For that the getter has
  to exist when the class bodies lower, so `registerMemberExtPropHeaders`
  reserves every member-extension getter's header before the bodies and the
  accessor is placed into it, and the accessor carries `kind =
  .member_extension`, which is what the resolved-call route and the flat
  activation gate key on.
- The checker read `indices.reversed()` inside `CharSequence.indexOfLast` as a
  package-qualified `reversed()`: nothing in scope named `indices`, so the
  member arm's package heuristic fired and resolved it against the implicit
  `CharSequence`, recording `CharSequence` for the call; the for-loop then
  bound `kotlin.text.iterator` on an `IntProgression`. A qualified path is
  read as package-qualified only when its head is a known package root
  (`Checker.package_roots`: the checked files' packages and imports, and the
  image's packages via `ExternDecls.package_roots`).
- `compose_foundation_lazy`: `LazyColumn`'s `LazyList(...)` call — named
  arguments plus the composer ABI — resolves only through the checker's pick,
  and the guard added to `eagerPinnedResolution` refused it because
  `LazyList` was still a header stub when `LazyColumn` lowered. The guard now
  asks `declaredWithBody` (a body, or an AST body still to place), not
  `hasBody()`.

The bound getter read first paid a `QualifiedThis` for its dispatch
receiver, which the census counts as a by-name site, so
`recv_qualified_this` rose by 3 643 while `field_read_by_name` fell. In the
owner's own method or accessor body the innermost `this` already is the
owner's instance — no extension receiver, splice receiver of another class or
receiver-lambda subject rebinds it — and `lowerMemberExtensionDispatchReceiver`
now hands that register over directly, for member-extension function calls as
well; the kind ends 5 139 below HEAD.

Measured, ReleaseSafe harness, cold `.klio-local`: corpus 587/587 (was
574/586 with the twelve compose examples failing on the first item), the
stdlib commontest sweep 149 files / 0 failures (was 8, the `time` tests), the
compose runtime suite in that sweep at 100%. `examples/member_extension_property_splice.kt`
pins the first two shapes.

Site census, cold, both binaries over the same 587 programs
(`scripts/site-census-sweep.py --cold`, HEAD `d4755d9e` against this tree):

| verdict | HEAD | now |
|---------|-----:|----:|
| resolved | 114 384 271 | 114 473 317 |
| unresolved | 2 893 225 | 2 853 232 |
| dynamic_by_design | 1 508 604 | 1 508 667 |

The unresolved kinds that moved:

| kind | HEAD | now | delta |
|------|-----:|----:|------:|
| `call_member_by_name` | 648 572 | 627 000 | -21 572 |
| `field_read_by_name` | 557 801 | 550 054 | -7 747 |
| `recv_qualified_this` | 25 245 | 20 106 | -5 139 |
| `call_member_or_global` | 557 261 | 555 596 | -1 665 |
| `recv_enclosing_pop` | 179 002 | 177 732 | -1 270 |
| `recv_enclosing_push` | 179 002 | 177 732 | -1 270 |
| `name_read_this_or_global` | 141 937 | 141 119 | -818 |
| `field_write_by_name` | 50 657 | 50 476 | -181 |
| `call_member_or_value` | 7 005 | 6 837 | -168 |
| `name_write_this_or_global` | 22 023 | 21 868 | -155 |
| `type_instanceof_by_name` | 4 691 | 4 676 | -15 |
| `call_new_instance` | 167 570 | 167 559 | -11 |
| `call_value_or_member` | 1 708 | 1 712 | +4 |
| `name_read_global_by_name` | 276 843 | 276 857 | +14 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | HEAD | now | delta |
|------|-----:|----:|------:|
| `call_static_id` | 3 153 829 | 3 163 811 | +9 982 |
| `call_member_builtin_op` | 1 467 778 | 1 475 664 | +7 886 |
| `field_read_slot_claimed` | 1 971 502 | 1 978 834 | +7 332 |
| `name_read_capture_slot` | 680 151 | 686 509 | +6 358 |
| `call_virtual_slot` | 4 707 632 | 4 713 430 | +5 798 |
| `call_member_resolved` | 16 869 | 21 143 | +4 274 |
| `field_read_prop_slot` | 640 373 | 643 032 | +2 659 |
| `name_read_global_resolved` | 459 369 | 460 645 | +1 276 |
| `name_cell_read` | 248 285 | 249 365 | +1 080 |

The ceiling in `plans/resolution-ceiling.json` is re-recorded from this
run: the program set grew by one, and the ratchet compares only equal sets.

Under `KLIO_REQUIRE_RESOLVED=1` (`scripts/site-census-sweep.py
--require-resolved`, same snapshot, warm): 139 of 587 programs pass, 448
fail (the log's last figure was 133 of 585). That is the strict-mode floor
the next items ratchet from.

`scripts/gate.sh`, run alone on the committed tree: GATE GREEN — the
ratchet at 2 853 232 unresolved sites against the re-recorded ceiling, the
dual-eager commontest sweep 149 files / 0 failures in both modes and
identical.

### A top-level property has a slot

The next producer step the last entry named: the instruction could carry a
function or a class identity but not a property's, so every read of a plain
top-level `val`/`var` was `LoadGlobal` by name and every write `StoreGlobal`
by name. Now the scan numbers each top-level property whose binding is its
own storage — an initializer or an explicit field with one, no accessor,
delegate, `lateinit` or `const` — once per simple name
(`registry.top_level_prop_slots`, imaged so an extending program keeps the
base's numbering), the root `Env` mirrors a numbered binding into a slot
table on every `define` and `assign`, and the two instructions carry the
slot. A read addresses the slot and takes the name path only until the
initializer has bound it — the by-name path is now the initialiser's, not
the reader's; a `var` write lands in the binding and the slot together. A
custom getter or setter, a delegate, `lateinit`, `const val` and a name two
declarations share stay by name, which is what the census still counts.

`examples/top_level_property_slots.kt` pins every shape. Corpus 588/588,
stdlib commontest sweep 149/0.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 114 473 317 | 114 743 273 |
| unresolved | 2 853 232 | 2 746 426 |
| dynamic_by_design | 1 508 667 | 1 511 151 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_global_by_name` | 276 857 | 169 034 | -107 823 |
| `name_write_global_by_name` | 16 260 | 14 762 | -1 498 |
| `type_ctx_load_by_name` | 641 | 642 | +1 |
| `name_write_this_or_global` | 21 868 | 21 871 | +3 |
| `call_value_or_member` | 1 712 | 1 716 | +4 |
| `recv_qualified_this` | 20 106 | 20 110 | +4 |
| `name_member_ref_by_name` | 12 861 | 12 866 | +5 |
| `type_instanceof_by_name` | 4 676 | 4 681 | +5 |
| `type_cast_by_name` | 11 625 | 11 631 | +6 |
| `call_member_or_value` | 6 837 | 6 844 | +7 |
| `field_write_by_name` | 50 476 | 50 496 | +20 |
| `name_build_object` | 29 631 | 29 670 | +39 |
| `name_read_this_or_global` | 141 119 | 141 160 | +41 |
| `call_new_instance` | 167 559 | 167 830 | +271 |
| `recv_enclosing_pop` | 177 732 | 178 013 | +281 |
| `recv_enclosing_push` | 177 732 | 178 013 | +281 |
| `field_read_by_name` | 550 054 | 550 493 | +439 |
| `call_member_by_name` | 627 000 | 627 509 | +509 |
| `call_member_or_global` | 555 596 | 556 195 | +599 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_global_resolved` | 460 645 | 569 356 | +108 711 |
| `name_read_param_slot` | 9 689 771 | 9 702 344 | +12 573 |
| `call_virtual_slot` | 4 713 430 | 4 720 790 | +7 360 |
| `call_static_id` | 3 163 811 | 3 168 051 | +4 240 |
| `call_member_builtin_op` | 1 475 664 | 1 477 983 | +2 319 |
| `field_read_builtin` | 1 173 658 | 1 175 658 | +2 000 |
| `field_read_slot_claimed` | 1 978 834 | 1 980 798 | +1 964 |
| `name_write_global_slot` | 0 | 1 501 | +1 501 |
| `call_new_instance_ctor_id` | 879 882 | 881 367 | +1 485 |

The small rises are the one added program: the census sums every
program's whole module, so a new example brings a module's worth of every
kind. The ceiling in `plans/resolution-ceiling.json` is re-recorded over 588
programs.

What stays by name in `name_read_global_by_name` is the shapes the slot
declines: custom getters (a getter call is their resolved form, once the
accessor's header is reserved before the bodies as the member-extension
getters' are), delegates and `lateinit`, names two packages declare, and the
producers other than the bare property read that load a global by name.

### A custom accessor is a call

The slot entry named what stayed by name first: a top-level property with a
custom getter or setter. Its resolved form is the accessor thunk itself — the
by-name read looked the name up, missed, and ran `__top_prop_get_<name>`;
the by-name write ran `__top_prop_set_<name>` with the value. Both thunks
lower in `lowerTopLevelProps`, after every body, so a site could not name
them; now `registerTopLevelAccessorHeaders` reserves each thunk's header
before the bodies, keyed by the accessor's own span, and the thunk is placed
into it. The read is `Call` with no arguments, the write `Call` with the
value. An accessor with context parameters, a name two declarations share
and a file-private rename stay by name.

So does a property the host implements under its FQN, and that rule was
found the expensive way: `COROUTINE_SUSPENDED` has a Kotlin getter and a
host intrinsic, every by-name read found the host's binding and the getter
never ran, and calling it directly handed the coroutine machinery a
different sentinel — fourteen coroutine and flow examples and seven
commontest files failed on it. `stdlib.declarationHostSymbol` decides at
the header pass, the same query a function header answers.

`examples/top_level_property_slots.kt` covers the getter (`computed`) and
the setter (`guarded`); its output is unchanged. Corpus 588/588, stdlib
commontest sweep 149/0.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 114 743 273 | 114 744 068 |
| unresolved | 2 746 426 | 2 745 631 |
| dynamic_by_design | 1 511 151 | 1 511 151 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_global_by_name` | 169 034 | 168 237 | -797 |
| `name_write_global_by_name` | 14 762 | 14 760 | -2 |
| `call_member_by_name` | 627 509 | 627 513 | +4 |

The reads went to `call_static_id` (+795). A small step in sites: few
top-level properties in the corpus's libraries have a custom accessor. It
is a whole shape leaving the by-name path, which is what the count of
producers measures, and it is the mechanism (a header reserved before the
bodies, a thunk placed into it) that the remaining accessor shapes reuse.
The `call_member_by_name` +4 is not this change — no member-call emission
moved — and stays unexplained here. The ceiling is re-recorded.

### A class in value position inside a receiver context

After the slot and accessor steps, the emit audit still showed thousands of
`LoadGlobal` rows from `tryTopLevelPropRead` — and the probe on one of them
(`HEX_DIGITS_TO_LONG_DECIMAL`) showed the slot attached. The audit labelled
a slotted read and a by-name read alike; it now says `LoadGlobal/slot` and
`LoadGlobal/class` apart from `LoadGlobal`, and with that the by-name reads
on `compose_foundation_lazy` were `class_name_value` 756 and
`multi_seg_head` 614, both class names in value position.

The second already carried its class. The first went by name because
`scopedClassIdForRead` refused every read in a receiver context: "an
unknown owner chain may still see a nested classifier the flat index cannot
rank". The hazard is real for a receiver the emitter cannot see; it is not
a reason to decline where every receiver is known. The implicit-receiver
walk already enumerates exactly those receivers, so it grew a `classifier`
kind: a receiver declares the name when its class chain nests a classifier
of it (`classDirectChild` up the supertypes), the answer is complete when no
class on the chain is a stub, and the verdict decides the read — the nested
class when a receiver nests one, the scope-ranked class when none does, by
name only when the walk cannot see a receiver. On the lazy example the 756
became 714 with a class and 42 by name.

What is left by name there: host intrinsics loaded as values
(`compareValues` under `alias_global_no_overload`, `COROUTINE_SUSPENDED`),
class reads the walk could not decide (`Recomposer$State` from a lambda
whose receiver it cannot see — the index itself ranks the name), and
private properties declared under one simple name in several files (`lock`,
`EmptyIntArray`), which the slot rule leaves ambiguous.

A `const val` whose initializer is not a literal (`MAX_MILLIS = Long.MAX_VALUE / 2`)
is bound like a stored property and now takes a slot like one.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 114 744 068 | 114 829 440 |
| unresolved | 2 745 631 | 2 660 259 |
| dynamic_by_design | 1 511 151 | 1 511 151 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_global_by_name` | 168 237 | 82 865 | -85 372 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_global_resolved` | 569 356 | 654 728 | +85 372 |

Corpus 588/588, stdlib commontest sweep 149/0. The ceiling is re-recorded.

### The checker's tables never reached a program run on an image

`CallMemberOrValue` was next on the list: nine sites and one producer on
`examples/collections.kt`, 6 844 corpus-wide. The producer emits it for
`recv.name(args)` when a local, parameter or captured outer is also named
`name`, and it was asking the wrong question. A local competes for a call
with an explicit receiver only when its type is an extension function type
or a class with an extension `invoke`; the guard excluded function-typed
parameters written without a receiver and nothing else, so `indication:
Indication?` competed with `Modifier.indication(...)`, `until: Int` with
`0.until(n)`, and every `colors: SliderColors` with `SliderDefaults.colors()`.
The local's declared type decides now, a nested class found under its
registered row, a class's `invoke` counted only with an extension receiver.
The other half was the receiver-lambda parameter whose receiver DOES
declare the name at another arity (`updater.update()` with
`Updater.update(value, block)` the only member): the resolver had already
refuted every member for the call shape, so the refutation rides the
`Fallback` and settles it, with a type-parameter receiver read through its
bound. On `examples/compose_material3.kt` the sites went 206 to 46.

The remaining 46 were all locals of unknown type or receivers of unknown
type, and reading them back found the fact that mattered. The trace showed
`recv_eager=no_map` for the user program: the checker's type table, receiver
heads, parameter shapes and call picks were all computed for the program
and then never adopted. A cloned or fresh module takes the thread's pending
tables in `Module.init`; a program run on a loaded image extends the base
in place through `adoptBuiltForRun`, and nothing took them. Every warm run
lowered the user program on the AST derivers alone, and every cold run had
them. The build adopts the tables for an owned base now, `adoptPicks`
merges instead of replacing so a base's republished picks survive the
program's, and a run discards a previous program's pending tables before
publishing its own.

Two more facts were missing on the producer side. A local initialised by a
literal (`var crossAxisSize = 0`) recorded its initialiser and not its
type; it records `Int`. And a generic call whose type argument is solved
from a lambda's result (`remember { FocusRequester() }`) stayed unsolved:
the checker models a user class as `Unresolved` and refused an `Unresolved`
solution as "an unknown is no solution". The unknown now carries its name
from the call that produced it, a named unknown IS a solution, the join of
two differently named ones is nameless, and a local initialised by such a
call takes the checker's head where the derivers have none.

`val block = this` inside `(R.() -> T).f()` is a receiver-function value
and is marked as one; the receiver-function locals ride the same
inheritance into nested lambdas as the receiver-lambda parameters do.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 114 829 440 | 114 878 686 |
| unresolved | 2 660 259 | 2 648 606 |
| dynamic_by_design | 1 511 151 | 1 514 492 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_member_or_value` | 6 844 | 648 | -6 196 |
| `field_read_by_name` | 550 493 | 544 990 | -5 503 |
| `call_member_by_name` | 627 513 | 625 480 | -2 033 |
| `field_write_by_name` | 50 496 | 50 245 | -251 |
| `name_write_this_or_global` | 21 871 | 21 846 | -25 |
| `call_new_instance` | 167 830 | 167 829 | -1 |
| `name_read_global_by_name` | 82 865 | 82 949 | +84 |
| `name_read_this_or_global` | 141 160 | 141 256 | +96 |
| `recv_qualified_this` | 20 110 | 20 287 | +177 |
| `call_member_or_global` | 556 195 | 556 814 | +619 |
| `recv_enclosing_pop` | 178 013 | 178 703 | +690 |
| `recv_enclosing_push` | 178 013 | 178 703 | +690 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_static_id` | 3 168 850 | 3 174 629 | +5 779 |
| `field_read_slot_claimed` | 1 980 798 | 1 985 568 | +4 770 |
| `field_read_prop_slot` | 643 704 | 645 584 | +1 880 |
| `call_virtual_slot` | 4 720 786 | 4 722 627 | +1 841 |
| `field_read_getter` | 243 117 | 244 550 | +1 433 |

The census is cold, so it never saw the warm-run gap: every warm run
now lowers with what a cold run always had. Corpus 588/588, stdlib
commontest sweep 149/0, and the ceiling is re-recorded at the new count.

### The walk answers a bare call, and a closure reaches the receivers behind its `this`

The three biggest by-name kinds all wait on one fact: which receiver in
scope a bare name binds. The walk had it for a receiver that declared the
sole callable of an arity; every other site went to the runtime's chain.
Measured on `examples/compose_foundation_lazy.kt` cold, the deferred bare
call (`unresolved_bare_call`, 3 803 sites) never asked the walk at all, the
committed-global form (`bare_call_member_shadowable`, 2 967) asked and threw
the member verdict away, and the undecided reasons were, in order,
`closure_tower_unknown`, `head_unresolvable` (942 of them the head `T`),
`own_receiver_unreachable`, `member_arity_unproven`, `tower_outer_declares`.

Four producers changed. The walk carries the call's argument shapes: a
receiver that declares the name binds the call when the member resolver
finds a member accepting them, is passed over when every member refuses
them, and binds through the extension resolver when an extension of the
name fits; the member verdict lowers on the receiver's register through the
resolved-member ladder, the extension verdict through `this@<label>`. A
head resolves through the owner-class ladder the explicit-receiver path
already ran: a type parameter reads through its bound, a shared simple
name through the file's imports, a nested class through its qualified
suffix. A subject bound by a splice and a plain method body carry the
`this@<label>` their splice or body bound, and a closure reaches a receiver
behind its captured `this` by capturing the label. And a trailing lambda
every namesake candidate agrees is receiverless records that, so the
closure's tower is complete.

Three of those were wrong the first time, and the corpus said so. A head
`T` in a closure's tower is the callee's type parameter recorded off its
signature, not the parameter of that name in scope, and reading it through
the in-scope bound bound `size` inside `compareProperty { size }` to
`Any`: a type-parameter-shaped tower head stays unknown, and a member's
`T.() -> R` block now records its receiver instantiated by the implicit
receiver's arguments. `this@let` names the innermost `let`, so a label a
nearer receiver also carries is no path to the farther one. And the tower
listed the receiver of `x.let { scope -> }` as a receiver of the block,
where the block takes it as a parameter and the resolve window hides it:
the runTest examples captured `this@let` and read a `TestScope` member off
`Unit`. The tower lists only the subjects `this` reaches, each further one
being the `this` the nearer displaced, and drops the splice-head entry that
duplicated a hidden subject.

A walked read is spelled with its declaring class, as every bare own-member
read is, and a private accessor binds outright: the getter link names it
ahead of the family slot, because no subclass redeclares a private property
and a same-named private one below is another declaration. That is what
`interface_private_shadow_async` tests, and the `GateBase.closed` field
had answered for `Gate.closed`'s getter until then. Member accessors record
their visibility for it.

On the lazy example, cold: `LoadFromThisOrGlobal` 4 402 -> 3 223,
`CallMemberOrGlobal` at the deferred bare call 3 803 -> 2 997 and at the
splice walk 1 254 -> 515, with 1 391 + 484 + 301 sites now direct or
virtual calls and 1 819 walked reads.

The getter link had been finding an accessor by scanning the function
table per read, and with the walk emitting reads for every receiver that
scan was most of a cold compose bake (`compose_material3.kt` cold 12.5 s
at the campaign start, 17.3 s with the walk, 6.9 s through the name
index). The index sees what the scan did not: a base class's accessor on
a run over an image. Two things that had never been asked of it then
failed at once. Member accessors were not indexed at all, only extension
ones, so `super.isActive` in `AbstractCoroutine` walked past `JobSupport`'s
getter to the `CoroutineContext.isActive` extension and recursed; every
accessor thunk is indexed now. And an accessor reserved as a header and
placed is indexed twice under one id, which read as two declarations.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 114 878 686 | 115 209 838 |
| unresolved | 2 648 606 | 2 493 490 |
| dynamic_by_design | 1 514 492 | 1 514 600 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_member_or_global` | 556 814 | 421 647 | -135 167 |
| `name_read_this_or_global` | 141 256 | 115 968 | -25 288 |
| `call_member_by_name` | 625 480 | 621 931 | -3 549 |
| `name_write_this_or_global` | 21 846 | 19 303 | -2 543 |
| `field_write_by_name` | 50 245 | 50 173 | -72 |
| `call_new_instance` | 167 829 | 167 828 | -1 |
| `recv_qualified_this` | 20 287 | 20 434 | +147 |
| `name_write_global_by_name` | 14 760 | 15 095 | +335 |
| `name_read_global_by_name` | 82 949 | 83 511 | +562 |
| `field_read_by_name` | 544 990 | 546 450 | +1 460 |
| `recv_enclosing_pop` | 178 703 | 183 203 | +4 500 |
| `recv_enclosing_push` | 178 703 | 183 203 | +4 500 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_virtual_slot` | 4 722 627 | 4 816 822 | +94 195 |
| `call_static_id` | 3 174 629 | 3 215 856 | +41 227 |
| `field_read_getter` | 244 550 | 264 875 | +20 325 |
| `name_read_capture_slot` | 687 330 | 705 691 | +18 361 |
| `field_read_prop_slot` | 645 584 | 648 850 | +3 266 |
| `field_write_slot_claimed` | 222 087 | 224 506 | +2 419 |
| `name_read_global_resolved` | 654 816 | 656 454 | +1 638 |
| `name_cell_read` | 249 159 | 250 456 | +1 297 |

Corpus 588/588, stdlib commontest sweep 149/0, and the ceiling is
re-recorded at the new count. The `EnclosingPush`/`Pop` rise is the
receiver-formed splice of lambdas whose receiver the consensus rule now
names; those pairs come out with the variant.

### `Any`'s members are every receiver's

The open constructions on the lazy example, listed by class with the
`[ctor-why]` probe now printing the argument heads it compared, were mostly
`args=?`: a head the deriver could not name. A third of those were
`x.toString()`, `x.hashCode()` and `x.equals(y)` on a receiver whose type the
checker had not settled. The receiver's type does not matter for these
three: `Any` declares them, every class inherits them, and Kotlin lets no
override change the result type. The checker's call typing and the lowering
deriver both answer them before the unresolved tail.

| lazy example | before | after |
|---|---|---|
| `[ctor-pick-link]` open | 703 | 435 |
| checker `[UNRES-KIND] Call` | 10 598 | 10 305 |

The census's `[site-name]` rows for a construction now name the class rather
than `<init>`, which is what made the list above readable. 588/588 corpus,
149/0 sweep.

What is left open there: `ArrayList(n)` and `LinkedHashSet(n)` with an
argument the deriver cannot type, and the compose text classes whose
constructions pass named or defaulted arguments, which `staticCtorPick`
declines outright.

### `CallSuper` leaves the union

An earlier entry here argued the opposite: that a slot claim cannot
express a non-virtual read, because the claim is a hint the runtime
re-proves against the receiver's class and falls back to a by-name read
when the proof fails, and a `super` receiver is by definition a subclass;
and that a super call into a host-backed member is neither a plain `Call`
nor a `CallVirtual`. Both premises were about the instructions as they
were, not about what the language needs, and both are gone.

**A super access is bound where it is emitted, or settled by the link
pass, and nothing walks a chain by name at execution.** In Kotlin's own
order:

- `super.f(args)` is a `Call` to the nearest implementation on the chain
  of the supertype the reference means. Two same-arity overloads, which the
  `(name, arity)` key calls ambiguous by construction, are separated by the
  call's static argument types under the member resolver's scoring; that
  is `placeAt(position, zIndex, layerBlock)` beside `placeAt(position,
  zIndex, layer)`, the shape every layout node's super call has. A named
  argument is proved to be the target's parameter, then rides the call the
  way it does for any exact call.
- `super.toString()`, `hashCode()` and `equals()` on a chain declaring none
  of them are a `CallMember` carrying an `any_*` builtin operation:
  `Any`'s implementation, run on the receiver without dispatch. The
  `any_default` field went with the instruction.
- `super.Inner(args)` is the bare `Inner(args)` construction on this
  receiver, which is what it means.
- A super call into a host-backed base runs on the `__delegate__<Base>`
  cell the instance holds for it, through the resolved member ladder with
  the base's type.
- `super.prop` and `super.prop = v` bind the accessor as a `Call` when it
  exists while the body lowers. When it does not, because the declaring
  class's body has not lowered yet or because the base stores the
  property, the site is a `GetField` or `SetField` of kind `super_target`
  carrying the class the reference resolves against, on a receiver copy in
  the register run a call reads. `linkSuperMembers` rewrites it in place
  into a direct accessor `Call` or into `super_slot`: the base's declared
  cell, served without dispatch and without the value-kind declines a
  claimed slot makes. The evaluator's `super_slot` arm re-proves only that
  the receiver's class chain carries the claimed class, which for a super
  receiver it always does.

The by-name fallback the earlier entry feared is not there to fall to. A
pending access that reaches execution, and a super member lowering could
not see at all, fail where they are reached with a message naming the
member: the only by-name answer to a super access is the override making
it, and that recurses, so a loud failure is the correct form of an
unbound site. The fused evaluator and the JIT, which read fields by name
whatever the kind, run a super-kind access framed.

**What was deleted.** The `CallSuper` variant and its `SUPER_TARGET_NONE`
and `AnyDefault`; `execArmCallSuper`; the host's `callSuper` walk and the
five helpers only it used; `setFieldFrom` and the `super_write_owner`
thread slot the super write travelled on; `linkSuperTargets`; the two
census kinds; the `call_super` dispatch kind. The producers grew: the
overload ranking, the nested-class and delegate arms, and the link pass
that settles accessors are new, and the change is net positive in lines.
The instruction set is one variant smaller, which is the measure.

**Two things found on the way.** Picking the supertype an unqualified
`super` means counted an interface that merely restates a method its
sibling class implements as a second declarer, and declined
`BufferedChannel.trySend` beside `BroadcastChannel.trySend`; only a class
that IMPLEMENTS the member counts. And a super write's qualified bit had
nowhere to live once `own_slot` carried the result register the settled
call writes; it is the register's high bit, and `super<M>@N.y += 200` was
the site that said so.

**A function-local class found the gap the corpus had not.** Its methods
lower at run time, when `RegisterClass` executes, and the class is never in
the class table, so the owner's supertypes were unknown to the binder and
`CollectionTest.abstractCollectionToArray`, whose `super.toArray()` runs in
a class declared inside the test, threw the unbound error. The declaration
lists the supertypes; `ownerSuperHeads` carries them into the member
lowering, and every super helper searches candidate classes rather than a
class-table hit on the owner. With that, the emit-time property path asks
the same question the link pass does, `superMemberAmong`, and binds the
base's cell directly where the layout is already composed.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this
tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 209 838 | 115 303 552 |
| unresolved | 2 493 490 | 2 401 085 |
| dynamic_by_design | 1 514 600 | 1 514 600 |

| kind | before | now |
|------|-----:|----:|
| `call_super_by_name` | 336 | kind deleted |
| `call_super_any_default` | 1 147 (resolved) | kind deleted |
| `call_new_instance` | 167 828 | 76 113 |
| `call_new_instance_ctor_id` | 881 368 | 973 083 |

The construction movement is the previous commit's, `Any`'s members typed
whatever the receiver, measured corpus-wide here for the first time. The
super sites went to `Call` (an accessor or a chain implementation),
`CallMember` with an `any_*` operation, `NewInstance`, and `GetField` or
`SetField` of kind `super_slot`; the census names no super kind any more.
588/588 corpus, 149/0 sweep, and the ceiling is re-recorded from this run.

### What keeps `recv.local(args)` a `CallMemberOrValue`

`CallMemberOrValue` has one producer and, after the walk, 648 static sites
corpus-wide, most of them in the compose packs. `KLIO_CMV_WHY` prints for
each the local's type and class row, the receiver's, and which of the
three tests declined. Thirty-three distinct shapes across the pack families,
and the reasons sorted into a short list:

- **The class row was asked too late.** `Dp` is two upper-case-led letters
  and the spelling heuristic that guards a type-parameter head took it for
  one; `height: Dp` competed with `Modifier.height`. The class resolves
  first now, and the heuristics apply only where no class does.
- **A nested class lost its qualifier.** `Alignment.Horizontal` lowers to
  its simple name with the qualifier in a `#qual:` marker, and the bare
  `Horizontal` is ambiguous three ways. The receiver-head resolver takes
  the qualified spelling and answers through the qualified suffix.
- **The hierarchy shadow record is incomplete for a nested class.** It
  resolves supertypes by simple name and `OperationArgContainer` is
  collision-mangled between two packages, so every `Operations.OpIterator`
  record is incomplete and `iterator.action()` stayed open. The class row
  holds the supertype ids lowering resolved, so both tests fall back to a
  chain walk over the table wherever the record is absent or incomplete and
  no stub is on the chain.
- **A splice parameter had no type.** `block: T.() -> R` inside its own
  `writable` splice is bound to a register and nothing else; the splice
  records the declared type and the decision now reads it. That exposed
  the first regression of the day: `sync { ... .block() }` inside
  `overwritable` read `sync`'s `block: () -> T`, a plain function type,
  refused the local, and dispatched `block` by name on a `StateStateRecord`.
  The register bindings of a callee are already hidden while a caller's
  lambda body lowers inside it; the parameter types are now hidden the same
  way. The map is name-keyed and cannot hold the outer `block` while the
  inner is bound, so a nested splice's `block` stays conservative, which is
  the by-name form and not a wrong one.

What is left is typing, not deciding: locals initialized by `remember {}`
and by extension calls on typed receivers, whose types neither deriver
names; captured outer locals whose types do not reach a nested lambda
builder; an anonymous object's captures; and a member property of function
type called on `this`. Each is a producer of the receiver's or the local's
type, and each moves every by-name kind, not this one.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this
tree):

| kind | before | now |
|------|-----:|----:|
| `call_member_or_value` | 648 | 508 |
| `call_value_with_this` (dynamic by design) | 38 099 | 38 212 |
| unresolved, every kind | 2 401 085 | 2 401 008 |

The 140 sites became the value call the language names. The same run moved
`name_write_global_by_name` down by 140 and `name_read_global_by_name` up
by 141, with a few dozen more on two other kinds: bodies lower from a pool
and a decision made by pool order moves a handful of sites between runs,
which is a measured variation and not an effect of this change. 588/588
corpus, 149/0 sweep; the ceiling is re-recorded from this run.

### A return nobody wrote down

Of the `CallMemberOrValue` shapes left after the decision fixes, four were
one thing: a local initialized by a call whose callee is an
expression-bodied function with no return annotation, `private inline fun
IntArray.isNode(address: Int) = this[...] and NodeBit_Mask != 0` and its
kin. Every return channel in the deriver requires `return_ty_declared`, and
the placeholder `Unit` an unannotated body records is rightly not a fact.

The on-demand channel already existed for class members: the registered
AST under (owner, name, arity), derived in a throwaway builder seeded with
the receiver and parameter types. A top-level function has no owner a call
site can spell, and the comment beside the `FuncId`-keyed map said as much;
the map was declared and never filled. The header pass now registers every
top-level expression body with no return type under its id, and the two
return arms that gate on the declared flag derive from it: the
member-extension candidate arm for `groups.isNode(x)`, the bare-call arm
for `f(x)`. A braced `if` branch derives as its last expression, which is
what `collapsedFraction() = if (limit != 0f) { offset / limit } else { 0f }`
needed to come out `Float`.

`[ebd] groupFlags recv=IntArray body=Index derived=Int` seventy times on
one program, and `isNode`, `positionChange`, `collapsedFraction` leave the
probe's list. What the same probe shows next: `groups` itself untyped in
one body (`val groups = addressSpace.groups` through a local that shadows a
property), a local typed by an extension call on a property read
(`to.anchor.asGapAnchor()`), `remember { X() }` locals, and the captures of
an anonymous object.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this
tree):

| kind | before | now |
|------|-----:|----:|
| `call_member_by_name` | 621 956 | 612 313 |
| `field_read_by_name` | 546 451 | 544 897 |
| `call_member_or_global` | 421 302 | 421 070 |
| `name_write_this_or_global` | 19 303 | 19 115 |
| `call_member_or_value` | 508 | 527 |
| `call_static_id` (resolved) | 3 216 520 | 3 218 544 |
| `field_read_slot_claimed` (resolved) | 1 986 034 | 1 987 092 |
| unresolved, every kind | 2 401 008 | 2 389 648 |

The measure this was aimed at rose by nineteen, since a receiver that now
has a type exposes a local beside it that has none, `to.anchor.asGapAnchor()`
above. The measure it was not aimed at fell by eleven thousand: a local
typed by an un-annotated callee is a receiver for every call after it, and
those were by name. 588/588 corpus, 149/0 sweep; the ceiling is re-recorded.

### What the derivers miss most, counted

`KLIO_DISPATCH_STATS` now counts every read of a bound local whose type
nothing recorded, by the shape of its initializer, and by name where it
has none. On the compose lazy example, cold, all packs:

| initializer | reads |
|---|---:|
| none (a parameter, `it`, `this`, a loop variable) | 15 466 |
| a call | 7 450 |
| a member read | 6 556 |
| a bare name | 6 366 |
| an index | 1 791 |
| a binary operator | 1 516 |

Of the first row, `it` alone is 2 656 reads and `this` 1 198: lambda
parameters whose type comes from a callee the call could not resolve, the
same fixpoint as everything else. The bare-name row is the shape this
entry closes one case of.

`private val addressSpace = table.addressSpace` beside `val table:
SlotTable` recorded no head, because the inference walk resolved a
receiver only when it named a classifier and `table` names a property.
Three things were missing at once. The walk now reads the owner's own
recorded head for a lower-case receiver. That head is the declaration's
spelling, `SlotTable`, and the rows it keys are under the class's row name
and FQN: a lifted twin, and the compose runtime carries two dozen such
pairs between its gap-buffer and link-buffer packages, registers as
`SlotTable$f1193`, so the bare tail is nobody's key. The head is resolved
in the declaring file's scope, and the member looked up under the FQN
before the tail. With that, `val addressSpace = addressSpace` types
through the own-member snapshot rule, `val groups = addressSpace.groups`
through the member read, and `groups.groupFlags(group)` derives `Int`.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this
tree):

| kind | before | now |
|------|-----:|----:|
| `call_member_by_name` | 612 313 | 608 967 |
| `field_read_by_name` | 544 897 | 543 103 |
| `name_read_this_or_global` | 115 880 | 115 564 |
| `call_member_or_value` | 527 | 478 |
| `recv_enclosing_push` / `pop` | 183 313 | 184 097 |
| `call_member_builtin_op` (resolved) | 1 479 302 | 1 481 311 |
| unresolved, every kind | 2 389 648 | 2 385 737 |

One property head, and the twins' rows found under their own names,
moved four thousand sites. The receiver towers rose by 784: a call that
now resolves through the member ladder inside a receiver lambda carries
the tower a by-name walk did not need, and the tower is the next item on
the list. 588/588 corpus, 149/0 sweep; the ceiling is re-recorded.

### A lambda's shape is settled by the parameter it binds, receiver or none

The walk's largest undecided reason was `closure_tower_unknown`: a bare
name inside a lambda whose receiver shape nothing had settled, so the
body's tower of implicit receivers was unknown and the walk could not
say which of them, if any, declares the name. Counted on
`examples/compose_foundation_lazy.kt` cold, `[lambda-shape] unknown`
fired 3 784 times, and the labels were the calls everyone writes:

| call | lambdas with no settled shape |
|------|---:|
| `forEach` | 340 |
| `remember` | 239 |
| none (a default value, an untyped `val`, a tail) | 191 |
| `forEachIndexed` | 182 |
| `updateScope` | 139 |
| `also` | 136 |
| `let` | 131 |
| `assert` | 88 |

None of these give their block a receiver, and that was the gap: a
lambda argument learned its receiver from the parameter it binds and
learned nothing else. A `(T) -> R` parameter recorded nothing, the block
lowered with `lambda_receiver_shape_known = false`, and the tower behind
its `this` stayed a question. The committed candidate already shaped the
block's arity, its `it`, its broad-collection masks and its composable
slots; its receiver shape is the same fact from the same parameter.

Every site that reads a candidate's parameters now records the block's
shape either way (`recordArgLambdaShape`): the receiver, substituted from
call evidence as before, or `lambdaArgNoRecv` when the parameter is a
plain `Function{N}` with no receiver slot. An alias records nothing, its
arity being all it says. The namesake consensus the deferred bare call
used for its trailing lambda moved to the lambda module and serves three
more sites: the deferred bare call with no single host, the by-name
member call (`emitDeferredMemberCall`, over the candidates that take a
receiver), and any call whose candidates all give the block no receiver.
A constructor's function-typed parameters shape their lambdas the same
way through `ctorArgFnArities`. A default value lowers under its
parameter's declared type, which the param thunk already carried for a
parent constructor's arguments and nothing else. A lambda initializing an
untyped `val` has no receiver by construction, since only an expected
function type can give it one.

Two consumers were wrong the moment the fact reached them, and both had
been carried by the runtime chain.

A member chain headed by a package that some declaration spells
(`child.placeOrder == androidx.compose.ui.node.LayoutNode.NotPlacedPlaceOrder`,
inside `forEachChild { }` inside `with(layoutNode) { }`) flattened to
its FQN only when `this` was out of scope; `isPkgRoot` knows eight roots
and `androidx` is not one, so with the block's `this` now bound the head
read `androidx` off the `LayoutNode`. A head some package declares is as
real as a hard-coded root unless a receiver in scope is proven to declare
it as a member, which the walk answers.

The VM rebound the `this` capture of every closure invoked through a
receiver, the shape `CallMemberOrValue` takes for `transformer(next())`
inside `TransformingSequence`'s iterator. A receiverless lambda survived
that only because the displaced `this` was pushed as an outer implicit
receiver for the by-name walk to find behind the wrong one; once
`subSequence` was bound on the captured register, `windowedSequence`'s
block called it on the iterator. A lambda whose shape is settled without
a receiver keeps the `this` it captured: the value it is invoked through
is the caller's receiver, not the block's.

On the lazy example, cold, the same probe after:

| measure | before | now |
|---------|-----:|----:|
| `[lambda-shape] unknown` | 3 784 | 1 059 |
| walk verdict `member` | 4 426 | 5 489 |
| walk verdict `global` | 5 200 | 5 509 |
| walk verdict `undecided` | 8 594 | 6 853 |
| of which `closure_tower_unknown` | 2 938 | 933 |

The array constructors' `init` block, a host class with no parameters in
the table, is receiverless by the intrinsic's own shape. What is left
under `[lambda-shape] unknown` is, in order: no label (156: class
property initializers and tail-position lambdas), `let` (108: the safe
call `x?.let { }` lowers on its own path), and calls the walk bound to a
member through `lowerWalkedMemberCall`, which shapes nothing
(`withoutReadObservation`, `updateScope`, `remember`, `items`, `layout`). The rise in `outer_class_declares` (406 to 515) is the same
towers, now known, reaching a receiver whose outer class declares the
name, the next question.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 348 242 | 115 462 926 |
| unresolved | 2 385 737 | 2 319 254 |
| dynamic_by_design | 1 514 649 | 1 514 793 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_member_or_global` | 421 168 | 388 704 | -32 464 |
| `name_read_this_or_global` | 115 564 | 87 365 | -28 199 |
| `name_write_this_or_global` | 19 115 | 13 348 | -5 767 |
| `name_read_global_by_name` | 83 548 | 83 225 | -323 |
| `call_member_by_name` | 608 967 | 608 725 | -242 |
| `field_read_by_name` | 543 103 | 543 026 | -77 |
| `name_write_global_by_name` | 15 039 | 15 057 | +18 |
| `recv_qualified_this` | 20 650 | 20 731 | +81 |
| `recv_enclosing_pop` | 184 097 | 184 342 | +245 |
| `recv_enclosing_push` | 184 097 | 184 342 | +245 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_capture_slot` | 705 801 | 739 860 | +34 059 |
| `field_read_prop_slot` | 649 864 | 674 473 | +24 609 |
| `call_virtual_slot` | 4 815 460 | 4 835 994 | +20 534 |
| `call_static_id` | 3 219 888 | 3 235 966 | +16 078 |
| `field_write_slot_claimed` | 224 744 | 229 313 | +4 569 |
| `name_read_global_resolved` | 656 240 | 658 719 | +2 479 |
| `name_write_global_slot` | 1 698 | 2 878 | +1 180 |
| `field_read_getter` | 265 566 | 266 690 | +1 124 |

Sixty-six thousand sites left the by-name kinds, the three that wait on
the tower most of all: the member-or-global call, and the read and write
through `this` or a global. Half the reads became capture-slot reads, a
closure's `this` now a settled register rather than a runtime probe, and
the rest went to property slots, virtual slots and static ids. The
enclosing-receiver pushes rose by 245, the towers those closures now
carry. 588/588 corpus, 149/0 sweep; the ceiling is re-recorded.

### A type parameter's block owns the argument's class

With the towers known, the walk's largest stop moved to
`subject_head_unknown`: a receiver in the tower whose head the
construction site recorded as a type parameter, which the walk rejects on
principle, since `T` there is the callee's and not the one of that name
in scope. On `examples/compose_foundation_lazy.kt` cold, 1 728 walks
stopped there, and 1 181 of them inside a closure whose own receiver was
spelled `T`.

`KLIO_LAR_TRACE` names the writer. Of the 542 receiver records spelled
`T`, thirty came from the resolved call's substitution, which reads the
argument bound to the parameter declared as the bare `T` and gives up when
that argument's static type is itself a type parameter: `with(saver) {
restore(value) }` for `saver: S` where `S : Saver<Original, Saveable>`.
The rest came from the inline splice, which recorded the callee's declared
receiver as written and substituted nothing: `with(density) {
leftDp.roundToPx() }` owned `T`, and so did every `with`, `run` and
`apply` block whose subject the splice seated.

The splice now instantiates the block's receiver the way the resolved
call does, from the argument bound to a parameter declared as that bare
type parameter, and both take a caller type parameter's bound as the
argument's class where the bound names one classifier
(`TypeParamBound.head_only`). Two arguments that disagree, or none that
names it, leave the declared spelling in place as before.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 5 489 | 5 909 |
| walk verdict `global` | 5 509 | 5 580 |
| walk verdict `undecided` | 6 853 | 6 076 |
| of which `subject_head_unknown` | 1 728 | 757 |
| of which with the closure's receiver spelled `T` | 1 181 | 265 |

What is left under `subject_head_unknown` is a subject whose head the
splice never knew (309, `processKeyDownEvent`, `initializeMetadata`,
`createOutline`: the receiver argument's type is underived), a `T`
that no argument names (265, `valueElements`, `measure`, `draw`: a
class type parameter's identity, `Updater<T>.set`, whose instantiation
the call receiver's type arguments would carry), and `U` (67).

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 462 926 | 115 494 549 |
| unresolved | 2 319 254 | 2 303 288 |
| dynamic_by_design | 1 514 793 | 1 514 914 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_this_or_global` | 87 365 | 74 582 | -12 783 |
| `call_member_by_name` | 608 725 | 603 657 | -5 068 |
| `call_member_or_global` | 388 704 | 384 287 | -4 417 |
| `name_write_this_or_global` | 13 348 | 11 959 | -1 389 |
| `name_write_global_by_name` | 15 057 | 14 279 | -778 |
| `type_cast_by_name` | 11 631 | 11 175 | -456 |
| `field_write_by_name` | 50 051 | 50 011 | -40 |
| `type_ctx_load_by_name` | 642 | 629 | -13 |
| `call_new_instance` | 76 064 | 76 055 | -9 |
| `name_read_global_by_name` | 83 225 | 83 229 | +4 |
| `recv_enclosing_pop` | 184 342 | 185 404 | +1 062 |
| `recv_enclosing_push` | 184 342 | 185 404 | +1 062 |
| `recv_qualified_this` | 20 731 | 22 942 | +2 211 |
| `field_read_by_name` | 543 026 | 547 674 | +4 648 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_capture_slot` | 739 860 | 748 613 | +8 753 |
| `field_read_prop_slot` | 674 473 | 682 419 | +7 946 |
| `call_virtual_slot` | 4 835 994 | 4 840 771 | +4 777 |
| `call_static_id` | 3 235 966 | 3 238 861 | +2 895 |
| `call_member_resolved` | 22 043 | 24 272 | +2 229 |
| `field_write_slot_claimed` | 229 313 | 230 811 | +1 498 |
| `field_read_slot_claimed` | 1 988 555 | 1 989 611 | +1 056 |

Sixteen thousand sites left the unresolved kinds. The reads through
`this` or a global fell by twelve thousand, most to capture slots and
property slots, and 4 648 of them became field reads by name: the walk
now names the receiver and its class, and the read carries both for the
link pass to claim, where before it carried a runtime probe. 588/588
corpus, 149/0 sweep; the ceiling is re-recorded.

### The walk resolves a receiver's head in the file's scope

`KLIO_WALK_PROBE` now prints `[head-unresolvable]` with what the class
lookup had: the declaring file, the simple name's candidate count and
the indexed answer. On `examples/compose_foundation_lazy.kt` cold, the
610 `head_unresolvable` stops were, by head: `OperationArgContainer`
250, `WriteScope` 108, `Builder` 23, `Node` 17, `Size` 16, `Vertical`
and `Horizontal` 14 each, then anonymous classes and type parameters.

The first is an `internal` class both changelist packages declare, so
its row is registered under a collision-mangled name and the simple name
has no candidates at all; the walk named a head by FQN, by unique simple
name, and through the explicit-receiver ladder, none of which reads the
file's scope renames a written receiver resolves through. `Builder` is
`AnnotatedString.Builder`, a nested classifier the file imports by name,
which the ladder's lexical-site search does not see either. The walk now
runs `scopeTypeRename` and the exact-import lookup from the declaration's
file, or the body's when the builder has no declaration.

Beside it, a top-level function's default value lowered with no expected
type: `onDragStart: (Offset) -> Unit = {}` gave the block no settled
shape, and its body no tower. A member's default already lowered under
the parameter's declared type; a top-level function's now does, and an
enum entry's constructor argument under the constructor parameter's.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 5 909 | 6 084 |
| walk verdict `global` | 5 580 | 5 604 |
| walk verdict `undecided` | 6 076 | 5 955 |
| of which `head_unresolvable` | 610 | 318 |
| `[lambda-shape] unknown` | 1 046 | 1 002 |

What is left under `head_unresolvable` is a nested classifier's head
recorded as its bare tail (`WriteScope` for `Operations.WriteScope`,
`Vertical` for `Arrangement.Vertical`), which no file scope names: the
lowered type spelling drops the qualifier before the head is recorded,
a producer question for the type lowering. `Size` inside its own
companion's initializers has no file to resolve in, since a property
initializer's builder carries neither a declaration span nor a body span.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 494 549 | 115 494 890 |
| unresolved | 2 303 288 | 2 303 109 |
| dynamic_by_design | 1 514 914 | 1 514 911 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_this_or_global` | 74 582 | 74 334 | -248 |
| `call_member_or_global` | 384 287 | 384 281 | -6 |
| `name_write_this_or_global` | 11 959 | 11 955 | -4 |
| `recv_enclosing_pop` | 185 404 | 185 401 | -3 |
| `recv_enclosing_push` | 185 404 | 185 401 | -3 |
| `call_value_or_member` | 1 716 | 1 719 | +3 |
| `call_member_by_name` | 603 657 | 603 661 | +4 |
| `name_write_global_by_name` | 14 279 | 14 283 | +4 |
| `field_read_by_name` | 547 674 | 547 748 | +74 |

A small move on the corpus: the collision-mangled changelist classes
live in the compose runtime, and the reads on them are the 248 that left
`name_read_this_or_global`. The point is the fact, not the count: a
receiver the walk could not name is one it cannot answer for, and the
same lookup serves every head it sees. 588/588 corpus, 149/0 sweep; the
ceiling is re-recorded.

### A member extension's dispatch receiver is a frame value the caller hands over

With the towers known and the heads named, the walk's largest stop was
`dispatch_receiver_unreachable`: 1 392 sites on the compose lazy example,
every one a bare read, write or call of the owner's member inside a
member extension (`override fun MeasureScope.measure(...)` in
`AlignmentLineOffsetDpNode` reading `alignmentLine`, `before`, `after`).
The body has two receivers and one register. `this` is the extension
receiver, a parameter. The dispatch receiver, the owner instance, reached
the body only through the enclosing chain: every caller pushed it there
before the call, and every read of an owner member walked the chain by
name at run time, a `LoadFromThisOrGlobal` per read.

The inventory of the calling convention put a second synthesized
parameter out of reach for now: some two hundred sites across fifty-five
files compute a receiver offset from `params[0].name == "this"`, and a
second leading parameter moves every one of them. The value the body
needs is nevertheless one the caller already holds, so it is handed over
as a value rather than a name.

Every site that pushed the owner onto the chain for a member-extension
call, fourteen of them across the resolved invoker, the by-name extension
fallback, the named-argument path, the three enclosing dispatchers, the
member-extension property accessors and the evaluator's own `Call` arms,
pushes it as a `dispatch` entry. A frame takes the last such entry among
the caller's in-flight pushes as its `dispatch_this` when it activates,
on the flat and the resumed paths alike, and every walk still sees the
entry as a receiver. The body loads it through one instruction,
`LoadDispatchThis`, emitted at entry, bound as `this@<Owner>` and typed
as the owner, so a closure inside captures it under that slot as it
captures any name. The walk answers an owner member behind an extension
receiver with that register; a sibling member extension's call inside
the body carries it as its dispatch receiver, where it emitted a
`QualifiedThis` walk before; and a member-extension caller of another
forwards its own rather than its extension receiver. A frame no caller
served derives the receiver once from its chain, the derivation the
by-name arms ran per read, and says so under `KLIO_DISPATCH_TRACE`: seven
frames on the lazy example, all found, one call path still to be named.

Two reads had mis-stated their receiver and lived on the runtime's slot
proof failing. A `"$member"` interpolation took a shortcut through `this`
with the lexical owner's class attached whenever `this` was bound; in a
member extension that reads the owner's property off the extension
receiver, in a receiver lambda off the lambda's, and the runtime, finding
the class wrong, fell back to the name and the chain. The census counted
these as resolved. The shortcut now applies only where `this` is the
owner's instance, and the rest go to the walk, which places 156 of them
on the lazy example.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 6 084 | 7 556 |
| walk verdict `global` | 5 604 | 5 590 |
| walk verdict `undecided` | 5 955 | 4 564 |
| of which `dispatch_receiver_unreachable` | 1 392 | 0 |

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 494 890 | 115 549 848 |
| unresolved | 2 303 109 | 2 270 247 |
| dynamic_by_design | 1 514 911 | 1 514 911 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_this_or_global` | 74 334 | 54 274 | -20 060 |
| `recv_qualified_this` | 22 942 | 16 250 | -6 692 |
| `call_member_or_global` | 384 281 | 381 607 | -2 674 |
| `field_read_by_name` | 547 748 | 545 687 | -2 061 |
| `name_write_this_or_global` | 11 955 | 10 644 | -1 311 |
| `call_member_by_name` | 603 661 | 603 589 | -72 |
| `name_read_global_by_name` | 83 229 | 83 237 | +8 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_dispatch_this` | 0 | 24 016 | +24 016 |
| `field_read_prop_slot` | 682 499 | 705 806 | +23 307 |
| `call_static_id` | 3 238 926 | 3 241 322 | +2 396 |
| `name_read_capture_slot` | 748 685 | 750 395 | +1 710 |
| `field_write_slot_claimed` | 230 811 | 232 122 | +1 311 |

Thirty-three thousand sites left the unresolved kinds: twenty thousand
reads through `this` or a global, the owner members read inside member
extensions, now property-slot reads off the dispatch register; 6 692
`QualifiedThis` walks, the dispatch receivers of sibling member-extension
calls, now the register itself; and the calls and writes beside them.
`name_read_dispatch_this` is the new resolved kind, one load per
member-extension body. 588/588 corpus, 149/0 sweep; the ceiling is
re-recorded.

### A context parameter is a parameter

`type_ctx_load_by_name` was the smallest item on the list, 629 sites in
23 kinds, and the plan's own note said it was not a lookup to improve but
a calling convention to stop. A `context(T) fun` read each context
parameter at entry through `CtxLoad`, a search of a thread-local stack
by runtime type, and the stack was fed out of band. `CtxScope` pushed the
values of `context(v...) { }`; `CtxCall` split a fully positional call's
leading arguments onto it; and once a module declared any context
parameter at all (`has_context_decls`), every frame entry with a receiver
pushed that receiver, every closure call pushed its bound `this`, and
every activation and flat call request carried a mark to unwind on exit.
The callee could not name a register for the value, because which
register held it was the caller's property.

The caller hands the values over now, the way it hands over a dispatch
receiver. A call site resolves each context argument statically
(`contextArgOfType`): the innermost `context(...)` scope entry of that
type, then a spliced subject, the declaration's own receiver, the
enclosing receiver a closure captures, and the receiver tower behind
its `this`. The values move into one run and push ahead of the call as
`context` entries on the enclosing chain (`ContextPush`/`ContextPop`),
around every resolved `Call`, `CallVirtual` and `CallMember` emitter,
twenty sites. The frame takes the caller's in-flight `context` entries
as its context slots when it activates, on the flat and the resumed
paths alike, keeps a caller's own slots reachable for a contextual
callee further in, and the body reads each by index (`LoadContextParam`).
Headers carry their context types (`FuncExtra.ctx_types`): top-level and
member functions, default-argument thunks, and now top-level accessors,
which the header pass had excluded, so the contextual `banner` getter is
a `Call` where it was a by-name read that missed and re-ran the thunk.

A lambda bound to a `context(T) (A) -> R` parameter takes its contexts
as leading parameters named `$ctx<n>`, from the expected function type
or the `#ctx:` markers the callee's parameter type carries, and binds
them in its context scope; a literal whose own parameters already cover
them (`fun(g: Greeter, name: String)`) takes them as those parameters,
and an implicit `it` is not a parameter for that count. `context(a, b)
{ }` is a `CallValue` of the block with the values; an implicit
invocation of a contextual function value resolves each context at the
site and passes it; a positional one passes what was written. A frame no
caller served, one reached through a by-name dispatcher, derives the
value once from its enclosing chain and says so under
`KLIO_DISPATCH_TRACE` (`[context-fallback]`), as a member extension does
for its dispatch receiver.

Deleted: the three instructions, their evaluator, exec, disassembler and
census arms (`type_ctx_load_by_name`, `call_ctx_value`,
`call_ctx_scope`), the host context stack and its six entry points, the
`has_context_decls` gate and the pass that set it, the receiver pushes
at the three frame-entry paths and two closure-call paths, `ctx_mark`
and `ctx_armed` on every activation and `ctx_mark_override` on every
flat call request. The image format is 83.

Over the four context examples, the callee derived a value three times,
all at `useContext()` inside a spliced `with(C("OK"))`: the bare call is
a `CallMemberOrGlobal` there, because the splice does not carry the
subject's type into bare-call resolution, and the dynamic dispatcher
cannot hand over what the site did not name. That is the
`CallMemberOrGlobal` item, and the fallback goes with it.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 549 848 | 115 550 576 |
| unresolved | 2 270 247 | 2 269 594 |
| dynamic_by_design | 1 514 911 | 1 514 908 |

The kinds that left the census and the kinds that replaced them:

| kind | verdict | before | now | delta |
|------|---------|-----:|----:|------:|
| `type_ctx_load_by_name` | unresolved | 629 | gone | -629 |
| `call_ctx_value` | dynamic_by_design | 3 557 | gone | -3 557 |
| `call_ctx_scope` | dynamic_by_design | 14 | gone | -14 |
| `name_read_context_slot` | resolved | 0 | 595 | +595 |
| `call_context_push` | resolved | 0 | 23 | +23 |
| `call_context_pop` | resolved | 0 | 23 | +23 |
| `call_value` | dynamic_by_design | 1 470 521 | 1 474 089 | +3 568 |

The other unresolved kinds that moved, all by the contextual sites the
examples hold:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_member_or_global` | 381 607 | 381 589 | -18 |
| `call_member_by_name` | 603 589 | 603 585 | -4 |
| `field_read_by_name` | 545 687 | 545 683 | -4 |
| `call_value_or_member` | 1 719 | 1 716 | -3 |
| `name_read_global_by_name` | 83 237 | 83 236 | -1 |
| `recv_enclosing_push` | 185 401 | 185 404 | +3 |
| `recv_enclosing_pop` | 185 401 | 185 404 | +3 |

The 595 context-slot reads are the stdlib `contextOf` body's own, one per
program, and the seven the examples declare; the 629 by-name loads were
those plus every `contextOf<T>()` call, which is a register now and no
instruction at all. The 23 handovers are every statically bound call of a
contextual declaration across the corpus, which says how little of it
uses the feature, and the 3 568 value calls are the `context(v...) { }`
blocks and implicit invocations that were the two dynamic kinds. Twenty-two
unresolved kinds remain, down from twenty-three. 588/588 corpus, 149/0
sweep, `itest-context_parameters` 24/24; the ceiling is re-recorded.

### The walk skips a subject the body's `this` does not reach

`StoreToThisOrGlobal` has one producer, the bare write whose walk came
back undecided, so the item is the walk's residuals, the same ones that
hold the reads and the calls: on the compose lazy example, cold, 358 of
1 256 bare writes were undecided, 172 of them `this_rebound_unknown`,
and that reason held 736 sites of every kind. The walk demanded that the
innermost spliced subject be the register `this` names and gave up
otherwise. Most of those sites were the block of an inline extension
whose block takes no receiver (`lock.synchronized { size += 1 }` in
`LruCache`, `Brush.let` in `PathComponent`, `AtomicRef.loop` in
`CancellableContinuationImpl`): the extension splice binds its receiver
as a subject, and the block restores the body's own `this`, so the
subject is bound for the function's own body and is no receiver of the
block. The rest were local extension functions, `fun
Float.toDecomposedOffset()` inside a member of `ScrollingLogic2D`, whose
`this` is the declared receiver bound at the prologue and not the
captured `this` the closure guard compared it against.

The tower a closure inherits already walked the subjects this way: the
innermost subject in scope is the one `this` names, each further one is
the `this` the nearer subject displaced, and a subject `this` does not
reach is hidden. The walk now follows the same chain, checks each
visible subject's head as before, and beneath them expects the body's
own `this`, the one the bottom subject displaced; a different register
is still a rebound it cannot name. A closure whose declared receiver is
bound is not compared against its capture. A unit test pins both: the
hidden `Lock` under the own `this`, and a `this` no subject and no prior
names.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 7 144 | 7 508 |
| walk verdict `global` | 5 287 | 5 530 |
| walk verdict `undecided` | 4 324 | 3 699 |
| of which `this_rebound_unknown` | 736 | 55 |
| bare writes decided | 898 | 1 047 |

The 55 left are closures holding a subject of their own, where the
walk's closure branch still refuses the captured `this` behind any
subject (`tower_outer_declares` took 50 more for the same reason); that
branch is next.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 550 576 | 115 577 356 |
| unresolved | 2 269 594 | 2 254 487 |
| dynamic_by_design | 1 514 908 | 1 514 908 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_member_or_global` | 381 589 | 373 157 | -8 432 |
| `name_write_this_or_global` | 10 644 | 5 196 | -5 448 |
| `name_read_this_or_global` | 54 274 | 52 998 | -1 276 |
| `name_read_global_by_name` | 83 236 | 83 040 | -196 |
| `call_member_by_name` | 603 585 | 603 830 | +245 |

Resolved kinds that took them (rises of four hundred or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_static_id` | 3 241 323 | 3 249 066 | +7 743 |
| `field_write_slot_claimed` | 232 122 | 237 521 | +5 399 |
| `name_read_global_resolved` | 658 409 | 659 346 | +937 |
| `field_read_prop_slot` | 705 806 | 706 365 | +559 |
| `call_virtual_slot` | 4 841 121 | 4 841 565 | +444 |

Fifteen thousand sites left the unresolved kinds, half of them the bare
writes: `name_write_this_or_global` is at 5 196 from 10 644, and the
calls beside those writes in the same blocks went with them. The 245
`call_member_by_name` are walked member calls whose receiver is now
named but whose slot the overload set still withholds. 588/588 corpus,
149/0 sweep; the ceiling is re-recorded.


### A closure reads its captured `this` behind a subject it does not reach

The 55 rebound sites left were closures holding a subject of their own,
and the same shape held 220 `tower_outer_declares`: the walk's closure
branch refused the captured `this` whenever the body held any subject,
and refused every receiver behind it too. `run { lock.synchronized {
size += 1 } }` inside a member is the shape: the tower's first entry, the
captured owner, declares `size`, and the branch answered that it could
not reach it. A lambda that had not loaded its captured `this` when the
subject bound had recorded no displaced register for it, and the reach
check of the previous entry read that as a rebound.

The captured `this` is the register the bottom subject displaced, else
the capture itself, loaded on first use, which is what the reads beside
it do. A receiver behind it is reached through its `this@<label>` slot
unless a subject of this body carries the same label, the same rule the
tower applies to its own entries. A subject bound before the capture
was loaded displaced the capture. Two unit tests pin the two shapes.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 7 508 | 7 598 |
| walk verdict `undecided` | 3 699 | 3 487 |
| of which `tower_outer_declares` | 220 | 115 |
| of which `this_rebound_unknown` | 55 | 4 |
| bare writes undecided | 197 | 166 |

The residuals that remain, by size: `closure_tower_unknown` 840,
`subject_head_unknown` 693, `outer_class_declares` 489,
`head_unresolvable` 316, `member_arity_unproven` 297,
`extension_unproven` 195, `property_unproven` 193, `this_unavailable`
146, `tower_outer_declares` 115, `own_static_name` 109.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 577 356 | 115 584 039 |
| unresolved | 2 254 487 | 2 249 384 |
| dynamic_by_design | 1 514 908 | 1 514 908 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_this_or_global` | 52 998 | 50 300 | -2 698 |
| `call_member_or_global` | 373 157 | 371 410 | -1 747 |
| `name_write_this_or_global` | 5 196 | 4 520 | -676 |
| `field_read_by_name` | 545 683 | 545 701 | +18 |

Resolved kinds that took them (rises of four hundred or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `field_read_prop_slot` | 706 365 | 709 041 | +2 676 |
| `call_static_id` | 3 249 066 | 3 250 089 | +1 023 |
| `call_virtual_slot` | 4 841 565 | 4 842 289 | +724 |
| `field_write_slot_claimed` | 237 521 | 238 197 | +676 |
| `name_read_capture_slot` | 750 412 | 750 911 | +499 |

Five thousand sites left the unresolved kinds, the reads, writes and
calls of the owner's members inside blocks under a hidden subject:
`name_write_this_or_global` is at 4 520. 588/588 corpus, 149/0 sweep,
itest-e2e green; the ceiling is re-recorded.


### A lambda's shape from its fun interface, its untyped initializer and its safe call

`closure_tower_unknown` was the largest residual at 840: a closure
whose construction site recorded no receiver tower, because the
literal's shape was not known when it lowered. Pairing every shapeless
literal on the lazy example with the shape-recording site that preceded
it found none for 921 of 968: the call paths that lowered them never
reached one. Three producers were missing. A fun-interface conversion
(`Comparator<Int> { a, b -> ... }`, `Easing { }`, `DoubleFunction { }`)
lowered its argument with no record of the interface's single abstract
method; a class or top-level property initializer with no declared type
(`val maker = { count++ }`) recorded nothing where a local `val` already
records "no receiver"; and a safe member call that fell to the by-name
`CallMember` skipped the namesake consensus the deferred member call
runs. The conversion's lambda now owns no receiver, the abstract
method's leading `this` being the interface instance and no receiver of
the block (a first cut read that `this` as an extension receiver, and
every `Comparator { a, b -> compareValuesBy(a, b, selector) }` in the
stdlib turned its resolved call into a `CallMemberOrGlobal`, ten sites
in every program, which the per-program census diff against the
previous build caught); a member extension as the abstract method stays
unrecorded. The initializer's lambda has no receiver, since only an
expected function type gives one; and the safe call runs the same
consensus.

The probe counts were also inflated. The static typers lower an
expression into a scratch builder to read its type, and a lambda inside
one printed a walk verdict and a shape line for a form that never runs;
the census already skipped those builders through `census_quiet`, the
probes did not. A scratch builder is marked as one and the count rides a
per-thread depth, so a body lowered inside it is silent too. The walk
counts below are the first measured that way, so the shape line's drop
is partly the gate.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 7 598 | 7 650 |
| walk verdict `global` | 5 485 | 5 484 |
| walk verdict `undecided` | 3 487 | 3 405 |
| of which `closure_tower_unknown` | 837 | 725 |
| lambdas lowered without a shape | 926 | 717 |

The shapeless literals that remain sit under calls the path lowers
without a candidate to read: a bare or member call the walk declined, a
companion-object path call, a `remember`/`pointerInput` whose callee is
a header stub at that point. Each is a producer at that path, and the
consensus rule bails on any namesake whose block type it cannot decode,
which a trace will now name.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 584 039 | 115 593 288 |
| unresolved | 2 249 384 | 2 242 593 |
| dynamic_by_design | 1 514 908 | 1 514 908 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_member_by_name` | 603 830 | 599 682 | -4 148 |
| `name_read_this_or_global` | 50 300 | 48 555 | -1 745 |
| `call_member_or_global` | 371 410 | 370 584 | -826 |
| `name_write_this_or_global` | 4 520 | 4 301 | -219 |
| `name_read_global_by_name` | 83 040 | 83 187 | +147 |

Resolved kinds that took them (rises of a hundred or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_virtual_slot` | 4 842 289 | 4 846 538 | +4 249 |
| `name_read_capture_slot` | 750 911 | 752 633 | +1 722 |
| `field_read_prop_slot` | 709 041 | 710 439 | +1 398 |
| `call_static_id` | 3 250 089 | 3 250 856 | +767 |
| `name_write_global_slot` | 2 927 | 3 074 | +147 |
| `field_read_getter` | 265 821 | 265 965 | +144 |

Seven thousand sites left the unresolved kinds. The largest move is the
4 148 by-name member calls that are slot calls now: the bodies of the
shaped lambdas know their receiver's class, so a member call inside one
binds its slot. The 147 global reads by name are the other side of the
147 slot writes: a top-level initializer's lambda now walks to the
global, and the read's slot is the accessor-registration gap already
noted. 588/588 corpus, 149/0 sweep, itest-e2e green; the ceiling is
re-recorded.


### The consensus reads members, skips synthetic parameters and keeps a concrete receiver

The shapeless literals left after the fun-interface, initializer and
safe-call producers were paired with the lowering stack that reached
each (`KLIO_SHAPE_STACK=<label>` prints it), and three paths came out:
the deferred member call, the safe call that falls to it, and the
member-or-global emitter. All three run the trailing-lambda consensus,
which agrees a block's shape over the namesakes that could take a call
whose receiver is decided at run time; the consensus was returning
nothing, silently. Tracing its returns under the walk probe named the
reasons. A companion or class member (`Snapshot.withoutReadObservation
{ }`, `?.updateScope { }`, `layout(w, h) { }`) is not in the top-level
name index, so the consensus saw no namesake at all. A composable's
`$composer`/`$changed` parameters sit after the block, so every
`remember` overload's last parameter was an `Int` and none qualified. A
named argument anywhere in the call disqualified it, though a trailing
block binds the last parameter whatever the others are named. And an
agreed receiver every namesake spells as a concrete class
(`PointerInputScope`, `SavedStateReader`, `StyleProperties`) went
unrecorded, the rule fearing a type parameter it could not instantiate.

Member declarations now register under their simple name in a registry
table (`member_fids_by_name`) the consensus reads beside the top-level
index; the block parameter is the last user one; only a named block is
left alone; a concrete agreed receiver is recorded and a type-parameter
one still not. A lambda literal standing as a statement or as a body's
tail expression with no expected type has no receiver, the rule a local
`val` already applied: `val getter = { state -> { ... } }` returns a
receiverless block.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 7 650 | 8 318 |
| walk verdict `global` | 5 484 | 5 906 |
| walk verdict `undecided` | 3 405 | 3 420 |
| of which `closure_tower_unknown` | 725 | 554 |
| lambdas lowered without a shape | 717 | 539 |

The undecided count holds while the decided ones rise by a thousand:
the closures that now have a tower walk it and land on the other
residuals, `subject_head_unknown` and `outer_class_declares` first. The
consensus's remaining refusals are namesakes that genuinely disagree
(`Operations.forEach` with an `OpIterator.()` block beside the stdlib's
plain one; a `layout` with a `PlacementScope.()` block beside one
without), blocks typed by an alias or a fun interface the decoder does
not read yet (`CompletionHandler`, `FlowCollector`), and `apply`'s `T`
against `U`, which is the same receiver spelled twice.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 593 288 | 115 603 281 |
| unresolved | 2 242 593 | 2 235 298 |
| dynamic_by_design | 1 514 908 | 1 515 263 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `call_member_or_global` | 370 584 | 365 116 | -5 468 |
| `name_read_this_or_global` | 48 555 | 46 459 | -2 096 |
| `name_write_this_or_global` | 4 301 | 4 024 | -277 |
| `field_read_by_name` | 545 701 | 545 673 | -28 |
| `recv_enclosing_pop` | 185 404 | 185 401 | -3 |
| `recv_enclosing_push` | 185 404 | 185 401 | -3 |
| `call_value_or_member` | 1 716 | 1 719 | +3 |
| `name_write_global_by_name` | 14 283 | 14 299 | +16 |
| `recv_qualified_this` | 16 250 | 16 268 | +18 |
| `call_member_by_name` | 599 682 | 599 723 | +41 |
| `name_read_global_by_name` | 83 187 | 83 689 | +502 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_capture_slot` | 752 633 | 755 448 | +2 815 |
| `call_virtual_slot` | 4 846 538 | 4 848 783 | +2 245 |
| `field_read_prop_slot` | 710 439 | 712 324 | +1 885 |
| `call_static_id` | 3 250 856 | 3 252 293 | +1 437 |
| `call_member_resolved` | 24 272 | 25 594 | +1 322 |

Seven thousand sites left the unresolved kinds, three quarters of them
bare calls under a `CallMemberOrGlobal` that are static or slot calls
now, and the rest owner-member reads and writes off a receiver a closure
can name. The 502 global reads by name are walks that reach `global`
for a name the slot table does not hold, the accessor-registration gap,
where they were `LoadFromThisOrGlobal` before. The `call_static_id`
column rises this time; the previous batch's swap is not repeated. 588/588
corpus, 149/0 sweep, itest-e2e green; the ceiling is re-recorded.


### A branch lambda has no receiver, and a block parameter reads through an alias or a fun interface

Two shapes were still leaving a literal without a receiver record. A
literal standing as an `if` or `when` branch with no expected type
(`return if (indent.isEmpty()) { line -> line } else { line -> indent +
line }` in the stdlib's `getIndentFunction`) reaches the body lowering as
the branch expression itself, which the statement rule does not see;
only an expected function type gives a literal a receiver, and none
reaches a branch. And the trailing-lambda consensus decoded a block
parameter only when it was spelled as a function type: `CompletionHandler`,
an alias of `(Throwable?) -> Unit`, and `FlowCollector`, a fun interface
the literal converts to, counted as no block at all, so
`invokeOnCompletion { }` and `collect { }` agreed nothing. A branch
literal with no expected type now has no receiver, and a block parameter
reads through an alias to its target's receiver and through a fun
interface to its abstract method.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 8 318 | 8 380 |
| walk verdict `global` | 5 906 | 5 955 |
| walk verdict `undecided` | 3 420 | 3 435 |
| lambdas lowered without a shape | 539 | 529 |

The shape work has reached its diminishing tail. What the consensus still
refuses is namesakes that genuinely disagree (`Operations.forEach` with an
`OpIterator.()` block beside the stdlib's plain one, a `layout` with a
`PlacementScope.()` block beside one without), which only the receiver's
type decides, and that type is the by-name call's missing input, not the
block's. The walk's residuals now stand at `subject_head_unknown` 778,
`closure_tower_unknown` 556 and `outer_class_declares` 524; the second is
what the shapeless literals cost, and the other two are the next items.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 603 281 | 115 603 335 |
| unresolved | 2 235 298 | 2 235 135 |
| dynamic_by_design | 1 515 263 | 1 515 266 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_this_or_global` | 46 459 | 46 334 | -125 |
| `call_member_or_global` | 365 116 | 365 091 | -25 |
| `recv_qualified_this` | 16 268 | 16 259 | -9 |

The 125 reads are `field_read_prop_slot` now. A measured tail: the two
producers are right and cheap, and they close the shape work rather
than extend it. 588/588 corpus, 149/0 sweep, itest-e2e green; the
ceiling is re-recorded.

### A local function's block, a fun interface's extension receiver, and the owner behind an extension receiver

Three more places where a fact lowering held was not handed on. A local
function's declared block parameter typed nothing: `fun expect(c: Char,
check: () -> Boolean)` inside `Duration.parseIso` lowered its trailing
block shapeless, where a top-level function's call records the block's
receiver from the parameter. The declaration now records its last user
parameter's block receiver under the mangled overload name
(`local_fn_block_recv`) and the call reads it. A fun interface whose
abstract method is a member extension (`fun interface
PointerInputEventHandler { suspend fun PointerInputScope.invoke() }`)
hands the converting literal that extension receiver, which the method's
leading `this` parameter names; the conversion and the consensus's
block-parameter decoder both read it where they left the shape open.

The third is the one that moved: a closure built inside a member
extension body (`override fun SemanticsPropertyReceiver.applySemantics()`
with `onClick { state... }`, `setText { manager... }`) inherited a tower
holding the extension receiver alone. The owner instance, the dispatch
receiver the body binds as `this@<Owner>` since the frame-value change,
was not in it, and every owner member such a closure read stopped at
`outer_class_declares`: 40 sites in one `applySemantics`, 21 in
another. The tower carries the owner behind the extension receiver,
labeled by the owner so the closure reaches it through its captured
`this@<Owner>` slot, the register the walk's closure branch already
resolves by label.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 8 380 | 8 569 |
| walk verdict `undecided` | 3 435 | 3 151 |
| of which `outer_class_declares` | 524 | 272 |
| lambdas lowered without a shape | 529 | 505 |

What `outer_class_declares` still holds is inner classes reading their
outer's members (`TextFieldTextDragObserver.onDrag` reading
`textLayoutState`), which the enclosing-member set names and no register
reaches: an inner instance carries its outer as a link, and the next
entry gives the walk one hop along it.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 603 335 | 115 613 912 |
| unresolved | 2 235 135 | 2 227 740 |
| dynamic_by_design | 1 515 266 | 1 515 266 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_this_or_global` | 46 334 | 43 324 | -3 010 |
| `field_write_by_name` | 50 011 | 47 659 | -2 352 |
| `call_member_or_global` | 365 091 | 363 849 | -1 242 |
| `field_read_by_name` | 545 670 | 545 094 | -576 |
| `call_member_by_name` | 599 719 | 599 419 | -300 |
| `name_write_this_or_global` | 4 024 | 3 872 | -152 |
| `recv_qualified_this` | 16 259 | 16 496 | +237 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `field_read_prop_slot` | 712 449 | 715 296 | +2 847 |
| `field_write_slot_claimed` | 238 530 | 241 034 | +2 504 |
| `name_read_capture_slot` | 755 401 | 757 093 | +1 692 |
| `call_static_id` | 3 252 246 | 3 253 499 | +1 253 |

Seven thousand sites left the unresolved kinds, the owner members read
and written from closures inside member extensions above all. The 237
`QualifiedThis` are the same closures reaching the owner through its
`this@<Owner>` slot where the slot is not yet a capture: a by-name walk
still, one hop closer, and the outer-instance entry that follows takes
the hop by structure. 588/588 corpus, 149/0 sweep, itest-e2e green; the
ceiling is re-recorded.


### An inner class reaches its outer instance by structure

`outer_class_declares` held what the tower entry above left: inner
classes reading their outer's members (`textLayoutState` in
`TextFieldSelectionState.TextFieldTextDragObserver.onDrag`,
`refreshChildNeeded` in `InfiniteTransition.TransitionAnimationState`).
Lowering records the enclosing classes' member names as one set with no
class behind each name and no register for any instance, so the read
lowered to `LoadFromThisOrGlobal` and the runtime walked the chain by
name at every read. The instance already holds the fact: construction
links an inner instance to the `this` it was constructed in, and the
runtime's qualified-`this` walk follows that link before anything else.

`LoadOuterThis` reads the link: one instruction per hop, from the body's
own `this`, from the captured `this` when a closure's tower starts at the
owner, and from the dispatch register in a member extension of the inner
class. The walk emits the hops for the first enclosing class that
declares the name when every class between is inner, and the read,
write or call binds on the outer's register like any member. A nested
class has no instance of its outer and keeps the enclosing-member
answer; a name an enclosing class holds only as a companion member or an
enum entry is not a hop either. The census counts the load as resolved
(`name_read_outer_this`); the image format is 84.

The corpus caught the one shape the probe could not: an inner class's
constructor context. Its parent-constructor arguments, constructor
defaults and secondary-constructor delegation lower as thunks whose
leading parameter named `this` is the enclosing instance, not the
owner's, and `inner class Derived : OuterValue(source)` hopped one level
too far from it and found no outer. The module builder now marks those
thunks (`this_is_outer`), the hop producer starts one level out with no
load there, and a closure built in such a thunk sees the enclosing class
first in its tower. A unit test pins the hop, the nested class that has
no instance to hop to, and the constructor context.

This is the first structural replacement for `QualifiedThis`: its
runtime walk is the outer link first, then the enclosing chain, then the
class parent chain, and the first of those is now an instruction the
walk can emit. The other producers of `recv_qualified_this` (the
explicit `this@Outer`, the member-shadowed property read, the
extension-body owner read) are the same hop where the target is an
enclosing class, and the entry after this one takes them.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| walk verdict `member` | 8 569 | 8 774 |
| walk verdict `undecided` | 3 151 | 2 954 |
| of which `outer_class_declares` | 272 | 74 |
| `LoadOuterThis` emitted | 0 | 204 |

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 613 912 | 115 638 640 |
| unresolved | 2 227 740 | 2 215 731 |
| dynamic_by_design | 1 515 266 | 1 515 263 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_this_or_global` | 43 324 | 36 632 | -6 692 |
| `call_member_or_global` | 363 849 | 359 124 | -4 725 |
| `name_write_this_or_global` | 3 872 | 3 481 | -391 |
| `field_read_by_name` | 545 094 | 544 892 | -202 |
| `recv_enclosing_pop` | 185 404 | 185 401 | -3 |
| `recv_enclosing_push` | 185 404 | 185 401 | -3 |
| `call_value_or_member` | 1 716 | 1 719 | +3 |
| `call_member_by_name` | 599 419 | 599 423 | +4 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_outer_this` | 0 | 11 576 | +11 576 |
| `field_read_prop_slot` | 715 296 | 721 996 | +6 700 |
| `call_virtual_slot` | 4 848 866 | 4 852 464 | +3 598 |
| `call_static_id` | 3 253 499 | 3 254 622 | +1 123 |

Twelve thousand sites left the unresolved kinds: 6 692 owner reads
through `this` or a global that are property-slot reads off the outer
register now, and 4 725 bare calls that are static or slot calls on it.
`name_read_outer_this` is the new resolved kind, 11 576 loads, most of
them the stdlib's `AbstractList.IteratorImpl` and its kin reading the
outer list's `size`, one per program. 588/588 corpus, 149/0 sweep,
itest-e2e green; the ceiling is re-recorded.


### A qualified `this` names an instance in scope before it walks

`recv_qualified_this` held 16 496 sites across seven producers: the
explicit `this@Outer`, `super@Outer`, a `::member` bound to an enclosing
class or to the owner behind an extension receiver, an inner
constructor's outer for `w.Inner()`, and a local class capturing the
dispatch receiver of a member extension. Every one emitted
`QualifiedThis`, the runtime's by-name walk from the nearest `this` over
the outer links, the enclosing chain and the class parent chain, and
every one names a class whose instance lowering can place: the owner's
own or dispatch register, an enclosing class's instance one
`LoadOuterThis` per inner hop, or the entry a closure's tower holds for
it under its captured `this` or a `this@<label>` slot.

`instanceOfClassReg` answers that question once, by structure, and the
seven producers ask it before falling to the walk, which stays only for
a class nothing in scope names. `this@Outer.seen += 1` inside an inner
class is a slot write on the outer register; `super@Outer.greet()`
starts from that register; a closure inside the inner class reads
`this@Outer.label` through its captured `this` and one hop.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| `LoadOuterThis` emitted | 204 | 241 |
| `QualifiedThis` emitted | 721 | 443 |

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 638 640 | 115 641 252 |
| unresolved | 2 215 731 | 2 209 593 |
| dynamic_by_design | 1 515 263 | 1 515 266 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `recv_qualified_this` | 16 496 | 10 289 | -6 207 |
| `call_member_or_global` | 359 124 | 359 106 | -18 |
| `call_member_by_name` | 599 423 | 599 419 | -4 |
| `call_value_or_member` | 1 719 | 1 716 | -3 |
| `recv_enclosing_pop` | 185 401 | 185 404 | +3 |
| `recv_enclosing_push` | 185 401 | 185 404 | +3 |
| `field_read_by_name` | 544 892 | 544 980 | +88 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_outer_this` | 11 576 | 14 160 | +2 584 |

Six thousand `QualifiedThis` walks are gone: 2 584 are outer loads now
and the rest name the owner's own or dispatch register, which is no
instruction at all. The 10 289 that remain are the class nothing in
scope names by structure yet; the next probe carries the producer of
each. 588/588 corpus, 149/0 sweep, itest-e2e green; the ceiling is
re-recorded.


### An instance of a class is any receiver that extends it

The audit names the producers behind the surviving `QualifiedThis` walks
on the lazy example, and the largest was not an outer instance at all:
`dp.toPx()` inside a `MeasureScope` body dispatches its member extension
on the `Density` the scope is, and the structural lookup matched a class
by exact name, so the `Density` behind `this` was walked for by name at
every call, 18 sites in one `measure`. A receiver whose class extends
the wanted one is that instance: the extension receiver, the owner and
a closure tower's entries now match by `classIsOrExtends`.

The first cut of that rule matched the body's own receiver before the
spliced subjects, and the e2e gate caught it where the harness corpus
could not: `with(other) { 5.scaled() }` inside `Outer` scaled by the
body's factor instead of `other`'s (`[15:3]` for `[35:3]` in
`examples/nested_receiver_extension_scope.kt`). The subjects `this`
reaches come first, innermost out, as in the walk and the tower; the
own receiver, the owner and the outer hops follow. The corpus line the
plan entries carry checks exit codes only (`corpus_check.py --no-rust`);
the output comparison over the corpus is `itest-e2e`, and it stands
before every commit.

The next producer was `this@SimpleGraphicsLayerModifier` inside a
property initializer's receiver lambda. A class's property initializers
and accessors lower as thunks that bind `this` but no `this@<Owner>`
label, which a method body binds at entry, so a closure built in a thunk
had no slot to capture the owner by. The thunk binds the label its
`this` answers to: the owner's, or the enclosing class's in an inner
class's constructor context.

On the lazy example, cold, the same probe:

| measure | before | now |
|---------|-----:|----:|
| `QualifiedThis` emitted | 443 | 196 |
| `LoadOuterThis` emitted | 241 | 257 |

What remains, by the audit: `inner_ctor_outer` sites whose wanted class
is a receiver the walk's own inputs do not name (`PlacementScope` inside
`place`, `Density` inside a body whose receiver is a type parameter), and
`labeled_this` in anonymous objects, which have an outer link at run time
and no `is_inner` mark or enclosing-class row in lowering, so nothing
structural names their outer yet. Both are the next hop.

Site census, cold, both binaries over the same 588 programs
(`scripts/site-census-sweep.py --cold`, the previous commit against this tree):

| verdict | before | now |
|---------|-----:|----:|
| resolved | 115 641 252 | 115 644 237 |
| unresolved | 2 209 593 | 2 201 437 |
| dynamic_by_design | 1 515 266 | 1 515 263 |

The unresolved kinds that moved:

| kind | before | now | delta |
|------|-----:|----:|------:|
| `recv_qualified_this` | 10 289 | 2 977 | -7 312 |
| `name_read_this_or_global` | 36 632 | 35 796 | -836 |
| `call_member_or_global` | 359 106 | 359 034 | -72 |
| `recv_enclosing_pop` | 185 404 | 185 401 | -3 |
| `recv_enclosing_push` | 185 404 | 185 401 | -3 |
| `call_value_or_member` | 1 716 | 1 719 | +3 |
| `call_member_by_name` | 599 419 | 599 423 | +4 |
| `field_read_by_name` | 544 980 | 545 043 | +63 |

Resolved kinds that took them (rises of a thousand or more, the plain
instruction and terminator counts aside):

| kind | before | now | delta |
|------|-----:|----:|------:|
| `name_read_outer_this` | 14 160 | 15 264 | +1 104 |

Seven thousand `QualifiedThis` walks are gone, most of them the member
extension dispatched on a receiver that extends its owner, which is a
register the site already held: the `Density` behind every
`MeasureScope`, the `Scaled` behind a `with(other)` subject. 2 977 remain.
The exit-code corpus is 588/588, the sweep 149/0, and the `itest-e2e`
output comparison over all 591 programs is green with the JIT on and
off; the ceiling is re-recorded.


### Where this stands

Deleted so far, by the goal's own measure: the three context instructions
(`CtxLoad`, `CtxScope`, `CtxCall`), their evaluator, exec, disassembler and
census arms, the host context stack with its six entry points, and the
module-wide context gate. A context parameter is a parameter, handed over
by `ContextPush`/`ContextPop` and read by `LoadContextParam`. Nothing else
on the elimination list has left `Inst`; every remaining variant still has
its producers and consumer arms.

Bound, over the entries above, on the cold corpus census:

| measure | before these entries | now |
|---------|----:|----:|
| unresolved sites | 2 270 247 | 2 209 593 |
| unresolved kinds | 23 | 22 |
| `name_write_this_or_global` | 10 644 | 3 481 |
| `name_read_this_or_global` | 54 274 | 36 632 |
| `recv_qualified_this` | 16 250 | 10 289 |
| walk verdicts undecided, lazy example | 4 564 | 2 942 |

Two structural instructions arrived: `LoadOuterThis` (an inner instance's
outer link) and, before it, `LoadDispatchThis`; the walk's residuals
`this_rebound_unknown` and `outer_class_declares` are gone or nearly, and
the lambda-shape producers (fun interfaces, untyped initializers, safe
calls, local functions, branch literals, the namesake consensus reading
members) are closed to their tail.

What governs the distance left, in the order to take it:

1. `subject_head_unknown` (776 on the lazy example) and
   `closure_tower_unknown` (498): a spliced subject or a closure's captured
   `this` whose head no source settled. These are the inputs the register
   lattice bottoms out on, and they gate `StoreToThisOrGlobal`'s last
   producer as much as the reads and calls beside it.
2. The anonymous object's outer: `object : X { this@Owner... }` links to
   its outer at run time through a per-class default, and lowering has no
   `is_inner` mark or enclosing-class row for it; `name_build_object`
   (29 670) and the surviving `labeled_this` walks sit there.
3. The type-information producers the goal names, none started: a type
   parameter resolved to its upper bound, a function value's return type
   from its `FunctionN` argument, a global's declared type on `LoadGlobal`.
   `call_member_by_name` (599 419), `field_read_by_name` (544 980) and
   `call_member_or_global` (359 106) are 1.5 million of the 2.2 million
   unresolved sites, and they wait on these.
4. `EnclosingPush`/`Pop` (185 404 each), `name_read_global_by_name`
   (83 689, the accessor-registration gap for reads) and
   `call_new_instance` (76 055), untouched.
5. The end-state checks, not yet run: `KLIO_REQUIRE_RESOLVED=1` over the
   corpus, `scripts/gate.sh` alone, the rename-every-variant compile, and
   the two headline cost measurements.

The corpus line each entry carries (`corpus_check.py --no-rust`) checks
that every program exits 0 and nothing more; the output comparison over
all 591 programs is the `itest-e2e` gate, run before each commit, and it
is what caught the two defects this stretch (an inner constructor's
`this`, a subject ordered behind the own receiver).

The instruments that carried this stretch: `KLIO_WALK_PROBE=1` on the cold
lazy example for the residual table, `KLIO_SHAPE_STACK=<label>` for the
path behind a shapeless literal, `KLIO_OR_AUDIT=1` for the producer behind
a surviving `QualifiedThis`, `KLIO_DISPATCH_TRACE=1` for a frame that had
to derive a receiver or a context value, and the per-kind census diff read
for a paired rise and fall before any total is believed.
