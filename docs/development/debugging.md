# Debugging the interpreter

Every diagnostic and tuning knob in klio is an environment variable,
read at process start or on first use. This page catalogues all of
them, grouped by subsystem, with the exact accepted values and the
stderr tag each one prints. All of them are safe to combine.

## How the switches parse

Four idioms cover almost every variable:

- **Presence flags**: setting the variable to anything (even the
  empty string) enables it; only unsetting disables it. Most trace
  switches work this way (`KLIO_ERR_TRACE=1`).
- **Truthy flags**: non-empty and not `"0"` enables; `=0` or empty
  disables. Used where a default-on feature needs an off switch
  (`KLIO_SEMA_IMAGE=0`) and by a few gates
  (`KLIO_TRACE_PATH`, `KLIO_TRACE_INVARIANTS`).
  The tables below say "`0`/empty off" for these.
- **Name filters**: the value is a function/type name the trace is
  restricted to, matched exactly (`KLIO_MISS_TRACE=maxOf`) or as a
  substring (`KLIO_SUBTYPE_TRACE=Comparable`); the tables say
  `<name>` or `<substr>`.
- **Numbers**: a count, size, or interval, noted per variable.

Two cross-cutting caveats:

- The variables are read through libc `getenv`, so they work in every
  libc-linked binary (`zig-out/bin/klio`, the harness, itest
  children) but are inert in the no-libc module unit-test binaries.
- `zig build` run steps forward only a fixed passthrough list to
  their child processes (`interp_env_keys` in `build.zig`):
  `KLIO_RACE_JITTER`, `KLIO_MAX_EVAL_DEPTH`, `KLIO_THROW_TRACE`,
  `KLIO_TRACE_RESOLVE`, `KLIO_TRACE_INVARIANTS`,
  `KLIO_TRACE_PATH`, `KLIO_TRACE_HTTP`, `KLIO_LINK_AUDIT`,
  `KLIO_STDLIB_PACK`, `KLIO_PACK_DIAG`
  (plus, for fuzz suites, `KLIO_FUZZ_SEED`, `KLIO_FUZZ_SEEDS`,
  `KLIO_SKIP_KOTLINC_PARITY`, `KLIO_KOTLINC_JVM_HOME`,
  `KLIO_KOTLINC_NATIVE`, `KLIO_NO_AUTO_INSTALL_KOTLINC`,
  `KONAN_DATA_DIR`). Exporting
  any other variable reaches `klio run` directly but not a
  `zig build itest-*` child; run the installed itest binary or the
  klio binary by hand instead.

## Dispatch and resolution traces

