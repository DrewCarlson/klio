# Coroutine model: complete async-compose story + the eager-outside-driver divergence

Author role: concurrency runtime architect. This plan is grounded in the live code
(file:line below), not the probe summaries alone.

---

## STATUS 2026-06-26 — async-compose story DONE; coroutine-semantics audit found the remaining work

The original framing ("eager model, no async event loop") is **superseded**. klio
*has* a working cooperative pump + ready-queue (`coroutines.zig`), launch ordering is
correct (`runBlocking { launch{A}; print B }` → `B A`), and the whole async-compose
story this plan was written for now works end-to-end:

- `kotlin.synchronized` as an inline actual (block can suspend) — `main`.
- `StateFlow`/`SharedFlow` collect machinery: writeback-call→member (`forEachSlotLocked`),
  object-arg-vs-fn-param inline overload (`collectWhile`/first/single), member-shadows-
  extension property (the `WorkaroundAtomicReference` recursion) — all on `main`.
- Frame clock + async `Recomposer.runRecomposeAndApplyChanges` + `snapshotFlow` +
  `Flow.collectAsState` **and** `StateFlow.collectAsState` — all green
  (`examples/compose_frame_clock.kt`, `compose_snapshot_flow.kt`, `compose_stateflow.kt`).
- The last collectAsState blocker was a compose bug (skipped `@Composable` returned
  Unit), not a coroutine one — see COMPOSE-RUNTIME.md.

### Audit 2026-06-26 — 33 confirmed divergences from kotlinx.coroutines (the remaining work)

A category audit (10 categories, each probe verified against vendored upstream
semantics) found **33 confirmed divergences**, clustering into ~10 root causes. These
are the remaining tasks to make klio coroutines match Kotlin. Ordered by severity:

1. **Structured-concurrency parent-job leak (10 findings) — highest impact.** A
   `coroutineScope`/`supervisorScope`/scoped-coroutine child failure that is **caught
   externally** still leaks to the parent `runBlocking` job → stdout is correct but the
   process ALSO prints `runtime error: uncaught …` to stderr and exits 1 (double
   delivery). Root cause: `klioMain/kotlinx/coroutines/KlioRuntime.kt` (`joinBlocking`
   ~lines 45/57/62-71, the `if (failed) throw failure`) records and rethrows a failure
   that upstream `JobSupport.cancelParent` short-circuits for scoped coroutines
   (`JobSupport.kt:336-338` `if (isScopedCoroutine) return true`; `internal/Scopes.kt`
   sets `isScopedCoroutine=true`). Fix: the parent `runBlocking` job must NOT be marked
   failed when a scoped-coroutine child's exception was delivered via the rethrow path
   (and supervisor children never propagate at all). Also surfaces as `join()` leaking
   the internal `KlioBlockingCoroutine` class name.

2. **CoroutineExceptionHandler not wired (2 findings + 1 segfault).** A `CEH` in the
   context of `GlobalScope.launch` / a `supervisorScope` child is IGNORED — the
   exception goes to the default "Exception in thread …" handler instead of the
   installed handler (`klioMain/kotlinx/coroutines/internal/Misc.kt:23`,
   `src/kotlinx_coroutines/kotlinx_coroutines.zig:613`). And a **SEGFAULT** when a CEH is
   installed on `CoroutineScope(SupervisorJob() + handler)` and a child throws
   (`src/interp_ir/vm/host_call_member.zig:3104`). Fix: route an uncaught coroutine
   exception through the context's `CoroutineExceptionHandler` before the default.

3. **Channel API + semantics (6 findings).** `trySend` returns `Boolean` not
   `ChannelResult` (`.isSuccess` fails on a Bool), `tryReceive` returns the bare value
   not `ChannelResult`, `isClosedForSend`/`isClosedForReceive` are dispatched as methods
   not properties, `produce` returns a `ReceiveChannel` whose `receive()` is broken,
   rendezvous `send` doesn't suspend (it behaves buffered), and a conflated channel keeps
   all values instead of the latest. Root: the channel actuals
   (`src/kotlinx_coroutines/kotlinx_coroutines.zig` + the `KlioChannel` klioMain) have
   wrong return types and buffering semantics. Fix: return `ChannelResult` from
   `trySend`/`tryReceive`, make the closed-flags properties, implement rendezvous +
   conflated buffering, fix `produce`.

4. **`select` + `Semaphore` (6 findings).** Every `select` clause crashes/errs —
   `onReceive`/`onSend`/`onReceiveCatching` (members unresolved on `KlioChannel`),
   `onAwait` (unresolved on `Job.Key`), and `onTimeout` **SEGFAULTs** (unbounded
   recursion through the select machinery). `Semaphore.withPermit` under contention
   crashes (`BinOp.Less on {ir-closure} and kotlin.Unit`). Fix: implement the `select`
   builder + the channel/deferred `SelectClause`s; fix the `Semaphore` permit accounting.

