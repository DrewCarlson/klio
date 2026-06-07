# Contributing

klio is an experiment. Contributions are welcome through GitHub pull
requests; the workflow is small.

## Setup

1. Install Rust 1.95+ via [rustup](https://rustup.rs).
2. `cargo build --workspace` once to pull dependencies.
3. `cargo test --workspace` to confirm a clean baseline.

Parity tests need a `kotlinc` on `PATH`; the harness can auto-install
a pinned one. See [Testing](testing.md).

## Branching and commits

- One topic per branch.
- Commit messages describe **why**, not **what** — the diff shows the
  what.
- Do not add a `Co-Authored-By` trailer.

## Adding a language feature

1. Read the relevant Kotlin Language Specification section (PDFs in
   `kotlin-language-spec/`) and cross-reference the `kotlin/` source.
2. Extend the passes in order: `klio-parser` for new syntax, then
   `klio-ir` lowering and the `klio-interp-ir` Vm for execution.
   Update `klio-resolver` / `klio-typeck` if the feature affects the
   `klio check` diagnostics path.
3. Add at least one corpus program under
   `crates/klio-parity/tests/corpus/` that exercises the feature
   end-to-end.
4. Add at least one `examples/` program demonstrating it with
   deterministic output, and update `examples/README.md`.
5. Run `cargo test --workspace` and the parity sweep. A feature is
   not done until tests fail when it is reverted.

## Adding a pack

1. `klio pack new crates/klio-mylib --id mylib` to scaffold.
2. Edit `klio.toml` and the Kotlin shim under `shim/`.
3. For native bindings, add a Rust crate exposing
   `host_bindings()` and wire it into `klio-cli`'s
   `merged_host_bindings()` and the workspace `Cargo.toml`.
4. Add a smoke `.kt` under `crates/klio-cli/tests/<lib>_pack/`.
5. Document the public surface under `docs/packs/shipped/<name>.md`.

## Diagnostics

User-facing diagnostic messages must not cite the Kotlin Language
Specification. Phrase the problem and the fix in user-actionable
terms; spec references belong in `///` comments above the emitting
code. See [Diagnostics](../architecture/diagnostics.md).

## Style

- `cargo fmt` and `cargo clippy --workspace -- -D warnings` are
  enforced in CI.
- Public functions get `#[must_use]` when the return value is the
  only useful effect.
- Tests over the public API live in `tests/`; tests over internals
  live in `src/` behind `#[cfg(test)]`.