Runtime dispatch is the Vm side (`interp_ir/vm`); bare-call
resolution against the module's tables is `ir/core`. The static/dynamic
pair to reach for first is `KLIO_BARE_TRACE` (what the tables picked)
plus `KLIO_MISS_TRACE` (which runtime tail missed).

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_BARE_TRACE` | `<name>` | How a bare call `name(...)` statically resolved during lowering: the chosen overload (fqn, params, ext, emit form) or `NONE` with the resolver's deferral reason; each candidate's parameter count, default flags and declared arity against the wanted arity; the composer-ABI direct and threaded verdicts | `[bare]`, `[bare-cand]`, `[abi-direct]`, `[abi-retry]` |
| `KLIO_EXT_TRACE` | `<name>` | How an explicit-receiver extension call resolved during lowering: receiver type, implicit dispatch owners, lexical owner, and exact target; also the static member-resolution verdict and self-recursive-bind arg shapes for `name` | `[ext-static]`, `[member-static]`, `[self-rec-shape]` |
| `KLIO_MISS_TRACE` | `<name>` (two field-miss sites fire on any set value) | Runtime dispatch tails for `name` that miss or fall back, with frame-chain dumps at several sites; also the member overload scorer's per-candidate verdict and the argument shapes it scored against | `[member-miss]`, `[miss]`, `[extfb]`, `[pno]`, `[cno]`, `[setfield-miss]`, `[lg-tail-a]`, `[lg-tail-b]`, `[ltg-tail]`, `[cmg-tail]`, `[sam-inv]`, `[rim]`, `[rim2]`, `[pmo-shape]`, `[pmo-multi]` |
| `KLIO_CMG_TRACE` | `<name>` | Snapshot of `CallMemberOrGlobal` preconditions for `name` (receiver tag, constructor-likeness, enclosing fn, this-index, capture count), plus every static `Call` of `name` with its first argument values (scalars and instance class@identity) and a `[frame-push]` line whenever a frame for `name` is entered — the arg/param values make stale-object reads visible at the call site | `[cmg]`, `[call-inst]`, `[frame-push]` |
| `KLIO_NU_TRACE` | `<name>`, or `1` for all at some sites | Candidate/visibility detail for hard dispatch cases: interface factories, member-extension visibility, strict extension member calls, enclosing-scope resolution | `[eev]`, `[ifact]`, `[mev]`, `[meoi]`, `[par-miss]`, `[strictext]`, `[sbc]` |
| `KLIO_SAM_TRACE` | set | Implicit-receiver candidate walk and member-arm dispatch shapes | `[sam-walk]`, `[sam-direct]`, `[sam-arm]`, `[marm]` |
| `KLIO_HEAD_TRACE` | set | Runtime head-directed receiver re-selection for `CallValueWithThis` instructions carrying a declared receiver head | `[cvth]` |
| `KLIO_SDU_TRACE` | set | Every stdlib member-dispatch call that missed both resolve-cache tiers and runs the uncached probe ladder (type, name, cacheability) | `[sdu]` |
| `KLIO_SELDBG` | set | Why an intrinsic-host `invokeMethod` probe declined (error tag + message for each swallowed non-Throw error — the recipe that separates "method missing" from "method ran and failed") | `[seldbg]` |
| `KLIO_ADM_TRACE` | set | Callable-vs-class adjudication detail inside `argDefinitelyNotParamType` | `[adm]` |
| `KLIO_EF_TRACE` | `<name>` | Emit-form / member-shadowability decision for a named call (inline target chosen, shadowable routing, receiver-context flags) | `[ef]`, `[tbie]`, `[efset]` |
| `KLIO_EXTKEY_TRACE` | `<fid>[,<fid>]` | The eight-element extension ranking key for the named candidates, plus their parameter type heads. Ranking is lexicographic, so the first differing component is the one that decided | `[extkey]` |
| `KLIO_SUBTYPE_TRACE` | `<substr>` | Instance-supertype search during overload scoring, for target types containing the substring | `[sub]` |
| `KLIO_SHADOW_TRACE` | set | Whether an imported pack extension shadows a member call (probe plus each candidate) | `[shadow]` |
| `KLIO_EXT_AUDIT` | `1` | Dual-compute audit for extension dispatch: the declaration a commit at lowering would name (`would`) beside the one the runtime's by-name walk serves (`ran`). Join them with `scripts/ext_audit_sweep.py` | `[KLIO_EXT_AUDIT]` |
| `KLIO_THIS_EXT` | `0` | Leaves bare `this` in an extension function body without a recorded class identity, so a wrong answer can be told from a wrong reading of one | |
| `KLIO_DISPATCH_TRACE` | set | Runtime: a member-extension frame that had to derive its own dispatch receiver from the enclosing chain because no caller handed one over (`[dispatch-fallback] fn= found=`), and a contextual frame that had to derive a context parameter the same way (`[context-fallback] fn= idx= ty= found=`); a producer is missing at whichever call site reached it. Static: how a context argument resolved at a call site, the scope, the subjects and the receiver tower it saw (`[context-arg] want= ...` then `-> <reg>` or `-> null`), a `contextOf<T>()` with nothing of that type in scope (`[context-none] ty= fn=`), and the context types a lambda literal was given from its expected type (`[lambda-ctx]`) | `[dispatch-fallback]`, `[context-fallback]`, `[context-arg]`, `[context-none]`, `[lambda-ctx]` |
| `KLIO_SLOT_TRACE` | set | Why a field read on the enclosing `this` did or did not claim a declared slot of its class's published layout: no owner, no class id, no layout (with the state), not a slot, or a capture | `[slot]` |
| `KLIO_CGEN_REACH` | set | What `klio transpile --native <file.kt>` reaches from `main`: every function (program or base) with its instruction count, every native with its binding, the classes it constructs, the slots it dispatches, its statics and closures, and a count of each instruction kind. The backlog for widening the native backend | `[reach]` |
| `KLIO_CGEN_DUMP` | `<substring>` | The resolved instructions of every function whose name or FQN contains the substring, as `klio transpile --native` sees them | (none) |
| `KLIO_ICRT` | `1` | Each return-type instantiation's pre-solve state and terminal (`OK`, `bindings incomplete`, `star head`), plus which parameter refused the bind and both sides' argument counts — a `param=x(Array nargs=1) actual=Array nargs=0` row means the ARGUMENT's recorded type dropped its arguments, not a real mismatch | `[icrt]` |
| `KLIO_MAX_WORKERS` | `<n>` | Caps BOTH the dispatcher pool's compute width (default: half the cores) and its elastic IO ceiling (default: max(16, cores)). Raise it when a single instance owns the machine; the commontest sweep sets `2` for its children so a full sweep stays near half the cores | — |
| — | — | NOTE: any captured log carrying `$class$` identity-mangle rows embeds NUL bytes and is BINARY to grep — filter with `grep -a`, or matching rows silently vanish and a dump looks nondeterministic | — |
| `KLIO_BIND_LUB` | `0` to disable | Off, a generic call's type-parameter constraints must be EQUAL across the receiver and every argument — a subsumed constraint (`getOrDefault(k, Derived())` on a Map of Base, `listOf(Derived(), base)`) rejects the instantiation again | — |
| `KLIO_TP_DISPROOF` | `0` to disable | Off, a receiver type argument that is a declared TYPE PARAMETER stops disproving concrete-element extension candidates (`Array<T>` no longer rules out `Array<out Double>.minOrNull`) | — |
| `KLIO_SOLE_EXT` | `0` to disable | Off, the single extension candidate left after the disproof pruned every competitor is withheld again instead of committed | — |
| `KLIO_DISPROOF_TRACE` | set | Per-candidate receiver-compat decision in extension resolution: subtype result and both disproof-completeness answers | `[disproof]` |
| `KLIO_LAMBDA_REFUTE` | `0` to disable | Off, a lambda argument stops refuting candidates whose parameter names a resolvable non-fun-interface class | — |
| `KLIO_NAMED_COMMIT` | `0` to demote | `0`, a candidate that named-argument mapping skipped stays a typing-only answer instead of committing for emission | — |
| `KLIO_RECV_REFUTE` | set to enable (default off) | On, a candidate whose declared receiver classifier is provably unrelated to the proven static receiver is dropped outright (kotlinc's static receiver semantics; the lazy default keeps runtime-polymorphic leniency) | — |
| `KLIO_STAR_RET` | `0` to disable | Off, a type parameter still unbound after the receiver and every argument had their chance refuses the whole return instantiation instead of erasing to `*` | — |
| `KLIO_SLOT_TRACE` | `<name>` or `*` | Each inherited-slot merge decision for methods of that simple name: the competing FuncIds and which one the class's table keeps | `[slot-merge]` |
| `KLIO_SLOT_DUMP` | `<name>` | Every `(class, slot) -> implementation` entry whose target has that simple name, with the target's owner — what runtime virtual dispatch will actually reach | `[slot-dump]` |
| `KLIO_APPLIC_TRACE` | set | Candidates the shared applicability scorer refuses: the runtime re-pick's null scores and the named-arm hard-reject site that declined | `[pp-null]`, `[applic-reject]` |
| `KLIO_BARG_TRACE` | `<fn name>` (`[barg-ids]` rows fire on any set value) | Static bare-call argument compatibility: per-argument param-vs-arg verdict with route, plus the receiver class-id scoping rows | `[barg]`, `[barg-ids]` |
| `KLIO_BCC_WHY` | set | Why the package/import-scoped bare-call candidate set came back empty (no candidates, no visible tier, other-package tier, no arity match) | `[bcc]` |
| `KLIO_CIX_TRACE` | `<class name>` | Scoped class-by-simple-name resolution: each candidate's fqn, package, and tier | `[cix]` |
| `KLIO_DROP_TRACE` | `<name>` | Why each bare-call candidate dropped from the applicable set (form mismatch, low priority, no sig view, inapplicable shape, static-incompatible) | `[drop]` |
| `KLIO_GRA_TRACE` | `<receiver head>` | The generic-receiver applicability walk for actual receivers with that head: head relation, binding failures, and per-param bound checks | `[gra]` |
| `KLIO_HOP_TRACE` | set | The `+`/`-` operator's member-call lowering channels, and a type-parameter-headed receiver substituting its full bound before extension ranking | `[binop-in]`, `[binop]`, `[hop]` |
| `KLIO_OVERRIDES_TRACE` | set | Why `overridesSlot` rejected each (own method, inherited slot) pair: missing sigs, kind/arity mismatch, no ancestor bindings, param-type mismatch | `[ovr]` |
| `KLIO_PROMO_NAMES` | set | Member-promotion proof verdicts, each `PROMOTED`/`HELD` with the refusal reason | `[promo-ext]`, `[promo-proof]` |
| `KLIO_REX_TRACE` | set | Extension-resolution ranking, one window per call: the call row, per-candidate state, each scored key or disqualification, and the exit reason | `[rex-call]`, `[rex]`, `[rex-key]`, `[rex-exit]` |
| `KLIO_RH_TRACE` | set | Each receiver-lambda body head the type checker records for the eager channel | `[rh-put]` |
| `KLIO_RMC_TRACE` | `<name>` | Per-candidate member-args-compatibility verdict during member resolution | `[rmc]` |
| `KLIO_SCORE_TRACE` | set | The applicability scorer's per-argument refusals: parameter vs argument type at each null score | `[score-null]` |
| `KLIO_SMAC_TRACE` | `<fn name>` | Static member-args compatibility: entry state and each argument's instantiated-parameter verdict with route | `[smac]`, `[smac-arg]` |

The `0`-to-disable rows above exist so one binary can be compared against
itself: `scripts/examples-ab.sh KLIO_SOME_GATE` runs the examples corpus both
ways and reports what differs. It skips the twelve examples that never
terminate (each blocks on a window or event loop at ~0% CPU, at every commit) —
left in, they cost twice the timeout apiece for no signal and turn a five-minute
comparison into a three-hour one.

| `KLIO_GLOBAL_TRACE` | `<name>` | Which arm resolves a global lookup: cached value, function, or intrinsic, with the instance address; a file `<clinit>` binding the name prints `arm=init` with the host, its globals scope, the thread and the frames that drove it | `[gtrace]` |
| `KLIO_CAS_TRACE` | set | Every atomicfu `AtomicRef.compareAndSet`: the atomic, the current and expected values with their addresses, and whether it swapped | `[cas]` |
| `KLIO_OUTER_TRACE` | `<substr>` | Inner-class enclosing `this@Outer` selection for IR names containing the substring | `[outer]` |
| `KLIO_REBIND_AUDIT` | set | Arity-guess `this` rebinds during closure invocation | `[REBIND]` |
| `KLIO_TRACE_RESOLVE` | `name1,name2` or `*` | Per-dispatch decision log for the named function(s) | `[RESOLVE]` |
| `KLIO_TRACE_PATH` | set; `0`/empty off | One structured record per terminal dispatch site (proves single-path dispatch; see `scripts/assert_single_path.py`) | `[PATH]` |
| `KLIO_TRACE_INVARIANTS` | set; `0`/empty off | Detect-only dispatch invariant checks, one machine-readable line per violation | `[INVARIANT]` |
| `KLIO_INIT_DEBUG` | set | `object`/companion initializer first-failure and the cause take/swallow/restash steps | `[init-debug]` |
| `KLIO_CFN_TRACE` | `<substr of a fn name>` | Named-argument call binding: the declared parameter list vs the supplied names, on both the named and the typed entry | `[cfn]`, `[cft]` |
| `KLIO_DRAIN_TRACE` | set | Each Iterable receiver drained to a list by the collection fallback, with the caller and call-site span | `[drain]` |
| `KLIO_FASTPLAN_TRACE` | `<substr of a fn name>` | Why a function is ineligible for the monomorphic fast call plan (no body, inline, extension, defaults, sibling overloads, ...) | `[fastplan]` |
| `KLIO_ITER_TRACE` | set | The builtin iterator's `next()` element kind per call | `[iter-next]` |
| `KLIO_KTYPE_TRACE` | set | Each synthetic `KType` materialized for a reified type name, with the enclosing function | `[ktype]` |
| `KLIO_MEOI_TRACE` | `<owner class>` | Member-extension dispatch-receiver selection: the enclosing entries walked and each owner-identity verdict | `[meoi]` |
| `KLIO_PICK_TRACE` | `<name>` | The runtime overload re-pick: the base candidate's applicability score and every sibling's | `[pick]` |
| `KLIO_REDIR_TRACE` | set | Value-shaped redirect-target resolution among same-arity expect/actual siblings | `[redir]` |
| `KLIO_RFP_DUMP` | set | Dumps every registered receiver-fn-property `(receiver, name)` pair when the gate masks build | `[rfp]` |
| `KLIO_ROUTE` | `<name>` | Which runtime arm bound each `*OrGlobal` execution of that name (member@depth, overload, global-id, global, the fallback variants), plus dispatch-ladder route markers | `[route]` |
| `KLIO_THIS_TRAP` | set | Every frame entry that binds a Bool or Int into a `this` parameter — the ext-receiver misbind signature — with the caller | `[this-trap]` |
| `KLIO_WALK_TRACE` | set | Each by-name IR method walk and extension-fallback walk entry, with the receiver and cache-key state | `[ir-walk]`, `[extfb-walk]` |

```sh
KLIO_BARE_TRACE=format KLIO_MISS_TRACE=format ./zig-out/bin/klio run repro.kt
```

## Resolution audits

The resolver and type checker serve `klio check`; `klio run` and `klio test`
resolve through sema. The audit switches emit machine-readable records the
sweep scripts grep.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_EAGER_AUDIT` | set | Eager-pipeline bookkeeping (skip reasons, record counts) and eager-vs-lazy pick disagreements | `[EAGER]`, `[EAGER-AUDIT]` |
| `KLIO_EAGER_HITS` | set | Per-call eager record/probe/hit/miss logging (high volume) | `[EAGER-REC]`, `[REC-MSC]`, `[EAGER-PROBE]`, `[EAGER-HIT]`, `[EAGER-MISS2]` |
| `KLIO_LINK_AUDIT` | set (any value enables) | Re-derives what the deleted per-call dispatch ladder would have chosen and logs any disagreement with the link-settled tables | `[KLIO_LINK_AUDIT]` |

