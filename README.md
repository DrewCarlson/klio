# klio

An experimental Kotlin interpreter written in Zig.

klio reads Kotlin source, lowers it to a register-based intermediate
representation, and executes that IR directly. There is no JVM, no
Kotlin/Native, and no separate compile step — the same Zig pipeline
that parses your code also runs it.

It targets Kotlin **2.4.0** with essentially full language coverage:
for interpreting Kotlin programs, klio is a drop-in replacement for
`kotlinc` — the same source, the same output. The project is still
experimental; the claim is held up by continuous verification against
`kotlinc` itself (see below), not by decree.

## Quick start

```sh
zig build                                  # dev build (Debug — fast to compile, slow to run)
./zig-out/bin/klio run examples/showcase.kt
```

**Build an optimized binary to actually run programs with:**

```sh
zig build -Doptimize=ReleaseFast
```

`zig build` follows the Zig convention and defaults to **Debug**, which keeps the
edit-compile loop fast but leaves the interpreter roughly 8x slower and the binary
3x larger. The difference is not subtle — measured on this repo:

| | binary | startup | 2M method calls | peak RSS |
| --- | --- | --- | --- | --- |
| `zig build` (Debug) | 158 MB | 0.21 s | 12.3 s | 49 MB |
| `zig build -Doptimize=ReleaseFast` | **54 MB** | **0.03 s** | **1.5 s** | **35 MB** |

Ship (and benchmark) the ReleaseFast binary. Use Debug only to iterate.

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
| `klio test [path]`         | Run `@Test` functions — a file, dir, or project (`klio.toml` `[[test]]` sets); `--filter`, `--format=json`, `--list`, `--isolate` |
| `klio check <file...>`     | Resolve + type-check, emit diagnostics (plain/json/sarif) |
| `klio lex <file>`          | Print the token stream                                  |
| `klio parse <file>`        | Print the AST                                           |
| `klio dump-ir <file>`      | Lower a file and print its IR without executing         |
| `klio bake [file...]`      | Pre-bake the stdlib image cache                         |
| `klio bundle <file\|dir>`  | Package a program into one self-contained executable — see [docs/BUNDLE.md](docs/BUNDLE.md) |
| `klio repl`                | Interactive prompt (placeholder; see note below)        |
| `klio pack <subcommand>`   | Build, install, inspect, verify, publish, and fetch packs |

`klio check` exits non-zero on any error and is the integration point
for editors and CI. `klio run` lexes, parses, lowers to IR, and
executes. Every command takes `--opt <fast|safe|off>` (also the
`KLIO_OPT` env var) to select the performance profile — see below.

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
the Vm never walks an AST. Setting `KLIO_EAGER=1` runs the resolver
and type checker ahead of lowering on the run path too, so lowering
consumes type-derived answers instead of deferring resolution to
runtime.

## Performance

The `--opt` flag (or `KLIO_OPT`) selects one bundled profile:

| Profile  | JIT                    | Memory                        |
| -------- | ---------------------- | ----------------------------- |
| `fast`   | loop + whole-function  | tracing GC (default)          |
| `safe`   | off (interpreter only) | tracing GC                    |
| `off`    | off                    | never-free arena              |

- **JIT** (`src/jit/`): a tiered native compiler with two backends —
  x86-64 (System V) and AArch64 — selected at comptime, sharing one
  emitter API so the loop/function compiler in `src/ir/jit_loop.zig`
  stays arch-neutral. Executable memory is W^X (`MAP_JIT` on macOS).
  Any unsupported shape falls back to the interpreter.
- **GC** (`src/runtime/gc.zig`): a precise, stop-the-world, non-moving
  mark-sweep collector over the runtime object heap; memory is freed
  by reachability, so reference cycles are collected.

## Language coverage

klio implements the Kotlin language essentially in full: classes in
all their forms (data, sealed, enum, inner, local, anonymous, value),
generics with variance and reified type parameters, lambdas and
`inline`/`crossinline`/`noinline`, coroutines with full state-machine
lowering, smart casts and sealed-`when` exhaustiveness, property
delegates, destructuring, operator conventions, reflection
(`::class`, callable references, `KClass` introspection), `tailrec`,
expect/actual, and the rest. Kotlin concurrency runs on real OS
threads with a documented memory model at least as strong as the JMM
([docs/architecture/memory-model.md](docs/architecture/memory-model.md)).

