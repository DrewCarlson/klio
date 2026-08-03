# Static dispatch campaign

Goal: bind every call at lowering time, so the runtime never resolves a
member by name. That retires the dispatch ladders and the memoization
layered over them, and it is the prerequisite a bytecode VM and a
Kotlin-to-C transpiler both need — a packed instruction stream cannot
fall back to a name walk. The only permitted exceptions are language
features deliberately omitted (advanced reflection and anything else
dynamic by definition).

## Standing constraint: no simple-name resolution

Every resolution this campaign adds or touches must key on a FULLY
QUALIFIED name. Simple-name keys have repeatedly produced silent wrong
answers (the canonical case: `typeck.classes` keyed by simple name let
two `SlotTable` classes overwrite each other, which mis-shaped a lambda
parameter, which suppressed `it`, which produced 8 unresolved-reference
errors — one map, four layers of consequence). Where a simple-name
lookup genuinely helps, it must be ISOLATED so no other declaration can
pollute it: a scoped index, not a global map. An ambiguous simple name
must answer NOTHING — a wrong answer feeds evidence channels and
disproves valid candidates downstream. The same defect recurred as
`Double.equals`/`String.equals` host linkage, the `Map.Entry`/user
`Entry` extension collision, and the expect/actual sibling scan: treat
every simple-name identity as suspect.

A sibling defect shape recurred four times: a scope query that knows a
NAME but not the POSITION in the block (`val iterator = iterator()`
shadowing its own initializer; a later local capturing an earlier bare
write; the boxed-var analysis; the local-init re-entry). Any new scope
query must carry the declaration point.

## Current state

Census scripts (cold cache, pinned file sets — two measurements are
comparable ONLY at the same cache state; the scripts clear it):

    scripts/dispatch-census.sh           stdlib commontest — generic throughout
    scripts/dispatch-census-examples.sh  the examples corpus — concrete types

Report BOTH for anything aimed at element types; a change can move one
and not the other and still be right.

    stdlib:   total 8,918 member sites
            1,519  17.03%  bound_static
            5,758  64.57%  bound_virtual     (81.6% bound; 2.34% at campaign start)
            1,279  14.34%  no_receiver_type
              213   2.39%  resolver_declined
               29   0.33%  no_class_id
              120   1.35%  nullable_or_generic

    examples: total 98,982
           15,540  15.70%  bound_static
           68,761  69.47%  bound_virtual     (85.2% bound; 37.4% at start)
           10,268  10.37%  no_receiver_type
            2,699   2.73%  resolver_declined
              436   0.44%  no_class_id
            1,278   1.29%  nullable_or_generic

The examples total grew 91,595→99,688 when the intrinsic-only-import
fix landed: programs importing `kotlin.concurrent.thread` had been
failing pre-run (the unresolved rejection), so their site mass was
absent. The restored threaded examples carry fresh unbound mass, which
is why the bound share dipped 85.0→84.7 while nothing regressed.

The member-site TOTAL moves in both directions: bare calls becoming
statically bound EXTENSION calls leave the member census (denominator
falls), and former OrGlobal deferrals becoming member binds join it
(the implicit-this commit grew it 6,425→8,139 / 68,928→87,715).

Flipped defaults (each `=0` disables for single-binary A/B):
`KLIO_HDR_BOUNDS`, `KLIO_THIS_NARROW`, `KLIO_BARE_EXT`,
`KLIO_TOWER_EXT`, `KLIO_TOWER_EMIT`, plus the per-channel gates named in
the ledger below. The eager pipeline is the ONLY pipeline
(`cli: eager is the only pipeline`, 43e8a1f4; `commontest-sweep.py
--eager` is accepted-and-ignored).

Standing gates, all green at HEAD: sweep 117/0
(`python3 scripts/commontest-sweep.py zig-out/bin/klio-harness`), corpus
drift 266/266 (out-of-process headless runner), parity pinned 153/153
(`backtick_this_param_not_receiver` closed: a provably-unresolved bare
call in a package-less file is rejected pre-run), threaded litmus 41/41
(`python3 scripts/litmus-sweep.py` — first fully-green run of the
suite), ir unit tests, `zig build test`.

## Compose 100% baseline — the throughput campaign (2026-08-03)

The user's standing requirement: stdlib AND compose test baselines are
100%, no "known throughput-bound" write-offs. stdlib commontest is
117/117. Compose's 7 failing tests are all concurrent snapshot-write
stress tests over budget. Measured state (concurrentGlobalModification_add
as the pinned benchmark; 1-worker == 3-worker time, so it is pure
single-thread interpreter throughput, zero retry/contention waste):

- 20.5s at start -> 13.7s now. Landed: field-WRITE memo, member-body
  ext splice (killed 10,000 per-call receiver DRAINS from
  `indexOfFirst` inside `AbstractList.indexOf`), anonKey stack buffers,
  `.Class`-receiver keys for the ext-walk memo (90k redundant walks ->
  0; time-neutral, the walks were cheap).
- The harness caps runTest's default timeout at 10s
  (kotlinx_coroutines_test_default_timeout in compose-test.sh) for hang
  isolation; upstream's real default is 60s. `_add` at 13.7s passes
  upstream semantics today. The REAL wall is the tests with
  source-written 30s budgets: concurrentGlobalModifications_addAll
  (~31s), concurrentMixingWriteApply_addAll_clear (~30s),
  concurrentMixingWriteApply_addAll_removeRange (~78s -> needs 2.6x),
  and the map-suite mirrors.
