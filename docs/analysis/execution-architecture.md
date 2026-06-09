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

**Companion thread-locals, same anti-pattern, none snapshotted.**
`member_only_probe`, `map_fallback_active`, `iterable_fallback_active`
(`host_call_member.zig:54-60`); `cc_explicit_read`, `field_resolve_stack`,
`field_outer_active` (`src/interp_ir/vm/host_fields.zig:62-70`); `ctor_guard`
(defined twice — `host_globals.zig` and `host_instances.zig:61`), `inner_outer_hint`
(`host_instances.zig:62`); `coro_stack`, `active_scope_stack`, `persisted_parked`
(`src/interp_ir/vm/coroutines.zig:514-527`); `coroutine_time_mode_tls`
(`src/interp_ir/interp_ir.zig:322`). Each is transient resolution state kept in
TLS, leakable across a suspend or a re-entrant dispatch, and never reset between
runs in a multi-program test binary.

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

- **`Module.funcId`** returns `first_user orelse first_body orelse first`, where
  `first_user` is the first candidate whose FQN is NOT `isShippedFqn`
  (`src/ir/ir.zig:787-801`, `isShippedFqn` at `ir.zig:936`). Any pack outside
  `kotlin.`/`kotlinx.`/`java.` counts as "user", so a pack's same-named function
  — concatenated first — wins over the user's.
- **`Module.classId`** returns the FIRST `class_index` entry matching the simple
  name (`src/ir/ir.zig:748-753`); same-simple-name/different-FQN classes are
  stored distinctly but the FQN distinction is unreachable from a bare
  reference. The resolver's `module_scope` is one flat last-write-wins table
  keyed by bare name (`src/resolver/resolver.zig:208-233`, `resolver.zig:443-506`);
  `file_package` is tracked only for import validation, never to namespace
  bindings.
- **Inline-fn table** is a process-global `StringHashMap` keyed by bare simple
  name, merged across packs + user (`src/ir/lower/inline_state.zig:31`,
  `inline_state.zig:72-93`, `inline_state.zig:284-302`); a pack `inline fun foo`
  and a user `inline fun foo` share one bucket, tie-broken by shape/order.
- **VM global lookup** hard-codes a `kotlin.*` prefix-probe ladder, then a
  **suffix scan** of `installed_bindings` matching any FQN ending in `.{name}`,
  returning the first hash-map hit (`src/interp_ir/vm/host_globals.zig:431-486`)
  — iteration-order nondeterministic.
- **Two executable forms.** `callFunc`/`callValue` short-circuit any FQN matching
  an `installed_bindings` entry to `dispatchIntrinsic` (a native binding) instead
  of the lowered body (`src/interp_ir/vm/host_call_func.zig:456-466`,
  `host_call_value.zig:270-282`). Which form runs depends on pack-install state,
  and the two forms route through the divergent closure engines of Class A.

**Aggravating factors.** Lowering forks FQN resolution on `isLambdaBody()`
(`src/ir/lower/expr.zig:867`, also `1058`, `2897`, `2956`), so the same dotted
path lowers to a `LoadGlobal`-of-FQN at top level but a member/`this` walk inside
a lambda — and pack code is heavily consumed through builder lambdas. Span-keyed
FQN overrides fire only for files WITH a package header (`build.zig:264-283`), so
packaged pack decls and package-less user scripts take structurally different
mangling/retain branches in the same build.

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
ordering/visibility flags. The `member_only_probe` thread-local
(`host_call_member.zig:54`) is a hidden state channel captured-and-cleared at the
top. `irMethodWalk` resolves the receiver class by two different keys — FQN
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

plus a separate `inner_outer_hint` thread-local for inner-class outer receivers
(`host_instances.zig:61-91`, `host_instances.zig:1827`). There is no assertion
that these agree.

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
  frame's field. Still pending: folding the frame's own `this` and the
  inner-class outer receiver (`inner_outer_hint`) into the same carrier.
- Set the frame receiver slot at call entry on every dispatch path (method walk,
  extension call, closure invoke, inline splice). `frameThisParam`/
  `callerThisValue`/`execCallMemberOrGlobal` read one field instead of recovering
  it by name+type matching. Drop the `== .Instance` restriction so
  primitive/`String` receivers thread identically.
- Eliminate the `outer_this` and `inner_outer_hint` thread-locals and their two
  push helpers. The inline splice sets the frame receiver slot for the spliced
  region instead of binding a scope local named `"this"`, so inline-body member
  resolution uses the identical path as a normal method body.
- Convert the transient boolean guards (`member_only_probe`,
  `*_fallback_active`, `field_outer_active`, `cc_explicit_read`) into explicit
  parameters on the relevant resolver functions so they cannot leak across a
  suspend or a re-entrant dispatch. Collapse the duplicate `ctor_guard`.

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
   "no package" case becomes `package = ""`, not a separate code path.
