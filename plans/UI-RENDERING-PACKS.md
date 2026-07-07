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

**Proven (spike done).** A minimal shim — `SkSurfaces::Raster(SkImageInfo::MakeN32Premul)`
→ `SkCanvas` `clear`/`drawRect`/`drawRRect`/`drawCircle` (anti-aliased `SkPaint`) →
`surface->peekPixels` → `SkPngEncoder::Encode(SkWStream*, SkPixmap, Options)` —
compiles and renders a correct anti-aliased PNG on this box. **Critical constraint:
Skia was built against GNU libstdc++ with the OLD string ABI** (undefined symbols
`std::string::_Rep::_S_empty_rep_storage`, `std::__throw_length_error`), so it links
with **system g++ (`/usr/bin/g++` 13.3, libstdc++)**, NOT `zig c++` (which pulls
LLVM libc++ → ABI mismatch, unresolved symbols). Link line that works:
`g++ -std=c++17 -Ithird_party/skia shim.cpp -Wl,--start-group
third_party/skia/out/Release-linux-x64/*.a -Wl,--end-group -lpthread -ldl`.

**Plan:**

1. **Vendor the libs.** A `scripts/fetch-skia.sh` downloads + extracts the pinned
   release into `third_party/skia/{include,modules,out}` (gitignored; fetched on
   demand like the kotlin stdlib checkout). Pin the tag `m150-1f14f1166a`.
2. **C++ shim** `src/compose_ui/skia_shim.cpp` — Skia's public API is C++, so expose
   the `DrawScope` primitives klio needs as `extern "C"` functions: create a raster
   `SkSurface` (`SkSurfaces::Raster(SkImageInfo)`), `clear`, `drawRect`/`drawRRect`/
   `drawCircle`/`drawPath`/`drawLine`/`drawOval`, `SkPaint` (color/style/stroke-width/
   antialias/shader-gradient), text via `SkFont`+`SkTextBlob` (simple) then
   `skparagraph::Paragraph` (real layout/wrapping), `readPixels`, and
   `SkPngEncoder::Encode` → bytes. Opaque handle types (surface/paint/path/font) over
   the FFI boundary. Zig calls these via `extern "C"` decls — no C++ in Zig.
3. **build.zig** — because of the libstdc++ ABI constraint, the shim CANNOT be built
   with `zig cc` (libc++). Build it + link Skia with **system g++** invoked from
   build.zig (`b.addSystemCommand("g++", …)`): compile `skia_shim.cpp` (`-std=c++17`,
   `-Ithird_party/skia`) and archive it with the Skia `*.a` into a single
   `libklio_skia.a` (or a `.so`). Then the `klio` binary links that archive +
   `-lstdc++ -lpthread -ldl` (`exe.linkSystemLibrary("stdc++")`, `exe.addObjectFile`/
   `addLibraryPath`). Alternatively produce `libklio_skia.so` and `dlopen` it from the
   `src/compose_ui` module (keeps libstdc++ fully out of the zig link). Gate behind a
   `-Dskia` build option **ON by default**: Skia is the primary backend once the libs
   are fetched (`scripts/fetch-skia.sh`); the software PPM path is the explicit
   `-Dskia=false` fallback for a checkout without the download.
4. **Wire into `src/compose_ui/`** — the existing module is already the seam
   (`mergedHostBindings`, kept out of the interpreter). Add Skia-backed host
   intrinsics beside the PPM sink; `UiRenderer` gets a `savePng(path, scale)` that
   routes the `PixelCanvas`/`DrawScope` ops to the shim instead of the palette
   rasterizer. Keep the software PPM path as the no-Skia fallback.
5. **Richer `DrawScope` in `klio.compose.ui`** — with Skia behind it, the draw pass
   can do real anti-aliased fills, stroked/rounded rects, gradients, clips, and real
   font glyphs (SkFont/skparagraph) instead of the 3×5 bitmap font. The measure/
   layout pass is unchanged; only the draw backend swaps.
6. **Deterministic tests** — headless raster → PNG; hash the encoded bytes (as the
   PPM sink already returns a checksum) for corpus assertions. GPU/windowing later.

Later: a GPU surface (`libskia_ganesh_ext` + GL/EGL), a platform window + live
input event loop (or a headless synthetic-input driver), and macos/windows shims
(same C ABI, per-OS lib variant).

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
