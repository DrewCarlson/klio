# Sema memory and churn

Sema analyzes every body of the base (stdlib, klio's actuals, the packs a
program selects) when no cached base image serves it: the cold path
(`KLIO_SEMA_IMAGE=0`, the differential suite's fresh base, any arena-backed
analysis) and the bake that makes the image. The goal is the least memory
held and the least allocated, at the same or better speed.

## How it is measured

`$SP/mem/measure.sh <binary> <label>` in the session scratchpad runs, from
the checkout, `compose_material3.kt` cold and baked and `hello.kt` cold, over
a copy of the test home, and prints peak RSS (`/usr/bin/time -l`), wall time
and the `bodies` phase's time and RSS (`KLIO_SEMA_TIMING`). Attribution:

- `KLIO_SLAB_CENSUS=churn` on a bake (sema runs on the slab build heap there)
  with `scripts/slab_census.py --churn`: bytes allocated by call site. The
  scratch arena below is page-allocator memory the census does not see.
- `KLIO_SEMA_TABLES=1` (with `KLIO_SEMA_TIMING`): the size of each table the
  analysis keeps, after a bake.

## Where it stood (2026-10-03)

| | peak RSS | `bodies` | RSS added by `bodies` |
|---|---:|---:|---:|
| cold compose_material3 | 5153 MB | 4.4 s | 4187 MB |
| bake compose_material3 | 2470 MB | 4.5 s | 1399 MB |
| cold hello | 355 MB | 0.28 s | 241 MB |

A bake allocated 6.3 GB in all. `infer.zig` allocated 2.6 GB of it: a trial
solve copied the whole constraint system (`clone`), and `solve` and the type
rebuilders (`zonk`, `close`, `replaceVars`, `substitute`) allocated working
lists and argument arrays into the analysis's arena, which never frees.
Material3's 75 locale tables (`Translations.xx() = mapOf(<90 pairs>)`,
expression-bodied) were the worst case: each `a to b` argument leaves its
`A`/`B` variables open for `mapOf`'s system to adopt, so the system grows by
two variables per argument and each argument's trial copied all of them,
O(n^2): 43 MB for one 90-pair call, 2.7 GB for the declaration whose
inference reached all 75.

## Done

- Call resolution works in `Sema.scratch_arena` (`s.scratch()`): constraint
  systems and their lists, solver temporaries. It is emptied after each
  top-level declaration `resolveFile` resolves (where no call is being
  resolved), keeping up to 16 MiB, and freed when `resolveAll` ends. What a
  system publishes past itself (`open_var_bounds`) is copied into the arena.
- A trial no longer copies the system: `tryConstrain` / `wouldConstrain` /
  `tryConstrainBoth` constrain the system itself under an undo log of the
  bounds appended and the variables adopted, and take a failed attempt back.
  A trial that succeeded was constrained twice before; now once.
- Types rebuilt only to be interned (`intern` copies) take their parts from
  a stack buffer (`types.PartsBuf`, 16 inline).

| | peak RSS | `bodies` | RSS added by `bodies` |
|---|---:|---:|---:|
| cold compose_material3 | 2411 MB | 1.84 s | 1446 MB |
| bake compose_material3 | 2368 MB | 2.04 s | 1299 MB |
| cold hello | 329 MB | 0.25 s | 217 MB |

The 90-pair `mapOf` now uses under 1 MB of scratch; the largest declaration
36 MB. The bake allocates 3.4 GB in all.

A census taken when `bodies` ends (not at exit, where the bake has
already dropped its heap) showed what was left: 1.1 GB of sema allocations
live, 600 MB of it call resolution's own working lists in the arena.

- Scratch is open only while `resolveAll` runs (`openScratch` /
  `closeScratch`); elsewhere `scratch()` is the arena, so nothing allocated
  outside a resolution outlives its analysis.
