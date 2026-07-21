# Bundling programs

`klio bundle` packages a Kotlin program — with its baked dependency
image, embedded resources, and (for Compose programs) the Skia
rendering backend — into one self-contained native executable. The
result runs on a machine with no klio, no Kotlin, no toolchain, and
no `~/.klio`. It serves both program classes klio runs:

- **CLI tools and servers** — headless programs using the stdlib and
  packs (kotlinx, ktor).
- **Compose UI desktop apps** — the real androidx Compose engine over
  the Skia backend, windowed through the platform's native layer
  (SDL2 on Linux, Cocoa/Metal on macOS).

Linux and macOS are supported today. Windows is planned; its stub
builds and its window backend exist, but the PE overlay placement is
not wired yet.

No compiler or linker is ever invoked. Bundling is file surgery: the
target's `klio` binary is copied as the runtime stub, the payload is
placed in an aligned overlay, and a 72-byte trailer marks it. The
exact placement of that overlay is per-OS (see
[Platform behavior](#platform-behavior)), but the format and the boot
path are identical everywhere.

## Quick start

Save this to `hello.kt`:

```kotlin
fun main() {
    println(1 + 1)
}
```

Bundle it, then run the output like any executable:

```sh
$ klio bundle hello.kt -o hello
bundled hello (22.3 MB): stdlib
$ ./hello
2
```

Arguments after the executable name go straight to the program's
`main(args: Array<String>)` — a bundle has no klio subcommands.

Bundling runs the full assemble-and-lower pipeline (the same one
`klio run` uses), so every resolution diagnostic surfaces at bundle
time, not on the user's machine. A program that does not lower
cleanly does not bundle. `klio run` stays the dev loop; `bundle` is
the release step.

## Command reference

```
klio bundle <main.kt | project-dir> [options]

  -o, --output <path>        Output executable (default: source basename;
                             `.exe` appended for windows targets)
  --target <target>          Host target by default; one of linux-x64,
                             linux-arm64, macos-x64, macos-arm64,
                             windows-x64, windows-arm64
  --ui | --headless          Force the flavor. Default: auto-detected — the
                             pack fixpoint selecting any androidx.compose.ui*
                             pack (or klio.compose.ui) marks the bundle UI.
  --include <path[:mount]>   Embed a file or directory into the bundle's
                             resource table (repeatable). Mount defaults to
                             the path relative to the source file's directory.
  --name <string>            App display name (window title default).
                             Default: output basename.
  --icon <png>               App icon source (single square PNG); applied as
                             the window icon and in the .app/.desktop metadata.
  --feature <pack>/<feat>    Enable a pack feature, baked into the bundle
                             (same meaning as `klio run --feature`).
  --stub <path>              Explicit stub binary (skips self-copy/fetch).
  --desktop-dir <dir>        Also emit <name>.desktop + the icon PNG for
                             GUI-first Linux distribution.
  --app-dir <dir>            Also emit <name>.app around the bundle for macOS.
  --dry-run                  Print the resolved pack set, flavor, sections,
                             and projected size without writing.
```

Every flag also accepts the `--flag=value` form.

A feature-gated pack surface is enabled the same way as at run time,
and the choice is baked into the bundle:

```sh
$ klio bundle serial_tool.kt --feature kotlinx.serialization/json -o serial_tool
bundled serial_tool (23.4 MB): stdlib + kotlinx.serialization
```

## Sizes and startup

Bundle size is dominated by the stub — a byte-for-byte copy of the
`klio` binary doing the bundling. Measured on linux-x64 with a
release build (`zig build -Doptimize=ReleaseFast`, stripped):

| Bundle                                   | Size    | Startup                                  |
|------------------------------------------|---------|-------------------------------------------|
| hello world                               | 22.3 MB | 20 ms (warm `klio run`: 27 ms)             |
| kotlinx.serialization CLI tool            | 23.4 MB | 24 ms                                      |
| Compose UI app (klio.compose.ui + shim)   | 44.3 MB | 119 ms first launch, 100 ms warm           |

A bundle starts faster than `klio run` runs the same file: the
program is baked as a whole-program IR image that boot mmaps straight
out of the executable and runs, with zero parsing or lowering.

macOS bundles are the same shape (stub-dominated); the ad-hoc code
signature adds the CodeDirectory's page hashes (~0.8% of the file, 32
bytes per 4 KiB) on top.

A default `zig build` produces a Debug binary, so bundles made with
it are dev-sized (hundreds of MB). Build the bundling `klio` with
`-Doptimize=ReleaseFast` (and `strip` it) for release-sized output.

## Embedded resources

`--include <path[:mount]>` embeds a file or a whole directory into
the bundle. The program reads them back through the `klio.bundle`
pack, which ships in-repo under `kotlin-klio/klio-bundle` and is
installed like any other pack:

```sh
klio pack build kotlin-klio/klio-bundle
klio pack install target/packs/klio.bundle.klio-pack
```

Given this layout, where `greeting.txt` contains
`hello from a bundled resource`:

```
app/
├── main.kt
└── assets/
    └── greeting.txt
```

```kotlin
// app/main.kt
import klio.bundle.Resources

fun main(args: Array<String>) {
    println("args: " + args.joinToString(","))
    println(Resources.readText("assets/greeting.txt").trim())
    println(Resources.list())            // every mount path, sorted
    println(Resources.exists("missing.txt"))
}
```

```sh
$ klio bundle app/main.kt --include app/assets -o resapp
bundled resapp (22.4 MB): stdlib + klio.bundle
$ ./resapp one two
args: one,two
hello from a bundled resource
[assets/greeting.txt]
false
```

`Resources` exposes four functions: `readBytes(path): ByteArray`,
`readText(path): String`, `exists(path): Boolean`, and
`list(): List<String>`. The mount path defaults to the included path
relative to the main source's directory (basename when it is not
under it); an explicit `:mount` overrides it. Resources are served
straight from the executable's memory map (zstd-compressed entries
decompress on read).

