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
   compose site unresolved, unlowered or unbound, and none in
   `tests/sema-census-open.txt`. ComposeSceneInputHandler is klioMain's copy
   of the skikoMain file without its import of RootNodeOwner, which only its
   KDoc names and which `klio pack build` rejects as unresolved, until
   RootNodeOwner comes with the upstream scene.
3. **Upstream suites.** Each module's upstream test sets as a ratcheted
   census in `src/itests/commontest_support.zig`.
4. **Examples and pixels.** A deterministic example per feature area under
   `examples/`, with pixel checks read back from the rendered frame for
   anything that draws.
5. **The JVM oracle.** Compose Desktop 1.12.0 itself, resolved from Maven
   Central and Google Maven and run headless through ImageComposeScene: an
   example written against `KlioComposeScene` runs unchanged on it (a
   same-API class over ImageComposeScene stands in), and its output is the
   expected output. Pixel values, text metrics and event sequences are
   compared exactly. `scripts/compose-oracle.py` runs an example on both and
   diffs them; `scripts/compose-oracle-fetch.py` resolves the classpath into
   target/parity-cache. The expected outputs are committed with the
   examples.

## Where the suites stand

| Suite | Upstream set | Passed | Failed | Ratchet |
|-------|--------------|-------:|-------:|---------|
| `compose_ui` | ui-util, ui-geometry, ui-unit, ui-graphics, ui-text, ui commonTest | 452 | 0 | 452 / 0 |
| compose runtime fleet | runtime commonTest + nonEmulatorCommonTest | 1138 | 0 | `scripts/compose-fleet.py` |
| `compose_plugin_commontest` | the same sets, one child per class | 1404 | 0 | 1385 / 5 |
| `compose_animation` | animation-core commonTest | 107 | 0 | 107 / 0 |
| `compose_ui_skiko` | ui-graphics and ui-text skikoTest | 110 | 0 | 110 / 0 |
| `compose_shapes` | graphics-shapes commonTest | 148 | 0 | 148 / 0 |
| `lifecycle_viewmodel` | lifecycle-viewmodel commonTest | 35 | 0 | 35 / 0 |
| `savedstate` | savedstate commonTest (with nonAndroidTest's actuals) | 356 | 0 | 356 / 0 |


Not run yet, and what each needs:

| Upstream set | Files | Needs |
|--------------|------:|-------|
| foundation commonTest | 1 | nothing; lands with the skikoTest suite |
| foundation skikoTest | 84 | the ui-test skiko harness (`runComposeUiTest` over `CanvasLayersComposeScene`) |
| foundation desktopTest | 13 | the harness, then the desktop APIs they test (TooltipArea, context menus, scrollbars) |
| material3 skikoTest | 8 | the harness; test actuals for `calendarLocale`, `getTimeZone`/`setTimeZone` |
| material3 desktopTest | 4 | the harness |
| ui skikoTest | 37 | the harness |
| lifecycle-runtime commonTest | 5 | the Main dispatcher fixes (below): under the desktop's `runLifecycleTest` (runBlocking on Main, the actual in tests/lifecycle_commontest_actuals/runtime) WithLifecycleStateTest.testBlockCancelledWhenInitiallyDestroyed waits forever; with a runTest form 39 of 65 passed |
| lifecycle-viewmodel-savedstate commonTest | 1 | lifecycle-runtime-testing's TestLifecycleOwner (not in the checkout) |

## Handoff: state and open items

State on 2026-09-26, for picking the work up cold.

**Done and green.** The suites above hold their ratchets. Every compose
example with an expected output matches it on macOS (75 of 75, compose_tray
under `KLIO_TRAY_HOST=1`; three interactive or output-less examples are not
compared), and `scripts/compose-ui-gate.sh`
passes 13 of 13. The JVM oracle's last full sweep found 44 headless
examples identical to Compose Desktop 1.12.0. The headless examples added
since (compose_graphics_layer, compose_onclick, compose_locale,
compose_clipboard, compose_foundation_lazy, ...) were checked against the
oracle when they landed and expect the JVM's output; compose_window_input and
compose_window_pointer expect the event sequences Compose Desktop prints for
the same events through ImageComposeScene. The other window examples
(lifetime, modal, transparent, menus, tray) open native windows the headless
oracle cannot, and are checked by frame dumps and scripted input. A fresh
full oracle sweep (`scripts/compose-oracle.py` over every compose example)
has not been run since the 44. The sema census
over the compose, lifecycle, savedstate and skiko packs has no unresolved
site, no unlowered site and no unbound native: material3's natives are all
bound (none remain), and skiko's 981 bind by @ExternalSymbolName. Linux
(aarch64 container) and Windows (cross-linked klio.exe) are in Platforms.

**Open, each with what to run and where it lives.**

1. Done: savedstate's commonTest passes whole (356 / 0). Its 23 failures had
   four causes: a reified `T?` lost its `?`
   (examples/reified_nullable_argument.kt), a type argument took its bound
   before a nested call's literal or list typed it, a reified argument only
   `Nothing` flowed into stayed `Nothing`
   (examples/literal_through_nested_call.kt), and generated serializers
   compared a default against serialize's own `value` parameter and wrote an
   inherited property at its default (examples/serial_encode_defaults.kt).
2. lifecycle-runtime's commonTest as a suite (test roots
   lifecycle/lifecycle-runtime/src/commonTest, extra support Kruth,
   testutils/testutils-lifecycle/src/commonMain and
   tests/lifecycle_commontest_actuals/runtime), now that Dispatchers.Main
   runs on the main thread and Main.immediate knows it
   (tl_main_immediate; examples/lifecycle_registry.kt prints what Compose
   Desktop prints).
