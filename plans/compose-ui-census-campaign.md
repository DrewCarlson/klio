# Compose-UI census campaign: upstream ui test suites become standing gates

STATUS 2026-09-02: NOT STARTED. The compose-ui family is guarded by
five example byte-gates only — no upstream test suite runs. The
census-gap lesson (perf batteries skipped libraries; example gates hid
~80 regressions and a 17-day corpus hole) applies verbatim to the UI
half: the render stack is pixel-verified, but its unit surfaces
(geometry math, unit arithmetic, graphics types, text) have no
conformance census.

## Measured starting facts (do not re-derive)

- The compose-multiplatform-core submodule
  (`kotlin-klio/klio-compose-runtime/upstream`) already carries
  `compose/ui/{ui,ui-unit,ui-geometry,ui-graphics,ui-text,ui-util}`
  at `src/commonMain` — the packs consume those sources — but the
  sparse set OMITS `src/commonTest` for every ui module (0 test
  files today). The androidx-collection census hit this exact shape
  ("androidx's ratchet had never run because its sparse checkout
  omitted commonTest") and the fix is the same: widen the sparse set,
  in scripts/init-compose-submodule.sh so bootstrap reproduces it.
- Suite mechanics to copy: commontest_support.zig registry entry
  (roots, packs, scratch home, ratchet floor, child caps, extra
  support actuals following the stdlib_commontest_actuals /
  tests/compose_commontest_actuals pattern for platform expects).
- Start with the pure-unit modules (ui-unit, ui-geometry, ui-util —
  scalar/geometry math, no composition, no window): cheapest closure,
  highest signal per failure. ui-graphics next (types + Skia-backed
  pieces — tests needing a real canvas may need actuals or exclusion
  WITH RECORD). ui-text after (Paragraph/TextMeasurer exist over
  Skia). The big `ui/ui` module's commonTest (input, layout, node
  machinery) is the last rung and may split by directory.
- Every failure is an interpreter or pack-surface root to fix, or an
  honest platform gap to record — never a test edit. Expect the first
  counts to be red; that is the point of a census.

## Task 1 — sparse widening + first counts

- Widen the submodule sparse set to the ui modules' `src/commonTest`
  (and any testutils they import), wire the per-module suites (or one
  `compose_ui_commontest` with per-module roots) into
  commontest_support.zig, run the first counts on per-class children,
  and record them in this plan. No ratchet yet — the count is the
  deliverable of this task.

## Task 2 — drive to a ratchet, module by module

- ui-unit/ui-geometry/ui-util first: root-fix to a stable green (or
  enumerated-exclusion) count, set the ratchet floor, add to the
  battery (stack.sh census wave or gate.sh, budgeted like the other
  suites).
- ui-graphics, ui-text, then ui/ui the same way; each module's rung
  records its count trajectory and named roots here. A module whose
  tests structurally need an Android/desktop host (instrumentation,
  golden images) closes by record with the exclusion list.

## Standing policy

- Correctness gates never weaken; new ratchets only ADD gates.
  scripts/stack.sh stays the full battery; heavy new suites must not
  move its wall materially (budget like the census waves, or park in
  gate.sh if wall-hostile — recorded either way).
- Traps in force: installed packs shadow sources; pack rebuild before
  judging failures; per-class children only; harness starvation =
  missing sibling/support files, not interpreter bugs; ONE heavy
  battery at a time.

Exit: the sparse widening is reproducible via the init script; every
ui module carries either a ratcheted standing census or a recorded
closure (host-bound exclusions enumerated); the counts and named
roots live in this plan; full battery green with the new gates in.
