# Standard library

The Kotlin standard library is delivered as a pack
(`stdlib.klio-pack`) that's embedded into the `klio` binary at build
time. Three modules collaborate to produce it:

| Module          | Role                                                                                            |
|-----------------|-------------------------------------------------------------------------------------------------|
| `stdlib`        | Hand-written Zig intrinsics keyed by FQN, plus the `HostBindings` registry.                     |
| `stdlib_gen`    | Mines upstream Kotlin's `kotlin/libraries/stdlib/` to produce the symbol index.                 |
| `stdlib_pack`   | Resolves the pack bytes the interpreter loads at startup: `KLIO_STDLIB_PACK` override, else a fresh `stdlib.build_stdlib_pack(...)` from the cwd checkout, else the bytes baked into the binary. |

The bake itself happens in build.zig: `src/stdlib_pack/embed_gen.zig`
builds the pack from the repo checkout (every consumed `.kt` is a
declared input of the step, so stdlib edits regenerate it) and the
bytes flow in through the `stdlib_embedded` module. The cwd checkout
outranks the embedded bytes so in-repo stdlib iteration needs no
rebuild; the embedded bytes make the installed binary self-contained
from any directory.

## Symbol registry

Every public symbol mined from upstream becomes a `SymbolEntry`:

```zig
pub const SymbolEntry = struct {
    fqn: []const u8,         // "kotlin.collections.listOf"
    package: []const u8,
    name: []const u8,
    kind: SymbolKind,
    receiver: ?[]const u8,
    signature: []const u8,
    param_names: []const []const u8,
    modifiers: Modifiers,
    source: SourceLoc,
    impl_fn: ?StdlibFn,
};
```

The registry serves two consumers:

1. **Resolver** — `is_known_package` and the symbol index validate
   imports during `klio check`.
2. **Vm** — `stdlib.implementation(fqn)` looks up the runtime
   function pointer at dispatch.

Coverage is reported via `stdlib.coverage()` (`implemented`
over `total`).

## Implicit imports

Spec §10.1 lists the packages every Kotlin file imports
implicitly. `stdlib.IMPLICITLY_IMPORTED_PACKAGES` is the exact
list. Loaded packs may extend it through `register_known_package`,
which is what kotlinx packs use to declare their packages visible.

## Adding a new intrinsic

1. Add the function under `src/stdlib/implementations/` (or
   `src/stdlib/implementations.zig`) keyed by its Kotlin FQN.
2. Add a sibling entry in `src/stdlib_gen/` if the FQN is
   not already mined.
3. Update or add a corpus program covering it.
4. Re-run `zig build test` and `klio pack verify`.

For library-shaped surface area, prefer a pack over a stdlib
intrinsic: the pack carries documentation, ships with a binding
manifest, and stays out of `stdlib`'s static surface.
