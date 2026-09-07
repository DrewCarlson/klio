# Architecture

The user-facing architecture documentation lives under
`docs/architecture/` (pipeline, Vm, performance, stdlib, concurrency,
memory model, diagnostics). This file is the plan-side summary of the
shape of the system and the load-bearing design decisions.

## Pipeline

```
source text
  │
  ▼  span        (SourceMap, FileId, Span)
  ▼  lexer       (token stream, trivia preserved)
  ▼  parser      (AST + diagnostics)
  ▼  ir          (AST → register IR lowering; applicability = the
  │               shared overload-resolution engine; jit_loop = the
  │               native compiler over the IR)
  ▼  interp_ir   (the Vm: executes IR; JIT tiers compile hot code)
  ▼  cli         (binary: run / test / check / lex / parse / dump-ir /
                  bake / repl / pack)
```

`resolver` and `typeck` (backed by `types` and `cfa`) serve the
`klio check` diagnostics path, and under `KLIO_EAGER=1` they run
ahead of lowering on the run path so lowering consumes type-derived
resolution answers. `runtime` owns the `Value` model, the `ObjRef`
cell protocol, the tracing GC, and the perf profiles; `stdlib` owns
the native intrinsics and symbol index; `pack` / `stdlib_pack` own
the `.klio-pack` format and the embedded stdlib.

The module graph is data-driven in `build.zig` (`mod_list`): one Zig
module per subsystem under `src/`, each `src/<name>/<name>.zig` the
root file re-exporting the public API.

## Design choices

- **One module per subsystem.** Explicit dependency edges in
  `build.zig`; `scripts/zigcheck.py <module>` verifies any module in
  isolation against that graph.
- **`Span` over raw offsets.** Encodes file identity so diagnostics
  never confuse two files.
- **Diagnostics-first.** Every pass threads a `DiagnosticSink`;
  diagnostics are data, not Zig errors.
- **IR-only execution.** There is no AST evaluator on the run path;
  every construct lowers to structured register IR.
- **Native code is additive.** The JIT (x86-64 + AArch64 emitters
  behind one comptime-selected API) compiles hot loops and functions;
  any unsupported shape falls back to the interpreter with identical
  semantics.
- **Memory by reachability.** The tracing mark-sweep GC
  (`src/runtime/gc.zig`, design in `GC.md`) frees by reachability;
  profiles (`--opt`) can drop to a never-free arena.

## Reference checkouts

- `kotlin-language-spec/` — spec PDFs by section (gitignored).
- `kotlin/` — JetBrains/kotlin submodule at tag **v2.4.0**, populated
  sparsely (`libraries/stdlib` + `libraries/kotlin.test`) by
  `scripts/init-kotlin-submodule.sh`.

Everything targets **Kotlin 2.4.0**. When the spec PDFs and the
`kotlin/` source disagree, the source wins, because that is what real
Kotlin code is compiled against today.

- `kotlin/compiler/` (when present in a full checkout) is a
  cross-reference for tokenization, parsing, and resolution behavior.
- `kotlin/libraries/stdlib/` is the source of truth for the standard
  library klio ships: the `common/` subtree is interpreted directly
  as the stdlib pack's Kotlin source, with klio-authored actuals
  under `kotlin-klio/` and native Zig intrinsics shadowing individual
  functions at dispatch.

## Stdlib strategy

See `STDLIB.md` for the full strategy. Headlines: the upstream
stdlib source is the implementation (interpreted, not re-written);
`stdlib_gen` mines the upstream tree into the symbol index; native
intrinsics exist where host access or performance demands them; the
whole thing ships as `stdlib.klio-pack` embedded in the binary and is
verified by running upstream's own `commonTest` suite under the
interpreter.

## Scope: packs, not JVM interop

Third-party libraries reach klio as `.klio-pack`s built from Kotlin
source (`docs/packs/`), with optional native bindings registered by
host modules. JVM interop — Maven resolution, `.jar` / `.klib`
consumption, a classpath — remains out of scope. Anything a program
references that no loaded pack or the stdlib provides fails to
resolve with a clear diagnostic.