Reading a path that was not bundled throws
``IllegalArgumentException: no bundled resource at `path` ``;
calling `readBytes`/`readText` outside a bundle (for example under
`klio run`) throws
`IllegalStateException: no resources are bundled with this program`.

## Project mode

`klio bundle <dir>` reads `<dir>/klio.toml`. The manifest's
`[application]` table supplies `name`, `icon`, `include = [...]`, and
`main = "path/to/main.kt"`. `main` is optional when exactly one file
under the project's source roots declares a top-level `main`; with
several, the manifest must name it. The whole project source set is
bundled, and flags override the manifest.

```toml
[application]
name = "MyApp"
icon = "assets/icon.png"
main = "src/main.kt"
include = ["assets"]
```

```sh
$ klio bundle myproject -o myapp
bundled myapp (22.4 MB): stdlib + klio.bundle
```

## Inspecting a bundle

`--dry-run` shows what a bundle would contain without writing it:

```sh
$ klio bundle app/main.kt --include app/assets --dry-run
bundle (dry run): main
flavor: headless
entry: main
packs:
  klio.bundle 0.1.0
sections:
  manifest 411 bytes
  program-src 263 bytes
  program-image 8421445 bytes
  resources 30 bytes
projected size: 22.4 MB (stub 14.4 MB + payload 8.1 MB)
```

`KLIO_BUNDLE_INSPECT=1 ./myapp` prints the same manifest from a
finished bundle (versions, packs, sections, resources) and exits —
the only bundle-mode CLI affordance:

```sh
$ KLIO_BUNDLE_INSPECT=1 ./resapp
bundle: resapp
klio: 0.1.0 (image format 21)
flavor: headless
entry: main
packs:
  klio.bundle 0.1.0
sections:
  manifest 413 bytes (413 uncompressed)
  program-src 263 bytes (263 uncompressed)
  program-image 8421445 bytes (8421445 uncompressed)
  resources 30 bytes (30 uncompressed)
resources:
  assets/greeting.txt 30 bytes
```

## Program surface

- `fun main(args: Array<String>)` receives the bundle's `argv[1..]`
  verbatim; klio subcommands are unreachable from a bundle.
- `kotlin.system.exitProcess(code)` terminates the process with `code`.
- stdin passes through (`readLine()` reads the process stdin).
- The `KLIO_*` diagnostic environment variables (GC, profiling,
  tracing, `KLIO_OPT`) keep working. The `~/.klio` cache and pack
  directories are never consulted in bundle mode.

## UI bundles

A program whose pack fixpoint selects any `androidx.compose.ui*` pack
(or `klio.compose.ui`) bundles as UI automatically; `--ui` and
`--headless` force it. A UI bundle embeds the Skia rendering backend
(zstd-compressed). Bundling one requires the backend library next to
the bundling `klio` (`zig build skia-lib`) or at `KLIO_SKIA_LIB`. The
library name is per-OS: `libklio_skia.so` (Linux), `libklio_skia.dylib`
(macOS), `klio_skia.dll` (Windows).

```sh
$ klio bundle counter.kt -o counter
bundled counter (42.3 MB, ui): stdlib + androidx.collection + androidx.compose.runtime + klio.compose.ui + kotlinx.atomicfu + kotlinx.coroutines + skia backend
$ ./counter     # opens the window; no klio and no rendering install needed
```

On first launch the shim is extracted to a content-addressed per-user
cache via temp file + atomic rename — concurrent first launches are
safe, upgrades and co-installed bundles coexist, and later launches
skip the write. The cache directory is per-OS:

- Linux: `$XDG_CACHE_HOME/klio/shim/<blake3-16>/libklio_skia.so`
  (default `~/.cache/...`).
- macOS: `~/Library/Caches/klio/shim/<blake3-16>/libklio_skia.dylib`.
- Windows: `%LOCALAPPDATA%\klio\shim\<blake3-16>\klio_skia.dll` (planned).

If the cache directory is unwritable the shim falls back to the system
temp dir; if that also fails the program runs headless with one stderr
line.

The Linux release shim links SDL2 statically (`scripts/fetch-sdl.sh` +
`zig build skia-lib -Dsdl-static`), so end users need no SDL2 install;
statically-linked SDL still dlopens the host's X11/Wayland client
libraries at runtime, so one shim covers both display servers. Dev
builds keep dynamic SDL2. `libstdc++`/`glibc` remain dynamic — present
on every desktop Linux distribution.

The macOS shim uses the Cocoa window layer and the Metal GPU path
(with a CPU raster fallback), linking only system frameworks
(AppKit, Metal, QuartzCore, …) — nothing for the end user to install.

### Desktop integration

- **Linux**: a bare executable does not reliably double-click on
  stock GNOME. The bundle itself stays a plain executable
  (terminal-first); `--desktop-dir <out>` additionally emits
  `<name>.desktop` plus the icon PNG for the user (or a package) to
  install under `~/.local/share/applications`.
