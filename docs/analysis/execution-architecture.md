# KLIO Execution & Resolution Architecture

Status: analysis + design proposal. Read-only audit of the current Zig tree at
`main`. Every claim below is grounded in concrete `file:line` citations against
live source under `src/`. The stale `crates/...` paths visible in `git status`
are Rust artifacts left from the port and are NOT the live pipeline.

---

## 1. Executive summary

KLIO has **one** build pipeline and **many** runtime execution paths. The build
side is structurally unified (pack ASTs are concatenated into one synthetic file
and lowered as a single program), but every downstream resolution and dispatch
decision fans out into independently-grown branches that re-derive the same
answers through different mechanisms. Three recurring bug classes all reduce to
this fan-out:

1. **Variable access in anonymous lambdas resolves inconsistently.** The same
   `IrClosure` body is executed by three separate engines that disagree on the
   capture store, the runtime env, and write-back behavior. A lambda called
   directly (`host_call_value.callValue`) reads the value's positional capture
   snapshot over the real globals; the same lambda called from a stdlib HOF
   (`intrinsic_host.invokeCallable`) reads a side-table cell and runs the body
   over a *capture-name-seeded child env* layered on globals. Captured-`var`
   writes lower to `StoreGlobal`, which only round-trips on the HOF path's
   scoped env. Same body, different name scope by caller.

2. **Implicit-receiver / `this` resolution breaks across `suspend`.** The
   enclosing-`this` chain lives in a process-wide `threadlocal` stack
   (`outer_this`), pushed/popped around synchronous calls. It is **not** part of
   `FrameSnapshot`, so when a frame parks and resumes (possibly on another
   driver iteration), the receiver context is whatever the resuming thread's TLS
   happens to hold — not what the parked frame had.

3. **Code loaded from PACKS resolves differently than the same code loaded
   directly.** There is no separate "pack branch"; the divergence is that every
   resolution table (`funcId`, `classId`, the resolver scope, the inline-fn
   table, the VM global lookup) is keyed by **bare simple name** and tie-broken
   by **declaration order**. Packs are the only thing that both add same-simple-
   name competitors from other packages and get inserted at a fixed position in
   that order. A symbol can also have two executable forms (native binding vs
   lowered shim body), chosen per dispatch site.

The structural root cause is shared: **KLIO has no single threaded execution-
context value, no single dispatch entry point, and no package/FQN-keyed symbol
resolution.** Receiver context, inline tables, and coroutine state all live in
separate process-wide thread-locals mutated as side effects of dispatch; the
same source resolves differently based on (a) which TLS the resuming thread
holds and (b) how a symbol was registered (FQN vs simple name vs mangled).

The remediation is to collapse the branches into canonical paths: one closure-
invocation routine reading one capture store; one receiver context threaded on
the `Frame` (and therefore on `FrameSnapshot`); one name-resolution function
shared by qualified and unqualified dispatch; one package/FQN-keyed symbol index
that makes pack-vs-direct indistinguishable at runtime.

**Status of the evidence.** The default test target (`zig build test`) is GREEN
(135 steps, 1506 tests; 79/79 e2e corpus byte-identical to kotlinc). The three
bug classes below are argued **structurally** — they identify the mechanism by
which the same source can resolve or execute differently — and several have
landed *point fixes* that mask a specific instance while leaving the general
mechanism in place (Class C's nested-name-collision fix is the clearest example,
see §2 Class C). Where a class is currently masked on `main` rather than
reproducible, that is called out inline. The first deliverable in §6 is therefore
detection scaffolding (a differential harness, choke-point invariants, a fuzzer):
it converts each structural mechanism into a reproducible, failing test before
the invasive unifications land, instead of asserting the divergence on faith.

---

## 2. Taxonomy of the three bug classes

### Class A — Divergent closure execution (lambda variable access)

**Symptom.** A captured variable read or write inside an anonymous lambda
produces a different result depending on whether the lambda was invoked directly
or through a stdlib higher-order function.

**Root cause.** An `IrClosure` is executed by three functions, each
re-implementing capture loading, arg padding, and write-back:

- **Main IR path** — `host_call_value.callValue`, reached from the
  `CallValue`/`Call*`/`CallMember*` arms. It reads the *value-carried* snapshot
  slice `callee.IrClosure.captures` (`src/interp_ir/vm/host_call_value.zig:254-256`,
  passed positionally), runs the body over the raw `self.globals` with no
  child env, and never writes captures back. The receiver-lambda special case
  rebuilds a fresh closure value with an overridden `this` capture
  (`host_call_value.zig:299-360`).
- **HOF path** — `intrinsic_host.invokeCallable`, reached by every stdlib HOF
  (`map`/`filter`/`let`/`apply`/`with`/`run`). It reads the *side-table* cell
  `info.captures` (`src/interp_ir/vm/intrinsic_host.zig:465-470`, NOT the value
  slice), builds a fresh `scoped_env = Env.withParent(globals)` and `define`s
  every captured **name** into it (`intrinsic_host.zig:472-485`), swaps that
  child env in as the host's `globals` (`intrinsic_host.zig:504-518`), then reads
  each name back out and overwrites `info.captures` (`intrinsic_host.zig:523-536`).
- **Coroutine driver path** — `intrinsic_host.evalClosureRaw` (and the
  receiver-lambda variant `invokeCallableWithThis`,
  `src/interp_ir/vm/intrinsic_host.zig:585-674`) prefer the live captures but
  ALSO seed a name-keyed `scoped_env` over globals.

Because the HOF/coroutine paths layer captured names into a child env and the
main path does not, a `LoadGlobal name` instruction inside the same lambda finds
the capture in the scoped env on the HOF path but must fall back to a positional
`LoadCapture` / enclosing-`this` chain on the main path. Captured-`var` writes
compound this: `computeBoxedVars` is a syntactic over-approximation
(`src/ir/lower/ast_scan.zig:289-306`); anything it misses lowers to a
`StoreGlobal name` + local `rebind` (`src/ir/lower/expr.zig:665-669`,
`expr.zig:1424-1428`). At runtime `StoreGlobal` assigns through `self.globals`
(`src/interp_ir/vm/host_globals.zig:624-633`). On the main path `self.globals`
is the parentless top-level env, so the write clobbers or defines a global and
the capturing frame never sees it; only the HOF path's `scoped_env` catches it.

**Aggravating factor.** `info.captures` (the cell) and `Value.IrClosure.captures`
(the snapshot) are two stores for the same data; the HOF path reading the cell
silently ignores a closure value rebound with overridden captures (the
receiver-lambda binding the main path produces).

**Resolved (4a + 4b).** This divergence was the HOF path's `scoped_env`
write-back: historically the only mechanism that made a captured-`var` *write*
from a stdlib HOF lambda visible at the declaration site when `computeBoxedVars`
under-approximated (i.e. the var was not boxed into a `Cell`). 4a made the
carrier precise (boxing captured-and-written `var`s — including across the inline
splice — into a shared `Cell`); 4b then extended that boxing to function/lambda
*parameters* a nested closure writes (the captured-param gap surfaced by a
prove-dead pass: `toMap(destination){ consumeEach { destination += it } }`) and
deleted both the `scoped_env` layering and the `StoreGlobal`-for-capture lowering
(plus the now-dead `WritebackCaptures`/`readLambdaCapture` capture-sync). The HOF
invoke path now runs the closure body over the real top-level env, identical to
the main value path; a captured write is a `CellSet` on the shared cell and is
visible by reference on every closure-execution path. `globals` is path-
independent again. The `captured_var_carrier` e2e + `closures_advanced` /
`closures_deep` itests pass unmodified.

**Evidence summary** (the `runtime env` / `write-back` rows are the pre-4b state;
post-4b both paths run over the real top-level env with no write-back — captured
writes round-trip through the shared `Cell`).

| concern | main path | HOF/coroutine path |
| --- | --- | --- |
| capture source | value snapshot `host_call_value.zig:393-398` | side-table cell `intrinsic_host.zig:465-470` |
| runtime env | raw `self.globals` | raw `self.globals` (post-4b; was name-seeded `scoped_env`) |
| write-back | none | none (post-4b; was read-back into `info.captures`) |
| `this` override | fresh closure value `host_call_value.zig:306-360` | mutate cell + restore `intrinsic_host.zig:603-660` |

### Class B — Receiver context lost across `suspend`/`inline`

**Symptom.** A bare member reference or `this@Outer` that resolved correctly
before a suspension point resolves differently or fails after resume.

