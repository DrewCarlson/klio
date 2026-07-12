# Compose UI on klio — status + roadmap

Grounded in the live code (`kotlin-klio/klio-compose-*/`, `src/compose_ui/`) and
the vendored upstream under `kotlin-klio/klio-compose-runtime/upstream`.

Goal: klio is a **drop-in for desktop Compose Multiplatform** — vendor upstream
`androidx.compose.*` common code verbatim, supply klio's Skia backend as the
desktop actual. The common/desktop/mobile source-set layering and the
one-pack-per-upstream-module rule are in [MULTIPLATFORM.md](MULTIPLATFORM.md)
(§3 and §0). Desktop is the only live target.

## What exists

- **Compose runtime** — the real `androidx.compose.runtime` (state, recomposition,
  `remember`/`key`/effects, CompositionLocal, `derivedStateOf`, the async Recomposer
  + frame clock, `snapshotFlow`/`collectAsState`, `@Composable` content, node
  emission via `Applier`/`ComposeNode`, subcomposition). Vendored + klioMain engine.
- **Skia rendering backend** — `src/compose_ui/skia_shim.cpp` is the `extern "C"`
  DrawScope (rects/rrects/circles/lines/text/paragraph, AA raster + PNG encode) over
  the prebuilt JetBrains skia-pack (fetched by `scripts/fetch-skia.sh`, gitignored,
  per-target). The `compose_ui` Zig module dlopens it and exposes the `__composeui_*`
  host intrinsics. A draw pass records a **display list** of ops — the deterministic,
  Skia-independent test artifact (PNG bytes are the visual proof). Optional GPU:
  Ganesh+EGL (Linux, opt-in) and Metal (macOS window).
- **Live windows** — **SDL2 (Linux, verified: software + GPU)** and **macOS Cocoa +
  Metal GPU** (verified on hardware): a real window runs render → present → poll →
  dispatch, with a Quit menu, live-resize, batched input, keyboard/hover/pointer, a
  `TextField`, and word-wrapped `Paragraph` text. A bundled Latin font
  (`src/compose_ui/fonts/`) makes text self-contained. The Linux backend is SDL2
  (one C ABI, `-DKLIO_SDL`): SDL picks X11 or Wayland at runtime, so it covers the
  broad desktop matrix; the raster path uploads the N32 surface to a streaming
  texture, and `-Dgpu` wraps the window's GL framebuffer as a Skia Ganesh surface
  (verified on an NVIDIA RTX 6000 via zink, GL 4.6, real on-screen GPU rendering),
  falling back to raster if GL bring-up fails. Win32 backend is written but
  unverified (needs a Windows host).
- **klio-authored ui-core** (`klio.compose.ui`) — `LayoutNode` emit →
  measure/layout/draw, a `Modifier` chain, `Column`/`Row`/`Box`/`Text`/`Button`/
  `LazyColumn`, pointer input, `MaterialTheme` via CompositionLocal, `runApp`. This
  proves the ui-core architecture end-to-end and is the interim driver until the real
  `androidx.compose.ui` engine replaces it.
- **Real pure-Kotlin `androidx.compose.ui.*` foundation** — vendored verbatim as
  one pack per upstream module (`androidx.compose.ui.{util,geometry,unit,graphics}`;
  see MULTIPLATFORM.md §0). Working: geometry (Offset/Size/Rect/RoundRect), unit
  (Dp/IntSize/**Density**/TextUnit conversions), graphics (**Color** + the full
  color-science colorspace package + the drawing-parameter value classes
  BlendMode/StrokeCap/PathFillType/…). No Skia in this layer.

Examples: `compose_{color,density,path,paint,pathop,ui,ui_click,ui_geometry,
ui_lazy,ui_material,ui_text,ui_window,ui_input,ui_png}.kt`, `mosaic_hello.kt`.

### Interpreter fixes this vendoring drove (all general, landed)

