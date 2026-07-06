# klio

An experimental Kotlin interpreter written in Zig.

klio reads Kotlin source, lowers it to a register-based intermediate
representation, and executes that IR directly. There is no JVM, no
Kotlin/Native, and no separate compile step — the same Zig pipeline
that parses your code also runs it.

It targets Kotlin **2.4.0**. Coverage is broad enough to run
non-trivial programs, but klio is an experiment, not a drop-in
replacement for `kotlinc`.

## Quick start

```sh
zig build
./zig-out/bin/klio run examples/showcase.kt
```

A first program:

```kotlin
fun main() {
    val xs = listOf(1, 2, 3)
    println(xs.joinToString { "${it * it}" })
}
```

```
1, 4, 9
```

## Commands

| Command                    | What it does                                            |
| -------------------------- | ------------------------------------------------------- |
| `klio run <file...>`       | Execute a `.kt` file, or a set of files as one module   |
| `klio check <file...>`     | Resolve + type-check, emit diagnostics (plain/json/sarif) |
| `klio lex <file>`          | Print the token stream                                  |
| `klio parse <file>`        | Print the AST                                           |
| `klio repl`                | Interactive prompt (placeholder; see note below)        |
| `klio pack <subcommand>`   | Build, install, inspect, verify, publish, and fetch packs |

`klio check` exits non-zero on any error and is the integration point
for editors and CI. `klio run` lexes, parses, lowers to IR, and
executes; type-checking is not on the run path today.

> The REPL is currently a placeholder that echoes input. Use
> `klio run` for real execution.

## How it works

```
.kt source
   │ lexer       UTF-8 → tokens
   │ parser      tokens → AST
   │ ir          AST → register IR (lowering)
   │ interp_ir   IR → result (the Vm)
   ▼
program output
```

`klio check` additionally runs the `resolver` module (name binding,
imports) and the `typeck` module (type system, smart casts, inference)
over the AST to produce diagnostics. The execution path is IR-only:
the Vm never walks an AST.

## What works

- Classes, data classes, sealed classes, enums, objects, companion
  objects, inner classes, anonymous objects, nested and local classes.
- Generics with declaration-site variance, where-clauses, and reified
  type parameters in `inline` functions.
- Functions: top-level, member, extension, anonymous, and lambdas
  with `inline` / `crossinline` / `noinline`. Top-level overloads
  resolve by argument type, so the upstream `kotlinx.atomicfu`
  `atomic(Int)` / `atomic(Long)` / `atomic(Boolean)` / `atomic<T>`
  overload set works verbatim.
- Coroutines: `suspend fun`, `runBlocking`, `suspendCoroutine`, full
  state-machine lowering, and ANF normalization so suspending calls
  compose inside expressions and string templates.
- Smart casts, including multi-`is` `when` arms, exhaustive `when`
  over sealed types, and `Nothing`-typed control flow.
- Property delegates: `by lazy`, `Delegates.observable` /
  `Delegates.notNull`, and user-defined `getValue` / `setValue` /
  `provideDelegate` as members or extensions.
- Reflection: `Foo::class`, `Foo::method`, `Foo::prop`,
  `KFunction.call`, `KMutableProperty1.set`, and `KClass` member
  introspection.
- Direct and mutual tail-call optimization for `tailrec fun`.

Correctness is enforced two ways: the `klio-parity` harness runs
every corpus program (532) and example (142) through both `kotlinc`
and klio and diffs stdout against Kotlin 2.4.0, and the upstream
stdlib's own `commonTest` suite (117 files) runs directly under the
interpreter.

## Packs

