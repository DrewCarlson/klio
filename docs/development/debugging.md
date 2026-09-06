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
  (`KLIO_STDLIB_IMAGE=0`) and by a few gates
  (`KLIO_OR_AUDIT`, `KLIO_TRACE_PATH`, `KLIO_TRACE_INVARIANTS`).
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
  `KLIO_TRACE_RESOLVE`, `KLIO_TRACE_CHAIN`, `KLIO_TRACE_INVARIANTS`,
  `KLIO_TRACE_PATH`, `KLIO_TRACE_HTTP`, `KLIO_LINK_AUDIT`,
  `KLIO_RESOLVE_AUDIT`, `KLIO_RESOLVE_STRICT`, `KLIO_STDLIB_PACK`,
  `KLIO_PACK_DIAG`, `KLIO_STDLIB_IMAGE`, `KLIO_TRACE_STDLIB_IMAGE`
  (plus, for fuzz suites, `KLIO_FUZZ_SEED`, `KLIO_FUZZ_SEEDS`,
  `KLIO_SKIP_KOTLINC_PARITY`, `KLIO_KOTLINC_JVM_HOME`,
  `KLIO_KOTLINC_NATIVE`, `KLIO_NO_AUTO_INSTALL_KOTLINC`,
  `KONAN_DATA_DIR`). Exporting
  any other variable reaches `klio run` directly but not a
  `zig build itest-*` child; run the installed itest binary or the
  klio binary by hand instead.

## Dispatch and resolution traces

