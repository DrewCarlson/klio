# Contributing

klio is an experiment. Contributions are welcome through GitHub pull
requests; the workflow is small.

## Setup

1. Install Zig 0.16.0 and put `zig` on your `PATH`.
2. `zig build` once to compile the interpreter.
3. `zig build test` to confirm a clean baseline.

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
2. Extend the passes in order: `parser` for new syntax, then
   `ir` lowering and the `interp_ir` Vm for execution.
   Update `resolver` / `typeck` if the feature affects the
   `klio check` diagnostics path.
3. Add at least one corpus program under
   `tests/fixtures/parity_corpus/` that exercises the feature
   end-to-end.
4. Add at least one `examples/` program demonstrating it with
   deterministic output, and update `examples/README.md`.
5. Run `scripts/gate.sh` (or the targeted subset from the
   [iteration playbook](testing.md)). A feature is not done until
   tests fail when it is reverted.

## Adding a pack

1. `klio pack new kotlin-klio/klio-mylib --id mylib` to scaffold.
2. Edit `klio.toml` and the Kotlin shim under `klioMain/`.
3. For native bindings, add a Zig module exposing
   `hostBindings()` and wire it into the CLI's
   `mergedHostBindings()` and `build.zig`.
4. Add a smoke `.kt` under `tests/fixtures/` for the new pack.
5. Document the public surface under `docs/packs/shipped/<name>.md`.

## Diagnostics

User-facing diagnostic messages must not cite the Kotlin Language
Specification. Phrase the problem and the fix in user-actionable
terms; spec references belong in `///` comments above the emitting
code. See [Diagnostics](../architecture/diagnostics.md).

## Zig conventions

klio began as a Rust codebase and was fully ported to Zig; the port
is complete. The conventions that outlived it:

- One module per subsystem: `src/<name>/<name>.zig` is the root
  file and re-exports the module's public API. Cross-module use goes
  through `@import("span")`, `@import("ast")`, … as registered in
  `build.zig`'s `mod_list`; intra-module files use relative
  `@import("foo.zig")`.
- Diagnostics are **data**, not Zig errors: user-facing parse/type
  errors collect into a `DiagnosticSink`. Reserve Zig `error` values
  for out-of-memory, IO, and truly exceptional control flow.
- Thread `std.mem.Allocator` explicitly. Prefer an arena per phase
  (parse, lower, eval); every type that owns heap memory outside an
  arena gets a `deinit`. Document ownership at API boundaries.
- Containers default to the unmanaged `std.ArrayList(T)` (allocator
  passed to `append`/`deinit`); hash maps use the managed API
  (`.init(allocator)`).
- snake_case fields, camelCase functions/methods, TitleCase types.

## Style

- `zig fmt` and a clean `zig build test` are enforced in CI.
- Integration tests over the public API live under `src/itests/`;
  unit tests over internals live alongside the code in `test {}`
  blocks within each `.zig` file.
