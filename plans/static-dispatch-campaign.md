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

    stdlib:   total 8,273 member sites (anon-body sites now countable)
              691   8.35%  bound_static
            5,121  61.90%  bound_virtual     (70.2% bound; 2.34% at campaign start)
            1,774  21.44%  no_receiver_type
              267   3.23%  resolver_declined
              300   3.63%  no_class_id
              120   1.45%  nullable_or_generic

    examples: total 89,139
            4,856   5.45%  bound_static
           60,437  67.80%  bound_virtual     (73.3% bound; 37.4% at start)
           15,437  17.32%  no_receiver_type
            3,315   3.72%  resolver_declined
            3,816   4.28%  no_class_id
            1,278   1.43%  nullable_or_generic

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
drift 266/266 (out-of-process headless runner), parity pinned 150/151
(the one red is `backtick_this_param_not_receiver`, owned by
`resolution-unification-plan.md`), ir unit tests, `zig build test`.

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

## Measured dead ends and falsified theories — do not retry

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
