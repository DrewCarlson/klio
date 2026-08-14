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

- [ ] Value stage 5b IN PROGRESS: RangeIter folded into its state cell;
      Range/BoundMethod/MapEntry boxed (rangebench A/B neutral: 83.6s vs
      83.7s). REMAINING: the Iterator fold (merge items/prim/mod_count/
      mutable into the IterCursor cell — one alloc either way; ~28 access
      sites, concentrated in host_call_member's iteratorMember which
      already borrows the cursor) → Value 40 → 32; then the 24B tier
      (Intrinsic/Array/Triple/MatchGroup + Pair/IrClosure/Function) → 16
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

## HANDOVER NOTE (Value=24 VERIFIED)

The whole 24B tier is done: Triple boxed, MatchGroup boxed (shared
descriptor struct), Intrinsic INTERNED (immortal records — no refcount,
no GC), Array REPACKED (the boxed/scalars tag was derivable from
`prim == null`, so the payload is (cell ptr, prim) with storage()
rebuilding typed handles). Census: Value 32 -> 24, NO payload >= 24.
rangebench 82.6s (band 83.0-83.7 — neutral/slightly better); units
zero-leak; hello smoke green. VERIFIED: sweep 117/0, corpus + compose slice at
baseline, litmus 43/44 (only the yield flake), plugin ratchet 1339
(ABOVE the 1337 baseline; the GC-stress step green).
16B wave state: Pair BOXED; dead AST-era variants (Function,
BoundUserMethod, BoundInnerClass) DELETED (net -74 lines, sweep 117/0).
Comparator BOXED (sweep 117/0), Result BOXED (units zero-leak). The
16B ENDGAME is now a recorded measured-first road, NOT the next step:
only IrClosure ({id u64, captures ValueSlice} — the side table already
keys canonical captures by id, so the payload could become the bare id
IF the per-value dup'd captures snapshot is semantically redundant —
verify against the closure invoke path before touching) and Array
remain at 16, both hot, and 24 -> 16 pays only if BOTH shrink. Measure
Value=24's own wins first (rangebench + suite wall vs the 40B-era
records). NEXT ACTUAL STEP for item 1: the transpiler hot-view sub-ABI
against the now-stable 24B layout + the rangebench speedup number.
Then items 2-4.

## previous note (Value=32 landed, superseded above)

The Iterator fold landed (2a6e72f3): census Value 40 -> 32, units green
zero leaks, rangebench 83.0s (inside the pre-fold band), sweep 117/0,
corpus/litmus at the known baseline. Before the NEXT wave: run the
compose warm+slice and the plugin ratchet once against this commit.
Next in item 1: the 24B tier (Intrinsic, Array, Triple, MatchGroup,
then Pair/IrClosure/Function/...) boxes for Value=16, paired with the
transpiler hot-view sub-ABI so scalar offsets freeze once; then the
rangebench speedup number. Items 2-4 (compose triage, coroutine debt,
ktor) follow per their sections above.
