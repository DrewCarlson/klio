# Compose parity

Every API of Compose Multiplatform 1.12.0's runtime, ui (ui, ui-graphics,
ui-text, ui-geometry, ui-unit, ui-util), foundation and foundation-layout,
animation, and material3 (with material-ripple and graphics-shapes), running
on klio the way the skiko desktop targets run it. Upstream sources are
vendored verbatim wherever klio can run them; a klio actual stands in only
where the upstream one needs the JVM, AWT or a native platform API.

## How parity is measured

1. **Source coverage.** For each module, the upstream files of every source
   set a skiko, non-JVM desktop target compiles (commonMain, nonAndroidMain,
   nonJvmMain, skikoMain, and the java-free desktopMain files) against the
   files the pack includes. The inventory script walks the upstream tree at
   the pinned commit and each pack's `klio.toml`.
2. **Sema census.** `scripts/sema-census.py` over every installed pack: no
   compose site unresolved, unlowered or unbound (`tests/sema-census-open.txt`
   carries none).
3. **Upstream suites.** Each module's upstream test sets as a ratcheted
   census in `src/itests/commontest_support.zig`.
4. **Examples and pixels.** A deterministic example per feature area under
   `examples/`, with pixel checks read back from the rendered frame for
   anything that draws.

## Where the suites stand

| Suite | Upstream set | Passed | Failed | Ratchet |
|-------|--------------|-------:|-------:|---------|
| `compose_ui` | ui-util, ui-geometry, ui-unit, ui-graphics, ui-text, ui commonTest | 452 | 0 | 452 / 0 |
| compose runtime fleet | runtime commonTest + nonEmulatorCommonTest | 1138 | 0 | `scripts/compose-fleet.py` |
| `compose_plugin_commontest` | the same sets, one child per class | 1404 | 0 | 1385 / 5 |
| `compose_animation` | animation-core commonTest | 103 | 4 | 103 / 4 |
| `compose_shapes` | graphics-shapes commonTest | 148 | 0 | 148 / 0 |

