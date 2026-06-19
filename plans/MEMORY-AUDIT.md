# Memory audit — startup, ktor, and lifetime (measured)

All on the current binary, macOS, RSS = `maximum resident set size` (exiting
programs) or `ps -o rss` (the long-running server). ktor runs use the five
installed packs (`--feature io.ktor/...`).

## Startup (initial) RSS

| Program | arena | gc | free |
|---|---|---|---|
| `println("hi")` | 47.5 | **42.0** | 44.4 |
| collections (map/filter/groupBy) | 49.4 | **42.5** | 46.8 |
| parse-error (no stdlib decode) | — | **5.5** | — |
| ktor **server** (routing + ContentNegotiation + `@Serializable`) | — | **234.8** | 211.5 |
| ktor **client** (`HttpClient` + 1 GET, exits) | 601.9 | **129.8** | — |

Basic/stdlib are Node-parity (~42 MB gc, floor 5.5 MB). ktor is far heavier: the
ktor image is 14.4–14.7 MB on disk (vs 6.8 MB basic) and `image.decode` is
**+50.8 MB / 135 K allocs** (basic ~20.8 MB). The client allocates ~550 MB of
transient per-request data (arena 602 MB for one GET; gc reclaims to 130 MB).

The ktor-startup number is what the lazy/position-independent image
(`plans/LAZY-IMAGE.md`) targets — it would help ktor most, since a program uses
a small fraction of that 50 MB forest.

## Lifetime RSS — ktor server under sustained requests (FIXED)

The per-request leak was the lazy func-body decode. `ensureFuncBody` decodes a
deferred function's blocks into the process-lifetime `deferred_func_arena`,
gated only by the per-`Func` `deferred_offset` flag; that flag is reset whenever
the func table is rebuilt (a fresh Vm per `runBlocking` body), so every request
re-decoded the same bodies and the blocks piled up unfreed. The tracing GC never
sees them (raw arena memory, not cells) — which is exactly why the live-cell
histogram stayed flat while RSS climbed, and why more-frequent collection looked
like more retention (it was re-decoding, not re-rooting). `decodeFuncBlocks` now
memoises by `(section, offset)`: each body decodes once for the whole process.

Server RSS, gc, 512 KB threshold, mixed GET/POST:

| | before memo | after memo |
|---|---|---|
| start | 159 MB | 136 MB |
| 4,000 req | 4,170 MB | 153 MB |
| rate | ~1 MB/req | warmup only, then ~flat |

`leaktrack` then localized the remaining per-request growth to two classes of
raw host-temporary that the process arena used to reclaim for free:

- **`snapshotItems` dupes** — `make{List,Set}(a, try snapshotItems(a, vl), m)`
  and `dst.appendSlice(a, try snapshotItems(a, vl))` allocate a dupe, copy it
  again, then orphan it. Every `toList`/`toSet`/`plus`/`minus`/`union`/`distinct`
  leaked one. Fixed by `makeListVL`/`makeSetVL`/`appendVL`, which copy once under
  the `ValueList` borrow with no dangling intermediate (31 call sites).

A fqn-attributed leaktrack pass (`KLIO_LEAK_BY_FQN`, `reportByFqn`) then named
the per-intrinsic scratch leaks directly — each takes a snapshot/dupe scratch
array, copies or reads it, and orphans the spine. Fixed `MutableList.addAll`,
`List.last`, `ByteArray.copyInto`, `List.sumOf` (free the scratch on exit).

Server RSS, gc, mixed load, steady slope after warmup:

| | decode memo only | + collections/intrinsic fixes |
|---|---|---|
| per-request creep | ~7.5 KB/req | ~0.4 KB/req |

The residual ~0.4 KB/request has no single dominant source: the intrinsics,
coroutine suspend/resume, member dispatch, closure invoke, serve loop and string
concat are all audited clean or fixed. What remains is a diffuse floor (many
sub-100-byte allocations plus slab high-water), three orders of magnitude under
the original decode leak.

## gc is the default

With both blockers closed and the per-request leak down ~2700×, the tracing GC
is now the **unset default** (`allocChoice()` returns `.gc`). The full suite
passes under gc-default. `KLIO_RECLAIM=arena|smp|debug` stay selectable. gc is
the only mode that bounds memory for a long-running process, so it is the right
universal default; a basic program is ~42 MB (vs 47.5 MB arena).

