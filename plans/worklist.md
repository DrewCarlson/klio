# Master worklist

The ordered execution plan across everything still open. Worked top to
bottom, one item at a time; each item lands with its battery (unit +
litmus + sweep + corpus + the suite ratchets that its area touches) and
updates this file. Detail lives in the linked campaign docs — this file
is the order of work and the completion state.

## Phase A — Performance (active)

The transpiler's hot view is live and measured (+3.2% rangebench
ReleaseFast JIT-off, a14d89e2) but the campaign's goal is a real
speedup, not neutrality-plus. The recorded levers, measure-first
(`plans/c-transpiler-plan.md` §speedup):

- [x] A1. Baseline re-measured: interp 13.68s / native 13.89s (the
      +3.2% did not hold on current main — native was ~1.5% BEHIND).
- [x] A2+A3 LANDED TOGETHER (50754db8), measured 13.8s -> 0.97s
      interp / 0.83s native (16.6x / 16.8x; native +17% over interp;
      312/312 transpiler parity, corpus 316/316, ratchet 1370):
      * KLIO_PROF on the native binary attributed the wall to
        INTERPRETED machinery, which led to two interpreter-side roots
        the emitted C merely inherited:
      * computeBoxedVars falsely boxed every var a same-function
        string template `$name`-mentioned (a template is not a
        lambda) — rangebench's accumulator paid a locked cell op per
        iteration. Unboxed; unit test pins it.
      * literal-step progressions (`step k`) ran the virtual iterator
        protocol per iteration; now counted register loops with
        kotlinc's overflow-free last-element snapping (JVM-verified;
        guard example step_progression_counted.kt).
      * the emitted C inlines the per-statement trace store (span
        offsets in the hot layout) and the fused edge guard
        (klio_edge_view flag polling; ABI v3).
- [x] A4 first increment (fdded783): native calls LEAF-SERVE in place
      (the glue answers monomorphic plain calls to leaf expression
      bodies via leafExprServe, no recursive full-frame serve, no
      unwind round trip). fib native 695ms -> 220ms, ahead of the
      interpreter's 232ms; rangebench unchanged. Deeper C-to-C frames
      (non-leaf callees) remain a recorded road — measure-first, the
      remaining gap on call-heavy code is now against the JIT ceiling,
      not the interpreter.
- [ ] A5. Value 16B endgame DEFERRED BY ITS OWN DOCTRINE: stage 5b's
      32B payloads already landed (Value = 24, hot-layout-confirmed);
      the 24 -> 16 tail needs BOTH remaining 16B payloads under 8:
      Array (clean: steal the cell pointer's low bit for the
      boxed-vs-PrimBuf discriminator, kind lives in the PrimBuf
      already) and IrClosure (every shape adds an allocation or an
      id-table lifetime problem to the HOTTEST creation path — compose
      builds closures per execution). The campaign doc marks these
      "measured-first, NOT the active front"; correctness work (Phase
      B's ~60 failing tests) outranks a speculative layout change with
      regression risk. Re-open when a measurement motivates it.
- [x] A6 CLOSED BY VERIFICATION: the yieldbench GPF family
      (activateChain chain-lifetime) is dead on current main — 15/15
      clean runs, ~230ms warm. resumeOnBackgroundThread PASSES in ~50s
      and profiles as the compute-heavy category by design (1000
      composables resumed incrementally under a background mutator
      thrash loop; memset of frame register files 13%, no stall, no
      single hot bug). Frame-pool/lazy-zero ideas belong to the CPU
      campaign's recorded roads, not this worklist.

## Phase B — Compose plugin suite long tail

Ratchet 1370 observed (floor 1340) across 46 classes; roughly 60
individual tests still fail and 3 heavy classes are excluded from
census. No enumerated mechanisms yet — enumeration first, the way the
ktor campaign started (`plans/compose-plugin-lowering.md`, triage
memory klio-compose-plugin-triage).

- [ ] B1. Census enumeration: per-class children at P=2, heavies solo
      uncapped; name every failing test; cluster by mechanism.
- [ ] B2. Fix the clusters, largest mechanism first; guard example per
      fix; ratchet floor raised as observed counts stabilize.
- [ ] B3. The 3 DNC heavy classes: get them completing under caps that
      match their compute (the suite-wall profile says benchmark-shaped
      tests set the floor, not the tooling).

## Phase C — Recorded correctness items

- [ ] C1. Inline-class dispatch family: member calls (`::class`,
      `toString`, methods) on RAW unboxed value-class payloads fail
      with "virtual call receiver is not an instance" — surfaced by
      slot-table walks over Color-like slot values (repro recipe in
      triage memory 64b; scratchpad reprosrc/CheckboxSlotDumpTests.kt).
- [ ] C2. Private member-extension-property visibility: plain
      (recv, name) registration leaks program-wide; the first gating
      attempt broke JobSupport's `Any?.exceptionOrNull` — needs
      frame-owner-aware visibility (recorded in open-campaigns §2).
- [ ] C3. ktor server/client e2e itests against the widened pack
      includes — the CI-gate surface the commontest census does not
      cover (devloop memory notes the risk).

## Phase D — Watches (no active work; act when they fire)

- tl_atomic_update_contended litmus flake: postmortem on next natural
  occurrence (the sweep prints got-vs-expected tails now).
- URLBuilder scheme-with-digits ×2: klio matches Kotlin, intentionally
  red upstream — never "fix".
- checkboxLike stays the slot-exact anchor; any emission work re-runs
  GroupSizeValidationTests.

## Done this stretch (index)

ktor commontest 465/468 zero-incomplete; compose remember-family 26/26;
dirty-bits calculus + slot-exact checkboxLike; corpus 315/315 with the
interactive-example contract; coroutine debt closed by JVM oracle;
ratchet floor 1305 -> 1340. Details: `plans/open-campaigns.md`.
