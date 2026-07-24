# P3 — `Module.resolveCall`: the single index-primary, type-aware, 3-tier bare-call resolver

## Completed

- `Module.resolveCall` is the live bare-call resolver (`src/ir/lower/expr.zig:5128`),
  index-primary with the shared `applicability.applicable()` ranking the best non-empty
  tier and returning a `Resolution{ target, confidence, emit_form, candidate_set }`.
- `Confidence`/`EmitForm`/`Resolution`/`ResolveCtx`, the `sigViewForApplicability` adapter,
  and the `paramHasDefault` null-`defaults` fallback are in place; the three-tier boundary
  (exact `Call` / virtual `CallMember`+`CallMemberOrGlobal` / deferred `CallValue`) is
  derived once and consumed by the pure emitters `emitCall` / `emitCallMember` /
  `emitMemberOrGlobal` / `emitValueCall`.
- The old ad-hoc lowering helpers are gone: `findCand`, `arityMatch`, `arityMatchTl`,
  `fallbackByDeclArity`, and `matchesRecv`.
- The residual-bug clusters are closed: FloorDivMod (named-arg routing for `IrClosure`
  callees + the `shadowed_by_local` this-prepend gate), NaN-minOf (static overload
  identity + the `linkResolvedForms` body-bearing guard), DeepRecursive (the VM SAM
  dispatch guard on a `CallMemberOrGlobal` callable receiver), and TestTimeSource
  (splice-before-writeback + class-identity type-arg bind). commonTest is 100% per-file.

---

## Completed: retired lowering heuristic ladder

- The lowering-side `preferredBareTarget`, `HeurRung`, `heurPickInexact`, and
  their bare-call divergence audit are deleted.
- Calls containing lambdas that mutate captured variables now use the ordinary
  member/bare-call lowering pipeline. The parallel writeback member/path lowerers
  and their independent index/dispatch decisions are deleted; boxed captures
  preserve the mutation.
- Static return inference rewrites an infix call `a fn b` to the same
  explicit-receiver shape used by execution. Receiver-sensitive overloads
  therefore retain `a`'s declared type instead of being ranked as a receiverless
  function family.
- A statically complete extension/dispatch receiver tower defers to runtime only
  when a visible member or extension accepts the call shape. Outer and companion
  receivers, named/spread extension shapes, and incomplete visibility remain
  conservative until their full candidate scope is modeled.
- Generic receiver proofs retain the structural dispatch type and require a
  complete bound environment. Qualified classifiers never match by simple name;
  dependent candidate bounds are substituted through the declaration receiver
  binding; cycles, lossy intersections, and unresolved bounds remain unknown.
- Caller and candidate type-parameter identities stay separate. A caller type
  parameter is not reinterpreted as a same-named class or builtin, including
  `Any`; the synthesized unbounded upper bound is the exact `kotlin.Any`.
- Exact binary-operator selection ignores the additive eager type-head channel
  and recursively resolves structural call returns instead. A raw inferred
  `List` must not displace a declaration-derived `List<Int>` and make
  `plus(element: T)` compete with `plus(elements: Sequence<T>)`.
- Member headers retain their generic owner receiver, and resolved return-type
  instantiation substitutes class and function type parameters in their own
  scopes. Inherited and extension receivers project through structural
  supertype edges before binding, so chained operators remain statically
  resolvable without treating a shadowing type-parameter name as a classifier.
  Reserved class shells carry their type parameters before member headers are
  created, and inheritance projection retains both the source spelling used by
  supertype edges and the owner-qualified identity used by method signatures.
- Qualified classifier identity remains attached during substitution. A
  declaration type parameter named `String` cannot rewrite `kotlin.String`,
  either directly or through an inherited generic supertype.
- Member-extension return inference binds declaration-class parameters from
  the dispatch receiver independently of the extension receiver. Reserved and
  body-carrying member forms retain the same qualified generic owner.
- Explicit member-extension calls carry their resolved `FuncId`, extension
  receiver, and dispatch receiver into `CallMember`. The declaring-owner side
  table is keyed by class FQN; lowering turns that identity into an exact
  `QualifiedThis` or `LoadGlobal(ClassId)` operand. Runtime invokes the recorded
  declaration with those two operands and never repeats owner selection. The
  loop JIT preserves the same target and both receiver operands instead of
  reopening name dispatch at its host-call boundary.
- An applicable ordinary member that cannot yet acquire an exact or virtual
  identity is recorded as deferred. It still shadows extensions, but emits the
  explicit dynamic member form rather than admitting a same-name extension.
- Class-owned type parameters use owner-qualified synthetic identities in
  static receiver and bound evidence. A method `<T>` can shadow a class `T`
  without rewriting its receiver substitution, and a bounded class parameter
  can select a downstream overload without being mistaken for a nominal class.
  Runtime applicability parses this identity directly, so interpreted and
  statically selected calls use the same bound environment. Applicability
  callbacks consume the complete `TypeRef`; a `#qual:` nominal is never
  reinterpreted as a same-named class or function type parameter.
- Constructor expressions preserve explicit generic arguments as structural
  receiver evidence. `Box<Int>()` therefore participates in member and
  extension applicability as `Box<Int>`, never as a raw `Box`.
- A nullable operator receiver cannot commit to a non-null member declaration;
  nullable extension candidates receive the call instead.

---

## Remaining: make `Module.resolveCall` applicability-primary

The lowerer now has one entry path, but the resolver internals still reconcile
`phaseBLadder` with the index through `preferredBareTargetLike`, and can fall
back through `phaseBFallback`. Replace that reconciliation with one
scope-tiered candidate set ranked directly by `applicability.applicable`, then
delete those remaining declaration-order paths. This is the next architectural
target.
