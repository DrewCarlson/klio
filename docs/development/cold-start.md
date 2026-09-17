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
4. **serialize**: encode the base into the image and write it.
5. The user program is then parsed, checked and lowered against the base as on
   a warm run, and executed.

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
| parse | 136 | 85 | 37 |
| stage | 377 | 240 | 57 |
| build | 941 | 290 | 131 |
| serialize | 337 | 34 | 37 |
| total prepare | ~1900 | ~690 | ~300 |

A warm run is unchanged at about 120 ms Debug and 25 ms ReleaseFast.

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

A cold run lowers from the AST and executes from the module it just built, so
what it keeps is what a warm run never materialises: the stdlib's parse trees
and the tables the build used. Debug, `hello.kt`, sync bake:

| Step | Before | After |
|------|-------:|------:|
| After parse | 105 MB | 82 MB |
| After the check that records the eager call picks | 165 MB | 87 MB (checker on an arena, freed) |
| After lowering | 216 MB | 184 MB |
| After the bake | 226 MB | 190 MB (image bytes freed) |
| At `main` | 307 MB | 188 MB |
| Peak (`/usr/bin/time -l`) | 357 MB | 258 MB |
| Warm run at `main` | 82 MB | 74 MB |

ReleaseFast at `main`: 177 MB cold, 65 MB warm. Of the cold run's resident
set at `main`, the slab holds 108 MB, 104 MB of it live; the rest is the
binary's own pages (large in a Debug build, small in release) and the GC's
reservation.

What was retained for nothing, and the fix for each:

- **The checker's tables.** The eager-call pass ran the type checker on the
  general allocator and never freed it: 60 MB of types, scopes and per-body
  scratch. The checker now runs on an arena per worker, freed once the pass
  has copied its picks out. That copy exposed a use-after-free: the checker
  recorded a call's receiver class as a slice of the call's own return type,
  which the caller freed. Class names the checker records are now interned
  in the checker, so the recorded tables own every string they hold.
- **Lowering caches.** The extension-resolution and receiver-verdict caches
  serve the build; `dropLoweringCaches` frees them after the base build
  (they rebuild lazily if a runtime lowering of an object literal needs them).
- **The image bytes.** A sync bake kept the 10 MB it had just written.
- **Four copies of the top-level declaration list.** A `Decl` is 672 bytes
  and was copied by value from each file into the concatenated file, from
  there into the lifted list, and from there into the retained list. The
  lowered module and the runtime read only the retained list, so the other
  three are freed once it exists (11 MB).
- **A clone of the base.** The base was cloned before the user program was
  lowered on top, so the base could be extended again; a cold `klio run`
  extends the base it just built and nothing reads it afterwards, so it is
  adopted in place, as the warm path already did.
- **The per-thread dispatch caches.** Two megabytes of `threadlocal` arrays
  (method, extension, field, permission and applicability caches, the
  polymorphic inline caches, the native slot banks) sized every thread's
  thread-local block. Darwin allocates that block with `malloc` on a thread's
  first access to any thread-local, so each of the thirty parse, check and
  lowering workers paid 2.4 MB it never used, and the C heap kept 23 MB of
  those blocks resident after the workers had exited. The caches now live in
  a per-thread block the owner thread reads as a global and any other thread
  allocates on first use (`runtime.tls_fast.PerThread`); the thread-local
  block is 300 KB. The build workers also hand their slab magazines back at
  exit.
- **Stripped bodies.** The base build blanks the body of every non-inline
  stdlib function the lowered code does not point into, but the trees stayed
  allocated. The strip now frees them (2250 bodies, 46000 nodes, 13 MB) by a
  walk over the node types that skips strings (slices of the source), type
  references and annotations (copied by value into the lowered module, so
  their children are shared) and class declarations (never in a stripped
  body). What the lowered module points into is pinned first: an
  `Inst.AstLambda` keeps its lambda's block for a runtime re-lowering, so the
  138 bodies holding one are blanked but left allocated. Before, those
  pointers survived only because nothing freed the trees; the bake encoded the
  dead-but-intact nodes inline. The oracle for the free is the image: baked
  with `KLIO_PRUNE_KEEP=1` (trees left allocated) and without, the two are
  byte-identical, so nothing the bake reads was freed. `KLIO_SLAB_POISON=1`
  overwrites freed cells; the corpus and the commontest sweep run under it
  after any change to what the build frees.
- **The trim.** Before `main`, `slab.reclaimAll` returns the build's fully
  free pages and every parked spare span to the OS, once, rather than waiting
  for the GC's aged trim.

### What remains

The AST itself stays: the runtime reaches class members' property
initialisers, accessors, delegates, constructor defaults, init blocks and
the inline bodies through `ForestField` pointers, and a cold run's forest is
the in-memory tree. Freed body cells sit between live nodes, so they lower
the run's later growth rather than its resident set at `main`. Two levers
would change that:

1. **Execute the fresh image.** After the bake, load the image the way a warm
   run does and drop the build wholesale; the cold run would then hold what
   the warm run holds. It costs the load (15 ms release) plus waiting for
   the bake instead of forking it, so it trades cold time for memory.
2. **Box the declarations.** `Stmt` embeds `Decl` (680 bytes) by value and
   `Function` is 664 bytes, so every statement is the size of a declaration
   and every list of declarations copies its contents. Boxing them shrinks
   the tree and makes the copies pointer-sized.

The embedded stdlib sources are still duplicated into the source map at
parse (4 MB, plus line tables) rather than borrowed from the binary as the
image path borrows them from the mapping.

## What remains for time

A ReleaseFast cold `klio run hello.kt` now prepares in 163 to 174 ms and
its wall is 175 to 215 ms; the process itself (load, `main`, exit) is 4 ms
of that. The bake in the child takes another 35 to 45 ms off the critical
path. Inside prepare:

| Phase | Now | Before this round |
|-------|----:|------:|
| Read and register the sources | 7 ms | 7 ms |
| Lex and parse, ten threads | 21 to 24 ms | 25 to 29 ms |
| Stage: resolve 7 on the pool, declarations 4, bodies 12 on ten threads, merge 5 | 37 ms | 55 ms |
| Build: headers about 20 serial, class bodies 10, bodies 25 to 30 on the pool, bookkeeping 5 | 78 ms | 118 ms |
| Everything else (cache key, user parse, extend) | about 18 ms | about 20 ms |

What this round changed, each with its own verification:

- **Trace flags read once.** Every lowering of a call read its trace flags
  with `getenv`, which walks the environment under libc's lock; on the
  pool that serialised the workers. The pool's bodies went from 60 ms to
  33 ms.
- **The stage runs the checker for the picks alone.** Its declaration-level
  diagnostic passes and the merge of every worker's control-flow graphs were
  work nothing read; the image is byte-identical without them
  (`KLIO_STAGE_DIAG=1` restores them to compare).
- **The pool's workers share the name indexes** instead of copying two maps
  of lists each; a fork is 2 to 5 ms instead of up to 22.
- **The compose pass skips a module without a `@Composable`**, which the
  parser flags, so a stdlib base no longer walks its declarations four times
  to find nothing.
- **The largest sources parse in pieces.** `_Arrays.kt` alone bounded the
  parse wall; its token stream is cut at declaration boundaries and the
  pieces parse alongside the other files. `KLIO_PARSE_JOBS=1` is the
  reference, `KLIO_PARSE_CHECK=1` compares a piecewise parse with a whole
  one.
- **A dead bake child is no longer silent.** The forked bake of the compose
  base had been crashing for every compose example while the runs passed,
  since a child that dies writes no image. The strip now pins every node a
  lowered instruction reaches, the cache keeps a `.baking` marker while the
  child works, and the next cold run says when the previous bake died.
  `KLIO_STDLIB_IMAGE_SYNC=1` on a compose example is the check the corpus
  cannot make.

The body lowering that is left is spread thin: string-keyed map lookups are
about 16% of a worker's time (local names, class names, receiver verdicts),
thread-local access 5%, allocation 5%, bare-call candidate iteration 7%,
extension resolution about a quarter, inline splicing about a sixth.

### A program that pulls packs in

`examples/compose_window.kt` keys its own image (the stdlib plus the
compose packs, 16000 declarations, a 78 MB image), so the shipped stdlib
image does not serve it and its first run bakes. ReleaseFast:

| | Cold | Warm |
|---|---:|---:|
| Wall | 3.0 s (was 3.8 s) | 600 ms |
| Prepare | 2.6 s | 226 ms |
| Stage: resolve 27, declarations 31, bodies 344 on ten threads, merge 40 | 510 ms | |
| Build: headers about 200 serial, class bodies 340 (pool), top-level bodies 174 (pool), member thunks 144 serial | 1.2 s (was 2.1 s) | |
| Serialize (in the child, off the path) | 320 ms | |
| Extend the user program | | 118 ms |
| Load the packs' metadata | | 42 ms |
| The program itself | 350 ms | 350 ms |

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
(`ir.remap`) so the module comes out as a serial pass builds it. A shard that
grew any other table makes the pool give up and the driver lower serially.
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

### Serialize in a child

`image.bake` defers bodies by editing the base's AST and function table in
place, and the run writes dispatch memos into instructions the base shares
with the running module, so the two cannot overlap in one address space. The
bake runs in a forked child instead: the child's copy of the base is the base
as built, the program starts as soon as lowering ends, and the image lands a
few hundred milliseconds later. `klio bake-image` waits for the child;
`klio run` does not. `KLIO_STDLIB_IMAGE_SYNC=1` serializes in-process, which
the image itests use because they read the image right after a run.

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