2. **Two-phase consumption.** Phase 1 registers every source's type/function/
   extension HEADERS (FQN + receiver type) across all packs, features, and user
   files. Phase 2 resolves bodies and extension-receiver bindings against that
   complete, package-qualified header set.
3. **Build one symbol index** mapping (caller-package + caller-imports) → FQN →
   `FuncId`/`ClassId`. Bare calls prefer: own package, then imported names, then
   built-in stdlib. **Tightening prerequisite:** "simple-name fallback only when
   exactly one candidate exists" would HARDEN resolution into an "ambiguous
   reference" error in cases the current order-based `first_user`/`first_body`
   tie-break (`ir.zig:787-801`) silently resolves — the `isShippedFqn` logic
   exists precisely because user simple names collide with embedded-stdlib
   same-names. Do NOT tighten to "exactly one candidate" until the differential
   harness (§5.1) is green across every `examples/*.kt` *and* it is proven that
   each green program's bare calls resolve to a unique
   `(package + imports) → FQN` target; otherwise currently-passing programs turn
   into ambiguity failures. Drop `isShippedFqn` and the flat
   `module_scope`/`classId`-by-simple-name as resolution inputs only once that
   uniqueness holds.
4. **Lowering emits FQN-qualified `Call`/`LoadGlobal`.** The VM does exact
   `funcIdByFqn` (`ir.zig:822`) / `installed_bindings.resolve(fqn)` lookups with
   NO prefix-probe ladder and NO suffix scan (`host_globals.zig:431-486`). Fold
   inline-fn resolution into the same entry point so there is one selection
   algorithm, not a parallel simple-name inline table.
5. **One executable form per symbol.** Resolve pack-vs-source identity once at
   load/link time — bind each symbol to a single executable form (native binding
   OR lowered body) in the program image. Remove the per-call FQN short-circuit
   in `callFunc`/`callValue`.
6. **Remove `isLambdaBody()` as a resolution axis** (`expr.zig:867`, also
   `1058`, `2897`, `2956`). Package-head vs receiver-member would instead be
   decided by resolving the head against the caller's imports/package and the
   lexical capture set — one predicate, no lambda special case. **This is a broad
   behavioral change, not a medium-risk local edit:** `isLambdaBody` currently
   forces a dotted head inside a lambda to a member/`this` walk rather than a
   `LoadGlobal`-of-FQN, and pack/DSL code is consumed almost entirely *through*
   builder lambdas (this is the same consumption surface as Class C's own
   evidence). Flipping it changes how every dotted path inside every builder/DSL
   lambda lowers, and must be gated behind a builder-DSL-heavy differential pass
   (kotlinx/ktor builder itests) being green, not characterized as medium risk.

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

> Note: `scripts/klio-parity-sweep.sh`, `klio-smoke.sh`, `klio-guard.sh`, and
> `corpus_check.py` still reference Rust/cargo paths (`target/release/klio`,
> `cargo build -p klio-parity`, `crates/klio-parity/tests/corpus`) and are stale
> post-port. Any new script should target `zig-out/bin/klio` and
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
| 6 | DONE (receiver chain) — enclosing-`this` chain is now a `Frame` field (`enclosing_this`), snapshotted into `FrameSnapshot` on suspend and restored on resume; the `outer_this` thread-local + `outerThisStack` + its `resetReceiverTls` are deleted and `enclosingThis`/`enclosingThisChain`/`pushAccessEnclosing`/`popAccessEnclosing` read/write the current frame's chain. `inner_outer_hint` and the remaining guards-as-params are not yet folded in. (§4.2) | B | high | high | XL |
| 7 | Single name-resolution function; collapse "Or" instructions to `CallUnresolved`; registry func-kind (member-extension as its own kind, §4.3 caution) for extension scorer | A/B | high | medium | L |
| 8 | Per-decl package tag + two-phase header registration + package/FQN symbol index; lowering emits FQN-qualified calls; remove `isShippedFqn`/prefix-ladder/suffix-scan — tighten simple-name fallback ONLY after §4.4-item-3 uniqueness proven | C | high | high | XL |
| 9 | One executable form per symbol resolved at link time; remove per-call FQN short-circuit (§4.4) | C | high | high | XL |
| 10 | Remove `isLambdaBody()` resolution axis; inline splice sets frame receiver slot (§4.4/§4.2) — gate behind builder-DSL differential pass | C/B | medium | high | M |
| 11 | DONE — deleted `Value.Lambda` (vestigial Env-based closure the live IR VM never produced; `AstLambda` already built `IrClosure`). Removed the variant, its one GC-test constructor, and every Value-context `.Lambda =>` arm; `IrClosure` is now the single closure value form and `func.capture_order` (via `ClosureInfo.captures`) is the sole capture-metadata authority. | cleanup | medium | medium | M |
| 12 | `KLIO_TRACE_PATH` structured trace + `scripts/assert_single_path.py` (§5.5) | detect | medium | low | M |

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
