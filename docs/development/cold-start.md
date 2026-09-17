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
against a fresh data home:

```sh
rm -rf /tmp/klio-cold && KLIO_HOME=/tmp/klio-cold KLIO_TRACE_STDLIB_IMAGE=1 \
  KLIO_TRACE_LOWER=1 ./zig-out/bin/klio run hello.kt
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

## What remains

After the changes the bake is dominated by lowering the function bodies
(about 70% of the remaining time), and inside that by resolution (extension
and bare-call candidate ranking, about a third), inline splicing (re-lowering
an inline callee's AST at each call site, about a sixth) and string hashing
across the module's many name-keyed maps. Serialization is about 10%, the
checker about 12%.

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

1. **Splice inline callees from a lowered template** instead of re-lowering
   their AST per call site.
2. **Bake at build time.** The key includes the executable's stamp, so every
   rebuild is cold; the JDK, V8, Dart and CPython all produce their equivalent
   of the image in the build and ship it. `zig build` already has a base-gen
   step for the parity harness; extending it to install the stdlib image next
   to the binary removes the cold path from a fresh install entirely, and
   layering pack images over it (as the JDK's dynamic archive layers over the
   static one) removes it for new pack combinations.
3. **Lower on demand.** The image already defers inline bodies and decodes
   function bodies lazily; lowering them lazily, with the image completed in
   the background after the run, would make a cold run cost the headers plus
   what the program reaches. This changes the runtime model and is the last
   resort rather than the first.