The four animation-core failures are sema gaps in upstream Kruth's bodies
(an inherited generic property keeps its supertype's `T` after a smart cast;
a bound's members are not found on `T & Any`), routed to sema. The ratchet
drops to 0 failures when that lands.

Not run yet, and what each needs:

| Upstream set | Files | Needs |
|--------------|------:|-------|
| foundation commonTest | 1 | nothing; lands with the skikoTest suite |
| foundation skikoTest | 84 | the ui-test skiko harness (`runComposeUiTest` over `CanvasLayersComposeScene`) |
| foundation desktopTest | 13 | the harness, then the desktop APIs they test (TooltipArea, context menus, scrollbars) |
| material3 skikoTest | 8 | the harness; test actuals for `calendarLocale`, `getTimeZone`/`setTimeZone` |
| material3 desktopTest | 4 | the harness |
| ui skikoTest | 37 | the harness |
| ui-graphics skikoTest, ui-text skikoTest | 7 + 7 | the org.jetbrains.skia binding layer |

## Order of work

1. **Cheap suites.** animation-core and graphics-shapes commonTest. Done.
2. **material3's platform half.** skikoMain and nonJvmMain verbatim, a
   ui-backhandler pack, `CalendarLocale` and `PlatformDateFormat` over the
   ICU the Skia shim bundles. Done: the 35 unbound natives are gone.
3. **The upstream scene.** RootNodeOwner, OwnedLayerManager,
   GraphicsLayerOwnerLayer, BaseComposeScene, CanvasLayersComposeScene and
   the input and focus handlers from ui's skikoMain, in place of
   KlioComposeHost and KlioScene. Layer alpha, color filter, blend mode,
   render effect and shadows, and hit testing through layer transforms, come
   with it; each property gets a pixel check, and hit testing a test.
4. **The ui-test skiko harness**, then the foundation, material3 and ui
   skikoTest suites, each with its own ratchet.
5. **Desktop and skiko public APIs.** Scrollbars, TooltipArea, ContextMenuArea,
   `Modifier.onClick` and PointerMatcher, `Modifier.onDrag`,
   `Modifier.onPointerEvent`, material3's `Modifier.scrollbar`, ui-graphics'
   PathSvg / PathHitTester / PathGeometry, MeshGradient, `rememberSerializable`.
6. **The org.jetbrains.skia binding layer**, so ui-graphics' and ui-text's
   skikoMain run verbatim in place of KlioCanvas, KlioPath and
   PlatformParagraph. Its API surface and mapping onto libklio_skia go to
   review before it is built.
7. **The long tail.** A host locale service for `Locale.current`, the
   remaining nonJvm actuals taken verbatim, the desktop window API's
   signatures (WindowState, DialogWindow, ...).

## Inventory

Upstream v1.12.0 (f29d2f99) against the packs, desktop-equivalent sets.

| Module | commonMain | skikoMain | nonJvmMain | desktopMain (java-free) |
|--------|-----------:|----------:|-----------:|------------------------:|
| runtime | 188 / 188 | n/a | 6 / 9, nonAndroid 10 / 10 | jvmAndAndroid 3 java-free; klio actuals |
| runtime-saveable | 7 / 9 | n/a | n/a | n/a |
| ui | 241 / 244 | 20 / 92 | 1 / 8 | 79 / 175 |
| ui-graphics | 82 / 82 | 0 / 19 | 1 / 1 | 0 / 7 |
| ui-text | 79 / 79 | 2 / 28 | 4 / 5 | 0 / 15 |
| ui-unit, ui-util, ui-geometry | complete | n/a | complete, ui-unit nonAndroid 2 / 2 | n/a |
| foundation | 354 / 354 | 126 / 127 | 8 / 8 | 26 / 37 |
| foundation-layout | 32 / 32 | 2 / 2 | 1 / 1 | n/a |
| animation, animation-core | complete | n/a | complete, animation nonAndroid 2 / 2 | n/a |
| material3 | 251 / 251 | 97 / 97 | 4 / 4 | 0 / 2 (java.text) |
| material-ripple | 4 / 4 | nonAndroid 1 / 1 | n/a | n/a |
| graphics-shapes | 16 / 16 | n/a | 0 / 1 | jvmMain 1 / 1 |

klio actuals that stay: runtime's thread id, identity hash, weak reference
(strong: the collector has no weak references), locks over atomicfu, the
desktop frame clock and the error logger; animation-core's current-thread
token; ui-util's tracing; ui-text's code-point direction helpers (they ask
skia's ICU through the binding layer). Not in the checkout yet:
runtime-annotation (klio's `Stable`/`Immutable`/lint markers stand in) and
runtime-retain (klio carries only the store interface the ui owner exposes;
the `retain` composables are missing). foundation's desktopMain files left:
TooltipArea, ContextMenuProvider, BasicContextMenuRepresentation and
text/ContextMenu (with the upstream scene); DesktopScrollable,
ClipboardUtils, KeyEventHelpers, TextFieldKeyInput and
TextFieldSelectionState, adapted in klioMain with their AWT calls replaced;
WindowDraggableArea (AWT window dragging).

Public API still missing (beyond the scene internals): ui's
`ImageComposeScene`, `renderComposeScene`, `Modifier.onPointerEvent`,
`PointerButtons`/`PointerKeyboardModifiers` helpers, `MeshGradient*`; the skia
interop (`asComposeCanvas`, `toComposeImageBitmap`, ...); ui-text's
`FontRasterizationSettings`, `PlatformFont`/`SystemFont`/`FontLoader`;
foundation's `Modifier.onClick`, `PointerMatcher`, `Modifier.onDrag`,
`TooltipArea`, `ContextMenuArea`; runtime-saveable's `rememberSerializable`;
runtime-retain's `retain`, `RetainedEffect` and the stores.

## Log

- 2026-09-25: the sparse checkout carries ui-backhandler, ui-test's skikoMain,
  Kruth and the foundation, animation-core, material3, graphics-shapes, ui,
  ui-graphics and ui-text test sets. Parser: a constructor parameter may be
  named by a soft modifier (`actual: Boolean?`), and a receiver may end its
  line before the `.`. The animation-core and graphics-shapes suites run
  through upstream Kruth.
- 2026-09-25: a loaded pack brings the packs its `[deps]` declare (by exact
  library id), so material3's qualified call into ui-backhandler resolves;
  `KLIO_PACK_TRACE` names each pack a run loads. material3's skikoMain and
  nonJvmMain run verbatim with the ui-backhandler pack; `PlatformDateFormat`
  asks ICU (`src/compose_ui/icu_shim.cpp`) for skeleton patterns, weekday
  names, the first day of the week and the hour cycle. The canvas draws with
  the paint's blend mode, and an image with the paint's alpha and blend, so a
  vector icon's cache clears (`BlendMode.Clear`) instead of painting black.
  Nodes' coroutines run in the scene's effect context with its frame clock,
  and a frame runs while an animation awaits it.
- 2026-09-25: a layout or draw that reads state is invalidated when the
  state changes (the owner's snapshot observer runs). foundation's skikoMain
  and nonJvmMain run whole, with the java-free desktopMain files by include:
  the scrollbars, clickable, scrollable, lazy lists and the text selection
  actuals. ui-graphics takes its whole commonMain: `Path.toSvg`/`addSvg`,
  `PathHitTester`, `computeDirection`, `divide` and `reverse`. A klio path
  iterates a closing line the way skiko's does and answers `isConvex` from
  its points with Skia's convexity test; arcs are exact at quarter turns.
- 2026-09-25: ui-util, ui-unit, ui-text, foundation-layout, ui-graphics,
  animation and animation-core take their nonJvmMain and nonAndroidMain
  sets verbatim in place of klio copies. The runtime takes its whole
  commonMain (hot reload, live literals, decoys), its nonJvmMain and
  nonAndroidMain actuals, and the ThreadContextElement-backed tracing context
  and snapshot context element from jvmAndAndroidMain. The runtime's error
  logger writes on standard error as the desktop's does.
- Open, routed to sema: inside `with(painter)`, a private member of the
  receiver captures a name the enclosing class declares, so `Modifier.paint`
  loses its tint and alpha (material3 icons draw untinted).
