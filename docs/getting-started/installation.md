# Installation

klio is a Rust workspace. There is no published binary yet; build it
from source.

## Prerequisites

- Rust 1.95 or newer (matches the workspace's `rust-toolchain.toml`).
  Install via [rustup](https://rustup.rs).
- A C linker (system clang/gcc) — needed transitively by `zstd` and
  the TLS stack used by `klio-ktor-client`.

## Build from source

```sh
git clone https://github.com/DrewCarlson/kt-exp
cd kt-exp
cargo build --release -p klio-cli
```

The binary lands at `target/release/klio`. Copy it onto your `PATH`,
or use `cargo run -p klio-cli -- <args>` directly out of the
workspace.

## Verify

```sh
cargo run -q -p klio-cli -- --version
```

Run the workspace tests once to confirm your toolchain matches:

```sh
cargo test --workspace
```

The first build pulls in chrono, ureq, and serde transitives; expect
a few minutes on a cold cache.

## Optional: install the ktor-client pack

`io.ktor.client` is not loaded by default. Build and install it once
to give your programs HTTP support:

```sh
cargo run -q -p klio-cli -- pack build crates/klio-ktor-client
cargo run -q -p klio-cli -- pack install target/packs/io.ktor.client.klio-pack
```

The same flow applies to kotlinx.atomicfu, kotlinx.io,
kotlinx.datetime, and kotlinx.coroutines — they all ship as packs
inside the workspace.
