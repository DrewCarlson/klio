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
io.ktor.client            3.2.0       abi 1   deps stdlib
kotlinx.atomicfu          0.32.1      abi 1   deps stdlib
kotlinx.coroutines        1.11.0      abi 1   deps stdlib
kotlinx.datetime          0.8.0       abi 1   deps stdlib
kotlinx.io                0.9.0       abi 1   deps stdlib
```

## Loading from a one-off path

For development you can point at a pack file without permanently
installing it:

```sh
KLIO_PACKS=/path/to/foo.klio-pack klio run app.kt
```

`KLIO_PACKS` accepts a colon-separated list of paths. These are
loaded after the stdlib pack and before the cached packs.

## Removing a pack

```sh
klio pack remove kotlinx.atomicfu
klio pack remove kotlinx.atomicfu --version 0.32.1   # exact match
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
manifest: library=kotlinx.io version=0.9.0 abi=1 implicit=[]
bindings: 18 entries
```

## Troubleshooting

- **`abi mismatch`** — rebuild the pack against the current
  `klio_pack::SUPPORTED_ABI_VERSION`.
- **`unbound identifier: <Type>`** — the pack failed to register its
  source files at install time. Run `klio pack inspect` to verify
  the source/ast section is non-empty and the file ordering does
  not reference symbols declared in a later-loaded file.
- **`pack hash mismatch`** — the file was modified after writing.
  Reinstall from a freshly built pack.
- **A native binding is missing** — the pack declares a binding
  whose `host_symbol` no host registers. Check the matching Rust
  crate is included in the build (`klio-cli`'s
  `merged_host_bindings`).
