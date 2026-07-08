# UI rendering packs — node emission → Mosaic → Compose UI on Skia

Author role: Compose runtime + UI toolkit architect. Grounded in the live code
(`kotlin-klio/klio-compose-runtime/`, `kotlin-klio/klio-compose-ui/`,
`src/compose_ui/`) and the vendored upstream (`…/klio-compose-runtime/upstream`).

The compose **runtime** (state, recomposition, remember, `key`, effects,
CompositionLocal, `derivedStateOf`, the async Recomposer + frame clock,
`snapshotFlow`/`collectAsState`, `@Composable` content lambdas) is functional and
green. This plan covers what renders UI on top of it.

## Done (recap)

- **N1 node emission** — `Applier<N>`/`AbstractApplier`, composer node ops
  (`startNode`/`createNode`/`useNode`/`endNode`), the synchronous child reconciler,
  `Updater`/`ComposeNode`, `Composition(applier, parent)`. All in the klioMain pack;
  no compose-specific interpreter code. Proof: `examples/compose_nodes.kt`.
- **N2 subcomposition** — `CompositionContext`/`rememberCompositionContext`, child
  compositions reparented to the parent recomposer. `examples/compose_subcompose.kt`.
- **M Mosaic** — vendored mosaic 0.3.0 (submodule), consumed core verbatim, a
  synchronous `mosaicRenderer`. `examples/mosaic_hello.kt`.
- **§5 androidx.collection** — pack vendored + swept, no intrinsic gaps.
  `examples/androidx_collection.kt`.
- **S ui-core (klio-authored, headless software canvas)** — the `klio.compose.ui`
  pack: `LayoutNode` emit → measure/layout/draw, `Modifier` (size/padding/fill/
  background/border/clickable), `PixelCanvas`, a 3×5 bitmap font, `Column`/`Row`/
  `Box`/`Text`/`Button`/`Spacer`/`LazyColumn`, pointer input (hit-test → onClick →
  recompose), `MaterialTheme`/`ColorScheme`/`Card` via CompositionLocal, and a
  native P6 PPM image sink (`src/compose_ui/compose_ui.zig`, kept out of the main
  interpreter). Examples: `compose_ui{,_click,_lazy,_material,_ppm}.kt`.
- **Real `androidx.compose.ui` geometry/unit/util** — `kotlin-klio/klio-compose-ui-graphics`
  consumes the actual upstream ui-geometry/ui-unit/ui-util (Offset/Size/Rect/Dp/
  IntOffset — real inline value classes) verbatim; klioMain supplies only the
  float-bit/round actuals. `examples/compose_ui_geometry.kt`.
- **Resolver fix** — an explicit import now wins over an unimported same-name
  function (`import kotlin.math.max` over an out-of-scope `other.max`).

## Open bugs

1. **Color colorspace static-init fails.** With the real `androidx.compose.ui.graphics`
   Color + colorspace package added to the graphics pack (Color.kt + the 13-file
   colorspace math), any use of `Color` throws `FileFailedToInitializeException` from
   the `ColorSpaces` object init — `Rgb(...)`'s init block (`computeXYZMatrix` /
   `inverse3x3` / `isWideGamut` / `isSrgb`, or the `DoubleFunction` SAM oetf/eotf,
   or secondary-ctor delegation). `Illuminant.D65` inits fine; the failure is inside
   the `Rgb` constructor. The wrapped cause is swallowed (matches kotlin-native) —
   surface it (temporary print at `host_globals.zig` init-failure catch) to find the
   failing op. The graphics pack additions are currently reverted; re-add
   (ui-graphics `[[source]]` + colorspace files + `androidx.annotation` klioMain
   stubs + `androidx.collection` dep) to reproduce.
2. **Pack-image companion-`val` import aliasing.** In a *baked* pack image,
   `import X.Companion.Y` does not alias the class-qualified singleton `X.Y`
   (`===` is false); correct when the pack loads from source. Blocks colour/style
   singleton identity in shipped packs. Repro noted in the mosaic pack.

## Remaining work

### Skia rendering backend (replaces the software rasterizer)

