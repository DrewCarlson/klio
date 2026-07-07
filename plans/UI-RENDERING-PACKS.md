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

**Open bug this surfaced (compose runtime, not windowing):** `var x by remember {
mutableStateOf(0) }` inside a `@Composable` does not persist writes across
recomposition — reads show the initial value forever. Isolated: standalone `var x by
mutableStateOf(0)` works (0→5→8); `val s = remember { mutableStateOf(0) }` + `s.value`
works and recomposes; ONLY the `by` + `remember` + composable combination fails. So
the property-delegate desugaring of a `remember`ed `MutableState` mis-slots or
mis-binds the delegate in the composition. `compose_ui_window.kt` uses the working
`remember { mutableStateOf }` + `.value` form; the `by` form needs the interpreter
fix.

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

Later: bundling a `.ttf` for fontless hosts, macOS (Cocoa) / windows (Win32) window
backends, and verifying the macos/windows shim recipes on those hosts.

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
