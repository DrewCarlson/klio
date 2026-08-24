# Four campaigns: concurrency correctness + the three performance fronts

Standing after the library-100 campaign (see `plans/census-gates-and-red-mass.md`
B1–B33): every library census suite is at zero, the compose_plugin gate holds
its 1375 baseline, and the native channel machinery is deleted. What remains
red anywhere in the project is one family of cross-thread compose tests, and
the three measured-but-open performance fronts. This plan tracks all four to
completion.

Discipline carried over: root-cause only, peel one root at a time, full
battery before every commit, examples + pinned output per interpreter root,
never `zig build` while a background battery runs, census scratch homes as
documented in the census plan.

---

## Task 1 — compose_plugin concurrency group: zero real failures

The last real red in the project. The gate tolerates `MAX_FAILED = 11`
because this family flips run to run:

- `SnapshotStateListTests.concurrent*` / `SnapshotStateMapTests.concurrent*` /
  `SnapshotStateSetTests.concurrent*` (cross-thread global-snapshot
  modification: writer threads mutate while the main thread applies)
- `RecomposerTests.validatePotentialDeadlock`
- `PausableCompositionTests.resumeOnBackgroundThread` /
  `markInvalidFromBackgroundThread`

The itest's own baseline comment records the instability as real tracked open
work, not test noise: the flip lives in klio's MVCC snapshot machinery
(upstream `Snapshot.kt` runs interpreted — see the snapshot-core port memory)
and/or the pump/worker cross-thread handoff.

Work items:
- [x] Flip rate measured (2026-08-23, 5 classes x 6 solo reps on an idle
      box): counts are 100% STABLE — List 62/3, Set 20/1, Map 56/3,
      Pausable 24/1, Recomposer 11/1 every rep. The "race family" is
      DISPROVEN as races: every solo failure is a deterministic
      THROUGHPUT timeout. concurrentMixingWriteApply_* declare
      `runTest(timeout = 30.seconds)` upstream and exceed it;
      put_replace exceeds even a 60s budget; validatePotentialDeadlock
      hits the 90s wall cap; the PausableComposition pair is the known
      timeout-bound pair. The gate-scale "flip" is load pushing
      borderline classmates over the same caps.
- [x] put_replace mechanism named (repro putrep2.kt bisect: replace on a
      100-entry map = 24ms/write, add = 2ms; ctor/collide-small = fast):
      SnapshotStateMap.mutate retries `newMap == oldMap` per attempt;
      the vendored PersistentHashMap has NO equals override, so `==` is
      AbstractMap's entry-walk (~50 interpreted trie-gets); a REPLACE
      keeps sizes equal so equality never short-circuits (put_new exits
      via the size check), and 100 concurrent writers amplify attempts
      quadratically. Upstream JVM runs the same asymptotics at native
      constants — the klio-side lever is interpreter throughput on this
      shape, not semantics.
- [x] Lever 1 LANDED (5f6b22be): TTAS spin locks (SpinMutex spun on a
      bus-locked swap; lockExclusive retried cmpxchg blind). Contended
      repro 904 -> 630ms/round; swap leaf 31.6% -> 7.4%.
- [x] Lever 2 LANDED (c8dda94e): host equality for the vendored
      PersistentHashMap — CHAMP-trie walk with node-identity pruning,
      collision nodes unordered, non-scalar elements bail to dispatch.
      Contended-replace repro 630 -> 78ms; put_replace PASSES solo
      (SnapshotStateMapTests 56 -> 57/59). Guard example
      snapshot_map_equality.kt pins the semantics (reorder, collision
      keys, custom equals, wide tries).
- [x] Lever 3 LANDED (47d9c817): same for the persistent vectors
      (SmallPersistentVector/PersistentVector) — array-identity pruned,
      tail padding respected, disjoint size ranges make cross-class
      false. Contended list-replace 40ms/round; every list
      assertEquals in the suite takes the pruned path. Guard example
      snapshot_list_equality.kt.
- [x] Levers probed and REJECTED with measurements: backoff sleep
      ladder after yield window (667ms vs 630ms on putrep3 — reverted;
      the libc time is malloc/memcpy, not sched_yield — ~500 voluntary
      switches/s/thread only); module-cell lock is already Noop
      (objref_immutable); memberNameIdentity already pointer-cached;
      field read/write memos already exist.
- 2026-08-23 IDLE-BOX RE-BASELINE after the three levers: gate 725s /
  1376 passed / 14 failed, 0 DNC. put_replace passes SOLO but
  re-crosses the 10s runTest cap under the gate's own 8-way
  contention (3-8x class inflation). The whole remaining family is
  contention-amplified throughput; no correctness component left.
