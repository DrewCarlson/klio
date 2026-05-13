# Testing

klio's correctness rests on four layers:

## 1. Unit tests

Each crate owns its unit tests under `crates/<name>/src/` (modules
gated on `#[cfg(test)]`) and `crates/<name>/tests/` for integration
tests. They cover happy paths, edge cases, and every diagnostic the
code can emit.

```sh
cargo test -p klio-typeck
cargo test --workspace
```

## 2. Negative tests

`crates/klio-typeck/tests/negative/` pins diagnostic wording per
code. Removing a diagnostic or changing its phrasing fails the
matching `negative.rs` snapshot.

## 3. Corpus + parity sweep

`crates/klio-parity` is the safety net:

- Walks every `.kt` file under
  `crates/klio-parity/tests/corpus/` and `examples/`.
- Compiles each program through `kotlinc-native 2.3.21` and through
  klio.
- Diffs stdout. Any byte difference fails the sweep.

Running the sweep requires a local kotlinc-native install. See
`plans/BENCHMARKS.md` for the toolchain pinning. To run only the
example sweep:

```sh
cargo test -p klio-parity --test parity examples_pass_parity
```

The corpus only grows. Removing a `.kt` from it is a deliberate act
that requires reviewer sign-off.

## 4. Pack smoke tests

Every pack ships a smoke flow:

```sh
cargo run -p klio-cli -- pack build crates/klio-kotlinx-datetime
cargo run -p klio-cli -- pack verify target/packs/kotlinx.datetime.klio-pack \
    --smoke crates/klio-cli/tests/kotlinx_pack/kotlinx_demo.kt
```

The `kotlinx_demo.kt` program imports all four shipped kotlinx
packs and prints deterministic output a future test harness will
assert against.

## Pre-commit checks

Before committing, run:

```sh
cargo build --workspace --tests
cargo test --workspace
```

CI runs the same flow on every PR plus the parity sweep.
