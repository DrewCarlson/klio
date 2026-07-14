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

## Open roots (found chasing BasicTextField)

`BasicTextField` no longer overflows the stack: it composes, attaches, measures,
and reaches text layout. Three roots are fixed (see the commit): the `super.`
first-supertype walk, the name-keyed property-invoke probe re-entering its own
getter (`TextRange.min`), and a SAM-lambda measure policy dispatching to an
unrelated class's `measure`. What is still open, in the order a text field hits it:

**FIXED — `fontScale`/`density` mis-bind (18fced76).** A member-extension's declaring
class is an implicit receiver of its body and now outranks the global tier in both
field-read ladders. `BasicTextField` composes, attaches, measures, and lays out text.

**FIXED — a bare call could bind a member extension of an unrelated class.**
A member extension (`fun A.f()` declared inside class B) needs two receivers: B to
dispatch on and A as the extension receiver. A bare call carries one implicit `this`,
so it can only bind such a candidate from inside B or a subclass, or when B is an
object. Bare-call resolution never checked that. When the applicability ladder could
not rank a candidate (a shipped function whose body is not lowered yet exposes no
signature view), the pick fell to the declared-arity fallback, whose user-over-shipped
preference in `funcId` ranked any non-shipped namesake first. compose-animation
declares `KeyframeEntity.with` inside `KeyframesSpecConfig` with an EMPTY package, so a
bare `with(x) { … }` in `MultiParagraph` bound it over `kotlin.with`, and being an
extension the call emitted a hard `CallMember` on the enclosing class.
`Module.memberExtOutOfScope` now gates the candidate on the caller's enclosing class
(carried on `ResolveCtx.owner_class`), mirroring the runtime's `memberExtVisible`. The
applicability ladder, the declared-arity fallback and the receiver rebind all skip an
out-of-scope member extension. BasicTextField composes, measures and paints its text.

**FIXED — a lifted nested class could not prove its own supertype in member dispatch.**
The earlier reading ("both overloads are missing from the module") was wrong: both are
lowered and present on the class. The runtime subtype walk compared raw simple names,
but a nested class lifts to a flat `Outer$Name` and that mangled form is what a
subclass records as its supertype, while a parameter declared `Outer.Name` lowers its
type head to the bare `Name`. The two never compared equal, so no instance of a lifted
nested type could prove it was one. Harmless for a lone candidate (whose check only
needs the absence of a disproof) and fatal for an overload set (whose scorer needs
positive proof per argument): both `hitInMinimumTouchTarget` overloads scored
inapplicable against a `Modifier.Node`, so the member walk missed and the pointer path
died. `instanceSubtypeDistance` now compares through `classDisplayName`, the same
lift-mangle strip `applicability`'s evidence head already applies.

**FIXED — a reified inline splice had no receiver evidence from a class member.**
`realclick` rendered but every FIRST pointer event was dropped (4 clicks -> 3;
`fclick` had the same off-by-one, masked because it clicked twice and only
asserted a non-zero count).

Chain: `HitPathTracker.Node.buildCache` calls
`modifierNode.dispatchForKind(Nodes.PointerInput) { coordinates = it.layoutCoordinates }`.
`dispatchForKind` walks the node chain on `node is T`, and for the SAME
`ClickableNode` at the SAME call site it answered false on the first event and
true on every one after. The cause: 70 `is` checks ran against the LITERAL type
name `T`. When an inline reified function is SPLICED, lowering substitutes `T`
with the real class; when it is NOT, the body lowers standalone with the bare
name, and `host_classes.instanceOf` resolves it through a PROCESS-GLOBAL keyed
by `T` -- written and restored by unrelated calls, so the answer is
order-dependent (unbound it accepts any non-null value; stale it tests against
whatever class another splice left behind).

The splice bailed because receiver-type inference for an inline call consulted
only locals and parameters. `modifierNode` is a primary-ctor `val`, so the call
had NO receiver type, and `dispatchForKind`'s two overloads can only be told
apart by the receiver -- no declaration was found, the splice fell back to a
plain member dispatch, and the reified argument died with it. Unspliced, the
node's coordinates were never read, it reported itself "not hit", and the event
dispatched to no one.

`inferReceiverType` now falls back to `ownerMemberDeclType`, which searches the
enclosing class and its supertypes for a primary-constructor `val` or a body
property. Clicks land on the first press: the interactive scenes report 2 of 2.
Guarded by `examples/reified_inline_property_receiver.kt`, which without the fix
lets a `Square` answer to a `Kind<Circle>`.