**Root cause.** The enclosing-`this` chain is a process-global
`threadlocal var outer_this: ?*std.ArrayList(Value)` lazily allocated on the page
allocator (`src/interp_ir/vm/host_call_member.zig:65-73`). It is pushed/popped
around `Call`/`CallMember` (`src/ir/eval.zig:1119-1135`, `eval.zig:1259-1271`),
around the main value path (`host_call_value.zig:349-358` via
`pushAccessEnclosing`), and around the intrinsic path (`intrinsic_host.zig:645-661`
via `pushOuterThis`) — two push helpers, one backing store. `enclosingThis` /
`enclosingThisChain` read it (`host_call_member.zig:875-916`), and
`CallMemberOrGlobal`, `LoadGlobal`, and `LoadFromThisOrGlobal` all consult it to
resolve a bare name against an implicit receiver
(`eval.zig:1466-1486`, `eval.zig:1500-1522`).

`FrameSnapshot` serializes only `func/module/block/inst_idx/regs/params/captures/
try_stack/is_lambda/resume_reg` (`src/ir/eval.zig:149-167`). The `outer_this`
stack is **not** in it. On suspend the Zig stack unwinds without running the
matching `popAccessEnclosing`/`popOuterThis`; on resume `resumeContinuation`
rebuilds the frame purely from the snapshot (`eval.zig:349`+) and a fresh
`VmHost` is constructed, so `enclosingThisChain()` returns whatever TLS currently
holds. Only `this` carried as a frame param (`frameThisParam`, `eval.zig:1847-1852`)
or as a `this`-named capture (`callerThisValue`, `eval.zig:1856-1870`) survives —
and `callerThisValue` additionally drops any receiver that is not `.Instance`
(`eval.zig:1858`), so primitive/`String` receivers in `with`/`apply` cannot
thread through this path at all.

**Companion thread-locals, same anti-pattern — now mostly resolved.**
`member_only_probe`, `cc_explicit_read`, and `inner_outer_hint` are converted
to explicit parameters (`member_only` on `callMemberInner`/
`callMemberNamedInner`, `suppress_cc_redirect` on `getFieldInner`,
`outer_hint` on the `newInstanceNamed` → `materializeInstance` construction
path), and the dead duplicate `ctor_guard` in `host_globals.zig` is collapsed
onto `host_instances.ctorGuardContains`. What remains in TLS is genuine
re-entrancy / driver state: `map_fallback_active`, `iterable_fallback_active`,
`call_outer_active` (`host_call_member.zig`, now `defer`-cleared and asserted
clear at run boundaries via `host_call_member.resetReceiverTls`);
`field_resolve_stack`, `field_outer_active` (`src/interp_ir/vm/host_fields.zig`);
the one `ctor_guard` (`host_instances.zig`); `coro_stack`,
`active_scope_stack`, `persisted_parked` (`src/interp_ir/vm/coroutines.zig`);
`coroutine_time_mode_tls` (`src/interp_ir/interp_ir.zig`). Every TLS-holding
VM module is wired into the run-boundary assert
(`vmhost.resetReceiverThreadLocals`).

**Inline variant.** An `inline fun` with a receiver binds the receiver as a
lowering-time scope local named `"this"` in the caller's builder
(`src/ir/lower/inline_call.zig:459-463`), so after inlining the caller frame's
`this` is a register, not a param named `"this"` — the runtime `frameThisParam`
scan does not see it, and nested-receiver references fall back to the same
suspend-fragile `outer_this` stack. The inline tables themselves are
build-scoped thread-locals (`src/ir/lower/inline_state.zig:31-49`).

**Resolved (item 6).** The enclosing-`this` chain is no longer a process-global
thread-local: it is the current `Frame`'s `enclosing_this` field, snapshotted
into `FrameSnapshot` on suspend and restored verbatim on resume, so the **narrow
window** that masked this — a `this@Outer` needed *only* via the chain (not a
param/capture) across a real `delay`/park — is closed structurally. The
regression is pinned by `examples/receiver_across_suspend.kt` (e2e corpus) and
the `enclosing_this_chain_survives_suspend` itest: a `suspend` member-extension
parks at `delay`, then resolves a bare member of its enclosing `this@Owner`
*after* resume; before the fix this reported `unresolved global 'owned'`. The
inline-receiver variant below (a lowering-time scope local named `"this"`) is a
separate facet handled by item 10.

### Class C — Pack-vs-direct resolution divergence

**Symptom.** Byte-identical source resolves a name (e.g. a `routing` extension)
correctly when loaded one way and reports "unresolved global" when loaded
another; load *order* of pack source files is resolution-significant.

**Root cause.** There is no pack pipeline. `runModuleFiles`/`runFileIrVm` build
`all_asts = loaded.asts ++ user_asts` (pack-first) and hand the concatenation to
`buildModuleFiles`, which flattens every file's decls into ONE synthetic
`KotlinFile` with `.package = null` (`src/cli/commands.zig:210-218`,
`commands.zig:245-253`, `src/interp_ir/build.zig:253-283`). All divergence comes
from declaration **order** and **FQN-mangling**, because every downstream table
is keyed by bare simple name and tie-broken by order:

- **`Module.funcId`** returns `first_user orelse first_body orelse first`,
  ranked over the per-decl `Func.package` (`isShippedFqn` is deleted). It is
  no longer a resolution input: the symbol index
  (`resolveBareCallIndexed`/`resolveBareRefIndexed`) is the primary path and
  `funcId` only breaks the shapes the index defers on (extensions, overload
  sets), order-stably.
- **`Module.classId`** (first `class_index` entry by simple name) remains only
  as the legacy fallback: bare construction/reference sites resolve through
  `classIdIndexed` (caller package + imports) and carry the resolved
  `ClassId` to the runtime, whose class registry is FQN-keyed (the
  simple-name view is a first-wins, user-over-shipped alias for callers with
  no resolved identity). The resolver declares per-package scopes —
  redeclaration is detected per package and the module scope is a
  diagnostics-free first-wins mirror for cross-package reads
  (`resolver.zig` `resolveModule`/`mirrorModuleBinding`).
- **Inline-fn table** is a process-global `StringHashMap` keyed by bare simple
  name, merged across packs + user (`src/ir/lower/inline_state.zig:31`,
  `inline_state.zig:72-93`, `inline_state.zig:284-302`); a pack `inline fun foo`
  and a user `inline fun foo` share one bucket, tie-broken by shape/order.
- **VM global lookup. RESOLVED (item 8 steps 2+3).** The `kotlin.*`
  prefix-probe ladder and the `installed_bindings` suffix scan are deleted;
  a bare name resolves through link-settled name→FQN maps
  (`default_import_globals`, first-package-wins; `pack_bare_aliases`,
  receiver-qualified keys excluded, lexicographic tie-break) and an
  index-resolved reference bypasses names entirely (`lookupGlobalById` on
  the emitted `FuncId`/`ClassId`).
- **Two executable forms. RESOLVED (item 9).** `callFunc`/`callValue` used to
  short-circuit any FQN matching an `installed_bindings` entry to
  `dispatchIntrinsic` (a native binding) instead of the lowered body, deciding the
  form per call from pack-install state. That per-call probe is deleted: each
  symbol's single form is now resolved once at link time
  (`ProgramImage.linkResolvedForms` → the `resolved_native` table keyed by
  `FuncId`), and both dispatch paths consult that resolved form by `FuncId`
  (`host_call_func.resolvedNativeForm`). The form is fixed at link time
  independent of load order, so it no longer depends on how a symbol was loaded.

**Aggravating factors.** Lowering used to fork FQN resolution on
`isLambdaBody()` (the four `expr.zig` dotted-head sites), so the same dotted path
lowered to a `LoadGlobal`-of-FQN at top level but a member/`this` walk inside a
lambda — and pack code is heavily consumed through builder lambdas. **Resolved
(item 10):** the lambda axis is gone; package-head vs receiver-member is now the
one predicate `headIsPackage` (real package root or a declared FQN-prefix package
via `Module.packageHeadDeclared`), so a dotted head resolves identically whether
or not it is lexically inside a lambda. Span-keyed FQN overrides still fire only
for files WITH a package header (`build.zig:264-283`), so packaged pack decls and
package-less user scripts take structurally different mangling/retain branches in
the same build.