The Kotlin 2.4 language additions are supported: explicit backing
fields, the `@all` annotation use-site target, the new annotation
use-site defaulting rules, and context parameters (declarations and
implicit resolution; explicit context arguments and callable
references to contextual declarations are diagnosed as unsupported,
matching a compiler that has not yet stabilized them).

Correctness is enforced two ways: the parity harness runs every
corpus program (532) and example (142) through both `kotlinc` and
klio and diffs stdout against Kotlin 2.4.0, and the upstream stdlib's
own `commonTest` suite (117 files, ~2,150 tests) runs directly under
the interpreter — at 100% per-file pass rate.

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
  ir               AST → register IR lowering (+ applicability,
                   the shared overload-resolution engine)
  jit              Tiered native compiler: x86-64 + AArch64 emitters
  interp_ir        IR Vm: the execution engine
  runtime          Runtime Value, instance data, GC, perf profiles
  stdlib           Native Zig intrinsics + symbol index
  stdlib_gen       Mines upstream Kotlin into the symbol index
  stdlib_pack      Embeds the stdlib .klio-pack
  pack             Pack format: writer, reader, schema
  kotlinx_*        Per-library binding modules
  compose_runtime  Compose runtime host bindings
  ktor_client      HTTP client bindings for the io.ktor pack
  test_runner      The klio test @Test runner
  cli              The `klio` binary
  parity           Cross-checks every program against kotlinc
  bench            Benchmark harness
  e2e              Runs examples/ against baked expected output
  itests           Integration suites, one test binary per file
  main.zig         Binary entry point
```

## Building from source

After a fresh clone, one script does all setup — submodules, the sparse
upstream checkouts, the Skia backend prebuilt, and the build:

```sh
./scripts/bootstrap.sh                 # full setup + build
./scripts/bootstrap.sh --release       # build with -Doptimize=ReleaseFast
./scripts/bootstrap.sh --packs         # also install the shipped packs into ~/.klio
zig build test
./zig-out/bin/klio run examples/showcase.kt
```

`bootstrap.sh` is idempotent — every phase is a no-op when already
satisfied, so it is safe to re-run to repair a partial setup, widen a stale
sparse checkout, or pick up a moved submodule pin. It also selects the
Compose-UI window/GPU backend automatically: the Cocoa window + Metal surface
on macOS, and the Ganesh GL/EGL surface on Linux when a display is attached
(`DISPLAY`/`WAYLAND_DISPLAY`), staying headless-raster otherwise. Pass
`--headless` to force a headless build. The individual steps it runs, if you
prefer to run them by hand:

```sh
git submodule update --init --recursive    # kotlinx + ktor vendor sources
./scripts/init-kotlin-submodule.sh          # upstream Kotlin stdlib (sparse)
./scripts/init-compose-submodule.sh         # compose-multiplatform-core (sparse)
./scripts/init-androidx-collection-submodule.sh
./scripts/fetch-skia.sh                     # Compose-UI Skia backend (host target)
zig build                                   # macOS: Cocoa window + Metal backend by default
                                            #   (-Dcocoa=false -Dgpu=false for headless; on linux add -Dgpu with a display)
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

## Documentation

The full documentation lives under [`docs/`](docs/index.md):
getting started, the architecture (pipeline, Vm, performance,
concurrency, memory model), the pack system, and the development
workflow. Running plan documents and design records live under
`plans/`.

## Reference sources

- `kotlin-language-spec/` — the Kotlin language specification PDFs
  (gitignored, reference only).
- `kotlin/` — JetBrains/kotlin at the pinned tag (the `kotlin` submodule,
  populated sparsely; see *Building from source*). Read for compiler
  cross-reference and as the source of truth for stdlib shape. When the
  spec and the source disagree, the source wins — it is what real Kotlin
  compiles against.

## License

MIT, see [LICENSE](LICENSE).
