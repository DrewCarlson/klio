# Open campaigns

The live plan register: every open workstream at one line of truth,
pointing at its owning doc. This file is the index, not the log —
update the state lines as work lands. Closed campaign records live in
`PLAN-archive.md` (which also indexes every finished campaign doc);
the finished docs themselves stay in place as logs. Reference docs
(architecture, design, practice) are listed in the doc register at the
bottom and are not campaigns.

## The active plan

`plans/conformance-and-hardening.md` — two tracks: Conformance (prove
what the interpreter actually passes: the coroutines suite's 896
failures behind a 340 floor, ratchet ceilings, the 44 unpinned examples,
a stdlib surface inventory) and Hardening (the structural weak spots the
last campaign exposed: process-global state, the two resolution paths
that can disagree, the coroutine park/wake contract, dispatch-ladder
density, the memory model). Carried perf roads stay measurement-gated.
Order of work and completion state live there.

Its predecessor `plans/simplify-validate-accelerate.md` CLOSED
2026-08-17 with every item landed and `scripts/gate.sh` GREEN; the full
record is summarised in `PLAN-archive.md`. The items below are the
standing fronts both plans draw from.

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

Open — measured-first recorded roads, NOT an active front (reopen only
when a measurement motivates):

- [ ] Deeper C-to-C frames (non-leaf callees) — `c-transpiler-plan.md`.
- [ ] Wider hot-op coverage in the emitted C — `c-transpiler-plan.md`.
- [ ] Value 24 -> 16 endgame (both IrClosure and Array must drop under
      8B or it pays nothing) — `value-layout-campaign.md`; gate any
      candidate on the compose suite wall as well as rangebench.

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

- [ ] The 4 concurrency stress tests + validatePotentialDeadlock + the
      2 PausableCompositionTests background tests: compute-bound
      (measured, not mechanism bugs). They are the ACCEPTANCE METRIC
      for the accelerate track
      (`simplify-validate-accelerate.md` V4 / Track A).
- [ ] Latent, waiting for a failure that names them: movableContentOf
      factory-wrap widening (the drafted ungated patch recursed;
      bisect plan in the triage memory) and the group start/end
      imbalance op-trace probe recipe. checkboxLike's slot count is
      the live emission-shape anchor; any emission work re-runs
      GroupSizeValidationTests.
- [ ] Recorded: non-private member-extension-property tower gating
      (the private half landed; gating the public half cost the suite
      ~400 tests — needs the receiver-tower emulation to see every
      legal frame).

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

- [ ] tl_atomic_update_contended litmus flake — watch state; postmortem
      on next natural occurrence (the sweep prints got-vs-expected
      tails).
- [x] Background-yield 55s round-trip — CLOSED BY MEASUREMENT
      (`simplify-validate-accelerate.md` A6 round record): the yield hop
      on Dispatchers.Default costs ~100us (2000-yield rig), and
      resumeOnBackgroundThread's spinner never iterates (`running` stays
      false) — the 55s is the test's own PausableComposition resume
      protocol, quadratic upstream (recordModificationsOf over the whole
      remaining scope set per resumeOnce), a compute floor here.
- [ ] Dispatched-block import scope: an imported top-level fn
      (kotlin.system.measureTimeMillis) is `unresolved global` inside a
      Dispatchers.Default-dispatched block (pool child-Vm loses the
      file's import scope), and the resulting internal CalleeFailed
      leaves the runBlocking root parked forever — a silent hang where
      upstream surfaces the failure. Repro: A6 session scratchpad
      reprosrc/yieldhop.kt.

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

- [ ] Risk note: the widened pack includes are validated by the
      commontest census only; the ktor_server/client e2e itests gate
      them in CI.
- [ ] `KTOR-SERVER-UPSTREAM.md` residue: the client/server
      serialization shim swap (blocked on the kotlinx.serialization
      pack growing the real serializer surface upstream
      KotlinxSerializationConverter compiles against) and the
      start-path connector-logging launch flake.

## 5. Suite-wall profile

State: DONE — buildSubTable is genuine interpreted compute, not an
O(n^2) pathology (oneRectBenchmarkSimulation solo 56.7s, 57k samples,
no dominant user frame); the floor stands until a generic
interpreter-speed lever. Record in PLAN-archive.md and memory
klio-compose-suite-perf; harness practice in `BENCHMARKS.md`.

## Doc register

LIVE (open work tracked): `conformance-and-hardening.md` (the
active plan), `c-transpiler-plan.md`, `value-layout-campaign.md`,
`KTOR-SERVER-UPSTREAM.md`, and this file.
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
