# P3 — `Module.resolveCall`: the single index-primary, type-aware, 3-tier bare-call resolver

Target-architecture item 3 (`docs/resolution-unification-plan.md:238-245`). One resolver
that tiers candidates by Kotlin scope, ranks the best non-empty tier with the shared
`applicability.applicable()` (P2, already live at runtime — `host_call_member.zig:2170`),
and returns a `Resolution{ target, confidence, candidate_set, emit_form }`. It consolidates
the 24 decision points across `lowerCallGeneral`/`lowerPathCall`/`emitBareFuncCall`/
`emitExtBareCall`/`lowerImplicitThisCall`/`lowerUnresolvedBareCall` into one query whose
answer is a pure function of `(call site, sig index, receiver context)`.

The residual bug cluster this phase is judged against is a **mix of resolution and
non-resolution roots**. Two of the four (DeepRecursive, TestTimeSource) and one-and-a-half
of the FloorDivMod pair are *not* bare-call resolution bugs at all; forcing them through
`resolveCall` would be wrong. This plan therefore covers `resolveCall` **and** the separate
targeted VM/lowering fixes, so P3 lands the whole residual green, not just the part that
happens to be shaped like overload resolution.

Grounding (verified against the tree):

- Index: `resolveBareCallIndexed` `ir.zig:1705`, `BareCallResolution` `ir.zig:1542`,
  `ResolveDeferReason` `ir.zig:1489`, module-internal `SigView`/`sigViewOf` `ir.zig:1596/1618`,
  `scopeTier` `ir.zig:1455`, `funcUserArity` `ir.zig:1468`, `funcHasImplicitThis` `ir.zig:1480`,
  `stubDeclArity`/`decl_user_arity` `ir.zig:1577`, `resolveBareRefIndexed` `ir.zig:1888`.
- Applicability (P2): `applicable()` `applicability.zig:491`, `ArgShape` `:37`, `Score` `:107`,
  `SigView` `:140`, `ApplicabilityScope` `:166`, `paramHasDefault` `:361`, `isFunctionTypeRef`
  `:355`, `builtinSupersOf`. Live runtime callers: `sigViewOfMember`/`shapeOfValueMember`
  `host_call_member.zig:1772/1756`, member pick loop `:2170`.
- Lowering surface: `lowerCall` `expr.zig:2341`, `lowerCallGeneral` `:2915`,
  `lowerValueInvocation` `:3648`, `shadowedByClass` `:3863`, `lowerPathCall` `:3938`
  (`shadowed_by_local` `:3948`, `prefer_member` `:4053`, HeurRung ladder `:4059-4083`,
  recv rebind `:4087-4104`, index-primary `:4116`, `resolveAudit` `:4134`, alias-global
  `:4144`, ext member-first defer `:4187`, `preferredBareTarget` `:4200/4269`),
  `resolveAudit` `:4423`, `heurPickInexact` `:4523`, `inReceiverContext` `:4547`,
  `memberShadowPossible` `:4563`, `findCand` `:4699`, `arityMatch` `:4720`, `arityMatchTl`
  `:4726`, `fallbackByDeclArity` `:4755`, `emitBareFuncCall` `:4877` (member-shadowable gate
  `:4924`, `CallMemberOrGlobal` `:4940`), `emitExtBareCall` `:5043` (member precedence
  `:5109`), `lowerImplicitThisCall` `:5215` (private static bind `:5262`, dynamic dispatch
  `:5306`), `lowerUnresolvedBareCall` `:5333`.
- FuncBuilder guards (`build.zig`): `capturesThisSlot` `:692`, `ownerClass` `:788`, `recvTy`
  `:794`, `hasEnclosingMember` `:811`, `hasOwnMember` `:855`, `ownMemberApplicable` `:869`,
  `isParamThunk` `:903`.
- Non-resolution bug sites: `callValueNamed` IrClosure reorder `host_call_value.zig:587`,
  `callValueWithThis` `recv_fills_param` `:835`; SAM-on-callable dispatch
  `host_call_member.zig:2690-2707`, `isCallableOrIntrinsic` `:3550`, `callValueRec` `:212`;
  reified-inline splice `inline_call.zig:276/665`; native-collapse `linkResolvedForms`
  `interp_ir.zig:339` (`resolved_native` loop `:368-385`, `linkBodyless` `:406`,
  `bodylessNativeForm` `:429`); `kotlin.comparisons.minOf → math.math_min`
  `implementations.zig:1356`, `array_min_or_null` `:776`, `coll_list_min_or_null` `:825`.

---

## 1. `Module.resolveCall` — signature, `Resolution`, tiering, lowering-time scoring

### 1.1 Types (new, `src/ir/ir.zig`, next to `resolveBareCallIndexed` at `:1705`)

