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

Then, from a profile whose largest single symbol turned out to be `memset`:

- The binary's `memset` was Zig compiler-rt's, which stores a byte at a time
  and is linked weakly; every `@memset` ran it (zeroing the passes' count
  tables, filling each fresh allocation of a safe build with `0xAA`). It
  was a third of a cold build. `src/fastmem` is a `memset` that stores wide
  words, built with `-fno-builtin` so its stores do not compile into a call
  to itself, and linked strongly in compiler-rt's place. Forwarding to the
  platform's instead is not safe everywhere: glibc's `__memset_chk` is
  folded back into a `memset` call by the optimizer, and compiler-rt's own
  weak `__memset_chk` shadows glibc's. C passes the fill as an `int`,
  possibly sign-extended; only its low byte is stored.
- A file's initialization unit scanned every symbol for that file's
  statics; they are bucketed by file once (`Program.staticsOf`).
- The image is encoded into one buffer, its header patched in at the end
  (`codec.Stream`), the bodies' section into another with one encoder reset
  per body: the image bytes are identical.

| | wall | `bodies` | `bridge` | `lower` |
|---|---:|---:|---:|---:|
| cold compose_material3, before | 3.80 s | 1.64 s | 0.22 s | 1.20 s |
| cold compose_material3 | 2.57 s | 1.16 s | 0.15 s | 0.79 s |
| cold compose_material3 on Linux (aarch64) | 3.88 s to 2.66 s | | | |
| cold hello | 0.44 s to 0.28 s | | | |

Execution gains too: the `collections` and `strings` memory benchmarks run
about a fifth faster.

Then three scans and a fixpoint that ran far more often than they had to:

- `calls.functionShape` found a class's `FunctionN` arity by scanning four
  arity-to-class maps on every call, for every type asked about; sema keeps
  them turned around (`Sema.fnClassOf`), rebuilt when they grow.
- An adapter's reference was found by scanning every record of every file
  (568K) per adapter; the records are indexed by what they adapt once
  (`Program.adapterRef`).
- Pruning dead type values removed a chain of copies one link per sweep;
  a sweep now walks each block backward, from reads to writes.
- Register placement intersects each clash row with the registers placed so
  far before walking its bits.

| | wall | `bodies` | `lower` |
|---|---:|---:|---:|
| cold compose_material3 | 2.23 s | 1.05 s | 0.60 s |

Then what a profile of `bodies` showed:

- `calls.topLevelTiers` walked a file's explicit imports, its package, its
  star imports and every default import for each name a body looked up:
  about half a million calls over 60K distinct file and name pairs. Sema
  keeps the answers, and the top-level extension functions
  `calls.extensionFunctions` takes from them, while `resolveAll` runs
  (`scope.TopLevelMemo`). Indexing a declaration drops them
  (`Symbols.index_gen`); their memory is freed between declarations.
- The type table regrew to 268K types, rehashing all of them each time:
  `resolveAll` reserves a type for every four nodes up front.
- Register compaction took its tables from the process heap, which maps
  fresh pages for the large ones on every body; they come from the body's
  scratch.
- The bridge formats a declaration's qualified name once.

| | wall | `bodies` |
|---|---:|---:|
| cold compose_material3 | 2.23 s to 2.01 s | 1.05 s to 0.84 s |
| bake compose_material3 | 2.37 s to 2.16 s | |
| cold hello | 0.26 s to 0.23 s | |

Then the parse ahead of all of it:

- A run's packs parsed one file after another: the run's arena serves one
  thread, so the parse pool, which needs an allocator that serves several,
  was never used. Each parse thread now parses a file in a scratch of its
  own and moves its tree into a heap of its own over the arena, taking
  chunks of it under a lock (`WorkerHeap`); the stdlib's own files parse
  the same way. `load and parse` on compose_material3 without an image,
  370 ms to 200 ms, wall 2.0 s to 1.83 s.
- The pool cuts a large file into pieces on threads that serve several,
  as the bake's heap does. Every piece numbered its nodes from 1 and the
  assembled file kept the first piece's count, so two nodes of a cut file
  could share an id, which sema keys its records by; the later pieces'
  annotated expressions were dropped. The assembled file is numbered again
  in source order, as a whole parse numbers it: a bake from pieces and one
  from whole files now give the same image byte for byte.

Then where a bake peaks, in its image's encode: the image was encoded into
one buffer, grown by doubling to 75 MB for its 54 MB (on macOS a grown
buffer is a copy, so for a moment both), and then only written to the
cache file and mapped back.

- `codec.Stream` takes a sink (`Stream.initTo`): once its buffer holds a
  megabyte it writes the buffer there, and a header is patched in place
  (`Stream.patch`). A bake writes its image into the cache's temporary
  file as it encodes it (`sema_base_cache.Writing`), renamed into place
  when whole; the image is byte for byte the one encoded in memory.
- The bridge resolves the headers it asks for (a class's supertypes, a
  member's overrides) in sema's scratch, emptied after each declaration:
  outside `resolveAll` sema's scratch is its arena, so their working data
  stayed for good.

| | peak RSS |
|---|---:|
| bake compose_material3 | 946 MB to 817 MB |
| cold compose_material3 | 664 MB to 635 MB |

## Next

- Register compaction is a third of lowering now: liveness, interference
  and placement over bitsets as wide as the register count.
- A bake peaks while its image is encoded: the sema, bridge and module
  tables are first copied into the image's shape (`base_sema.image`,
  `bridgeImage`, `resolvedImage`), which an encoder reading the live tables
  would not need.
