# Cold start

A cold `klio run` is one whose stdlib image is not in the cache: after the
interpreter is rebuilt (the image key carries the executable's stamp), after
the stdlib sources change, or for a pack combination the cache has not seen.
Everything the image holds has to be produced from source before the user's
`main` runs. This page records where that time goes, what has been done about
it, and the plan for the rest. Warm runs are covered by the stdlib image cache
section of [performance](../architecture/performance.md).

Measure with `KLIO_TRACE_STDLIB_IMAGE=1` (phase totals), `KLIO_TRACE_LOWER=1`
(lowering steps and cache counters) and `KLIO_TRACE_RUN=1` (the run itself),
against a fresh data home, and with the image the build ships beside the
binary ignored, or the run is a warm one:

```sh
rm -rf /tmp/klio-cold && KLIO_HOME=/tmp/klio-cold KLIO_STDLIB_IMAGE_SHIPPED=0 \
  KLIO_TRACE_STDLIB_IMAGE=1 KLIO_TRACE_LOWER=1 ./zig-out/bin/klio run hello.kt
```

A profile of the whole bake is one `sample` of the process at 1ms; the
`[stdlib-image]` lines name the phase each sample belongs to.

Note that the default `zig build` produces a Debug binary. Every Debug number
below is two to three times what a ReleaseSafe or ReleaseFast build measures;
the ratio is roughly constant across phases, so the shape of the profile is
what matters.

## The pipeline

A bake runs these phases in order, for the whole stdlib (232 files, 3.4MB,
91k lines, 4134 top-level function bodies) plus any selected packs:

1. **parse**: read the sources, lex and parse each file.
2. **stage**: the type checker runs over every body, only to record which
   declaration each call resolves to. Lowering pins its own resolution to that
   pick wherever the two differ, so the picks are semantic and must be
   complete before any body lowers.
3. **build**: lowering. Headers are registered first (function headers, class
   shells, member headers, aliases, imports), then class bodies, then the
   top-level function bodies, then thunks, dispatch tables and the finishing
   passes.
4. **bake**: encode the base into the image bytes, in this process, with the
   four per-item sections (inline bodies, function blocks, function headers,
   lifted declarations) encoded on threads; a thread writes the file.
5. **drop the build**: everything the parse, stage, lowering and bake
   allocated lives on one heap of its own, unmapped in a few milliseconds
   once the bytes exist.
6. The base is loaded back from those bytes exactly as the next run will
   load them from the file; the user program is then parsed, checked and
   lowered against it as on a warm run, and executed.

## Where the time went

The starting point of this work, Debug build, hello world:

| phase | ms | of which |
|---|---|---|
| parse | 556 | pack bytes rebuilt from the checkout and decoded again 100; lex 210; parse 205 |
| stage | 2502 | smart-cast and definite-assignment dataflow 40%; inference refresh 15%; allocation churn |
| build | 3760 | function bodies 2773; headers 352; class bodies 309; finish 125 |
| serialize | 346 | |
| total prepare | 7390 | |

The same numbers after the changes below, Debug and ReleaseFast, with the
ReleaseFast figures from the session's start alongside:

| phase | Debug now | ReleaseFast before | ReleaseFast now |
|---|---|---|---|
| parse | 136 | 85 | 10 |
| stage | 377 | 240 | 30 |
| build | 941 | 290 | 65 |
| serialize | 337 | 34 | 38 (in the child) |
| total prepare | ~1900 | ~690 | ~127 |

A warm run is unchanged at about 120 ms Debug and 24 ms ReleaseFast.

Every change was verified by baking the image before and after and comparing
the bytes: the lowered program is identical, only the time changed. The
examples corpus and the unit suites are the gate for the paths the image
identity cannot see (user code lowered against the base).

### What was wrong, and the fix

The pattern throughout was work that scaled with the size of the module being
redone per query, per call or per declaration.

- **The checker re-solved a function's dataflow for every name it read.**
  Each path expression asked for the smart-cast state at its position, and the
  answer was computed by solving the whole function's CFG to a fixpoint,
  copying one block's entry out and discarding the rest; the definite
  assignment query did the same with its own solve. A function is now solved
  once and every query in it reads the memoised states (`narrowing.SolveMemo`).
  A CFG containing an `AssumeRefEq` node reads the declared-type map, so it
  re-solves only when that map has moved.
- **A solved inference session rewrote every type ever recorded.** After each
  generic call the checker walked the module-wide `types` map substituting the
  session's variables. Only types recorded since the session began can carry
  them; a journal of those spans is what gets rewritten.
- **`declarationHostSymbol` scanned the 1615-entry host table**, splitting
  each fqn, for every stdlib header. It reads a name index built on first use.
- **`anyFactoryApplicable` walked every registered function comparing names**
  on every candidate probe. The name index already held the answer.
- **Builtin-head predicates compared a name against each builtin in turn**;
  they use static string maps.
- **The supertype-name walk (`evidenceSubtypeCb`) re-walked the chains** for
  every candidate of every call. The set of names a walk from a class reaches
  is kept on the registry and dropped whenever the chains change.
- **An extension candidate's receiver verdict was recomputed at every call**
  with the same receiver. It reads only the receiver, the declaration and the
  caller's bounds, so it is memoised on exactly those and invalidated when the
  class, function or alias tables it read grow. Hit rate on the stdlib bake:
  77%.
- **Method slot linking read the declaration table once per class.** It reads
  it once.
- **The lexer decoded every byte as UTF-8**; ASCII runs are scanned
  byte-wise.
- **The parse and the body check were serial.** Both are per-file and
  per-declaration pure once the declarations are seeded, so both run on a pool
  (`KLIO_PARSE_JOBS`, `KLIO_TYPECK_THREADS`). The checker's one
  cross-declaration flow, a top-level property's inferred type reaching later
  declarations, is reproduced by checking properties first in order and
  replaying their bindings into each worker as it passes them.

Two things that looked like wins and were not, kept here so they are not
retried: an identity-keyed cache in front of the class-name lookup hit 95.7%
of the time and was slower, because the string lookup it replaced was already
a cheap hit; and a whole-call cache in front of extension resolution hit only
15%, because the probe that decides a call's emit form and the resolution that
emits it share the name, receiver and arguments but not the context. The
per-candidate receiver verdict is the grain that repeats.

## Memory

The trace lines above carry the resident set (`rss`) at each step, so the
same run that shows where the time goes shows where the memory goes. For the
finer view, `vmmap --summary <pid>` splits the resident set by region type
(the slab and the page allocator are `VM_ALLOCATE`, the C heap is `MALLOC_*`,
the binary's own pages are `__TEXT`/`__LINKEDIT`); `KLIO_SLAB_STAT=1` prints
the slab's per-size-class occupancy at the pre-execution trim; and
`KLIO_SLAB_TRACE=1 KLIO_SLAB_TRACE_ALL=1` with a SIGTERM during `main`
attributes every mapping the process still holds to the allocation that made
it. A `Thread.sleep` or a long loop in the program gives the time to attach.

### What a cold run holds when `main` starts

`KLIO_SLAB_CENSUS=1` charges every slab allocation from process start to
its calling site and credits it back on free, so the report at exit is the
live set by owner (`scripts/slab_census.py` groups it by phase, file and
site; `=churn` orders it by bytes turned over instead). It also prints the
byte size of every shape the pipeline allocates in volume. What a cold
hello held live when `main` started, ReleaseFast, before this round:

| Owner | Live at `main` | Allocated over the run |
|-------|---------------:|-----------------------:|
| The stdlib parse trees, bodies of non-inline functions blanked | 37 MB | 47 MB |
| The lowered base: blocks, instructions, headers, module tables | 36 MB | 64 MB |
| The stdlib sources, read from the checkout | 7.5 MB | 7.5 MB |
| The stage's call picks | 5 MB | 60 MB (checker arenas, freed) |
| Total | 92 MB in 386k allocations | 700 MB |

Of that, the program needed almost none of it: the runtime reads no AST
except through the pinned bodies (an object expression, a local class, a
lambda re-lowered at runtime), and the lowered base's bodies are what the
image defers and decodes on demand. The resident set at `main` was 160 MB
against 38 MB for the same program warm.

What changed:

- **The build lives on its own heap and dies whole.** `runtime.slab` is now
  instantiable: `buildHeap()` hands the cold path a second heap with its own
  size classes, large-block lists and reserve, every mapping it makes on a
  region list. The parse, the stage, the base build and the bake's own
  turnover allocate from it. Once the image bytes exist the run loads the
  base back from them, as a warm run loads the file, and `releaseAll`
  unmaps the heap: 205 MB in 2.8 ms, no per-cell frees, no tree walks. The
  strip's freeing walk, its pinned-address collection and the thread that
  released the detached bodies are gone with it; the strip only blanks. A
  free into a released heap is a no-op, so a container the build left
  behind may still `deinit`; an allocation from one is a bug. The
  collector's lists are purged of any cell inside the heap before the
  unmap: a build mints permanent cells, and a store into one had put it on
  the remembered set, which the next collection traced through freed
  memory (six examples crashed in `traceRemembered` before the purge).
- **The cold run is the warm run plus a bake.** There is one execution
  path now: `finishFromLoaded` over the bytes, whether they came from the
  cache, the build's shipped copy, or the bake a moment ago. The lowering
  fingerprints of the base build are identical before and after
  (`KLIO_LOWER_FINGERPRINT=1`), and the per-run cold corpus (a fresh data
  home per program) matches the warm corpus program for program.
- **The bake encodes its sections on threads.** Each inline body, function
  body, function header and lifted declaration is a self-contained encode
  after a registry reset, so contiguous runs of items go to per-thread
  encoders whose buffers concatenate in order; the bytes are what the
  serial encode wrote. The root encode writes straight into a buffer sized
  from the sections and the sources, on the heap that keeps it. 32 ms to
  16; `KLIO_TRACE_BAKE=1` times each phase.
- **Small strings on the page allocator cost a page each.** Four
  registries duped tiny strings with `std.heap.page_allocator`, which maps
  16 KB per call on macOS: the environment cache (a page per variable ever
  asked about, 3000 maps a cold run), the known-package set, the intrinsic
  intern table, the host-symbol name index (a page per name, 8 MB), the
  inline candidate lists (a page per name), and the lowering's per-thread
  type memo on `smp_allocator`, whose free lists never return a page
  (19 MB across the workers). They are on the process heap now. Maps per
  cold run went from 3800 to 640, and the warm run's footprint at `main`
  from 31 MB to 25.

ReleaseFast at `main` now: 47 MB cold (40 MB physical footprint against 25
warm), from 160. The peak over the run is unchanged at about 250 MB: it is
the build itself, and the levers on it are the shapes below.

### The shapes

The peak was the build's own size, and the census said the shapes were
fat. Each was boxed or split, and the base build's lowering fingerprints
(`KLIO_LOWER_FINGERPRINT=1`, with the hash following pointers to AST nodes)
are identical before and after every step; the per-run cold corpus and the
installed-home corpus match the baseline program for program.

| Shape | Before | After | What changed |
|-------|-------:|------:|--------------|
| `Expr` | 288 | 80 | nine rare variants (`AnonFun`, `When`, `For`, `Super`, `IsCheck`, `As`, `ObjectExpr`, `Try`, `Lambda`) behind pointers; a call is the largest left |
| `Stmt` | 680 | 88 | the declaration, assignment and destructuring payloads boxed |
| `Decl` | 672 | 280 | follows `Function` |
| `Function` | 664 | 248 | receiver and return type references boxed |
| `Property` | 640 | 144 | receiver type, type and initializer boxed |
| `Accessor` | 456 | 144 | return type boxed |
| `WhenBranch` | 320 | 112 | follows `Expr` |
| `Token` | 40 | 20 | template text and interpolation names index `LexResult.strings` |

`KLIO_SLAB_CENSUS=shapes` prints the variant and field sizes behind the
largest unions and structs, which is how each step was chosen. What the
boxing bought, ReleaseFast cold hello on an idle machine:

| | Before | After |
|---|---:|---:|
| Resident set after the parse | 85 MB | 55 MB |
| Resident set after the build | 190 MB | 158 MB |
| Peak resident set | 251 MB | 217 MB |
| Lex and parse, ten threads | 9 to 15 ms | 5 ms |
| Prepare | 130 to 137 ms | 120 to 122 ms |

The boxing has one hazard: a pass that copied an expression by value and
rewrote a variant's field now writes through to the shared node. The
fingerprint over the base build is the check for it (fourteen functions
differed once, and it was the hash walker skipping the boxed nodes, not the
lowering); a pointer cast that took the address of an inline declaration
was the one real fault, caught by the release build's own bake.

The checker's body workers also cloned the top-level frame, twenty
thousand bindings each, before starting; they read the main checker's seed
through a shared pointer now.

### The IR round

The lowered side went the same way, checked the same way: base-build
fingerprints identical to the pre-round commit at every step (the walker
hashes a block's handlers as if inline, a call's fields in one fixed order
whichever side of its box they sit on, and union tags by name so a
reordered union changes no hash), both corpus modes at the baseline, and
the interpreter's own time flat on eight CPU-bound examples (medians within
noise of the pre-round binary, from 80 ms to 2.2 s each).

| Shape | Before | After | What changed |
|-------|-------:|------:|--------------|
| `ir.Block` | 152 | 64 | the try machinery (catch handlers, the finally and its sentinels, the labeled-return region, the frames to pop) behind a `BlockHandlers` pointer the few blocks that carry any allocate |
| `ir.Inst` | 128 | 64 | `CallSpread`, `CallMemberOrGlobal`, `AstLambda` and `BuildObject` boxed; a member call's lowering facts (named arguments, static and declared receivers, a resolved target, the dispatch receiver) in an `extra` box most calls never allocate, the hot fields and the site memo inline; the resolved virtual call keeps its argument maps the same way |
| `ir.Func` | 304 | 232 | the adapted-reference key, a receiver lambda's receiver head, the capture order, the implicit label and the annotation names in a `FuncExtra` box |
| `ast.TypeRef` | 104 | 80 | annotations and the qualified path in a `TypeRefExtra` box; `Param` 176 to 152, `TypeArg` 120 to 96, `FunctionTypeRef` 264 to 216 with it |
| `ast.Class` | 272 | 184 | where bounds, init blocks and their positions, named supertype arguments, secondary constructors and enum entries in a `ClassExtra` box; `Decl`, the union that held the class as its widest variant, 280 to 256 with it |

What it bought, ReleaseFast cold hello, idle machine, the shapes round as
the baseline: resident set after the build 156 MB to 141, at the bake 171
to 157, the image 10.0 MB to 9.7 (a box that is absent encodes as one
byte); the cold wall (141 to 148 ms), the warm run (18 ms) and the eight
run-time examples unchanged within noise. The peak stays at about 210 MB,
which the checker's arenas and the module tables set, not the IR.

The bytecode stream cache keyed on the address of a function's blocks
alone; with blocks a third the size a function freed and another built at
the same address collided in the evaluator's own tests, so the key carries
a shape signature of the blocks. `Func.freeBuilt` frees everything a
builder allocated for a function, which the unit tests share instead of
six private copies.

`ast.Class` went last. Of its eight rarely-filled slices, six are rare
in fact: where bounds, init blocks and their positions, named supertype
arguments, secondary constructors and enum entries, which one stdlib class
in eight carries. The per-supertype argument and delegate slices are
parallel to `supertypes`, so any class with a supertype fills them, and
they stay inline. The six sit in a `ClassExtra` box, null when every one
is empty; readers go through `x()`, the parser and the object lifter build
the box with `classExtra`, and the one writer takes it through `xMut()`.
A class is 184 bytes rather than 272, and because the class was the
widest variant of the declaration union, every `Decl` is 256 rather than
280, which reaches the forty thousand declarations the stdlib parses, not
only the three thousand classes. The fingerprint hashes a class's fields
in their former order whichever side of the box they sit, so the base
build read identical (6506 functions), both corpus modes held the
baseline, and the cold wall, the warm run and the eight run-time examples
did not move. The resident set at the megabyte moves by less than one.

### The serial stretch

With the parallel pools at about 45 ms of the 119 ms prepare, the serial
work between them was the larger half, and it came in two dozen pieces
none of which a millisecond trace could rank. Three instruments settled
it. The lowering trace prints microseconds. The PC sampler runs on macOS
(the timer through libc, the program counter and the link register read
from the arm64 signal context, since the std helper returned zero), tags
every sample with the phase it fell in, and dumps raw addresses that
`scripts/prof_symbolize.py` folds by function, by phase, and by caller
for a leaf. Measure from outside the checkout: a run inside it reads the
231 stdlib sources from disk (4 ms) where a user's binary has them
embedded.

What the profile said, in samples of 100 µs across the whole run:

| Where | Samples | What it was |
|-------|--------:|-------------|
| `memcpy` | 630 | a block's instruction slice grew by one element per push, a fresh allocation and a full copy each; a thread's fork of the module for the body pool; the root encoder's buffer growing once past its estimate |
| `__mmap`, `__munmap` | 240 | the checker's page-allocator arenas mapping a chunk per call and unmapping at the end of the stage; the build heap's regions at the drop; the parse's token arrays above the slab's parking limit |
| `swtch_pri` | 120 | parse workers yielding in a loop while the last big files were cut |
| hash map growth | 240 | tables doubling through passes whose sizes were known |

What changed, and what it bought on a cold hello from outside the
checkout (prepare 118 ms, wall 135 ms, peak 211 MB before):

- The builder keeps a list per block and sizes the slice once at finish.
  The copying moved rather than vanished: the finish copy lands on fresh
  pages, and a variant that left the lists in place saved no wall and
  cost 24 MB of build heap, so the exact slices stay.
- The build heap's regions unmap on a detached thread once the collector
  has forgotten them, and the checker's worker arenas release through the
  same janitor: the two together were four milliseconds on the path. The
  same arenas moved onto the process slab cost 150 MB of resident set and
  moved back.
- The root encoder reserves for the tables and its slice registry once.
- A parse worker with nothing to take parks on an event gate.
- The stage runs as a job the build starts once the syntax transforms
  are done and joins before the first body lowers; nothing between reads
  its picks and nothing writes the syntax it reads. The pick tables are
  thread-local and a module adopts them from its own thread when it is
  made, so the stage hands its tables over and the build adopts them
  after the join: with that, lowering fingerprints are identical to the
  build before the move on every function. (Without it 63 functions
  lost their eager routes, which the stdlib commontest sweep and the
  corpus could not tell apart.)
- A name with no inline candidate is remembered as such; the header pass
  and the resolver size their tables by declaration count.

| | Before | After |
|---|---:|---:|
| Prepare | 118 ms | 99 ms |
| Cold wall, median | 135 ms | 125 ms |
| Warm wall | 17 ms | 16 ms |
| Peak resident set | 211 MB | 223 MB |

The peak rises because the stage's arenas and the build's tables now
coexist. The eight run-time examples are unchanged within noise.

The pools scale at about 65% from five threads to ten, so their wall is
compute plus contention, not the page-fault cliff the off-CPU share
suggested; the sampler simply undercounts a phase on ten threads.

### Lazy bodies

Off by default, behind `klio run --lazy-bodies`, `KLIO_LAZY_BODIES=1` or
`lazy_bodies = true` under `[application]` in the working directory's
klio.toml. A cold run then stops the base build short of its body pools:
every function's reserved header stands in its slot, marked deferred so
dispatch treats it as a body (the header carries the suspension, kind
and receiver a caller binds against), and the program runs from inside
the build while everything the lowering installed on the thread is still
in place. A body lowers on its first execution, where the VM already
materialises image-deferred bodies (`ensureFuncBody`). It lowers in one
shard forked from the base, whose tables are complete where the run
module's extend clone is not; the functions and constants it adds are
renumbered into the module that reached it, as the pool's merge
renumbers a worker's, with one map per module since an anonymous
object's side module interns its own constants and diverges. A body
reached on a dispatcher thread lowers under the plan's own copy of the
inline tables. When the program returns, the pools lower every deferred
body into the base in their usual order and the run bakes and publishes
the image as before.

What it buys is the time to `main`, not the time to exit:

| Cold, from outside the checkout | Eager | Lazy |
|---|---:|---:|
| hello, first output | 107 ms | 64 ms |
| hello, wall to exit | 107 ms | 110 ms |
| collections example, first output | 121 ms | 71 ms |
| collections example, wall to exit | 130 ms | 131 ms |

The collections example lowers 76 of the 4885 deferred bodies on first
call, a coroutine example about 180 of 6587 with the packs; hello lowers
none, as `println` is a host binding. The costs: the build stays resident
for the whole run (the run's resident set is the build's, about 95 MB at
`main` for hello against 48), the image lands only once the program ends
and a program that exits abnormally leaves no image, and the completed
image numbers its lambdas after the data-class components rather than
before them, so it differs from an eager bake in ids though not in
behaviour. The eager path is untouched: its fingerprints are identical on
every function. The corpus in lazy mode and a warm run of the corpus over
a lazy-baked image both hold the baseline. Bundles ship an image and never
take this path.

### What remains

The churn that remains is the checker's arenas (60 MB, freed together),
the module tables doubling as they fill (30 MB) and the resolver's and
checker's per-worker tables.

The image carries the sources (7.5 MB of its 10). A run that has the
stdlib pack in its binary has those bytes already; keying the sources by
the content hash the image already carries would take the copy out of the
bake, the file and the mapping.

## What remains for time

A ReleaseFast cold `klio run hello.kt` now prepares in about 145 ms and
its wall is 140 to 165 ms; the process itself (load, `main`, exit) is 4 ms
of that. Back-to-back runs are the faster ones: after a second of idle the
cores clock down and the same run takes 190 to 200 ms. The bake is on the
critical path since the run continues from its bytes (the section below on
memory says why); it went from 32 ms serial to 16 with the sections on
threads. Inside prepare:

| Phase | Now | Before this round |
|-------|----:|------:|
| Read and register the sources | 0 ms from the binary, 4 ms from a checkout | 7 ms |
| Lex and parse, ten threads | 9 to 10 ms | 21 to 24 ms |
| Stage: resolve 5 on the pool, declarations 4, bodies 12 on ten threads, merge 2, tables 2 | 29 to 31 ms | 37 ms |
| Build: headers about 12 serial, class bodies 9, bodies 25 to 29 on the pool, bookkeeping 4 | 62 to 68 ms | 78 ms |
| Bake 16 (sections 7 on threads, tables 2, root 7), load 4, drop 3, extend 4 | 27 ms | fork 3 to 5 plus 8, with the bake off the path in a child |

What this round changed, each with its own verification:

- **Fresh memory was the shared resource.** On macOS a page fault costs
  1.1 µs alone and 4.6 µs with eight threads faulting at once, and a 256 KB
  map, touch and unmap goes from 34 µs to 151 µs. Every parallel phase
  builds fresh trees, and the slab handed them out a few cells per lock
  step from slabs whose free list it had just threaded, faulting the pages
  in under the lock, with anything over 8 KB a map and an unmap of its own.
  Now a refill takes an untouched run of 16 KB in one lock step and bumps
  through it, slabs come from a 4 MB reserve carved with an atomic step,
  and a freed large block parks on a power-of-two class list, mapped and
  resident, for the next one; the size class is a table lookup. Maps per
  cold run went from 2228 to 464, the parse wall from 26 ms to 9, the body
  pool from 29 ms to 25. The build's peak is higher by the parked blocks,
  which go with the build heap. `KLIO_SLAB_MAPS=1` lists every
  map by site.
- **The lexer reserves its token list once**, four bytes a token, and
  scans a comment star to star instead of byte by byte; the largest source
  lexes in 8 ms rather than 22.
- **The checker's merge reserves room for every worker at once**, so each
  table grows one time rather than once per worker: 5 ms to 2.
- **The stdlib sources are borrowed, not copied.** The source map adopts
  the bundle's arena and indexes no lines, and the pack the binary carries
  is read in place, without the hash over its four megabytes or a copy of
  each file: 7 ms to 0 from an installed binary, 4 from a checkout (the file
  reads).
- **Host symbols are found through a hash index**; the comptime string map
  compared every key of a length, and every function header asked it.
- **The strip only blanks on the cold path.** Its freeing walk over the
  stripped bodies is gone with the build heap (a base the harness keeps
  still frees, on a thread, and a debug build in place so its check of the
  kept declarations still runs).
- **The cold run's tail is traced**: what runs before the bake, the stage's
  table copy and total, the bake, the load, the heap drop, and the extend.
- **The extend keeps a live base's tables.** A base built in this process
  had every class's member ASTs registered by its own build; the one
  extend that owns it adds the user's classes instead of resetting the
  tables and registering every base class again: 3 ms of a 7 ms extend.
  An image's base decodes its declarations and starts over as before.
- **The resolver's pool arenas come from the process allocator** when it
  can serve several threads, so their teardown parks blocks instead of
  unmapping a chunk at a time.
- **The member AST tables key on the names themselves.** Registering a
  class's members formatted an owner-and-name string into the build arena
  per property and formatted it again per lookup; the keys are now the
  declarations' own names hashed together. On the compose base the table
  install went from 22 ms to 5. The stage's output tables are reserved at
  their final size: 16 ms to 11 on that base.

What is left is mostly serial now. The parallel phases are the parse at 9
to 10 ms, bounded by the largest file's lex; the stage's bodies at 12 ms
(about 60 ms of CPU on ten threads, a fifth of it the checker's own
control-flow lowering); and the body pool at 25 to 29 ms (143 ms of CPU:
string-keyed class lookups 16%, thread-local access 5%, type-head scans 4%,
bare-call candidate iteration 7%, extension resolution about a quarter,
inline splicing about a sixth). The serial steps add to about 70 ms: the
stage's resolve 5, declarations 4, merge 2, tables 2 and teardown 3; the
headers 12; the strip's pinned check 2.5 and its collection 1.1; the bake 16
(its root encode 7 and the tables 2 serial); the load 4; the drop 3; the
extend 4; the class-member thunks 2.

### Toward 100 ms for a program that pulls packs in

The compose bases carry 16000 declarations and about five seconds of CPU
across their parse, stage and lowering. No parallel speed-up of that
pipeline reaches 100 ms; a cold pack program must not lower pack sources
at all. Two tracks, in this order:

1. **The warm path is the floor.** A pack program that finds its image
   pays the pack catalogue, the image load and the extend before its own
   code runs. Everything the extend recomputes over the base by decoding
   the base's declarations is either baked into the image (the compose
   collections, the trailing-lambda shapes, the settled defaults) or
   walked for the build's own classes only (hierarchy method names,
   shadowed storage). What remains here: the member AST tables, still
   registered by decoding every base class (16 ms, 45 MB), the eager
   decode of the image's tables (50 ms, 27 MB), the catalogue (12 ms),
   and publishing the base's declarations for the user check (6 ms).