## gc-as-default blocker (FIXED: coroutine GC-root completeness)

The deterministic use-after-free on heavy coroutine I/O (a 1 MB+ channel write
crashing under gc with `BinOp.Less on null` / `compareTo on KlioBlockingCoroutine`)
was two coroutine GC-root gaps, both surfacing only once a closure body outlives
a collection that fires mid-execution:

1. A running/parked closure body holds only a *copy* of its capture values, not
   the `IrClosure` value, so nothing marked its side-table slot — `reclaimDead`
   recycled the id (aliasing a live closure) and swept its capture store. Fixed
   by threading the closure id onto `Frame`/`FrameSnapshot` and re-rooting the
   slot via `markClosureHook` while the body runs or sleeps.
2. `drainLaunched` moved queued launch blocks out of the GC-rooted
   `self.launched` into a local slice; while an earlier block ran and suspended,
   the not-yet-started blocks were unrooted. Fixed by keepaliving the drained
   batch across the pump loop.

Repro now passes across thresholds 256 KB–8 MB and both slab/smp backends; the
1 MB writer-parks program is a regression itest under `reclaim=gc`. Diagnostic
`KLIO_GC_POISON` (quarantine-on-sweep, names the swept-while-live cell type)
added for future root-completeness work.

### Path to making gc the default
Both blockers (the UAF and the server leak) are now closed. Remaining before the
flip: re-run the full suite + ktor itests under gc-as-default and fix any further
UAF it surfaces, then flip `allocChoice()`'s unset default to `.gc`.

## Phase campaign vs Python (baseline: klio 43/136 MB, node 35/55, python 8/27)

### Phase 1 — per-iteration leaks (DONE)
A `KLIO_LEAK_BY_FQN` attributor (leaktrack keyed by the intrinsic fqn active at
each alloc; ~40x faster after moving its metadata off page_allocator and skipping
stack capture; all six intrinsic dispatch sites tagged) drove the per-iteration
leak of two moderately-complex loops to ~zero:
- collections+closures+strings: ~2 KB/iter -> flat (returns to ~46 MB baseline).
- 40-op comprehensive: ~20 KB/iter -> ~180 B/iter.
Fixes: sorted/groupBy/joinToString/zip/windowed/reversed/chunked/min-maxOrNull/
in-place sorts/set intersect+subtract, plus a blanket `snapshotItems`-scratch
free (results are always copied, never adopted — one grouping-key escape aside)
and the zip/set scratch accumulators. Residual ~180 B/iter = the map-view
`MapBacking` raw struct (not GC-owned) + a tiny eval-level tail.

### Phase 2/3 — startup & bare-runtime (lazy-forest flip)
Decode breakdown (KLIO_DECODE_STATS): basic 13.5 MB, ktor 34 MB. The AST forest
(`ast.Decl`+`Expr`+`Stmt`+`Property`+`Param`+`Ident`) is ~8-9 MB basic / ~21 MB
ktor — 5880 decls / 12534 decls eagerly materialized though a program touches a
handful. Startup allocations are `alloc_perm` (never swept), so the rest of the
136 MB ktor RSS is the eagerly-built runtime graph (ClassDefs/IR/globals), all
genuinely live — no high-water shortcut.

The fix is the lazy-forest flip (`plans/LAZY-IMAGE.md`). Foundation landed: the
per-decl self-contained sections + offset table are baked, the `forest.zig`
resolver (`ForestRef{decl,ord}`, `ForestField`, `resolveNode/Expr/Function/...`)
exists, `setSection` is called at load, and `MethodDef.decl` is a `ForestField`.
Remaining (I2/I4): convert the other forest backrefs to `ForestRef` —
`PropertyDef.init/getter/setter/delegate`, `ClassDef.init_blocks/
parent_ctor_args/secondary_ctors`, `Inst.BuildObject.ast`, inline ids — then drop
the eager `lifted_decls` decode and replace the three load-time forest traversals
(file_classes/collectInline/top_props) with baked indices. Estimated win: the
~8-21 MB forest decode plus the share of the runtime graph that a given program
never reaches.
