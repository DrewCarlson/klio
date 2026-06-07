# Installation

klio is a Zig project. There is no published binary yet; build it
from source.

## Prerequisites

- Zig 0.16.0 (matches `build.zig.zon`'s `minimum_zig_version`). Put
  `zig` on your `PATH`.

## Build from source

```sh
git clone https://github.com/DrewCarlson/kt-exp
cd kt-exp
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

## Optional: install the ktor-client pack

`io.ktor.client` is not loaded by default. Build and install it once
to give your programs HTTP support:

```sh
./zig-out/bin/klio pack build src/ktor_client
./zig-out/bin/klio pack install target/packs/io.ktor.client.klio-pack
```

The same flow applies to kotlinx.atomicfu, kotlinx.io,
kotlinx.datetime, and kotlinx.coroutines — they all ship as packs
inside the project.
