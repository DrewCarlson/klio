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
│   ├── klio-resolver/          Name binding, imports (R00xx) — klio check
│   ├── klio-types/             Kotlin Type model, variance, constraints
│   ├── klio-typeck/            Type checking, smart casts (T00xx) — klio check
│   ├── klio-cfa/               Control- & data-flow analyses
│   ├── klio-ir/                AST → register IR (lowering)
│   ├── klio-interp-ir/         IR module builder + the Vm
│   ├── klio-runtime/           Value / InstanceData / Output
│   ├── klio-stdlib/            Native Rust stdlib intrinsics + symbol index
│   ├── klio-stdlib-gen/        Mines upstream Kotlin into the symbol index
│   ├── klio-stdlib-pack/       Build-script crate that embeds stdlib.klio-pack
│   ├── klio-pack/              On-disk pack format (writer, reader, schema)
│   ├── klio-cli/               The `klio` binary
│   ├── klio-parity/            Parity sweep against kotlinc
│   ├── klio-bench/             Criterion benchmarks
│   ├── klio-kotlinx-atomicfu/  Native bindings + shim for kotlinx.atomicfu
│   ├── klio-kotlinx-io/        Native bindings + shim for kotlinx.io
│   ├── klio-kotlinx-datetime/  Native bindings + shim for kotlinx.datetime
│   ├── klio-kotlinx-coroutines/Native bindings + shim for kotlinx.coroutines
│   └── klio-ktor-client/       Native bindings + shim for io.ktor.client
├── examples/                   .kt programs that pass parity against kotlinc
├── docs/                       This site (mkdocs)
├── kotlin-language-spec/       Spec PDFs (read-only reference, gitignored)
├── kotlin/                     JetBrains/kotlin checkout (read-only, gitignored)
└── third-party/                Vendored kotlinx submodules (read-only)
```

## Roles

- **Front end** (`klio-lexer` → `klio-parser`) produces the AST that
  both entry paths share.
- **Execution** (`klio-ir` → `klio-interp-ir` + `klio-runtime` +
  `klio-stdlib`) lowers the AST to IR and runs it. This is the
  `klio run` path.
- **Diagnostics** (`klio-resolver` → `klio-typeck`, backed by
  `klio-types` and `klio-cfa`) type-checks the AST for `klio check`.
  It is not on the execution path.
- **Packs** ride on top of execution. Each kotlinx-style crate has a
  Kotlin shim (`shim/`) plus a Rust native impl (`src/lib.rs`) and
  ships as a `.klio-pack` built from its `klio.toml`.
- **Tests / corpus** live in `crates/klio-parity/tests/corpus/`,
  per-crate `tests/` directories, and `examples/`. The parity sweep
  diffs klio against `kotlinc` byte-for-byte.

## Common cargo flows

| Goal                        | Command                                                          |
|-----------------------------|------------------------------------------------------------------|
| Build everything            | `cargo build --workspace`                                        |
| Run tests                   | `cargo test --workspace`                                          |
| Rebuild the stdlib pack     | `cargo build -p klio-stdlib-pack`                                |
| Build a kotlinx pack        | `cargo run -p klio-cli -- pack build crates/klio-kotlinx-<name>` |
| Run an example              | `cargo run -p klio-cli -- run examples/<file>.kt`                |
| Update mined stdlib symbols | `cargo run -p klio-stdlib-gen`                                   |
