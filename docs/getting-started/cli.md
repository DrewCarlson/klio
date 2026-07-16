# CLI tour

`klio` exposes everything through subcommands. Run `klio --help` for
the live list.

## Running and inspecting programs

| Command                 | Purpose                                                                                  |
|-------------------------|------------------------------------------------------------------------------------------|
| `klio run <files...>`   | Execute one or more Kotlin files as a single module.                                     |
| `klio test <file\|dir...>` | Run `kotlin.test` `@Test` functions; see [Testing](../testing.md).                    |
| `klio check <files...>` | Resolve + type-check, emit diagnostics. Exits non-zero on error. `--format plain\|json\|sarif`. |
| `klio lex <file>`       | Print the lexer's token stream.                                                          |
| `klio parse <file>`     | Print the parser's AST.                                                                  |
| `klio dump-ir <file>`   | Lower a file and print its IR without executing (`--func N` for one function); tallies DIRECT vs DYNAMIC call sites. |
| `klio repl`             | Placeholder prompt — currently echoes input; not yet a live evaluator.                   |
| `klio bake [files...]`  | Pre-bake the stdlib image cache (see below). `klio run` does this automatically on first use. |
| `klio bundle <file\|dir>` | Package a program into one self-contained executable; see [Bundling programs](../BUNDLE.md). |

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
  `--opt`. The granular overrides `KLIO_JIT`, `KLIO_FUNC_JIT`, and
  `KLIO_RECLAIM` layer on top for diagnosis
  ([details](../architecture/performance.md)).
- `KLIO_EAGER=1` — run the resolver and type checker ahead of
  lowering on the `run`/`test` path, so lowering consumes
  type-derived resolution answers; files the checker cannot finish
  fall back to lazy lowering.
- `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` — use an on-disk
  stdlib pack instead of the checkout or the embedded bytes. Useful
  when iterating on a pack without rebuilding the binary.
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