- [ ] REMAINING = interpreted CALL throughput, ~1.5-2x needed. The
      mixing repro (mixrep.kt: 100 maps x 100 indexed puts +
      notifyObjectsInitialized) runs 3.06s/rep on the harness; the
      failing tests do 10 reps against a 30s upstream budget. Per put
      ~300us =~ 100 interpreted calls x ~3us frame/dispatch cost.
      Profile is DIFFUSE: getAdapted string-map gets ~4% across many
      tables, eqlBytes 4% (eql__anon_3017 dominant), acquireRegs
      memset 2.5% (frames failing frameDefBeforeUse's <=64-local
      def-before-use test still eagerly fill), allocSmall/
      allocLockedOne ~3%, libc malloc/memcpy ~8%. No single 2x lever;
      this is the dispatch/activation-machinery campaign shape (frame
      open/close, arg settle, member-dispatch ladder).
- [ ] Solo-failing set with timings (all deterministic, vs their
      budgets): List addAll trio 31/31/42s, Set mixing add 31s, Map
      mixing set/clear 31/47s (30s upstream runTest timeouts);
      validatePotentialDeadlock 90s wall cap; Pausable pair
      resumeOnBackgroundThread ~28s yield-cost + markInvalid needs
      >10s (env-cap bound, pass at 90s).
- [ ] Each interpreter root ships an example + pinned output.
- [ ] Exit: the concurrency classes pass 10/10 consecutive SOLO gate runs;
      `MAX_FAILED` lowered to the new honest ceiling (target 0, and the
      baseline expect tightened accordingly).
- [ ] Verify whether the 5 standing corpus compose load-flakes
      (compose_foundation/material3/material3_text/multiwindow/window under
      `--jobs 4`) share the root; they are contention-sensitivity of the same
      machinery by hypothesis. If they fall, pin them green in the corpus
      run; if not, they move to task 2 (throughput) or get their own root
      entry here.

## Task 2 — compose suite wall time

The plugin gate takes minutes; every compose iteration pays it. The perf
memory (`klio-compose-suite-perf`) already established:
- The wall floor is compute-heavy classes run interpreted ~300x native
  (`SlotTableBuilderTests.oneRectBenchmarkSimulation` repeat(10000),
  `SlotTableTests` 138 pure-compute tests).
- Loop JIT does NOT help this shape (378s vs 326s measured), and `klio test`
  forces JIT off anyway.
- 8-way CPU contention inflates per-class walls 3-8x.
- Lowering the runTest dispatch cap is HARMFUL (teardown-deadlock hangs).
- OPEN QUESTION pinned: profile whether `buildSubTable` is an O(n^2)
  pathology or genuine cost.

Work items:
- [x] Profile the heavy classes and answer the buildSubTable question:
      ANSWERED 2026-08-22 — buildSubTable is LINEAR (in-module scaling probe:
      2.08/2.09/2.07 ms per ~30-group round across 4000 rounds with an aging
      parent table; zero growth). No pathology; the cost is genuine
      interpreted work, so the wall-time lever is per-call overhead.
- [ ] Attack the top interpreter frames the profile names (dispatch, field
      access, allocation — whatever actually dominates), measure after each
      change on the SAME solo class before touching the suite.
- 2026-08-22 SOLO GATE BASELINE: 727s wall (including the itest binary
  rebuild) — 1378 passed (ABOVE the 1375 ratchet, best measurement ever
  recorded), 12 counted failures = exactly the throughput-timeout family
  (Snapshot concurrent group, validatePotentialDeadlock,
  resumeOnBackgroundThread double-counted) + one MovableContent load flake.
  The former contamination flakes (frame-clock, testInsertDuringRecomposition,
  markInvalidFromBackgroundThread) are green at gate scale. NOTE: 12 is one
  over MAX_FAILED=11 under this box's background load; the ceiling stays —
  the fix direction is down via throughput work, not a wider ceiling.
- 2026-08-23 WORKER-WIDTH SCALING MEASURED (32-core box, solo):
  4 workers = 727s / 1378 passed / 12 failed; 8 workers = 512s / 1372 /
  18; 6 workers = 513s / 1372 / 18 (0 DNC everywhere). Two findings:
  (a) the wall FLOORS at ~510s above 4 workers — the heavy-class tail
  (snapshot/SlotTable compute) bounds it, not queue width; (b) any width
  above 4 inflates the task-1 race family past the ratchet (1372 < 1375,
  18 > MAX_FAILED 11) — the same concurrent* snapshot tests plus
  markInvalidFromBackgroundThread/testInsertDuringRecomposition. Width
  stays at 4. CONVERGENCE: task 2's halving is BLOCKED by task 1's race
  family; fixing the MVCC-snapshot cross-thread races unlocks both the
  fail ceiling and ~-215s of wall.
- [ ] Exit: full solo `itest-compose_plugin_commontest` wall time halved from
      the current measured baseline (record it first), with the gate still at
      its pass baseline. Path after the width measurement: fix the task-1
      races first, then re-adopt width 6-8 (~510s), then shorten the
      heavy-class tail (interpreter throughput: profile is diffuse —
      libc-malloc 14%, runFrameExec 9%, allocator-poison memset 4.5%,
      eqlBytes 3% — allocation traffic is the aggregate theme).