Vendoring real compose surfaced and fixed several genuine interpreter gaps (each
with a minimal repro + green suites): identity-based inherited-method dispatch
(name-collision), inherited companion `const`/`fun` resolution (qualified + in
ctor-delegation), identity-aware `is`/subtype/overload across package name
collisions, and interface-inherited member-extensions via a `with` receiver (the
`Density.toPx()` unblocker). The graphics/DrawScope layer drove more: a class ctor
beating a same-named defaulted factory on one positional arg (`CornerRadius(8f)`);
companion members in primary-ctor default values (`Stroke(width = …)`); named-call
member-overload scoring (`drawRoundRect(Color, …, cornerRadius = X)` bound the
brush overload); a package-qualified `object` reference resolving to the class not
the singleton (`…drawscope.Fill`); and a receiver-lambda argument that is not the
trailing arg of a multi-arg call losing its receiver context (`withTransform`'s
transform block → `DrawScope.rotate`/`scale`/`clipRect` stack overflow), fixed by
recording each lambda argument's expected arity by span at the call-lowering entry.
See git history and the `klio-compose-graphics-stack` memory for specifics.

## Next work

### 1. Skia-backed `compose.ui.graphics` — DONE

The full drawing API is vendored as klioMain actuals over the `src/compose_ui`
shim: `Path` → `Paint` → `Canvas` → `DrawScope` → `Shape`/`Outline` → `Brush`.
A real upstream `DrawScope` block rasterizes to a PNG through `KlioCanvas`
(`klioRenderToPng`): rect/circle/roundRect/oval/path/line/arc, fill + stroke,
`clipRect`/`clipPath`, the `rotate`/`scale`/`translate`/`clipRect`/`withTransform`
transform helpers, `Shape.createOutline`, `SolidColor` + **linear/radial gradient
brushes** (real `SkShaders` via the `__skia_c_set_shader` intrinsic). Deferred:
sweep/image/composite shaders, `ImageBitmap`, colourspace conversion. Examples:
`compose_{canvas,drawscope,shape,brush,gradient}.kt`.

The earlier per-`Path`/`Paint` notes are folded into the above.

- **`Path` — done.** A pure-Kotlin command buffer (`KlioPath`): build ops,
  `getBounds`, `isEmpty`/`isConvex`, `translate`, `addPath`, `PathIterator`; higher-
  level shapes decompose to cubics on add. `Path.op` (union/intersect/difference/
  xor) runs through the shim's `SkPathOps` via the `__skia_path_op` intrinsic.
  Examples: `compose_path.kt`, `compose_pathop.kt`.
- **`Paint` — done.** A plain value object (`KlioPaint`): fill/stroke, colour,
  stroke width/cap/join/miter, blend mode, alpha, AA, filter quality. The shader /
  colour-filter / path-effect / `ImageBitmap` factories throw pending (they need
  the shim's shader/filter/bitmap surface); the slots resolve and default to null.
  Example: `compose_paint.kt`.
- **`Canvas` + `DrawScope` — next.** A `Canvas` actual over a `KlioSurface` that
  draws through the shim (extend it with an `SkCanvas` transform/clip/`drawPath`
  surface + a graphics-namespace draw intrinsic, the same wiring `Path.op` uses),
  then vendor `graphics.drawscope.{DrawScope,CanvasDrawScope,DrawContext,
  DrawTransform}` so a real upstream `DrawScope` block rasterizes to a PNG. Then
  the deferred shader/filter/bitmap actuals. `Shape`/`Outline` sit just above
  (`Outline.Generic` needs `Path`), unblocking `RoundedCornerShape` etc.

### 2. Real `androidx.compose.ui` engine — running through measure/layout into draw

The klio Owner + render tier is built (`klio-compose-ui-core/klioMain`:
`KlioComposeHost.kt` — `KlioComposeOwner` over the vendored `MeasureAndLayoutDelegate`,
a direct-draw `KlioOwnedLayer`, the platform CompositionLocals provider, minimal
platform services, and a `renderComposeToPng` headless entry). The runtime gained
`CompositionLocalMap` + `Composer.currentCompositionLocalMap` (so `Layout` can store
resolved locals on a node), a headless `SnapshotStateObserver`, and vendored
`MutableVector`. The pointer value classes are ported from skikoMain.

**§2 is DONE end-to-end.** `renderComposeToPng` runs the full real engine:
compose → Owner + root `LayoutNode` → measure → layout → placement → draw →
Skia PNG. Verified by decoding pixels: the Box `drawBehind` render is an exact
100×100 red block, and the FULL material3 scene (`MaterialTheme { Surface {
Column { Text, Button { Text } } } }`) renders with the M3 surface tone
`#FEF7FF`, the primary `#6750A4` button, and real `#1D1B20` glyphs
(commits `01f0e90d`, `080c08de`). The measure/placement/draw phases drove a
dozen general interpreter fixes — dispatch walks no longer re-run failed
bodies (the double-measure root), SAM/anon-object member-extension receivers,
argument-type-aware inline-splice picks, spliced bodies resolving in their
donor file's package, owner seeding for named member-extension calls, strict
`where`-bound checks, named-arg class delegation, and parser support for the
annotated function-type/setter forms material3 uses. material-ripple is
vendored as its own pack (material3 depends on it).

Earlier general fixes from the measure bring-up:
- a nested-class value loaded by id resolved the ENCLOSING class's companion (an enum
  nested in a class, `LayoutNode.LayoutState.Idle`, became `LayoutNode.Companion.Idle`)
  — `lookupGlobalById` now takes the class's OWN companion via `classDirectChild`, not
  the chain-walking `classIdNestedIn`;
