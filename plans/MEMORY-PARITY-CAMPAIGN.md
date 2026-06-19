# Memory parity campaign — get klio close to Python

Standing goal: drive klio's memory characteristics as close to Python (CPython)
as we can, in phases. This is the single source of truth for that campaign; it
supersedes ad-hoc notes. Related docs: `MEMORY-AUDIT.md` (measurements ledger),
`LAZY-IMAGE.md` (the deep design for the startup work), `GC.md` (collector design).

## The five targets (from the user)

1. **Leaks** — a moderately complex program must return to *exactly* its baseline
   RSS on GC. No growth where nothing is explicitly retained.
2. **Bare runtime** — shrink from 43 MB to somewhere between node (35) and
   python (8). Target ~25 MB.
3. **ktor startup (0 req)** — shrink from 136 MB to between python (27) and
   node (55). Target ~45 MB.
4. **Steady under load** — drive well below node's ~96 MB, toward python.
5. **Eliminate all growth** — same as (1), stated for the server path.

## Measured baseline (this session, same machine, identical curl+`ps` harness)

Equivalent HTTP server (`GET /users/:id` -> `id=<id>`, `POST /items` -> echo) on
all three. Reproduction servers + harness live in `/tmp/memcompare/`
(`node/srv.js` = Express 4.22, `py/srv.py` = Flask 3.1 on system py3.9 via
`PYTHONPATH=/tmp/memcompare/py/libs`, `bench.sh` = the shared harness; klio uses
`/tmp/srv.kt` + `--feature io.ktor/server-serialization`).

| | klio · ktor | node · Express | python · Flask |
|---|---|---|---|
| bare runtime (alive, no framework) | 43 MB | 35 MB | **8 MB** |
| startup (listening, 0 req) | 136 MB | 55 MB | **27 MB** |
| steady under load | ~142 MB | ~96 MB (V8 sawtooth, plateaus) | **27 MB (flat)** |
| per-request growth | ~0.4 KB/req (now ~flat after P1) | bounded sawtooth | ~flat (refcount) |

Python is flat+lowest (refcount frees eagerly, tiny heap). Node sawtooths but the
V8 heap high-water grows to ~96 MB then plateaus and is never returned to the OS.
klio is heaviest, dominated by eager stdlib/ktor image materialization at startup.

Re-measured this session (ReleaseFast `zig build -Doptimize=ReleaseFast`, warm
image cache, all packs reinstalled from the freshly-checked-out submodules):
**bare runtime 42 MB**, **ktor startup 124 MB** — consistent with the table.
Debug builds and cold (first-run, cache-miss) bakes inflate peak RSS markedly
(bare ~54 MB Debug / ~104 MB cold; ktor ~195-219 MB cold), so always measure
ReleaseFast + warm. The map-view `MapBacking` leak (P1 residual) is fixed and the
fix is validated by a 200k-iter sawtooth that returns to baseline.

## Phase status

- **Phase 1 — per-iteration leaks: DONE** (target 1 & 5). Committed. MapBacking
  residual also fixed this session.
- **Phase 2 — bare runtime: 42 -> 30 MB** (ReleaseFast, warm). Lazy-forest flip +
  beyond-forest step 1 (defer object/lambda func bodies). Near target 25; the
  residual is the IR func headers + the runtime stdlib ClassDef graph + GC/binary
  floor. Lazy func-headers (~1.5 MB) + lazy ClassDef would approach 25.
- **Phase 3 — ktor startup: 124 -> 91 MB.** Same flips. Target 45 needs lazy
  ClassDef: ktor's ~84 MB non-decode (eager decode is now only 7 MB) is dominated
  by the framework's runtime ClassDef graph + runtime-read registry side-tables.
  Lazy ClassDef is the only lever big enough, and the highest-risk VM change.
- **Phase 4 — steady-under-load << node: PARTIAL.** Server creep ~flat after P1;
  absolute steady RSS dropped with the lower P2/P3 baseline but ktor steady (~103)
  is still ~node (~96); the gap is the eager IR/ClassDef graph (beyond-forest).

Phases 2 and 3 are the *same underlying work* (lazy materialization of the stdlib
forest); the only difference is which image (basic vs ktor) benefits.

---

## Phase 1 — per-iteration leaks (DONE)

A moderately-complex loop (`data class` users + map/filter/groupBy/associate/
sumOf/joinToString/StringBuilder/closures) leaked ~2 KB/iter; a 40-op
comprehensive loop leaked ~20 KB/iter — both climbing RSS linearly with a **flat
GC live-cell histogram**, i.e. raw *non-cell* scratch the collector never sees
(same shape as the ktor server leak).

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