Runtime dispatch is the Vm side (`interp_ir/vm`); bare-call
resolution is the lowering side (`ir/lower`). The static/dynamic
pair to reach for first is `KLIO_BARE_TRACE` (what lowering picked)
plus `KLIO_MISS_TRACE` (which runtime tail missed).

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_BARE_TRACE` | `<name>` | How a bare call `name(...)` statically resolved during lowering: the chosen overload (fqn, params, ext, emit form) or `NONE` | `[bare]` |
| `KLIO_EXT_TRACE` | `<name>` | How an explicit-receiver extension call resolved during lowering: receiver type, implicit dispatch owners, lexical owner, and exact target; also the static member-resolution verdict and self-recursive-bind arg shapes for `name` | `[ext-static]`, `[member-static]`, `[self-rec-shape]` |
| `KLIO_MISS_TRACE` | `<name>` (two field-miss sites fire on any set value) | Runtime dispatch tails for `name` that miss or fall back, with frame-chain dumps at several sites; also the member overload scorer's per-candidate verdict and the argument shapes it scored against | `[member-miss]`, `[miss]`, `[extfb]`, `[pno]`, `[cno]`, `[setfield-miss]`, `[lg-tail-a]`, `[lg-tail-b]`, `[ltg-tail]`, `[cmg-tail]`, `[sam-inv]`, `[rim]`, `[rim2]`, `[pmo-shape]`, `[pmo-multi]` |
| `KLIO_CMG_TRACE` | `<name>` | Snapshot of `CallMemberOrGlobal` preconditions for `name` (receiver tag, constructor-likeness, enclosing fn, this-index, capture count), plus every static `Call` of `name` with its first argument values (scalars and instance class@identity) and a `[frame-push]` line whenever a frame for `name` is entered — the arg/param values make stale-object reads visible at the call site | `[cmg]`, `[call-inst]`, `[frame-push]` |
| `KLIO_NU_TRACE` | `<name>`, or `1` for all at some sites | Candidate/visibility detail for hard dispatch cases: interface factories, member-extension visibility, strict extension member calls, enclosing-scope resolution | `[eev]`, `[ifact]`, `[mev]`, `[meoi]`, `[par-miss]`, `[strictext]`, `[sbc]` |
| `KLIO_SAM_TRACE` | set | Implicit-receiver candidate walk and member-arm dispatch shapes | `[sam-walk]`, `[sam-direct]`, `[sam-arm]`, `[marm]` |
| `KLIO_RLP_TRACE` | `<name>` | Receiver-lambda-param lowering for bare calls of `name`: which arm engaged (marked/resolved/outer/head) and the receiver-tower `this@<label>` pick | `[rlp-arm]`, `[rlp-head]` |
| `KLIO_HEAD_TRACE` | set | Runtime head-directed receiver re-selection for `CallValueWithThis` instructions carrying a declared receiver head | `[cvth]` |
| `KLIO_SDU_TRACE` | set | Every stdlib member-dispatch call that missed both resolve-cache tiers and runs the uncached probe ladder (type, name, cacheability) | `[sdu]` |
| `KLIO_SELDBG` | set | Why an intrinsic-host `invokeMethod` probe declined (error tag + message for each swallowed non-Throw error — the recipe that separates "method missing" from "method ran and failed") | `[seldbg]` |
| `KLIO_MCRT_TRACE` | `<name>` | Member-call return-type derivation for a chained arg (`recv.map { … }`): receiver tag/type and candidate agreement | `[mcrt]` |
| `KLIO_ADM_TRACE` | set | Callable-vs-class adjudication detail inside `argDefinitelyNotParamType` | `[adm]` |
| `KLIO_MEMO_TRACE` | set | Compose plugin memoization-path decisions per lambda arg (cache / lifted singleton / remember, with capture keys) and the value-invocation call-site `$changed` bits | `[memo]`, `[bits]` |
| `KLIO_EF_TRACE` | `<name>` | Emit-form / member-shadowability decision for a named call (inline target chosen, shadowable routing, receiver-context flags) | `[ef]`, `[tbie]`, `[efset]` |
| `KLIO_INLINE_PICK` | `<name>` | Inline-overload candidate set (receiver type, owner class, file) plus the receiver chain head | `[ipick]` |
| `KLIO_EXTKEY_TRACE` | `<fid>[,<fid>]` | The eight-element extension ranking key for the named candidates, plus their parameter type heads. Ranking is lexicographic, so the first differing component is the one that decided | `[extkey]` |
| `KLIO_ARGTY_TRACE` | `<identifier>` | The static type lowering actually used for that named expression, and whether it came from an inline splice's declared parameter type. Separates "no type" from "wrong type", which look identical from a failing test | `[argty]` |
| `KLIO_SPLICE_TRACE` | `<function name>` | Whether a named `inline fun` reaches the splice path (with the declaration and call-site spans), whether the call-site splice landed or bailed to dispatch, and — matched against a lambda PARAMETER name — each caller-lambda splice with its receiver-mark state | `[splice]`, `[splice-ok]`, `[splice-bail]`, `[splice-lam]` |
| `KLIO_THIS_TRACE` | set | Every bare-`this` lowering: the active splice window, each scope index holding a `this` binding, and the register `resolve` picked. The tool for "whose `this` did this lambda capture" | `[this-trace]`, `[splice-bind]` |
| `KLIO_LEAF_TRACE` | `<substring of a function name>` | Why the frameless leaf-expression serve declined for a matching function (unsupported opcode, non-instance field receiver, unclaimed field route, callee that is not a leaf) | `[leaf]` |
| `KLIO_SBC_TRACE` | set | Constructor-vs-member routing inputs for each capitalized bare call | `[sbc]` |
| `KLIO_SUBTYPE_TRACE` | `<substr>` | Instance-supertype search during overload scoring, for target types containing the substring | `[sub]` |
| `KLIO_SHADOW_TRACE` | set | Whether an imported pack extension shadows a member call (probe plus each candidate) | `[shadow]` |
| `KLIO_BARERET` | `<name>` or `*` | Why a bare call does or does not lend its return type to the local it initializes: the receiver head it resolved against, the target, the final type, and each refusal | `[bareret]` |
| `KLIO_LI_NAMES` | set | Names the callee of every local initializer that yields no static type. Pair with `KLIO_BARERET` on whichever name dominates | `[li-null]` |
| `KLIO_DISPATCH_STATS` | `1` | Route counts per dispatch kind, plus `replay-hits`: how many named member calls the builtin intrinsic replay served outright. `member_ladder` names a route, not a walk — compare the two before reading it as name-resolution work | `[dispatch-stats]` |
| `KLIO_NOINST_WHY` | `1` | Why a statically bound slot on a host-backed receiver declined to a member-name walk: `no-slot-entry` (no `(class, slot)` mapping) or `target-not-executable` (the target is bodyless and no native is registered under its FQN) | `[noinst-why]` |
| `KLIO_NORECV_WHY` | a local name, or `*` | Why an untyped-receiver site's local has no type: `at=file:line`, the initializer's AST tag, and the deriver's terminal. NOTE: the census counts CALL sites — probe with `x.first()`, never `x.size`, or the file has no counted site at all and the measurement is vacuous | `[norecv-why]` |
| `KLIO_ICRT` | `1` | Each return-type instantiation's pre-solve state and terminal (`OK`, `bindings incomplete`, `star head`), plus which parameter refused the bind and both sides' argument counts — a `param=x(Array nargs=1) actual=Array nargs=0` row means the ARGUMENT's recorded type dropped its arguments, not a real mismatch | `[icrt]` |
| `KLIO_MAX_WORKERS` | `<n>` | Caps BOTH the dispatcher pool's compute width (default: half the cores) and its elastic IO ceiling (default: max(16, cores)). Raise it when a single instance owns the machine; the commontest sweep sets `2` for its children so a full sweep stays near half the cores | — |
| `KLIO_NORECV_NAMES` | a `[no-recv-path]` bucket name, or `*` | Names the receiver identifier behind each untyped bare-path receiver, split by why it is untyped (`local_no_decl_type`, `captured`, `enclosing_member`, `unknown`) | `[no-recv-name]` |
| `KLIO_ARGSHAPE_UNK` | set | Every argument whose applicability shape carries no type, no literal kind and no callable form — the expression forms that leave a member call unproven. Histogram the tags to pick the next typing channel | `[argshape-unk]` |
| `KLIO_NULLEXT_NAMES` | set | Every member call held off the static path because a `T?` extension of that name exists and the extension itself did not resolve — the residue of the nullable-receiver rule | `[nullext]` |
| `KLIO_SPLICE_REF` | set | The full receiver type each inline splice installs in its window, and the argument it came from. Names the link where a chain loses its type arguments | `[splice-ref]` |
| `KLIO_SLOT_BYNAME` | set | Every statically bound virtual slot call that degraded to a by-name member walk, with the slot root. The host boundary made visible | `[slot-byname]` |
| — | — | NOTE: any captured log carrying `$class$` identity-mangle rows embeds NUL bytes and is BINARY to grep — filter with `grep -a`, or matching rows silently vanish and a dump looks nondeterministic | — |
| `KLIO_COMP_TRACE` | set | The type a destructured name takes from its `componentN()` accessor, or why none was available | `[comp]` |
| `KLIO_INIT_SELF` | `0` to disable | Off, a local's own name shadows its initializer's bare call again (`val iterator = iterator()`). For A/B measurement of that channel from one binary | — |
| `KLIO_TP_HEAD` | `0` to disable | Off, a type-parameter receiver resolves only through a bound that carries no type arguments, so `C : MutableCollection<in T>` names no owner again | — |
| `KLIO_EXT_RECV_PROP` | `0` to disable | Off, a bare name in a top-level extension's body stops resolving to the extension receiver's property, so it gets no declared type | — |
| `KLIO_MEMBER_INIT` | `0` to disable | Off, a property-read, indexed-read or ALIAS initializer (`val node = coord.layoutNode`, `val held = row[1]`, `val b = a`) stops lending its type to the local | — |
| `KLIO_RECV_CHAIN` | `0` to disable | Off, a member or indexed receiver is typed only from a declared type or a call's return type, never from the type a local's own initializer lends it | — |
| `KLIO_BIND_LUB` | `0` to disable | Off, a generic call's type-parameter constraints must be EQUAL across the receiver and every argument — a subsumed constraint (`getOrDefault(k, Derived())` on a Map of Base, `listOf(Derived(), base)`) rejects the instantiation again | — |
| `KLIO_TP_DISPROOF` | `0` to disable | Off, a receiver type argument that is a declared TYPE PARAMETER stops disproving concrete-element extension candidates (`Array<T>` no longer rules out `Array<out Double>.minOrNull`) | — |
| `KLIO_SOLE_EXT` | `0` to disable | Off, the single extension candidate left after the disproof pruned every competitor is withheld again instead of committed | — |
| `KLIO_DISPROOF_TRACE` | set | Per-candidate receiver-compat decision in extension resolution: subtype result and both disproof-completeness answers | `[disproof]` |
| `KLIO_BARE_EXT` | `0` to disable | Off, a bare call in a receiver context resolves only MEMBERS of the implicit receiver — an extension written without `this.` (`toMutableList()` in an extension body) stops lending its return type | — |
| `KLIO_TP_RECV` | `0` to disable | Off, a call on a receiver typed by a TYPE PARAMETER (`M : MutableMap<in K, MutableList<T>>`) stops deriving its return type through the parameter's full upper bound, so the local it initializes loses its type again | — |
| `KLIO_SOLE_GLOBAL` | `0` to disable | Off, a bare call under a receiver context stops lending its return type even when its name has exactly one declaration program-wide | — |
| `KLIO_FACTORY_PROP` | `0` to disable | Off, only a CONSTRUCTOR call names an un-annotated property's type — a factory call (`val made = newBase()`) and a constructor PARAMETER (`private val held = start`) both stop registering a type head | — |
| `KLIO_NULL_CHAIN` | `0` to disable | Off, only a condition that is itself the whole `!= null` check narrows — an `&&` chain and an early-return guard stop smart-casting | — |
| `KLIO_AGREED_RET` | `0` to disable | Off, a bare call whose every top-level declaration agrees on a return type stops lending that agreed return to the local it initializes | — |
| `KLIO_CTOR_RET` | `0` to disable | Off, a direct constructor expression (`SlotTable().also { … }`) stops naming its own type for the value it produces | — |
| `KLIO_EAGER_MEMBER` | `0` to disable | Off, the checker's eager extern-call pick stops serving member-call lowering where the lazy engine has no receiver type or no resolver target | — |
| `KLIO_ENGINE_LAMBDA` | `0` to disable | Off, a lambda's declared fn type is no longer instantiated through the one-pass call-binding solve (receiver + typed args + explicit type args) | — |
| `KLIO_ITC_MEMBER` | `0` off, `1` on (default), or `name1,name2` | Whether a member the receiver type provably declares commits statically over the `OrGlobal` fallback; a name list restricts the commit to those calls | — |
| `KLIO_LAMBDA_REFUTE` | `0` to disable | Off, a lambda argument stops refuting candidates whose parameter names a resolvable non-fun-interface class | — |
| `KLIO_LAMBDA_RET` | `0` to disable | Off, lambda argument shapes are no longer enriched from the target's declared `Function`-typed parameters | — |
| `KLIO_MEMBER_EXT_SPLICE` | `0` to disable | Off, a member body's own extension call stops qualifying for the inline splice | — |
| `KLIO_MEMBER_PROMO` | `0` to disable | Off, a deferred member call is never promoted to a static bind by the member-compatible / every-extension-refuted proof | — |
| `KLIO_NAMED_COMMIT` | `0` to demote | `0`, a candidate that named-argument mapping skipped stays a typing-only answer instead of committing for emission | — |
| `KLIO_RECV_REFUTE` | set to enable (default off) | On, a candidate whose declared receiver classifier is provably unrelated to the proven static receiver is dropped outright (kotlinc's static receiver semantics; the lazy default keeps runtime-polymorphic leniency) | — |
| `KLIO_REFSHAPE` | `0` to disable | Off, a callable-reference argument (`::f`) stops contributing its declaration-read function type to the argument shapes | — |
| `KLIO_STAR_RET` | `0` to disable | Off, a type parameter still unbound after the receiver and every argument had their chance refuses the whole return instantiation instead of erasing to `*` | — |
| `KLIO_SUBST_NONGEN` | `0` to disable | Off, a head-only receiver naming a non-generic class stops counting as a complete substitution receiver (`SlotWriter.let { … }` no longer binds `T := SlotWriter`) | — |
| `KLIO_THIS_NARROW` | `0` to disable | Off, an `is`-narrowed `this` stops serving as the innermost implicit receiver head for bare calls | — |
| `KLIO_TOWER_EMIT` | `0` to disable | Off, a bare call stops committing statically to an OUTER tower entry's extension through its `this@<label>` slot | — |
| `KLIO_TOWER_EXT` | `0` to disable | Off, typing-side bare-call extension resolution stops trying the outer implicit-receiver tower entries when the innermost head serves none | — |
| `KLIO_TOWER_SCOPE` | `0` to disable | Off, a this-capturing lambda or parameter thunk never counts its receiver scope complete through the tower | — |
| `KLIO_VOWN` | `0` to disable | Off, a stub or value-class owner stops emitting its virtual slot and declines to the member-name walk | — |
| `KLIO_HDR_BOUNDS` | `0` to disable | Off, header-stub type-parameter bounds are not registered at image build, so bare-call resolution loses them | — |
| `KLIO_HDR_BOUNDS_SKIP` | `<substr>` | Skips header-bound registration for functions whose name the value contains — the per-name bisect of `KLIO_HDR_BOUNDS` | — |
| `KLIO_HDR_BOUNDS_LIST` | set | Prints each function's registered header bounds as they are put | `[hdrb]` |
| `KLIO_NO_LR_ABSORB` | set disables | Set, an inline body containing `return@<fnName>` no longer gets the labeled-return absorb region | — |
| `KLIO_NO_LR_STATIC` | set disables | Set, a `return@<inlineFnName>` inside a spliced lambda stops resolving statically to the splice frame's join | — |
| `KLIO_SPLICE_HYG` | `0` to disable | Off, a top-level extension's spliced body resolves in the caller's member scope instead of its own declaration scope | — |
| `KLIO_SPLICE_PIN` | set disables | Set, a bound-receiver member call inside a splice is no longer pinned to its virtual slot — the per-invocation walk arbitrates again | — |
| `KLIO_SLOT_TRACE` | `<name>` or `*` | Each inherited-slot merge decision for methods of that simple name: the competing FuncIds and which one the class's table keeps | `[slot-merge]` |
| `KLIO_SLOT_DUMP` | `<name>` | Every `(class, slot) -> implementation` entry whose target has that simple name, with the target's owner — what runtime virtual dispatch will actually reach | `[slot-dump]` |
| `KLIO_ABSVETO_TRACE` | set | Each inline-overload pick vetoed because a member of the receiver chain takes the call instead | `[absveto]` |
| `KLIO_AGREED_TRACE` | `<name>` or `*` | Why the agreed-top-level-return channel accepted or refused the name (top-level usable, enclosing member, class-member namesake, ...) | `[agreed]` |
| `KLIO_ALPT` | `<fn name>` (`[alpt-site]` rows fire on any set value) | Argument-lambda parameter-type computation for calls of the named target: entry shape, each filled slot, and which emit site asked | `[alpt]`, `[alpt-slot]`, `[alpt-site]` |
| `KLIO_APPLIC_TRACE` | set | Candidates the shared applicability scorer refuses: the runtime re-pick's null scores and the named-arm hard-reject site that declined | `[pp-null]`, `[applic-reject]` |
| `KLIO_BAREARM` | set | The bare-member arm of unresolved bare-call lowering: why it broke (no class id, no `this` register) and each final miss with file:line | `[barearm-break]`, `[barearm-miss]` |
| `KLIO_BARG_TRACE` | `<fn name>` (`[barg-ids]` rows fire on any set value) | Static bare-call argument compatibility: per-argument param-vs-arg verdict with route, plus the receiver class-id scoping rows | `[barg]`, `[barg-ids]` |
| `KLIO_BCC_WHY` | set | Why the package/import-scoped bare-call candidate set came back empty (no candidates, no visible tier, other-package tier, no arity match) | `[bcc]` |
| `KLIO_BINDS_TRACE` | `<name>` | Whether a bare name binds `this`: receiver-chain head, hierarchy-shadow completeness, own-member state, and the verdict | `[binds]` |
| `KLIO_CHAN` | `<name>` | Snapshot of every receiver channel at a bare call in receiver context: `this`-narrow, splice hint and receiver, owner class, `this` decl, static head | `[chan]` |
| `KLIO_CITR_TRACE` | `<name>` | Constructor-initializer type derivation for a bare ctor call: the local-class head or the bail reason (local/outer binding, function namesake, no class) | `[citr]` |
| `KLIO_CIX_TRACE` | `<class name>` | Scoped class-by-simple-name resolution: each candidate's fqn, package, and tier | `[cix]` |
| `KLIO_CPT_TRACE` | set | Why instantiating a declared receiver typed by a class type parameter declined | `[cpt]` |
| `KLIO_CTORLPT_TRACE` | set | Constructor trailing-lambda parameter typing: the class row's parameter shapes at each ctor call carrying lambda args | `[ctorlpt]` |
| `KLIO_DECLTY_TRACE` | `<name>` | The receiver static type a member call of that name resolved against, and whether it came from a declaration or the full deriver | `[declty]` |
| `KLIO_DROP_TRACE` | `<name>` | Why each bare-call candidate dropped from the applicable set (form mismatch, low priority, no sig view, inapplicable shape, static-incompatible) | `[drop]` |
| `KLIO_EBM_TRACE` | set | Expression-body member registry register/lookup rows (currently keyed to `createOnCancellationAction` only) | `[ebm]` |
| `KLIO_EMIT_TRACE` | `<name>` or `*` | Every `Call`/`CallVirtual`/`CallMember`/`CallMemberOrGlobal` instruction pushed for that simple name, with the resolved target and emitting function | `[emit]` |
| `KLIO_EMIT_STACK` | set (needs `KLIO_EMIT_TRACE`) | Adds a native stack trace naming the emitting arm at each traced `CallMember` push | native stack |
| `KLIO_EXPECT_HDR_TRACE` | set | Each bodyless `expect`-class member retained as a header row binding its host symbol | `[expect-hdr]` |
| `KLIO_FORVAR_TRACE` | set | Each for-loop variable whose iterable element type could not be derived, so the variable lowers untyped | `[forvar]` |
| `KLIO_GRA_TRACE` | `<receiver head>` | The generic-receiver applicability walk for actual receivers with that head: head relation, binding failures, and per-param bound checks | `[gra]` |
| `KLIO_HOP_TRACE` | set | The `+`/`-` operator's member-call lowering channels, and a type-parameter-headed receiver substituting its full bound before extension ranking | `[binop-in]`, `[binop]`, `[hop]` |
| `KLIO_IMPLPROP_TRACE` | `<name>` | Implicit property-read typing for that name: the bare, guard, implicit-receiver, and member arms with their channel state | `[implprop]`, `[implprop-bare]`, `[implprop-guard]`, `[implprop-mem]` |
| `KLIO_LAMINH` | set | The lambda-body declared-type inheritance channel: the pending snapshot each lambda body consumes (an empty pending while the enclosing builder holds records means the records were lost) | `[laminh]` |
| `KLIO_LAMRET_TRACE` | set | The lambda-return-directed extension-family pick: the derived return head's winner and the instantiated callee return | `[lamret-pick]`, `[lamret-inst]` |
| `KLIO_LAMRET_WHY` | `<substr of an fqn>` | Per-candidate skip reasons in the lambda-return family walk (no body, receiver mismatch, non-fn last param) | `[lamret-why]` |
| `KLIO_LAR_TRACE` | set | The lambda-arg declared-receiver record: each put and get keyed by argument span | `[lar-put]`, `[lar-get]` |
| `KLIO_LFN_TRACE` | set | Local-fn overload selection for bare calls: overload count, the selected mangled cell, applicability, and capture reachability | `[lfn]` |
| `KLIO_NOCLASS_HEADS` | set (needs `KLIO_DISPATCH_STATS`) | Names each receiver head the census counted as having no class id, with its bound record where one exists | `[no-class-head]` |
| `KLIO_OPTY_TRACE` | set | Indexed-read return typing (`a[i]` as `get` on the container): receiver typing and the answer | `[opty]` |
| `KLIO_OVERRIDES_TRACE` | set | Why `overridesSlot` rejected each (own method, inherited slot) pair: missing sigs, kind/arity mismatch, no ancestor bindings, param-type mismatch | `[ovr]` |
| `KLIO_PROMO_NAMES` | set | Member-promotion proof verdicts, each `PROMOTED`/`HELD` with the refusal reason (the per-candidate `[promo-ext]` rows also need `KLIO_DISPATCH_STATS`) | `[promo-ext]`, `[promo-proof]` |
| `KLIO_REF_TRACE` | `<name>` | `::name` callable-reference lowering state: local-ext detection, receiver context, resolve/capture reachability, and the expected fn type | `[ref-trace]` |
| `KLIO_RENAME_TRACE` | set | Each package-scope type-rename resolution (an `internal` classifier renamed for its whole package) | `[rnm-pkg]` |
| `KLIO_REX_TRACE` | set | Extension-resolution ranking, one window per call: the call row, per-candidate state, each scored key or disqualification, and the exit reason | `[rex-call]`, `[rex]`, `[rex-key]`, `[rex-exit]` |
| `KLIO_RH_TRACE` | set | Each receiver-lambda body head the type checker records for the eager channel | `[rh-put]` |
| `KLIO_RMC_TRACE` | `<name>` | Per-candidate member-args-compatibility verdict during member resolution | `[rmc]` |
| `KLIO_SCOPEFN_TRACE` | set | The scope-function (`let`/`run`/`also`/`apply`) return-derivation arm: enter and each bail reason | `[scopefn]` |
| `KLIO_SCORE_TRACE` | set | The applicability scorer's per-argument refusals: parameter vs argument type at each null score | `[score-null]` |
| `KLIO_SCRT_TRACE` | `<name>` | The static call-return-type derivation for calls of that name: which channel answered, the explicit-type-arg arm, the agreed-return handoff, and the final answer | `[scrt-via]`, `[scrt-out]`, `[scrt-path]`, `[scrt-agreed]`, `[scrt-target]`, `[expl]` |
| `KLIO_SIBEXP_TRACE` | set | The sibling-argument expected-type solve: the pushed instantiation or the bail | `[sibexp]`, `[sibexp-inst]`, `[sibexp-bail]` |
| `KLIO_SIBEXP_WHY` | `<outer fn name>` | Per-candidate skip reasons in the sibling-expected solve (receiver untyped, no bindings, result not concrete) | `[sibexp-why]` |
| `KLIO_SMAC_TRACE` | `<fn name>` | Static member-args compatibility: entry state and each argument's instantiated-parameter verdict with route | `[smac]`, `[smac-arg]` |
| `KLIO_TLP_TRACE` | `<prop name>` | The tiered top-level property type-head lookup: each declaration's package, tier, and head | `[tlp]` |
| `KLIO_VABI_NAMES` | set | Each member call declined off the virtual-slot emit, with the owner's receiver ABI and body state | `[vabi]` |
| `KLIO_VALTY_TRACE` | `<local name>` | Property-decl lowering entry state for that local, and every declared-type write recorded under the name | `[valty]` |
| `KLIO_VALTY_STACK` | set (needs `KLIO_VALTY_TRACE`) | Adds a native stack trace at each declared-type write | native stack |
| `KLIO_VARARG_TRACE` | set (most rows keyed to `listOf`) | The sole-trailing-vararg full-instantiation derivation (`listOf("a")` as `List<String>`): guards, candidate refusals, and element typing | `[vaf-guard]`, `[vaf-nocands]`, `[vaf-enter]`, `[vaf-cand]`, `[vaf-sole]`, `[vaf]` |

The `0`-to-disable rows above exist so one binary can be compared against
itself: `scripts/examples-ab.sh KLIO_SOME_GATE` runs the examples corpus both
ways and reports what differs. It skips the twelve examples that never
terminate (each blocks on a window or event loop at ~0% CPU, at every commit) —
left in, they cost twice the timeout apiece for no signal and turn a five-minute
comparison into a three-hour one.

| `KLIO_OPERATOR_TY` | `0` to disable | Off, an indexed read and the `times`/`div`/`rem`/`rangeTo` operators stop lending their declared return type to a receiver | — |
| `KLIO_GLOBAL_TRACE` | `<name>` | Which arm resolves a global lookup: cached value, function, or intrinsic | `[gtrace]` |
| `KLIO_OUTER_TRACE` | `<substr>` | Inner-class enclosing `this@Outer` selection for IR names containing the substring | `[outer]` |
| `KLIO_ANON_AUDIT` | set | Synthesized class name and captured names at each anonymous-object site | `[ANON]` |
| `KLIO_REBIND_AUDIT` | set | Arity-guess `this` rebinds during closure invocation | `[REBIND]` |
| `KLIO_CVNRC` | set | A this-less closure invoked on an instance receiver being rebound to `callValueWithThis` | `[cvnrc]` |
| `KLIO_TRACE_RESOLVE` | `name1,name2` or `*` | Per-dispatch decision log for the named function(s) | `[RESOLVE]` |
| `KLIO_TRACE_CHAIN` | set | Adds the enclosing-`this` chain to each traced dispatch (with `KLIO_TRACE_RESOLVE`) | `[RESOLVE]   chain=` |
| `KLIO_TRACE_PATH` | set; `0`/empty off | One structured record per terminal dispatch site (proves single-path dispatch; see `scripts/assert_single_path.py`) | `[PATH]` |
| `KLIO_TRACE_INVARIANTS` | set; `0`/empty off | Detect-only dispatch invariant checks, one machine-readable line per violation | `[INVARIANT]` |
| `KLIO_TRACE_CAPTURE` | set | A lambda capture that fails to resolve and collapses to `Unit` | `[CAPTURE]` |
| `KLIO_UNRESOLVED_TRACE` | set | The unresolved bare name, function, and span just before an `Unbound` error | `[unresolved]` |
| `KLIO_INIT_DEBUG` | set | `object`/companion initializer first-failure and the cause take/swallow/restash steps | `[init-debug]` |
| `KLIO_ANON_BASE` | `0` to disable | Off, anonymous-object synthesis lowers against the empty side module instead of the image-clone, leaving every call in anon bodies name-dynamic | — |
| `KLIO_ANON_PROP` | `0` to disable | Off, an anon object's property type heads are not carried into its member lowerings, so sibling bodies lose their bare property-read types | — |
| `KLIO_BARRIER_TRACE` | set | The type-safe collection bridge (erased-bound check on generic members called through an erased signature): each refusal reason | `[barrier]` |
| `KLIO_CFN_TRACE` | `<substr of a fn name>` | Named-argument call binding: the declared parameter list vs the supplied names, on both the named and the typed entry | `[cfn]`, `[cft]` |
| `KLIO_CHAIN_TRACE` | set | Enclosing-`this` chain activation per frame: enter/activate with thread id, frame pointers, and chain base (high volume) | `[chain]` |
| `KLIO_DCS_TRACE` | set | The declaring-class scan for a FuncId — the per-class method walk feeding the owner cache (very high volume) | `[dcs]` |
| `KLIO_DRAIN_TRACE` | set | Each Iterable receiver drained to a list by the collection fallback, with the caller and call-site span | `[drain]` |
| `KLIO_FASTPLAN_TRACE` | `<substr of a fn name>` | Why a function is ineligible for the monomorphic fast call plan (no body, inline, extension, defaults, sibling overloads, ...) | `[fastplan]` |
| `KLIO_ITER_TRACE` | set | The builtin iterator's `next()` element kind per call | `[iter-next]` |
| `KLIO_KTYPE_TRACE` | set | Each synthetic `KType` materialized for a reified type name, with the enclosing function | `[ktype]` |
| `KLIO_MEOI_TRACE` | `<owner class>` | Member-extension dispatch-receiver selection: the enclosing entries walked and each owner-identity verdict | `[meoi]` |
| `KLIO_NOINST_TRACE` | set | Each virtual slot resolved by member name against the runtime class of a host-backed (non-`Instance`) receiver | `[noinst]` |
| `KLIO_PICK_TRACE` | `<name>` | The runtime overload re-pick: the base candidate's applicability score and every sibling's | `[pick]` |
| `KLIO_QT_TRACE` | `<substr of a qualifier>` | The qualified `this@Qualifier` receiver walk: each candidate class and the match | `[qt]` |
| `KLIO_REDIR_TRACE` | set | Value-shaped redirect-target resolution among same-arity expect/actual siblings | `[redir]` |
| `KLIO_RFP_DUMP` | set | Dumps every registered receiver-fn-property `(receiver, name)` pair when the gate masks build | `[rfp]` |
| `KLIO_ROUTE` | `<name>` | Which runtime arm bound each `*OrGlobal` execution of that name (member@depth, overload, global-id, global, the fallback variants), plus dispatch-ladder route markers | `[route]` |
| `KLIO_SLOT_RECV` | set (needs `KLIO_SLOT_BYNAME`) | The slot-byname note prints the receiver's runtime type instead of the slot root | `[slot-recv]` |
| `KLIO_THIS_TRAP` | set | Every frame entry that binds a Bool or Int into a `this` parameter — the ext-receiver misbind signature — with the caller | `[this-trap]` |
| `KLIO_VFLAT_TRACE` | set | One line per declined virtual flat prepare, with the reason a slot population stays recursive | `[vflat]` |
| `KLIO_WALK_TRACE` | set | Each by-name IR method walk and extension-fallback walk entry, with the receiver and cache-key state | `[ir-walk]`, `[extfb-walk]` |

```sh
KLIO_BARE_TRACE=format KLIO_MISS_TRACE=format ./zig-out/bin/klio run repro.kt
```

## Resolution audits and the eager front end

The resolver + type checker always run ahead of lowering; their overload
picks and type heads feed it. There is no switch — `KLIO_EAGER` was removed
once validation was identical with and without the evidence. A
resolver/typeck failure still falls back to AST evidence alone, so a program
that defeats the front end runs.


The audit switches emit machine-readable divergence records the
sweep scripts grep; see
[Testing and verification](testing.md) for the
`resolve_audit_sweep.py` cycle.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_EAGER_AUDIT` | set | Eager-pipeline bookkeeping (skip reasons, record counts) and eager-vs-lazy pick disagreements | `[EAGER]`, `[EAGER-AUDIT]` |
| `KLIO_EAGER_HITS` | set | Per-call eager record/probe/hit/miss logging (high volume) | `[EAGER-REC]`, `[REC-MSC]`, `[EAGER-PROBE]`, `[EAGER-HIT]`, `[EAGER-MISS2]` |
| `KLIO_RESOLVE_AUDIT` | set (any value, even `0`, enables) | One record per bare call / inline target / value ref comparing the symbol index against the order-based heuristic, with a divergence grade | `[KLIO_RESOLVE_AUDIT]` |
| `KLIO_RESOLVE_STRICT` | set; `0`/empty off | Turns an unexplained index-vs-heuristic divergence into a panic instead of a log line | none (panics) |
| `KLIO_OR_AUDIT` | set; `0`/empty off | Member-vs-global audit: each `*OrGlobal` emission decision and the runtime arm that actually bound (`scripts/or_audit_sweep.py` asserts the lenient-arm residue) | `[KLIO_OR_AUDIT]` |
| `KLIO_LINK_AUDIT` | set (any value enables) | Re-derives what the deleted per-call dispatch ladder would have chosen and logs any disagreement with the link-settled tables | `[KLIO_LINK_AUDIT]` |
| `KLIO_RECVHEAD_AUDIT` | set | Whether the type checker's recorded receiver-lambda head can answer the membership walk | `[RECVHEAD-AUDIT]` |
| `KLIO_TYPEHEAD_AUDIT` | set | The type checker's per-argument type head vs the AST-derived declared type (fills and disagreements) | `[TYPEHEAD-FILL]`, `[TYPEHEAD-AUDIT]` |
| `KLIO_DECL_AUDIT` | `1` | Completeness audit of the no-holes symbol table after the run: every intrinsic FQN paired with whether the module declares it, tallied per package with hole samples. Program-scoped — the lazy IR only declares what the program reached, so the number is a lower bound | `[decl-audit]` |

