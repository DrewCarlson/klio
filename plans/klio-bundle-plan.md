# `klio bundle` — single-executable programs

## Status

Linux support is implemented and gated (`zig build itest-bundle_smoke`);
user docs live in `docs/BUNDLE.md`.

Landed:

- Bundle core: `src/pack/bundle_format.zig` (trailer + section table +
  `BundleManifest`, blake3 payload hash, 16 KiB mmap alignment),
  `src/cli/bundle.zig` (assembly: full dep load, base-image cache reuse
  or fresh bake, bundle-time program verification), `src/cli/bundle_boot.zig`
  (probe in `cli.run` + main.zig profile guard; mmap → hash check →
  manifest/version checks → image load → program-src extend → bindings
  replay from the manifest — `~/.klio` is never consulted),
  `KLIO_BUNDLE_INSPECT`. Float encode/decode in `image.zig` and the pack
  codec normalized to explicit little-endian (with codec byte tests).
- Program surface: argv[1..] → `main(args: Array<String>)` (also fixes
  `klio run` binding Unit for the missing parameter),
  `kotlin.system.exitProcess`, stdin passthrough, `--include` resources +
  the `klio.bundle` pack (`kotlin-klio/klio-bundle`) with mmap-served
  `Resources.readBytes/readText/exists/list`.
- Manifest replay: known packages snapshot, platform binding FQNs, and
  pack host bindings as `(fqn, host symbol)` pairs re-resolved at boot
  (hard error on an unresolvable symbol).
- Tests: `bundle_format` unit tests; itest `bundle_smoke` (hello +
  serialization-with-feature byte-identical to `klio run` under an empty
  HOME, argv, resources round-trip + missing-resource exception, exit
  code, stdin, corruption refusal, inspect shape, double-bundle byte
  determinism). `bundle_smoke` joined `scripts/gate.sh`.

Deviations so far:

- A program that redeclares a base name refuses to bundle with a clear
  error (the run path's whole-program fallback has no image to embed);
  the plan's silent-fallback language applies to the program-image bake
  only.
- `zstd` gained a `frameContentSize` helper for release shim artifacts
  distributed as bare frames.

The original design (all decisions committed) follows. It supersedes the
Rust-era "Phase 14 — Application packs" section of
[`PACK-DISTRIBUTION.md`](./PACK-DISTRIBUTION.md) (its locked decisions
carry over and are restated here against the Zig codebase).

`klio bundle main.kt -o myapp` turns a Kotlin program plus everything it
needs — baked IR, packs, assets, and (for Compose programs) the Skia/SDL2
rendering backend — into one self-contained executable. A user runs it on a
machine with no klio, no Kotlin, no toolchain, no `~/.klio`. Both program
classes are first-class:

1. **Headless** — CLI tools and servers (ktor, kotlinx packs).
2. **Compose UI desktop** — the real androidx Compose engine over the Skia
   backend with the SDL2 window layer (Linux verified; Win32/Cocoa backends
   written, unverified).

The model is `deno compile`: a prebuilt per-target runtime binary plus an
injected data payload. Bundling is file surgery — copy, append, patch,
hash — never compilation.

---

## Decision: is a local Zig toolchain required? **NO.**

`klio bundle` never invokes Zig (or any compiler/linker). This is
definitive, not optional. The rationale is grounded in what the runtime
actually consumes:

1. **Everything a program needs at run time is data, not code.** The
   interpreter executes baked IR images (`src/interp_ir/image.zig`, format
   `KIMG` v20) and pack sections (`src/pack/format.zig`, `KPK` v2). Both
   codecs are postcard-style: little-endian header scalars, LEB128 varints
   with zigzag for signed values, length-prefixed slices — no raw
   native-width integers on the wire (`src/pack/write.zig:encodeInt`,
   `image.zig:encodeInt`). An image baked on linux-x64 is byte-consumable
   on any supported target (see Risks for the two codec caveats and their
   fixes).
2. **All native code already lives in the klio binary.** This was locked in
   PACK-DISTRIBUTION.md and holds in the Zig codebase: packs are pure
   Kotlin whose `bindings` sections name host symbols resolved against the
   in-binary registry (`pack_cache.zig:mergedHostBindings`). There is no
   per-program native artifact to produce, so there is nothing for a
   toolchain to build at bundle time.
3. **The one out-of-binary native piece — the Skia shim — cannot be built
   locally even in the YES world.** `libklio_skia.so` must be compiled by
   the platform C++ toolchain against the prebuilt Skia archives' ABI
   (GNU libstdc++ on Linux; see `build.zig:buildSkiaShim`). `zig cc`
   cannot link it. It is already a prebuilt, dlopen'd blob; bundling
   embeds its bytes, it never links them.
4. **The precedent is uniform.** Deno appends/injects an eszip payload into
   a prebuilt `denort` fetched per target from dl.deno.land; Bun copies its
   own runtime and writes the module graph into a `__BUN,__bun` section;
   neither requires a toolchain on the user's machine. Cross-compilation in
   both is "download the other platform's runtime".

**Consequences of NO (all committed):**

- klio's release CI must publish, per supported target, two artifacts: the
  runtime stub (the `klio` binary itself, ReleaseFast, stripped) and the
  Skia shim blob. New workflow `.github/workflows/release.yml` (M5).
- Same-target bundling is always offline: the stub is the running
  executable (`/proc/self/exe` / `_NSGetExecutablePath` /
  `GetModuleFileNameW` — the pattern already exists in
  `stdlib_image.zig:exeStamp`).
- Cross-target bundling fetches the stub for `--target` **of the exact
  same klio version** over HTTPS (`std.http.Client`), verifies a sha256
  pinned in a manifest baked into the bundling binary at release, and
  caches under `~/.klio/stubs/<version>/<target>/`. Offline after first
  fetch; `KLIO_STUB_DIR` overrides for CI/air-gapped use.
- Bundle payloads carry the klio version + image `FORMAT_VERSION`; a stub
  refuses a payload from a different version with an actionable error.
  This replaces the exe-size+mtime keying the `~/.klio/cache` images use —
  a bundle is only ever assembled by the same-version binary that boots it.
- What YES would have bought and why it is rejected anyway: static-linking
  the shim into the stub (impossible — libstdc++ ABI), per-program native
  codegen (out of scope by the locked "embedded IR snapshot, no native
  code generation" decision), and per-program dead-code elimination at the
  machine-code level (the win lives in IR-level pruning instead —
  `src/interp_ir/prune.zig` already strips dead AST bodies, and image
  tree-shaking is the listed future mitigation).

---

## 1. CLI surface and UX

```
klio bundle <main.kt | project-dir> [options]

  -o, --output <path>        Output executable (default: source basename,
                             `.exe` appended on windows targets)
  --target <target>          linux-x64 (default: host), linux-arm64,
                             macos-x64, macos-arm64, windows-x64, windows-arm64
  --ui | --headless          Force the flavor. Default: auto-detected —
                             the pack fixpoint selecting any androidx.compose.ui*
                             pack (or klio.compose.ui) marks the bundle UI.
  --include <path[:mount]>   Embed a file or directory into the bundle's
                             resource table (repeatable). Mount defaults to
                             the path relative to the source file's directory.
  --name <string>            App display name (window title default, .app /
                             .desktop metadata). Default: output basename.
  --icon <png>               App icon source (single square PNG). Used for the
                             window icon, the PE icon resource (M6), and the
                             .app icns (M7).
  --feature <pack>/<feat>    Enable a pack feature, baked into the bundle
                             (same meaning as `klio run --feature`).
  --stub <path>              Explicit stub binary (skips self-copy/fetch).
```

Project mode: `klio bundle <dir>` reads `<dir>/klio.toml`. The manifest
gains an `[application]` table (continuing PACK-DISTRIBUTION 14.1):
`name`, `icon`, `include = [...]`, `main = "path/to/main.kt"` (optional
when the project's source roots contain exactly one `main`). Flags
override the manifest.

**First-time user, end to end (Linux, headless):**

```
$ klio bundle tool.kt -o tool
bundled tool (22.9 MB): stdlib + kotlinx.coroutines + kotlinx.serialization
$ ./tool --input data.json     # argv goes to the program's main(args)
```

**First-time user, Compose UI:**

```
$ klio bundle app.kt -o myapp
bundled myapp (78.4 MB, ui): stdlib + 14 packs + skia backend
$ ./myapp                      # opens the window; no klio, no SDL2 install
```

Bundling performs the full assemble-and-lower pipeline (the same one
`klio run` uses), so every resolution diagnostic surfaces at bundle time,
not on the user's machine. A program that does not lower cleanly does not
bundle.

**Error messages** (exact text, no spec citations per CLAUDE.md):

- Missing pack:
  `error: program imports io.ktor but the pack is not installed; run 'klio pack fetch io.ktor' first`
- Cross-target stub unavailable offline:
  `error: no cached stub for windows-x64 (klio 0.1.0); connect once to fetch it, or pass --stub <path>`
- Version mismatch at boot (stub side):
  `error: this bundle was produced by klio 0.2.0 but the runtime is 0.1.0; rebundle with a matching klio`
- Payload corruption at boot:
  `error: bundle payload hash mismatch (file truncated or modified); rebundle`
- UI bundle on a display-less machine: the existing headless fallback
  applies (`application {}` returns without opening a window); no new
  failure mode.

`klio run` remains the dev loop; `bundle` is the release step. Nothing
about `run`/`test`/`check` changes.

## 2. Bundle format

A bundle is the unmodified stub executable followed by an aligned payload
area and a fixed-size trailer. On Linux this is a plain ELF overlay
append; Windows and macOS need signature-aware placement (§2.3).

```
+--------------------------------------------------+
| stub executable (byte-identical to the release)  |
| padding to 16384-byte alignment                  |
| payload area:                                    |
|   section table (postcard, same codec as pack)   |
|   sections, each 16384-aligned when mmap-target: |
|     manifest       postcard BundleManifest       |
|     base-image     .klio-image bytes, UNcompressed|
|     program-src    user sources (path + bytes)   |
|     program-image  optional (M4), uncompressed   |
|     resources      --include VFS, zstd per entry |
|     skia-shim      UI flavor only, zstd           |
|     icon           raw PNG (window icon)          |
| trailer (72 bytes):                              |
|   magic      "KBND\0KL1"  8 bytes                |
|   payload_off u64 LE                             |
|   payload_len u64 LE                             |
|   table_off   u64 LE   (absolute)                |
|   table_len   u64 LE                             |
|   payload_hash [32]    blake3 of payload area    |
+--------------------------------------------------+
```

- **Alignment 16384**: the base-image and program-image sections are
  mmap'd directly out of the executable file (read-only `MAP_PRIVATE`,
  exactly like `stdlib_image.zig:mmapImage` does for the cache file), and
  mmap offsets must be page-aligned; 16 KiB covers macOS arm64's page
  size, so one constant serves every target.
- **No compression on image sections** — the whole point of the image
  format is lazy page-backed decode (`image.zig` header comment); zstd
  would force materialization. Resources and the shim are cold data and
  compress (the shim ~23.5 MB → ~10 MB).
- **Integrity**: `payload_hash` is blake3 over the full payload area,
  verified at boot before anything decodes. The trailer itself is
  covered by the version fields inside the manifest (hash-covered).
- **`BundleManifest`** (postcard struct, versioned like `PackManifest`):
  klio version string, image `FORMAT_VERSION`, flavor (headless/ui),
  app name, entry ("main" FQN when program-image is present), embedded
  pack ids + versions + resolved features (for `--version`-style
  introspection and diagnostics), `binding_fqns` + `known_packages`
  replay lists (the image already serializes these — `image.zig`
  `ImageRoot.known_packages`/`binding_fqns`), and the resource table
  (mount path → section offset, length, uncompressed length).

### 2.1 What gets baked

At bundle time, klio runs the exact assembly `klio run` performs today:
parse the program, run the pack import fixpoint
(`pack_cache.loadInstalledPacks`), and bake **one dependency-base image**
containing the lowered stdlib plus every selected pack — the same
`image.bake` the `~/.klio/cache` path uses (`stdlib_image.zig`), but
written into the bundle instead of the cache, with `KEEP_IMAGES`
irrelevant and the exe-stamp key ingredient dropped (the manifest version
fields replace it).

The user program itself ships two ways:

- **M1 (always works): `program-src`** — the user's source files embedded
  verbatim. Boot parses them and extends the base exactly like the warm
  cache path (`stdlib_image.finishFromLoaded` →
  `buildModuleFilesExtend`). This is the measured 36 ms hello-world path,
  minus the pack-cache walk — parse+extend of one file is milliseconds.
- **M4 (fast path): `program-image`** — the fully-extended `BuiltModule`
  (base + user decls) baked as a whole-program image, so boot is mmap →
  `image.load` → `Vm.fromBuilt` → run, with zero parsing or lowering.
  The bake can refuse (the same non-serializable-surface gate that
  produces `.unbakeable` tombstones today); on refusal the bundler falls
  back to `program-src` silently and records the fallback in the
  manifest. Nothing user-visible breaks; startup is the only difference.

Host bindings are never serialized (they are function pointers): boot
recomputes `mergedHostBindings` and replays `binding_fqns` /
`known_packages` from the manifest, erroring hard on an unresolvable
symbol (which can only mean a version-mismatched stub, already refused
earlier).

### 2.2 Boot probe

`src/main.zig` gains one call before CLI dispatch: `cli.bootBundle`.

1. Resolve the own-executable path (per-OS, as `exeStamp` does; never
   trust bare argv[0]).
2. Read the trailer candidate (72 bytes) from the platform-specific tail
   position (§2.3). No magic → return null, proceed to the normal CLI.
   Cost: one `open` + one small `pread`.
3. On magic: verify version fields, mmap the payload area, blake3-check,
   decode the section table, and boot. **argv[1..] belongs entirely to
   the program** — `fun main(args: Array<String>)` receives it; klio
   subcommands are unreachable from a bundle.
4. `KLIO_BUNDLE_INSPECT=1 ./myapp` prints the manifest (versions, packs,
   sections, sizes) and exits — the only bundle-mode CLI affordance.
   The `KLIO_*` diagnostic env vars (GC, profiling, tracing) keep
   working; the `~/.klio` cache and pack directories are **never
   consulted** in bundle mode.

### 2.3 Per-OS payload placement (the signing problem)

Appending bytes after the linked image is free on ELF, breaks Authenticode
tail placement on PE, and is fatal on Mach-O arm64 (the kernel SIGKILLs
invalidly-signed arm64 binaries). Deno solved this in 1.46 by moving the
payload into structured locations (libsui: ELF note / PE resource / Mach-O
section + ad-hoc re-sign). klio commits to the lighter variant that keeps
mmap-ability and one writer:

- **Linux (ELF)**: plain overlay append + trailer at EOF. No signature
  exists to break; the AppImage ecosystem is precedent for large appended
  overlays. Probe position: `EOF - 72`.
- **Windows (PE)**: overlay append + trailer at EOF. Authenticode hashes
  the overlay and appends the certificate table after it (the NSIS
  model), so `signtool` works on a bundle **after** bundling. Probe
  position: `EOF - 72`; if that misses and the PE has a security
  directory entry, retry at `cert_table_offset - 72` (so a signed bundle
  still boots). Subsystem/icon patching happens before the append (§6).
- **macOS (Mach-O)**: append the payload, patch the `__LINKEDIT` segment
  size to cover it, and re-sign ad hoc (SHA-256 CodeDirectory, identity
  `-`), implemented natively in `src/cli/macho_sign.zig` — this is what
  sui does on x86_64 and what the arm64 kernel requires. Probe position:
  parse the own binary's `LC_CODE_SIGNATURE` load command; the trailer
  sits at `codesig_dataoff - 72`. A developer re-signing with a real
  identity afterwards (`codesign -f -s "Developer ID" myapp`) replaces
  only the signature blob; the payload and trailer stay put and the probe
  still lands.

One inherited caveat (documented, from libsui): binary packers (UPX) hide
overlays/sections — pack nothing, or inject after packing. klio does not
support packing bundles.

## 3. Runtime stubs

**One stub per target, and the stub is the `klio` binary itself.** There
is no separate slim runtime and no separate headless/UI stub binary:

- Measured on this checkout: `klio` ReleaseSafe stripped is **13.6 MB**
  (includes the 4.1 MB embedded stdlib pack and the 0.65 MB symbol
  index). ReleaseFast is comparable. A dedicated runtime-only binary
  would save little: the parser must stay (the `program-src` boot path),
  the interpreter dominates, and the CLI dispatch layer is noise. One
  artifact per target keeps release CI, fetching, caching, and version
  pinning trivial, and makes same-target bundling a self-copy.
- Stripping is safe: user-facing stack traces are Kotlin-level, rendered
  from spans via `span.active_map`, not native symbols.
- **UI is a payload property, not a stub flavor.** The `compose_ui`
  module (always compiled in) dlopens the shim by name/env
  (`compose_ui.zig:openSkiaLib`). A UI bundle embeds the shim blob; a
  headless bundle simply doesn't. This kills the flavor matrix: 6 stub
  artifacts, not 12.

### 3.1 The Skia shim in UI bundles: embed + extract, committed

Options weighed:

| Option | Verdict |
|---|---|
| Static-link Skia into the stub | Impossible. The prebuilt Skia archives use the GNU libstdc++ ABI on Linux (`-D_GLIBCXX_USE_CXX11_ABI=0`); `zig cc`/libc++ cannot link them (`build.zig:buildSkiaShim` doc). |
| Ship the `.so` next to the executable | Breaks the single-file contract; users move binaries. |
| **Embed zstd'd shim; extract on first launch to a per-user cache; dlopen the extracted path** | **Committed.** One file to distribute; extraction is a one-time ~24 MB write (tens of ms on any SSD); the cache is content-addressed so upgrades and co-installed bundles coexist. |

Mechanics: extract to `$XDG_CACHE_HOME/klio/shim/<blake3-16>/libklio_skia.so`
(macOS `~/Library/Caches/klio/shim/...`, Windows
`%LOCALAPPDATA%\klio\shim\...`), write via temp file + rename (the
`stdlib_image.zig:writeAtomic` pattern — concurrent first launches are
safe and idempotent), then pass the path straight into `loadSkia` (a new
explicit-path parameter beside the existing `KLIO_SKIA_LIB` env probe).
If the target directory is unwritable, fall back to the system temp dir;
if that fails, the UI program gets the existing headless fallback plus a
clear stderr line. A memfd/`/proc/self/fd` dlopen was considered for
Linux and rejected: Windows `LoadLibrary` and macOS `dlopen` need real
files, and one mechanism beats three.

**Shim dependency closure (must shrink for bundles):**

- Today `libklio_skia.so` carries `DT_NEEDED` on `libSDL2-2.0.so.0`
  (ldd-verified) — an end-user install dependency, unacceptable for
  double-click UX. **Commit: the release shim links SDL2 statically.**
  SDL2 is zlib-licensed (static linking explicitly permitted, no source
  obligations); a static, `-fPIC` libSDL2 built in CI joins the Skia
  archives in `third_party/` (`scripts/fetch-sdl.sh`, mirroring
  `fetch-skia.sh`). Statically-linked SDL still dlopens the host's
  X11/Wayland/audio client libraries at runtime, so one Linux shim covers
  both display servers. The dev-machine build keeps dynamic SDL2 (the
  current `detectSdl` path) — only the released stub artifacts require
  the static variant.
- `libstdc++.so.6`/`libgcc_s`/glibc remain dynamic — present on every
  desktop Linux distribution (same class of floor as Deno's glibc
  requirement). Document the glibc minimum from the CI builder image.
- Windows shim (`klio_skia.dll`, Win32 backend, no SDL): link the CRT
  statically (`/MT`-equivalent) so no VC++ redistributable is needed.
  macOS shim: system frameworks only, nothing to do.
- **Fonts**: the shim already embeds the NotoSansMono fallback subset
  (15 KB, `font_data.cpp`) and registers app fonts via
  `klio_skia_font_register`. App-supplied fonts ride the `resources`
  section and register at boot from a manifest `fonts = [...]` list —
  no font files on disk.

### 3.2 Size and startup expectations

| Bundle | Contents | Size (est., zstd where applicable) | Startup target |
|---|---|---|---|
| hello (headless) | stub 13.6 + base image 8.3 + src | ~23 MB | < 50 ms (measured 36 ms today on the equivalent warm path; M4 lowers it further) |
| ktor server | + coroutines/io/serialization/ktor in the base image | ~30–35 MB | < 150 ms |
| Compose UI app | + compose pack set in image (packs total ~35 MB installed; image adds its lowered form) + shim ~10 MB zstd | ~75–110 MB | first frame < 1 s cold (includes one-time shim extraction), < 500 ms warm |

Mitigations, in force from day one: ReleaseFast + strip; zstd on
resources/shim; `prune.stripDeadBodies` already removes dead AST weight
from images. Future (out of scope here, noted for the roadmap): IR-level
tree-shaking of unreferenced pack decls at bundle time — images are IR,
so this is a reachability walk, not a linker feature.

Determinism: two `klio bundle` runs over identical inputs with the same
klio version produce byte-identical output. The image bake is already
required to be byte-reproducible (the parity `base_gen` caching depends
on it; map iterations are sorted). The bundler adds no timestamps; the
manifest's version fields are the only environment-derived bytes. An
itest asserts the double-bundle hash equality.

## 4. Cross-bundling

- Target names use klio's existing OS-arch vocabulary
  (`third_party/skia/<os>-<arch>`): `linux-x64`, `linux-arm64`,
  `macos-x64`, `macos-arm64`, `windows-x64`, `windows-arm64`.
- `--target` resolves a stub + (for UI) a shim blob for that target:
  1. `--stub` explicit path, else
  2. `~/.klio/stubs/<klio-version>/<target>/` cache (also seeded by
     `KLIO_STUB_DIR`), else
  3. fetch `klio-<version>-<target>[.exe]` and
     `klio-skia-<version>-<target>.zst` from the GitHub release for the
     bundler's own version, verify against the sha256 manifest **baked
     into the bundling binary at release build time**, cache, proceed.
- The stub must be the same klio version as the bundler — enforced, not
  advised. Images are consumed across targets but only within one
  version; `FORMAT_VERSION` plus the release manifest guarantee it.
- Release CI (`.github/workflows/release.yml`): the Zig side
  cross-compiles all six stubs from one Linux runner (`zig build
  -Dtarget=... -Doptimize=ReleaseFast`); the shim cannot cross-compile
  (per-OS C++ driver + ABI, `build.zig:buildSkiaShim` doc), so shim jobs
  run on `ubuntu-latest` / `macos-14` / `windows-latest` runners with the
  Skia prebuilts from `scripts/fetch-skia.sh` and static SDL2 on Linux.
  Artifacts: 6 stubs, 6 shims, one `stubs-manifest.json` (name → sha256)
  that is committed back into the source tree for the release tag build.
- Offline story: same-target never touches the network; cross-target
  works offline once the cache is seeded (or via `--stub`/`KLIO_STUB_DIR`).
  CI tests never fetch — they point `KLIO_STUB_DIR` at freshly built
  artifacts.
- Cross-bundled Windows/macOS binaries get their PE/Mach-O patching done
  from Linux (the patchers are pure byte surgery in Zig — no host tools),
  including the macOS ad-hoc signature (§2.3); this is exactly why
  `macho_sign.zig` is implemented natively rather than shelling to
  `codesign`.

## 5. Dev experience

- `klio run` stays the inner loop; `bundle` is a release action. No
  watch/incremental bundling.
- Bundling is fast: the dominant cost is the base-image bake, which the
  `~/.klio/cache` machinery has usually already done for `klio run` of
  the same program — the bundler reuses a cache hit when the key matches
  (same packs, features, stdlib) and rebakes otherwise. Target: < 5 s
  warm, < 60 s cold for the full Compose set.
- Reproducible output (§3.2) makes bundles diffable and CI-cacheable.
- `klio bundle --dry-run` prints the resolved pack set, flavor, sections,
  and projected size without writing (cheap CI guard against accidental
  UI-flavor or pack-set growth).

## 6. Desktop integration for Compose bundles

- **Window icon (all OSes)**: new shim entry
  `klio_win_set_icon(rgba_pixels, w, h)` (SDL: `SDL_SetWindowIcon`;
  Win32: `WM_SETICON`; Cocoa: `NSApplication.applicationIconImage`).
  The `icon` section's PNG is decoded via the existing Skia image
  facilities and applied when the first window opens. `--name` feeds the
  default window title.
- **Linux**: a bare ELF does not reliably double-click on stock GNOME
  (Nautilus removed binary launching). The bundle itself stays a plain
  executable (terminal-first, matching the CLI story); for GUI-first
  distribution, `klio bundle --desktop-dir <out>` additionally emits
  `<name>.desktop` + the icon PNG the user (or a package) can install.
  AppImage is deliberately out of scope for now — it layers cleanly on
  top later (ELF stub + squashfs, same appended-payload family) and
  brings the libfuse2 support burden; the plan notes it as follow-on.
- **Windows**: `--ui` bundles get the PE subsystem field flipped to
  `IMAGE_SUBSYSTEM_WINDOWS_GUI` (2-byte patch in the optional header +
  PE checksum fix, done on the stub copy **before** the payload append
  and before any signing) so double-click opens no console window;
  headless bundles stay `CONSOLE` so stdout works in terminals and
  scripts. Consequence documented: a GUI-subsystem bundle's `println`
  goes nowhere when launched from Explorer. `--icon` becomes an
  `RT_GROUP_ICON`/`RT_ICON` resource rewrite (rcedit-style, in
  `src/cli/pe_patch.zig`) with .ico generation from the PNG.
- **macOS**: `--app-dir <out>` emits `Name.app/Contents/`
  (`Info.plist` with CFBundleIdentifier/name/icon, `MacOS/<name>`,
  `Resources/icon.icns` generated from the PNG). The inner binary is the
  ad-hoc-signed bundle; users with a signing identity re-sign the .app
  (`codesign --deep -f -s ...`) — payload placement survives re-signing
  (§2.3). Notarization is the user's release process, not klio's.

## 7. Implementation milestones

Ordering is Linux-first; M1–M4 land and gate entirely on Linux CI.
Every milestone ships its tests in the same commit series; the suite
names below follow the existing `src/itests/` + `build.zig` `itests_files`
conventions (`needs_exe` suites spawn the harness `klio`).

**M1 — bundle core, headless, same-target Linux.**
- `src/pack/bundle_format.zig`: trailer + section table + `BundleManifest`
  codec (reuses the pack postcard primitives), alignment, blake3.
  Unit tests: round-trip, corruption, alignment invariants, trailer
  probe negative on the plain binary.
- `src/cli/bundle.zig`: the `bundle` subcommand — assemble (parse, pack
  fixpoint, base-image bake or cache reuse, program-src section), copy
  self-exe as stub, append, patch nothing yet.
- `src/cli/bundle_boot.zig` + the `cli.bootBundle` probe called from
  `src/main.zig`: self-exe resolution, trailer read, mmap, hash check,
  manifest decode, base-image load, program-src parse + extend
  (`buildModuleFilesExtend`), bindings replay, run `main` with argv[1..].
- `src/cli/cli.zig`: usage text + dispatch.
- itest `bundle_smoke` (`needs_exe`): bundles `examples/hello.kt` and a
  pack-using program (kotlinx.serialization) under a scratch HOME, runs
  the bundle with HOME pointed at an empty dir and no repo cwd, asserts
  stdout/exit byte-identical to `klio run`; corrupts a payload byte and
  asserts the hash-mismatch message; asserts argv passthrough into
  `main(args)`; asserts `KLIO_BUNDLE_INSPECT=1` output shape.
- Docs: `docs/BUNDLE.md` + README section.

**M2 — resources and program surface.**
- `--include` → `resources` section; host bindings
  `klio.bundle.Resources.readBytes/readText/list` served from the mmap
  (new FQNs in the stdlib binding registry; a klio-authored
  `kotlin-klio/klio-bundle` actual surface).
- Exit-code fidelity (program `exitProcess` value is the process exit),
  stdin passthrough.
- itest additions: resource round-trip (binary + text), missing-resource
  exception, exit code.

**M3 — UI bundles on Linux.**
- `skia-shim` + `icon` sections; the extractor
  (`src/cli/shim_extract.zig`) with the content-addressed cache dir +
  atomic rename; `loadSkia` explicit-path parameter in
  `src/compose_ui/compose_ui.zig`.
- Static-SDL2 release shim: `scripts/fetch-sdl.sh`, `build.zig` link
  variant `-Dsdl-static` used by release CI only.
- `klio_win_set_icon` + title plumb-through in `skia_shim.cpp` /
  `compose_ui.zig`.
- Flavor auto-detection off the fixpoint pack set; `--ui/--headless`
  override.
- itest `bundle_ui` (`needs_exe`): bundles a headless-render Compose
  program (offscreen Skia → PNG checksum, the established pixel-gate
  pattern) with the shim embedded, scratch HOME, empty
  `LD_LIBRARY_PATH`, no `KLIO_SKIA_LIB`; asserts the render checksum and
  that the shim extracted to the scratch cache dir; second run asserts
  extraction is skipped. Windowed double-click verification is manual
  (display required), documented in the itest header.

**M4 — whole-program image.**
- `image.zig`: program bake — the extended `BuiltModule` (base + user
  decls) through the existing codec; a `canBakeProgram` gate mirroring
  the base gate; loader path that skips `buildModuleFilesExtend`
  entirely. This is the "no re-lowering at boot" end state.
- Bundler prefers `program-image`, falls back to `program-src` on
  refusal (recorded in the manifest; `--dry-run` reports it).
- Determinism itest (double-bundle byte equality) + startup benchmark
  in `bench/` (hello bundle boot vs `klio run` warm; gate: bundle ≤
  warm-run).

**M5 — cross-target stubs and release CI.**
- `.github/workflows/release.yml`: six Zig stub cross-builds from Linux,
  three per-OS shim jobs, `stubs-manifest.json` generation; artifacts on
  the GitHub release.
- `src/cli/stub_fetch.zig`: resolve order (`--stub`, `KLIO_STUB_DIR`,
  `~/.klio/stubs`, HTTPS fetch + sha256 verify against the baked
  manifest).
- `--target` in `bundle.zig`; cross-assembly never executes the target
  stub, so the only host requirement is byte surgery.
- itest `bundle_cross`: bundles for a *fake* target from a local
  `KLIO_STUB_DIR` (a copy of the host stub under the target's name) and
  boots it (host-runnable since it is really a host stub) — exercises
  the fetch/cache/verify path without network; a checksum-mismatch case
  asserts refusal.

**M6 — Windows.** (first non-Linux milestone; needs the Windows CI
runner and the unverified Win32 backend brought up)
- `src/cli/pe_patch.zig`: subsystem flip + checksum, `.ico` generation +
  icon resource rewrite; cert-table-aware trailer probe in
  `bundle_boot.zig`.
- Static-CRT shim build on the Windows runner; verify the Win32 window
  backend (currently written-but-unverified) as part of this milestone —
  root-cause any backend defects, do not gate bundling on renderer bugs
  that also affect `klio run`.
- Windows CI job running `bundle_smoke` + the headless-render UI gate;
  sign-after-bundle verification with a self-signed cert (`signtool` +
  boot).

**M7 — macOS.**
- `src/cli/macho_sign.zig`: `__LINKEDIT` extension + ad-hoc SHA-256
  CodeDirectory writer; `LC_CODE_SIGNATURE`-aware probe.
- `--app-dir` emitter (`Info.plist`, icns from PNG).
- Cocoa backend verification on the macos-14 runner; `bundle_smoke` +
  re-sign-then-boot test (`codesign -f -s -` over the bundle, assert it
  still boots).

**M8 — desktop polish.**
- `--desktop-dir` emitter on Linux; window icon verified on all three
  backends; `[application]` klio.toml table + project-mode bundling;
  `--dry-run`.
- examples/README + docs pass; `scripts/gate.sh` includes `bundle_smoke`.

## 8. Risks and open questions (with resolutions)

| Risk | Resolution |
|---|---|
| **Image portability across targets.** The codec is varint/LE by construction, but (a) floats encode via `std.mem.toBytes` (native byte order) and (b) `usize`-typed fields decode through `std.math.cast`. | All six targets are little-endian and 64-bit, so both are non-issues within the support matrix. Still: normalize float encode/decode through an explicit LE bitcast in `image.zig`/`write.zig` (cheap, removes the trap) and add a codec unit test asserting the encoded bytes of a known f64. Do this in M1 while touching the codec. |
| **Program-image bake refusal** (the `.unbakeable` class: non-serializable build surface, base-name collisions). | Designed in: `program-src` is the always-works path (M1); `program-image` is an optimization with silent fallback (M4). The bundle never fails for bake reasons. |
| **Cross-version stub/image skew.** | Hard-enforced version equality between bundler and stub; manifest carries klio version + `FORMAT_VERSION`; boot refuses mismatches with the exact message in §1. |
| **Skia shim for Windows/macOS is unverified.** | M6/M7 verify the backends on real runners as part of the milestone. The shim build recipes exist (`buildSkiaShim` handles all three OSes); risk is bring-up debugging, not design. |
| **SDL2 static linking.** | zlib license explicitly permits static linking with no obligations. Static SDL still runtime-dlopens X11/Wayland client libs, preserving the one-shim-covers-both property. Keep the dynamic-SDL dev build so local iteration doesn't need the static archive. |
| **libstdc++/glibc floor on Linux.** | Accepted (Deno-equivalent). Build release shims/stubs on the oldest supported builder image; document the resulting glibc/libstdc++ minimums in docs/BUNDLE.md. Musl-static stubs are possible for *headless* later (no dlopen needed) — noted, not committed. |
| **macOS signing.** | Ad-hoc sign natively at bundle time (M7); re-signing by the developer is supported by construction (§2.3). Notarization/stapling is downstream of klio. |
| **Windows Authenticode vs the EOF trailer.** | Cert-table-aware probe fallback (§2.3, M6); verified in CI with a self-signed cert. |
| **Icon/GUI-subsystem patch before vs after signing.** | All PE patching happens on the stub copy before the payload append; signing is always last. Documented order in docs/BUNDLE.md. |
| **Concurrent/interrupted shim extraction.** | Content-addressed dir + temp-file + atomic rename (existing `writeAtomic` pattern); a torn temp file is invisible. |
| **Bundle-time pack availability** (bundling machine lacks a pack). | Same failure as `klio run` today, surfaced at bundle time with the fetch hint; no new mechanism. |
| **Huge UI bundles.** | Sizes are honest (§3.2) and in family with Electron/Deno-UI norms. The committed mitigations (strip, zstd, prune) land in M1–M3; IR tree-shaking is the named follow-on with real headroom because images are IR, not machine code. |
| **GNOME double-click reality.** | Terminal-first stance + `--desktop-dir`; AppImage follow-on documented rather than half-shipped. |

## 9. Test strategy summary

- **Unit** (`zig build test`): `bundle_format` codec round-trips, trailer
  probe negatives, float-LE codec guard, PE/Mach-O patcher byte-level
  tests against tiny fixture binaries under `tests/fixtures/bundle/`.
- **Integration** (`zig build itest-bundle_smoke`, `-bundle_ui`,
  `-bundle_cross`): real `klio` child (`needs_exe`), scratch HOME, empty
  env, byte-identical-output assertions against `klio run`, corruption /
  version-skew / resource / argv / extraction cases. Wired into
  `itests_files` with weights; `bundle_smoke` joins `scripts/gate.sh`.
- **Examples/docs**: `docs/BUNDLE.md` end-to-end walkthroughs (headless +
  UI); the smoke tests bundle existing `examples/*.kt` programs so the
  corpus keeps a single source of truth.
- **Benchmarks**: bundle boot time in `bench/` gated ≤ warm `klio run`
  (M4).
