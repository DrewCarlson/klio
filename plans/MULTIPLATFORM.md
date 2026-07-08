# Multiplatform support (interpreter + packs)

Status: design plan. Desktop is the only live target today; this document
defines the target/source-set axis KLIO grows into so that a single Kotlin
program (and its packs) can expose common code that runs everywhere plus
platform-specific code that is visible only on the platform that provides it —
matching Kotlin Multiplatform's `expect`/`actual` + source-set model.

The immediate work continues to target desktop only. Nothing here asks for
Android/iOS runtimes now; it defines the shape so that when a mobile runtime is
added, common apps keep working unchanged and platform APIs slot in cleanly.

Related: [PACK-ROADMAP.md](PACK-ROADMAP.md), [PACK-DISTRIBUTION.md](PACK-DISTRIBUTION.md),
[UI-RENDERING-PACKS.md](UI-RENDERING-PACKS.md).

## 0. Pack granularity — one pack per upstream module

When vendoring a multi-module upstream library (compose, ktor, kotlinx.*),
**maintain the upstream module boundaries: one klio pack per upstream Gradle
module**, each pack's `id` being that module's real coordinate/package
(`androidx.compose.ui.util`, `androidx.compose.ui.graphics`,
`io.ktor.http`, `io.ktor.client.core`, …). Do NOT collapse several modules into
one umbrella pack. Each pack declares only its real cross-module dependencies as
`[[deps]]`; the fixpoint loader (`src/cli/pack_cache.zig`, `importPrefixMatches`)
pulls dependency packs in transitively via source imports, so a program that
imports one module's symbol loads exactly that module's pack and its dependency
closure — nothing more.