```zig
/// The three-tier static/dynamic boundary (plan §61-79) as a resolver verdict.
///   exact   — a committed static target, no runtime leaf. Emits a direct Call.
///   virtual — the slot / candidate is static, the leaf is chosen at runtime
///             (member-vs-global on an implicit receiver, or a receiver-bound
///             extension). Emits CallMember / CallMemberOrGlobal carrying the set.
///   deferred— no static target: unknown receiver or no unique applicable
///             candidate. Emits the runtime probe (CallMemberOrGlobal/CallValue).
pub const Confidence = enum { exact, virtual, deferred };

/// The IR emission shape the lowerer switches on. One enum replaces the
/// per-path re-decision at emitBareFuncCall:4924, emitExtBareCall:5109,
/// lowerImplicitThisCall:5306, lowerUnresolvedBareCall:5397/5450.
pub const EmitForm = enum {
    Call,               // static direct Call(FuncId)
    CallMember,         // static receiver member/extension call on `this`
    CallMemberOrGlobal, // runtime member-first walk, resolved global arm = target
    CallValue,          // LoadGlobal/LoadCapture + CallValue (value invocation)
};

pub const Resolution = struct {
    /// Committed target on exact, the resolved global arm / receiver-bound
    /// extension on virtual, null on a pure deferral.
    target: ?FuncId,
    confidence: Confidence,
    emit_form: EmitForm,
    /// In-scope candidates (scope tier <= best_tier), sig-index order. Carried
    /// on virtual/deferred for the runtime walk + the ambiguity / out-of-scope
    /// diagnostics. Borrowed from `alloc` (a lowering scratch arena).
    candidate_set: []const FuncId = &.{},
    /// Preserved from the index so recordAmbiguousCall / recordOutOfScopeCall
    /// and the audit read the same classification they read today.
    reason: ?ResolveDeferReason = null,
    tier: u8 = 255,
    tier_count: usize = 0,
};

/// The receiver-context bits the lowerer already computes on the FuncBuilder,
/// passed in so resolveCall stays a pure function of (call site, sig index,
/// receiver context) and never reaches into FuncBuilder. Each field maps 1:1 to
/// an existing gate; resolveCall folds them once instead of 6 sites re-deciding.
pub const ResolveCtx = struct {
    in_receiver_context: bool = false, // inReceiverContext(b)            expr.zig:4547
    unknown_receiver: bool = false,    // capturesThisSlot||isParamThunk||recvTy!=null  :4564
    enclosing_has_member: bool = false,// hasEnclosingMember(name)        build.zig:811
    has_type_args: bool = false,       // ast_type_args.len != 0
    cast_pick: ?FuncId = null,         // overloadPickByCast result       expr.zig:4057
    recv_ty: ?[]const u8 = null,       // b.recvTy()                      build.zig:794
    is_value_capture: bool = false,    // knowsOuter && resolve==null     expr.zig:3948
};

pub fn resolveCall(
    self: *const Module,
    alloc: std.mem.Allocator,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
    args: []const applicability.ArgShape,
    last_arg_lambda: bool,
    ctx: ResolveCtx,
) std.mem.Allocator.Error!Resolution;
```

`resolveCall` is index-primary: the INDEX establishes the winning tier and, where it can, the
unique target; APPLICABILITY ranks the tier only when the INDEX defers. `EmitForm` is derived
from `(index/applicability outcome, ctx)` exactly once, so the emitters below become pure
single-input functions.

### 1.2 Tiering by Kotlin scope

Candidates come from `funcsBySimpleName(name)` (`ir.zig:1290`). Scope tier is
`scopeTier(fqn, pkg, name, caller_pkg, caller_file)` (`ir.zig:1455`): tier 0 non-wildcard
import whose full path == FQN, 1 own package, 2 wildcard import of the candidate's package,
3 default-import package, 4 shipped/stdlib, 5 other (unimported). The winning tier is the
lowest non-empty tier over the *rankable* candidates (body-bearing, or a stub with a
`decl_user_arity` record), exactly as `resolveBareCallIndexed`'s `best_tier` loop
(`ir.zig:1719-1747`). resolveCall reuses that loop verbatim by calling `resolveBareCallIndexed`
as its INDEX phase — it does not re-implement tiering.

### 1.3 The engine

