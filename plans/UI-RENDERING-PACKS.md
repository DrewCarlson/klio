# Compose UI on klio — status + roadmap

Goal: klio is a **drop-in for desktop Compose Multiplatform** — vendor upstream
`androidx.compose.*` common code verbatim, supply klio's Skia backend as the
desktop actual. Source-set layering and the one-pack-per-upstream-module rule
are in [MULTIPLATFORM.md](MULTIPLATFORM.md) (§0, §3). Desktop is the only live
target.

Code: `kotlin-klio/klio-compose-*/`, `src/compose_ui/`; vendored upstream under
`kotlin-klio/klio-compose-runtime/upstream`.

---

## Done

Each item below is landed and verified (pixel checks where it renders; see the
commit log and the `klio-compose-*` memories for the per-fix detail that used to
live in this file).

**Runtime + backend**

- **compose-runtime** — the real `androidx.compose.runtime`: state, recomposition,
  `remember`/`key`/effects, CompositionLocal, `derivedStateOf`, the async Recomposer
  + frame clock, `snapshotFlow`/`collectAsState`, `@Composable` content, node emission
  via `Applier`/`ComposeNode`, subcomposition, ReusableComposition.
- **Skia backend** — `src/compose_ui/skia_shim.cpp` is the `extern "C"` surface over
  the prebuilt JetBrains skia-pack (`scripts/fetch-skia.sh`). A draw pass records a
  display list (the deterministic, Skia-independent test artifact); PNG bytes are the
  visual proof. Optional GPU: Ganesh+EGL (Linux) and Metal (macOS).
- **Live windows** — SDL2 (Linux; software + on-screen GPU both verified) and Cocoa +
  Metal (macOS, verified on hardware). Real render → present → poll → dispatch loop,
  live resize, batched input, keyboard/hover/pointer. Win32 is written but unverified
  (no Windows host).
- **Desktop entrypoints** — `application { Window(onCloseRequest = ::exitApplication) { … } }`
  is a real composition; multi-window, state-gated open/close, and live title/size
  changes all work. Headless reports `opened=false` cleanly.

**Pure-Kotlin packs (vendored verbatim, one pack per upstream module)**

- `ui.util`, `ui.geometry`, `ui.unit` (Dp/IntSize/Density/TextUnit), `ui.graphics`
  (Color + the full colorspace package + the drawing-parameter value classes),
  `animation.core`, `graphics-shapes`, `runtime.saveable`.
- **Colorspace conversion** — `convert` across sRGB/CieXyz/CieLab/Oklab/DisplayP3/
  AdobeRgb (roundtrips exact), Oklab-backed `lerp`, `compositeOver`, `luminance`.
  Locked by `examples/compose_colorspace.kt`.

**Skia-backed `ui.graphics`**

- `Path` (command buffer + `SkPathOps` for union/intersect/difference/xor), `Paint`,
  `Canvas`, `DrawScope`, `Shape`/`Outline`, `Brush` (SolidColor + linear/radial
  gradients via real `SkShaders`), transform helpers (`rotate`/`scale`/`translate`/
  `clipRect`/`withTransform`).
- **ImageBitmap** over an offscreen Skia surface (`Canvas.drawImage`/`drawImageRect`,
  `readPixels`, `toPixelMap`), plus the `painter/` family (Painter/BitmapPainter/
  BrushPainter/ColorPainter).

**Real `androidx.compose.ui` engine (§2 — DONE end-to-end)**

`renderComposeToPng` runs the full real engine: compose → Owner + root `LayoutNode`
→ measure → layout → placement → draw → Skia PNG. `KlioComposeHost.kt` supplies the
Owner over the vendored `MeasureAndLayoutDelegate`, a direct-draw `KlioOwnedLayer`,
the platform CompositionLocals, and the headless entry.

**ui-text (DONE, over skparagraph)**

The Paragraph engine is `skia::textlayout`. Real shaping/wrap/bidi (ICU), per-span
font sizes, word boundaries, hit testing, cursor/selection geometry,
`getPathForRange`, `getRangeForRect`. Font FILES load real typefaces
(`FontFamily(Font(path))`). letterSpacing + lineHeight, inline placeholders
(`placeholderRects`). A bounded paragraph-handle pool (192, evict-oldest,
revive-on-use). Headless keeps a deterministic pure-Kotlin stub wrap.

Shim ABI lessons (both were silent corruption): compile with `-DNDEBUG`, and on Linux
`-D_GLIBCXX_USE_CXX11_ABI=0` (the skia-pack mangles `u16string` pre-cxx11).

**foundation + material3 (over the real text stack)**

- **LazyColumn / scroll** — SubcomposeLayout drives per-item subcomposition, items
  measure through foundation `BasicText` into skparagraph, `LazyListState` carries the
  scroll window. Pixel-verified (`initialFirstVisibleItemIndex = 10` starts at `row 10`).
- **material3 `Text`/`Surface`/`Button`** — render through the real engine with correct
  M3 theming (surface tone `#FEF7FF`, primary `#6750A4`, real `#1D1B20` glyphs), across
  the typography scale. `MaterialTheme` provides/overrides/restores its subtree.
