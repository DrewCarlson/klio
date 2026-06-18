# Memory reclamation: making the value model free memory again

## TL;DR for a fresh agent (current state)

Two distinct problems, both now largely solved:

1. **Startup baseline / "high usage for simple programs" — FIXED.** Every
   program (even `println("hi")`) used ~646 MB resident. Root cause was a single
   allocator misuse, not the stdlib graph: `decodeSymbols`
   (`src/stdlib/generated/mod.zig`) deserialised the embedded symbol index
   (~33 K tiny records) straight into `std.heap.page_allocator`, which mmaps a
   whole page **per allocation** (16 KB min on macOS) — ~535 MB for a few MB of
   data. Decoding into a process-lifetime arena dropped every simple/stdlib
   program to **~127 MB** (`d0b126c8`). See §8.

2. **Long-running leak (the value model never frees) — largely reconciled.**
   The interpreter runs on one never-reset arena with reference-counting
   reclamation force-OFF. The value-lifetime layer the Rust→Zig port dropped is
   now rebuilt and, under a real freeing allocator with reclaim ON
   (`KLIO_RECLAIM=smp`), simple programs, string churn, `Pair`/destructuring,
   mutable List/Set/Map loops, data-class instances, **and the full coroutine
   surface incl. `async`/`await` at scale** (`runBlocking`, suspend funcs,
   `delay`, `launch`, `coroutineScope`, `Dispatchers.Default`) run
   double-free-clean. The `async`-at-scale corruption was a cluster of
   store-without-retain / borrowed-return bugs in the host, all now fixed:
   - stored-property writes (`setField` → `define`) adopted a borrowed value;
   - collection element *accessors* (map/array/list get) returned a borrow;
   - collection *builders* (`NewList`, `makeList`/`Set`/`Array`, `listOfNotNull`)
     stored borrowed elements; `MutableMap.remove` over-retained the transferred
     value and dropped the removed key;
   - instance `outer` links stored a borrow of the enclosing `this`/capture;
   - bound-closure creation copied captures without retaining them;
   - a block dispatched to a worker thread (`kotlin.concurrent.thread`,
     `Dispatchers` pool) crossed threads without a retain.

   With those landed, the routing *livelock + multi-GB leak* that previously
   exploded RSS to the 6 GB cap in ~1 s is **fixed**: a `routing { get(...) }`
   server now starts `df`-clean under real reclaim and (with
   `start(wait = false)`) logs `Responding` and runs to a clean exit — the full
   route set + `install(ContentNegotiation){json()}` + `@Serializable` all
   included. (Caveat: end-to-end request *serving* under reclaim is not yet
   green — see the `start(wait = true)` residual below — so the earlier
   "4000 requests, flat RSS" reading was a server stuck in startup, not serving;
   the real, verified win is that the livelock/explosion is gone and startup is
   `df`-clean.) The root cause was a single bug: **anonymous-object captures were
   stored in the anon-method registry as borrows.** `KtorSimpleLogger(name)`
   returns an
   `object : Logger` that captures `name`; when the enclosing function returned
   and freed its `name` register, the captured `String` dangled. The next log
   line read that freed `String` cell, whose reader/writer lock now held garbage
   (a stray sign bit = "writer held"), so `renderValue`'s `borrow` spun in
   `lockShared` forever — and the surrounding retry allocated, exploding RSS.
   `KLIO_RC_DETECT=1` (leaks freed cells) masked it because the cell was never
   destroyed. Fix: `buildCapturePairs` retains each captured value (the registry
   owns them for the object's lifetime), matching closures. The same pass fixed
   the `MutableMap` accessors the pipeline/event-bus use (`computeIfAbsent` /
   `putIfAbsent` returned the present value borrowed; `getOrPut` stored the new
   entry without retaining; `replace` returned a value `mapSet` had already
   freed). The hunt technique that pinned it: `sample(1)` showed the worker
   spinning in `SpinRwLock.lockShared` under `renderValue → StringRef.borrow`; a
   gated check in the `BinOp.StringConcat` path (`s.strongCount()==0 or huge`)
   caught the freed string mid-concat as `"[INFO] (" + <freed name>`.

   The `df=1` that the routing/pipeline setup showed at teardown is **fixed** and
   was NOT a cycle: the per-cell RC-history tracker (re-added in `ObjRef`, dumped
   on `KLIO_RC_DETECT` double-free) pinned the doubly-freed `PipelinePhase` to a
   borrowed return from **`Iterator.next()`** — `iteratorMember` in
   `host_call_member.zig` returned `items[p]` without retaining, so a `for (phase
   in phases)` / route-node walk freed an element one ref early. `next()` now
   retains the element. With that, the full JSON/ContentNegotiation server
   (`wait = false`) runs `df`-clean under `KLIO_RECLAIM=smp KLIO_RC_DETECT=1`. The
   technique to find these: re-add the RC-history tracker, run the *completing*
   (`wait = false`) repro, read the doomed cell's full clone/deinit trajectory at
   the double-free, then a gated `KLIO_RET_DBG` print of member-call Instance
   results (+ a `KLIO_BLANKET` retain to confirm "df→0 ⇒ a borrowed Instance
   return") narrows to the exact accessor.

   *Remaining — request serving under reclaim:* a tail of the SAME bug class
   (host builders/accessors that adopt a borrowed value without retaining) still
   lives in the request path. A large batch is now fixed — see below — and a
   single route (`GET /api/v1/ping`, no params/body) **serves correctly under
   `KLIO_RECLAIM=smp`**. Routes that touch path params / query / headers / body /
   JSON still segfault on a freed container.

   **Correction (important): `KLIO_RECLAIM=arena` is NOT the arena mode.**
   `allocChoice` maps any unrecognised value to `.smp` and `reclaimRequested`
   maps it to reclaim-ON, so `KLIO_RECLAIM=arena` runs **smp + reclaim-ON** (the
   corruption oracle). True arena = `KLIO_RECLAIM` *unset* (or `0`). Under true
   arena the full ktor server serves every route cleanly — the crashes are
   purely reclaim-on missing-retains, exactly as expected.

   **Diagnostic method that works:** run `KLIO_RECLAIM=smp` (reliable `0xaa`
   crash; no detector). A gated freed-cell UAF tracer (threadlocal freed-address
   registry recording the freeing stack, cleared on realloc to survive smp
   address reuse; read-side checks at `getField`/`Array.get`/the response
   `strAt`; a per-cell retain/release history) names the freed cell, the
   over-releasing frame (`Frame.deinit` releasing a register that held the only
   counted ref), and the unbalanced store. Heavy history capture perturbs the
   deepest bugs (heisenbug) — keep it to the freed-registry + read-checks for
   those. (This tracer was scaffolding; not committed.)

   **Fixed and validated (committed; leak suite green, `ping` serves):** the
   borrowed-element builders — `makeListBorrowed`/`makeArrayBorrowed` routing
   (filterNotNull, distinctBy, groupBy, distinct, slice, list/array
   plus/minus/flatten/unzip, array copyOf/copyInto), `makeMap` (retain kept
   key+value, release displaced), map `keys()`/`values()` views, set
   plus/minus/intersect, associateBy/associateWith, groupingBy.reduce,
   `cloneItemsList` (toList/toMutableList/asList/toTypedArray/toSet/iterators/
   sorted), and StringBuilder fluent returns (`okSb`).

   **Also fixed since:** `MutableSet.add`/`addAll` stored borrows without
   retaining and `MutableSet.clear` dropped elements without releasing
   (the `MutableList` equivalents were already correct); data-class
   `componentN()` returned the instance field borrowed (destructuring UAF);
   `kotlinx_serialization.decodeObject` leaked the owned decoded ctor args the
   constructor borrows. Each fix moves a ktor route further before the next
   crash (e.g. `GET /users` now reaches the routing method-dispatch /
   `delegateForward` before hitting the next freed-receiver UAF), so the tail is
   **converging, not diverging** — it is the same store-without-retain class,
   just spread across the StringValues / routing / pipeline / response builders.

   **Two ownership audits run + applied (19 confirmed fixes, all leak-suite-green):**
   adversarial workflow audits over the host stdlib/interp found and verified the
   container/accessor/builder ownership bugs; all confirmed UAF/double-free fixes
   and the safe missing-release leak fixes are committed. Highlights of round 2:
   SAM-conversion & direct local-class allocation stored borrowed ctor args as
   owned fields without retaining; `Enum.valueOf`/`enumValueOf`/enum `.name`
   returned the immutable-ClassDef singleton borrowed; `boundRefDispatch`
   returned borrowed `getField` results; `serve`/`drainIterableToList`/
   `materializeUserMap` leaked owned containers. (Deferred: `funcValueById`
   returns a fresh owned `IrClosure` its three callers treat as borrowed — a
   leak; the fix is to make it borrow-returning across all three sites.)

   **Residual blocker — a layout-sensitive query-param value-substitution UAF.**
   With ping serving cleanly, the param/query/body/JSON routes still crash under
   reclaim-on, now with an *unstable* signature (segfault `0xaa`, then
   `call_member percentEncode on kotlin.Function`, then `incorrect alignment` in
   `allocator.create`) — the hallmark of a heap double-free whose manifestation
   shifts with allocation layout. Root: a query-param `String`/`Char` in the
   `parseQueryString`→`StringValues`→`encodeParameters` path is freed one ref
   early; its smp cell is reused (e.g. for the `.map { it.encodeURLParameterValue() }`
   lambda closure), so an upstream `it.percentEncode()` dispatches on a `Function`.
   It resists BOTH tools now: the static audits have covered the host ops this
   path uses (all fixed), and the dynamic freed-cell tracer's bookkeeping shifts
   the layout enough to make the crash vanish (heisenbug). The remaining
   missing-retain is therefore either in a host op neither audit reached or in a
   subtle StringValues interaction; pinning it needs a near-zero-overhead probe
   (a single refcount-poison check at the exact dispatch, not a registry).

   **Recommended close-out: the structural per-request arena reset (§12.4
   option 2).** The residual tail is layout-sensitive and resists per-site
   fixing; the robust fix is to run each request's value graph with reclaim
   *off* in a per-request sub-arena and reset it after copying the response out —
   no per-request `ObjRef.deinit`, so no missing-retain UAF is possible, and the
   sub-arena reset reclaims everything (flat RSS). This needs the VM to support a
   scoped allocator swap around `invokeCallable` in `serve` and a deep-copy of the
   response to the long-lived allocator; it retires the entire request-path tail
   at once. `free` mode already proves the request *logic* is correct (every route
   serves), so only the reclaim discipline is at issue.

   **Open tail (next):** the eager `engineReceiveChannel: ByteReadChannel =
   ByteReadChannel(bodyText.encodeToByteArray())` in `KlioApplicationRequest`
   builds a `prim=null` Value array that is freed at the property-init frame's
   teardown while still referenced — read later via `Array.get` (`0xaa`). The
   store-without-retain is inside the upstream-Kotlin `ByteReadChannel(ByteArray)`
   buffer construction (kotlinx.io Buffer / ChunkBuffer), not a klio builtin, so
   it needs the tracer's history to pin. Plus the remaining audit findings not
   yet applied: `host_call_member` collectionMutators/componentMembers/
   dataClassAutoMembers, and `kotlinx_serialization.decodeObject` (releases the
   owned decoded args the constructor borrows — a JSON-path leak). The
   `host_fields`/`host_instances` *over-retain* audit findings are suspected
   false positives (leak suite is clean) — verify before touching (removing a
   needed retain would introduce a UAF). The deeper structural option
   (per-request arena reset, §12.4 option 2) retires the whole request-path tail
   at once if the per-accessor hunt proves long.
   Separately, the anon-capture retains are released only at host teardown (a
   bounded per-anon-class hold, fine for a once-created logger but worth
   releasing on registry eviction). (The logger-name garble noted previously was
   the same anon-capture bug and is fixed — names now render correctly.) A
   long-running server can also run `KLIO_RECLAIM=free` (a freeing allocator with reclaim OFF:
   reclaims the explicitly-freed host/container temporaries — ~5× better
   per-request — without the value-graph teardown that still corrupts the job
   tree).

**Allocator modes** (`src/main.zig`, selected by `KLIO_RECLAIM`):
- *(unset)* `arena` — production: one process-lifetime arena, reclaim OFF
  (`ObjRef.deinit` is a no-op). Byte-for-byte the original behavior. Every
  reclamation change below is gated on `reclaimEnabled()` so this path is
  unchanged.
- `free` — `smp_allocator`, reclaim OFF. Safe for long-running processes; frees
  what the run path explicitly frees, leaks the value graph (bounded enough to
  be a real improvement, not yet flat).
- `smp` / `1` — `smp_allocator`, reclaim ON. The full reclamation path; the
  oracle for "does the value graph stay bounded / never corrupt".
- `debug` — `DebugAllocator(thread_safe, safety)`, reclaim ON. Surfaces UAF /
  double-free at the source.

**Do NOT** try to add runtime retain/release by guessing ownership at each
instruction handler blindly — ownership is known *statically by the handler*
(`LoadParam` aliases, `NewList` mints, `Move` copies); that is the model that
works (§7.0). The superseded `Retain`/`Drop`-IR sketch (§7.1) is not being used.

---

## 0. Current state (consolidated)

### 0.1 Committed work (all gated on `reclaimEnabled()`; production unchanged)

Value-model foundation (earlier; see §5):
- `ada8fcdb` — fixed a real arena-masked double-free in the `Call` dispatch.
- `ba6bec4b` — `Value.retain`/`release`/`deinit` + `InstanceData.deinit`.
- `58266139` — recursive release of container elements (List/Set/Array/Map/
  Iterator/IrClosure), `strongCount()==1`-guarded.
- `StringRef` byte ownership (init dupes, release frees); owning-`*Value`
  variants (`Pair`/`Triple`/`MapEntry`/`Result`/`Exception.cause`/
  `BoundMethod.receiver`/`Generate`) converted to `ValueBox` (`ObjRef(Value)`).
- eval register balance: `Frame` owns one ref per register, releases on
  overwrite (`Frame.write`) and teardown (`Frame.deinit`); alias handlers
  (`Move`/`CellGet`/`LoadParam`/`LoadCapture`/`Cast`/`NotNullAssert`), accessors
  (`GetField`/`LoadGlobal`/`QualifiedThis`), and terminators (escaping
  `Return`/`Throw`/non-local-return) retain. Closure-capture, instance-ctor
  field, and collection-map-put stores retain + release-old.

This session:
- `d0b126c8` — **§8 baseline 646 → 127 MB**: `decodeSymbols` decodes the symbol
  index into a process-lifetime arena instead of `page_allocator`. Adds
  `src/runtime/alloc_track.zig` (committed diagnostic tooling — `KLIO_ALLOC_TRACK`
  byte/size-histogram + phase snapshots + a `pageAllocator` stack-tracing probe).
- `d0efb310` — **`KLIO_RECLAIM=free`** mode (freeing allocator, reclaim OFF).
- `a3a7db4e` — **suspend/resume snapshot value ownership** (§7.5 / Phase 4):
  `FrameSnapshot` owns the regs/params/captures it copies on suspend
  (`retainSnapshotValues`); a resumed frame adopts that ownership
  (`Frame.owns_params_caps`) and releases on teardown; `SuspendState.deinit`
  releases the never-resumed path and frees snapshot buffers.
- `174ebf38` — **mutable List/Set store-retain** (add/insert/addAll/set retain;
  remove/clear/removeAll/retainAll release the discarded; index-removes
  transfer) **and the coroutine launch queue** (`enqueueLaunch` retains on
  enqueue, releases a drained block on completion — a suspended block keeps its
  ref until it resumes — and releases still-queued blocks on interceptor
  teardown).
- `f2ab5ecd` — **AtomicRef** `compareAndSet`/`getAndSet` own their stored value
  (retain the new; transfer the returned previous instead of `define`-releasing
  it and handing back freed memory).
- `8eeab3b7` — **receiver pinned across member-call dispatch**
  (`CallMember`/`CallMemberOrValue`/`CallSuper` retain the receiver and release
  after). A method borrows its receiver, but the dispatched body can drop every
  other reference to it before the call returns — the canonical case is
  `runBlocking`'s `joinBlocking` reading `this.failed` *after* the pump completes
  the job and the job tree releases the coroutine instance. Fixes single/small
  `async` and the general dangling-receiver class; raises the async-loop crash
  threshold from `n≥8` to `n≥10`.

### 0.2 What works under reclaim ON (`KLIO_RECLAIM=smp`), verified

- Simple / arithmetic / string-churn / `Pair` + destructuring.
- Mutable List / Set / Map loops with **reference-typed** elements (the prior
  collection tests only used `Int`s, which have no refcount, so the List/Set
  over-release stayed hidden).
- Data-class / instance loops; linked-node (`var next`) graphs.
- `runBlocking` with and without suspension; loops inside `runBlocking`.
- Plain `suspend fun` call chains.
- `delay` (real park → resume).
- `launch` (cooperative child coroutine).
- Single and small (`n ≤ 9`) `async { … }.await()` (was `n ≤ 5` before the
  receiver-retain `8eeab3b7`).

The full unit + itest suite is green under reclaim-ON `testing.allocator`
(leak-checked) except two PRE-EXISTING failures unrelated to reclamation
(`parity_coroutine_smoke.cs6`, a flaky Flow test; `parity_kotlinx_io_read.
read_line`, cross-test global-state pollution — both bisected to the
session-start commit).

### 0.3 What still corrupts under reclaim ON

- `async`/`await` **at scale** — deterministic threshold: `n ≤ 9` children OK,
  `n ≥ 10` over-releases the parent coroutine in the suspend/resume + job-tree
  machinery (fatal release in `resumeContinuation`'s `frame.deinit`). See §12,
  esp. §12.3a for the refined finding.
- `Dispatchers.Default` / the real worker pool: `scheduler.post` stores `block.*`
  cross-thread without cloning (`intrinsic_host.zig:817`), plus the same
  job-tree issue. The ktor server hits both at startup.

### 0.4 Measurements

- Simple/stdlib program RSS: **646 MB → 127 MB** (arena, after the §8 fix).
- ktor `GET` server, default arena: **~8.5 MB/request**, hits the 6 GB cap in
  ~700 requests. Per-request profile (30 requests via `KLIO_ALLOC_TRACK`):
  830 MB allocated / **556 MB explicitly freed** but retained by the arena /
  ~1.5 MB live growth per request.
- ktor `GET` server, `KLIO_RECLAIM=free`: **~1.75 MB/request** (≈5× better, no
  crash); residual is the ObjRef value graph (reclaim-OFF), which reclaim-ON
  would free once the job tree is reconciled.

### 0.5 Validation methodology / tooling (use these)

- **`KLIO_RECLAIM=smp`** on real programs is the corruption oracle (it aborts on
  the latent double-frees `DebugAllocator`'s quarantine hides). `0xaa…` faults
  are Zig's `undefined` poison reaching a reused/uninitialised cell.
- **`KLIO_RC_DETECT=1`** makes `ObjRef.deinit` leak the control block and dump a
  stack on a *second* decrement. NB: it still runs `T.deinit` at count 0, so it
  does **not** mask a missing-retain UAF (only true double-decrements).
- **Instance-free tracing**: a temporary `if (getenvSlice("…")) { print
  identity+class; dumpCurrentStackTrace }` at the top of `InstanceData.deinit`
  (`src/runtime/class.zig`) pinpoints which instance is freed and from where —
  the technique that found the launch-queue, AtomicRef, and job-tree frees.
  Pair it with a print of the dispatched method + receiver cell at
  `samInstanceDispatch` / `instanceBindingProbe` entry to identify the
  dispatched-after-free receiver.
- **`KLIO_ALLOC_TRACK=1`** (`src/runtime/alloc_track.zig`) reports total/live
  bytes + a size histogram + per-phase deltas; `runtime.pageAllocator()` is a
  page-alloc stack-tracing probe (route a suspect allocator through it to
  attribute large mmaps — this found the §8 bug).
- **DebugAllocator leaked-count diffed across two N** is the bounding oracle
  (`smp` max-RSS is non-deterministic — it returns OS pages unpredictably).
- The unit suite under `testing.allocator` (reclaim-ON, leak-checked) validates
  that a fix retains/releases in balance; run it after every ownership change.

### 0.6 Remaining work (ordered)

1. **Job-tree lock-free reclamation** (§12) — the last reclaim-ON corruption;
   unblocks `async` at scale and the ktor server under reclaim-ON.
2. **Cross-thread `scheduler.post`** block ownership (`Dispatchers.Default`).
3. **ktor server/client RSS flat over many requests** under reclaim-ON (follows
   from 1+2), validated with `zig build itest-ktor_server`.
4. **Flip production** (§7.8): drop `setReclaim(false)`, default to a freeing
   allocator (or the split arena+smp) once the corpus is clean under reclaim-ON.
5. **Optional**: further cut the ~127 MB baseline (lazy/compact stdlib decode in
   `image.zig`) and the resume-value / `scope_delta` retain audit
   (`token_resume_value`, `interceptSuspend` — currently fine because the tested
   resume values are primitives, but a real value would leak/corrupt).

---

## 1. Goal

- A long-running KLIO process (server, REPL, any loop) must reclaim memory for
  values that are no longer referenced, bounded for any duration.
- Match Kotlin/Rust semantics: "freed when no longer referenced" via the
  reference-counted value handles (`ObjRef`), exactly as the original Rust
  implementation got for free from `Drop`/`Clone`.
- Also reduce the ~670 MB startup baseline (separate problem; see §8).

## 2. Symptoms and measurements

Measured with a ReleaseFast build, a ktor server (`embeddedServer(Klio, port)`)
hit by HTTP requests:

- **Startup baseline ~670 MB** even for `fun main(){ println("hi") }`
  (kernel max-RSS via `/usr/bin/time -l`). Unchanged by `KLIO_STDLIB_IMAGE=0`,
  unchanged under a freeing allocator → genuinely *live* memory: the entire
  embedded stdlib (AST + lowered IR + registry) is loaded eagerly and kept
  resident. The 7.6 MB on-disk image expands ~88× in RAM.
- **Per-request growth ~1–19 MB**, ~153 K allocations/request (the 128 B size
  class dominates: interpreter `Value`s, coroutine frames, `ObjRef` cells).
  Two-thirds of those allocations are *logically* freed (a `deinit` is called)
  but the arena makes `free` a no-op, so nothing is returned.
- Linear growth until the **6 GB RSS watchdog** aborts the process
  (`src/runtime/safety.zig:38`, `DEFAULT_RSS_CAP_KB = 6*1024*1024`; override
  with `KLIO_RSS_CAP_KB`). The watchdog existing at all is a tell: the authors
  knew growth was a hazard.

(NOTE: §2 records the as-found symptoms. The ~670 MB baseline is FIXED — see §8
/ §0 — and the "per-request growth" and tooling below are superseded by the
current measurements in §0.4 and the committed tracker.)

Tooling built during investigation, now COMMITTED as `src/runtime/alloc_track.zig`
(`KLIO_ALLOC_TRACK=1`): an opt-in tracking allocator wrapping the arena that
prints total/live bytes, alloc/free counts, a power-of-two size histogram, and
named per-phase deltas; plus `runtime.pageAllocator()`, a page-alloc
stack-tracing probe (route a suspect allocator through it to attribute large
direct mmaps — this is what found the §8 bug).

## 3. Root cause

Three compounding facts:

1. **One process-lifetime arena, never reset.** `src/main.zig`:
   ```zig
   var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
   defer arena.deinit();
   return cli.run(arena.allocator(), init.args);
   ```
   Every allocation in the whole process — compile *and* runtime — goes here
   and is freed only at process exit.

2. **Reclamation is force-disabled in the run path.** `src/cli/commands.zig`
   calls `runtime.setReclaim(false)` in `runProgram`/`tryImagePath`/
   `runBuiltModule` (lines ~295, ~312, ~329). That flips `ObjRef.deinit` to its
   "arena fast path" (`src/runtime/objcell.zig:260`):
   ```zig
   pub fn deinit(self: Self) void {
       if (!reclaim_tls) return;   // skip refcount decrement + destroy
       ...
   }
   ```
   `reclaim_tls` defaults to `true` (`objcell.zig:58`); the run path turns it
   off. The justification in the code comment is that "the backing arena
   reclaims every cell wholesale on reset."

3. **That reset never happens for a long process.** The only arena teardown is
   the process-exit `defer arena.deinit()`. `src/interp_ir/vm/intrinsic_host.zig:92`
   documents this as a hard invariant: the coroutine worker pool *shares* the
   one arena, so resetting it mid-run while any worker is live is a cross-thread
   UAF. The "run-boundary arena reset" the design references
   (`src/interp_ir/vm/coroutines.zig:1825`) exists **only in a unit test** and
   in the e2e/parity harnesses (each short program runs in its own arena, reset
   between programs). The production `klio run` is one arena for the whole
   process.

**So: a batch program is fine (everything freed at exit). A server never
reaches a reset boundary, reclaim is off, and per-request garbage accumulates
forever.** The documented Arc-refcounting model (which *would* bound memory) is
the disabled path.

## 4. The documented model vs reality

`plans/STAGE8-PARALLEL-EXECUTION.md`: `Value = ObjRef<T> = Arc<AdaptiveCell>` —
reference counting; a cell frees when its strong count hits zero. In the Rust
original this happened automatically via `Drop` as frames/containers went out
of scope, so memory was reclaimed continuously, per-scope.

**Reality of the Zig port:** the refcount *counts* but the count-hits-zero path
frees almost nothing of the graph, because there is **no recursive teardown at
any level**. Verified bottom to top:

- `StringRef = ObjRef([]const u8)` (`src/runtime/value.zig:27`): at count zero,
  `ObjRef.deinit` frees the control block but **not the string bytes**
  (`[]const u8` has no `deinit`, so `deinitData` is never called for it). Worse,
  `StringRef` byte ownership is **ambiguous**: some `StringRef.init` sites pass
  interned/borrowed module-const bytes (must NOT free), others pass owned concat
  buffers (must free). ~100 `StringRef.init` call sites.
- `ValueList = ObjRef(std.ArrayList(Value))` (`value.zig:29`): release frees the
  array buffer but **never releases the element `Value`s** (`std.ArrayList`'s
  `deinit` frees the buffer only).
- `InstanceData` had **no `deinit`** — releasing an instance never released its
  fields. (Fixed; see §5.)
- `Frame.deinit` (`src/ir/eval.zig:496`) frees the register *arrays* but
  **never releases the register `Value`s**; `Frame.write` overwrites without
  releasing the old occupant.
- **Stores don't retain**: `InstanceData.set/define`, `StoreGlobal`, collection
  mutators store the handle without `clone()`.
- Some variants hold **raw owning `*Value` pointers** that *alias* when a
  `Value` is copied (`Pair`/`Triple`/`MapEntry`/`Result`/`Exception.cause`/
  `BoundMethod.receiver`) — they cannot be refcount-released without
  restructuring (convert to `ObjRef`).

The unit tests pass under reclaim-ON + the leak-checking `testing.allocator`
because they almost exclusively use primitive `Int` values (no refcounted cells
to leak). So "the tests are green" did not mean the discipline worked.

`ObjRef` API of note (`src/runtime/objcell.zig`): `init` (count 1), `clone`
(count++), `deinit` (count--, runs `T.deinit` via `deinitData` at zero — this is
the **only** concurrency-safe place to recurse, since exactly one thread zeroes
the count), `borrow`/`borrowMut` (RW lock, *not* a refcount op), `strongCount`,
`identity`, `ptrEq`.

## 5. Committed foundation (done)

Three commits, all additive and inert in production (they only execute when a
handle is actually released, which the reclaim-off run path never does):

- `ada8fcdb` — **fix a real arena-masked double-free** in the `Call` dispatch
  (`src/ir/eval.zig`, named-overload prepend path): `arg_values`/`names` were
  reassigned to freshly-allocated prepended buffers *and* tracked in separate
  `prepended`/`prepended_names` locals, so both the `arg_values`/`names` defer
  and the `prepended` defer freed the same buffer (the original `readArgRun`
  buffers leaked). Correct in both arena and freeing modes.
- `ba6bec4b` — **`Value.retain`/`release`/`deinit` + `InstanceData.deinit`**.
  `retain`/`release` clone/drop every refcounted handle a value holds; no-ops
  for primitives, the immutable `Class` graph, and the not-yet-refcounted
  owning-`*Value` variants. `InstanceData.deinit` releases field values, the
  captured `outer`, and the instance's class clone, then frees the field list.
  Validated by `src/runtime/class.zig` test "instance release recursively frees
  a retained instance field".
- `58266139` — **recursive release of container elements** (List/Set/Array/Map/
  Iterator/IrClosure). `Value.release` releases the elements when it drops the
  last owning handle to the backing store, using a **`strongCount() == 1`
  guard** (helpers `releaseValueList`/`releaseSliceElems` in `value.zig`):
  ```zig
  fn releaseValueList(items: ValueList, allocator) void {
      if (items.strongCount() == 1) {            // we hold the only handle —
          const g = items.borrow();              // no other thread can clone it,
          for (g.get().items) |e| e.release(...); // so the element walk is race-free
          g.deinit();
      }
      items.deinit();
  }
  ```
  Validated by test "list release recursively frees retained instance elements".

**Key insight (keep it):** `strongCount() == 1` means this thread holds the
*only* handle, so no other thread can be concurrently cloning it (it would need
a handle). That makes a `strongCount==1`-guarded recursive walk race-free
without wrapping every container payload type (which would be massive churn —
every `.get().items` access site). Use this pattern instead of wrapping.

## 6. What was attempted and PROVEN not to work (do not repeat)

Wiring frame-register reclamation directly in the runtime — `Frame.write`
releases the overwritten slot, `Frame.deinit` releases all registers, `Move`/
`MakeCell`/`LoadParam`/`LoadCapture`/`CellGet` retain their copies, the return
value is retained before teardown, suspension suppresses register release — and
gating it all on `runtime.reclaimEnabled()`.

Result: **crashes even trivial programs** under reclaim-ON (`val s = "a"+"b"`,
an int loop) — segfault at `0xaaaaaaaaaaaaaaaa` (DebugAllocator poison) inside
`releaseValueList`, i.e. releasing a register that holds a List whose elements
were stored **without retain** and already freed elsewhere.

Why it's a dead end: it is **all-or-nothing**. Every value-touching instruction
and every container store (IR *and* host-side, e.g. vararg arrays, arg arrays,
`prependReceiver`) has its own move-vs-borrow-vs-own semantics. Unless *all* of
them are simultaneously correct, releasing a register frees a value something
else still aliases → UAF. There is no way to validate it incrementally because
any gap corrupts basic execution. The runtime cannot cheaply know, at a given
`frame.write`/read, whether a value is a fresh produce (move), a register copy
(retain), or a borrow.

This attempt was **reverted** (`src/ir/eval.zig` restored to `HEAD`). The
committed foundation (§5) is untouched and correct.

## 7. The plan: activate reclamation (the ownership contract)

### 7.-1 DEFINITIVE FINDING (validated with a freeing allocator)

The committed value-model foundation below (StringRef byte ownership, `ValueBox`
refcounting, retain-gating, the `KLIO_RECLAIM` oracle) is **done, green, and
stable** under a real freeing allocator: `KLIO_RECLAIM=smp ./klio run x.kt`
runs every program correctly (it leaks, because no register reclamation is
active, but never corrupts). Per-module leak-checked tests pass under reclaim-on.

Activating register reclamation (the eval `Frame.deinit` releasing registers +
per-handler retains, equivalently the §7 IR `Drop` emission) was implemented and
**proven to corrupt even `fun main() {}`** under `KLIO_RECLAIM=smp`. Root cause,
now established with hard evidence:

- The interpreter **host** (`src/interp_ir/vm/*`, `src/stdlib/*`, ~600 KB) was
  written for the arena model: it copies `Value`s — and the refcounted
  sub-handles inside them (`ValueList`/`MapEntries`/`StringRef`/`ObjRef`) —
  **bitwise, without cloning**, all over: building an `Iterator` that shares a
  collection's `items` cell, packing a vararg `Array`, returning an arg/element/
  field/receiver borrow, sharing a backing store between a view and its source.
  Under the arena none of this mattered (nothing was ever freed). The moment a
  register release decrements one of those shared handles, the other aliases
  dangle → use-after-free / double-free. `DebugAllocator` quarantine *masks*
  some of these (the run appears to "pass"); `smp_allocator` aborts on them,
  which is why `fun main(){}` aborts under smp but looked clean under debug.
- This is exactly the §6 "all-or-nothing" wall, now **confirmed independently**.
  It is **not** specific to the runtime-`Frame.deinit` mechanism: the §7 IR
  `Retain`/`Drop` route hits the identical wall, because dropping a Call-result
  register requires the host to have returned an owned value, and dropping any
  register requires every container the value flows into to own (clone) its
  copy. The register mechanism is interchangeable; the **prerequisite is the
  host reconciliation**, and it is the whole job.

**The required (large) prerequisite — host ownership reconciliation.** Before any
register reclamation can be turned on, every host site must obey one rule:
*a refcounted handle copied into a separately-owned or longer-lived location
must be cloned; a borrowed value returned to the interpreter must be retained
(host-returns-owned); a container/field/global/cell store must retain its
element and release the value it overwrote.* Concretely audit, in
`src/interp_ir/vm/*` and `src/stdlib/*`:
1. **clone-on-share**: every `Value.Iterator`/view/derived-value construction
   that reuses another value's `items`/`entries`/backing `ObjRef` must
   `.clone()` it (e.g. `iterator()` on a List/Array, map key/value/entry views,
   `withIndex`, the vararg `Array` packer in `host_call_func.zig`).
2. **host-returns-owned**: accessors returning a borrowed element/field/receiver
   (`get`/`first`/`last`/`[]`/`getValue`/`component1..3`/`iterator.next`/
   `getField`/global reads/`apply`/`also`) `retain()` before returning.
3. **stores-retain + release-old**: collection `add`/`put`/`set`/build, instance
   `set`/`define`/primary-ctor init, `StoreGlobal`, `CellSet`, closure capture
   build (`host_call_value.zig` `buildClosure`), `InstanceData.set`.

Validation must use `KLIO_RECLAIM=smp` on real programs (it aborts on the latent
double-frees that `DebugAllocator` quarantine hides). Per-module leak tests are
necessary but **not sufficient** — they exercise host intrinsics in isolation,
not the Kotlin-source stdlib functions (`apply`, `forEachIndexed`, …) that run
through the evaluator and where the sharing bugs actually bite.

The eval register-balance edits (`Frame.write` release-old, `Frame.deinit`
release-regs, alias-handler retains, terminator retains for escaping
return/throw values, the suspend/resume snapshot retain/release) were written
and validated to *bound* a pure-string loop (`leak_strings`: RSS identical at
N=300 and N=300000), then reverted because they corrupt under the unreconciled
host. They are the correct activation; re-land them only after the host
reconciliation above is complete and `smp` runs the corpus clean.

### 7.-0.5 SECOND CRITICAL FINDING: two independent leak classes

Activating reclamation surfaced **two** distinct memory problems, not one:

1. **Value-graph ownership** (the refcounting). Fixed incrementally and working:
   under `KLIO_RECLAIM=smp` (a real freeing allocator), `fun main(){}`,
   string-churn loops, `Pair`/destructuring, mutable list/map loops, and
   data-class/instance loops all run **double-free-clean** and **bounded**
   (RSS flat across 2000→2,000,000 iterations). The fixes: alias-handler/
   accessor/escaping-return retains in eval (`Frame` owns its registers,
   releases on overwrite + teardown), `IrClosure` release double-deinit fix,
   closure-capture retain, collection map-put retain + release-old,
   instance-ctor field retain + `InstanceData.define` adopt+release-old.

2. **Host temporary allocations relying on the arena** (the Rust→Zig port
   dropped explicit frees). Pervasive: every host path that `allocPrint`s a
   probe FQN, builds an arg/`prependReceiver` array, or a scratch `ArrayList`
   and lets the arena reclaim it **leaks per call** under a freeing allocator —
   independent of Value refcounting. Freeing the member-dispatch scratch
   (`stdlibMemberDispatch` probe FQNs, sibling anchor, array-builder probe,
   prepended args) halved the per-iteration leak of a combined instance+map
   loop. The remainder is the same class in other host paths.

**Implication for §7.8.** "One freeing allocator for everything" is *not* free:
it requires restoring explicit deallocation of every host temporary the port
dropped — a large audit on top of Value refcounting. The leak classes split by
workload, which points at the most practical decomposition of the goal:
- **Simple programs / stdlib usage are batch**: they exit, so the arena already
  bounds them for the run. Their only "high usage" is the **§8 startup baseline
  (~670 MB)** — fix that (lazy/compact stdlib), not reclamation.
- **A long-running ktor server/client** is the case that needs continuous
  reclamation. Either finish the host-temp + Value reconciliation under a
  freeing allocator, **or** reset a per-request/run-boundary arena when a
  request's coroutines complete (reclaims temps *and* values without the
  full temp-free audit; the run-boundary reset already exists for the test
  harness — `coroutines.zig`). The per-request-arena route trades the temp-free
  audit for coroutine-lifetime/escape bookkeeping.

Diagnostic added: `KLIO_RC_DETECT=1` makes `ObjRef.deinit` leak freed cells and
dump the stack on a double-free (DebugAllocator quarantine masks these; smp
crashes downstream) — used to pinpoint each value-ownership bug.

**Leak-validation methodology correction.** `smp_allocator` max-RSS is
**non-deterministic** (it retains/releases OS pages unpredictably — observed
RSS at N=1,000,000 *below* N=500,000 for the same program), so RSS slope is
NOT a reliable leak oracle. The reliable oracle is the **DebugAllocator leaked-
allocation count** diffed across two N (`(count(N₂)−count(N₁))/(N₂−N₁)` =
true allocs leaked per iteration), filtering the one-time stdlib-image/module
baseline (`image.zig`/`build.zig`/`ir.zig` sites are loaded once and resident).
Use this, not smp RSS, to confirm bounding.

**Workload split observed in practice.** Light-stdlib loops (pure strings,
isolated lists/maps/instances) load a small resident baseline and are fully
bounded under reclaim. A program that *combines* features (data class + string-
keyed map + method dispatch) loads the full stdlib (~670 MB baseline) and its
member-dispatch path allocates ~tens of per-call scratch objects (probes, arg
arrays, candidate/type-resolution temps) — the host-temp class — most of which
the port never frees. That is the bulk of the remaining per-iteration leak and
is pervasive across the heavy dispatch path.

**Recommended pragmatic path to the goal** (given the host-temp audit is huge):
1. **§8 lazy/compact stdlib** — fixes the ~670 MB baseline that is the only
   "high usage" for *batch* simple/stdlib programs (they exit, so the arena
   already bounds their per-run allocation).
2. **Per-request/run-boundary arena reset for the ktor server** — reclaims
   temps *and* values per request without the full host-temp-free audit; the
   reset already exists for the test harness. Trades the temp audit for
   coroutine-lifetime/escape bookkeeping.
The value refcounting committed here is complementary (it bounds the value
graph for any path and is required for anything that escapes a reset boundary).

**§8 confirmed uniform (~646 MB) under the production arena.** Measured: every
program — `fun main(){ val x=1+2 }`, `println("hi")`, a `listOf`, a string concat
— is ~646 MB resident under the arena (the embedded stdlib AST+IR+registry is
deserialized in full at startup by `image.zig:load`→`moduleFromImage`, eager and
uniform; the 7.6 MB on-disk image expands ~88×). This is the dominant "high
usage for simple programs" and is independent of reclamation. Reducing it needs
lazy/on-demand decl deserialization in `image.zig` (decode a func/class on first
lookup) or a more compact in-memory node representation — a focused workstream in
that module.

### Continuation roadmap (each a focused increment)
1. **Split allocator** (the enabler): a process-arena for the persistent compile/
   stdlib graph (the §8 baseline, genuinely resident) + a freeing allocator for
   runtime values/temps. `ObjRef` already carries its own allocator, so the two
   free correctly when mixed, and persistent→runtime references don't occur.
   This makes the DebugAllocator leak report show *only* runtime allocations
   (fast, clean — no 200 K stdlib-baseline noise), which makes the host-temp
   audit tractable, and it is the §7.8 production shape.
2. **Finish host-temp + value reconciliation** under the split's clean oracle
   until a heavy-stdlib loop and a never-returning loop are bounded (DebugAllocator
   per-iter leak count → 0).
3. **Re-apply + validate coroutine suspend/resume ownership** (Phase 4: snapshot
   retain on suspend, retain-into-frame + release/free snapshot on resume).
4. **Ktor server**: per-request/run-boundary arena reset when a request's
   coroutines complete (or rely on the completed reconciliation). Validate with
   `zig build itest-ktor_server` under a freeing allocator, RSS flat over many
   requests.
5. **§8 lazy/compact stdlib** to cut the ~646 MB baseline.
6. **Flip production** (§7.8): drop `setReclaim(false)`, switch `main.zig` to the
   split (arena + smp), verify server/client RSS flat.

Follow-up (quality): the member dispatch-miss now returns a static sentinel; a
genuine "no such member" error should be re-tagged with `name`+receiver-type
context at the dispatch top (`callMemberNamed` final return) so diagnostics keep
the specifics without a per-call allocation.

### 7.0 Revised approach (decided after a full subsystem re-audit)

A complete re-audit of the IR, lowering, evaluator, host, and coroutine
subsystems revised the premise behind the §6 "runtime reclamation is
all-or-nothing" conclusion. That attempt crashed **because the host/container
stores did not retain their elements** (the §7.3 prerequisite), so dropping a
register that held a container double-freed elements other registers still
aliased. That prerequisite is required *identically* by the IR-`Retain`/`Drop`
pass and by per-handler ownership — neither escapes it. The decisive realization:
ownership at a given instruction is **statically known by its handler**
(`LoadParam` always aliases a param slot, `NewList` always mints, `Move` always
copies). That is not the "guess at `frame.write`/`read`" dead end of §6; it is
correct-by-construction at the handler granularity, and it handles the hard
cases (exception edges, suspension, `var`-home re-defs, phi joins, inlining)
without a CFG liveness analysis.

**The ownership contract (the model now being implemented):**

- A **register owns exactly one strong reference** to the refcounted value it
  holds. `Frame.read` is a borrow (no count change). `Frame.write` releases the
  previous occupant, then stores (retain-new-before-release-old on the handler
  side).
- **Producers**: *mint* handlers (`Const` string, `BinOp` concat, `NewList`,
  `MakeCell`, every host `Call`/`NewInstance` result) leave the dest owning the
  one fresh ref — no retain. *alias* handlers (`Move`, `CellGet`, `LoadParam`,
  `LoadCapture`, `GetField`, `LoadGlobal`, `Index`, `Cast`, `NotNullAssert`,
  `QualifiedThis`, `MemberRef`, …) copy a value owned elsewhere — they `retain`
  so the dest owns its own ref.
- **Host-returns-owned contract**: every host function returns a value the
  caller solely owns. Mints return as-is; accessors that return a borrowed
  field/element/capture `retain` before returning.
- **Stores retain**: every store into a container / field / global / cell /
  capture slice `retain`s the element (the container owns its own ref) and
  releases the value it overwrote.
- **Frame teardown** releases the frame's regs, params, and captures. The return
  (and escaping throw / non-local-return) value is retained out before teardown.
- **Suspension**: the snapshot retains the regs/params/captures it copies; resume
  retains into the rebuilt frame and releases+frees the consumed snapshot.
- **Value model**: `StringRef` owns its bytes (init dupes; release frees);
  the owning-`*Value` variants become `ObjRef`-backed so copies share by
  refcount.

**Everything is gated on `runtime.reclaimEnabled()`.** With reclaim off (today's
production = arena + `setReclaim(false)`) the data model and behavior are
byte-for-byte unchanged. With reclaim on (unit tests under `testing.allocator`,
and the new checked/measured binary) the whole contract activates and is
leak-/UAF-checked. The §7.8 flip removes `setReclaim(false)` and switches the
process allocator to a freeing one. The IR `Retain`/`Drop` instructions of the
original §7.1/§7.2 are **not required** by this model and are not being added;
if validation ever shows growth the handler model cannot bound (a single
never-returning frame that accumulates without overwrite), a liveness `Drop`
pass can be layered on later.

### Original §7.1/§7.2 sketch (superseded by 7.0; kept for reference)

Stop guessing ownership at runtime. Make the **lowering** emit explicit
ownership instructions, because the lowering generated the IR and knows the
exact value flow:

1. **Add two IR instructions** in `src/ir/ir.zig`: `Retain { reg }` and
   `Drop { reg }`. Runtime handlers in `src/ir/eval.zig`: `Retain` =
   `frame.read(reg).retain()`; `Drop` = `frame.read(reg).release(allocator)`
   then write `.Unit` to the slot (so a later `Drop`/teardown can't double-free
   it). Gate execution on `runtime.reclaimEnabled()` so production is unchanged.

2. **Liveness / ownership pass in the lowering** (`src/ir/lower/`): for each
   lowered `Func`, compute per-register last-use within the control-flow graph
   and emit:
   - `Drop reg` at a register's last use / block/scope exit when its value is
     dead (not returned, not stored, not still live on another path).
   - `Retain reg` where a value is *shared* — stored into a container
     (`SetField`/`StoreGlobal`/collection add), captured into a closure,
     returned, or copied to a second still-live register (`Move`).
   Model registers as owning exactly one reference; reads are borrows; the pass
   inserts the retains/drops that keep the count balanced. Because the pass
   emits a *complete, consistent* set, partial progress does not corrupt — a
   function either has its drops/retains or it doesn't, and you can roll the
   pass out function-class by function-class, validating each.

3. **Container stores must retain at the IR boundary too.** The store
   instructions (`SetField`, `StoreGlobal`, collection mutators) take a value
   from a register; the pass emits `Retain` so the container owns its own
   reference (and the store handler releases the overwritten value). Host-side
   constructors that build collections/arrays from `Value`s (vararg arrays,
   `prependReceiver`, `listOf`, map building) must `retain` each element they
   store — audit `src/interp_ir/vm/*` for `ObjRef(std.ArrayList(Value)).init`
   and `.append` of `Value`s.

4. **Frame teardown** then only needs to `Drop` whatever registers the pass
   didn't already drop (or: rely entirely on emitted `Drop`s and keep
   `Frame.deinit` releasing nothing — cleaner, since the pass is authoritative).
   Prefer emitted drops; avoid the runtime-guessing `Frame.deinit` release that
   failed in §6.

5. **Coroutine suspension**: when a frame suspends, its registers are
   snapshotted into the `SuspendState` for resume, which takes over ownership.
   The drop pass must not emit drops that run on the suspend unwind for
   still-live registers; the snapshot/resume path must `retain` what it keeps
   and `release`/`Drop` it when the coroutine completes. This is the subtlest
   part — see `src/ir/eval.zig` `EvalError.Suspended` and the
   `runFrame`/`resumeContinuation` paths, and `src/interp_ir/vm/coroutines.zig`.

6. **Owning-`*Value` variants** (`Pair`/`Triple`/`MapEntry`/`Result`/
   `Exception.cause`/`BoundMethod.receiver`): convert these to `ObjRef`-backed
   payloads so copies share-by-refcount instead of aliasing raw pointers. Until
   then `retain`/`release` treat them as no-ops (they leak but don't corrupt) —
   see the `else => {}` arms in `Value.retain`/`release`.

7. **`StringRef` bytes**: make `StringRef` uniformly own its bytes so release
   can free them. Lowest-risk approach: `StringRef.init` always dupes (so every
   `StringRef` owns a private copy) and `Value.release` frees the bytes under a
   `strongCount()==1` guard; then audit owned-buffer `init` sites to free their
   original buffer (a missed site *leaks*, never corrupts — the safe failure
   mode). The alternative (take-ownership init) corrupts on any missed
   borrowed-bytes site, so prefer always-dupe.

8. **Flip production** only when the corpus is clean under reclaim-ON: drop the
   `setReclaim(false)` calls in `src/cli/commands.zig` and switch `src/main.zig`
   to a real freeing allocator (`std.heap.smp_allocator` for production;
   `DebugAllocator(.{thread_safe,safety})` for the checked build). Keep the
   process arena only for genuinely process-lifetime data if a split is worth
   it; otherwise one freeing allocator for everything (Rust's model) is fine —
   persistent data stays resident because it stays referenced.

## 8. Startup baseline — ROOT-CAUSED AND FIXED (646 MB → 127 MB)

The ~646 MB uniform baseline was **not** the stdlib graph itself (that is only
~100 MB live). It was a single allocator-misuse bug, found by instrumentation
(`src/runtime/alloc_track.zig`, `KLIO_ALLOC_TRACK` / the `pageAllocator` probe):

`src/stdlib/generated/mod.zig` `decodeSymbols` deserialised the embedded symbol
index (`symbols.postcard`, ~33 K small strings/records ≈ the stdlib decl count)
straight into **`std.heap.page_allocator`**. That allocator mmaps **one whole
page per allocation** (16 KB minimum on macOS arm64), so ~33 K tiny decode
allocations consumed ~535 MB resident — a few MB of real data inflated ~250×.
(vmmap coalesced the adjacent pages into ~4781 × 112 KB regions, which is what
made it look like a per-decl structure.)

**Fix:** decode into a process-lifetime `ArenaAllocator` (bump-allocated into a
handful of large chunks, intentionally never freed — the slices live for the
process), instead of page-granular `page_allocator`. Result: every simple /
stdlib program drops from ~646 MB to **~127 MB** RSS (the genuine live stdlib
graph), output unchanged, no other behavior change. The diagnostic
`alloc_track` module (arena byte/size-histogram tracking via `KLIO_ALLOC_TRACK`,
plus a `pageAllocator` stack-tracing probe for attributing large mmaps) is kept
as committed tooling.

`std.heap.page_allocator` used for many small allocations is a latent footgun
anywhere in the codebase; `decodeSymbols` was the only bulk offender (every
other `pack.*.decode` site already threads a real `gpa`/arena). Further baseline
reduction (the remaining ~127 MB) would need lazy/on-demand decl
deserialisation in `image.zig` or a more compact in-memory node representation —
optional; 127 MB for a fully-loaded stdlib is acceptable.

## 9. Validation methodology (oracles)

- **Leak scaling oracle (fast, no server):** run a looping program under
  reclaim-ON + a checking allocator, compare leaked-allocation count at small
  vs large N. Before activation, string-churn loops leak ~30 allocs/iteration;
  the target is ~0 growth with N.
  ```
  fun main() { var x=0; for (i in 0 until 500) { val s = "item-"+i; x += s.length }; println(x) }
  ```
- **Corruption oracle:** build with reclaim-ON and
  `DebugAllocator(.{ .thread_safe=true, .safety=true })` in `src/main.zig`, plus
  `setReclaim(true)` in `commands.zig`. `safety=true` quarantines freed memory
  so a use-after-free reads poison (`0xaa…`) at the offending site; double-frees
  are reported with alloc/first-free/second-free traces. ReleaseSafe builds give
  usable panic traces; Debug builds give full DebugAllocator stack traces (but
  are slow — startup can be many seconds). For a worker-thread crash that won't
  flush, run the serve loop on the main thread (`start(wait = true)`) and/or use
  `lldb -b -o run -o "thread backtrace" -o quit -- ./zig-out/bin/klio run ...`.
- **Pitfalls observed:** under `DebugAllocator(safety)` the freed-then-poisoned
  data made ktor responses come back empty — a *red herring*; under `smp`/normal
  allocators the same program returned correct data. Always cross-check a
  symptom against a normal freeing allocator before chasing it. `smp_allocator`
  crashes on the latent double-frees where `DebugAllocator` reports-and-
  continues, so use DebugAllocator to *find* bugs and smp to *measure* slope.
- **Unit suite:** `zig build test` runs with `testing.allocator` (leak-checking)
  under reclaim default-ON, so it catches double-frees/leaks — but only in
  Zig-level paths; it under-covers full-program value flow (mostly `Int`s). Add
  targeted leak-checked tests next to each new teardown (see the two in
  `class.zig`). Per-module: `python3 scripts/zigcheck.py <module>`.
- **End-to-end:** `zig build itest-ktor_server` (spawns a real klio server,
  drives HTTP, asserts bodies) — build the server binary with reclaim-ON +
  DebugAllocator to exercise the request path under the checker.

## 10. Key files and locations

- `src/main.zig` — process allocator (the arena).
- `src/cli/commands.zig` — `setReclaim(false)` at ~295/312/329 (the run path).
- `src/runtime/objcell.zig` — `ObjRef`: `reclaim_tls` (58), `clone` (244),
  `deinit`/arena fast path (260), `deinitData` (282), `strongCount` (331).
- `src/runtime/value.zig` — `Value` union (256), aliases (`StringRef` 27,
  `ValueList` 29, `ValueSlice` 31, `MapEntries` 35), and the committed
  `retain`/`release`/`deinit` + `releaseValueList`/`releaseSliceElems`.
- `src/runtime/class.zig` — `InstanceData` (269), committed `deinit`, and the
  two leak-checked teardown tests.
- `src/ir/eval.zig` — `EvalError` (82), `Frame` (386), `newWithCaptures` (419),
  `deinit` (496), `write` (509), `Move` (1190), `CellGet` (1249), `LoadParam`
  (1447), `GetField` (1463), `LoadGlobal` (1977), `LoadCapture` (2004),
  `evalWithCapturesChained` return path (~648–670). This is the runtime
  evaluator used by `interp_ir` (`src/interp_ir/vm/run.zig` calls
  `ir.eval.evalWith*`).
- `src/ir/lower/` — the lowering (where the `Retain`/`Drop` liveness pass goes).
- `src/interp_ir/vm/intrinsic_host.zig:92` — the shared-arena/no-mid-run-reset
  invariant.
- `src/interp_ir/vm/coroutines.zig` — suspension/resume; run-boundary reset
  (test only).
- `src/runtime/safety.zig:38` — 6 GB RSS watchdog.

## 11. Status

- [x] Root cause established (arena-everything + reclaim-off + no recursive
      teardown).
- [x] Real arena-masked double-free fixed (`ada8fcdb`).
- [x] Value-graph teardown foundation: `retain`/`release`/`deinit`,
      `InstanceData.deinit`, container element release — committed, leak-checked,
      inert in production (`ba6bec4b`, `58266139`).
- [x] Proven that runtime-guessing frame reclamation is all-or-nothing and
      corrupts trivial programs — reverted.
- [x] Checked/measured binary path: env-gated freeing allocator + reclaim-ON
      (`KLIO_RECLAIM={smp,debug}`) (§9 oracles). Committed.
- [x] `StringRef` owns+frees its bytes (§7.7). Committed, leak-clean.
- [x] Convert owning-`*Value` variants to `ObjRef`/`ValueBox` (§7.6). Committed,
      leak-clean.
- [x] DEFINITIVELY established (§7.-1): register reclamation corrupts trivial
      programs under a freeing allocator until the **host ownership
      reconciliation** is complete; this prerequisite is identical for the
      `Frame.deinit` route and the §7 IR `Drop` route. Foundation is green &
      stable under `smp` (leaks, never corrupts).
- [x] **eval register balance + value-graph reconciliation LANDED & WORKING**
      (committed): under `KLIO_RECLAIM=smp`, simple / string-churn / Pair /
      mutable-collection / data-class-instance programs run double-free-clean.
      `Frame` owns/releases its registers; alias/accessor/escaping-return
      retains; closure-capture + collection-store + instance-field retains;
      `IrClosure` release double-deinit fixed. No suite regressions — the 2
      itest failures (`parity_coroutine_smoke.cs6`, `parity_kotlinx_io_read.
      read_line`) are PRE-EXISTING at session-start (a flaky Flow/concurrency
      test and a cross-test global-state pollution), orthogonal to reclamation;
      all reclaim changes are gated no-ops under the arena those tests use.
- [ ] **Host-temporary reconciliation (the remaining large work)**: free the
      per-call host scratch the port never freed (probes, arg arrays, dispatch
      temps) — pervasive across `src/interp_ir/vm/*`/`src/stdlib/*`; gate every
      free on `reclaimEnabled()` (arena `free` rewinds the last alloc). Or use a
      per-request arena for the ktor server (reclaims temps+values without the
      audit). Validate with the DebugAllocator leaked-count diffed across N
      (smp RSS is non-deterministic).
- [x] **Coroutine suspend/resume snapshot ownership re-applied (§7.5)** —
      eval-side, committed, gated (production byte-identical, no suite
      regressions). `FrameSnapshot` now *owns* the regs/params/captures it
      copies on suspend (`retainSnapshotValues`); a resumed frame adopts that
      ownership (`Frame.owns_params_caps`) and releases it on teardown;
      `SuspendState.deinit` releases the never-resumed (cancelled/abandoned)
      path. This is the correct foundation but is NOT sufficient alone — see
      the coroutine-host finding below.
- [~] **Coroutine host value reconciliation — largely landed.** Several
      store-retain / host-returns-owned gaps fixed (all gated, suite-green):
      - **Mutable List/Set** mutators stored elements without retaining while
        teardown released them (over-release for reference elements; Int-element
        tests missed it). add/insert/addAll/set retain; remove/clear/removeAll
        release; index-removes transfer.
      - **Coroutine launch queue** (`enqueueLaunch`, the `__kxco_spawn` seam)
        appended blocks without retaining → a dispatched continuation wrapper was
        freed when its dispatching frame returned. Now retain-on-enqueue,
        release-on-completion (a suspended block keeps its ref until it resumes).
      - **AtomicRef** `compareAndSet`/`getAndSet` stored without retaining (and
        `getAndSet` returned a value it had just `define`-released). Now own the
        stored value; transfer the returned previous.
      - **Suspend/resume snapshot ownership** (§7.5, the Phase-4 foundation).

      Result under `KLIO_RECLAIM=smp`: `runBlocking` (with/without suspension),
      loops, suspend funcs, `delay`, and `launch` all run correct & UAF-clean.
      **Remaining: `async`/`await` (structured-concurrency job tree).** A
      completion handler node is read during job-completion notify and
      dispatched (`afterCompletion`) after being released — the lock-free linked
      list (`LockFreeLinkedList`) + Job state machine, where node reclamation and
      refcounting interleave. This is the hard remaining frontier (lock-free
      reclamation), and it is what the ktor server hits at startup. Until it
      lands, the safe server option is `KLIO_RECLAIM=free`.
- [ ] **ktor server/client RSS flat over many requests.** Measured (with the §8
      fix): under the default arena a ktor `GET` server grows ~8.5 MB/request
      (mostly transients the run path *explicitly frees* — 556 MB freed / 830 MB
      allocated over 30 requests — that the arena cannot return) and hits the
      6 GB cap in ~700 requests. Under `KLIO_RECLAIM=free` the per-request growth
      drops ~5× to ~1.75 MB/request (no crash; the residual is the ObjRef value
      graph, which reclaim-ON would free but currently corrupts — see above).
      Full bounding needs either the coroutine-host reconciliation (then
      reclaim-ON) or a per-request/run-boundary arena reset for the server.
- [x] **Startup baseline ROOT-CAUSED + FIXED (§8): 646 MB → 127 MB.** The
      baseline was `decodeSymbols` deserialising the symbol index into the
      page-granular `page_allocator` (~33 K tiny allocs × 16 KB page = ~535 MB);
      decoding into a process-lifetime arena removed it. Diagnostic tooling
      (`src/runtime/alloc_track.zig`, `KLIO_ALLOC_TRACK`) committed.
- [ ] Flip production to reclaim-ON + (split) freeing allocator (§7.8).

## 12. The remaining frontier: structured-concurrency job-tree reclamation

This is the one reclaim-ON corruption left after §0.1, and the blocker for the
ktor server under reclaim-ON.

### 12.1 Reproducer and signature

```kotlin
import kotlinx.coroutines.*
fun main() { runBlocking { var s = 0; for (i in 1..N) { val d = async { i*2 }; s += d.await() }; println(s) } }
```
- `KLIO_RECLAIM=smp`: **`N ≤ 5` succeeds, `N ≥ 8` faults** (deterministic
  threshold, not a race — small async loops and a single `async` are clean).
- `async(Dispatchers.Default){…}` faults at any N (also exercises the
  cross-thread `scheduler.post` gap).
- The fault is a use-after-free: `samInstanceDispatch` /
  `instanceBindingProbe` dispatches a method (`afterCompletion`, `equals`) on a
  released instance — under plain `smp` it surfaces downstream as
  `incorrect alignment` in `SmpAllocator` (free-list corruption from the earlier
  double-free); under `KLIO_RC_DETECT=1` it surfaces as the raw `0xaa…` read.

### 12.2 What is freed

Instrumenting `InstanceData.deinit` (§0.5) shows the released classes are the
Job machinery: `ChildHandleNode`, `Removed` (LockFreeLinkedList sentinel),
`NonDisposableHandle`, `KlioBlockingCoroutine`, `JobSupport$Finishing`, plus
many `AtomicRef`. The dispatched-after-free receiver is a job **completion
handler node** invoked via `afterCompletion` during the parent job's
completion-notify.

### 12.3 Where to look

- `kotlin-klio/klio-kotlinx-coroutines/klioMain/kotlinx/coroutines/internal/
  LockFreeLinkedList.kt` — `forEach` (the notify traversal), `addLast`,
  `removeOrNext`, `correctPrev`, the `Removed` sentinel. Each `_next`/`_prev` is
  an atomicfu `atomic<Any>` (an `AtomicRef` instance — so it flows through the
  now-fixed `atomicRefCas` / the `value` getField/setField, which DO retain).
- Upstream `JobSupport` completion path (`notifyCompletion` / the handler-list
  promotion Empty → single node → `NodeList`).
- `nextNode` getter reads `_next.value` via `getField` (retains, §GetField), and
  the `forEach` `cur` variable owns each node — so a *naive* traversal should
  keep nodes alive. The corruption is subtler: a node's refcount reaching zero
  while a register/`cur`/handler still aliases it, i.e. one release without a
  matching retain somewhere in the add/remove/correctPrev/notify interleaving,
  *or* the AtomicRef-CAS `release-old` dropping a link's ref to a node that is
  still logically in the list during a repair (`correctPrev`) rather than a
  removal. The `release-old` is correct for an *ownership-transfer* CAS but the
  lock-free list also CASes for pointer *repair*, where the old value is not
  being given up — that asymmetry is the prime suspect.

### 12.3a Refined finding (this session)

The over-release is now pinned to the **parent coroutine** (`runBlocking`'s
`KlioBlockingCoroutine`), not (only) the lock-free list nodes:

- Tracing `Value.release` for `KlioBlockingCoroutine`: the fatal release
  (refcount → 0) is always **`resumeContinuation`'s `frame.deinit`**
  (`eval.zig:558`, the per-register release), reached via `pumpLoop`
  (`coroutines.zig:1264`) → `resumeRaw` → `resumeContinuation`. A resumed frame
  releases a register that holds the parent coroutine.
- Total retains == total releases (the instance is freed *exactly once*, no
  leak, no double-free in aggregate) — but the **last** release happens during
  the pump, while `joinBlocking`'s receiver borrow still needs the instance.
- It is a per-iteration NET drift: the receiver-retain (`8eeab3b7`) adds one
  buffer reference, which is why the threshold moved from `n≥8` to `n≥10` rather
  than being fixed outright. So somewhere in the suspend/resume + job-tree
  interplay the parent coroutine is released slightly more eagerly than it is
  retained, and the buffer is exhausted at ~10 children.
- Under plain `smp` this surfaces downstream as `incorrect alignment`
  (free-list corruption); under `KLIO_RC_DETECT=1` as the `0xaa…` UAF, and at
  larger N as an actual `[RC DOUBLE-FREE]` in the same `resumeContinuation`
  `frame.deinit`.
- Object **singletons** (`NonDisposableHandle`, an `object`) are also shared by
  value all over the job tree without retaining; a systematic fix is to make
  `ClassDef.is_object` instances immune to reclamation (retain/release no-op,
  like the immutable `Class` graph) since they are process-global. This was
  prototyped and is neutral for the *current* bottleneck (the parent coroutine
  above is not a singleton) but is very likely needed before the tail is clean;
  do it with a cheap per-instance flag, not a per-op class borrow.

Further bisecting (env gates on `Frame.deinit`'s per-slot releases):
- Disabling the resumed frame's **captures** release (`KLIO_NO_CAP_REL`) makes
  the async loop pass at every N — but that is a *buffer/leak*, not the fix:
  it adds one un-released reference per suspension that absorbs the real
  over-release. Removing the snapshot's capture retain *and* the resume release
  together (making captures pure borrows) made it worse, confirming the snapshot
  capture retain is the absorbing buffer, not the bug.
- So the over-release is one un-matched **release** of the parent coroutine that
  the snapshot-capture-retain (+1) and the receiver-retain (+1) together buffer —
  exhausted at ~10 children.
- Pinpointing it with env-gated prints is blocked by a *funnel*: every
  `Instance` retain/release routes through `Value.retain`/`Value.release` →
  `ObjRef.clone`/`deinit`, so both `@returnAddress()` and per-address tallies
  collapse to those two wrapper sites; and retains vs releases live at different
  code sites by nature, so address tallies never pair. A full-stack dump per op
  perturbs the timing enough to move the crash.

**What it needs:** a proper refcount-pairing tracker — record, per cell, the
ordered (op, full call site) history and, for any cell whose count hits zero
while a known borrow is still outstanding (or simply dump the complete history
of the one `KlioBlockingCoroutine` cell), so the unmatched release is read
directly. That is the same class of tool as `src/runtime/alloc_track.zig` and is
the right next investment. Alternatively, the **per-request / per-coroutine-tree
arena reset** (§12.4 option 2) sidesteps the value-graph reclaim entirely and is
the more bounded route to a bounded server.

**Built and run that tracker (this session, then reverted as it adds hot-path
cost):** a per-cell op history in `ObjRef.clone`/`deinit` (gated `KLIO_RCH`),
dumped with symbolized stacks on the `KLIO_RC_DETECT` double-free. Definitive
finding for `n=20`:
- The over-released cell is the `KlioBlockingCoroutine` (the `runBlocking`
  scope). It reaches refcount 0 legitimately, then is released ~4 more times
  (the trace shows the count wrap through `0, -1, -2, …`).
- **Every** one of those extra releases is `resumeContinuation` →
  `frame.deinit` (the per-register release at `eval.zig:556`, via
  `pumpLoop:1264` → `resumeRaw` → `resumeContinuation`). So the resumed frames
  release the scope register more times than it was retained.
- The scope's *retain* sites are all correct (`GetField` `v.retain()`, the
  alias-handler retains, the receiver-retain `8eeab3b7`, and
  `retainSnapshotValues`). So the missing retain is a **store** that puts the
  scope into a register without retaining — invisible to a refcount tracker
  (a `frame.write`/`appendSlice`, not a `clone`/`deinit`). The two structural
  candidates: a host function that *returns* the scope as a borrow (the eval
  `Call`/`CallMember` `.ok` arm writes the result with no retain, relying on the
  host-returns-owned contract), or a `SuspendState` whose frames are resumed
  more than once (each resume releasing the snapshot's single reg retain).
- The over-release is roughly proportional to N (the receiver-retain `+1` and
  the snapshot-capture `+1` buffer it, so it only crosses zero at ~10 children).

The next concrete step is a **store tracker**: instrument `Frame.write` (and the
resume-path `appendSlice`/`frame.write(carry)`) to log when the
`KlioBlockingCoroutine` value is stored into a register *and whether the stored
value carried an owning ref*, pairing those against the `resumeContinuation`
releases to expose the host-returns-borrowed (or double-resume) site directly.

The honest assessment: this is the §6/§7.-1 "all-or-nothing host reconciliation"
wall — a long tail of borrow-without-retain share sites in the coroutine / job
tree / suspend-resume machinery, each fix unblocking a little more. The
remaining sites live in the resume path's register ownership and the structured-
concurrency parent/child reference management.

### 12.4 Likely shape of the fix

Lock-free reclamation + refcounting do not compose by naive per-CAS
retain/release. Options, roughly in order of safety:
1. **Audit the LockFreeLinkedList ownership model** end to end: decide exactly
   which `_next`/`_prev` links *own* a node ref vs which are *borrows* (back-
   pointers / repair), and make CAS retain/release only on the owning links.
   The `_prev` back-pointer almost certainly should NOT own (else cycles /
   double-counting); only `_next` (forward) should own, with the head holding
   the list. This likely means the AtomicRef CAS cannot uniformly release-old —
   the list needs link-kind-aware store ops, or the nodes need an explicit
   single-owner discipline.
2. **Per-request / per-coroutine-tree arena** for the server: sidesteps the
   lock-free reclamation entirely by reclaiming the whole request's value graph
   at a completion boundary (the run-boundary reset already exists for the test
   harness — `coroutines.zig`). Trades the lock-free audit for coroutine-
   lifetime/escape bookkeeping.
3. **Cross-thread `scheduler.post`** (`intrinsic_host.zig:817`) must clone the
   block on post and release it when the worker task completes — required for
   `Dispatchers.Default` regardless of which path above is chosen.

Validate any fix with the §12.1 reproducer sweeping N, then the coroutine
itests, then `zig build itest-ktor_server`, all under `KLIO_RECLAIM=smp`.

## Startup baseline today: where the ~104 MB goes, and the path to Node-level

Hello-world (`println`) resident set is **~104 MB** (`/usr/bin/time -l`, warm
image cache). Almost all of it is the eagerly-decoded stdlib image:

- `image.decode` **~70 MB** / ~142 K allocations — the post-lift AST forest
  (`lifted_decls`) plus the lowered IR `module`.
- `image.baseFromRoot` **~12 MB** — the `ClassDef` graph.
- The rest is the binary, stacks, and host scratch.

Within the `image.decode` 70 MB, measured by stripping body classes at bake and
reading `KLIO_ALLOC_TRACK`:

- **Inline-function bodies ~26 MB.** Kept because the lowerer splices `inline fun`
  bodies into user code. A trivial program inlines none of them yet pays for all.
- **Non-inline (dead) function bodies ~6 MB.** Now stripped: a non-inline base
  function runs from its lowered IR, never its AST body, so the body is replaced
  with an empty block at `buildStdlibBase` (keeping the `body != null`
  concrete-vs-abstract sentinel, `Inst.BuildObject` object subtrees, and the
  inline bodies). See `src/interp_ir/prune.zig`.
- **AST skeleton + lowered IR ~38 MB.** Decls, params, type refs, signatures,
  class metadata, and the whole stdlib's lowered functions — needed eagerly by
  the current loader.

Stripping *all* bodies (inline included) lands hello-world at **~82 MB**, so the
inline bodies are worth ~22 MB RSS but cannot be dropped wholesale — they are
live for any program that inlines a collection/sequence/flow operator.

**To reach Node (~40 MB) / Python (~15 MB)** the image must stop materialising
the whole stdlib on the heap at startup. Two routes, both real format work:

1. **Lazy-decode inline bodies** (~22 MB for trivial programs, and a fraction of
   that paid per real program — each only materialises the operators it actually
   inlines). Blocker: the current codec bakes the entire `lifted_decls` forest in
   one traversal with a single shared node/slice registry, so a body's backrefs
   reference globally-numbered nodes and cannot be decoded in isolation. Needs
   inline bodies baked into a self-contained section (own local registry, shared
   nodes duplicated), the skeleton decoded with a body-offset placeholder, and
   `inlineAstById` decoding on first splice with memoization.
2. **Position-independent / mmap'd image** (the big one, ~50 MB). Store the AST +
   IR in a fixed, pointer-free layout (offsets, swizzled once or dereferenced
   through a base) so the loaded image lives in the file-backed mmap and only
   touched pages stay resident. Eliminates the 142 K heap allocations entirely.

The dead-non-inline-body strip (route 0) is landed. Routes 1 and 2 are the
remaining levers and are both core image-format changes.

### Note: bake determinism

The baked image is now byte-reproducible run to run. The earlier
non-determinism was a single in-place result-location aliasing bug in the body
strip: writing the empty block into `f.body` clobbered the body fields the new
block's span was read from when the span read sat inline in the struct literal.
Reading the span into a local first fixes it. The image is keyed by exe stamp +
stdlib hash, but reproducible bytes keep the rebake-after-corruption path (and
its test) stable.
