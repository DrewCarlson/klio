# `klio bundle` — single-executable programs

`klio bundle main.kt -o myapp` turns a Kotlin program plus everything it
needs — the baked dependency image, embedded resources, and (for Compose
programs) the Skia/SDL2 rendering backend — into one self-contained
executable. The result runs on a machine with no klio, no Kotlin, no
toolchain, and no `~/.klio`.

Bundling is file surgery: the running `klio` binary is copied as the
runtime stub, the payload is appended in an aligned overlay, and a
72-byte trailer is written at the end. No compiler or linker is invoked,
ever — everything a program needs at run time is data (baked IR images
and pack sections), and all native code already lives in the `klio`
binary (plus the dlopen'd Skia shim for UI bundles).

## Quick start

Headless CLI tool:

```
$ klio bundle tool.kt -o tool
bundled tool (22.9 MB): stdlib + kotlinx.serialization
$ ./tool --input data.json     # argv goes to the program's main(args)
```

Compose UI app:

```
$ klio bundle app.kt -o myapp
bundled myapp (78.4 MB, ui): stdlib + 14 packs + skia backend
$ ./myapp                      # opens the window; no klio, no SDL2 install
```

Bundling performs the full assemble-and-lower pipeline (the same one
`klio run` uses), so every resolution diagnostic surfaces at bundle
time, not on the user's machine. A program that does not lower cleanly
does not bundle. `klio run` remains the dev loop; `bundle` is the
release step.

## Options

```
klio bundle <main.kt | project-dir> [options]

  -o, --output <path>        Output executable (default: source basename,
                             `.exe` appended on windows targets)
  --target <target>          linux-x64 (default: host), linux-arm64,
                             macos-x64, macos-arm64, windows-x64, windows-arm64
  --ui | --headless          Force the flavor. Default: auto-detected — the
                             pack fixpoint selecting any androidx.compose.ui*
                             pack (or klio.compose.ui) marks the bundle UI.
  --include <path[:mount]>   Embed a file or directory into the bundle's
                             resource table (repeatable). Mount defaults to
                             the path relative to the source file's directory.
  --name <string>            App display name (window title default).
                             Default: output basename.
  --icon <png>               App icon source (single square PNG); applied as
                             the window icon when the first window opens.
  --feature <pack>/<feat>    Enable a pack feature, baked into the bundle
                             (same meaning as `klio run --feature`).
  --stub <path>              Explicit stub binary (skips self-copy/fetch).
  --desktop-dir <dir>        Also emit <name>.desktop + the icon PNG for
                             GUI-first Linux distribution.
  --dry-run                  Print the resolved pack set, flavor, sections,
                             and projected size without writing.
```

Project mode: `klio bundle <dir>` reads `<dir>/klio.toml`. The manifest's
`[application]` table supplies `name`, `icon`, `include = [...]`, and
`main = "path/to/main.kt"` (optional when the project's source roots
contain exactly one `main`). Flags override the manifest.

```toml
[application]
name = "MyApp"
icon = "assets/icon.png"
main = "src/main.kt"
include = ["assets"]
```

## Embedded resources

Files embedded with `--include` are read back through the `klio.bundle`
pack (installed like any other pack; it ships in-repo under
`kotlin-klio/klio-bundle`):

```kotlin
import klio.bundle.Resources

fun main() {
    val cfg = Resources.readText("assets/config.json")
    val icon = Resources.readBytes("assets/icon.png")
    println(Resources.list())          // every mount path, sorted
    println(Resources.exists("x.txt")) // false
}
```

Reading a path that was not bundled throws `IllegalArgumentException`;
calling `readBytes`/`readText` outside a bundle throws
`IllegalStateException`. Resources are served straight from the
executable's memory map (zstd-compressed entries decompress on read).

## Program surface

- `fun main(args: Array<String>)` receives the bundle's `argv[1..]`
  verbatim; klio subcommands are unreachable from a bundle.
- `kotlin.system.exitProcess(code)` terminates the process with `code`.
- stdin passes through (`readLine()` reads the process stdin).
- The `KLIO_*` diagnostic environment variables (GC, profiling, tracing,
  `KLIO_OPT`) keep working. The `~/.klio` cache and pack directories are
  never consulted in bundle mode.
- `KLIO_BUNDLE_INSPECT=1 ./myapp` prints the manifest (versions, packs,
  sections, resources) and exits — the only bundle-mode CLI affordance.

## Bundle format

A bundle is the unmodified stub executable, padding to a 16384-byte
boundary, a payload area, and a 72-byte trailer:

- **Sections**: `manifest` (postcard-encoded `BundleManifest`),
  `program-image` (deps + program lowered as one module and baked,
  uncompressed and 16 KiB-aligned so boot mmaps it straight out of the
  file and runs with zero parsing or lowering), `program-src` (the user
  sources), `resources` (zstd per entry), `skia-shim` (UI flavor only,
  zstd), `icon` (raw PNG). When the program bake refuses (a base outside
  the image codec's serializable surface) the bundle instead carries
  `base-image` (the dependency base alone) and boots by parsing
  `program-src` against it — the always-works path, recorded in the
  manifest and reported by `--dry-run`; startup is the only difference.
  `KLIO_BUNDLE_PROGRAM_IMAGE=0` at bundle time forces that path.
- **Trailer**: magic `"KBND\0KL1"`, payload offset/length, section-table
  offset/length, and a blake3 hash of the whole payload area, verified
  at boot before anything decodes.
- **Versioning**: the manifest carries the producing klio version and
  the image format version; a stub refuses a payload from a different
  version with an actionable error. A bundle is only ever assembled by
  the same-version binary that boots it.
- **Determinism**: two `klio bundle` runs over identical inputs (same
  sources, packs, features, flags) produce byte-identical output. The
  bundler adds no timestamps.

Per-OS payload placement: on Linux (ELF) the overlay append is free and
the trailer sits at EOF. Windows needs an Authenticode-aware probe and
macOS needs the `__LINKEDIT` extension + ad-hoc re-sign; the probe seams
for both are in `src/cli/bundle_boot.zig` and land with their platform
milestones. Binary packers (UPX) hide overlays — do not pack bundles.

## UI bundles

A UI bundle embeds the Skia rendering backend (`libklio_skia.so`,
zstd-compressed). On first launch the shim is extracted to a
content-addressed per-user cache
(`$XDG_CACHE_HOME/klio/shim/<blake3-16>/libklio_skia.so`, default
`~/.cache/...`) via temp file + atomic rename — concurrent first
launches are safe, upgrades and co-installed bundles coexist, and later
launches skip the write. If the cache directory is unwritable the shim
falls back to the system temp dir; if that also fails the program gets
the existing headless fallback plus one stderr line.

The flavor is auto-detected: a program whose pack fixpoint selects any
`androidx.compose.ui*` pack (or `klio.compose.ui`) bundles as UI.
`--ui`/`--headless` force it.

The release shim links SDL2 statically (`scripts/fetch-sdl.sh` +
`zig build skia-lib -Dsdl-static`), so end users need no SDL2 install;
statically-linked SDL still dlopens the host's X11/Wayland client
libraries at runtime, so one Linux shim covers both display servers.
Dev builds keep dynamic SDL2. `libstdc++`/`glibc` remain dynamic —
present on every desktop Linux distribution; the release CI builder
image sets the supported floor.

## Cross-target bundles

`--target` selects one of `linux-x64`, `linux-arm64`, `macos-x64`,
`macos-arm64`, `windows-x64`, `windows-arm64`. Same-target bundling is
always offline (the stub is the running executable). Cross-target
bundling resolves the target's stub (and shim, for UI):

1. `--stub <path>` explicit.
2. `KLIO_STUB_DIR`: `<dir>/<target>/klio` (CI / air-gapped).
3. `~/.klio/stubs/<version>/<target>/` — the fetch cache.
4. An HTTPS fetch from the GitHub release of the bundler's own version,
   verified against the sha256 manifest baked into release binaries,
   then cached. Offline after the first fetch. Dev builds carry no
   manifest and refuse to fetch:
   `error: no cached stub for windows-x64 (klio 0.1.0); connect once to fetch it, or pass --stub <path>`

The stub must be the same klio version as the bundler — enforced, not
advised. Windows and macOS cross-bundles additionally need the PE/Mach-O
patchers, which land with those platform milestones.

## Desktop integration (Linux)

A bare ELF does not reliably double-click on stock GNOME. The bundle
itself stays a plain executable (terminal-first); for GUI-first
distribution, `--desktop-dir <out>` additionally emits `<name>.desktop`
plus the icon PNG for the user (or a package) to install under
`~/.local/share/applications`. AppImage layers cleanly on top later
(same appended-payload family) and is deliberately not built in.

## Failure modes

- Missing pack at bundle time: same failure as `klio run`, surfaced at
  bundle time with the fetch hint.
- Version mismatch at boot:
  `error: this bundle was produced by klio X but the runtime is Y; rebundle with a matching klio`
- Payload corruption at boot:
  `error: bundle payload hash mismatch (file truncated or modified); rebundle`
- UI bundle on a display-less machine: the existing headless fallback
  applies; no new failure mode.
