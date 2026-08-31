# Interpreter shared-op campaign: the routines every tier funnels through

STATUS 2026-08-31: NOT STARTED. Successor to
`plans/interpreter-next-campaign.md` (COMPLETE; its exit state carries the
standing numbers). Standing baseline: compose gate 1390/0/0, vpd child
564-577s (budget ratchet 650s, shrink-only), replica ~147-150us with the
function tier at cost parity, mono virtual loop 1 ns/iter, Value 24B.

THE LAW this campaign is built on (measured four times, never relitigate):
every execution tier — per-op C transpiler, bytecode tier, fused walker,
per-body function JIT — is neutral on dispatch-heavy code because the
heavy ops (field lookup, member dispatch, allocation) run through the
same host routines in every tier. Adding tiers is done. This campaign
attacks the SHARED ROUTINES those tiers funnel through, so every tier
(including the plain interpreter) gets faster at once, plus the one
architecture no per-body tier reaches: native regions that span call
boundaries.

Replica profile buckets (recompF, fast harness, 2026-08-30 — Task 1
re-attributes under gate parity before anything is built):
- drivers (runFrameExec / execInst / runFlatLoop / leaf walkers) ~15%
- string-keyed lookup machinery (eqlBytes / mix / getIndex / get / has /
  hash — the dispatch and field memo maps) ~11%
- refcount atomics (fetchAdd / fetchSub / borrow) ~7% — RUN-MODE ONLY;
  the gate runs reclaim-off, so this bucket banks nothing (the Task 3
  closure of the last campaign stands)
- allocation (allocSmall / allocLockedOne / newSlab / freeSmall /
  append / copyFixedLength) ~6%
- field machinery (getFieldInner / execArmGetField / leafStoredField /
  fieldWriteCacheGet) ~4%

## Task 1 — gate-parity profile attribution — DONE 2026-08-31

CORRECTION to this plan's own premise, established first: `klio test`
does NOT run arena/reclaim-off memory — BOTH the fast and safe profiles
run `reclaim = .gc` (tracing GC, refcount neutralized; `perf.zig
forProfile`). The gate's memory regime is the tracing GC.

vpd solo profile (KLIO_PROF, gate env, fast harness; thread-aggregated
samples): drivers ~10% (runFrameExec 4.9, execInst 1.7, runFlatLoop 1.2,
fusedInst 1.1, leaf walkers ~1), GC ~12% (shade 5.8, gc-counter
fetchAdd/fetchSub ~3.6, writeBarrier 0.8, sweepMinor 0.6, isUsed 0.9,
memset ~1), string-keyed lookups ~8% (eqlBytes 3.7, mix 1.15, get 1.3,
getIndex 1.0, getOrPut 0.65), alloc ~6% (allocLockedOne 2.1, allocSmall
1.0, freeSmall 0.8, append 1.2, copyFixedLength 0.95), libc-unattributed
8.5%, borrow (ObjRef guards, closed <=1% envelope) 1.3. Baseline vpd
solo wall under gate env: 544-546s across 5 runs (tight).

