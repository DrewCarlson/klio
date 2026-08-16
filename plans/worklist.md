# Master worklist

The ordered execution plan across everything still open. Worked top to
bottom, one item at a time; each item lands with its battery (unit +
litmus + sweep + corpus + the suite ratchets that its area touches) and
updates this file. Detail lives in the linked campaign docs — this file
is the order of work and the completion state.

## Phase A — Performance (active)

The transpiler's hot view is live and measured (+3.2% rangebench
ReleaseFast JIT-off, a14d89e2) but the campaign's goal is a real
speedup, not neutrality-plus. The recorded levers, measure-first
(`plans/c-transpiler-plan.md` §speedup):

- [x] A1. Baseline re-measured: interp 13.68s / native 13.89s (the
      +3.2% did not hold on current main — native was ~1.5% BEHIND).
- [x] A2+A3 LANDED TOGETHER (50754db8), measured 13.8s -> 0.97s
      interp / 0.83s native (16.6x / 16.8x; native +17% over interp;
      312/312 transpiler parity, corpus 316/316, ratchet 1370):
      * KLIO_PROF on the native binary attributed the wall to
        INTERPRETED machinery, which led to two interpreter-side roots
        the emitted C merely inherited:
      * computeBoxedVars falsely boxed every var a same-function
        string template `$name`-mentioned (a template is not a
        lambda) — rangebench's accumulator paid a locked cell op per
        iteration. Unboxed; unit test pins it.
      * literal-step progressions (`step k`) ran the virtual iterator
        protocol per iteration; now counted register loops with
        kotlinc's overflow-free last-element snapping (JVM-verified;
        guard example step_progression_counted.kt).
      * the emitted C inlines the per-statement trace store (span
        offsets in the hot layout) and the fused edge guard
        (klio_edge_view flag polling; ABI v3).
- [x] A4 first increment (fdded783): native calls LEAF-SERVE in place
      (the glue answers monomorphic plain calls to leaf expression
      bodies via leafExprServe, no recursive full-frame serve, no
      unwind round trip). fib native 695ms -> 220ms, ahead of the
      interpreter's 232ms; rangebench unchanged. Deeper C-to-C frames
      (non-leaf callees) remain a recorded road — measure-first, the
      remaining gap on call-heavy code is now against the JIT ceiling,
      not the interpreter.
