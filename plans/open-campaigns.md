# Open campaigns

The five active workstreams, tracked here at one line of truth each; the
detail lives in the linked plan docs. Update the checkboxes and the
"state" lines as work lands — this file is the index, not the log.

## 1. Transpiler speedup + Value 16B

Full plans: `c-transpiler-plan.md`, `value-layout-campaign.md`.

- [x] Value 40 -> 24: RangeIter/Iterator folds; Range/BoundMethod/
      MapEntry/Triple/MatchGroup/Pair/Comparator/Result boxed; Intrinsic
      interned; Array repacked; dead AST-era variants deleted. Verified:
      sweep 117/0, ratchet 1339, rangebench neutral.
- [x] Hot-view sub-ABI landed + measured: +3.2% rangebench RF JIT-off at
      293/293 corpus parity (a14d89e2).
- [ ] RECORDED ROADS (measured-first, not the active front): the 16B
      endgame (IrClosure via side-table id + Array), inline trace store,
      wider hot-op coverage, light-frame C-to-C calls.

State: substance LANDED AND MEASURED; deeper speedup roads recorded in
the plan docs and the handover note below.

## 2. Compose plugin triage residue

The doc's original checklist was stale: entries 43-47, the window
family, foundation_lazy, and serial_names are ALL FIXED (triage memory
54i/54j/54k + entry records; today's corpus = the 3 interactive
permanents + lazy's Debug-CLI time cap + the animation load flake).
The LIVE residue is two emission roots from the triage memory head,
both suite-level (plugin conformance ratchet):

- [x] Local-ext-on-declared-builtin family FIXED (c3f3fc38 + 75a92601):
      the static subtype judgment learned the builtin collection
      hierarchy + the bare-type-param non-refuting rule (the deriver
      leaves factory type args unsubstituted — MutableList<T>).
      MovableContentTests 41 -> 42/44; ratchet 1338; guard example
      local_ext_declared_receiver.kt. Deeper channel recorded: the
      deriver should substitute call-site type args.
- [x] anchorIndex-on-MutableList FIXED: nested splice-window hole —
      a lambda spliced from inside another spliced lambda (let inside
      fastForEach's action) records a caller window whose region
      includes the OUTER inline fn's receiver bind, so bare `this`
      resolved to the outer splice receiver (`scopes`) instead of the
      class instance. Fix: `splice_hidden_bands` stack on FuncBuilder —
      every active window registers its hidden `[caller_depth,
      own_base)` band and the windowed caller scan skips enclosing
      bands. MovableContentTests 42 -> 44/44. NOTE: the wrong spliced
      code lowers in EVERY context but is live only via the pack-loaded
      module (test-file lowering ran an alternate emission), so
      standalone repros pass pre-fix — in-situ probe (println in
      SlotTable.kt + pack rebuild) was the discriminator.
- [ ] movableContentOf factory wrap: kotlinc wraps factory-returned
      composable lambdas in composableLambdaInstance (key, tracked,
      wrapper) so every content(n) call site gets a restart group
      enclosing the movable group; klio leaves them RAW = a missing
      bracket level. A drafted patch (wrap ret_composable lambdas ×3
      arms) CORE-DUMPED with 10001-frame recursion — bisect plan:
      gate the wrap to movableContent* factory names first, then find
      which fn self-recurses (suspect engine fns whose returned lambda
      self-references, or the CLI-invoke updateScope loop).
- [ ] Group start/end imbalance: the ref-1 offset stream closes ONE
      level too many (EndCurrentGroup lands parent=3 not parent=5), so
      SkipToEndOfCurrentGroup runs to the PARENT end past the ref2
      destination; single-ref tests tolerate it. Probe recipe in the
      triage memory (Operations.kt [op] print with val op0=this.operation).

State: opened this stretch; both roots recorded with probes and bisect
plans in memory klio-compose-plugin-triage.

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
records). HOT-VIEW SUB-ABI LANDED (a14d89e2): the emitted C inlines
const_int/move/bin/cmp_br over the runtime-measured layout slot —
Int/Int + Long/Long + mixed-width promotion with applyBinop-exact
semantics, per-op helper fallback everywhere, gated on KV.usable
(computed from reclaimRequested; the live per-thread flag sampled too
early left the path dark — found via the layout probe). MEASURED:
rangebench RF JIT-off 13.38s native vs 13.82s interp = +3.2% at full
293/293 corpus parity. Honest reading: the fused stream was already
cheap, and the remaining per-iteration costs (edge guard, trace
bookkeeping) are SHARED with the interpreter — next recorded levers are
an inline trace store (frame.cur_span offset via the same probe
mechanism) and wider op coverage. Item 1's Value+transpiler substance
is landed-and-measured; the deeper speedup is an open recorded road
alongside the 16B endgame. Items 2-4 are NOW the active front.

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