3. A program's `[deps]` does not load a pack no import names by id prefix
   (src/cli/pack_cache.zig; with Sema). `org.jetbrains.skia` imports need an
   `org.jetbrains.skiko` import beside them, and `androidx.lifecycle.
   SavedStateHandle` alone selects no pack. Cause, fix and tests are in
   plans/resolved-interpreter.md, open correctness bugs.
4. The upstream scene (item 3). Every library it needs is a pack now:
   androidx.lifecycle (runtime-compose), androidx.savedstate (compose),
   androidx.lifecycle.viewmodel.savedstate, androidx.lifecycle.viewmodel.
   compose. Next: ui's skikoMain PlatformContext with desktopMain's
   DefaultArchitectureComponentsOwner (lifecycle, view model store,
   saved-state registry, enableSavedStateHandles),
   ProvidePlatformCompositionLocals (LocalLifecycleOwner,
   LocalSavedStateRegistryOwner, LocalSaveableStateRegistry,
   HostDefaultProviderImpl), then RootNodeOwner, BaseComposeScene and
   CanvasLayersComposeScene in place of KlioComposeHost and KlioScene
   (kotlin-klio/klio-compose-ui-core/klioMain). ui-core's klio.toml takes the
   two viewmodel packs as deps then; ComposeSceneInputHandler.klio.kt goes
   back to upstream's file once RootNodeOwner is in.
5. Done: the skia binding layer's second half (item 6). ui-graphics and
   ui-text run their skikoMain whole over org.jetbrains.skia (with ui-text's
   nativeMain, and klio actuals only for the locale, the string casing and
   the font resolve interceptor); foundation takes skiko's BreakIterator and
   CharProperties and upstream's DragAndDropSource. klio's own canvas, path,
   path measure, paragraph and graphics layer are gone, with the shim's
   entry points only they used. The ui-graphics and ui-text skikoTest suites
   pass (compose_ui_skiko, 110 / 0). Open: the shaper's run handlers
   (kotlin-klio/klio-skiko/klioMain/org/jetbrains/skia/shaper/
   Shaper.klio.kt) still throw; they need callbacks through src/skiko like
   the Drawable's.
6. lifecycle-viewmodel-savedstate's commonTest needs
   androidx.lifecycle.testing.TestLifecycleOwner (lifecycle-runtime-testing):
   add it as a `runtime-testing` feature of androidx.lifecycle once the
   checkout carries it, then register the suite.
7. Done: the gesture timing divergence. A resume that needs no dispatch now
   runs on the resuming thread, so after two quick taps the next one is a
   single click, as on Compose Desktop; compose_onclick can take
   timeout-driven gestures.
8. Not verified anywhere: running on Windows (the shim's link needs the MSVC
   toolchain the Windows Skia prebuilt is built with), a Wayland session.
