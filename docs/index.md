# klio

An experimental Kotlin interpreter written in Rust.

klio reads a `.kt` source file (or set of files) through a full
front-end pipeline — lexer → parser → resolver → typechecker → CFG
analyses → interpreter — and executes the program directly. There is
no separate compilation step, no JVM, and no Kotlin/Native: every
Kotlin language feature that klio supports runs through the same
hand-written Rust pipeline.

## Highlights

- **Spec-driven.** The Kotlin Language Specification (v2.3.21) is the
  primary source of truth. Each implemented section ships with corpus
  tests that byte-match `kotlinc-native`.
- **Pack-based standard library.** klio's stdlib lives in a
  versioned `.klio-pack` archive embedded into the binary; the same
  format hosts third-party Kotlin libraries.
- **Native bindings, declarative.** A pack's `klio.toml` lists
  `FQN → host_symbol` pairs. Rust crates register host symbols once;
  the loader joins them to the bindings at install time, and a
  matching native function shadows the corresponding Kotlin body at
  dispatch.
- **Single binary.** `cargo install --path crates/klio-cli` produces
  a `klio` command that runs files, scaffolds libraries, builds
  packs, and inspects pack archives.

## Where to start

- [Install klio](getting-started/installation.md) and run your first
  program.
- Read the [pack overview](packs/overview.md) to understand how
  libraries are shipped and consumed.
- Skim the [pipeline](architecture/pipeline.md) if you want to know
  where each Kotlin construct is implemented.

## Status

Tracking against Kotlin 2.3.21. ~270 corpus programs and a growing
example suite match `kotlinc-native` byte-for-byte. Detailed
in-progress work lives in `plans/PLAN.md` (development) and
`plans/PACK-ROADMAP.md` (pack system). Everything user-facing lives
here under `docs/`.