```
Phase A — INDEX (authoritative when it resolves):
  ires := resolveBareCallIndexed(name, caller_pkg, caller_file, args.len, last_arg_lambda)
  if ctx.cast_pick != null and ires.reason in {ambiguous_tier, type_overload}:
      ires.reason := cast_disambiguated            // expr.zig:4127-4132, preserved
  if ires resolved (tier_count == 1):
      target := ires.pick();  tier := ires.tier
      → go to Phase C (emit-form) with a committed non-extension target.

Phase B — APPLICABILITY (only when INDEX deferred):
  best_tier := (ires.tier == 255 ? scan tiers 0..=other_package for the lowest non-empty
                                   over funcsBySimpleName : ires.tier)
  cand_set := funcsBySimpleName(name) filtered to scopeTier(id) <= best_tier
  for id in cand_set (body-bearing only):
      sv := sigViewForApplicability(id)             // §1.5, strips a leading `this`
      sc := applicable(&sv, args, loweringScope(args))   // applicability.zig:491
      track best by (sc.points, then sc.proven_args)     // same tuple as pickOverload
  receiver rebind: if ctx.recv_ty != null and best is an extension whose declared
      receiver head != recv_ty, and a same-arity candidate matches recv_ty, prefer it
      (rung .recv_rebind, expr.zig:4087-4104 folded in).
  if a unique tie-free best with a non-null Score exists:
      target := best;  confidence := virtual-or-exact (decided in Phase C)
  else:
      target := null;  reason := ires.reason;  → Phase C emits a pure probe.

Phase C — EMIT FORM (the single member-vs-global decision, folding gates once):
  is_ext := target != null and funcHasImplicitThis(funcById(target))
  member_shadowable := ctx.unknown_receiver
                       or ctx.enclosing_has_member
                       or class_member_names.contains(name)   // memberShadowPossible:4563
  static_ok := ctx.cast_pick == target or ctx.has_type_args    // keep static form
  if target != null and not is_ext and not (ctx.in_receiver_context and member_shadowable and not static_ok):
      → { exact, Call, {target} }
  if target != null and is_ext and ctx.in_receiver_context and member_shadowable and not static_ok:
      → { virtual, CallMemberOrGlobal, cand_set } (defer the ext to the member-first walk;
        exactly the expr.zig:4187-4195 "resolved extension a member could shadow" guard)
  if target != null and is_ext:  → { virtual, CallMember, {target} }  (emitExtBareCall arm)
  if target != null and ctx.in_receiver_context and member_shadowable and not static_ok:
      → { virtual, CallMemberOrGlobal, cand_set } with global arm = target
  if target == null and ctx.is_value_capture:   → { deferred, CallValue, {} }
  if target == null and ctx.in_receiver_context: → { deferred, CallMemberOrGlobal, cand_set }
  otherwise (no candidate, not a receiver context): → { deferred, CallValue, {} }
```

`confidence` is a strict function of `emit_form`: `Call → exact`, `CallMember/
CallMemberOrGlobal → virtual` (target non-null) or `deferred` (target null),
`CallValue → deferred`. This is the plan's three-tier boundary (`§61-79`) made concrete: the
`Call` tier is "static as possible", `CallMember`/`CallMemberOrGlobal` are "dynamic
preserved" with the slot/candidate carried, `CallValue` is the genuine escape valve.

The receiver-preference rebind (`preferredBareTarget` `expr.zig:4269`) is subsumed: an
extension the receiver ladder matched (Phase B `.recv_rebind`, or a resolved extension in
Phase A) is retained over its non-extension namesake because Phase C routes it to
`CallMember`/`CallMemberOrGlobal`, never overriding it with the index's non-extension pick.

### 1.4 The lowering-time `ArgShape` builder — what it can populate

`resolveCall` takes `args: []const applicability.ArgShape`; the caller builds them once from
the AST before the query (replacing the per-rung `findCand`/`arityMatch` walks). At lowering
time the builder (P2 `shapeOfAstArg`) populates only what it can prove cheaply and soundly:

```zig
fn shapeOfAstArg(b: *FuncBuilder, arg: *const Expr, name: ?[]const u8) applicability.ArgShape {
    return .{
        .named       = name,                       // call.arg_names[i]
        .is_spread   = arg.* == .Spread,
        .is_lambda   = arg.* == .Lambda or arg.* == .AnonFun,
        .lambda_arity= trailingLambdaArity(arg),   // 0 for implicit-`it`, else param count
        .literal_kind= argLitKind(arg),            // numeric/string/boolean/char, else null
        // ty / runtime_class / lambda_param_types / value stay NULL at lower time:
        //   no lowered TypeRef, no runtime value, unannotated lambda params.
    };
}
```

Consequences inside `applicable()` at lower time (`scope.refine = scope.subtype = null`):

- Arity / default / vararg / trailing-lambda **binding** is fully decidable from the shapes:
  `applicable()` gates on `args.len` vs `params.len`, `paramHasDefault`, and
  `args[last].is_lambda` + `isFunctionTypeRef(last param)` (`applicability.zig:501-556`).
  This is the whole of what the old `arityMatch`/`arityMatchTl`/`tlShapeMatches` computed,
  now in one place.
- Per-arg **type scoring** runs on `literal_kind` when present (numeric exact-head 100,
  widen 40/30) and treats every arg whose `ty`/`runtime_class` is null as **unknown**: it
  contributes its base score (`Any 10`, type-param `5`, `Unit 1`) and is *never disproven*
  (`refineDelta` returns 0 for a null callback, `applicability.zig:368`). The one place a
  null-typed arg is disqualifying is the callable gate: `is_lambda = false` against a
  function-typed parameter → `scoreArg` null (`applicability.zig` function-type branch),
  which is correct and cast-safe.
- Because unknown args never disqualify, lowering resolution stays sound where types are
  unknown (scope-function receivers, generic instantiation across lambdas) — those defer to
  `virtual`/`deferred`, which is exactly the residual the eager mode (P7) later collapses.

### 1.5 The applicability `SigView` adapter for lowering

