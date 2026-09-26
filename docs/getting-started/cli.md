# CLI tour

`klio` exposes everything through subcommands. Run `klio --help` for
the live list.

## Running and inspecting programs

| Command                 | Purpose                                                                                  |
|-------------------------|------------------------------------------------------------------------------------------|
| `klio run <files...>`   | Execute one or more Kotlin files as a single module.                                     |
| `klio test <file\|dir...>` | Run `kotlin.test` `@Test` functions; see [Testing](../testing.md).                    |
| `klio check <files...>` | Resolve + type-check, emit diagnostics. Exits non-zero on error. `--format plain\|json\|sarif`; `--engine sema` analyzes as `klio run` does and names kotlinc's diagnostics. |
| `klio lex <file>`       | Print the lexer's token stream.                                                          |
| `klio parse <file>`     | Print the parser's AST.                                                                  |
| `klio dump-ir <file>`   | Lower a program and print its functions' IR without executing (`--func N` for one function, `--all` for the base's too); tallies DIRECT vs DYNAMIC call sites. |
| `klio transpile-dump <file>` | Print the program's functions as the bytecode streams the transpiler reads.         |
| `klio repl`             | Placeholder prompt — currently echoes input; not yet a live evaluator.                   |
| `klio bake [files...]`  | Pre-bake the base image cache (see below). `klio run` does this automatically on first use. |
| `klio bake-image <files...> -o <out>` | Write the programs' base (stdlib and packs) as one self-contained image, sources included. |
| `klio run-image <image> <file> [args...]` | Run a program over such an image, with no data home, pack install or checkout. |
| `klio bundle <file\|dir>` | Package a program into one self-contained executable; see [Bundling programs](../BUNDLE.md). |
| `klio transpile <files...> [-o out.c]` | Write a C launcher (`out.c`) and the program's sema image beside it (`out.klio-image`). `zig cc out.c -I<include> -L<lib> -lklio_rt -lzstd` builds a binary that runs the program with no data home: a compiler with `#embed` builds the image in, and the program's sources are in the C. `--native` compiles the program itself to C over the same runtime. |

`klio run` takes `--virtual-time` (deterministic virtual time
for coroutines) and `--feature <pack>/<feature>` (enable a
feature-gated pack surface, repeatable); `klio test` accepts the
same two.

### Performance profile

Every command accepts `--opt <fast|safe|off>` (equivalently the
`KLIO_OPT` env var): `fast` enables the JIT tiers and the tracing
GC, `safe` keeps the GC but stays on the interpreter, `off` is the
interpreter over a never-free arena. `klio run` defaults to `fast`,
`klio test` to `safe`. See
[Performance](../architecture/performance.md).

### The base image cache

A program runs over its base: the stdlib, the sema actuals and the packs
it imports. The first `klio run` of a base analyzes and lowers it and
bakes the result to `~/.klio/cache/sema-base-<key>.klio-sema`; every
later run over the same base loads that image and analyzes and lowers
only the program. The key hashes the interpreter binary's identity and
the path and text of every base file, so editing a stdlib source,
installing a different pack or rebuilding `klio` bakes afresh; a stale
image is never served. The build bakes the image of the base a program
without packs runs on and installs it under `share/klio/cache` beside
`bin/klio`; a run whose own cache misses reads that copy, so a freshly
built klio's first run of such a program is already warm. `klio bake`
pre-warms the cache (with files, for the base those programs run on
together; without, for the base without packs).

`klio bake-image` writes a base as one self-contained file: the base
image with the text of every base file and the pack features it was
loaded with. `klio run-image` runs a program over it without reading
the data home, the pack cache or a checkout; a bundle carries the same
image.

## Working with packs

| Command                                       | Purpose                                                                       |
|-----------------------------------------------|-------------------------------------------------------------------------------|
| `klio pack new <dir> [--id NAME]`             | Scaffold a library: `klio.toml`, `src/main/kotlin/`, README.                   |
| `klio pack build <dir> [--out PATH]`          | Build a `.klio-pack` from a directory holding a `klio.toml`. `--out` names the file.  |
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

## Stdlib resolution

The interpreter resolves its stdlib pack in this order:

1. `KLIO_STDLIB_PACK` — an explicit on-disk pack override (a deliberate
   per-run choice, so it wins over everything).
2. The working directory's source checkout (`kotlin/libraries/stdlib`
   plus `kotlin-klio/`), built fresh per run. This sits ahead of the
   embedded bytes so in-repo stdlib `.kt` edits take effect without
   rebuilding the binary.
3. The pack bytes baked into the binary at build time — present in
   every `zig build` binary, so `klio run` works from any directory
   with no setup.

## Environment variables

- `KLIO_OPT=fast|safe|off` — the performance profile, same values as
  `--opt`. `KLIO_RECLAIM` overrides its memory backend for diagnosis
  ([details](../architecture/performance.md)).
- `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` — use an on-disk
  stdlib pack instead of the checkout or the embedded bytes. Useful
  when iterating on a pack without rebuilding the binary.
- `KLIO_SEMA_IMAGE=0` — disable the base image cache (every run
  analyzes and lowers its whole base).
- `KLIO_STDLIB_IMAGE_SHIPPED=0` — ignore the base image the build
  installed beside the binary.
- `KLIO_SEMA_TIMING=1` — print the milliseconds each step of a run
  takes, the base image's bake or load among them.
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
