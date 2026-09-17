# Authoring a Pack

This walkthrough builds a small library `com.example.greetings` from
scratch.

## 1. Scaffold

```sh
klio pack new ~/projects/greetings --id com.example.greetings
```

`pack new` creates:

```
greetings/
  README.md
  klio.toml
  src/main/kotlin/Sample.kt
```

## 2. Edit `klio.toml`

```toml
[library]
id = "com.example.greetings"
version = "0.1.0"
abi = 1
implicit_packages = []
source_roots = ["src/main/kotlin"]

[deps]
stdlib = "*"

# Map Kotlin FQN -> host_symbol for any native bindings. Omit the
# table when the library is pure Kotlin.
# [bindings]
# "com.example.greetings.systemUser" = "com.example.greetings.systemUser"
```

The fields that matter:

| Field               | Notes                                                                |
|---------------------|----------------------------------------------------------------------|
| `id`                | Globally unique. Used as the cache filename.                          |
| `version`           | Free-form SemVer; the loader does not enforce it today.               |
| `abi`               | Bump when your bindings change shape.                                 |
| `implicit_packages` | Packages always visible to consumers (rare).                          |
| `source_roots`      | Glob-relative directories of `.kt` files. Defaults to `["src"]`.      |
| `[[source]]`        | A packed source set: `root` + optional `include` (file list relative to `root`). Repeatable; use instead of `source_roots` for finer control. |
| `[deps]`            | One line per dependency: `"kotlinx.io" = "*"` for any version, a version string for a minimum, `{ version = "..", features = [..], default_features = false }` for the rest. The loader topo-sorts them. |
| `[bindings]`        | `"FQN" = "host_symbol"` lines for native intrinsics.                  |
| `[features]`        | One feature per upstream module: `default = [...]` names the primary module(s); `name = { sources = [...], requires = [...], deps = [...] }` declares one (see below). Consumers enable them with `--feature <id>/<name>`. |
| `[[test]]`          | A test source set for `klio test <project>`: `root` + optional `include`, optional `feature = "<name>"` (composed only when that feature is active; untagged = core, always active), optional `group` (each group is its own test program). Test sources are never packed. |

### Features: one per upstream module

A multi-module library ships as one pack whose features are its modules,
named after the artifact with the library prefix stripped
(`kotlinx-coroutines-test` -> `test`, `ktor-client-core` -> `client-core`):

```toml
[[source]]
root = "upstream/kotlinx-coroutines-core/common/src"

[[source]]
root = "upstream/kotlinx-coroutines-test/common/src"

[[source]]
root = "klioMain"

[features]
default = ["core"]
core = { sources = ["upstream/kotlinx-coroutines-core", "klioMain"] }
test = { sources = ["upstream/kotlinx-coroutines-test", "klioMain/kotlinx/coroutines/test"], requires = ["core"] }
```

- `sources` are pack-relative path prefixes over the collected files. A
  file claimed by several features belongs to the one whose matching
  prefix is longest, so `klioMain` can hold every module's klio-authored
  actuals with the package path placing each file in its module. A file
  no feature claims always loads.
- `requires` names the pack's own modules this one is built on (its
  upstream `api` dependencies inside the library); `deps` names features
  of other packs (`"kotlinx.serialization/json-io"`, or a bare pack id for
  its defaults).
- `default` is the module that loads when a consumer names nothing,
  normally the library's entry point (`core`); a pack with no single
  entry point (ktor) defaults to nothing.
- A library with one module declares no `[features]` at all.
- `klio pack build` refuses a manifest whose `default`, `requires`, or
  `[[test]] feature` names an undeclared feature, or whose `sources`
  prefix covers no collected file.

Lay klio-authored sources out as `klioMain/` (packed, any module) and
`klioTest/` (test-only support for `[[test]]`, never packed).

### Testing the project

With one or more `[[test]]` stanzas, `klio test <project-dir>` builds+installs
the pack, composes the active test sources into one module, and runs every
`@Test`:

```toml
[[test]]
root = "upstream/core/common/test"

[[test]]
root = "upstream/feature/common/test"
feature = "myfeature"   # only composed under --feature <id>/myfeature (or --all)
```

```sh
klio test .                              # this project
klio test . --filter MyTest --format json
klio test . --isolate --timeout 5        # per-test sub-process, pinpoint a hang
```

See [Testing with KLIO](../testing.md#project-mode) for the full runner surface.

## 3. Write the Kotlin source

Pure Kotlin libraries are easiest — no Zig module required. Edit
`src/main/kotlin/Sample.kt`:

```kotlin
package com.example.greetings

fun greet(name: String): String = "hello, $name"

fun shout(name: String): String = greet(name).uppercase() + "!"
```

## 4. Build

```sh
klio pack build ~/projects/greetings
```

Output goes to `target/packs/com.example.greetings.klio-pack`.

## 5. Install and use

```sh
klio pack install target/packs/com.example.greetings.klio-pack

cat > /tmp/use.kt <<'EOF'
import com.example.greetings.greet
fun main() = println(greet("world"))
EOF

klio run /tmp/use.kt
# => hello, world
```

## Adding a native binding

When pure Kotlin is too slow or needs host capabilities (clock, HTTP,
threads), pair the library with a Zig module.

1. Create a sibling module (`src/com_example_greetings/`)
   exposing a `pub fn hostBindings(allocator) HostBindings`.
2. Declare the binding in `klio.toml`:

```toml
[bindings]
"com.example.greetings.now" = "com.example.greetings.now"
```

3. In your Kotlin source, declare a stub body that returns the
   default the loader uses if the host fails to resolve:

```kotlin
internal fun now(): Long = 0L
```

The loader, on installing the pack, will replace `now` with the
intrinsic at dispatch time. See [Native Bindings](native-bindings.md)
for the full pattern.

4. Wire the new module into the CLI's `mergedHostBindings()` and
   `build.zig` so the registry contains its function pointers at
   startup.

## Tips

- **Companion-object initialisers run eagerly.** A `val FOO: T =
  T(...)` inside a companion fires before the outer class is bound.
  Use `fun foo(): T = T(...)` or a top-level `val` instead.
- **File load order is alphabetical.** Types referenced in property
  initialisers of later files must be defined in an alphabetically
  earlier file path. Use `_` prefixes (`_types.kt`) when ordering
  matters.
- **Determinism is enforced.** `klio pack build` twice on the same
  source produces byte-identical output. If your build flakes,
  suspect non-deterministic hash-map traversal in the builder;
  report it.
- **Smoke test from the project.** `klio pack verify <path>
  --smoke <file.kt>` is the fastest feedback loop.