**One instance of this class is fixed and regression-protected — not live.**
`plans/KTOR-UPSTREAM.md:232-246` documents what it calls "the load-order bug":
consuming `ContentTypes.kt` (which contains a nested `object Application`) broke
the server's `Application.routing` extension. Its root cause is NOT `rel_path`
sort order — `pack_cache.zig:560-626` iterates `bundle.files` in bundle order and
appends via `out_asts.append` (`:624`) with no sorting anywhere in that file. The
actual root cause is **last-writer-wins on a bare simple name**: a nested
`object` lifted to its bare top-level name overwrote a same-named true top-level
type in the global table. That fix has **landed in Zig**:
`src/interp_ir/build/lift.zig:240-241` (object) and `:314-320` (nested class)
mangle a colliding nested type to `Outer$Name` (keyed on `top_level_type_names`
membership), and `tests/fixtures/parity_corpus/nested_name_collision.kt` asserts
top-level `Application.who() == "top-level"` while `Holder.Application.who() ==
"nested"`. So this specific symptom is a resolved, test-protected case — not live
evidence. (Caveat: `parity_corpus` is checked by the kotlinc-oracle parity sweep
via `parity.zig:654 corpusDir` / `parity/main.zig:122`, NOT by any in-process
itest, so this regression test does **not** run under the default `zig build
test` target — see §5.1.)

What remains genuinely live is the **general mechanism**: every resolution table
is still keyed by bare simple name and tie-broken by declaration order
(`funcId` `ir.zig:787-801`, `classId` `ir.zig:748-753`, the suffix scan
`host_globals.zig:480-485`). The nested-collision fix mangles *one* family of
collisions; it does not make resolution a function of `(package, imports, FQN)`,
so a same-simple-name competitor introduced from another package by a pack
remains order-sensitive. The differential harness (§5.1) is what would surface
any still-live instance of this class as a test failure rather than a field bug.

---

## 3. Current execution / resolution branch map

### 3.1 Build & load (one structural path, three call-time configs)

```
source .kt / compiled .pack
        |
   loadInstalledPacks (CLI)  /  registerAstPackage + embedded stdlib (parity)
        |
   all_asts = pack_asts ++ user_asts        (commands.zig:210-218 / 245-253)
        |
   buildModuleFiles  -> one synthetic KotlinFile (.package = null)   (build.zig:253-283)
        |  flatten decls; span-keyed FQN overrides only for packaged files (build.zig:264-283)
        |
   Module { funcs, classes, func_index, class_index, const pool, installed_bindings }
        |
   Vm.fromBuilt -> vm.run
```

Three load configurations feed the **same** VM but never cross-check each other:

| runner | packs | host bindings | used by |
| --- | --- | --- | --- |
| `runWithKtc` (`parity.zig:1118`) | embedded stdlib only | none | `check()` kotlinc oracle |
| `runWithPacks` (`parity.zig:1505`) | kotlinx source dirs | coroutines + atomicfu | all itests, e2e |
| `runFileIrVm` (`commands.zig:222`) | compiled `.pack` binaries | larger merged set | the real binary |

Nothing runs one program through two of these and diffs the output.

### 3.2 Instruction decode — nine call shapes

`eval.zig` decodes nine call-shaped instructions (`src/ir/eval.zig:818-828`):
`Call` (FuncId), `CallValue`, `CallValueWithThis`, `CallSpread`, `CallSuper`,
`CallMember`, `CallMemberOrGlobal`, `CallMemberOrValue`, `CallValueOrMember`.
Three of them encode *unresolved* dispatch the lowerer could not classify
(`eval.zig:1250`, `1277`, `1298`) and re-derive resolution at runtime by probing
in different orders. `execCallMemberOrGlobal` (`eval.zig:1616-1832`) is a ~220-
line multi-tier fallback (member-only probe, this-param probe, enclosing-this
probe, inner-outer chain, has-member probe, lexical-extension probe, named-
overload, global value, frame-this last resort), each tier calling a different
Host method. The probe order is itself the language's name-resolution policy,
duplicated against — and divergent from — the order `callMember` uses for
qualified `recv.name()`.

### 3.3 Host vtables — two abstractions, one real boundary

Two host vtables back two structs cloning the same 11 shared handles:

- `ir.eval.Host` (`src/ir/eval.zig:2500`+) — evaluator-facing, ~40 slots:
  `callValue`, `callMember`, `callFunc`, `lookupGlobal`, `storeGlobal`,
  `isShadowingCapture`, `enclosingThis`, etc.
- `runtime.IntrinsicHost` (`src/interp_ir/vm/intrinsic_host.zig:683-696`) —
  stdlib-facing, ~25 slots: `invokeCallable`, `invokeCallableWithThis`,
  `invokeMethod`, coroutine seams.

The boundary is not real: `invokeMethod` builds a `VmHost` and forwards to
`Host.callMember`, i.e. the IntrinsicHost path tunnels back into the eval.Host
path. The closure-execution divergence of Class A lives exactly at this seam,
because `invokeCallable` does NOT reuse `callValue`.

A **dead duplicate** `Host`/`VTable`/`NullHost` lives in `src/ir/eval/host.zig`
(712 lines) with no importer in the tree (verified: no `@import` of `eval/host`
anywhere). Its `defaultCallFunc` (`host.zig:550`) calls `eval(module, f, args)`
with a 3-arg signature that no longer matches the live
`eval(allocator, module, func, args)` (`eval.zig:285`). The drift is real but
never type-checked: the file is never `@import`ed and `defaultCallFunc` is never
instantiated (it is additionally guarded by an `@hasDecl` + lazy `@import`
inside the fn body, `host.zig:545-547`). It compiles fine *because* it is dead —
but it is a second, drifted source of truth for the dispatch contract and should
be deleted (§4.5).

### 3.4 Member dispatch — one long linear cascade + subsets

`callMember` (`src/interp_ir/vm/host_call_member.zig:1301-1832`, ~530 source
lines before the first sibling helper at `:4021`) linearly checks dozens of
(receiver-variant, method-name) special cases — Delegate protocol,
Thread handles, Intrinsic/Class static probes, List/Iterator/Sequence/Range
protocols, data-class auto members, anon-object dispatch (`anonMethodDispatch`),
IR class+supertype walk (`irMethodWalk`, `host_call_member.zig:3339-3448`), Any
fallback, stdlib member dispatch, delegate forwarding, companion forwarding,
function-typed property invocation, extension-fn fallback — in fixed order, each
`if (try X) |r| return r`. `callMemberNamed` (`:4021`), `callMemberOnly`
(`:4053`), and `userMethodNamed` (`:4177`) re-enter subsets with different
ordering/visibility flags. The member-only restriction is an explicit
`member_only` parameter on `callMemberInner`/`callMemberNamedInner` (the old
`member_only_probe` thread-local channel is gone). `irMethodWalk` resolves the
receiver class by two different keys — FQN
(`host_call_member.zig:3369`) then a simple-name scan (`:3373-3380`) — which is
what makes pack-mangled classes layout-sensitive. `extensionFnFallback`
(`:3692-3711`) admits any func whose first param is named `"this"` and whose
`member_ext_owner_class` gate is absent, conflating synthesized method receivers
with synthesized extension receivers — the ktor double-`execute` root cause noted
in `plans/KTOR-UPSTREAM.md`.

### 3.5 Receiver / `this` sources (three competing origins)

At any dispatch, the receiver is sourced from up to three unsynchronized places:

1. a param literally named `"this"` (`frameThisParam`, `eval.zig:1847-1852`),
2. a capture named `"this"` (`callerThisValue` scans `capture_order`,
   `eval.zig:1862-1868`, `.Instance`-only),
3. the thread-local `outer_this` stack (`enclosingThisChain`,
   `host_call_member.zig:875-891`),

The fourth origin — the `inner_outer_hint` thread-local for inner-class outer
receivers — is gone: the outer is an explicit `outer_hint` parameter on the
construction path, and `selectInnerOuter` picks it by the inner class's
lexically enclosing class (`registry.enclosing_class`) over the hint's
class-nesting tower (its `outer` links) and the subject-tagged frame chain.
There is still no assertion that the remaining origins agree.

### 3.6 Closure execution call-site count

