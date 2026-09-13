# Source hygiene

A running record of the structural cleanup of `src/`: comment quality, file
size, function size, and Zig 0.16 idiom. Update the tables as work lands.

## Rules

### Comments

A comment earns its place by saying something the code cannot. Keep
invariants, ownership and lifetime contracts, the reason a non-obvious
branch exists, and the shape of a wire format or protocol. Cut everything
else.

- No references to plan documents, milestone numbers, census runs, or
  measurement history. `Phase` is fine when it names a real compiler or
  interpreter phase; it is not fine as a label for staged feature work.
- No narration of how the code got here: what it used to do, what the Rust
  original did, which commit changed it. Git history holds that.
- No framing that calls the work hard, fragile, or incomplete. Describe what
  the code guarantees, not what it struggles with.
- No em-dashes. Use a comma, colon, semicolon, or a second sentence.
- No restating the signature. `/// Returns the name of the class.` above
  `fn className() []const u8` is noise.
- Doc blocks stay under roughly six lines. A module header may run longer
  when it documents a format or a protocol.

### Files

No source file over ~3000 lines. Split along a real seam (one concern per
file), not at an arbitrary line count. Sibling files inside a directory may
import each other; the parent re-exports what the rest of the tree calls.

### Functions

No function over ~150 lines. Extract named helpers whose names say what the
step does. A long `switch` over an opcode or AST tag is the exception when
each arm is short.

### Zig

Target 0.16: `std.ArrayList` (unmanaged) over `std.ArrayListUnmanaged`,
labeled `switch` with `continue :label` for interpreter dispatch loops,
`@branchHint` on cold paths, arena allocators for phase-scoped data.

## Splits landed

Eleven files over 5000 lines were split along real seams. Each parent keeps
its public surface and re-exports it, so no call site outside the file
changed.

| was | lines | now | files | largest child |
|---|---|---|---|---|
| `ir/lower/expr.zig` | 27008 | `ir/lower/expr/` | 24 | 2229 |
| `ir/ir.zig` | 17236 | `ir/core/` | 18 | 2365 |
| `interp_ir/vm/host_call_member.zig` | 16968 | `.../host_call_member/` | 16 | 2112 |
| `ir/eval.zig` | 13546 | `ir/eval/` | 17 | 1706 |
| `stdlib/implementations/collections.zig` | 8222 | `.../collections/` | 13 | 1118 |
| `cli/cgen.zig` | 8016 | `cli/cgen/` | 8 | 1848 |
| `ir/jit_loop.zig` | 7304 | `ir/jit_loop/` | 10 | 1561 |
| `interp_ir/build.zig` | 6495 | `interp_ir/build/` | 7 | 2988 |
| `interp_ir/vm/host_instances.zig` | 6150 | `.../host_instances/` | 8 | 1399 |
| `interp_ir/vm/host_fields.zig` | 5826 | `.../host_fields/` | 10 | 1572 |
| `compose_pass/compose_pass.zig` | 5294 | `compose_pass/pass/` | 9 | 1829 |

### What a split has to get right

Three traps, each of which the compile caught only once the parent's test
block referenced every child:

- A `var` cannot be re-exported through a `const` alias. Either the `var`
  stays in the parent, or every reader qualifies it against the one file
  that owns the storage. Two copies of a cache is a real bug.
- A struct method a sibling now calls needs `pub`. An object-only build
  will not tell you: an unreferenced declaration is never analyzed.
- Two functions that each declare their own anonymous result type cannot
  delegate to each other. Give the type a name.

The parent's test block must call `refAllDecls` on each child by path.
Referencing only the children the alias table happens to name left the ir
module running 162 of its 258 tests.

## Verification

- `python3 scripts/comment_only_check.py <base-rev> [paths...]` proves a
  comment pass changed no code: it strips comments and whitespace from both
  revisions and reports any file whose code text moved.
- `python3 scripts/zigcheck.py <module>` compiles and tests one module.
- `zig build && zig build test` after every batch.
- `scripts/quick-gate.sh` for the fast full battery.
