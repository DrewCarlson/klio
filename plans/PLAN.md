# Running Plan

Living document covering **outstanding work only**. Historical milestone records (M0–M21) live in `docs/PLAN-archive.md`. Update as work lands; once a milestone here completes, summarize it briefly into the archive and clear the entry here.

## Target version & scope

- **Target Kotlin version:** 2.3.21. Pinned via a local checkout of [JetBrains/kotlin](https://github.com/JetBrains/kotlin) at tag `v2.3.21` in `kotlin/` (gitignored).
- **In scope:** the Kotlin language itself, plus a built-in implementation of the Kotlin stdlib (primarily the `common/` surface under `kotlin/libraries/stdlib/`).
- **Out of scope (for now):** loading or interoperating with third-party Kotlin / JVM libraries — no Maven resolution, no `.jar` / `.klib` consumption, no classpath.

## Current state

- 270+ parity-corpus programs + examples byte-identical against `kotlinc-native 2.3.21`.
- `cargo test --workspace` green.
- Pipeline: `lexer → parser → resolver → typecheck → interp`.
- Diagnostic surface: T0001–T0117, W0001–W0007, R0001–R0015, P00xx parser codes.

## Sections completed

### M29-spec — declaration-site annotations, when-binding, definitely-non-null, infix calls, labeled jumps, visibility enforcement, `as` / `as?`, anonymous functions
Phases A–E complete. See archive for details.

### M30-spec — `const val`, `value class`, `annotation class`, `tailrec`, `typealias`, extension properties, inheritance delegation, six small completion items (data object, `field` enforcement, vararg spread, `@UnsafeVariance`, private-variance relaxation, `@PublishedApi`).
Phases F–K complete. See archive for details.

### §3 Built-in types — complete except deferred items (see "deferred-big" below)
- T0050 enum forbids final override; T0051 throwable type params; T0057 tailrec on open.

### §4 Declarations
- Underscore type arguments parsed and inferred.
- `inline val` / `inline var`: T0053 (backing field), T0054 (no-backing-field initializer).
- Inline parameter escape enforcement: T0055 / T0056 (inline / crossinline leaks).
- Implicit lambda → fun-interface conversion at call sites.
- Implicit lambda labels (`forEach { return@forEach }`) — runtime stack + checker.
- Named vararg spread `name = *arr`.
- Annotation `Array<T>` element-type validation, annotation enum / annotation-typed params.
- Data class restrictions: T0061 ≥1 data property, T0062 no vararg data property, data class final-inherited equals, data class open-inherited equals (auto-override).

### §5 Inheritance
- Constructor delegation cycles: T0060.
- Inherit-from-final: T0063. Inherit-from-object: T0064.
- Override return type / mutability / property type / visibility: T0065–T0068.
- Private-and-{open/abstract/override}: T0070.
- Sealed inheritor must be qualified: T0071.
- Data / enum class cannot be open / abstract: T0072.
- Function-type as inheritable interface (corpus).

### §6 Scopes
- Object expression forward references (resolver pre-pass).
- Super-qualified label `super@Outer.foo()`.
- T0075 non-property primary-ctor params out of scope from methods.
- T0076 property-initializer cycle.
- T0078 label target not labelable (1.4+).

### §7 Statements / §8 Expressions
- Compound-assignment dispatches to `plusAssign` etc. (§7.1.2).
- T0079 ambiguous compound assignment.
- For-loop variable annotations and destructure types parsed (§7.2.3).
- T0081 / T0082 reference / value equality distinct types.
- T0083 `as?` warns on non-reified type parameters.
- T0085 anonymous-object escape rule.
- T0086 spread element-type mismatch.
- `null is T?` / `null is T` const-fold warnings (§8.11.1).
- Bare type `is` syntax (§8.11.1).
- §8.9.2 `==` lowering arms pinned (boxed float bit-equality, null arms).
- IEEE 754 vs boxed Float / Double `==` semantics.
- `!!` not-null assertion with subject narrowing (§8.19).
- Safe-call result nullability (§8.21.1).
- `this@<extensionFn>` inside extension function body (§8.24).
- KProperty / KFunction / KCallable / KClass `is`-check recognition (§8.21.2).
- Branchless `if (c) else;` (§8.5).
- Const-expression predicate accepts enum entries / templated strings (§8.2).

### §9 Operator overloading
- User-type binary / unary / range / contains operator dispatch.
- Extension `compareTo` and `invoke`.
- `inc` / `dec` with chained eval-once for `++` / `--`.
- Destructured lambda parameters with optional per-slot type, `_` placeholder skipping `componentK`.
- `provideDelegate` operator.
- T0087 `operator` keyword missing on convention dispatch.
- T0088 `operator fun` signature mismatch.

### §10 Packages and imports
- Backtick-escaped identifiers (lexer + parser).
- P0044 wildcard import with alias; P0045 / P0046 misplaced package/import headers; P0047 malformed import paths.
- R0003 narrowed; R0012 unknown kotlin packages.
- Renaming imports (`import x.y as z`) bind + shadow.
- Spec implicitly-imported package list surfaced.

### §11 Overload resolution
- T0089 / T0090 / T0091 / T0093 / T0094 (none-applicable, MSC forwarding-test ambiguity, ambiguous super, conflicting overloads).
- Overload set filtered by named-arg names + explicit type-argument count.
- Member callables excluded on `Nothing` receivers (§11.3.2).

### §12 Control- and data-flow analysis
- W0002 unreachable code, T0084 senseless comparison, T0085 useless cast, useless elvis (single sweep landing).
- Stdlib function contracts for scope functions and `check` / `require`.
- VIA extended to class-body val/var across init blocks.
- Smart-cast narrowing killed on `var` reassignment.
- `!!` and `as T` narrowings propagated onto the subject.
- Finally-divergence propagated into try expression type.

### §13 Type constraints
- T0022 upper-bound enforcement on explicit type arguments.
- T0096 circular type-parameter bounds.
- `Type::Intersection` IR and §13 constraint-system scaffold.
- Call-site type-argument inference via constraint system.

### §14 Type inference (smart casts + local inference)
- Smart-cast through `as` / `as?` with subject narrowing.
- Elvis-return narrowing.
- Cross-variable reference-equality narrowing.
- `when` subject narrowing in `is`-pattern branches.
- Definite-evaluation loop forms (`while (true)`, `do-while`): body narrowings propagate post-loop.
- Bound smart casts via `val` aliasing.
- Negative-type narrowing via `!is` dual branches.
- Phantom-`it` parameter selection by callable shape.
- Bare type-argument inference for `is` / `as`.
- Builder-style entry points: typeck + resolver accept and constrain.

### §15 Runtime type information — complete
- T0100 cannot check erased type param; T0101 nullable class literal LHS; T0102 non-reified class literal; T0103 class literal LHS not a class; T0104 class literal with type arguments; T0105 runtime-unavailable catch types.

### §16 Exceptions — complete
- T0106 throw operand must be Throwable.
- Subtype-aware catch dispatch for user exception classes (`Instance` + builtin tail walk + captured-env supertype chain).
- User exception class corpus + example.

### §17 Annotations — complete
- T0107 ANNOTATION_CYCLE (direct + transitive through `Array`).
- T0108 ANNOTATION_PARAM_DEFAULT_NOT_CONST.
- T0109 ANNOTATION_NOT_REPEATABLE.
- T0110 ANNOTATION_TARGET_MISMATCH.
- T0111 / W0006 `@Deprecated` use-site diagnostics.
- T0112 / W0007 `@RequiresOptIn` / `@OptIn`.
- `@Suppress` filters diagnostics by code.
- Enum / annotation-typed annotation parameters resolved through classifier kind.

### §18 Coroutines — diagnostics partial
- T0114 SUSPEND_NOT_ALLOWED on ctor / property / delegation operators.
- T0115 SUSPEND_CALL_FROM_NON_SUSPEND coloring.
- T0069 OVERRIDE_SUSPEND_MISMATCH.
- `is_suspend` threaded through `Type::Function`, mismatched assignment rejected.

## Outstanding work

Items below are either small but bounded, or large enough to deserve their own milestone.

### Small / bounded

- [ ] **`@Retention` reflection support.** Parsed and dropped. Lands when reflection grows past `KClass.simpleName` (currently no consumer).

(Full `@BuilderInference` integration folded into M-Constraints Phase 4.)

### Deferred-big (milestone-sized)

- [ ] **M31 — Coroutines runtime.** Continuation-frame interpreter, `Continuation<T>`, `CoroutineContext`, `EmptyCoroutineContext`, `ContinuationInterceptor`, `kotlin.coroutines.intrinsics` surface, `COROUTINE_SUSPENDED` sentinel, `runBlocking { ... }` smallest builder. Parser / typeck-side `suspend` diagnostics already in place.
- [ ] **M-multifile.** Module model: the files compiled in one `klio` invocation form a module. Tightens `internal` (T0117 INTERNAL_ACROSS_MODULES), enables object-member imports, companion-object imports through type names, R0013 / R0014 object-import diagnostics, R0015 import-visibility, file-local import scoping.
- [ ] **M33 — LSP + editor integration.** `klio-lsp` (tower-lsp), `render::lsp`, VS Code extension, JetBrains smoke-test manifest. Deferred per archive note until language surface stabilized.
- [ ] **Unsigned types.** `UInt` / `ULong` / `UByte` / `UShort` plus their array / range / collection / sequence variants.
- [ ] **True lazy `Sequence<T>` + `sequence { yield(x) }` builder.** Lazy iterator semantics. Builder requires coroutine machinery, gated on M31.

## M-CFA — First-class CFG (Control- and Data-Flow Analysis) — **Cutover landed**

The `klio-cfa` crate is the single source of truth for smart-cast narrowing, killDataFlow, definite-assignment dataflow, and unreachable-code detection. Phases 1–5 are complete; Phase 6 ripped the legacy `Frame.narrowings` / `narrowing_class` / `aliases` / `check_condition` / `CondNarrow` / `diverged: bool` infrastructure and the `check_loop_body_propagating` lift. Contracts effects live in `klio-cfa::analyses::contracts`. Reachability consults the typechecker's `self.types` so `Nothing`-returning calls prune their block's successors. Remaining residue: the `Frame.bindings` map (declared types, still needed) and the `Checker.assigned: HashSet<String>` definite-assignment set kept as a fallback for lambda-callback contract effects the CFG cannot yet trace into (`run { x = 4 }` style).

### Phase 1 — `klio-cfa` crate skeleton + IR
New crate `crates/klio-cfa` with no behavior migration.
- `ir.rs`: `Cfg { blocks: IndexVec<BlockId, BasicBlock>, entry, exits, labels }`, `BasicBlock { nodes, term, preds, succs }`.
- `Node` per spec §12.1.1: `Eval { reg, expr }`, `Assign { lhs: Place, rhs }`, `Assume { reg, polarity }`, `AssumeIs { reg, ty, polarity }`, `AssumeNull { reg, eq_null }`, `Assert`, `KillDataFlow { var }`, `Backedge { loop_id }`, `Unreachable`, `LabelMark`.
- `Terminator`: `Goto`, `Branch { cond, t, f }`, `Switch { reg, arms, default }`, `Throw`, `Return`, `Unreachable`.
- `Edge { kind: EdgeKind::{Normal, True, False, Exception(TypeRef), FinallyEntry, FinallyExit} }`.
- `Place::{Local(Symbol), Field(Reg, FieldId), This}` for assignment targets and smart-cast dot paths.
- `print.rs` producing spec's dashed/solid box diagrams for snapshot tests.

### Phase 2 — AST → CFG lowering
`lower.rs` covers everything that does not introduce joins, then everything that does.
- `LoweringCtx { cur: BlockId, regs, loop_stack: Vec<LoopFrame{entry,exit}>, try_stack, finally_stack }`.
- Expressions: literals, calls (eval receiver then args then call per §12.1.1), property access, assignment, `++`/`--` desugared.
- `if`/`when` per §12.1.1: emit `Eval cond`, `Assume`/`Assume !`, branch arms, join. Multi-arm `when` desugared into chained two-armed forms (spec p. 4).
- Boolean `&&`/`||`/`!`, elvis `?:`, `a?.b`, `a!!`, `as`, `as?` lowered to spec p. 5–8 fragments (assume + unreachable branch for `!!` and `as`; null/non-null split for `?.`).
- `return`/`throw`/`return@label`/`break@l`/`continue@l` → terminator to function exit, labeled exit, or backedge.
- `while`/`do-while`/`for` (desugared to iterator while) per spec p. 9–10. `Backedge` Node inserted at every loop back-jump.
- `try/catch/finally` per spec p. 7: dup finally for normal-exit and for each exception path; exception edges from every Node in body/handler to handlers filtered by `Exception(T)`.
- Class bodies: chain decls/init blocks in source order (spec p. 11).
- Snapshot tests: 50+ fixtures covering each form.

### Phase 3 — Monotone dataflow framework + killDataFlow
`dataflow.rs`.
- `trait Lattice { fn bottom(); fn join(&mut self, other) -> bool; fn leq(&self, other) -> bool; }`.
- Forward + backward worklist solver, RPO iteration, dirty-bit, terminates via lattice height (§12.2).
- `killDataFlow` inference (§12.2.2): natural-number map lattice over assignable Places; at fixpoint, every backedge where `[[b_pred]](x) > [[b_succ]](x)` for some `x` gets a `KillDataFlow(x)` inserted into the successor.
- `Map<K, L>` and `Flat<T>` lattice combinators.

### Phase 4 — VIA, unreachable code, finally
`analyses/{via.rs, reachable.rs, finally.rs}`.
- VIA (§12.2.3): `Map<Place, Flat<Assigned|Unassigned>>`. `DeclLocal` adds Unassigned; `Assign` sets Assigned; read at Top|Unassigned emits T0020; `val` reassign at non-Unassigned emits the val-reassign diagnostic. Replaces `Binding.needs_init` and ad-hoc `assigned_set`.
- Reachability (§12.1.5): unreachable iff entry bottom or all preds end in `Unreachable`/`Throw`/`Return`/`Eval _ : Nothing`. Reports W0002 once per source region. Replaces threaded `diverged`.
- Finally divergence: when finally's (2)-copy reaches `Unreachable`, prune body's normal-exit edge. Replaces check.rs:6059.
- `Nothing`-typed expressions feed reachability via synthetic `Unreachable` terminator (§12.1.5).
- Moves: T0020, W0002, unreachable-after-return, val-reassign, finally-divergence pruning.

### Phase 5 — Smart-cast and nullability dataflow
`analyses/smartcast.rs` integrated with `klio-types::Type` (intersection variant already exists).
- Lattice `Map<Place, Flat<Type>>` ordered by Kotlin subtyping (intersection = GLB at joins).
- Transfer: `AssumeIs(r,T,true)` narrows `state[p] & T`; negative refinement records dual for sealed-`when` exhaustiveness; `AssumeNull(r,false)` narrows to non-null projection; `Assign(p,_)` resets to declared type; `KillDataFlow(p)` resets explicitly.
- Join: pointwise intersection; feeds constraint solver's `add_constraint(t <: bound)` for GADT.
- Replaces `Frame.narrowings`/`narrowing_class` and manual save/restore around `&&`/`||`/elvis/if/when/try.
- Moves: T0084 (senseless comparison via `Nothing` join after exhaustive negative is-check), T0085 (useless cast via `AssumeIs(p,T)` where state already `<: T`), smart-cast stability re-check.

### Phase 6 — Contracts, when-exhaustiveness, migration
`contracts.rs` + integration into `check.rs` + deletion of replaced code.
- Contract effects (§12.2.5): `kotlin.run/let/with/apply/also` get `callsInPlace(EXACTLY_ONCE)` edges into lambda body; `check`/`require` get `Assume cond` after the call. Standard contracts hard-coded; user contracts via `kotlin.contracts.contract { ... }` parsed into the same effect list.
- `when`-exhaustiveness: drive T0021 off CFG's negative-AssumeIs accumulation at the default arm; fall-through becomes a reachability query.
- typeck wiring: `typecheck()` builds one CFG per function/property accessor/init block via `klio_cfa::build`; check.rs reads via `cfa.smart_cast_at(span)`, `cfa.assigned_at(span)`, `cfa.is_reachable(span)`. Delete `Frame.narrowings`, `narrowing_class`, `needs_init`, per-branch HashSet plumbing.
- Migration discipline: gate behind `--cfa` until full 270+ corpus parity, flip the default and remove dead paths in one commit.
- Final diagnostics owned by CFG: T0020, T0021, T0084, T0085, W0002, val-reassignment, contract-induced smart-cast, lateinit-before-init, finally-divergence reachability, GADT `is` narrowing (feeds M-Constraints).

## M-Constraints — Full constraint solver — **Phases 1–4 landed, Phase 5 in effect at call sites**

The solver in `klio-types/src/constraints.rs` is now spec §13.2.1-shaped: `ConstraintKind::{Subtype, Equality}` with variance-aware reduction, `Provenance` (`CallSite { span, arg_idx }` surfaces in T0097), dual-arm `S? <: T?`, paired-generic equality derivation, cycle union-find, staged fixation via Tarjan SCC, and `PostponedKind` scaffolding for lambda / callable-ref / builder / eta deferral. The typechecker's `infer_call_return_with_args` runs the solver inside a multi-call `InferenceSession` so `foo(bar(x), baz(x))` and three-deep `id(id(id(5)))` chains share one solve. Post-inference lambda body re-typing folds refined return types back into the substitution. Smart-cast narrowings flow into inference automatically because `Path` reads return the CFG-narrowed type.

Gaps verified vs spec §13.2.1: flexible types `(α..α?)`; parameterised supertype walk with variance-aware containment `Q ⪯ F`; intersection-on-lhs alternative-branch handling; equality-bound derivation; type-variable lower-bound substitution. `incorporate` only does `S <: α ∧ α <: T ⇒ S <: T` — missing equality-substitution and parameterised-supertype variance incorporation. `solve` ignores dependency staging. `infer_call_return` (check.rs:7707) builds a fresh CS per call and discards it; no multi-call, postponed vars, lambda return inference, callable refs, or GADT path.

### Phase 1 — Constraint kinds, provenance, flexible/intersection completeness
- `enum ConstraintKind { Subtype, Equality }` with `Variance { Invariant, In, Out, Star }`. `Constraint { lhs, rhs, kind, provenance: Provenance::{CallSite(Span,ArgIdx), Return(Span), LambdaBody(Span), SmartCast(Span), Bound(Symbol), LubJoin(Span)} }`. Provenance points T0097 at the failing constraint, not the call.
- Add `Type::Flexible(lo, hi)` to `klio-types::lib.rs` if absent.
- Reduction rules per §13.2.1: var/var → bound; `(α..α?) <: T` → `α <: (T..T?)`; `S? <: T?` → `S <: T` ∧ `S!! <: T`; parameterised rhs `G[A1..AN]` → walk lhs supertype chain to `G[B1..BN]`, emit per-arg containment `BM ⪯ AM`; type-variable rhs → reuse lower bound + intersection-self elimination; intersection rhs → per-component subtype constraints.
- Containment `Q ⪯ F` exactly per §13.2.1 table: invariant→both directions; covariant→one; contravariant→reversed; `*`→none; mismatched→error. Declaration-site variance normalised to use-site before reduction (helper in `klio-types::variance`).

### Phase 2 — Incorporation, equality, transitive closure
- Retain `S <: α ∧ α <: T ⇒ S <: T`.
- New: `S <: α ∧ α <: S` (or equality) records `α ≡ S` in union-find; every `Q <: P` containing `α` rewritten via `[α := S]` and refed.
- New: for `α <: S, α <: T` sharing parameterised supertype `G[..]`, pairwise-invariant args produce equality constraints `A'M ≡ B'M` (§13.2.1 final bullet). Infers `T = Int` from `α <: List<T>, α <: List<Int>`.
- Cycle detection: `α <: β <: α` collapses both; downstream rewritten.
- Termination: `seen` over canonicalised constraint string; bound by total bound count (finite — reduction never invents fresh class symbols).

### Phase 3 — Staged dependency, fixation order, multi-call
`inference/staging.rs`.
- Dependency relation `α →dep β` iff some bound `α <: T` or `T <: α` contains `β` (§13.2.2). SCC over inference vars; fix in reverse topo order. Substitution after each fixation may trigger fresh RIP.
- Fixation per `SolutionPreference`: push-down → GLB(uppers) excluding free vars; pull-up (default) → LUB(lowers) via §13.2.3 constraint-system encoding (`A <: T, B <: T, ↓T, ↑A, ↑B`); both/neither → pull-up.
- Multi-call: `infer_call_return` lifts to `InferenceSession` that survives nested calls inside one expression. Calls register fresh vars; outer-call constraints reduce against inner-call vars before fixation. Handles `foo(bar(x), baz(x))`. Wiring: `check_expr` Call carries `&mut InferenceSession` instead of allocating its own CS.
- Diagnostics: T0098 (non-comparable substitutions) when pull-up var has incomparable lowers whose LUB widens to `Any?` and contradicts an upper; T0099 (circular) when SCC has no resolvable bound. (Note: T0097–T0117 currently in use — these need fresh codes during integration; placeholders here.)

### Phase 4 — Postponed type variables
`inference/postponed.rs` + check.rs hookup.
- `PostponedKind::{Lambda{param_tys, return_var}, CallableRef{ref_expr}, Eta{fn_sig}, BuilderInference{owner_var}}`. Excluded from active stage until owning expression re-typed with resolved context.
- Lambda: `{ a -> body }` whose expected type is `(α) -> β` registers `α`, `β`; defers body typing until `α` fixed; feeds `body_ty <: β`.
- `@BuilderInference`: marks lambda receiver var postponed; after outer call vars fix, builder body re-typechecked with receiver substituted; new constraints flow back. Required for user `buildList { add(x); add(y) }`-style functions. **This closes the existing "Full @BuilderInference integration" item.**
- Callable references `::foo`: defer until expected-type context arrives; resolve overload by expected `(P1..Pn) -> R`; emit chosen-overload constraints.
- Eta: `f` in function-typed context expands to `{ a -> f(a) }` lazily; param vars postponed until call-site arity known.

### Phase 5 — CFG integration: GADT equality, smart-cast intersections, LUB at joins
Bridge with M-CFA.
- At each CFG join, smart-cast pointwise intersections per Place are emitted as fresh `(state_p) <: declared_p` constraints into the active session whenever declared type contains an inference var (e.g. lambda parameter).
- `when (x) { is Sub<*> -> body }` on generic `x: T`: if `Sub<A> : Super<f(A)>` and `x: Super<U>`, add `U ≡ f(A)` for body's subgraph. Implemented as per-block `BranchAssumptions` consulted via scoped `assume_equality(α, T)`; assumption dropped at join.
- CFA `Type::Intersection` outputs become legitimate lower bounds for `↑α` — exactly the §13.2.3 LUB encoding. LUB at `if`/`when`/`try` joins becomes adding `A <: E, B <: E, ↓E, ↑A, ↑B` to the session instead of eager `lub_pair`, giving room to refine `E` against a later expected type.

### Phase 6 — Diagnostics, performance, migration
- Provenance-aware diagnostics: each `InferenceError` carries originating `Provenance`; renderer points at the argument expression, lambda return, or smart-cast join.
- Intern types inside the solver via `Interner` in `klio-types`; canonicalise constraint keys to interned ids rather than `Type::to_string`. `seen: HashSet<(String, String)>` becomes `HashSet<(TypeId, TypeId, ConstraintKind)>`.
- Migration: `infer_call_return` becomes a thin wrapper opening a one-shot `InferenceSession`; multi-call activates when `check_expr` opens a session at the outermost call. Existing 270+ corpus stays green at every phase boundary; new tests gate each phase.

### Ordering note
M-CFA Phase 5 (smart-cast) produces the inputs M-Constraints Phase 5 consumes; M-Constraints Phase 4 (postponed vars / @BuilderInference) is independent and may land before M-CFA Phase 6. Suggested interleave: M-CFA P1–P3 → M-Constraints P1–P2 → M-CFA P4–P5 → M-Constraints P3–P4 → M-CFA P6 + M-Constraints P5–P6.

## Working agreements

- Land milestones via small PR-sized changes; keep `main` always green.
- Drive design of non-trivial subsystems with role-based adversarial agents (e.g. *Language Designer*, *Compiler Programmer*) before implementing.
- Every milestone update: tick boxes, add discoveries, retire stale items. Once complete, fold a one-paragraph summary into `docs/PLAN-archive.md` and clear the entry here.

## Testing discipline

Every language feature ships with:

1. **Unit tests** in the owning crate covering success paths, all spec-listed edge cases, and every diagnostic the code can emit.
2. **End-to-end tests** that drive the full pipeline and assert observable behavior (stdout, return values, diagnostics with codes).
3. **A growing `.kt` corpus.** Per-crate snapshot corpora plus the workspace `crates/klio-parity/tests/corpus/`. The corpus only grows.
4. **Negative tests** for every error path under `crates/klio-typeck/tests/negative/`.

A feature is not "done" if removing or breaking it leaves the test suite green.

## Example programs

Maintain `examples/` (indexed by `examples/README.md`):

1. One example per new feature, minimum.
2. Deterministic output.
3. Examples never regress.
