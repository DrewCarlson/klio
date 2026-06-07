# Zig port conventions

Read this before porting any Rust file to Zig. The goal is a faithful translation:
same behavior, same names, same structure, same diagnostics. Not a redesign.

## Toolchain
- Zig 0.16.0 (`zig` on PATH). Build: `zig build`. Test: `zig build test`.
- Each former Rust crate is a Zig module under `src/<name>/<name>.zig` (root file).
  Hyphens become underscores: `klio-interp-ir` → module `interp_ir`.
- The root file re-exports the module's public API (`pub const X = @import("x.zig").X;`).
- Cross-module use: `@import("span")`, `@import("ast")`, etc. (registered in build.zig).
  Add intra-module files via relative `@import("foo.zig")`.

## Layout within a module
- Mirror the Rust file structure: `crates/klio-foo/src/bar.rs` → `src/foo/bar.zig`.
- Put shared types (the ones every file references) in the root or a `types.zig`,
  imported by the rest. Decide this first so parallel file ports agree on shapes.

## Type mapping
| Rust | Zig |
|------|-----|
| `struct Foo(pub u32)` newtype | `pub const Foo = enum(u32) { _, pub fn from/int };` |
| `String` (owned) | `[]const u8` (owned; document the owner/allocator) |
| `&str` | `[]const u8` (borrowed) |
| `Vec<T>` | `std.ArrayList(T)` (unmanaged: init `.empty`, methods take allocator) or `[]T` when frozen |
| `Box<T>` | `*T` (heap via allocator) |
| `Option<T>` | `?T` |
| `Result<T, E>` | `E!T` (error union) or `union(enum){ ok: T, err: E }` when E is data |
| `HashMap<K,V>` | `std.AutoHashMap(K,V)` / `std.StringHashMap(V)` (managed: `.init(a)`) |
| `Rc<T>`/`Arc<T>` | reference-counted struct, or arena ownership; see Memory below |
| enum with data | `union(enum)` (tagged union) |
| C-like enum | `enum` |
| `derive(Clone)` | a `pub fn clone(self, allocator) !Self` when it owns heap data; trivial copy otherwise |
| trait | a struct of fn pointers (vtable) or `comptime` interface; pick simplest faithful form |
| `impl Trait for X` dispatch | tagged-union switch, or vtable when truly dynamic |

## Memory
- Thread `std.mem.Allocator` explicitly. Prefer an arena per phase (parse, lower, eval)
  matching where Rust dropped the data at scope exit.
- Containers default to the **unmanaged** `std.ArrayList(T)` (allocator passed to
  `append`/`deinit`/`toOwnedSlice`). Hash maps use the **managed** API (`.init(a)`).
- Every type that owns heap memory gets a `deinit(self, allocator)` (or relies on an arena).
- Match Rust ownership: what `Drop`/scope-exit freed in Rust must be freed in Zig.

## Errors & diagnostics
- Compiler diagnostics (user-facing parse/type errors) are **data**, collected into a
  diagnostics sink — they are NOT Zig `error` values. Reserve Zig `error` for
  out-of-memory / IO / truly exceptional control flow, mirroring Rust's `Result` vs
  pushing a `Diagnostic`.
- Keep diagnostic message text identical to the Rust version. No spec citations in
  user-facing messages (see CLAUDE.md).

## Tests
- Translate the Rust `#[test]` functions in each file into Zig `test "name" {}` blocks
  in the corresponding `.zig` file. Keep assertions equivalent.
- A ported file is not done until its module is added to `build.zig` (`.tested = true`)
  and `zig build test` passes for it.

## Style
- No AI-tell comments, no "Phase X" references in code/comments (see CLAUDE.md).
- snake_case fields, camelCase functions/methods, TitleCase types (Zig idiom).
- Keep doc comments (`///` → `///`) where they aid understanding; drop spec-tail noise.
