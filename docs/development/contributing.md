# Contributing

klio is an experiment. Contributions are welcome through GitHub
pull requests; the workflow is small.

## Setup

1. Install Rust 1.95+ via [rustup](https://rustup.rs).
2. `cargo build --workspace` once to pull deps.
3. `cargo test --workspace` to confirm a clean baseline.

For parity testing you also need `kotlinc-native 2.3.21` on your
`$PATH`. See `plans/BENCHMARKS.md`.

## Branching and commits

- One topic per branch.
- Commits should describe **why** not **what** — the diff already
  shows the what.
- Do not add a `Co-Authored-By` trailer.
- Do not commit files under `docs/` from a feature PR — they ship
  through the docs site separately.

## Adding a language feature

1. Read the relevant Kotlin Language Spec section (PDFs in
   `kotlin-language-spec/`).
2. Update the parser / resolver / typecheck / interp passes in
   that order.
3. Add at least one corpus program under
   `crates/klio-parity/tests/corpus/` that exercises the feature
   end-to-end.
4. Add one or more `examples/` programs that demonstrate the
   feature with deterministic output.
5. Run `cargo test --workspace` and the parity sweep.

## Adding a pack

1. `klio pack new crates/klio-mylib --id mylib` to scaffold.
2. Edit `klio.toml` and the Kotlin shim under `shim/`.
3. Wire the Rust binding crate into `klio-cli`'s `merged_host_bindings`
   and the workspace `Cargo.toml`.
4. Add a smoke `.kt` under `crates/klio-cli/tests/<lib>_pack/`.
5. Document the public surface under
   `docs/packs/shipped/<name>.md`.

## Diagnostics

User-facing diagnostic messages must not cite the spec. Spec
references belong in `///` comments above the emitting code or in
`plans/PLAN.md`. See [Diagnostics](../architecture/diagnostics.md).

## Style

- `cargo fmt` and `cargo clippy --workspace -- -D warnings` are
  enforced in CI.
- Public functions get `#[must_use]` when their return value is the
  only useful side effect.
- Tests over the public API live in `tests/`; tests over internals
  live in `src/` behind `#[cfg(test)]`.