`scripts/commontest-sweep.py` accepts `--eager` for compatibility and
ignores it: there is only one pipeline, so `both` just runs the corpus
twice and reports any run-to-run divergence (useful for catching
nondeterminism, not modes).

## Sema and the resolved pipeline

`klio run` and `klio test` run the symbol-identity front end (`src/sema`),
the bridge and lowering from sema's records; `klio sema` runs the front end
alone and reports its census.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_SEMA_TRACE` | `<name>` | Every candidate a call named `<name>` considers, level by level, and why each is rejected | `[sema-trace]` |
| `KLIO_SEMA_TIMING` | set | Milliseconds per step of a sema-pipeline run: load and parse, collect, headers, bodies, records, bridge, lowering, execution | `[sema-timing]` |
| `KLIO_CHECK_BASE` | `1` | As `KLIO_CHECK_PACKS`, over the base set (the stdlib and klio's actuals): with `scripts/sema-census.py`, a `type_mismatch` site there is a false positive of the type checks, or klio-authored code kotlinc would refuse | none |
| `KLIO_CHECK_PACKS` | `1` | Also runs the declaration, annotation and use checks (`declcheck`, `annocheck`, `usecheck`) over the installed packs' sources, which kotlinc compiled: a finding there is a false positive to fix, or klio-authored code kotlinc would refuse. The pack checks see no module `-opt-in` or `@file:Suppress`, so `use` sites there are noise | none |
| `KLIO_SEMA_PIPELINE_BASE` | set | Also prints the base's lowering failures, which a run otherwise only counts | `[base]` |
| `KLIO_SEMA_IMAGE` | `0` off | The base image: a run loads the base's bridge and lowered bodies from `$KLIO_HOME/.klio/cache/sema-base-<key>.klio-sema`, else from the copy the build installed under `share/klio/cache` beside the binary (baked on a miss, keyed by the binary and every base file's path and text), and analyzes and lowers only the program; `0` analyzes and lowers the base in every run | none |

## Errors, throws, and hangs

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_ERR_TRACE` | set | On otherwise-traceless Vm failures: the live frame chain plus a site-specific miss line (unresolved field get, uninvokable call value, unmatched `this@label`). In `klio test` it also renders the full throwable (type, message, frames, causes) instead of the terse summary | `[errtrace]`, `[getfield-miss]`, `[callvalue-miss]`, `[labeled-this]` |
| `KLIO_THROW_TRACE` | set | One line per exception as it is thrown (including failed casts that raise without a `Throw`, which name the class of the value and the receiver in `r0` with its address) | `[throw-trace]` |
| `KLIO_THROW_STACK` | set (needs `KLIO_THROW_TRACE`) | Adds the full frame chain at each throw site | `[errtrace]` |
| `KLIO_LR_TRACE` | set | Labeled-return propagation through interpreter frames (raise, pass, exit) | `[lr-raise]`, `[lr]`, `[lr-exit]` |
| `KLIO_AMP_TRACE` | `<substr>` | A resolution-class error about to be re-tagged as `CalleeFailed` whose message contains the substring; dumps the frames before they are torn down | `[amp]` |
| `KLIO_SPIN_TRACE` | seconds (unparsable values fall back to 30) | Every N seconds of wall time, dumps the live frame chain and the innermost frames' registers, so a run that never returns names its loop | `[spin]` |
| `KLIO_SEGV_TRACE` | set | Installs a segfault handler at startup so SIGSEGV/SIGBUS prints a native backtrace | native backtrace |
| `KLIO_FAULT_INJECT` | `internal-error@<fqn>` | A test knob: calling the function with that qualified name (`trigger`, `demo.trigger`) raises the internal error "injected internal error in `<fqn>`" instead of running it, for the tests of the paths that handle one (`tl_dispatched_internal_error_fails_run` sets it through its `//>env` line) | none |
| `KLIO_MAX_EVAL_DEPTH` | number (default 100000) | Caps interpreter recursion depth; a call past it throws `java.lang.StackOverflowError`, which Kotlin code catches. A call the host makes back into Kotlin also throws it when the native stack is down to its reserve, whatever the depth | none |
| `KLIO_RUN_TIMEOUT_S` | seconds (`0`/unset off) | Wall-clock deadline for the whole run; a watchdog thread aborts the process when it expires | `[klio]` |
| `KLIO_TEST_WALL_CAP` | seconds (default 300; `0` disables) | Per-test wall cap in `klio test`: a wedged test fails "test wall-clock deadline exceeded" instead of hanging the run | none |

```sh
KLIO_ERR_TRACE=1 KLIO_THROW_TRACE=1 KLIO_THROW_STACK=1 ./zig-out/bin/klio run repro.kt
```

## Coroutines and the pump

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_PUMP_DIAG` | set | The cooperative pump: loop/slot/parked dumps, the park/adopt/persist/take token lifecycle, stalled-pump dumps, idle-streak and exit-time sleep attribution, and the timer thread's posts and takes | `[PUMP]`, `[tok]`, `[pump-streak]`, `[wall-timer]`, `[pump-sleep]`, `[timer]` |
| `KLIO_RESUME_TRACE` | set | The resumer's identity and frame chain, then one line per frame a resume drive re-runs, with `path:line`, the delivery route (`via=pump-ready`, `inline-claim`, `persisted-on-top`, ...), and the activation id. Catches double delivery | `[resume-call]`, `[resume-frame]` |
| `KLIO_SCOPE_DIAG` | set | The coroutine active-scope stack lifecycle: capture/restore on park and resume, guard enter/leave, push/pop | `[scope]` |
| `KLIO_NO_INLINE_RESUME` | set disables | Forces every continuation resume to queue on the pump instead of running inline on the caller's stack | none |
| `KLIO_PUMP_NOSLEEP` | set | Skips the 1 ms sleep slice in the wall-clock timer drain (busy-loops instead) | none |
| `KLIO_SYNC_RESUME` | `1` to enable (default off) | A cross-thread Kotlin `resumeWith` post waits (bounded) for the owner pump to run the routed step before the caller continues, instead of the fire-and-forget default | none |
| `KLIO_SUSPEND_STATS` | set | Running counters of suspension snapshots (dense, slots, saved, params, captures, receivers), printed every 50k snapshots | `[suspend-stats]` |
| `kotlinx_coroutines_test_default_timeout` | Duration, e.g. `10s` (default `60s`) | The `runTest` timeout. This is the env alias for the `kotlinx.coroutines.test.default_timeout` property: the property shim retries a dots-to-underscores form of any property name against the environment | none |
| `KLIO_RACE_JITTER` | set | Widens object-cell lock acquisition windows (spin + yield) so genuine data races reproduce reliably under test | none |

```sh
KLIO_PUMP_DIAG=1 KLIO_RESUME_TRACE=1 kotlinx_coroutines_test_default_timeout=10s \
  ./zig-out/bin/klio test HangingTest.kt
