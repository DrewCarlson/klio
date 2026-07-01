# P2 — Shared Overload-Resolution Applicability Engine

Single `applicable()` function serving all three overload callers (lowering ladder,
runtime scorers, eager typeck) through one `ArgShape` input type: each caller populates
the fields it can prove and leaves the rest `null`. `applicable()` is a pure, allocation-
frugal function in a new `src/ir/applicability.zig`; the three callers keep their own
emission/binding/diagnostic code and only swap their per-candidate scoring core for a
call into it.

Grounding (verified against the tree):

- Lowering ladder: `src/ir/lower/expr.zig:4021-4108` (`lowerPathCall` rungs),
  `overloadPickByCast` `expr.zig:169`, `findCand` `4674`, `arityMatch` `4695`,
  `arityMatchTl` `4701`, `matchesRecv` `4647`, `fallbackByDeclArity` `4730`,
  `HeurRung` `4660`.
- Runtime global scorer: `src/interp_ir/vm/host_call_func.zig` — `overloadScoreArg`
  `389-507`, `builtinSupersFor` `511-525`, `overloadScore` `529-589`,
  `pickOverload` `649-671`, `pickOverloadCached` `636-647`, exact bypass at `1278-1280`.
- Runtime member scorer: `src/interp_ir/vm/host_call_member.zig` — `overloadScoreArg`
  `1626-1701`, `builtinSupers` `1741`, `pickMethodOverload` `1990-2182`,
  `scoreExtCandidates` `6666-6771` (`ExtKey = [8]i32` `6657`), `extReceiverSpecificity`
  `898`, `staticReceiverApplicable` `1013`.
- Tri-state matcher: `src/interp_ir/vm/overload_match.zig` — `valueMatches` `168-249`,
  `builtinHeadAccepts` `267-283`, `builtinKindMismatch` `124`, `containerArgsMatch` `337`,
  `functionShapeDelta` `467`, `refineByDeclaredArgs` `520`.
- Eager typeck: `src/typeck/check/expr_calls.zig` — `checkOverloadedCall` `500-819`,
  `trailingLambdaParamIdx` `1258`; `src/typeck/check/helpers.zig` — `atLeastAsApplicable`
  `697-724`, `pickMsc` `734`; `FnSig` `src/typeck/check.zig:431`.
- IR / runtime surface: `Func.low_priority` `ir.zig:726`, `DeclArity` `ir.zig:923-927`,
  `TailCallFunc` handler `ir/eval.zig:2089-2104`, `Call.exact` re-resolution skip
  `ir/eval.zig:2676`, `callFuncTyped` exact bypass `host_call_func.zig:1278-1280`,
  the `KLIO_RESOLVE_AUDIT` detector `expr.zig:3417,4384-4109`.

---

## 1. The `ArgShape` type

`ArgShape` is the union of everything any caller can know about one actual argument at the
moment it resolves an overload. It is a plain value struct (no allocation, borrows only):

