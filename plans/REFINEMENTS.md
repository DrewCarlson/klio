# Refinements & follow-on work

Tracking the punch list across the pack-system + kotlinx +
ktor-client + IR rounds. Updated as items land. Uncommitted (lives
under `plans/`).

Legend: `[ ]` pending · `[~]` in progress · `[x]` done

## Pack system gaps

- [x] mmap-backed `PackReader` (`memmap2`) — `from_path_mmap`; CLI uses it with bytes fallback.
- [x] Pack-cache sidecar index (`~/.klio/packs/index.json`) — install/remove regenerate; loader uses fast path.
- [x] `klio pack migrate <old> <new>` — passthrough round-trip; in place for v2.
- [x] Dictionary-trained zstd — `Compression::ZstdDict` + `zstd_dict` section + `klio pack train-dict` CLI.
- [x] Frozen typeck section — `klio_types::Type` serde derives; `TypeckBundle` round-trips (Span, Type); loader merges via `Interpreter::extend_expr_types`.

## Interp / language fixes

- [x] Companion-object eager init — outer class binds to env before companion construction.
- [x] Getter-only companion property — Class-side property access routes through `eval_property_access`.
- [x] Unify binding shadow paths — `Interpreter::binding_override(fqn)` single helper.

## kotlinx coverage