2. **Pack layers baked at install.** `klio pack install` bakes an image
   for the pack's dependency closure by extending the image below it with
   the pack's sources, in a canonical dependency order, so a program that
   selects a closure loads its image and lowers nothing but its own code,
   and a program whose selection is not a closure lowers only the packs
   past the nearest prefix. The extended base is materialised before the
   bake: an image's base keeps its declarations and functions encoded and
   decodes them on demand, and the bake needs them live.

   The machinery is in, behind `KLIO_STDLIB_IMAGE_LAYER=1`: a pack program's
   cold run loads the stdlib image for its gate (the build ships one per
   gate), materialises it in about 20 ms, and lowers only the packs on top,
   on the pool. The stage still checks stdlib and packs together, so its
   picks are the whole-program ones. On `compose_animation` the image comes
   out the same size as one lowered from source and the program runs the
   same, with the build phase's lowering cut from about 590 ms to 420
   serial and to 100 on the pool.

   Two gaps keep it opt-in, both the same the program-over-image path has
   today. A global call inside a pack member resolves dynamically over the
   layer where the whole-program build resolved it statically, because the
   check over an image's published declarations lacks the generic detail to
   pick an overload (`xs.sum()` in the hello example is a direct call cold
   and a dynamic member call warm). And a pack `actual` does not yet
   supersede the stdlib `expect` it implements across the image boundary,
   since the stdlib's `expect` is already lowered into the base. The first
   shows as a member miss deep in a compose run; the second as a duplicate
   class. Closing them makes the layer exact and improves every warm run's
   code. `KLIO_STDLIB_IMAGE_LAYER=0` (the default) lowers from source.