## Task 3 — Value layout stage 5b (RESOLVED: further along than assumed)

Plan correction (2026-08-22): the value-layout campaign is FURTHER along
than this tracker assumed — per `plans/value-layout-campaign.md`, stage 5b's
first half LANDED and `Value` = 24B today (hot-layout-confirmed). Only
stage 5c (24 -> 16: Array pointer-bit tag + IrClosure boxing) remains, and
it is DEFERRED by its own recorded measurement discipline: IrClosure boxing
adds an allocation to compose's hottest creation path (the profile's
`buildAstLambdaWithFlagFuncid`), so it re-opens only when a measurement
motivates it, gated on the compose plugin wall as well as rangebench.

- [x] Baseline re-measured on the current tree (post perf batches 1+2):
      rangebench 290ms warm on the ReleaseSafe harness (1650ms cold with
      bake load), oneRect 60s, SnapshotStateList.contains(1000) 4.87ms.
- [x] Exit satisfied per the task's own terms: the landed measured-positive
      step is 5b-first-half (Value 24B, prior session); 5c's deferral with
      numbers is recorded in the value-layout plan. Nothing to do here until
      a profile shows Value-copy traffic dominating.

## Task 4 — C transpiler speedup (inline hot-view sub-ABI)

The transpiler is at 293/293 corpus byte-parity but measured perf-NEUTRAL
(rangebench RF 14.44 vs 14.55 JIT-off). The speedup campaign (inline
hot-view sub-ABI) is pinned open in the transpiler plan. Traps recorded:
ids need the PINNED image artifact (bakes are not cross-process id-stable),
the 256MB runCli initial-thread stack, `KLIO_NATIVE_TRACE` is the engagement
oracle.

