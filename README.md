# klio

**A new Kotlin runtime. Skip compilation and ship self-contained programs.**

klio is an experimental Kotlin runtime that runs `.kt` source without a JVM,
a Gradle project, or a Kotlin/Native build.

[Documentation](https://drewcarlson.github.io/klio/main/) ·
[Getting started](https://drewcarlson.github.io/klio/main/getting-started/installation/) ·
[Examples](examples/README.md)

> klio is an experiment under active development. It already runs a broad
> range of Kotlin programs, but it is not (and may never be) a production
> replacement for the official Kotlin toolchains.

## What can you build?

- **Scripts and command-line tools.** Run Kotlin files without build config.
- **Servers and connected applications.** Use official Kotlin libraries,
  including coroutines, serialization, datetime, I/O, and Ktor.
- **Desktop applications.** Build with Compose Runtime, Compose UI,
  and Material 3, rendered through Skia on Linux and macOS.
- **Self-contained releases.** Bundle a CLI tool, web server, or Compose
  desktop app with libraries, resources, and renderer in one executable

## Quick start

Klio binaries are not currently published, so you must build it from source.
You only need [Zig 0.16.0](https://zigtools.org/zls/install/?zig_version=0.16.0&compatibility=only-runtime):

```sh
git clone https://github.com/DrewCarlson/klio.git
cd klio
./scripts/bootstrap.sh --release
```

Save a program as `hello.kt`:

```kotlin
fun main() {
    val names = listOf("Ada", "Grace", "Linus")
    println(names.joinToString("! ") { "Hello, $it" })
}
```

Then run it:

```sh
./zig-out/bin/klio run hello.kt
```

```text
Hello, Ada! Hello, Grace! Hello, Linus!
```

The bootstrap script fetches the source and rendering dependencies klio needs,
then creates an optimized binary at `zig-out/bin/klio`. Add `--packs` to the
bootstrap command to build and install the optional Kotlin, Compose, and
AndroidX integrations. The
[installation guide](https://drewcarlson.github.io/klio/main/getting-started/installation/)
covers the individual requirements and library packs.

## One CLI from first run to release

The everyday workflow stays small:

| Command | What it is for |
| --- | --- |
| `klio run <file...>` | Run Kotlin source directly |
| `klio test [path]` | Run `kotlin.test` tests |
| `klio check <file...>` | Check code and produce editor- or CI-friendly diagnostics |
| `klio bundle <file\|dir>` | Create a distributable desktop executable |
| `klio pack <command>` | Install and manage supported Kotlin libraries |

The full command reference, project manifests, feature flags, and diagnostic
formats live in the [CLI documentation](https://drewcarlson.github.io/klio/main/getting-started/cli/).

## Native application bundling

`klio bundle` turns a Kotlin program into a native host executable carrying a
ready-to-run image of your code. The destination machine does not need klio,
Kotlin, or a compiler.

```sh
klio bundle hello.kt -o hello
./hello
```

Bundles can include files and directories as application resources. Compose
applications also carry the Skia renderer they need. klio can produce a macOS
`.app` wrapper or Linux desktop metadata with your application name and icon,
while the underlying program remains a normal executable.

Desktop bundling is available for Linux and macOS. Windows support is planned.
See [Bundling programs](https://drewcarlson.github.io/klio/main/BUNDLE/) for packaging, resources,
desktop integration, and distribution details.

## Compose on desktop and mobile

klio runs the Compose Runtime and Compose UI without a separate Compose
compiler-plugin workflow.

On Linux and macOS, Compose programs can open native desktop windows or render
offscreen, then ship with the same `klio bundle` command as any other program.
Runnable examples cover interactive controls, themes, multi-window apps, lazy
layouts, graphics, text, and terminal interfaces with Mosaic.

Browse the [Compose examples](examples/README.md#integration-showcases) to see
the current UI surface in action.

## Kotlin libraries

The standard library is built in. Optional libraries are installed as klio
packs, and the repository includes integrations for:

- `kotlin.test`
- `kotlinx.coroutines`
- `kotlinx.serialization`
- `kotlinx.datetime`
- `kotlinx.io`
- `kotlinx.atomicfu`
- Ktor
- Compose Runtime, Compose UI, Foundation, Material 3, and related AndroidX
  modules
- Mosaic terminal UI

See [Using packs](https://drewcarlson.github.io/klio/main/packs/using/)
for installation and the documentation for each supported library.

## Project status

| Area | Current status |
| --- | --- |
| Kotlin source, tests, and diagnostics | Available; experimental and tracking Kotlin 2.4 |
| Linux and macOS desktop bundles | Available |
| Compose desktop UI | Available on Linux and macOS; Partial Foundation and Material3 coverage |
| iOS and Android | Embedded runtime and Compose demos are working |
| Windows | Planned |

Compatibility is checked continuously against `kotlinc` and upstream Kotlin
tests. Those checks give the project a strong behavioral baseline without
pretending that every Kotlin program or ecosystem library is covered today.

## Developing klio

klio is written in Zig 0.16.0. From a fresh clone, initialize the workspace and
run the fast test suite with:

```sh
./scripts/bootstrap.sh --packs
zig build test
```

Use `scripts/gate.sh` for the full pre-commit check. The
[contributor guide](https://drewcarlson.github.io/klio/main/development/contributing/),
[testing guide](https://drewcarlson.github.io/klio/main/development/testing/), and
[debugging guide](https://drewcarlson.github.io/klio/main/development/debugging/) cover the project workflow in
detail.

## License

klio is available under the [MIT License](LICENSE).
