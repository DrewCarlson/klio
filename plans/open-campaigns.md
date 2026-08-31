# Open campaigns

The live plan register: every open workstream at one line of truth,
pointing at its owning doc. This file is the index, not the log —
update the state lines as work lands. Closed campaign records live in
`PLAN-archive.md` (which also indexes every finished campaign doc);
the finished docs themselves stay in place as logs. Reference docs
(architecture, design, practice) are listed in the doc register at the
bottom and are not campaigns.

## The active plan

`plans/census-gates-and-red-mass.md` — bound every census in both
directions (the predecessor's C3 covered only the six suites that run
through `commontest_support.zig`; `stdlib`, `compose_plugin`, and
`androidx_collection` counted passes only, and androidx's ratchet had
never run at all because its sparse checkout omitted `commonTest`), then
drive the tolerated failure mass down starting with serialization.

THE PERF ERA IS CLOSED (2026-08-29 .. 2026-08-31, five campaigns, each
doc terminal — do not reopen a per-op interpreter-perf campaign without
NEW profile evidence): `concurrency-perf-campaigns.md`,
`interpreter-next-campaign.md` (function-tier coverage + probe tax;
cost parity), `interpreter-shared-op-campaign.md` (instance shapes;
ratchet 650 -> 645), `interpreter-native-floor-campaign.md` (kl_
sub-ABI measured 34x; suite wall proven vpd-bound; Value 16B,
frame-push, and per-thread-prof closed below threshold). Standing:
gate 1390/0/0, vpd ratchet 645s, replica 146us, fib native 34x AOT.

`plans/conformance-and-hardening.md` CLOSED 2026-08-18 with every item
landed and `scripts/gate.sh` GREEN; the record is summarised in
`PLAN-archive.md`. Its predecessor `simplify-validate-accelerate.md`
closed 2026-08-17. The items below are the standing fronts any next
campaign draws from.

## 1. Transpiler speedup + Value 16B

Full plans: `c-transpiler-plan.md`, `value-layout-campaign.md`.

State: substance LANDED AND MEASURED. The transpile -> out.c ->
zig cc pipeline is complete at full corpus byte parity against the
interpreter (pinned-artifact image path); Value is 24 bytes
(40 -> 24 boxing waves verified); the hot-view sub-ABI went live at
+3.2% rangebench (a14d89e2); the follow-up round (50754db8:
template-var unboxing, counted step-progression loops, inline
edge-guard/trace store in the emitted C) took rangebench 13.8s ->
0.97s interp / 0.83s native (16.6x / 16.8x, native +17% over interp,
312/312 transpiler parity); native leaf-serve calls (fdded783) took
fib 695ms -> 220ms, ahead of the interpreter. The landing record
(boxing waves, hot-view handover) is in PLAN-archive.md.

CLOSED 2026-08-31 (`interpreter-native-floor-campaign.md`): the C-to-C
road was already the landed `kl_` pass — measured 34.5x on fib, corpus
401/0 — and Value 24 -> 16 re-closed on its own terms (copy bucket
~2-3% ceiling, IrClosure boxing taxes compose's hottest path). The only
recorded future vein is WIDENING kl_ eligibility, driven by a real
program that misses it; details and traps in `c-transpiler-plan.md`.

## 2. Compose plugin residue

The cutover LANDED: the lowering plugin is the only compose path (the
implicit-composer hook and the `composePluginEnabled` gate are
deleted, 8835dfc8), the conformance ratchet floor is 1370
(`src/itests/compose_plugin_commontest.zig`), and the dirty-bits skip
calculus landed with checkboxLike slot-exact
(`compose-dirty-bits-plan.md`, closed). Corpus 315/315 (2026-08-15) —
window, multiwindow, foundation_lazy, serial_names all pass on warm
caches; the three maxFrames=-1 interactive demos are marked
`// corpus: interactive` and skipped by corpus_check. The fixed-entry
record is in PLAN-archive.md; running triage detail is memory
klio-compose-plugin-triage; the build-out log is
`compose-plugin-lowering.md` (finished).

Open:

- [x] CLOSED 2026-08-31: the concurrency stress family passes in the
      standing gate (1390/0/0) under the declared per-test wall caps;
      the compute floor is the recorded verdict
      (`interpreter-native-floor-campaign.md` Task 4 — the suite wall
      IS vpd, guarded by the 645s ratchet). Further movement is the
      verification-latency campaign's Task 5.
- [x] CLOSED BY RECORD 2026-08-31 (latent, no failing test names
      them): movableContentOf factory-wrap widening (bisect plan in the
      triage memory) and the imbalance op-trace probe recipe stay
      recorded for the failure that names them; checkboxLike's slot
      count remains the emission-shape anchor.
- [x] PARTIALLY LANDED + CLOSED BY RECORD 2026-08-31: the PROPERTY-READ
      half of the tower's lexical rule landed (7fb58485 — the implicit
      walk probes members before imported extension properties, and
      receiver_is_owner only trusts a window-bound head); the CALL-half
      public gating stays recorded with its measured terms (~400 tests
      without full receiver-tower emulation).

## 3. Coroutine debt cluster