```zig
// src/ir/applicability.zig
pub const LiteralKind = enum { numeric, string, boolean, char };

pub const ArgShape = struct {
    /// Declared/checked static type of the argument, when the caller has one.
    /// Lowering: null (only an AST Expr, no lowered TypeRef).
    /// Runtime: null (has a Value, not a declared type) EXCEPT the synthesized
    ///          receiver slot for members, which carries the declared receiver TypeRef.
    /// Eager:   the checked `Type` re-expressed as a TypeRef view (always set).
    ty: ?TypeRef = null,

    /// The argument is a lambda / anonymous-function literal (trailing or not).
    /// Lowering: set from AST (Lambda/AnonFun node).
    /// Runtime: set when the Value is IrClosure/Function/BoundMethod/Class ref.
    /// Eager:   set when the AST arg is a lambda literal.
    is_lambda: bool = false,

    /// Declared parameter count of the lambda, when known.
    /// Lowering: trailingLambdaArity() — 0 for implicit-`it`, else param count, null if not a lambda.
    /// Runtime: closures[id].n_params, or Function.decl.params.len, 0 for a class ctor ref.
    /// Eager:   lambda literal param count (null if body is deferred/Unresolved).
    lambda_arity: ?u8 = null,

    /// Declared lambda parameter types, when the caller can see them (for
    /// functionShapeDelta refinement / suspend proof).
    /// Lowering: null (AST param annotations not lowered at pick time).
    /// Runtime: resolved via closureBodyFunc params; null when unannotated.
    /// Eager:   the annotated lambda param types; null when inferred.
    lambda_param_types: ?[]const TypeRef = null,

    /// Named-argument name for this slot (`x = ...`), else null (positional).
    /// Lowering: call.arg_names[i]. Runtime: interned Call.arg_names[i]. Eager: arg_names[i].
    named: ?[]const u8 = null,

    /// The argument is a spread (`*arr`) feeding a vararg.
    /// Lowering: AST Spread node. Runtime: spread flag on the call. Eager: AST Spread node.
    is_spread: bool = false,

    /// Runtime class simple-name of the argument value, ONLY the runtime callers
    /// have this. It is what drives builtin-supertype and instance-subtype scoring.
    /// Lowering: null. Runtime: Instance class name / simpleName(typeFqn()). Eager: null.
    runtime_class: ?[]const u8 = null,

    /// Literal-kind classification for an AST literal argument.
    /// Lowering: argLitKind() (numeric/string/boolean/char), null otherwise.
    /// Runtime: null (has a concrete Value, uses runtime_class/ty instead).
    /// Eager:   optionally set for literals to match the conservative literal-vs-builtin gate.
    literal_kind: ?LiteralKind = null,

    /// Runtime Value pointer, opaque to applicability.zig, passed straight through
    /// to the tri-state refinement callbacks (valueMatches / refineByDeclaredArgs).
    /// Only the runtime callers populate it; the scorer treats it as a token.
    value: ?*const anyopaque = null,
};
```

Field justification, by which caller populates and which leaves null:

| field | lowering | runtime global | runtime member | eager |
|---|---|---|---|---|
| `ty` | null (no lowered TypeRef) | null (value, not type) | receiver slot only | set (checked Type) |
| `is_lambda` | AST Lambda/AnonFun | callable Value | callable Value | AST lambda |
| `lambda_arity` | `trailingLambdaArity()` | `closures[id].n_params` | `closures[id].n_params` | literal param count |
| `lambda_param_types` | null | resolved closure params | resolved closure params | annotated params |
| `named` | `call.arg_names[i]` | `Call.arg_names[i]` | `Call.arg_names[i]` | `arg_names[i]` |
| `is_spread` | AST Spread | call spread flag | call spread flag | AST Spread |
| `runtime_class` | null | Value class name | Value class name | null |
| `literal_kind` | `argLitKind()` | null | null | optional |
| `value` | null | `&Value` | `&Value` | null |

The design rule: a field is present iff the caller can prove it *cheaply and soundly* at
its phase. `applicable()` never faults on a null field — a null means "this caller could
not prove anything here," which downgrades that arg's contribution from *proven* to
*unknown* (never to *disproven*). This is what lets one function serve a phase that knows
only literal kinds (lowering), one that knows runtime classes (runtime), and one that
knows checked types (eager), with identical control flow.

### How each caller builds an `ArgShape`

**Lowering caller (partial type info)** — `lowerPathCall` (`expr.zig:4021`) walks the
AST `args` before any lowered TypeRef exists:

```zig
fn shapeOfAstArg(b: *FuncBuilder, arg: *const Expr, name: ?[]const u8) ArgShape {
    return .{
        .named = name,                                   // call.arg_names[i]
        .is_spread = arg.* == .Spread,
        .is_lambda = arg.* == .Lambda or arg.* == .AnonFun,
        .lambda_arity = trailingLambdaArity(arg),        // expr.zig:2332
        .literal_kind = argLitKind(arg),                 // expr.zig:3809
        // ty / runtime_class / lambda_param_types / value stay null:
        //   no lowered TypeRef, no runtime value, unannotated lambda params.
    };
}
```

**Runtime callers (Value class)** — `pickOverload` (`host_call_func.zig:649`) and
`pickMethodOverload` (`host_call_member.zig:1990`) walk the `[]const Value` args:

```zig
fn shapeOfValue(self: *VmHost, v: *const Value, name: ?[]const u8, spread: bool) ArgShape {
    return .{
        .named = name,
        .is_spread = spread,
        .runtime_class = runtimeHead(v),                 // overload_match.zig:251
        .is_lambda = valueIsCallable(v),
        .lambda_arity = callableArity(self, v),          // closures[id].n_params etc.
        .lambda_param_types = closureParamTypes(self, v),// null when unannotated
        .value = @ptrCast(v),                            // opaque token for refinement
        // ty stays null for value args; only the member receiver slot sets ty
        // (to the declared receiver TypeRef) so the receiver-specificity tier keys on it.
        .literal_kind = null,
    };
}
```

**Eager caller (checked Type)** — `checkOverloadedCall` (`expr_calls.zig:500`) has each
arg's checked `Type` and the AST literal:

```zig
fn shapeOfChecked(c: *Checker, arg: *const Expr, t: Type, name: ?[]const u8) ArgShape {
    return .{
        .named = name,
        .is_spread = arg.* == .Spread,
        .ty = t.asTypeRef(),                             // checked Type → TypeRef view
        .is_lambda = arg.* == .Lambda,
        .lambda_arity = lambdaLiteralArity(arg),         // null when body deferred
        .lambda_param_types = lambdaAnnotatedParams(arg),
        .literal_kind = argLitKind(arg),                 // keep the conservative gate parity
        // runtime_class / value stay null: no runtime value at check time.
    };
}
```

The three builders are the *only* per-caller code that has to understand its own phase;
everything downstream is shared.

---

## 2. The `Score` type + `applicable()` signature

```zig
// src/ir/applicability.zig

/// A ranked applicability verdict. `null` from `applicable()` == inapplicable
/// (a DEFINITE mismatch: wrong arity that no default/vararg fixes, a named arg
/// that no parameter accepts, or a per-arg DISPROVEN type). Never returned for
/// mere lack of information — unknown args still yield a Score.
pub const Score = struct {
    /// Sum of per-arg points. Proven-exact head = 100, numeric widen 40/30,
    /// callable-arity 90, builtin-super 75-dist, subtype 60/75-dist, Any 10,
    /// SAM 8, type-param 5, Unit 1. Unknown args contribute their base with a
    /// +0 refinement delta; proven refinement adds +6, disproven → null.
    points: i32,

    /// Count of args scored from PROVEN evidence (ty/runtime_class present and
    /// matched) vs UNKNOWN (field null / only literal_kind). Used only as a
    /// secondary tiebreak so a caller with more evidence never loses to noise.
    proven_args: u16,
    unknown_args: u16,

    /// Mirrors the two exact-arity adjustments already in the scorers:
    ///   member exact-arity bonus (+5, host_call_member.zig:2159),
    ///   global under-application penalty (-1 when defaults are used, :582).
    /// Encoded once here so both callers agree.
    exact_arity: bool,

    /// The candidate is `@LowPriorityInOverloadResolution` / HIDDEN.
    /// Global path drops it at declaration level; member path applies -1000
    /// (host_call_member.zig:2163). Carried, not pre-applied, so each caller
    /// keeps its own convention.
    low_priority: bool,

    /// True when this candidate is a member (implicit-receiver) rather than an
    /// extension/top-level. Lets the caller resolve member-vs-extension ties in
    /// the one place they already do (resolveInstanceMethod before ext fallback).
    is_member: bool,

    /// Extension-only lexicographic ranking tuple, populated ONLY when
    /// scope.rank_extensions is set. Mirrors ExtKey exactly
    /// (host_call_member.zig:6750): { applicable, is_user, spec, recv_match,
    /// score, owner_rank, param_spec, neg_fid }. null for non-extension scoring.
    ext_key: ?[8]i32 = null,

    /// P2 binding side-channel the caller consumes verbatim: which param each
    /// arg bound to (named/default/vararg/trailing-lambda folded in one place).
    binding: Binding,
};

/// Where each supplied arg landed, plus which params take defaults / vararg
/// packing bounds. This is the single materialization of the binding rules the
/// runtime P2 path (callFuncNamed) and the eager path currently each redo.
pub const Binding = struct {
    arg_to_param: []const u16,      // supplied-arg index -> param index
    default_params: []const u16,    // params filled from the default thunk table
    vararg_param: ?u16,             // param that packs the spread/trailing positional run
    vararg_lo: u16, vararg_hi: u16, // [lo,hi) supplied-arg range packed into the vararg
    trailing_lambda_param: ?u16,    // last function-typed param bound out of sequence
};

pub const ApplicabilityScope = struct {
    receiver: ?ArgShape = null,        // implicit `this` (member) — skipped before value scoring
    static_recv: ?[]const u8 = null,   // declared static receiver head (extension applicability)
    is_extension: bool = false,
    rank_extensions: bool = false,     // build ext_key, compare lexicographically
    all_candidates: ?[]const DeclSig = null, // for `spec` (supertype-specificity count)
    enclosing_chain: ?[]const []const u8 = null, // owner-rank source
    check_low_priority: bool = false,  // strict-drop vs lenient -1000
    // Callbacks injected by the runtime callers; null for lowering/eager.
    refine: ?*const fn (*const TypeRef, *const anyopaque) ?i32 = null, // refineByDeclaredArgs
    subtype: ?*const fn ([]const u8, []const u8) ?i32 = null,         // instance-subtype distance
};

/// One candidate against the actual args. `sig` is the unified per-FuncId
/// signature (DeclSig; §4 of the P1 map). Returns null = definite mismatch.
pub fn applicable(
    sig: *const DeclSig,
    args: []const ArgShape,
    scope: ApplicabilityScope,
) ?Score;
```