Memory follows: a cold run then holds what a warm run holds, and the
warm run's resident set is the image's touched pages plus what the
extend keeps.

### A program that pulls packs in

`examples/compose_window.kt` keys its own image (the stdlib plus the
compose packs, 16000 declarations, a 78 MB image), so the shipped stdlib
image does not serve it and its first run bakes. ReleaseFast, after this
round:

| | Cold | Warm |
|---|---:|---:|
| Wall | 2.2 s (was 3.0 s) | 560 ms (was 600) |
| Prepare | 1.73 s (was 2.6 s) | 185 ms (was 226) |
| Load the packs: catalogue by header, read the selected sections, parse | 100 ms | 16 ms (was 42) |
| Stage | 480 ms (was 510) | |
| Build | 1.04 s (was 1.2 s) | |
| Serialize (in the child, off the path) | about 300 ms | |
| Load the image | | 55 ms |
| Extend the user program | | 111 ms (was 118) |
| The program itself | 430 ms | 350 ms |

The smaller `examples/compose_animation.kt` (a 42 MB image) prepares in
815 ms cold, 840 ms wall, and 128 ms warm, 160 ms wall.

Every installed pack used to be read whole and hashed to learn its
manifest, on every run, whether or not the program imported it: thirty
megabytes read and twenty milliseconds of Blake3 before a source was
parsed. A pack is now catalogued by its header alone, a few hundred bytes
for the stored hash and the section directory, and a program that selects
it reads the sections it needs by position; the hash covers the whole body
and goes unchecked here, since an installed pack was checked when it was
installed. The strip of the dead bodies, 27 ms serial on this base, walks
the declarations on threads: 15 ms.

