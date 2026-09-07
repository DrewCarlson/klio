# Stdlib strategy

The Kotlin stdlib is **the** runtime surface a program has access to. klio ships a complete implementation that behaves exactly like Kotlin 2.4.0's stdlib on the JVM where semantics are platform-agnostic.

## Guiding principles

1. **Upstream source is the implementation.** The stdlib pack's Kotlin source is the upstream tree itself (`kotlin/libraries/stdlib`, pinned at v2.4.0) plus klio-authored actuals under `kotlin-klio/`, interpreted like any other Kotlin. Hand-written Zig intrinsics (`src/stdlib/implementations/`) shadow individual functions at dispatch where host access (IO, clock, threads) or performance demands a native body. This inverts the original plan (all-native, CPython-style): interpreting upstream keeps behavior exactly aligned and makes version bumps a re-pin, not a rewrite.

2. **The API surface is mined, not maintained by hand.** `stdlib_gen` reads `kotlin/libraries/stdlib/` and produces the symbol index (`SymbolEntry` per public symbol: FQN, kind, signature, modifiers, source span) that the resolver and the Vm's dispatch consult. Bumping Kotlin versions regenerates the surface mechanically.

3. **Pin to Kotlin 2.4.0.** The `kotlin/` submodule is pinned at the tag; bumping is a deliberate, tracked operation.

4. **Coverage is enforced by upstream's own tests.** The upstream stdlib `commonTest` suite (117 files, ~2,150 tests) runs directly under the interpreter. `src/itests/stdlib_commontest.zig` ratchets the pass count (never lower it); `scripts/commontest-sweep.py` gives per-file iteration. The suite passes per-file at 100% as of 2026-07-06.

## Sources of truth in the `kotlin/` checkout

| Path                                                                | Role                                                                                                |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `libraries/stdlib/common/src/kotlin/`                               | Hand-written headers declaring the common surface (often with `expect`).                            |
| `libraries/stdlib/common/src/generated/`                            | JetBrains-generated files: `_Collections.kt`, `_Arrays.kt`, `_Sequences.kt`, `_Maps.kt`, `_Ranges.kt`, `_Strings.kt`, `_Comparisons.kt`, and unsigned-variant siblings. |
| `libraries/stdlib/src/kotlin/`                                      | Pure-Kotlin definitions shared across platforms (no `expect`).                                      |
| `libraries/stdlib/jvm/src/`                                         | JVM `actual` implementations — read **only** to disambiguate semantics, never linked.               |
| `libraries/stdlib/test/`                                            | The `commonTest` suite klio runs as its conformance gate.                                           |
| `libraries/kotlin.test/`                                            | The `kotlin.test` API shipped as the kotlin.test pack.                                              |

## Architecture

Three Zig modules plus the pack machinery deliver the stdlib
(details in `docs/architecture/stdlib.md`):

- **`stdlib`** — the native intrinsics keyed by FQN, the
  `HostBindings` registry, and the implicit-import package list.
- **`stdlib_gen`** — mines the upstream tree into the symbol index
  committed under `src/stdlib/`.
- **`stdlib_pack`** — resolves the pack bytes the interpreter loads
  at startup: `KLIO_STDLIB_PACK` override, else a fresh build from
  the cwd checkout (so in-repo stdlib edits need no rebuild), else
  the bytes embedded into the binary by `build.zig`.

At dispatch, `stdlib.implementation(fqn)` is the single resolution
path: when an intrinsic exists for a FQN it shadows the lowered
Kotlin body, otherwise the interpreted upstream source runs. The
lowered stdlib is baked to a content-addressed image under
`~/.klio/cache` so runs after the first skip re-lowering it.

## Implementation discipline

For every stdlib gap that closes:

1. **Prefer consuming more upstream source** over adding an
   intrinsic; an intrinsic is for host access or measured hot paths.
2. **Match Kotlin/JVM semantics exactly**: integer overflow wraps,
   `Double`/`Float` follow IEEE-754 with JVM formatting, `String` is
   UTF-16 in observable behavior.
3. **Test through upstream's own suite** — the commonTest ratchet
   only goes up — plus parity corpus programs for anything
   user-visible.

## What we are explicitly *not* doing

- Loading the upstream stdlib's compiled `.klib` / `.jar` artifacts.
- Implementing JVM-runtime-dependent pieces (`java.*` interop
  helpers) beyond what upstream's common surface requires.
