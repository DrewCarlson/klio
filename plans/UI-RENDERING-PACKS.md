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

Examples: `compose_{color,density,ui,ui_click,ui_lazy,ui_material,ui_text,
ui_window,ui_input,ui_png}.kt`, `mosaic_hello.kt`.

### Interpreter fixes this vendoring drove (all general, landed)

Vendoring real compose surfaced and fixed several genuine interpreter gaps (each
with a minimal repro + green suites): identity-based inherited-method dispatch
(name-collision), inherited companion `const`/`fun` resolution (qualified + in
ctor-delegation), identity-aware `is`/subtype/overload across package name
collisions, and interface-inherited member-extensions via a `with` receiver (the
`Density.toPx()` unblocker). See the git history and the
`compose-graphics-color-vendored` memory for specifics.

## Next work

### 1. Skia-backed `compose.ui.graphics` (the current frontier)

The pure-Kotlin graphics is done; the next layer is the **Skia-backed** drawing
API — real `androidx.compose.ui.graphics.Canvas` / `Paint` / `Path` / `Shader` /
`ImageBitmap` and the `graphics.drawscope.DrawScope`, implemented as **klioMain
actuals over the `src/compose_ui` shim**. This is where the vendored graphics API
meets the renderer. Suggested order: `Path` → `Paint` → `Canvas` → `DrawScope`.
Each upstream `expect`/platform type gets a klioMain actual that calls the shim's
`extern "C"` entry points (extend the shim as needed). `Shape`/`Outline` sit just
above (`Outline.Generic` needs `Path`), unblocking `RoundedCornerShape` etc.

### 2. Real `androidx.compose.ui` engine

The ~240-file engine: `LayoutNode`, the `Modifier.Node` chain, measure/layout/draw,
`Constraints`/`Placeable`, pointer input, focus, semantics. Vendor incrementally
on top of the graphics layer; the klio-authored ui-core documents the shapes the
real engine needs and is retired as the real API lands. Converge the public
entrypoints on upstream (`androidx.compose.ui.window.Window`, `application { }`)
so desktop Compose programs are source-compatible.

### 3. foundation → material3

`compose.foundation` (Box/Row/Column/Text/Image, scroll, gesture, `Lazy*` on
subcomposition), then `compose.material3` (mostly verbatim on foundation).

Vendor per module (one pack each; expand the sparse checkout via
`scripts/init-compose-submodule.sh`), klioMain supplying only platform actuals.

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
- **Pack-image companion-`val` import aliasing** — in a baked pack image,
  `import X.Companion.Y` doesn't alias the qualified singleton `X.Y` (`===` false);
  correct from source. Blocks colour/style singleton identity in shipped packs.
- **Other backends:** verify Win32 on a Windows host. The Linux window is SDL2
  (raster + on-screen Ganesh GPU over SDL's GL context); the offscreen Ganesh+EGL
  path also remains for headless GPU. The macOS window GPU surface is Metal.
- **SDL notes:** the Linux backend targets SDL2 (in every distro's repos today).
  The on-screen GPU path assembles Skia's **native** (GLX) GL interface — the
  loader-assembled interface crashes in zink's extension enumeration. Only editing
  keys (Backspace/Delete) are mapped from key-downs; printable input comes through
  `SDL_TEXTINPUT`, reported with the X11-style keysyms the interim ui-core expects.
