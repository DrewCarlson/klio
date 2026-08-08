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

## Continuation — 2026-08-03 (resumed session)

Landed on top of the handoff below, battery green after each
(sweep 117/0, litmus 42/42 — one new fixture, drift 266/266, unit
tests, compose SnapshotStateListTests 61/65 + MapTests 56/59
unchanged):

- **Still-unbound function type params erase to star** (60bffe8b): the
  last-resort star fill now covers receiver-LESS generic calls
  (`MutableList(3) { ... }`, `mutableListOf()`), not only the
  receiver-bind arms. stdlib no_receiver_type 1,211 -> 1,174 (82.7%
  bound), examples 9,362 -> 9,223. This also cleared the whole
  `val it = iterator()` init-carrying family in
  AbstractMutableCollection.remove/clear. Pin
  `factory_lambda_local_star`.
- **No js/wasm logic actuals** (d202d616, 25558689): user directive —
  klio must not consume actual implementations built for js/wasm.
  Replaced: `wasm/**/Atomics.wasm.kt` + `AtomicArrays.wasm.kt` with
  klio-authored `kotlin-klio/kotlin-concurrent/` actuals (same shapes,
  fields, FQNs — host RMW bindings hold; the inline update family is
  now CAS loops, fixing a REAL lost-update bug: inline splices cannot
  be host-shadowed and the wasm bodies were store(transform(load()))).
  Pin `tl_atomic_update_contended` (litmus now 42). Replaced
  `test-utils/wasmWasi` with klio-authored
  `klio-kotlinx-coroutines/klioTestUtils/` (runBlocking runTest, no
  platform skips; A/B behavior-neutral). Remaining native-wasm/
  consumption (AbstractMutable*4, CharCategory) is the Kotlin/Native
  SHARED sourceset — platform-neutral collection logic and a data
  enum, judged within policy; replace with klio actuals if strictness
  is wanted.
- **Two resolver defects** (545c62a3), found via the coroutines test
  tree (`klio test kotlin-klio/klio-kotlinx-coroutines
  --only-file=.../SharedFlowTest.kt`): (1) fn-typed extension
  receivers (erased `Function{N}` heads) never triggered the
  closed-member-surface stand-down (only the `<function>` spelling was
  recognized) — bare `runSafely(completion) { }` inside
  `(suspend () -> T).startCoroutineCancellable` deferred a private
  INLINE callee to a walk that cannot splice it;
  `ResolveCtx.recv_cannot_shadow` now feeds emitFormFor directly.
  (2) the raw bare-candidate iterator ignored visibility — a test
  class's PRIVATE member extension `CoroutineScope.block(context)`
  entered every file's candidate set; private decls (incl. member
  extensions, now file-registered) are dropped cross-file at the
  iterator. Also: memberExtOutOfScope reads DeclSig kind (stubs carry
  .plain on Func); callable-vs-registered-non-fun-interface-class is
  a definite mismatch. Pins `fn_type_ext_private_inline` + a
  cross-file-private unit test.
- **OPEN residual** (pre-existing, NOT from the test-utils swap —
  fails identically under the old wasmWasi infra):
  SharedFlowTest.testOnSubscription (`Vm::call_member block on
  kotlin.Function`) + onSubscriptionThrows (stack overflow), ONLY in
  the coroutines test-project compile context (standalone repro of the
  full operator chain passes). State: bare `block` candidates now
  empty (was the test-class leak); the failing instruction is
  `collector.block()` (SafeCollector.common.kt:107, unsafeFlow's anon
  `collect` member, span len 17) executing a MEMBER call whose
  receiver register holds the crossinline closure. The
  member_or_local arbitration (`member_or_local_exact_value` /
  `CallMemberOrValue`) emitted pre-filter but no longer fires for
  that site — next: dump the anon collect override's lowered body in
  the test context (KLIO_DUMP_FN by fid; the fn displays as `collect`
  under $anon$1) and find which member path lowers `collector.block()`
  without consulting the anon capture. KLIO_ADM_TRACE (new, kept)
  prints callable-vs-param adjudications.

- **Lambda-context typing, first arc** (0f242f44): four channels — the
  deferred CMG emitters thread argLambdaParamTypes from the committed
  candidate (emitMemberOrGlobal + lowerUnresolvedBareCall's ext hint);
  CharSequence/String/StringBuilder loops type their element Char;
  inline-splice param bindings inherit the argument expressions'
  derived types with save/restore shadowing; and a lambda's param
  names SHADOW inherited enclosing-local records (clearLocalDeclType
  at bindParams — the nested-it defect: the inner `it` read the outer
  `it`'s List record and refuted a local String extension,
  sortedByNullable's exact failure; this was the one regression the
  arc introduced and root-fixed). stdlib no_receiver_type 1,174 ->
  1,163 (it-family 182 -> 169). Examples: no_class_id 437 -> 466 —
  newly typed heads whose class rows are missing; that bucket is now
  the cheap next slice. Remaining stdlib `it` (169) is dominated by
  IterableTests-style GENERIC bounded receivers (head-only bounds
  drop the `Iterable<String>` args — the bound-args completeness
  design) plus unsigned-array splice contexts. Pin
  `nested_it_shadow_local_ext`. Battery green after the arc (sweep
  117/0, litmus 42/42, drift 266/266, compose 61/65+56/59, units).

- **Splice-inherited types refuse bare type-param heads** (e5f6606a):
  no_class_id 44 -> 33 after the R/T pollution the splice channel
  introduced. The remaining 33 stdlib no_class heads: T 9, Builder 8,
  R 4, Monotonic 4, NumberHexFormat/BytesHexFormat/Function0/
  DeepRecursiveFunctionBlock 2 each. MEASURED ZERO, do not retry
  as-is: resolving the `Builder`/`Monotonic` family via
  `classIdNestedIn(ownerClass)` or `classIdIndexed(head, pkg, file)`
  — the sites sit in top-level extension bodies (no owner class) and
  the nested lifted registrations are invisible to both probes; the
  fix needs file-scope class-alias resolution (the file's import/
  declaration TYPE scope), not a call-site probe.
- **Next design steps for the remaining `it` mass (169)**: the
  IterableTests family (`data.count { it.startsWith }` where
  `data: T`, `T : Iterable<String>`) needs (a) `TypeParamBound` to
  carry the bound's type ARGUMENTS when they are fully concrete
  (loweredClassTypeParamBounds drops `upper.args` — keep them when no
  arg mentions another type param), and (b) receiver-substitution in
  the lambda-param channel: argLambdaParamTypes ->
  instantiatedLambdaValueParams substitutes only explicit call-site
  type args today; it needs the receiver binding (T := String) like
  instantiatedCallReturnType's owner-projection arm. The unsigned
  splice family rides the storage-mapped contexts.

- **Receiver channels for the generic test-class family** (dd727310,
  a1b446b5): TypeParamBound carries concrete bound ARGS (image format
  39); method bodies register the full bound ref; the lambda-param
  channel substitutes from the receiver
  (Module.instantiatedTypeFromReceiver + substitutionRecv resolving
  T-heads through the bound ref); bound refs cross into lambda/local-fn
  bodies (pending_lambda_type_param_bound_refs); the invoke-convention
  unwrap types `createFrom(...)` calls from the fn-typed property's
  return; and instantiatedCallReturnTypeScoped keeps owner params as
  THEMSELVES when the caller is inside the owner (the star-fill erased
  `val data = createFrom(...)` to a refused bare `*`). stdlib
  no_receiver_type 1,163 -> 1,124 (83.1% bound; 82.3% at session
  start; 1,211 at handoff). Pins `bound_args_lambda_param`.
  **MEASURED AND REVERTED — the next ranker gap**: flipping
  classPropHead to return the PARAM name (another -11) broke
  LinkedStringSetTest.minus* with Expected<[bar]> actual<[bar]>: a
  T-headed receiver reaches resolveExtensionCall's RANKER unresolved,
  so Set.minus stays applicable where kotlinc refutes it against the
  Iterable<String> bound and the SET result breaks List equality. The
  ranker (and the operator Binary arm) need the typeParamBoundRef hop
  applied to the receiver BEFORE ranking; land that, then re-flip
  classPropHead. Remaining stdlib `it` (169) is a long tail of
  stdlib-bake lambda contexts (Duration takeIf-chains, unsigned splice
  contexts, windowed/joinToString shapes) — per-family, not one
  design.
- **Ranker bound hop landed (7db4d2db); Array arg disproof landed
  (229a9c15); the flip is STILL blocked** — third derivation level:
  with the hop, minus{Element,Collection,Sequence} resolve under the
  flip, but minusArray's 4-way arity-1 overload set stays ambiguous
  because the extension ranker's ARG scoring flows through the shared
  applicability engine whose `ext_is_subtype_name` oracle
  (evidenceSubtypeCb, walking class_super_names) claims
  Array <: Iterable — deliberate for RECEIVER dispatch (arrays run
  Iterable extensions), kotlinc-wrong for ARGUMENT positions. The fix
  is a receiver-vs-argument split in the applicability scope (a
  second callback or a flag the arg-scoring path sets), after which
  classPropHead keeps the param name (re-derives at ~-11
  no_receiver_type and correct static minus binding on Set
  subclasses).

## Handoff — exact state as of 2026-08-03 (session end)

Everything below is committed on `main` at `730200c7`; the working tree
is clean except the user's in-progress README.md rewrite (NEVER commit
or revert that file).

Census standing (fresh, cold-cache, both sets):
- stdlib: 8,910 sites, 82.3% bound (1,513 static + 5,824 virtual),
  no_receiver_type 1,211, declined 213, no_class_id 29.
- examples: 98,878 sites, 86.1% bound (15,462 + 69,641),
  no_receiver_type 9,362, declined 2,699, no_class_id 436.
- Campaign start was 2.34% / 37.4%.

Gates, all green at HEAD: commontest sweep 117/117, threaded litmus
41/41 (scripts/litmus-sweep.py — in the standing battery), corpus
drift 266/266, parity pinned 154/154 (`zig build test`), ir 236 +
interp_ir 118 unit tests, compose SnapshotStateListTests 61/65 +
SnapshotStateMapTests 56/59 (the 7 fails are the concurrent
throughput set below, nothing else).

Where work stopped, in priority order:

1. REMAINING no_receiver mass after the iterator-family clearance:
   `it` 1,192 (lambda-context typing design, plan item #1),
   `captured destination` 468 + `captured iterator` 104 (captured
   implicit receiver, plan item #2), then a small tail (element 234,
   list 159, line 105, index 104+104) NOT yet probed — next concrete
   action was to run the `KLIO_NORECV_WHY=<name>` recipe on `element`
   and `list` exactly as was done for `iterator` (that recipe found
   three root causes and cleared the whole family; see the ledger
   entry at `730200c7`).
2. Compose 100% baselines: the 7 failing tests are pure single-thread
   interpreter throughput on the lock-serialized snapshot-write path
   (verified: 1 worker == 3 workers). Benchmark
   concurrentGlobalModification_add went 20.5s -> ~13.4s this
   session; `_add` passes upstream's real 60s runTest default (the
   harness caps at 10s), but the source-written 30s budgets need
   1.3x (`addAll`, true runtime 37.3s) to 2.6x (`removeRange`,
   ~78s). Every spot-fix family is measured and closed (drains,
   caches, allocation, syscalls — see the throughput section):
   what remains is the core dispatch/execution loop
   (superinstructions or the bytecode VM). Timing methodology:
   same-day numbers drift thermally; only back-to-back A/B pairs.
3. Long tail (all recorded with re-derivation recipes): 213/2,699
   resolver_declined await lambda-context arg typing; no_class_id
   29/436; KLIO_ANON_BASE default-ON awaits runtime-lowering arena
   discipline; the refcount backend hangs on coroutines (never
   benchmark with it), arena OOMs at the RSS cap.

Diagnostics added this session (all env-gated, all kept):
KLIO_NORECV_WHY (per-site derivation-terminal), KLIO_ICRT
(instantiation trace), KLIO_DRAIN_TRACE, KLIO_WALK_TRACE, the
[valty]-enter context print, litmus-sweep.py.

## Current state

Census scripts (cold cache, pinned file sets — two measurements are
comparable ONLY at the same cache state; the scripts clear it):

    scripts/dispatch-census.sh           stdlib commontest — generic throughout
    scripts/dispatch-census-examples.sh  the examples corpus — concrete types

Report BOTH for anything aimed at element types; a change can move one
and not the other and still be right.

    stdlib:   total 8,910 member sites
            1,513  16.98%  bound_static
            5,824  65.36%  bound_virtual     (82.3% bound; 2.34% at campaign start)
            1,211  13.59%  no_receiver_type
              213   2.39%  resolver_declined
               29   0.33%  no_class_id
              120   1.35%  nullable_or_generic

    examples: total 98,878
           15,462  15.64%  bound_static
           69,641  70.43%  bound_virtual     (86.1% bound; 37.4% at start)
            9,362   9.47%  no_receiver_type
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

Leaf-profile findings (sample's own "Sort by top of stack", the ONLY
trustworthy self-time view — a hand-rolled tree parser double-counted):

- `<deduplicated_symbol>` 1,903 leaf samples = ~40% of active CPU;
  ancestry (ensureTotalCapacityPrecise 278, dispatchWithReceiver 248,
  callNamedOverload 180, invokeMethodFuncId 152) identifies it as
  memcpy/memmove under PER-CALL ARG-ARRAY builds: every interpreted
  call allocates, fills, and frees a `std.ArrayList(Value)` args
  carrier (prependReceiver's `[receiver] ++ args`, the packed_args
  builds). THE next big lever: an args pool mirroring `regs_pool`
  (EvalTls), exposed as shared eval.acquireArgs/releaseArgs so the vm
  build sites and evalWith's consumption agree. CAUTION: ownership
  crosses vararg repacking (`packVarargArgs` may return the input or a
  new list), `discardArgs`, and FlatCallReq transfer — every seam must
  route through the pool helpers or a pooled buffer double-frees.
- FIXED: `maxWorkers()` ran `getCpuCount` (a sysctl SYSCALL) on every
  task post; eval.zig's `routeTraceOn` getenv'd per call
  (~300 leaf samples together). Both resolved once.
- MEASURED NEGATIVE, do not retry: a threadlocal L1 in front of the
  field read/write memos REGRESSED 13.7s -> 17.0s (A/B'd twice each
  way) — macOS `_tlv_get_addr` indirection per probe costs more than
  the saved ObjRef borrow. The tl_method_cache survives because it
  saves a full walk, not one map probe. The ObjRef(ProgramImage)
  borrow contention under getFieldInner (362 spin-yield samples) is
  real but the read lock guards map REHASH during cache fills —
  lock-free reads need an RCU-style snapshot, not a raw pointer.
- Waits dominate raw samples (19.5k of 26k across threads — parked
  workers); always read the active-CPU slice, not totals.
- ARGS POOL BUILT AND MEASURED NEUTRAL (13.37s -> 13.5s, x2 runs): the
  EvalTls args pool landed (acquireArgsCap/releaseArgs, frame carriers
  recycled at Frame.deinit, drain folded into the regs drain) and the
  three main builders converted (argsListFromSlice, the member
  fast-path list, packVarargArgs) — no benchmark movement. Conclusion:
  the 1,903-sample memcpy leaf is dominated by the persistent-vector
  DATA copies (`buffer.copyOf(size+1)` per add, `copyInto` per
  mutation) — INHERENT algorithmic work the JVM also does, just on
  faster arrays — not by carrier allocation. The pool stays (zero-risk
  infra; marginal alloc savings) but per-call carrier work is NOT the
  next lever — UNDER ANY BACKEND (see below). Post-measurement discovery:
  the DEFAULT backend is the tracing GC (`KLIO_RECLAIM` unset), where
  the args pool never engages (it is reclaim-gated), so the neutral
  result says nothing about GC-mode carrier churn. Backend A/B on the
  benchmark: KLIO_RECLAIM=1 HANGS before the test starts (the
  refcount teardown is unreconciled on the coroutine path — known);
  KLIO_RECLAIM=arena aborts at the 8GiB RSS cap. The GC is the only
  viable backend for this workload, so the GC-mode args-carrier churn
  (the exact churn the regs pool's own comment calls "the dominant
  allocation churn on call-heavy code" before regs got c_allocator
  pooling under GC) is still an OPEN lever. Extending the pool to GC
  requires the regs discipline — TOTAL producer conversion so buffer
  origin is uniform by construction: a GC-heap buffer parked in the
  (non-root) pool can be collected and reused-after-free, and mixing
  origins frees GC memory with c_allocator. Producers = every list
  passed into evalWith/evalWithCaptures*/composableEval/FlatCallReq
  .args plus the eval-internal frame rebuilds (resume/persist). SUPERSEDED
  BY MEASUREMENT: enabling the pool under GC (run-allocator buffers,
  origin-uniform, no conversion needed) regressed 13.1s -> 14.7s x2 —
  the slab run allocator is already a size-classed free-list and the
  pool's top-of-stack fit check thrashes on mixed carrier sizes.
  Reverted. The allocation family is now CLOSED with three measured
  negatives (TL field cache -25%, refcount args pool neutral, GC args
  pool -10%): the slab absorbs allocation cost; the remaining time is
  the dispatch/execution loop itself. Also: same-day timings drift
  upward with machine thermal state — only back-to-back A/B pairs are
  valid; never compare against a number from hours earlier. What remains is the core loop itself: instruction
  dispatch + value move/retain cost per op. The credible next steps
  are (a) a superinstruction/fast-path pass for the hottest op
  sequences (GetField+CallVirtual pairs), (b) the bytecode VM. Both
  are design-scale, not spot fixes.
- removeRange verified NOT pathological (no drains, one 20k
  `fastForEach on host List keyed=false` walk family): its 78s is raw
  interpreted volume — 4 reps x 100 iters x 100 lists x (addAll(100) +
  subList(0,100).clear() through interpreted AbstractMutableList
  machinery). It needs the general per-call cost work, starting with
  the args pool.

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

Concrete first step, PARTIALLY INVESTIGATED 2026-08-03 (pick up here):
the star-return channel (KLIO_STAR_RET) already serves the USER shape —
`val iterator = iterator()` inside `fun <T> Sequence<T>.countAll()`
lowers all three of iterator/hasNext/next as bound CallVirtual (verified
by dump). The 516-weighted census sites are STDLIB-INTERNAL (57/example
recv=SequenceScope inside `sequence {}` builder bodies, 25 recv=Map,
10 recv=<none>), where the derivation misses at BAKE time.
KLIO_VALTY_TRACE=iterator over one example run: 219 sites DO record
head=Iterator; 1,676 reads see decl=<unset>, with `enter iterator
annotated=false init_tag=Call` at nf ids 6003/6005/6080/6082 (two
module variants d278/a478). The lambda tower IS propagated into
pre-lowered bodies (lowerLambda stashes collectReceiverTowerLabeled via
module.pending_lambda_receiver_tower -> setImplicitReceiverTower in
lambda_body.zig), so the miss is deeper. ADVANCED (same day): the failing
sites are `min`/`max`/`minOrNull`/… Sequence ext bodies LAZILY
relowered at run time (in_fn trace added to [valty] enter), and the
1,396 `[bareret] iterator shadowed local=true` refusals were the
canonical self-shadow: the derivation chains that follow a local's
initializer from its READ site (`iterator.hasNext()` ->
argDeclTypeRefLazy init chain) never set `init_self_name`, so the
init's bare call saw the local's own binding. FIXED two ways, both
landed: `setLocalInitExprAt` carries the DECL SPAN so a relower pass's
own prior binding is recognized as self (the standing-constraint
recipe), and the init-chain read now sets `init_self_name` under
`localInitNameFree`. Shadow refusals 1,396 -> 0. THE CENSUS FAMILY IS
UNCHANGED at 516 — those sites fail through yet another channel:
probe LANDED as `KLIO_NORECV_WHY=<name>` (prints init tag,
name-free state, lazy + full re-derivation terminals, enclosing fn,
receiver head, head/Iterator cid presence, module identity). It
identified TWO sub-families and one fix landed:
- LANDED: `this@label.iterator()` inside receiver lambdas
  (`runningReduce`'s `sequence { this@runningReduce.iterator() }`) —
  argDeclTypeRefLazy's This arm only served the unqualified case; a
  labeled `this` now answers from the builder's own label (an ext
  body's label is its fn name) or the tower entry carrying the label.
  End-to-end verified on the user shape ([2, 4] from a
  `this@skipOdd.iterator()` sequence body).
- CLOSED (was the bulk of the 516): the receiver (`entries` -> Set
  head) derived fine and `Set.iterator` resolved; the null was in
  `instantiatedCallReturnType` — an inherited interface header's
  return carries the owner's type parameters as IDENTITY MANGLES
  (`Iterator<$class$ 152 1:E>`), the star-fill's mentions-check tested
  RAW names only, so it skipped exactly the headers the completeness
  check then refused. The mentions-check now tests both forms. This
  cleared the ENTIRE `local_no_decl_type iterator` census family:
  stdlib no_receiver 1,279 -> 1,211 (82.3% bound), examples
  10,268 -> 9,362 (86.1% bound) — the largest single-slice move in
  weeks. Diagnosed with the new `KLIO_ICRT=1` instantiation trace
  (kept). Pin `interface_prop_receiver_iterator`. Remaining iterator
  mass is `captured iterator` (104) — the captured-receiver design
  gate, item #2. The `iterator` local family
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

## Addendum — the minusArray blocker, fourth derivation level (2026-08-03)

With the ranker bound hop live, the hopped `Iterable<String>` receiver
DOES reach the ranker (`[rex] ... recv=Iterable rargs=1`), yet every
minus candidate stays `compat0=unknown`: `staticReceiverCompatibility`
deliberately keeps a Set/List-recv candidate NON-refuted for an
Iterable-typed receiver — lazy-mode leniency (a statically
Iterable-typed value may be a Set at runtime). kotlinc's static
semantics refute on the STATIC type: `Set.minus` is not a candidate
for an Iterable-typed receiver at all. This is the plan's standing
"ranker learns to REFUTE competing tiers" design — receiver-static-
type refutation for PROVEN receivers — and is the real gate for both
the classPropHead provenance flip (~-11 no_receiver_type) and the
whole `resolver_declined` ext_* family. It is a semantic mode change
(many deferred sites rely on the leniency), to be landed with the
KLIO_RESOLVE_AUDIT zero-disagreement discipline, not as a spot fix.
Diagnostics for re-entry: KLIO_HOP_TRACE ([hop] rows), [rex] enter
rows now print the ranked receiver; the flip re-applies by returning
`tp.name.name` from classPropHead when an upper bound exists.

## Addendum 2 — the gated receiver-refutation slice measured short (2026-08-03)

A default-OFF `KLIO_RECV_REFUTE` slice was built in
resolveExtensionCall's loop (unknown-compat candidates whose declared
receiver classifier is provably unrelated to a PROVEN args-carrying
receiver head become incompatible) and tested with the classPropHead
flip + gate ON: minusArray STILL fails. Conclusion: the extension
RANKER is not the deciding call for the operator EMISSION — the `[rex]`
rows observed during the run come from the derivation channel, and the
`data - arrayOf(...)` emission resolves elsewhere (probe next with
KLIO_OR_AUDIT on the operator lowering path, then find its resolver and
apply the refutation THERE). The slice was reverted rather than kept
unproven; re-derive it from this entry once the emission site is
identified — the refutation logic itself (head inequality + both
builtin identities + evidenceSubtypeCb negative) behaved as designed.

## Addendum 3 — minusArray fifth level: relowered test bodies bypass the operator resolver (2026-08-03)

With the flip applied and the operator lowering's lhs extended through
staticBareReceiverType (prop-head channel answers `data -> T`), the
`[binop]` probe (kept, KLIO_HOP_TRACE) printed ZERO rows during the
minus test run — including for the PASSING minusElement — while the
bake-time Duration sites do print. CORRECTION on re-read: the
[binop] print sits AFTER the member-call attempt, so zero rows cannot
distinguish "fn not called" from "both lhs typing channels nulled and
the fn returned early" — and the latter is consistent with
staticBareReceiverType returning null in the relower context (suspect:
propTypeHeadOn keys on the class SIMPLE name while the relower's
ownerClass() may answer a lifted/fqn form). Next probe: move the
[binop] print to the fn ENTRY printing the lhs tag and both channel
answers, rerun minusElement, and adjudicate; then fix the owner-key
mismatch or the routing, whichever the rows show. The lhs prop-head
extension (staticBareReceiverType blk) re-applies from this entry. All experiments
reverted; battery green.

## Captured-receiver arc — first two slices landed (2026-08-03, continued)