Why: it mirrors the upstream module graph (so klio is a faithful drop-in), keeps
each pack independently buildable/testable, lets a consumer pull in a feature
module without dragging in unrelated ones, and matches the per-target source-set
axis below (a module's platform actuals live in that module's pack's klioMain).

Status: **compose UI is split** — `androidx.compose.ui.{util,geometry,unit,graphics}`
are separate packs (`kotlin-klio/klio-compose-ui-{util,geometry,unit,graphics}`).
**ktor is still a monolithic `io.ktor` umbrella** (`kotlin-klio/klio-ktor` bundles
ktor-io/utils/http/client-core/server-core/events) — a retrofit to split it into
`io.ktor.{io,http,client.core,server.core,…}` packs is a follow-up.

## 1. Where we are (ground truth)

There is currently **no platform/target axis anywhere** in the pack model,
manifest schema, resolver, CLI, or runtime. What the manifests informally call
"source sets" are just ordered lists of directory roots that a pack build
concatenates into one flat declaration stream. "Desktop" is not a selected
target — it is the only runtime that exists, and it is implicit.

Concretely, today:

- **Manifest source model** (`src/cli/pack_build.zig`, `SourceRoot`): a
  `[[source]]` block has exactly `root`, `include`, `exclude`. No `target`,
  `platform`, or source-set field. `collectPackSources` walks each root in
  manifest order, applies its include/exclude globs, dedups by relative path,
  and returns one undifferentiated `[]SourceFile`. There is no runtime TOML
  parser — the source-set → declarations composition happens entirely at pack
  **build** time; the runtime loads compiled `.klio-pack` binaries.

- **`expect`/`actual`** is recognized but name-keyed, not a checked feature.
  `expect`/`actual` are soft-keyword modifiers (parsed, `is_expect`/`is_actual`
  flags on the AST). In `src/interp_ir/build.zig`, `retainDecl` drops an
  `expect` declaration iff an `actual` with the same **simple name** exists;
  default parameter values are transplanted expect→actual. There is no
  expect↔actual **signature** verification (the
  `ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT` diagnostic exists only as a stub).

- **Platform selection**: none. No `--target`/`--platform` flag, no
  `KLIO_TARGET` env var. The only "platform choice" is the manual, per-manifest
  editorial decision of which upstream platform source-set directories an author
  lists as ordinary `[[source]]` roots (e.g. the androidx.collection pack pulls
  `commonMain` + `nonJvmMain` + `jbMain`; the ktor pack mixes `common/src`,
  `posix/src`, `nonJvm/src`). Which platform is baked into each `klio.toml`.

- **How klioMain overrides upstream**: three cooperating mechanisms, none of
  which is a generic "same-FQN, klioMain wins" resolver. (1) the name-keyed
  `expect`→`actual` drop; (2) curated `include` lists that omit upstream files
  klio can't consume and re-declare them in klioMain; (3) host bindings that win
  at dispatch regardless of the Kotlin body.

- **Dormant hooks already in the tree** that a real design formalizes: the
  parsed-but-unused `SourceRoot.exclude`, the fully-plumbed-but-never-read
  `Binding.platform_actual` flag (`src/pack/schema.zig`), and the stubbed
  `ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT` diagnostic.

- **Compose UI native binding** (the one desktop-specific surface that exists):
  `kotlin-klio/klio-compose-ui` declares 6 host intrinsics (`__composeui_*`)
  with `error("… not installed")` Kotlin fallbacks; `src/compose_ui/compose_ui.zig`
  registers them to Zig implementations that dlopen the Skia/Metal backend. The
  pure-Kotlin layout/measure/draw stack sits above those intrinsics.

## 2. Target model

Introduce a first-class **target** axis. A target is a leaf platform the
interpreter can run as:

```
common                      (no platform APIs; runs on every target)
├── desktop                 (native desktop: window/GPU via the Skia backend)
├── android                 (future)
└── ios                     (future)
```

Mirrors Kotlin's hierarchical source sets: `common` is the root; each leaf
target `dependsOn` common (and, later, intermediate sets like `native` or
`mobile` may sit between). Only **one leaf target is active per run**. The
active source-set set is `{common} ∪ {ancestors of the active target}`.

Today only `common` and `desktop` are populated. The axis is introduced so the
current packs — which are effectively "common+desktop merged" — split cleanly:
platform-neutral Kotlin becomes `common`, the desktop-only actuals/bindings
become `desktop`.

### 2.1 Manifest schema

Extend `[[source]]` with an optional `target` (default `common`):

```toml
[[source]]
target = "common"          # default; omit for common
root = "upstream/.../commonMain/kotlin"
include = [ ... ]

[[source]]
target = "desktop"
root = "desktopMain"       # actuals + host-intrinsic entrypoints
```

A block with no `target` is `common`. `collectPackSources` filters blocks by the
active target chain instead of concatenating all of them, so a pack ships all
targets in one `.klio-pack` and the loader selects. (Compiled packs must carry
the per-file target tag; extend the pack binary section accordingly.)

`[[bindings]]` gain the same axis via the already-present `Binding.platform_actual`
flag: a binding tagged for a target participates only when that target is active.
Host-intrinsic bindings for the Skia backend become `desktop` bindings.

### 2.2 Target selection

Add `--target <name>` to `klio run`/`klio pack build` (and a `KLIO_TARGET` env
fallback), defaulting to `desktop`. The selected target drives (a) which source
blocks compose, (b) which `expect` actuals are chosen, (c) which host-binding
set is merged. Absent the flag, behaviour is exactly today's (desktop).

### 2.3 expect/actual, made target-aware

Keep the name-keyed `retainDecl` drop as the mechanism, but scope candidate
`actual`s to the **active target chain** so two targets can supply different
actuals for the same `expect` without colliding. Then progressively harden:

- Wire `ACTUAL_ANNOTATIONS_NOT_MATCH_EXPECT`: verify the `actual` signature
  matches the dropped `expect` (arity, receiver, param/return type heads). A
  mismatch is a diagnostic, not a silent wrong-actual.
- A common declaration that is `expect` with **no** actual for the active target
  is an unresolved reference on that target (matches kotlinc: `expect` without
  `actual` fails to link).

### 2.4 Platform-only API visibility

A symbol declared **only** in a target source set is visible only when that
target is active. A `common` program referencing a `desktop`-only symbol fails
to resolve on `android`/`ios` (matching Kotlin MPP). This is what lets one pack
expose:

- **common multiplatform apps** — code in `common` that compiles/runs on every
  target, calling only common APIs (+ `expect` declarations backed per target);
- **platform-specific functionality** — code in a target source set calling APIs
  that exist only there (desktop windowing, Android `Context`, iOS `UIView`).

Implementation: the resolver already keys most resolution off the composed
declaration stream; once composition is target-filtered, an out-of-target symbol
simply is not in the stream and resolves to "unresolved", which is the correct
MPP behaviour. No separate visibility pass is required for the common case.

## 3. Compose UI / Skia layering

Goal: **be a drop-in replacement for desktop Compose Multiplatform code written
for normal kotlinc** — same package and API shapes, so a program written against
`androidx.compose.*` desktop APIs compiles and runs on klio unchanged. To get
there, vendor the upstream *common* compose code verbatim and supply klio's
desktop backend as the *desktop actual* layer, exactly as Compose Multiplatform
splits `commonMain` from `skiko`/desktop.

### 3.1 Source-set split for compose

```
androidx.compose.runtime        common   (vendored verbatim; klio engine actuals)
androidx.compose.ui.graphics    common   (Color + colorspace — vendored; started)
androidx.compose.ui             common   (Modifier, layout, semantics, …)
androidx.compose.foundation     common
androidx.compose.material3      common
────────────────────────────────────────
compose desktop backend         desktop  (Skia window/GPU via __composeui_* host
                                          intrinsics; the src/compose_ui shim)
compose android/ios backend     android/ios  (future: platform canvas + interop)
```

The common layers are upstream-verbatim `androidx.compose.*` — this is what makes
klio a drop-in. The desktop backend is klio's actual for the platform-`expect`
surface compose defines (the equivalents of `skiko`'s window, canvas, input,
frame clock). Package/API shapes stay identical to upstream desktop; only the
implementation under the platform `expect`s is klio's.

### 3.2 Current position and near-term path

- Done: `androidx.compose.runtime` (common + klioMain engine), and the first
  slice of `androidx.compose.ui.graphics` (real `Color` + the colorspace
  package), plus ui-util/geometry/unit math. The desktop backend is a live
  Metal/Cocoa Skia window (see [UI-RENDERING-PACKS.md](UI-RENDERING-PACKS.md)).
- Next (desktop-only, in order): finish real `androidx.compose.ui.graphics` →
  real `androidx.compose.ui` (Modifier / LayoutNode / semantics / input) →
  `androidx.compose.foundation` → `androidx.compose.material3`. Each vendored as
  `common`; each platform `expect` it introduces gets a `desktop` actual backed
  by the Skia host intrinsics.
- The public entrypoints must match upstream desktop: `androidx.compose.ui.window.Window`,
  `application { }`, so desktop Compose programs are source-compatible. klio's
  current `klio.compose.ui.runApp` is the interim driver; it converges onto the
  upstream `androidx.compose.ui.window` API as the `ui` layer lands.

### 3.3 Mobile (future)

Android and iOS become target source sets under the same axis: the common
compose layers are unchanged; new `android`/`ios` backends supply the platform
`expect` actuals (Android Canvas/View interop and Compose-for-Android; iOS
UIKit + Skia). A React-Native-style setup (klio driving a native host UI) rides
the same host-intrinsic mechanism the desktop Skia backend uses today — a
per-target host-binding set selected by `--target`.

## 4. Phasing

1. **Axis, desktop-only** — add `target` to the manifest schema + pack binary,
   `--target` selection (default desktop), target-filtered source composition
   and host-binding merge. Split today's packs into `common` vs `desktop` blocks.
   Everything stays green: desktop is the default and the only populated leaf.
2. **expect/actual hardening** — target-scoped actual selection; wire the
   signature-match diagnostic.
3. **Compose common surface** — continue vendoring `androidx.compose.*` common
   layers; converge the public window/application API onto upstream desktop.
4. **Mobile targets** — populate `android`/`ios` source sets and backends when a
   mobile runtime is built.

Steps 1–3 are desktop-only and are the current focus; step 4 is deferred.