- **Interactivity** — synthetic clicks deliver for foundation AND material3 through the
  real `PointerInputEventProcessor`. `Modifier.clickable`, raw `Layout` +
  `Modifier.pointerInput`, and a full `MaterialTheme > Surface > Column > Button(onClick)`
  scene all observe their onClick, with the recomposed count label pixel-verified.
- **`Modifier.background` and `Modifier.border`** — both render, pixel-verified.

Examples: `compose_{color,density,path,paint,pathop,canvas,drawscope,shape,brush,
gradient,colorspace,uitext,foundation_lazy,material3,material3_text,window,multiwindow,
ui,ui_click,ui_lazy,ui_material,ui_text,ui_window,ui_input,ui_png}.kt`, `mosaic_hello.kt`.

> Render-tier examples stay corpus-SKIP: the e2e source-pack set stops at ui-text, and
> baking ui-core/foundation/material3 per e2e run is not worth the gate time. The
> compose battery covers them.

---

## Remaining work

### 0. Find the missing actuals with the TOOL, not by running the program

`klio check --unimplemented <program.kt>` loads the program with every pack it
imports and the embedded stdlib, walks all declarations, and lists every `expect`
function/property with neither a Kotlin `actual` nor a registered klio intrinsic.
It is the static analogue of the silent-`Unit` runtime failure.

**Use it before touching anything.** Discovering these one at a time by running the
program costs a pack rebuild + a run per name, and each run only ever reveals the
NEXT one. One invocation gives the whole backlog:

    klio check --unimplemented probe.kt

For a `BasicTextField` probe today: **127 unimplemented actuals, 51 of them under
`androidx.compose.foundation.text*`** — key mapping, cursor/selection drawing,
magnifier, clipboard, code-point helpers, context menu, drag-and-drop. That is the
real shape of the text/selection work, and it batches into a few klioMain files.

**Where the actuals come from.** Upstream ships them: `skikoMain` (pure Kotlin, safe
to LINK — the pack already does this for ui-text) and `desktopMain`. Desktop
Compose is skiko + desktop, so the text-field cursor/draw/pointer modifiers and the
key mapping live in `desktopMain`.

`desktopMain` must be **copied, not linked**: as a source set it depends on JVM APIs
(java.awt clipboard, Swing context menus) that klio cannot satisfy, so pointing the
pack at it would bake in a dependency we cannot honour. The java-free subset is
vendored into `klioMain` (22 files, provenance header on each); the one JVM-coupled
text file (`ContextMenu.desktop.kt`) and five stragglers behind it are klio-authored.

Caveat: the check only sees `expect`/`actual`. A klio-authored runtime API that is
simply ABSENT is a different gap and will not appear (e.g. `currentRecomposeScope`,
which the compose runtime declares next to the compiler-coupled `RecomposeScopeImpl`
the pack cannot carry — klio supplies its own).

### 1. foundation API sweep (in progress)

The foundation surface is only partly exercised. Known state:

| API | State |
| --- | --- |
| `Modifier.background` (color + shape) | DONE, pixel-verified |
| `Modifier.border` | DONE, pixel-verified |
| `BasicText` / `LazyColumn` / `verticalScroll` | DONE, pixel-verified |
| `Modifier.clickable`, `pointerInput` | DONE (synthetic click) |
| `Image` / `painter` | DONE, pixel-verified |
| `Canvas` composable | DONE, pixel-verified (rect + circle) |
| `LazyRow` | DONE (windowed: composes 10 of 20) |
| `BasicTextField` | **All 51 `foundation.text*` actuals now supplied** (127 unimplemented → 76). Still stack-overflows in deep native recursion — a real bug now, not a gap. Next up. |
| Gesture detectors (`detectTapGestures`) | BROKEN — the tap does not fire (`Modifier.clickable` does). Not an actuals gap. |
| `Modifier.scrollable` interaction (fling, `ScrollState` drag) | untested |
| Selection (`SelectionContainer`, text selection handles) | untested — needs the selection actuals |
| `LazyVerticalGrid` / staggered grid | untested |

Work: drive each with a pixel/engine-fact probe, root-cause what fails, add an
example, keep the corpus green.

### 2. material3 component sweep

`Text`/`Surface`/`Button` render. The rest of the component set is unexercised:
`Card`, `Scaffold`, `TopAppBar`, `TextField`, `Checkbox`/`Switch`/`RadioButton`,
`Slider`, `NavigationBar`, `Dialog`, `Snackbar`, the `Icon` family. Ripple animation
in a live window is also open (material-ripple is vendored).

### 3. Known interpreter roots still open

