# Testing

klio's correctness rests on four layers.

## 1. Unit tests

Each crate owns its unit tests under `crates/<name>/src/` (modules
behind `#[cfg(test)]`) and `crates/<name>/tests/` for integration
tests. They cover happy paths, edge cases, and every diagnostic the
code can emit.

```sh
cargo test -p klio-typeck
cargo test --workspace
```

## 2. Negative tests

`crates/klio-typeck/tests/negative/` pins diagnostic wording per
code. Removing a diagnostic or changing its phrasing fails the
matching snapshot.

## 3. Corpus + parity sweep

`crates/klio-parity` is the primary correctness gate:

- Walks every `.kt` under `crates/klio-parity/tests/corpus/` (285
  programs) and `examples/` (68 programs).
- Compiles each through `kotlinc` and through klio.
- Diffs stdout. Any byte difference fails the sweep.

The harness defaults to JVM `kotlinc` (fast: ~1s compile, jar run)
and targets Kotlin 2.3.21. It auto-installs a pinned `kotlinc` if
none is found; set `KLIO_KOTLINC_JVM_HOME` to point at an existing
distribution, or `KLIO_NO_AUTO_INSTALL_KOTLINC=1` to disable
auto-install (the parity tests then skip).

Run only the example sweep:

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

`pack verify` re-decodes every section through the loader; with
`--smoke` it also runs a program against the pack, exercising both
binding resolution and the shipped Kotlin source.

## Before committing

```sh
cargo build --workspace --tests
cargo test --workspace
```

CI runs the same flow on every PR, plus the parity sweep.