- an imported nested-enum entry (`import Outer.State.Idle`) kept its intermediate
  classifier segment instead of collapsing to `Outer.Idle`.

**Resolved blocker** (fixed en route; kept for the record):
the abstract base class `NodeCoordinator` is present in the ui-core `include` and its
methods load + dispatch, but its `ClassDef` is DROPPED from the baked pack's module
class table (its two concrete subclasses `InnerNodeCoordinator` /
`LayoutModifierNodeCoordinator` are present). So constructing an `InnerNodeCoordinator`
cannot resolve its parent (`classDefByName("NodeCoordinator")` misses everywhere), the
body-property init chain is just `[InnerNodeCoordinator]`, and `NodeCoordinator`'s
stored fields (`layer`, `wrapped`, …) never materialize — a `Vm::get_field layer on
InnerNodeCoordinator` at draw. The likely cause is the pre-built pack's pruning
dropping an `internal abstract` class that is only referenced as a supertype within
the pack (a small hand-written repro of `internal abstract` + subclass instantiation
does NOT reproduce, so it is specific to the supertype-only + pack-build-prune case).
A defensive `parentDefForInit` (resolve a null-linked parent by name at construction)
is in place but cannot help while the class is entirely absent from the table.

The ~240-file engine (sparse-checkout expanded: `compose/ui/ui/src/commonMain`):
`LayoutNode`, the `Modifier.Node` chain, measure/layout/draw, `Constraints`
(already in the unit pack) / `Placeable`, pointer input, focus, semantics. 81
`expect` decls across 38 files need klio actuals — most are platform primitives
(`Synchronization`, `AtomicReference`/`AtomicInt`, `IdentityHashCode`,
`WeakReference`, `SortedSet` — trivial single-threaded actuals); the rest are
integrations (pointer/key input → SDL, clipboard, text input, popup/dialog) that
can start stubbed.

**Render integration is settled and small**: `NodeCoordinator.draw(canvas:
Canvas, …)` draws through the exact `androidx.compose.ui.graphics.Canvas` already
vendored — `KlioCanvas` is its actual. So the path is `Owner.measureAndLayout →
root LayoutNode → NodeCoordinator.draw(KlioCanvas)` onto a `KlioSurface`. The work
is: vendor the node + layout packages, provide the platform-primitive actuals, and
supply a klio `Owner` actual that hosts the root `LayoutNode`, runs the
measure/layout passes, and draws via the Canvas. Deeply interconnected (even
`Modifier` references `Modifier.Node` → the node package), so it lands as a
coherent tier, not tiny slices. The klio-authored ui-core documents the shapes the
real engine needs and is retired as the real API lands. Converge the public
entrypoints on upstream (`androidx.compose.ui.window.Window`, `application { }`)
so desktop Compose programs are source-compatible.