`applicable()` folds ALL of the following in one place — this is the whole point:

1. **Named-arg → distinct param.** Every `args[i].named` must map to a distinct
   `sig.param_names` slot; a name matching no param → `null` (mirrors the eager filter at
   `expr_calls.zig:526-541` and the runtime `scoreNamedCandidate` mapping). Distinctness
   (no two named args to the same param) is enforced here so no caller re-checks it.

2. **Default padding.** After positional + named binding, any unfilled param must be a
   default (`sig.has_default`) or a vararg, else `null` (mirrors `overloadScore:568-580`,
   `pickMethodOverload:2134-2145`). Filled slots go to `Binding.default_params`.

3. **Vararg packing at ANY position.** A vararg param (final or non-final) consumes the
   contiguous positional run that no named/default claims; prefix and post-vararg params
   must be reachable positionally or defaulted (mirrors the non-final-vararg block
   `pickMethodOverload:2010-2041` and `hasNonFinalVararg` `host_call_func.zig:83`). A
   `*spread` arg (`is_spread`) binds one-to-one to the vararg slot. Result recorded in
   `Binding.vararg_param/vararg_lo/vararg_hi`.

4. **Trailing-lambda out-of-sequence.** When the last arg `is_lambda` and
   `args.len < effective_params`, it binds to the LAST function-typed param, and the gap
   between the last positional and that param must be all-defaulted (mirrors
   `overloadScore:538-566`, `pickMethodOverload:2078-2130`, and `trailingLambdaParamIdx`
   `expr_calls.zig:1258`). Recorded in `Binding.trailing_lambda_param`.

5. **Per-arg type scoring.** For each bound (arg, param) pair, `scoreArg(param_ty, arg,
   scope)` returns the point value or `null`. It uses whichever of `arg.ty`,
   `arg.runtime_class`, `arg.literal_kind`, `arg.lambda_arity` is present, and calls
   `scope.refine` / `scope.subtype` when the runtime caller supplied them. A `null` from
   any bound pair makes the whole candidate `null`. This is the merge of the two
   `overloadScoreArg` bodies (`host_call_func.zig:389`, `host_call_member.zig:1626`) and
   the eager `atLeastAsApplicable` per-param rules (`helpers.zig:697`).

6. **Merged builtin-assignability relation** (§3) — the single table both
   `builtinSupersFor` and `builtinSupers` and `builtinHeadAccepts` collapse into, consulted
   once inside `scoreArg`.