Work items:
- [x] Design re-read + REALITY RE-MEASURED (2026-08-22): the hot-view
      sub-ABI partially EXISTS in the emitter (klio_hot_layout KV,
      kv_const_int/int/long/bool inlines, kv_trace, kv_edge, div-guarded
      scalar binop fast paths) — the plan's speedup section is half built.
      Fresh A/B on rangebench: transpiled native 825-830ms vs TODAY'S
      interpreter 291ms (ReleaseSafe harness, BC tier + recent levers) —
      the interpreter has improved ~3.3x since the plan's recorded 0.97s/
      0.83s numbers, so the C output is now ~2.9x SLOWER than interpreted.
      The neutral-to-losing gap means the remaining exported-call ops
      (loops' compare/branch/add run through klio_op_* calls per op)
      dominate; the campaign's real work is extending the inline coverage
      until whole scalar loops stay in C (then the C compiler vectorizes).
      Value layout is settled at 24B (task 3), so the KV offsets are
      stable to build against.
- [x] Remaining speedup work, all landed (2026-08-23): (a) startup floor
      62ms — fine; (b) char-range escape ROOT-FIXED IN THE LOWERING
      (4d00da2f): char ranges now lower as counted register loops like
      int/long (Char comparisons order by code, Char±Int is Char), so
      the iterator protocol vanishes for BOTH tiers — interpreter 291 ->
      164ms, native escapes 52k -> 132; stepped char keeps the iterator
      lowering (step-snap arithmetic is Int-only); (c) fused counted-loop
      emission extended to descending loops (28c73118): the latch
      validator admitted only Add so downTo/step (Sub latch) was
      silently rejected — Sub admitted, every recognizer bail now
      fuseTraces, rangebench 535 -> 303ms with both int loops fused.
- [x] ENGAGEMENT ROOT FOUND AND FIXED (2026-08-23): the hot view never
      engaged — the klio_rt layout probes read undefined padding, UB
      lowered to a trap that silently killed the fill thread; usable was 0
      in every historic measurement. Probes now zero their backing bytes.
- [x] First fused-loop emitter landed: intbench 122ms native vs 180ms
      interp (first C-beats-interpreter), rangebench 830 -> 535ms with 1/3
      loops fused; parity 392/393 (compose_foundation = standing load
      flake, solo byte-identical). Remaining: downTo recognizer widening +
      the char-range escape.
- [x] EXIT MET (2026-08-23): rangebench transpiled native 124ms vs
      interpreter 164ms (1.32x, JIT-off ReleaseSafe harness; was 830ms vs
      291ms = 2.9x SLOWER at diagnosis). Full battery green: unit tests,
      sweep 117/0, transpiler corpus 392/1 (standing foundation load
      flake), cli corpus 395/396 (same flake). char_range_loops.kt
      example + pinned output added. Corpus transpile timeout 300 -> 600s
      (heavy compose files bake cold after any zig build and take ~380s
      on the first transpile — the 300s limit flapped).

---

## Gate-red round (2026-08-24, CLOSED — GATE GREEN)

The first full `scripts/gate.sh` of the campaign flagged suites the
targeted batteries never ran (e2e at 16 fails, ktor_server red). Five
roots, all landed; final gate.sh GREEN:
- 1932fb08: the virtual-slot interface-delegate arm forwarded before
  the arg_params->names reconstruction — delegated named args bound
  positionally (bisected to the delegation-defaults commit).
- c73ce5f9: the parity/e2e in-process runner never grew the
  serialization/datetime packs or their host bindings — every
  census-era example importing them failed since being pinned (the
  bisect "first bad" was where each example APPEARED, twice over —
  appearance-not-regression trap). Lenient-warn memo made per-run;
  typed_format pin de-warninged (stderr never reaches the capture).
- 61bdf9c7: the inference-opened reified-extension splice never asked
  whether the receiver's static type serves the call — kotlinc
  resolves members first; pipelineCall.respond(message, typeInfo)
  spliced respond(status, message) and every ktor server response died
  on a status dispatch miss (itest-ktor_server red).
- 0e13c1e5: Virtual-mode pumps starved parked timers under a busy
  yield loop (launch queue hot every round; advance never ran) —
  timeout_over_a_yield_loop livelocked to the harness wall cap. Rule
  landed: virtual time never runs slower than real time.
- 071d1ca0: a NESTED Vm join (mid-run image-extend bake) raised the
  process-global boundary abandon, drained the shared pool, and swept
  run-scoped registries the outer run still owned (latent; found en
  route). Scoped to the outermost join via a live-run counter.

## Collection-hot-path round (2026-08-24, closed)

Three levers landed after the gate-green round; solo-deterministic
family 9 -> 4:
- 25db6cfa: scalar bitwise infix (and/or/xor/shl/shr/ushr on static
  Int/Long, Boolean trio) lowers as BinOps — 3.7M virtual-slot calls
  became register ops in the snapshot-map repro (call_virtual_slot
  4.0M -> 0.9M); took SnapshotStateSetTests to 21/21 SOLO GREEN and
  Map's mixing_set under budget solo.
- 45bc114a: host contains/indexOf scans for the vendored persistent
  vectors — 4257ms -> 31ms per 1000 contains. The flat-call preparers
  must DECLINE host-served names or a flat-prepared interpreted body
  bypasses every dispatch-ladder intercept (the virtual-slot preparer
  was the live route). SnapshotStateListTests 62 -> 63/65
  (concurrentGlobalModifications_addAll passes).
- Gate at width6/cap5: 528s / 1378 passed / 12 failed — the
  global-modification + put_replace family is GONE at gate scale;
  remaining = the five 30s-budget mixing tests (re-inflated by gate
  contention; Set's passes solo), the Recomposer pair, Pausable pair,
  one MovableContent flake.
- REMAINING CEILING, precisely sized: the mixing_clear shape runs 1M
  puts + 100k clears against a 30s budget = 30us/put needed vs 280us
  today (~10x). Profile stays diffuse (memset 5.3, eqlBytes 3.8,
  getIndex 2.6, alloc ~3, libc 8) — this IS the dispatch/activation
  call-throughput campaign, nothing narrower is left.
- TRAP: solo harness class runs now hit the default 6GB RSS cap
  (arena profile + tests running further); use KLIO_RSS_CAP_KB=16777216
  for solo classes. Gate children run CLI GC mode, unaffected.

## Call-throughput round 2 (2026-08-24)

- d5815f1e LANDED: trivial property initializers (one Const or one
  LoadParam, returned) serve without a framed eval at both construction
  sites — put census 60.9k -> 42.6k calls (-30%). Builder-heavy paths
  carried ~10 such frames per operation.
- Try-recursion in thisScan LANDED: the binds-this scan no longer
  blanket-trues try/finally bodies (over-declining member splices).
- ATTEMPTED AND REVERTED, both findings recorded: bare-inline
  lambda-literal splicing (kotlinc semantics — run/repeat/synchronized
  splice instead of closure+two frames). kotlin.synchronized measured
  2640 -> 905ns/block spliced, BUT: (1) spliced bodies resolve bare
  names against the CALL file — creatingSnapshot's file-private
  `observers` leaked cross-file; a DECL-FILE RESOLUTION window
  (extend lambda_splice_resolve) is prerequisite; (2) even same-file
  gated, the compose plugin suite COLLAPSED (1259/131, CompositionTests
  hangs) — the composable lowering conflicts with newly-spliced inline
  bodies in test files; plugin compatibility is the second
  prerequisite. Ratchet restored at 526s/1378/12 after revert.
- Put-cycle census (oneput.kt, 1000 puts): 55 calls/put — snapshot
  validity cluster is the largest coherent block (8x valid(),
  4x SnapshotIdSet.get, 4x Snapshot.current, 4x readable per put),
  then per-construction inits (now served), then 4x synchronized.
  Queued next: host fast path for SnapshotIdSet.get/valid (interpreted
  bit-set over Long fields, host-readable layout), allocator zero-fill
  audit (memset 186/425 = allocBytesWithAlignment).

## Call-throughput round 4 (2026-08-23)

- 6d33ce07 LANDED: persistent-vector builder bulk ops host-served
  (persistent_list_mut.zig). `removeRange` (the SubList-clear
  iterator-removeAt O(n^2) walk) rebuilds the trie from kept elements in
  fresh owned 33-slot buffers: 3.8ms -> 0.33ms per addAll+removeRange
  pair (11.6x); `addAll` append (tail-fit fast path + gated full
  rebuild): addAll+clear pair 305 -> 218us. BOTH List timeout tests now
  PASS solo (addAll_clear 29.1s, removeRange 12.3s vs 39s). Example
  snapshot_list_bulk_ops.kt pins 16 shapes incl. two-level tries.
- 4b916b7d LANDED, three roots on the way to the literal-lambda splice:
  (1) trivial-init serve now classifies LAZY image funcs
  (ensureFuncBody before the block scan) and multi-LoadParam prologues,
  and runs at the parent-chain site too — aconly census -23%.
  (2) VALUE-REFERENCE scoping now follows the reference span's file
  (bareRefTier/classRefTier/topLevelPropRefTier derive the package from
  packageOfFile, as resolveBareCallIndexed already did) — kills the
  cross-file `observers` unresolved-reference that sank the first LLP
  attempt.
  (3) KLIO_LLP=1 re-lands lambda-literal splicing with three exclusions:
  class-member callees (bare member reads need the decl class's this —
  `objectArgs` global miss), receiver-formed lambda params (with(x){}
  nested rebinding unimplemented, as member_body_ext), and lambdas that
  `return@<callee>` their own label (a nested member-inline stays
  framed, so the label must live on a real frame; deep label scan
  descends nested lambdas). CompositionTests-family 147/148 under
  LLP=1 (the one fail = the standing cap-bound Pausable test); the old
  collapse (1259/131 + hangs) is GONE.
- LLP=1 measured: synchronized 2640 -> 975ns/block; addAll+clear pair
  218 -> 164us; the real addAll_clear test shape 2.87 -> 2.30s/rep
  (23s of 30s budget — margin recovered). Map put group unchanged
  (its costs are flat machinery, not frame count: census -30% frames,
  wall flat).
- Stdlib sweep drove three more fit gates (eacede58, a36c97c9): 6
  OrderingTest-family failures were all wrong-overload splices —
  crossinline/noinline capture (compareBy embeds the selector in a
  result closure), arity + lambda-slot fit under the trailing-lambda
  mapping with default-fill tails (conditionalUpdate(structural=true,
  block)), and a same-package same-shape candidate-tie decline (sumOf's
  per-numeric selectors; kotlin.synchronized vs platform.synchronized
  are scope-separated, NOT a tie — cross-package ties cost 0.5s/rep
  until scoped). Sweep 117/0 under LLP.
- 5eabde0b FLIPPED: splice on by default (KLIO_LLP=0 bisects back).
  SnapshotStateListTests 65/65 solo — FIRST full green.
  COMPOSE GATE RECORD: 1383 passed / 7 failed at 510s (from 1380/10 at
  522s): both List timeout tests and Pausable.markInvalid left the fail
  set. Remaining 6 unique: Movable flake, Pausable.resumeOnBackground,
  Recomposer pausing/testInsert/validatePotentialDeadlock, Map _clear.
- Gate-red round on the flip (3 itest fails), all three splice
  regressions root-caused: (1) lock-family "virtual call receiver is
  not an instance" (tl_atomicfu_lock_mutex, ktor_locks_mutex) — a
  CAPTURE-reached caller local (`val lock`) shadowed the spliced
  receiver's member `lock()`; the documented ctorInitNonInvocable bail
  only covers init-recorded locals, so capture-hoisted names with a
  splice receiver whose class declares the name now defer to the
  member path, and the anon-capture call arm emits the arbitrated
  CallValueOrMember under a splice receiver. (2)
  captured_write_shared_resolution — a class's fn-typed property `run`
  outranks kotlin.run by scope; the splice now declines SHADOWED
  callees (own/enclosing member or in-scope binding named like the
  inline fn). TRAP recorded: a lambda body lowers more than once and
  the KEPT pass resolves captures differently (resolve() non-null via
  hoist) — arbitration arms must cover capture-reached names, and
  single-pass lowering traces can mislead.
- Dead-closure elimination LANDED (06d2a3aa + f8fb6e20): a lambda
  literal the spliced callee only CALLS no longer materializes (the
  splice's call-position expansion consumes it; the per-call closure
  alloc + captures vanish). The `paramOnlyCalled` scan's final rule
  set, each clause bought by a real regression: call-head exemption at
  the body's TOP LEVEL only (tryAdd called inside loopOnState's nested
  lambda); MEMBER-name occurrences count (`expected.getter()` invokes
  the receiver-lambda param through the member route); any nested
  lambda literal in the body counts (undecidable through another
  splice layer); the ARG lambda referencing the PARAM'S OWN NAME
  declines (observe's literal into observeDerivedStateRecalculations —
  both named `block` — needed the binding as the shadow the window
  hides). KLIO_ARG_SKIP=0 bisects, KLIO_ARG_SKIP_ONLY=<names> narrows,
  KLIO_ARG_SKIP_TRACE lists fired skips. Measured: synchronized 2640
  -> 490ns/block cumulative, map group 1649 -> 1606ms.
  GATE RECORD: 1385 passed / 5 failed at 502s; RecomposerTests
  pausing/testInsert left the fail set. Ratchet RAISED 1377 -> 1381.
  Remaining fail set (4 unique): Movable flake,
  Pausable.resumeOnBackgroundThread, validatePotentialDeadlock,
  Map _clear.
- Solo standing: List 65/65, Set 21/21, Observer 30/30, Recomposer
  11/12 (validatePotentialDeadlock only), Pausable 24/25, Map 58/59
  (_clear 36.9s vs 30). compose_window example: correct output but
  394s wall solo (the corpus rc=None entries are real perf, not
  flakes).
- Pausable.resumeOnBackgroundThread ROOT-CAUSED and CLOSED: the test
  resumes 1000 pausable chunks one cross-thread round-trip at a time
  (~40-55s interpreted) and passes under upstream's OWN 60s runTest
  default; the only failure was our 10s gate override — a hang-era
  trade (90s once measured 1336 with two classes not completing vs
  1345 at 10s) whose hang population no longer exists. The cap
  returned to the upstream default.
  GATE: **1388 passed / 2 failed at 452s** — the 10s cap was also
  COSTING wall (capped tests burned their 10s then their classmates
  absorbed noise; 502 -> 452s). Movable flake and both Pausable
  entries left the fail set.
- REMAINING REAL FAILURES (2): RecomposerTests.validatePotentialDeadlock
  (interpreted TestCoroutineScheduler drain slower than the infinite
  withContext(Default) writer round-trip at one virtual instant) and
  SnapshotStateMapTests.concurrentMixingWriteApply_clear (1M puts vs
  its declared 30s: ~170us/put vs 28us needed — CHAMP-put + mutate
  wrapper floor). Both are pure interpreted-throughput ceilings.
## Candidate-pool chip (2026-08-24)

- dda02ebc: the implicit-candidate dispatch walk's per-call buffer
  (alloc + free every dynamic member dispatch) now rides a threadlocal
  free-list mirroring the args-pool pattern. oneRect 28.5 -> 27.8s
  (-2.3%) — the diffuse-wall verdict re-confirmed: no single interpreter
  allocation family moves the gate meaningfully. Full battery green.
  (Context: oneRect itself had already halved across the session,
  61 -> 28.5s, from the splice + serve rounds.)

## Round 5: the ceiling quantified (2026-08-24)

- 9fa01f5f LANDED: class-static memo for `<class-companion-or-self>`
  value reads (the string-keyed companion_singletons probe priced every
  `Job`-in-value-position context lookup; 700k occurrences in one
  drainbench). Wall-neutral — another cheap-event elimination.
- MEASURED-NEGATIVE, recorded: (a) id-keyed dispatch caches — the
  string-hash cluster is DIFFUSE (~10 distinct maps at 1-2% each:
  member registry via callMemberInnerStatic, field-ladder probes via
  getFieldInner/getMemberField, per-map getAdapted instances); ceiling
  ~10% wall, unreachable to either remaining test. (b) Accessor and
  init classifiers were dead for lazy image funcs — fixed earlier;
  eliminating 487k getter frames moved census -16%, wall FLAT. Frame
  counts are not the wall; the flat floor (libc/memset/exec loop/
  refcount) is.
- The allocator memset (5.9% + free-poison) is STRUCTURAL to
  ReleaseSafe: std.mem.Allocator's generic wrapper `@memset(...,
  undefined)`s every alloc and free in safe builds regardless of
  backing allocator. Only ReleaseFast removes it.
- ReleaseFast DECISIVE A/B: passes NEITHER remaining test
  (Map _clear 31.1s vs 30 declared; validatePotentialDeadlock still
  incomplete past 600s). It would buy gate wall (~-15-20%, ≈380s vs
  the 364 target) and nothing else. Build-policy call stays with the
  user, now with complete data.
- validatePotentialDeadlock QUANTIFIED: not a stuck race — the bare
  drain-vs-worker race is trivially winnable (advance returned in 2ms
  in isolation). The cost is volume: 10 advances x ~300 virtual frames
  x (recompose 200 Texts + apply + notifications) ≈ 500-900s
  interpreted vs the 90s cap — needs ~10x. Map _clear needs ~5.5x.
  BOTH are compile-tier territory (the pinned transpiler/bytecode
  campaigns); every surgical lever is landed or measured-insufficient.

## Call-throughput round 3 (2026-08-24)

- 956600b5 LANDED: host-served snapshot validity walk (readable/valid
  + IdSet probe via a Func.host_route fqn-classified memo at
  execArmCall). Put census 42.6k -> 29.2k calls; mixrep 2.8 -> 2.44s;
  COMPOSE GATE RECORD: 1380 passed / 10 failed at 524s. The residual
  `readable` stat = the same-fqn T.readable(state) extension wrapper
  (needs Snapshot.current threadlocal + observer dispatch — poor host
  fit, not chased).
- Cached-pointer field probes for host paths (InstanceData.getCached).
- Cumulative shape standing: clearShape 22.3 -> 18.1s/rep, mixrep
  2.8 -> 2.44s, putrep3 78 -> 47ms. Map _clear solo 46 -> 38s (needs
  ~6x more on its bulk shape); List addAll_clear 33s / removeRange 39s.
- Remaining profile: diffuse floor (libc 8.3, runFrameExec 7.7,
  memset 4.9, eqlBytes 4.2, alloc ~4.5) — no single >10% item left on
  the put cycle.
- Round close: List addAll_clear at 30.4s vs its 30.0s budget (0.4s
  over — boundary); removeRange 39s; Map _clear 38s. Durable passage
  needs either host addAll-at-index/removeRange (vendored
  PersistentVectorBuilder mutation surgery) or the diffuse floor
  (string-keyed dispatch caches -> interned ids; allocator zero-fill).

## Running log

- 2026-08-22 PERF BATCH 2: every remaining `[24]ArgShape` scratch shrunk
  to `[6]` (heap fallback covers the rare rest) — oneRect 61 -> 60s,
  contains(1000) 5.0 -> 4.87ms. ReleaseFast A/B DATA POINT (not adopted):
  the harness at ReleaseFast runs oneRect in 48s vs 60s (-20%), contains
  4.47ms, launch 190us — the whole delta is Zig safety machinery (stack
  0xAA fills we cannot reach + allocator poison + bounds checks). Whether
  the GATE should trade safety checking for 20% wall is a build-policy
  call for the user; recorded, not switched.
- 2026-08-22 PERF BATCH 1 (tasks 2+3): the top profile frame of the heavy
  compose classes was memset (15.5% of oneRectBenchmarkSimulation) — Zig
  safety builds 0xAA-fill every `undefined` stack array at its DECLARED
  size, and three hot paths declared multi-KB buffers per call. Fixes:
  leaf-serve coerce buffer moved to a per-depth threadlocal bank; the leaf
  register-bank eager Unit-fill replaced by a wmask read-guard (reads of
  unwritten slots serve the fill value; reclaim builds keep the eager
  fill); two-tier buffers in invokeMethodFuncId (8 before 64 Value slots)
  and the runtime applicability shapes (6 before heap ArgShape). Measured:
  oneRect solo 64-65s -> 61s stable, SnapshotStateList.contains(1000)
  6.0ms -> 5.0ms, empty cross-thread launch 234 -> 214us, withContext
  round-trip 486 -> 424us. memset bucket 15.5% -> 7.8%. Full battery
  green.

- 2026-08-22: plan written. Task 1 started.
- 2026-08-22 flip-rate measurement (5 classes x 3 SOLO runs, itest-exact
  env): the group splits three ways.
  - DETERMINISTIC (3/3): List.concurrentGlobalModifications_addAll,
    List.concurrentMixingWriteApply_addAll_clear / _addAll_removeRange,
    Map.concurrentModificationInGlobal_put_replace,
    Map.concurrentMixingWriteApply_set / _clear,
    Set.concurrentMixingWriteApply_add, Recomposer.validatePotentialDeadlock,
    Pausable.resumeOnBackgroundThread.
  - FLAKY SOLO: Set.concurrentGlobalModification_remove (1/3),
    Recomposer.pausingTheFrameClockStopShouldBlockWithFrameNanos (2/3).
  - LOAD-ONLY (pass 3/3 solo): List.concurrentGlobalModification_add,
    Map.concurrentModificationInGlobal_put_new,
    Pausable.markInvalidFromBackgroundThread, MovableContent/Recomposer
    strays seen in gate runs.
  - Every deterministic failure lands EXACTLY on its cap (30.2s on the
    declared 30s runTest timeout, 10.3s on the 10s env cap, 90.2s on the
    wall cap). These are TIMEOUTS, not lost writes: no assertion failure
    observed anywhere in the group.
- 2026-08-22 microbench (scratchpad/xthread.kt): an EMPTY
  `launch(Dispatchers.Default) {}` costs ~1.5ms; an empty SAME-thread
  launch ~2.2ms; a `withContext(Default)` round-trip ~2.9ms. KLIO_PROF
  shows no sleeping (libc <2%) — the cost is flat interpreted compute:
  string hashing for dispatch-cache keys (`hash`/`hashString`/`mum` ~10%,
  via methodArgSig / memberSiteSig / instanceMethodKeyScoped), string
  equality (`eqlBytes` 4.4%), and the interpreter loop. The GetField site
  cache already serves field reads (mono+poly routes); the residue is the
  breadth of interpreted upstream Job/context machinery per launch.
  CONCLUSION: tasks 1 and 2 share one root — coroutine-op throughput —
  and the fix surface is task-2/3-shaped (shorten or cache the hot
  interpreted paths), NOT a memory-model race. Task 1 keeps two possibly
  genuine correctness items: validatePotentialDeadlock (hang-vs-slow probe
  under 400s wall in flight) and pausingTheFrameClockStopShouldBlockWithFrameNanos
  (frame-clock ordering, flaky 2/3).
- 2026-08-22 ROOT QUANTIFIED (ReleaseSafe harness this time — the earlier
  Debug numbers were 6x inflated): empty cross-thread launch 234us,
  same-thread 350us, withContext(Default) round-trip 486us — launches are
  NOT the problem. The killer is the VERIFY phase of the Snapshot tests:
  `SnapshotStateList.contains` at size 1000 costs 6.0ms/call (vs 27us on a
  plain klio ArrayList — 220x); the addAll test's 50x1000-contains verify
  loop alone needs ~300s against its 30s cap. Direct PersistentVector
  numbers (scratchpad/pvbench.kt): indexed get 9us, iterator step 8.2us,
  contains 9.6ms (≈19us/element scanned), snapshot `readable` read 27us.
  The per-element cost is INTERPRETED-CALL OVERHEAD (~6us/call across
  hasNext/next/equals), not instruction-walk: the bytecode tier moves it
  only 6% (KLIO_BC=0 A/B), CallMemberOrGlobal/callNamedOverload are COLD
  in the loop (64 CMGs total), and the profile is flat — libc (malloc/
  memcpy family) ~16-18%, runFrameExec ~11%, memset ~4% (callNamedOverload
  stack-buffer init), eqlBytes ~4% (name-keyed cache checks), everything
  else <3%. No single lever: the campaign target is per-call overhead
  (frame open/close, register-file init, name-identity string work), i.e.
  exactly tasks 2+3. Native shadow implementations of the vendored
  PersistentVector were considered and REJECTED on the same grounds the
  native channels were deleted.
- 2026-08-22 CONTAMINATION FIXED: two-part root. (1) The wall-cap abort
  unwound with an interpreter-level error that SKIPPED Kotlin catch/finally,
  so a capped test's infra teardown (compositionTest disposing its
  recomposer/composition, runTest cancelling children) never ran — its
  globally registered snapshot observers and live compositions poisoned
  every later test in the class. The wall cap is now STAGED: first fire
  throws a catchable kotlin.RuntimeException (finally/teardown runs) with a
  20s unwind budget; a second expiry hard-aborts + abandons as before.
  (2) The drain window was a fixed 200ms with an unconditional flag clear —
  a straggler in a bounded native wait (sync-resume spin) could outlive it
  and keep running its dead test forever with the flags cleared. The drain
  now polls a new `threads_in_eval` census until the cohort actually leaves
  interpreted code (10s bound, loud warning on timeout). Verified:
  RecomposerTests 4/4 runs = 11/1 with ONLY the throughput livelock red
  (pausing frame-clock was 2/3 red, now 4/4 green in class context);
  SnapshotStateSetTests.concurrentGlobalModification_remove 5/5 green
  solo — its earlier flake was the same contamination. Unit tests +
  coroutines census 1299/0 hold.
- validatePotentialDeadlock RECLASSIFIED: spin dumps 40s apart show
  different live frames (ChangeList apply, then a worker's snapshot write)
  — progress, not deadlock. Mechanism: the interpreted TestCoroutineScheduler
  drain iteration is slower than the worker round-trip, so the infinite
  withContext(Default) writer keeps the zero-virtual-delay task stream
  dense and advanceTimeBy never reaches its target (upstream passes only
  because real JVM threads out-pace the drain loop). Folds into the
  throughput campaign with the rest of the timeout family.
- 2026-08-22 CONTAMINATION MECHANISM (task 1 correctness item): the
  pausing frame-clock test is 4/4 green run as the ONLY test, but 2/3 red
  when its class runs — validatePotentialDeadlock (declared earlier in the
  class) hits the 90s wall cap first and its two INFINITE LaunchedEffect
  loops + Default-dispatcher workers are ABANDONED, not stopped; the
  successor test inherits stolen CPU and possibly dirty process-global
  snapshot state ("daemon task abandoned at run boundary" then surfaces in
  arbitrary later monitor waits). NEXT: verify what the run boundary
  actually does to abandoned worker loops, and make a wall-capped test's
  teardown quiesce them before the next test starts.
