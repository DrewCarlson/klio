# Workspace layout

```
kt-exp/
├── build.zig                   Module graph + run/test steps
├── build.zig.zon               Package metadata (minimum Zig version)
├── src/                        One Zig module per directory (src/<name>/<name>.zig)
│   ├── span/                   Source map / file ids / positions
│   ├── diagnostics/            Diagnostic sink + plain/json/sarif renderers
│   ├── diagnostics_gen/        Codegen for the diagnostic table
│   ├── lexer/                  UTF-8 → tokens
│   ├── ast/                    AST node types (KotlinFile, Expr, Decl, …)
│   ├── parser/                 Tokens → AST (P00xx diagnostics)
│   ├── resolver/               Name binding, imports (R00xx) — klio check
│   ├── types/                  Kotlin Type model, variance, constraints
│   ├── typeck/                 Type checking, smart casts (T00xx) — klio check
│   ├── cfa/                    Control- & data-flow analyses
│   ├── ir/                     AST → register IR (lowering)
│   ├── interp_ir/              IR module builder + the Vm
│   ├── runtime/                Value / InstanceData / Output
│   ├── stdlib/                 Native Zig stdlib intrinsics + symbol index
│   ├── stdlib_gen/             Mines upstream Kotlin into the symbol index
│   ├── stdlib_pack/            Produces the embedded stdlib.klio-pack bytes
│   ├── pack/                   On-disk pack format (writer, reader, schema)
│   ├── cli/                    The `klio` binary entry points
│   ├── parity/                 Parity sweep against kotlinc
│   ├── bench/                  Benchmark harness
│   ├── kotlinx_atomicfu/       Native bindings for kotlinx.atomicfu
│   ├── kotlinx_io/             Native bindings for kotlinx.io
│   ├── kotlinx_datetime/       Native bindings for kotlinx.datetime
│   ├── kotlinx_coroutines/     Native bindings for kotlinx.coroutines
│   ├── kotlinx_serialization/  Native bindings for kotlinx.serialization
│   ├── ktor_client/            Native bindings for io.ktor.client
│   ├── e2e/                    Runs examples/*.kt against tests/corpus/expected/
│   └── itests/                 Integration suites (one binary per file)
├── kotlin-klio/                Kotlin shims + klio.toml manifests for the packs
├── examples/                   .kt programs that pass parity against kotlinc
├── tests/                      Corpus, expected output, and fixtures
├── docs/                       This site (mkdocs)
└── kotlin/                     JetBrains/kotlin submodule (sparse: libraries/stdlib)
```

## Roles

- **Front end** (`lexer` → `parser`) produces the AST that
  both entry paths share.
- **Execution** (`ir` → `interp_ir` + `runtime` +
  `stdlib`) lowers the AST to IR and runs it. This is the
  `klio run` path.
- **Diagnostics** (`resolver` → `typeck`, backed by
  `types` and `cfa`) type-checks the AST for `klio check`.
  It is not on the execution path.
- **Packs** ride on top of execution. Each kotlinx-style pack has a
  Kotlin shim plus `klio.toml` under `kotlin-klio/klio-kotlinx-<name>/`
  and a native impl in `src/<name>/<name>.zig`, and ships as a
  `.klio-pack` built from its manifest.
- **Tests / corpus** live in `tests/fixtures/parity_corpus/`,
  `src/itests/`, and `examples/`. The parity sweep diffs klio against
  `kotlinc` byte-for-byte.

## Common zig flows

| Goal                        | Command                                            |
|-----------------------------|----------------------------------------------------|
| Build everything            | `zig build`                                        |
| Run tests                   | `zig build test`                                   |
| Run the binary              | `zig build run -- <args>`                          |
| Build a kotlinx pack        | `./zig-out/bin/klio pack build src/<name>`         |
| Run an example              | `./zig-out/bin/klio run examples/<file>.kt`        |
