# Lowering memory, churn and speed

After sema (`plans/sema-memory.md`), the build's memory and time were in
bridging and lowering: on `compose_material3.kt` analyzed without an image,
`lower` added 424 MB and took 1.3 s, `bridge` added 166 MB.

## How it is measured

- `$SP/low/measure.sh <binary> <label>` (session scratchpad) prints peak RSS
  and each step's time and RSS (`KLIO_SEMA_TIMING`) for compose_material3
  cold and baked and hello cold.
- `KLIO_SLAB_CENSUS=churn KLIO_SLAB_CENSUS_AT='bake: lower'` prints the
  allocation census when lowering ends, before the bake drops its heap (the
  census at exit has lost those sites by then).
- `KLIO_LOWER_FINGERPRINT=1` prints one line per lowered body with a hash of
  its blocks by value. A change meant to leave the IR alone must leave this
  file identical: 74007 bodies on compose_material3.

## Done

- Each body lowers in a scratch level of its own (`Program.pushScratch`):
  its blocks and instruction lists, its tables of locals, receivers and
  loops, its argument runs, and the passes `Builder.finish` runs.
  `finish` compacts registers on the scratch blocks and copies the body out
  to the program's arena once (`copyOut`: one array for its instructions,
  one for closure captures). A lambda's or an inline callee's body lowers
  inside its caller's, on a level above it. What goes to the program stays
  in the arena: interned constants, errors, the `coerce` memos.
- `finish` runs a pass only on a body holding the instructions it acts on
  (a conversion, a `!`, a cell, a copy).
- The passes no longer remove instructions one at a time from the middle of
  a block (each a shift of the rest): they mark them and drop the marks
  once. `aliasRuns` finds a copy and a later write of its source from the
  last write of each register, in one walk of the block, not a scan per
  argument. Pruning keeps its read counts current instead of recounting.
- Register placement stamps the slots a unit's clashes take instead of
  clearing a table per unit.

All of it leaves every body's IR identical (`KLIO_LOWER_FINGERPRINT`).

| | peak RSS | `lower` | RSS added by `lower` |
|---|---:|---:|---:|
| cold compose_material3, before | 1014 MB | 1.33 s | 424 MB |
| cold compose_material3 | 671 MB | 1.20 s | 81 MB |
| bake compose_material3 | 965 MB | 1.24 s | 89 MB |
| cold hello | 86 MB | 0.07 s | 9 MB |

## Next

- Register compaction is a quarter of lowering: interference and placement
  walk every clash edge.
- The bridge adds 166 MB: 614K qualified names formatted (92 MB churn),
  headers, parameters, override roots.
- A bake's image encoding adds 200 MB after lowering, the bake's peak.