A `.klio-pack` is a single deterministic binary file that bundles a
Kotlin library: its manifest, symbol index, native-binding table, and
source (raw and pre-parsed). The standard library ships as a pack
embedded into the `klio` binary, so every `klio run` starts with the
stdlib already loaded.

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-atomicfu
./zig-out/bin/klio pack install target/packs/kotlinx.atomicfu.klio-pack
./zig-out/bin/klio run examples/atomic_counter.kt
```

Installed packs live in `~/.klio/packs/` and load automatically. The
pack subcommands cover the full lifecycle — `build`, `install`,
`list`, `remove`, `inspect`, `verify`, `new`, `migrate`, plus a
local-filesystem registry (`publish`, `search`, `fetch`). Set
`KLIO_STDLIB_PACK` to swap the embedded stdlib for an on-disk build,
or `KLIO_PACKS` to load extra packs without installing them.

See [`docs/packs/`](docs/packs/overview.md) for the format and
authoring guide.

### Bundled libraries

Each library lives under `kotlin-klio/klio-<name>/` as a pack
definition: a `klio.toml` manifest, the upstream sources as a git
submodule, and klio-authored actuals/shims where the library needs a
platform layer.

| Library                  | Pinned version | Platform layer                          |
| ------------------------ | -------------- | --------------------------------------- |
| kotlin.test              | 2.4.0          | asserter actuals (from `kotlin/`)       |
| kotlinx-atomicfu         | 0.33.0         | full native coverage                    |
| kotlinx-coroutines       | 1.11.0         | upstream common sources + actuals       |
| kotlinx-datetime         | 0.8.0          | clock, tz conversion, ISO parse/format  |
| kotlinx-io               | 0.9.1          | Buffer surface                          |
| kotlinx-serialization    | 1.11.0         | reflective serializer (no plugin)       |
| ktor                     | 3.5.1          | opt-in client/server pack               |
| compose-runtime          | 1.11.1         | runtime common sources                  |
| androidx-collection      | 1.11.1         | consumed by compose-runtime             |

```sh
git submodule update --init --recursive
```

`io.ktor` ships as an opt-in pack and is not loaded by default;
feature-gated pack surfaces (e.g. `kotlinx.serialization/json`) are
enabled per run with `--feature`.

## Source layout

The interpreter is built from Zig modules under `src/`, wired
together in `build.zig`:

```
src/
  span             Source files, byte spans, line/column mapping
  diagnostics      Error/warning model, plain/json/sarif renderers
  diagnostics_gen  Generator for diagnostic-factory tables
  lexer            Kotlin tokenizer
  ast              AST node definitions
  parser           Recursive-descent parser
  resolver         Name resolution (klio check)
  typeck           Type checker (klio check)
  cfa              Control- and data-flow analyses
  types            Type system + constraint solver
  ir               AST → register IR lowering
  interp_ir        IR Vm: the execution engine
  runtime          Runtime Value, instance data, output sink
  stdlib           Native Zig intrinsics + symbol index
  stdlib_gen       Mines upstream Kotlin into the symbol index
  stdlib_pack      Embeds the stdlib .klio-pack
  pack             Pack format: writer, reader, schema
  kotlinx_*        Per-library binding modules
  ktor_client      Opt-in HTTP client pack + bindings
  cli              The `klio` binary
  parity           Cross-checks every program against kotlinc
  bench            Benchmarks
  main.zig         Binary entry point
```

## Building from source

```sh
git submodule update --init --recursive   # kotlinx + ktor vendor sources
./scripts/init-kotlin-submodule.sh         # upstream Kotlin stdlib (sparse)
zig build
zig build test
./zig-out/bin/klio run examples/showcase.kt
```

Zig 0.16.0+ is required (pinned in `build.zig.zon`).

The interpreter reads upstream Kotlin's stdlib sources from
`kotlin/libraries/stdlib` at build/run time. `kotlin` is a submodule, but
the full JetBrains/kotlin repo is ~5GB, so it is marked `update = none` and
populated by `scripts/init-kotlin-submodule.sh` as a sparse, blobless clone
of just `libraries/stdlib` + `libraries/kotlin.test` at the pinned tag
(`v2.4.0`).

The `parity` module needs a `kotlinc` on `PATH`; without one the
parity tests skip. The `stdlib_gen` module needs a checkout of
[JetBrains/kotlin](https://github.com/JetBrains/kotlin) at the target
tag; without it the registry uses the symbol index already committed
under `src/stdlib/`.

## Reference sources

- `kotlin-language-spec/` — the Kotlin language specification PDFs
  (gitignored, reference only).
- `kotlin/` — JetBrains/kotlin at the pinned tag (the `kotlin` submodule,
  populated sparsely; see *Building from source*). Read for compiler
  cross-reference and as the source of truth for stdlib shape. When the
  spec and the source disagree, the source wins — it is what real Kotlin
  compiles against.

## License

MIT OR Apache-2.0.