The top-level bodies had lowered serially here: a local function's
default-argument thunks grew a registry table in a shard, so the pool gave
up. That table rides the merge now (1023 ms to 174 ms). What remains on
this base, in order of size: the stage's bodies (3.5 s of CPU over ten
threads; the checker's per-body cost is the lever), the serial header
steps, the class-member thunks, and on the warm side the extend, which
re-registers every base class's members on each run by decoding them from
the image (`installMemberAstTables`, `registerHierarchyMethodNames`, and
the compose pass decoding every lifted declaration to collect composable
names that the image could carry precomputed).

### Bodies on a pool

Headers reserve every body's FuncId before any body lowers, so bodies are
independent: each reads the module's tables and appends only the lambdas,
thunks and constants of its own (measured on the stdlib: 539 functions and
371 constants over 4134 bodies, nothing else). `body_pool.zig` gives each
worker a shard, a copy of the module whose appendable tables are its own,
allocates those ids locally, and merges the shards in declaration order,
renumbering ids through a reflective walk of the emitted instructions
(`ir.remap`) so the module comes out as a serial pass builds it. A body that
declares a local class or object registers its supertypes and member headers
in the registry as it lowers, tables the shards share read-only, so the pool
keeps such a body off the shards and lowers it on the main thread at its
position in the merge. A shard that still grew a shared table makes the pool
give up and the driver lower serially.
Ambient lowering state is threadlocal and captured per worker; see
[process globals](process-globals.md). Class member bodies take the same
pool: every class's shell and member sets are registered first, every member
body lowers, then each class is sealed in declaration order. Before the shards
fork, the module's lazy lookup caches are filled once, so the copies share
them without writing.

