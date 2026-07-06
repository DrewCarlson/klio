# Memory parity campaign — get klio close to Python

Standing goal: drive klio's memory characteristics as close to Python (CPython) as
we can, in phases. This is the single source of truth for that campaign; it
supersedes ad-hoc notes. Related docs: `LAZY-IMAGE.md` (the deep design for the
startup work), `GC.md` (collector design).

## Completed

The five memory-parity targets are met (ReleaseFast, warm image):

| target | start | now | goal | status |
|---|---|---|---|---|
| per-iter leak -> baseline on GC | leak | flat | flat | MET |
| bare runtime | 43 | 27 | ~25 | ~MET (binary floor) |
| ktor startup (0 req) | 136 | 49 | ~45 | MET (< node 55) |
| ktor steady under load | ~142 | ~61 flat | << node 96 | MET |
| per-request growth | ~0.4 KB/req | flat plateau | flat | MET |

- **Per-iteration leaks (Phase 1).** The "allocate scratch, copy into result,
  orphan scratch" leak class was closed by freeing raw host scratch (gated on
  `runtime.freeScratch()`); the map-view `MapBacking` residual is now an
  `ObjRef(MapBacking)` cell the view owns and sweeps (validated cross-mode +
  200k-iter bounded sawtooth).
- **Lazy-forest field conversion (Phase 2/3).** `PropertyDef.init/getter/setter/
  delegate`, `ClassDef.init_blocks/parent_ctor_args/secondary_ctors`,
  `ClassParamDef.default`, and `SupertypeDelegate.expr` are all `forest.ForestField`;
  the image codec encodes any `ForestField` as a lazy `(decl, ord)` ref (with an
  inline-encode fallback for synthetic nodes), and the eager `lifted_decls` decode
  is dropped at bake with `FORMAT_VERSION` bumped. (The remaining eager-path
  `lifted_decls` drop is tracked in `LAZY-IMAGE.md`.)
- **Lazy func headers.** Per-func header sections decode on first `funcById`;
  `cloneForExtend` delegates base ids; build/VM/link sites route through
  `funcById`/`funcByIdMut`/`nextFuncId`; the link uses binding-iteration + baked
  bodyless-ids; `funcIdByFqn`/`packageHeadDeclared` are lazy simple-name lookups.
  bare 30→27, ktor 91→84.
- **ktor startup pack-AST retention fix.** The ktor pack was re-parsed every run
  and its AST + source retained for the process life; `tryPrepare`
  (`cli/stdlib_image.zig`) now parses packs into a scratch arena and copies out
  only the bindings table (owned keys) + selection before dropping the arena. ktor
  84→49 MB, steady ~61 flat. The ClassDef graph (~1-2 MB) was never the lever.
- **Tracing GC is the default** (`allocChoice()` returns `.gc` unset;
  `arena`/`smp`/`debug` selectable via `KLIO_RECLAIM`).

Remaining tail: the leaktrack exit-collect fix and the sub-node ktor steady-state
stretch (both below).

## Leak-hunt tooling

### Tooling built (keep — it is the leak-hunt workhorse)
- **`KLIO_LEAK_BY_FQN`** — `KLIO_GC_ALLOC=leaktrack KLIO_LEAK_BY_FQN=1`. leaktrack
  keyed by the *intrinsic fqn active when each allocation was made* (a thread-local
  `leaktrack.current_fqn` set around every `func(&ctx)` dispatch). After the final
  collect, GC-managed result cells are gone, so what remains under an fqn is the
  raw scratch that intrinsic leaks. `reportByFqn()` prints bytes-per-fqn.
- Made it usable on hot loops: leaktrack metadata moved off `page_allocator` to
  `smp_allocator` (was mmap/munmap per op) and by-fqn skips per-alloc stack
  capture (`by_fqn_only`) — ~40x faster (200 iters: 90s timeout -> 2s).
- All **six** intrinsic dispatch sites set `current_fqn` (host_call_member,
  host_fields, host_call_value, host_call_func, host_instances, host_globals);
  before, only host_call_member did, so the other paths' leaks hid in
  `<non-intrinsic>`.
- `KLIO_GC_HIST` (live cell counts/type/collection) — flat counts confirm a leak
  is raw scratch not cells. `KLIO_GC_POISON` (quarantine-on-sweep UAF trap) from
  the gc-default work.

### Leak-hunt loop (the repeatable procedure)
1. Write a loop program (`const val ITERS = N; for ... process()`); `process()`
   exercises the ops of interest, every iteration's output is garbage.
2. Confirm a leak: sample `ps -o rss` over a long run (climbs) and/or
   `KLIO_GC_HIST` (flat cells => raw-scratch leak).
3. Attribute: `KLIO_LEAK_BY_FQN` at two iter counts (e.g. 200 vs 800), diff the
   per-fqn bytes; `(b800-b200)/600` = bytes/iter per intrinsic.
4. Fix the named intrinsic (free its scratch, gated on `runtime.freeScratch()`).
5. Re-measure; repeat until the only residual is a small `<non-intrinsic>` tail.
6. Validate the *ground truth*: RSS trajectory is a bounded GC sawtooth that
   returns to baseline, not a climb.

