# Workspace layout

```
klio/
├── build.zig                   Module graph + run/test steps (data-driven mod_list)
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
│   ├── ir/                     AST → register IR (lowering; also hosts the
│   │                           `applicability` overload-resolution module
│   │                           and the JIT loop/function compiler)
│   ├── jit/                    Machine-code emitters: x86-64 + AArch64
│   ├── interp_ir/              IR module builder + the Vm
│   ├── runtime/                Value / InstanceData / Output / GC / perf profiles
│   ├── stdlib/                 Native Zig stdlib intrinsics + symbol index
│   ├── stdlib_gen/             Mines upstream Kotlin into the symbol index
│   ├── stdlib_pack/            Produces the embedded stdlib.klio-pack bytes
│   ├── pack/                   On-disk pack format (writer, reader, schema)
│   ├── test_runner/            The `klio test` @Test runner
│   ├── cli/                    The `klio` binary entry points
│   ├── parity/                 Parity sweep against kotlinc
│   ├── bench/                  Benchmark harness
│   ├── kotlinx_atomicfu/       Native bindings for kotlinx.atomicfu
│   ├── kotlinx_io/             Native bindings for kotlinx.io
│   ├── kotlinx_datetime/       Native bindings for kotlinx.datetime
│   ├── kotlinx_coroutines/     Native bindings for kotlinx.coroutines
│   ├── kotlinx_serialization/  Native bindings for kotlinx.serialization
│   ├── compose_runtime/        Native bindings for the Compose runtime
│   ├── ktor_client/            Native bindings for the io.ktor pack's client
│   ├── e2e/                    Runs examples/*.kt against tests/corpus/expected/
│   └── itests/                 Integration suites (one test binary per file)
├── kotlin-klio/                Pack definitions: klio.toml manifests, upstream
│                               submodules, and klio-authored actuals/shims
├── examples/                   .kt programs that pass parity against kotlinc
├── tests/                      Corpus, expected output, and fixtures
├── scripts/                    Verification tooling (gate.sh, commontest-sweep.py,
│                               zigcheck.py, prune-zig-cache.sh, …)
├── docs/                       This site (mkdocs)
├── plans/                      Running plan documents and design records
└── kotlin/                     JetBrains/kotlin submodule (sparse: libraries/stdlib
                                + libraries/kotlin.test at v2.4.0)
```

## Roles

- **Front end** (`lexer` → `parser`) produces the AST that
  both entry paths share.
- **Execution** (`ir` → `interp_ir` + `runtime` +
  `stdlib`, with `jit` compiling hot code) lowers the AST to IR and
  runs it. This is the `klio run` path.
- **Diagnostics** (`resolver` → `typeck`, backed by
  `types` and `cfa`) type-checks the AST for `klio check`. It gates
  nothing on the run path (under `KLIO_EAGER=1` it runs there too,
  feeding lowering).
- **Packs** ride on top of execution. Each library has a pack
  definition under `kotlin-klio/klio-<name>/` (a `klio.toml`, the
  upstream sources as a submodule, and klio-authored actuals) and,
  where it needs host access, a native module in `src/<name>/`.
- **Tests / corpus** live in `tests/fixtures/parity_corpus/`,
  `src/itests/`, and `examples/`. The parity sweep diffs klio against
  `kotlinc` byte-for-byte; the stdlib commonTest suite runs upstream's
  own tests under the interpreter.

## Common zig flows

| Goal                        | Command                                            |
|-----------------------------|----------------------------------------------------|
| Build everything            | `zig build`                                        |
| Fast unit tests             | `zig build test`                                   |
| One integration suite       | `zig build itest-<name>`                           |
| Everything CI runs          | `zig build test-all`                               |
| Run the binary              | `zig build run -- <args>`                          |
| Build a library pack        | `./zig-out/bin/klio pack build kotlin-klio/klio-<name>` |
| Run an example              | `./zig-out/bin/klio run examples/<file>.kt`        |

See [Testing and verification](testing.md) for the full iteration
playbook (Debug harness, targeted sweeps, the pre-commit gate).