`resolveCall` scores candidates through `applicability.SigView` (`applicability.zig:140`),
distinct from the module-internal `SigView` (`ir.zig:1596`) that `resolveBareCallIndexed`
uses only for the `sameUserSig` identity check. `func_defaults` lives on `ProgramImage`
(`interp_ir.zig:114`), **not** on `Module`, so the lowering adapter cannot read it; it carries
defaults on the params instead:

```zig
fn sigViewForApplicability(self: *const Module, id: FuncId) ?applicability.SigView {
    const f = self.funcById(id) orelse return null;
    const off: usize = if (funcHasImplicitThis(f)) 1 else 0;   // strip synthesized `this`
    if (!f.hasBody()) return null;      // stubs are ranked by the INDEX arity gate, not here
    return .{
        .params      = f.params[off..],
        .defaults    = null,            // → paramHasDefault falls back to params[i].has_default
        .has_body    = true,
        .low_priority= f.low_priority,
        .is_member   = self.registry.member_ext_owner_class.get(id) == null and off == 1
                       and self.isMemberFid(id),   // member vs top-level extension
        .is_extension= off == 1,
        .fid         = id,
        .package     = f.package,
    };
}
```

This requires one small additive change to `paramHasDefault` (`applicability.zig:361`) so a
null `defaults` slice falls back to the param flag — sound because the runtime callers set a
non-null `defaults` and never reach the fallback:

```zig
fn paramHasDefault(sig: *const SigView, i: usize) bool {
    const defs = sig.defaults orelse
        return i < sig.params.len and sig.params[i].has_default;   // lowering path
    return i < defs.len and defs[i] != null;                       // runtime path (unchanged)
}
```

---

## 2. What `resolveCall` replaces, and how emission changes

`lowerCallGeneral` (`expr.zig:2915`) keeps its shallow pre-dispatch (special forms, inline
expansion, `shadowedByClass`, value-invocation of a bound local). The **bare-call tail** —
today the 13-way arm from `:3257` (path call) through `:3357` (fallback CallValue), plus
`lowerPathCall`/`emitBareFuncCall`/`emitExtBareCall`/`lowerImplicitThisCall`/
`lowerUnresolvedBareCall` — collapses to:

```zig
const shapes = try buildArgShapes(b, call.args, call.arg_names);   // §1.4, once
const res = try b.module.resolveCall(b.allocator, name0, b.self_package,
    seg.span.file, shapes, lastArgIsLambda(args), ctxFromBuilder(b, name0, ast_type_args, cast_pick));
if (res.reason == .ambiguous_tier) try recordAmbiguousCall(b, name0, seg.span, res);
_ = try recordOutOfScopeCall(b, name0, seg.span, res);
return switch (res.emit_form) {
    .Call               => try emitCall(b, expr, res.target.?),           // static Call
    .CallMember         => try emitCallMember(b, expr, res.target.?),     // ext/member on `this`
    .CallMemberOrGlobal => try emitMemberOrGlobal(b, expr, res),          // walk + global arm
    .CallValue          => try emitValueCall(b, expr, name0, res),        // LoadGlobal/Capture
};
```

Decision points replaced (surface-map → resolveCall internal):

| Replaced site | resolveCall equivalent |
|---|---|
| `lowerPathCall` HeurRung ladder `expr.zig:4059-4083` (`findCand`/`arityMatch`/`arityMatchTl`) | Phase B `applicable()` scoring over the tier |
| `fallbackByDeclArity` rung 6 `:4755` | Phase B on the widened `scopeTier <= best_tier` set + INDEX stub-arity gate |
| `overloadPickByCast` rung 1 `:4057` | `ctx.cast_pick`, honored in Phase A reclass + Phase C `static_ok` |
| recv-rebind `:4087-4104` | Phase B receiver rebind (`.recv_rebind`) |
| `resolveBareCallIndexed` + `preferredBareTarget` `:4116/4200` | Phase A/B, index-primary; preference folded into Phase C routing |
| alias-global-no-overload `:4144` | Phase B empty best + Phase C `CallValue` (in-receiver alias) |
| ext member-first defer `:4187-4195` | Phase C `is_ext + member_shadowable → CallMemberOrGlobal` |
| `emitBareFuncCall` member-shadowable gate `:4924` | Phase C `member_shadowable` |
| `emitExtBareCall` member precedence `:5109` | Phase C `CallMember` vs `CallMemberOrGlobal` |
| `lowerImplicitThisCall` dynamic dispatch `:5306` | Phase C `CallMemberOrGlobal` |
| `lowerUnresolvedBareCall` context/alias/this arms `:5397/5421/5450` | Phase C `deferred` arms |
| `inReceiverContext` `:4547`, `memberShadowPossible` `:4563` | `ctx` + Phase C (computed once, not per branch) |

**Emission change, per confidence:**

- **exact → resolved `Call`.** `emitCall` is `emitBareFuncCall` with the member-shadowable
  gate and the tailrec/`needs_this` handling retained but the *routing already decided*: it
  only ever emits the static `Call{ func = target, exact = was_cast }` (`:4994`). A resolved
  extension with `this` in scope still routes through `emitExtBareCall` **only** when Phase C
  chose `CallMember` (a static receiver bind), never here.