22+ distinct `evalWith*`/`evalWithCaptures`/`evalWithCapturesIn`/
`resumeContinuation` call sites reach `ir.eval.eval*` across the VM
(`host_call_func.zig:592`, `host_call_value.zig:400,684`,
`host_instances.zig:2475`, `host_call_member.zig:3301,3324`,
`intrinsic_host.zig:308,521`, plus the resume path). Capture metadata is also
computed twice: lowering records `capture_order` (`src/ir/build.zig:435-458`),
and runtime `buildClosure` re-reads it (`host_call_value.zig:484-527`), so a
mismatch silently mis-binds captures by position. `Value.Lambda` (formerly
`src/runtime/value.zig:287-303`) was a dead Env-based closure representation
parallel to `Value.IrClosure`: the live interp_ir pipeline never produced it (the
`AstLambda` instruction's runtime handler `buildAstLambdaWithFlagFuncid` already
built an `IrClosure`), and the only constructor was a single GC unit test
(`src/runtime/runtime.zig`). **Deleted (§6 item 11):** the variant, the test
constructor, and every Value-context `.Lambda =>` arm. The capture authority is
now `func.capture_order` flowing through `ClosureInfo.captures`; there is no
parallel per-value Env snapshot. (`tests.zig:313` builds `Expr.Lambda`, the AST
syntax node, which is unrelated and stays.)

---

## 4. Proposed unified execution + resolution architecture

The goal is to collapse each fan-out into a single canonical path so that the
same source produces the same resolution regardless of caller, suspend state, or
load configuration. Five canonical components, each mapping directly to a bug
class.

### 4.1 One closure value, one capture store, one invocation routine (→ Class A)

- **One representation.** `Value.IrClosure` holds the stable `id` plus its
  capture snapshot. The single source-of-truth capture vector lives in
  `ClosureInfo.captures` (the shared cell). `Value.Lambda` (the parallel
  Env-based closure) is deleted (§6 item 11): it was unreachable on the live
  interp_ir pipeline, so `IrClosure` is the sole closure value form. The
  per-value snapshot slice on `IrClosure` is the remaining duplication to fold.
- **One routine.** A single `invokeClosure(id, args, this_override)` reads/writes
  the cell and uses one env strategy. `host_call_value.callValue` and
  `intrinsic_host.invokeCallable`/`invokeCallableWithThis`/`evalClosureRaw` all
  delegate to it (build a transient `VmHost` if needed). `VmIntrinsicHost`
  becomes a thin adapter that forwards ALL callable/method invocation to the
  eval.Host implementations — as `invokeMethod` already does for members —
  keeping only genuinely intrinsic-only slots (coroutine seams, thread spawn).
- **Stop swapping `self.globals`** — DONE (4a then 4b). The precise carrier was
  proven first (4a: box captured-and-written `var`s, including across the inline
  splice, into a shared `Cell`; 4b extended it to function/lambda parameters a
  nested closure writes), then the fallbacks were deleted (4b): the
  `StoreGlobal`-for-capture lowering, the `scoped_env` layering on both HOF invoke
  sites, and the now-dead `WritebackCaptures`/`readLambdaCapture` capture-sync.
  `globals` now always points at the real top-level env on every path;
  `isShadowingCapture`/`storeGlobal`/`lookupGlobal` are path-independent, and
  reads and writes of a captured name share one path on both invocation routes.
- **One capture-metadata authority.** Treat `func.capture_order` as canonical:
  the construction site emits capture values strictly in capture-order index
  order (assert it); `invokeClosure` stores exactly one capture vector keyed by
  that order. Drop the cell/snapshot duplication.

### 4.2 One receiver context, threaded on the Frame (→ Class B)

- **Receiver chain: DONE (item 6).** The enclosing-`this@` chain is now an
  `enclosing_this` field of `Frame` (seeded at frame entry from the caller's
  active chain so the frame inherits the enclosing implicit receivers a
  `with`/member-extension/receiver-lambda dispatch pushed) and of
  `FrameSnapshot`. It is duped on suspend and restored verbatim in
  `resumeContinuation`, so the chain travels with the parked continuation by
  construction; the suspend-`this` bug disappears. The `outer_this` thread-local
  and `outerThisStack` are deleted, and `enclosingThis`/`enclosingThisChain`/
  `pushAccessEnclosing`/`popAccessEnclosing` read/write the current frame's chain
  via a thread-local `active_chain` pointer that only ever points at a live
  frame's field.
- **Inner-class outer receiver: DONE (item-6 close-out).** The
  `inner_outer_hint` thread-local and its push/pop helpers are deleted. The
  outer is an explicit `outer_hint: ?*const Value` parameter on
  `newInstanceNamed`, threaded through `newInstance` →
  `dispatchSecondaryCtor`/`superDelegation` (nested shell constructions see
  the same hint) → `primaryCtorPath` → `materializeInstance`, where
  `selectInnerOuter` picks the outer by the inner class's lexically
  enclosing class (`registry.enclosing_class` /
  `ClassDef.enclosing_class`), walking the receivers in scope at the
  construction site innermost-first the way kotlinc resolves the inner
  constructor's dispatch receiver: the hint itself; the hint's
  class-nesting tower (`outer` links — a member of `Inner` constructing a
  sibling `Inner()` reaches `this@Outer` through its own outer link, never
  through a receiver inherited from a caller frame), skipped when the hint
  is the innermost receiver-lambda subject (a displaced `with(x)` slot —
  the subject brings only itself into scope); then the enclosing-receiver
  chain, each entry direct plus — for non-subject entries — its own tower.
  Chain entries carry the subject/receiver distinction from the push site
  (`ir.eval.EnclosingEntry.is_subject`; the three receiver-lambda dispatch
  sites push the subject tagged, the displaced prior `this` plain). On the
  build side, a lambda body lowering a bare `Inner()` to `NewInstance` now
  records a `this` capture (kotlinc's `this$0`: the inner construction is
  a *use* of the enclosing instance), `ir.Class` carries `is_inner` to key
  that decision — stamped on the `reserveClass` stub too, so a
  forward-referenced sibling inner class lowers identically in either
  declaration order — and the `NewInstance` arm sources the hint via
  `callerThisValue` (param or capture). Together these fixed
  `with(other) { Inner().show() }` inside an Outer member — including the
  shadowing case where the unrelated subject declares a same-named
  property (the stamped `outer` resolves through `instanceField`'s early
  outer-instance walk, ahead of the dynamic chain-top rescue) — plus inner
  instances escaping HOF lambdas, user-HOF lambdas, two-level `inner`
  nesting, sibling construction under a polluted caller chain, and
  later-declared siblings built from lambdas. Pinned by the
  `inner_class_constructed_inside_with_lambda` /
  `inner_class_in_with_lambda_ignores_shadowing_subject` /
  `inner_class_constructed_inside_user_hof_lambda` /
  `inner_class_two_level_nesting` /
  `inner_class_escapes_lambda_with_outer` /
  `sibling_inner_construction_ignores_caller_receivers` /
  `later_declared_sibling_inner_class_from_lambda` /
  `with_subject_of_enclosing_class_supplies_outer` /
  `with_subject_outer_links_not_in_scope` /
  `with_unrelated_subject_in_inner_member_reaches_outer` itests
  (sibling/`with`-subject expectations confirmed against kotlinc-native
  2.3.10), the suspend pins in `parity_suspend_shapes` (including
  `sibling_inner_constructed_after_park`), and
  `examples/inner_class_suspend.kt`.
- **Guards → params: DONE (item-6 close-out) for the deletable set.**
  `member_only_probe` is the `member_only` parameter of
  `callMemberInner`/`callMemberNamedInner` (public surface forwards
  `false`, `callMemberOnly` passes `true`); `cc_explicit_read` is the
  `suppress_cc_redirect` parameter of `getFieldInner`. The duplicate
  `ctor_guard` is collapsed: the `host_globals.zig` copy had no writer (its
  deferred-`object` gate read was always false), and `lookupGlobal` now
  consults the one real guard via `host_instances.ctorGuardContains`. The
  load-bearing re-entrancy flags stay as TLS
  (`map/iterable_fallback_active`, `call_outer_active`,
  `field_outer_active`, `field_resolve_stack`) but are `defer`-cleared and
  covered by run-boundary asserts (`host_call_member.resetReceiverTls` is
  wired into `vmhost.resetReceiverThreadLocals`); their full TLS→param
  conversion rides the §4.3 single-resolver work.