### 3. foundation → material3

**API surface + MaterialTheme theming — DONE.** The real
`androidx.compose.material3` pack (over ui-text, foundation, foundation-layout,
graphics-shapes) builds `lightColorScheme`/`darkColorScheme`/`Typography` (real
token font sizes)/`Shapes`/`ColorScheme.copy`, and `MaterialTheme(colorScheme=…,
typography=…) { … }` runs inside a `Composition`: it provides the theme through
its `CompositionLocal`s and reading `MaterialTheme.colorScheme`/`typography`/
`shapes` inside content returns the provided values, including a nested
`MaterialTheme` that overrides its subtree and restores the outer theme.
`example: compose_material3.kt`. The two ui-text init/resolution bugs noted below
are cleared (the whole stack loads + runs). Rendering actual COMPONENTS is **DONE**:
`Text`/`Surface`/`Button` render through the real engine with correct M3
theming (see §2). The remaining component work is interactivity (pointer
input + ripple animation in a live window) and the wider component sweep
(scroll, gesture, `Lazy*` on subcomposition, Image).

**Interactivity (WIP):** the real-engine window/scene tier exists —
`androidx.compose.ui.window.runComposeWindow` (native window, frames drawn
by the Owner straight onto the window surface via
`__composeui_winSurface`/`winPresent`/`winClear`) and `KlioComposeScene`
(headless ImageComposeScene analogue with synthetic `click`/`hover` through
`PointerInputEventProcessor`; klio actuals for `PointerInputEvent` +
`InternalPointerEvent`). **The synthetic click DELIVERS for foundation AND
material3**: `Box(Modifier.clickable { ... })` and a full
`MaterialTheme > Surface > Column > Button(onClick)` scene both observe
their onClick for every in-bounds `scene.click`, with the recomposed
count label pixel-verified. The material3 chain needed five roots, all
general-interpreter: (1) a reified inline fn whose trailing lambda
under-declares the fn-typed param's arity refused to splice even when
another argument (a `NodeKind<T>`) binds `T`, so the runtime saw an
erased always-true `is T` and dispatched `onRemeasured` on
`ClickableNode`; nested reified inline calls now also solve `T`
lexically from enclosing-splice parameter types (`splice_param_tys`).
(2) `instanceOfClassName` walked superclasses only — interface-typed
ctor params rejected implementations (`TweenSpec` for
`AnimationSpec<T>`), disqualifying the vectorizing secondary ctor;
interface chains now count, and a confirmed subtype scores as positive
ctor-overload evidence. (3) An unimported foreign pack's top-level fn
could capture a bare call (`kotlin.math.max` under `import kotlin.math.*`
resolving to `androidx.compose.ui.unit.max(Dp, Dp)`): the symbol index
no longer *resolves* a unique candidate at the invisible tier, the
applicability ladder and the runtime overload re-pick rank invisible
candidates last, and the runtime bare-name global falls through to the
intrinsic when the flat pick is out of scope at the reference site.
(4) A fun-interface value that arrives as a RAW closure now dispatches:
implicit SAM conversion wraps callable ctor args whose declared param
type is a fun interface (the explicit `Iface { }` path already did),
and the CMG walk serves a bare name that misses on a callable candidate
by invoking it as the interface's single abstract method — with the
next implicit receiver out handed as `this` for member-extension SAMs
(`MeasurePolicy`'s `MeasureScope.measure`, `PointerInputEventHandler`'s
`PointerInputScope.invoke`). (5) `probeCoroutineCreated` actuals.
Raw `Layout(content, modifier) { measure }` + `Modifier.pointerInput`
in USER source delivers END-TO-END: measure runs, the pointer coroutine
starts once, `awaitPointerEventScope` receives events, and the user
handler fires (scene_click HIT). Desktop-style entrypoints landed:
`application { Window(onCloseRequest = ::exitApplication) { … } }` in
`androidx.compose.ui.window` drives `runComposeWindow` — a native SDL2
window rendered by the real engine with clicks through
`PointerInputEventProcessor`; headless it reports `opened=false`
cleanly (examples/compose_window.kt, deterministic in both
environments). Multi-window and recomposition-driven
window parameters are DONE: `application {}` is a real composition (its
block is `@Composable ApplicationScope.() -> Unit`), `Window(...)` is a
composable managing its native window's lifecycle — state-gated windows
open and close with recomposition, and title/size changes on a live
window apply through `__composeui_winSetTitle`/`__composeui_winSetSize`.
The SDL backend routes events per window (the global queue parks foreign
events on the owning window) and ref-counts the VIDEO subsystem across
closes. The loop drives `Recomposer.pumpFrame()` — a synchronous frame
pump (frame-clock fan-out + recompose) — so effect-driven state repaints
windows without input. LaunchedEffect bodies now run AFTER the pass
applies (the Compose contract; the eager launch ran them mid-composition),
which surfaced and fixed two interpreter roots: the runtime→eval error
map dropped `.LabeledReturn` at host-intrinsic boundaries (`return@fn`
inside kotlinx `synchronized` blocks), and same-name PLAIN inline picks
now re-rank by call-site scope tier (seven `synchronized` actuals made
registration order flaky). examples/compose_multiwindow.kt verifies the
live retitle, the state-driven window close, and exit. Two follow-up roots landed: (a) the
`launch(start = UNDISPATCHED)` body ran twice-or-more because three
runtime arms treated ANY bare name missing on a callable receiver as
that callable's SAM method — `probeCoroutineResumed(completion)` inside
`startCoroutineUndispatched` (whose implicit `this` IS the coroutine
block) invoked the block itself; all three arms now require the
callable's declared arity to match AND no top-level non-extension
function to serve the name (`invoke` stays lenient). (b) a bare
`fastForEach { }` inside `List.fastFirstOrNull` spliced the WRONG
overload — `SlotIdsSet`'s member (whose body reads its own `set`
field) — because a member-inline pick with no enclosing class was never
receiver-checked; the bare-inline target correction now consults the
receiver chain when there is no owner class and swaps in the extension
whose declared receiver is on the chain. The extension-fallback ladder
also stops ranking candidates whose surplus parameters lack defaults
(trailing-callable-aware), which had let the 3-user-param
`startCoroutineUninterceptedOrReturn` variant steal a 2-arg call. The
label-this raise on that path is fixed (class-DELEGATION thunks run
with the under-construction instance as an enclosing receiver, and the
labeled-this walk follows each enclosing entry's OUTER links).
Explicit-receiver member-inline reified calls work in all shapes:
explicit `<T>` splices with the owner scope active; inference-bound
calls emit a typed member dispatch whose stamped type-argument names
bind as globals around the normal member walk; and callable references
inside member extensions bind the DISPATCH owner (`::requestFocus` in
`SemanticsPropertyReceiver.applySemantics()`), with enclosing members
shadowing global `::name` forms. PUBLIC
cross-package top-level name collisions (`internal` ones now lift
mangled with a package-scoped rename channel) wait on the symbol index
and import channels resolving renamed classifiers
(resolution-unification). Also
open: a `@Composable` trailing CONSTRUCTOR lambda misbinds the ctor's
other args (plain lambdas fine; `KlioComposeScene` uses `setContent`
instead).

`compose.foundation` (Box/Row/Column/Text/Image, scroll, gesture, `Lazy*` on
subcomposition), then `compose.material3` (mostly verbatim on foundation).

Dependency chain (surveyed from foundation's imports; sparse-checkout expanded to
`compose/foundation/foundation/src/commonMain` — 342 files, 67 expects): foundation
needs two modules on top of the ui engine. **`androidx.compose.animation.core`**
(120 refs; pure-Kotlin animation math) is **DONE** — vendored as
`klio-compose-animation-core` (36 files; Easing/CubicBezier/AnimationSpec/ArcSpline;
klioMain actuals for atomics, current-thread, binarySearch, the cancellation base;
needed `ui-graphics/Bezier.kt` added). Still needed: **`androidx.compose.ui.text`**
(341 refs; needs the shim's text-shaping actuals). So the remaining order is
**ui-text → foundation → material3**. foundation's `androidx.compose.ui.*` needs
(node/input/layout/platform/semantics) are satisfied by the vendored ui-core
engine; unit/graphics/geometry/util/animation-core by their packs.

A general resolution bug this tier surfaced and fixed (`0acc0805`): a class
resolved to a *same-simple-named* class's companion (`companion_singletons` is
keyed by simple name), so a top-level enum shared its name with a nested
companion-bearing value class in another pack and lost its identity. Now a class
forwards to a companion only when it declares one. This unblocked the whole
ui + animation-core + graphics + unit pack set coexisting.

**ui-text status (`14b2d86c`, WIP):** the 81-file model+styling module is vendored
and BUILDS, but unlike ui-core/animation-core its core types need their platform
actuals to even initialize — `AnnotatedString.Companion` reads `AnnotatedStringSaver`
at init, which builds on the expect Savers (`LineBreak`/`TextMotion`/
`PlatformParagraphStyle`.Companion.Saver), so a program using `AnnotatedString`
throws `FileFailedToInitializeException` until those land (diagnosed via
`KLIO_INIT_DEBUG=1`). Remaining ui-text actual layer, in dependency order:
1. **Style value classes** — `LineBreak` (value class over a packed `Int` mask;
   Simple/Heading/Paragraph/Unspecified — use the real bit layout, not sentinels),
   `TextMotion` (Static/Animated), the `PlatformTextStyle` family
   (`PlatformParagraphStyle`/`PlatformSpanStyle` + `createPlatformTextStyle` + the
   two `lerp`s + `.Default`/`merge`).
2. **The three Savers** (`runtime.saveable.Saver<T, Any>` round-trips) — no-op-safe
   for klio (no state restoration) but must construct.
3. **Locale/text-break/string** — `Locale`/`PlatformLocale`, `PlatformString`,
   `CharHelpers.find{Preceding,Following}Break`, `GapBuffer.toCharArray` (simple).
4. **Font resolution** — `createFontFamilyResolver`, `FontSynthesis.synthesizeTypeface`,
   `PlatformFontFamilyTypefaceAdapter` (stub to the bundled font initially).
5. **Text shaping/measure/draw** — `ActualParagraph` (×3) + `MultiParagraph.
   drawMultiParagraph` over the Skia Paragraph shim (`src/compose_ui`, which already
   does SkFont wrap + Paragraph). This is the substantive part; the rest is plumbing.
Then foundation → material3.

**ui-text FUNCTIONAL end to end** (2026-07-12): both blocking interpreter bugs
above resolved by intervening core work (companion init cascade + multi-import
overloads); the styling model (AnnotatedString spans, TextStyle merge),
Paragraph/TextMeasurer measurement (real shaping/wrap off the shim's font
metrics under a Skia backend; deterministic stubs headless), and
TextPainter.paint all run through the REAL pack. Landed with it:

- **ImageBitmap over an offscreen Skia surface** (`KlioImageBitmap` +
  `ActualCanvas(image)`; `Canvas.drawImage`/`drawImageRect` blit via surface
  snapshots; `readPixels` through the `__skia_surf_pixel` intrinsic) — so
  `TextPainter.paint(Canvas(ImageBitmap(w,h)), result)` renders standalone
  and `toPixelMap()` verifies pixels.
- **Styled span painting**: `KlioParagraph` splits each laid-out line at
  SpanStyle boundaries and paints runs with per-span color, synthetic
  bold/italic, and underline/strikethrough (`klioDrawTextRun2` /
  `klio_skia_c_draw_text2`; advances match the plain run so mixed-style
  lines lay out off one measurement). Per-span fontSize/typeface still
  follow the paragraph style — full multi-size shaping arrives with the
  skparagraph adoption below.
- **Named-argument overload correctness** (general interpreter fixes the
  pack surfaced): `callFuncTypedInner` re-picks NAME-AWARE when the call
  carries named args (the positional cache re-pick was overriding eval's
  correct named pick — `ParagraphIntrinsics(annotations = …)` bound the
  deprecated `spanStyles` overload and silently defaulted it), and
  `callNamedOverload` attaches arg names to its applicability shapes so
  an overload lacking a supplied name is inapplicable.
- ui-text + runtime-saveable joined the parity/e2e pack dirs;
  `examples/compose_uitext.kt` exercises the surface deterministically in
  both headless and Skia environments.

**Remaining ui-text depth (deferred, next milestone = skparagraph):** the shim
draws with one bundled Latin typeface; per-span fontSize, real font families,
FontSynthesis, bidi, and cursor/selection geometry over styled runs want the
linked-but-unused skparagraph (`ParagraphBuilder` with styled runs replacing
the manual SkFont wrap). That is the substantive text-engine upgrade; the
current engine is faithful for single-size styled text.

Vendor per module (one pack each; expand the sparse checkout via
`scripts/init-compose-submodule.sh`), klioMain supplying only platform actuals.
Each module's pack builds with unimplemented actuals throwing at runtime (the
graphics/ui-core pattern), so the API surface lands incrementally; end-to-end
rendering follows the ui-engine Owner/render driver (§2).