Doing this exposed a declaration-order dependence in the serial lowering: a
call resolved differently depending on whether its callee's body had already
been lowered, because a few resolution gates asked `hasBody` where they meant
"declared with a body". Bodies are now placed only after every body has
lowered, in both modes, and those gates read `declaredWithBody`, so a body
sees the header set alone and the pool and the serial loop produce the same
module. The change made three stdlib functions resolve statically where they
had fallen back to runtime dispatch, and 72 class members gained a direct
call to a sibling once every class shell was registered before any member
lowered. `KLIO_LOWER_THREADS=1` is the serial
reference; `KLIO_LOWER_FINGERPRINT=1` prints a per-function hash for
comparing two builds.

Byte identity of the image is no longer the pool's gate: the encoder dedups
slices by address, and which shard allocated a slice moves those references
by a byte or two. The fingerprint dump is the comparison that matters.

### Serialize in process

`image.bake` defers bodies by editing the base's AST and function table in
place, and the run writes dispatch memos into instructions the base shares
with the running module, so the bake ran in a forked child and the program
started against the base as built. The run continues from the baked bytes
now (see the memory section), so the bake runs in this process before the
program starts, with its sections encoded on threads, and a thread writes
the file; `klio run` joins that thread after the program, `klio bake-image`
before it returns. The image itests read the image right after a run for
the same reason.