The process-global that `is T` falls back to is still unsound in principle: an
unspliced reified call has no way to carry its type argument (`Inst.Call` has a
`type_args` field, `Inst.CallMember` does not). It was NOT merely latent -- every
reified `Json` call reached it and died with `unresolved global T`, because
`Json` is a companion-object NAME and receiver-type inference did not recognise
one, so the splice declined. Receiver evidence now covers locals, parameters,
class members, and type names, which is every form these call sites use. The
global remains the fallback of last resort; carrying type arguments on
`CallMember` would retire it.

**FIXED — an `actual` superseded every same-named `expect` in the program.**
Kotlin requires an `actual` to declare its `expect`'s package, but the supersede
pass matched the pair by SIMPLE NAME. Linking foundation's
`androidx.compose.foundation.text.getString` actual therefore deleted
`androidx.compose.material3.internal.getString`'s unrelated expect from the
symbol table; material3's own callers import that expect by name, so the only
candidate left was foundation's, in a package they do not import, and every
material3 scene failed to lower with an unresolved reference. The actual set is
keyed by FQN now.

Second root on the same call: the runtime overload re-pick (`pickOverload`)
ranks the candidates lowering could not tell apart from the argument shapes; it
is not a second scope resolution. A bodyless target has no signature to score,
so any body-bearing namesake anywhere in the program outranked it by default and
the call silently ran a stranger's body instead of reporting the missing actual.
A candidate outside a bodyless target's package is no longer considered.

The context-menu strings actual is linked again -- it had been unlinked to dodge
the first root. Both shapes are pinned in `src/itests/resolve_ambiguity.zig`.

## Compose runtime conformance

`zig build itest-compose_runtime_commontest` runs the upstream Compose runtime's
own test suite (`CompositionTests`, `RestartTests`, `MovableContentTests`,
`EffectsTests`, `CompositionLocalTests`, the `snapshots/` suites) through
`klio test` against the installed pack, composed against upstream's mock
View/Applier harness. It is the conformance signal for the implicit-composer
hook: the same tests androidx runs against the Compose compiler plugin.

**203 pass across 46 test classes; 8 classes do not complete inside the
per-child cap.** Ratcheted at 180 -- raise it as fixes land, never lower it.

The suite immediately paid for itself: `field` inside a nested scope
(`get() = synchronized(lock) { field }`, how kotlinx-coroutines-test guards its
scheduler clock) was never rewritten onto the backing slot and read an
unresolved global, which failed every test that reaches `TestCoroutineScheduler`
-- most of the suite. Fixed.

What it says is still broken, in rough order of leverage:

- **A pack does not export its `internal` declarations.** `SnapshotIdSet`,
  `ScopeMap`, `BitVector` and `MultiValueMap` are `internal` in the compose
  runtime, and their own tests -- same package, separate module here -- cannot
  see them at all (`unresolved global SnapshotIdSet`, and a bare mention then
  reads as a member of the test class). This alone accounts for ~30 failures
  across four classes and is not composer logic; it is pack visibility.
- **A continuation resume is asynchronous, and the test scheduler needs it to be
  synchronous.** This is now the single blocker for every composer test that
  advances the clock. `KlioContinuation.resumeWith` (`__klio_co_resume`) queues
  the parked activation on the pump instead of running it, so the coroutine's
  next step happens on a later pump turn. Kotlin runs that step on the caller's
  stack -- dispatch is decided ABOVE it, by the continuation's interceptor -- so
  a test scheduler that fires a frame inside `advanceTimeBy` observes the
  coroutine still parked. Reduced to
  `runTest { launch { delay(16); … }; advanceTimeBy(1000) }`: the delayed body
  runs only after `advanceTimeBy` returns.

  A first attempt at resuming inline (take the parked entry from the owning
  interceptor, `resumeRaw` it on the current stack, re-park on re-suspension)
  makes that repro pass and leaves plain `runBlocking` / `launch` / `async` /
  `coroutineScope` intact, but it drops `coroutines_commontest` from 233 to 44
  with `Vm::call_value on kotlin.Nothing` -- resuming an activation while
  another one is mid-flight corrupts state the evaluator holds per thread.
  Reverted. The fix is to make a nested resume re-entrancy-safe (save/restore
  the evaluator's per-thread activation state around `resumeRaw`, deliver a
  throw from the resumed activation to the owning pump rather than swallowing
  it, and re-park into the OWNING interceptor rather than the top one), not to
  keep queueing the step.

- With that fixed, the recomposer already paces off the frame clock in its own
  context (`runRecomposeAndApplyChanges` parks on `parentClock.withFrameNanos`
  when the context carries one), and `Recomposer` carries `changeCount` /
  `cancel()` / `join()`, which the mock harness drives.
- `BroadcastFrameClockTest` reads `isUnconfinedLoopActive` off `Unit` -- the
  unconfined event loop, already a known open item.
