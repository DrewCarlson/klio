# CLI tour

`klio` exposes its full surface through subcommands. Run `klio --help`
to see them at a glance.

## Running and inspecting programs

| Command                         | Purpose                                                                                                  |
|---------------------------------|----------------------------------------------------------------------------------------------------------|
| `klio run <files...>`           | Execute one or more Kotlin source files as a single module.                                              |
| `klio check <files...>`         | Typecheck and emit diagnostics. Exits non-zero on any error. `--format plain|json|sarif`.                |
| `klio lex <file>`               | Print the token stream produced by the lexer.                                                            |
| `klio parse <file>`             | Print the AST produced by the parser.                                                                    |
| `klio repl`                     | Interactive prompt over the same pipeline.                                                               |

## Working with packs

| Command                                       | Purpose                                                                                  |
|-----------------------------------------------|------------------------------------------------------------------------------------------|
| `klio pack new <dir> [--id NAME]`             | Scaffold a new library: `klio.toml`, `src/main/kotlin/`, README.                          |
| `klio pack build <dir> [--out PATH]`          | Build a `.klio-pack` from a library directory holding a `klio.toml`.                      |
| `klio pack install <pack>`                    | Copy a pack into `~/.klio/packs/` so subsequent `klio run` calls see it.                  |
| `klio pack list`                              | Show every cached pack with version and dependency hints.                                 |
| `klio pack remove <id> [--version VER]`       | Delete a cached pack.                                                                     |
| `klio pack inspect <pack>`                    | Print manifest, section sizes, binding count.                                             |
| `klio pack verify <pack> [--smoke FILE.kt]`   | Re-decode every section through the loader. With `--smoke`, run a program against it.     |
| `klio pack stdlib --out PATH`                 | Rebuild the embedded stdlib pack (developer flow).                                        |

## Environment variables

- `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` — swap the embedded
  stdlib bytes for an on-disk file. Useful when iterating on stdlib
  changes without rebuilding the binary.
- `KLIO_PACKS=path1:path2:...` — colon-separated list of additional
  packs to load at startup (in addition to `~/.klio/packs`).
- `HOME` — determines `~/.klio/packs`. Override with caution.

## Examples

Run a script that uses an installed kotlinx pack:

```sh
klio pack install target/packs/kotlinx.atomicfu.klio-pack
klio run examples/atomic_counter.kt
```

Build a third-party library you cloned locally:

```sh
klio pack new ~/projects/widgets --id com.example.widgets
klio pack build ~/projects/widgets
klio pack install target/packs/com.example.widgets.klio-pack
```

Smoke-test a published pack without permanently installing it:

```sh
klio pack verify ./vendor/foo.klio-pack --smoke ./samples/uses_foo.kt
```