- **Remaining §4.2 line item — fold the frame's own `this` into the
  carrier.** The frame's own receiver is still a param/capture recovered by
  name (`frameThisParam`, `callerThisValue` with its `.Instance`-only gate,
  `implicitThisValue`), not `enclosing_this[0]`. Folding it changes the
  depth assumptions of every chain consumer:
  `implicitReceiverChain` (eval's choke point would double-count), the
  getField enclosing-receiver rescue (chain-top-only read in
  `host_fields.zig`), `enclosingOwnerSet`/`enclosingChainClassOrder`
  (member-ext visibility), `checkReceiverChain` (the KLIO_TRACE_INVARIANTS
  interior-hole rule), and the B13 `.Instance`-only gate. Set the frame
  receiver slot at call entry on every dispatch path; drop the
  `== .Instance` restriction so primitive/`String` receivers thread
  identically; the inline splice sets the slot for the spliced region
  instead of binding a scope local named `"this"`. Known residual until
  then: the dynamic chain-top rescue in `getField` can still resolve a
  bare name inside an inner-class member body against an unrelated
  enclosing receiver when neither the instance, its captured outer
  chain, nor any earlier ladder step owns the name — a leniency over
  kotlinc (which rejects such programs at compile time), not a wrong
  value for valid programs.

### 4.3 One name-resolution function (→ Class A/B dispatch order)

Define ONE resolver `resolve(frame_receiver_ctx, name, args) -> ResolvedTarget`
used by both `execCallMemberOrGlobal` and `callMember`'s implicit-receiver
handling, so bare `name()` and `this.name()` traverse identical precedence.
Reduce the three "Or" instructions to a single `CallUnresolved` whose runtime
arm calls this resolver; keep `Call`/`CallValue`/`CallMember`/`CallSuper` as the
only statically-classified shapes. Split pure builtin-protocol dispatch
(List/Map/Sequence/Range/Iterator, keyed on receiver type) from user-class
resolution (instance/supertype/anon/extension walk), and drive user resolution
through this one resolver. Mark every func with an explicit kind in the registry at build time
(`instance-method` / `member-extension` / `top-level-extension`) so the
extension scorer selects candidates by kind, not by `param[0] == "this"`.

**Landed (item 7, member-extension kind).** `Func.kind: FuncKind` now carries
`member_extension` as a first-class category (`src/ir/ir.zig`), set at the
member-extension lowering site (`src/ir/lower/decl.zig`) alongside the existing
`member_ext_owner_class` side-table entry — the two are co-populated for the same
`FuncId`, so `kind == .member_extension` and `member_ext_owner_class.contains(fid)`
are equivalent predicates over the same set. The five member-extension dispatch
sites in `host_call_member.zig` route through `isMemberExt(mod, fid)` (kind is
authoritative) and `memberExtVisible(mod, fid, &visible_owners)` (the owner-class
gate). The side table is kept as the owner-class data source (per the caution
below — the kind is additive, the gate is preserved exactly). The single
implicit-receiver resolution choke point (`implicitThisValue` +
`implicitReceiverChain` in `ir/eval.zig`) feeds the three `*OrGlobal` handlers;
the four "Or" *instructions* are kept (collapse deferred to item 8 — see §6 row 7).

**Caution — the taxonomy must distinguish member-extension from plain
instance-method, not collapse "is in `class.methods`" ⇒ "not an extension".**
The current `extensionFnFallback` (`host_call_member.zig:3692-3711`) deliberately
also serves *synthesized member-receiver* methods: it admits funcs whose first
param is named `"this"` (`:3705`) and gates them by `member_ext_owner_class`
(`:3706-3708`), and that gate is what makes member-extension visibility (e.g.
`with(a) { memberExtFn() }`) work. KLIO lowers member extensions — and some
member methods — to funcs with a leading `"this"` param (`inline_call.zig:462`
binds `"this"` as a local). A registry kind that excludes *every* func appearing
in `class.methods` from the extension set would drop the member-extension
dispatch the ktor paths rely on. The kind field must therefore carry
`member-extension` as a first-class category distinct from both
`instance-method` and `top-level-extension`; the scorer admits
`member-extension` candidates exactly when their `member_ext_owner_class` is in
the visible-owner set, preserving the current `:3706-3708` gate behavior.

### 4.4 One package/FQN-keyed symbol index (→ Class C)

Make resolution a pure function of (caller package, caller imports, complete FQN
header set) — provably independent of pack load order:

1. **Tag every decl with its declaring package** at flatten time (empty string
   for user scripts) — one uniform field, not a presence-gated span map. The
   "no package" case becomes `package = ""`, not a separate code path. **DONE
   (item 8).** `Func.package` / `Class.package` (`ir.zig`) is a uniform field
   set at the func-stub / class-shell lowering site from `packageOfFqn`
   (`ir.zig`); the build-driver seeds the caller package onto `FuncBuilder`
   (`self_package`) per top-level decl and per class.
2. **Two-phase consumption.** Phase 1 registers every source's type/function/
   extension HEADERS (FQN + receiver type) across all packs, features, and user
   files. Phase 2 resolves bodies and extension-receiver bindings against that
   complete, package-qualified header set. **DONE (item 8, made explicit).**
   `buildModuleWithOverrides` (`interp_ir/build.zig`) reserves every class name
   and emits every func stub (FQN + package + receiver `this`) — the complete
   phase-1 header set — before any body lowers in phase 2.
3. **Build one symbol index** mapping (caller-package + caller-imports) → FQN →
   `FuncId`/`ClassId`. Bare calls follow Kotlin's scoping order: named imports,
   then the caller's own package, then star imports, then the default imports,
   then built-in stdlib. **DONE (item 8, PRIMARY path; hardened, fallback
   retained for classified shapes).**
   `Module.resolveBareCallIndexed(name, caller_pkg, caller_file, arity, …)`
   (`ir.zig`) ranks each non-extension candidate by tier (0 file-named import
   — kotlinc-probed: an explicit import outranks even a same-file declaration
   — 1 own package, 2 file-wildcard import, 3 default-import package — the
   spec's implicitly imported set, mirrored from
   `stdlib.IMPLICITLY_IMPORTED_PACKAGES` with a lockstep test — 4 built-in
   stdlib, 5 other), commits the unique exact-arity no-default no-vararg
   candidate in the best non-empty tier, and otherwise returns a reason-tagged
   deferral (`ResolveDeferReason`: no_candidates / extension_form /
   intrinsic_owned / ambiguous_tier / type_overload / unimported_set /
   arity_mismatch / default_param_shape / bodyless_only / low_priority_only /
   vararg_only / trailing_lambda_shape / cast_disambiguated). Forward
   references rank order-independently: phase-1 header stubs carry their
   declared arity (`decl_user_arity`), declared parameter types at FULL
   structural granularity (`decl_user_sig`, rendered by the same
   `loweredTypeRef` body params use — generic arguments, function-type
   receiver/parameter/return shapes, suspend and `T & Any` markers), and
   AST-derived `low_priority`, so the index's answer does not depend on
   whether a candidate's body has been lowered yet; default-parameter shapes
   defer identically from the stub AND the body gate for the same reason. A
   file's same-leaf named imports are ALL kept (`registry.import_aliases`
   maps leaf → import-path list): a second `import pkg2.f` after
   `import pkg1.f` is a tie the index classifies, not a shadow. Lowering
   (`lower/expr.zig lowerPathCall`) prefers the index target when it
   resolves — except a receiver-matched extension pick, which stays with the
   heuristic (the index never models receivers) — and otherwise keeps the
   order-based heuristic pick for the classified deferral shapes.
   **Ambiguity is a lowering diagnostic (default-on), scoped precisely:** it
   fires only for a CALLED, non-extension bare call whose in-scope (tier ≤ 3)
   same-arity candidates carry no defaults or varargs and prove identical at
   full signature granularity — the sets kotlinc itself rejects. Two
   identical FQNs render as
   "`file.kt:4: error: conflicting overloads of `f`: identical signatures
   declared at file.kt:2 and file.kt:3 — rename or remove one of the
   declarations`" (qualifying cannot separate one FQN); distinct FQNs render
   as "`file.kt:4: error: ambiguous reference `f`: candidates `a.f`, `b.f` —
   qualify the call or import one explicitly`". Surfaced by the run pipeline
   (`commands.zig runBuilt`, `parity.zig runInMode`) with `file:line` from the
   `SourceMap`. NOT diagnosed (deferred to the heuristic, kotlinc-stricter
   shapes): identical pairs exercised through default parameters or varargs,
   extension-form candidates, and pairs that are never called.
   Type-distinguishable overload sets (`type_overload` — anything not
   provably identical at full granularity) stay runtime-resolved, cast-picked
   sets reclassify as `cast_disambiguated`, and identical sets visible only
   outside Kotlin scoping (`unimported_set`) keep klio's lenient pick. The
   `KLIO_RESOLVE_AUDIT` detector emits one machine-readable line per bare call
   (outcome + reason + tier + counts + heuristic pick + emitted shape +
   divergence grade) and flags divergences; every index/heuristic divergence
   is graded (`tier_correction` — index pick in a strictly better tier;
   `shape_correction` — same tier, heuristic fell back to a
   vararg/default/arity-mismatched candidate where the index found an exact
   overload; `receiver_pref` — heuristic's extension pick retained) and
   `KLIO_RESOLVE_STRICT` turns an unexplained divergence into a hard failure.
   Strict+audit sweep over all 85 examples + the coroutine fixtures: 0
   failures, 0 unexplained divergences; the graded divergences are 300
   `checkIndexOverflow` tier corrections (own-package target over the
   heuristic's cross-package pick) and 12 `CompletableDeferred` shape
   corrections (exact-arity overload over the default-param sibling, with
   runtime type dispatch unchanged since non-exact calls re-resolve through
   `pickOverload`). Items 8b/8c are landed: `isShippedFqn` is deleted
   (`funcId` ranks by `Func.package`), the resolver declares per-package
   scopes (redeclaration is per package; the module scope is a
   diagnostics-free first-wins mirror), and the runtime class registry is
   FQN-keyed — the simple-name views that remain are order-stable
   fallbacks behind identity-carrying emission, not resolution inputs.
4. **Lowering emits identity-carrying `Call`/`LoadGlobal`. LANDED** (except
   the inline-fn fold, deferred as 8d). A unique index pick emits
   `LoadGlobal` carrying the exact `FuncId`/`ClassId` (`lookupGlobalById`
   binds it directly — no name round-trip, so extension twins sharing a
   receiverless FQN string and dotless root-package FQNs bind exactly);
   the three runtime ladders are DELETED — the `lookupGlobal` prefix probe
   and suffix scan replaced by the link-time
   `default_import_globals`/`pack_bare_aliases` maps, the `callFunc`
   bodyless ladder by link-settled `resolved_redirect`/`resolved_native`
   (`KLIO_LINK_AUDIT` re-derives the deleted algorithms independently).
   Fold inline-fn resolution into the same entry point so there is one
   selection algorithm, not a parallel simple-name inline table (8d).
   The pre-deletion inventory was `KLIO_TRACE_RESOLVE`-gated
   `ladder=<which> name=<simple> fqn=<resolved>` lines, so a corpus sweep
   enumerates exactly which (program, name, fqn) still reach them. Current
   sweep over all 85 examples: 18 distinct prefix-ladder names (constants and
   `*ArrayOf` builders dominate), exactly one suffix-scan name
   (`runBlocking` via the pack overlay), zero bodyless-ladder hits — the
   removal worklist for this item.
5. **One executable form per symbol. DONE (item 9).** Pack-vs-source identity is
   resolved once at link time: `ProgramImage.linkResolvedForms` (`interp_ir.zig`)
   runs after the two-phase build and the `installed_bindings` overlay exist, and
   for every top-level `FuncId` whose FQN maps to a native binding records that
   binding in `resolved_native` (keyed by `FuncId.int()`); funcs with no binding
   run their lowered body and are absent. The decision is a pure function of
   `(FuncId → fqn, installed_bindings)`, settled deterministically independent of
   load order. The per-call FQN short-circuit in `callFunc` and `callValue` (the
   "Pack-installed binding fast path" / closure-body overlay probe) is deleted;
   both now consult `host_call_func.resolvedNativeForm` by `FuncId`. The
   `KLIO_LINK_AUDIT` detector compares the link form to the deleted per-call
   probe's pick on every dispatch and reports 0 divergences over the green corpus
   — the executable proof the link form is a faithful, behavior-preserving
   replacement.
6. **Remove `isLambdaBody()` as a resolution axis. DONE (item 10).** The four
   `(isPkgRoot(head) or !b.isLambdaBody())` gates in `expr.zig` are replaced by
   one principled predicate, `headIsPackage(b, head)`: a dotted head is a
   package-qualified global (flatten to `LoadGlobal`-of-FQN) when it is a real
   package root (`isPkgRoot`) or names a package the program contributes a
   top-level symbol to (`Module.packageHeadDeclared` — `head.<rest>` is a
   declared FQN prefix over the complete phase-1 header set); otherwise it is a
   member of an implicit receiver and walks `this`. A captured/local name or an
   enclosing-class member shadows a package head (the sites already filter those
   with `resolve`/`knowsOuter`/`hasEnclosingMember`/`classId` guards). The answer
   is independent of lambda nesting AND of declaration order / load mode, so the
   same dotted head inside a builder/DSL lambda lowers identically to the same
   head at top level — which also fixes the latent Class-C bug where
   `isLambdaBody` *blocked* a legitimately package-qualified head from flattening
   inside a builder lambda. The inline splice binds the inline body's receiver as
   a scope local named `"this"` already, so inline-body dotted heads resolve
   through the same predicate without a lambda axis (no extra frame-receiver slot
   was required at the splice). Gated behind the builder-DSL differential pass:
   `examples/dsl_dotted_head.kt` + `coroutine_smoke/cs8_dotted_in_builder.kt`
   byte-identical across EmbeddedOnly / SourcePacks / CompiledPacks, the
   extension/dsl/suspend/inner-class/functional/lambda itests unmodified, and
   `KLIO_RESOLVE_AUDIT`/`KLIO_LINK_AUDIT` = 0 over the corpus.

### 4.5 Cleanup (supporting)

- Delete `src/ir/eval/host.zig` (the dead duplicate Host) and the now-empty
  `src/ir/eval/` directory.
- Extract one `dispatchIntrinsic` + one `runtimeErrorToEval` + one
  `makeIntrinsicHost`/`intrinsicHostDeinit` pair into a shared `host_impl.zig`,
  removing the ~8 copied 11-handle clone/deinit blocks and guaranteeing one
  suspend-mapping (`host_call_func.zig:123-199`, `host_call_value.zig:563-638`,
  `host_call_member.zig:163-175`, `host_globals.zig:79-118`).
- Keep the `internConst` value-owning fix (`ir.zig:921-933`); make the
  `SourceMap`-lifetime contract explicit (borrow/assert it outlives the returned
  module) and replace the O(n) dedup scan with a hash set.

---

## 5. Detection / prevention infrastructure

Each item below names a concrete attach point in the live tree.

### 5.1 Differential pack-vs-direct harness (highest leverage)

Add a canonical `loadProgram(allocator, io, file, mode) -> {asts, bindings,
main_hint}` in `parity.zig` with `mode ∈ {EmbeddedOnly, SourcePacks,
CompiledPacks}`, and rewrite `runWithKtc` (`parity.zig:1118`), `runWithPacks`
(`parity.zig:1505`), and `cli/commands.zig:runFileIrVm` (`commands.zig:222`) to
call it — three paths become one function with three data inputs. Then add
`src/itests/differential.zig` (append its name to the `itests_files` list at
`build.zig:48`; it needs `setCwd` like e2e — generalize the e2e match at
`build.zig:136` to also match `"differential"`). For every `examples/*.kt` it
runs the program through every available mode and asserts **byte-identical**
output, failing with the first divergent line. Run under one arena over
`page_allocator` exactly as `e2e.zig:18-21`. This turns Class C from a field bug
into a compile-test failure.

> Why this is needed even though a Class C instance is already "covered."
> `tests/fixtures/parity_corpus/nested_name_collision.kt` (the landed
> nested-collision regression test, §2 Class C) is consumed only by the
> kotlinc-oracle parity sweep (`parity.zig:654 corpusDir`, driven by
> `parity/main.zig:122` and the bench/sweep tooling) — it is NOT in the
> `itests_files` list (`build.zig:51-61`) and therefore does NOT run under the
> default `zig build test` (1506 tests). The in-process itests only walk
> `conformance` / `coroutine_smoke` / `threaded_litmus` / `typeck_negative`. A
> `src/itests/differential.zig` registered in `itests_files` is what brings
> Class C protection *into the default target*, where a regression cannot pass
> CI silently.

### 5.2 Reset / thread the hidden VM state

- **Cheap, immediate.** In `Vm.deinit` (`src/interp_ir/vm/run.zig`) and at the
  top of each public runner (`parity.zig:1118`, `1505`; `commands.zig:222`),
  assert in Debug that `outer_this`, `coro_stack`, `active_scope_stack`,
  `field_resolve_stack`, and `ctor_guard` are empty, then
  `clearRetainingCapacity` them. This makes leaked-across-runs state a loud
  failure and makes the differential harness trustworthy.
- **Real fix.** Add the receiver context to `FrameSnapshot` (`eval.zig:149`) and
  save/restore it in the `Suspended` unwind and `resumeContinuation`
  (`eval.zig:349`) alongside `regs/params/captures` — implements §4.2.

### 5.3 Single dispatch entry + invariant assertions at the choke point

Funnel every user-function execution through one private
`dispatchUserFunc(self, allocator, module, func, args, captures, receiver_ctx)`
(the ~22 `evalWith*` call sites delegate to it; `callMemberNamed`/`Only` and
`callValueNamed` already forward — extend the pattern). At its top, Debug-only
invariants: (i) `func.body_func`/`FuncId` in range; (ii) no-dangling-name — any
name resolved is non-empty and selects exactly one declaration (assert the
overload candidate set at `host_call_member.zig:924` is unique or
deterministically ordered); (iii) receiver-chain consistency — if a `"this"`
param and a `"this"` capture both exist they are the same `Instance`, and the
enclosing chain has no `Null`/`Unit` interior entries unless intended. Emit
violations as machine-readable lines through the existing tracer
(`src/interp_ir/vm/trace.zig:76`) under a new `KLIO_TRACE_INVARIANTS` gate.

### 5.4 Property / fuzz generator for closures + suspend

Add `src/itests/fuzz_closures_suspend.zig` (append to `build.zig:48`; needs
`setCwd`). Use `std.Random` with a fixed, env-overridable seed to emit small but
valid Kotlin programs from a constrained grammar: N nested lambdas each capturing
a mutable `Int`, M of them suspending (`delay`) inside `runBlocking`/`launch`,
with implicit-receiver method calls at varying depth. For each program: (a) run
through `runWithPacks` AND `runWithKtc` and assert identical (reuses §5.1's
invariant); (b) when `KLIO_SKIP_KOTLINC_PARITY` is unset, call `parity.check`
(`parity.zig:1764`) to diff against kotlinc and shrink-report the minimal failing
program. Keep ~200 seeds per CI run; persist any failing seed+source under
`tests/corpus/` so it becomes a permanent regression case (monotonic-corpus
rule).

### 5.5 Delete the dead Host + assert single execution path

Delete `src/ir/eval/host.zig` (no importer; confirm with a build) — it is a false
second source of truth for the dispatch contract that has already drifted from
the live `Host` at `eval.zig:2500`. Extend the tracer (`trace.zig:76`) to emit
structured records (one line per dispatch: `{fn, receiver_type, chosen_decl,
path_tag}`) under a new `KLIO_TRACE_PATH=1` gate, where `path_tag` identifies
which consolidated dispatch entry (§5.3) handled it. Add a small
`scripts/assert_single_path.py` (targeting `zig-out/bin/klio`, replacing the
stale Rust-path `corpus_check.py`) that runs a program with `KLIO_TRACE_PATH=1`
and asserts each `(fn, receiver_type)` pair maps to exactly one `path_tag` and
one `chosen_decl` — turning "one execution path" into an executable check.

> Note: `scripts/assert_single_path.py` is the live replacement: it targets
> `zig-out/bin/klio`, runs the examples + coroutine-smoke corpus under
> `KLIO_TRACE_PATH=1`, and asserts decl determinism, single-path grouping, and
> cross-run record stability. `corpus_check.py` remains usable only in
> `--no-rust` mode; `scripts/klio-parity-sweep.sh`, `klio-smoke.sh`, and
> `klio-guard.sh` still reference Rust/cargo paths (`target/release/klio`,
> `cargo build -p klio-parity`, `crates/klio-parity/tests/corpus`) and are
> stale post-port. Any new script should target `zig-out/bin/klio` and
> `tests/corpus/expected/`.

---

## 6. Sequenced remediation roadmap

Ordered for maximum risk reduction per step: land detection before invasive
refactors, then the structural unifications in dependency order.

| # | Work item | Class | Impact | Risk | Effort |
| --- | --- | --- | --- | --- | --- |
| 0a | Delete dead `src/ir/eval/host.zig` + empty dir | cleanup | low | low | S |
| 0b | Extract shared `dispatchIntrinsic`/`runtimeErrorToEval`/`makeIntrinsicHost` into `host_impl.zig` | cleanup | medium | low | M |
| 0c | Debug-only "TLS empty between runs" asserts + `clearRetainingCapacity` (§5.2 cheap) | B detect | high | low | S |
| 1 | Differential harness `loadProgram` + `src/itests/differential.zig` (§5.1) | C detect | high | medium | L |
| 2 | Single `dispatchUserFunc` choke point + invariant asserts (§5.3) | A/B detect | high | medium | L |
| 3 | Fuzz generator for closures + suspend (§5.4) | A/B detect | high | low | M |
| 4a | Precise captured-`var` carrier FIRST: `StoreCapture` instr OR precise boxing (replace syntactic `computeBoxedVars`), proven green with closures itests + §5.1 (§4.1) | A | high | medium | L |
| 4b | DONE — stop swapping `self.globals`, deleted `StoreGlobal`-for-capture + `scoped_env` + the now-dead `WritebackCaptures`/`readLambdaCapture` capture-sync; the HOF invoke path runs over the real top-level env and captured-`var` writes round-trip through the shared `Cell`. Required extending 4a's boxing to function/lambda *parameters* a nested closure writes (the captured-param gap, e.g. `toMap(destination){ consumeEach { destination += it } }`). (§4.1) | A | high | high | L |
| 5 | `VmIntrinsicHost` becomes thin adapter delegating to eval.Host (§4.1) | A | high | medium | L |
| 6 | DONE (receiver chain + close-out) — enclosing-`this` chain is now a `Frame` field (`enclosing_this`), snapshotted into `FrameSnapshot` on suspend and restored on resume; the `outer_this` thread-local + `outerThisStack` + its `resetReceiverTls` are deleted and `enclosingThis`/`enclosingThisChain`/`pushAccessEnclosing`/`popAccessEnclosing` read/write the current frame's chain. Close-out landed: `inner_outer_hint` TLS replaced by an explicit `outer_hint` param (sourced via `callerThisValue` — param or capture) with class-keyed outer selection in `materializeInstance`, plus a lambda-side `this` capture for bare inner-class construction keyed on the new `ir.Class.is_inner` (fixes `with(other){Inner()}` incl. shadowing subjects, lambda-escaping inners, user-HOF lambdas, two-level nesting), `member_only_probe`/`cc_explicit_read` are now params, the dead duplicate `ctor_guard` is collapsed onto `host_instances.ctorGuardContains` (activating the deferred-`object` gate), and `host_call_member`'s re-entrancy flags are defer-cleared + run-boundary-asserted. Remaining §4.2 line item: fold the frame's own `this` into the carrier (see §4.2 consumer inventory). (§4.2) | B | high | high | XL |
| 7 | PARTIAL — single implicit-receiver resolution choke point (`implicitThisValue` + `implicitReceiverChain` in `ir/eval.zig`) now feeds all three `*OrGlobal` handlers (`CallMemberOrGlobal`/`LoadFromThisOrGlobal`/`StoreToThisOrGlobal`), so the bare-name member-vs-global precedence is derived in one place instead of three. Registry func-kind landed: `Func.kind` (`FuncKind.member_extension`) is the authoritative member-extension predicate, set at the member-extension lowering site (`decl.zig`); the five `member_ext_owner_class` dispatch sites route through `isMemberExt`/`memberExtVisible` (the owner-class gate is preserved exactly — the kind selects which funcs are gated, the side table supplies the owner). The four "Or" *instructions* are NOT collapsed to a single `CallUnresolved`: they encode three distinct operations (read / write / call) plus the explicit-receiver `CallMemberOrValue`, and the "Or" itself is the "couldn't classify member-vs-global statically" signal item 8's FQN static resolution removes — collapsing now would re-encode the read/write/call distinction without removing the runtime decision. Deferred to item 8. (A/B) | A/B | high | medium | L |
| 8 | PARTIAL (steps 1-4 + tightening + the steps-2/3 ladder deletion landed; only 8d remains) — per-decl `package` tag on `Func`/`Class`, explicit two-phase header registration, and the package/FQN symbol index (`Module.resolveBareCallIndexed`) as the PRIMARY bare-call path, now hardened: reason-tagged deferrals (`ResolveDeferReason`, 13 classified shapes), order-independent forward references (phase-1 stubs rank by declared arity `decl_user_arity`, full-granularity declared types `decl_user_sig` rendered by the same `loweredTypeRef` body params use, and AST-derived `low_priority`; default-param shapes defer from stub and body gates alike), a six-tier preference order matching kotlinc's probed scoping (named import → own package → wildcard import → default-import package → shipped → other; a named import outranks even a same-file declaration; same-leaf named imports are ALL kept in `registry.import_aliases` so a second import of one leaf is a classified tie, not a shadow; wildcard imports per file in `registry.import_wildcards`, default imports mirroring `stdlib.IMPLICITLY_IMPORTED_PACKAGES` under a lockstep test), and ambiguity as a DEFAULT-ON lowering diagnostic scoped to what kotlinc rejects: a CALLED, non-extension bare call whose in-scope identical-FULL-signature candidates carry no defaults/varargs records `Module.resolve_diags`, surfaced by `klio run`/parity with `file:line` — same-FQN duplicates as "conflicting overloads … identical signatures declared at a.kt:2 and a.kt:3 — rename or remove one of the declarations", cross-package ties as "ambiguous reference … qualify the call or import one explicitly" (exact-wording + both-orders coverage in `itests/resolve_ambiguity.zig`); NOT diagnosed (heuristic-deferred): default/vararg-exercised, extension-form, and never-called identical pairs. Type-distinguishable sets — anything not provably identical at full granularity, incl. generic-argument-only and function-shape-only differences — stay runtime-resolved (`type_overload`), cast picks reclassify (`cast_disambiguated`). Out-of-scope sets are now an error matching kotlinc: a bare call whose every candidate lives in a package the caller neither declares, imports, nor sees by default or via the shipped surface (tier 5, index-verdict shapes only — `resolved`/`unimported_set`/`type_overload`) records an "unresolved reference … add `import pkg.f` or qualify the call" lowering diagnostic; loose-shape deferrals (arity/default/vararg) stay with the heuristic since the runtime may still dispatch a member. Every lowering entry point now seeds the caller package (`ir.build.setLowerSelfPackage` read by every `FuncBuilder`; class bodies get the file's true package via the `decl_pkg` span map — a companion's class-qualified FQN is not a package). `KLIO_RESOLVE_AUDIT` emits a machine-readable per-call readout incl. a divergence grade (`tier_correction` / `shape_correction` / `receiver_pref`); `KLIO_RESOLVE_STRICT` (in the test cache key) hard-fails any ungraded divergence. Sweep readout (85 examples + coroutine fixtures): 0 failures, 0 ungraded divergences; 300 `checkIndexOverflow` tier corrections + 12 `CompletableDeferred` shape corrections. Steps 2+3 (items 8b/8c) are landed: `isShippedFqn` is deleted (`funcId` ranks by `Func.package` and is only the order-based fallback behind the index); the `lookupGlobal` prefix ladder and `installed_bindings` suffix scan are replaced by link-time name→FQN maps (`ProgramImage.default_import_globals` / `pack_bare_aliases` / `any_member_globals`, first-package-wins rank + lexicographic pack tie-break, both unit-pinned incl. the StringBuilder production collision); the `callFunc` bodyless ladder is replaced by link-settled `resolved_redirect`/`resolved_native` (`KLIO_LINK_AUDIT` re-derives the DELETED ladder's algorithm — old prefix order `deleted_bodyless_prefixes`, per-call sibling scan — independently of the new tables, so a divergence is detectable). Resolved identity is carried end-to-end: value-position bare refs AND `::name`/`::Ctor` callable references resolve through the index and emit `LoadGlobal` with the exact `FuncId`/`ClassId` (`refAudit` instruments both arms); the runtime class registry is FQN-keyed with a user-over-shipped first-wins simple-name alias view, `NewInstance`/named-arg/copy/secondary-ctor/parent-chain materialization resolve by FQN (side tables dual-keyed), and the per-class side tables are read through the resolved identity. Cross-phase consistency: typeck's T0094 conflicting-overloads check is per-package (`file_packages` on the Checker), matching the resolver's per-package scopes; expect-fn default parameter values transplant onto the superseding `actual` before the expect drops (Kotlin: defaults live on the expect only). DEFERRED: folding the inline-fn table into the index (8d). | C | high | high | XL |
| 9 | DONE — one executable form per symbol resolved at link time (`ProgramImage.linkResolvedForms` → the `resolved_native` table keyed by `FuncId`, populated once after the module + `installed_bindings` exist); the per-call FQN short-circuit in `callFunc` and `callValue` is deleted, both now consulting the resolved form by `FuncId` (`host_call_func.resolvedNativeForm`). Pack-vs-source identity is settled at link time, load-order-independent. `KLIO_LINK_AUDIT` is a permanent env-gated detector proving the link form equals the deleted per-call probe's pick (0 divergences over the full suite + 82 examples + the differential corpus). (§4.4) | C | high | high | XL |
| 10 | DONE — removed `isLambdaBody()` as a resolution axis at the four `expr.zig` dotted-head sites; package-head vs receiver-member is now the one predicate `headIsPackage` (real package root or `Module.packageHeadDeclared` FQN-prefix), shadowed by captured/local/enclosing-member names — order- and load-mode-independent, no lambda special case. The inline splice already binds the inline receiver as a `"this"` scope local, so no extra frame-receiver slot was needed. Gated green behind the builder-DSL differential (`examples/dsl_dotted_head.kt` + `coroutine_smoke/cs8_dotted_in_builder.kt`, byte-identical across all three pack modes); both audits 0. (§4.4/§4.2) | C/B | medium | high | M |
| 11 | DONE — deleted `Value.Lambda` (vestigial Env-based closure the live IR VM never produced; `AstLambda` already built `IrClosure`). Removed the variant, its one GC-test constructor, and every Value-context `.Lambda =>` arm; `IrClosure` is now the single closure value form and `func.capture_order` (via `ClosureInfo.captures`) is the sole capture-metadata authority. | cleanup | medium | medium | M |
| 12 | DONE — `KLIO_TRACE_PATH=1` emits one structured `[PATH]` record per terminal dispatch through the tracer (`fn`/`recv`/`argc`/`args`/`decl`/`path`), instrumented at every terminal site: `callFunc` body + default thunks, `callValue` closure body + default thunk, `irMethodWalk`, `invokeAnonMethod`, `callSuper` (labelled `super(Target)` — super dispatch is static, so keying on the runtime receiver would collide with the virtual call's key), getter/setter, ctor/init thunks, anon-object build, top-level prop init, the closure trio (`call_value_closure`/`hof_invoke`/`coroutine_closure`), and every native `dispatchIntrinsic` terminal (each now carries the resolved FQN). Value labels report the `typeFqn` simple name — the axis member dispatch probes — so `MutableList`/`List` and `IntRange`/`IntProgression` stay distinct. `scripts/assert_single_path.py` (§5.5) asserts, per program with `--rerun`: (1) one declaration per call shape, (2) one dispatch-path group per target, (3) identical record sets across runs; green over all examples + coroutine-smoke. Two corrections to this row's original spec proved necessary: the chosen-decl assertion keys on `(fn, recv, argc, arg-tags)` rather than `(fn, recv)` because Kotlin overloads legitimately map one `(fn, recv)` to several declarations; and the three behaviorally-unified-but-structurally-distinct closure execution sites form one `closure_body` group (with anonymous bodies identified by declaration, and named function-reference wrappers joining the direct-call group), since a literal one-tag assertion is false by design until the closure sites are structurally merged. | detect | medium | low | M |

**Critical path.** 0a–0c and 1–3 are detection scaffolding that should land
first — they make every later refactor verifiable and convert the three
structural mechanisms into loud test failures (on the green tree, none of the
three classes is reproducible by an existing default-target test, so this
scaffolding is what makes the later steps *checkable* rather than faith-based).
Then the structural unifications fall in dependency order: **4a (precise
captured-`var` carrier) must land and be proven green before 4b (deleting
`scoped_env`/StoreGlobal-for-capture)** — collapsing them in one step silently
drops HOF-lambda captured-`var` mutations and regresses the closures itests. 4b
then unblocks 5 (adapter) and is the prerequisite for 6's frame-receiver work to
be coherent; 7 (one resolver) depends on 6's receiver context existing, and its
extension scorer must keep `member-extension` as a first-class kind (§4.3
caution) so it does not drop the `member_ext_owner_class`-gated member-extension
dispatch the ktor paths rely on; 8→9→10 form the pack-vs-direct chain and depend
on 7's single resolver to route the FQN-keyed lookups — with 8's simple-name
tightening gated on the §4.4-item-3 uniqueness proof and 10 gated on a
builder-DSL differential pass. Items 4b, 6, 8, 9 are the XL/high-risk structural
root-cause fixes; everything else is supporting consolidation.