- **~~`@Composable` trailing CONSTRUCTOR lambda misbinds the other arguments~~ — FIXED.**
  The note misattributed it: nothing to do with `@Composable`, and plain lambdas were
  equally broken. A CONSTRUCTOR call combining a named argument that skips a defaulted
  parameter with a trailing lambda (`Panel("p", n = 11) { … }`) dropped the block into the
  first free slot (`flag`) and shifted everything after it. Kotlin binds a trailing lambda
  to the LAST parameter whatever gap the names leave — the named FUNCTION path already did
  this, the constructor path did not. Two supporting bugs fell out: the constructor binder
  asked `ClassDef` whether a skipped parameter has a default, but `ClassDef` is not
  reachable by name from every build path (it is null under the parity harness), so a
  satisfiable named call fell through to the positional fallback. Both the default check
  and the parameter type now come off the IR class. Locked by
  `examples/ctor_trailing_lambda.kt`. `KlioComposeScene` can drop its `setContent`
  workaround.
- **PUBLIC cross-package top-level name collisions** — `internal` ones now lift mangled
  with a package-scoped rename channel; the public case waits on the symbol index and
  import channels resolving renamed classifiers (resolution-unification).
- **Class MEMBERS are absent from the lowering's name index.** (This was previously
  recorded here as "cross-pack signatures are invisible to the lowering" — that
  diagnosis was wrong. Packs are fine: the base and the user program are ONE module.)
  `Module.func_name_index` is built only from top-level `Function` declarations, so a
  bare call to a class member cannot reach its signature at lower time. Consequence:
  `overloadHostingTrailingLambda` misses, the trailing lambda's expected arity is
  unknown, and a `T.() -> R` receiver lambda keeps a synthetic `it`
  (`onDrawWithContent { … }` on a `CacheDrawScope`). The runtime binder repairs this from
  the parameter's declared type at the call (`ClosureInfo.recv_lambda`), deliberately
  excluding SUSPEND function types — they carry the continuation as an extra positional
  argument, so their arity already lines up.

  The fix is to let the bare-call arity path consult the receiver/owner class's members.
  `registry.member_method_fids` already exists for exactly this ("reach a SIBLING member
  method's lowered signature at lower time, when members are absent from the simple-name
  indexes"), but it is keyed `{class}\x00{name}\x00{arity}` and owner-scoped, so it needs
  a hierarchy walk (the member may be declared on a supertype) and care over whether the
  arity counts the leading `this`. Until then the runtime repair carries it.
- **~~The registry misses pack classes~~ — FIXED.** An EXTENDING build (a user program on
  top of a baked stdlib+packs base) carries only the user's declarations in `decls`, so a
  registry table registered from `decls` alone left every pack class out — `recv_fn_props`
  came back EMPTY for a compose program and every receiver-fn-property lookup silently
  missed. It now registers from `file_classes` (base + user), the universe the sibling
  tables already use: 0 → 140 entries for a compose program. Any NEW registry table must
  register from `file_classes`, not `decls`, or it will be silently empty for packs.

### 4. Platform / backend

- **Win32** — written, needs verification on a Windows host.
- **macOS window hardening** — display-change / backing-scale on monitor move
  (`viewDidChangeBackingProperties`); input completeness (modifiers, key repeat, scroll,
  right-click, IME); color-space tagging (sRGB/P3 vs DeviceRGB).
- **SDL notes** — the Linux GPU path assembles Skia's **native** (GLX) GL interface; the
  loader-assembled one crashes in zink's extension enumeration. Only editing keys
  (Backspace/Delete) come from key-downs; printable input arrives via `SDL_TEXTINPUT`.

### 5. Perf backlog (impact order)

**Done:**

- **The profiler's sample tables no longer sit in every binary.** Three
  `[4M]usize` statics (32 MB each) were declared `= undefined`; a Debug build fills an
  `undefined` global with a poison pattern, so they could not live in `.bss` and became
  96 MB of real file bytes — the bulk of a **525 MB** `klio`. They are `mmap`ed by
  `maybeStart` now, so a run without `KLIO_PROF` pays nothing: **525 MB → 158 MB** Debug.
- **The optimize mode is documented** (README). `zig build` follows the Zig convention and
  defaults to Debug; `-Doptimize=ReleaseFast` is ~8× faster and 3× smaller. Measured:

  | | binary | startup | 2M method calls | peak RSS |
  | --- | --- | --- | --- | --- |
  | Debug | 158 MB | 0.21 s | 12.3 s | 49 MB |
  | ReleaseFast | **54 MB** | **0.03 s** | **1.5 s** | **35 MB** |

**Open:** slim custom Skia build (the +112 MB is Skia's fixed working set, not klio) →
lazy stdlib load (baseline ~35 MB) → shrink the evaluator per-call frame → drop the
per-frame display-list serialize/parse round-trip. Idle CPU (~0.3%) and the resize "leak"
(proven bounded/GC-managed) need no action.

---

## Operational notes

- **Rebuild packs after a binary change.** A pack IMAGE is only consistent with the
  interpreter binary it was built against: `klio pack build <dir>` + `klio pack install`,
  then clear `~/.klio/cache/*.klio-image`. A stale image misresolves.
- **The interim klio-authored ui-core** (`klio.compose.ui`) still exists and documents
  the shapes the real engine needs. It is retired as the real API lands.