5. **Channel-backed flow operators (4 findings).** `buffer`/`conflate`/`flowOn`
   (ChannelFlow → `iterator` on a channel), `combine`/`zip`/`flatMapMerge` (`invoke` on a
   `SafeCollector`), `drop`/`dropWhile`/`takeWhile` (`collect` on `unsafeFlow`), and
   `onCompletion` + `catch` (`invoke` on `$anon`). Mostly **downstream of #3 (channels)**
   and the SafeCollector emit path (#6); re-verify after those land.

6. **Hot-flow suspending collector (3 findings).** A `SharedFlow`/`StateFlow` collector
   that suspends and then takes a *second* emit fails with `Vm::call_member emit on
   kotlin.Function` (`src/interp_ir/vm/host_call_member.zig:3013` — the SafeCollector
   emit dispatch on resume binds the collector as a bare function). And
   `subscriptionCount` hits `unresolved global lastReplayedLocked` — the *same*
   pack-member-inline-unresolved class as `forEachSlotLocked` (now fixed) but for another
   `AbstractSharedFlow` member (`src/ir/eval.zig:3045`). Fix: the resume-side
   SafeCollector emit must dispatch the collector's `emit`, and `lastReplayedLocked`
   needs the inherited-member-inline resolution.

7. **`Dispatchers.Unconfined` eager-start ordering (3 findings).** `Unconfined` should
   start eagerly on the current thread until the first suspension; klio's interleaving
   differs (`A C B D` vs Kotlin's order). The narrowest genuine remnant of the "eager"
   divergence (default `launch` ordering is already correct).

8. **`yield()` doesn't yield to the pump (1, found pre-audit).** In a `launch`-collector
   loop resumed across `yield()`s from another coroutine, the yielder runs again before
   the ready coroutine, double-resuming the same continuation → `Already resumed`
   (`/tmp` repro `loopsusp.kt`). Not on the collectAsState path (that uses delay/slot
   resume), but a real dispatch-ordering bug.

9. **User top-level `coroutineContext` symbol corrupts the runtime (1).** A user-declared
   top-level `coroutineContext` (or similar coroutine-intrinsic name) shadows/poisons the
   runtime → `ClassCastException: cast to Map failed`. A name-domain/resolution bug, same
   family as the `System.err` → `Clock.System` clash noted while probing.

10. **`channel_worker_writer` missed-wakeup deadlock (pre-existing, from memory).** A
    `ByteChannel` + `Dispatchers.Default` worker hangs on a missed wakeup. Re-verify after
    the channel + dispatcher fixes; may be subsumed.

Unsure/uncconfirmed: 2 probes the audit could not pin to a definite Kotlin-correct
output — re-derive before acting.

**Suggested fix order:** #1 (structured-concurrency leak — the KlioRuntime parent-failure
path) and #2 (CEH + segfault) first (highest user impact, shared root in KlioRuntime);
then #3 (channels) which unblocks #4 (select), #5 (channel flow ops), and parts of #6;
then #6/#7/#8 (flow + dispatch ordering); #9 is an isolated resolution fix. Each fix
ships with a deterministic probe promoted into the parity/e2e corpus.

---

## 0. What the machinery actually is (verified)

Two layers, exactly as mapped:

- **Layer 1 — dispatcher/time-agnostic suspension.** `src/ir/eval.zig` returns
  `error.Suspend`; the activation is packed into a `SuspendState`. No clock, no
  dispatcher.
- **Layer 2 — `CooperativeInterceptor` pump.** `src/interp_ir/vm/coroutines.zig`.
  Per-`runBlocking`/per-root cooperative pump on one OS thread. Owns a ready
  queue, a token→`ParkedEntry` map, a slot table, a virtual clock, a cross-thread
  `DriverWakeup` mailbox.
  - `runBlocking` → `__kxco_rbPump` → `driveRunBlocking`/`driveRoot(persist=false)`
    (coroutines.zig:1600-1601, 1186-1187).
  - `pumpLoop` (coroutines.zig:1320-1505): drain launches, resume ready tokens,
    `advanceTimeGated` (:818-899) advances virtual time gated by the global
    `VirtualClock` barrier (:353-438), drain worker mailbox, break when the root
    completes.
  - `park` requires an active pump: `coroTop() orelse return error.OutOfMemory`
    (coroutines.zig:1178). Suspending with **no** pump is an error.

Real OS parallelism: `Dispatchers.Default`/`IO` → `__kxco_dispatch` →
`coroutineDispatchPooled` → `scheduler.zig` worker pool; each task materializes a
fresh child `Vm` and runs the block via `runVmTask`/`runThreadBlock`
(scheduler.zig:327-345). Cross-thread resume routes back through `SlotOwners` +
the owning driver's mailbox, or `PersistedParked` after the driver exited
(`coroutineResumeExternal`, coroutines.zig:1693-1747).

**The divergence.** `coroutineLaunch` (coroutines.zig:1642-1654): with an active
pump it enqueues the child onto the pump; with **no** pump it runs the child
**eagerly inline** via `invokeCallable`, so `delay` is a no-op and `await`
returns immediately. The reason a bare `GlobalScope.launch{}` hits this path is
that klio's `newCoroutineContext` actual installs the Unconfined-like
`KlioDispatcher` as the default (ContextActuals.kt:9-11) instead of upstream's
`Dispatchers.Default`. `KlioDispatcher.dispatch` → `__kxco_spawn` →
`coroutineLaunch` with no pump → eager.

Verified probes that the design relies on:
- **DRIVEN works.** `withContext(Dispatchers.Default){delay;…}` inside
  `runBlocking` → `1\n2\ndone` (p1a). `awaitCancellation()`+`cancel()`+`join()`
  inside a launch → finally runs (p6). Channel producer/consumer inside
  `runBlocking` completes (p4). `CoroutineScope(Dispatchers.Default).launch`
  outside `runBlocking` already dispatches + `delay` works (p1b). **Conclusion:
  everything PART A needs already works as long as it runs under `runBlocking`.**
- **Eager footgun.** `GlobalScope.launch{child;delay;child-end}` outside
  `runBlocking` runs eager: `child-start\nchild-end\nmain-after-launch\ndone`
  (p1c). This is PART B.
- **Blocker.** `StateFlow.collect` (and `StateFlow.first()`) inside a launch
  stack-overflows at 10001 frames through `concurrent_synchronized →
  invokeCallable → dispatchIntrinsic` (p5/p5b/p5c). Root-caused below.

## 1. Root cause of the StateFlow / suspend-inside-`synchronized` overflow (PART A blocker)

`concurrent_synchronized` (src/stdlib/implementations/concurrent.zig):

```
try monitorEnter(key);
const result = ctx.host.invokeCallable(&block, &.{}, ctx.out);  // body may .Suspend
_ = try monitorExit(key);
return result;   // .Suspended propagates out
```

When the body suspends *inside* the monitor, the IR activation for the body is
captured into a `SuspendState`, but the **host** frame `concurrent_synchronized`
is not part of that captured activation. It runs `monitorExit` and returns
`.Suspended`. The upstream `SharedFlowImpl.awaitValue` / `emitSuspend` call
`suspendCancellableCoroutine{…}` **inside** `synchronized(this){…}`
(SharedFlow.kt:670-671, 497-499). On resume the interpreter re-enters the
suspending function from its start rather than from the suspend point that was
captured under the host monitor frame — so `collect` re-runs from the top, calls
`awaitValue` again, suspends again, ad infinitum: the 10001-frame recursion.

Two correct fixes (do the cheaper one first, keep the second as the real fix):

- **Fix B1 (real fix): make the suspend point survive a host-monitor frame.**
  The captured `SuspendState` must record that it is nested inside an open
  monitor so that (a) on park the monitor is released, and (b) on resume the
  monitor is re-acquired *before* the activation continues, and the activation
  continues from the suspend point — not from `collect`'s entry. Concretely:
  `concurrent_synchronized`, on observing `.Suspended`, must push a
  "monitor-reacquire" continuation marker onto the `SuspendState` (a
  `pending_monitor: usize` field on `ParkedEntry`, coroutines.zig:524-536) and
  release the monitor (`monitorExit`). `resume` (coroutines.zig:1398-1399), after
  restoring the scope delta, calls `monitorEnter(pending_monitor)` before
  re-entering the activation. This matches Kotlin/JVM where a monitor is NOT held
  across a suspension boundary in the cooperative model but the function resumes
  at the suspend point. This is the root-cause fix and unblocks all of
  SharedFlow/StateFlow.

- **Fix B0 (cheaper, narrower — verify first whether it is sufficient):** the
  upstream `SharedFlow.collect` continuation must be a *real* IR continuation,
  not restarted. If the overflow is actually that `invokeCallable` re-runs the
  whole closure on resume (a continuation-identity bug) rather than a
  monitor-specific bug, the fix is in how a suspended closure body resumes — it
  should resume the captured activation, never re-invoke `invokeCallable` from
  scratch. Add a probe: a plain `suspend fun f(){ synchronized(x){ delay(1) } }`
  under `runBlocking`. If that alone overflows, the bug is monitor-specific
  (B1). If a `suspend fun` that suspends inside *any* host intrinsic (not just
  synchronized) restarts, the bug is in resume identity and must be fixed there.

`snapshotFlow` itself does **not** suspend inside `synchronized` — its
`synchronized(lock){…}` blocks only read/snapshot subscription sets
(SnapshotFlow.kt:258,319,344,410,438,463) and the suspend points are
`withFrameNanos`/`emit` *outside* the lock. `BroadcastFrameClock.withFrameNanos`
also enqueues under `synchronized` (AwaiterQueue.addAwaiter, AwaiterQueue.kt:51)
but the actual park (`suspendCancellableCoroutine`) returns the suspend directive
*after* `synchronized` has returned — so the frame clock and snapshotFlow are
viable even before B1 lands. **collectAsState on a StateFlow is the only PART A
surface that hard-requires B1.** Plan accordingly: ship frame clock + recomposer
+ LaunchedEffect/produceState/snapshotFlow first (no B1 needed), then land B1 to
enable `StateFlow.collectAsState`.

---

# PART A (PRIMARY): complete async-compose story inside a driver

Everything runs under `runBlocking`, where klio's cooperative pump is already
correct (p1a/p4/p6). No new low-level engine. The pieces:

## A1. Frame clock (compose pack klioMain)

Add to the compose pack so the upstream files parse, but supply the engine in
klioMain to avoid pulling the whole atomic/`AwaiterQueue` graph.

1. **`klio.toml` include additions** (kotlin-klio/klio-compose-runtime/klio.toml,
   the `include = [...]` list): add
   `MonotonicFrameClock.kt` (pure interface + `withFrameNanos`/`withFrameMillis`
   top-levels + `monotonicFrameClock` accessor — depends only on
   `CoroutineContext`, all available). Do **not** add the upstream
   `BroadcastFrameClock.kt` (it needs `internal/AwaiterQueue` + the platform
   `synchronized` expect); instead supply a klioMain `BroadcastFrameClock`.

2. **klioMain `BroadcastFrameClock.kt`** — a minimal, parse-clean reimplementation
   that parks awaiters on slots via the existing intrinsics
   (`__kxco_newSlot`/`__kxco_parkSlot`/`__kxco_resumeSlot`, bound at
   kotlinx_coroutines.zig:873-875), avoiding `AwaiterQueue`. Shape:

   ```kotlin
   class BroadcastFrameClock(private val onNewAwaiters: (() -> Unit)? = null) : MonotonicFrameClock {
       private class Awaiter<R>(val onFrame: (Long) -> R, val cont: CancellableContinuation<R>)
       private val lock = Any()
       private var awaiters = ArrayList<Awaiter<*>>()
       private var spare = ArrayList<Awaiter<*>>()
       val hasAwaiters: Boolean get() = synchronized(lock) { awaiters.isNotEmpty() }

       override suspend fun <R> withFrameNanos(onFrame: (Long) -> R): R =
           suspendCancellableCoroutine { co ->
               val a = Awaiter(onFrame, co)
               val hadAwaiters = synchronized(lock) {
                   val had = awaiters.isNotEmpty(); awaiters.add(a); had
               }
               if (!hadAwaiters) onNewAwaiters?.invoke()
               co.invokeOnCancellation { synchronized(lock) { awaiters.remove(a) } }
           }

       fun sendFrame(timeNanos: Long) {
           val toResume = synchronized(lock) {
               val cur = awaiters; awaiters = spare; spare = cur; cur
           }
           for (a in toResume) resumeAwaiter(a, timeNanos)
           toResume.clear()
       }
       private fun <R> resumeAwaiter(a: Awaiter<R>, t: Long) =
           a.cont.resumeWith(runCatching { a.onFrame(t) })
   }
   ```

   Note: the `suspendCancellableCoroutine` body enqueues under `synchronized` but
   the park happens after the lambda returns, so this is safe pre-B1 (see §1).

3. **`MonotonicFrameClock` as a `CoroutineContext.Element`.** The upstream
   interface already extends `CoroutineContext.Element` with `key = Key`. klio's
   context machinery must resolve `coroutineContext[MonotonicFrameClock]` to the
   element installed via `withContext(frameClock)`. Verify klio's
   `CoroutineContext.get(key)` finds an element by companion-object key
   (kotlinx.coroutines pack already does this for `ContinuationInterceptor`,
   `Job`, `CoroutineName`). No host intrinsic needed.

## A2. Recomposer.runRecomposeAndApplyChanges (compose pack klioMain)

Do **not** port the 78k-line upstream `Recomposer.kt`. Extend the existing klio
`Recomposer` (Composition.kt:26-50) with an async loop built on the same
primitives the upstream loop uses (Recomposer.kt:565 `runRecomposeAndApplyChanges`
→ `recompositionRunner` → `parentFrameClock.withFrameNanos{...}`):

```kotlin
public class Recomposer(
    private val effectContext: CoroutineContext = EmptyCoroutineContext,
) {
    private val compositions = ArrayList<KlioComposition>()
    private val broadcastFrameClock = BroadcastFrameClock { /* invalidations woke us */ }
    private val invalidations = ... // a wake slot / channel-of-units
    internal val recomposeContext: CoroutineContext
        get() = effectContext + broadcastFrameClock   // effects launch onto this

    // The async driver. Run inside runBlocking; awaits work, asks the parent
    // clock for a frame, recomposes invalidated compositions, applies.
    public suspend fun runRecomposeAndApplyChanges() {
        recomposeAndApplyChanges(Long.MAX_VALUE)   // run forever until cancelled
    }

    suspend fun recomposeAndApplyChanges(frameCount: Long) {
        var frames = 0L
        while (frames < frameCount) {
            awaitWorkAvailable()                    // suspend until an invalidation
            // ask the PARENT clock (the driver's frame clock) for a frame tick:
            parentFrameClock().withFrameNanos { frameNanos ->
                // 1) deliver this frame tick to composition-internal awaiters
                broadcastFrameClock.sendFrame(frameNanos)
                // 2) recompose every composition with pending invalidations
                for (c in compositions.toList()) if (c.hasInvalidations) c.recompose()
            }
            frames++
        }
    }
}
```

`awaitWorkAvailable()` parks on a slot (via `__kxco_newSlot`/`__kxco_parkSlot`)
that the `StateObservation` write-observer resumes
(`__kxco_resumeSlot`) when a state write invalidates a registered composition.
Wire this in `KlioComposition.ensureWriteObserver` (Composition.kt:68-74): on
`composer.invalidate(state)`, also call `parent.notifyWorkAvailable()` which
resumes the recomposer's await slot.

`parentFrameClock()` reads `coroutineContext[MonotonicFrameClock]` — the clock
the *driver* installed (the app's `BroadcastFrameClock`, see A4). This mirrors
upstream where the recomposer awaits the platform/host frame clock and re-fans it
to compositions through its own `broadcastFrameClock`.

## A3. Effects launch onto the recomposer context

`CoroutineEffects.kt` today launches onto `CoroutineScope(Job())` with no driver
(CoroutineEffects.kt:23,45-47), which is why they run eagerly. Change them to
launch onto a scope whose context carries the recomposer's `recomposeContext`
(so `withFrameNanos`/the frame clock resolve) and whose `Job` is a child of the
recomposer, cancelled on dispose:

- `rememberCoroutineScope()` → `CoroutineScope(recomposer.recomposeContext + Job())`.
  The composer must know its `Recomposer` (thread it through
  `KlioComposition`/`KlioComposer`; the composition already holds `parent`).
- `launchEffect` → `scope.launch { block() }` where `scope` carries the recompose
  context. Because the recomposer runs under `runBlocking`, `coroTop()` is
  non-null when these launch, so `coroutineLaunch` enqueues onto the **pump**
  (coroutines.zig:1644-1646) instead of running eager. `delay`, `withFrameNanos`,
  `flow.collect` now park correctly. This is the whole fix — verified-correct
  driven behavior (p1a/p6) does the rest.
- `produceState` (CoroutineEffects.kt:97-118) already routes through
  `LaunchedEffect`; once LaunchedEffect launches onto the pump, `awaitDispose`
  can become a real `awaitCancellation()` (p6 proves it parks + runs finally) so
  a producer can legitimately suspend forever and be cancelled on dispose,
  instead of the current eager `throw CancellationException`.

## A4. snapshotFlow + collectAsState (compose pack klioMain)

- **`snapshotFlow`** — klioMain reimplementation built on `flow{}` +
  `Snapshot.registerApplyObserver` semantics. klio already has
  `StateObservation` (StateObservation.kt) with a write-observer. Implement:

  ```kotlin
  fun <T> snapshotFlow(block: () -> T): Flow<T> = flow {
      val seen = HashSet<Any>()      // read state objects
      var last: Any? = NoValue
      while (true) {
          val readSet = HashSet<Any>()
          val v = StateObservation.observe({ s -> readSet.add(s) }) { block() }
          if (v != last) { emit(v); last = v }
          // suspend until any read state object is written:
          awaitWriteTo(readSet)      // parks on a slot resumed by the write-observer
      }
  }
  ```

  `awaitWriteTo` registers a one-shot write observer over `readSet` that
  `__kxco_resumeSlot`s a parked slot. `emit` is a normal flow emit (suspends into
  the collector's continuation). Because this `flow{}` is `collect`ed inside a
  `LaunchedEffect` that now runs on the pump, the whole thing parks correctly.
  `snapshotFlow` does NOT suspend inside `synchronized`, so it works pre-B1.

- **`collectAsState`** — klioMain, two overloads (SnapshotFlow.kt:52/66 shapes):
  ```kotlin
  @Composable fun <T> Flow<T>.collectAsState(initial: T, context: CoroutineContext = EmptyCoroutineContext): State<T> {
      val state = remember { mutableStateOf(initial) }
      LaunchedEffect(this, context) {
          if (context == EmptyCoroutineContext) collect { state.value = it }
          else withContext(context) { collect { state.value = it } }
      }
      return state
  }
  @Composable fun <T> StateFlow<T>.collectAsState(context: CoroutineContext = EmptyCoroutineContext): State<T> =
      collectAsState(value, context)
  ```
  The `StateFlow` overload requires the SharedFlow suspend-in-`synchronized`
  blocker (B1) to be fixed; the plain `Flow<T>` overload (and snapshotFlow) do
  not.

## A5. Public driver API a klio compose app uses

The app drives the whole thing under `runBlocking`, so the existing pump *is* the
frame loop. Provide a thin entry point in klioMain:

```kotlin
// androidx/compose/runtime/RecomposerRunner.kt (klioMain)
fun runComposeApp(frames: Int = -1, content: @Composable () -> Unit) = runBlocking {
    val clock = BroadcastFrameClock()
    withContext(clock) {                       // install the driver frame clock
        val recomposer = Recomposer(coroutineContext)
        val composition = Composition(recomposer)
        val runner = launch { recomposer.runRecomposeAndApplyChanges() }
        composition.setContent(content)        // initial composition
        // Drive frames deterministically:
        var n = 0
        while (frames < 0 || n < frames) {
            if (!recomposer.hasPendingWork && !clock.hasAwaiters) {
                if (frames < 0) break          // quiescent: nothing more to do
            }
            clock.sendFrame(n.toLong() * 16_000_000L)   // 16ms/frame, monotonic
            yield()                            // let the pump run the frame
            n++
        }
        recomposer.close()                     // cancel runner + effect jobs
        runner.cancelAndJoin()
        composition.dispose()
    }
}
```

This is deterministic: frame N has `frameTimeNanos = N * 16ms`, frames advance
only when the app calls `sendFrame`, and the loop stops when the composition
quiesces (no invalidations, no awaiters) in the bounded/`frames<0` case. Apps
that need infinite animation pass a fixed `frames` count for a deterministic run.

`Recomposer.close()` cancels the runner job and all effect child jobs (structured
concurrency: effect scopes are children of `recomposeContext`'s Job).

## A6. Host intrinsics needed for PART A

**None new.** Everything is reachable through existing bindings:
`__kxco_newSlot`/`__kxco_parkSlot`/`__kxco_resumeSlot` (kotlinx_coroutines.zig:873-875),
`__kxco_spawn`/`__kxco_dispatch`, `__kxco_rbPump`, `advanceTimeGated`/virtual clock
already in place. The only Zig change PART A *requires* is **B1** (monitor across
suspend) and only for `StateFlow.collectAsState`; the frame clock, recomposer,
LaunchedEffect/produceState, snapshotFlow, and plain-`Flow` collectAsState need
zero Zig changes.

## A7. Why PART A works with klio's current driven behavior (citations)

- Effects launched inside the `runBlocking`-driven recomposer enqueue onto the
  pump, not eager: `coroutineLaunch` with `coroTop()!=null`
  (coroutines.zig:1644-1646). Proven equivalent by p1a/p4/p6.
- `withFrameNanos` parks on a slot and is resumed by `sendFrame` →
  `__kxco_resumeSlot` → `coroutineResumeSlotValue` →
  `coroutineResumeExternal` enqueues onto this pump (coroutines.zig:1684-1703).
- `delay` inside an effect parks with `wake_at` and is fired by
  `advanceTimeGated` (coroutines.zig:818-899) under the global `VirtualClock`
  barrier, so deterministic ordering across the recomposer + effect coroutines.
- Cancellation on `close()`/dispose delivers `CancellationException` through the
  slot mechanism; finally blocks run (p6).

## A8. PART A implementation order

1. Add `MonotonicFrameClock.kt` to `klio.toml` include; confirm it resolves
   (`withFrameNanos`/`monotonicFrameClock`). Probe: a `runBlocking{ withContext(BroadcastFrameClock()){...} }` that calls `withFrameNanos`.
2. klioMain `BroadcastFrameClock.kt` (A1.2). Test it standalone (A-test-1 below).
3. Extend `Recomposer` with `recomposeContext` + `runRecomposeAndApplyChanges` +
   `awaitWorkAvailable`/`notifyWorkAvailable` (A2).
4. Thread the `Recomposer` into `KlioComposition`/`KlioComposer`; wire the
   write-observer to `notifyWorkAvailable` (A2/Composition.kt:68-74).
5. Repoint `rememberCoroutineScope`/`launchEffect`/`produceState` onto
   `recomposeContext` (A3).
6. `RecomposerRunner.runComposeApp` public API (A5).
7. snapshotFlow + plain-`Flow` collectAsState (A4); test A-test-3/4.
8. Land B1 (monitor-across-suspend); enable `StateFlow.collectAsState`; test
   A-test-5.

## A9. PART A tests (deterministic, match kotlinc)

All `runComposeApp(frames = N){...}` with `println`-instrumented effects so
output is a fixed transcript checkable against kotlinc + compose-runtime-test
(`androidx.compose.runtime.mock` / `compositionTest`).

- **A-test-1 (frame clock):** `runBlocking{ withContext(BroadcastFrameClock() as MonotonicFrameClock){ launch{ println("f="+withFrameMillis{it}) }; (ctx clock).sendFrame(16_000_000) } }` → `f=16`.
- **A-test-2 (LaunchedEffect suspends, not eager):**
  ```
  setContent { LaunchedEffect(Unit){ println("a"); delay(50); println("b") } }
  // before first sendFrame:
  ```
  Expected transcript: composition prints nothing from the effect's post-delay
  half until virtual time advances 50ms across frames; ordering `a` (on launch),
  then `b` after the pump advances 50ms. Contrast current eager output `a\nb`
  emitted synchronously at setContent. The test asserts that a marker printed by
  `setContent`'s caller *after* `setContent` appears between `a` and `b`.
- **A-test-3 (snapshotFlow):** a `mutableStateOf(0)`; a `LaunchedEffect` collecting
  `snapshotFlow { state.value }`; drive frames mutating state 0→1→2; expect
  `0\n1\n2` (distinct-until-changed, one emit per applied write).
- **A-test-4 (produceState + frame loop):** `produceState(0){ repeat(3){ delay(10); value = it+1 } }`; assert the recomposing reader sees `0,1,2,3` across frames.
- **A-test-5 (StateFlow.collectAsState, post-B1):** `MutableStateFlow(0)`,
  `collectAsState`, mutate, assert recompositions observe updates — and crucially
  that it no longer stack-overflows (the p5 regression test).
- **A-test-6 (cancel on dispose):** an effect with `try{ awaitCancellation() }
  finally { println("disposed") }`; `runComposeApp` closes → `disposed` printed
  exactly once.

## A10. PART A risks

- **B1 correctness.** Re-acquiring the monitor on resume must use the *same*
  monitor key and must not double-release. Mitigate: store the key on
  `ParkedEntry`; assert depth bookkeeping with a unit test that suspends N deep
  inside nested `synchronized`.
- **Frame determinism vs. the global VirtualClock barrier.** If an effect's
  `delay` and the frame loop's `sendFrame` race on virtual time, ordering could
  wobble. Mitigate: `sendFrame` uses an explicit monotonic `N*16ms`; `delay`
  resumes are gated by `advanceTimeGated`; both are on the *same* pump (single
  thread), so they are totally ordered by the ready queue.
- **`coroutineContext[MonotonicFrameClock]` resolution.** If klio's context-get
  doesn't dispatch on a companion-object key for a user-defined element, A1.3
  fails. Mitigate: probe early (step A8.1); if broken, fix context-key dispatch
  (same path that already resolves `Job`/`CoroutineName`).
- **Quiescence detection.** `hasPendingWork && hasAwaiters` must be evaluated on
  the pump thread between frames; an effect that re-invalidates every frame would
  loop forever in `frames<0` mode — that is correct (it is animating), and the
  bounded-`frames` mode handles deterministic tests.

---

# PART B (SECONDARY): make launch/async OUTSIDE a driver match Kotlin

The eager divergence is `coroutineLaunch`'s no-pump branch
(coroutines.zig:1648), reached because `GlobalScope`/default context uses the
Unconfined-like `KlioDispatcher` (ContextActuals.kt:9-11) rather than
`Dispatchers.Default`.

## Recommendation: do BOTH (a) and (b); (a) is the primary root-cause fix.

### B-(a) — default context uses `Dispatchers.Default` (primary, root cause)

Change `CoroutineScope.newCoroutineContext` actual (ContextActuals.kt:9-11) to
add `KlioDefaultDispatcher` (== `Dispatchers.Default`) when no interceptor is
present, exactly matching upstream jvm `CoroutineContext.kt:28-29`:

```kotlin
return if (combined[ContinuationInterceptor] == null)
    combined + Dispatchers.Default      // was: + KlioDispatcher
else combined
```

Effect: `GlobalScope.launch{}` now routes through `KlioDefaultDispatcher.dispatch`
→ `__kxco_dispatch` → `coroutineDispatchPooled` → the worker pool — the **exact
path** that `CoroutineScope(Dispatchers.Default).launch` already takes and that
p1b proves works (main-after-launch prints first, `delay` honored). The eager
`invokeCallable` branch is no longer reached for the common case.

Why this is the root-cause fix: Kotlin/JVM's `GlobalScope.launch{}` *does* use
`Dispatchers.Default`. klio currently diverges by defaulting to Unconfined. p1b
already demonstrates the pooled path suspends correctly outside `runBlocking`,
because `coroutineDispatchPooled` posts to the worker which — per the scheduler
mapping — establishes a pump for its task. (Confirm: `runVmTask` materializes a
child Vm; for `delay` to suspend there, the worker task must run under a driver.
p1b's success means the dispatch path already drives suspension for the pooled
task. If it relies on the resume routing back to a *caller's* pump rather than a
worker-local pump, that is fine for `GlobalScope.launch` because there is no
caller pump — see the note in B-(b) about giving the worker its own pump.)

### B-(b) — make the eager no-pump branch honor suspension (defensive, for genuine Unconfined)

There remain builders that legitimately want an Unconfined-on-the-current-thread
coroutine (e.g. `launch(Dispatchers.Unconfined){…}` outside `runBlocking`, or
internal delay continuations). Today those still hit eager `invokeCallable`.
Change `coroutineLaunch`'s no-pump branch (coroutines.zig:1648) to spin a fresh
`persist=true` driver via the existing `coroutineRunRoot`/`driveRoot` path — the
*same* mechanism `startCoroutine`/`__klio_co_runRoot` already uses
(coroutines.zig:1604-1639, result.zig coro_run_root):

```zig
// No active runBlocking — drive the child on a fresh persisted pump so
// delay/await suspend instead of becoming no-ops (matches Kotlin's
// dispatch to a default executor; finite blocks complete, suspending
// blocks park on the persisted registry and resume on a later pump).
return coroutineRunRoot(self, scope, block, out);   // persist=true path
```

This makes `delay`/`await` honored even for the Unconfined default, and a
suspending block parks in `PersistedParked` (coroutines.zig:275-323) to be
resumed by a later pump — the protocol already exists.

### Scheduler-mapping check: does the worker pool drive suspension?

Per the scheduler mapping, a pooled task runs `runVmTask` → `runThreadBlock` with
a fresh child `Vm` but **no interceptor push** (scheduler.zig:327-345), so a
`delay`/channel op *inside* the worker task would hit `park`'s
`coroTop() orelse error` (coroutines.zig:1178). Yet p1b (delay inside
`CoroutineScope(Dispatchers.Default).launch` outside runBlocking) **works**. The
reconciliation: in p1b the *outer* launch is what dispatches to the pool; the
worker runs the launch *body*, and the body's `delay` must park somewhere. The
two possibilities — (1) the worker establishes its own pump in `runThreadBlock`,
or (2) the launch body's continuation routes back through `coroutineResumeExternal`
to a driver — must be confirmed by reading `runThreadBlock`. **Action item B-(b').**
If the worker does NOT establish a pump, then B-(a) alone is insufficient for a
worker task that *itself* suspends, and the real fix is to wrap the worker's
block execution in `driveRoot(persist=true)` (a worker-local pump), coordinating
its timers through the same global `VirtualClock` barrier. This is the
scheduler-side analogue of B-(b): give every dispatched task a cooperative pump.

> Resolve B-(b') before shipping B-(a): read `run.zig:280` `runThreadBlock`. If it
> already pushes an interceptor, B-(a) is complete and B-(b) is the only extra
> work. If not, add a `driveRoot` wrapper in `runVmTask` (scheduler.zig:327-345)
> so dispatched tasks have a pump.

### Why NOT "stay eager"

Eager-outside-driver is observably wrong (p1c): it reorders output relative to
Kotlin and turns `delay` into a no-op. The JVM-daemon-abandonment argument ("a
`GlobalScope.launch` whose process exits before the child finishes is racy
anyway") does not justify making `delay` a no-op *while the process is alive* —
a `runBlocking{}` later in the same program, or a `Thread.sleep`/join, gives the
child real time to run on the JVM, and klio should match. Eager also breaks any
`GlobalScope`-launched effect body that escapes the recomposer scope. So: fix it.

## PART B — keep inside-runBlocking behavior unchanged

Both changes are gated on `coroTop() == null`:
- B-(a) only changes which dispatcher the *default context* installs; inside
  `runBlocking` the context already has an interceptor (the
  `combined[ContinuationInterceptor] != null` branch), so `newCoroutineContext`
  is unchanged there. The driven path (p1a/p4/p6) is untouched.
- B-(b) only rewrites the `else` branch of `coroutineLaunch` that runs when
  `coroTop()` is null; the `if (coroTop()) |top| { enqueueLaunch }` branch
  (coroutines.zig:1644-1646) — the inside-runBlocking path — is byte-for-byte
  unchanged.

Regression guard: re-run p1a/p4/p6 and the full coroutine corpus after each
change; they must stay green.

## PART B implementation order

1. **B-(b')** — read `run.zig` `runThreadBlock`; determine whether pooled tasks
   have a pump. Add a `driveRoot` wrapper in `runVmTask` if not.
2. **B-(a)** — flip `newCoroutineContext` actual to `Dispatchers.Default`. Run
   p1b/p1c equivalents; p1c must now print `main-after-launch\nchild-start\nchild-end\ndone` (or `done` may interleave per real concurrency — make the test join).
3. **B-(b)** — rewrite the eager branch to `coroutineRunRoot`. Test
   `launch(Dispatchers.Unconfined){ println(1); delay(5); println(2) }` outside
   `runBlocking` honors the delay.
4. Re-run inside-runBlocking regression suite (p1a/p4/p6 + corpus).

## PART B tests (deterministic, match kotlinc)

- **B-test-1 (GlobalScope.launch dispatches):** the p1c program, but with a
  `Thread.sleep(200)` or an explicit join so the child completes deterministically;
  expected kotlinc-matching order `main-after-launch\nchild-start\nchild-end`.
- **B-test-2 (Unconfined honors delay):** `runBlocking`-free
  `launch(Dispatchers.Unconfined){println("a");delay(10);println("b")}` + a join;
  `a\nb` with real virtual-time delay (not a no-op).
- **B-test-3 (worker task self-suspends):** `async(Dispatchers.Default){ delay(5);
  41+1 }.let{ runBlocking{ println(it.await()) } }` style — assert the pooled task
  suspended and resumed rather than erroring.
- **B-regression:** p1a/p4/p6 unchanged; full `tests/corpus` coroutine examples
  green off and on (`KLIO_JIT` both states).

## PART B risks

- **Process exit before `GlobalScope` children finish.** Matching JVM means a
  bare `GlobalScope.launch` may not complete before the program returns from
  `main`. Keep klio's existing process-exit semantics; do not block on orphan
  daemon-equivalent children (that *would* diverge). Tests must join.
- **`PersistedParked` growth (B-(b)).** A suspending Unconfined block with no
  resumer leaks a persisted entry. Mitigate: persisted entries are already bounded
  by the registry; an abandoned `GlobalScope.launch{ delay(forever) }` is the
  user's leak, same as JVM.
- **Worker-pool pump + VirtualClock barrier interaction (B-(b')).** A worker-local
  pump must register with the global barrier so its `delay` doesn't race ahead of
  the main pump. The barrier (coroutines.zig:353-438) already supports lazy
  multi-pump registration; the worker pump must publish its floor like any pump.

---

# Sequencing across both parts

PART A and PART B are orthogonal (A runs under `runBlocking`; B fixes the
no-driver case). Ship A first (it is the goal and needs no PART B work), landing
B1 (monitor-across-suspend) as the one Zig prerequisite for `StateFlow`. Then ship
PART B as the general correctness fix, B-(a) first (root cause), B-(b)/B-(b') as
the defensive completions. Every step keeps the verified driven behavior
(p1a/p4/p6) green.

## Root cause found: field receiver-lambda park (the real "B1")

The blocker for snapshotFlow + StateFlow.collectAsState is NOT monitor-across-
suspend. It is narrower and exact: a call `recv.lambda()` where `lambda` is a
**receiver-typed suspend lambda read from a field/property** (not a local), whose
body **parks**, breaks on resume — the activation re-invokes the lambda from the
top (producer re-runs) or the root driver re-invokes a non-closure (`Vm: Type`).

Confirmed minimal repro (no flows involved):
- V3 `recv.block()` where `block` is a **param**            → resumes OK
- V5 `val b = block; recv.b()` (copy field to a local)      → resumes OK
- V4 `recv.block()` where `block` is a **field**            → BREAKS

`SafeFlow` is V4 verbatim: `private val block: suspend FlowCollector<T>.() -> Unit`
+ `collectSafely(collector) { collector.block() }`. So every `flow{}` that parks
inside its producer hits this.

Mechanism: `recv.fieldLambda()` lowers to a name-resolving `CallMember` on `recv`;
`recv` has no such member, so eval falls back to the enclosing-`this` closure. That
works the first time, but the suspend-activation capture records "re-invoke this
member call" rather than "resume the closure's continuation" — so resume re-runs
(or re-resolves the name on `recv`, which is not a closure → Type).

Fix direction: when a `CallMember` resolves to an enclosing-`this` closure, invoke
it as a value call (`CallValueWithThis` shape) so the park captures the closure
continuation — exactly what the local-copy V5 already does. Either lower
`recv.enclosingFieldReceiverLambda()` to `CallValueWithThis(GetField(this,name),
this=recv)`, or fix the CallMember eval's enclosing-`this` fallback to do so.

snapshotFlow + both collectAsState overloads are written and correct (held out of
the pack) and will work once this lands.

## Parking `select` — layered blockers (ready-clause select + Semaphore work)

A `select` whose clauses are all ready (a buffered `onReceive`, `onTimeout`, an
`onAwait` on a completed `Deferred`) and `Semaphore` under contention work. A
`select` that must *park* on a not-yet-ready clause and be woken by a concurrent
`trySelect` was a never-exercised path; reaching it uncovered a stack of distinct
bugs. Three were general interpreter bugs, now fixed:

1. **Star-import shadows an enclosing receiver member.** `import Enum.*` rewrote a
   bare name to `Enum.name` whenever it was not an *own* member; a lambda has no
   own class, so `state` inside `SelectImplementation.waitUntilSelected`'s lambda
   became `TrySelectDetailedResult.state` (the AtomicRef read the wrong receiver).
   Fixed: gate on `hasEnclosingMember`.
2. **A labeled return from a non-inlined lambda was dropped.** `return@sc` from the
   lambda passed to the (called-not-spliced) inline `atomicfu.loop` lowered to a
   plain `Return`, so `state.loop { … return@sc }` looped forever. Fixed: always
   emit `LabeledReturn` for a labeled return.
3. **A star-import outranked a same-scope top-level decl.** Bare `STATE_COMPLETED`
   (a top-level `val`) became `TrySelectDetailedResult.STATE_COMPLETED`, reading a
   bogus enum field -> an internal `Symbol` where the state machine expected its
   sentinel. Fixed: skip the wildcard rewrite for a known top-level property/fn.

Remaining (deep select-engine work, not the bare-name bug):

4. **Offer value-handoff.** A rendezvous send hands its value to the parked select
   through `trySelect`'s result, but `klioProcessReceive` re-polls the (empty)
   channel instead of returning that result. Returning the `trySelect` result is
   the fix, but it is gated behind (5).
5. **`trySelect` state-machine spins / never returns.** With (1)-(3) fixed, the
   channel `onReceive` parks and the sender's `trySelect` is invoked, but
   `trySelectInternal`'s `state.loop` does not reach a returning branch (the
   `curState is CancellableContinuation` / CAS path), so `trySelect` hangs. The
   deferred `onAwait` parking path has its own analogous `Symbol`/state issue.
   These plus the suspend/resume dispatch for a parked-then-woken select are the
   remaining layers.
