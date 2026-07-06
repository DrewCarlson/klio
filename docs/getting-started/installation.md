# Installation

klio is a Zig project. There is no published binary yet; build it
from source.

## Prerequisites

- Zig 0.16.0 (matches `build.zig.zon`'s `minimum_zig_version`). Put
  `zig` on your `PATH`.

## Build from source

```sh
git clone https://github.com/DrewCarlson/klio
cd klio
git submodule update --init --recursive   # kotlinx + ktor vendor sources
./scripts/init-kotlin-submodule.sh        # upstream Kotlin stdlib (sparse)
zig build
```

The binary lands at `./zig-out/bin/klio`. Copy it onto your `PATH`,
or use `zig build run -- <args>` directly out of the project.

## Verify

```sh
./zig-out/bin/klio --version
```

Run the tests once to confirm your toolchain matches:

```sh
zig build test
```

## Optional: install the bundled library packs

The project bundles kotlin.test, kotlinx-atomicfu,
kotlinx-coroutines, kotlinx-datetime, kotlinx-io,
kotlinx-serialization, ktor, the Compose runtime, and
androidx-collection as pack definitions under `kotlin-klio/`. Build
and install the ones your programs need:

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-coroutines
./zig-out/bin/klio pack install target/packs/kotlinx.coroutines.klio-pack
```

The ktor pack is feature-gated: install it the same way
(`kotlin-klio/klio-ktor`), then enable what a program uses per run,
e.g. `klio run --feature io.ktor/client program.kt`. See
[Using packs](../packs/using.md).