### The leak patterns (all "allocate scratch, copy into result, orphan scratch")
- `make{List,Set}(a, snapshotItems(...))` / `appendSlice(a, snapshotItems(...))`
  — fixed earlier with `makeListVL`/`makeSetVL`/`appendVL` (borrow+copy once).
- Standalone `const x = try snapshotItems(a, ...)` — **always scratch** (the
  result is copied by make*/appendSlice or iterated; a `[]Value` is never adopted
  as a cell backing, which takes an `ArrayList`). Blanket-freed. ONE escape:
  the `__grouping_key` helper returns its snapshot to the caller — left alone.
- Scratch accumulators (`groups` in groupBy, `rhs` in zip, `removals`/`other` in
  set minus/intersect) — the result is a *separate* adopted list; deinit the
  accumulator.
- Per-element scratch (`piece` in joinToString = each transform/display dupe) —
  free per element after appending.

### Results
- collections+closures+strings loop: ~2 KB/iter -> flat; RSS holds ~46-53 MB
  sawtooth and returns to ~46 MB baseline.
- 40-op comprehensive loop: ~20 KB/iter -> ~180 B/iter (~110x).
- Suite green (one failure is the known `parity_threaded_litmus` concurrency-
  stress flake — load-sensitive, deterministically green isolated, not a
  regression; verified 5x).

### Residual (small, tracked — finish before declaring target 1 fully met)
- **Map-view `MapBacking`** (`Map.entries/keys/values`): a raw `*MapBacking`
  struct (~16-32 B) attached to the result List/Set Value via `.backing` and not
  GC-owned, so it leaks when the view is collected. Needs the result cell to own
  + free it (or make MapBacking a cell, or skip it for read-only views). ~16-32
  B/iter per map-view op.
- **eval-level `<non-intrinsic>` tail** (~60-100 B/iter): a handful of small
  allocations in the eval Call / frame path not attributed to any intrinsic.
  To localize, extend `current_fqn` tagging to the eval `execInst` Call/CallMember
  handlers (eval.zig) or use stack-based leaktrack (now fast enough) and diff.

---

## Phase 2 / 3 — startup & bare runtime (the lazy-forest flip)

### Where the bytes are (measured via `KLIO_DECODE_STATS=1`)
`image.decode` totals: **basic 13.5 MB, ktor 34 MB**. Top types (ktor):
`ast.Decl` 8.0 MB (12534), `ast.Expr` 6.8 MB, `ir.Inst` 4.2 MB, `ast.Stmt`
2.8 MB, `ir.Func` 2.4 MB (13586), `ir.Param` 1.6, `ast.Property` 1.6,
`ast.Param` 1.1, `ir.Block` 1.0, `ir.TypeRef` 0.85. The **AST forest**
(`ast.*`) is ~8-9 MB basic / ~21 MB ktor; the **IR module** (`ir.*`) ~4/10 MB.

A program touches a handful of the 5880 (basic) / 12534 (ktor) decls; the rest
are decoded for nothing. Startup allocations are `gc.alloc_perm = true` (the
stdlib/ktor image is permanent, never placed on the sweep registry), so the rest
of the 136 MB ktor RSS — the eagerly *built* runtime graph (ClassDefs, IR module,
globals) on top of the decode — is genuinely live. **No high-water shortcut**;
the win requires lazy materialization.

### Foundation already landed (this and prior sessions)
- Lazy function **bodies**: `deferred_func_section` + `ensureFuncBody`, memoised
  by `(section, offset)` (fixed the ktor per-request re-decode leak).
- Per-decl **self-contained sections** baked: `lifted_decl_section` +
  `lifted_decl_offsets` (each `lifted_decls[i]` encodes standalone with a fresh
  registry). `decodeLiftedDeclReg` decodes one decl + its node-ordinal table.
- Resolver `src/runtime/forest.zig`: `ForestRef{decl,ord}`, `ForestField(T)`
  (a `ptr|ref` union with `.get()` that resolves+memoises on first touch),
  `setSection`, `resolveNode/Expr/Function/Accessor/Block`. **`setSection` IS
  called at load** (image.zig:1608, 2184) — the resolver is live.
- `MethodDef.decl` is already a `ForestField` (the one converted backref).