Ranking is the tuple `(low_priority desc-drop, ext_key?, points, proven_args,
!uses_defaults)` — but `applicable()` returns the Score for ONE candidate; the caller's
existing max-scan (`pickOverload:661-669`, `pickMethodOverload:2165-2172`, `pickMsc`) does
the cross-candidate selection using these fields. That keeps `applicable()` pure and
per-candidate, exactly matching all three current shapes.

---

## 3. The single builtin-assignability relation

Replaces `builtinSupersFor` (`host_call_func.zig:511`), `builtinSupers`
(`host_call_member.zig:1741`), and `builtinHeadAccepts` (`overload_match.zig:267`) with one
canonical UNION table. It maps a concrete runtime/value head to the ordered list of
nominal supertypes it satisfies; distance in the list is the scoring position. Callers keep
their own formula (`75 - dist`, `90 - dist`, or bool membership).

```zig
// src/ir/applicability.zig
pub fn builtinSupersOf(concrete: []const u8) []const []const u8 {
    const eq = std.mem.eql;
    const s = simpleName(concrete);
    if (eq(u8, s, "List"))
        return &.{ "Collection", "Iterable", "MutableList", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "MutableList"))
        return &.{ "List", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "Collection"))                       // present only in member table today
        return &.{ "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "Set"))
        return &.{ "Collection", "Iterable", "MutableSet", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "MutableSet"))
        return &.{ "Set", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "Map"))    return &.{"MutableMap"};
    if (eq(u8, s, "MutableMap")) return &.{"Map"};
    if (eq(u8, s, "IntRange"))                          // absent from builtinHeadAccepts today
        return &.{ "IntProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, s, "LongRange"))
        return &.{ "LongProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, s, "CharRange"))
        return &.{ "CharProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, s, "IntProgression") or eq(u8, s, "LongProgression") or eq(u8, s, "CharProgression"))
        return &.{"Iterable"};
    if (eq(u8, s, "String"))
        return &.{ "CharSequence", "Comparable" };
    if (eq(u8, s, "StringBuilder"))                     // present in the member table's tail only
        return &.{ "CharSequence", "Appendable" };
    return &.{};
}
```

The union is intentional and behavior-*additive*: the `Collection`, `StringBuilder`, and
`Range/Progression` rows that were missing from one or another of the three tables are the
documented silent bugs in the tables map. Because they only *add* accepted supertypes (a
previously-`null` arg becomes a positive score), no previously-selected overload can lose —
the migration audit (§5) will flag any candidate that newly becomes applicable so we can
confirm each is a genuine Kotlin-legal widening before it goes live.

---

## 4. Per-caller adapter plan

Each caller keeps its emission / binding / diagnostic responsibilities and only routes its
per-candidate scoring through `applicable()`. What each must preserve byte-for-byte:

### 4a. Lowering `resolveCall` (`lowerPathCall`, `expr.zig:4021-4108`)

- Builds `ArgShape` via `shapeOfAstArg` (§1). Scope: `is_extension` from candidate,
  `static_recv = b.recvTy()`, `refine/subtype = null` (no runtime value at lower time).
- The heuristic ladder rungs (`cast`, `non_ext_arity`, `ext_arity`, `*_tl`,
  `fallbackByDeclArity`) become thin wrappers that ask `applicable()` for a Score and keep
  the *rung order* as the tiebreak — `applicable()` supplies arity/named/vararg/trailing-
  lambda folding; the rung enum still names which class of match won, because the
  `KLIO_RESOLVE_AUDIT` records key on it (`expr.zig:4109,4398`).
- **Must not change:**
  - **exact-cast bypass:** `overloadPickByCast` (`expr.zig:169`) still runs first and, when
    it picks, the lowered `Call.exact=true` is emitted (emit site `expr.zig:5776-5790`) and
    the `cast_disambiguated` reclassification at `4102-4106` is preserved. `applicable()`
    does not see casts; the cast rung stays caller-side and simply short-circuits.
  - **prefer_member interplay:** `prefer_member` (`expr.zig:4028-4030`) still gates whether
    the ladder runs at all (`4036`). `applicable()` is only consulted for the candidate
    set; the member-vs-global routing decision stays with the caller (and its P1/P4 owner).
  - The post-heuristic `resolveBareCallIndexed` (`ir.zig:1705`) still runs and still wins;
    `applicable()` feeds only the heuristic fallback, so a name the index resolves is
    unaffected.