9. The long tail in Inventory: foundation's TooltipArea, ContextMenuProvider,
   BasicContextMenuRepresentation, text/ContextMenu; ui's ImageComposeScene,
   renderComposeScene and the skia interop; runtime-retain's `retain`.

**Sparse checkout widenings a future item needs** (for the coordinator to
run; scripts/init-compose-submodule.sh lists the current set):

- `lifecycle/lifecycle-runtime-testing/src/commonMain` (and its nonJvmMain
  or nativeMain actuals, if the module has them): TestLifecycleOwner, for
  lifecycle-viewmodel-savedstate's commonTest (item 6).
- `lifecycle/lifecycle-runtime-compose/src/commonTest` and
  `savedstate/savedstate-compose/src/commonTest`, if upstream has them:
  their suites.
- `compose/ui/ui-test/src/desktopMain`, if the ui-test skiko harness
  (item 4 of Order of work) reaches it.

## Order of work

1. **Cheap suites.** animation-core and graphics-shapes commonTest. Done.
2. **material3's platform half.** skikoMain and nonJvmMain verbatim, a
   ui-backhandler pack, `CalendarLocale` and `PlatformDateFormat` over the
   ICU the Skia shim bundles. Done: the 35 unbound natives are gone.
3. **The upstream scene.** RootNodeOwner, OwnedLayerManager,
   GraphicsLayerOwnerLayer, BaseComposeScene, CanvasLayersComposeScene and
   the input and focus handlers from ui's skikoMain, in place of
   KlioComposeHost and KlioScene. The layers are done: GraphicsLayerOwnerLayer
   and OwnedLayerManager run verbatim over skiko's RenderNode, with every
   graphicsLayer property and hit testing through layer transforms checked
   against Compose Desktop (compose_graphics_layer). The lifecycle library is
   in: one androidx.lifecycle pack, a feature per upstream module (common,
   runtime by default, viewmodel, runtime-compose), commonMain with the
   non-JVM and native actuals verbatim; the runtime's main-thread check is
   the desktop's over klio.Thread. The savedstate library is in too (one
   androidx.savedstate pack: savedstate, the default, and compose), and
   runtime-saveable takes its whole commonMain over it. The lifecycle
   library's viewmodel-savedstate and viewmodel-compose modules are packs of
   their own (savedstate is built on lifecycle-common and they are built on
   savedstate). viewmodel-savedstate's commonTest needs lifecycle-runtime-
   testing's TestLifecycleOwner, which the checkout does not carry. Then the
   PlatformContext's architecture components owner the scene provides.
4. **The ui-test skiko harness**, then the foundation, material3 and ui
   skikoTest suites, each with its own ratchet.
5. **Desktop and skiko public APIs.** Scrollbars, TooltipArea, ContextMenuArea,
   `Modifier.onClick` and PointerMatcher, `Modifier.onDrag`,
   `Modifier.onPointerEvent`, material3's `Modifier.scrollbar`, ui-graphics'
   PathSvg / PathHitTester / PathGeometry, MeshGradient. `rememberSerializable`
   is in.
