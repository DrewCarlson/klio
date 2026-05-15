# CLI tour

`klio` exposes everything through subcommands. Run `klio --help` for
the live list.

## Running and inspecting programs

| Command                 | Purpose                                                                                  |
|-------------------------|------------------------------------------------------------------------------------------|
| `klio run <files...>`   | Execute one or more Kotlin files as a single module.                                     |
| `klio check <files...>` | Resolve + type-check, emit diagnostics. Exits non-zero on error. `--format plain\|json\|sarif`. |
| `klio lex <file>`       | Print the lexer's token stream.                                                          |
| `klio parse <file>`     | Print the parser's AST.                                                                  |
| `klio repl`             | Placeholder prompt — currently echoes input; not yet a live evaluator.                   |

`klio run` accepts a legacy `--ir-vm` flag for backwards
compatibility; it is ignored, because the IR Vm is the only run path.

## Working with packs

| Command                                       | Purpose                                                                       |
|-----------------------------------------------|-------------------------------------------------------------------------------|
| `klio pack new <dir> [--id NAME]`             | Scaffold a library: `klio.toml`, `src/main/kotlin/`, README.                   |
| `klio pack build <dir> [--out PATH]`          | Build a `.klio-pack` from a directory holding a `klio.toml`.                    |
| `klio pack install <pack>`                    | Copy a pack into `~/.klio/packs/` so subsequent `klio run` calls see it.        |
| `klio pack list`                              | Show every cached pack with version and dependency hints.                      |
| `klio pack remove <id> [--version VER]`       | Delete a cached pack.                                                          |
| `klio pack inspect <pack>`                    | Print manifest, section sizes, and counts.                                    |
| `klio pack verify <pack> [--smoke FILE.kt]`   | Re-decode every section; with `--smoke`, run a program against it.             |
| `klio pack stdlib --out PATH`                 | Rebuild the embedded stdlib pack (developer flow).                            |
| `klio pack migrate <in> [--out PATH]`         | Migrate a pack to the current format version (passthrough at v1).             |
| `klio pack train-dict <packs...> --out PATH`  | Train a shared zstd dictionary from pack sections.                            |
| `klio pack publish <pack> [--registry DIR]`   | Publish a pack into a local-filesystem registry.                              |
| `klio pack search <query> [--registry DIR]`   | Search a registry's index by library id.                                      |
| `klio pack fetch <id> [--version V] [--registry DIR]` | Fetch a pack from a registry into the local cache.                    |

The registry defaults to `~/.klio/registry`; its layout mirrors a
Maven cache plus an `index.json`.

## Environment variables

- `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` — use an on-disk
  stdlib pack instead of the embedded bytes. Useful when iterating
  on stdlib changes without rebuilding the binary.
- `KLIO_PACKS=path1:path2:...` — colon-separated extra packs to load
  at startup, in addition to `~/.klio/packs`.
- `HOME` — determines `~/.klio/packs`.

## Examples

Run a script that uses an installed kotlinx pack:

```sh
klio pack install target/packs/kotlinx.atomicfu.klio-pack
klio run examples/atomic_counter.kt
```

Build and install a library you cloned locally:

```sh
klio pack new ~/projects/widgets --id com.example.widgets
klio pack build ~/projects/widgets
klio pack install target/packs/com.example.widgets.klio-pack
```

Smoke-test a pack without installing it:

```sh
klio pack verify ./vendor/foo.klio-pack --smoke ./samples/uses_foo.kt
```