`scripts/commontest-sweep.py` accepts `--eager` for compatibility and
ignores it: there is only one pipeline, so `both` just runs the corpus
twice and reports any run-to-run divergence (useful for catching
nondeterminism, not modes).

## Errors, throws, and hangs

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_ERR_TRACE` | set | On otherwise-traceless Vm failures: the live frame chain plus a site-specific miss line (unresolved field get, uninvokable call value, unmatched `this@label`). In `klio test` it also renders the full throwable (type, message, frames, causes) instead of the terse summary | `[errtrace]`, `[getfield-miss]`, `[callvalue-miss]`, `[labeled-this]` |
| `KLIO_THROW_TRACE` | set | One line per exception as it is thrown (including failed casts that raise without a `Throw`) | `[throw-trace]` |
| `KLIO_THROW_STACK` | set (needs `KLIO_THROW_TRACE`) | Adds the full frame chain at each throw site | `[errtrace]` |
| `KLIO_LR_TRACE` | set | Labeled-return propagation through interpreter frames (raise, pass, exit) | `[lr-raise]`, `[lr]`, `[lr-exit]` |
| `KLIO_AMP_TRACE` | `<substr>` | A resolution-class error about to be re-tagged as `CalleeFailed` whose message contains the substring; dumps the frames before they are torn down | `[amp]` |
| `KLIO_SPIN_TRACE` | seconds (unparsable values fall back to 30) | Every N seconds of wall time, dumps the live frame chain and the innermost frames' registers, so a run that never returns names its loop | `[spin]` |
| `KLIO_SEGV_TRACE` | set | Installs a segfault handler at startup so SIGSEGV/SIGBUS prints a native backtrace | native backtrace |
| `KLIO_MAX_EVAL_DEPTH` | number (default 2000) | Caps interpreter recursion depth; on breach returns a catchable `StackOverflow` instead of faulting the native stack | none |
| `KLIO_RUN_TIMEOUT_S` | seconds (`0`/unset off) | Wall-clock deadline for the whole run; a watchdog thread aborts the process when it expires | `[klio]` |
| `KLIO_TEST_WALL_CAP` | seconds (default 300; `0` disables) | Per-test wall cap in `klio test`: a wedged test fails "test wall-clock deadline exceeded" instead of hanging the run | none |

```sh
KLIO_ERR_TRACE=1 KLIO_THROW_TRACE=1 KLIO_THROW_STACK=1 ./zig-out/bin/klio run repro.kt
```

## Coroutines and the pump

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_PUMP_DIAG` | set | The cooperative pump: loop/slot/parked dumps, the park/adopt/persist/take token lifecycle, stalled-pump dumps, idle-streak and exit-time sleep attribution | `[PUMP]`, `[tok]`, `[pump-streak]`, `[wall-timer]`, `[pump-sleep]` |
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