- [ ] A5. Value 16B endgame DEFERRED BY ITS OWN DOCTRINE: stage 5b's
      32B payloads already landed (Value = 24, hot-layout-confirmed);
      the 24 -> 16 tail needs BOTH remaining 16B payloads under 8:
      Array (clean: steal the cell pointer's low bit for the
      boxed-vs-PrimBuf discriminator, kind lives in the PrimBuf
      already) and IrClosure (every shape adds an allocation or an
      id-table lifetime problem to the HOTTEST creation path — compose
      builds closures per execution). The campaign doc marks these
      "measured-first, NOT the active front"; correctness work (Phase
      B's ~60 failing tests) outranks a speculative layout change with
      regression risk. Re-open when a measurement motivates it.
- [x] A6 CLOSED BY VERIFICATION: the yieldbench GPF family
      (activateChain chain-lifetime) is dead on current main — 15/15
      clean runs, ~230ms warm. resumeOnBackgroundThread PASSES in ~50s
      and profiles as the compute-heavy category by design (1000
      composables resumed incrementally under a background mutator
      thrash loop; memset of frame register files 13%, no stall, no
      single hot bug). Frame-pool/lazy-zero ideas belong to the CPU
      campaign's recorded roads, not this worklist.

## Phase B — Compose plugin suite long tail

Ratchet 1370 observed (floor 1340) across 46 classes; roughly 60
individual tests still fail and 3 heavy classes are excluded from
census. No enumerated mechanisms yet — enumeration first, the way the
ktor campaign started (`plans/compose-plugin-lowering.md`, triage
memory klio-compose-plugin-triage).

- [x] B1. Census enumeration: per-class children at P=2, heavies solo
      uncapped; name every failing test; cluster by mechanism.
      Result: 12 unique failing tests (not ~60 — the larger number was
      contention duplication): 4 fast-real, 7 concurrent-stress
      timeouts (verify solo before believing), validatePotentialDeadlock
      (300s wall). "INCOMPLETE" census rows were "no tests found"
      helper-class over-collection, not failures.
- [ ] B2. Fix the clusters, largest mechanism first; guard example per
      fix; ratchet floor raised as observed counts stabilize.
      - [x] validate_subList_remove + subList family (23/23): ERROR/HIDDEN
            deprecated declarations excluded as extension candidates
            (`deprecated_error` skip in resolveExtensionCall); guard
            examples/deprecated_error_not_callable.kt.
      - [x] restart_and_skip (RestartTests 6/6): restart lambda re-invoke
            wraps $changed in updateChangedFlags; ratchet 1374 observed.
      - [x] testApplierBeginEndCallbacks: elvis static type is the JOIN
            of both branches, not the lhs type — lhs-typed elvis
            devirtualized `applier.onBeginChanges()` to the interface
            default through final RecordingApplier; guard
            examples/elvis_join_dispatch.kt + lower.expr unit test.
      - [ ] The 7 concurrent-stress timeouts: verified REAL solo (not
            census contention). Root mechanism profiled (put_replace as
            proxy): the run was ATOMICS-BOUND, not interpretation-bound —
            31% in the slab allocator's per-class spinlock (rawAlloc/
            rawFree), then the SpinRwLock reader cmpxchg storm, then
            three global GC external-bytes counters RMW'd on every frame.
            Landed levers, each re-profiled: per-thread slab magazines
            (batched refill/flush; flushed at worker exit), wait-free
            reader entry (fetchAdd + undo; writer unlock clears only the
            sign bit), per-thread buffered external-bytes deltas (flush
            at ±256KB, thread exit, and collect start). put_replace
            24→55 outer iterations per 30s (2.3x). Remaining profile:
            memset (frame zeroing) ~9%, arg refcount fetchAdd ~9%,
            shared-instance borrow (setFieldInner) ~10%, prog/classes
            registry read locks ~10%. The tests still exceed their
            declared runTest timeouts interpreted; next levers listed
            in the same profile order.
      - [x] 3 of the 7 stress timeouts now PASS solo (concurrentMixing
            WriteApply_add, concurrentModificationInGlobal_put_replace,
            resumeOnBackgroundThread) after the second lever round:
            lock-free steady-state registry reads (resolvedNativeForm /
            lookupIntrinsic via `asPtrConst` gated on an atomic
            `resolved_linked`), exponential lock backoff, ObjRef.clone
            gated like deinit, CallVirtual host-receiver site memo
            (native / host-slot-op / by-name verdicts), ClassDef
            resolved-ClassId memo, Module.classIdByStaticFqn
            pointer-identity memo. put_replace 24 -> 62 outer
            iterations per 30s cumulative.
      - [ ] The 4 remaining (SnapshotStateMapTests.concurrentMixing
            WriteApply_clear + SnapshotStateListTests addAll_removeRange /
            addAll_clear / concurrentGlobalModifications_addAll) fail
            their own declared runTest(timeout=30s): ~5s per outer rep
            interpreted, 10 reps. The residual profile is spread
            (memset frame zeroing ~9%, string-eql walk internals ~9%,
            shared-instance borrows ~5%, unattributed ~15%) — no single
            lever left; needs the next measured campaign round (frame
            pooling, walk-internal caches).
      - [ ] RecomposerTests.validatePotentialDeadlock: NOT compute — the
            test's `withContext(Dispatchers.Default)` loop re-posts an
            immediate event at the same virtual timestamp forever, and
            upstream `advanceTimeBy` only returns when a poll finds the
            queue momentarily empty. That is a real-time race the
            compiled JVM usually wins; klio's interpreted drain loop
            always loses against a microsecond-fast worker, so advance
            iteration 3 never returns and the 300s wall cap fires
            ("daemon task abandoned at run boundary" is the abandon
            diagnostic, not the cause). Needs a pump-fairness mechanism
            for virtual-time drains racing real-thread reposts.
- [x] B3. The 3 DNC heavy classes: CLOSED by the two concurrency lever
      rounds — the ratchet's last three runs report "0 did not
      complete" across all 46 classes (previously 3-5 classes variably
      crossed the 480s cap and RecomposerTests always did). Floor
      raised 1340 -> 1370 on observed 1375.

Phase B residuals (open, recorded above): the 4 declared-30s stress
tests (compute gap, next measured campaign round) and
validatePotentialDeadlock (pump fairness for virtual-time drains).

## Phase C — Recorded correctness items

- [x] C1. Inline-class dispatch family: CLOSED BY VERIFICATION — the
      recorded repro (CheckboxSlotDumpTests slot walk) and harder
      shapes (value class behind an interface through generic
      containers/Any casts; ULong-payload value class in Any? slots)
      all pass and match kotlinc/JVM byte-for-byte; fixed by the
      intervening dispatch work. Guards:
      examples/value_class_interface_dispatch.kt,
      examples/value_class_any_slot.kt.
