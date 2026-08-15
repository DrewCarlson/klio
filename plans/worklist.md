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

- [ ] A1. Baseline re-measure on current main (rangebench RF, JIT off,
      interpreter vs native tier) so every lever has a fresh yardstick.
- [ ] A2. Inline trace store — the a14d89e2 commit names it "the next
      recorded lever": the per-statement trace bookkeeping and edge
      guard still call into the runtime from emitted C.
- [ ] A3. Wider hot-op coverage: branch/jump/cmp_br shapes, the
      range-loop ops, and whatever the measurement says dominates after
      A2 (profile the native binary, not assumptions).
- [ ] A4. Light-frame direct C-to-C calls (call-heavy yardstick: fib) —
      the tagged-table / vararg-prologue ideas land here if the
      measurement wants them.
- [ ] A5. Value 16B endgame, stage 5b (`plans/value-layout-campaign.md`):
      IrClosure via side-table id + Array — measure-first, AFTER A2-A4
      (the hot-view layout descriptor is runtime-measured so it adapts,
      but every layout change re-runs the A1 yardstick).
- [ ] A6. Background-yield 55s suite cost (suite-perf memory): profile
      the yield path under the plugin suite before touching anything.

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
