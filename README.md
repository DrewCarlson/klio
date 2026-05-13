# klio

An experimental Kotlin interpreter written in Rust.

Klio parses, type-checks, and executes Kotlin source directly. It targets
language parity with Kotlin 2.3.x and ships a pack format that bundles
libraries (the standard library and selected kotlinx libraries) into
self-contained `.klio-pack` artifacts the interpreter loads at startup.

Status: experimental. The language coverage is broad enough to run
non-trivial programs but it is not a drop-in replacement for `kotlinc`.

## Quick start

Build and run a Kotlin file:

```
cargo build --release
target/release/klio run examples/showcase.kt
```

Or run from the workspace without installing:

```
cargo run -p klio-cli -- run path/to/file.kt
```

Available subcommands:

| Command                      | What it does                                    |
| ---------------------------- | ----------------------------------------------- |
| `klio run <file...>`         | Run a `.kt` file or set of module files         |
| `klio check <file...>`       | Type-check and emit diagnostics (plain/json/sarif) |
| `klio lex <file>`            | Print the token stream                          |
| `klio parse <file>`          | Print the AST                                   |
| `klio repl`                  | Interactive REPL                                |
| `klio pack ...`              | Build, install, inspect, verify, list, remove packs |

## What works

The interpreter covers most of the language. Notable points:

- Classes, data classes, sealed classes, enums, objects, companion
  objects, inner classes, anonymous objects, nested classes.
- Generic types with declaration-site variance, where-clauses,
  reified type parameters in `inline` functions.
- Functions: top-level, member, extension, anonymous, lambdas with
  inline / `crossinline` / `noinline`. Top-level function overloads
  resolve by argument type, so the upstream `kotlinx.atomicfu`
  `atomic(Int)` / `atomic(Long)` / `atomic(Boolean)` / `atomic<T>`
  overload set works verbatim.
- Coroutines: `suspend fun`, `runBlocking`, `suspendCoroutine`, full
  state-machine lowering, ANF normalisation so suspending calls compose
  inside expressions (`val a = ask(1) + ask(2)`, string templates, etc.).
- Smart casts including multi-`is` `when` arms, exhaustive `when` on
  sealed types, `Nothing`-typed expressions terminating control flow.
- Property delegates: `by lazy`, `Delegates.observable` /
  `Delegates.notNull`, user-defined `operator fun getValue` / `setValue`
  as members or extensions, `provideDelegate`.
- Reflection: `Foo::class`, `Foo::method`, `Foo::prop`,
  `KFunction.call` with receiver, `KMutableProperty1.set`,
  `KClass.memberFunctions` / `memberProperties` / `primaryConstructor` /
  `findAnnotation<T>()`.
- Tail-call optimisation: direct `tailrec fun` and mutual
  tail-recursion. A 200 000-deep even/odd ping-pong runs in a flat
  host stack.
- `@BuilderInference` user functions and receiver-typed lambda
  parameter dispatch so `MutableList<T>.() -> Unit` builders work
  end-to-end.

Compiler parity is enforced by the `klio-parity` test harness, which runs
each corpus program through both `kotlinc-native` and `klio` and diffs
the output.

## Packs

A `.klio-pack` is a single deterministic binary file that bundles a
Kotlin library's surface area:

- `manifest`: library id, version, ABI, implicit packages, dependencies.
- `symbols`: symbol index (FQN, signature, source location) for the
  resolver and any future tooling.
- `bindings`: FQN to host-symbol map for native Rust intrinsics.
- `sources`: raw `.kt` source bytes (zstd-compressed).
- `ast`: pre-parsed `KotlinFile` tree (skipped at install when present).

The interpreter ships with `klio-stdlib-pack` embedded via `include_bytes!`,
so every `klio run` invocation starts with the standard library already
loaded. Set `KLIO_STDLIB_PACK=/path/to/stdlib.klio-pack` to swap in a
dev build without recompiling.

Building a pack from a library directory containing `klio.toml` plus a
`src/` tree:

```
cargo run -p klio-cli -- pack build crates/klio-kotlinx-atomicfu
```

Output lands at `target/packs/<library-id>.klio-pack`. Inspecting one:

