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
- [ ] checkboxLike = the SLOT-EXACT emission anchor: klio emits 21
      slots memo-off / 24 memo-on vs kotlinc's 18 cap (groups fine at
      6 <= 8). The excess predates memoization — this is the measuring
      stick for the group/slot emission-shape debt below. MEASURED
      NEGATIVE: skipping the 0-capture memo wrap BREAKS
      funInterface_isMemoized (the VM builds a fresh closure per
      execution — ir-closure#542 vs #904; the
      non_capturing_lambda_identity guard exercises a different path)
      and does NOT reduce checkboxLike's slots (still 24). ROOT NOW
      FULLY CHARACTERIZED (slot dump via in-situ CompositionGroup.data
      print in slotExpect): the +6 excess = memo KEY slots — klio's
      `remember(k1,k2){lam}` stores each captured key, while kotlinc
      keys the memo on per-param `$dirty` BIT-TRIPLES (zero key slots,
      one cache slot). A coarse single-bit condition is NOT a shortcut:
      it over-invalidates and breaks funInterface_isMemoized (identity
      must survive recompositions where the captures did not change).
      The fix is the skip-calculus upgrade to kotlinc's per-param
      changed/dirty bit layout (3 bits per param + child-call masks) —
      a campaign of its own; checkboxLike stays its ratchet test.
      Closure interning at buildClosure is the companion road (UNSOUND
      naively — closures capture the creation-time receiver chain).
- [ ] CompositionTests remember-family (~8 solo fails:
      testSimpleRemember, testRememberOneParameter..Five, keyChange,
      testApplierBeginEndCallbacks) — ROOT DIAGNOSED, campaign-sized:
      a LOCAL class declared in the compositionTest suspend lambda has
      its `count++` init resolve `count` through the DYNAMIC runtime
      receiver chain instead of its lexical scope — the walk finds a
      REAL `count` member on a scheduler/machinery receiver (=100 after
      100 virtual frames), and the write falls to the name-keyed global
      (assert then reads 101). Repro family
      scratchpad/reprosrc/LocalRememberReproTests.kt (zq-renamed
      variants pass after the read-tier fix; `count`-named still hit
      the dynamic-chain member). LANDED SO FAR: bare-name reads now
      rank an active scoped-capture layer ABOVE implicit receivers'
      EXTENSION properties (AwaiterQueue's `private inline val
      Int.count` was hijacking any unresolved `count` via chain Ints).
      REMAINING (the campaign): (1) receiver-PUBLICATION discipline —
      seeding local-class instances with a RegisterClass-time chain
      snapshot was MEASURED NEUTRAL (reverted): the captured chain is
      itself dynamically over-wide because evtls.active_chain
      accumulates every published receiver up the call stack; the chain
      must carry only lexical implicit receivers; (2) scoped-capture
      layer writes must
      round-trip through the captured CELL (StoreToThisOrGlobal
      currently clobbers via storeGlobal); (3) the private
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

State: opened this stretch; both roots recorded with probes and bisect
plans in memory klio-compose-plugin-triage.

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
- [ ] Cancellation cluster (flow campaign residue)
- [ ] Unconfined event loop (= createEventLoop debt)
- [ ] tl_atomic_update_contended litmus flake (timeout under load)
- [ ] tl_yield_cross_thread_teardown litmus flake (the every-battery
      43/44; rc=0 with a missed teardown yield)
- [ ] Background-yield 55s cost (suite-perf memory)
- [ ] CompositionTests.testCompositionAndRecomposerDeadlock +
      PausableCompositionTests.markInvalidFromBackgroundThread — both
      eat the 300s wall cap solo (background-thread scheduling /
      teardown deadlock family; from the compose DNC audit)

State: not started.

## 4. ktor_commontest upstream fails

292 upstream test failures, unmapped. Reference: `KTOR-SERVER-UPSTREAM.md`.

- [ ] Triage the 292 into failure classes
- [ ] Fix by class, ratchet the count

State: not started; least-known of the five.

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
