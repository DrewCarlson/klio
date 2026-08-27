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
- [x] Interpreted CALL throughput rounds (see the running log through
      2026-08-26): mixrep 3.06s -> 0.77s/rep, putrep3 78 -> 22ms,
      map-replica frames/insert ~30 -> ~5.3, mixing_set PASSES solo at
      7.5s. Solo standing 2026-08-26: List 65/65, Set 21/21, Map 58/59
      (_clear ~36s of work vs its 30s declared budget — 1.2x), the
      Pausable pair green under upstream's 60s default; remaining =
      _clear (allocation-bound floor) + validatePotentialDeadlock
      (order-of-magnitude, re-measurement in flight).
- [x] Each interpreter root ships an example + pinned output
      (snapshot_map_equality/list_equality/list_bulk_ops,
      indices_shadowing, collection_indices, char_range_loops; the
      whole-put serve's oracle is the 59/59 class itself).
- [~] Exit (2026-08-27 gate on the rendezvous fix: **1389 passed / 1
      failed / 0 DNC at 418s**, ratchet 1386): the ONLY standing failure
      is validatePotentialDeadlock. Was: SnapshotStateMapTests 59/59 SOLO (first ever; _clear 14.4s
      vs 30s budget after the whole-cycle put serve + the perm-mint
      birth-barrier GC fix), List 65/65, Set 21/21, Observer 30/30
      solo; gate 1389/1/0 with the ONLY real failure
      validatePotentialDeadlock; ratchet RAISED 1381 -> 1386,
      MAX_FAILED LOWERED 11 -> 5. Remaining for target-0: vpd's 8.5x
      (Front A) and the 10/10-consecutive-solo confirmation runs.
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
  and SnapshotStateMapTests.concurrentMixingWriteApply_clear. Both are
  pure interpreted-throughput ceilings, both now PRECISELY sized
  (2026-08-26): vpd PASSES solo at 763s under a raised wall cap — the
  first-ever completion, correct end to end, needs 8.5x vs the 90s cap
  (its cost is the recompose/apply machinery, untouched by the map-path
  rounds); _clear does its 10-rep workload in ~36s vs the declared 30s
  runTest budget — 1.2x, allocation-bound (~16% of profile is
  alloc/poison/slab; frames/insert already ~5).
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

## Round 6: the compounding core found (2026-08-24)

The "diffuse floor" verdict in Round 5 was WRONG in one decisive way: the
unattributable libc bucket (17-29% in every profile) was not diffuse — it
was `std.c.getenv` (a full environ scan) executing on EVERY GetField (two
sites), EVERY CallMember, and EVERY frame activation x3, for trace gates
(KLIO_GF_TRACE/KLIO_CM_TRACE/KLIO_CHAIN_TRACE) nobody had set. Profile
mis-attribution hid it: the scans were inlined into unknown-libc.

- ed851d67 LANDED: all per-call env probes now one-time cached statics
  (gf/cm/chain + rsel/qt/remember). framed 1.56 -> 1.11s (-29%),
  oneRect 28.4 -> 22.1s (-22%), stdlib sweep 190 -> 168s, libc bucket
  GONE from profiles.
- cf7594d0 LANDED: leaf serve runs the dense bytecode stream (fib
  interp 3.15 -> 0.44s, 7x) + structural leaf-abandons memoize on Func
  (leaf_hopeless; framed micro -17%).
- 73184cd8 LANDED: per-Func bc-stream memo (bc_memo) — funcStreams took
  a GLOBAL mutex + hashmap probe per activation (and the leaf walker
  asked twice). framed 1.11 -> 1.055s, oneRect 22.1 -> 21.2s.
  FORMAT_VERSION 52 -> 53 (TRAP: any ir.Func field addition must bump
  it, else stale pinned images panic "incorrect alignment").
- 280ae7ab LANDED: negative TL cache entries (miss_ttl=63 amortized
  re-probe) for method/ext/intrinsic/field-read/field-write caches —
  measured FLAT on mapops/Map _clear (their misses were rare) but kills
  the per-miss prog-cell borrow class; and the type-disproof
  adjudicator (`argDefinitelyNotParamType`) memoized by (param_ty ptr,
  arg-type identity) — its uncached ladder pays alias/class string
  probes + a HEAP-ALLOCATING supertype BFS per candidate-arg per call.
  vpd eqlBytes 6.5 -> 4.8%. Containers excluded (content-dependent).
- Gate wall: 497s (relink-tainted) -> 420s WARM (prev best 452). Target
  364.
- validatePotentialDeadlock re-diagnosed at speed: NOT a livelock —
  live churn (spin shows recomposeToGroupEnd over the 200 Texts while
  the Dispatchers.Default loop ticks ~10/s). advance(5000 virtual ms)
  x10 = ~3000 recomposes x 200 Texts. Needs order-of-magnitude call
  throughput (the pinned campaign), not a fairness fix.

- 1288874b: bc_memo gen-stamped (v54) — the memo dangled into
  FuncStreams freed by `resetCacheForTest` at in-process program
  boundaries (parity_object_init "invalid enum value" crash). Rule: a
  per-Func pointer memo into a resettable cache must carry that cache's
  generation. gate.sh GREEN (litmus 126s, sweep 164s); gate 419s
  true-warm, 1388/2.

## Round 7: receiver-formed lambda splicing (2026-08-24)

The round-4 splice exclusion (`with(x){}`-family receiver lambdas stayed
framed) is LIFTED (81c76695, KLIO_RFS=0 restores). The changelist op VM
(`Operations.executeAndFlushAllPendingOperations`: drain → forEach →
with(operation) → executeWithComposeStackTrace, ~30 interpreted calls
per applied op, `kotlin.with` alone 612k calls in a 45s vpd window) was
the motivating shape. Three enabling fixes:

- Spliced receiver lambdas set `spliceRecvTy` from the SUBJECT's static
  head — declared head when concrete, else derived from the receiver
  EXPRESSION (`with(stack)` substitutes Operations for the generic `T`),
  mirroring the inline-fn splice's generic-receiver substitution.
- The spliced subject PREPENDS to the bare-call receiver chain (it is
  the innermost implicit receiver, ahead of the enclosing framed
  receiver), with the head resolved through `classIdIndexed` because
  registry keys carry file-collision mangles (`Operation$f429`).
- `hierarchy_shadow_names` has NO entry for image-loaded pack classes
  (the round-4 assumption "baked emissions never consult it" broke once
  pack inline bodies re-splice at test-source sites): membership falls
  back to the function index (`mextCandidateOwnedBy` via
  `member_ext_owner_class`).

DECLINED (precise, scanned): a lambda body whose bare call is a member
EXTENSION candidate (`executeWithComposeStackTrace` = Operation's mext
on OperationArgContainer) needs TWO implicit receivers from the runtime
tower, which a spliced lambda does not carry — `argLambdaHasMemberExtBareCall`
keeps those callees framed. Splicing them emitted `unresolved global`
(the fallback emission has no runtime receiver walk). Future work:
thread a splice receiver TOWER so this last shape splices too.

Results with RFS ON: sweep 117/0, unit green, vpd `kotlin.with`
612k→259k (residual = the declined mext site), compose gate 1388/2 @
415s true-warm (from 419). Map _clear/oneRect flat (no apply-path
dependence). One gate-load flake (pausingTheFrameClock*) passed solo
and in class context.

OUTCOME: OPT-IN (5e9cb057, `KLIO_RFS=1`), default OFF. The parity
battery caught the broader hazard surface the decline scan cannot
cover: QUALIFIED member-ext calls (`with(owner) { list.show() }` —
Vm::call_member miss), static operator resolution, and companion
implicit-chain reads inside spliced bodies all need the subject on the
RUNTIME receiver chain. Every RFS resolution change (subject-head
derivation, chain prepend, mangle-tolerant receiver_is_owner, index
mext fallback) is gated on the same switch — the tree is
behavior-identical to pre-RFS with the flag off. PREREQUISITE pinned:
a splice receiver TOWER — emitted dispatches inside spliced receiver
lambdas must carry the bound subject registers so the runtime
member/mext/operator walks see them ahead of the frame chain (likely
an inst-level `splice_tower: []Reg` on the CallMember family + walk
plumbing). That is the completing piece for this round's ~4s wall and
the op-VM splice family.

## Round 8: the splice receiver tower (2026-08-24, infrastructure landed)

24fa6c50: two new insts — `EnclosingPush {src}` / `EnclosingPop` — mark a
spliced receiver-lambda region; the exec arms push the subject onto the
frame-owned enclosing-receiver chain (`pushEnclosingSubject`), which every
dispatch walk already consults and which callees inherit (`activateChain`
copies in-flight pushes). A non-local exit that skips the pop is healed at
frame teardown (the chain dies with the frame). Emission sites inside a
tower region use chain-driven CMG (`recv = null`) instead of pinning one
bound register — a pinned subject REPLACES the frame `this` and inverts
Kotlin's innermost-first ranking for nested subjects. FORMAT_VERSION 55.

Acceptance progress with KLIO_RFS=1: the qualified member-extension pair
(with_receiver_member_extension_visible_in_lambda,
inline_member_extension_via_with_block) PASSES — the tower works for the
shape that motivated it. REMAINING ROOT, precisely diagnosed on
ext_receiver_strict_proof.kt: an `AstLambda` closure CREATED inside a
pushed-subject region materializes its `this` capture from the chain top
(the pushed subject), and the receiver-split override at
`callValueWithThis` then leaves the stale subject in the activation's
capture slot — `with(Outer()) { with(list) { render() } }` walks
[Outer] instead of [List, Outer] and the member beats the applicable
extension. The fix lives in AstLambda capture materialization (creation
must not eagerly bind a pushed SUBJECT as the `this` capture of a
receiver-formed literal) or in making the split override unconditional
for receiver-formed closures. Until that lands, KLIO_RFS stays opt-in
and the tree is behavior-identical with it off (parity 0 fails, sweep
117/0).

## Round 8b: with-family CORRECT under RFS; the flip backlog (2026-08-24)

c715b615: the diagnosed AstLambda root fixed at its true mechanism —
`recvFnReceiverFor` walked the chain to REPLACE a supplied receiver when
the literal's declared head is a bare TYPE PARAMETER (`with`'s `T.()`),
which proves nothing about any value; once the subject tower put an
Instance on the chain it won over the real `with(list)` subject. An
unprovable (unregistered-class) head now keeps the supplied receiver.
With `KLIO_RFS=1`, ext_receiver_strict_proof.kt matches kotlinc
EXACTLY — nested with() subjects, strict extension proofs, typealias
expansion, nullable subjects all correct through spliced regions.