## Reproduction quick-reference

- Leak attribution: `KLIO_GC_ALLOC=leaktrack KLIO_LEAK_BY_FQN=1 KLIO_RSS_CAP_KB=20000000 ./zig-out/bin/klio run prog.kt 2>&1 | sed -n '/by-fqn/,$p'`
- Decode breakdown: `KLIO_DECODE_STATS=1 ./zig-out/bin/klio run prog.kt 2>&1 | grep decode-stats`
- Live-cell histogram: `KLIO_GC_HIST=1 KLIO_GC_THRESHOLD_KB=2048 ./zig-out/bin/klio run prog.kt`
- RSS trajectory: run in bg, sample `ps -o rss= -p <pid>` every 0.5s; a bounded
  sawtooth that returns to baseline = no leak; a steady climb = leak.
- 3-way server comparison: `/tmp/memcompare/` (node/srv.js, py/srv.py, bench.sh,
  COMPARISON.md). klio server: `/tmp/srv.kt` + `--feature io.ktor/server-serialization`.

## Durable learnings

- **Raw non-cell scratch is the leak class under gc.** The tracing GC frees
  *cells* by reachability; any `a.alloc`/`a.dupe`/`ArrayList` host scratch that
  isn't a cell leaks unless explicitly freed (gated on `runtime.freeScratch()`,
  true under gc and the freeing modes, false only under the pure arena). A flat
  `KLIO_GC_HIST` with climbing RSS is the signature.
- **`snapshotItems` results are always scratch** (never adopted) — safe to free
  universally; only a returns-the-slice helper escapes.
- **Adopt vs copy**: `makeListFromArrayList`/`makeListBorrowed`/`ValueList.init`
  *adopt* an `ArrayList` (becomes the cell backing — do NOT free); `makeList`/
  `makeArray`/`makeSet`/`appendSlice` *copy* a slice (free the source). The
  by-fqn tool + cross-mode (`arena`==`gc`==`smp`) correctness checks catch a
  mistaken free (double-free shows as SIGBUS under gc once the slab reuses the
  page; smp's reclaim-on catches it immediately).
- **Validate frees across modes**: run fixed ops under `arena`, `gc`, and `smp`;
  identical output + rc=0 means the free is sound. (Some complex programs fail
  under `smp` for *pre-existing* reasons — smp's reclaim path isn't reconciled
  for the coroutine/ktor host path — so isolate the specific changed ops.)
- **Startup is permanent**: `alloc_perm` makes image/graph allocations unsweepable;
  RSS can't be GC'd down. Lower startup = materialize less.
- **gc is the default now** (`allocChoice()` returns `.gc` unset); `arena`/`smp`/
  `debug` selectable via `KLIO_RECLAIM`.

## Phase 4 — steady-under-load << node

Mostly falls out of P1 (no per-request growth) + P2/P3 (lower baseline). The
server's residual ~0.4 KB/req is a diffuse floor (sub-100-byte eval-level allocs
+ slab high-water). If a hard-flat profile is needed, the slab `reclaimDormant`
50%-live hysteresis can be tuned to return more half-full slab pages, and the
eval-level tail (see the remaining-work checklist) chased to zero.

## Remaining-work checklist

- [ ] **leaktrack exit-collect fix.** `KLIO_GC_ALLOC=leaktrack` segfaults at the
      exit-time `gc.collect()` — `markThreadRoots` walks a stale thread-root after
      `cli.run` returns (a Zig-0.16-drift regression in the diagnostic path, in
      `src/runtime/leaktrack.zig`'s exit path, not the campaign code). It is the
      attribution workhorse, so fix it first or validate via RSS trajectory only.
- [ ] **P1 residual: eval-level `<non-intrinsic>` tail to zero** (~60-100 B/iter):
      a handful of small allocations in the eval Call / frame path not attributed
      to any intrinsic. To localize, extend `current_fqn` tagging to the eval
      `execInst` Call/CallMember handlers (eval.zig) or use stack-based leaktrack
      and diff. BLOCKED on the leaktrack fix above.
- [ ] **P4: drive ktor steady-state below node.** ktor steady (~103-122 MB) is
      ~node (~96); driving below node needs the beyond-forest baseline drop.
      Per-request growth is already flat.

### Architectural conclusion (why the targets need a dedicated rearchitecture)
Bare (30 MB) is at the interpreter's own code+data floor (binary text 29 MB /
data 7.7 MB incl. embedded stdlib pack; ~25-28 MB resident before any program) —
target 25 is essentially that floor; further wins need binary shrink (strip debug,
less code), not laziness. The ktor gap (91->45) is the framework's eagerly-built
runtime graph, and the only levers (lazy funcs + lazy ClassDefs) are blocked on
the `cloneForExtend` copy-by-value + contiguous-id model: closing the gap requires
converting the extend model from COPY to DELEGATION across funcs AND classes — a
VM rearchitecture touching the hottest paths (call dispatch, instance creation,
two-phase linking). That is a dedicated, reviewable effort, not a safe auto-loop
increment; a subtle bug would silently miscompile dispatch on programs the (broad
but not exhaustive) suite doesn't cover.