```

## Compose plugin

The `@Composable` lowering (`ir/lower/sema/compose.zig`) and the upstream
engine runtime are the only compose path; the lowering always runs.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_COMPOSER_BIND_TRACE` | set | Each call that threads the `$composer, $changed` pair: the owning declaration and the composer's class (a non-Composer instance in the pair slot also dumps the frame chain) | `[composer-bind-fn]`, `[composer-bind]` |
| `KLIO_RSS_LOG` | set | Prints process RSS on each rendered Compose UI frame | `[rss]` |
| `KLIO_CTOR_TRACE` | set | Every secondary-constructor side-table lookup: the key, how many entries it found, and each entry's parameter/default counts. The table that decides whether a defaulted secondary constructor can take a call | `[ctor]` |
| `KLIO_CTOR_PICK_SERVE` | `0` disables | Whether a construction takes the constructor its site named. Off with the pass still on measures the pass without serving it | — |
| `KLIO_TC_OWN_MEMBER` | `0` disables | The checker resolving a bare name against an enclosing class's members before giving up on it | — |
| `KLIO_CALL_UNRES` | set | Which exit of the call checker returns an unnameable type, by source line, plus the callee shape at its last exit | `[CALL-UNRES]`, `[CALL-TAIL]` |
| `KLIO_CALL_UNRES_NAMES` | set | With the above: the callee name at each last-exit give-up | `[CALL-TAIL]` |
| `KLIO_DISPATCH_HANDOFF` | `0` disables | A `Dispatchers.Default`/`IO` dispatch from a non-worker thread waits, bounded and only when the pool was idle, for a worker to pick the task up and run it to its first suspension. Without it a `launch` followed by `yield()` and a cancel finds a child whose body never ran | — |
| `KLIO_TC_FIXPOINT` | `<n>` extra body passes | Re-check every body `n` more times with reporting off, so a body can use what the first pass learned. Off by default: it converges after ONE extra pass for 2 007 more type heads and 27 fewer unresolved sites, at 16% of the cold build | — |
| `KLIO_TC_<NAME>` | `0` disables | One checker capability, for bisection: `EXTERN` (image class members), `TOPFN` (image top-level functions), `GENERIC` (receiver substitution), `RECV` (receiver constraints in inference), `LAMBDA` (lambdas checked inside inference), `CTOR` (constructor overload sets), `TOPPROP` (top-level property type inference), `MEMBERFB` (member receiver class fallback), `INFIX`, `COMPANION`, `LOSSY`/`LOSSYRH`/`CLONERH` (generic and receiver heads on converted types), `PERMISSIVE` (subtyping of unrelated heads), `PKGROOT` (a qualified path's head must be a known package root before it reads as package-qualified) | — |
| `KLIO_TYPE_TRACE` | set | One row per type the checker records, by span | `[type]` |
| `KLIO_INFER_TRACE` | set | Each receiver constraint and solved variable of a generic call's inference session | `[infer]` |
| `KLIO_EXTERN_TRACE` | `<Class>` | The class info the checker imports from the image for that class: type parameters, typed supertypes, member types | `[extern-class]` |
| `KLIO_FILE_IDS` | set | Every file id the front end assigns with its path, so a `f<id>:<start>-<end>` span in any trace can be read | `[file]` |
| `KLIO_RUN_STATS` | set | One line when the program's `main` returns: the boot/exec time split, RSS at `main` and at exit, RSS + mapped bytes after a forced final collection, and the live cell count that collection kept. Works the same for `klio run`, a bundle, and a transpiled binary, so the three are comparable | `[run-stats]` |

## Compose UI and Skia

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_SKIA_LIB` | path | The Skia shim library to load at runtime (first in the search order) and to embed when bundling. A shim that is there but does not load says why on stderr (`klio: the Skia shim at ... did not load (<the loader's reason>)`, or the symbol it lacks) and rendering is headless | none |
| `KLIO_SKIA_VERBOSE` | set | One-line backend notes: window backend chosen, dump writeback result | `[klio-skia]` |
| `KLIO_SKIA_DUMP` | path | Writes a window's presented frame to the given PNG path (the first, or the `KLIO_SKIA_DUMP_AT`-th), GPU or raster, on every backend; an SDL window's frame includes its drawn menu bar and open menus. A path with `%d` writes every presented frame, numbered from 1 (`frame-%d.png`) | none |
| `KLIO_CLIPBOARD` | `system`, `private`, `none` | The clipboard `klio.datatransfer.systemClipboard()` answers with, which Compose's `LocalClipboard` uses: the host's (the default; none where the host has none), one of the program's own that nothing outside it reads or changes (the test runners set this), or none, as a headless desktop has | `system` |
| `KLIO_A11Y` | `1` | Turns a window's accessibility on from its first frame, as a screen reader reading it does: the program sends its semantics to the platform's accessibility API (NSAccessibility, UI Automation, AT-SPI through ATK). A scripted input with an `a11y` event turns it on too | off until an assistive client reads the window |
| `KLIO_SYSTEM_THEME` | `light`, `dark`, `unknown` | The system theme skiko's `currentSystemTheme` reports, so `isSystemInDarkTheme()` answers it, in place of the host's (macOS: its interface style; Windows: whether apps use the light theme; elsewhere unknown). The test runners set `light` | the host's |
| `KLIO_URI_OPENER` | program | The program Compose's `LocalUriHandler` runs with a URI to open it, in place of the platform's (`open` on macOS, `xdg-open` on Linux, the URL protocol handler on Windows); `openUri` throws when it exits non-zero or cannot start | none |
| `KLIO_LOCALE` | language tag | Compose's `Locale.current`, as `-Duser.language`/`-Duser.country` set the JVM's default; unset, it is the host's (macOS: the first preferred language with the current region; Windows: the user's UI language; elsewhere LC_ALL, LC_MESSAGES or LANG). The test runners set `en-US` | the host's |
| `KLIO_MENU_DUMP` | `1` | Prints a window's menu bar (native, or the one an SDL window draws) or a tray's menu on stderr each time it changes (`[menu]` lines: titles, disabled items, checked states, key equivalents), each item icon set, and each tray notification | none |
| `KLIO_SCRIPT_TRACE` | set | Scripted window input (`KLIO_WIN_INPUT`) as it is taken: each window's poll that queued events, when, and how many, and the frame each window presented after them | `[script]` |
| `KLIO_SKIA_DUMP_AT` | n | Which presented frame `KLIO_SKIA_DUMP` writes, counting from 1 | none |
| `KLIO_WIN_INPUT` | path | Scripted window input: a file of events (`<when> move/press/release/scroll/key/text/focus ...`, described in `src/compose_ui/window_events.h`) queued on a window at its n-th event poll, or `<t>ms` after the first poll of any window (one timeline for every window), as if its platform sent them; a key given `menu` carries the platform's menu shortcut modifier (Command on macOS, Control elsewhere); `<when> menu File/Open` chooses a menu bar item by its titles' path, through the menu as a click does; `<when> menushow File/Open` opens an SDL window's drawn menus down to the item and leaves them open, for frame dumps (native menu bars ignore it); `<when> close` is the window's close button; `<when> tray action` and `<when> tray menu Quit` click a tray icon and choose its menu's items (a tray counts its own polls and time); `<when> compose <text>` and `<when> commit <text>` are the input method's composing and committed text; `<when> a11y dump` prints the window's accessibility tree as the platform's accessibility API exposes it, and `<when> a11y press <name>`, `a11y focus <name>`, `a11y value <name>=<text>` and `a11y increment <name>` ask through that API as a screen reader does; `<when> cursor` prints the cursor the window shows; `<when> drop <x> <y> text <text>` and `<when> drop <x> <y> files <path>|<path>` are another application's drag entering at the point and dropping there, offering copy and move. The windows take timed events in the order they fall due, and each window's next events wait until the program has shown the effect of the last ones any window took (a frame presented, or the window loop settled with nothing left to do). A scripted press drags within the window (a real press drags through the platform). A script with pointer events is the windows' only pointer input, and one with a focus event their only focus changes: the real pointer and focus do not reach them. The example runners set it for an example with a `<name>.input` beside it | none |
| `KLIO_XDND_TRACE` | set | X11 windows' drag and drop: each XDND message a window sends and hears, the data asked for and whether it was served, each drag a window starts and the action it ended with | `[xdnd]` |
| `KLIO_SKIA_FONT` | path | Typeface override for text painting (checked before the bundled and system fonts) | none |
| `KLIO_COMPOSE_DEBUG` | set | Traces the SDL+GL / Skia GPU-window bring-up path in the C++ shim | `[klio-compose]` |
| `KLIO_PARA_TRACE` | set | Traces SkParagraph text-layout construction (font/unicode readiness, lengths) | `[para]` |
| `KLIO_DRAW_TRACE` | set | Each canvas rect draw with its surface, geometry, and color | `[draw]` |

## Performance profile and profiler

The profile itself (`--opt` / `KLIO_OPT`) is documented in
[Performance](../architecture/performance.md); the granular
variables override individual fields on top of it.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_OPT` | `fast`/`safe`/`off` (aliases: `full`, `on`, `balanced`, `none`, `interp`) | Selects the performance profile, which picks the memory backend: `fast` and `safe` the tracing collector, `off` an arena | none |
| `KLIO_FLAT` | `0` off (default on) | The flat call driver; `0` falls back to native recursion for every call (bisect) | none |
| `KLIO_RSEL_TRACE` | set | Every compatibility receiver re-selection at a receiver-lambda invoke: the recorded head, the passed receiver, and what was selected | `[rsel]` |
| `KLIO_RECLAIM` | `gc`, `arena`, `smp`/`free`/`1`, `debug`, `0` | Memory backend override (and whether refcount teardown is active); the profile default is the tracing GC | none |
| `KLIO_PROF` | set; value = sampling interval in microseconds (default 1000, floor 100) | Statistical SIGPROF profiler on Linux and macOS; prints a by-function sample histogram to stderr at the end of the run. On macOS the in-process symbolizer resolves nothing: dump raw addresses with `KLIO_PROF_RAW` and fold them with `scripts/prof_symbolize.py`. The timer is per process, so a phase on ten threads is undercounted; the shares within a phase still hold | `[prof]` |
| `KLIO_PROF_ALL` | set (needs `KLIO_PROF`) | Widens profiling to the whole process, including startup and image decode | `[prof]` |
| `KLIO_PROF_CALLERS` | `<substr>` | After the histogram, folds the callers of every sampled leaf whose name contains the substring | `[prof]` |
| `KLIO_PROF_RAW` | `<n>` (needs `KLIO_PROF`) | Prints the n most sampled addresses folded by address, phase and caller (the link register on arm64, so a leaf such as memcpy names who called it), after the phase table and the handler's own address for sliding. Every lowering pass, bake step and cold-run step marks a phase | `[prof-raw]`, `[prof-phase]` |
| `KLIO_OP_PROF` | set; value = sampling interval in microseconds (default 1000, floor 100) | Opcode sampler: a SIGPROF histogram over the interpreter's currently executing opcode tag (with host-route sub-tags), printed at the end of the run as self-time by opcode | `[op-prof]` |
| `KLIO_FN_PROF` | set; value = sampling interval in microseconds (default 1000, floor 100) | Kotlin-function sampler: a SIGPROF histogram over the INTERPRETED program's currently executing function, printed as self-time per Kotlin function. `KLIO_PROF` attributes time to interpreter internals; this one names the library body to serve or splice. Self-time excludes a callee only when the callee gets its own frame: a leaf- or bytecode-served callee is attributed to its caller | `[fn-prof]` |
| `KLIO_FRAME_COUNT` / `KLIO_FRAME_CENSUS` / `KLIO_FRAME_WATCH=<substr>` | set / substring | How many interpreted activations a workload runs (`activations` = register-bank acquisitions, one per real frame; `entries` = `runFrameExec` entries, higher because a flat call re-enters its caller's frame at the return block), with `_CENSUS` the top functions by activation count and `_WATCH` a line per activation of a matching function naming its caller. The frames-per-unit metric that separates "too many frames" from "frames too expensive" | `[frames]`, `[framewatch]` |
| `KLIO_CALL_STATS` | set | Counts every interpreted function invocation by FQN over the whole run; `klio run` and `klio test` print the top entries after the program. The workload census that separates "slow per call" from "more calls than the reference would make" (missed skipping, repeated recompose, un-inlined accessors) | `[call-stats]` |
| `KLIO_CALLVALUE_TRACE` | set | Flat closure-call preparation on the value-call path: per-argument kinds and under-application | `[flat-prep]`, `[cvt-flat]` |
| `KLIO_DUMP_FN` | a simple name, a qualified name, or `#<FuncId>` (the frame and fill censuses print ids) | Prints the named function's lowered instructions the first time it runs, every operand (`rN` registers, `bN` blocks) with each block's catch and finally handlers and its terminator's targets — the only way to see what an emit path produced for a body inside a baked base | `[dump-fn]` |

```sh
KLIO_PROF=500 KLIO_PROF_CALLERS=append ./zig-out/bin/klio run bench.kt
```

## The JIT

The baseline JIT (`plans/jit.md`, `src/ir/eval/baseline.zig`) and its
optimizing loop tier (`plans/jit-opt.md`) are on for `klio run` and bundled
apps, on AArch64 and x86-64, and off for every other command (`klio test`,
the harness's in-process runs) unless `KLIO_JIT` turns them on; `KLIO_JIT=0`
or `KLIO_JIT_OPT=0` turns them off anywhere. `zig build` forwards `KLIO_JIT`,
`KLIO_JIT_THRESHOLD`, `KLIO_JIT_MIN_NATIVE`, `KLIO_JIT_INLINE` and
`KLIO_OPT` to the itests.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_JIT` | `0` off, anything else on (default on for `klio run` and bundled apps, off otherwise) | Compiles a function once its entries and loop edges reach the threshold | none |
| `KLIO_JIT_THRESHOLD` | number (default 10000) | Entries plus back edges before a function compiles; `0` compiles every function at its first entry, as the JIT gate runs | none |
| `KLIO_JIT_MIN_NATIVE` | percent (default 70) | A function whose ops (its loops' ops, when it has loops) compile natively below this share is declined; `0` compiles every function | none |
| `KLIO_JIT_INLINE` | `0` off (default on) | Callees compiled in place into their callers | none |
| `KLIO_JIT_INLINE_WORDS` | number (default 250) | The largest callee, in stream words, compiled in place | none |
| `KLIO_JIT_EXITS` | number (default 1000), `0` never | Runs of one exit from a callee compiled in place (an op the callee does not run there, which gives the callee and its callers' callees their frames) after which that callee is called rather than compiled in place anywhere, and the function the code was compiled from compiles again with it as a call. `KLIO_JIT_STATS` counts the callees (`exits_hot=`) and `KLIO_JIT_CENSUS` names the calls (`leaves often`); `0` keeps every callee in place however often it leaves, for A/B timing | none |
| `KLIO_JIT_KINDS` | `0` off | Compiled code checks every register's tag, as though no register's kind were known (bisect a wrong kind) | none |
| `KLIO_JIT_PINS` | `0` off | No loop keeps registers in machine registers (bisect a wrong pin); `KLIO_JIT_STATS` counts the registers kept (`pinned=`) | none |
| `KLIO_JIT_NATIVE` | `0` off | Every op compiles as a call of its handler (bisect a native op against its handler) | none |
| `KLIO_JIT_DIRECT` | `0`, `shared` | By default a call compiled code does not run in place, to a callee its site keeps (a virtual call's behind a check of the receiver's class), opens the callee's frame and goes on in its code with no call handler between: in shared code (`directCall`), or for a function's call of itself, at its direct entry, the same work compiled with the function (`direct=` in `KLIO_JIT_STATS` counts the sites). `shared` gives no function a direct entry; `0` sends every such call through the call's handler. Both are for A/B timing and for bisecting a fault to a path | none |
| `KLIO_JIT_ENTRIES` | `0` off | Only loop edges count toward compiling | none |
| `KLIO_JIT_SKIP` | op names, comma-separated | Those ops compile as their handlers (bisect one op) | none |
| `KLIO_JIT_ONLY` | `lo-hi` | Only functions whose id (the `#` `KLIO_JIT_LOG` prints) is in that range compile (bisect one function) | none |
| `KLIO_JIT_STATS` | set | At exit: compiled, recompiled, declined and failed functions, callees in place, code bytes and compile time; the loops the optimizing tier compiled, refused, and kept values of in stack slots | `[jit]` |
| `KLIO_JIT_LOG` | set | Every function as it compiles, and the callees it compiles in place | `[jit]` |
| `KLIO_JIT_DUMP` | a function id | That function's streams as it compiles | `[jit]` |
| `KLIO_JIT_DUMP_CODE` | set, with `KLIO_JIT_DUMP` | That function's machine code as hex, 32 bytes a line at its offset, and each op's offset in it, which `scripts/jit-disasm.py` disassembles | `[jit-code]`, `[jit-op]` |
| `KLIO_JIT_MAP` | set | One line per op's entry address in each compiled function, then where each op's own code starts (`slow:at:<op>`), where each op of a callee compiled in place starts, named by the callee (`slow:in:<op>`), each way out of the code (`slow:handler:`, `slow:exit:`, `slow:stale:`, `slow:fill:` by the op it leaves at), and the function's direct entry (`slow:direct:`), to attribute samples of compiled code to the op that ran | `[jitmap]` |
| `KLIO_JIT_OPT` | `0` off, anything else on (default on where the JIT is on by default) | A compiled function's innermost loops compile a second time over values in machine registers (`plans/jit-opt.md`), where the tier takes every op of the loop and of the callees it takes in place; `KLIO_JIT_LOG` names each loop taken or refused and why | `[opt]` |
| `KLIO_JIT_OPT_DUMP` | set | Each compiled function's innermost loops as the optimizing tier's graphs, or why each was refused | `[opt]` |
| `KLIO_JIT_OPT_EXITS` | set | At exit (with `KLIO_JIT_STATS`): per optimized loop, how often each of its exits ran and how often its entry checks failed, by the op each exit resumes at | `[opt-exit]` |
| `KLIO_JIT_CENSUS` | set, or `all` | At exit: the ops left to their handlers in compiled and declined functions, what kept callees from compiling in place, and, counted as they run, the calls, host functions and instruction arms compiled code still reaches and why; the busiest 60 sites, or every one with `all` | `[jit-census]` |

## Memory: GC, allocators, and leak tracking

The `KLIO_GC_*` family, `KLIO_GC_ALLOC`, `KLIO_LEAK_BY_FQN`, and the
slab tracers take effect only when the run uses the tracing GC
backend (the default for `fast`/`safe`).

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_GC_DEBUG` | set; `0`/empty off | One line per collection: epoch, kind (`minor`, `major`, and for a spanning major `initial`, `slice`, `remark`), cells marked, live, freed, and the phase times (`mark_us`, `sweep_us`, `stop_us` for the rendezvous, `pause_us` from the raise to the release), the other mutators stopped, where the sweep ran (`sweep=pause` or `sweeper`), and a minor mark's split: `roots_us`, `rem_us` for retracing the remembered set, and what it retraced (`rem_whole` cells whole, `rem_spans` index ranges over `rem_span_len` elements), then for a spanning major the cells it traced in this stop (`slice`, `slice_us`) and the stops it has spanned (`major_stops`). A sweep the sweeper thread ran reports its freed cells and time on its own line | `[kgc]`, `[kgc-sweep]` |
| `KLIO_GC_REGION` | `1` on (default), `0` off | Whether a mutator's cells are bumped out of region blocks (`src/runtime/region.zig`) or allocated one slab cell each. Off, every cell is on the collector's lists as before, for an A/B in one binary or to rule the region heap out. `KLIO_GC_VERIFY`, `KLIO_GC_POISON`, `KLIO_GC_HIST` and `KLIO_GC_NOFREE` turn it off. With `KLIO_GC_DEBUG` each sweep of region blocks reports the blocks read, the ones left free, the free lines and the blocks mapped | `[kgc-region]` |
| `KLIO_GC_SWEEP` | `pause` | Keeps every sweep inside its collection's stop instead of handing it to the sweeper thread, to compare pause times or to rule the sweeper out. `KLIO_GC_NOFREE`, `KLIO_GC_HIST`, and a post-sweep audit sweep in the stop too | none |
| `KLIO_LOCKFREE_READS` | `1` on (default where the program runs on the slab heap), `0` off | Whether a list's element reads and a map's lookups take no lock, checked against the cell's write sequence (`ObjRef.readAtMoving`, `lookupNoLock`); off, they take the shared lock as before, for an A/B in one binary or to rule them out | none |
| `KLIO_GC_MAJOR` | `concurrent` (default), `slices`, `stop` | How a major marks: `concurrent` spans it across stops, beginning in a minor's stop, with the marking thread tracing it while the mutators run and running the remark itself; `slices` spans it the same way but traces a slice at each minor's stop; `stop` marks it whole in one stop. Spanning needs generational collection | none |
| `KLIO_GC_SLICE` | number (default 10000) | Cells a spanning major traces per stop beyond what the stop's minor handed it | none |
| `KLIO_GC_MAJOR_EVERY` | number (`0` off) | Makes every Nth collection a major, to exercise majors in a short run | none |
| `KLIO_GC_GEN` | `1` on (default), `0` off | Generational collection: minor (nursery-only) sweeps between Appel-scheduled majors; `0` forces every collection major | none |
| `KLIO_GC_GROWTH` | integer, min 2 (default 2) | The Appel growth multiplier: the next collection fires after `live * factor` bytes | none |
| `KLIO_GC_MINOR_STOP` | `1` on (default), `0` off | Whether a minor mark stops at tenured cells; `0` full-traces minors to bisect a missed-barrier suspicion | none |
| `KLIO_GC_VERIFY` | set | After each minor mark, traces every tenured cell and reports a child that is an unmarked nursery cell: a store that skipped the write barrier. After a major's mark it traces every marked cell and reports an unmarked child, and after each slice of a spanning major it does the same for every marked cell not due a retrace (not grey, not remembered since): a store into a traced cell that no barrier recorded, or a child a tracer skipped (`major:` in the line). Names the class and field for an instance, and dumps the frame chain on the first report; pair with `KLIO_GC_STRESS=1` so the report lands right after the store. A tenured cell that is already unreachable can also report, so confirm the holder is live |  `[gc-verify]` |
| `KLIO_GC_REMEMBER_TRACE` | set | Logs, with a native stack, any remembered-set cell as it is swept | `[gc-freed-remembered]` |
| `KLIO_GC_REM_TOP` | set (with `KLIO_GC_DEBUG`) | A collection whose retrace of whole remembered cells takes over a millisecond prints the payload types that took it: cells, time, children shaded and the slowest cell. A cell whose retrace took over 200 µs is watched, and the next whole-cell barrier on it prints the native stack of the store, which names the path that remembers a large cell whole | `[kgc-rem]`, `[kgc-rem-store]` |
| `KLIO_GC_LATE` | milliseconds | A rendezvous still short after this long has every other mutator print its native stack: a parked thread shows the park, a late one what it runs without reaching a safe point (a yield loop outside a blocking-safe bracket, a long native). The reports themselves slow the stop, so read the stacks, not the pause they land in | `[gc-late]` |
| `KLIO_GC_HIST` | set; `0`/empty off | Top-16 live-cell payload types per collection | `[kgc-hist]` |
| `KLIO_ENUM_INIT_TRACE` | set | VM-start enum entry construction: which entries are rebuilt through the class path and the header thunk chain per class | `[enum-init]`, `[chain]` |
| `KLIO_CTOR_TRACE` | set | Each secondary-constructor default-argument thunk as it is evaluated (class, parameter, thunk id, argument count) | `[ctor-default]` |
| `KLIO_PARSE_JOBS` | count | Caps the threads that lex and parse the stdlib and pack sources at load (default: one per CPU); `1` parses serially, every file whole, which is the reference for the pool's piecewise parse of the largest files | none |
| `KLIO_STDLIB_IMAGE_SHIPPED` | `0` | Ignores the base image the build installed under `share/klio/cache`, so a run with an empty data home bakes as a cold run would | none |
| `KLIO_PARSE_CHECK` | set | Prints where each large source was cut into pieces for the parse pool, parses each such file whole again and reports the first declaration the piecewise parse got differently, and checks every declaration name is a slice of its source | `[parse-check]` |
| `KLIO_TRACE_FILES` | set | The FileId each stdlib source registers under, for reading a `fN:offset` span in a trace | `[file]` |
| `KLIO_RESOLVE_THREADS` | count | Caps the threads the resolver's second pass uses over the files of a module (default: one per CPU); `1` resolves serially, the reference | none |
| `KLIO_TRACE_RUN` | set | Wall time of the run's own steps: VM init, the pre-execution trim with the slab's mapped bytes before and after it, `main`, teardown, and the startup/prepare/execute split with the resident set | `[run]` |
| `KLIO_BOX_FILTER` / `KLIO_BOX_JOBS` / `KLIO_BOX_TIMEOUT_MS` | substring / count / ms | The box conformance runner's test subset, worker width, and per-test wall | `[box-fail]`, `[box-excluded]` |
| `KLIO_GC_STRESS` | set; `0`/empty off | Collects at every safe point; surfaces incomplete roots/tracers immediately | none |
| `KLIO_GC_STRESS_EVERY` | number (`0` off) | Collects every N safe points (cheaper sampled stress) | none |
| `KLIO_FRAME_AUDIT` | `1`, `2` | At every collection, checks each frame at the position it recorded against its function's frame map (`src/ir/core/framemap.zig`): every register the collector traces there (those live there) must hold a tag a value can have, which garbage an earlier frame left in the window seldom does, so a register the map calls live that nothing wrote, or a safe point reached without the frame recording where it stands, reports. `2` also poisons every register not live there (`CoroutineSuspended`), so a read the map missed fails where the register is read. Prints each finding and, at the end of the run, frames audited, unmapped (filled whole), bad positions, live registers holding garbage and registers poisoned. Pair with `KLIO_GC_STRESS_EVERY` for coverage | `[frame-audit]` |
| `KLIO_FRAME_AUDIT_FN` | a function's simple name, or `*` | With `KLIO_FRAME_AUDIT`, prints every audited frame of that function (or every frame): its position, its live registers, and `~rN` for each one poisoned | `[frame-audit]` |
| `KLIO_GC_THRESHOLD_KB` | KiB (default 8192) | The collection-trigger floor; a small floor collects frequently | none |
| `KLIO_GC_NOFREE` | set; `0`/empty off | Marks fully but never frees; if a crash disappears, it was a premature free, not a marking bug | none |
| `KLIO_GC_POISON` | set; `0`/empty off | Quarantines swept cells and traps the next trace through one, naming the swept-while-live type | `[GC-POISON]` (panics) |
| `KLIO_GC_GUARD` | set, or `dbg` | Panics on absurd (>1 MB) allocations after program start, the signature of reading a corrupted length from a swept buffer; `dbg` uses the checking allocator instead | panic |
| `KLIO_GC_EXT` | `1` on, `0`/empty off (default on) | Counts external frame/snapshot heap growth toward the GC trigger | none |
| `KLIO_GC_ALLOC` | `slab` (default), `smp`, `gpa`, `calloc`, `leaktrack` | The freeing backend the collector frees into; `leaktrack` wraps the slab in the leak locator and reports at exit | `[leaktrack]` |
| `KLIO_LEAK_BY_FQN` | set (needs `KLIO_GC_ALLOC=leaktrack`) | Attributes outstanding allocations by intrinsic FQN instead of by stack (much cheaper) | `[leaktrack-by-fqn]` |
| `KLIO_RC_DETECT` | set; `0`/empty off | Refcount double-free detector: leaks control blocks so a second decrement is observable, then dumps a stack trace | `[RC DOUBLE-FREE]` |
| `KLIO_BOXDIE_TRACE` | set | Logs, with a native stack, a boxed List view whose box dies while a backing value is still attached | `[boxdie]` |
| `KLIO_ALLOC_TRACK` | set; `0`/empty off | Global allocation counters, a size histogram, and named phase snapshots; whole-process report at exit | `[alloc-track]` |
| `KLIO_PAGE_TRACE` | set; `0`/empty off | Histogram of direct page allocations, with stacks for the 96 KB to 160 KB window | `[page-trace]` |
| `KLIO_SLAB_STAT` | set | Total bytes currently mapped from the OS with the count of map and unmap calls, printed at exit, and at the pre-execution trim the per-size-class occupancy: partial spans, their free and dormant cells, parked spares, the uncarved slab reserve, the parked large blocks, and what that leaves live | `[slab]` |
| `KLIO_SLAB_MAPS` | set | Every map call by the site that made it, live or not, with counts and bytes, printed at exit: a list that grows through a chain of maps and copies shows as a site with a count where the live tracer sees only its last size | `[slabmaps]` |
| `KLIO_SLAB_CENSUS` | set; `churn`; `shapes` | Every slab allocation from process start charged to its calling site and credited back on free, with the byte size of each AST, token and IR shape first; printed at exit by bytes still live (`churn`: by bytes allocated over the run; `shapes` adds the variant and field sizes behind the largest unions and structs), so a cold run answers who holds what at `main` and who turns memory over. The tracing costs seconds; `scripts/slab_census.py` groups the report by phase, file and site | `[census]` |
| `KLIO_SLAB_TRACE` | set | Capture stacks of every live slab/large mmap made after the program started, dumped at exit or on SIGTERM/SIGINT; a span is attributed to the allocation that mapped it | `[slabtrace]` |
| `KLIO_SLAB_TRACE_ALL` | set (with `KLIO_SLAB_TRACE`) | Traces the build-phase mmaps too, so a SIGTERM during `main` attributes everything a cold run still holds | `[slabtrace]` |
| `KLIO_SLAB_POISON` | set | Overwrites every freed slab cell with `0xAA`, so a reader of freed memory sees garbage at once; the check to run the corpus and the sweep under after anything that frees build-phase trees | none |
| `KLIO_CELL_TRACE` | set | Sampled tracking of live small slab cells with their allocation stacks | `[slabtrace]` |
| `KLIO_RSS_CAP_KB` | KiB (default 6 GiB) | The RSS watchdog cap; the process aborts the moment RSS exceeds it, forestalling the kernel OOM killer. `0`/unset keeps the default (it does not disable the watchdog) | `[klio]` |
| `KLIO_PARITY_RSS_CAP_KB` | KiB | Legacy alias for `KLIO_RSS_CAP_KB`, consulted only when the primary is unset | `[klio]` |

```sh
KLIO_GC_ALLOC=leaktrack KLIO_LEAK_BY_FQN=1 ./zig-out/bin/klio run leaky.kt
```

## Stdlib, packs, and bundles

The stdlib pack resolution order and the image cache are described
in the [CLI tour](../getting-started/cli.md); these are the
overrides and traces.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_HOME` | path | The klio data home (packs, cache, registry, stubs); overrides the `~/.klio` default | none |
| `KLIO_STDLIB_PACK` | path | On-disk stdlib pack override, first in the resolution order (also folded into the image cache key) | none |
| `KLIO_PACK_DIAG` | set | Per-source lex/parse error dumps while the stdlib and pack sources load | `[embed lex err]` |
| `KLIO_PACK_TRACE` | set | One line per installed pack a run or `klio sema` loads, with its path | `[pack-load]` |
| `KLIO_AST_REBASE_TRACE` | set | Old-to-new FileId mapping when a cached AST bundle's spans are rebased | `[ast-rebase]` |
| `KLIO_BUNDLE_INSPECT` | `1` (`0` off) | A bundled executable prints its manifest and payload table, then exits without running | manifest listing |
| `KLIO_STUB_DIR` | directory | Local source for cross-target runtime stubs and Skia shims (`<dir>/<target>/<name>`), checked before the download cache | none |
| `KLIO_ENUM_INIT_TRACE` | set | Names any enum-instance field APPENDED rather than replaced in place during baked-enum init — the signature of a bake that dropped a field | `[enum-init-append]` |

## Libraries and the front end

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_NET_TRACE` | set | One line as each ktor-network selector `poll` starts and one as it returns: the thread, how many polls are in flight across threads, the timeout and the descriptors. A poll that never returns names a selector that was never closed | `[kknet]` |
| `KLIO_DOLLAR_TRACE` | set | Lexer trace for multi-dollar string-template arming (file, position, source window) | `[dollar-arm]` |
| `KLIO_REPEAT_DBG` | set | The `String.repeat` intrinsic's argument tags per call | `[srep]` |
| `KLIO_SEQ_DIAG` | set | A sequence drain whose iterator lacks `hasNext`, with the iterator's kind and FQN | `[seq-diag]` |
| `KLIO_UCTOR_TRACE` | set | An unsigned constructor refusing its argument shape, with the argument tags and a frame dump | `[uctor]` |

## Test harness and dev tooling

These are honored by the itest binaries, the kotlinc oracle
(`src/itests/kotlinc_support.zig`), and the scripts, not by `klio run`
itself.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_ITEST_BIN` | path (default `zig-out/bin/klio`) | The `klio` binary child-spawning itests run; `zig build` points it at the installed harness | none |
| `KLIO_ITEST_HOME` | directory | The data home the program-running suites run in; `zig build` names `zig-out/klio-test-home`, where the `klio-test-home` step installs every shipped pack once per tree and harness. Unset, a suite installs the packs into `/tmp/klio_itest_home` on first use | none |
| `KLIO_ITEST_VERBOSE` | set | Surfaces the differential itest's otherwise-suppressed progress lines | none |
| `KLIO_COMMONTEST_SHARD` | `K/N` | Runs shard K of N of the commontest target list (weighted split; set by CI) | none |
| `KLIO_E2E_SHARD` | `K/N` | Runs only corpus programs whose name hashes into shard K of N | none |
| `KLIO_E2E_FILTER` | `<substr>` | Restricts the e2e corpus to programs whose file stem contains the substring | none |
| `KLIO_PARITY_JAVA_XMX_MB` | MB (default 2048) | JVM heap ceiling for the kotlinc oracle | none |
| `KLIO_PARITY_JAVA_TIMEOUT_SECS` | seconds (default 60) | Wall-clock timeout for the kotlinc oracle | none |
| `KLIO_KOTLINC_JVM_HOME` | path | Existing JVM kotlinc distribution (or binary) for the kotlinc oracle | none |
| `KLIO_KOTLINC_NATIVE` | path | Native kotlinc override | none |
| `KONAN_DATA_DIR` | path (default `~/.konan`) | Where the kotlinc oracle looks for Kotlin/Native distributions | none |
| `KLIO_NO_AUTO_INSTALL_KOTLINC` | `1` (`0` off) | Never auto-install kotlinc; the kotlinc comparisons skip when none is found | none |
| `KLIO_SKIP_KOTLINC_PARITY` | `1` (`0` off) | Skips the kotlinc leg of the fuzzer's checks entirely | none |
| `KLIO_FUZZ_SEED` | u64, decimal or `0x` hex | Base seed for the closures/suspend fuzzer (a failure prints the repro seed) | none |
| `KLIO_FUZZ_SEEDS` | u64 | How many seeds the fuzzer sweeps | none |
| `KLIO_SWEEP_DEBUG` | set | `scripts/commontest-sweep.py` prints each child's argv before spawning | `ARGV` |
| `KLIO_BIN` | path | The binary `scripts/klio-smoke.sh` sweeps with | none |
| `KLIO_SKIA_OS` / `KLIO_SKIA_ARCH` | `linux`/`macos`/`windows`, `x64`/`arm64` | Target selection for `scripts/fetch-skia.sh` | none |

### Harness / test-infrastructure variables

Plumbing read only by test code — not user debugging knobs.

| Variable | Values | What it does |
|----------|--------|--------------|
| `KLIO_ENVONCE_SELFTEST_A` / `KLIO_ENVONCE_SELFTEST_B` | never set | Sentinel names the `envOnce` unit tests probe to prove distinct cache slots and unset-miss behavior |
| `KLIO_DEFINITELY_NOT_SET_XYZZY` | never set | Sentinel name the `proc_env` `isSet` unit test probes |

## Workflow recipes

**Tracing a coroutine hang.** Turn on the pump and resume traces,
cap `runTest` so the hang fails fast, and add a spin dump in case
the hang is a busy loop rather than a parked pump:

```sh
KLIO_PUMP_DIAG=1 KLIO_RESUME_TRACE=1 KLIO_SPIN_TRACE=10 \
kotlinx_coroutines_test_default_timeout=10s \
  ./zig-out/bin/klio test kotlin-klio/klio-kotlinx-coroutines --filter FlowTest
```

Read the `[tok]` lifecycle to see which continuation parked and was
never taken; `[resume-frame]` lines show every frame each resume
re-ran and by which route.

**Tracing a wrong overload pick.** Pair the static and dynamic
views for the one name that misbehaves:

```sh
KLIO_BARE_TRACE=encodeToString KLIO_MISS_TRACE=encodeToString \
KLIO_NU_TRACE=encodeToString \
  ./zig-out/bin/klio run repro.kt
```

`[bare]` shows what the module's tables bound (or `NONE`); the `[extfb]` /
`[member-miss]` tail shows which runtime candidates were skipped and
why; `[strictext]` / `[mev]` add visibility detail. Add
`KLIO_CMG_TRACE=<name>` for the dispatch preconditions at the call
instruction.

**Root-causing an exception.** When a failure surfaces as a bare
error with no trace, or a teardown masks the original throw:

```sh
KLIO_ERR_TRACE=1 KLIO_THROW_TRACE=1 KLIO_THROW_STACK=1 \
  ./zig-out/bin/klio run repro.kt
```

`[throw-trace]` names every throw as it happens (first one is
usually the root cause), `[errtrace]` dumps the frame chain, and in
`klio test` the failure detail becomes the fully rendered throwable.

## Per-thread state and the owner fast path

Darwin resolves every `threadlocal` access through a `_tlv_get_addr` CALL rather
than a register-relative load, and LLVM can only hoist that call within a
function — so in an interpreter the cost lands on every hot helper. It measured
25% of samples on a member-call loop.

`src/runtime/tls_fast.zig` answers it: the thread that calls `claimOwner()` at
process entry reads the hot per-thread structures (the evaluator's state,
the keepalive stack) from ordinary globals, and every
other thread keeps its threadlocal. The owner never changes, so no state
migrates between the two storages — a thread reads the same object for the
process's life. A binary that never claims an owner (the test harnesses) behaves
exactly as before.

Two things to know before extending it:

- It is NOT a win everywhere. The evaluator's own `EvalTls` is read on the
  per-call seam, where the compare that replaces the call costs more than the
  call did; it is deliberately left a plain threadlocal, and the comment at its
  declaration says so with the numbers.
- Grouping threadlocals into one struct does nothing on its own. The compiler
  already reuses a repeated access within a function; the cost is one resolution
  per hot helper CALL, so only removing the resolution helps.

## Measuring peak RSS (and the spin-loop trap)

Use `scripts/measure-rss.sh -- <cmd>`; it prints `PEAK_KB=<n> RC=<rc>
WALL=<s>`. For `zig build itest-*` you usually do not need it at all — the
build runner already prints `MaxRSS:` per run step under `--summary all`.

Do NOT hand-roll the sampler. The obvious inline version leaks a process
that spins forever:

    ( <cmd> ) &
    TP=$(pgrep -f "<name>" | head -1)          # matches THIS shell too
    while kill -0 $TP; do ...; sleep 10; done  # never terminates

`pgrep -f` matches full command lines, and the wrapper's own command line
contains the pattern, so `TP` is the wrapper itself, `kill -0` is always
true, and the loop runs at 0% CPU with a `sleep` child until something
reaps it. Three of these leaked in one session, two for sixteen hours,
because a run that prints nothing reads as "the measurement failed" rather
than "it is still going".

`measure-rss.sh` removes both failure modes by construction: the PID comes
from `$!` so no name matching happens, the loop is bounded by `--max-wall`
(default 900s) as well as by the child exiting, and an EXIT trap kills the
child on every path out.

The same self-match bites VERIFICATION code: `pgrep -f "sleep 600"` run
from a shell whose command line contains `sleep 600` reports a leak that
is not there. Check with `ps -eo pid,comm,args` and match on `comm`
instead.
