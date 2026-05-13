# Standard library

The Kotlin standard library is delivered as a pack
(`stdlib.klio-pack`) that's embedded into the `klio` binary at build
time. Three crates collaborate to produce it:

| Crate                 | Role                                                                                            |
|-----------------------|-------------------------------------------------------------------------------------------------|
| `klio-stdlib`         | Hand-written Rust intrinsics keyed by FQN, plus the `HostBindings` registry.                    |
| `klio-stdlib-gen`     | Mines upstream Kotlin's `kotlin/libraries/stdlib/` to produce the symbol index.                 |
| `klio-stdlib-pack`    | Build-script crate that calls `klio_stdlib::build_stdlib_pack(...)` and `include_bytes!`s it.   |

## Symbol registry

Every public symbol mined from upstream becomes a `SymbolEntry`:

```rust
pub struct SymbolEntry {
    pub fqn: &'static str,         // "kotlin.collections.listOf"
    pub package: &'static str,
    pub name: &'static str,
    pub kind: SymbolKind,
    pub receiver: Option<&'static str>,
    pub signature: &'static str,
    pub param_names: &'static [&'static str],
    pub modifiers: Modifiers,
    pub source: SourceLoc,
    pub impl_fn: Option<StdlibFn>,
}
```

The registry serves two consumers:

1. **Resolver** — `is_known_package` and `all_symbol_names` use the
   index to validate imports.
2. **Interpreter** — `klio_stdlib::implementation(fqn)` looks up
   the runtime function pointer.

Coverage is reported via `klio_stdlib::coverage()` (`implemented`
over `total`).

## Implicit imports

Spec §10.1 lists the packages every Kotlin file imports
implicitly. `klio_stdlib::IMPLICITLY_IMPORTED_PACKAGES` is the exact
list. Loaded packs may extend it through `register_known_package`,
which is what kotlinx packs use to declare their packages visible.

## Adding a new intrinsic

1. Add the function to `crates/klio-stdlib/src/implementations.rs`
   keyed by its Kotlin FQN.
2. Add a sibling entry in `crates/klio-stdlib-gen` if the FQN is
   not already mined.
3. Update or add a corpus program covering it.
4. Re-run `cargo test --workspace` and `klio pack verify`.

For library-shaped surface area, prefer a pack over a stdlib
intrinsic: the pack carries documentation, ships with a binding
manifest, and stays out of `klio-stdlib`'s static slab.