- **macOS**: `--app-dir <out>` wraps the bundle in
  `<name>.app/Contents/` (`Info.plist`, `MacOS/<name>` = the bundle,
  `Resources/icon.icns` generated from `--icon`) so it double-clicks
  and shows a name/icon in the Dock. The inner binary is the
  ad-hoc-signed bundle; the `.app` itself is not sealed. For
  distribution, seal it with your identity:
  `codesign --deep -f -s "Developer ID Application: …" <name>.app` —
  the bundle payload and its trailer survive re-signing (see
  [Platform behavior](#platform-behavior)).

## Platform behavior

The bundle format and boot path are identical on every target; only
where the overlay sits in the host binary format differs.

- **Linux (ELF)** — the payload is a plain overlay appended after the
  linked image, with the trailer at `EOF - 72`. No signature exists
  to disturb; the AppImage ecosystem is precedent for large appended
  overlays.

- **macOS (Mach-O)** — a Mach-O cannot simply carry trailing data:
  the arm64 kernel refuses a binary whose bytes extend past its code
  signature, and such a binary cannot be re-signed. So `klio bundle`
  strips the stub's own signature, places the overlay where it was,
  extends the `__LINKEDIT` segment to cover it, and writes a fresh
  ad-hoc SHA-256 code signature over the whole image. The trailer
  lands immediately before the new signature, at
  `LC_CODE_SIGNATURE.dataoff - 72`, which is where boot reads it. This
  is done natively (no host `codesign`), so a Linux host can
  cross-assemble a signed macOS bundle. Results:
  - The bundle runs on Apple Silicon and Intel Macs with no extra
    steps, and `codesign --verify` reports it valid.
  - A developer re-signing with a real identity
    (`codesign -f -s "Developer ID" app`) replaces only the signature
    blob; the payload and trailer stay put and the bundle still boots.
  - Because the payload is inside the signature's coverage, the OS
    enforces integrity: a tampered signed bundle is rejected by the
    kernel (the process is killed on the modified page) rather than
    reaching the blake3 check. The blake3 payload hash is the tamper
    defense on ELF/PE, where the OS enforces nothing.
  - Gatekeeper only inspects quarantined downloads. A locally
    produced bundle runs directly; a distributed one should be signed
    with a real identity and notarized (your release process, not
    klio's).

- **Windows (PE)** — planned. The payload will append after the image
  with the trailer at `EOF - 72`, the GUI/console subsystem flip and
  icon resource patched before the append, and Authenticode's
  certificate table appended after it, so `signtool` works on a
  finished bundle.

Binary packers (UPX) hide overlays — do not pack bundles.

## Cross-target bundles

`--target` selects the output platform (default: the host). Same-target
bundling is always offline — the stub is the running executable.
Cross-target bundling resolves the target's stub (and, for UI, its
shim) in this order:

1. `--stub <path>` explicit.
2. `KLIO_STUB_DIR`: `<dir>/<target>/klio` (CI / air-gapped).
3. `~/.klio/stubs/<version>/<target>/` — the fetch cache.
4. An HTTPS fetch from the GitHub release of the bundler's own
   version, verified against the sha256 manifest baked into release
   binaries, then cached. Offline after the first fetch. Dev builds
   carry no manifest and refuse to fetch:
   `error: no cached stub for macos-arm64 (klio 0.1.0); connect once to fetch it, or pass --stub <path>`

Cross-assembly is pure byte surgery, so any host can target any OS —
including the macOS ad-hoc signature, which is written natively rather
than by shelling to `codesign`. The one thing that does not
cross-compile is the Skia shim (a per-OS C++/ABI build), so a UI
bundle for another OS needs that OS's shim artifact resolved alongside
its stub.

The stub must be the same klio version as the bundler — enforced, not
advised.

## Bundle format

A bundle is the unmodified stub, padding to a 16384-byte boundary, a
payload area, and a 72-byte trailer. The trailer's position is per-OS
(`EOF - 72` on ELF/PE; `LC_CODE_SIGNATURE.dataoff - 72` on the
re-signed Mach-O), and boot reads it from the right place for the host
binary format.

- **Sections**: `manifest` (encoded `BundleManifest`),
  `program-image` (deps + program lowered as one module and baked,
  uncompressed and 16 KiB-aligned so boot mmaps it straight out of
  the file and runs with zero parsing or lowering), `program-src`
  (the user sources), `resources` (zstd per entry), `skia-shim` (UI
  flavor only, zstd), `icon` (raw PNG). When the program bake refuses
  (a base outside the image codec's serializable surface) the bundle
  instead carries `base-image` (the dependency base alone) and boots
  by parsing `program-src` against it — the always-works path,
  recorded in the manifest and reported by `--dry-run`; startup is
  the only difference. `KLIO_BUNDLE_PROGRAM_IMAGE=0` at bundle time
  forces that path.
- **Trailer**: magic `"KBND\0KL1"`, payload offset/length,
  section-table offset/length, and a blake3 hash of the whole payload
  area, verified at boot before anything decodes.
- **Versioning**: the manifest carries the producing klio version and
  the image format version; a stub refuses a payload from a different
  version with an actionable error. A bundle is only ever assembled
  by the same-version binary that boots it.
- **Determinism**: two `klio bundle` runs over identical inputs (same
  sources, packs, features, output name) produce byte-identical
  output. The bundler adds no timestamps, and the macOS signature is a
  deterministic function of the signed bytes.

## Troubleshooting

Bundle-time errors:

- `error: this is a UI bundle but no Skia backend library was found for <target>; build it (zig build skia-lib) or set KLIO_SKIA_LIB`
  — a UI bundle needs the rendering backend to embed; build it or
  point `KLIO_SKIA_LIB` at one.
- `error: the macos-arm64 stub is not a code-signed Mach-O and cannot be bundled`
  — an arm64 macOS stub must carry the linker's ad-hoc signature (its
  `__TEXT`/`__LINKEDIT` layout is read to re-sign); the provided stub
  is not a normal `klio` binary.
- `error: the program redeclares a name from its dependency base and cannot bundle; rename the declaration`
  — a top-level declaration in the program collides with one in the
  stdlib/pack base; bundling requires the extendable base.
- `error: no cached stub for <target> (klio <version>); connect once to fetch it, or pass --stub <path>`
  — cross-target bundling could not resolve the target's stub (see
  the resolution order above).
- A missing pack fails exactly like `klio run` does, with the same
  fetch hint — at bundle time, not on the user's machine.

Boot-time errors (from the bundled executable itself):

- `error: this bundle was produced by klio <X> but the runtime is <Y>; rebundle with a matching klio`
  — the payload came from a different klio version than the stub
  (also raised on an image-format mismatch). Rebundle.
- `error: bundle payload hash mismatch (file truncated or modified); rebundle`
  — the blake3 payload check failed: the file was truncated,
  patched, or corrupted in transit. On macOS a tampered signed bundle
  is instead killed by the OS before this check runs.
- ``error: bundle host binding `<symbol>` does not resolve in this runtime; rebundle with a matching klio``
  — a pack's native binding recorded in the manifest is unknown to
  the stub; a version-skewed stub.
- `error: bundle section table is malformed; rebundle`,
  `error: bundle manifest is malformed; rebundle`,
  `error: bundle carries no manifest; rebundle` — the payload
  structure does not decode; the file was damaged or assembled by a
  broken tool.
- `error: bundle program image rejected (<reason>); rebundle`,
  `error: bundle names an entry but carries no program image; rebundle`
  — the whole-program image is missing or fails to load.
- `error: bundle carries no base image; rebundle`,
  `error: bundle carries no program sources; rebundle`,
  `error: embedded program sources fail to parse; rebundle`,
  `error: embedded program cannot extend the bundle base; rebundle`
  — the program-src boot path is incomplete or inconsistent.

Boot-time warnings (UI bundles; the program continues headless):

- `warning: embedded rendering backend is corrupt; running headless`
- `warning: cannot extract the rendering backend (cache and temp dirs unwritable); running headless`

A UI bundle on a display-less machine is not an error: the normal
headless fallback applies.