DEFAULT-ON ATTEMPT: 14 parity reds (census in scratchpad/rfs_backlog.txt:
two-receivers-via-this@label, companion implicit chain, static operator
resolution, unsigned compare/sort via comparator paths, empty-container
declared/binding elem typing, local-ext f-bounded param, nested-it
shadow, char/string compareTo difference, nested expected-comparator
chain, derived-receiver static binds). Each is a distinct shape where
the splice's static resolution diverges from the framed route — the
drive-green backlog for the flip. Default stays opt-in; the head-guard
lands unconditionally (parity 0, sweep 117/0 with RFS off).

BACKLOG REFRAMED (first peel): `string_compare_to_difference.kt` run
STANDALONE under KLIO_RFS=1 is byte-identical to RFS=0 — the 14 reds
are NOT per-shape user-code divergences. The parity itests run against
PRE-BAKED base images (KLIO_PARITY_BASE_IMAGES) whose STDLIB was
lowered with the flipped default; fresh-lowered stdlib under RFS=1
passes where the baked form fails (unsigned_compare dies in `sorted`'s
UnsupportedOperationException fallback arm). So the flip blocker is a
bake/image-path interaction with RFS-spliced stdlib bodies — WRONG,
retired by the next isolation:

ISOLATED (second peel): the baked-image path is INNOCENT — a default-on
build's `klio-harness run` (fresh KLIO_HOME, freshly re-baked embedded
stdlib) passes the fixtures, and the corpus itest fails EVEN WITHOUT
`KLIO_PARITY_BASE_IMAGES` set. The failing universe is parity's
`.SourcePacks` mode (stdlib + kotlinx packs lowered from source, one
process). First mechanism read: `sorted()` is
`toTypedArray().apply { sort() }` — the RFS-spliced `apply` body
statically binds a WRONG `sort` (UnsupportedOperationException at
runtime) where the framed closure defers everything (its recv_ty is the
bare `T`). The flip therefore needs RESOLUTION PARITY: inside a tower
region, a bare call with any receiver-shadowable candidate must defer
to the chain-driven CallMemberOrGlobal exactly as the framed body
would, instead of letting the static tiers commit. One rule, applied at
lowerPathCall's commit point gated on (rfsEnabled, encl_tower_depth >
0), should retire most of the 14-shape backlog at once.

Parity-defer LANDED (inert with RFS off): the lowerPathCall bail is in
(gated rfsEnabled + encl_tower_depth>0). Default-on census after it:
still 12 corpus reds, with several failure MODES changed (receiver
ranking outputs shifted) — the rule moves shapes but is not sufficient
alone; the remaining divergences also live outside bare-Path calls
(operators, comparator paths through non-Path forms, elem typing).
Continue peeling per-fixture with the default flipped locally.