- **virtual → `CallMember` / `CallMemberOrGlobal` with candidate set.** `CallMemberOrGlobal`
  carries `func = res.target` (the resolved global arm) and, newly, `res.candidate_set` so the
  runtime member-first walk chooses the leaf from the resolved set instead of a bare-name
  probe (plan tier 2/3, `§66-76`). `CallMember` is the static-receiver extension/member arm
  (`emitExtBareCall:5149`, `lowerImplicitThisCall:5320`).
- **deferred → runtime probe.** `emitValueCall` is `lowerUnresolvedBareCall`'s
  `LoadGlobal`/`LoadCapture` + `CallValue`, or `CallMemberOrGlobal` with `target = null` when a
  receiver is in scope but no unique candidate exists.

**P1 member-precedence + `hasEnclosingMember` guard — kept verbatim.** The member-vs-global
decision stays exactly the P1 shape: a bare call in a receiver context is member-shadowable
iff the receiver type is unknown (`ctx.unknown_receiver`, the lambda/scope-fn/param-thunk/
extension over-approximation) **or** the lexically enclosing class declares the member
(`ctx.enclosing_has_member`, the precise `hasEnclosingMember` signal at `build.zig:811`) **or**
the program-wide `class_member_names` fallback fires. resolveCall computes this once as Phase C
`member_shadowable` — it does **not** widen the guard (still `class_member_names` as the last
resort until P4/P5 make it receiver-type-precise) and does **not** narrow it. The
`hasEnclosingMember` union of `own_members` + `enclosing_members` is preserved, so an inner
class reaching an outer member and a plain method reaching its own member resolve identically
under run and test. `prefer_member` (`expr.zig:4053`) stays caller-side as the gate on whether
Phase B even runs the ladder, unchanged from P2's `resolveCall` adapter note.

---

## 3. Per-residual-bug fix (resolution vs non-resolution roots)

The four residuals split cleanly: **NaN-minOf is a link-time static-overload-dispatch bug that
`resolveCall`'s type-aware selection is *necessary but not sufficient* for; FloorDivMod,
DeepRecursive, and TestTimeSource are not bare-call resolution bugs at all** and need separate
targeted VM/lowering fixes. Do not force-fit them; the plan lands both kinds.

### 3.1 FloorDivMod (`numbers/FloorDivModTest.kt`) — NOT resolveCall; two dispatch fixes (already in tree)

Two independent defects, both specific to a **local** `check` helper (not top-level), so they
never appear in a naive top-level repro:

- **BUG 1 — named-arg routing missing for `IrClosure` callees.** `check(x, y, expectedMod = z)`
  bound `z` positionally into the first optional slot `expectedFd`. Fix: an `IrClosure` branch
  in `callValueNamed` that reorders named + positional args against `params[0..n_params]` and
  default-fills the gaps, mirroring `callFuncNamed`. **Landed** — `host_call_value.zig:587-640`
  is exactly this branch.
- **BUG 2 — `shadowed_by_local` prepends the enclosing `this`.** A plain captured local `check`
  called inside a `repeat { }` lambda got the enclosing `FloorDivModTest` instance shoved into
  `a` by `callValueWithThis`'s `recv_fills_param` heuristic (`host_call_value.zig:835`). Fix:
  gate the `this`-prepend on `b.isLocalExtFn(name0) or b.isReceiverLambdaParam(name0)`, emitting
  a plain `CallValue` otherwise. **Landed** — `expr.zig:3958` is exactly this gate.

**`resolveCall` does not touch either.** BUG 1 is host-side named-arg binding on a value call;
BUG 2 is the `shadowed_by_local` value-capture arm (`ctx.is_value_capture → CallValue` in Phase
C, which resolveCall preserves — it must *not* attach `this`). The P2 doc's claim that
FloorDivMod is "Fixed by P2" via the numeric-widen scorer is a **mis-attribution**: the true
roots are these two dispatch fixes, and the Long arithmetic / `%=` overload was never wrong.
P3's obligation here is a **verification-and-lock slice**: confirm `FloorDivModTest` green under
`klio test` and add a `klio run` example with a *local* `check` (named-arg-skips-default + call
from inside `repeat { }`) that fails if either site regresses.

### 3.2 NaN-minOf (`numbers/NaNPropagationTest.kt` `NaNTotalOrderTest`) — resolveCall is NECESSARY, plus a link fix

`minOf(0.0, NaN)` for `T = Comparable<Any>` returns `NaN` (IEEE-min) where total order requires
`0.0`. Root cause is a two-part **static-overload-dispatch** defect, confirmed static (not
runtime) because `Array<Double>` and `Array<Comparable>` feed byte-identical boxed runtime input
(`ArrayData.prim == null`, `value.zig:753`) to the same intrinsic yet require divergent output:

1. **Overload not selected by static type at the call site.** klio routes `minOf` /
   `.minOrNull` by receiverless FQN / name only; the numeric overload `minOf(Double,Double)` and
   the generic `minOf<T: Comparable<T>>` are not distinguished at lowering. `::minOf` is worse:
   resolved by name via `Module.funcId` (`ir.zig:1301`) ignoring the expected
   `(Comparable,Comparable)->Comparable` functional type.
2. **The generic overload collapses onto the numeric intrinsic.** `linkResolvedForms`
   (`interp_ir.zig:368-385`, comment "all overloads share the receiverless fqn") marks *every*
   FuncId whose receiverless FQN matches a binding `resolved_native`, so even the generic
   overload's real Kotlin body (which computes the correct total order — proven by user `genMin`
   returning `0.0` and `Double.compareTo(NaN) == -1`) is shadowed by `math.math_min`
   (`implementations.zig:1356`).

**How `resolveCall` fixes part 1:** the type-aware Phase B scores `minOf(Double,Double)` vs
`minOf<T: Comparable<T>>` against the **static arg `ty`** — which lowering *does* have here when
the call site annotates `Comparable<Any>` (the eager-typeck `ty` on `ArgShape`, and the
declared `val` type). The generic overload wins for `Comparable`-typed args, the numeric for
`Double`-typed. `resolveCall` records that identity on the emitted `Call.func` (and on the
`::minOf` callable-ref via a new type-aware `resolveBareRef` that consults the expected
functional type instead of `funcId`-by-name). This is the discriminator klio erases today.

**Why `resolveCall` alone is not sufficient — the required companion fix:** even after Phase B
selects the generic FuncId, `linkResolvedForms` still marks *that FuncId* `resolved_native →
math_min`, so its body never runs. The companion fix, in `linkResolvedForms`/`linkBodyless`
(`interp_ir.zig:368-423`): **do not mark a func `resolved_native` when it carries a real IR
body** — bind the native intrinsic only to the numeric/primitive/bodyless overloads, and let
the generic `<T: Comparable<T>>` body execute (it is already total-order correct). Equivalently,
give the generic overloads a distinct intrinsic id. A runtime-only patch (sniffing
`ArrayData.prim` or element kind) is provably insufficient: `arrayOf(0.0)` as `Array<Double>` and
as `Array<Comparable>` are both boxed `prim == null`. This is the plan's completeness invariant
in action (`§26-59`): the native intrinsic stays as the *backing* of the numeric overload; it
must stop being a *resolution shortcut* that captures the generic body.

So NaN-minOf lands as **resolveCall (static overload identity) + the `linkResolvedForms`
body-bearing guard** — both in the P3 slice list.

### 3.3 DeepRecursive (`utils/DeepRecursiveTest.kt`, all 8) — NOT resolveCall; a VM SAM-dispatch guard

All 8 fail (not just the "Suspended" ones), in **both** `klio run` and `klio test`. The lowering
is already correct: a bare `plain(param)` inside an extension whose receiver type is a
**function type** lowers to `CallMemberOrGlobal this.'plain' [DYN-bound -> plain#4068]` —
byte-identical to the working plain-class-receiver case. The divergence is purely runtime:

- `host_call_member.zig:2690-2707`, the "SAM conversion on a callable receiver" path. The strict
  member pass reaches `if (isCallableOrIntrinsic(receiver))` (`:2691`) with the implicit `this`
  being the deep-recursion block (a function value), and — because the name is not `invoke` and
  no extension is longer than args — calls `callValueRec(receiver, args)` (`:2694`), **invoking
  the block** instead of resolving the global `startBlock`/`plain`. The whole deep-recursion
  continuation engine calls its bare helpers with a function-type `this`, so every test corrupts.

**`resolveCall` does not fix this** and the plan must say so plainly: the emitted IR is already
the correct `CallMemberOrGlobal`; the bug is that the runtime member arm SAM-invokes the
callable receiver before it consults the resolved global arm. The fix is a **VM dispatch guard**
at `host_call_member.zig:2691`: the SAM-invoke-on-callable path must fire only for an *explicit*
member/`invoke` call or a real SAM method name, **not** for the implicit `this` of a
`CallMemberOrGlobal` whose `name` resolves to a global. Concretely: when the instruction is
`CallMemberOrGlobal` and its `func` arm (or the global map) resolves `name`, prefer the global
before the callable-receiver SAM-invoke. `resolveCall` can *assist* — the new `candidate_set` on
`CallMemberOrGlobal` gives the runtime a resolved global arm to prefer, so the guard becomes
"resolved global arm present → do not SAM-invoke the receiver" — but the guard itself is the root
fix and lives in the VM, not in resolution.

### 3.4 TestTimeSource (`time/TestTimeSourceTest.kt` `overflows`) — NOT resolveCall; the writeback pre-dispatch steals the reified splice (FIXED)

Instrumentation (`StoreGlobal`/`LoadGlobal` tracing on the `T` global + lowering-decision
tracing + `dump-ir`) **disproved** the earlier register-clobber/run-vs-test hypothesis. The
"passes under run" observation was a confound: the run repro used `probe<String>` and the test
repro `probe<IllegalStateException>`; with an exception-class type argument the same failure
reproduces under `klio run`. The `T::class == Function` symptom was two stacked defects, both
confirmed and both fixed:

- **ROOT 1 — `lowerCall`'s outer-writing-lambda pre-dispatch bypassed the inline splice.**
  `assertFailsWith<IllegalStateException> { timeSource += d }`: the lambda body's compound
  assign on the captured `timeSource` matches `anyLambdaWritesOuter` (a `plusAssign` member
  call on a `val` is syntactically an `Assign` to an outer name), so the call routed to
  `lowerCallWithWritebackPath` — which never attempts inline expansion — emitting a plain
  direct `Call` and dropping the reified splice entirely. The member arm already tried the
  splice first (`expr.zig:2645`); the bare-path arm did not. Fix: extract the bare-path
  inline expansion into `tryBareInlineExpansion` and attempt it before the writeback
  dispatch (`expr.zig` `lowerCall`); the spliced body lowers the lambda's write in the
  caller's own frame, so writeback machinery is unnecessary there.
- **ROOT 2 — `callFuncTyped` bound the type-arg global to the constructor intrinsic.** On the
  non-spliced fallback, the runtime type-arg binding (`host_call_func.zig`) resolved the
  type-arg name with a raw `lookupGlobal`, which for an exception class returns the
  constructor `Intrinsic`, not the `.Class` value — so `T::class` yielded `kotlin.Function`.
  Fix: probe the class table first (the same class-identity discipline the splicer's
  `classIdIndexed` pick and the `enumValues<T>` arm already apply), falling back to
  `lookupGlobal`.

The `LoadGlobal T -> Function` read was NOT a nested-splice clobber of the unsaved `"T"`
global — no competing `StoreGlobal` ever fired; the real probe frame simply read a
mis-bound global. Regression lock: `examples/reified.kt` `probeAfterFailure` (both the
`val`-`plusAssign` and genuine `var`-write lambda shapes, block throwing, `T::class` read
after `runCatching`).

**Summary:** resolveCall recovers NaN-minOf (part 1) and hardens DeepRecursive/TestTimeSource's
symptom via the `candidate_set`-on-`CallMemberOrGlobal` global-arm preference, but the residual
is only fully green with the companion fixes: `linkResolvedForms` body-bearing guard (3.2), the
`host_call_member.zig:2691` SAM guard (3.3), and the splice-before-writeback + class-identity
type-arg bind (3.4, landed). The FloorDivMod pair (3.1) is already landed and only needs a lock.

---

## 4. Audit-gated migration + ordered implementation slices

`resolveCall` is built **additively** and shadowed behind `KLIO_RESOLVE_AUDIT` against the
current ladder until zero-disagreement, then bare-call emission switches to it. The audit is the
existing detector (`resolveAudit` `expr.zig:4423`), extended to compare the *full* resolveCall
`Resolution` (target + emit_form) against the legacy `(bare_func_id/rung, index_res,
preferredBareTarget)` pick, so a divergence in **either** the target or the chosen emit form
prints a `[KLIO_RESOLVE_AUDIT] ... divergent=1` line the sweep already greps
(`resolve_audit_sweep.py:31` matches `] (member|scorer|named) `; add a `call2` tag).

**Verification cadence:** `scripts/resolve_audit_sweep.py --build` (fast Debug klio, ~2 min,
in-process so the audit env applies across the whole stdlib commonTest corpus + `--examples`) at
every slice; the canonical `zig build itest-stdlib_commontest` (~18 min ReleaseSafe) only at the
milestone slices (5, 9, 11). Zero divergence on the sweep is the stronger gate; the canonical is
the ratchet. Baseline canonical is ~2003; the phase is done at **>= 2006** (the residual cluster
recovered: NaN-minOf +4, DeepRecursive +8, TestTimeSource +1, FloorDivMod locked).

Each slice is independently landable (green build) and independently verifiable.

1. **`paramHasDefault` fallback + `sigViewForApplicability`.** Add the null-`defaults` fallback
   to `applicability.zig:361` and the lowering `SigView` adapter (`ir.zig`, private). Pure
   additive, no caller yet. *Verify:* `zig build test` green; runtime member scorer unchanged
   (its `defaults` is non-null). Landable.

2. **`buildArgShapes` at lowering.** Add `shapeOfAstArg` + a `buildArgShapes(b, args, names)`
   walk in `expr.zig` (§1.4), used by nothing yet. *Verify:* `zig build test`; a unit test
   asserting the shapes for a literal / lambda / spread / named call. Landable.

3. **`Module.resolveCall` (dead code).** Add `Confidence`/`EmitForm`/`Resolution`/`ResolveCtx`
   + `resolveCall` (`ir.zig`), implementing Phases A/B/C by *delegating* Phase A to
   `resolveBareCallIndexed` and Phase B to `applicable()`. No caller. *Verify:* `zig build`
   green (dead code); unit tests for each Phase-C arm on a synthetic module (exact non-ext,
   resolved-ext-in-receiver, deferred type_overload, value capture). Landable.