Real Skia is available as self-contained prebuilt static libs — JetBrains skia-pack
(the Skiko build): `Skia-m150-1f14f1166a-linux-Release-x64.zip` (52 MB), from
`https://github.com/JetBrains/skia/releases/tag/m150-1f14f1166a` (also Debug,
arm64, and macos/windows/wasm/android/ios variants). The archive is fully
self-contained:

- `include/` — all Skia headers (`core/`, `effects/`, `encode/`, `gpu/`, `ports/`,
  `svg/`) + `modules/skparagraph`, `modules/skshaper`, `modules/skunicode` headers.
- `out/Release-linux-x64/*.a` — `libskia.a` **plus every dependency bundled**:
  `libskparagraph`, `libskshaper`, `libskunicode_core`/`_icu`, `libfreetype2`,
  `libharfbuzz`, `libicu`, `libpng`, `libjpeg`, `libwebp`, `libexpat`, `libzlib`,
  `libskcms`, `libwuffs`, `libsvg`, `libskottie`, `libskia_ganesh_ext` (GPU, optional).

Because freetype/harfbuzz/icu/png are bundled, CPU raster + PNG encode + real text
shaping all work offline with essentially no system deps (pthread/dl). No GPU
context needed for a headless deterministic backend.

**Decision (2026-07): Skia-only.** The optional software rasterizer (PixelCanvas +
3×5 bitmap font + PPM sink, ~250 lines) is being dropped rather than maintained as a
second draw backend. Skia is the single renderer; deterministic tests come from a
draw-op **display list** (text-dumpable, Skia-independent to assert) plus PNG-bytes
hashes. CI runs `scripts/fetch-skia.sh` once (like the kotlin checkout).

**DONE (build backend wired + proven):**

1. **`scripts/fetch-skia.sh`** — downloads + extracts the pinned `m150-1f14f1166a`
   release for a target os/arch into `third_party/skia/<os>-<arch>/{include,modules,
   out}` (gitignored, per-target so several coexist for cross builds). All 6 desktop
   targets: `{linux,macos,windows}` × `{x64,arm64}`. Defaults to host; override with
   `fetch-skia.sh <os> <arch>` or `KLIO_SKIA_OS`/`KLIO_SKIA_ARCH`. Archives are
   self-contained (`libskia.{a,lib}` + all deps + headers).
2. **`src/compose_ui/skia_shim.cpp`** — the `extern "C"` DrawScope: `klio_skia_new`/
   `_free`/`_clear`/`_fill_rect`/`_stroke_rect`/`_fill_rrect`/`_fill_circle`/
   `_draw_line`/`_draw_text` (SkFont, needs a bundled font — see below) /`_save_png`/
   `_encode_png`. Anti-aliased `SkPaint`, N32-premul raster `SkSurface`. Zig calls
   these via `extern` — no C++ in Zig. Platform-agnostic source (one shim, all OSes).
3. **build.zig** — `buildSkiaShim(target)` builds a self-contained Skia dynamic
   library the compose_ui module dlopens (Skia `.a`/`.lib` are `-fPIC`; dlopen keeps
   the platform C++ runtime out of the zig link). It is **target-aware** — per OS it
   picks the lib dir (`third_party/skia/<os>-<arch>/…`), the C++ driver + ABI, the
   output name, and the link deps:
   - **linux** → `g++` (GNU libstdc++ — the prebuilt Skia uses the OLD string ABI,
     `std::string::_Rep::_S_empty_rep_storage`, which `zig cc`/libc++ cannot link),
     `-Wl,--start-group *.a`, `-lstdc++ -lpthread -ldl -lm`, `libklio_skia.so`.
   - **macOS** → `clang++` (LLVM libc++), `*.a` + `-lc++` + CoreFoundation/CoreGraphics/
     CoreText/Metal/… frameworks, `libklio_skia.dylib`.
   - **windows** → clang++/clang-cl (MSVC ABI), `*.lib` + user32/gdi32/opengl32/…,
     `klio_skia.dll`.
   `-Dskia` ON by default when the target's libs are present; `-Dskia=false` skips.
   `-Dskia-cxx=<compiler>` overrides the C++ driver — the hook for a **cross build**
   (osxcross clang++, a mingw/clang-cl wrapper): fetch the target's libs, pass
   `-Dtarget=<...>` + `-Dskia-cxx=<cross-compiler>`. `zig build` (and `zig build
   skia-lib`) install the lib to `zig-out/lib`. **Verified on linux-x64** (builds +
   dlopens + renders a correct anti-aliased PNG); macOS/windows use the standard
   per-platform recipe but are unverified on this host.

