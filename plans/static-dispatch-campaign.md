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

Next step: print `module.pending_lambda_local_decl_types` unconditionally
at the top of the lambda-body lower for this repro and distinguish
"channel was null" (a producer that never set it — the `apply` receiver
lambda reaches `lowerLambdaBody*` through a caller other than the two in
`expr.zig`) from "snapshot taken too early". The fix differs: the first
needs the missing producer to set the channel, the second needs the
lambda lowered after the enclosing declaration settles.

This is the last named cluster in `local_no_decl_type`. The other residual
names — `symbol`/`index`/`array`, and the `it` family — are separate.