- [x] C2. Private member-extension-property visibility LANDED: a
      PRIVATE member-ext property registers only under its
      owner-qualified key; resolution covers the legal scopes via the
      receiver-tower probe (now walking the WHOLE resolved parent
      chain — JobSupport sits several classes above a coroutine's
      class), an "Any"-key tower probe (`private val
      Any?.exceptionOrNull` registers under recv "Any" while receivers
      have their own heads), and a file-import probe
      (`import Duration.Companion.seconds` — the import fqn minus its
      leaf IS the owner key). NON-private member exts keep the plain
      pair: kotlinc scopes them to the tower too, but the tower
      emulation does not yet see every legal frame — gating them cost
      the compose suite ~400 tests (two traps hit and fixed on the
      way: public Duration companion imports in stdlib TimeMark tests,
      JobSupport under compose). Guard:
      examples/member_ext_prop_visibility.kt (kotlinc/JVM-verified
      shadow/tower/import surface). Ratchet 1372-1373 observed, floor
      trimmed to 1365 (pre-change peak 1375 is inside the ±3 band).
- [x] C3. ktor server/client e2e itests: client GET works END-TO-END
      (status=200) — itest-ktor_client_get 4/4 and channel_async PASS
      after peeling five pre-existing roots, each with a
      kotlinc-verified guard example:
      1. Stored-lambda receiver seating: a `{ scope -> … }` lambda
         stored through a generic slot (`plugins[key] = …`) and
         replayed via `receiver.apply(it)` / `handler(recv, arg)` now
         seats the receiver positionally when the declared arity says
         so (unknown-shape closures; headerless speculative-`it`
         blocks excluded — that exclusion also protects suspend-lambda
         starts whose (receiver, completion) pair must not split).
         examples/stored_lambda_receiver_seat.kt.
      2. `::proceed` inside a receiver lambda binds the receiver's
         member through the capture slot the runtime receiver-binding
         fills (was a KProperty shell / a global miss).
         examples/receiver_member_callable_ref.kt.
      3. The innermost receiver's member outranks a top-level pick for
         bare `::name` refs (stdlib alias intrinsics excluded).
      4. A foreign class's PRIVATE stored field never answers another
         class's private computed property: stored privates now
         register in instance_prop_private, the sgetter virtual walk
         skips them, and owner_applies uses the module-walk ownership
         test (the value-level check misses pack-loaded chains).
         examples/private_stored_no_override.kt.
      5. Pack include: ktor-client-core jvmAndPosix
         `checkContentLength` actual.
      SERVER GATE ALSO GREEN after four more roots (each verified):
      6. Hierarchy ascent by name evidence when a pack shim class's
         cross-root supertype ids never resolved (KlioApplicationResponse
         walked as a leaf, hiding BaseApplicationResponse.status).
      7. Bodyless member declarations join overload ranking: the
         registry records abstract member arities (rides pack images —
         LAYOUT CHANGE, rebuild installed packs), and the inline-target
         pick declines an extension/top-level candidate when an implicit
         receiver's hierarchy declares an abstract member taking the
         call (respond(message, typeInfo<T>()) spliced the reified 2-arg
         respond(status, message), binding CONTENT to status).
         Member-inline picks exempt (DebugPipelineContext.proceed).
      8. Scope-qualified property reads whose lexical-owner premise
         fails (a companion-fn lambda reading the RECEIVER's `call`
         while the outer class declares an instance `call`) retry the
         implicit-receiver candidates with the plain name before
         failing. examples/companion_lambda_receiver_read.kt.
      9. The gate fixtures themselves were ILLEGAL Kotlin (bare
         get/post never imported — kotlinc rejects them); klio's
         unimported-extension leniency resolved them but mistyped the
         handler lambdas' receivers, unbinding `call`. The fixtures now
         import routing.get/post. RECORDED klio-ism: that leniency
         still mistypes receiver lambdas when it engages.
      All three ktor e2e gates green: itest-ktor_server,
      itest-ktor_client_get, itest-ktor_channel_async.
      Also recorded: hangbisect3 shape (foreign private stored + async
      in interface default member) hangs pre-existing — parks both
      coroutines.

## Phase E — Next round (active; worked top to bottom)