### Operational note — rebuild packs after a binary change

A pack IMAGE is only consistent with the interpreter binary it was built against.
After changing the interpreter, rebuild every pack you have installed
(`klio pack build <dir>` + `klio pack install`); a stale image can misresolve
(it read as a spurious cross-pack enum shadow until the ui-core pack was rebuilt).

## Deferred / open

- **Colorspace conversion** (`convert`/`compositeOver`) — deferred (advanced path;
  construction + luminance work). Real blocker is a companion-function-body
  overload-dispatch gap in the `Connectors`/`adapt`/`isSrgb` chain, not minimally
  reproducible yet. Details in the `compose-graphics-color-vendored` memory.
- **macOS window hardening (remaining):** display-change / backing-scale on monitor
  move (`viewDidChangeBackingProperties`); input completeness (modifiers, key repeat,
  scroll, right-click, IME); color-space tagging (sRGB/P3 vs DeviceRGB).
- **Perf backlog (impact order):** slim custom Skia build (the +112 MB compose
  memory is Skia's fixed macOS framework working set, not klio) → lazy stdlib load
  (baseline ~38 MB) → shrink the evaluator per-call frame → drop the per-frame
  display-list serialize/parse round-trip. Zero-code lever: ship ReleaseFast (~2×
  smaller than Debug). Idle CPU (~0.3%) and the resize "leak" (proven bounded/
  GC-managed) need no action. See the `klio-perf-memory-review` memory.
- **Pack-image companion-`val` import aliasing — FIXED** (`01f0e90d`,
  `2b98f72d`): the flattened-global read falls back to the owner class's
  member, and a named companion-member import outranks a same-named class, so
  `import X.Companion.Y` aliases the SAME instance `X.Y` yields (`===` holds)
  in baked packs.
- **Other backends:** verify Win32 on a Windows host. The Linux window is SDL2
  (raster + on-screen Ganesh GPU over SDL's GL context); the offscreen Ganesh+EGL
  path also remains for headless GPU. The macOS window GPU surface is Metal.
- **SDL notes:** the Linux backend targets SDL2 (in every distro's repos today).
  The on-screen GPU path assembles Skia's **native** (GLX) GL interface — the
  loader-assembled interface crashes in zink's extension enumeration. Only editing
  keys (Backspace/Delete) are mapped from key-downs; printable input comes through
  `SDL_TEXTINPUT`, reported with the X11-style keysyms the interim ui-core expects.