6. **The org.jetbrains.skia binding layer**, so ui-graphics' and ui-text's
   skikoMain run verbatim. Done. In place: skiko's C glue (all 86 sources of
   nativeJsMain and commonMain's common) builds into the Skia shim from the
   skiko checkout on macOS, Linux and (compiled) Windows; the
   org.jetbrains.skiko pack carries skiko's commonMain verbatim (it resolves
   and lowers whole) with klio actuals for its expects; src/skiko registers a
   host function per native under its C symbol (natives.zig, generated by
   scripts/gen-skiko-natives.py), converting pointers as Longs and arrays
   and strings through native memory, and lowering binds each `external
   fun` to the host function its @ExternalSymbolName names (the census has
   no unbound native left). A program using skia directly (paints, raster
   surfaces, path builders, font managers, text lines) prints what the same
   program prints on the JVM. Skia calls back into
   Kotlin (a Drawable's onDraw and onGetBounds, a PaintFilterCanvas's
   onFilter, skottie's logger) through the callbacks skiko_initCallbacks
   installs, run through the host of the native call that invokes them;
   the shaper's run handlers still throw. ui-graphics and ui-text run their
   skikoMain verbatim over it; a host surface (a window's frame, an icon, a
   menu, an offscreen PNG) is drawn through a skiko Canvas over the
   surface's SkCanvas (klio.skia.wrapCanvas), and a scene's frame renders on
   a raster N32 surface, as ImageComposeScene's does. Managed peers free
   their native objects on close(), or the runtime's native finalizer after
   a collection frees them.
7. **The long tail.** The remaining nonJvm actuals taken verbatim, the
   desktop window API's AWT-bound rest. Dialog modality and window
   transparency are done. `Window(icon)` draws its painter at 192 pixels, as
   the desktop does, and sets it on SDL and Win32 windows; a macOS window
   has no icon of its own. The `window` of a WindowScope is AWT's own window
   and has no klio counterpart.

## Inventory

Upstream v1.12.0 (f29d2f99) against the packs, desktop-equivalent sets.

| Module | commonMain | skikoMain | nonJvmMain | desktopMain (java-free) |
|--------|-----------:|----------:|-----------:|------------------------:|
| runtime | 188 / 188 | n/a | 6 / 9, nonAndroid 10 / 10 | jvmAndAndroid 3 java-free; klio actuals |
| runtime-saveable | 9 / 9 | n/a | n/a | n/a |
| ui | 244 / 244 | 45 / 92 | 8 / 8 | 86 / 175 |
| ui-graphics | 82 / 82 | 19 / 19, skikoExcludingWeb 1 / 1 | 1 / 1 | 0 / 7 |
| ui-text | 79 / 79 | 28 / 28 | 5 / 5, native 6 / 6 | 0 / 15 |
| ui-unit, ui-util, ui-geometry | complete | n/a | complete, ui-unit nonAndroid 2 / 2 | n/a |
| foundation | 354 / 354 | 127 / 127 | 8 / 8 | 27 / 37 |
| foundation-layout | 32 / 32 | 2 / 2 | 1 / 1 | n/a |
| animation, animation-core | complete | n/a | complete, animation nonAndroid 2 / 2 | n/a |
| material3 | 251 / 251 | 97 / 97 | 4 / 4 | 0 / 2 (java.text) |
| material-ripple | 4 / 4 | nonAndroid 1 / 1 | n/a | n/a |
| graphics-shapes | 16 / 16 | n/a | 0 / 1 | jvmMain 1 / 1 |

klio actuals that stay: ui-text's Locale, its right-to-left test and the
string delegate (the native target's are darwinMain's, over Foundation;
klio reads tags and cases as the desktop does, and takes AWT's
right-to-left languages), and the font resolve interceptor; ui-graphics'
byte copy (native's is memcpy); runtime's thread id, identity hash, locks
over atomicfu, the desktop frame clock and the error logger;
animation-core's current-thread token; ui-util's tracing. Not in the checkout yet:
runtime-annotation (klio's `Stable`/`Immutable`/lint markers stand in) and
runtime-retain (klio carries only the store interface the ui owner exposes;
the `retain` composables are missing). foundation's desktopMain files left:
TooltipArea, ContextMenuProvider, BasicContextMenuRepresentation and
text/ContextMenu (with the upstream scene and a Swing-free popup menu);
DesktopScrollable, KeyEventHelpers and TextFieldKeyInput, adapted in
klioMain with their AWT calls replaced; ClipboardUtils, adapted over
klio.datatransfer; WindowDraggableArea (AWT window dragging).

Public API still missing (beyond the scene internals): ui's
`ImageComposeScene`, `renderComposeScene`; foundation's
`TooltipArea`, `ContextMenuArea`;
runtime-retain's `retain`, `RetainedEffect` and the stores.

## Platforms

Everything the compose packs and the Skia shim do runs on macOS, Linux and
Windows: each window, input, clipboard, menu, tray and dialog feature has a
Cocoa, an SDL (with X11 for the tray) and a Win32 backend, and a feature a
platform cannot give says so, as the desktop does (Tray where no system
tray runs on the X display; a MenuBar in a GPU SDL window). skiko's C glue
(RenderNode, the default font manager) builds for all three.

| Platform | Verified by running | Verified by compiling only |
|----------|---------------------|----------------------------|
| macOS arm64 | every compose example (71 of 71 with the tray), the compose-ui gate, the upstream suites, the JVM oracle, skiko's natives through the shim's glue (the skiko module's test) | |
| Linux aarch64 (Debian 12 container, Xvfb) | the compose examples (69 of 70 with skiko's glue in the shim: compose_text_fonts prints FreeType's baselines, 17.312 where CoreText gives 17.312012, and Compose Desktop 1.12.0 prints the same 17.312 in that container), the JVM oracle run in the same container (identical on the 11 font- and pixel-dependent examples it can compile), the drawn menu bar by frame dumps, the XEmbed tray under trayer (icon, menu, action, balloon) and without a tray, skiko's natives through the shim's glue (the skiko module's test), and all 31 packs, org.jetbrains.skiko included, building | the harness is cross-compiled from macOS; the shim is built in the container with g++ |
| Linux x86_64 | | compose_ui and the stdlib (`zigcheck.py --target x86_64-linux-gnu`) |
| Windows x86_64 | | klio.exe with compose_ui and the skiko bindings, compiled and linked by the cross build (`zig build -Dtarget=x86_64-windows-gnu`, over the runtime's platform layer); the shim's own sources and all 86 of skiko's glue sources to objects (`zig c++ -target x86_64-windows-gnu`, C++20). Linking the shim needs the MSVC toolchain the Windows Skia prebuilt is built with |

Not verified anywhere yet: a Wayland session (SDL picks Wayland or X11 at
runtime; the tray is X11's, so under Wayland without XWayland
isTraySupported is false), and running on Windows.

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
- 2026-09-26: the JVM oracle. Checked against Compose Desktop 1.12.0:
  - Graphics layers draw through skiko's RenderNode (vendored in
    src/compose_ui/skiko) under upstream's GraphicsLayerOwnerLayer: alpha,
    scale, translation, the rotations through the camera, the transform
    origin, shape clips, shadows lit as RootNodeOwner lights them, color
    filters, blend modes, blurs and both compositing strategies, and clicks
    through transformed layers.
  - Canvas concats a 4x4 matrix and draws points.
  - Every ui-graphics shader, color filter, path effect and render effect;
    vertices; image decoding; the mesh gradient painter.
  - Modifier.onPointerEvent.
  - Text shapes with the platform's fonts through skiko's generic-family
    aliases and the program's loaded fonts (SystemFont, LoadedFont,
    `Font(identity, data)`).
  - ui's nonJvmMain whole and more skikoMain files verbatim (actuals, locks,
    applier, pointer events, haptic feedback types, rotary events, the text
    input session contract); the host serves text input sessions.
- 2026-09-26: `scripts/compose-oracle.py` runs an example on Compose
  Desktop and on klio and diffs them; 44 of the headless compose examples
  print the same on both. Of the rest, compose_foundation_platform differed
  only by the clipboard (now the desktop's), compose_pathmeasure is open
  below, two stop on the lowering gap below, and the others use klio's own
  UI toolkit or open windows. Paint reads back and
  draws as skiko's SkiaBackedPaint: the alpha shares the color's 8 bits, the
  join and miter limit report Compose's defaults until set while the skia
  paint draws with its own, and a canvas's alpha multiplier folds into the
  color once per draw. Images sample by the paint's filter quality.
- 2026-09-26: scenes take input through skiko's ComposeSceneInputHandler,
  SyntheticEventSender and ComposeScenePointer, verbatim: the tracked button
  and modifier state, the synthetic moves before a press or release, the
  pointer re-sent after a relayout, and the owners' results merged as
  CanvasLayersComposeScene merges them. The owner takes pointer, key and
  rotary input as RootNodeOwner does (Tab and Shift+Tab move focus).
  KlioComposeScene sends pointer and key events with ImageComposeScene's
  signatures, and windows send theirs through the same handler. On macOS a
  key's text is the toolkit's glyph once a scene has opened, as AWT's is.
  The parser takes a when branch whose conditions end with a comma.
- 2026-09-26: a native window's input reaches its content as Compose
  Desktop delivers AWT's. The shim's backends (Cocoa, SDL, Win32) report
  presses and releases of every mouse button with the buttons held, moves,
  drags outside the window, enters and exits, wheel scrolls, key presses and
  releases numbered by AWT's key codes and locations with their modifiers,
  typed text, and focus; the window sends them through its scene's input
  handler, typed characters as key events whose platform event marks them
  typed, which foundation's `isTypedEvent` reads. A window's compositions
  run on the window loop's dispatcher, a Delay whose timers the loop fires,
  as a desktop window's run on the AWT event thread; a focused text field's
  cursor blinks and typing edits it. Scenes provide ui's own common
  composition locals (the software keyboard controller, text input service,
  pointer icon service, retained values store and locale list among them),
  and ui-text has skiko's deprecated `FontLoader`. `KLIO_WIN_INPUT` scripts
  a window's input and `KLIO_SKIA_DUMP_AT` picks the frame to dump, so
  compose_window_input checks the whole path; its sequence is the one
  Compose Desktop prints for the same events through ImageComposeScene.
  The stdlib's `contentEquals` and StringBuilder's range appends and
  inserts read a program's own CharSequence, which TextFieldState's buffer
  is.
- 2026-09-26: Compose Desktop's window API with desktop's signatures:
  `application(exitProcessOnExit)`, `awaitApplication`, `launchApplication`,
  `Window` and `DialogWindow` (both overloads each), `singleWindowApplication`,
  the window scopes, and desktop's java-free WindowState, DialogState,
  WindowPlacement, WindowSize, WindowDecoration and menu marker verbatim
  (WindowPosition and Notification adapted: their equals read javaClass).
  An application runs until its content is gone and its effects end, as
  desktop's does; a window is created and its content set when the
  composition applies, composes as a child of where it is called, and syncs
  its state both ways as desktop's listeners do (frame size, position,
  placement, minimized). The close button asks, it does not close. The
  shim's backends set resizable, decoration, always-on-top, visibility,
  placement, minimized, position and frame size, and report moves and
  placement changes. A window's onPreviewKeyEvent and onKeyEvent wrap its
  content's key handling; a disabled window takes no input, an unfocusable
  one no keys. klio's own `application(maxFrames)`, `ApplicationScope.Window
  (width, height)` and `runComposeWindow` are gone; the examples and the
  iOS scenes use desktop's API.
- 2026-09-26: a window's input handlers run before its next event: the
  scene flushes its compositions' dispatcher after each input event, as
  BaseComposeScene flushes its FrameRecomposer's trampoline, so a drag
  resumed by a press sees the moves after it. `Modifier.onClick` with a
  PointerMatcher (buttons, double clicks) and `Modifier.onDrag` work in
  windows, where huge delays are the loop's timers; compose_window_pointer
  checks them against Compose Desktop. Scripted input can be timed
  (`<t>ms`).
- 2026-09-26: the clipboard is Compose Desktop's. `klio.datatransfer` has
  the java.awt.datatransfer types the desktop's clipboard is written against
  (DataFlavor with stringFlavor, Transferable, ClipboardOwner,
  StringSelection, UnsupportedFlavorException, Clipboard), and its system
  clipboard is the host's through the Skia shim (NSPasteboard, UIPasteboard,
  the Win32 clipboard, SDL's): while no other application changes it, the
  transferable a program put there is the one it reads back, and once one
  does, the owner is told and the contents are the host's text. ui's
  PlatformClipboard and foundation's ClipboardUtils are the desktop's over
  it, TextFieldSelectionState.desktop.kt runs verbatim, and the owner takes
  its clipboards from the platform factories. `KLIO_CLIPBOARD` picks the
  host's, a private one (the test runners use it, so a run never touches
  the user's) or none (a headless desktop's; the oracle runs klio so, as its
  JVM is headless). compose_clipboard and compose_window_clipboard (Select
  All, Copy, Paste and Cut in a window's text fields) check it; a
  ClipEntry of a plain AnnotatedString empties the clipboard, as on the
  desktop, so compose_foundation_platform prints what Compose Desktop does.
  The deprecated `Modifier.pointerMoveFilter` is desktopMain's.
- 2026-09-26: Compose's Locale is the desktop's. A language tag reads as
  the JVM's `Locale.forLanguageTag` reads it, and `Locale.current` is the
  host's as the JVM's default is (macOS: the first preferred language with
  the current region, through the Skia shim; Windows: the user's UI
  language; elsewhere LC_ALL, LC_MESSAGES or LANG); `KLIO_LOCALE` sets it,
  and the test runners pin en-US. ui-text's string delegate cases for a
  locale as the JVM does (Turkish and Azerbaijani i, Lithuanian dot above),
  and the stdlib's `uppercase()` and `lowercase()` take SpecialCasing's
  expansions (ŉ, ǰ, և) and the final sigma, as the JVM's root casing does.
  compose_locale checks them against Compose Desktop.
- 2026-09-26: `FrameWindowScope.MenuBar` with the desktop's MenuBarScope
  and MenuScope (Menu, Separator, Item, CheckboxItem, RadioButtonItem with
  icons, mnemonics and KeyShortcut). The menus compose into a tree the Skia
  shim makes native: on macOS the application's main menu while the window
  is key, as the desktop's screen menu bar is, on Win32 the window's menu
  bar (mnemonics marked, shortcuts shown). A check box or radio button item
  keeps the state its composition gives it and a click calls back, as the
  desktop's ComposeState makes Swing's items behave; shortcuts match as a
  menu bar's accelerators, after the content leaves the key (on macOS
  whatever the content did). Scripted input chooses items by path through
  the native menus (`menu File/Open`) and `KLIO_MENU_DUMP` prints them;
  compose_window_menu checks it. Window(icon) is drawn and set on SDL and
  Win32 windows.
- 2026-09-26: `ApplicationScope.Tray` with the desktop's TrayState,
  rememberTrayState and isTraySupported. The tray is the platform's own: a
  status item in the macOS menu bar (a left click shows the menu, a right
  click is the action, as the desktop's macOS tray has them), a Windows
  notification area icon (a right click shows the menu, a double click is
  the action); its menu is the desktop's AWT popup menu, which takes no
  icons, mnemonics, shortcuts or radio button items and says so as the
  desktop's does, and a notification shows as the platform's (none for a
  macOS process without an application bundle, as the desktop's). With only
  trays open the application loop runs the platform's events. SDL hosts
  have no tray: Tray says so on standard error, as the desktop's does.
  compose_tray checks it (`corpus: tray`).
- 2026-09-26: with sema resolving a setter deferred while another
  declaration was typed (the draw context's setters, 231b2e70), the
  graphics layer examples, LazyColumn, material3 text and the windows run
  again; compose_foundation_lazy's expected output is Compose Desktop's
  (eight rows fit). A move the program makes is recorded as reported, so
  the window's first report (or a late one of an earlier move) no longer
  sets a WindowState position the program has since changed back to the
  old one; compose_window_state checks the state both ways, a DialogWindow
  and the window key callbacks.
- 2026-09-26: Linux. An SDL window draws its MenuBar as Swing draws the
  desktop's there: a bar above the content (which gives up its height), a
  panel per open menu with check marks, radio dots, icons, shortcuts and
  submenus (flipped left of their parent where the right has no room), the
  mouse and the keys (F10, Alt with a mnemonic, the arrows) while one is
  open; `menushow` in a script leaves them open for frame dumps. On X11 a
  Tray docks in the system tray over the XEmbed tray protocol, as AWT's X11
  SystemTray does: a 24-pixel icon window with size hints, a popup menu, a
  tooltip and balloon notifications drawn with Skia; with no tray on the
  display isTraySupported is false. The Linux shim did not load at all: it
  is built without RTTI now, as Skia and skiko's glue are, and links
  libstdc++ before the Skia archives so a weak copy of a libstdc++ function
  no longer pulls in the GL backend. A shim that is there but does not load
  says why. The default font manager is skiko's own FontMgrDefaultFactory
  (CoreText, DirectWrite, fontconfig), so Linux and Windows lay out default
  text in the platform's sans-serif as the desktop does, where they had
  used the bundled monospace face. A Window applies its properties through
  desktop's UpdateEffect, whose effect keeps the application running while
  the window is open: a window with no effects of its own no longer ended
  the application after its first frame (compose_window_lifetime). The
  oracle takes skiko's runtime for its host, so it runs in the Linux
  container too; `zigcheck.py --target` compiles a module for another
  target. The Platforms section records what runs where.
- 2026-09-26: a DialogWindow is modal, as the desktop's are: a
  document-modal dialog blocks the windows of its document (the windows
  under its top-level window, its own descendants excepted) and an
  application-modal one every window, as AWT's modality types do. A blocked
  window drops its pointer, key, text and menu input, and a press or focus on
  it brings the dialog forward (a new window flag each backend raises by). It
  is the application loop's, so the three backends block alike;
  compose_window_modal and compose_window_modal_app check it with a window of
  another document beside. DialogModalityType has 1.12.0's three types. A
  window that cannot open throws, saying why, as AWT's HeadlessException.
- 2026-09-26: a transparent Window has no background, as the desktop's: its
  frame starts clear and the window composites its alpha (macOS: a
  non-opaque window and layers over a clear background; Windows: a layered
  window presented with UpdateLayeredWindow). SDL2 windows have no
  per-pixel transparency, and the shim says so. Checked by frame dump (the
  frame's corners alpha 0 around an opaque disc, compose_window_transparent);
  the see-through compositing itself is the platforms', not screen-captured.
- 2026-09-26: with the coroutine runtime's Unconfined fixes, foundation's
  desktop `Modifier.onClick` and PointerMatcher run: compose_onclick (the
  buttons a matcher names, the keyboard modifiers it asks for) is identical
  to Compose Desktop. A focused text field's headless frames return.
- 2026-09-26: the lifecycle library is one androidx.lifecycle pack with a
  feature per upstream module (common; runtime, the default; viewmodel;
  runtime-compose), in place of the lifecycle slice runtime-saveable carried.
  The modules share the androidx.lifecycle package, so an import selects the
  library and `--feature androidx.lifecycle/viewmodel` the module, as with
  kotlinx.coroutines/test. LifecycleRegistry's main-thread check is the
  desktop's MainDispatcherChecker over klio.Thread; ui-core takes
  LocalLifecycleOwner from runtime-compose. lifecycle-viewmodel's commonTest
  is the lifecycle_viewmodel suite. skiko's natives bind by name at
  lowering, and a program drawing with skia directly prints what it prints
  on the JVM.
- 2026-09-26: the savedstate library is one androidx.savedstate pack
  (savedstate, the default, and compose), and runtime-saveable takes its whole
  commonMain over it (rememberSerializable, serializableSaver, the registry's
  bridge to a SavedStateRegistryOwner). lifecycle-viewmodel-savedstate and
  lifecycle-viewmodel-compose ship as packs of their own. savedstate's
  commonTest is the savedstate suite. A local class's `KClass.qualifiedName`
  is null, as Kotlin's is (lifecycle refuses a local class as a ViewModel by
  it), and lifecycle-viewmodel's suite passes whole.
- Resolved by the coroutine runtime: `Dispatchers.Main.immediate` dispatched
  work already running on Main, and `runBlocking(Dispatchers.Main)` from a
  worker ran its block on the worker. examples/lifecycle_registry.kt prints
  what Compose Desktop prints.
- 2026-09-26: ui-graphics and ui-text run their skikoMain whole over
  org.jetbrains.skia, and foundation takes skiko's ICU breaks and upstream's
  drag-and-drop source; klio's canvas, path, path measure, paragraph and
  graphics layer are deleted, with the 69 host functions and the shim entry
  points only they used. The weak references the runtime, ui and lifecycle
  use are upstream's over kotlin.native.ref, and skiko's managed peers free
  their Skia objects through the runtime's native finalizers. The JVM oracle
  finds 53 of the 56 headless compose examples identical (compose_popup's
  placement is printed twice on the JVM, as before; two do not compile for
  the JVM), compose_pathmeasure now prints Compose Desktop's output, and the
  ui-graphics and ui-text skikoTest suites pass (110 / 0).
- Resolved: after two taps too quick for a double click, onClick took the
  next tap as a long click; a resume that needs no dispatch now runs on the
  resuming thread, as on the JVM.
- Resolved: klio's paragraph layer differed from skiko's SkiaParagraph in
  line tops, line height trims, text indent, baseline shift and ellipsis
  flags; ui-text now runs SkiaParagraph itself.
- Resolved: PathMeasure measured klio's own path (arcs as cubics) with a
  Kotlin contour measure; it is skiko's SkContourMeasure over the SkPath now,
  and compose_pathmeasure prints what Compose Desktop prints.
- Open, pre-existing: compose_popup prints its placement lines twice on
  Compose Desktop's ImageComposeScene and once on klio's scene.