- Remaining profile (execution phase, sample at 45s): core loop
  execInst/runFlatLoop/evalWithCapturesChained ~1/3; productive
  interpreted bodies (equals 82k calls, invokeMethodFuncId); getField
  328 + instanceField 176; materializeInstance 166 via primaryCtorPath
  (record/vector churn); ensureTotalCapacityPrecise 211 + slab 380
  (alloc churn). No single spot fix left; next candidates in order:
  (1) profile removeRange specifically (78s smells like interpreted
  O(n^2) element shifting), (2) ctor/materialize churn on the
  record-per-write path, (3) the general core-loop cost (the bytecode
  VM this campaign's end state names).
- Diagnostics added: KLIO_DRAIN_TRACE ([drain]), KLIO_WALK_TRACE
  ([extfb-walk] at the real walk, [ir-walk]).
- Tools: benchmark via `kotlinx_coroutines_test_default_timeout=300s
  KLIO_TEST_WALL_CAP=400 scripts/compose-test.sh
  SnapshotStateListTests.concurrentGlobalModification_add`; profile via
  macOS `sample` ~45s into the run (earlier samples catch typecheck).
  Stale-pack trap: drift caches under .klio-local/cache bake with the
  CURRENT binary — clear after harness rebuilds when validating fixes.

## Remaining work

### 1. The typeck generic-argument project — the mass

Both large buckets are blocked on the same missing thing: infer and
carry GENERIC ARGUMENTS through the call graph. Every syntactic channel
that reads a type out of the source has been opened and pinned (see the
ledger); six separate measured zeros say more of the same is worthless.

  - `no_receiver_type` (1,872 / 15,475): initializers dominated by
    `getOrPut`, `iterator`, `toMutableList`, `listIterator` — stdlib
    generics whose declared return is the CALLER's own type parameter
    (`M : MutableMap<K, V>` makes `getOrPut` return `V`, which names no
    class, and the bound record drops the arguments that would
    substitute it). Latest split: `[no-recv-path]` 632
    local_no_decl_type, 335 unknown, 81 captured, 38 enclosing_member;
    `[localinit]` 2,944 total = 1,356 derived, 858 no_return_type,
    730 no_initializer.
  - `resolver_declined` (465 / 3,775): every blocked pair has an
    applicable member and an applicable same-arity extension, and the
    arguments carry no authoritative type to choose between them
    (`[extlit]` shows zero literal-carrying queries). Latest split:
    213 target_known_deferred, 208 virtual_owner_stub, 44
    virtual_owner_value; `[promo-blocked]` on the deferred 213: 66
    ext_own_head, 61 ext_builtin_super, 34 ext_declared_super, 30
    receiver_not_instance, 22 ext_generic_receiver.

The inference work list, ranked by `[TYPEHEAD-SKIP]` over one compose
test: MutableList 1,058, Iterator 880, List 349, Array 252,
MutableVector 247, SnapshotStateList 172, MutableScatterSet 71,
Flow 68. Start with `listOf`/`mutableListOf` and the `iterator()`
chain, and the substitution of a caller's own type arguments into a
generic member's return type (`getOrPut` returning `V`).

Concrete first step, measured 2026-08-03: the `iterator` local family
(516 examples-weighted, recv=SequenceScope 57/example + recv=Sequence
direct) is `val iterator = iterator()` inside stdlib extension bodies.
The resolved `Sequence.iterator()` returns `Iterator<T>` with the
CALLER's `T` unbound, and the return-derivation refuses the generic
head outright. Design: answer HEAD-WITH-STAR-ARGS (`Iterator<*>`, the
421e8f8a star-erasure convention) — member binding on the head then
binds `hasNext()`/`next()` virtual slots (T-independent signatures),
while the `*` keeps element-dependent extension selection refused (the
minOrNull IEEE hazard that killed plain head-only answers). Same shape
should serve `getOrPut`/`toMutableList`/`listIterator` receivers.

**The declared-type rule, which every later phase must keep:** a
generic function's body is resolved once, against its type PARAMETERS,
never against any one call site's instantiation. Eager evidence is
keyed by span, and a span inside a generic body has as many types as
the function has instantiations — recording one and applying it to the
body is ambiguous by construction (`plusElement`'s one-line body:
`plus(element)` must resolve against `T`; instantiate `T=List<String>`
and the Iterable overload becomes applicable and CONCATENATES —
`plusCollectionInference`'s exact failure). Re-widening the eager
channel therefore needs either (a) no evidence recorded inside generic
bodies (cheap, loses coverage) or (b) per-instantiation evidence with
lowering asking with the instantiation in hand (the real answer, and a
significant design). `GroupingTest.countEach` is almost certainly the
same shape.

**Prerequisite before ANY further theory on the `plusElement`
regressions:** `ApplicabilityScope` carries no call SPAN, so an
`[extkey]` ranking row cannot be tied to a source line. Thread a span
through (diagnostic-only). Five theories were already falsified — see
the dead-end list.

### 2. Reach a CAPTURED implicit receiver statically

The `CallMemberOrGlobal` family (~2,400 stdlib sites) and the
`LoadFromThisOrGlobal`/`StoreToThisOrGlobal` bare-name walks. The bare
member-call bind is built and measured at +18 without this, because at
~4,400 sites `b.resolve("this")` is null — the receiver is a capture.
`KLIO_BCC_WHY`: 5,403 no-visible-tier sites are MEMBERS on implicit
receivers. Do not rebuild the bind without first fixing the
captured-receiver reach. (The tower emission commit below is the first
slice of this: outer receivers now reach through `this@<label>` capture
slots when an extension serves the call.)

### 3. `no_class_id` — 300 stdlib / 3,816 examples

Latest split: 296 of 300 `simple_unknown`, 4 `fqn_unknown`. Receivers
are NAMED but the head resolves no class — unsigned-array-style heads
needing members-by-head answers. ~146 stdlib sites are the unsigned
types (`UInt`, `ULongArray`, …): host primitives with NO IR class or
vtable — not a registration gap; they need a binding form naming a HOST
SYMBOL directly, designed together with the C transpiler. The
host-symbol route already exists (`DeclSig.host_symbol` →
`ProgramImage.resolved_native` → `src/stdlib/implementations.zig`,
1,578 entries) — that table is exactly what a C transpiler emits.
Remaining stub/value residue from the host-backed round: 98
`virtual_owner_stub`-shaped + 30 value sites need the same route from a
receiver representation with no runtime class.

### 4. Phases 2–4 (after the census work)

  - **Phase 2 — lower `a[i]` as `Index`.** 19.9M `member_fast_subscript`
    dispatches per rob run should never reach the member arm.
  - **Phase 3 — retire the runtime caches** once `[dispatch-stats]`
    shows `member_ladder`/`member_flat_prepare` near zero
    (`tl_method_cache`, `tl_ext_cache`, `tl_resolve_cache`,
    `tl_perm_cache`, `ext_method_cache`, member-resolve memos). Measure
    after removal; they cost real time on every miss.
  - **Phase 4 — bytecode VM.** Only meaningful once dispatch is static.
    Already measured (`interpreter-performance-plan.md`): widening
    `Inst` 120→200 bytes cost 0%; an extra call per instruction cost
    0%. Re-encoding is optional cleanup, not a performance change — the
    win is that a statically bound call needs no resolution.

### Genuinely dynamic by design

`invoke` on a function value and SAM conversion; reflection
(`::member`, `KClass`) — intended to stay dynamic or be omitted.

## Landed ledger

Each entry: mechanism, movement, pin. Gates were green at every landing
unless noted. Chronological.

- **Ambiguous simple-name classes answer nothing** — `putClassChecked`/
  `classNamed` record collisions (`ambiguous_class_names`); the 8
  unresolved-`it` errors from the SlotTable overwrite went to 0.
- **Eager channel widening tried and REVERTED** — full types with
  `args_complete` delivered 311 fills (all non-generic) vs 3,800
  skips, zero generic fills, and two regressions where typeck's arguments
  were wrong (`plusCollectionInference`, `countEach`). The transport is
  not the bottleneck; typeck's generic inference is.
- **Typing a local from its initializer** — `localInitTypeRef` feeds
  `staticCallReturnTypeRef` callers, gated `staticClassifierArgsComplete`.
  bound 1,853→2,140/6,929. The `sumOf` wrong-overload hazard fixed via
  `intrinsicOverridesBody` (host implementation serves where Kotlin
  picks by inferred lambda return). Lesson: find out which function
  EXECUTED before reasoning about which should have (`[whosum]`
  `body=true` ended nine failed theories).
- **`val x = x()` self-shadow fixed** — `local_init_name_free` recorded
  before the bind; a local is not in scope inside its own initializer.
  stdlib 34.6%→45.6% bound, examples 37.4%→50.9% — the single biggest
  jump; the `iterator` bucket (9,458 examples sites) was this.
- **Loop variables, lambda params, destructured components typed** —
  from the iterable's type argument / `argLambdaParamTypes` /
  `componentN` declared returns. Data-class `componentN` accessors are
  now REAL lowered declarations (`lowerMethodWithMemberContext` from
  primary-ctor properties; hand-written ones suppress; runtime
  synthesis stands down) — kills the `Map.Entry`/`Entry` extension
  collision class. Pin `data_class_components_are_declared_members`.
- **Catch parameters typed** — two lines at `lowerTry`'s bind; pin
  `catch_param_static_type`. Enabled by deleting the placeholder
  `ThrowableActuals.kt` that shadowed the host renderer.
- **Interface receivers promoted; virtual-slot linker FQN-widened** —
  `overrideTypeClassId` widens outwards along the owner FQN
  (`ContinuationInterceptor.minusKey` vs `Element.minusKey` compared
  unequal before); host half via `invokeVirtualMember` runtime-class
  resolution. bound 2.34%→4.93% (+170 sites).
- **`target_known_deferred` promotion** — `unknown_count == 1` in
  `resolveMemberCall`, guarded by `extCouldApply` (arity-aware);
  `Module.dispatchForTarget` centralizes direct-vs-virtual.
  bound_static 196→274. Wrong turns recorded: unguarded representation,
  excluding stub/value (broke Sequence), excluding interfaces (broke
  TrieNode — final/private has no slot).
- **Type-parameter receivers read their upper bound** — `TypeParamBound`
  `head_only` mode (the old `complete` excluded `C : MutableCollection<in T>`
  shapes, 6,590 examples sites): stdlib no_class_id 675→187; examples
  8,702→2,358 (59.2% bound). Cycle guard added after a latent
  initializer-cycle stack overflow (`val a = b.x` beside `val b = a.y`),
  pinned by a unit test.
- **Bare names in extension bodies belong to the receiver** —
  `staticBareReceiverType` searches the receiver incl. supertypes. Gate
  `KLIO_EXT_RECV_PROP`. Pin `bare_name_inside_an_extension_body`.
- **Operator returns, alias chains, factory/ctor property types,
  null-chain narrowing, sole-global commit** — each a small typed
  channel, each pinned (`receiver_typed_from_an_operator`,
  `alias_local_keeps_its_source_type`, `property_typed_from_a_factory_call`,
  `property_typed_from_a_ctor_parameter`, `null_check_through_and_chain`);
  several measured ~0 on the censuses and are kept as wrong-ANSWER
  fixes.
- **Safe calls bind statically** — the member runs on the null-tested
  branch; receiver register reused. The remaining 122
  nullable_or_generic sites are CORRECT to decline.
- **Host-backed members bound — 1,226 sites** — dropped the
  `receiver_abi != .instance` refusal; host symbols reached by FuncId
  through `resolved_native` (1,163 calls/run with no name compare,
  `KLIO_NOINST_TRACE`). Three simple-name linkage bugs fixed alongside.
- **Generic project first slices** — initializer chains reach receivers
  (`recvChainTypeRef`, gate `KLIO_RECV_CHAIN`); explicit type arguments
  are final; `bindCallType` keeps the subsuming side of subsumed
  constraints (gate `KLIO_BIND_LUB`; fixes `listOf(Derived(), Base())`);
  `getOrDefault` declared in `kotlin-klio` MapActuals. Pins
  `generic_receiver_through_its_initializer`,
  `generic_argument_from_every_constraint`,
  `receiver_typed_through_its_parameter_bound` (`KLIO_TP_RECV`,
  examples 63.2% bound).
- **Bare calls may be extensions of the implicit receiver** — the
  fourth slice (`KLIO_BARE_EXT`): members first, then
  `resolveExtensionCall` on the implicit receiver. stdlib 56.7% bound.
  Pin `bare_extension_call_in_a_receiver_body`. Latent bug fixed:
  `lowerResolvedExtensionCall` read its target pointer after receiver
  lowering could move the function table.
- **Override relation beats overload tie; zero-arg bare heads project**
  — two resolver defects under the iterator residue, module-test
  pinned; exposed linker bug fixed by `unifyRedeclaredSlots`
  (`ir: a redeclared interface slot reaches the inherited body`).
- **Type-parameter disproof + sole-survivor commit** —
  `staticTypeDisproofComplete` (head-only bounds are complete for
  NEGATIVE conclusions); `KLIO_SOLE_EXT` requires pruning evidence
  (without it `indentWidth` inside `trimIndent` broke). Fixes the NaN
  `minOrNull` blocked pair (a declared type parameter disproves the
  IEEE overload).
- **Six pinned applicability reds fixed** — alias receivers
  (`resolveTypeAliasAt` in `localOverloadReceiverCouldApply`),
  member-shadows-constructor typing (`ctorInitTypeRef`), dispatch-owner
  members in member-extension scope, private member extensions stay in
  the declaring class, generic inline receivers carry the call-site
  classifier. Pinned 127→133/134.
- **THE FLIP: `KLIO_HDR_BOUNDS` + `KLIO_THIS_NARROW` default on** — the
  armed-refuter arc: header-time bound registration armed
  `receiverViolatesTypeParamBound`; the smart-cast `this` was invisible
  to `bareStaticRecvHead` (found by `KLIO_DUMP_FN` showing a static
  self-`Call` baked into `Iterable.contains`); the genuine-narrow gate
  (entry must differ from the frame's own declared receiver) fixed both
  the ArrayDeque mis-bind and a 4.3x DeepRecursive slowdown. Along the
  way, four member-first guards landed (deferred members block static
  ext commits; thinned-set walks defer; executing-frame cache guards;
  `receiverHasMemberNamed` FQN host probe).
- **Enum-entry patching / e2e recovery** — `InstanceData.fields_foreign`
  + `ensureFieldsOwned`; `Vm.patch_allocator` threading; e2e crash was
  pre-existing at de72470a. Durable recipe: the harness+sweep loop
  cannot see in-process base-image adoption — run `KLIO_E2E_SHARD=0/16`
  on a built e2e binary when interp_ir/runtime/image internals change.
- **The corpus drift campaign: 249 → 266/266, ~17 root causes** — the
  out-of-process drift runner reproduced every in-process failure.
  Fixes, each pinned: anonymous-receiver exact-FQN host dispatch
  (4 examples), getter expected types
  (`lowerAccessorExprWithExpected`; `getter_lambda_param_shape`),
  `kotlin.io` out of `any_member_prefixes`
  (`receiver_scope_zero_arg_println`), `valueCouldServeName` host-probe
  + supertype-chain walk (`bare_call_through_closure_subject`,
  `flow_builder_object_identity`), alias-gated by-id inline splice
  (ungated it broke every compose example and blew the 6GB RSS cap),
  F-bounded local extensions (`staticGenericReceiverCouldApply`
  could-apply mode; `local_extension_fbounded_param`), Iterable
  fallback arity (`iterator_member_global_arity`), defaulted post-vararg
  positionals (`vararg_before_defaulted_positional`), range-in-range
  standdown (`range_in_range_user_operator`), finally-leaf
  classification (`finally_runs_on_return_leaf_shape`),
  suppressed-exception intrinsics on Instances
  (`throwable_suppressed_user_instance`), `Any` never
  evidence-refutable (`reified_from_lambda_annotation`),
  virtual-fallback arg names (`delegated_member_named_args_pin`).
- **select_on_timeout_loses: the eleven-piece chain** — root: klio
  bound the member `tryResume(value, idempotent)` where kotlinc binds
  Select.kt's file-private `CancellableContinuation<Unit>.tryResume(onCancellation)`
  — the substituted `value: Unit` refutes the callable argument, and
  the untyped local chain starved the refutation. Landed: cast/call/
  elvis initializer typing, callable-arg-vs-builtin-param refutation
  (`staticArgCompatibility` + `nonCallableBuiltinHead`), expr-body
  return derivation (decl-time + on-demand registry
  `registerExprBodyMember`/`exprBodyMemberAst`, od_depth<3), receiver
  type-arg substitution in member refutation, and the commit rule: a
  member-refuted call commits its sole surviving SAME-FILE extension
  (file-blind widening broke trimIndent — bisected, refined). Pin
  `select_receive_beats_timeout`. Also cured mosaic_hello as a side
  effect (the lazy-reader derivation tail).
- **compose_nodes keyed loops** — `wrapLoopContent` skips the
  per-iteration wrap for sole-`key(...)` bodies (matching pre- and
  post-rewrite forms; key rewrite runs child-first), so movable groups
  sit as siblings and MOVE instead of recreating.
- **compose_ui_text was environment skew** — a runner beside
  `zig-out/lib/libklio_skia.dylib` measures real font metrics; corpus
  expectations are headless. See traps.
- **Eager-mode readiness retired** — pipeline unified (43e8a1f4); the
  NaN total-order trio and DurationTest (`varargParamType` supplies
  `Array<out String>` for vararg params) verified green.
- **The tower consult, derivation slice (`KLIO_TOWER_EXT`)** —
  `bareExtensionTarget` walks the implicit-receiver tower innermost
  first for every derivation consumer. stdlib no_receiver_type
  1,964→1,872; examples 16,424→15,475 (−949).
- **The tower emission commit (`KLIO_TOWER_EMIT`)** — tower entries are
  `(head, label)` pairs (`ir.ReceiverTowerEntry`); a member-refuted
  outer level commits its extension with the receiver bound through the
  `this@<label>` slot (the qualified-this capture channel); an
  applicable outer MEMBER stops the walk (Kotlin's members-over-
  extensions per level). Local extension fns now bind `this@<name>`.
  Census unchanged on both sets — an honest zero: CMG→Call conversions
  are not member-census sites; `[KLIO_OR_AUDIT] Call/bare-tower-extension`
  counts the commits. Pins `tower_outer_receiver_extension`,
  `tower_local_extension_label`, and the module test asserting the
  labeled-slot `.Call`.
- **The implicit-this member commit (`KLIO_ITC_MEMBER`)** — the largest
  single jump since the self-shadow fix. `lowerImplicitThisCall`
  (the `hasOwnMember` bare-call path) emitted the OrGlobal deferral
  without ever attempting a static member bind; it now runs the full
  `lowerResolvedMemberCall` (direct for final/private, virtual slot
  otherwise) before deferring — a member the receiver provably declares
  beats any same-named top-level in Kotlin's scope order, so only the
  UNPROVEN cases keep the fallback. Census: stdlib bound 57.1% → 64.9%
  (bound_static 146→549, bound_virtual 3,522→4,733; member-site total
  6,425→8,139 as former deferrals became countable member sites);
  examples bound 64.7% → 71.5% (bound_static 1,456→4,324,
  bound_virtual 43,128→58,361; total 68,928→87,715). no_receiver_type
  share 29.14%→23.00% / 22.45%→17.64%. Two regressions root-caused and
  fixed before landing:
  - Invoke-convention peers: `class C(val f: (A) -> T) { fun
    f(vararg s: A) = f(s) }` — the member resolver ranks FUNCTIONS
    only, so the sole-member promotion bound the vararg member back to
    itself (kotlinc binds the property's `invoke`; a non-spread array
    cannot feed a vararg). The arm stands down when the receiver
    declares a same-named function-typed property (registry head or
    primary-ctor param). Pin `invoke_convention_peer_vararg_member`;
    IterableTests' `createFrom` family was the live case.
  - The loop JIT dropped `Char` tags (latent interpreter bug the new
    static binds exposed — next entry).
  Gate `KLIO_ITC_MEMBER=0`/`=name,name` for A/B and per-name bisection.
- **Loop-JIT rebox preserves value kinds (`box_tags`)** — `RegType.i32`
  covers `Int`/`Char`/`Short`/`Byte`, and every rebox
  (`valueFromSlot(.i32)`) minted `.Int`: a trampolined `append(c)`
  appended the char's CODE as digits (Base64's aladdin credential
  encoded the missing chars' codes as digit soup, byte-exact). The
  compile-time `CompiledLoop.box_tags` (from resolved callee returns,
  Consts, Moves, live samples) plus a runtime `TrampCtx.tags` buffer
  refreshed by trampoline RESULT writes (an intrinsic `toChar` has no
  static return to read) restore the original kind at every boxing site
  (tramp args, loop/func exit, nullables; cell writeback restores the
  cell's own previous tag). The trigger: call-count-accumulated
  compilation firing at a COLD loop entry, sampling stale frame
  registers. OPEN hardening: a cold sample can also miss a packed-array
  receiver and accept a trampoline shape the warm compile rejects —
  gate compile sampling on a warm entry. Pin `jit_char_append_tag`
  (six-call sequence; corrupts only on the 6th, at the OSR checkpoint
  after a cold-entry compile).

- **Tower-complete receiver scope (`KLIO_TOWER_SCOPE`)** — a lambda/thunk
  body's receiver scope is COMPLETE when its implicit-receiver tower
  enumerates every level and each entry's class passes the plain-method
  tests (no enclosing-class instance, no companion pairing, complete
  hierarchy shadow set per lifted-outer chain). `ResolveCtx` carries the
  tower; `knownReceiverApplicability` consults every tower head like the
  owner path (symbolic instantiation + bounds). Unlocks the
  `bare_call_member_shadowable` deferral family — BUT a tower-unlocked
  static commit requires a SOLE candidate: the old deferral was the
  runtime's overload/tier safety net for unproven argument types, and
  the unguarded unlock let same-package
  `test.text.assertContentEquals(String, CharSequence)` beat the
  star-imported applicable Sequence overload (StringTest.
  splitToLineSequence caught it — tier picks without type proof are not
  commitments). Guarded yield on the stdlib set: 8 of the 186 reachable
  sites; the rest wait on argument-type authority (each arg-typing gain
  auto-widens this) or the ranker learning to REFUTE competing tiers.
  Next refinement: commit multi-candidate picks when the shapes prove
  the target applicable and refute every competitor.

- **Bare receivers typed by a type-param bound substitute the FULL
  bound ref** — the bare-call derivation arm mirrors the `.Member`
  arm's third-slice rule: a receiver head naming no class resolves
  through `typeParamBoundRef` (projections stripped), so `val iter =
  iterator()` inside `C : MutableCollection<T>` derives
  `MutableIterator<T>` and the downstream `hasNext()`/`next()` flip
  CallMember → CallVirtual. Census ZERO on both fixed sets (their
  iterator misses live in lambda/`with` bodies with no declared
  receiver — the twice-measured head-only dead end's population), kept
  under the wrong-answer precedent: the repro's dispatch forms improve
  demonstrably. Pin `bound_receiver_bare_iterator`; `KLIO_TP_RECV=0`
  disables with the member-arm slice.

- **Final stub/value members bind DIRECT** — `dispatchForTarget`
  answered `.virtual` unconditionally for stub/value owners, which is
  exactly the emission a vtable-less host shell cannot run; a FINAL
  method on a closed stub/value class now answers `.direct` (the fid
  call runs the Kotlin body or its resolved-native form regardless of
  the host representation), and the deferral site accepts a direct
  answer for blocked-class receivers — with the extension-shadow
  question now computed for them too (String and the unsigned shells
  carry extension families everywhere). stdlib bound_static 549→575,
  resolver_declined 565→539; examples 4,324→4,377 / 4,461→4,408.

- **Stub/value owners emit their virtual slot** (`KLIO_VOWN`, default
  ON; `=0` disables): binds the `virtual_owner_stub`/`virtual_owner_value`
  deferral families. The flip needed three prerequisites, each a real
  bug the emission exposed:
  1. *Final members downgrade `.virtual` → `.direct` at the deferral
     site* when `dispatchForTarget` proves it — `Result.exceptionOrNull`
     as a virtual slot misdispatched on the value representation and
     `runCatching { }.fold` took the success arm holding the thrown
     exception (assertFailsWith is built on exactly that shape).
  2. *Exit-guard `!is` narrowing* (`narrowNegatedIsCheckAll`): after
     `if (x !is T) throw ...`, `x` is `T` below, including through the
     `||` chain — `ValueTimeMark.minus(ComparableTimeMark)` guards then
     calls `this.minus(other)` meaning the ValueTimeMark overload, and
     the static bind without the narrow resolved the call back to the
     enclosing overload and recursed until the stack ran out
     (TimeMarkTest adjustmentBig/Infinite). Pin
     `exit_guard_negated_is_narrows_overload`.
  3. *Host-repr receivers prefer their FQN-keyed intrinsic over the
     interpreted slot target* (`invokeVirtualMember` non-Instance path):
     the source `Result.toString` matches on the `Failure` wrapper the
     host `.Result{ok, payload}` never materializes, so the slot entered
     a representation-mismatched body and printed `Success(...)` for a
     failure (coroutines ResultTest). Same most-derived rule the
     host-synth Instance probe already applied. Fixed alongside two
     VOWN-independent render gaps the investigation surfaced: `println`
     and template stringify now dispatch a host Result's `toString`, so
     `Failure($exception)` uses the payload's override. Pin
     `result_host_render_custom_tostring`.

  Census: stdlib resolver_declined 539→239 (every `virtual_owner_stub`
  208 + `virtual_owner_value` 92 site converted; the 239 remainder is
  all `target_known_deferred`), bound_static 575→671, bound_virtual
  4,733→4,935 (65.2%→68.9% bound). Examples resolver_declined
  4,408→2,906, bound 71.5%→73.2%. Full battery green: sweep 117/0,
  corpus drift 266/266, threaded litmus at its 3-failure baseline,
  compose SnapshotStateListTests 61/65 with exactly the four known
  throughput-bound concurrent tests.

- **Anon-object bodies lower against an image clone** (`KLIO_ANON_BASE=0`
  restores the empty side module): `buildObject` gives every
  runtime-synthesized member/thunk lowering ONE shared `cloneForExtend`
  of the main module instead of an empty `Module.default`, so anon
  bodies resolve classes/members/extensions exactly as build-time
  lowering does — and their emitted main-space slots and fids execute
  correctly both through the host and through the side module itself
  (the cloned lazy header section serves ids below the append range).
  Three companion pieces:
  1. The anon class's own property heads travel via a thread-local
     snapshot (`setLowerAnonPropHeads`, gate `KLIO_ANON_PROP`) —
     declared annotations as written, un-annotated initializers derived
     from the CAPTURED value's runtime class (including through a
     captured `this`'s field, the `Sequences.kt` shape) — consumed by
     `propTypeHeadOn` since the synthesized class has no registry rows.
  2. The companion-object redirect in `lowerResolvedMemberCall` stands
     down when an enclosing receiver declares a property of the bare
     receiver's name (`iterator` inside `object : Iterator<T>` is a
     `this` property read, not a class-name access; the redirect
     silently returned `.none` for it).
  3. Decl-span reservations are DISABLED on the clone
     (`Module.anon_side`): synthesized getter/setter thunks share their
     property ident's span, and the reservation channel made the setter
     overwrite the getter at the adopted id (anon_object_setter's
     read-back returned Unit).
  The previously-invisible anon population now enters the lower-site
  census and mostly binds: total 8,135→8,273, bound_virtual
  4,935→5,025, bound_static 671→691, resolver_declined 239→267 (anon
  deferrals now countable). Battery green (sweep 117/0, drift 266/266,
  litmus baseline, compose 61/65 known-four). Pin
  `anon_object_outer_prop_iterator`; `examples/anon_object_setter.kt`
  pins the thunk-collision regression. Local classes (`host_classes.zig`
  runtime synthesis) still lower into empty side modules — same
  treatment is the follow-up.

- **Unbindable return-type params erase to star projections**
  (`KLIO_STAR_RET=0` disables): `instantiatedCallReturnType` refused
  whenever the receiver couldn't bind the declared params — a bare
  owner head with no args to project, a head-only extension receiver
  failing `bindCallType`, and (the actual stdlib mass) a bare
  `iterator()` resolved through the receiver-less top-level pick. All
  three now substitute `*` for the still-unbound parameters after
  argument binding has had its chance, so `val iterator = iterator()`
  inside an `Iterable<T>` extension body types the local `Iterator<*>`
  — the HEAD binds its `hasNext()`/`next()`, and `*` is
  applicability-neutral so the erased arguments prove and refute
  nothing. A result erased to a bare `*` head is still refused. Census:
  no_receiver_type 1,870→1,774, bound_virtual 5,121 (+96), 70.2% bound.
  Battery green. Pin `ext_body_bare_iterator_star`.

- **Spliced inline callees carry their type-param bounds**
  (`bindSpliceTypeParamBound`, restored on splice exit): a callee's
  param types reach the caller's builder through `spliceParamTy`
  (`destination: M`), but `M`'s bound stayed behind, so the head named
  nothing and every member call on such a receiver was `no_class_id`
  (the whole `M`/`C` family — `getOrPut` on `groupByTo`'s destination).
  Recorded incomplete: the bound supports the receiver-owner lookup,
  never a negative proof. With the projection-head fix the same tick:
  no_class_id 300→193, bound_virtual 5,187, 71.4% stdlib bound. Pin
  `splice_bounded_type_param_receiver`. Long-tail found writing the
  pin: `toSortedMap { cmp }` (comparator lambda) and
  `toSortedMap(compareBy { ... })` both unimplemented.

- **Top-level property declared types flow to bare-receiver reads**
  (`top_level_prop_type_heads`, keyed by FQN; baked through the image's
  `TopPropImage` rows, format 37): `asserter.assertEquals(...)` had no
  channel at all for the top-level `val asserter: Asserter`'s declared
  type — the bare-read walk covered locals, captures, and enclosing
  members only. `topLevelPropTypeHead` picks the best-tier declaration
  under the same scoping walk a bare call ranks by, and types nothing
  on a same-tier cross-package head disagreement. Census:
  no_receiver_type 1,772→1,714, most converting to statically bound
  extension calls (total 8,230→8,174; 71.9% bound). Pin
  `toplevel_prop_bare_receiver`.

- **Lambda-return inference for the RETURN channel** (built, gated
  `KLIO_LAMBDA_RET`, currently default OFF): when a resolved call's
  declared parameter is `Function{N}` with a bare type-param return
  and concrete value-param types, an unannotated lambda literal's
  single-block tail derives in a scratch builder under those param
  types, the shape gains the full function type, and `bindCallType`
  binds the callee's `T` from it — `List(3) { it * 2 }` types
  `List<Int>`. Three sub-fixes landed en route, ACTIVE regardless of
  the gate: primitive binary arithmetic result typing
  (`primitiveBinResultHead`, Kotlin numeric promotion + `String +`),
  same-head structural binding in `bindCallType` for the synthetic
  `Function{N}` family (no class row backs the head; positional
  arg-binding now proceeds), and the enrichment plumbing. Census with
  the gate ON: stdlib no_receiver_type 1,524→1,403, 80.0% bound.
  GATED OFF; the failure is now fully characterized and is NOT a
  lowering-context corruption: the lowered `checkInvariants` body is
  BYTE-IDENTICAL in passing and failing processes (CallMember `or` ×4
  + CallMemberOrGlobal `require`). The break is RUNTIME DISPATCH
  ORDER: reproduce with the batch-shaped child (`--only-file` for
  BOTH ArraysTest and UnsignedArraysTest, `--filter=ArraysTest`
  substring-matches both, all dir siblings + the three cross-dir
  providers) — the unsigned tests execute FIRST, their on-demand
  lowerings (with the gate on) shift what registers before
  `XorWowRandom` lowers, and the dynamic `or` dispatch on an Int
  receiver then runs `UInt.or`'s interpreted body (`UInt(this.data or
  other.data)` → the ctor intrinsic rejects the garbage `data` read).
  A single-test run of the same file set passes — the trigger is the
  unsigned TESTS executing beforehand. An owner-chain guard on the
  total-miss member tail (committed — correct hardening regardless)
  did NOT fix it. Session-3 facts: the failing site is
  ArraysTest.shuffle/shufflePredictably's OWN body (fails in ~5ms),
  whose first statements are `val numbers = List(100) { it }` (the
  gate's own feature types it) then
  `testShuffle(numbers.map(Int::toUInt).toUIntArray(), ...)`; the
  thrown error is `ctor_uint` receiving exactly ONE argument of tag
  INSTANCE (`[uctor] nargs=1 tags=Instance`, KLIO_UCTOR_TRACE); the
  `or`-dispatch theory is DEAD (checkInvariants executes fine, no
  or/nextInt/shuffle dispatch rows precede the error), and
  `resolved=null` on its CallMembers rules out baked-fid staleness
  there. Toy repros of every suspected shape (List-factory +
  `map(Int::toUInt)` + `toUIntArray` + testShuffle generic
  receiver-lambdas, unsigned lowerings primed first) PASS — only the
  full batch-shaped child with the unsigned suite executing
  beforehand reproduces (the --only-file pair + dir siblings + the 3
  cross-dir providers, `--filter=ArraysTest`, `KLIO_LAMBDA_RET=1`,
  cold cache — deterministic there). RESOLVED by the frame-chain
  probe (`runtime.debug_frame_dump`, installed by the evaluator): the
  chain read `kotlin.toUInt (UInt.kt:462) <- kotlin.collections.map`
  — an UNBOUND method reference (`Int::toUInt`) invoked with its own
  receiver value prepended. `Int` in value position is its COMPANION
  INSTANCE (Primitives.kt Int declares one), and the STATIC-FID ref
  invocation path tested only `rv == .Class` for the unbound form, so
  the companion got prepended as `this` and every argument shifted.
  The fix reuses the by-name path's type-like predicate (Class, or
  uppercase ctor-function, or companion instance whose companion does
  not serve the member) on the fid path. Order-dependence explained:
  the fid attaches only when the extension target statically resolves
  at ref-lowering, which the lambda-return typing enabled.
  KLIO_LAMBDA_RET is now DEFAULT ON: stdlib no_receiver_type
  1,524→1,353, 80.6%% bound. Pin `unbound_ref_companion_receiver`.

- **Extension-property declared types flow to bare reads**
  (`KLIO_EXT_RECV_PROP`): a bare read whose name resolves to an
  extension-property getter (`__ext_get_<Head>_<name>` on the receiver
  tower) types the read from the getter's declared return head, so
  `n`/`last`-style ext-prop locals stop being `no_receiver_type`
  downstream. Pin `ext_prop_type_bare_read`.

- **Splice-hint feed + setter value typing**: the inline splice hands
  its receiver/param type hints to the spliced builder eagerly, and a
  class-member setter's `value` parameter carries the property's
  declared type (`lowerSetterExprTyped`/`lowerSetterBlockTyped` set
  the local decl type + nullability). Pin `setter_value_param_typed`.

- **The bare return derivation walks the outer receiver tower**: `val
  iterator = iterator()` inside `sequence { }` receiver-lambdas
  derived no type because `staticCallReturnTypeRef`'s bare Path arm
  probed only the innermost head (SequenceScope); it now walks the
  enclosing implicit-receiver tower and resolves the member or bare
  extension against each outer head, adopting the first hit's receiver.
  stdlib no_receiver_type 1,333→1,329, examples 9,839→9,791. Pin
  `sequence_scope_outer_iterator`.

- **Litmus restoration: two holes the static campaign opened, one
  latent shadowing bug** (found by the new
  `scripts/litmus-sweep.py`, 34/41→41/41 — first fully-green litmus):
  (1) the pre-run unresolved rejection fired on intrinsic-only imports
  — `kotlin.concurrent.thread` has a host impl but no Kotlin
  declaration, so every provability probe answered no; a named import
  of the leaf now defeats provability. (2) `linkResolvedForms` marked
  only simple-name-indexed funcs native, so a member-form binding
  (`kotlinx.atomicfu.locks.ReentrantLock.lock`) never settled onto the
  class METHOD's FuncId — a statically resolved spliced `lock()` ran
  the placeholder no-op body and held no lock (8×500 guarded
  increments lost ~5%); the link now resolves the binding key's class
  prefix and marks matching methods. (3) latent: a caller local
  shadowing a receiver member for a bare CALL — `val lock =
  ReentrantLock()` beside the spliced body's `lock()` lowered
  `CallValue` on the instance (`invoke` miss); a local whose
  initializer is a constructor of a concrete class with no `invoke`
  operator (member or applicable extension) now defers to the
  function/member path, matching kotlinc candidate rules. Census:
  stdlib total 8,978→8,974 (deferred locals leaving the value-call
  census); examples total 91,595→99,688 — programs importing
  `kotlin.concurrent.thread` had been failing pre-run, so the import
  fix restored their whole site mass (bound share 85.0→84.7 from the
  fresh threaded mass, no regression). Pin
  `lock_member_binding_spliced` + a linkResolvedForms member-form unit
  test; litmus sweep promoted to the standing battery
  (`scripts/litmus-sweep.py`).

- **Extension-property type heads recorded at declaration scan**
  (`ext_prop_type_heads` in the registry, image format 38): the bare
  `indices` receiver family — 629 examples-weighted sites, all inside
  shipped array/CharSequence extension bodies — derived nothing because
  the ext-prop channel read the GETTER FUNC's return type, and (a)
  accessor funcs never entered `func_name_index` (`pushFunc` skipped
  the index; the `__ext_get_*` naming contract found nothing, ever),
  (b) even indexed, stdlib-internal sites lower during the bake BEFORE
  the getters lower — ordering no func-lookup can beat. Both fixed:
  `pushFunc` indexes `__ext_get_*` accessors, accessors carry the
  declared property type as their return type, and the decl scan
  records `(receiver head, prop) -> declared head` before any body
  lowers, which `extPropReturnHead` consults first. stdlib
  no_receiver_type 1,329->1,279, examples 10,897->10,268 (the whole
  family). Pin `ext_prop_receiver_typed_read` (property declared AFTER
  the consuming function, so only the decl channel can answer).
  The new typed sites exposed two dispatch holes, both fixed in the
  same slice: (a) the member-form binding link is restricted to
  CONCRETE classes — an interface/abstract method fid marked native
  would serve host-repr intrinsics to interpreted receivers; (b) a
  virtual slot on an interpreted Instance that links to a BODYLESS
  header with a host symbol now falls to the by-name ladder whenever
  the receiver's class hierarchy declares the member — the header's
  native form fed a `PersistentList` instance to
  `kotlin.collections.List.isEmpty` (host-List-only), the compose
  `validateIsEmpty` failure. This interaction class (typed receiver ->
  newly bound slot -> repr-mismatched native header) is the expected
  failure shape as binding coverage grows; the name ladder still
  reaches host bindings through its own tails when no interpreted body
  exists.

## Measured dead ends and falsified theories — do not retry

- Invoke-convention return typing for enclosing fn-typed ctor
  properties (2026-08-03): two forms built — a chain walk answering
  the fn type's last argument for a bare `createFrom(...)` whose
  member resolution finds nothing, and an unwrap at the final
  fallback when the resolved target is the property GETTER (zero
  params, args present, `Function` return head). Derivation-level
  effect confirmed (`[valty] data = List` stores appear; the
  `[no-recv-name] data` rows collapse 30→3) yet BOTH censuses
  identical: the consuming reads sit inside expect-style LAMBDAS,
  classified `captured`, where the local decl-type inheritance already
  fails to convert the site. Reverted. Re-derive only after the
  captured-receiver/lambda channel converts sites at all — the
  unwrap's guard (`value_params == 0 and call.args.len != 0`) is the
  correct discriminator against fn-returning functions.

- **Unsigned representation unification, first arc landed**: the real
  `unsigned/src/kotlin/U*{,Array}.kt` + `UnsignedCommon.kt` ship, with
  execution host-repr end to end — `kotlin.U*` constructor intrinsics
  reinterpret the signed payload as the host value (companion constants
  and source-body `UInt(...)` wraps never build an interpreted
  instance; the scalar types joined `isIntrinsicClass`), the
  `UnsignedCommon` expect surface (uintDivide/uintCompare/…toString)
  is implemented as host intrinsics, `data`/`storage` reads were
  already host-served, and `ArrayList(<array>)` routes through its
  ctor intrinsic instead of building a hollow expect-class shell (the
  `first_is_array` guard now exempts collection ctors). All unsigned
  scalar suites green. STANDING RED (immediate follow-up): 15
  UnsignedArraysTest tests fail `unresolved global indices/lastIndex`
  — a bare receiver-extension-property read inside an inline body
  spliced into a lambda context executes as
  `$sgetter$<TestClass>␟indices` against the LEXICAL owner instead of
  the splice receiver (host getField serves indices/lastIndex on
  arrays fine; the read never reaches the array). Evidence:
  `KLIO_OR_AUDIT` shows `bare_name_fallthrough LoadFromThisOrGlobal`,
  `[ltg-tail] raw=$sgetter$UnsignedArraysTest␟indices in_fn=<lambda>`,
  RESOLVED — root cause was none of the earlier candidates: the test
  class's own METHODS are named after the operations (`fun indices()`,
  `fun lastIndex()`, `fun sumOf()`...), so `enclosing_only_member`
  blocked the splice's receiver shortcut and the runtime walk found
  the caller's method instead of the receiver's extension property.
  Fixed by SPLICE SCOPE HYGIENE (`KLIO_SPLICE_HYG=0` disables): a
  top-level extension's spliced body parks the caller's own/enclosing
  member sets and lexical owner (`beginSpliceDeclScope`) — the body
  resolves in its declaration scope, as Kotlin scopes it — and
  spliced caller-LAMBDA content swaps the caller scope back in
  (`enterCallerMemberScope` around `spliceInlineLambda`'s body). Two
  follow-on fixes the hygiene surfaced: the inline-splice receiver
  WALK no longer captures extension NAMESAKES (the static
  bare-extension resolution ranks `plus(element)` correctly inside a
  spliced `plusElement`; the walk's member-first runtime pick took the
  Iterable overload — plusCollectionInference), and a total-miss
  member tail resolves host-value members against the runtime class's
  shipped source (`UByteArray.isEmpty` runs its interpreted body over
  the host-served `storage`). `sumOf` on unsigned arrays routes to
  the dynamic-sum intrinsic like the List family. Pin
  `splice_hygiene_caller_members` (also pins the plusElement pick).
  Memory: per-site image clones blew compose's 6GiB RSS watchdog; the
  side-module clone is now SHARED process-wide behind a reentrant
  anon-lower lock, but even one clone's runtime-lowering resolution
  churn keeps compose near the edge, so `KLIO_ANON_BASE` is default
  OFF (=1 opts in) until runtime lowering gets scratch-arena
  discipline, and `scripts/compose-test.sh` runs under an 8GiB cap
  (64GB box; the unsigned image legitimately grew the suite ~300MB
  past the old 6GiB edge). One-off worker panic seen once in
  SnapshotStateMapTests (`acquireRegs` torn func read under
  concurrent on-demand lowering) — not reproduced; candidates noted.

- Shipping the unsigned value-class declarations (2026-08-02): adding
  `unsigned/src/kotlin/U{Byte,Short,Int,Long}{,Array}.kt` to the
  curated manifest creates the class rows the 168 `no_class_id`
  unsigned sites need — but it flips THREE representation-coupled
  channels at once and broke UIntTest/UnsignedArraysTest/MinMax*:
  companion constants (`UInt.MAX_VALUE`) resolve to the source
  companion and construct INTERPRETED `UInt(data=...)` instances that
  collide with host unsigned values; inline members
  (`toDouble() = uintToDouble(data)`) splice bodies that read `data` on
  the host repr; and direct-bound member bodies execute interpreted.
  An `invokeResolvedMember` intrinsic-preference guard (mirroring the
  virtual-path rule) did NOT fix it — the failing path is constant
  construction, not member dispatch. Prerequisite: unify the unsigned
  representation (companion constants and ctors must produce host
  values, inline splices suppressed for host-repr owners) — then
  re-add the manifest entries. Remaining `no_class_id` split for
  targeting: unsigned 168, incomplete type-param bounds (`M`/`C`) 81,
  `out#T` projection-prefix artifact 26.

- Proof-based promotion of the ext_* promo-blocked pairs, re-derived
  2026-08-03 with per-site why-tracing: of the sites reaching the
  proof, 49 carry NO argument type at all (`ty=-`) — they sit in the
  untyped-lambda-context cascade — 4 judge member-INCOMPATIBLE
  (correctly held), 2 unknown. The proof pipeline itself is sound;
  the gate is still argument authority, which the lambda/captured
  design front owns. Re-derive a THIRD time only after lambda-context
  arguments type.
- Proof-based promotion of the ext_* promo-blocked pairs (2026-08-02):
  a `memberPromotionProven` (member `.compatible` + every chain-related
  extension `.incompatible`, all-args-authoritative gate, mirroring the
  tower proof) was built, wired at the deferral, and measured ZERO on
  both fixed sets AND on a synthetic member/ext literal pair — the
  synthetic was already bound by the existing literal-disproof channel,
  and the real blocked pairs carry no authoritative arguments (the
  plan's standing `[extlit]` evidence). Reverted. The 185 ext_* pairs
  wait on the generic-argument project; re-derive the helper from this
  entry when argument authority exists.


- Boolean operator results; cast (`.As`) initializers; the `storage`
  splice hint (UByteArray has no IR class — host-symbol category);
  type-aware `extCouldApply` literal disproof (`[extlit]` zero
  literal-carrying queries). All built, measured zero on both sets,
  reverted.
- The type-param bound fallback in the `.Member` arm: `getOrPut`
  returns the caller's own `V`; the bound record drops the substituting
  arguments. Needs real inference.
- The return-type channel, built three times: green everywhere and
  bound ZERO extra sites (bound_static 196 identical). Its product was
  four latent interpreter bugs (thunks not pushing enclosing receivers
  — `init_lambda_encloses_instance`; `Func.return_ty` is a Unit
  placeholder for un-annotated expression bodies — `return_ty_declared`
  is committed separately). CLOSED as a direction.
- Head-only receiver evidence for lambda bodies, twice: the target
  population has no recv head at all (`with(xs) { iterator() }`).
- Star-erased returns, first attempt (2026-08-02): the owner-projection
  arm alone measured an IDENTICAL census. The reason was mislocated
  twice — the real null was the EXTENSION arm: bare `iterator()`
  resolves through the top-level pick with `receiver == null`, so
  `bindCallType` never runs, no receiver param binds, and
  `returnTypeBindingsComplete` refuses. LANDED once all three refusal
  points erase (owner projection, head-only receiver bind failure,
  receiver-less top-level pick): see the star-erasure ledger entry.
- Anon-object property type heads via a thread-local snapshot
  (2026-08-02): built and verified end-to-end — `buildObject` derived
  `iterator -> Iterator` from the captured `this`'s field value's
  runtime class plus main-module member resolution, installed it
  `setLowerAnonScopeRenames`-style, and `propTypeHeadOn` consulted it —
  and the body STILL emitted `CallMember`, because anon member bodies
  lower into `Module.default` side modules with NO class table:
  `uniqueClassIdBySimpleName("Iterator")` is null there, so every
  member call in every anon body is name-dynamic regardless of receiver
  evidence. Reverted. The real project is side-module lowering
  visibility into the main image (a base-module reference consulted by
  the class/registry lookups, or lowering anon members against the main
  module under its write lock); the prop-head snapshot is the right
  evidence channel to rebuild AFTER that lands. The anon-body population
  is the top of `[no-recv-name]` (`Sequences.kt` object expressions) and
  also feeds `no_class_id` (296 simple_unknown).
- `plusCollectionInference` five falsified theories:
  instantiation-dependent recordings (29,517 excluded, still fails);
  unbound splice param (`KLIO_SPLICE_TRACE`: `bound element: T`);
  `argDeclTypeRef` wrong (`element -> T`); `param_spec` gating (no
  change); splice substituting the caller's argument
  (`KLIO_EXTKEY_TRACE`: `recv=Collection args=T` picks correctly).
  Thread a span through `ApplicabilityScope` before a sixth.
- ArrayDeque nested-splice receiver hints (both variants): hint/receiver
  channels are restored per splice layer; the inner substitution never
  reaches the site.
- select arc falsified: defaults-padding discriminator; the `::fn as
  FnType` invoke break; raw-vs-mangled substitution identity; a
  resolveMemberCall memo (none exists). The `contains` recursion hunt
  excluded twelve routes (all `KLIO_ROUTE`-proven) before `KLIO_DUMP_FN`
  showed the baked static self-call.
- e2e base-cache eviction (`base_cache_max = 0` crashed identically).
- Claimed +46 from comparing baselines of DIFFERENT builds — always
  measure back-to-back on one build.

## Environment traps

- **Scratch homes in /tmp**: `/tmp/klio_itest_stdlibtest_home` (sweep)
  and `/tmp/klio_itest_compose_plugin_home` (compose, FIVE packs in
  dependency order). A failure reported by EVERY test, or an unresolved
  reference to an obviously existing name, is evidence about the
  ENVIRONMENT — `ls` the home's `packs/` before any interpreter
  hypothesis. The sweep and `scripts/compose-install-packs.sh` now
  install/refuse as needed. `assertEquals` cost nine wrong diagnoses;
  `runBlocking` cost two full sweeps.
- **KLIO_HOME is the PARENT of `.klio/packs`** — passing the `.klio`
  dir silently loses every pack. The full local home is the repo's
  `.klio-local` (26 packs).
- **Headless vs Skia**: corpus expectations are headless; a harness
  beside `zig-out/lib/libklio_skia.dylib` loads the real shim via the
  exe-relative `../lib` probe. Copy the harness to a scratch dir for
  drift sweeps of compose-ui text output.
- **Cache state**: lowering is on demand; censuses are comparable only
  cold. Installed-pack IR caches under `<home>/.klio/cache` — lowering
  traces fire only on a cold cache.
- **Stale installed packs shadow `kotlin-klio/` source** — rebuild with
  `scripts/install-local-packs.sh` after editing pack Kotlin.
- `scripts/compose-test.sh` honours an outer
  `kotlinx_coroutines_test_default_timeout` override.

## Instrumentation

`KLIO_DISPATCH_STATS=1` prints `[dispatch-stats]` (executed call forms)
and `[lower-sites]`/`[examples]` (per-site census) at run end — free
when off. The campaign's gated probes, all kept:

| Var | What |
|---|---|
| `KLIO_OR_AUDIT` | every emit-form decision with site tag (`Call/bare-tower-extension`, …) |
| `KLIO_BARE_TRACE=<fn>` | static bare-call resolution (`[bare]`, `[bareret]`) |
| `KLIO_BAREARM` | bare-member arm misses + break sites |
| `KLIO_DUMP_FN=<name|fid>` | baked instructions per bearer, per-block try metadata |
| `KLIO_ROUTE` | dispatch-route hit counting |
| `KLIO_SMAC_TRACE` / `KLIO_VALTY_TRACE` / `KLIO_SELDBG` / `KLIO_EF_TRACE` / `KLIO_REX_TRACE` | select-arc probes (`[smac]`, `[valty]`, `[seldbg]`, `[tbie]`) |
| `KLIO_EBM_TRACE` | expr-body member registry |
| `KLIO_PROMO_NAMES` / `KLIO_NORECV_NAMES` / `KLIO_LI_NAMES` / `KLIO_BCC_WHY` | census name splits |
| `KLIO_MISS_TRACE` / `KLIO_NU_TRACE` | runtime dispatch tails (see docs/development/debugging.md) |

Census A/B: every flipped default takes `=0`.

## Lessons

- Measure which code RAN before theorising about which should have; a
  probe's silence localizes better than its output.
- Better static types make previously unreachable implementations
  reachable — four times the fix was in the newly reachable thing.
- Wrong-answer fixes measure zero and are still worth landing; say so
  in the entry rather than reverting them.
- Every receiver-typing fix grows `resolver_declined` until
  argument-side inference exists — that growth is progress, not
  regression.
