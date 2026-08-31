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

## Task 1 — gate-parity profile attribution (measure FIRST)

Re-profile under the exact conditions the ratchet pays for: the fast
harness in `klio test` mode (arena, reclaim-off, the gate's JIT policy),
on the replica AND on a `validatePotentialDeadlock` solo run. Produce a
bucket table with percentages and a per-task budget line each following
task must beat (the >=2% implement threshold from the closed campaigns
applies). KLIO_PROF is the profiler; KLIO_PROF_RAW + addr2line pins
anonymous maps. Any bucket that shrinks below its threshold under gate
parity closes its task by measurement on the spot.

## Task 2 — string-keyed lookups out of the hot ladders (~11% bucket)

The dispatch and field ladders resolve through hash maps keyed by name
strings (eqlBytes) and class-name pairs. The wins land as either:
- per-SITE monomorphic inline caches on the interpreted CallMember /
  CallVirtual / GetField arms: class identity -> resolved target stamped
  on the site (the `stampVirtSite` low-bits verdict encoding is the
  landed precedent; `ClassDef.resolve_mod/resolve_cid` is the memo
  precedent), one identity compare per hit; or
- widening KLIO_CANON ptr-keying (97% ptr-hits already) into the maps
  the profile names — getIndex/mix time is map-walk cost even when the
  final compare is a pointer hit.
Traps: the field-write memo BORROWED-slice bug (klio-field-write-memo
memory) is the canonical stamped-cache hazard — own every stamped key;
host-binding shadowing must stay ahead of any stamped target (the
convertDurationUnit trap); a stamp that skips the extension/visibility
walk must only serve receivers proven to take the walked route.

## Task 3 — class-shape fixed field offsets (the object model itself)

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

## Task 4 — native regions across call boundaries (the successor opening)

The one architecture no per-body tier reaches: a compiled body whose
monomorphic member/virtual callee is itself compiled should SPLICE the
callee inline (class-guarded, deopt to the call site), removing the
host round-trip entirely for the pair — the loop tier's inline-site
machinery (`inlineSiteAt` / `emitInlinedCall`, the member-inline entry
guard + field-NN deopt rules) is the substrate, extended to the
function tier. Start from the replica's hottest compiled-body call
pairs (KLIO_JIT_DEBUG census names them). The probe-tax lesson applies
in full: measure the NET effect (tier-on vs tier-off), not the spliced
bodies; splice depth and code-size caps before breadth.

## Task 5 — allocation fast path (~6% bucket, measure-first)

allocSmall/allocLockedOne/newSlab under gate parity: if the arena
profile already absorbs the bucket (the ReleaseSafe-memset trap says
part of it is safe-mode fill, not alloc cost), close by measurement.
Otherwise: a thread-local slab head for the dominant size class, no
locks on the hit path.

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