The `@Composable` lowering plugin + upstream engine runtime is the only compose
path — it always runs. These knobs bisect its two emissions.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_COMPOSE_DBG` | set | One activation summary line (oracle sizes) plus group-emission debug inside the pass | `[compose-pass]` |
| `KLIO_COMPOSER_BIND_TRACE` | set | Each call that threads the `$composer, $changed` pair: the owning declaration and the composer's class (a non-Composer instance in the pair slot also dumps the frame chain) | `[composer-bind-fn]`, `[composer-bind]` |
| `KLIO_RSS_LOG` | set | Prints process RSS on each rendered Compose UI frame | `[rss]` |

```sh
./zig-out/bin/klio run scene.kt      # plugin lowering
KLIO_COMPOSE_SKIP=0 ./zig-out/bin/klio run scene.kt   # bisect the skip calculus
```

## Compose UI and Skia

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_SKIA_LIB` | path | The Skia shim library to load at runtime (first in the search order) and to embed when bundling | none |
| `KLIO_SKIA_GPU` | set | Requests a GPU (Ganesh+EGL) surface for offscreen render; falls back to raster on failure | none |
| `KLIO_SKIA_VERBOSE` | set | One-line backend notes: window backend chosen, dump writeback result | `[klio-skia]` |
| `KLIO_SKIA_DUMP` | path | Writes the first presented GPU frame to the given PNG path (Metal builds) | none |
| `KLIO_SKIA_FONT` | path | Typeface override for text painting (checked before the bundled and system fonts) | none |
| `KLIO_COMPOSE_DEBUG` | set | Traces the SDL+GL / Skia GPU-window bring-up path in the C++ shim | `[klio-compose]` |
| `KLIO_PARA_TRACE` | set | Traces SkParagraph text-layout construction (font/unicode readiness, lengths) | `[para]` |
| `KLIO_DRAW_TRACE` | set | Each canvas rect draw with its surface, geometry, and color | `[draw]` |