4. **Zig dlopen binding** — DONE. `src/compose_ui/compose_ui.zig` lazily dlopens the
   Skia lib (`KLIO_SKIA_LIB` env → platform lib name via the loader path), resolves
   the `klio_skia_*` symbols, and the `__composeui_skiaRender(path, w, h, list)` host
   intrinsic replays a display list → PNG (returns an FNV-1a checksum). The pack
   exposes `renderDisplayListToPng`. Verified: a Kotlin program renders a correct AA
   PNG through the full stack. `loadSkia` returns null gracefully when absent.

5. **Display list + Skia draw in `klio.compose.ui`** — DONE. The draw pass records a
   `DisplayList` of ops (rect/srect/rrect/circle/line/text, ARGB, real colors);
   `UiRenderer` exposes `displayList(scale)` (the deterministic artifact) and
   `savePng(path, scale)`. `PixelCanvas`, the 3×5 bitmap font, `toAscii`/`toHex`, and
   the `src/compose_ui` PPM sink (`writePpm` + palette) are deleted. Measure/layout
   unchanged.
6. **Font** — DONE. The shim loads a typeface from `$KLIO_SKIA_FONT` or the first
   available system font (Noto/DejaVu/Liberation/macOS/windows paths); `replay()`
   handles the `text` op. Verified: `savePng` produces a PNG with real anti-aliased
   text. (Bundling a `.ttf` for a fontless host, or `skparagraph` for wrapping, later.)
7. **Tests + examples** — DONE. `compose_ui{,_click,_lazy,_material}.kt` print the
   display list (asserted by the corpus, Skia-independent); `compose_ui_png.kt`
   (renamed from `_ppm`) prints the list + calls `savePng`. The corpus was
   regenerated; check_examples/differential/e2e green.