CORPUS CLEAR (252/252 default-on) via three more roots on top of the
walk-ordering fix: (1) reverse fn-type refutation in the static shape
engine — a definitely non-callable argument (String/scalar) never
satisfies a function-typed param in ANY spelling (`<function>`, `->`,
FunctionN; the head previously named no class and answered .unknown);
also the raw KLIO_LAMBDA_REFUTE getenv there is now cached. (2) The
inline-splice PIN declines when the resolved member has a fn-spelled
param fed a non-lambda argument (url(urlString) must not pin
url(block)). (3) `collectReceiverTowerLabeled` ranks the splice-window
subject BEFORE the lexical owner under RFS (member-extension scope
tiers index that order: InnerScope's String.towerTag() outranks
OuterScope's inside with(InnerScope())); mirrored switch
rfsSpliceFirst in build.zig (import cycle). FLIP RESIDUE (4 shapes,
full-litmus census under default-on): companion_property_rides_
implicit_chain (companion read in spliced body -> global), e2e
inline_member_in_receiver_lambda (member-inline eachInline in
with(sb){}), receiver_fn_field_direct_invoke (null hit),
splice_receiver_member_write (member WRITE in spliced body). Then:
full battery + compose gate + flip.

ROUND 8f: the LITMUS surface reached ZERO under default-on (nested
window-head provenance fix: `inlineBodyRecvHead` may use the window's
subject head only when the WINDOW set it — `splice_recv_from_window` —
which un-declined the reified `subclass` splice while keeping the
MeasurePolicy/List hygiene test; plus catch/finally routes now restore
the frame chain to try-entry length). The FLIP COMMIT (d7912d93) then
hit the STDLIB SWEEP: 22 failures, one dominant mechanism (values
becoming `kotlin.Unit`, e.g. ReversedViews subLists), reproducible ONLY
with the full per-directory RUN SET in one process (compile context
alone is clean; single-file and single-target runs pass). Seed
isolated: ConcurrentModificationTest.mutableList — `unresolved global
removeAt` thrown with NO closure frame above mutableList:154
(`ArrayDeque(4).apply { addAll(...); action(this) }`), i.e. an
op-literal body (`{ removeAt(2) }`, a CollectionOperation ctor arg
consumed DYNAMICALLY) executing through an emission that only makes
sense spliced. The failing test then pollutes siblings in-process.
ROUND 10 — FLAG RETIREMENT + THE MARK-PROVENANCE ROOT (fa1dc55c,
a4272233; user directive: no feature flags for landed behavior):
KLIO_RFS (+ its build.zig mirror), KLIO_PIS, KLIO_XIS are GONE — the
receiver-formed splice family and both no-lambda inline tiers are
unconditional. The Movable regression root LANDED: nested splices
sharing a param NAME (`kotlin.with`'s own `block` inside
`SlotTable.edit`, whose receiver-formed param is also `block`) had
name-keyed mark suspension strip the OUTER callee's receiver-lambda
mark — the caller's `block()` then spliced with NO receiver and the
editor lambda ran on the table. Marks now carry SHARED provenance
(noteSharedRlpMark at the already-marked skip; suspension keeps shared
keys). A 12-line repro (scratchpad/edm4.kt) pins it. member_inline_
lambda additionally got a COST gate (smallInlineBody: expr-body or
<=4 stmts, no try) — splicing large bodies into hot callers inflates
frames past the no-fill mask (the map test lost a third of its
throughput to per-activation fill/alloc, compounding under CAS
contention to the 90s cap). KLIO_MIS remains the LAST flag: with the
provenance fix Movable passes under it, but the map path still
degrades under contention even cost-gated (~-13% per-op) — root that,
then delete the flag.

ROUND 9 — FULL INLINE COVERAGE (bd2deccf, fb0453ab, 28891e49,
5f65e2f3; user goal: "make sure this applies to any relevant inline
functions"): three new splice tiers, all gate.sh GREEN —
(1) plain_inline_nolambda: no-lambda inline fns splice at bare call
sites (member inlines inside the owner hierarchy via the member-splice
window; top-level when unshadowed) — `peekOperation` (311k frames in
one vpd window) eliminated; declined when the call carries explicit
type args on a NON-reified inline (`listOf<String>()`'s type arg IS
the empty list's element knowledge — the splice would drop it; caught
by parity empty_container_declared_elem).
(2) scalar-receiver no-lambda inline EXTENSIONS splice at explicit-
receiver sites (`value.countOneBits()`, 193k ladder dispatches) —
scoped to scalar heads with no member namesake; exposed a LOWERING
stack overflow: inferReceiverType recursed through self-referential
local inits (`val x = x.rotateLeft(1)` shadowing) — now depth-bounded.
(3) member_inline_lambda: member-inline callees WITH lambda params
(`drain { }`/`forEach { }` inside Operations' own methods) splice in
the owner hierarchy — vpd `<lambda>` count 803k -> 492k (-39% on the
op loop). ROLLED BACK TO OPT-IN (KLIO_MIS=1; 1e7ecf4d): the gate
caught two regressions — MovableContentTests.movableContent_nested
MovableContent_tree fails fast with `Vm::get_field currentGroup on
linkbuffer.SlotTable` (a spliced member-inline body's bare read of a
SIBLING member bound the wrong `this` in a nested-splice context) and
Map _clear degraded from 32.8s to the 90s wall cap. The tier needs
the nested this-binding root fixed before default-on; the -39% op-loop
win is banked behind the switch. FIRST PROBE: window_recv_declares now
requires window-bound provenance (sweep+corpus green, insufficient for
Movable — the failing read survives). The failing frame chain:
`ChangeList.execute` -> `slotTable.edit { executeAndFlushAllPending
Changes(applier, this, ...) }` (SlotTable.edit = member-inline with a
RECEIVER-FORMED SlotTableEditor lambda + try/finally + `with(
openEditor())`); the fatal `currentGroup` GetField lands on the
SlotTable. Note edit{} is an EXPLICIT-receiver member-inline — the MIS
tier is bare-only, so the actual MIS-spliced fn is further in
(executeAndFlushAllPendingOperations' bare member-inline callees under
linkbuffer's Operations). Traced further: every currentGroup emission
is the runtime-walking LoadFromThisOrGlobal; the fatal one executes in
the forEach-lambda inside `SlotTable.extractNestedStates`'s spliced
`edit { references.forEach { ... } }` — at runtime the walk's
candidate list is missing the EDITOR (the with(openEditor()) subject),
probing the SlotTable and then missing everywhere. The editor's
absence from the closure's runtime chain under MIS is the mechanism
still to pin (nested member-splice x with-subject x closure-snapshot).
DEPRIORITIZED: MIS stays opt-in with its -39% op-loop win banked; the
accessor family (649k OpIterator_operation frames) and
executeWithComposeStackTrace are simpler and larger levers for the
remaining two tests. Map _clear meanwhile IMPROVED to
31.8s with PIS+XIS alone (~3% from the no-lambda tiers). REMAINING census giants: the accessor family
(OpIterator_operation 649k getter frames, Stack_size 262k,
MutableList.size 330k gf), executeWithComposeStackTrace 324k (plain
member fn), and countOneBits INSIDE pack code (the scalar tier
declines because some stub class declares the name as a member —
class_member_names is owner-blind; refine with the shadow set).

ROUND 8i — THE FLIP LANDED (29e052f5): receiver-formed lambda
splicing is ON BY DEFAULT with COMPLETE acceptance — stdlib sweep
117/0, the full litmus battery (parity suites, examples, e2e, ktor,
concurrency, bundle) at ZERO failures, unit tests green, gate.sh
GREEN. The final root was a HOST-layer leak: a native's capability
sniff (`getProperty(iterable, "entries")` inside host `putAll`,
telling a user Map from an Iterable) was answered by an ENCLOSING
receiver's member through the chain fallbacks — with the spliced
`apply` subject (the destination map) on the runtime chain, every
Iterable looked like a Map and drained empty. The sniff now routes
through the MEMBER-STRICT probe (`getMemberField`). Ten distinct roots
total drove the flip green (rounds 8-8i); KLIO_RFS=0 remains the
bisect switch.

MEASURED (flip vs opt-in): compose gate 1388/2 unchanged, 423s
true-warm (415 pre-flip — variance-level); vpd census: `kotlin.with`
ELIMINATED from the hot list (612k -> absent) and total interpreted
calls in the same 45s window 7.52M -> 8.02M (~+7-12% op-path
throughput on the changelist apply loop); Map _clear 32.8s (32.4
pre-flip, its path never used the spliced shapes), oneRect 21.6s,
mapops 1516ms — all flat. The flip's value: kotlinc-equivalent inline
semantics for the with/apply family across the whole corpus (a
structural completeness milestone the earlier splice campaign
excluded), plus the vpd op-loop gain. The two remaining gate tests
still need the deeper call-throughput work; the with-splice alone was
never their whole gap.

ROUND 8h (baab8f95): the 22-sweep family root LANDED — subject-kind
chain entries (a spliced/framed `with` subject) no longer suppress a
REAL receiver param's own candidate run (the dispatch tower is what
lets the inner IteratorImpl's `remove` reach the OUTER list), while a
capture-received lambda `this` still dedups against its subject entry
(kotlinc REJECTS `describe()` inside `with(outer.Inner())` — the
subject exposes no enclosing-instance tower; the with_subject_outer_
member_call_rejected fixture pins both sides). Sweep default-on went
22 -> 2 with this + the walk-ordering fix; the seed file (CMT) is
6/6 under the flip. Plus: ext fns bind `this@<name>` at entry (the
labeled receiver resolves inside spliced regions), the labeled-this
static type derives from the declared receiver, the commit-point
parity guard defers only PLAIN top-level picks (extension picks
stand), and the walking arm declines member-claims when a chain-
compatible extension candidate needs argument adjudication. REMAINING
under default-on: the MapTest pair (createFrom/populateTo) — the
spliced `destination.apply { putAll(this@toMap) }` still ranks the
putAll overload family wrong through the fallthrough (labeled-this
type derivation not consulted by that site's shapes; #2423 vs #2422).
One overload-rank root from the flip.

Splicing went back to OPT-IN on top (all fixes kept). BISECTED
(minimal repro: ConcurrentModificationTest.kt + the 3 actuals +
testUtils, --filter=mutableList — fails SOLO, no batch needed): with
KLIO_RFS=1 the failure persists with LLP=0, MEMBER_EXT_SPLICE=0, the
tower reorder, receiver_is_owner widening, head derivation/inheritance,
window recvTy, the relaxed walking arm, and the parity-defer bail ALL
individually disabled — and DISAPPEARS exactly when the
spliceInlineLambdaOn `EnclosingPush` is disabled (the ext-splice push
alone is innocent). So the remaining root is the RUNTIME interaction:
a subject pushed for an always-on splice kind (reified/suspend
literals run even with LLP=0) lands on the chain that AstLambda
CLOSURES created in the region snapshot (`captureChainAlloc` keeps
kind=subject), and an op-literal (`{ removeAt(2) }`, receiver-formed
CollectionOperation ctor arg) later resolves its bare calls against
the stale snapshot instead of its invoke-time receiver-split. Next:
either exclude tower-pushed subjects from closure creation snapshots
when the literal declares its OWN receiver, or rank the snapshot
subject below the receiver-split at the closure's walk.

ROUND 8e (88bf1f7f, flip residue 4 -> 1 family): (a) the tower-region
pin declines outright (a lexical-owner pin dispatched Holder's member ON
the StringBuilder subject); (b) a BARE generic receiver-lambda
invocation inherits the enclosing splice window's head instead of
clobbering it with null (`scope.apply { result = ... }` kept Scope, so
the write arbitration knows the subject hides no `result`); (c) the
own-member GetField READ shortcut is guarded like the write side
(`spliceSubjectHidesOwnMember` — companion `tag` inside
`with(Other()) { tag }`); (d) EXT-splice receivers join the runtime
tower too (EnclosingPush around inline-ext bodies inside an active
region — `resumeWith` inside a spliced `Continuation.resume` inside a
spliced atomic `loop {}` dispatches on the continuation), with
`encl_tower_top` distinguishing tower subjects from pinned ext
receivers at emission sites; (e) REIFIED-inline candidates are never
claimed by dispatch-deferring arms (they can only run as splices).
REMAINING (1 family): nested receiver-lambda windows under RFS keep the
OUTER window's head in the kept pass (`polymorphic(Any::class) {
subclass(ints) }` sees SerializersModuleBuilder where
PolymorphicModuleBuilder is the subject) -> recv_mismatch declines the
reified subclass splice -> dynamic CMG -> unresolved `T`. Multi-pass
keep-selection is the mechanism to pin down next.

THE UOE FAMILY ROOT (12 -> 2): `implicitCandidatesAlloc` ranked the
frame's own receiver ABOVE in-flight chain pushes, so inside
`List.sorted`'s spliced `toTypedArray().apply { sort() }` the walk's
innermost candidate was the LIST (the extension's `this`), whose
MutableList.sort actual mutates an immutable list —
UnsupportedOperationException. In-flight pushes (the spliced subject)
are lexically INNER to the frame receiver; they now rank first
(in_flight = chain len - active_chain_base, the reversal's prefix).
One fix cleared 10 fixtures. REMAINING 2 (static_operator_resolution
line-9 inner-vs-outer ranking, fn_param_member_vs_string_extension
invoke_callable_with_this on String) fail ONLY inside the corpus itest
process — both pass standalone with the default-on binary — an
in-process interaction still to isolate.

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

## Three-front closure plan (the map/vpd class of failures, defined 2026-08-26)

The remaining gap on the concurrency stress tests decomposes into three
fronts. Each has a concrete mechanism, an owner-lever, and an exit test.

### Front A — ship precompiled natives for the heavy library functions

Current state, honestly assessed: the loop JIT (60-79x) and bytecode
tier only accelerate SCALAR code; the snapshot/collection functions are
object- and call-heavy, so today they run interpreted or hand-served.
The C transpiler already produces AOT native bodies bound to a pinned
image (`kl_<fid>` scalar-replay: fib 6.6x, corpus 293/293 byte-parity)
— but its replay set is scalar-pure only; the recorded leaf-miss tally
says the boundary is exactly "escape-op 57 = object work". So the
existing per-function host serves (snapshot_fast, persistent_map_mut)
are hand-written instances of what Front A generalizes.

Plan:
- A1. Object-shape sub-ABI for the transpiler: stable native access to
  Instance field slots (index-claimed like the GetField site memos),
  object-array elements, instance minting via the template mechanism
  persistent_map_mut proved, and native->native calls. Bail-to-interp
  on shape surprise exactly like the serves.
- A2. Bake-time AOT: at pack bake (ids are pinned within the artifact),
  transpile the hot library functions (snapshot walk family, CHAMP trie
  ops, TestScheduler drain loop) and ship the .so with the pack; the
  runtime registers them via the existing
  `klio_rt_register_native_leaf` path. No runtime JIT needed — bakes
  are already the natural AOT point.
- A3. Retire the hand serves one for one as the transpiled versions
  reach parity (each serve is the acceptance oracle for its function).
- Exit: the snapshot write cycle (currentSnapshot -> readable ->
  builder/put/build -> attemptUpdate) runs with zero interpreted frames
  on the happy path.

### Front B — interpreter floor (make the ritual cheap even interpreted)

- B1. Frame cost: activation open/close is the diffuse floor
  (runFrameExec 6.3%, memset/poison ~6.8% scales with allocation, arg
  marshaling). Levers: smaller Value (56->40 landed; 5b pinned),
  register-bank reuse pools, and the ReleaseFast-for-gate build-policy
  decision (measured -20%, awaiting user call).
- B2. Id-keyed dispatch: eqlBytes 4.2% + getIndex ~5% + hash family =
  string-keyed cache probes on member dispatch; replace name/sig string
  keys with interned symbol ids stamped at bake. (The earlier
  "id-keyed dispatch caches" successor item — now quantified.)
- B3. Allocation rate: boxing per put (builder+ownership+buffers) is
  ~GBs per stress test; A1's native bodies cut it structurally, and
  slab spare aging already removed the remap churn.
- Exit: the timed replica's per-rep wall (currently ~8s warm) reaches
  <=3s, which puts the 10-rep test inside its 30s runTest budget.

### Front C — inline parity with kotlinc (frames that should not exist)

kotlinc inlines EVERY inline-fun lambda at compile time — `mutate {}`,
`withCurrent {}`, `sync {}` contribute ZERO frames on the JVM. klio's
splicer covers top-level/extension inlines and many member shapes; the
recorded exclusion set (member-inline callees whose bodies need
this-threading through receiver-formed blocks, own-label returns,
crossinline capture) is exactly the five 1/insert lambda bodies the
KLIO_CALL_STATS_LAMBDA decomposition isolated (3.4M frames in one map
run).

- C1. Member-splice this-threading: bind `this` in a spliced member
  body to the CALL's dispatch receiver (the round-9b mechanism), which
  un-excludes mutate/withCurrent/update and their blocks.
- C2. Own-label returns + crossinline capture shapes, in that order
  (each currently forces framing).
- Frame-count target: after C, one interpreted map put should cost
  <=5 frames (the genuinely polymorphic boundaries); kotlinc's
  equivalent compiles to ~1 unit with everything else inlined, so
  frames-per-put is the tracked parity metric (was ~30 at session
  start, ~15 now, <=5 after C, ~0 after A).

## Running log

- 2026-08-27 THE REAL ROOT: A STOP-THE-WORLD RENDEZVOUS HOLE (not a
  missing GC root at all). The map UAF, the "premature free", and the
  0xAA-poisoned trie nodes were all one bug: the collector could begin
  MARKING while another mutator was still running, so it walked that
  thread's frame chain as the thread tore frames down and swept cells
  the running thread was still linking. Found with a new tripwire
  (`KLIO_GC_STW_AUDIT=1`: frame teardown inside the marking window,
  reporting tid/collector/park state) plus `gc.world_marking` — the
  audit showed ~90k violations per stress run. Four distinct holes in
  the handshake, all fixed:
  (a) `parkForStop` incremented `parked_count` even when NO stop was in
  progress (a thread that lost the `gc_lock` race a moment before the
  winner raised the flag), transiently satisfying the winner's wait;
  (b) the count was per-REASON, so one thread (nested blocking-safe, or
  blocking-safe plus exit) could satisfy the rendezvous alone — now
  per-THREAD (0<->1 edges only);
  (c) NON-mutator threads (the RSS watchdog, deadline timer, any helper
  sleeping in a blocking-safe bracket) were counted against a total
  derived from `mutators` — parking is now published by mutators only;
  (d) the fatal one: `exitMutator` published as parked and THEN
  decremented `mutators`, so a leaving thread was removed from the
  wait's target while still counted as parked, covering for a
  DIFFERENT running mutator. Membership changes now take a
  `mutator_lock` that the collector also holds while snapshotting
  `mutators` and raising the stop, and per-stop parking is tallied in a
  `stopped_count` reset as each stop is raised (so a publication left
  over from the previous stop cannot satisfy the next rendezvous).
  Result: stress-mode violations 90k -> ZERO, every crash repro passes,
  normal-mode wall unchanged (map replica 1.42s/rep). The worker
  perm-mint stopgap stays retired (`gcThreadEnter` drops `alloc_perm`
  once the program starts; `KLIO_WORKER_PERM=1` restores it for
  bisecting). NOTE: `KLIO_GC_STRESS` is now much slower — it forces a
  full major mark at every safe point AND the rendezvous now genuinely
  waits; that is honest cost, not a regression.

- 2026-08-26 THE GC ROOT NAMED AND FIXED; MAP CLASS 59/59 — FIRST FULL
  GREEN: worker threads minted PERMANENT (a June stopgap, "for now",
  from before the per-thread-root and pool-queue-root work; the
  threadlocal `alloc_perm` never flipped on workers and vmRun's
  comment claiming otherwise was wrong). Minors stop at permanent
  cells, and a HOST mint assembles its field list before ObjRef.init,
  so no borrowMut barrier ever remembers the perm->nursery BIRTH
  edges — a worker-minted trie node embedding main-minted subtrees
  was their only holder and the minor swept them (the interpreted
  flow survives only because its post-construction field writes
  barrier). FIRST FIX (a2269ee4) birth-remembered every program-phase
  permanent mint: correct but a remembered-set MELTDOWN — minors
  re-traced the whole worker allocation history and the litmus ran
  hours. REAL FIX: retire the stopgap — `gcThreadEnter` drops
  `alloc_perm` once `program_started`, so program-phase threads mint
  NURSERY like the main thread and ordinary marking covers them. Every sv-repro passes, put_replace passes,
  the whole-put serve is ON BY DEFAULT (KLIO_SSMPUT=0 bisects), and
  SnapshotStateMapTests is 59/59 solo with _clear at 14.4s vs its 30s
  budget. Task 1's remaining real failure: validatePotentialDeadlock
  alone (8.5x). TRAP class recorded: any HOST-SIDE mint that
  references non-permanent cells at construction, running on a worker
  thread, was invisible to minor GC — every host serve had this
  latent hazard.
- 2026-08-26 WHOLE-CYCLE SnapshotStateMap.put SERVE (LANDED OPT-IN,
  KLIO_SSMPUT=1; default OFF pending a GC root-cause): the steady-state
  write cycle host-side — record read under the map file's `sync`
  monitor (resolved from globals by mangled name `sync$f<N>` with the
  file-basename check, plain-name fallback for collision-free names),
  writableRecord's born-in-current-snapshot fast gate, the
  builder()/put/build sequence composed from the proven builder serves,
  then attemptUpdate's protected section replayed under the host
  monitor with a retry loop. notifyWrite proven no-op via the
  file-private `globalWriteObservers` list being empty (GlobalSnapshot's
  writeObserver is NEVER null — it is the ctor lambda draining that
  list; snapshot_fast.globalWriteGate deliberately does NOT check it).
  MEASURED ON: map replica 3.7 -> 1.26s/rep (2.9x), mapclear_full 10
  reps in 12.5s vs the 30s budget, census 1.29M -> 474k. BLOCKED BY a
  GC-profile memory-corruption interaction, diagnosed to a precise
  fingerprint but not to root: a committed map's trie node reads back
  0xAA-poisoned (fields ptr/len = 0xAAAA…) minutes of puts later.
  Repro (KLIO_SSMPUT=1, crashes in seconds; needs MAIN-thread seeding +
  replaces from a worker coroutine + commits):
  `repeat(300) { val map = mutableStateMapOf<Int,Int>();
  repeat(100){ map[it] = -1 };
  repeat(100){ coroutineScope { launch(Dispatchers.Default){ map[it] = it } } };
  repeat(100){ check(map[it] == it) } }`
  (sv8 all-main passes, sv6 all-worker
  passes, compute-only mode passes, full-monitor-lock mode still
  crashes, arena and debug-allocator profiles survive 150+ rounds, and
  gc_debug's never-free mode STILL crashes — so the dangling reference
  exists before any sweep; the commit's `record.map` define is the
  publishing edge, mode-7 bisect). Groundwork landed along the way:
  keepalive pins on every host mint (collect-at-alloc discipline for
  node/buffer/map/builder mints — the builder serves had unrooted
  mid-construction windows), entry marks on tryPut/tryBuild/tryBuilder,
  validator + phase-trace + victim-report modes (KLIO_SSMPUT=2/4/5/6/7,
  KLIO_SSMPUT_TRACE). NEXT SESSION: run with the GC arsenal
  (KLIO_GC_STRESS bisect, remembered-set traces, per-cell provenance)
  and root-cause the reachability/initialization hole; then flip the
  serve default and Map _clear closes (its budget math already passes
  with the serve on).
  SESSION-END FACTS (tooling landed): KLIO_GC_NOFREE=1 makes sv7 PASS
  — a PREMATURE FREE is proven (the earlier "predates any sweep"
  read was wrong; KLIO_GC_DEBUG only logs, never-free is
  KLIO_GC_NOFREE). A pre-sweep mark AUDIT is landed
  (gc.audit_hook + gc.cellSweepFate; KLIO_SSMPUT=8 registers committed
  records and re-walks their tries after marking): it reports WHITE
  (about-to-be-freed) depth-1 trie nodes with FRESH per-put ownedBy
  instances under a TENURED root inside a MARKED record whose `map`
  field reads TENURED (stale) — an age-inverted tenured-root ->
  nursery-children shape the minor's stop-at-tenured rule cannot
  reach. CHECK FIRST next session: (a) whether the record carries
  owner-qualified twin `map` fields (StateMapStateRecord\x1fmap) so
  getCached/define and the interpreted accessors use DIFFERENT slots
  (the audit read a tenured "map" seconds after a nursery commit);
  (b) the audit registry keeps records from finished rounds — filter
  to the live round before trusting WHITE reports; (c) who mutates a
  committed root in place across puts (each WHITE child carries a
  different ownership instance = one child per builder generation).
- 2026-08-26 EXT-LAMBDA TIER HEAD-EVIDENCE REGRESSION (caught by the
  sweep, fixed): SequenceTest spun forever — the tier derived the
  receiver head of `nats().withIndex()` through the general static
  deriver, which resolved the OVERLOADED `withIndex` return
  heuristically to `Iterable`, matched the EAGER inline
  `Iterable.filter`, and spliced it onto an infinite Sequence (the
  right target, Sequence.filter, is not inline so the tier never saw
  it). The tier now accepts DECLARED evidence only: an unsafe cast's
  target type, a declared local/param type, or the enclosing
  extension's declared receiver for bare `this`. `KLIO_XLE=0` /
  `KLIO_NRG=0` landed as bisect switches for the tier and the
  recursion-guard visibility base. TRAP for perf tiers: a head from
  overload-heuristic derivation is not resolution evidence — an
  inline-only candidate index can pick an inapplicable eager overload
  when the true target is not inline.
- 2026-08-26 FRONT C ROUND 2 — ALL per-insert closure frames eliminated
  (map replica census 3.62M -> 1.59M total frames, -56%; wall/rep 4.9 ->
  3.7s, -25%; frames/insert ~5.3 = the Front C target). Four roots on
  top of the qualified-inline splice:
  (a) Explicit-receiver ext-inline-lambda tier (`record.withCurrent(
  block)`, `(firstStateRecord as T).writable(this, block)`): a
  top-level inline EXTENSION with a fn-typed last param fed a literal
  or forwarded inline-lambda param now splices when the whole prefix
  head derives (gateReceiverHead gained an `.As` arm — an unsafe cast
  fixes the static type) and the declared receiver is a concrete head
  or a BOUNDED type param the head extends; hierarchy-scoped member
  shadow declines; ambiguity declines.
  (b) SEATED subjects get the full window: a receiver-formed literal
  invoked value-arity+1 (`block(current(this))`) now sets the splice
  window head (from the span-keyed recorded receiver) and joins the
  runtime tower, exactly like a supplied receiver — bare member reads
  inside the seated body resolve against the record, not the enclosing
  class (the `unresolved global map` failure).
  (c) Subject-bind stack (`FuncBuilder.subject_binds` — with/apply/ext/
  seat subjects with derived heads + the `this` beneath the run): a
  bare MEMBER-inline splice and the own-private-member direct path
  (`lowerImplicitThisCall`) now dispatch on the innermost receiver
  whose class reaches the owner instead of the ambient (subject)
  `this` — `with(rec) { writable { … } }` dispatched SnapshotStateMap's
  writable ON THE RECORD before (pre-existing bug, exposed by the new
  splices; xler2/xler3 repros pin it).
  (d) The splice self-recursion guard (`inlineDeclInProgress`) no
  longer blocks a same-fn call inside a spliced ARGUMENT literal
  (caller code): `repeat { forEach { repeat { } } }` now splices all
  the way (visibility base lifted around literal-content lowering;
  the expand-depth cap bounds pathology). Plus: `contract { }` literals
  are dead code to the consumption scan (repeat's action no longer
  materializes).
- 2026-08-26 READABLE RESIDUE CLOSED + QUALIFIED-INLINE SPLICE: two roots.
  (a) Caller-attributed census (KLIO_CALL_STATS_CALLER=<substr> bumps
  `<fqn>@<caller>[file:line]`; lambda keys carry the caller's cur_span =
  the exact call site) named the 1.1/insert `readable` route in ONE run:
  writableRecord's direct 3-arg call rides the CMG OVERLOAD leg
  (callNamedOverload dispatches natively — no static-arm, no replay, no
  serve). Fix: `hostRouteServe` now also runs at the recursive seam in
  evalWithCapturesChained (owning/closure/chain/captures all empty), so a
  routed target serves from EVERY dispatch path. Census 3.62M -> 3.30M
  frames on the map replica; readable rows gone.
  (b) Front C root: package-QUALIFIED calls to inline fns never spliced
  (`tryBareInlineExpansion` required a single-segment bare Path; dotted
  callees parse as Member chains). The compose sync chain (platform
  synchronized -> kotlinx.atomicfu.locks.synchronized ->
  kotlin.synchronized, each a qualified forward) therefore materialized a
  closure + framed the block per sync region — 4 of the 6 residual
  1/insert lambda bodies. `tryQualifiedInlineExpansion` flattens a
  Path/Member dotted callee, requires the WHOLE prefix to equal the
  candidate's declaring package (value/class/companion prefixes can never
  match), requires a unique arity-fitting top-level non-receiver inline
  candidate, then runs the normal splice. attemptUpdate now lowers to
  __klioMonitorEnter + inline body + exit — zero closures. Map replica
  census 3.30M -> 2.22M (-33%); lambda mass 6.7 -> ~3.0/insert.
  Remaining 1/insert bodies, caller-named: withCurrent block (framed
  top-level T.withCurrent @ Snapshot.kt:2529), writable block (framed
  T.writable @ 2418), user repeat action (framed kotlin.repeat @
  Standard.kt:163 — its contract literal mentions `action`, so the
  consumption scan keeps the closure). Next: why the explicit-receiver
  member-forwarded T.withCurrent/T.writable calls stay framed, and the
  nested-literal clause in pocUses (blanket `.Lambda => true` — descend
  and check the name instead).
- 2026-08-26 READABLE-RESIDUE ROUTE HUNT (finding recorded, route not
  yet found): the 1.1/insert interpreted `readable` frame residue is
  NOT serve bails — KLIO_SNAPFAST_TRACE per-reason counters printed
  nothing at an 8192 threshold over a full run (<8k bails/reason
  total), and the exec-route trace shows the sync-retry lambdas' 3-arg
  calls (53k, exact=false) ARE reaching hostStaticServe and being
  served. The CMG `site_global_replay` arm now consults the shared
  `hostRouteServe` helper (extracted from hostStaticServe) — measured
  no census movement, so the residue rides neither the static-call arm,
  the getter route, nor the CMG global replay. NEXT: attribute the
  frames by CALLER (a census key like `readable@<caller>` under the
  lambda-stats flag), then hook whichever dispatch path that names
  (candidates: the member-walk invoking the accessor/wrapper via
  invokeMethodFuncId-adjacent paths, extensionFnFallback, or a flat
  prepare that bypasses serves).
- 2026-08-26 GETTER-ROUTE SERVES + BUILDER MINT: census throughput
  200k -> 700k inserts inside the watchdog window (3.5x the session
  baseline). (a) snapshot_fast routes 8/9 classify the ACCESSOR fqns
  (`__get_SnapshotStateMap_readable` + List/Set twins,
  `__get_Snapshot$Companion$Companion_current`) and evalGetterTagged
  serves them through the same wrapper-walk/GlobalSnapshot gates — the
  840k+480k getter-frame families vanished. (b) `map.builder()` is
  host-minted from a template captured off a live builder in tryPut;
  TRAPS burned: the live builder carries TEN fields — the six declared
  ones plus AbstractMap's `_keys`/`_values` AND their owner-qualified
  `AbstractMutableMap\x1f_keys` twins (owner-scoped storage names use
  the 0x1f separator, which PRINTS as an underscore — eql against the
  printed spelling silently fails; match by last-0x1f-segment); and a
  capture latch that stamped the generation before validation turned
  the first failure permanent. (c) KLIO_CALL_STATS_LAMBDA decomposes
  the literal-"<lambda>"-fqn census mass into per-body `<lambda>#<id>`
  counters: the map test's 5.7/insert lambda mass = five bodies at
  exactly 1/insert — the mutate/withCurrent/sync member-inline blocks,
  i.e. the recorded member-splice-widening exclusion set (the next
  structural lever). (d) The compose itest child RSS cap rose 6.5 ->
  10GB: per-test arena churn scales with interpreter THROUGHPUT inside
  a fixed runTest window, so every serve round raises it — the 1-DNC
  gate signature (test vanishes from failing, did-not-complete = 1) is
  the cap tripping, not a hang. Remaining per-insert: <lambda> 5.7,
  readable wrapper residue 1.1 (serve bails ~1/insert — root-cause
  next), attemptUpdate 1.0 (sync-gated). Gate 1388/2/0 restored at the
  raised cap; class 58/59; sweep/litmus/units green.
- 2026-08-26 MAP-BUILDER CHAMP SERVE + SLAB SPARE AGING: the vendored
  `PersistentHashMapBuilder.put`/`build` are host-served
  (persistent_map_mut.zig — the exact TrieNode `mutablePut` over the
  interpreted objects: ownership-gated in-place mutation vs fresh node
  minting from a captured class/field template, `makeNode` chains,
  collision nodes; keys restricted to scalars/strings whose
  hashCode+equals the host owns via the NEW shared
  `Value.kotlinScalarHash` — Float/Double bail on `equals`-NaN
  divergence; every bail provably precedes the first mutation). All
  five list-serve intercept points mirrored (ladder head + two
  flat-preparer declines + virtual-slot + funcid replay). The scalar
  hash moved from stdlib collections into `Value.kotlinScalarHash` so
  served and interpreted bucket placement can never diverge. TRAP
  burned: i32 bitmap math (`mask - 1` at bit 31) PANICS in safe builds
  — all CHAMP mask arithmetic must run in u32 (the first class run
  crash). Slab allocator: fully-free slabs now park UNBOUNDED on the
  per-class spare stack (a GC sweep frees whole bursts; any free-time
  cap made the next burst remap+rethread) and the reclaim pass ages
  them out after RECLAIM_IDLE_PASSES instead of dropping all spares
  each cycle; measured NEUTRAL on the map test (its newSlab 2.3% is
  raw heap growth, not churn) but principled + unit-tested. MEASURED:
  solo wall-to-fail 38.8 -> 31.9s; size-setter frames gone (400k);
  map class 58/59; compose gate 1388/2/0 held; sweep/litmus/units +
  gate.sh GREEN. GROUND TRUTH (timed replica, warm): ~8s per rep ->
  full 10-rep workload ~82s vs the 30s budget — the test needs ~2.7x
  more end-to-end. Remaining per-insert census: <lambda> 5.7 (fqn is
  literally "<lambda>" — needs an id-keyed census discriminator),
  map.readable getter 2.1, Snapshot.current getter 1.2, readable
  wrapper residue 1.1, builder ctor 1.0, attemptUpdate 1.0. NEXT:
  getter-route serves for Snapshot.current + SnapshotState*.readable,
  builder() host mint, lambda census decomposition.
- 2026-08-26 SNAPSHOT-READ WRAPPER SERVES: THROUGHPUT 2x + THE
  WALL-TO-FAIL DECOY: the KLIO_PROF+KLIO_PROF_CALLERS/KLIO_CALL_STATS
  round on the contended map test found the per-insert cost was the
  snapshot READ machinery, not the trie put: per insert ~4.3
  `Snapshot.current` companion-getter frames (860k), ~3.2 top-level
  `readable` wrapper frames (640k — only the 3-arg private walk was
  served), ~2.1 `SnapshotStateMap.readable` getter frames, plus 220k
  slow-ladder `List.indices` reads. snapshot_fast now also serves the
  2-arg `T.readable(state)` wrapper (GlobalSnapshot-exact class gate —
  subclasses override `snapshotId`/`invalid`/`readObserver` as computed
  accessors, so stored-field reads are only sound on that final class;
  observer-null gate; walk-null bails to the interpreted sync retry),
  `current(r)` and `current(r, snapshot)` (same walk, no observer
  semantics), sharing one `readableWalk` core. builtinFieldFast serves
  `indices`/`lastIndex` for backing-free containers, GATED on a
  program-wide "no non-stdlib extension property of either name exists"
  verdict (`builtinIndexPropsServable`, gen-stamped) — the ungated form
  hijacked user extension shadows (A/B-proven against kotlinc
  semantics: a user `List.lastIndex` must print its own answer).
  Bonus root fix from the same audit: `setOf(...).indices` was a
  runtime dispatch error (`collectionLen` had no Set arm) — fixed, with
  `examples/indices_shadowing.kt` + `examples/collection_indices.kt`
  pinning both behaviors. MEASURED: identical-census throughput
  DOUBLED (400k vs 200k inserts inside the watchdog window); compose
  gate held 1388/2/0; class run 58/59 (only `_clear`); sweep 117/0,
  litmus 48/48, units green. THE DECOY: solo wall-to-fail ROSE 30.8 ->
  38.8s and looked like a regression — it is watchdog(30s) + teardown
  over a ~2x fatter churned heap, not slowness; judge this test by
  work-inside-the-window, never by wall-to-fail. Standalone full-scale
  replica (mapclear_full.kt, run-mode arena) hit the 6GB RSS cap at
  rep 7 of 10: the workload is ALLOCATION-BOUND (~900MB garbage per
  rep: a builder + ownership instance per put, trie buffer copies,
  records). Post-serve profile: slab family ~8.5% (newSlab 2.4% — GC
  unmap/remap churn against the single parked spare), memset 6.8%
  (alloc/free poison scales with allocation count), materializeInstance
  1.2%. NEXT LEVERS: slab spare-depth/hysteresis for GC-churn
  workloads, then the persistent-map builder serve family
  (`builder()`/`put`/`build` host-side; CHAMP node shape already mapped
  in persistent_map_eq.zig) which cuts compute AND garbage per put.
- 2026-08-26 CURRENTSNAPSHOT NATIVE SERVE + THE ROUTE-CONTENTION TRAP:
  snapshot_fast serves `currentSnapshot()` natively (the ThreadMap
  binary search over the interpreted objects, same thread-id source as
  the intrinsic, globals memoized behind the dispatch-cache
  generation). Route-dependent outcome measured on the concurrent map
  test: the execArmCall serve is −0.7s (kept; median ~30.7s vs the 30s
  budget); the SAME serve on the leaf-serve entries was +10s under
  8-thread contention while −30% single-threaded, and a getter-route
  serve was neutral — both removed. Working theory for the divergence:
  the shared GlobalSnapshot's refcount line is RMW-contended and the
  leaf propagation pays extra retain/release pairs per read. PINNED:
  refcount elision / borrow-free reads for program-lifetime singletons
  (fetchAdd+fetchSub+borrow ≈ 5-7% of the map profile) — the likely
  unlock for both remaining tests. Never adopt a host serve from a
  solo micro; measure the contended test per route.
- 2026-08-25 DEAD FORWARDED-LITERAL ELISION + WALL RECORD 394s: the
  pinned pass landed same-day — `finish()` nops a materialized
  forwarded-literal AstLambda when no instruction or terminator reads
  its register, using the comptime-generated `visitInstRegs` /
  `visitTerminatorRegs` walkers (which made the "complete operand
  model" risk vanish; the visitor also gained the missing
  `CtxScope.ctx_args`+`n_ctx` run expansion — a latent hole under
  every register analysis including Move fusion). The sync-chain
  closures (compose -> atomicfu -> kotlin.synchronized) elide in
  `SnapshotStateMap.put`; deadlock-test throughput rose ~7% by
  capped-window census; TRUE-WARM WALL 402 -> 394s (halving target
  364). Map `_clear` flat at ~31.4s — its remaining gap is not the
  closure churn.
- 2026-08-25 GETFIELD FAST SERVES + WALL RECORD 402s: builtinFieldFast
  now answers plain-container `.size`, Range `first`/`last`/`step`
  (host-arm-exact, view-backed containers decline), the
  companion-or-self sentinel serves in the exec arm (memo for Class
  receivers, identity otherwise), and the leaf member arm serves
  backing-free `isEmpty` (member only). Census heads eliminated:
  `MutableList.size` 678k, `Stack_size` 538k, sentinel 718k, range
  bounds 440k. True-warm compose-gate wall 402s (record, was 406).
  Measured-negative: host-binding `SnapshotThreadLocal.get/set` via
  member-form bindings made the map test 40% SLOWER (dynamic member
  dispatch to a native form takes the slow tail per call) — reverted.
  PINNED NEXT LEVER for Map `_clear` (31.5s vs 30) and the recompose
  lambda head: lazy materialization of forwarded inline-lambda
  literals. The compose->atomicfu->kotlin.synchronized chain
  materializes and registers a closure per call purely to feed forwards
  whose terminal only CALLS the block; a lazy bind (emit the AstLambda
  only on a value-position resolve; call positions ride the existing
  lambda_map chase) removes the per-op allocation. A fiat skip is
  UNSOUND (50/59 map tests red) — the lazy form is required because it
  alone proves the value is never needed. Implementation shape settled:
  emit the materialization as today, then a post-splice dead-reg pass
  nops the AstLambda when NO instruction reads its dst register. The
  pass needs a COMPLETE per-variant register-operand model of Inst
  (call arg runs are base+count ranges, so byte-scanning is unsound;
  any unmodeled variant must conservatively count as a read, which
  neuters the pass unless the model covers essentially every variant).
  A fresh-session task: write `instReadsReg(inst, r) bool` beside the
  Inst union with a unit test that constructs one of EVERY variant, so
  a new variant fails the test until modeled.
- 2026-08-25 CONCRETE PARAM HEADS + WIDTH-MATCHED SCALAR SPLICES: spliced
  inline parameters with concrete declared types now record their heads
  in the local-decl channel (previously only type-param-declared ones
  did), so explicit-receiver derivations work inside spliced bodies —
  the pack-side `countOneBits` wrapper's inner call now splices (403k
  ladder dispatches gone from the deadlock census). The new heads
  activated a dormant hazard: the scalar-extension arm picked the first
  receiver+arity candidate without checking argument widths, so
  `Long.mod` inside `Instant.fromEpochMilliseconds` spliced as a
  narrower overload and truncated milliseconds (two v7-UUID sweep
  reds). Arguments' derived heads must now equal the declared param
  heads. The owner-blind member-namesake decline is hierarchy-scoped
  for scalar heads. Gate re-held 1388/2/0; sweep 117/0; litmus 48/48.
- 2026-08-25 OUTER-HOP FIELD ROUTES: inner-class reads of an enclosing
  instance's stored field ran the slow field ladder every time
  (`OpIterator.operation` reading `opCodes`: 1.5M ladder runs inside
  validatePotentialDeadlock's window). The outer-chain fallback now
  propagates a hop-counted slot route onto the inner class's field-read
  memo (outer runtime-class identity verified at serve); the GetField
  site fast path, its polymorphic sibling, and the frameless leaf
  evaluator all serve the new route, and the leaf member arm serves
  container `get` indexing (accessor bodies lower `data[idx]` as a
  member call). Inner-accessor microbench 7.26s -> 1.43s; the
  OpIterator pair left the recompose census top; compose gate re-held
  1388/2/0-DNC; sweep 117/0, litmus 48/48, units green. Remaining
  census heads (`MutableList.size`, companion-or-self reads,
  `executeWithComposeStackTrace`'s frame + virtual execute) are
  call-throughput-campaign shapes, not memo gaps.
- 2026-08-25 SNAPSHOT-MAP LIVELOCK ROOT (07939c91): the Map `_clear`
  90s-wall + 16.7GB-RSS regression was a RECEIVER-SEATING bug exposed by
  the member-inline-lambda tier going always-on. `SnapshotStateMap`'s
  member `withCurrent` forwards its `StateMapStateRecord.() -> R` block
  into the global `T.withCurrent(block) = block(current(this))`; the
  call-position splice of the literal bound `current(this)` to the
  parser's speculative implicit `it` and derived `this` from the
  ENCLOSING splice subject (`firstStateRecord`). Reads therefore pinned
  to the first record; correct while it IS the current record (reps
  0-1), livelocked the moment record reuse split them (rep 2): the CAS
  compared a stale modification forever, and every retry re-registered
  the sync-block closure (SharedClosures grows per AstLambda exec) —
  the RSS explosion. Fix: a receiver-formed literal invoked with
  declared-value-arity+1 positional args seats arg0 as `this` (declared
  arity recorded span-keyed at materialization; `String.(Int)` literals
  keep `it`). Also landed: materialized splice literals lower under the
  param's declared fn type (receiver-formedness survives forwarding),
  and break/continue unwind the subject tower to loop-entry depth.
  Diagnosis traps burned: stale bake caches serve OLD lowering across
  env changes (A/B needs a fresh data home per config), the first run
  after an install pays a ~50s bake (never time it), and pack lowering
  happens in the first-run bake, not `pack build` (traces go there).
  Verified: cliff micro linear (17.6s N=12 warm), sweep 117/0, litmus
  48/48, units green, SnapshotStateMapTests 58/59 (the `_clear` budget
  test now runs 31.8s vs its 30s runTest cap — the standing perf item,
  no longer a hang).
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