- Candidate levels and the lists that build them (`bareCall`,
  `receiverLevels`, `extensionFunctions`, `topLevelTiers`,
  `visibleMembers`, `operatorLevels`, the callable-reference levels), the
  applicable lists, `check`'s per-candidate arguments, slots and
  conversions, implicit receivers, supertype walks (`supertypeWalk`,
  `commonSupertype`, `joinedClass`, `nestedClassifier`) and member
  lookups' frontiers live in scratch. A record copies the contexts it
  keeps (`callDetail`); a memoized lookup copies a class's substitution
  only for a class that contributes a member (`keptSubst`).

| | peak RSS | `bodies` | RSS added by `bodies` |
|---|---:|---:|---:|
| cold compose_material3 | 1462 MB | 1.77 s | 502 MB |
| bake compose_material3 | 1348 MB | 1.78 s | 291 MB |
| cold hello | 178 MB | 0.24 s | 65 MB |

The tables' growth was the rest of the churn (refs 214 MB allocated for
71 MB kept, expression types 75 for 25), and in a run's arena every buffer
a table outgrew stayed:

- A run's build memory is a `runtime.LargeArena`: an allocation of 64 KB or
  more is a mapping of its own, unmapped when freed, so a table keeps only
  its last buffer. It exposed a stdlib path the file list kept after its
  sources were freed (`addBaseSource` now keeps the source map's copy);
  `KLIO_ARENA_GUARD=1` faults on any such read.
- `resolveAll` reserves the record and expression-type logs from the node
  count of the files it resolves (about 0.58 and 0.67 per node across
  programs), so they never regrow.
- Once `output.build` has indexed them, the pipeline frees the logs
  (`output.releaseLogs`); lowering reads the index.
- A muted analysis no longer formats the detail of a site it drops.

| | peak RSS | `bodies` | RSS added by `bodies` |
|---|---:|---:|---:|
| cold compose_material3 | 1061 MB | 1.59 s | 234 MB |
| bake compose_material3 | 1240 MB | 1.59 s | 253 MB |
| cold hello | 126 MB | 0.22 s | 30 MB |

From the start: cold peak 5153 to 1061 MB, bake 2470 to 1240 MB, `bodies`
4.4 s to 1.6 s. What sema keeps when its bodies are resolved is 258 MB,
and the run's peak is now in bridging and lowering.

The working data's own high-water was 88 MB in one declaration:
Material3's `findTranslation`, whose resolution types the 75 locale tables
on demand, each in the same scratch window.

- A declaration typed on demand from another's body (`inferReturnType`,
  `inferPropertyType`) resolves in a scratch level of its own
  (`pushScratch` / `popScratch`), emptied when it returns.
- Scratch is emptied after each member of a top-level class too: a class
  only resolves from `resolveFile`, so no call is in flight between two
  members.
- A member's scopes (function, block, lambda) live in scratch. A class's
  scopes and its constructor's stay open across its members and are held
  by the arena; each scope carries the allocator its lists grow in
  (`Scope.a`). A class declared in a body keeps an arena copy of its scope
  chain (`keptScope`) for members resolved later. `Ctx.resetScratch`
  asserts that every scope still open is the arena's.
- Scratch is a bump allocator of its own (`scratch.Scratch`): not
  thread safe (an analysis resolves on one thread), and it keeps its first
  chunks mapped across resets, so a declaration does not fault fresh pages
  in. On std's arena the levels' resets cost 1.5% of `bodies`.

| | peak RSS | `bodies` | RSS added by `bodies` |
|---|---:|---:|---:|
| cold compose_material3 | 1014 MB | 1.63 s | 187 MB |
| bake compose_material3 | 1185 MB | 1.62 s | 198 MB |
| cold hello | 120 MB | 0.22 s | 24 MB |

The largest declaration's working data is now 4 MB.

## Next

- The type store, the symbols and the memo maps still regrow (about 130 MB
  allocated for 40 MB kept); their sizes do not follow the node count, and
  a run's arena returns what they outgrow.
- `output.build` copies the records into per-file arrays (50 MB) where it
  could index them in place; the log is freed right after, before
  lowering, where a run's peak is.
