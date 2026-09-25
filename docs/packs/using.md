# Using packs

This page covers consumption — installing existing packs and using
them from your Kotlin programs.

## Installing a pack

Packs live in `~/.klio/packs/<library-id>-<version>.klio-pack`. The
`klio pack install` command copies a file there and the next
`klio run` picks it up automatically.

```sh
klio pack install target/packs/kotlinx.atomicfu.klio-pack
```

Verify it landed:

```sh
$ klio pack list
androidx.annotation               1.8.1       abi 1  deps stdlib
androidx.collection               1.12.0      abi 1  deps stdlib, androidx.annotation, kotlinx.atomicfu
androidx.compose.runtime          1.12.0      abi 1  deps stdlib, androidx.annotation, kotlinx.coroutines, androidx.collection
io.ktor                           3.5.2       abi 1  deps stdlib, kotlinx.coroutines, kotlinx.atomicfu, kotlinx.io
kotlin.test                       2.4.20      abi 1  deps stdlib
kotlinx.atomicfu                  0.33.0      abi 1  deps stdlib
kotlinx.coroutines                1.11.0      abi 1  deps stdlib
kotlinx.datetime                  0.8.0       abi 1  deps stdlib, kotlinx.serialization
kotlinx.io                        0.9.1       abi 1  deps stdlib
kotlinx.serialization             1.11.0      abi 1  deps stdlib
```

## Loading from a one-off path

For development you can point at a pack file without permanently
installing it:

```sh
KLIO_PACKS=/path/to/foo.klio-pack klio run app.kt
```

`KLIO_PACKS` accepts a colon-separated list of paths. These are
loaded after the stdlib pack and before the cached packs.

## Features: one per upstream module

A pack is one library; its features are that library's Gradle modules,
named after the artifact with the library prefix stripped
(`kotlinx-coroutines-test` is `kotlinx.coroutines/test`,
`ktor-client-core` is `io.ktor/client-core`). Each pack's `default`
names its primary module, so importing `kotlinx.coroutines.*` loads
`core` with nothing to enable; every other module is opt-in per run
with `--feature <pack>/<feature>` (repeatable, or one value naming
several of a pack's features with commas; accepted by `klio run`,
`klio test`, `klio check`, and `klio bundle`, which bakes the choice
into the [bundled executable](../BUNDLE.md)):

```sh
klio run --feature kotlinx.serialization/json app.kt
klio run --feature kotlinx.coroutines/test scheduler_test.kt
klio run --feature io.ktor/client-cio fetch.kt
klio run --feature io.ktor/server-content-negotiation,serialization-kotlinx-json api.kt
```

A feature carries its module's upstream dependencies: `requires` pulls
the pack's own modules it is built on (`io.ktor/client-core` activates
`http`, `http-cio`, `utils`, `io`, `events`, `sse`,
`websocket-serialization`, `serialization`, and `websockets`), and `deps` pulls features of other packs
(`io.ktor/serialization-kotlinx-json` enables
`kotlinx.serialization/json-io`, which enables `json` and loads the
`kotlinx.io` pack). A program's `klio.toml` asks for the same thing
durably: `"kotlinx.serialization" = { features = ["json"] }` under
`[deps]`, with `default_features = false` to take only what it names.

An import that lands in a module that is not active prints a note
naming the feature to enable. A pack with no `[features]` table is a
single module and loads whole.

A program's dependencies belong in its `klio.toml`: `[deps]` names the
packs and the features of each, and that is the whole load set. A file
run without a manifest still selects packs by matching its imports
against installed pack ids; that path exists for one-off scripts and is
being retired in favour of declared dependencies. The shipped feature
tables are on each pack's page: [kotlinx.coroutines](shipped/coroutines.md),
[kotlinx.serialization](shipped/serialization.md),
[kotlinx.io](shipped/io.md), and [io.ktor](shipped/ktor.md).

## Removing a pack

```sh
klio pack remove kotlinx.atomicfu
klio pack remove kotlinx.atomicfu --version 0.33.0   # exact match
```

## Verifying a pack

`klio pack verify` re-decodes every section through the loader. Pass
`--smoke <file.kt>` to also run a program against the pack, which
exercises both binding resolution and any shipped Kotlin source.

```sh
klio pack verify ./vendor/foo.klio-pack --smoke ./samples/uses_foo.kt
```

## Importing pack symbols

Imports work exactly like imports against the stdlib. The resolver
sees the pack's symbol index and treats every declared package as
known. A program that uses `kotlinx.atomicfu` once installed looks
like a normal Kotlin source file:

```kotlin
import kotlinx.atomicfu.atomic

fun main() {
    val counter = atomic(0)
    repeat(10_000) { counter.incrementAndGet() }
    println("counter=${counter.value}")
}
```

## Inspecting a pack

```sh
$ klio pack inspect target/packs/kotlinx.io.klio-pack
file:    target/packs/kotlinx.io.klio-pack
format:  v1
hash:    f3a2…
sections:
  - ast      stored=...
  - bindings stored=...
  - manifest stored=...
  - sources  stored=...
manifest: library=kotlinx.io version=0.9.1 abi=1 implicit=[]
bindings: 18 entries
```

## Troubleshooting

- **`abi mismatch`** — rebuild the pack against the current
  `pack.SUPPORTED_ABI_VERSION`.
- **`unbound identifier: <Type>`** — the pack failed to register its
  source files at install time. Run `klio pack inspect` to verify
  the source/ast section is non-empty and the file ordering does
  not reference symbols declared in a later-loaded file.
- **`pack hash mismatch`** — the file was modified after writing.
  Reinstall from a freshly built pack.
- **A native binding is missing** — the pack declares a binding
  whose `host_symbol` no host registers. Check the matching Zig
  module is included in the build (the CLI's
  `mergedHostBindings`).