4. **Shadow audit in `lowerPathCall`.** When `KLIO_RESOLVE_AUDIT` is set, compute `resolveCall`
   alongside the legacy pick and emit `call2 ... divergent=1` on any target/emit-form mismatch;
   **legacy stays authoritative**. *Verify:* `resolve_audit_sweep.py --build` — drive the
   `call2` divergence list to zero, hand-checking each (expected classes: the receiver-preference
   rebind and the tier corrections the legacy `resolveAudit` already grades). Landable at zero
   `call2` divergence.

5. **Flip bare-call emission to `resolveCall`.** Replace the `lowerPathCall` tail
   (`:4046-4208`) + the `emitBareFuncCall`/`emitExtBareCall`/`lowerImplicitThisCall`/
   `lowerUnresolvedBareCall` routing with the `switch (res.emit_form)` (§2). Keep the emitters as
   pure single-target functions; keep `recordAmbiguousCall`/`recordOutOfScopeCall`/the tailrec
   path. *Verify:* `resolve_audit_sweep.py` clean; **canonical must return to >= baseline**
   (expect a transient dip, then recover). `factRun` 5/5, `crossmember.kt` no downgrade,
   run-vs-test parity harness byte-identical. **Milestone (canonical run).**

6. **NaN-minOf part 1 — static overload identity.** In `resolveCall` Phase B, honor the static
   arg `ty` for the `minOf`/`.minOrNull` numeric-vs-generic split; add a type-aware
   `resolveBareRef` for `::minOf` consulting the expected functional type (replacing the
   `funcId`-by-name at `ir.zig:1301` for callable refs). *Verify:* `scratchpad/min.kt` selects
   the generic overload's FuncId (dump the `Call.func` FQN); sweep clean.

7. **NaN-minOf part 2 — `linkResolvedForms` body-bearing guard.** In `interp_ir.zig:368-423`, do
   not mark a body-bearing func `resolved_native`; bind the intrinsic only to
   numeric/primitive/bodyless overloads. *Verify:* `NaNTotalOrderTest.minOfT/arrayTMinOrNull/
   listTMinOrNull/sequenceTMinOrNull` green under `klio test`; `NaNPropagationTest` (numeric,
   IEEE) still green (no regression on the `Double` overloads); `math.math_min` still backs
   `kotlin.math.min`. Landable (+4).

8. **DeepRecursive — VM SAM guard.** At `host_call_member.zig:2691`, suppress the
   SAM-invoke-on-callable path for a `CallMemberOrGlobal` implicit `this` whose `name` has a
   resolved global arm (use the `candidate_set`/`func` on the instruction). *Verify:* rc17
   minimal repro (`block.myStart(42)` enters the global `plain`) under `klio run` *and* `klio
   test`; all 8 `DeepRecursiveTest` green. Landable (+8).

9. **TestTimeSource — splice-before-writeback + class-identity type-arg bind.** DONE (see
   §3.4 for the corrected root cause): `tryBareInlineExpansion` attempted ahead of
   `lowerCallWithWritebackPath` (`expr.zig`), and `callFuncTyped`'s type-arg global bind
   probes the class table before `lookupGlobal` (`host_call_func.zig`). *Verified:* reduced
   `reif.kt` 2/2 under `klio test` and the run-mode repro prints the class name;
   `TestTimeSourceTest` 2/2 (`overflows` recovered, `nanosecondRounding` held); DurationTest
   23/26, TimeMarkTest 11/13, MeasureTimeTest 3/3 held; sweep zero-divergence;
   `examples/reified.kt` extended as the lock. **Milestone (canonical run).** Landed (+1).

10. **FloorDivMod lock.** Confirm 3.1's two landed fixes hold; add a `klio run` example with a
    local `check` exercising named-arg-skips-default + call-from-inside-`repeat{}`. *Verify:*
    `FloorDivModTest` green under `klio test`; the example fails if either
    `host_call_value.zig:587` or `expr.zig:3958` regresses. Landable.

11. **Delete the retired ladder + canonical ratchet.** Remove the now-dead `findCand`/
    `arityMatch`/`arityMatchTl`/`fallbackByDeclArity`/`preferredBareTarget`/HeurRung and the
    duplicated `inReceiverContext`/`memberShadowPossible` re-computations (their logic now lives
    once in `resolveCall`). *Verify:* `resolve_audit_sweep.py` clean; **canonical >= 2006** with
    all four residuals green under run and test; run-vs-test parity byte-identical; strict-mode
    (`KLIO_RESOLVE_STRICT`) no unexplained divergence. **Milestone (canonical run) — phase done.**

Slices 1-5 land `resolveCall` behavior-neutral (audit-proven, then flipped). Slices 6-10 land the
residual — a mix of resolution (6, 7) and non-resolution (8, 9, 10) roots — each behind its own
repro. Slice 11 retires the ladder and ratchets the canonical past baseline. Every slice is green
at commit except the intentional transient dip at slice 5, which slice 6+ recovers.
