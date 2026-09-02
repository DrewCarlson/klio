# Compose-UI census campaign: upstream ui test suites become standing gates

STATUS 2026-09-02 (late): Task 1 DONE — sparse set widened (the six ui
modules' commonTest: 46 files) via scripts/init-compose-submodule.sh,
`compose_ui` suite registered in src/itests/commontest_support.zig
(roots for ui-util/ui-geometry/ui-unit/ui-graphics/ui-text/ui, the ui
packs, a klio-authored `androidx.kruth` assertion stand-in under
tests/compose_ui_commontest_actuals), `zig build itest-compose_ui_commontest`
and `klio-census compose_ui` wired. FIRST COUNT: 389 passed, 63 failed; AFTER ROUND 1: 446 passed, 6 failed
across 42 files, 0 did not complete (baseline 0). Failures by module:
ui-graphics 38 (RenderEffectTest 12, MatrixTest 9, PathParserTest 7,
ShadowParamsTest 6, ColorSpaceTest 2, ShadowTest 1, InlineClassHelperTest
1), ui-util 12 (ListUtilsTest 11), ui-unit 8 (TextUnit/Dp/DpSize/DpOffset
2 each), ui-geometry 5 (SizeTest 3, OffsetTest 2); ui-text and ui/ui
green. Task 2 (drive to a ratchet) starts with ui-unit/geometry/util.

Task 2 round 1 (named roots, all root-fixed in the interpreter or the
pack surface, never in a test):
- R1 extension property on a spliced subject: a bare `isSpecified` inside
  the spliced `Dp.takeOrElse`, `indices` inside `List.fastForEach`, read
  the enclosing `this` (`get_field isSpecified on T`). Extension
  properties are not in `funcsBySimpleName`; their getters are
  `__ext_get_<Head>_<name>` and their heads live in
  `registry.ext_prop_type_heads`. `extensionPropOnHead` now walks the
  subject head, its builtin supers and `class_super_names`, and the
  subject walk binds the bare name to that subject. ListUtilsTest 0/11 ->
  11/11, DpTest 25 -> 27/27, OffsetTest 33/33, SizeTest 36 -> 38/39.
- R2 a simple type head shared by two classes (`androidx.compose.ui.geometry.Size`
  and the klio-authored `androidx.annotation.Size` annotation) made
  `uniqueClassIdBySimpleName` decline the static member path, and the
  runtime's `hierarchy_methods` (keyed by simple name, first registration
  wins) answered "no user toString" from the annotation, so
  `Size(10f, 20f).toString()` rendered structurally. The static owner
  pick falls back to the import-aware `classIdIndexed`; the registry
  also carries a qualified-name key for top-level classes and the
  runtime reader tries the fqn first. SizeTest 38 -> 39/39.
- R3 pack surface: the ui-graphics pack shipped a curated include list
  without `vector/` (PathParser, PathNode, PathBuilder, FastFloatParser),
  the `shadow/` package, `Interpolatable.kt` or `RenderEffect.kt`
  (`expect` classes: klio actuals for RenderEffect/BlurEffect/OffsetEffect
  added under klioMain). PathParserTest, ShadowParamsTest (the ctor arity
  miss was the OTHER `Shadow`), RenderEffectTest.
- R4 (shared with ktor) a bare call whose name is shadowed by a plain
  value (`if (initParentJob) initParentJob(parent)` in AbstractCoroutine)
  lowered to a `LoadGlobal` of the value name; a member function of the
  enclosing class chain now keeps the call.
- R5 (FIXED) MatrixTest: `matrix.map(Offset(1f,1f))` in an assertEquals
  argument spliced `Flow<T>.map` because the Matrix.map overload set
  (`map(Offset)`/`map(Rect)`/`map(MutableRect)`) was ambiguous for the
  factory-derived argument shape, so the receiver-member check reported
  no target. `receiverConcreteMemberTakes` now treats an APPLICABLE-but-
  ambiguous member as shadowing the inline extension (returns on
  `res.target != null or res.applicable`). MatrixTest 20 -> 29/29.

Round 1 result (compose_ui census on the corrected harness): 389 -> 446
passed, 63 -> 6 failed across 42 files (baseline 0). Remaining 6:
ShadowTest 2, ColorSpaceTest 2, SizeTest 1
(testSpecifiedSizeToString: value-class `Size.toString` still renders
structurally in the baked IMAGE path though it is correct in run mode
-- the runtime `class_fqn` is empty for a value-class instance so the
qualified `hierarchy_methods` key is not consulted; OPEN),
InlineClassHelperTest 1. Ratchet the floor once these 6 close.
Before that the family was guarded by
five example byte-gates only — no upstream test suite ran. The
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
