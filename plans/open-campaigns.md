# Open campaigns

The five active workstreams, tracked here at one line of truth each; the
detail lives in the linked plan docs. Update the checkboxes and the
"state" lines as work lands — this file is the index, not the log.

## 1. Transpiler speedup + Value 16B

Full plans: `c-transpiler-plan.md`, `value-layout-campaign.md`.

- [x] Value 40 -> 24: RangeIter/Iterator folds; Range/BoundMethod/
      MapEntry/Triple/MatchGroup/Pair/Comparator/Result boxed; Intrinsic
      interned; Array repacked; dead AST-era variants deleted. Verified:
      sweep 117/0, ratchet 1339, rangebench neutral.
- [x] Hot-view sub-ABI landed + measured: +3.2% rangebench RF JIT-off at
      293/293 corpus parity (a14d89e2).
- [ ] RECORDED ROADS (measured-first, not the active front): the 16B
      endgame (IrClosure via side-table id + Array), inline trace store,
      wider hot-op coverage, light-frame C-to-C calls.

State: substance LANDED AND MEASURED; deeper speedup roads recorded in
the plan docs and the handover note below.

## 2. Compose plugin triage residue

The doc's original checklist was stale: entries 43-47, the window
family, foundation_lazy, and serial_names are ALL FIXED (triage memory
54i/54j/54k + entry records; today's corpus = the 3 interactive
permanents + lazy's Debug-CLI time cap + the animation load flake).
The LIVE residue is two emission roots from the triage memory head,
both suite-level (plugin conformance ratchet):

- [x] Local-ext-on-declared-builtin family FIXED (c3f3fc38 + 75a92601):
      the static subtype judgment learned the builtin collection
      hierarchy + the bare-type-param non-refuting rule (the deriver
      leaves factory type args unsubstituted — MutableList<T>).
      MovableContentTests 41 -> 42/44; ratchet 1338; guard example
      local_ext_declared_receiver.kt. Deeper channel recorded: the
      deriver should substitute call-site type args.
- [x] anchorIndex-on-MutableList FIXED: nested splice-window hole —
      a lambda spliced from inside another spliced lambda (let inside
      fastForEach's action) records a caller window whose region
      includes the OUTER inline fn's receiver bind, so bare `this`
      resolved to the outer splice receiver (`scopes`) instead of the
      class instance. Fix: `splice_hidden_bands` stack on FuncBuilder —
      every active window registers its hidden `[caller_depth,
      own_base)` band and the windowed caller scan skips enclosing
      bands. MovableContentTests 42 -> 44/44. NOTE: the wrong spliced
      code lowers in EVERY context but is live only via the pack-loaded
      module (test-file lowering ran an alternate emission), so
      standalone repros pass pre-fix — in-situ probe (println in
      SlotTable.kt + pack rebuild) was the discriminator.
- [x] GroupSizeValidationTests 2 -> 4/5 (uncommitted stretch): two roots.
      (a) file-private classifier refutation — staticReceiverCompatibility
      resolved an unqualified declared head (`Modifier`) module-wide
      (unique-name = null, or the wrong package's namesake), refuting the
      right overload; now resolves in the DECLARATION's file scope
      (exact import, then decl-package FQN — the mangled `$fN` class's
      fqn stays clean — then classIdIndexed). (b) the plugin's
      strong-skipping memo wrap emitted qualified-Path
      `androidx.compose.runtime.remember(keys..., calc)` UNTHREADED,
      which lowered through the arity-blind global-value route and
      invoked the 0-key overload with junk args; the wrap now appends
      the composer pair, multi-segment Path callees route through the
      FQN flatten/global-fit lowering, and the flatten's exact-arity
      match skips vararg decls (fixed-arity wins, Kotlin rule).
- [x] Per-class census (heavies excluded) surfaced two more roots, both
      FIXED: CompositionLocalTests 31/31 — a member overload whose
      declared param type provably rejects the arg now stands aside for
      the same-named extension (`putAll(pairsArray)` inside the stdlib
      `plusAssign` hit the builder's `putAll(Map)`; Array vs non-array
      container heads is now a definite disproof + member walk consults
      it when a surviving extension exists). SlotTableEditorTests
      11/11 — a bare `::ref` to a LOCAL EXTENSION fn now eta-expands
      binding the enclosing implicit receiver (arity carried in the
      inherited local-ext mark). Guard examples
      local_ext_fn_reference.kt, member_arg_disproof_extension.kt.
- [ ] checkboxLike anchor: 24 -> **19** slots (kotlinc 18) after the
      dirty-bits campaign LANDED its core (f6bbd362): per-param
      `$dirty` triples + caller-certainty-guarded probes + call-site
      `$changed` bits (lowering-side, resolved-signature named-arg
      mapping) + zero-key-slot memo shapes (cache from `$dirty`,
      lifted `{}` singletons, cache(false)). Ratchet 1370 rc=0,
      remember-family 26/26, funInterface_isMemoized green. REMAINING:
      the last slot + the 2-group deficit need slot-level attribution,
      blocked on the nested CompositionGroup tooling surface
      (compositionGroups/data on non-root groups are empty/raise);
      full record in plans/compose-dirty-bits-plan.md. checkboxLike
      stays the red anchor until slot-exact.
- [x] CompositionTests remember-family FIXED — 26/26 solo (was ~8
      fails), LocalRememberReproTests 4/4. Three stacked roots, all
      landed:
      (a) OWN-RUN capture shadow: ImplicitCandidate carries an `own`
      bit (the frame's own dispatch receiver + its companion/nesting
      tower); a scoped-capture binding now loses only to the OWN run's
      members — a dispatch-published chain receiver's same-name member
      no longer outranks a captured local, on the read AND write arms
      (`count++` in a local-class init binds the captured `count`, and
      storeGlobal writes through its Cell).
      (b) runtime-lowered bodies know their CAPTURE NAMES:
      registerClassCaptured/buildObject install captured_names via
      build.setLowerAnonCaptureNames; the bare-name classifiers skip
      top-level-const inline / LoadGlobal binding for captured names
      (SlotTableEditorTests' file-private `const val count = 100` was
      const-inlined into another test's local-class init).
      (c) keyChange: delegated-local param shadow — inside compareBy's
      spliced `{ a, b -> compareValuesBy(a, b, selector) }`, `a`/`b`
      resolved to the TEST's `var a by mutableIntStateOf(0)` delegates
      (getValue → Int) instead of the lambda params;
      plainShadowsDelegate walks the scope chain in resolve order and
      an inner plain binding now shadows the delegate read AND
      setValue write-through. Guard examples:
      delegated_var_param_shadow.kt, captured_local_shadows_const.kt.
      Also: intrinsic_host.invokeMethod no longer swallows CalleeFailed
      into a null dispatch-miss (it masked (c) as
      "unresolved global sortWith").
      STILL RECORDED (not blocking any live test here): the private
      member-extension-property visibility gate (plain (recv,name)
      registration leaks program-wide; first gating attempt broke
      JobSupport's `Any?.exceptionOrNull` — needs frame-owner-aware
      visibility, not just the this-chain tower).
- [x] movableContentOf factory wrap RECLASSIFIED latent: the gated
      wrap (movableContent* factory names, compose_pass wrap_ret) is
      in tree and MovableContentTests is 44/44 — no live test pins the
      ungated arms. Widening to all composable-returning factories
      stays recorded (the drafted ungated patch core-dumped with
      10001-frame recursion; bisect plan in triage memory) and waits
      for a failure that names it.
- [x] Group start/end imbalance RECLASSIFIED latent: the tests that
      exposed it (movable multi-ref family) are green after the window
      band + judgment + dispatch fixes; no live failing test remains.
      The op-trace probe recipe stays in the triage memory
      (Operations.kt [op] print with val op0=this.operation) for when
      a shape re-pins it. checkboxLike's SLOT count is the live
      emission-shape anchor instead.

State: CORPUS 315/315 GREEN (2026-08-15) — window, multiwindow,
foundation_lazy, serial_names all pass on warm caches; the three
maxFrames=-1 interactive demos are marked `// corpus: interactive` and
skipped by corpus_check (an Xvfb display exists on this box, so their
until-close loop is the app's specified behavior). Remaining fronts:
the dirty-bits skip calculus (plans/compose-dirty-bits-plan.md), the
two 300s cross-thread Recomposer tests, and the latent items above.

## 3. Coroutine debt cluster

Scattered, each half-diagnosed. No single plan doc yet — write one when
the campaign opens (`COROUTINE-MODEL.md` is the architecture reference).

- [x] with_timeout preempt — STALE: re-verified passing
      (withTimeoutOrNull(5){delay(50)} = null, standalone and nested
      under coroutineScope / withTimeout; fixed by intervening work).
- [x] private_shadow cells — STALE: both val and var shapes print the
      exact kotlinc outputs (distinct per-class cells).
- [x] THE #10 "CHANNEL DEADLOCK" FIXED — it was the LOOP JIT, not
      the channel: a trampolined callee's SUSPENSION propagated as a
      plain error, dropping the JITted loop frame from the
      continuation. A `for (i in 1..N) ch.send(i)` lost every element
      after the ~64-iteration tier-up (KLIO_JIT=0 was the decisive
      bisect; segment-size and capacity sweeps were red herrings, as
      was the entire cross-thread machinery — resumeExternal and the
      mailboxes traced clean). Fix: the trampoline stashes the call
      site's inst+dst on a Suspended result and the interpreter parks
      the frame at the call site (park_out), exactly the interpreted
      protocol. Whole family green: 1..2000 items, 5-actor original,
      worker/inline variants. Guard: litmus
      tl_channel_jit_send_loop.kt (litmus now 45/45). SIDE FIND still
      open: every park/resume cycle leaks one EMPTY TailSeg on the
      suspend-state chain (routeResumedResult re-wraps; empties never
      freed eagerly) — unbounded, benign-looking.
- [ ] combine/zip STILL LIVE (the last of the flow-campaign #3
      family; takeWhile/drop/produce-standalone all pass): zip fails
      `cast to SendChannel` because `val second = produce<Any>{...}`
      inside the pack-lowered zipImpl never binds — TWO stacked roots.
      FIXED HALF: bare `produce {}` statically tied across the 3
      CoroutineScope.produce overloads (all applicable via defaults);
      the extension ranking key now carries Kotlin's
      fewest-defaults-filled tiebreak (9th key slot before identity)
      and the site statically pins produce#2771. REMAINING HALF (the
      receiver-publication campaign again): at runtime the implicit
      receiver chain inside unsafeFlow's anon collect is headed by the
      RAW COLLECTOR CLOSURE (toCollection's `collect {}` lambda passes
      as an IrClosure, `collector.block()` then seats it as the
      block's receiver), so coroutineScope/produce/println all
      member-dispatch against kotlin.Function first and the resolved
      target gets the wrong `this`. combine's `emit` on FlowCoroutine
      is the same seating. Full trace anatomy in triage memory (62).
- [x] Cancellation cluster CLOSED BY RE-VERIFICATION (2026-08-15): the
      flow campaign's recorded repros all pass on current main
      (plans/repros/channel_segment_rotation_break sum=2415,
      channel_worker_send_park_lost_wakeup sum=5050, both matching the
      JVM oracle; combine_captured_param_typeparam_cast is a distilled
      erasure probe the JVM itself CCEs on — not an oracle), and the
      litmus tl_cancel_* family is green in the 45/45 baseline.
- [x] Unconfined event loop: eager start (guard
      unconfined_starts_eagerly.kt), yield order (oracle-verified, see
      below), and the manual CancellableContinuation save/resume crash
      (`get_field context on Unit`) all pass on current main — the
      save/resume shape now matches the JVM byte-for-byte (guard
      cancellable_continuation_save_resume.kt).
- [ ] tl_atomic_update_contended litmus flake (timeout under load;
      the sweep now prints got-vs-expected tails, so the next natural
      occurrence is postmortem-able)
- [x] tl_yield_cross_thread_teardown "flake" was the litmus sweep's
      expectation PARSER stopping at the first code line (bottom-of-
      file //> lines read as empty). Fixed; litmus baseline is now
      45/45 — any litmus failure is REAL.
- [x] The recorded #10 five-actor channel deadlock was the LOOP JIT
      dropping a suspended loop frame from the continuation (fixed;
      litmus guard tl_channel_jit_send_loop.kt) and the park/resume
      empty-TailSeg leak is fixed too (chains hold at one segment;
      ratchet 1353 with DNC classes 3 -> 2).
- [x] Stale-killed on re-verification: with_timeout preempt,
      private_shadow val+var, atomicfu SupervisorJob CAS. Unconfined
      yield ORDER: ORACLE RUN (kotlinc 2.2.20 + kotlinx-coroutines
      1.9.0 on JVM, toolchain in the session scratchpad) — the JVM
      prints U1 U2 L1 L2, exactly klio's order. NOT a bug; guard
      example unconfined_yield_order.kt pins it.
- [ ] Background-yield 55s cost (suite-perf memory) — PERF, not
      correctness; parked with the suite-wall floor.
- [x] CompositionTests.testCompositionAndRecomposerDeadlock +
      PausableCompositionTests.markInvalidFromBackgroundThread —
      RECLASSIFIED (2026-08-15): no stall remains. The deadlock test
      PASSES solo under the census recipe (10s virtual cap); the
      markInvalid test PASSES in 40s wall once the virtual timeout
      admits it (kotlinx_coroutines_test_default_timeout=600s) — its
      body runs 10,000 interpreted background invalidates (repeat(1000)
      × 10 launches + joins), which is the compute-heavy category from
      the suite-wall profile, not a cross-thread dispatch loss. Under
      the census's 10s cap it reports UncompletedCoroutinesError by
      design; it counts as wall-capped in the ratchet, not as a bug.

State: CORRECTNESS COMPLETE (2026-08-15). Every recorded coroutine bug
is fixed, oracle-verified not-a-bug, or reclassified compute-heavy;
what remains is one perf item (background-yield 55s, parked with the
suite-wall floor) and the tl_atomic_update_contended flake watch
(postmortem-able on next natural occurrence — the sweep prints
got-vs-expected tails).

## 4. ktor_commontest upstream fails

Reference: `KTOR-SERVER-UPSTREAM.md`. The recorded "292" was stale AND
inflated by a stale-pack census trap: the itest REBUILDS all five packs
before running — a census against old installed packs fails 100%.
Fresh-pack per-class census (43 files, ktor-io/utils/http common
tests): 322/444 passing at the start of this stretch.

- [x] Triage: the DOMINANT class was not interpreter bugs at all — the
      io.ktor pack's curated `include` lists simply omit upstream files
      the tests exercise (Base64, Crypto/Hash/Nonce, converters, date
      parsing, Cookie/Mimes/FileContentType/AcceptEncoding,
      LineEnding(Mode)/ByteChannelScanner/SinkByteWriteChannel...).
      Recipe proven and applied in three batches: 322 -> 399/444
      (Base64Test, AcceptEncoding, ContentType*, CommonHeaders,
      RenderSetCookie, GMTDate*, ReadLine 22/25... whole classes to
      green). One trap: a speculative include (IpParser.kt) pulled the
      unconsumed parsing DSL and broke the whole bake — add only files
      a failing test names, drop on bake error.
- [x] Interpreter root-causes landed off the cluster list (each with a
      guard example; commits 21186c6e, 44471f59, eac108fa):
      * anon-object method params typed by the ENCLOSING declaration's
        type params registered + consulted in the anon disproof, so an
        unrelated class named `Key` no longer refutes `add(element: Key)`
        (ConcurrentSetTest 1/10 -> 10/10).
      * `return@inlineFn` across nested inline splices resolves at
        lowering (InlineReturn carries the fn name), and a label crossing
        a REAL frame inside a spliced body is absorbed by a runtime
        `Block.lr_absorb` region at the splice join (CookieDateParser
        4/4). Image FORMAT_VERSION 45 -> 46.
      * companion members through the class name bind with a leading
        defaulted param skipped (trailing-lambda pmo remap + named-ladder
        companion forwarding): `StringValues.build { }`, `Parameters
        .build { }` (UrlTest testEncoding included).
      * intrinsic applicability predicates consulted unconditionally;
        `String.repeat` declines non-(Int) calls — a bare `repeat(n){}`
        against an in-scope String receiver silently NO-OPED (this also
        produced the CookieDateParser NumberFormatException).
      * `typeOf<T>()` carries generic ARGUMENTS end-to-end (full-spelling
        reified stamps + KTypeProjection materialisation)
        (DataConversion 4/4); tuple `contains` dispatches user equals
        through Pair components (MimesTest 3/3).
      * `object : Iface by <expr> {}` evaluates the delegate through a
        site-cached thunk (SinkByteWriteChannel 4/4); KClass.isInstance
        agrees with `is` via the registry walk (ByteChannel 13/13).
      * `io/ktor/util/ByteChannels.kt` include (copyToBoth; ChannelTest
        21/22 -> full class green).
- [x] Second interpreter batch (commits 44471f59, eac108fa, 036aa54a,
      3776afc5): full-spelling reified stamps + KType arguments; tuple
      contains via user equals; anon-object interface delegation thunks;
      KClass.isInstance registry walk; spliced-receiver-lambda bare reads
      prefer a window member the head declares (the whole URLBuilder
      `parameters`-as-Function family); trailing-vararg element
      adjudication + Pair-component disproof (StringValues 9/9); range
      literal peer widening (list-of-ranges vs Long peer).
- [x] FINAL census: **465 passed / 2 failed / ZERO incomplete** — the 2
      = URLBuilder scheme-with-digits (klio MATCHES Kotlin; do not
      "fix"). RangesTest.testResolveRanges CLOSED (27/27 solo): the
      self-recursive member bind now defers to the runtime walk when an
      argument's generic content is unresolved (`List<*>` from the
      un-derived map), and argDefinitelyNotParamType refutes a List of
      Long-kind Ranges against an invariant `List<IntRange>` param, so
      the walk binds kotlin.test.assertEquals exactly as kotlinc does
      (guard: examples/member_invariant_arg_delegation.kt). The
      fast/flat `eq(0, 0L)` peer-widening gap is ALSO fixed
      (leafExprServeAt applies coercePlanFor; guard:
      examples/generic_literal_long_widening.kt).
- [x] Census before those last fixes: 464 passed / 3 failed / 0 incomplete
      (was 322/444-ish at the stretch start; the deadlocked classes'
      tests now all count and PipelineTest is 18/18 in 10s). Latest
      landing (e2200304): CallValueOrMember's non-invocable arm walks the
      outer implicit receivers on the canonical miss — a NON-callable
      captured local (val pipeline = pipeline()) no longer strands the
      enclosing member. LANDMARK (704597a0):
      the inline `synchronized` actual leaked its monitor on NON-LOCAL
      RETURN/exception exits; TestCoroutineScheduler.tryRunNextTaskUnless
      returns from inside synchronized(lock), so under runTest the root
      thread owned the scheduler lock forever and every cross-thread
      resume spun in registerEvent's monitorEnter — the ENTIRE
      GlobalScope.writer/reader deadlock family. try/finally fixed it:
      CoroutinesTest 2/2, WriterReaderTest 4/4, PipelineTest completes
      solo at 14/18 (census 180s cap still cuts it; its 3 `pipeline()`
      member misses on DebugPipelineContext = the receiver-publication
      campaign — the intercept lambda's dynamic chain lacks the lexical
      test-class this; +1 asyncFork daemon-abandonment tail). Pack-baked
      splices carry the old enter/exit sequence until rebuilt. Landed since the 435
      snapshot: named args on RESOLVED member calls bind by name
      (ReadLineTest 25/25 with the exact-limit pair), partial-index
      overload repick + eager unresolved-param gate
      (ByteReadChannel(byteArray) overload), and the pack-scale
      String-factory scope fix (plans/repros/pack_scale_repeat_echo.md —
      RESOLVED; shadowedByClass now tier-filters factory competitors,
      fixing "A".repeat receiver-echo in fully-loaded homes and both
      remaining ReadLine/Utf8 limit tests). The tail:
      * ReadLineTest 3 + ReadUtf8LineTest 1 — suspend-resume local
        corruption family (`readBuffer.buffer` reads a ByteArray /
        `.length` on Int AFTER an awaitContent resume in a frame with
        local fns + local extension fns — repro scratchpad/rl1.kt).
      * URLBuilderTest 2 (scheme-with-digits) — matches Kotlin semantics:
        upstream URLProtocol's own `require(name.all { it.isLowerCase() })`
        rejects digit schemes on the JVM too (verified against
        Character.isLowerCase); how upstream CI passes these is unclear —
        do NOT "fix" klio to diverge.
      * CodecTest.testFormUrlEncode — FIXED: bareCallReturnTypeRef's
        sole-bodied-candidate fallback now respects the extension
        receiver (kotlinx's deprecated `Flow.flatMap` was the sole
        bodied 1-arg candidate in the pack universe and stamped
        `declared=Flow` on a Set-receiver chain).
      * RangesTest.testResolveRanges — FIXED (27/27 solo; see the final
        census entry above for the two-layer mechanism).
      * CoroutinesTest (GlobalScope.writer/reader deadlock — parks with
        ~2s user time over minutes; task #31 territory), PipelineTest,
        WriterReaderTest — INCOMPLETE at the census cap.
      * Side find: fast/flat `eq(0, 0L)` peer widening — FIXED
        (leafExprServeAt applies the coerce plan).
- [ ] Risk note: the widened includes are validated by the commontest
      census only; the ktor_server/client e2e itests gate them in CI.

State: the big clusters are fixed at interpreter root-cause; the tail is
enumerated above with repros.

## 5. Suite-wall profile

The pending question from the compose suite perf work: is
SlotTableBuilder's buildSubTable an O(n^2) pathology or genuine compute?
Reference: memory klio-compose-suite-perf; `BENCHMARKS.md` for harness
practice.

- [x] Profile buildSubTable under KLIO_PROF (`klio test` now honors
      KLIO_PROF like `run` does)
- [x] Verdict: NOT a pathology. oneRectBenchmarkSimulation solo = 56.7s,
      57k samples with NO dominant user frame — time spreads across
      generic dispatch (runFrameExec/execInst/member dispatch), ~8.6%
      memset (regs/array-init churn), ~8% name-keyed hashmap equality.
      Genuine interpreted compute; the floor stands until a generic
      interpreter-speed lever (the JIT is off under `klio test` by
      design, and the loop JIT measured unhelpful on this workload).

State: DONE — floor recorded here and in memory.

## HANDOVER NOTE (Value=24 VERIFIED)

The whole 24B tier is done: Triple boxed, MatchGroup boxed (shared
descriptor struct), Intrinsic INTERNED (immortal records — no refcount,
no GC), Array REPACKED (the boxed/scalars tag was derivable from
`prim == null`, so the payload is (cell ptr, prim) with storage()
rebuilding typed handles). Census: Value 32 -> 24, NO payload >= 24.
rangebench 82.6s (band 83.0-83.7 — neutral/slightly better); units
zero-leak; hello smoke green. VERIFIED: sweep 117/0, corpus + compose slice at
baseline, litmus 43/44 (only the yield flake), plugin ratchet 1339
(ABOVE the 1337 baseline; the GC-stress step green).
16B wave state: Pair BOXED; dead AST-era variants (Function,
BoundUserMethod, BoundInnerClass) DELETED (net -74 lines, sweep 117/0).
Comparator BOXED (sweep 117/0), Result BOXED (units zero-leak). The
16B ENDGAME is now a recorded measured-first road, NOT the next step:
only IrClosure ({id u64, captures ValueSlice} — the side table already
keys canonical captures by id, so the payload could become the bare id
IF the per-value dup'd captures snapshot is semantically redundant —
verify against the closure invoke path before touching) and Array
remain at 16, both hot, and 24 -> 16 pays only if BOTH shrink. Measure
Value=24's own wins first (rangebench + suite wall vs the 40B-era
records). HOT-VIEW SUB-ABI LANDED (a14d89e2): the emitted C inlines
const_int/move/bin/cmp_br over the runtime-measured layout slot —
Int/Int + Long/Long + mixed-width promotion with applyBinop-exact
semantics, per-op helper fallback everywhere, gated on KV.usable
(computed from reclaimRequested; the live per-thread flag sampled too
early left the path dark — found via the layout probe). MEASURED:
rangebench RF JIT-off 13.38s native vs 13.82s interp = +3.2% at full
293/293 corpus parity. Honest reading: the fused stream was already
cheap, and the remaining per-iteration costs (edge guard, trace
bookkeeping) are SHARED with the interpreter — next recorded levers are
an inline trace store (frame.cur_span offset via the same probe
mechanism) and wider op coverage. Item 1's Value+transpiler substance
is landed-and-measured; the deeper speedup is an open recorded road
alongside the 16B endgame. Items 2-4 are NOW the active front.

## previous note (Value=32 landed, superseded above)

The Iterator fold landed (2a6e72f3): census Value 40 -> 32, units green
zero leaks, rangebench 83.0s (inside the pre-fold band), sweep 117/0,
corpus/litmus at the known baseline. Before the NEXT wave: run the
compose warm+slice and the plugin ratchet once against this commit.
Next in item 1: the 24B tier (Intrinsic, Array, Triple, MatchGroup,
then Pair/IrClosure/Function/...) boxes for Value=16, paired with the
transpiler hot-view sub-ABI so scalar offsets freeze once; then the
rangebench speedup number. Items 2-4 (compose triage, coroutine debt,
ktor) follow per their sections above.