- [ ] E1. Free-win harvest + pack hygiene. IN PROGRESS:
      - [x] Pack homes rebuilt on the new image layout (`~/.klio` all
            26 shipped packs, `.klio-local` via install-local-packs;
            both with KLIO_COMPOSE_PLUGIN=1; caches cleared). Corpus
            re-warmed — the 17 "failures" were cold-bake timeouts, all
            pass warm including the heavy four (material3, m3_text,
            multiwindow, window).
      - [x] flow ZIP FIXED (was the recorded receiver-publication
            zip half): the runtime extension-arity check was
            trailing-lambda-blind — `produce<Any> { }` against
            `produce(context=, capacity=, block)` needs only the GAP
            defaulted when the last arg is callable and the last param
            function-typed (extArityApplicableTL). All three produce
            overloads were silently dropped and a lenient tail ran
            produce with the wrong binding, so zipImpl's `second`
            failed the SendChannel cast. Guard examples/flow_zip.kt
            (kotlinc/JVM-verified).
      - [x] flow COMBINE FIXED. Root cause was two-layered. (1) A
            receiver-lambda param invoked bare from inside a coroutine
            lambda must bind the lexically innermost implicit receiver
            of its DECLARED head, and the dynamic enclosing-this chain
            cannot recover it after a pump resume (the chain at the
            call held only FlowCoroutine + SAM-collector closures).
            The lowering now records the declared receiver head per
            receiver-lambda param (decl.zig / lambda_body.zig), walks
            the labeled receiver tower at the captured-RLP call site,
            and lowers the matching `this@<label>` slot (the same slot
            extension-fn entry binds) as the call receiver;
            CallValueWithThis carries `recv_head` so the VM re-selects
            by head (callValueWithThisHead, resel off) when the tower
            gave nothing. (2) Two engagement traps cost most of the
            session: the vmhost re-export for callValueWithThisHead
            was missing so the eval arm's @hasDecl gate silently chose
            the old path, and the flat-call fast path intercepted
            CallValueWithThis before the head branch (now gated on
            recv_head == null). Also: pack BUILD consumes the lowering
            cache — clear `~/.klio/cache` BEFORE `pack build`, not
            just before the run, or the pack bakes stale IR. The
            "receiverless closure" theory was wrong: this@combineInternal
            IS an IrClosure by design (FlowCollector is a fun
            interface; SAM lambdas stay raw closures and bare `emit`
            on one SAM-invokes it). Guard examples/flow_combine.kt
            (kotlinc/JVM-verified).
      NOTE: the cached ratchet binary was pruned with the zig cache;
      ratchet now runs via `zig build itest-compose_plugin_commontest`
      (source floor 1365).
- [ ] E2. hangbisect3 hang: foreign private stored field + async in an
      interface default member parks both coroutines forever
      (pre-existing; standalone repro in scratchpad
      reprosrc/hangbisect3.kt). Suspect: the sgetter member-probe
      rejection (an errRes) unwinding through a suspend frame without
      completing the coroutine.
- [ ] E3. Pump fairness: a virtual-time drain must be able to observe
      the queue empty even when an interpreted worker always wins the
      repost race. Unlocks RecomposerTests.validatePotentialDeadlock
      and the recorded runTest-teardown / "daemon task abandoned"
      family — one mechanism, two symptom groups.
- [ ] E4. Concurrency perf round 3 (the last 4 stress tests, and the
      suite wall): frame-buffer pooling (kills the ~9% memset + the
      per-frame alloc), member-walk string-eql caches (~9%), then
      attribute the ~15% unknown PCs. Need ~1.7x more under
      contention; each lever measured on the addAll_clear rep count.
- [ ] E5. Leniency diagnostic: klio accepts illegal Kotlin (unimported
      extensions) and silently mistypes receiver lambdas. Either type
      them correctly when the leniency engages or emit a real
      "unresolved reference" diagnostic.
- [ ] E6. Deferred measured-first roads, only when a measurement
      motivates: C-transpiler C-to-C frames (A4 continuation), Value
      24 -> 16 (A5), C2 completion (nullable member-ext gating; tower
      strength for public member exts).

## Phase D — Watches (no active work; act when they fire)

- tl_atomic_update_contended litmus flake: postmortem on next natural
  occurrence (the sweep prints got-vs-expected tails now).
- URLBuilder scheme-with-digits ×2: klio matches Kotlin, intentionally
  red upstream — never "fix".
- checkboxLike stays the slot-exact anchor; any emission work re-runs
  GroupSizeValidationTests.

## Done this stretch (index)

ktor commontest 465/468 zero-incomplete; compose remember-family 26/26;
dirty-bits calculus + slot-exact checkboxLike; corpus 315/315 with the
interactive-example contract; coroutine debt closed by JVM oracle;
ratchet floor 1305 -> 1340. Details: `plans/open-campaigns.md`.