```
$ klio pack inspect target/packs/kotlinx.atomicfu.klio-pack
file:    target/packs/kotlinx.atomicfu.klio-pack
format:  v1
hash:    7bc026830b165b50...
sections:
  - ast        stored=  1987 bytes  uncompressed= 4553 bytes  Zstd
  - bindings   stored=  2097 bytes  uncompressed= 2097 bytes  None
  - manifest   stored=    35 bytes  uncompressed=   35 bytes  None
  - sources    stored=   917 bytes  uncompressed= 2865 bytes  Zstd
manifest: library=kotlinx.atomicfu version=0.32.1 abi=1 implicit=[]
bindings: 24 entries
```

`klio pack install <pack>` copies into `~/.klio/packs`, where every
subsequent `klio run` picks it up automatically. `klio pack list`,
`klio pack remove`, and `klio pack verify` round out the lifecycle.

### klio.toml

```toml
[library]
id = "kotlinx.atomicfu"
version = "0.32.1"
abi = 1
implicit_packages = []
source_roots = ["shim"]

[[deps]]
id = "stdlib"

[bindings]
"kotlinx.atomicfu.AtomicInt.compareAndSet" = "kotlinx.atomicfu.AtomicInt.compareAndSet"
"kotlinx.atomicfu.AtomicLong.compareAndSet" = "kotlinx.atomicfu.AtomicLong.compareAndSet"
```

The `[bindings]` map entries pair a Kotlin FQN with a host-symbol key
the loader resolves against a `klio_stdlib::HostBindings` registry.
Each `klio-kotlinx-*` crate ships a `host_bindings()` function that
populates that registry with Rust function pointers. Interpreted
Kotlin source covers everything that isn't bound natively.

## Kotlinx libraries

Vendored as git submodules under `third-party/kotlinx/`:

| Library            | Pinned version | Native bindings |
| ------------------ | -------------- | --------------- |
| kotlinx-atomicfu   | 0.32.1         | full coverage   |
| kotlinx-io         | 0.9.0          | Buffer surface  |
| kotlinx-datetime   | v0.8.0         | scaffold only   |
| kotlinx-coroutines | 1.11.0         | scaffold only   |

```
git submodule update --init --recursive
```

`atomicfu` and `io` ship Kotlin shims plus working Rust implementations
of the platform-specific operations (`compareAndSet`, byte buffers, and
so on). The shim source declares the class shapes the upstream API
exposes; the host bindings shadow each method body at dispatch so the
interpreter runs the native fast path. Smoke programs for both libraries
live under the binding crates and are exercised by the workspace tests.

`datetime` and `coroutines` have crate scaffolds and submodule pins but
the binding tables are empty.

## Workspace layout

```
crates/
  klio-span             Source files, byte spans, line/column mapping
  klio-diagnostics      Error/warning model with labels and rendering
  klio-diagnostics-gen  Generator for diagnostic-factory tables
  klio-lexer            Kotlin tokenizer
  klio-ast              AST node definitions
  klio-parser           Recursive-descent parser
  klio-resolver         Name resolution
  klio-typeck           Type checker
  klio-cfa              Control-flow graph + dataflow analyses
  klio-types            Type system + constraint solver
  klio-runtime          Runtime Value, environment, output trait
  klio-interp           Tree-walking interpreter
  klio-stdlib           Native Rust intrinsics + symbol index
  klio-stdlib-gen       Mines Kotlin upstream sources into the symbol index
  klio-stdlib-pack      Embeds the stdlib .klio-pack via include_bytes!
  klio-pack             Pack format: writer, reader, schema
  klio-kotlinx-*        Per-library binding crates (atomicfu, io, datetime, coroutines)
  klio-cli              `klio` binary
  klio-parity           Cross-checks each corpus program against kotlinc-native
  klio-bench            Criterion benchmarks
```

## Building from source

Standard Cargo workflow:

```
cargo build --workspace
cargo test --workspace
cargo run -p klio-cli -- run examples/showcase.kt
```

`klio-parity` requires a `kotlinc-native` install on PATH; without it
the parity tests skip. `klio-stdlib-gen` requires a checkout of
[JetBrains/kotlin](https://github.com/JetBrains/kotlin) at the pinned
tag; without it the registry uses the symbol index already committed at
`crates/klio-stdlib/src/generated/symbols.postcard`.

## Reference sources

Two trees are gitignored and consumed as references:

- `kotlin-language-spec/`: Kotlin language specification PDFs.
- `kotlin/`: JetBrains/kotlin at the target tag, read for
  compiler / spec cross-reference and as the source of truth for
  the standard library shape.

Klio implements every supported feature against the spec. The
`klio-stdlib-gen` binary mines `kotlin/libraries/stdlib/` for the
symbol index.

## License

MIT OR Apache-2.0.
