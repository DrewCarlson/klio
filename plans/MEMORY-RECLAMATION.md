# Memory reclamation: making the value model free memory again

## TL;DR for a fresh agent

KLIO leaks unboundedly in any long-running process (a ktor server hits the
6 GB self-cap and aborts in ~24 s). Root cause: the whole interpreter runs on
a **single process-lifetime arena that is never reset**, and the
reference-counting reclamation the design documents is **disabled in
production** and, even when enabled, is **structurally incomplete** — the value
model has *no recursive teardown at any level*. The fix is to finish the
value-lifetime layer the Rust→Zig port dropped: give every value graph a
correct `release` (done — see "Committed foundation"), then **activate** it by
emitting explicit `Retain`/`Drop` IR instructions from a liveness pass in the
lowering (not yet done — see "The plan"). Do **not** try to add runtime
retain/release by guessing ownership at each instruction handler: that is
all-or-nothing and corrupts even trivial programs (proven below).

Production today is stable but leaky (arena frees everything at process exit).
Every change below is gated so production behavior does not change until the
new path is complete and validated.

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

Tooling built during investigation (re-create if useful): an opt-in tracking
allocator wrapping the arena (`KLIO_ALLOC_TRACK=1`) that prints total bytes,
alloc count, free count, and a power-of-two size histogram at exit. It lives in
`src/main.zig` when enabled; it is not committed.

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

## 8. Startup baseline (~670 MB) — separate workstream

The whole embedded stdlib is lowered/loaded eagerly and kept resident even for
`println("hi")`: ~205 MB in ~70 large buffers (lowered IR arrays, registry
maps, embedded pack) + ~110 MB in small AST/IR nodes (128–512 B). Even the
image-cache path expands to this (deserialization rebuilds the full live
registry). Fixing requires lazy/on-demand decl lowering or a more compact
in-memory representation. Independent of the leak; do it after.

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
- [ ] **Host ownership reconciliation (the large prerequisite, §7.-1)**:
      clone-on-share, host-returns-owned, stores-retain+release-old across
      `src/interp_ir/vm/*` and `src/stdlib/*`. Validate with `KLIO_RECLAIM=smp`
      on real programs (init → simple → stdlib → ktor).
- [ ] Re-land eval register balance + coroutine handoff (written & string-loop-
      validated, reverted pending the reconciliation; §7.5).
- [ ] Flip production to reclaim-ON + freeing allocator; verify server RSS flat
      (§7.8).
- [ ] Startup baseline / lazy stdlib (§8).
