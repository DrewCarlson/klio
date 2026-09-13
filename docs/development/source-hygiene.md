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

## Verification

- `python3 scripts/comment_only_check.py <base-rev> [paths...]` proves a
  comment pass changed no code: it strips comments and whitespace from both
  revisions and reports any file whose code text moved.
- `python3 scripts/zigcheck.py <module>` compiles and tests one module.
- `zig build && zig build test` after every batch.
- `scripts/quick-gate.sh` for the fast full battery.