## Performance profile, JIT, and profiler

The profile itself (`--opt` / `KLIO_OPT`) is documented in
[Performance](../architecture/performance.md); the granular
variables override individual fields on top of it.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_OPT` | `fast`/`safe`/`off` (aliases: `full`, `on`, `balanced`, `none`, `interp`) | Selects the performance profile: JIT tiers plus memory backend. `klio run` defaults to `fast`, `klio test` to `safe` | none |
| `KLIO_JIT` | `1` on, `0` off | Loop-tier JIT override on top of the profile (on by default under `fast`) | none |
| `KLIO_FLAT` | `0` off (default on) | The flat call driver; `0` falls back to native recursion for every call (bisect) | none |
| `KLIO_FLAT_VCALL` | `0` off (default on) | The fused virtual flat path; `0` keeps slot-bound and lowering-resolved member calls on the recursive invoker (bisect) | none |
| `KLIO_MEMBER_SITE` | `0` off (default on) | The `CallMember` instruction-site memo — the by-name replay path; `0` disables for bisection | none |
| `KLIO_NATIVE_TRACE` | set | In a transpiled binary (`klio transpile` + libklio_rt): one line per native activation with its entry block and outcome, plus a miss line for user-package functions with no (or an fqn-guarded) native table entry — the engagement oracle: output parity alone cannot distinguish native execution from silent fallback to interpretation | `[native]`, `[native-miss]` |
| `KLIO_CM_TRACE` | `<member name>` | At every CallMember execution of that name: the executing frame, whether lowering resolved it, and the full enclosing-`this` chain with entry kinds — the receiver-visibility debugger for member-extension dispatch | `[cmarm]` |
| `KLIO_GF_TRACE` | `<substr of a field name>` | Every GetField execution whose field name matches: field, receiver class, executing frame — pairs with `KLIO_CM_TRACE` to separate a wrong read from a wrong dispatch | `[gfarm]` |
| `KLIO_RSEL_TRACE` | set | Every compatibility receiver re-selection at a receiver-lambda invoke: the recorded head, the passed receiver, and what was selected | `[rsel]` |
| `KLIO_FUNC_JIT` | `1` on, `0` off | Whole-function JIT override; turning it on also forces the loop tier on | none |
| `KLIO_JIT_DEBUG` | set; `0`/empty off | Per-decision JIT tracing: compile, bail, inline, evict | `[jit]` |
| `KLIO_RECLAIM` | `gc`, `arena`, `smp`/`free`/`1`, `debug`, `0` | Memory backend override (and whether refcount teardown is active); the profile default is the tracing GC | none |
| `KLIO_PROF` | set; value = sampling interval in microseconds (default 1000, floor 100) | Statistical SIGPROF profiler; prints a by-function sample histogram to stderr at the end of the run (Linux) | `[prof]` |
| `KLIO_PROF_ALL` | set (needs `KLIO_PROF`) | Widens profiling to the whole process, including startup and image decode | `[prof]` |
| `KLIO_PROF_CALLERS` | `<substr>` | After the histogram, folds the callers of every sampled leaf whose name contains the substring | `[prof]` |
| `KLIO_OP_PROF` | set; value = sampling interval in microseconds (default 1000, floor 100) | Opcode sampler: a SIGPROF histogram over the interpreter's currently executing opcode tag (with host-route sub-tags), printed at the end of the run as self-time by opcode | `[op-prof]` |
| `KLIO_FN_PROF` | set; value = sampling interval in microseconds (default 1000, floor 100) | Kotlin-function sampler: a SIGPROF histogram over the INTERPRETED program's currently executing function, printed as self-time per Kotlin function. `KLIO_PROF` attributes time to interpreter internals; this one names the library body to serve or splice. Self-time excludes a callee only when the callee gets its own frame: a leaf- or bytecode-served callee is attributed to its caller | `[fn-prof]` |
| `KLIO_FRAME_COUNT` / `KLIO_FRAME_CENSUS` / `KLIO_FRAME_WATCH=<substr>` | set / substring | How many interpreted activations a workload runs (`activations` = register-bank acquisitions, one per real frame; `entries` = `runFrameExec` entries, higher because a flat call re-enters its caller's frame at the return block), with `_CENSUS` the top functions by activation count and `_WATCH` a line per activation of a matching function naming its caller. The frames-per-unit metric that separates "too many frames" from "frames too expensive" | `[frames]`, `[framewatch]` |
| `KLIO_CALL_STATS` | set | Counts every interpreted function invocation by FQN over the whole run; `klio test` prints the top entries after the summary. The workload census that separates "slow per call" from "more calls than the reference would make" (missed skipping, repeated recompose, un-inlined accessors) | `[call-stats]` |
| `KLIO_CALLVALUE_TRACE` | set | Flat closure-call preparation on the value-call path: per-argument kinds and under-application | `[flat-prep]`, `[cvt-flat]` |
| `KLIO_DUMP_FN` | `<name>` or a numeric FuncId | Prints the named function's lowered instruction stream the first time it runs (and its block table at startup) — the only way to see what an emit path produced for a body inside a baked pack | `[dumpfn]` |

```sh
KLIO_PROF=500 KLIO_PROF_CALLERS=append ./zig-out/bin/klio run bench.kt
```

## Memory: GC, allocators, and leak tracking

The `KLIO_GC_*` family, `KLIO_GC_ALLOC`, `KLIO_LEAK_BY_FQN`, and the
slab tracers take effect only when the run uses the tracing GC
backend (the default for `fast`/`safe`).

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_GC_DEBUG` | set; `0`/empty off | One summary line per collection: epoch, kind (minor/major), marked, live bytes, freed | `[kgc]` |
| `KLIO_GC_GEN` | `1` on (default), `0` off | Generational collection: minor (nursery-only) sweeps between Appel-scheduled majors; `0` forces every collection major | none |
| `KLIO_GC_GROWTH` | integer, min 2 (default 2) | The Appel growth multiplier: the next collection fires after `live * factor` bytes | none |
| `KLIO_GC_MINOR_STOP` | `1` on (default), `0` off | Whether a minor mark stops at tenured cells; `0` full-traces minors to bisect a missed-barrier suspicion | none |
| `KLIO_GC_REMEMBER_TRACE` | set | Logs, with a native stack, any remembered-set cell as it is swept | `[gc-freed-remembered]` |
| `KLIO_GC_HIST` | set; `0`/empty off | Top-16 live-cell payload types per collection | `[kgc-hist]` |
| `KLIO_ENUM_INIT_TRACE` | set | VM-start enum entry construction: which entries are rebuilt through the class path and the header thunk chain per class | `[enum-init]`, `[chain]` |
| `KLIO_CTOR_TRACE` | set | Each secondary-constructor default-argument thunk as it is evaluated (class, parameter, thunk id, argument count) | `[ctor-default]` |
| `KLIO_TOPPROP_TRACE` | set | A top-level property initializer that deferred to on-access during the startup pass, with its error tag | `[topprop-defer]` |
| `KLIO_BOX_FILTER` / `KLIO_BOX_JOBS` / `KLIO_BOX_TIMEOUT_MS` | substring / count / ms | The box conformance runner's test subset, worker width, and per-test wall | `[box-fail]`, `[box-excluded]` |
| `KLIO_GC_STRESS` | set; `0`/empty off | Collects at every safe point; surfaces incomplete roots/tracers immediately | none |
| `KLIO_GC_STRESS_EVERY` | number (`0` off) | Collects every N safe points (cheaper sampled stress) | none |
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
| `KLIO_SLAB_STAT` | set | Total bytes currently mapped from the OS, printed at exit | `[slab]` |
| `KLIO_SLAB_TRACE` | set | Capture stacks of every live slab/large mmap, dumped at exit or on SIGTERM/SIGINT | `[slabtrace]` |
| `KLIO_CELL_TRACE` | set | Sampled tracking of live small slab cells with their allocation stacks | `[slabtrace]` |
| `KLIO_DECODE_STATS` | set | Per-type decoded bytes/nodes while loading a stdlib/module image, top 25 by bytes | `[decode-stats]` |
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
| `KLIO_STDLIB_IMAGE` | `0` disables | The stdlib image cache; disabled, every run lowers the full dependency set | none |
| `KLIO_TRACE_STDLIB_IMAGE` | set; `0`/empty off | One `hit`/`baked`/`fallback` line per run with the cache key and timing | `[stdlib-image]` |
| `KLIO_PACK_DIAG` | set | Disables the image cache so the legacy loader runs, and turns on its diagnostics (per-source lex/parse error dumps) | `[embed lex err]` |
| `KLIO_AST_REBASE_TRACE` | set | Old-to-new FileId mapping when a cached AST bundle's spans are rebased | `[ast-rebase]` |
| `KLIO_BUNDLE_INSPECT` | `1` (`0` off) | A bundled executable prints its manifest and payload table, then exits without running | manifest listing |
| `KLIO_BUNDLE_PROGRAM_IMAGE` | `0` disables (default on) | Whether bundling attempts the whole-program image bake; `0` forces the program-source boot path | none |
| `KLIO_STUB_DIR` | directory | Local source for cross-target runtime stubs and Skia shims (`<dir>/<target>/<name>`), checked before the download cache | none |
| `KLIO_STDLIB_CHECK` | `0` disables | Checking the stdlib base's own sources while an image is built (publishes extern decls and eager call resolutions for the checker) | none |
| `KLIO_ENUM_INIT_TRACE` | set | Names any enum-instance field APPENDED rather than replaced in place during baked-enum init — the signature of a bake that dropped a field | `[enum-init-append]` |