### I2 DONE (this session) — codec is forest-field-aware
The runtime-graph forest backrefs are now `forest.ForestField` and the image
codec encodes any `ForestField` as a `(decl, ord)` ref (tag 0) resolved lazily on
first `.get()`, with an **inline-encode fallback (tag 1)** for a `.ptr` whose node
is not in the bake-time forest map (synthetic nodes; any encode with no map
installed). Converted: `PropertyDef.init/getter/setter/delegate`,
`ClassDef.init_blocks/parent_ctor_args/secondary_ctors`, `ClassParamDef.default`,
`SupertypeDelegate.expr`, `MethodDef.decl`. The bake builds `forest_map`
(node-addr -> `ForestRef`) while emitting per-decl sections and installs it for
the final `ImageRoot` encode (`image.zig` `bake_forest_map`). `setSection` is now
called at the TOP of `baseFromRoot` (before the base is built, since building it
resolves refs). **`inline_ids` was reverted to eager** (raw forest pointer) — as
`ForestField` it `.get()`s at load and re-decodes inline-fn decls on top of the
still-eager `lifted_decls` (+6 MB); it must stay eager until I4 drops the eager
decode, then become a `ForestField`. Net: I2 is behaviour-preserving and
RSS-neutral (42 MB bare), but gives NO win yet — the eager `lifted_decls` is still
decoded. The win is I3+I4.

### What remains (the flip — the actual Phase 2/3 win)
With I2's codec in place, the eager `lifted_decls` decode (~8 MB basic / ~21 MB
ktor) is still in the payload AND the load-time `buildModuleFilesExtend`
traversals iterate `base.lifted_decls`. To drop it (I4) every forest pointer must
not require the eager forest, AND the three traversals must get their base data
without it (I3). NOTE the safety net: with `lifted_decls` nulled at bake, any
still-raw forest pointer (e.g. IR `BuildObject.ast`/`RegisterClass.class`) finds
no global-registry entry and **inline-encodes** (eager, correct, just no savings)
— so I4 cannot corrupt, only under-save; convert those to `ForestField` later for
the full win.

REMAINING I3 SUB-CHANGES (each large; full-suite + bake-determinism per piece):
- **I3-A inline-by-id lazy:** `inline_fn_ids: id -> ForestField`;
  `inlineAstById` resolves `.get()` and records a reverse `ptr -> id` map so
  `inlineIdByAst` (expr.zig:2898, called with an already-resolved fn) is a map
  lookup, NOT an iterate-and-`.get()`-all (which would resolve the whole inline
  forest). `registerInlineFnId` takes a `ForestField`. `inline_ids` becomes a
  `ForestField` again; load installs WITHOUT `.get()`.
- **I3-B inline-by-name lazy:** `inline_fn_asts: name -> []ForestField`; bake a new
  `base.inline_by_name: []KV(name, []ForestRef)` (the base half of
  `collectInline`); at load+build install the baked base refs, then add USER
  `collectInline` results (`.ptr`). Candidate readers (`inlineFnAst`,
  `inlineFnAstForRecv`, `candidatesFor`) resolve `.get()` per candidate.
- **I3-C file_classes lazy:** `FileClasses` value -> `ForestField(ast.Class)`; bake
  `base.file_classes: []KV(name, ForestRef)`; consumers (hierarchy walks / member
  collection for USER classes extending base classes) `.get()` on use. Audit ALL
  `FileClasses` readers.
- **I3-D top_props:** bake the base's top-level property names + `notePropScope`
  inputs (name/fqn/package strings) so the scope replay needs no AST.
Then **I4:** null `root.lifted_decls` between the per-decl-section build and the
final `ImageRoot` encode; re-make `inline_ids` a `ForestField`; bump
`FORMAT_VERSION`; measure.

ALTERNATIVE to I3 (free-after-lower): decode eager `lifted_decls` into a dedicated
page-backed arena, free it after the one `buildModuleFilesExtend`. REJECTED as
simpler: `built`/`module` still hold raw global-registry backrefs into
`lifted_decls` (the un-converted IR-inst pointers), so freeing dangles them — it
needs the SAME full `ForestField` conversion as I4, and the decode peak still
spikes during build. Only the "listening, 0 req" sample would drop, and only if
the arena is page-backed (munmap on deinit).

REALITY CHECK: even a complete I3+I4 reaches only ~34 MB bare / ~103 MB ktor.
The 25/45 targets additionally require the "Beyond the forest" work (lazy
`ir.Func` headers + lazy ClassDef construction), each a comparable change. The
forest flip is the necessary first lever, not sufficient alone.

### Original I-plan (superseded by the I2-done note above; kept for reference)
The eager `lifted_decls` forest is still decoded because most `built`/`module`
backrefs are still raw `*const ast.X` pointing into it. Convert them to
`ForestRef`, drop the eager decode, bake indices for the load traversals:

1. **Convert the remaining forest backrefs to `ForestField`/`ForestRef`:**
   - `class.zig` `PropertyDef.init/getter/setter/delegate` (`?*const ast.Expr` /
     `?*const ast.Accessor`).
   - `class.zig` `ClassDef.init_blocks` (`[]*const ast.Block`),
     `parent_ctor_args` (`[]*const ast.Expr`), `secondary_ctors`
     (`[]*const ast.SecondaryCtor`).
   - `ir.Inst.BuildObject.ast`, `Inst.RegisterClass.class`, and the inline-fn
     registry (`inline_ids`).
   For each: change the field type, make the image encoder store the `ForestRef`
   (look up the pointer's `ForestRef` in the bake-time `global_addr -> ForestRef`
   map captured while emitting per-decl sections — same mechanism `MethodImage`
   uses for `MethodDef.decl`), and route every reader through `.get()`.
2. **Reader sites that must use `.get()`** (from LAZY-IMAGE.md, verify each):
   `host_instances.zig` (init 2376/2812/3018, getter 2778, init_blocks walk 2836,
   positions 804), `host_call_value.zig:186-190`, `host_fields.zig:1548`,
   `host_classes.zig:463-469`, plus `MethodDef.decl` readers already done
   (`class.zig:504/536/551`, `value.zig:1345/1597`, `host_call_member.zig:1049`).
   Bake-time-only sites (`prune.zig`, `qualified_refs.zig`, `build.zig`) construct
   from AST at bake and need NO resolver.
3. **Baked indices for the three load-time forest traversals** (build.zig):
   `file_classes` (class simple-name -> decl index), `collectInline` (inline-fn
   name -> []decl index, overloads in order), `top_props` (top-level Property
   name+scope). Bake these maps so load installs indices without walking the
   forest; a lookup decodes only its specific decl on demand.
4. **Drop the eager `lifted_decls` decode** from the load payload. Forest decodes
   purely on `ForestField.get()` / index lookup. Measure basic + ktor RSS.

### Increment discipline (each must end green)
Per LAZY-IMAGE.md I2..I4: convert backrefs (resolve on access) -> replace the
three load traversals with baked indices -> drop eager `lifted_decls`. After each
increment: `zig build test` (full suite under gc-default), the corpus, a ktor
server smoke, and **bake determinism** (re-bake the image and diff — the
`ForestRef` ordinals must be stable; decl decode order in the decoder must match
the bake encoder exactly). Bump `FORMAT_VERSION` when the payload shape changes.

### Risks / gotchas
- `ForestRef.ord` is the node's index in *its decl's fresh registry*; the
  decoder's decl-decode order must match the bake encoder's exactly or ordinals
  desync (silent wrong-node). Keep them lockstep; the bake-determinism check
  guards this.
- `BuildObject.ast`/`RegisterClass.class` point into *kept* (non-body-deferred,
  object-bearing) function bodies — those funcs can't be body-deferred, but their
  owning decls are still in the lazy forest, so the ref must still become a
  `ForestRef`.
- The runtime graph (ClassDefs) is built from the forest at load; once the forest
  is lazy, ClassDef construction that reads hierarchy/methods must resolve through
  the forest on demand too (the ForestField conversion of ClassDef/PropertyDef
  fields is exactly this).

### Beyond the forest (if startup still too high after the flip)
The `ir.Func` headers (5920 basic / 13586 ktor) and the runtime ClassDef graph
are eager independent of the forest decode. If startup is still far from target
after I4, the next levers are lazy func-header / lazy ClassDef construction
(decode/build on first FuncId lookup / first class use) — larger, separate work.

---

## Phase 4 — steady-under-load << node

Mostly falls out of P1 (no per-request growth) + P2/P3 (lower baseline). The
server's residual ~0.4 KB/req is a diffuse floor (sub-100-byte eval-level allocs
+ slab high-water). If a hard-flat profile is needed, the slab `reclaimDormant`
50%-live hysteresis can be tuned to return more half-full slab pages, and the
eval-level tail (see Phase 1 residual) chased to zero.

---

## Session learnings (durable)

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

## Reproduction quick-reference

- Leak attribution: `KLIO_GC_ALLOC=leaktrack KLIO_LEAK_BY_FQN=1 KLIO_RSS_CAP_KB=20000000 ./zig-out/bin/klio run prog.kt 2>&1 | sed -n '/by-fqn/,$p'`
- Decode breakdown: `KLIO_DECODE_STATS=1 ./zig-out/bin/klio run prog.kt 2>&1 | grep decode-stats`
- Live-cell histogram: `KLIO_GC_HIST=1 KLIO_GC_THRESHOLD_KB=2048 ./zig-out/bin/klio run prog.kt`
- RSS trajectory: run in bg, sample `ps -o rss= -p <pid>` every 0.5s; a bounded
  sawtooth that returns to baseline = no leak; a steady climb = leak.