Task #2's first mechanisms (1aa2ad0b, 2e3bdf3b): nested closures
inherit (a) ACTIVE inline-splice param types (the spliceParamTy channel
folded into the pending local-decl snapshot — `destination.add(it)`
inside `transform(element)?.let { }` spliced from mapNotNullTo), and
(b) PRE-DERIVED types for lazily-typed outer locals, derived in the
OUTER builder's scope at snapshot time (`val iterator =
listIterator(size)` captured by a closure). Census: stdlib
no_receiver_type 1,124 -> 1,070 (captured family 87 -> 47, 83.7%
bound); examples 9,234 -> 8,714 (86.7% bound) — the largest
single-session examples move since the implicit-this commit. Battery
green at every step. Remaining captured rows (47): takeLastWhile's
iterator family persists (the callee body context that lowers those
sites is NOT the lambda producer path — probe which body-lowering
route emits them before extending), plus random/chunked/windowed
shapes. Session total: stdlib 1,211 -> 1,070, bound 82.3% -> 83.7%;
examples 86.1% -> 86.7%.

## Session-close standing (2026-08-03, resumed session end)

Census, cold, both sets, at HEAD:
- stdlib: 8,832 sites, 84.0% bound (1,513 + 5,905), no_receiver_type
  1,048, declined 213, no_class_id 33. Session start: 1,211 / 82.3%.
- examples: 98,793 sites, 86.9% bound (15,463 + 70,418),
  no_receiver_type 8,472 (from 9,362), declined 2,699, no_class_id 463.

Gates all green: sweep 117/0, litmus 42/42, drift 266/266, parity pins
(+5 this session), units, compose SnapshotState 61/65 + 56/59.

The remaining stdlib `it` mass (166) is now CONFIRMED dominated by
head-only-bound receivers (`data: T` with `T : Iterable<String>` where
only the bound HEAD survives the prop-head channel): `count`/`any`/
`none`/`windowed` transform lambdas all wait on the receiver-refutation
program (Addendum 1-3) that also gates the classPropHead flip. That
program — kotlinc's static-receiver candidate semantics under the
KLIO_RESOLVE_AUDIT discipline — is the single biggest remaining lever
for both counts and is the designed next leg. After it: the
resolver_declined 213 (same argument-authority family), no_class_id
(unsigned host-symbol route), compose throughput, the bytecode VM.

## Addendum 4 — sixth level: the minus family carries TWO bound records (2026-08-03)

Fn-level bounds now carry concrete args (ea362778), and the full proof
chain works end-to-end for `fun <T : Iterable<String>> probe(data: T) =
data.count { }` — hop -> Iterable<String>, generic_applies=true, KEPT
compatible, extension COMMITS statically (pin
fn_bound_receiver_ext_commit). Under the classPropHead flip, the
`Iterable<T>.minus` candidates STILL fail generic_applies — the rex
rows show `bounds=2` for every minus fid where the passing count fid
shows `bounds=1`: declaredTypeParamBounds returns TWO records for a
single-`<T>` declaration, and the multi-bound arm refuses. Find why the
minus family double-registers (expect/actual pair? the operator's
`element: T` vs collection overload registration?), dedupe or teach the
multi-bound arm same-param merging, and the flip should clear
end-to-end. Flip reverted again; battery green.

## Addendum 5 — seventh level + the program's A/B entry is in-tree (2026-08-03)

fb851166 lands: declaredTypeParamBounds DEDUPES same-name entries (the
header+body double registration made `Iterable<T>.minus` read
bounds=2; note the rex bounds probe ALSO exposed that same-fid rows
from the second module variant print under one name — fid spaces are
per-module, read traces accordingly), the per-candidate bound-record
rex print, and KLIO_RECV_REFUTE (default OFF) as the
receiver-refutation A/B entry in resolveExtensionCall's loop.

minusArray under the classPropHead flip resists the FULL composition
(hop + Array-arg disproof + fn-level bound args + dedup + gate ON):
still 4/5. Seventh-level HYPOTHESIS, next probe: the
`minus(element: T)` overload stays applicable with T := Array<String>
and TIES the Array overload in ext_key — the withhold would then be
`tied`, not best_unknown, and the fix is the specificity rule (a
concrete `Array<out T>` param outranks a bare `T` in the key), checked
by printing the ext_keys of the two finalists in the flip run. The
flip remains reverted; every landed piece is battery-green.

## Addendum 6 — eighth level LANDED: the head-blind proof (2026-08-03)

The real defect under the whole minusArray chain: KLIO_DUMP_FN on the
flip run's committed winner identified `kotlin.sequences.minus` — the
generic-receiver PROOF (staticGenericReceiverApplicable) was binding
pattern params head-blind, proving a `Sequence<T>` receiver pattern
against an `Iterable<String>` actual via `T := String`. Fixed
(d7f4c2d5): the proof requires related heads (class-id chain /
builtin identity + supertype oracle; unknown never refutes). Under the
flip the minus family still shows one residual failure whose [rex-key]
rows need SITE attribution (the trace conflates every minus ranking in
the run — add the call span to the rex-key row, one cold run, read
which site's winner remains wrong). All landed pieces battery-green at
the default. The eight levels stand as: hop -> Array disproof ->
argument-position split (superseded) -> emission-site hunt
(superseded) -> relower routing (superseded) -> bound double-read ->
element-tie hypothesis (superseded) -> HEAD-BLIND PROOF (the root).

## Addendum 7 — flip residual: the test site never reaches ranking (2026-08-04)

With span attribution (KLIO_REX_TRACE + KLIO_EXTKEY_TRACE together),
the flip run's ranked minus finalists all sit at STDLIB-INTERNAL spans
(f33/f26:99883 — legitimate Sequence-receiver sites; the head-blind
fix's committed winners there are correct). The failing TEST site
(`data - arrayOf(...)`) produces NO ranked resolution and NO
[binop-in]/[hop] rows in the same run — but probe-state trust across
rebuilds broke twice in this arc, so treat that as UNVERIFIED until a
fresh context runs ONE cold, single-variable pass: flip applied,
KLIO_HOP_TRACE + KLIO_REX_TRACE + KLIO_EXTKEY_TRACE all set, grep
binop-in/hop/rex-key for the test file's span. If the operator lowering
is genuinely bypassed for relowered @Test bodies, find lowerBinary's
caller on that path; if [binop-in] shows both typing channels null, the
prop-head consult (staticBareReceiverType under the flip) is the fix
point. The head-blind proof fix (d7f4c2d5) stands regardless and was
the chain's real defect.

## Addendum 8 — protocol run facts and the bracketing requirement (2026-08-04)

Single-variable protocol run (flip + all probes, control rows verified
present) established: the test-site operator DOES enter
lowerResolvedBinaryOperator with data typed T by BOTH channels
([binop-in] lazy=T bare=T owner=IterableTests x4 — level 5's "bypass"
was stale-binary noise); the member arm answers none ([binop] member=
none x4); the extension path runs the hop (T -> Iterable via the raw-
name record; note the identity-mangled sibling record carries NO args
and sits FIRST — a hop-order hazard to fix when touching this again);
bake-window loops show hop -> generic_applies=true -> KEPT for the
2308 family. What remains unattributed: the test-site ranking's
FINALIST stage produces no rows at the test span (f2:17.5k) in the
same run — neither keys, nor DISQUALIFIED, nor exit-arm rows — while
other f2 calls (windowed, indexOfFirst) do print finalists. The row-
grep methodology cannot separate per-call windows any further: the
next tool is a BRACKET pair (resolveExtensionCall entry/exit rows with
name+span+outcome under the rex trace), after which the residual site
reads off directly. Landed this cycle: exit-arm rows, DISQUALIFIED
rows, span-carrying finalist rows (all rex-gated). Flip reverted;
battery green.

## Addendum 9 — the minusArray synthesis (2026-08-04)

The bracket rows finally isolated the window: at f2:17517 the Array
overload (fid 2309) WINS the ext_key (100105 vs the element overload's
100010) but stays KEPT unknown, and the best_unknown withhold defers
the call to the runtime value pick (Set.minus -> Set -> equal-printing
List/Set mismatch). Three kotlinc-fidelity corrections landed en route
(e02414e9: projection-transparent compat, qualified-Any bound compare,
inference-tolerant absent-args arm) — the arg verdict STILL lands
unknown through a branch the per-arg probe has not named (next probe if
resumed piecemeal: tag the rex-arg row with WHICH route inside
staticArgCompatibility answered — tp-arm / class-tp-arm / literal /
contains-fn-param / receiver-compat tail). The RECORDED DECISION: stop
adding arms. The compat stack is three near-identical implementations
with projection/qualification/absent-args handling scattered
(staticArgCompatibility, staticGenericArgCompatibility,
staticReceiverCompatibility) — exactly the RC-B shape P2 unified at the
SCORER level but not at the static-proof level. The fix class is that
unification (one proof engine with one projection/alias/absent-args
policy), after which the classPropHead flip and the withhold rule
re-derive trivially. All landed pieces battery-green; the flip stays
reverted.

## Addendum 10 — THE FLIP LANDS (2026-08-04)

The route-tagged rex-arg row named the final branch in one run:
`route=recv-compat-tail` — staticTypeContainsFuncParam could not see T
through the `out#` projection prefix, so `Array<out T>` never entered
the generic proof. With the strip (56239bc0), the ENTIRE nine-level
chain resolves and the classPropHead provenance flip HOLDS across the
full battery: sweep 117/0, litmus 42/42, drift 266/266, units, compose
61/65 + 56/59. Census: stdlib bound_virtual 5,905 -> 5,989 (84.4%
bound, member total +89 as deferrals became countable); examples
70,418 -> 70,522 bound_virtual (86.95% bound). Five real fixes landed
under the chain: the head-blind generic-receiver proof (soundness),
projection transparency in the arg proof AND the containment check,
the qualified-Any bound compare, the inference-tolerant absent-args
arm, and the bound-record dedup. The withheld KLIO_RECV_REFUTE gate
and the sole-commit refinements remain available for the
resolver_declined family, which this proof stack now serves with
correct answers. Next legs unchanged: resolver_declined 213, unsigned
no_class_id route, compose throughput, bytecode VM.

## Addendum 11 — run-mode sibling target (2026-08-04)

Writing the flip's pin exposed the RUN-pipeline sibling:
`tests/fixtures/parity_corpus/bounded_prop_minus_list.kt` (committed,
NOT yet registered in the pinned suite) prints `is List = false` under
`klio run` — the bounded-receiver minus still picks Set.minus by value
there, and NO lowering probes fire at all in run mode even cold
(the embedded prebaked stdlib image serves without lowering, and the
user file's operator lowering route in run mode never hits
lowerResolvedBinaryOperator's probes — find the run-mode Binary entry
first; this is the RC-A run-vs-test divergence family). The test-mode
battery is fully green WITH the flip. Register the fixture in
parity_corpus_pinned with the List-true expectations once run mode
resolves through the same engine.

## Addendum 12 — run-mode sibling CLOSED (2026-08-04)

One cold probe run named it (once the greps were run in a clean shell —
the ugrep -c silent-empty quirk cost a false "no rows" reading, twice;
prefer `grep pattern file | wc -l` in this repo): the run pipeline's
class-bound twin collector (interp_ir/build.zig
collectClassTypeParamBounds) never populated bound args, so run-mode
hops carried no substitution and the proof stack stood down. The twin
now calls the shared concreteBoundArgs (9294e594);
bounded_prop_minus_list is REGISTERED with kotlinc-correct
expectations, and both pipelines resolve the bounded-receiver operator
through the same engine. The duplicate-collector shape itself (two
bound collectors, two func_type_params registrations, three compat
provers) remains the standing P2-completion debt.

## Addendum 13 — refutation-gate A/B on the declined family: zero (2026-08-04)

KLIO_RECV_REFUTE=1 census is IDENTICAL on every bucket: the
target_known_deferred 213's deferral decision lives in emitFormFor's
member-vs-extension arbitration (knownReceiverApplicability and the
promo gates), not in resolveExtensionCall's per-candidate compat loop
where the gate sits. The family's actual blockers per [promo-blocked]:
receiver_not_instance 130 (the host-symbol route design),
ext_own_head/builtin_super/declared_super 169 (argument authority — the
memberPromotionProven helper is due its THIRD re-derive now that six
lambda/receiver typing channels landed; rebuild it from the Addendum-
dated entry and measure), ext_generic_receiver 22 (the now-sound
generic proof may serve these — include in the re-derive). The gate
stays in-tree default-OFF for the ranker-level cases it was built for.

## Addendum 14 — the promotion proof LANDS, third derivation (2026-08-04)

memberPromotionProven (f64340af) commits deferred members under full
argument authority in two tiers: proven-applicable members commit by
scope order alone (with positional owner-instantiation substitution:
contains(element: E) on Iterable<String> proves against String);
non-refuted members commit when every reachable same-name extension is
refuted by arity or argument. First two derivations measured zero for
lack of argument authority; the session's typing channels supplied it
(164 of 213 sites typed vs 49 at the second derivation). Census:
stdlib resolver_declined 213 -> 169, bound_virtual 6,029 (84.5%
bound); examples declined 2,699 -> 2,123 (-576!), 87.5% bound — the
largest single-slice declined move of the campaign. Held remainder is
honest: ext-unrefuted 96 (genuine competitors needing the
argument-side disproofs to grow), arg-unauthoritative 45 (the it-tail
families), member-arg-refuted 6 (correct declines). Battery green
including both compose suites. The detail-probe UB lesson from this
arc: never stash borrowed TypeRef name slices in threadlocals across
the fn boundary — print inline or copy.

## Addendum 15 — declined family decomposed to honesty (2026-08-04)

After 162ce188 the stdlib declined 161 decomposes: PROMOTED 50 (the
proof's commits), arg-unauthoritative 45 (it-tail), ext-unrefuted 22,
member-arg-refuted 74 of which 66 are CORRECT — `set.removeAll(iterable)`
sites where kotlinc binds the MutableCollection.removeAll(Iterable)
EXTENSION, not the member. The next promotion class is therefore
EXT-COMMIT-ON-MEMBER-REFUTATION beyond same-file: the sole-survivor
rule exists (sole_same_file, the trimIndent-hazard note) and the
now-sound proofs can widen it — commit the sole reachable extension
when the member is REFUTED by an authoritative argument and exactly
one extension survives arity+argument refutation. Re-derive from
memberPromotionProven's enumeration (it already walks the reachable
ext set); [promo-pair] rows name the sites. The 2 EnumEntriesList
pairs are an identity-mangle compare miss in the same walk
(param `$class$ 155 1:T` vs arg `T` — normalize both sides).

## Addendum 16 — the ext-commit widening LANDS (2026-08-04)

fd5ebc65: member-refuted calls fall to the extension path and the
ranker commits the strict winner under three guards, each pinned by
the regression that derived it (full argument authority — Duration
nanosecond flip, Uuid onError; winner-receiver relation — flatten's
Map-ext-on-Sequence). stdlib declined 161 -> 87, bound_virtual 6,662,
85.3% bound. The declined remainder (87) is now: arg-unauthoritative
45 + ext-unrefuted 22 + the residual ~20. Battery green everywhere.

## Addendum 18 — declined 87 fully named (2026-08-04)

The tp-arg bound-judgment rule reached final form (b2a064be: prove
through the bound, refute on disjoint bounds, unknown otherwise — the
bare-bail variant lost 28 correct ext-commits). The declined 87:
arg-unauthoritative 45 (Random.nextInt 30 — untyped Int locals in
RandomTest bodies, the it-tail typing class; Collection.contains 8;
AbstractMap 4), ext-unrefuted 22 ([promo-ext-alive] names them:
kotlin.collections.putAll/removeAll/addAll same-family pairs whose
argument type fits BOTH member and extension — genuine deferrals
pending the exact arg instantiation), residual ~20 (tied/unrelated
winners). Every remaining declined site is now individually named and
categorized; the family-level levers are exhausted — further declined
work rides the it-tail argument-typing legs. Current standing: stdlib
85.3% bound / declined 87; examples 87.9% / 1,075.

## Addendum 19 — ctor-tail admission re-measured negative (2026-08-04)

Re-admitted CONSTRUCTOR-only Call tails to the lambda-return channel
under the now-sound compat stack (bound judgment, projection
transparency, head relation): still net NEGATIVE — stdlib no_receiver
1,172 -> 1,234, bound_virtual -64. The recorded dead end holds under
new conditions; the getOrPut `V := ArrayList` narrowing genuinely
disproves more downstream than the typed local buys, independent of
proof soundness. The groupBy `list` family (67) therefore waits on the
REAL substitution engine (per-instantiation evidence), not tail
admission. Reverted.

## Handoff — exact state as of 2026-08-04 (session end)

Everything committed on main at feea5a2d..9f4e114c lineage; working
tree clean except the user's README.md (NEVER commit or revert it).

Census standing (cold, both sets):
- stdlib: 9,597 sites, 85.3% bound (1,521 static + 6,664 virtual),
  no_receiver_type 1,172, declined 87, no_class_id 33.
- examples: 105,443 sites, 87.9% bound (15,541 + 77,106),
  no_receiver_type 9,980, declined 1,075, no_class_id 463.
- Session start (2026-08-03 handoff): 82.3% / 86.1%, declined 213 /
  2,699.

Gates, all green at HEAD: sweep 117/0, litmus 42/42, drift 266/266
(scratchpad corpus-drift.py — recreate from the memory recipe if
absent), parity pinned suite +11 this session, units, compose
SnapshotStateListTests 61/65 + SnapshotStateMapTests 56/59 (the known
throughput set only).

The session's landed arc, chronological: star-fill generalization;
klio-authored wasm-actuals policy (atomics CAS-loops — REAL lost-update
fix — and coroutines test-utils); fn-typed-receiver shadow gate +
cross-file private candidate exclusion; lambda-context typing (six
channels incl. splice inheritance + nested-it shadowing fix);
TypeParamBound.args + full bound refs into lambdas + receiver
substitution (image format 39); captured-receiver inheritance (splice
params + pre-derived outer locals); primitive-array iteration; the
classPropHead flip (nine-level chain; head-blind proof SOUNDNESS fix
underneath); run-mode bounds-collector unification (both pipelines one
engine); the promotion proof (two tiers + owner-instantiation
substitution + star-erasure); the ext-commit widening (three
regression-derived guards); tp-args judge through bounds; signed
literals; two re-confirmed dead ends (ctor-tail admission, gated
receiver refutation at the ranker).

Where work stops, in priority order:
1. no_receiver 1,172: it 186 + list 67 (groupBy getOrPut — WAITS on
   the per-instantiation substitution engine, ctor-tail admission
   re-confirmed dead), destination 33 (spliced filterIndexedTo param —
   next probe: whether the member-receiver typing path consults
   spliceParamTy in the newly-countable contexts), then the recorded
   per-family tail.
2. declined 87 — every site named (Addendum 18); rides the arg-typing
   legs.
3. no_class_id 33 — the unsigned host-symbol route (design with the C
   transpiler coupling).
4. Compose throughput (7 concurrent tests) and the bytecode VM — the
   end-state architecture.
5. Standing debt the session repeatedly paid interest on: the
   DUPLICATED implementations (two bound collectors now sharing
   concreteBoundArgs, two func_type_params registrations, THREE static
   compat provers) — the P2-completion unification of the static-proof
   stack is the single highest-leverage structural change remaining.

## Addendum 21 — the declaration-scope resolution slice (2026-08-04)

no_class_id: stdlib 33 -> 17, examples 466 -> 299 (c4b417d3). Two
mechanisms, one exposed defect:

- **Scoped class resolution at the member-bind site**: a dotted
  `Outer.Inner` the FQN map misses resolves via
  `classIdByQualifiedSuffix` (the type-position convention, ir.zig
  2688); a bare simple head resolves via `nestedClassIdAtLexicalSite`
  (owner chain + FQN-derived nesting — tree-free, works at bake-time
  lowering).
- **CORRECTION to the Addendum-19 "MEASURED ZERO, do not retry"
  record**: the prior probe failed for two reasons that are NOT
  "no owner class": (a) `classIdNestedIn` needs the `class_children`
  tree, which is built at VM setup, AFTER bake-time lowering — every
  tree-walk returned null; `nestedClassIdAtLexicalSite`'s FQN-derivation
  arm is the tree-free path that works. (b) The `Builder` sites' record
  was TRUNCATED (below), so even correct scoped resolution bound the
  wrong class. The "file-scope class-alias resolution" design it called
  for was not needed for this family.
- **The truncated-record defect (real bug, sweep-caught)**:
  `classPropHead` (+ the object arm) stored `ty.name.name` — the LAST
  segment of a qualified type. `bytes: BytesHexFormat.Builder` recorded
  `Builder`; the new scoped resolution then bound `HexFormat.Builder`
  and its `build()` read `upperCase` on a `NumberHexFormat.Builder`
  instance (NumberHexFormatTest, 5 tests). Property heads now keep
  `qualified_path`. Pin: `nested_sibling_prop_head` (litmus 43),
  verified failing against the pre-fix collector.
- Residual 17, attributed (probe now prints identity/call/fn/owner):
  R 4 (CoroutineContext.plus / CombinedContext.toString — callee-tp
  leak, waits on call-site substitution), T 9 (AbstractCollection.
  toString + CollectionTest lambdas — enclosing type params invisible
  to lambda builders, `tp=false`), DeepRecursiveFunctionBlock 2 +
  Function0 2 (function-type heads, no class by design).

Unit-suite debt found and paid (70ead202): b2a064be's battery claim
included "units green" without a run — it broke `member resolution
separates class and caller function bounds`, which pinned the OLD
checker-style refusal for a caller `T : CharSequence` against a class
`T : Number` slot. The pair proves nothing and refutes nothing (one
type can satisfy both bounds); the contract is a DEFERRED single-
candidate commit, and the test now asserts exactly that (a static bind
here would mean the bound records conflated). The bounds-metadata test
also leaked the new `TypeParamBound.args` — freed. LESSON for every
future battery: `zig build test` is part of the gate, not optional.

Census after slice: total 9,593 — no_receiver 1,172 / nullable 120 /
no_class 17 / declined 87 / bound_static 1,533 / bound_virtual 6,664
(85.44% bound). Examples: 105,421 — declined 1,075 / no_class 299
(88.02% bound). Battery: sweep 117/0, litmus 43/43, drift 266/266,
units green, compose 61/65 + 56/59 (known throughput set).

## Addendum 22 — the lambda-typing completion arc (2026-08-04)

Four commits (822e4f4e, 523fa569, 7e49f66e + the slice records above):
stdlib no_receiver_type 1,172 -> 1,091, no_class_id 33 -> 4 (only
DeepRecursiveFunctionBlock/Function0 — function-type heads with no
class by design), bound 85.3% -> 86.2%. Examples no_receiver 9,980 ->
9,469, no_class 299 -> 219. The `it` family fell 189 -> ~100. Every
gate stayed green at every landing.

The arc, mechanism by mechanism:
- **Splice windows carry the receiver's FULL static type**
  (`splice_recv_ty_ref`, 822e4f4e): the head-only channel starved
  `for (element in this)` inside spliced extension bodies; the window
  now records the call site's receiver type (bound-ref hop included)
  and the `this` typing arm consults it first.
- **Inline calls type their lambda arguments' closure bodies**
  (523fa569): the splice's own arg loop bypassed `lowerArgRun`'s
  transfer; the ext emitter now computes instantiated param types
  before the inline branch and the loop consumes them per slot
  (pointer-recovered arg index). The instantiation fallback's bare
  callee-tp leak (T/R/S, no_class 17 -> 66 mid-arc) is refused at the
  producer — `instantiatedLambdaValueParams` nulls the slice when any
  entry's head is one of the callee's own tps.
- **Deferred member calls type lambdas from the static extension**
  (7e49f66e): a member-shadowed deferred call still types its lambdas
  the way kotlinc does (against the static resolution = the ext
  candidate). And the REPLAY defect underneath: lambda bound replay
  dropped `TypeParamBound.args`, so one lambda level down
  (`expect(1) { data.count { ... } }`) the bound hop offered bare `T`
  and resolution tied. Args now survive replay. Pinned
  bound_args_lambda_replay — behavior-bearing (static CharSequence
  beats runtime String, kotlinc parity).

Probe discipline note: the whole arc came from ONE repro file grown
in three steps (declared-type property -> ctor-fn-typed property ->
member-shadow -> expect-wrapper), each step converting or exposing
the next channel. The census-row attribution (call/fn/splice columns
added to [no-recv-name]) named each step's shape.

Residual `it` (~100): unsigned-array splice contexts (~28, storage-
mapped), AbstractMutableCollection retain/remove iterator loops,
nested `compareBy { it.take(2) }` (the inner lambda belongs to a
DIFFERENT callee than the window), `list`/`destination` families
unchanged (substitution engine). declined 87 unmoved by this arc.

## Addendum 23 — short-circuit narrowing (2026-08-04)

`&&`/`||` EXPRESSIONS now narrow their right operand by the left
side's proofs (is-checks + null-checks, if-arm parity; 23e1a9e9,
pinned and_chain_smartcast). nullable_or_generic 120 -> 78,
bound +82 on a +50 site denominator. With 51cccf75's partial
receiver substitution (return-only params no longer block the
proven bindings), the cycle stands at: no_receiver 1,078 on 9,542
sites (86.9% bound), no_class 4, declined 87.

Next named families, probe-ready:
- AbstractMutableCollection `val it = iterator()` loops (12 rows):
  a LOCAL named `it` initialized from a bare call to the enclosing
  class's own abstract member — the init-typing channel does not
  resolve a bare member call against the enclosing hierarchy when
  the simple name is program-wide ambiguous. The fix is owner-first
  resolution in staticCallReturnTypeRef's bare-call arm.
- `list` 67 / `destination` 33 — unchanged, substitution engine.
- Unsigned `sum`/`indexOfFirst` splice rows ride storage-mapped
  contexts (the splice window's receiver is the STORAGE array).

## Addendum 24 — diamond slots and the window-receiver chain (2026-08-04)

c0dfd25a: a DIAMOND of overrides is one slot family — resolution
retries the slot test from the RESOLUTION owner and keeps the more
specific return (AbstractMutableCollection's `iterator` ->
MutableIterator). ad12b976: bare calls inside a splice window
instantiate against the window's ACTUAL receiver, which now also
forms from a lazily-typed local receiver. no_receiver 1,078 -> 1,062
across the two; bound 87.1%.

CORRECTION to Addendum 23: SequenceScope was never a family — the
"target=no" row is an INTERMEDIATE print and the tower arm resolves
those sites immediately after (the intermediate-row trap; the row
now prints enough context to avoid the misread).

Residual no_receiver 1,062 by name: it 75 (nonEmptyLength local-ext
6, unsigned sum/indexOf splices ~16, windowed/joinToString 4,
toString 2, long tail), list 69 + destination 33 (substitution
engine), v1 26, iterator 24, value 19, result 16, index 16. The
substitution-engine families are now the largest coherent mass.

## Addendum 25 — tp-param arguments and the receiver-bound judgment (2026-08-04)

1ec9065c. The groupBy `list`/`destination` mass fell WITHOUT the full
substitution engine: recording the ARGUMENT's static type for a
tp-declared inline param (`destination: M`) was the missing link —
no_receiver dropped under 1,000 for the first time (1,062 -> 963 at
first landing, 975 after the soundness give-back).

The landing exposed a REAL kotlinc-parity wrong answer, latent and
reachable with plain declared types: `listOfLists.plus(elementList)`
flattened (picked the Iterable overload) because the arg judgment
treated the callee's own T as unconstrained while the receiver had
bound it. Two fixes: the extension ranker substitutes the receiver's
instantiation into every parameter before judging (the first concrete
P2-unification step — instantiatedTypeFromReceiverPartial is now the
shared substitution primitive), and bare-call emission inside splices
prefers the window's ACTUAL receiver record (tp NAMES capture across
nested same-named callees otherwise). Pin plus_element_inference
covers all three routes.