**Windowing — DONE (X11).** A live on-screen window + input loop: the shim
(`skia_shim.cpp`, `-DKLIO_X11` when build.zig finds the X11 headers/lib) opens an X
window and blits the Skia raster surface (N32 premul == X TrueColor BGRX) with
XPutImage; `klio_win_open`/`_surface`/`_present`/`_poll`/`_close`. Zig wraps them as
`__composeui_win{Open,Render,Poll,Close}` host intrinsics; the pack's `runApp(w, h,
scale, title, maxFrames, content)` runs the render → present → poll → dispatch loop.
`examples/compose_ui_window.kt` — verified end-to-end (screenshotted): a real
window renders the UI, and xdotool clicks on the ADD button drive
hit-test → state → recompose → redraw (COUNT increments live). Headless-safe:
`winOpen` returns 0 with no backend, so `runApp` returns immediately (no corpus
output). macOS (Cocoa) / windows (Win32) window backends are the per-OS follow-up.

**Bug this surfaced (compose runtime) — FIXED (`aac66ad3`).** `var x by remember {
mutableStateOf(0) }` inside a `@Composable` did not persist writes across recomposition
— reads showed the initial value forever, because the property-delegate desugaring of a
`remember`ed `MutableState` mis-dispatched `setValue`. Fixed with write-through for a
delegated `var x by D`; `compose_ui_window.kt` now uses the `by remember` form directly.

**Richer input — DONE (X11).** The shim poll now returns key (char + keysym via
XLookupString), pointer-motion, and resize (ConfigureNotify, recreating the surface)
events. The pack adds `Modifier.onKey`/`.onHover`; `HitRegion` carries click/key/
hover handlers; `UiRenderer` gains focus (click a node with `onKey` to focus it;
focus re-resolves from a click anchor after each recompose so it tracks the fresh
handler), `key()`, `hover()` (fires each hoverable's handler with the current
inside-ness → state-driven highlight), and `resize()`; `runApp` dispatches all event
types. A `TextField` composable (click to focus, type, Backspace). Demo:
`examples/compose_ui_input.kt` — verified live (screenshots): typing into the field
updates it + a greeting, the button highlights on hover, and the window resizes +
relayouts.

**Better text — DONE (word-wrap).** A `Paragraph` composable lays out word-wrapped,
multi-line, aligned (left/center/right) text within a fixed width. The shim
(`klio_skia_draw_paragraph` / `klio_skia_measure_paragraph`) greedily wraps with
`SkFont::measureText` and paints line by line; the pack emits a `para` display-list
op and sizes the box via a `__composeui_measureText` intrinsic (real font metrics
when the backend is loaded, else a nominal-advance estimate for headless layout).
Demo/corpus: `examples/compose_ui_text.kt`. (skparagraph proper was tried first but
the prebuilt libs' bundled ICU data ships under a skiko-renamed symbol
`icudt_skiko74_dat` that ICU's loader does not pick up, so full shaping/BiDi is
deferred; SkFont wrapping covers Latin UI text.)

**GPU surface — DONE (opt-in, Ganesh+EGL).** `zig build -Dgpu` compiles the shim
with `-DKLIO_GPU` and links libGL/libEGL; `klio_skia_new_gpu` brings up a
surface-less EGL desktop-GL context, assembles a `GrGLInterface` from
`eglGetProcAddress` (the prebuilt ganesh's native interface is GLX-bound, so we
assemble rather than use `MakeEGL`, which these libs don't ship), and makes a
Ganesh `SkSurfaces::RenderTarget`. PNG save/encode read back GPU→CPU. At runtime
`KLIO_SKIA_GPU=1` selects it; it falls back to raster if unbuilt or if EGL/GL
bring-up fails. Verified end-to-end here (renders + reads back correctly) — but on
this host GL is software (Mesa llvmpipe), so it is a correctness proof of the path,
not a speedup. Default builds stay raster.

**macOS window backend — DONE (Cocoa + Metal GPU, verified on real hardware).**
Commit `674031d8`. `zig build -Dcocoa` builds the Cocoa backend (shim compiled as
Objective-C++); `-Dgpu` additionally compiles the Metal GPU surface (`-DKLIO_METAL`).
The window brings up a `CAMetalLayer`, a Ganesh `GrDirectContext` (Metal), and per
frame wraps the layer's next drawable as a GPU `SkSurface`
(`SkSurfaces::WrapCAMetalLayer`), draws, `flushAndSubmit`s, and presents the drawable
through the Metal command queue — falling back to a CPU-raster `CGImage` present if
Metal bring-up fails. `KLIO_SKIA_VERBOSE=1` logs the active backend
(`window backend: Metal (GPU)` / `raster (CPU)`). Verified live on an M-series Mac:
the counter UI renders on the GPU and the render→present→poll loop runs clean;
`examples/compose_ui_window.kt` now uses the `var count by remember { mutableStateOf(0) }`
delegate form (the write-through bug below was fixed in `aac66ad3`). Three
macOS-specific fixes were needed — none of the Cocoa path had ever compiled: the shim
used `SkFontMgr_New_Custom_Empty`, absent in the macOS Skia pack → `SkFontMgr_New_CoreText`;
build.zig left `-x objective-c++` applying to the linked `.a` archives → reset with
`-x none`; and the structural one — the interpreter ran the VM on a large-stack
*worker* thread, but AppKit windowing and the single-threaded Skia Metal context both
require the process **main thread** (`NSWindow should only be instantiated on the main
thread`). `safety.runOnBigStackMainThread` now switches to a 256 MB mmap'd stack
in-thread (an aarch64/x86_64 asm SP switch) so `klio run` keeps the main thread while
still getting the big stack (macOS only; tests/parity keep the worker thread). Also
needs the `klio.compose.ui` + `androidx.compose.runtime` packs installed.

**Windows (Win32) window backend — WRITTEN (unverified).** The `_WIN32` backend
(`StretchDIBits` blit of the N32 surface, window-proc event queue) is written against
the Win32 API but not compiled/run-verified — a Windows host is needed, and it will
hit the same which-thread / message-pump question the macOS path did (the fix will
likely reuse `runOnBigStackMainThread`). X11 (Linux) is verified and unchanged.

**macOS follow-ups — the window "contract" to settle before broadening.** The
coordinate model, frame/present model, and input set that both the higher Compose
desktop APIs and the other-platform backends build against are still thin on macOS;
settle them here once rather than re-doing them per platform:
1. **HiDPI / Retina** — currently `contentsScale = 1.0`, `drawableSize` in points, so
   Retina renders at 1x (soft, OS-upscaled). Track `window.backingScaleFactor`, size
   the drawable in pixels, and scale the Skia canvas so layout stays in points. Fixes
   the points-vs-pixels contract everything else inherits.
2. **Frame pacing / run loop** — the loop is VM-driven `nextEventMatchingMask` polling
   (~10 fps; repaints only when the VM loops; janky live-resize; no occlusion redraw;
   no vsync). Move to a `CVDisplayLink`/vsync-presented redraw and pump the run loop so
   the window stays responsive.
3. **App lifecycle** — a minimal `NSApplicationDelegate` + main menu so Cmd-Q / Cmd-W /
   activation / dock behave like a real app.
4. **Live resize + display change** — track `windowDidResize` /
   `viewDidChangeBackingProperties` (moving between monitors of different scale).
5. **Input completeness** — modifiers, key repeat, scroll wheel, right-click; IME later.
6. **Color management** — tag the surface's color space (sRGB / display P3) rather than
   DeviceRGB.

**Sequencing recommendation:** the small macOS hardening pass (items 1–3 lock the
contract) → then the Compose desktop API surface (real `compose.ui.graphics` on the
shim → `compose.ui` engine → foundation → material3; platform-agnostic, inherits the
contract) → then broaden/verify the other platform backends (Win32; keep X11), each
just implementing the same window contract. Not the reverse: broadening platforms first
copies an unfinished contract 2–3×, and jumping to the API layer before HiDPI bakes a
1x coordinate assumption into it.

**Bundled font — DONE.** A Latin subset (~15 KB) of Noto Sans Mono (Google, OFL
1.1) is committed under `src/compose_ui/fonts/` and baked into a byte array
(`src/compose_ui/font_data.cpp`, regenerated by `scripts/gen-font-data.py`) that the
shim links. `ensureFonts` uses it as the default typeface (after a `$KLIO_SKIA_FONT`
override, before any system-font scan), so text renders self-contained on fontless
hosts and deterministically everywhere. License at `src/compose_ui/fonts/LICENSE.txt`.

Later: building + verifying the Win32 backend on a real Windows host (Cocoa is done;
the macOS GPU *window* surface is Metal — the offscreen Ganesh+EGL GPU path remains
linux-only).

### Vendor the real compose.ui / foundation / material

The geometry/unit/util math layer is vendored and running. Remaining, in order:

- **`androidx.compose.ui.graphics`** — Color + colorspace (blocked on open bug #1),
  then `Canvas`/`Paint`/`Path`/`ImageBitmap` as klioMain actuals over the Skia shim
  (this is where the Skia backend and the vendored graphics API meet).
- **`androidx.compose.ui`** (the ~240-file engine) — the real `LayoutNode`,
  `Modifier.Node` chain, measure/layout/draw, `Constraints`/`Placeable`, pointer
  input, focus, semantics. Vendor incrementally; the klio-authored ui-core proves
  the shapes the real engine needs.
- **`compose.foundation`** — Box/Row/Column/Text/Image, scroll, gesture, `Lazy*`
  (on N2 subcomposition).
- **`compose.material3`** — consumed mostly verbatim on foundation.

Each consumes upstream common code; klio supplies platform actuals (the Skia
`DrawScope`, window, input, fonts). Expand the submodule sparse checkout
(`scripts/init-compose-submodule.sh`) per module as vendored.

### Sequencing

Skia backend (fetch libs → C shim → build wiring → PNG sink → richer DrawScope) →
unblock Color/graphics (bug #1) → vendor real `compose.ui.graphics` on the shim →
real `compose.ui` engine → foundation → material3 → GPU/windowing.