- 3-way server comparison: `/tmp/memcompare/` (node/srv.js, py/srv.py, bench.sh,
  COMPARISON.md). klio server: `/tmp/srv.kt` + `--feature io.ktor/server-serialization`.

## Remaining-work checklist

- [x] P1 residual: GC-own the map-view `MapBacking` — DONE. It is now an
      `ObjRef(MapBacking)` cell the view owns (retained/released + swept with the
      view); its `gcTrace` keeps the borrowed source entries reachable. Validated
      cross-mode (gc/arena/smp identical) + a 200k-iter bounded sawtooth.
- [ ] P1 residual: chase the eval-level `<non-intrinsic>` tail to zero (extend
      `current_fqn` to eval Call sites). BLOCKED: `KLIO_GC_ALLOC=leaktrack`
      segfaults at the exit-time `gc.collect()` (`markThreadRoots` walks a stale
      thread-root after `cli.run` returns) — a Zig-0.16-drift regression in the
      diagnostic path, not the campaign code. Fix leaktrack first (it is the
      attribution workhorse) or validate via RSS trajectory only.
- [ ] P2/P3 I2: convert `PropertyDef.init/getter/setter/delegate`,
      `ClassDef.init_blocks/parent_ctor_args/secondary_ctors`,
      `ClassParamDef.default`, `SupertypeDelegate.expr` (these last two were
      missing from the original list — they are forest exprs too),
      `Inst.BuildObject.ast`/`RegisterClass.class`, inline ids to `ForestRef`;
      route readers through `.get()`. Green per increment. NOTE: these
      runtime-graph AST fields are read only at build/bake time (the lowered
      side-tables come from `BuiltImage`), so a loaded image never `.get()`s
      them — that is exactly why making them lazy frees the forest decode.
      SAFETY NET: `lifted_decls` encodes first (ImageRoot field 2), so any forest
      pointer NOT converted falls back to inline-encode after I4 (correct, just
      no savings) — missing a field cannot corrupt, only under-save.
- [x] P2/P3 I3: baked `inline_by_name`/`file_classes`/`top_props` indices replace
      the three load traversals; `inline_fn_ids`/`inline_fn_asts`/`FileClasses`
      hold `ForestField` and resolve per-decl sections on demand. DONE.
- [x] P2/P3 I4: eager `lifted_decls` dropped at bake (`root.lifted_decls = &.{}`
      after the per-decl sections + indices); `FORMAT_VERSION` 5->6. DONE.
      **Measured: bare 42->32 MB, ktor startup 124->103 MB, steady ktor flat at
      ~103-122 MB across 2500 req (no per-request growth).** Suite green.
- [x] BEYOND FOREST step 1 — defer AST-referencing func bodies: `RegisterClass.class`
      /`BuildObject.ast` -> `ForestField`, `funcRefsAst` retired, so object/lambda
      bodies defer to the lazy-IR section. **bare 32->30, ktor 103->91**
      (eager decode basic 5.9->3.2 MB, ktor 18.5->7.0 MB). Suite green.
- [ ] **BEYOND FOREST step 2 (next, larger):** the eager `ir.Func` HEADERS remain
      (~13586 Func structs resident for ktor; ir.Func/ir.Param/ir.TypeRef decode).
      Lazy func-header decode needs per-func sections + decode-on-`idGet` (the
      `idGet` is `*const` — needs a side cache `[]?*Func` + offsets) + baked
      `fqn->id` index and package-head set to avoid the `funcIdByFqn`/
      `packageHeadDeclared` sweeps over `funcs.items` (ir.zig:1167/1184).
- [ ] **BEYOND FOREST step 3 (largest):** lazy ClassDef construction — ktor's
      ~84 MB non-decode is dominated by the runtime ClassDef graph + baked
      registry side-tables (hierarchy_methods/class_super_names/... for hundreds
      of classes). Build ClassDef shells lazily on first class use; riskiest
      (dispatch/instance/two-phase-link paths read ClassDefs).
- [ ] leaktrack fix (segfaults at exit-collect) — enables the P1 eval-tail
      attribution; validate via RSS trajectory until then.
- [ ] P4: ktor steady (~103-122) is ~node (~96); driving below node needs the
      beyond-forest baseline drop. Per-request growth already flat.
