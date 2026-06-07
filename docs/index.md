# klio

An experimental Kotlin interpreter written in Rust.

klio reads a `.kt` source file (or a set of files), lowers it to a
register-based intermediate representation, and executes that IR
directly. There is no JVM, no Kotlin/Native, and no separate
compilation step — the same hand-written Rust pipeline that parses
your code also runs it.

## Highlights

- **IR-based execution.** Source is lowered by `klio-ir` into a
  register IR that `klio-interp-ir`'s Vm runs. The Vm never walks an
  AST.
- **Spec-driven.** The Kotlin Language Specification (2.3.21) and the
  upstream Kotlin source are the references. Every supported feature
  ships with corpus tests that byte-match `kotlinc`.
- **Pack-based standard library.** The stdlib lives in a versioned
  `.klio-pack` archive embedded into the binary; the same format
  hosts third-party Kotlin libraries.
- **Declarative native bindings.** A pack's `klio.toml` lists
  `FQN → host_symbol` pairs. Rust crates register host symbols once;
  the loader joins them at install time and a native function
  shadows the matching Kotlin body at dispatch.
- **Single binary.** `cargo install --path crates/klio-cli` produces
  a `klio` command that runs files, type-checks, and manages packs.

## Where to start

- [Install klio](getting-started/installation.md) and run your first
  program.
- Take the [CLI tour](getting-started/cli.md) for the full command
  surface.
- Read the [pipeline overview](architecture/pipeline.md) to see
  where each Kotlin construct is handled.
- Read the [pack overview](packs/overview.md) for how libraries are
  shipped and consumed.

## Status

Experimental, tracking Kotlin **2.3.21**. The `klio-parity` harness
runs every corpus and example program through both `kotlinc` and
klio and diffs stdout; the current sweep is **353/353** (285 corpus
+ 68 examples). Coverage is broad enough to run non-trivial programs
but klio is not a `kotlinc` replacement.
