# Workspace layout

```
kt-exp/
├── crates/
│   ├── klio-span/              Source map / file ids / positions
│   ├── klio-diagnostics/       Diagnostic sink + plain/json/sarif renderers
│   ├── klio-diagnostics-gen/   Codegen for the diagnostic table
│   ├── klio-lexer/             UTF-8 → tokens
│   ├── klio-ast/               AST node types (KotlinFile, Expr, Decl, …)
│   ├── klio-parser/            Tokens → AST (P00xx diagnostics)
│   ├── klio-resolver/          Name binding, imports (R00xx)
│   ├── klio-types/             Kotlin Type IR, variance, constraints
│   ├── klio-typeck/            Type checking, smart casts (T00xx)
│   ├── klio-cfa/               Control- & data-flow analyses
│   ├── klio-runtime/           Value / InstanceData / CallCtx
│   ├── klio-interp/            Tree-walking interpreter
│   ├── klio-stdlib/            Hand-written Kotlin stdlib intrinsics
│   ├── klio-stdlib-gen/        Mines upstream Kotlin into the symbol table
│   ├── klio-stdlib-pack/       Build-script crate that embeds stdlib.klio-pack
│   ├── klio-pack/              On-disk pack format (writer, reader, schema)
│   ├── klio-cli/               `klio` binary
│   ├── klio-parity/            Parity sweep against kotlinc-native
│   ├── klio-bench/             Criterion benchmarks
│   ├── klio-kotlinx-atomicfu/  Native bindings + shim for kotlinx.atomicfu
│   ├── klio-kotlinx-io/        Native bindings + shim for kotlinx.io
│   ├── klio-kotlinx-datetime/  Native bindings + shim for kotlinx.datetime
│   ├── klio-kotlinx-coroutines/Native bindings + shim for kotlinx.coroutines
│   └── klio-ktor-client/       Native bindings + shim for io.ktor.client
├── examples/                   .kt programs that pass parity against kotlinc
├── docs/                       This user-facing site (mkdocs)
├── plans/                      In-progress design + roadmap documents
├── kotlin-language-spec/       Spec PDFs (read-only reference)
├── third-party/                Vendored kotlinx sources (read-only)
└── xtask/                      cargo-xtask command runners (lint, gen)
```

## Roles

- **Front end** (lexer → parser → resolver → typeck → cfa) compiles
  source to a typed-and-analysed AST. Each crate owns its diagnostic
  prefix.
- **Back end** (runtime + interp + stdlib + stdlib-pack + pack)
  runs the AST. The pack crate defines the on-disk container; the
  stdlib crate provides intrinsics; the interpreter dispatches.
- **Packs** ride on top of the back end. Each kotlinx-style crate
  has a Kotlin shim (`shim/`) plus a Rust native impl
  (`src/lib.rs`), shipping as a `.klio-pack` archive at build time.
- **Tests / corpus** live in `crates/klio-parity/tests/corpus/`,
  per-crate `tests/` directories, and `examples/`. The parity sweep
  diffs klio against `kotlinc-native` byte-for-byte.

## Common cargo flows

| Goal                       | Command                                                          |
|----------------------------|------------------------------------------------------------------|
| Build everything           | `cargo build --workspace`                                        |
| Run tests                  | `cargo test --workspace`                                         |
| Rebuild stdlib pack        | `cargo build -p klio-stdlib-pack`                                |
| Build a kotlinx pack       | `cargo run -p klio-cli -- pack build crates/klio-kotlinx-<name>` |
| Run an example             | `cargo run -p klio-cli -- run examples/<file>.kt`                |
| Update mined stdlib symbols| `cargo run -p klio-stdlib-gen --bin klio-stdlib-gen`             |