## Libraries and the front end

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_TRACE_HTTP` | set | Logs each outbound ktor HTTP request (method + URL) before the transport runs | `[HTTP]` |
| `KLIO_SERVE_MAX` | number (`0`/unset unlimited) | Caps the embedded ktor server to N requests so a leak-checking run reaches its exit report | none |
| `KLIO_DOLLAR_TRACE` | set | Lexer trace for multi-dollar string-template arming (file, position, source window) | `[dollar-arm]` |
| `KLIO_REPEAT_DBG` | set | The `String.repeat` intrinsic's argument tags per call | `[srep]` |
| `KLIO_SEQ_DIAG` | set | A sequence drain whose iterator lacks `hasNext`, with the iterator's kind and FQN | `[seq-diag]` |
| `KLIO_UCTOR_TRACE` | set | An unsigned constructor refusing its argument shape, with the argument tags and a frame dump | `[uctor]` |

## Test harness and dev tooling

These are honored by the itest binaries, the parity harness, and
the scripts, not by `klio run` itself.

| Variable | Values | What it shows/does | Output tag |
|----------|--------|--------------------|------------|
| `KLIO_ITEST_BIN` | path (default `zig-out/bin/klio`) | The `klio` binary child-spawning itests run; `zig build` points it at the installed harness | none |
| `KLIO_ITEST_VERBOSE` | set | Surfaces the differential itest's otherwise-suppressed progress lines | none |
| `KLIO_TEST_FILE_TRACE` | set | `klio test` prints each selected file's path-to-FileId mapping | `[test-file]` |
| `KLIO_COMMONTEST_SHARD` | `K/N` | Runs shard K of N of the commontest target list (weighted split; set by CI) | none |
| `KLIO_E2E_SHARD` | `K/N` | Runs only corpus programs whose name hashes into shard K of N | none |
| `KLIO_E2E_FILTER` | `<substr>` | Restricts the e2e corpus to programs whose file stem contains the substring | none |
| `KLIO_E2E_TRACE` | set | One line per e2e program as it runs, with the JIT state | `e2e RUN` |
| `KLIO_TRACE_STDLIB_BASE` | set; `0`/empty off (Linux) | One `fast`/`fallback` line per program: was the baked dependency base reused or rebuilt | `[stdlib-base]` |
| `KLIO_PARITY_BASE_IMAGES` | directory | Where the parity/e2e/bench harness loads the baked base images from (`zig-out/parity-base` when running an itest binary by hand) | none |
| `KLIO_PARITY_JOBS` | number (default: CPU count, cap 6) | Parity sweep worker count | none |
| `KLIO_PARITY_JAVA_XMX_MB` | MB (default 2048) | JVM heap ceiling for the kotlinc oracle | none |
| `KLIO_PARITY_JAVA_TIMEOUT_SECS` | seconds (default 60) | Wall-clock timeout for the kotlinc oracle | none |
| `KLIO_KOTLINC_JVM_HOME` | path | Existing JVM kotlinc distribution (or binary) for the parity oracle | none |
| `KLIO_KOTLINC_NATIVE` | path | Native kotlinc override | none |
| `KONAN_DATA_DIR` | path (default `~/.konan`) | Where the parity harness looks for Kotlin/Native distributions | none |
| `KLIO_NO_AUTO_INSTALL_KOTLINC` | `1` (`0` off) | Never auto-install kotlinc; parity tests skip when none is found | none |
| `KLIO_SKIP_KOTLINC_PARITY` | `1` (`0` off) | Skips the kotlinc leg of parity/differential checks entirely | none |
| `KLIO_FUZZ_SEED` | u64, decimal or `0x` hex | Base seed for the closures/suspend fuzzer (a failure prints the repro seed) | none |
| `KLIO_FUZZ_SEEDS` | u64 | How many seeds the fuzzer sweeps | none |
| `KLIO_SWEEP_DEBUG` | set | `scripts/commontest-sweep.py` prints each child's argv before spawning | `ARGV` |
| `KLIO_BIN` | path | The binary `scripts/klio-smoke.sh` sweeps with | none |
| `KLIO_SKIA_OS` / `KLIO_SKIA_ARCH` | `linux`/`macos`/`windows`, `x64`/`arm64` | Target selection for `scripts/fetch-skia.sh` | none |

### Harness / test-infrastructure variables

Plumbing read only by test code — not user debugging knobs.

| Variable | Values | What it does |
|----------|--------|--------------|
| `KLIO_ITEST_WALL_CAP` | seconds (default 60; `0` off) | Per-program wall cap for the in-process itest harnesses; a spinning program fails "test wall-clock deadline exceeded" and names itself instead of hanging the binary |
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

`[bare]` shows what lowering bound (or `NONE`); the `[extfb]` /
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

**Bisecting the compose plugin.** The plugin always runs; bisect its two
emissions:

```sh
./zig-out/bin/klio run scene.kt                                # plugin (always on)
KLIO_COMPOSE_SKIP=0 ./zig-out/bin/klio run scene.kt            # no skip calculus
```

Rebuild any baked pack between flips (the flag is part of the pack
cache key), and add `KLIO_COMPOSE_DBG=1` to confirm the pass
activated.

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