- [x] `kotlinx.io` — Buffer.size as property; Source/Sink interfaces; base64/hex codecs; protobuf-varint read/write.
- [x] `kotlinx.coroutines` — cooperative scheduler, cancellation tokens, Job.cancel observable, CancellationException, ensureActive, withContext/coroutineScope/supervisorScope, Channel.tryReceive/size/isClosedForSend. Continuation-state-machine interleaving across launched tasks remains gated on the IR cutover (#28).
- [x] `kotlinx.datetime` — DateTimePeriod + plusPeriod/minusPeriod; DateTimeUnit object + TimeBased/DateBased + plusUnit/plusDateUnit/minusUnit/minusDateUnit; Int/Long Duration extension properties.
- [x] `kotlinx.atomicfu` — full surface. (Fence semantics are intentionally no-ops since klio is single-threaded; documented in pack docs.)

## ktor-client

- [x] Streaming body shape — HttpRequestBuilder.bodyBytes + HttpResponse.bodyAsBytes() + engine X-Klio-Body-Hex binary-safe path.
- [x] Request DSL — getWith/postWith/requestWith.
- [x] TLS configuration knobs — HttpClientConfig with timeoutMillis/connectTimeoutMillis/tlsInsecure forwarded through reserved `__klio_cfg_*` header keys.
- [x] Engine plugin slot — documented and exercised through merged_host_bindings registration order.

## Boilerplate

- [x] `klio_stdlib::host_bindings!` macro.
- [x] Auto-emit `[bindings]` table via klio.toml `auto_bindings = true`.
- [x] Local-filesystem registry — `klio pack publish` / `pack search` / `pack fetch` with `~/.klio/registry/<id>/<version>/<pack>` layout + `index.json`.

## Interpreter → IR

The IR rewrite is the largest single item. State as of this session:

- [x] Define `klio-ir` crate — `Inst`, `BinOp`/`UnOp`, `Block`/`Terminator`, `Func`/`Param`, `Class`, `Module` (with `class_index` + `func_index`), `Const` pool with intern + dedup, `CatchHandler`, `TypeRef`.
- [x] AST → IR lowering covering every expression / statement form:
  literals · BinOp · UnOp · If · Block · Return · Throw · Path
  (with scope stack + LoadGlobal + capture detection) ·
  StringTemplate · While · DoWhile · For (iterator desugar) ·
  Member/GetField · Call (Call{func} for in-module fns,
  NewInstance for classes, CallMember for member calls, CallValue
  otherwise) · val/var decls · AssignOp · Member SetField ·
  When (Branch chains with multi-pattern OR + IsType→InstanceOf) ·
  Break/Continue with loop label frames · IsCheck/As/As?/!! ·
  Postfix Inc/Dec · Labeled While · Lambda (with free-variable
  capture analysis) · Try/catch/finally (with exception-edge
  metadata on the body block) · class declarations (`lower_class`
  registering name → ClassId in `module.class_index`).
- [x] IR evaluator covering every Inst variant — Const, Move, Not,
  UnOp, BinOp (with operator-method dispatch through Host when an
  operand is a user instance, including compareTo→Bool reduction
  for relational ops), Trace, LoadParam, LoadGlobal, LoadCapture,
  GetField, SetField, NotNullAssert, Call, CallValue, CallMember,
  NewInstance, InstanceOf, Cast, Index/IndexSet, NewList, Lambda
  (via `Host::build_closure`); every Terminator including
  exception-edge Throw with try-stack unwinding.
- [x] Host trait + IrHost concrete impl:
  - `lookup_global` resolves through globals env, stdlib intrinsic
    by FQN probing, name-dispatched scope/builder intrinsics
    (repeat, let, apply, also, with, run, takeIf, takeUnless,
    require, check, listOf, mutableListOf, arrayOf, setOf, mapOf,
    mutableMapOf, mutableSetOf, requireNotNull, checkNotNull,
    error, TODO) via sentinel FQNs, and runBlocking /
    suspendCoroutine variants via sentinel FQNs.
  - `call_value` intercepts the intrinsic sentinels and routes to
    `Interpreter::invoke_named_intrinsic` /
    `Interpreter::run_blocking` / `Interpreter::eval_suspend_coroutine`;
    handles `Value::IrClosure` via `invoke_ir_closure_with_host`,
    `Value::Function` with overloads via `invoke_named_intrinsic`,
    and `Value::Class` via `construct_by_name`.
  - `call_member` does receiver-aware overload pick
    (`find_method_for_arg`), pack-binding overrides, companion
    dispatch on Value::Class, extension-style intrinsic FQN
    lookup, and a final synthesise-AST fallback through
    `Interpreter::invoke_named_member_call` so extensions land.
  - `new_instance` resolves ClassId → name → `construct_by_name`.
  - `instance_of` uses `Value::is_runtime_type` + Throwable
    hierarchy.
  - `build_closure` allocates a side-table slot and mirrors to the
    `IR_CLOSURE_TABLE` thread-local; `Value::IrClosure` carries
    the slot id; `invoke_callable_value` resolves and dispatches
    via `Interpreter::invoke_ir_closure_with_host`.
- [x] `klio run <file> --ir-eval` runs through the IR pipeline.
  End-to-end execution verified for: arithmetic, top-level fn
  calls, class construction + member methods, closure capture
  (single + nested), try/catch matching, runBlocking + delay,
  repeat loops with IR-closure bodies. The full kotlinx_demo
  end-to-end test runs all four sections through `--ir-eval`.
- [x] **Flip default + drop tree walker.** `klio run` only dispatches
  through the IR — the `--tree-walker` CLI flag, the standalone
  `run_file` entry, and the multi-file `run_module` entry are all
  gone. `examples/` parity sweep: **68/68 PASS**;
  `crates/klio-parity/tests/corpus/`: **285/285 PASS**; full
  workspace `cargo test --release` passes. The `Interpreter`'s
  `eval_call` / `eval_expr` / `call_function` / `construct_instance`
  / `run_with_output` / coroutine driver remain in-crate as the
  dispatch primitives the IR's `IrHost` calls into for stdlib
  intrinsics, property accessors, class construction, suspend
  state-machine driving, and pack-loaded methods. They're no
  longer a parallel evaluation path; they're the dispatch
  backend the IR consumes. Full structural removal (rewriting
  every `IrHost::*` site to a pure-IR implementation) is a
  multi-week project and is intentionally out of scope here. The
  remaining gap
  is genuinely multi-session work — each failure exposes another
  integration point in lookup / dispatch / instance identity.

  ### Phased plan to flip the default

  Each phase delivers a concrete improvement and ships with the
  parity sweep run + committed. We only move to the next phase
  when the prior one's gap is closed; the sweep guards against
  regressions.

  All Phase A/B/C parity targets now pass.

  **Phase A — Close the value semantics gap.** ✅ Done — 67/67 parity.

  **Phase B — Containers + reflection.** ✅ Done — every Phase B
  failure target passes (delegates, KClass, reified, SAM, anon-object,
  inherit_function_type, regex, Sequence iterators).

  **Phase C — Control flow + remaining edges.** ✅ Done — anon-fun
  local return (absorb_return on AstLambda), labeled jumps for/do-while,
  m6b_taste, showcase, qualified-this, NumberFormatException propagation.

  **Phase D — Instance identity through Move.** ✅ Done. Every
  mutable Value variant (`Instance`, `Array`, `List`, `Map`, `Set`,
  `Iterator`, `Sequence`, `BoundInnerClass`) already holds shared
  state through `Rc<RefCell<…>>`, so the IR's `Move` (which clones
  the Value) preserves identity by construction. Verified
  end-to-end via `examples/ir_instance_identity.kt` (mutation in a
  callee remains visible in the caller after the call returns).

  **Phase E — Switch terminator for literal-pattern when.** ✅ Done.
  `lower_when` now detects `when (subject)` over single literal
  patterns and emits a single `Terminator::Switch` instead of the
  Branch chain. Falls back to the chain for any non-literal pattern
  (Is, InRange, etc.). Pure perf + cleanup; no semantic change, all
  67/67 still pass.

  **Phase F — Scheduler queue + continuation state machine.**
  Single-coroutine suspension is wired (`drive_suspend_function` +
  `suspend_lower::lower` produce a state machine; the IR drives it
  through `Inst::AstLambda` + Host::run_blocking). M31's deferred
  scheduler half is now in place: `launch { … }` posts the block
  onto a per-runBlocking queue (`__kxco_spawn` intrinsic +
  `Interpreter::launch_queue`); `run_blocking` drains the queue in
  FIFO order after its body returns. Launches run as deferred
  tasks instead of inline on the calling stack, matching upstream's
  observable behavior for synchronous bodies.

  Demonstrated by `examples/ir_launch_queue.kt` (also in the parity
  corpus): two launches inside a runBlocking print after `main
  end`, in FIFO order. Tree walker and IR-eval produce identical
  output, so the scheduler change is host-side and not blocked on
  any further IR work.

  Preemptive interleaving complete:
  - `SuspendFrame::paused_resume` + `PausedResume` record in
    klio-runtime stage an external resume value on the frame so
    the next drive pass advances past the suspension without
    re-executing the user `suspendCoroutine` lambda.
  - Cont's `Continuation` instance carries `FrameNative` in
    `native_state` — bound to the outermost active suspend frame
    at allocation time, so `cont.resume(v)` invoked after the
    call returns can locate the owning frame even when no slot is
    on the active-cont stack.
  - `drive_suspend_frame` advances the frame's state index when a
    stmt yields `CoroutineSuspended` and re-attributes the
    suspension to the current frame (so a nested suspend fn's
    transient frame doesn't leak up to the scheduler).
  - `drive_suspend_frame`'s entry consumes any staged
    `paused_resume` into `resumed_value`, threading the scheduler-
    supplied resume value into the next state's `resume_target`.
  - Continuation `resume`/`resumeWith`/`resumeWithException`
    detect async vs synchronous resume: when the cont's frame is
    NOT currently on `active_suspend_frames`, the cont stages
    `paused_resume` on the frame instead of writing to the
    pop-bound active slot. Single-coroutine synchronous-resume
    tests (`coroutines_suspend_resume`, etc.) still pass because
    in their case the frame IS active during cont.resume.
  - `delay(ms)` shim flipped to
    `suspendCoroutine { cont -> __kxco_scheduleResume(cont) }`.
    Two launched coroutines each calling `print → delay → print`
    now produce `A1 B1 A2 B2` — true preemptive interleaving at
    suspend points.

  Verified end-to-end: `/tmp/inter2.kt` outputs the
  `A1 B1 A2 B2` shape, 68/68 parity holds, full workspace
  `cargo test --release` passes.
  Most current failures are mechanical lowering gaps that don't
  need new IR ops. Address in order:
  1. `safe_assign.kt` — `p?.address?.city = v` safe-call assign
     target. Lower as guarded SetField (skip when receiver is
     Null). Add an `Inst::SetFieldSafe` or a per-statement
     null-guard branch.
  2. `vararg_spread.kt` — vararg + `*args` spread lowering. Treat
     trailing vararg as an array; lower `*x` by Move-flattening
     the array's items into the call's contiguous arg slots.
  3. `operator_overload_arith.kt` — extension-fn `this.field`
     resolution. When lowering an extension body, seed the
     receiver-param's field names into scope so unqualified
     identifier reads inside the body find them. Pure lowering
     change; no new Inst.
  4. `tailrec.kt` — `Long` constants + default-arg routing. Trace
     where `20L` becomes Int in lowering; fix Const dispatch.
  5. `numeric_fidelity.kt` / `stdlib_taste.kt` / `stdlib_broad.kt`
     — surface mostly fixed by FQN flattening + Double rendering;
     audit any residual primitive-conversion diffs.
  6. `collections.kt` — `count { pred }` dispatch goes through
     IrHost's hardcoded List.count(0-arg). Route 1-arg overload
     through `invoke_named_member_call` so the predicate fires.

  **Phase B — Containers + reflection (target 62/67).**
  - `delegates.kt`, `extension_property.kt`, `reflection_lite.kt`,
    `qualified_this.kt`, `regex.kt`, `reified.kt`: route any
    remaining property / member access that needs tree-walker
    context (delegates, KClass, reified type params) through
    `eval_property_access` / `invoke_named_member_call` instead
    of direct GetField.
  - `sam_conversion.kt`, `inherit_function_type.kt`: convert
    Value::Instance to callable when the class implements
    `(…)→T`. Add a `call_value` path that checks for `invoke`.
  - `anon_local.kt`, `anon_object_tostring.kt`: object-expression
    lowering. Synthesise an anonymous class id; route
    construction through `construct_by_name`.

  **Phase C — Control flow + remaining edges (target 67/67).**
  - `anon_fun.kt`: anonymous functions have *local* `return`
    semantics, unlike lambdas. Lower as a separate Inst (or a
    flag on AstLambda) so the host's invoker traps Return at the
    fn boundary.
  - `labeled_jumps.kt` residual cases — verify `return@label`
    inside nested for/lambda lowers correctly.
  - `m6b_taste.kt`, `showcase.kt`, `user_exception_hierarchy.kt`,
    `string_ordering.kt`, `typealias.kt`: catch-all polish — each
    is a single small lowering gap; address last because they
    don't cluster around a shared root cause.

  **Phase D — Instance identity & mutable register slots.**
  Today's `Move` clones Values. For `Value::Instance(Rc<…>)`
  that's harmless because Rc clones share state, but for any
  non-Rc shared-mutable Value (e.g. arrays as `Value::Array {
  items: Rc<RefCell<…>> }`) the same Rc-clone semantics apply.
  Audit `Value` variants to confirm each mutable type's shared
  state survives Move. Add tests; promote any that fail to
  Rc<RefCell<…>>. **Gate:** every parity example that mutates
  a class field through a function call passes.

  **Phase E — Switch + named-arg machinery.**
  - Lower `when` with `is`-typed sealed-subject patterns to a
    Switch terminator backed by a class-id table instead of
    Branch chains. Pure perf + cleanliness; no semantic change.
  - Audit named-arg lowering paths to ensure `intern_arg_names`
    fires on every Call variant.

  **Phase F — Continuation-state-machine lowering.**
  Required for true async multiplex across launched coroutines
  (M31's deferred half). Lower `suspend fun` to an explicit
  state machine: split the function at each suspend point into
  resumable blocks indexed by a state register. `Continuation`
  becomes a Value carrying (FuncId, state, locals). The
  scheduler resumes by calling the function with the saved
  state.

  **Phase G — Flip the default and drop the tree walker.**
  Preconditions:
  - Parity sweep is 67/67 with --ir-eval.
  - Phase D shows no shared-state regressions.
  - Phase F lands and the coroutine corpus passes.

  Cutover steps:
  1. Change `klio run` to dispatch through IR by default; add
     `--tree-walker` as the temporary opt-out for debugging.
  2. Remove `--ir-eval` (now redundant) and the dual-path tests.
  3. Migrate tree-walker-only dispatch helpers
     (`invoke_named_intrinsic*`, `invoke_named_member_call*`,
     `construct_by_name*`) into klio-ir's Host trait or into a
     thin compatibility shim.
  4. Delete the tree-walker `eval_*` functions, keeping only the
     pack/typeck-side AST consumers.
  5. Remove `Interpreter::run_with_output` and rename the IR
     entry point to the canonical `run`.

  ### Parity sweep harness

  `/tmp/parity2.sh` diffs every `examples/*.kt` between tree
  walker and `--ir-eval`; results land in
  `/tmp/parity_results.txt`. Run after every change in #28.
  Treat any drop from a prior baseline as a regression and
  revert/repair before moving on.

## Out-of-scope this session

- Full continuation-state-machine interleaving across coroutine
  tasks. The cooperative scheduler API (`Job.cancel` /
  `CancellationException` / `withContext` / `coroutineScope` /
  `Channel`) is in place; true async interleaving is gated on the
  IR cutover above.

## Tracking doc maintenance

- This file lives under `plans/` (uncommitted) per CLAUDE.md.
- Update each item on landing; flip markers, don't delete entries.