### 4b. Runtime global `pickOverload` (`host_call_func.zig:649-671`)

- Builds `ArgShape` via `shapeOfValue`; scope `refine = refineByDeclaredArgs`, `subtype =
  instanceSubtypeDistance`, `check_low_priority = false` (global drops low-priority at the
  declaration/index level, not in the scorer).
- Replaces the `overloadScore`/`overloadScoreArg` body (`529-589`, `389-507`) with a call to
  `applicable()`; `pickOverload`'s max-scan and order-preserving tiebreak (`661-669`) is
  unchanged.
- **Must not change:**
  - **exact bypass:** `callFuncTyped` still short-circuits `if (exact) func else
    pickOverloadCached(...)` (`host_call_func.zig:1278-1280`); `applicable()` is never
    reached for an `exact` call.
  - **`pickOverloadCached` memo:** the `(module_p, func_p, primitive_sig)` cache
    (`636-647`) still wraps `pickOverload`; `applicable()` must be a pure function of
    `(sig, args, scope)` so the memo stays sound (no invalidation exists).
  - **`TailCallFunc`:** still binds `funcById(tc.func)` directly with NO re-resolution
    (`eval.zig:2089-2104`); `applicable()` is not on the tail-call path and must not become
    a dependency of it.
  - Under-application penalty `-1` (`overloadScore:582`) is reproduced by `Score.exact_arity`
    → caller applies `if (!exact_arity) score -= 1` exactly as today, or reads it from the
    encoded `points` (the folded convention keeps the arithmetic identical).

### 4c. Runtime member `pickMethodOverload` / `pickMethodOverload`+`scoreExtCandidates`
(`host_call_member.zig:1990-2182`, `6666-6771`)

- Builds `ArgShape` for value args plus a receiver `ArgShape` (with `ty` = declared receiver
  TypeRef) placed in `scope.receiver`. `applicable()` skips the receiver slot before value
  scoring (the `skip=1` when `params[0].name=="this"` logic, `2002`).
- For extension ranking, sets `scope.rank_extensions = true`, `scope.all_candidates`,
  `scope.enclosing_chain`; `applicable()` fills `Score.ext_key` and the caller's
  `extKeyGreater` (`6659`) lexicographic compare is unchanged.
- **Must not change:**
  - **exact-arity bonus `+5`** (`2159`) → `Score.exact_arity`; **low-priority penalty
    `-1000`** (`2163`) → `Score.low_priority` with `check_low_priority` lenient mode. The
    caller applies both exactly as today so tie-tracking (`tied`, `checkOverloadUnique`
    `2164-2177`) is bit-identical.
  - **`callableArgPrefersFunctionExtension`** filter (`5571`) and the
    `isDefinitelyNonFunctionTypeName` disqualification (`1675`) stay caller-side: they gate
    whether a member candidate is offered to `applicable()` at all, preventing the lambda→
    generic-member bind that caused the `removeAll` infinite recursion.
  - **static-receiver applicability** (`staticReceiverApplicable` `1013`,
    `extReceiverSpecificity` `898`) feeds `scope.static_recv` / the `recv_match` tier of
    `ext_key`; the strict/lenient extension filtering in `extensionFnFallback`
    (`6372-6588`) is preserved around the `applicable()` call.
  - **`resolveInstanceMethod`** hierarchy BFS (`5607`) still walks the supertype chain and
    calls `applicable()` per level, skipping low-priority to fall through to extensions —
    the walk order is unchanged.

### 4d. Eager `checkOverloadedCall` (`expr_calls.zig:500-819`)

- Builds `ArgShape` via `shapeOfChecked` (§1), always with `ty` set. Scope has no
  `refine/subtype` callbacks (no runtime values); scoring uses `ty` + `literal_kind`.
