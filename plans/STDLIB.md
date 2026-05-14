# Stdlib strategy

The Kotlin stdlib is **the** runtime surface a program has access to. We aim to ship a complete, performant implementation that behaves exactly like Kotlin 2.3.21's stdlib on the JVM where semantics are platform-agnostic.

## Guiding principles

1. **Native by default.** Like CPython implements `len`, `dict`, `str.split`, and the rest in C, we implement Kotlin stdlib functions in **Rust**, not as interpreted Kotlin. The interpreter calls these as intrinsics. Interpreted-Kotlin fallbacks exist only as a transitional stopgap or for trivial wrappers; the steady state is "all of stdlib is in Rust."

2. **Auto-generate the API surface from upstream sources.** The Kotlin stdlib is too large to maintain by hand and the upstream tree is structured for codegen. We mine `kotlin/libraries/stdlib/` to produce:
   - The list of every public symbol (top-level functions, extension functions, classes, interfaces, properties, type aliases) along with its fully qualified name, signature, modifiers, and Kotlin source span (for diagnostics).
   - A registration table the interpreter loads at startup to resolve `kotlin.*` names to Rust implementations.
   - Per-function Rust stubs the human then fills in (or that the generator implements directly when the upstream definition is purely mechanical).

3. **Pin to Kotlin 2.3.21.** The generator reads from the `kotlin/` checkout already pinned at that tag. Bumping Kotlin versions is a deliberate, tracked operation that regenerates the surface and forces us to address any new or changed symbols.

4. **Coverage is enforced, not aspirational.** A `coverage` report compares the generated symbol inventory against the set with real Rust implementations. CI fails when implementations regress (a previously-implemented symbol becomes unimplemented) and surfaces the unimplemented set as a single number we drive to zero.

## Sources of truth in the `kotlin/` checkout

| Path                                                                | Role                                                                                                |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `libraries/stdlib/common/src/kotlin/`                               | Hand-written headers: `KotlinH.kt`, `MathH.kt`, `TextH.kt`, `SequencesH.kt`, `ExceptionsH.kt`, etc. Declares the common surface (often with `expect`). |
| `libraries/stdlib/common/src/generated/`                            | JetBrains-generated files: `_Collections.kt`, `_Arrays.kt`, `_Sequences.kt`, `_Maps.kt`, `_Ranges.kt`, `_Strings.kt`, `_Comparisons.kt`, and unsigned-variant siblings. These are highly regular and easiest to consume. |
| `libraries/stdlib/src/kotlin/`                                      | Pure-Kotlin definitions shared across platforms (no `expect`).                                      |
| `libraries/stdlib/jvm/src/`                                         | JVM `actual` implementations — read **only** to disambiguate semantics, never linked.               |
| `libraries/tools/kotlin-stdlib-gen/`                                | JetBrains' own generator. Study it for the templates and naming conventions; do not run it.         |

## Architecture

A new crate, `klio-stdlib`, ships the implementations and a build-time companion `klio-stdlib-gen` produces the registration tables.

```
crates/
  klio-stdlib-gen/      Binary that reads kotlin/libraries/stdlib/, produces Rust.
  klio-stdlib/          Hand-written Rust intrinsics + generated/ submodule of
                       registration tables and per-function stubs.
```

### `klio-stdlib-gen`

A standalone binary (so generation runs only when invoked, not on every build). Inputs: the `kotlin/` checkout path. Outputs: Rust files under `crates/klio-stdlib/src/generated/`, committed to the repo for reviewability.

Pipeline:

1. **Walk** the curated set of stdlib source roots (common headers + `generated/` + shared `src/kotlin/`).
2. **Parse** each `.kt` file enough to extract declarations and their signatures. Once `klio-parser` is mature enough, we use it directly — until then, a focused subset parser inside the generator handles declarations only (the upstream `generated/` files are particularly regular, so this is tractable).
3. **Normalize** declarations into a stable schema: FQN, kind (function / property / class / typealias), receiver type, parameter list (name + type + default-arity), return type, modifiers (`inline`, `infix`, `operator`, `tailrec`, …), source span.
4. **Emit** Rust modules:
   - `generated/registry.rs` — a `pub static STDLIB_SYMBOLS: &[SymbolEntry]` indexing every symbol.
   - `generated/sig/*.rs` — typed signature descriptors for each function (so the typechecker / dispatcher don't have to re-parse).
   - `generated/stubs/*.rs` — `pub fn name(...) -> Result<Value, RuntimeError> { Err(RuntimeError::Unimplemented("kotlin.foo.bar")) }` for any symbol without a hand-written Rust implementation.
5. **Coverage report** — `klio-stdlib-gen coverage` walks the registry and prints implemented / unimplemented counts and the unimplemented FQNs.

### `klio-stdlib`

Layout:

```
crates/klio-stdlib/src/
  lib.rs               Registers everything with the interpreter.
  numerics/            Int, Long, Short, Byte, unsigned variants, Float, Double, math.
  text/                String, StringBuilder, CharSequence, Char ops, regex.
  collections/         List, MutableList, Map, Set, ArrayList, HashMap, etc.
  sequences/           Sequence + intermediate / terminal ops.
  ranges/              IntRange, LongRange, CharRange, progressions.
  io/                  println / readLine / minimal IO surface.
  exceptions/          Throwable hierarchy.
  generated/           Output of klio-stdlib-gen (do not edit by hand).
```

### Interpreter integration

- On boot, the interpreter loads `STDLIB_SYMBOLS` and populates a global resolver keyed by FQN.
- Calls to `kotlin.io.println`, `kotlin.collections.listOf`, etc. dispatch directly to the Rust implementation — no AST walking through stdlib code, no per-call interpretation cost.
- Non-`kotlin.*` imports fail with a clear diagnostic ("third-party libraries are not supported"). This matches the project scope captured in `ARCHITECTURE.md`.

## Implementation discipline

For every batch of stdlib symbols we implement:

1. **Generate first.** Re-run `klio-stdlib-gen` so the registry and stubs reflect the upstream truth.
2. **Implement in Rust.** Replace stubs with real Rust functions. Match Kotlin/JVM semantics: integer overflow wraps, `Double` follows IEEE-754, `String` is UTF-16 in observable behavior even if backed by Rust's UTF-8 internally.
3. **Test exhaustively.** Per the project-wide testing discipline: unit tests in `klio-stdlib`, end-to-end `.kt` programs in `examples/` and the workspace corpus, snapshot tests where output is large. Cross-check against running the same snippet under real Kotlin where reasonable (recorded as expected output in the example file's header).
4. **Track coverage.** Each PR notes the delta: "+N implemented, -M stubs."

## What we are explicitly *not* doing

- Loading the upstream stdlib's compiled `.klib` / `.jar` artifacts.
- Implementing Kotlin/JVM-specific stdlib pieces that depend on the JVM runtime (e.g. `java.*` interop helpers). These are out of scope.
- Interpreting the upstream Kotlin source as our stdlib at runtime. We read it as input to codegen; we do not ship it as runtime data.