The image cache key now takes each stdlib source's path, size and
modification time rather than its content: reading and hashing 3.4MB of
sources cost more than loading the image it keyed, on every warm run too.

The levers, in the order they will be taken:

1. **The serial remainder.** The resolver's second pass now runs on the
   pool (10 ms to 7 ms; its declaration pass is the serial rest); the
   header steps (about 20 ms) are one thread registering 6000 signatures;
   the extend of the user program and the cache-key work are 18 ms of
   small steps.
2. **Splice inline callees from a lowered template** instead of re-lowering
   their AST per call site.
3. **Bake at build time: done for the stdlib.** The key includes the
   executable's stamp, so every rebuild was cold. `zig build` now runs the
   built binary once (`klio bake-image --stdlib-cache`) and installs the
   image and its meta file under `share/klio/cache`; a run whose own cache
   misses reads them there (`hit (shipped)` in the trace). The first run
   after a rebuild of an import-free program is 25 ms in release, 141 ms in
   Debug, where it was the cold bake. A program that pulls packs in still
   keys its own image; layering pack images over the stdlib one (as the
   JDK's dynamic archive layers over the static one) is what remains here.
4. **Lower on demand.** The image already defers inline bodies and decodes
   function bodies lazily; lowering them lazily, with the image completed in
   the background after the run, would make a cold run cost the headers plus
   what the program reaches. This changes the runtime model and is the last
   resort rather than the first.