- The MSC frontier (`pickMsc` `helpers.zig:734`) is a pairwise-dominance selection, not a
  point-sum. Adapter: `applicable()` first acts as the *fitting filter* (returns `null` for
  a non-fitting candidate, replacing the per-arg `isSubtypeOf` fit test), and its `Binding`
  supplies the named/default/vararg mapping the eager path currently open-codes. `pickMsc`
  then runs `atLeastAsApplicable` (`697`) over the surviving fitting set — that pairwise
  routine stays, because MSC dominance is a distinct relation from the point score. So for
  eager, `applicable()` owns *applicability + binding*, and `pickMsc` retains *specificity*.
- **Must not change:** the named-filter T0089/T0092 diagnostics (`543-579`), the
  crossinline check (`checkCrossinlineArgReturns` `513`), and the MSC tiebreakers
  (non-param > param, fewer defaults, no-vararg > vararg; `helpers.zig:761-790`). These stay
  in the caller; `applicable()` only removes the duplicated binding/fit arithmetic.

---

## 5. Migration order (keep canonical `stdlib_commontest` from dropping)

Canonical baseline is `zig build itest-stdlib_commontest` (currently ~2000 passing). The
migration switches ONE caller at a time behind the existing `KLIO_RESOLVE_AUDIT` machinery
(compile half `expr.zig:3417,4384-4109`; extend it with a runtime half for the scorers), and
proves zero disagreement before flipping the next.

**Switch order (least-blast-radius first):**

1. **Runtime global `pickOverload`** first. It has the cleanest interface (pure
   `Value`→score, memoized separately) and no receiver/extension tiers. Add
   `applicable()`, gate it behind `KLIO_RESOLVE_AUDIT`: when the env var is set, compute
   BOTH the legacy `overloadScore` and the new `applicable()` for every candidate and log
   any disagreement (chosen FuncId, per-arg points). Run the full canonical + `zig build
   test` with the audit on; require zero divergence lines. Then make `applicable()` the
   live path and delete the legacy body.
2. **Runtime member `pickMethodOverload` + `scoreExtCandidates`** second, same
   dual-compute audit, including `ext_key` equality. This is where the `+5`/`-1000`/tier
   conventions live, so the audit must compare the full `ExtKey`, not just the winner.
3. **Eager `checkOverloadedCall`** third — audit compares the *fitting set* and the
   *binding*, not the MSC winner (MSC stays). Zero divergence in the fitting/binding proves
   the shared binder matches the eager binder.
4. **Lowering ladder** last — highest blast radius (it decides emission tier). Audit
   compares the per-rung Score against the legacy rung pick; the `resolveBareCallIndexed`
   path is untouched, so only the fallback heuristic is under test.

**Proving zero-disagreement at each step:** the audit dual-computes and emits a
`[KLIO_RESOLVE_AUDIT] divergent=1` line (same format as `expr.zig:3582`) whenever legacy and
`applicable()` disagree on the chosen candidate OR the binding. Green = no divergent line
across canonical + `zig build test`. The builtin-table union (§3) is the one place a
divergence is *expected and allowed*: an arg that was `null` under the narrower table
becomes positive; each such line is hand-verified as a legal Kotlin widening, then the
legacy table row is deleted.

**What P1 currently regresses, and which P2 fixes:**

- **ResultTest (member-vs-global).** P1's index-completion timing flips some bare calls in
  class bodies from member dispatch to a resolved global. P2 fixes this: `applicable()`
  scores the member candidate and the global candidate on the *same* `ArgShape`s, and the
  member `Score.is_member` + receiver-slot skip lets `resolveInstanceMethod` prefer the
  applicable member before the global — the two are no longer decided by two divergent
  scorers. **Fixed by P2** (unifies the member and global scoring so the tie is resolved by
  one relation, not by emission timing).
- **FloorDivModTest (`remAssign`/`%=` + overload).** The augmented-assignment `%=` desugars
  to a `rem`/`remAssign` overload pick that today runs through the member scorer while the
  operand-type widening (`Int`→`Long`) runs through the global scorer's numeric rules. P2
  fixes this: the numeric-widen rules (40/30) and the merged builtin relation live in ONE
  `scoreArg`, so `remAssign(Long)` vs `rem(Int)` resolves consistently regardless of which
  caller (compound-assign lowering vs member dispatch) reaches it. **Fixed by P2.**
