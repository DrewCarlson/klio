# klio

An experimental Kotlin interpreter written in Zig.

klio reads a `.kt` source file (or a set of files), lowers it to a
register-based intermediate representation, and executes that IR
directly. There is no JVM, no Kotlin/Native, and no separate
compilation step — the same hand-written Zig pipeline that parses
your code also runs it.

## Highlights

- **Drop-in for interpreting Kotlin.** klio targets Kotlin 2.4.0
  with essentially full language coverage: for running Kotlin
  programs it is a drop-in replacement for `kotlinc`, verified by
  diffing stdout byte-for-byte against the real compiler.
- **IR-based execution.** Source is lowered by the `ir` module into
  a register IR that the `interp_ir` Vm runs. The Vm never walks an
  AST.
- **Tiered JIT and a tracing GC.** Hot loops and functions compile
  to native code (x86-64 and AArch64 backends); the heap is managed
  by a precise mark-sweep collector. One `--opt` profile controls
  both.
- **Pack-based libraries.** The stdlib ships as a versioned
  `.klio-pack` embedded into the binary; the same format hosts
  kotlinx-coroutines, kotlinx-serialization, ktor, the Compose
  runtime, and third-party libraries.
- **Declarative native bindings.** A pack's `klio.toml` lists
  `FQN → host_symbol` pairs. Zig modules register host symbols once;
  the loader joins them at install time and a native function
  shadows the matching Kotlin body at dispatch.
- **Single binary.** `zig build` produces a `./zig-out/bin/klio`
  command that runs files, runs tests, type-checks, and manages
  packs.

## Where to start

- [Install klio](getting-started/installation.md) and run your first
  program.
- Write and run a [hello world](getting-started/hello-world.md).
- Take the [CLI tour](getting-started/cli.md) for the full command
  surface.
- Test your Kotlin with [`klio test` and `kotlin.test`](testing.md).

## Architecture

- [Pipeline overview](architecture/pipeline.md) — where each Kotlin
  construct is handled, from lexer to Vm.
- [The Vm](architecture/interpreter.md) — lowering, values,
  dispatch, coroutines.
- [Performance](architecture/performance.md) — the `--opt` profiles,
  the JIT tiers and backends, and the garbage collector.
- [Standard library](architecture/stdlib.md) — how upstream Kotlin
  source plus native intrinsics become the embedded stdlib pack.
- [Concurrency](architecture/concurrency.md) — real threads,
  dispatchers, and the coroutine engine.
- [Memory model](architecture/memory-model.md) — the normative
  rules, each with an executable litmus program.
- [Diagnostics](architecture/diagnostics.md) — codes, wording rules,
  output formats.

## Packs

- [What is a pack?](packs/overview.md)
- [Pack format](packs/format.md)
- [Using packs](packs/using.md) — installing, feature flags,
  troubleshooting.
- [Authoring a pack](packs/authoring.md)
- [Native bindings](packs/native-bindings.md)
- Shipped packs: [kotlinx.atomicfu](packs/shipped/atomicfu.md),
  [kotlinx.io](packs/shipped/io.md),
  [kotlinx.datetime](packs/shipped/datetime.md),
  [kotlinx.coroutines](packs/shipped/coroutines.md),
  [kotlinx.serialization](packs/shipped/serialization.md),
  [io.ktor](packs/shipped/ktor.md),
  [androidx.compose.runtime](packs/shipped/compose-runtime.md).

## Development

- [Workspace layout](development/workspace.md)
- [Testing and verification](development/testing.md) — the unit /
  integration split, the parity sweep, the stdlib commonTest gate,
  and the fast iteration playbook.
- [Contributing](development/contributing.md)

Running plan documents and design records live under `plans/` in the
repository (GC, JIT, coroutine model, resolution work, and the rest);
they are working documents, not user documentation.

## Status

Experimental, tracking Kotlin **2.4.0**. Two harnesses hold the
drop-in claim up: the parity sweep runs every corpus program (532)
and example (142) through both `kotlinc` and klio and diffs stdout
byte-for-byte, and the upstream stdlib's own `commonTest` suite
(117 files, ~2,150 tests) runs directly under the interpreter at
100% per-file pass rate. Kotlin 2.4's new language features
(explicit backing fields, the `@all` use-site target, annotation
use-site defaulting, context parameters) are in progress.