GC VEIN CLOSED BY MEASUREMENT (the ~12% bucket does not convert to
wall — vpd's critical path is not the memory subsystem):
- Appel growth factor 2 -> 8: 546 vs 544-545s (ZERO; with vpd's small
  live set the trigger is FLOOR-driven, growth never engages).
- Threshold floor 8MB -> 64MB (8x fewer collections): 564-566s, ~4%
  SLOWER — the default floor is already right.
- Batched per-thread nursery registration (register() had a global
  spinlock + shared counter RMW per allocation): 544-545s, wall-NEUTRAL
  despite ~5% of profile samples — committed for the record and
  REVERTED (5f881573 / 32708759). SAFETY FACT banked in that commit for
  any future revival: a cell left in a threadlocal segment across a
  collection is a reachability hole (parent promotes, minor stops at
  the unmutated tenured parent, next sweep frees the live child —
  surfaced as `lazySet` on a recycled cell); segments must flush at the
  STW rendezvous and at blocking-safe entry.

METHOD NOTE (discovered work, applies to every later vein): the profile
is thread-AGGREGATED while the wall follows the slowest chain, so a
profile share is only a ceiling — each vein needs its own cheap A/B on
the vpd solo before implementation effort, exactly as run here. If the
Task 2/3 A/Bs also come back flat, build per-thread (critical-path)
attribution before spending further.

## Task 2 — string-keyed lookups out of the hot ladders — CLOSED 2026-08-31

Closed by measurement: the member-dispatch site machinery this task
proposed ALREADY EXISTS and has converged — `CallMember.site_cls/site_
sig/site_route` single-fill memos, a per-site PIC (`callPicGet`), flat
prepare caches, and `stampVirtSite` for host receivers, all landed in
prior campaigns. The KLIO_DISPATCH_STATS census on the replica shows the
full string ladder (`member_ladder`) at 0.37% of dispatch events; the
dominant events are frame pushes (35%) and flat prepares. The residual
eqlBytes cost attributes (KLIO_PROF_CALLERS) not to member NAME
resolution but to the FIELD ladders (execArmGetField / setFieldInner /
getFieldInner / getMemberField and their (class,name) memo probes plus
the per-replay name re-verify) — which is Task 3's territory — and to
sub-threshold dust (instanceOf, applicability, virtual flat prep).
METHOD KEEPER: the single-threaded replica is the composer-thread
critical-path proxy (profile share = wall share there); vpd solo is the
banking measurement only.

## Task 3 — class-shape fixed field offsets (the object model itself)

PROGRESS 2026-08-31 (first two rounds landed, battery pending):
- Substrate (5279a790): interned instance-LAYOUT shapes — same
  canonicalized name POINTERS in the same order => same id, so a match
  proves (name at index) with one integer compare. Lazy per-instance
  memo reset on append/remove (all 9 host-side mutation sites patched),
  bounded intern table (overflow => UNSHAPED sentinel), unit-tested.
- Conversions (92763900): the framed GetField site arm and the leaf
  serve claim SHAPES and drop the per-hit name re-verify (the claim
  binds shape/index/name under ONE borrow; the leaf re-checks the memo
  word under its read borrow so a define between borrows declines);
  the polymorphic class-memo fallback keeps its verify (unchecked
  index). storePlainField fused its probe-then-define double scan into
  one borrow + one scan.
- Measured: replica 143-146us (median 144) vs the 146-152 pre-shape
  band (~2-3%); vpd solo 539-540s vs 544-546 baseline (~1%) — BANKED:
  ratchet 650 -> 645 (c415fc92). GC-stress smoke clean.
- Residue attribution (KLIO_PROF_RAW + addr2line): the remaining eql
  cost is smeared over a dozen string-keyed maps (overload scoreArg,
  barrierSpec name probes, arm-inlined flat caches), each sub-1% — no
  further single >=2% conversion exists in the field family. Remaining
  ladder conversions (getFieldInner/getMemberField internals) are
  ~0.3-0.5% each; do them only if a later profile promotes them.
- SOUNDNESS TRAP, found by the gate (26 fails: GroupSize/SlotTable
  source-info families, class-run-only) and fixed in 4075cf2d:
  **shape is LAYOUT identity, not class identity** — two classes can
  share a layout while routing the same name differently (a custom
  getter on one, a plain slot on the other; the GroupSize mock View
  subclasses are exactly this), so a shape-KEYED claim served one
  class's getter route to another class. Site claims must stay
  CLASS-keyed; the shape (`GetField.site_shape`, bound to the verified
  index under one borrow at fill) only licenses skipping the per-hit
  name verify when class AND shape both match. Sound-build numbers:
  replica 146-148 (median 146, ~1%), vpd solo 540-541s vs 544-546 —
  the 645 ratchet stands.

Instance fields today are an append-ordered array, name-verified per
access (field order is NOT class-static — dynamic defines append; the
method tier re-verifies BY NAME per entry because of exactly this).
Give instances a SHAPE: a per-layout id (class + define history) with a
name->index table computed once, so:
- interpreted stored reads/writes become shape-check + O(1) index (kills
  the name scans and their eqlBytes),
- the JIT's method_fields per-entry name re-verify becomes one shape id
  compare (today's guard_class + per-field memcmp),
- `plainStoredFieldIndex` becomes a shape-table lookup.
This is a core-path layout change: land it big, drive it green (the
operating rule), with the delegate/getter rejection semantics carried
over exactly. Budget comes from Task 1's field + lookup buckets.

## Task 4 — native regions across call boundaries — CLOSED 2026-08-31

Closed by census before building: the splice needs compiled-caller ->
compiled-callee pairs with real call volume, and the replica's compiled
set (17 bodies, KLIO_JIT_DEBUG census) contains essentially ONE such
pair (`Changes.isNotEmpty -> ChangeList.isEmpty`), invoked at
frame-batch frequency — dust. Compose's flat profile offers no pair
above the >=2% threshold; the loop tier's inline machinery already
serves the scalar workloads where pairs are hot (native recursion,
member inlining, 349 -> 1 ns/iter precedent). Revisit only if a future
census names a hot pair.

## Task 5 — allocation fast path — CLOSED 2026-08-31

Closed by measurement on both fronts: (a) the proposed mechanism ALREADY
EXISTS — `slab.zig` keeps threadlocal per-size-class magazines (~4KB
each) refilled half-a-magazine per lock acquisition, so the profile's
`allocLockedOne` 2.1% IS the ~32:1-amortized refill path, with
`flushMagazines` at worker exit; and (b) the Task 1 A/B trilogy showed
the memory subsystem is off vpd's critical path entirely (registry
batching wall-neutral, cadence zero-or-negative). No lever above
threshold remains in the bucket.

## Standing policy

- Bank every throughput win into the vpd budget ratchet (650s,
  `src/itests/compose_plugin_commontest.zig`); it never grows.
- Measure NET effects with A/B on the replica (tier-on vs tier-off, fix
  on vs off) — the probe-tax regression was invisible in the compiled
  bodies' own numbers.
- Gate-parity conditions for every ratchet-facing measurement: fast
  harness, test mode (arena, reclaim-off), the gate's JIT policy.
- Verification: harness + commontest-sweep for iteration, full battery
  (compose gate + threaded-litmus parity + examples + stdlib sweep +
  unit tests) once per round; `zig build itest-*` is the gate only.
- Traps in force: cold stdlib-image bakes shift which bodies compile
  (rm the newest ~/.klio/cache image = deterministic repro lever);
  zig's "failed command:" prints for any step with stderr — the exit
  code is the only verdict; SnapshotStateMapTests.
  concurrentMixingWriteApply_set fails only under 8-way gate load (90s
  wall cap) — rerun before blaming a change; installed packs shadow
  sources — rebuild after lowering/registry changes.

Exit: every task landed green (full battery + compose gate) or closed by
measurement recorded here; wins banked into the ratchet.
