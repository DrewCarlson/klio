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
| `klio bake [files...]`  | Pre-bake the stdlib image cache (see below). `klio run` does this automatically on first use. |

`klio run` accepts a legacy `--ir-vm` flag for backwards
compatibility; it is ignored, because the IR Vm is the only run path.

### The stdlib image cache

The first `klio run` lowers the embedded stdlib (and any packs the
program imports) and bakes the result to
`~/.klio/cache/stdlib-<key>.klio-image`; every later run loads that
image and lowers only the user program, cutting startup from seconds to
a few hundred milliseconds. The cache is content-addressed — the key
hashes the interpreter binary's identity, every stdlib source the bake
consumed, the stdlib load gate, and each selected pack's content hash
and feature set — so editing a stdlib source, swapping a pack, or
rebuilding `klio` transparently rebakes; a stale image can never be
served. Programs that redeclare a stdlib top-level name (or otherwise
fail the reuse gate) automatically fall back to the whole-program
build with identical behavior. `klio bake` pre-warms the cache (with
files, for exactly those programs' dependency sets; without, for both
stdlib gate variants). Old images beyond a small keep-count are pruned.

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
- `KLIO_STDLIB_IMAGE=0` — disable the stdlib image cache (every run
  lowers the full dependency set, as before).
- `KLIO_TRACE_STDLIB_IMAGE=1` — print one `hit`/`baked`/`fallback`
  line per run with the cache key and timing breakdown.
- `KLIO_PACKS=path1:path2:...` — colon-separated extra packs to load
  at startup, in addition to `~/.klio/packs`.
- `HOME` — determines `~/.klio/packs` and `~/.klio/cache`.

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
