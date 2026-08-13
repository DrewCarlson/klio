# Open campaigns

The five active workstreams, tracked here at one line of truth each; the
detail lives in the linked plan docs. Update the checkboxes and the
"state" lines as work lands — this file is the index, not the log.

## 1. Transpiler speedup + Value 16B

Make the transpiled native tier faster than the stream interpreter
(currently perf-neutral: rangebench RF JIT-off 14.44s interp vs 14.55s
native), paired with Value 40B → 16B since both freeze scalar layout.
Full plans: `c-transpiler-plan.md` ("Next: the speedup campaign"),
`value-layout-campaign.md` (stage 5b).

- [ ] Value stage 5b: 32B payloads → 16, measure-first (rangebench gate)
- [ ] Hot-view sub-ABI: static-inline C ops over frozen Value scalar
      offsets, comptime-checked at klio_rt build
- [ ] Light-frame C-to-C calls (tagged-table / vararg ideas land here if
      measurement wants them)
- [ ] The number: rangebench RF JIT-off, native meaningfully under interp

State: not started; roads pinned in both plan docs.

## 2. Compose plugin triage residue

The named correctness bugs left from the plugin cutover. Full plan:
`compose-plugin-lowering.md` + the triage list in memory
(klio-compose-plugin-triage).

- [ ] Corpus entry 43: qualified-exact dispatch
- [ ] Corpus entry 45: assign-lambda-typed
- [ ] Corpus entry 46: abstract-member static anchor + splice-write owner
      + inline-param hidden from spliced caller lambda
- [ ] Receiver-loss residue
- [ ] serial_names
- [ ] window family + foundation_lazy hang cluster

State: not started this stretch; entries carried from the cutover.

## 3. Coroutine debt cluster

Scattered, each half-diagnosed. No single plan doc yet — write one when
the campaign opens (`COROUTINE-MODEL.md` is the architecture reference).

- [ ] with_timeout preempt
- [ ] private_shadow cells
- [ ] Cancellation cluster (flow campaign residue)
- [ ] Unconfined event loop (= createEventLoop debt)
- [ ] tl_atomic_update_contended litmus flake (timeout under load)
- [ ] Background-yield 55s cost (suite-perf memory)

State: not started.

## 4. ktor_commontest upstream fails

292 upstream test failures, unmapped. Reference: `KTOR-SERVER-UPSTREAM.md`.

- [ ] Triage the 292 into failure classes
- [ ] Fix by class, ratchet the count

State: not started; least-known of the five.

## 5. Suite-wall profile

The pending question from the compose suite perf work: is
SlotTableBuilder's buildSubTable an O(n^2) pathology or genuine compute?
Reference: memory klio-compose-suite-perf; `BENCHMARKS.md` for harness
practice.

- [x] Profile buildSubTable under KLIO_PROF (`klio test` now honors
      KLIO_PROF like `run` does)
- [x] Verdict: NOT a pathology. oneRectBenchmarkSimulation solo = 56.7s,
      57k samples with NO dominant user frame — time spreads across
      generic dispatch (runFrameExec/execInst/member dispatch), ~8.6%
      memset (regs/array-init churn), ~8% name-keyed hashmap equality.
      Genuine interpreted compute; the floor stands until a generic
      interpreter-speed lever (the JIT is off under `klio test` by
      design, and the loop JIT measured unhelpful on this workload).

State: DONE — floor recorded here and in memory.