- **DeepRecursiveTest.** Regresses on `TailCallFunc`: P1 shifts a call to the exact tier,
  and the tail-call handler (`eval.zig:2089`) does NO re-resolution. P2's guarantee that
  `applicable()` is a *pure per-candidate* function and is *not* consulted on the tail-call
  path (§4b) means the exact-tier target baked at lower time is the same one the scorer
  would pick — so raising the call to exact is provably safe. **Fixed by P2** (removes the
  scorer/lowering disagreement that made the exact bake wrong).
- **TestTimeSourceTest.** Regresses on a value-class / inline-member overload where the
  member table's missing `Collection`/`StringBuilder`/range rows (§3) caused a `null` score
  and the wrong sibling to win. The merged builtin-assignability relation (§3) restores the
  missing rows, so the intended overload scores positive. **Fixed by P2** (the table union
  is the direct fix).

All four are disagreements between two independently-drifted scorers or between a scorer and
the lowering/tail-call path; unifying on one `applicable()` is what removes the drift. Any
that remain red after step 4 indicate a genuine binding-rule bug that the audit will have
localized to a specific `[KLIO_RESOLVE_AUDIT] divergent=1` line.

---

## 6. Concrete first implementation slice (additive, behavior-neutral)

The first landable slice creates the shared module and switches exactly ONE scorer behind
the audit, with the legacy path still authoritative until proven. Nothing observable changes
until the audit is clean.

**Step 1 — add `src/ir/applicability.zig`, wire into `build.zig` `mod_list`.** Contents:
`ArgShape`, `LiteralKind`, `Score`, `Binding`, `ApplicabilityScope`, `builtinSupersOf`
(§3, the union table), and `applicable()`. Implement `applicable()` by *lifting* the
existing global `overloadScore` + `overloadScoreArg` logic verbatim (arity/default/vararg/
trailing-lambda gates from `host_call_func.zig:529-589`, per-arg points from `389-507`),
reading from `ArgShape` fields instead of `*const Value` and calling `scope.refine` /
`scope.subtype` for the runtime deltas. No other module imports it yet → the build is green
and behavior is byte-identical (dead code).

**Step 2 — add the `shapeOfValue` builder + a dual-compute audit in `pickOverload`
(`host_call_func.zig:649`).** When `KLIO_RESOLVE_AUDIT` is set, for each candidate compute
both `overloadScore(...)` (legacy) and `applicable(&declSigOf(cand), shapes, scope)` (new),
and emit a `[KLIO_RESOLVE_AUDIT] divergent=1` line on any mismatch of winner or points. The
LIVE selection still uses the legacy `overloadScore`. This is purely additive: with the env
var unset there is zero overhead and zero behavior change.

**Step 3 — verify.** Run `zig build test` (unit) and
`KLIO_RESOLVE_AUDIT=1 zig build itest-stdlib_commontest` (canonical). Require: canonical
count unchanged at baseline, and zero `divergent=1` lines except the intended §3 table-union
widenings (each hand-checked). This proves `applicable()` reproduces the global scorer
exactly before it becomes authoritative.

**Step 4 — flip the global scorer live.** Replace the `overloadScore` call in `pickOverload`
with `applicable()`, delete the now-dead `overloadScore`/`overloadScoreArg`/`builtinSupersFor`
in `host_call_func.zig`. Re-run canonical: must stay at baseline. `pickOverloadCached`
(`636-647`), the `exact` bypass (`1278-1280`), and `TailCallFunc` (`eval.zig:2089`) are
untouched — the slice is confined to the one scorer.

This slice is safe to commit at Step 1 (dead code, green), again at Step 3 (audit clean,
still legacy-authoritative), and again at Step 4 (one scorer flipped, canonical held). Each
commit is independently green, and the remaining three callers (§5 steps 2-4) follow the
identical add-audit-verify-flip pattern against the same `applicable()`.