State: CORRECTNESS COMPLETE (2026-08-16, combine/zip included). Every
recorded coroutine bug is fixed (channel/loop-JIT suspension drop,
zip's trailing-lambda-blind extension arity, combine's receiver-tower
`this@fn` head binding), oracle-verified not-a-bug (unconfined yield
order), or reclassified compute-heavy (the Recomposer deadlock pair).
Litmus baseline 45/45 — any litmus failure is real. The closed record
is in PLAN-archive.md; the architecture reference is
`COROUTINE-MODEL.md`.

Open:

- [x] CLOSED AS WATCH-STATE 2026-08-31: litmus 45/45 and every parity
      battery green all session; the postmortem recipe (sweep
      got-vs-expected tails) stands for the next natural occurrence.
- [x] Background-yield 55s round-trip — CLOSED BY MEASUREMENT
      (`simplify-validate-accelerate.md` A6 round record): the yield hop
      on Dispatchers.Default costs ~100us (2000-yield rig), and
      resumeOnBackgroundThread's spinner never iterates (`running` stays
      false) — the 55s is the test's own PausableComposition resume
      protocol, quadratic upstream (recordModificationsOf over the whole
      remaining scope set per resumeOnce), a compute floor here.
- [x] CLOSED 2026-08-31 — verified FIXED: the kept repro (yieldhop.kt)
      passes on main (yield ~133us, no hang); the defect died in the
      Aug resolution work.

## 4. ktor commontest + upstream residue

State: CLOSED. Final census 465 passed / 2 failed / 0 incomplete; the
last 2 are CLOSED BY RECORD and the suite baseline is ratcheted at 440
in `src/itests/ktor_commontest.zig` (census floor 465 solo, margin for
CI load). The campaign record (include-list recipe, the interpreter
root-fix batches, the inline-`synchronized` monitor-leak landmark) is
in PLAN-archive.md. Upstream-consumption reference:
`KTOR-SERVER-UPSTREAM.md`.

The 2 closed-by-record fails, kept here because they must never be
"fixed": URLBuilderTest scheme-with-digits ×2 — klio MATCHES Kotlin
semantics (upstream URLProtocol's own
`require(name.all { it.isLowerCase() })` rejects digit schemes on the
JVM too, verified against Character.isLowerCase); how upstream CI
passes them is unclear — do NOT diverge klio.

Open:

- [x] CLOSED BY RECORD: the risk stands as documentation; the
      ktor_server/client e2e itests gate the includes in CI.
- [x] CLOSED AS BLOCKED-WITH-TERMS 2026-08-31: the shim swap reopens
      when the kotlinx.serialization pack grows the serializer surface
      KotlinxSerializationConverter compiles against; the launch flake
      is watch-state. Both recorded in `KTOR-SERVER-UPSTREAM.md`.

## 5. Suite-wall profile

State: DONE — buildSubTable is genuine interpreted compute, not an
O(n^2) pathology (oneRectBenchmarkSimulation solo 56.7s, 57k samples,
no dominant user frame); the floor stands until a generic
interpreter-speed lever. Record in PLAN-archive.md and memory
klio-compose-suite-perf; harness practice in `BENCHMARKS.md`.

## Doc register

LIVE (open work tracked): `c-transpiler-plan.md`,
`value-layout-campaign.md`, `KTOR-SERVER-UPSTREAM.md`, and this file.
`conformance-and-hardening.md` is FINISHED (closed 2026-08-18) and kept
as a log — it holds the census baselines, the process-global contract,
the resolution-path map and the coroutine terminal-state contract.
`simplify-validate-accelerate.md` is FINISHED (closed 2026-08-17) and
is kept as a log — it is still cited above for the V4 acceptance
standing and the A6 yield-hop record. `worklist.md` is a pointer:
its round closed 2026-08-16 and the full record (including the E4
concurrency rig and C2 visibility records the active plan cites) moved
to `PLAN-archive.md`.

REFERENCE (design / architecture / practice; not campaigns):
`ARCHITECTURE.md`, `BENCHMARKS.md`, `COROUTINE-MODEL.md`,
`DIAGNOSTICS.md`, `GC.md`, `INTRINSICS-TO-KOTLIN.md`, `JIT-DESIGN.md`,
`kotlin24-annotations-backing-fields.md`,
`kotlin24-context-parameters.md`, `MOBILE-TARGETS.md`,
`MULTIPLATFORM.md`, `PACK-DISTRIBUTION.md`, `PLAN.md`,
`project-manifest.md`, `STDLIB.md`, `UI-RENDERING-PACKS.md`,
`verification-speed-plan.md`, and `analysis/` (deferred-findings,
execution-architecture, guard-inventory, zig-freedoms).

FINISHED (campaign logs; indexed with outcomes in `PLAN-archive.md`):
`bytecode-vm-plan.md`, `ci-green.md`, `compose-dirty-bits-plan.md`,
`compose-plugin-lowering.md`, `CPU-EFFICIENCY-CAMPAIGN.md`,
`eager-resolution-plan.md`, `feedback-loop-plan.md`,
`interpreter-perf-campaign.md`, `interpreter-performance-plan.md`,
`klio-bundle-plan.md`, `LANGUAGE-GAPS.md`, `LAZY-IMAGE.md`,
`loadglobal-member-fallback-audit.md`, `MEMORY-PARITY-CAMPAIGN.md`,
`PACK-ROADMAP.md`, `p2-applicability-design.md`,
`p3-resolvecall-design.md`, `resolution-unification-plan.md`,
`static-dispatch-campaign.md`.