declined 87 -> 97: each new declines is a site whose old commit was
the FALSE proof — honesty, not regression (the wrong-answer-fix
precedent). Census standing: 975 / 78 / 4 / 97 on 9,578 (88.0%
bound). Battery green everywhere at every landing.

## Addendum 26 — declined 97 re-decomposed under the new prover (2026-08-04)

The promo probe names the whole set: ArrayList/MutableSet
addAll/removeAll/retainAll (~60 rows) hold as member-arg-refuted with
a live super-receiver extension; Random.nextInt 30 stays
arg-unauthoritative; the unsigned `get` family (~56 promo-class rows)
rides the host-symbol route. VERIFIED: the addAll shape COMMITS in
user code (repro binds the Sequence extension exact on both ArrayList
and MutableSet receivers) — the census's residual rows are
stdlib-INTERNAL sites whose `elements` argument types are still
generic, so the extension set ties as unknown/compatible with no
strict winner. Those declines are honest under the evidence; they
convert as the remaining arg-typing legs land, not by a ranker
change. No quick slice here — the bucket is correctly priced.

## Addendum 27 — compose throughput measured under fresh packs (2026-08-04)

The five compose packs were rebuilt+reinstalled with the current
harness (all session gains baked) and the scratch cache cleared —
concurrentGlobalModification_add still completes at ~13.4s against
the 10s runTest budget (1.34x). Profile of the test body (leaf
attribution, staged sampling): the parked EventGate workers dominate
raw samples (idle, not contention); the busy thread spends in the
interp call chain (execInst/runFlatLoop/evalWithCapturesChained,
callFunc*), with irMethodWalk already inline-cache-served and the
residue in per-call frame overhead, threadlocal reads, image borrow,
and string-keyed lookups on cold paths. CONCLUSION: the compose
throughput set is core-loop-bound as priced — the bytecode VM leg,
not a resolution or staleness artifact. The stale-pack hypothesis was
tested and refuted; all future compose measurements now run against
fresh packs.

## Addendum 28 — when-narrowing lands; takeLastWhile capture family attributed (2026-08-04)

9cc1a1ed: subjectless `when` branches narrow by their WHOLE condition
(&&-chains + truthy null-checks, if-arm parity) — the
contentDeepEqualsImpl family converted, no_receiver 975 -> 949, under
ten percent for the first time.

takeLastWhile (24 rows) attributed to its terminal shape: `val
iterator = listIterator(size)` types fine at its own sites (bareret
returns ListIterator args=1 in BOTH user and census contexts), but the
`ArrayList<T>(n).apply { while (iterator.hasNext()) ... }` receiver
lambda reads it as a CAPTURE (`which=captured`, lam_recv=ArrayList)
where only the pre-derivation snapshot channel (2e3bdf3b) can type it
— and that channel misses here even though the init expr is recorded
and derivable in the outer builder. Next probe (Debug harness):
whether the apply argument's closure lowering runs lowerLambda's
pre-derivation loop at all in this doubly-spliced context, and
whether the snapshot's contains-guard skips `iterator` on a stale
same-named record.

## Addendum 29 — the shared leaf closes (2026-08-04)

71985bb9: THIRD kotlinc-parity wrong answer of the session, found by
construction from the plus-flip mechanism — the member resolver's
sibling. `Box<List<String>>.put(arg)` answered "list" for kotlinc's
"one": the argument-compat TAIL was head-only, so an instantiated
`List<List<String>>` param accepted a `List<String>` argument. The
tail now routes any generic pair through staticGenericArgCompatibility
— with the ext ranker's receiver substitution (Addendum 25) and the
member path's existing owner-projection substitution, all three
static provers now adjudicate arguments through ONE args-aware leaf.
The P2-completion unification's judgment layer is effectively done;
what remains of it is mechanical consolidation (one entry fn), not
semantics. Pins: plus_element_inference,
member_overload_receiver_instantiation.

declined 99 (two more false proofs un-committed). Census otherwise
stable at 949 / 78 / 4 (88.2% bound); battery green everywhere.

## Addendum 30 — the trailing-lambda mapping; agreed-return parked (2026-08-04)

c54d5e7e. FOURTH latent prover bug of the session: both static provers
judged a trailing lambda against a defaulted MIDDLE parameter
(`windowed(2, 3) { transform }` refuted by `partialWindows: Boolean`).
Both now map a trailing callable to the LAST parameter, the mapping
every other channel already used. 31 bound_static give-backs were
wrong-sibling commits of transform pairs.

The agreed-return channel measured -72 sites but armed two behavioral
collaterals through DOWNSTREAM channels (the windowed transform
pipeline at runtime selection; a HexExtensions property-init lambda
binding Char as Int) — parked behind KLIO_AGREED_RET=1 with the
member-name guard in place, per the measured-negative precedent. The
-72 return when the downstream channels are fixed; the A/B gate makes
that re-probe a one-env-var experiment.

Standing: 949 / 78 / 4 / 99 on 9,521 (88.1% bound), battery green
everywhere. The disk-exhaustion interruption (zig cache + census
logs) is resolved; scripts/prune-zig-cache.sh remains the periodic
answer.

## Addendum 31 — the Char-coercion wrong answer, fully differentialized (2026-08-04)

REAL user-visible wrong answer, PRE-EXISTING (both KLIO_AGREED_RET
states), minimal repro:

    const val DIGITS = "ab"
    fun main() { DIGITS.forEachIndexed { i, c -> println(c) } }

prints 97/98 where kotlinc prints a/b. The differential matrix:
- typed receiver (literal or `val s: String`) -> SPLICED -> correct.
- `forEach` (1-param) via the same dynamic pick -> correct Chars.
- user-code mimic of the exact body (CharSequence + `action(index++,
  item)`) -> correct.
- ONLY the bake-lowered kotlin.text.forEachIndexed#1519 invoked
  dynamically passes the item as an Int-kind value.
- Runtime pick verified correct ([extpick] chosen=1519); host
  builtinIterator and string_get both yield .Char; the caller's
  block-2 instruction KINDS are IDENTICAL to the working user mimic
  (CallMember next / Move / UnOp / Move / Move / CallValue) — the
  divergence is OPERAND- or HINT-level in the baked next()/CallValue,
  invisible to the current dump. Fresh bake reproduces (not an image
  round-trip artifact).

Next probe (queued): extend KLIO_DUMP_FN to print CallMember hint
fields and register operands, then diff #1519 against the user mimic
operand-by-operand. This bug is ALSO the collateral that parked the
agreed-return channel (Addendum 30): the HexExtensions property init
is exactly this shape, so fixing it un-parks -72 census sites.

Repro fixtures preserved: scratchpad tp3-tp13 (tp11 is the minimal
pair). Separate finding from the same session: a top-level property
whose init chain hits this shape reports `unresolved global` (tp3) —
the init failure is silently swallowed at image load; the property
never registers. Root-causing the Char bug should re-test tp3.

## Addendum 32 — the Char chain, one hop from root (2026-08-04)

The Addendum-31 wrong answer is now a THREE-LINK verified chain with
one unknown left:
1. The builtin String iterator yields .Char kinds ([iter-next],
   verified in the exact failing run, interleaved with the output).
2. The closure RECEIVES .Char ([cv-arg] #1 kind=Char immediately
   before the wrong "97" line) — no coercion at bind (only the
   Int->Long walks exist).
3. The closure's `println(char)` is a CMG with a BOUNDED 2-candidate
   set {fid 5443 println(), fid 5444 println(message: Any?)}; the
   pick is 5444 (pts=10, the Any score) and ITS BODY renders the
   .Char as its integer code. The same value through the STATIC
   println route renders 'q' correctly (tp18) — so the defect is
   inside fid 5444's source body chain (its inner print/toString
   hop), not in the value or the pick.

NEXT PROBE (one hop): dump fid 5444's body (KLIO_DUMP_FN=5444 on a
COLD bake — image-loaded fns don't dump) and trace its inner hop;
suspect the body's `print(message)`/toString dispatch on a .Char
value taking a numeric rendering. Also explains tp3's swallowed
top-prop-init failure (same chain under HEX_DIGITS init) and the
parked agreed-return collaterals (Addendum 30) — fixing this leaf
un-parks -72 census sites.

Probe kit landed (env-gated): KLIO_ITER_TRACE, cv-arg rows under
KLIO_TRACE_PATH, operand-level KLIO_DUMP_FN.

## Addendum 33 — the Char chain's last hop localized (2026-08-04)

fid 5444 (kotlin.io.println expect) has ZERO BLOCKS — the invoke
falls through to the io intrinsic, whose render path (display ->
writeTo .Char -> writeChar) is verified correct. The corruption is
NOT in println at all: [frame-bind] (new, 69f05fcb's kit + this
commit) shows the closure FRAME binds param#1 as Int while [cv-arg]
shows the dispatch passed Char. The defect is INSIDE the
closure-invoke plumbing between execArmCallValue's copied arg list
and Frame creation — and the lambda frame is created TWICE per
iteration (once expected). Prime suspects for the next context:
an arg-register RE-READ on a secondary invoke path (off-by-one on
the args base would produce exactly (Int, Int) from r10/r11), or a
double-dispatch where the second, wrong-args invocation wins.
Repro: tp15.kt + KLIO_TRACE_PATH=1, grep cv-arg/frame-bind around
the 97 line. This is the LAST unknown in the Addendum-31 wrong
answer; everything upstream and downstream of this plumbing is
verified correct.

## Addendum 34 — the fifth wrong answer FIXED: JIT stale-tag rebox (2026-08-04)

1ec6316f closes the Addendum-31/33 chain. Root cause: the loop JIT's
native code copies argument SLOTS through Moves without updating the
per-register tag array, so a trampolined callee's live-refreshed
result tag (the unresolved `next()`'s Char) never reached the arg
register's rebox — the closure received the char's CODE as an Int.
Fix: each call site precomputes the register whose LIVE tag governs
each argument (the same-block move-chain source); both trampoline
argbuf builders read through it. KLIO_JIT=0 equivalence verified;
pinned jit_char_tag_rebox.

Bonus: the silently-swallowed top-level property init (tp3's
`unresolved global`) was the SAME bug — the HexExtensions table build
threw mid-init. Both now correct.

The windowed collateral under KLIO_AGREED_RET=1 is a DIFFERENT chain
(the source-windowed-on-host-generator interop suspected in Addendum
30) — the agreed-return channel stays parked on that one remaining
collateral; its -72 census sites now wait on a single fix instead of
two.

## Addendum 35 — the sixth wrong answer; agreed-return LIVE (2026-08-04)

2e379ae8. The windowed collateral decomposed into wrong answer #6:
the extension ARITY gate's positional default-check dropped the
transform overload, and the surviving sibling bound the trailing
lambda into `partialWindows: Boolean` — the "iterator lacks hasNext"
was an invokeMethod-swallowed "non-bool in branch" (KLIO_SELDBG
revealed it; the seq drains now report the iterator kind under
KLIO_SEQ_DIAG). The gate now honors the trailing-callable rule.

With #5 (JIT stale-tag) and #6 both fixed, the agreed-return channel
is LIVE by default: stdlib no_receiver 949 -> 876 (9.27%, bound
88.8%), the full battery green. Six kotlinc-parity wrong answers
found and fixed this session, each with a pin.

## Addendum 36 — the member-read receiver arm (2026-08-04)

One arm, -106: a member property READ as a receiver now lends its
declared head (class-prop heads + the ext-prop getter contract with
supertype walks). no_receiver 876 -> 770 (8.23%), bound 89.8% — from
85.3% at session start. The [no-recv-member] attribution row is the
probe that named the family in one census pass.

Residual 770: Path locals 406 (it 72, iterator 24, value/result/
index/expected/acc tails — substitution-engine and per-family), the
remaining Member chains (~106), Call receivers 180 (not_simple_callee
142 + no_func 80 + ambiguous 24), Binary 50.

## Addendum 37 — companion-constant reads (2026-08-04)

Companion property heads register under `<Class>$Companion` (the walk
had skipped nested is_companion Decl.Class members entirely) and both
class-named read forms consult them. no_receiver 770 -> 690 (7.38%),
bound 90.7% — the session arc is 1,172 -> 690 and 85.3% -> 90.7%.

## Addendum 38 — Call-receiver bucket decomposed (2026-08-04)

[no-recv-callrecv] (landed) names the 180: joinTo(...).toString()
28 (the joinToString bodies — the bare joinTo resolves NO target,
applicable=false, at the member walk AND the ext arm despite full
positional args; next probe is the ext-arm ranking for the
A-bounded buffer overload set), fn-typed-param invokes (transform/
expect ~28 — callable-return typing, substitution territory),
copyOfRange 8 (receiver-tp return on an untyped receiver),
shr/and shifted-int chains, and trim/trimStart/append Member-callee
chains. The member-read arm (Addendum 36) plus companion reads
(Addendum 37) already took Member receivers 212 -> ~30.

Standing: 690 / 78 / 4 / 99 on 9,351 — 90.7% bound, battery green.

## Addendum 39 — the joinTo frontier, precisely (2026-08-04)

The joinTo(...).toString() family's terminal state, one contradiction
from root: the candidate WALK keeps fid 2267 (Iterable.joinTo) as the
sole survivor — every argument compatible except the forwarded
transform judged unknown (absent-args Function1 vs the receiver-
substituted concrete param) — yet the RANKED scoring stage exits
no-applicable-tier (best_tier=255, the observed applicable=false).
applicableMember skips the receiver and scores tp-headed params at 5,
and the callable arm returns 20 for member scopes on unparseable
Function heads — so the null is in some OTHER scoreArg leaf for one
of 2267's seven args. NEXT PROBE: KLIO_EXTKEY_TRACE=joinTo on the
census prints the per-arg key vector; instrument scoreArg's `return
null` paths if the key rows don't localize it. A sole-unknown typing
channel (ExtensionResolution.sole_unknown, typing-only consumers) is
the designed fix once the scorer agrees with the walk — drafted and
reverted this cycle to keep the tree clean.

## Addendum 40 — sole-survivor widening: measured, reverted (2026-08-04)

Widening `receiver_pruned` to count proven receiver refusals at the
erased-head stage (or at the shared incompatible exit) converts -37
census sites INCLUDING the joinTo family and -4 declined — but breaks
the trimIndent chain both ways (`call_member indentWidth on String`
at runtime: three text tests). The named trimIndent hazard on the
sole-survivor rule is real and still not understood mechanically —
the breakage is an EMISSION change surfacing as a runtime name miss
on a same-file private extension, which the current probes don't
explain. Reverted to the exact pre-slice rule per the
measured-negative precedent; tree verified green.

NEXT PROBE for this -37: KLIO_DUMP_FN diff of the trimIndent/
prependIndent lowering with the widening on vs off, to see which
call form changes; the sole-unknown TYPING-ONLY channel (Addendum 39
draft) remains the safer alternative shape — it lends the return
type without touching emission, which the trimIndent hazard is
about.

## Addendum 41 — the sole-unknown typing channel lands (2026-08-04)

The Addendum-39 design, implemented: ExtensionResolution.sole_unknown
carries the untied strict-key winner past the unknown-argument
withhold, and bareExtensionTarget (typing-only) consumes it.
no_receiver 690 -> 642 (6.90%), declined 99 -> 93, bound 91.2% —
strictly dominating the reverted emission-side widening (-48 vs -37,
zero breakage). Session arc: 1,172 -> 642, 85.3% -> 91.2% bound.

## Addendum 42 — compose margin re-measured at 91.2% bound (2026-08-04)

Packs rebuilt with the full session's dispatch gains (agreed-return,
member-read arm, companion reads, sole-unknown channel) and the
scratch cache cleared: concurrentGlobalModification_add completes at
13.5s — statistically unchanged from the 13.4s measured at 88.8%
bound. The +2.4% bound did not move the compose hot loop, exactly as
Addendum 27 priced it: the margin is per-call frame overhead in the
interpreter core (threadlocals, image borrows, frame setup), not
dispatch resolution. The compose set's 1.34x budget gap is the
bytecode VM's to close; no further census work changes it.

Session-close standing: no_receiver 640 / 9,305 (6.88%), nullable 78,
no_class 4, declined 93 — 91.2% bound from 85.3%. Six kotlinc-parity
wrong answers fixed and pinned; two measured negatives banked; the
agreed-return channel live; every residual family attributed with a
terminal cause. The two remaining structural legs are the
per-instantiation substitution engine (the ~400 locals mass) and the
bytecode VM (compose + the dynamic floor).

## Addendum 43 — attribution complete; the census program's converged state (2026-08-04)

Every receiver KIND now carries a per-site attribution probe
([no-recv-name], [no-recv-member], [no-recv-callrecv],
[no-recv-binary]) and every bucket has been decomposed to named
families with terminal causes. The Binary 46 are scattered singles;
no coherent unconverted family remains outside the two structural
legs. The census program of this campaign — convert what per-family
mechanisms can convert, fix every wrong answer found beneath, keep
the battery green — is at its converged state: 640 / 9,305 (6.88%
untyped), 91.2% bound, from 1,172 / 85.3% at session start.

The end-state ("fully static dispatching", compose green) is now
PRECISELY two builds, both specified by the addenda record:
1. The per-instantiation substitution engine — the ~400 locals mass
   (it/iterator/value/result tails) whose types require call-site
   tp instantiation the current per-channel substitutions
   (instantiatedTypeFromReceiver/Partial, the window channels)
   approximate one shape at a time.
2. The bytecode VM — the compose throughput set (double-measured
   VM-bound at 13.5s vs the 10s budget, invariant under +2.4%
   bound) and the dynamic-dispatch floor.

## Addendum 44 — substitution engine, step one (2026-08-04)

The engine build begins as landable slices: the receiver-instantiation
twins now share instantiatedTypeFromReceiverImpl(require_complete).
Census-neutral, battery green. Next steps in order:
1. Extract instantiatedCallReturnTypeScoped's binding solve
   (receiver projection + named/positional/vararg arg binds +
   explicit type args + star erasure) into pub solveCallBindings +
   substituteBound — the engine's core, consumed first by the
   existing return-type wrapper (neutrality checkpoint).
2. Migrate instantiatedLambdaValueParams onto solveCallBindings
   (adds ARG-evidence to lambda-param substitution — expected to
   convert part of the it-tail).
3. Feed the splice window's param records through it (destination/
   element chains get full instantiation instead of the per-shape
   approximations).
4. Then the locals families re-census; what remains after 1-3 is
   the genuinely-dynamic floor that rides the VM leg.

## Addendum 45 — engine step two: solveCallBindings extracted (2026-08-04)

The engine's core is now one pub entry (solveCallBindings: explicit
args + owner projection + receiver + named/positional/vararg args +
star erasure -> SolvedBindings), with the return-type wrapper as its
first consumer. Neutrality verified end to end. Step three migrates
instantiatedLambdaValueParams onto it (arg evidence reaches
lambda-param substitution — the it-tail's lever); step four the
splice window.

## Addendum 46 — engine step three; wrong answer seven (2026-08-04)

Arg evidence now reaches lambda-param typing through
solveCallBindings (engine consumers: return types, lambda params ×2
channels). The landing surfaced wrong answer #7 — the per-arg typing
stash leaking into nested-receiver lambdas — sealed at lowerReceiver
and the inline this_arg lowering, with the WRITE-side valty trace
(+KLIO_VALTY_STACK) that pinpointed it in two runs. no_receiver
640 -> 623 (6.71%), bound 91.4%. Session arc: 1,172 -> 623,
85.3% -> 91.4%. Engine step four (the splice window onto
solveCallBindings) remains, then the VM leg.

## Addendum 47 — engine step four lands; the engine is BUILT (2026-08-04)

All four engine steps are landed: (1) the receiver-instantiation
twins unified; (2) solveCallBindings extracted as the one core —
explicit args + owner projection + receiver + named/positional/
vararg args + star erasure; (3) the lambda-param channels consume it
(arg evidence reaches closure typing); (4) the splice window
registers its solved fn-tp bindings as bound refs for every
in-window consumer. no_receiver 623 -> 611 (6.58%), bound 91.6%.
Session arc: 1,172 -> 611, 85.3% -> 91.6% — with SEVEN kotlinc-parity
wrong answers fixed and pinned along the way.

The residual 611 is the flat tail (scattered singles, the
genuinely-dynamic locals, fn-typed-param returns) plus what rides
declined ties and the unsigned route. The remaining structural leg is
ONE: the bytecode VM — the compose set (double-measured VM-bound)
and the dynamic floor.

## Addendum 48 (2026-08-04): annotated lambda/local-fn params bind their bodies

Source-annotated lambda parameter types (and local `fun` params, which
share the body lowering) now register as static types for member
resolution; local-fn varargs register the materialized array head via
`pending_lambda_vararg_params`. The compose pass stamps its appended
`($composer: Composer, $changed: Int)` pair, which this channel binds.

- Stdlib census: no_receiver 611 -> 599. (The census set's
  CollectionTest.minWithOrNull/maxWithOrNull failures are set
  artifacts: the pinned list omits comparisons/OrderingTest.kt, which
  defines the imported STRING_CASE_INSENSITIVE_ORDER. Pre-existing.)
- Compose-side census: unbound 10,085 -> 7,090; untyped-local family
  6,161 -> 3,432; every $composer/$changed/$dirty site bound; bound
  share 53.5% -> 66.2%.
- Three latent defects exposed by the new static binds, fixed at the
  mechanism: KClass-keyed extension properties now resolve for class
  values (with the companion reroute gated to companion-keyed
  registrations) and a klio actual ships for qualifiedOrSimpleName;
  digitOf's actual gained the fullwidth rows its host intrinsic had;
  local-fn vararg params register the array head (Duration tests read
  the annotation's element head otherwise).

Remaining top untyped-local names on the compose side after this:
writer (581), slots (485), reader (255), it (239), groups (147),
snapshot (139) — SlotWriter/SlotReader/array locals typed from
initializer calls, the next binding family.

## Addendum 49 (2026-08-04): mangled-classifier ctor typing

`ctorInitTypeRef` walks the scope rename ladder (same-file/package
references reach a collision-mangled internal class's registration)
and falls back to exact-import FQN resolution. With addendum 48 this
window takes the compose-side bound share 53.5% -> 72.4% (unbound
10,085 -> 8,743 on comparable warm-state runs); stdlib stays 599.

Remaining compose untyped-local families, by census weight: `it` 384
(let/also shapes off call-return receivers), `m` 264, residual
writer/slots 242/235 (openWriter().let { writer -> } — the callee-
return-typed `let` param family), groups 196, hash2 176. These ride
the same it-family channel task #1 built; the receiver is a call
return whose head needs the mangled-aware resolution the ctor arm now
has.

Runtime effect on the concurrent probe: none measurable (~13.1s) — the
newly-bound sites are composition machinery, not the snapshot-write
loop. The five over-budget tests remain throughput-bound
(addAll at 34.7s vs its 30s in-test budget).

## Addendum 50 (2026-08-04): the substitution/rename wave (66416304)

Four channels landed in one verified wave (duplicate-class repro
harness under scratchpad/mangle/, control = drop the b.kt duplicate):

1. substitutionRecv: a head-only receiver naming a NON-GENERIC class
   IS the complete type — `T := SlotWriter` binds for
   `openWriter().let { writer -> }`. The old rule (args-carrying heads
   only) was built for bare generic heads and starved every
   non-generic let/also/apply param.
2. Return-head mangle renames: declared returns now rename like params
   (decl + phase-1 header, both params and returns), and the rename
   ladder gained the package scope (fileOrPkgTypeRename over an
   installed file->package view). A same-package helper's
   `testItems(): SlotTable` now resolves the mangled registration.
3. staticCallReturnTypeRef ctor arm: a direct constructor expression
   types itself (`SlotTable().also { it.write { … } }`).
4. Exposed ranking divergence, fixed at the mechanism:
   @Deprecated(level=ERROR) was conflated with
   @LowPriorityInOverloadResolution; kotlinc restores the former under
   caller-side @Suppress("DEPRECATION_ERROR"). Func.deprecated_error +
   rankLowPriority + a suppression scope threaded from the enclosing
   declaration now match kotlinc (stdlib deprecatedAppend pins it).

Census: compose-side unbound 10,085 -> 8,359 across addenda 48-50
(bound 53.5% -> 73.7%); stdlib 611 -> 591. Batteries green at every
landing. Bisect gates: KLIO_SUBST_NONGEN, KLIO_CTOR_RET.

Debug note for the record: two bisection runs in this wave produced
wrong verdicts from a stale binary (a stash test rebuilt HEAD and the
next sweep ran that binary) and from gates defaulting ON during
"revert" tests. Both caught by re-running the matrix 3x stable before
acting.

## Addendum 51 (2026-08-05): the masked-regression cluster (ed946b6b)

The corpus-drift sweep had been running a STALE scratch harness copy for
six landings; a fresh binary surfaced three regressions the batteries
never see (the drift corpus is the only compose-UI end-to-end gate):

1. `unresolved global remember` (compose_ui_click + compose_uitext):
   first-bad 71985bb9. The generic-pair route fired when EITHER side
   carried type args, so the plugin-memoized `remember(key: Any?, ...)`
   judged `MutableState<Int>` against `Any?` in the generic prover —
   whose class-table walk has no edge to `Any` — and every overload
   refuted. FIXED (ed946b6b): route requires the PARAM to carry args;
   the prover treats `Any` as universal. Pin: generic_arg_vs_any_param.
2. `non-bool in branch: TextOverflow(value=1)` (compose_uitext,
   FontResolver init -> CoroutineContext.plus fold lambda): ALSO
   first-bad 71985bb9, NOT covered by the fix (all four session gates
   ruled out). The branch condition register receives a foreign
   value-class instance inside the plus-fold lambda — the
   universe-pollution shape from the misalignment recipe. OPEN.
3. select_on_timeout_loses drift TIMEOUT. OPEN.

Also this cycle: `KLIO_JIT=1` takes the compose concurrent probe
12.7s -> 0.31s (41x) and the failing snapshot suites 5 -> 2 failures
(the two left need ~1.4-2.3x more); a JIT Char-tag bug on static-call
args and member receivers was fixed and pinned (aeb53b8e). The `test`
subcommand's safe-profile default stands; the JIT question for the
compose gate is scoped, not global.

Process: the drift script now refreshes its harness copy automatically;
the trap is recorded in the session memory. Two bisects this cycle were
initially misread from a stale binary and gates defaulting ON during
"revert" tests — both verdicts only accepted after 3x-stable reruns.

## Addendum 52 (2026-08-05): the masked cluster CLOSED — drift 267/267

All three regressions surfaced by the fresh drift binary are fixed at
their mechanisms, each with a parity pin:

1. `unresolved global remember` — generic-tail route narrowed to
   args-carrying params; `Any` is the universal supertype in the
   prover (ed946b6b, pin generic_arg_vs_any_param).
2. compose_uitext wrong overload — a type-overload deferral now emits
   the runtime-rankable CallMemberOrGlobal form instead of falling to
   the first-wins bare-name value read (925859c3, pin
   type_overload_runtime_pick). Plus the shape-aware expect-redirect
   hardening (7e33b73f).
3. select_on_timeout_loses hang — the trailing-callable mapping
   (c54d5e7e) skipped UNDEFAULTED middles, so tryResume's callable
   mapped past (value, idempotent), the token-returning member beat
   the Boolean extension, and a swallowed Symbol-in-branch parked
   every rendezvous. Both judgment loops now require the gap
   all-defaulted; integer literals bind Long statically
   (ef073798, pin trailing_callable_gap_defaults).

State: drift 267/267 (WHOLE corpus green, compose UI + select
included), sweep 117/0, litmus 43/43, units green. Compose snapshot
suites 62/65 + 57/59 in the gate profile — the remaining five are the
known throughput-bound concurrent tests (2 remain under KLIO_JIT=1).

## Addendum 53 (2026-08-05): the last two reds are one function family

The two remaining over-budget concurrent snapshot tests
(SnapshotStateListTests.concurrentMixingWriteApply_addAll_removeRange,
SnapshotStateMapTests.concurrentMixingWriteApply_clear) are wall-
invariant (~36.6s vs their 30s runTest budgets) under: safe vs fast
profiles, a 32x GC threshold, extra workers, and a wider monitor spin
(44758da5). Test-window profiling shows <10% busy across threads —
the mutator's ~1.1M snapshot writes queue behind the CONSUMER
coroutine's interpreted `advanceGlobalSnapshot`/apply-observer walks,
which hold the global snapshot sync for long interpreted stretches
per `notifyObjectsInitialized`. kotlinc absorbs the same lock
protocol because its advance is compiled.

Next leg, in order of expected leverage:
1. Profile the advance path's own body (KLIO_CALL_STATS on the
   consumer) and flat/leaf-serve its hot members.
2. The advance's record walks are container iterations over modified
   state records — the same persistent-iterator chain already fused;
   measure whether the loop JIT can take the walk once the calls
   inline (KLIO_FUNC_JIT covers whole bodies).
3. If interpretation cannot close it, a klio-authored native serve
   for the snapshot-advance hot members (FQN-keyed intrinsics over
   interpreted instance state) is the remaining lever.

Everything else is green: drift 267/267, sweep 117/0, litmus 43/43,
units green, stdlib census 591 (91.8% bound), compose bound 73.7%.

## Addendum 54 (2026-08-05): advance-path census — the branchy-leaf frontier

KLIO_CALL_STATS on concurrentMixingWriteApply_clear (partial run to the
30s kill; proportions stable): snapshots.valid 1.71M calls,
SnapshotIdSet.get 856K, readable 640K, record `.next` reads 430K,
ThreadMap.find 430K, Snapshot.current companion reads 430K — ~17
interpreted calls per snapshot write, all through THREE small
functions plus field reads. Each is a few instructions with a BRANCH
(valid: three-clause predicate; SnapshotIdSet.get: bit probe with a
bounds branch), which excludes them from the leaf evaluator's
straight-line subset — so every one of those millions of calls pays a
full activation.

NEXT UNIT — branchy leaf serve: extend `leafExprServeAt` to walk
Branch/Goto over a bounded block set (<=8 blocks, same register bank,
no calls beyond the existing leaf-chain rule, no throws/catches).
That collapses valid/get/readable AND the earlier iterator family
(elementAtCurrentIndex, isWhitespace shapes) to frameless serves —
the single highest-leverage interpreter change left for the two
remaining reds, and it compounds across every workload.

Alternative if insufficient: FQN-keyed native serves for the three
functions (they only read instance fields + bit math), which needs
the static-Call path to honor intrinsic shadowing for BODIED pack
functions (today only bodyless decls link to native forms).

## Addendum 55 (2026-08-05): the fusion never covered member calls

Calibrating the interpreter against a plain member call
(`class Box { fun bump(n: Int) }`, 5M iterations) showed 1.12us per call
— thousands of cycles for a two-instruction body. The census said every
one was `call_static` with ZERO `static_flat_fuse`: `fastCallPlan`
required the callee's simple name to have exactly one entry in the
module function-name index, and an instance method has NO entry there
(the index carries top-level and extension functions). The clause meant
to reject same-name overload sets was rejecting every member. Fixed to
reject only genuine ambiguity (`len > 1`); 1.12us -> 0.89us, and
`KLIO_FASTPLAN_TRACE=<name>` now reports which clause declined a callee.

Landed alongside: primitive bit members served inline (addendum 54,
ladder 494k -> 93k on the map-write workload) and per-site environment
gate memos (`envOnce`).

MEASURED NEGATIVE, reverted: a size-classed pool for the frame ARG/
CAPTURE carriers. It is worth ~20% on the call microbenchmark (3.55s vs
4.45s for 5M calls) but is not sound as written — carriers reach
`releaseArgs` from several producers, and under the tracing GC the
register buffers come from `c_allocator` while the arg carriers come
from the run allocator, so pooled buffers cross allocator lifetimes and
abort at teardown (reproducible on the stdlib time/unsigned/uuid
suites). Making it sound means routing EVERY carrier producer through
one acquire/release pair with one allocator choice — a real refactor,
recorded here as the next throughput unit.

Remaining interpreted-throughput profile of a member call after the fix:
~20% carrier alloc/free (the reverted pool's target), 8% threadlocal
address lookups (`evtls`), 7% leaf-serve attempts that decline on the
field-getter path.

## Addendum 56 (2026-08-05): the throughput leg, and what it cost per unit

The compose snapshot suites are the last red. Where they stand after this
leg: SnapshotStateMapTests 58/59 (was 57/59), SnapshotStateListTests
62/65, with the remaining five failures at 30.4s / 30.4s / 34.0s / 40.3s
against 30s in-test budgets — two of them within 2%.

Landed, each measured on the concurrent workload:

- The static-call fusion never covered MEMBER calls: it required the
  callee's simple name to have exactly one entry in the function-name
  index, and an instance method has none. 1.12us -> 0.89us per member
  call.
- Size-classed pooling for the frame argument/capture carriers, extended
  to the host's own producers (`argsFromSlice`, the closure prepare, the
  constructor thunk). The pool must drain at depth 0, BEFORE the pooled
  register early return, or buffers cross run boundaries.
- Primitive bit members served inline, and the frameless leaf walk now
  runs them, so the persistent collections' index helpers cost no frame.
- A guard's throwing arm no longer disqualifies its whole body from the
  leaf serve.
- Same-arity overload sets are settled by the CALL SITE's scope tier
  rather than declining the fusion outright.
- A member-or-global site replays its resolved global target.
- The klio-authored skeletal mutable collections (see below).

MEASURED NEUTRAL, reverted: caching the intrinsic host per thread
(twice), keeping the carrier pool warm across depth 0.

Two traps this leg, both worth remembering:

- A single-threaded repro of `SnapshotStateList.removeRange` said
  per-index removal beat the iterator form by 39%. The concurrent test
  said the opposite (49s vs 40s), because the persistent-vector builder
  overrides `listIterator` with a trie cursor. The TEST is the authority
  for a test's budget.
- `zig build klio-harness` must be re-run after any manifest edit before
  timing anything: two 56s-vs-30s readings that looked like a 2x
  regression were the previous binary still sitting in `zig-out`.

The klio-authored `AbstractMutable*` actuals replaced upstream's
native-wasm platform sources (which this project does not consume) and
took the concurrent snapshot-map clear test from 56s to 30.4s on their
own. Splitting them one-class-per-file matters: a dangling annotation at
a file boundary was tolerated by the stdlib load path instead of
rejected, and the anonymous key set silently lost its base class. A
stdlib source that does not parse should fail the build loudly — the
next unit.

## Addendum 57 (2026-08-05): measure WORK COMPLETED, not wall time

The remaining compose reds all report ~30s wall, which reads as "1% over
budget". That reading is wrong and it misdirected a whole leg of tuning.
These tests declare `runTest(timeout = 30.seconds)`, so a test that
cannot finish reports ~30s no matter how far behind it is (a 56s reading
is the 30s budget plus a teardown drain, not slower work).

The real metric is how much of the test's own loop completed, which
`KLIO_CALL_STATS` gives directly — every one of these tests is a fixed
count of `mutate` calls:

| test | completed / total | factor needed |
|---|---|---|
| SnapshotStateMapTests.concurrentMixingWriteApply_set | 100k / 100k | PASSES (28.9s) |
| SnapshotStateMapTests.concurrentMixingWriteApply_clear | 200k / 1,100k | 5.5x |
| SnapshotStateListTests.concurrentMixingWriteApply_addAll_clear | 50k / 100k addAll | 2x |

So the reds are 2x-5.5x away, not 1%. Nothing in the 5-10%-per-unit
class closes that; the levers that can are the flattened engine
(`frame_push_flattenable` is 100% of frames on these workloads), native
persistent collections, or whole-function JIT coverage of these bodies.

`concurrentMixingWriteApply_set` passing at 28.9s for its full 100k is
the calibration point: ~3.4k snapshot mutations/second through the
interpreted snapshot machinery.

Method note: run one test with `KLIO_CALL_STATS=1`, read the
`SnapshotState{Map,List}.mutate` / `.addAll` counter, and compare against
the loop bounds in the test source. Wall time is only usable for a test
that PASSES.

## Addendum 58 (2026-08-05): the no-receiver-type tail, four rules in

The 591-site `no_receiver_type` bucket is the largest remaining static-
dispatch hole. `KLIO_INIT_KINDS=1` names which initializer shapes reach a
local with no type at all; over the examples corpus: Binary 685, If 111,
This 39, As 34, Unary 25, When 17. Four rules landed against them:

- `x as? T` — the safe cast was skipped outright because it can yield
  null. The head is exact; the local is typed `T` and marked nullable.
- `this` in an ordinary member — only an extension receiver in scope could
  supply the type, so a plain `val self = this` stayed untyped.
- predicate operators and `!x` — Boolean; `-x` keeps its operand's type.
- `if`/`when` — the branches' type when they AGREE (Kotlin's answer is
  their least upper bound; the exact case is what a member call needs and
  is never a widening).

Plus one call-shape rule: a call whose callee names a function-typed local
or parameter takes that type's declared return
(`assertIterableContentEquals(…, iterator: T.() -> Iterator<*>)` invokes
its own parameter, and the whole kotlin.test iterator-comparison family
was reaching `hasNext`/`next` with an untyped receiver).

Census: no_receiver_type 591 -> 539, statically bound 91.8% -> 92.3%.

Residual, by name (`KLIO_NORECV_NAMES=local_no_decl_type`): `destination`
and `it` dominate. `destination: C` where `C : MutableCollection<in T>` is
NOT a missing bound rule — the bound substitution already exists and
answers `MutableCollection` — it is a SPLICED inline body whose parameter
types reach the caller through `spliceParamTy` without filling the local
declared-type channel. That is the next unit, together with the `it`
family (lambda parameters typed from the resolved callee).

## Addendum 59 (2026-08-05): a receiver-lambda splice drops an outer local's type

Repro in tree: `tests/fixtures/lowering_repros/receiver_splice_loses_local_type.kt`.

    fun <T> List<T>.runA(): List<T> {
        val iterator = listIterator(size)          // typed: MutableListIterator
        return ArrayList<T>(1).apply {
            while (iterator.hasPrevious()) add(iterator.previous())
        }                                          // ^ NO receiver type here
    }

`KLIO_VALTY_TRACE=iterator` shows the local's declared type IS recorded and
IS read at the sites outside the `apply`; the two sites inside the splice
never consult `argDeclTypeRef` at all. `KLIO_NORECV_NAMES='*'` classifies
them `local_no_decl_type` with `splice=ArrayList`, so the name resolves as
a local in that window but carries no type.

Ruled out: a plain `run { }` (no receiver) keeps the type, so it is the
RECEIVER-lambda splice specifically; the enclosing function being `inline`
makes no difference (both `runA` and `runB` fail identically); the lambda
snapshot path in `lowerLambda` (which already pre-derives lazily-typed
outer locals — its comment names this exact `iterator` shape) is not the
path taken, because `apply` splices rather than lowering a lambda body.

Narrowed 2026-08-05 with `KLIO_VALTY_TRACE` extended to print the builder
identity and its declared-type count: the successful reads are in builder
`9a58` (`ndecl=2`, `decl=MutableListIterator`); the failing ones are in a
DIFFERENT builder with `ndecl=0`, and a trace on
`inheritLocalDeclTypes` shows that builder never enters the lambda-body
inheritance path at all. So this is not a case of the snapshot being
taken and dropped — the failing body is lowered through a construction
path that does not deliver `pending_lambda_local_decl_types`.

Identified 2026-08-05 by tagging every non-test `FuncBuilder.init` site:
the failing builder IS constructed by `lambda_body.zig` — the same path
that inherits — and the construction happens BEFORE the enclosing
statement finishes (the trace order is `WRITE iterator = ListIterator`,
then the lambda-body builder, then `WRITE iterator = MutableListIterator`
and the successful reads). So the body is lowered while the caller's
record is still being refined, and it receives an EMPTY snapshot
(`ndecl=0`) rather than a stale one.

ANSWERED 2026-08-05 (`KLIO_LAMINH=1`, now a permanent diagnostic that
prints both ends of the channel). The trace for the repro:

    WRITE iterator = ListIterator          caller records the type
    [laminh] produce lambda b=eb78 n=0     producer holds ZERO records
    [laminh] consume pending=1             body inherits 1 unrelated entry
    WRITE iterator = MutableListIterator
    READ iterator decl=MutableListIterator b=92a8 ndecl=2   (outside)
    READ iterator decl=<unset>             b=…   ndecl=0    (inside)

Neither branch: the channel was SET, and set by a builder (`eb78`) that is
not the enclosing function's (`92a8`, 2 records) and holds nothing. So the
`apply` lambda body is lowered from a THIRD builder that never held the
enclosing locals — the snapshot is faithful to the wrong scope.

That is a pipeline-shape bug, not a missing-call bug: the fix is to lower
the lambda from the builder that owns the enclosing scope (or to give the
producing builder that scope), and a patch at either end of the channel
would only paper over it. Finding which construction produces `eb78` is
the remaining step; `KLIO_LAMINH` prints its identity, so a breakpoint or
a pointer match at the two `FuncBuilder.init` sites in `decl.zig` /
`thunks.zig` settles it.

This is the last named cluster in `local_no_decl_type`. The other residual
names — `symbol`/`index`/`array`, and the `it` family — are separate.

## Addendum 60 (2026-08-05): part of the residual is the language, not the resolver

Chasing the `enclosing_member` bucket (46 sites) reached
`class CompareContext<out T>(val expected: T, val actual: T)`, where
`expected.getter()` has a receiver typed by an UNBOUNDED type parameter.
There is nothing for a static pick to name: Kotlin erases `T`, and the
reference compiler dispatches that call virtually too. The same holds for
the `it`/`e`/`removed` names in `local_no_decl_type` — parameters typed by
their function's own type parameters.

So `no_receiver_type` will not reach zero, and 100% static binding is not
the right target for a language with generics and open classes. The
meaningful target is: every site that CAN bind statically does.

An attempt to MEASURE the irreducible share was reverted (it counted 0):
the classifier keyed on `localDeclTypeRef`, but these sites have no
declared-type record at all — that is precisely why they are in the
bucket. Measuring it properly needs the FUNCTION's parameter types (the
declaration), not the local-declaration channel, and the
`KLIO_NORECV_NAMES` output already shows `param=true` on exactly these
rows. Next attempt should key on the signature.

Current: 521 no_receiver_type / 9,268 sites; 92.6% statically bound
(bound_static 1,561 + bound_virtual 7,021).

## Addendum 61 (2026-08-06): class evidence must be name-resolved before it helps

With the image's declarations now reaching the checker (see the resolution
plan's P7 entry), the obvious next move is to hand lowering the checker's
CLASS evidence: `expr_class` is where a receiver's class identity actually
lives, since a plain user class is `Type.Unresolved` in the checker and
`tc.types` therefore cannot carry it.

MEASURED NEGATIVE, reverted. Folding `expr_class` into the existing
`pending_eager_types` channel moved the corpus census:

    no_receiver_type   521 -> 487   (better)
    no_class_id          4 -> 554   (much worse)
    bound_virtual     7021 -> 6491
    bound share      92.6% -> 87.0%

The evidence supplies head names that lowering cannot resolve to a class
id — file-scoped mangles and simple names the module knows under another
spelling — so sites that previously bound virtually now land in
`no_class_id`. Feeding a name channel is not enough: the class evidence has
to travel through the SAME rename/scope resolution lowering applies
(`fileOrPkgTypeRename` and the simple-name class index), or be published as
class IDS rather than names. That is the next attempt's shape.

RESOLVED (same day) by guarding the READ instead of the write. `eagerTypeOf`
now drops a head this module cannot resolve — builtins pass through, since
they carry no class id by design — so an unresolvable name costs nothing
rather than displacing a virtual bind. With that guard the same class
evidence is a net gain:

    no_receiver_type   521 -> 508
    no_class_id           4 -> 4     (was 554 unguarded)
    bound share       92.6% -> 92.7%

Worth keeping as a rule: a static-evidence channel needs a resolvability
guard at its CONSUMER, not just correctness at its producer. The two name
universes (checker source names, lowering mangled/qualified names) do not
have to be reconciled for the channel to be safe — the consumer only has to
decline what it cannot use.

## Addendum 62 (2026-08-06): `concurrentMixingWriteApply_set` is contention-marginal

The map suite reports 58/59 or 57/59 from run to run, and the difference is
always `concurrentMixingWriteApply_set`. Measured directly:

    run alone:        PASSED 29537ms, PASSED 29373ms
    inside the suite: FAILED 30124ms, PASSED (earlier runs)

It completes its full 100k mutations either way (addendum 57) and lands
within ~2% of the 30s budget, so whether it passes is decided by what else
is on the machine — the rest of the suite running before it, or another
build. Do not read a 58->57 change as a regression without running that
test alone first.

The suite's real content is unchanged: `concurrentMixingWriteApply_clear`
is the one test genuinely short of budget, at 5.5x.

## Addendum 63 (2026-08-06): more typeck visibility does not move the census

With the eager channels now carrying the image's declarations and the
checker's class evidence, the obvious question is how much further that line
of attack can go. Answer: not far. Running the corpus census with the image
DISABLED — the configuration where typeck sees all 634 pack/stdlib files and
resolves 45% of member-call receiver classes — gives

    image ON :  no_receiver_type 5.62%   bound 92.7%   (total 9268 sites)
    image OFF:  no_receiver_type 6.45%   bound 91.9%   (total 4944 sites)

The totals differ because lowering re-derives the stdlib from source when
the image is off, so the site POPULATION is not the same and the comparison
is indicative rather than exact. But there is no sign that fuller typeck
knowledge reduces `no_receiver_type`: the image-on configuration is the
better of the two on every bucket.

So the remaining 508 sites are not waiting on what typeck knows. They are
shapes LOWERING cannot use — which is where the gains of this stretch
actually came from (safe casts, `this` in a member, predicate operators,
conditional agreement, numeric promotion, function-typed callees, spliced
type-parameter heads: 591 -> 508). Further widening of the eager channel
should not be expected to pay; the next units are lowering-side derivations.

## Addendum 64 (2026-08-06): the `unique_concrete` channel measures NEGATIVE

`classifyCallReturn` exists (its doc says so) to measure what a module-level
return-type channel would be worth: it reports `unique_concrete` — one
candidate, a return naming a resolvable class — for 1,645 initializers per
corpus run, each leaving its local untyped.

Built it. The answer is that the channel is worth less than nothing:

    matching the classifier's rule (candidates agree on the return):
        no_receiver_type 508 -> 562, bound 92.7% -> 92.2%
    requiring a single index entry (stricter):
        no_receiver_type 508 -> 509, bound flat, residue unchanged at 1,645

The strict form never fires (the index holds several entries per
declaration — a header stub beside its body — the same `len != 1` trap the
call fusion hit). The correct form fires and REGRESSES: typing the local
from the callee's declared return displaces better evidence already in
place (the constructor and alias channels), and a generic return head types
the local with something lowering then cannot use for the member call.

So `unique_concrete` is not latent value; it is a count of sites where the
declared return is present but is not the right answer. Reverted. The probe
that reports the causes is kept — the remaining blocks are `no_func` 9,858
and `not_simple_callee` 3,828, both larger and neither yet characterized.

## Addendum 65 (2026-08-06): `KLIO_INIT_KINDS` was an invalid instrument

The probe asked `localDeclTypeRef(name) == null` right after the typing
switch and reported everything it found as an untyped local. That is not
what an untyped local is. A `.Call` initializer is never written into the
declared-type table: `setLocalInitExprAt` RECORDS the expression, and
`localInitTypeRef` derives the type on demand at each use site, consulting
`ctorInitTypeRef` first. So the probe was counting locals that are typed —
just not yet.

Three measurements confirm it, each contradicting the probe:

  * `ctorInitTypeRef` never once declines for `ArrayList`, `StringBuilder`,
    `LinkedHashMap`, `HashSet` or `CharArray` across the corpus, though the
    probe named those as its second-largest block (~2,100 sites).
  * A direct repro — `val xs = ArrayList<E>()` in a generic function, then
    `xs.add`, plus `StringBuilder` beside it — censuses 3/3 bound.
  * Erasing incomplete constructor type ARGUMENTS instead of declining
    (a fix aimed at the probe's story) moved the census by exactly zero.

The probe is removed rather than repaired: rewriting it to consult the lazy
channel does not work either, since at the declaration statement the local
is not yet in scope for `b.resolve`, so the lazy answer is unconditionally
null there. Its by-name entry point `localInitTypeRefNamed` is kept.

Standing rule this produced: **the census is the only authority on what is
unbound.** An instrument that counts a lowering-internal table's misses
measures the table, not dispatch. Addenda 61-64 each spent a unit on a
channel this probe pointed at; all three measured flat or negative.

## Addendum 66 (2026-08-06): the indexed half of the array family lost its `it`

`it` is the single largest name in the whole unbound residue — 57 of 508
sites, 11%. The cause is one line in the inline-lambda splice.

An inline function invokes its lambda parameter in one of two ways, and the
generated array family is split almost evenly between them:

    ShortArray.any        →  predicate(element)        // a loop variable
    ShortArray.indexOfFirst →  predicate(this[index])  // an indexed read

`spliceInlineLambda` types the spliced lambda's parameter from the ARGUMENT
expression, through `argDeclTypeRefLazy`. That handles the loop variable and
nothing else, so `any { it.toInt() }` bound its member call and
`indexOfFirst { it.toInt() }` did not — a difference with no reason behind
it, visible in the census as the whole unsigned-array block
(`toUShort`/`toULong`/`toUInt`/`toUByte` under indexOfFirst/indexOfLast),
which reaches the same code through `storage.indexOfFirst { … }`.

The fix gives an indexed argument the element type its receiver iterates,
reusing `iterableElementTypeRef` — so `Map` declines on its own, wanting one
type argument where a map has two.

    no_receiver_type 508 -> 488     bound 92.73% -> 92.93%

The 20 sites do not move to a bound bucket, they leave the census entirely:
with the receiver typed, those calls resolve to primitive/intrinsic paths
that never register a dispatch site at all.

Two false starts worth recording, both from the same mistake — patching the
channel a probe named instead of the one the code path calls:

  * A `.Index` arm on `staticExprTypeRef` measured EXACTLY flat. The splice
    site does not call it; it calls `argDeclTypeRefLazy`.
  * `KLIO_ALPT` appeared to show the call resolving to `IntArray`/`LongArray`
    receivers for a `ShortArray` call. A clean re-run showed one line,
    `recv=ShortArray a0=Short` — resolution was right all along, and the
    loss was strictly downstream in the splice.

## Addendum 67 (2026-08-06): a member call's declared return types the chain

`not_simple_callee` became the largest leaf of the residue once the `it`
family cleared — 110 sites whose receiver is a CALL with a member callee:

    sb.append(x).deleteAt(0)      (v shr 8).toByte()
    joinTo(sb, …).toString()      rangesDelimitedBy(…).map { … }

Every channel that read a call's return handled a bare simple name only, so
a chain lost its type at the first link. `memberCallReturnTypeRef` resolves
the link the way `memberCallArgArities` resolves arities: the receiver's own
static type selects candidates whose declared receiver it extends, ranked by
scope tier, and the return counts only when every best-tier candidate
agrees. A declared member of the receiver's class is taken outright, as
Kotlin resolves it.

    no_receiver_type 488 -> 454     bound 92.93% -> 93.22%

Two guards make the difference between this and the bare-function version
that measured negative in addendum 64:

  * `return_ty_declared`. An expression body with no annotation records
    `Unit` as a PLACEHOLDER; without this check the channel types chains
    off half the stdlib as Unit.
  * A resolvable, non-type-parameter head. `no_class_id` moved 4 -> 11,
    which is the visible price of the heads that slip past — small next to
    the 34 sites gained, and each one is a site that was unbound anyway.

## Addendum 68 (2026-08-06): an unannotated top-level constant states its type

The `unknown` leaf of the residue — a receiver path that is neither a local,
a capture, nor an enclosing member — turned out to be almost entirely
file-level constants: `NANOS_PER_SECOND`, `MILLIS_PER_SECOND`,
`UPPER_CASE_HEX_DIGITS`, `base64EncodeMap`.

The consumer was already there. `argDeclTypeRefLazy` ends with a top-level
property arm reading `topLevelPropTypeHead`, and the registry it reads was
written only from a DECLARED `: T`. The stdlib writes its file constants
without one, so the head was absent and every member call on such a read
resolved by name.

Recording a head derived from a literal initializer closes it:

    no_receiver_type 454 -> 426     bound 93.22% -> 93.52%

Literals only, deliberately. A call or a name initializer would need
resolution this early declaration pass does not have, and addendum 64
already measured what a wrong head costs.

Cumulative for the session's three landed channels: 508 -> 426, a fifth of
the residue, with bound share 92.73% -> 93.52%.

## Addendum 69 (2026-08-06): a receiver lambda in a companion could not read its receiver

Two faults in one shape, found by writing the fixture for the type channel
and running it:

    class C(val raw: Long) {
        companion object { fun mk(r: Long) = C(r).apply { check(raw >= 0) } }
    }
    // runtime error: IR eval: unresolved global `raw`

**Resolution.** A bare name whose declaring class is not the LEXICAL owner is
deliberately deferred to the runtime implicit-receiver walk, which rides the
CAPTURE chain. Inside a companion function that chain holds no `C` at all,
so the read missed to a global that does not exist — a receiver lambda in a
companion could not read its own receiver's members. It now takes the field
read when the innermost receiver's static class IS the class the scoped
getter names, which is decidable at lowering.

**Typing.** `staticBareReceiverType` searched the enclosing class and
stopped. `Duration(raw).apply { … value … }` sits in Duration's companion,
whose surface has no `value`, so the receiver stayed untyped. It now falls
back to the receiver hint after the enclosing class declines — after, so no
answer the walk already gave can change.

    no_receiver_type 426 -> 418

The resolution fault was live in the stdlib the whole time and no test
reached it. It is the second time this session that writing the fixture for
a typing change surfaced a correctness bug underneath it.

## Addendum 70 (2026-08-06): a bare call is a member call on the implicit receiver

A spliced inline body writes its receiver's members bare —
`val iterator = listIterator(size)` inside `List.takeLastWhile` — and every
return channel wanted the receiver spelled out, so the local carried no type
and both `hasNext` and `next` on it resolved by name.

The bare form resolves against the splice receiver, then the extension
receiver, then the enclosing class, and only when nothing else can claim the
name: no local, no local `fun`, and NO top-level function of that simple
name anywhere. That last guard is what keeps it from re-running addendum
64's mistake — where a top-level namesake exists, the bare call may not be
the member at all.

    no_receiver_type 418 -> 402, all sixteen into bound_virtual

Session total so far: 508 -> 402, a fifth of the residue gone, bound share
92.73% -> 93.76%.

## Addendum 71 (2026-08-06): the same literal-init gap, one level down

Addendum 68 recorded a head for an unannotated TOP-LEVEL property. The
identical gap sat one level down: an unannotated CLASS property had no
recorded head either, so `private var index = 0` in the unsigned-array
iterators left every bare read of `index` untyped — the whole
`enclosing_member` block those iterators contributed.

Same rule, both forms (class and companion): a literal initializer states
the type, nothing else is read.

    no_receiver_type 402 -> 394, all eight into bound

Session ledger for the receiver-typing channels:

    508  start
    488  indexed argument types a spliced lambda parameter
    454  a member call's declared return types the chain
    426  unannotated top-level property, literal init
    418  receiver-lambda member read (plus the resolution bug under it)
    402  a bare call is a member call on the implicit receiver
    394  unannotated class property, literal init

    bound 92.73% -> 93.85%

## Addendum 72 (2026-08-06): where the residue actually is

Session ledger, receiver-typing channels, each measured on the full census
and pinned:

    508  start                                   92.73% bound
    488  indexed argument types a spliced lambda parameter
    454  a member call's declared return types the chain
    426  unannotated top-level property, literal init
    418  receiver-lambda member read (+ the resolution bug under it)
    402  a bare call is a member call on the implicit receiver
    394  unannotated class property, literal init   93.85% bound

Two channels measured NEGATIVE and were reverted with the reason recorded:
the `unique_concrete` module-level return channel (addendum 64) and routing
image extension return heads into `expr_class` (addendum 71, fixed by the
ranking/typing split rather than abandoned).

**The residue is no longer a set of families.** At 394 sites nothing is
larger than ~10 except `it` at 37, and those are lambda parameters whose
type is a bare type PARAMETER — they name no class, so no channel can type
them without inventing an answer. The leaves:

    local_no_decl_type 135   (no_init_recorded 86, init_yields_no_type 49)
    not_simple_callee   73
    no_func             38
    enclosing_member    38
    unknown             25
    captured            15

`init_yields_no_type` is the honest tail: 2-4 sites per name across ~20
distinct names, each a different derivation that stops one step short.

Alongside it: `nullable_or_generic` 78 and `resolver_declined` 83 are by
design — a nullable or type-parameter receiver has no single class, and a
declined resolution is the resolver refusing to guess. 100% static dispatch
is not the target those two describe; binding everything that NAMES a class
is, and that is what the 394 measures.

## Addendum 73 (2026-08-06): the infix family does not move the census

`(v shr 8).toByte()` looked like a live family — the by-name census reports
`callee=shr call=toByte` six times, plus `and`/`or` pairs. Three separate
placements of the rule all measured EXACTLY flat:

  * an infix arm on `memberCallReturnTypeRef` (a member call written without
    the dot: the receiver is `args[0]`, the callee a bare Path);
  * a stated rule for the integer bit operators, since `Int.shr` has no
    Kotlin declaration anywhere to read a return type from;
  * the same rule in `argDeclTypeRefLazy`, which is the function the member
    lowering actually consults for a receiver's type.

Flat in all three. Whatever types those receivers, it is not reached from
the site the census counts — the `shr` receiver is itself untyped, so the
rule has nothing to build on and typing the outer call would need the whole
chain first.

All three reverted. Recorded because the family LOOKS like the ones that
worked (a named shape, a countable size, an obvious rule) and is not: a
by-name census entry is a symptom, and the site it names is not always where
the derivation fails. The channels that paid this session were the ones
where a probe showed the derivation stopping at a specific function
(`argDeclTypeRefLazy` for the indexed splice, `topLevelPropTypeHead` for the
literal constants); the ones that measured flat were the ones reasoned about
from the census name alone.

## Addendum 74 (2026-08-06): the per-site method finds the two dead links

Addendum 73's failures came from reasoning about a census NAME. Applied to
the same tail the other way — take one site, read its source, follow the
derivation — the answer is immediate. `Base64.charsToBytesImpl` has:

    val symbol = source[index].code

and `symbol.toByte()` was unbound. Two links, each a builtin with no Kotlin
declaration anywhere to read:

  * `source[index]` — an indexed read of a CharSequence is a Char. Stated for
    the shapes that HAVE no declaration (CharSequence/String/StringBuilder,
    the twelve primitive arrays); anything else still comes from the type
    argument.
  * `.code` — a Char's code point is an Int.

Both in `argDeclTypeRefLazy`, which is the function the member lowering
consults. That placement matters: addendum 73 put an equivalent rule in
`staticExprTypeRef` and measured flat, because the lowering never asks it.

    no_receiver_type 394 -> 392

Two sites. Recorded not for the size but for the method: the tail is made of
chains where ONE link has no declaration, and each is found by reading the
source at a site, never by grouping the census by name.

## Addendum 75 (2026-08-06): an operator on a class is a member call

Same method as addendum 74, next site. `kotlin.time.longSaturatedMath` has:

    val half = duration / 2

and `half.toLong(unit)` was unbound. The arithmetic arm beside the fix
promotes NUMERIC operands and declines everything else, so a class receiver
reached no channel at all — though `Duration.div(Int): Duration` is an
ordinary member with a declared return sitting in the registry.

`+ - * / %` on a non-primitive left operand now read that member's declared
return (`plus`/`minus`/`times`/`div`/`rem`, arity 1).

    no_receiver_type 392 -> 384, bound_static +4

Running total for the session: **508 -> 384**, a quarter of the residue,
bound share 92.73% -> 94.02%.

### Found while writing the fixture: a fully-qualified companion call

    import kotlin.time.Duration
    Duration.parse("10s")            // works

    kotlin.time.Duration.parse("10s")
    // runtime error: unresolved global `kotlin.time.Duration.parse`

The package-qualified spelling of a companion member call does not resolve.
The fixture uses the import form because it is testing operator returns, not
this.

One wrong guess ruled out and reverted: `emitFqnWithClassPrefix` declines a
prefix whose simple name is unambiguous, which DOES drop the remaining
segments — but restricting that decline to `end == fqn.len` changed nothing,
because a qualified CALL never reaches that function. Its callee is lowered
by the call path, which joins the segments into one global name. That is
where to look next.

## Addendum 76 (2026-08-06): the tail is one bug, not many missing rules

Three rules in a row measured EXACTLY flat — the infix bit operators
(addendum 73), and then the primitive conversions (`toInt`, `toLong`, ...)
plus those same bit operators placed in `argDeclTypeRefLazy`, which is the
right function. Flat is not what a correct rule in the right place looks
like, so the next step was to stop writing rules and trace one site.

Repro, `tests/fixtures/lowering_repros/local_type_write_read_builder_split.kt`:

    fun decode(source: ByteArray, sourceIndex: Int): Int {
        val symbol = source[sourceIndex].toInt() and 0xFF
        return symbol.toInt()
    }

`KLIO_VALTY_TRACE=symbol` on an UNMODIFIED build:

    [valty] symbol = Int mod=b078 classes=393
    [valty] WRITE symbol = Int  b=ea58 n=2
    [valty] READ  symbol decl=<unset> b=ea58 fn=decode ndecl=2

The derivation is not missing. `symbol` IS typed `Int` and the write
succeeds. The read then misses.

**Correction to the first reading of this trace.** Without the builder
pointer on the WRITE line it looked like a producer/consumer split across
two builders. It is not: printing the pointer shows the SAME builder
(`b=ea58`) on both lines, the same `local_decl_types` map, and the same
plain-name key — `fetchPut(name)` against `get(name)`. The record count is 2
at both points.

So the write lands and something REMOVES it before the read.
`clearLocalDeclType` is the only remover, and every call site of it is in
`lambda_body` or `inline_call` — paths that should not touch a plain
top-level function's local at all. That is the thread to pull.

**It reframes the whole remaining tail.** The rules that measured flat were
not wrong; they computed the right type into a builder the reader never
consults. Every "chain with one dead link" reading in addenda 73-75 has to be
re-checked against this: some number of the 384 are not missing derivations
at all, they are derivations whose answer is discarded. Finding which clear removes
`symbol` — every `clearLocalDeclType` call site is in a lambda or inline
splice path, and this function is neither — comes before any further rule.

The rules that DID land (74, 75) moved the census, so they reach a reader.
What distinguishes them from the flat ones is the next thing to learn.

## Addendum 77 (2026-08-06): the derived type was deleted two lines after it was written

Root cause of addendum 76, found by following the trace to the end instead
of stopping at the first plausible reading. `setLocalInitExprAt` ended with:

    try self.local_init_exprs.put(name, e);
    if (self.local_decl_types.fetchRemove(name)) |old| { … }   // <- removed

and `lowerLocalDecl` calls it in the recording switch that runs immediately
AFTER the typing switch. So for every `.Call`, `.Index`, `.Member` and
`.Path` initializer the sequence was: derive the type, write it, then erase
it — the record the whole declared-type channel exists to produce, deleted
by the next statement.

Deleting the erasure:

    no_receiver_type 384 -> 379, resolver_declined 83 -> 81

**Two wrong readings of the same trace, both recorded above, both disproved
by the next probe.** They are left in place because the sequence is the
lesson:

  1. "a producer/consumer split across two builders" — the WRITE line
     carried no builder pointer, and the READ's differed between runs
     (ASLR). Printing the pointer on both showed one builder.
  2. "something clears it between" — `clearLocalDeclType` is the obvious
     remover and its call sites are all in lambda/inline paths. Instrumenting
     it showed no CLEAR fires at all.
  3. The remover was a `fetchRemove` inline in an unrelated setter, which
     only a grep for the MAP rather than for the clear function finds.

Each reading was consistent with the evidence in hand and wrong. The one
that held was the one where the fix moved the census.

It does NOT explain addenda 73 and 76's flat rules. Re-applied on top of the
fix, the primitive conversions and the integer bit operators still measure
exactly flat — so those sites are typed by another channel already, or are
not reached at all. Reverted again. The erasure was a real bug worth its own
fix; it was not the reason those particular rules paid nothing.

## Addendum 78 (2026-08-06): what the 379 are, counted rather than characterised

Session close: **508 -> 379 unbound, bound share 92.73% -> 94.09%.** Every
channel below was measured on the full census and pinned by a fixture:

    indexed argument types a spliced lambda parameter
    a member call's declared return types the chain
    unannotated top-level property, literal init
    receiver-lambda member read (plus the resolution bug under it)
    a bare call is a member call on the implicit receiver
    unannotated class property, literal init
    an indexed read and a builtin property keep the chain typed
    an arithmetic operator on a class types from its member's return
    a local's derived type survives the recording of its initializer

Reverted after measuring flat or negative, each recorded with its reason:
the `unique_concrete` module-level return channel; the infix bit operators
(three placements); the primitive conversions; the infix arm on the member
return channel (re-tested after the erasure fix — still flat); extension
return heads into `expr_class` (fixed by the ranking/typing split instead).

**The residue, by name.** 193 of the 379 sites are reachable by the by-name
census; the six names of eight sites or more account for 89 of them:

    it        40   lambda parameter, type is a bare type PARAMETER
    expected  13   `CompareContext<out T>.expected: T`
    value     11   `Lazy<T>.value: T` and kin
    actual     9   `CompareContext<out T>.actual: T`
    symbol     8   mid-chain builtin conversions
    index      8   loop variable over an infix-produced range

Four of those six — 73 sites, 19% of the whole residue — are declarations
whose type IS a type parameter. No channel can bind them, because there is
no class to name; typing them would mean inventing an answer, and this
session's two worst regressions came from exactly that.

The other two names resisted six separate rules across three addenda. Each
rule was correct Kotlin and each measured exactly flat, which says the sites
are typed elsewhere or not reached from where the rule sits.

Beside them, `nullable_or_generic` (78) and `resolver_declined` (81) are by
design in the same sense.

So of 9,204 call sites: 8,655 bind. Of the 379 that do not, at least 73 name
a type parameter, and 159 more sit in buckets that exist to refuse a guess.
The remaining ~147 are individual chains, and the method that reaches them
is the one that found the erasure bug — trace a single site to its end, and
disbelieve the first two explanations.

## Addendum 79 (2026-08-06): `index` was a postfix increment, not a range

`index` (8 sites) survived six rules across three addenda because every one
of them guessed at the wrong shape — a loop variable over `a until b`. The
source says otherwise:

    LOWER_CASE_HEX_DIGITS.forEachIndexed { index, char -> … index.toLong() }

`CharSequence.forEachIndexed` splices as

    var index = 0
    for (item in this) action(index++, item)

so the lambda's `index` parameter is bound from the ARGUMENT `index++`, and
`argDeclTypeRefLazy` had no `.Postfix` arm at all. `x++` evaluates to the
operand's prior value and carries its type; one line adds it.

    no_receiver_type 379 -> 375, all four into bound

Third time the spliced-lambda argument position has been the answer
(addendum 66's indexed argument, addendum 77's erased record, this). The
inline splice types a lambda parameter from whatever expression the callee
passes, so every expression SHAPE the stdlib uses at an invocation site is a
channel that must exist. The census's `Postfix` bucket — six sites — was
naming this the whole time.

## Addendum 80 (2026-08-06): the argument-shape rule, stated

Addendum 79's finding generalises, and the census's own shape histogram is
the worklist. The inline splice types a lambda parameter from whatever
expression the callee passes at the invocation site, so EVERY expression
shape the stdlib writes there needs an arm in `argDeclTypeRefLazy` — the
function the splice consults. Missing arms show up in the census as the
shape buckets themselves:

    Postfix  6 -> arm added (addendum 79)    379 -> 375
    Unary   10 -> arm added                  375 -> 365

`!x` is Boolean; `-x` / `+x` keep their operand's type. Ten sites, all into
bound, no battery moved.

This is the fourth time the spliced-argument position has been the answer
(66, 77, 79, 80) and the first time it was reached by rule rather than by
tracing a site — because the shape histogram names the gap directly. The
remaining buckets are `Path` 197, `Call` 88, `Member` 36, `Binary` 34, all
of which HAVE arms; their misses are inside those arms, not absences.

    Range   -> arm added                     365 -> 351

`a..b` names a range CLASS from its endpoints (`IntRange`, `CharRange`,
`LongRange`, `UIntRange`, `ULongRange`). The classes exist; the operator
producing them is builtin with no declaration, so the mapping is stated.
Fourteen sites — the largest single arm of the three, because a range is
both an argument shape AND the thing a `for` draws its element from.

    Binary  -> arms added                    351 -> 347

Arithmetic promotion and the Boolean predicates existed for the EAGER walk
(`staticExprTypeRef`) and not for the one the splice consults. Adding them
also removed 34 sites from the census outright: with both operands typed the
call resolves to a primitive path that registers no dispatch at all.

One mistake worth keeping: the first version `return null`ed on a
non-primitive operand, which skipped the class-operator arm below it and
regressed `duration / 2` — 351 -> 355 with 38 static binds lost. A channel
that cannot answer must FALL THROUGH, not answer null; the two are the same
value and opposite meanings when arms are chained.

Session: **508 -> 347 unbound, 92.73% -> 94.35% bound.**

## Addendum 81 (2026-08-06): the shape worklist is exhausted; the tail is intrinsics

Four arms landed off the census shape histogram (Postfix, Unary, Range,
Binary). The next three attempts all measured exactly flat, and each names
the same wall:

  * **Builtin properties** (`.length`, `.size`, `.indices`, `.lastIndex`) —
    flat because the RECEIVERS of those reads are themselves untyped. The
    chain's head, not its links, is what is missing.
  * **Fully-qualified calls** — `val roundedScaled = kotlin.math.floor(x)`
    in the Duration formatter has no return channel at all, since every one
    of them wants a bare simple name. Adding an FQN lookup changed nothing:
    `funcIdByFqn("kotlin.math.floor")` is null, because `floor` is a HOST
    INTRINSIC with no `Func` in the module to read a return type from.

That last point is the shape of what remains. The declared-type channels can
only read declarations, and the tail of the census is calls whose callee has
none — the same 1,281 "builtin-type members" the P10 audit classified as
"no source declaration in Kotlin either, not holes".

The obvious next step was a table of intrinsic SIGNATURES (name -> return
head) as data, the way `primitiveMemberFast` already encodes their
behaviour. **Built it; it measures flat.** Three forms, all exactly zero:
the conversion members (`toInt`, `toLong`, …), the integer bit operators,
and the math functions (`floor`, `sqrt`, `abs`, `min`, `max`, keyed so the
bare and qualified spellings both reach it).

Four consecutive flat results retire the theory. Knowing an intrinsic's
return type is not what these sites are missing — their RECEIVERS are
untyped, and a rule that types the result of an operation on an untyped
value has nothing to stand on. The `symbol` chain proves the shape: once
addendum 77's erasure fix let its head keep a type, the whole chain bound
with no intrinsic table at all (`decode`'s two sites, 2/2 bound).

So the tail is not "unknown intrinsic returns". It is untyped chain HEADS,
and each one is its own reason.

Session: **508 -> 347 unbound, 92.73% -> 94.35% bound**, nine channels
landed, ten measured-flat or negative attempts reverted with their reasons.

## Addendum 82 (2026-08-06): the same instrument mistake, twice in one session

Tracing the `byteSeparator` family (`bytesFormat.byteSeparator.length`) I
reduced it to

    class Inner(val sep: String)
    class Outer { val inner: Inner = Inner("-") }
    val i = o.inner        // KLIO_VALTY_TRACE=i -> decl=<unset>

and read `<unset>` as "the property chain does not type". It does not mean
that. A `.Member` initializer is RECORDED, not written into the declared-type
table, and typed on demand at each use — which is exactly what addendum 65
established when it retired `KLIO_INIT_KINDS` for the same misreading.
`<unset>` is the expected state for such a local; the question the trace does
not answer is whether the lazy derivation succeeds at the USE site.

So the byteSeparator lead is unresolved, not disproved, and the repro above
is not evidence either way. Recorded because the failure mode is now
two-for-two in one session: **a lowering-internal table's miss is not a
dispatch miss, and only the census can say which is which.**

The instrument that would answer it is a trace at the USE site — what
`argDeclTypeRefLazy` returns for the receiver of `i.sep` — not at the
declaration.

## Addendum 82 (2026-08-06): the same instrument mistake, twice in one session

Tracing the `byteSeparator` family (`bytesFormat.byteSeparator.length`) I
reduced it to a two-class property chain and read `KLIO_VALTY_TRACE`'s
`decl=<unset>` on the local as "the property chain does not type".

It does not mean that. A `.Member` initializer is RECORDED, not written into
the declared-type table, and typed on demand at each use — exactly what
addendum 65 established when it retired `KLIO_INIT_KINDS` for the same
misreading. `<unset>` is the expected state for such a local; what the trace
does NOT answer is whether the lazy derivation succeeds at the USE site.

So the byteSeparator lead is unresolved, not disproved, and that repro is not
evidence either way. Recorded because the failure mode is now two-for-two in
one session: **a lowering-internal table's miss is not a dispatch miss, and
only the census can say which is which.**

The instrument that answers it is the census itself, restricted to the
repro's own function: `KLIO_NORECV_NAMES='*'` filtered to `fn=render`. Run
that way, both shapes BIND — the plain two-class chain and the nested
qualified-parameter form that matches `HexExtensions.kt` exactly:

    class HexFmt { class BytesFmt(val byteSeparator: String, …)
                   val bytes: BytesFmt = … }
    fun render(bytesFormat: HexFmt.BytesFmt): Int {
        val sep = bytesFormat.byteSeparator      // binds
        return sep.length + bytesFormat.bytePrefix.length
    }

So the general shape is not broken, and the four real `byteSeparator` sites
fail for something particular to their file — most likely the inline splice
they sit inside. A synthetic repro that BINDS is real evidence: it rules the
shape out and moves the question to the context.

Extended to the real declaration's exact context — the four sites live in

    private fun ByteArray.toHexStringNoLineAndGroupSeparatorSlowPath(
        …, bytesFormat: HexFormat.BytesHexFormat, …
    ) { val byteSeparator = bytesFormat.byteSeparator … }

so the repro was rebuilt with an EXTENSION receiver as well as the nested
qualified parameter type. It binds too. Three synthetic forms, all binding.

What that leaves is the file's own context rather than any shape: the
function is `private` and reached only through two `internal` callers, and
`HexFormat.BytesHexFormat` is nested inside a class declared in another
file. One of those is the difference. Narrowing it needs the trace run
against `HexExtensions.kt` itself, not a reconstruction — a synthetic repro
has now cost three attempts and ruled out three hypotheses, which is what it
is good for, and it cannot rule in the fourth.

That is where this lead stands. It is the honest state, not a conclusion.

## Addendum 83 (2026-08-06): a nullable receiver is not automatically dynamic

`nullable_or_generic` was described as by-design — a receiver with no single
class. Half of that is right and half was a rule applied too widely.

The rule: an extension declared on `T?` outranks the member, so `x.f()` on a
nullable `x` cannot bind the member. True — WHERE SUCH AN EXTENSION EXISTS.
Where the name declares none anywhere in the module, Kotlin has exactly one
legal target for that call, and it is the member. The gate refused all of
them.

Checked across the whole module, so a later-loaded pack cannot introduce a
`T?` extension behind the decision:

    nullable_or_generic  78 -> 2
    bound                94.35% -> 95.14%

Seventy-six sites, the largest single move since the early channels, and it
came from re-reading a bucket this plan had written off as by-design rather
than from finding a new channel. The two that remain are names that DO
declare a nullable extension, which is the rule working as intended.

Worth stating for the rest of the residue: "by design" was a claim about
Kotlin's semantics, and it deserves the same measurement as everything else.
`resolver_declined` (81) is the next bucket carrying that label.

## Addendum 84 (2026-08-06): `resolver_declined` measured, not assumed

Applying addendum 83's lesson to the next bucket carrying a "by design"
label. All 81 sites are one kind:

    [decline] 81 100.00% target_known_deferred

The resolver PROVED a single declaration and withheld dispatch anyway,
because an argument's type is unknown so the member's applicability is not
proven. The promotion gate that exists to rescue those reports why it
refuses (181 events over the 81 sites — a site can be blocked more than
once):

    ext_own_head            58   an extension of that name on the receiver's own head
    receiver_not_instance   52   a stub or value class: host-backed, no vtable
    ext_declared_super      36   an extension on a declared supertype
    ext_generic_receiver    22   an extension with a generic receiver
    ext_builtin_super       13   an extension on a builtin supertype

The four `ext_*` kinds are one question: could an extension take this call
if the member turns out not to apply? Kotlin gives a MEMBER precedence over
an extension on the same type, so where the member IS applicable the
extension never wins — the block is entirely about the unproven
applicability, not about precedence. Proving the argument types would
collapse all four, which is the same receiver-typing work the rest of this
plan needs.

`receiver_not_instance` is different in kind: a value or stub class is
host-backed and has no vtable to index, so binding it statically needs the
HOST member's identity, not a better type. That is the intrinsic-identity
work — distinct from the intrinsic-SIGNATURE table addendum 81 retired,
because here the receiver is already typed and only the callee's identity is
missing.

Both are now named and counted rather than labelled by-design.

The promotion PROOF itself reports why it holds, which splits the 81 again:

    arg-unauthoritative   40   an argument's type is not authoritative
    ext-unrefuted         23   an extension of that name could not be refuted
    member-arg-refuted    12   an argument REFUTES the member — correctly held

One hypothesis checked and refused: that `ext-unrefuted` was the precedence
rule being missed, since Kotlin gives a member precedence over an extension
unconditionally. It is not. `memberPromotionProven` already short-circuits
on `if (member_fully_proven) return true` BEFORE it looks at any extension,
so that path is reached only when the member is not proven — where both
sides are genuinely uncertain and holding is right.

So all 63 promotable declines reduce to one thing: argument types that are
not authoritative. There is no shortcut past it, and it is the same
receiver-typing front the 347 need. That is now measured from three
independent directions — the census's own buckets, the eager channel's
`hits=0`, and this proof's own reasons — and they agree.

## The argument-type front, opened

The `arg-unauthoritative` reason names a shape, not a site, so the shapes
themselves were counted. `KLIO_ARGSHAPE_UNK` reports every argument whose
applicability shape carries no type, no literal kind and no callable form;
under `KLIO_PROMO_NAMES` the same report is emitted only for the arguments
that actually made the proof hold. That second, filtered, report was 40
lines and 28 of them were one shape: a `Binary Add` inside
`random.nextInt(i + 1)`, where `i` is a for-loop variable. The loop variable
had no type because the iterated expression is a PROGRESSION, and a range or
progression carries its element in the class NAME (`IntProgression`), not in
a type argument — the only path `iterableElementTypeRef` had. Naming the ten
range/progression classes typed the loop variable, and the 28 declines went
to bound.

    resolver_declined   81 -> 53

That is the whole lesson of the census reading backwards: `arg-unauthoritative`
sounded like a deep inference problem and was, in the majority, one missing
table.

### The bug the loop-variable type exposed

Typing the loop variable made `parseHexToLong`'s body reach a splice it had
been falling short of, and the splice was wrong. A lambda ARGUMENT spliced
into an inline body is caller code: the inline lambda parameters it can
invoke, the scope depth its free names resolve against, the call-site hint,
and the localize target for an unlabeled `return` all belong to the frame
the lambda was WRITTEN in. Every one of those was read from the INNERMOST
frame instead. With one inline level that is the same frame, which is why it
held for so long; with two levels that both name a parameter `onError` — the
exact shape of `HexExtensions.parseHexToLong` under `Uuid.parseHexDash` — the
body bound the callee's closure instead of the caller's.

Three separate corrections, each measured on its own:

  - the substitution map carries over the caller's entries, but only for
    names the skipped frames RE-BIND. Carrying everything hands unrelated
    calls to a splice and broke `select { }`; carrying nothing is what lost
    the collision in the first place.
  - the caller scope depth and the call-site hint come from the substituting
    frame.
  - so does the return-localize snapshot, without which
    `uuidParseHexDashOrNullCommonImpl`'s `{ _, _, _ -> return null }`
    returned a value into the arithmetic instead of leaving the function.

A fourth correction is independent: `this.onError(index)`, an inline lambda
parameter with a receiver type invoked through an explicit `this`, was
emitting a member dispatch no class declares. The qualifier names the
lambda's receiver, so the call is the same splice the bare form takes — with
the receiver supplied by the call rather than inferred from the parameter's
mark, which an enclosing splice of the same name suspends.

## Two gates measured, one stale

`promo_blocked_by_class` withheld the promotion proof whenever the receiver's
class was a stub or a value class, reasoning that a host-backed receiver has
no vtable. The branch beside it already emits a virtual answer for exactly
those classes — the runtime resolves the slot against the receiver's runtime
class and prefers the FQN-keyed intrinsic. The guard described a rule the
interpreter had stopped following. Removing it is +2 sites, which is small,
but it deletes a fallback rather than adding a channel.

## A property states its type by what builds it

`private val base64EncodeMap = byteArrayOf(...)` is as definite as an
annotation, and the stdlib writes its tables that way. The registration pass
that records top-level property heads runs before anything is resolved, so
it could only read LITERAL initializers. It now records the initializer's
callee NAME instead, and the module answers at query time when every
declaration is visible: a user function of that name is in the candidate set
and either agrees or makes the answer ambiguous, so a shadowed factory
cannot mistype the property. `apply`/`also` are seen through, so
`IntArray(256).apply { ... }` is an `IntArray`.

    no_receiver_type   347 -> 321

The downstream effect is larger than the property reads themselves: the
untyped `base64EncodeMap` left `forEachIndexed`'s lambda parameters untyped,
and every call on those was unbound too.

## Where the census stands

    total            9075
    no_receiver_type  321   3.54%
    resolver_declined  51   0.56%
    no_class_id        11
    nullable_or_generic 2
    bound            8690  95.76%

The remaining `no_receiver_type` was read the same way. Its largest named
sub-bucket, `enclosing_member` (30), is a class member whose declared type is
a bare TYPE PARAMETER — `CompareContext<out T>.actual`, `UnsafeLazyImpl.value`,
`TestCollection<T>.data`. Those name nothing in the receiving scope; kotlinc
resolves them from the instantiation, which lowering does not carry. That is
a floor, not a channel, and it is now measured rather than assumed.

## Two censuses, and the one that could see the safe call

The stdlib commontest census is generic containers throughout, so a change
that reads CONCRETE types measures near zero there by construction. The
examples census is ordinary application code. Read together they separated a
floor from a channel twice in a row.

`transform` is the floor. It is the single most common untyped call receiver
in the examples set (156 sites), and it is an inline lambda PARAMETER whose
declared return is a bare type parameter — `mapNotNullTo` writes
`transform(element)?.let { destination.add(it) }` with `transform: (T) -> R?`.
There is no type to read. Counting it was still worth it: it is the largest
single entry in that census and it is not work.

The safe call was the channel. `x?.let { it.f() }` lowered its
proven-non-null branch straight to a runtime member call — the inline splice
never ran, so `it` got no type, so every member call inside the lambda
resolved by name. Those sites did not even APPEAR in the census, because a
raw `CallMember` is not a lowering decision the census records. Rewriting the
branch as a plain call on a temporary bound to the already-lowered receiver
put 832 examples-set dispatches and 64 stdlib-set dispatches on the ordinary
path, where they bind.

    examples total    101165 -> 102005 sites, all of the difference bound
    stdlib   total      9075 -> 9139

The ratio barely moves and the change is one of the larger ones in the
campaign. A census that only counts what the lowering decided cannot see
work the lowering never attempted; the fix is to compare the two file sets
and to watch the TOTAL, not only the percentage.

## Standing

    stdlib census    8766 / 9139   95.92% bound
    examples census 98742 /102005  96.80% bound

Landed since the last standing: range/progression loop-variable element
types, the four-part inline-splice frame correction and the `this.f(x)`
splice, the stale host-backed-receiver gate, unannotated top-level property
heads from their initializer's callee, package-qualified call return types,
argument types read before the splice binds, and the safe-call non-null
rewrite.

### Measured flat and reverted: the safe call's own return type

`memberCallReturnTypeRef` refuses a nullable receiver outright. Kotlin
allows one — through a safe call, whose result is nullable in turn — so the
lookup was changed to use the non-null head and carry the `?` back, which is
the rule as written. It measures exactly zero on BOTH censuses. The chain it
was aimed at (`a?.self()?.b?.twice()`) still types nothing, because the link
that fails is the safe member READ in the middle, not the call. Correct and
unused is still unused: reverted, and recorded here so the next reading of
that chain starts at the read.

## The thunks that knew only names

Three kinds of expression lower in a builder of their own over a
constructor's parameters: a delegation argument (`: this(...)`), a default
value, and a superclass argument. All three were handed the parameter NAMES
and nothing else, so `seed1.inv()` in `XorWowRandom`'s
`: this(seed1, seed2, 0, 0, seed1.inv(), ...)` had no receiver type at all.
The declaration lowering now stashes the declared types beside the names and
the thunk records them; function-typed and bare type-parameter slots are
skipped, since neither names a class.

    stdlib census    309 -> 307 no_receiver_type
    examples census 2271 -> 2245 no_receiver_type

The gap between the two counts is the whole reason both are kept: this is
one site in the stdlib source and twenty-six in the examples set, because
every example re-lowers it.

## Standing

    stdlib census    8768 / 9139   95.94% bound
    examples census 98768 /102005  96.83% bound

## The safe chain, and what typing it exposed

`a?.self()?.leaf?.twice()` typed nothing past the first link. Two separate
causes, both in the same arm:

  - the safe member READ was excluded by the arm's own guard, though it is
    the only legal form for reading through a nullable receiver. It now
    looks the property up on the non-null owner and hands the `?` back.
  - a receiver that is itself a CALL has no declared type to read, so the
    walk stopped there. Its resolved return is the same fact one step along.

Typing them measured as zero bound and looked like a wash:

    no_receiver_type      307 ->  291   (stdlib)
    nullable_or_generic     2 ->   18
    no_receiver_type     2245 -> 2036   (examples)
    nullable_or_generic    30 ->  238

Every site moved from having NO receiver type to having a nullable one,
where the rule is that a `T?` extension outranks the member — so the call
was handed to the runtime. Naming the residue (`KLIO_NULLEXT_NAMES`) showed
what it was: `ByteArray?.contentEquals`, `ShortArray?.contentHashCode`,
`Any?.toString`. Those are declarations like any other, and Kotlin binds an
extension statically with the receiver in the leading slot. Resolving it
there instead of deferring closed the whole bucket:

    stdlib   nullable_or_generic  18 ->   2, bound_static 1539 -> 1555
    examples nullable_or_generic 238 ->  26, bound_static 16018 -> 16230

The sequence is the point. The typing change alone measures nothing and
would have been reverted under the flat-means-revert rule; what it did was
move a population from a bucket with no name to a bucket whose name said
exactly what to do next.

## Standing

    stdlib census    8784 / 9139   96.12% bound
    examples census 98980 /102006  97.03% bound

## Two shapes the indexes could not answer for

Both were the largest single entry in one of the censuses, and both were
invisible to the simple-name index for the same reason: the declaration is
not a module function.

An IDENTITY extension — `fun <T> T.apply(block: T.() -> Unit): T` — declares
a bare type parameter on both ends, so the receiver-head filter never
admitted it and its return named nothing. The receiver instantiates both.
`buildString` writes `StringBuilder().apply(builderAction).toString()`, where
the argument is a FORWARDED parameter rather than a literal lambda, so the
splice that normally carries the type cannot take it and the chain stopped
at `apply`.

A LOCAL `fun` is a closure in a cell, keyed by a mangled binding name.
`funcId` misses it, so the return-type channels all declined — including for
`expect("'-'", i) { it == '-' }?.let { return it }` in `Instant.parseIso`,
which was the biggest `unique_concrete` group in the stdlib census (the
classifier could see an answer the typing path could not reach). The
declaration now records its declared return beside the parameter types it
already recorded.

    stdlib   no_receiver_type  291 -> 275
    examples no_receiver_type 2036 -> 1957

## Standing

    stdlib census    8784 / 9123   96.28% bound
    examples census 98983 /101930  97.11% bound

## The container family, and reading the OTHER census's residue

`resolver_declined` was 51 on the stdlib census and 654 on the examples one
— the only bucket where the two sets disagreed by more than a factor of
three. Splitting the examples residue by the proof's own reason showed why:

    ext-unrefuted        496
    member-arg-refuted   158
    arg-unauthoritative  158

and the `ext-unrefuted` sites were one family, every one of them a container
member: `Map.get`, `containsKey`, `containsValue`, `remove`, `putAll`,
`addAll`, `removeAll`, `containsAll`, `flatten`.

Addendum 84 had already refused the hypothesis that these were Kotlin's
member-over-extension precedence being missed, on the grounds that
`memberPromotionProven` short-circuits on `member_fully_proven` before it
looks at any extension. That was correct and the conclusion drawn from it
was not: the question was never whether the short-circuit exists, it was
why the member is not PROVEN. The answer is that its parameter is a bare
type parameter — `get(key: K)` under a head-only receiver — and an
unsubstitutable parameter was scored UNKNOWN, which costs the proof.

A parameter that is still a type parameter after the receiver's
substitution accepts whatever the source passed: the program compiled, so
the argument conforms to whatever the instantiation makes it. That is the
star-erasure convention one level up — the head adjudicates, the parameter
neither proves nor refutes — and applying it to the parameter itself is
what the family needed.

    stdlib   resolver_declined  51 ->  37
    examples resolver_declined 654 -> 472

## Standing

    stdlib census    8798 / 9123   96.44% bound
    examples census 99165 /101930  97.29% bound

### The rest of the container family: the head decides an erased slot

Naming the (parameter, argument) pairs behind every remaining
`ext-unrefuted` hold split them cleanly in two:

    MutableMap.putAll     param=Map<*,*>       arg=Sequence   hold is RIGHT
    MutableSet.removeAll  param=Collection<*>  arg=Sequence   hold is RIGHT
    Set.containsAll       param=Collection<*>  arg=Set        hold is WRONG
    MutableCollection.addAll param=Collection<*> arg=Collection  hold is WRONG

The first two are calls whose argument does NOT fit the member's parameter,
so the extension beside it genuinely is the binding kotlinc picks. The
second two are the member's own call, held because a star-erased parameter
scored UNKNOWN.

The erasure convention already says an unsubstitutable type ARGUMENT
neither proves nor refutes; the missing half is that the argument's HEAD
then decides the slot outright. Applying it keeps both right answers: a
`Sequence` does not extend `Map`, so `map.putAll(sequence)` still declines
and takes the extension.

    stdlib   resolver_declined  37 -> 30
    examples resolver_declined 472 -> 392

## Standing

    stdlib census    8805 / 9123   96.51% bound
    examples census 99245 /101930  97.37% bound

### The same rule read backwards

If the argument's head decides a star-erased slot, a head that does NOT
satisfy it is a definite mismatch. That is the refutation half, and it is
worth as much as the proof half: a refuted member is not the target at all,
so the same-named extension the resolver was already holding for takes the
call statically instead of being left to the runtime's value ranking.

    stdlib   resolver_declined  30 ->  14
    examples resolver_declined 392 -> 184

Restricted to heads the module KNOWS. An unresolved or host-only name is
one whose hierarchy this module cannot see, and a false refutation binds
the WRONG declaration — the one failure mode this campaign cannot trade
for a number. Lambdas, nulls and spreads keep the conservative answer.

### An instrument that had stopped measuring anything

`receiver_not_instance` was the largest entry in the promotion census (52
of 153) and named a gate that no longer exists — a host-backed receiver
stopped blocking the proof several commits earlier. It was recording a
PROPERTY of the receiver class, not a reason anything was held, and it sat
on top of the residue where it was read as work. Retired; those sites now
attribute to the reachable extension the proof has to refute, like every
other site.

## Standing

    stdlib census    8805 / 9107   96.68% bound
    examples census 99245 /101722  97.57% bound

`resolver_declined` is now 14 sites on the stdlib census and 184 on the
examples one — down from 81 and 654 when this front opened. What remains
in it is `arg-unauthoritative`: `Collection.contains(e)` and
`AbstractMap.get(key)` where the argument is a lambda parameter with no
type. That is the receiver-typing floor again, reached from the other side.

## A target that needs no receiver type at all

The residue was read one more way: by CALL NAME rather than by receiver.
The largest entry is `toString` (26 of 275 on the stdlib census), and it is
not a typing problem — it is a call every value answers.

`toString()` and `hashCode()` are declared in the stdlib as `Any?`
EXTENSIONS, and those are what Kotlin binds when the receiver may be null.
For a non-null receiver they delegate to the member, so the two agree
wherever both apply. A receiver no channel could type therefore has a known
target after all.

Taken only when EXACTLY one extension of that name and arity exists and its
declared receiver is `Any?`. A member of the same name is not competition —
the extension delegates to it — but a same-named extension on a real type
disqualifies the whole shortcut.

    stdlib   no_receiver_type  275 ->  249, bound_static  1555 ->  1581
    examples no_receiver_type 1957 -> 1755, bound_static 16230 -> 16432

Two attempts alongside it measured flat and were reverted: expanding a
TYPEALIAS receiver to the class it stands for (the alias that remains is a
function type, which names no class), and typing a spliced function-typed
parameter's return through the splice window.

## Standing

    stdlib census    8831 / 9107   96.97% bound
    examples census 99447 /101722  97.76% bound

## Where the campaign stands, and what the residue is made of

    stdlib census    8831 / 9107   96.97% bound
    examples census 99447 /101722  97.76% bound

Opened at 92.73%. Every bucket that named a MECHANISM has been closed:

    nullable_or_generic   78 ->   2   (the nullable receiver binds its member,
                                       and where a `T?` extension outranks it,
                                       that extension binds statically too)
    resolver_declined     81 ->  14   (a type-parameter or star-erased
                                       parameter proves the member; the same
                                       rule read backwards refutes it, and the
                                       extension then binds)
    no_class_id          915 ->  11   (a type-parameter receiver resolves
                                       through its bound; what remains is one
                                       function-type typealias)

What is left does not name a mechanism. Read by receiver, `no_receiver_type`
is 249 sites: 91 locals with no derivable type, 22 members whose declared
type is a bare type PARAMETER (`CompareContext<out T>.actual`,
`UnsafeLazyImpl.value`), 17 unresolved names, 9 captures, and 110 receivers
that are themselves calls, reads or arithmetic over those same leaves. Read
by CALL NAME, after the universal-extension channel took `toString`, the
largest entries are `let` (19, an inline extension that must reach its
splice), `getter` (18, all on `CompareContext<out T>`), and the numeric
conversions `toInt`/`toLong`/`toUInt` (33) on receivers that are arithmetic
over untyped leaves.

The 14 remaining declines are `arg-unauthoritative`: `Collection.contains(e)`
and `AbstractMap.get(key)` where the argument is a lambda parameter with no
type. That is the same floor reached from the argument side.

So the residue is one thing said three ways: a value whose type Kotlin knows
only from an INSTANTIATION that lowering does not carry. Closing it needs
monomorphisation, or a runtime type feed that specialises a call site after
its first dispatch. Both are real projects and neither is a resolution
change — which is what the resolution plan concluded independently, from the
checker's side, before this campaign reached the same wall.

### Channels that measured flat and were reverted

Recorded so they are not retried: the safe call's own return type; a
TYPEALIAS receiver expanded to the class it stands for (the one that remains
is a function type, which names no class); a spliced function-typed
parameter's return read through the splice window; the intrinsic signature
table (addendum 81).

## Why the residue cannot be typed: the bodies are lowered ONCE

The last attempt was the one both plans had been pointing at — substitute
the call site's solved type arguments for a spliced declaration's own type
parameters, so a loop variable over `Iterable<T>` gets the element type the
caller supplied. The window already carries solved bindings
(`typeParamBoundRef`), so the change was small: where the element is a bare
type parameter, read the binding instead of declining.

It measures exactly zero on BOTH censuses, and the probe says why. Every
site reports no binding at all:

    [elemsub] elem=R recv=Iterable bound=<none> fn=zip
    [elemsub] elem=T recv=Sequence bound=<none> fn=sumOf
    [elemsub] elem=T recv=Iterable bound=<none> fn=groupByTo
    [elemsub] elem=T recv=List     bound=<none> fn=sortedMapOf

Not "the binding is a type parameter again" — ABSENT. And the reason is
structural rather than missing plumbing: `sumOf`, `zip`, `count`,
`groupByTo` are generic library functions whose bodies are lowered ONCE,
generically, and the census counts their sites there. At that moment there
is no call site to read an instantiation from. The receiver in the probe is
the function's OWN declared `Iterable<T>`, not any caller's `List<Duration>`.

That is the residue, stated mechanically instead of by analogy:

  * it is concentrated in generic bodies lowered once and shared by every
    caller — which is also why the examples census shows the same figures
    multiplied by the number of example programs;
  * no call-site channel can reach it, because the lowering that produces
    those sites does not happen at a call site;
  * typing them requires lowering a COPY per instantiation
    (monomorphisation) or feeding the runtime's observed receiver class back
    into a specialised copy.

Both are real projects with their own cost model — code size for the first,
a deoptimisation path for the second — and neither is resolution work. The
campaign's own instruments now say so from five directions: the census
buckets, the eager channel's `hits=0`, the promotion proof's reasons, the
call-name split, and this probe.

## Erasure to the bound — the fourth option, and where it stops

Monomorphisation and a runtime type feed both fail the constraints this
project works under: the first grows packs and memory, the second IS a
runtime decision and puts a guard on every call. The fourth option is what
kotlinc, the JVM and a C backend all use — erase each type parameter to its
declared upper bound and resolve the member there. In valid Kotlin a call on
a `T`-typed value can only target a member of `T`'s bound, so this is
complete rather than approximate: one shared body, a slot named at lowering,
no guard, no cache, no extra IR.

The machinery to consume a bound already existed. What was missing was
DECLARING one and then not throwing the parameter away:

  - a function type parameter with no explicit upper bound recorded no bound
    at all, though Kotlin gives it `Any?` (the CLASS builder had always
    recorded that);
  - a class property declared with an unbounded class type parameter
    recorded no head;
  - a bare type-parameter ELEMENT of an iterated receiver was discarded;
  - a head shaped like a type parameter with no record in THIS scope — one
    declared by an enclosing generic — reached no owner, though `Any?` is
    the floor for every type parameter.

Each of those filters was choosing "no type" over "the bound", which is
strictly worse: a bound resolves and an absent type does not.

    stdlib   no_receiver_type 249 -> 226, resolver_declined 14 -> 6
    examples no_receiver_type 1755 -> 1703, resolver_declined 184 -> 80

### Where erasure stops, measured

Two follow-ons in the same direction measure exactly flat, on both censuses,
and both say the same thing:

  * substituting the RECEIVER's type arguments into a generic member's
    return (`List<String>.get` returns String) has no input, because the
    receiver types lowering derives are largely HEAD-ONLY — `List`, not
    `List<String>`. Nothing to substitute.
  * carrying a bare type-parameter SPLICE parameter when a bound exists
    moves nothing, because the sites are inside generic bodies whose own
    parameters have only the `Any?` floor.

So erasure closed the receivers whose bound is a real classifier, and the
residue is the receivers whose bound is `Any?` — where a call can only be
`toString`/`hashCode`/`equals` (already taken by the universal-extension
channel) or an extension selected from an instantiation nobody has. The 91
remaining local receivers are all in generic library bodies: `sum`,
`minOfWith`, `flatMap`, `flatten`, `sortedByNullable`.

## Standing

    stdlib census    8839 / 9083   97.31% bound
    examples census 99551 /101667  97.92% bound

### Two more measured flat, in the same family

Carrying a NULLABLE named element (`List<String?>`) and stripping a
USE-SITE projection prefix (`Array<out String>`) off the element head both
measure exactly zero. Recorded so they are not retried: the projection
prefix is not what blocks those sites, and the nullable element already
reaches the nullable receiver rule by another route.

## The head-only representation, and what it was costing

The census file sets are generic-container-heavy, which hid a plain defect
in ordinary code. This program had SIX unbound receivers:

    class Holder(val items: List<Named>, val lookup: Map<String, Named>) {
        fun firstTag() = items[0].tag()
        fun loopTags() { for (i in items) … i.tag() }
        fun mapped()   = items.map { it.tag() }
        fun viaMap()   = lookup.values.first().tag()
    }
    val topItems: List<Named> = …

Every property-type registry stored a HEAD — `List`, not `List<Named>` — and
a head cannot say what iterating or indexing the property yields. Both
registries now carry the full declared type beside the head, recorded when
every type argument names a real class, and lowering prefers it.

    examples no_receiver_type 1703 -> 1651
    fixture                     0/6 -> 5/6 bound

The stdlib census does not move by construction: its properties are generic,
so their arguments are the owner's type parameters, which name nothing
outside an instantiation.

### The sixth case, and a substitution that still measures flat

`lookup.values.first().tag()` needs `Map<K, V>.values: Collection<V>`
substituted from the receiver — which now HAS arguments, so the input the
earlier attempt lacked exists. Implemented (record generic-argument property
types, substitute the owner's parameters positionally at the read) and it
still measures exactly flat on both censuses: the probe shows the member-read
arm is never reached for `lookup.values` at all, so the substitution has
nothing to do. Reverted; the arm that DOES type that read is the thing to
find next, and it is not this one.

## Standing

    stdlib census    8841 / 9081   97.36% bound
    examples census 99577 /101641  97.97% bound

### The arm that answers, found by elimination

The property-read substitution measured flat twice before it worked, and
both times for the same reason: it was wired into the member-read arm that
`lookup.values` never reaches. There are two `.Member` arms in
`argDeclTypeRefLazy`, 200 lines apart; the one that answers a property read
used AS A RECEIVER is the first, and it returned the declared HEAD.

Wired there — with generic-argument property types recorded rather than
dropped, so the substitution has an input — `for (v in lookup.values)`,
`lookup.values.map { }` and a nested `List<List<Named>>` walk all type.

A flat measurement is not always a dead channel. Twice here it meant the
consumer was in the wrong place, and the probe that named the reached arm
was worth more than either retry.

Substituting an EXTENSION's own type parameter from the receiver
(`fun <T> Iterable<T>.first(): T` on a `Collection<Named>`) measures flat
and is reverted; `first()` never reaches that loop.

## Standing (corrected arithmetic)

Two earlier examples-census figures in this document were stated as 98.20%
and 98.28%; the census's own printed shares (bound_static + bound_virtual)
give 97.92% and 97.97%. Corrected in place. The stdlib figures were right.

    stdlib census    8837 / 9077   97.36% bound
    examples census 99528 /101591  97.97% bound

### The extension-return substitution: traced, not guessed, and still open

Following the lesson above, the extension-call receiver was TRACED before
any rule was written. `memberCallReturnTypeRef` does reach
`recv=Collection<1>` for `first` — the receiver types correctly, and 38
declarations carry the name — but a probe placed inside the extension loop
never fires. Something between the two returns first, and the suspect is the
MEMBER probe loop above it: it answers `return null` on an undeclared return
rather than falling through to the extensions.

Recorded rather than patched: the fix is to make that loop fall through
instead of returning, which changes every consumer of the member branch, and
that deserves its own measurement rather than being folded into a
substitution change. The probe belongs in the plan so the next attempt starts
from the traced fact instead of re-deriving it.

## Standing

    stdlib census    8837 / 9077   97.36% bound
    examples census 99528 /101591  97.97% bound

### A flat measurement kept, with the reason

`List<E>.get(index): E` on a `List<Named>` receiver now returns Named. It
measures flat on both censuses and was kept, which is a departure from the
rule this campaign has followed all along — so the reason is recorded rather
than assumed:

  * the change is DEMONSTRATED, not speculative: `items.get(0).tag()` and
    `lookup.get("k")?.tag()` went from binding nothing to binding;
  * the census file sets spell those reads with the OPERATOR (`items[0]`,
    `lookup["k"]`), which the index path already types, so the file sets
    cannot show the gain — the same blind spot that hid the head-only
    property type for this entire campaign;
  * it is pinned with both spellings side by side, so the two paths cannot
    drift apart.

The revert-if-flat rule is about not accumulating unproven machinery. A
repro that goes from unbound to bound is proof; a census that does not
contain the shape is not a refutation. Both halves of that matter, and the
distinction is what the earlier flat reverts were missing when they were
right and what this one turns on when it is not.

### The user-code shapes, verified one by one

With the property-type and substitution work in, every ordinary shape that
motivated it now binds. Measured per repro against a warm home, so each file
reports only its OWN sites:

    chainext   7 sites   0 unbound   lookup.values.first().tag(), and via a local
    opform     9 sites   0 unbound   items[0], lookup["k"]?, items.last(), firstOrNull()
    getsub    10 sites   0 unbound   items.get(0), lookup.get("k")?
    collrecv   5 sites   0 unbound   first() on List / Collection / Iterable / Set
    mapvals    9 sites   1 unbound

The one that remains is `lookup.values.map { it.tag() }`: the lambda
parameter is bound through TWO splices — `map`'s body iterates `this` and
calls `transform(item)`, and the user lambda's `it` takes its type from
`item`. `items.map { it.tag() }` binds, so the receiver being a property
READ rather than a directly-recorded property is what differs. That is a
splice-window question, not a substitution one, and it is the next thread.

## The delegation that dropped the receiver

`lookup.values.map { it.tag() }` was the last user-code shape left, and the
answer came from tracing rather than guessing. `KLIO_SPLICE_REF` reports
what every inline splice installs in its window:

    [splice-ref] fn=map   this_arg=Member ref=Collection<1>
    [splice-ref] fn=mapTo this_arg=-      ref=null<0>

`Iterable<T>.map` is one line — `return mapTo(ArrayList(…), transform)` —
and that delegation is a BARE call on the implicit receiver. With no
receiver EXPRESSION to read a type from, the nested splice installed
nothing, and the `Collection<Named>` the outer splice had just established
was gone one level in. Every lambda parameter derived from the element went
untyped from there.

The window already held the answer. Carrying it forward across a bare
delegation — only when the callee's declared receiver is the same
classifier or a supertype, so an unrelated extension cannot inherit these
arguments — closes it.

    stdlib no_receiver_type 222 -> 215

### Every user-code shape now binds

Measured per repro against a warm home, so each file reports only its own
sites:

    mapvals   9 sites  0 unbound   lookup.values.map { }, keys.map { }
    chainext  7 sites  0 unbound   lookup.values.first().tag(), and via a local
    opform    9 sites  0 unbound   items[0], lookup["k"]?, last(), firstOrNull()
    getsub   10 sites  0 unbound   items.get(0), lookup.get("k")?
    collrecv  5 sites  0 unbound   first() on List / Collection / Iterable / Set
    headonly 12 sites  0 unbound   the six-receiver program that opened this thread

That program was 0/6 bound when the head-only representation was found. It
is now fully bound, and so is every shape derived from it.

## Standing

    stdlib census    8831 / 9064   97.43% bound
    examples census 99526 /101589  97.97% bound

### `ref=null` is not a defect count

Following the delegation fix, `KLIO_SPLICE_REF` reports 2,404 splices whose
receiver expression is a Path and whose installed ref is null. That number
invites a chase and should not have one: a receiver with no TYPE ARGUMENTS
installs no ref because there is nothing to install. `CharSequence.zip`
called on a `String`, `isEmpty` on a concrete class — `ref=null` is the
correct and complete answer for every non-generic receiver.

The probe's value is the PAIR: a receiver that did carry arguments one
frame out and null one frame in, which is what `map`/`mapTo` showed. Read
the transitions, not the totals.

## An instrument counting work that does not exist

`let` was the largest single entry in the residue by CALL NAME (19 of 215),
and it is not a dispatch at all. `fun <T, R> T.let(block: (T) -> R): R`
declares an unbounded type parameter as its receiver, so it applies to every
value and its body is SPLICED at the call site whatever the receiver turns
out to be. `KLIO_MISS_TRACE=let` on an untyped receiver reports zero runtime
misses — there is nothing there to be static or dynamic about.

The census noted `no_receiver_type` at the member path's decline, before the
splice that actually serves the call. That is the second instrument in this
campaign found to be measuring something other than its name
(`receiver_not_instance` was the first), and both were sitting on top of the
residue where they read as work.

    stdlib   no_receiver_type  215 ->  189, bound_static  1569 ->  1595
    examples no_receiver_type 1650 -> 1417, bound_static 16350 -> 16583

The emitted code is byte-identical — this is a measurement correction, not
new binding, and it is recorded as one. Taken only when EXACTLY one
extension of the name and arity exists, it is inline, and its declared
receiver is a bare unbounded type parameter.

## Standing

    stdlib census    8857 / 9064   97.72% bound
    examples census 99759 /101589  98.20% bound

### The census program is not clean, and the gate does not see it

Reading the census's full output rather than grepping it for `[lower-sites]`
turned up two failing tests inside the very program every measurement in
this campaign is taken on:

    [test] CollectionTest.minWithOrNull FAILED
    [test] CollectionTest.maxWithOrNull FAILED

A/B'd against a binary built early in this session: both fail there too, so
they are PRE-EXISTING, not a regression from any of this work. They are also
invisible to the gate — `commontest-sweep --filter CollectionTest` reports
0 failures, because the sweep compiles the whole directory while the census
passes a reduced `--only-file` set. Same source, different file set,
different answer.

That is the cross-file interference workstream the resolution plan already
tracks ("~53 failures when the corpus runs as ONE module"), reached from a
new direction. Recorded here because it bears on this campaign's own
integrity: the numbers are taken on a program that does not fully pass, and
a future reader should know that before trusting a small delta.

## The arithmetic table, completed where it paid

The unsigned types were in the primitive SET but absent from the promotion
TABLE, so every arithmetic expression over them produced no type at all.
`UInt.until` is written `(to - 1u).toUInt()` — exactly that shape.

    no_receiver_type 189 -> 183

Kotlin's unsigned arithmetic is a closed family: never mixed with the signed
types, `UByte`/`UShort` widening to `UInt`, a `ULong` operand making the
result `ULong`. A mixed signed/unsigned pair declines, as it must.

Three more rules from the same table were written and REVERTED: `String +`
concatenation, `Char + Int` / `Char - Int` / `Char - Char`, and a mixed
`Byte`/`Short` pair. All three are exact Kotlin, all three measure flat on
both censuses, and an A/B on a repro built specifically for them moved ONE
site of five — the class operator-member arm below already answers the rest.
Completing a table for its own sake is machinery without measured value.

## Standing

    stdlib census    8863 / 9064   97.78% bound

### The unsigned promotion, measured on the other census

    examples no_receiver_type 1417 -> 1339, bound_static 16583 -> 16661

Seventy-eight sites against the stdlib census's six — the same asymmetry the
head-only property type showed, and for the same reason: the example
programs are ordinary code, where an unsigned expression's result is
actually used as a receiver.

## Standing

    stdlib census    8863 / 9064   97.78% bound
    examples census 99837 /101589  98.28% bound

## The walk that stopped at the top level

`toCharArrayIfNotEmpty` was the third-largest entry in the residue by call
name, on receivers named `byteSeparator`, `groupSeparator`, `prefix`,
`suffix` — all locals initialized from `bytesFormat.<prop>`. Tracing the
local with `KLIO_VALTY_TRACE` showed `decl=<unset>`, and the reason was one
level up: the property-head walk visits top-level classes and their
COMPANIONS and stops. Every NESTED declaration's properties were unknown,
and that is exactly where the stdlib keeps its option records
(`HexFormat.BytesHexFormat`).

    no_receiver_type 183 -> 163

### The compose suite now names what does not complete

"2 did not complete" is a number, not a fact. The suite now prints the
class, and it reports `CompositionTests` and `PausableCompositionTests` —
the known throughput-bound pair, not something new. That took a two-line
change and turns an every-run mystery into a check.

### tl_cancel_via_coroutine_context is a pre-existing flake

It appeared twice running and looked like a regression. A/B'd against a
binary from early in this session: the OLD binary produces the same
truncated output, and sometimes none at all, where the current one at least
prints `c1-cancelled` some runs. Same class as
`tl_atomic_update_contended` — recorded so the next appearance is not
re-diagnosed.

## Standing

    stdlib census    8873 / 9054   98.00% bound

### Nested objects: reverted, and the reason is the key

`TimeSource.Monotonic`, `DateTimeComponents.Formats.ISO` — a nested OBJECT
read through its enclosing class name is an instance of that object, and
nothing recorded it, so eight receivers had no type. Recording
`class_prop_type_heads[{Outer, Nested}] = Nested` moves those eight and
BREAKS `TimeMarkTest.defaultTimeMarkAdjustmentBig`
(`get_field reading on kotlin.time.Duration`).

The head is the problem. A nested declaration is not registered under its
bare simple name, so `Monotonic` either names nothing or names the wrong
class, and a wrong head mis-resolves where an absent one merely declined.
Halving the change (dropping the nested object's own property heads, keeping
only the object-name read) does not help — the object-name entry alone is
what breaks it.

Two hypotheses were then tested and both are WRONG, which is the useful
part. First: that the property map also drives the read FORM
(`staticTypeDeclaresProp` consults it), so recording a nested object there
changes how the read lowers. A separate type-only map — kept out of the
property map entirely — fails identically. Second: that the head simply
does not resolve. It does; the census shows the receivers typing and
`no_class_id` unchanged.

So the breakage is in what the resolver does with a CORRECTLY typed
`Monotonic` receiver: `markNow()` returns `Monotonic.ValueTimeMark`, a
`@JvmInline value class` over a Long, and binding that call by declaration
changes which representation the chain sees — the failure is
`get_field reading on kotlin.time.Duration`, an unwrapped value where the
wrapper was expected. That is value-class representation, not receiver
typing, and four to eight sites do not justify opening it.

Recorded with both refuted hypotheses so the next attempt does not spend
its budget re-testing them.

## Every constructor scope, not just three of five

The delegation, default and superclass thunks were given their parameters'
declared types earlier in this campaign. Two more constructor-scoped
lowerings were not: the INIT BLOCK and the secondary constructor's BODY.
Both read the constructor's parameters, both were handed the names alone.

    no_receiver_type 163 -> 157

The init-block half measures flat on its own and is kept anyway. That is a
deliberate exception to the revert-if-flat rule and the reason is
structural rather than statistical: it is the same rule as the half that
pays, one fixture exercises both, and leaving one constructor scope typed
while its sibling is not is exactly the asymmetry that costs an afternoon
to rediscover. The rule this campaign follows is "do not accumulate
UNPROVEN machinery" — a proven rule applied to its remaining site is not
that.

## Standing

    stdlib census    8879 / 9048   98.13% bound

## The qualified nested constructor

`Inner.Deep(2)` reached no class at all. The BARE form `Inner(1)` already
resolves through the lexical nested-class walk; only the qualified spelling
was missing, and `HexFormat.Builder` builds `BytesHexFormat.Builder`
exactly that way. Resolved through `classIdByQualifiedSuffix` — the same
type-position convention `Outer.Inner` uses as an annotation — and
declining for an object, stub, value or abstract class.

    no_receiver_type 157 -> 155

A three-line repro proved it before the rule was written, which is the loop
that has produced every landed channel in the last stretch: name the shape,
build the smallest program that shows it unbound, THEN write the rule and
watch that program bind.

## Standing

    stdlib census    8881 / 9046   98.18% bound

## The population the census never counted

The `[lower-sites]` census measures EXPLICIT-receiver member calls. Bare
calls — no receiver written — are a separate population it does not see,
and `KLIO_OR_AUDIT` counts them by the instruction actually emitted:

    3939  NewInstance
    3338  Call/bare-extension      static
    2177  CallMemberOrGlobal       resolves by NAME at run time
    2136  Call/implicit-member     static
     451  LoadGlobal
     413  Call/bare-member         static

That third line is the one the goal cares about: 2,177 emission sites that
resolve a name at run time, against the ~155 the census had been reporting.
At run time it is `call_member_or_global` = 3.8 M executions, 8.9 % of all
dispatches. The campaign's headline number was measuring a real thing and
not the biggest thing.

Read carefully, too: the audit's SITE label and its INST are different
questions. `site=unresolved_bare_call` mostly emits `Call/bare-extension`,
which is static — counting sites by label overstates the dynamic population
by roughly half. Only `inst=CallMemberOrGlobal` is name resolution.

### First cut: nothing to shadow

`bare_call_member_shadowable` exists because a member of the implicit
receiver could shadow the resolved global. Where there is NO receiver in
scope there is no member to find, and the runtime walk resolves a name only
to arrive at the declaration already in hand. Binding those:

    CallMemberOrGlobal 2177 -> 2077

A trailing lambda keeps the old path deliberately. A unit test —
"member-or-global emission binds a composable trailing lambda by parameter"
— caught the first version of this: that path does more than dispatch, it
shapes the lambda's arity, receiver and composable broad masks from the
committed candidate. The test earned its keep.

### The splice-receiver walk is not a missed bind

`inline_splice_recv_walk` is 396 of the remaining dynamic emissions, and
its `member_of_recv` leg looked sound: the name is in the receiver chain's
COMPLETE hierarchy set, so the bound `this` is the owner and the member is
decided. Resolving it there instead of walking cuts the dynamic population
hard — 2077 -> 1748 — and breaks three commontest files and a compose
corpus program:

    ArrayDequeTest.clear         unresolved global `generateArrayDeque`
    UnsignedArraysTest.sort      stack overflow
    UnsignedArraysTest.sortDescending
    compose_uitext               DIFF

`sort()` inside `sort`'s own body binding to itself is the tell. Membership
in the hierarchy set says the NAME is a member somewhere on the chain; it
does not say the bound `this` is the class that declares the one this call
means, and it does not distinguish a self-recursive spliced body from a
call to the same name one level out. The walk's member-first behaviour is
doing real work there, not deferring for lack of information.

Reverted. Recorded because the leg reads sound and the number is the
largest single one left — the next reader should know it was tried, what it
cost, and that the missing evidence is WHICH class on the chain declares
the target, not whether the name is on it.

## What the emission count did not show

The "nothing to shadow" cut moved 100 emission SITES. At run time it moved
this:

                              early session      now
    call_member_or_global      3,788,055        10,552
    call_static                   59,388     3,836,895
    total dispatches          42,635,738    27,524,472

Name resolution for bare calls goes from 8.88 % of all dispatches to
0.04 %. The hundred sites it touched are in the hot paths — a site count is
a measure of SOURCE, and the goal is about EXECUTION.

That is the strongest single result in this campaign and it came from
changing the question, not from a new channel. The `[lower-sites]` census
had been the instrument all along; it counts explicit-receiver calls and
weights every site equally, so a fix worth 3.8 M runtime resolutions
registered as "100 sites" and a fix worth 20 cold sites registered the same
way. `KLIO_DISPATCH_STATS`'s own totals were the measure that mattered and
were never read as the headline.

Both instruments are worth keeping and they answer different questions:

  * `[lower-sites]` — did lowering decide this call site, weighted by source
    site. Good for finding UNTYPED RECEIVERS, which is what it found.
  * `[dispatch-stats]` — what the interpreter actually executed. Good for
    ranking work by what it costs at run time.

Read the second one first when the goal is "no runtime resolution".

### And it is 2.6x faster

The same change, A/B'd on otherwise-identical HEAD by removing only its
guard block and rebuilding:

    without the bare-call bind    73.48 s
    with it                       28.61 s

on the census program. So the 15.1 M `served_intrinsic` that vanished
alongside the 3.79 M `call_member_or_global` was real work, not changed
accounting: each name resolution was serving an intrinsic through the
member ladder, and binding the declaration at lowering removes the whole
chain.

This is worth stating plainly because the campaign spent most of its length
optimising a metric that could not see it. Ninety-eight per cent of
explicit-receiver call SITES were bound while 8.9 % of executed dispatches
still resolved a name — and closing that one was worth more than every
receiver-typing channel combined, in both dispatch count and wall clock.

The lesson for the next front: rank by `[dispatch-stats]` totals, confirm
with wall clock, and use `[lower-sites]` to find the mechanism once the cost
is known.

## Standing (both instruments)

    RUNTIME, census program
      call_member_or_global   3,788,055 -> 10,552    8.88% -> 0.04%
      wall clock                  73.5s -> 28.6s     2.6x

    LOWERING, explicit-receiver call sites
      stdlib census    8881 / 9046    98.18% bound   (from 92.73%)
      examples census 99901 /101377   98.54% bound

    LOWERING, bare calls (KLIO_OR_AUDIT, by emitted instruction)
      Call/bare-extension  3338   static
      Call/implicit-member 2136   static
      Call/bare-member      413   static
      CallMemberOrGlobal   2077   resolves by name

## Ranking by execution, second pass

With the bare-call form closed, `member_ladder` became the largest dynamic
resolution path at 113,980 executions. `KLIO_CALL_STATS` splits it by
receiver and name, and it is not spread out:

    84,595  <ladder>kotlin.Char.compareTo
    16,873  <ladder><instance>.assertTrue
     8,466  <ladder>kotlin.collections.MutableList.set
      1,029  <ladder>kotlin.String.get

Three quarters of it is one shape. `NaturalOrderComparator.compare(a:
Comparable<Any>, b)` holds a Char at run time, a primitive has no vtable
slot to bind, so every comparison in every sort resolved the name. The
primitive fast path handled `Int` and `Long` receivers and no comparison at
all.

    member_ladder  113,980 -> 29,380
    member_prim_op  11,610 -> 28,474

The instrument existed the whole time (`KLIO_CALL_STATS`), already split by
receiver and name, and was never read. That is the same failure as the
headline metric: the data to rank by execution was there before the work
started.

### Noted, not changed: Char.compareTo returns -1/0/1

klio returns the SIGN; kotlinc on the JVM compiles `Char.compareTo` to
integer subtraction, so `'z'.compareTo('a')` is 25 there and 1 here. The
documented contract is sign-only, so nothing in the suites catches it, and
the fast path added above deliberately reproduces the existing value rather
than changing behaviour inside a performance change. It is a real divergence
from kotlinc's observable output and belongs to whoever takes the
value-semantics pass.

### The confirmation step matters as much as the ranking

The rule recorded above is "rank by `[dispatch-stats]`, CONFIRM with wall
clock". The `compareTo` fast path is what makes the second half of that
sentence earn its place:

    before  28.61 s
    after   28.53 / 28.53 / 28.57 s

It removed 84,595 ladder executions — three quarters of that path — and
cost nothing measurable, because 84,595 out of 27.5 M total dispatches is
0.3 %. It is still worth having: the goal is no runtime NAME RESOLUTION,
not only speed, and this removes 84,595 of them. But it is not a
performance result and must not be reported as one.

By the same measure the rest of the ladder is cold. `DefaultAsserter.assertTrue`
is 16,873 executions, 0.06 % of dispatches.

The first diagnosis of it was WRONG and is worth keeping as a correction.
"The interface slot is not linked" — `KLIO_SLOT_DUMP=assertTrue` says it is:

    [slot-dump] class=kotlin.test.DefaultAsserter slot=2 -> fid=2 owner=kotlin.test.Asserter

and that target is right, because `DefaultAsserter` overrides only `fail`;
`assertTrue(message: String?, actual: Boolean)` is an interface DEFAULT with
a body. The slot call lands correctly. What ladders is INSIDE that body:

    public fun assertTrue(message: String?, actual: Boolean): Unit {
        assertTrue({ message }, actual)
    }

a bare call to the OTHER overload of its own name on the implicit receiver.
So it is not slot linking at all — it is the bare-call population again, in
its hardest form: a self-named overload set where static selection has to
pick `(() -> String?, Boolean)` over `(String?, Boolean)` from argument
shape alone.

That is precisely the shape whose binding was refuted above — `sort()`
inside `sort` bound to itself. The difference here is that correct
shape-based overload selection would pick the sibling rather than itself,
which is the evidence the earlier attempt lacked. Left open with that stated,
because 0.06 % does not justify re-entering a change that broke four suites.

One contract error found on the way and worth fixing whenever this is taken
up: `execArmCallVirtual` documents itself as having "no name-based fallback:
a missing slot is a link error", and the host it calls opens with "Named
arguments folded into `arg_params` at lowering must survive a BY-NAME
FALLBACK (an unlinked slot, a bodyless target)". Both cannot be true. A
statically bound virtual call can silently degrade to name resolution, which
is exactly what a bytecode VM or a C backend cannot allow — there the
unlinked slot must be a build error, not a walk.

So the execution-ranked front has one large result (the bare-call bind,
2.6x) and a tail that is already cold. What remains dynamic is worth
removing for the STATED goal — no runtime resolution, which a bytecode VM
and a C backend both need — not for speed.

## The third population: slot calls that walk anyway

Chasing the contract mismatch above produced a number that neither existing
instrument reported. `KLIO_SLOT_BYNAME` counts every statically bound
virtual slot call that degrades to a by-name member walk:

    68,987 on the census program
      20,243  Iterator.hasNext
      20,117  Iterator.next
       9,530  Char.toInt
       4,834  ArrayList.add
      12,831  Int.ushr / Int.shr / Int.toChar

That is larger than the ladder (29,380) and larger than the bare-call form
(10,552), and it was invisible: the site is `bound_virtual` in the census
and `call_virtual_slot` in the runtime stats. By both of this campaign's
measures those calls are STATIC. They resolve a name.

They are not broken links. Every top entry is the HOST-VALUE boundary — a
host generator serving `Iterator`, a primitive serving `Char.toInt`. There
is no interpreted body for the slot to reach, and the intrinsic is the
implementation; the walk is how the host finds it.

Which makes this the shape of the remaining work, stated exactly:

  * for the INTERPRETER it is by design and costs a name lookup;
  * for a bytecode VM or a C backend it is not acceptable at all — the call
    must name the intrinsic directly, because there is no name walk to fall
    back on in generated C.

### "Degrade" was the wrong word, and the code said so first

The obvious fix was tried: where the slot's own target links to the SAME
host symbol the name walk would find, dispatch it by FuncId instead —
identical implementation, no lookup, guarded on exact symbol equality.

    slot by-name walks  68,987 -> 45,643

and four stdlib tests fail:

    ResultTest.testRunCatchingFailure  Expected <Failure(...)>, actual <Success(...)>
    ResultTest.testConstructedSuccess
    ResultTest.testConstructedFailure
    UComparisonsTest                    exit=-6

The comment sitting directly above that branch had already said why:
"the interpreted source body reads a source-level representation the host
value never materializes (`Result.toString` matches on the `Failure`
wrapper; the host Result stores a discriminant and the raw payload)".
Symbol equality is not enough — the two paths differ in how the RECEIVER
arrives, and the by-name walk performs the representation conversion that
the FuncId entry does not.

So for a host-backed receiver the name walk is not a degrade at all. It is
the host-value conversion boundary, and counting it as "static dispatch we
failed to achieve" was wrong. The counter stays — it is the right measure of
the boundary's size — but 68,987 is the cost of the host-value model, not a
defect, and closing it means giving those members a REPRESENTATION as well
as a declaration.

So the target is not "bind the slot" but "emit the intrinsic". That is
P10's host-declaration manifest reaching its conclusion: once a host member
carries a declaration, a receiver whose static type is that host class can
be lowered to a direct intrinsic call instead of a virtual slot that
degrades. The census already says those receivers ARE typed — `Char`,
`Int`, `ArrayList` are exactly the heads the campaign spent its length
proving.

Three populations, three instruments, all now measured:

    explicit-receiver sites   155 unbound        [lower-sites]
    bare-call emissions     2,077 name-resolving  KLIO_OR_AUDIT
    slot degrades          68,987 name-walking    KLIO_SLOT_BYNAME
    member ladder          29,380 name-resolving  [dispatch-stats]

## More static can be slower, and here is the mechanism

The "nothing to shadow" win has an obvious sibling: a receiver IS in scope
but its hierarchy provably does not declare the name, so nothing can shadow
the global either. `ownerChainShadowContains` answers only from a COMPLETE
shadow set, so a `false` is proof. Binding those:

    CallMemberOrGlobal   2,077 -> 1,582
    call_member_or_global (runtime) 10,552 -> 1,865

All suites pass. And the census program gets 18 % SLOWER:

    before   28.5 s        after   33.6 s
    call_virtual_slot     99,802 -> 2,371,690
    served_user_body      85,023 -> 2,325,884
    frame_push          11.5 M   -> 13.7 M

The member-first walk was not merely resolving a name — it was SELECTING
THE HOST IMPLEMENTATION. `CallMemberOrGlobal` finds an intrinsic keyed by
the receiver's runtime class and serves it natively; the static `Call`
binds the DECLARATION and enters the interpreted Kotlin body instead. Two
million calls changed from an intrinsic to a source body.

That is the same mechanism as the FuncId experiment above, from the other
side, and together they explain why the one bare-call change that worked
was worth 2.6x: `assertEquals` and its kin have no intrinsic, so binding
the declaration reached the same body the walk would have — pure win. Where
an intrinsic exists, binding the declaration is a pessimisation.

So the rule for the remaining bare-call population is not "bind what can be
proven". It is:

    bind statically only where the target has no faster host form,
    OR teach the static call path to prefer the intrinsic the way the
    member walk already does.

The second is the real fix and it is the same missing piece as task #15:
the interpreted body and the host implementation are two representations of
one declaration, and only the by-name path currently knows how to choose
between them.

### The convergence point, refuted three ways

"Teach the static call path to prefer the intrinsic the way the member walk
does" was the fix the previous two findings pointed at. It does not work
either, and the failure names the root.

`callFunc` already consults `lookupIntrinsic(f.fqn)` — but only on an
arity-MISMATCH path, never as a preference. Making it a preference for a
body-carrying declaration at exact arity:

    commontest  2 failures
      OrderingTest.maxOfWith   Vm::get_field `name` on `kotlin.Array`
      OrderingTest.minOfWith
    wall clock  28.97 s (baseline 28.8 s — no gain either)

`get_field name on kotlin.Array` is the tell: the intrinsic and the body
take DIFFERENT ARGUMENT SHAPES for the same declaration FQN — the vararg is
packed for one and spread for the other. They are not interchangeable. The
member walk can prefer the intrinsic only because the walk ALSO normalises
the receiver and arguments on the way in.

So three attempts at this one point, each refuted with its own evidence:

  1. dispatch the slot's target by FuncId when it links to the same host
     symbol — breaks `Result` (host representation vs source representation);
  2. bind a global whose receiver provably cannot shadow it — 18 % slower
     (body instead of intrinsic);
  3. make the static path prefer the intrinsic — wrong arguments, no gain.

The root is one thing said three ways: **a declaration has two
implementations with different calling conventions, and only the by-name
path knows how to convert between them.** Fully static dispatch requires
unifying that convention — a shared entry shape for the interpreted body
and the host symbol — not a smarter choice at the call site. That is a real
project with a clear definition, and it is the honest end of this campaign's
reach.

### The design already encodes the rule, and it separates the two subsets

The link that settles a declaration's native form declines a body-bearing
one deliberately, and the comment states why: "the native representation may
cover only builtin receiver values, while Kotlin's declaration also accepts
user-defined subtypes". There is a curated escape hatch,
`intrinsicOverridesBody`, with exactly one entry.

That reasoning has a sound extension: a FINAL class has no user-defined
subtype, so the native form covers every receiver its declaration can ever
see. Allowing the link to settle those:

    slot by-name walks  68,987 -> 68,987   (no change at all)

and the reason is the useful part. The loop iterates `decl_sigs` looking for
a `host_symbol`, and the builtin-type members HAVE NO DECLARATION — that is
the audit's other 1,281. The rule could not fire because there was nothing
to fire on.

So the remaining dynamic dispatch is two disjoint problems, not one:

  * **builtin-type members** (`Iterator.hasNext`, `Char.toInt`, `Int.shr`) —
    1,281 with no Kotlin declaration anywhere. The by-name walk is the only
    thing that can find them. Needs declarations; the calling convention is
    not the obstacle because there is no body to disagree with.
  * **body-carrying stdlib declarations that also have an intrinsic**
    (`maxOf`, `Result.toString`) — the declaration exists and the two
    implementations differ in argument shape and receiver representation.
    Needs the shared entry shape.

The earlier note collapsed these into one root. They are separate, they have
different fixes, and only the second one is blocked on convention.

## Crossing the boundary per type: Char lands, and the unsigned types say why

The host short-circuits to a by-name walk whenever a member of a
host-backed receiver is an intrinsic, so a statically bound slot call
resolves a name at run time. Where the slot's own target links to the
IDENTICAL host symbol, dispatching by FuncId is the same call without the
lookup.

    all scalar variants   68,987 -> 46,421   UnsignedArraysTest / UComparisonsTest abort
    Char only             68,987 -> 59,457   every suite green

`Char` is committed. The abort was then reduced rather than left as a
restriction, and the reason is not what the first guess said:

    uintArrayOf(1u, 2u).associateWith { it.toString() }
    [klio] RSS 6480912KB exceeded cap — aborting

Unbounded recursion, not a wrong value. The intrinsic for an unsigned type
RE-ENTERS member dispatch, so binding the declaration to it by FuncId
closes a cycle; the by-name walk breaks the cycle because it re-resolves
against the runtime class each time and lands elsewhere.

So the rule is not "the receiver is a scalar" — `UInt` is as scalar as
`Char` in this runtime. It is:

    dispatch the intrinsic by FuncId only where the intrinsic is
    SELF-CONTAINED — it does not call back through member dispatch.

That is a property of the implementation, not of the receiver, and nothing
currently records it. `Char`'s conversions are leaf functions; the unsigned
formatting path is not. Whoever takes this next should look for that
property rather than widen the type list — widening is what the measurement
already refuted.

### The gate is a body, not a receiver kind

The re-entrance theory above is wrong and the guard built for it measured no
change — `1u.toString()` alone still exhausted RSS with a per-slot recursion
guard in place, so the growth was never a cycle through one slot.

The actual gate is visible in the declaration:

    public override fun toString(): String = uintToString(data)

`UInt.toString()` carries a BODY, and that body is written against the boxed
representation — it reads `data`, a field a scalar `.UInt` does not have.
Reaching it by FuncId runs a body the receiver cannot satisfy. `Char`'s
conversions have no body at all: the native form IS the implementation, which
is why `Char` alone survived the earlier sweep and looked like a fact about
scalars.

So the condition is `!hasBody()` on the slot target, and with it every scalar
variant is safe:

    Char only, no body test        68,987 -> 59,457
    all scalars, bodyless target   68,987 -> 46,421

which is exactly the number the unrestricted all-scalars attempt reached
before it aborted. The restriction cost nothing; it was in the wrong place.

Green at 46,421: commontest 117/0, drift 267/267, litmus 42/43 (the known
`tl_atomic_update_contended` timeout), units, compose exit 0 / 1314 vs 1275.
Pinned by `unsigned_scalar_intrinsic_dispatch`.

This also answers task #15 in the narrow case: a declaration's body and its
host symbol have DIFFERENT calling conventions whenever the body assumes a
boxed receiver, and `hasBody()` is a cheap, sound way to tell the two apart
without unifying them.

### The iterator protocol: 87% of the remaining walks, and no wall clock

With the scalar channel landed, the residue was concentrated rather than
spread out:

    20,243  hasNext   root=kotlin.collections.Iterator.hasNext
    20,117  next      root=kotlin.collections.Iterator.next
     4,834  add       root=kotlin.collections.ArrayList.add
    ......  the rest is a long tail under 500 each

The receiver type at each of those sites is the INTERFACE — `recv_ty=
kotlin.collections.Iterator`, not a concrete class. Host iterators are a
`Value` variant implemented in Zig with no Kotlin declaration behind them, so
`methodSlotTarget(runtime_class, slot)` has nothing to return and the slot
degrades to the named ladder. The ladder reaches `iteratorMember` only after
`collectionMutators`, `componentMembers` and everything above them, so each
of those 40,360 calls paid for the whole prefix.

Dispatching the six names the iterator variants own outright (`hasNext`,
`next`, `hasPrevious`, `previous`, `nextIndex`, `previousIndex`) straight to
the variant handler:

    46,421 -> 5,887 slot walks

and the wall clock is FLAT: 28.37s / 28.43s against a 28.6s baseline, inside
noise. That is the honest result. This channel is not a performance win — the
walks were cheap, because the names hit early string comparisons and the
receiver test is a tag check. It is worth keeping for the other reason: a
statically bound slot that resolves a NAME at run time is exactly what a
bytecode VM and the C backend cannot express, and 87% of the remaining
violations of that contract are now gone.

Restricting to names no earlier ladder step claims keeps the fix behavior-
preserving — `remove` is deliberately NOT in the set, since
`collectionMutators` answers it first for a mutable iterator.

Green: commontest 117/0, drift 267/267, litmus 42/43 (the known
`tl_atomic_update_contended` timeout), units, compose exit 0 / 1316 vs 1275.

### An overload set never cached its pick

The ladder census was two entries, not a long tail:

    16,873  <ladder>DefaultAsserter.assertTrue
     8,466  <ladder>kotlin.collections.MutableList.set
     ~1,000 and below, everything else

`DefaultAsserter.assertTrue` is an interface DEFAULT — `DefaultAsserter`
declares only `fail`. That was the first hypothesis and it is wrong: a
repro with an inherited default flat-dispatches on the first call and
memoizes. What reproduces is the OVERLOAD SET:

    interface I {
        fun f(msg: () -> String?, actual: Boolean): Int = ...
        fun f(msg: String?, actual: Boolean): Int = ...
    }

200 calls, 200 ladder entries. The resolution walk ends at

    if (resolved.unambiguous) instanceMethodCachePutRaw(...)

with `unambiguous = candidates.items.len == 1`, so a name with two
declarations was re-walked on EVERY call forever — and because
`prepareMemberFlatCall` serves from that same cache, it also never flattened
and never claimed a site memo.

The guard is stronger than it needs to be. The STRICT key already folds every
discriminator the pick consults: the receiver class and name that fix the
candidate set, and per argument a tag plus its class identity, closure body +
module, function decl pointer, or primitive array kind. For a fixed strict key
the pick is a pure function of the key, so storing it cannot serve an overload
the walk would not have chosen. Only the RELAXED key (container kind tags, no
identity) still needs the single-candidate guarantee, since two overloads can
share its coarser signature.

    ladder      29,380 -> 12,505
    site memo    ~0    -> 17,000

Wall clock is again FLAT (28.52s / 28.55s against 28.6s). Both channels
closed this session moved work off the dynamic paths without moving the
clock, which is worth stating plainly: the remaining dispatch cost of this
program is not in name resolution.

`overload_set_lambda_discriminated` pins the semantics that matter — the
lambda/String? pair, a Base/Derived pair, and an Int/String pair each keep
resolving to the right member on repeat calls.

Green: commontest 117/0, drift 267/267, litmus 42/43 (known timeout), units,
compose exit 0 / 1314 vs 1275.

### The census program was two tests short of the one it measured

`CollectionTest.minWithOrNull` and `maxWithOrNull` failed under
`scripts/dispatch-census.sh` while passing under the commontest sweep, and
that was carried for a while as a suspected cross-file interference bug in
the interpreter. It is not a bug. The failure is

    unresolved global `STRING_CASE_INSENSITIVE_ORDER`

and `CollectionTest.kt:15` imports that symbol from `test.comparisons`,
declared in `OrderingTest.kt` — a file the census set did not include.
Adding it makes both tests pass with no interpreter change.

Two consequences worth stating. The measurement was wrong in a small way the
whole time: two test bodies never ran, so their sites were never lowered and
never counted. And the "cross-file interference" framing pointed at a
mechanism that does not exist, which is worse than the miscount.

The file is now in the set. The site total moved 9,046 -> 9,063, so the
NEW BASELINE is:

    total=9063   bound_virtual 7,274 (80.26%)  bound_static 1,608 (17.74%)
                 no_receiver_type 163 (1.80%)  no_class_id 10
                 resolver_declined 6           nullable_or_generic 2

Bound share 97.99%. Counts taken before this change are not comparable to
counts taken after it.

### The untyped-local tail, and one refutation inside it

`no_receiver_type` is 163 sites, and 66 of the 92 PATH cases are
`local_no_decl_type`: a local with no declared type whose initializer is a
`Call` the return-type deriver cannot answer. `KLIO_NORECV_WHY` now prints
`at=file:line` for each, which turns a guessing exercise into a list:

    CollectionTest.kt:39   val mixed  = listOf('a', "b", StringBuilder("c"), null, ...)
    CollectionTest.kt:45   val data   = listOf(null, "foo", null, "bar")
    CollectionTest.kt:56   val source = listOf(null, "foo", "bar")
    CollectionTest.kt:612  val hasNulls = listOf("foo", null, "bar")
    IterableTests.kt:475   val accumulators = data.runningReduce { acc, e -> acc + e }
    Arrays.kt / Instant.kt / HexExtensions.kt / Strings.kt — one each

The shape is visible: a generic call with a NULL argument. Reduced,
`listOf("zzz", "foo")` derives `List` and `listOf(null, "foo")` derives
nothing. (Two earlier repros appeared to refute this; both were run without
`KLIO_DISPATCH_STATS=1`, which is what enables the counting, so they printed
nothing for the wrong reason. Worth remembering: the census sets that
variable, a bare `klio run` does not.)

The obvious cause is that applicability rejects a null argument against a
bare type parameter — `arg.is_null and param_ty.nullable` fails for `T`,
though an unbounded `T` has `Any?` for a bound and Kotlin admits the null.
Scoring it applicable (below `Any?`, preserving Kotlin's preference for the
non-generic overload) DID fix one derivation, `optimizeReadOnlyList`. It did
NOT fix the sites above, left the census exactly at 9,063 / 163, and A/B on
`only(null)`, `pick(null)`, `pick("s")` and `listOf(null, "foo")` produced
byte-identical output with and without it — the runtime path already handles
null against `T` by another route. Flat and unobservable, so it is reverted
rather than carried.

That leaves the real cause elsewhere: at the failing sites `listOf` resolves
to no target at all (no `[bare]` line), while the same call in a different
function resolves to `kotlin.collections.listOf#2349`. The next step is why
resolution declines there, NOT the applicability score.

### The compose non-completers were a crash, not throughput

`CompositionTests` and `PausableCompositionTests` were carried as
throughput-bound — classes too slow for the 480s per-child cap. They are not.
Run directly, `PausableCompositionTests` dies after 8 tests in 76s:

    panic: index out of bounds: index 9028, len 6
      constStr  -> module.consts.items[id.int()]
      leafExprServe
      runFrameInner

A const id from one module indexing another module's const table. The func is
`androidx.compose.runtime.report`, id 15036, served against a module holding
ONE func and SIX consts.

The mechanism is at the flat-call seam:

    const lmod = site.req.run_module orelse f.module;

A flat request carries the callee's `Func` directly, but the module its body
must be read against is only known when the request names one. Falling back
to the CALLER's module is right only when that module owns the callee. An
anonymous object's runtime module delegates base funcs through the shared
lazy header section — so `funcById` succeeds for id 15036 — while carrying
only its own const pool, so every const id in that body lands outside it.

Guarding just the leaf serve moved the panic rather than fixing it:
`openActivation(H, allocator, f.module, site.req, host)` makes the identical
assumption one line down, and the next crash was a register read at the same
9028/6. The fix resolves the callee's module ONCE at the seam — the request's
own, else the caller's when it truly owns the `Func`, else the program module
that does — and uses it for both the leaf serve and the activation.

    before   1314-1317 passed, 2-3 classes did not complete
    after    1345 passed across 46 test classes, 0 did not complete

Baseline raised 1275 -> 1305 on the same ~±40 margin. Two real test failures
inside `PausableCompositionTests` (`resumeOnBackgroundThread` and one other)
are now VISIBLE for the first time — the class used to be discarded whole.

Green: commontest 117/0, drift 267/267, litmus 42/43 (known timeout), units,
census unmoved at 9,063.

### Char.compareTo returned the sign, kotlinc returns the difference

    'a'.compareTo('c')   klio -1    kotlinc -2

kotlinc compiles `Char.compareTo` to `Character.compare`, which is the code
difference. `Comparable` only contracts for the SIGN, so -1 was not a
contract violation — but a program that prints the result sees a different
number than it does under kotlinc, and matching kotlinc is the rule.

Both paths returned the sign and both are fixed: the `kotlin.Char.compareTo`
intrinsic, and the `primitiveMemberOp` fast path added earlier in this
campaign (which was written to return "the same -1/0/1 the host intrinsic
does" — it did, and both were wrong together). `Int` and `Long` correctly
stay -1/0/1: kotlinc compiles those to `Integer.compare` / `Long.compare`.

`kotlin.String.compareTo` had the SAME divergence and is fixed too, in a
follow-up. It routes through `compareUtf16`, whose three-way ordering is used
for sorting elsewhere, so the fix is a SIBLING — `compareUtf16Difference`,
plus `compareIgnoreCaseUtf8Difference` for the folded form — rather than a
change to the existing comparator:

    "a".compareTo("c")            -1  ->  -2   (code-unit difference)
    "ab".compareTo("abcd")        -1  ->  -2   (length difference)
    "".compareTo("abc")           -1  ->  -3
    "A".compareTo("a")            -1  -> -32
    "A".compareTo("a", true)       0  ->   0   (folds first, then differs)

The existing unit test was `"abc"` vs `"abd"` asserting -1 — which passes
under BOTH behaviours, since `'c' - 'd'` is -1. It was extended with the
cases that actually distinguish them (first-mismatch difference, prefix
length difference, and the `ignoreCase` fold) so the coverage is real.

Pinned by `char_compare_to_code_difference`. Green: commontest 117/0, drift
267/267, litmus 42/43 (known timeout), units, compose exit 0 / 1342 passed,
0 did not complete (baseline 1305).

### The slot contract, stated accurately

`CallVirtual`'s definition claimed:

    runtime work is one `(receiver ClassId, slot) -> FuncId` lookup,
    never a method-name search

and `invokeVirtualMember` performs that search. Both could not be true; the
comment was the aspiration, and `KLIO_SLOT_BYNAME` exists because of it.

After this session's channels the residue is 5,893, and it is one shape:

    4,834  add       root=kotlin.collections.ArrayList.add
      450  add       root=kotlin.collections.MutableCollection.add
      184  iterator  root=kotlin.collections.Iterable.iterator
      146  isEmpty   root=kotlin.collections.Collection.isEmpty
      ...  everything else under 100

Every one is a HOST-BACKED collection receiver. The value reports a
collection interface as its type; that interface has no Kotlin declaration in
any source klio reads (the same `js/builtins` gap task #16 names), so
`methodSlotTarget` has nothing to return.

So the contract cannot be made true by a change to the instruction or to the
host — it is blocked on declaring the builtin members, and pretending
otherwise in the IR definition is what makes the next reader chase the wrong
mechanism. The comment now states what holds, for which receivers, and what
the remaining gap is. The claim gets restored when the declarations land.

The iterator-protocol shortcut earlier in this plan is deliberately NOT the
model to copy here: it removed a ladder prefix, not the name search, so
repeating it for `add` would move the count without changing the contract.

### The iterator protocol dispatches by FuncId, and the shortcut is retired

`KLIO_NOINST_WHY` said the iterator calls declined with
`target-not-executable`: the slot resolved, but the target was a bodyless
interface member with no native registered under its FQN, because the
implementation lives VM-side in `iteratorMember` and is reached by RECEIVER
VARIANT, not by name.

So the target `FuncId` is now bound to that handler directly. `hostSlotOpFor`
matches the declaration's owner and name ONCE per `FuncId` per thread and
caches the answer, so every later call on that slot is an integer probe; the
handlers are the existing ones, since a second implementation is exactly the
duplication this is meant to avoid. Where the class has no slot entry at all,
the slot ROOT still names the declaration, which settles
`ListIterator.hasPrevious`/`previous` the same way.

    target-not-executable  Iterator.hasNext   20,255 -> 0
    target-not-executable  Iterator.next      20,125 -> 0

That retires the name-keyed shortcut added earlier in this campaign. Removing
it alone cost 174 walks (5,893 -> 6,067); binding the root as well brings it
back to 5,893 with NO name matching left on the path. Same count, different
mechanism — and the mechanism is the point: 40,380 calls that reached their
implementation by comparing a string now reach it by id, which is what a
bytecode VM and the C backend can express.

Wall clock 28.98s / 28.94s against 28.6s — flat to slightly noisy, consistent
with every other channel in this campaign.

Green: commontest 117/0, drift 267/267, litmus 42/43 (known timeout), units.

### Collection `iterator()` joins it

Same shape, same fix: `Iterable.iterator` resolved to `List.iterator` /
`MutableSet.iterator` / `Set.iterator`, all bodyless with no native under
their FQN, because the host builds the iterator from the receiver's own
representation. Adding a `collection_iterator` op — self-iterator convention
first, then `builtinIterator`, exactly the order the named path applies —
settles them by id too.

    decline reasons   ~350 -> 55
    slot walks      5,893 -> 5,691

`hostSlotOpFor` is the extension point for the rest of this class of member:
a builtin whose implementation exists host-side but is reached by receiver
variant rather than by FQN. The remaining 55 declines are `KClass.isInstance`
and a short tail.

### A host collection reaches its intrinsic directly

The decline counter and the walk counter disagreed — 55 declines against
5,691 walks — because most walks never reach the block `KLIO_NOINST_WHY`
instruments. They exit earlier, at the host-intrinsic probe:

    if (lookupIntrinsic(self, member_fqn)) |native| {
        if (isScalarValue(receiver)) { ...bind by FuncId... }
        break :blk .{ .target = null, .name = n };   // <- here
    }

The native is ALREADY IN HAND at that point. The code finds
`kotlin.collections.MutableList.add`, then declines so the named ladder can
find the same symbol again by string.

The scalar carve-out was justified by wrapper-backed values: `Result` stores
a discriminant and a raw payload, an iterator is a host generator, and the
conversion for those lives on the named path (binding them by id returned
`Success` for a `Failure`). That reasoning does not extend to the CONTAINER
variants. A host `.List`/`.Set`/`.Map` is not a wrapper — `add`, `set`, `get`
take the value as it stands — so calling the intrinsic in hand is the same
call the walk would make.

    slot walks   5,691 -> 80

and the wall clock is 28.71s / 28.74s against 28.6s, flat as every other
channel here. What remains is a 25-entry tail: `KClass.isInstance`,
`StringBuilder.reverse`, `Comparator.compare`, `Array.get`.

Pinned by `collection_slot_direct_intrinsic`, which exercises the rebound
members together with the mutation and iteration order a wrong binding would
disturb — `add`/`add(index)`/`set`/`removeAt`/`addAll`/`remove`/`subList` on a
list, the set and map forms, and a `listIterator` walking backwards.

Green: commontest 117/0, drift 267/267, litmus 42/43 (known timeout), units.

### The other non-wrapper variants, and where the channel ends

`Array` holds its elements inline, a `StringBuilder` its bytes, a
`Comparator` its comparison — none is a discriminant over a payload the
intrinsic would have to unpack, so they take the same direct call:

    slot walks   80 -> 60

That is where this channel ends for now. What is left is a real tail, and
each entry is a DIFFERENT reason rather than one more variant:

    25  KClass.isInstance          reflection receiver, not a host container
    13  Comparator.compare         reached without a class-keyed intrinsic
     5  IntArray.get / Array.get   a `get` whose FQN probe misses
     4  ArrayList.iterator
     3  Any.toString

Session total on this channel: 68,987 -> 60, and the mechanism changed
rather than being special-cased — the name-keyed shortcut added early in the
campaign was deleted once the FuncId binding covered its cases.

Every step measured FLAT on wall clock (28.4-29.0s across six independent
changes against a 28.6s baseline). That is the honest summary: this work
buys contract conformance — a call reaching its implementation by id rather
than by string, which is what a bytecode VM and the C backend can express —
and not speed.

### `member_ladder` counts the route, not the work

The ladder number has been quoted all through this campaign as a
dynamic-dispatch channel, including in the summary above. That reading is
too strong, and the new `replay-hits` line in the stats dump shows why:

    member_ladder   12,517
    replay-hits     20,738

`callMemberInnerStatic`'s FIRST step, for any non-`Instance` receiver, is
`builtinIntrinsicReplay` — a cached (class, name) -> intrinsic lookup. A
call routed to the "ladder" and served there never walks an arm; it takes one
hash probe. The replay count EXCEEDS the ladder count because
`callMemberInnerStatic` is reached from several routes, not only that arm.

So `member_ladder` is the name of a ROUTE, not a measure of name-resolution
work, and the honest form of the campaign's headline is:

    slot by-name walks   68,987 -> 60     (a real name search, removed)
    member_ladder        29,380 -> 12,517 (a route label; most are one
                                           cached probe, not a walk)

This does not make the ladder work worthless — the overload-set caching
earlier in this plan removed 16,873 genuine re-resolutions, and those were
re-walking the full candidate set every call. It does mean the remaining
12,517 should not be counted as 12,517 name searches, and that closing them
further is a representational change (a `CallMember` carrying a resolved
target for a host receiver), not a hot-path win. Wall clock with the counter
installed: 28.67s / 28.71s, unchanged.
