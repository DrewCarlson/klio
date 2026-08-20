//! Shared overload-resolution applicability engine.
//!
//! One `applicable()` function scores a single candidate signature against a
//! list of actual arguments described by `ArgShape`. Each caller (lowering
//! ladder, runtime global/member scorers, eager typeck) populates the
//! `ArgShape` fields it can prove at its phase and leaves the rest null; the
//! scorer folds arity / default / vararg / trailing-lambda binding and the
//! per-argument point values in one place.
//!
//! The scoring constants and special cases are the canonical rules consumed by
//! lowering, eager type checking, and runtime binding. The runtime deltas that
//! depend on a live value (declared-generic-argument / function-shape
//! refinement and instance subtype distance) are supplied through
//! `ApplicabilityScope`; when a callback is null, the evidence is UNKNOWN and
//! never disproves a candidate.

const std = @import("std");

const ir = @import("ir");
const span_mod = @import("span");

const TypeRef = ir.TypeRef;
const Param = ir.Param;
const FuncId = ir.FuncId;

// -------------------------------------------------------------------------
// Input shape.
// -------------------------------------------------------------------------

pub const LiteralKind = enum { numeric, string, boolean, char };

/// Everything a caller can know about one actual argument at overload-pick
/// time. A plain value struct: it borrows, never allocates. A field left null
/// means "this caller could not prove anything here" and downgrades that
/// argument from proven to unknown (never to disproven).
pub const ArgShape = struct {
    /// Declared / checked static type, when the caller has one (eager typeck,
    /// and the synthesized member-receiver slot). Runtime value args leave it
    /// null and score off `runtime_class`.
    ty: ?TypeRef = null,

    /// `ty` came from source syntax or declaration metadata rather than the
    /// additive eager type-head channel. Static resolution may reject a
    /// candidate only from authoritative evidence.
    ty_authoritative: bool = true,

    /// The argument is callable per `valueIsCallable`
    /// (IrClosure/Function/Intrinsic/BoundMethod/PropertyRef) — drives the
    /// trailing-lambda binding gate.
    is_lambda: bool = false,

    /// Declared arg arity when the callable is an IrClosure / Function / class
    /// ctor ref (the legacy `arg_arity` switch: IrClosure -> n_params, Function
    /// -> params.len, Class -> 0); null otherwise. Feeds the FunctionN score.
    lambda_arity: ?u8 = null,

    /// The value's runtime typeFqn starts with "kotlin.Function"
    /// (Function/IrClosure/Intrinsic/BoundMethod/BoundUserMethod). Part of the
    /// per-arg callable gate for callables that carry no `lambda_arity`.
    func_typed: bool = false,

    /// The argument is a LAMBDA LITERAL at the call site (AST-time shape),
    /// so `lambda_arity` is the literal's declared header count — reliable
    /// for exact-arity overload ranking. Runtime closure shapes leave this
    /// false: their `n_params` includes lowering-added params (receiver,
    /// continuation, composer pair), where only the `want`/`want+1` parity
    /// is sound.
    lambda_is_literal: bool = false,

    /// Declared lambda parameter types when the caller can see them. Unused by
    /// the runtime path (the refine callback re-derives them from the value);
    /// carried for the eager caller of a later step.
    lambda_param_types: ?[]const TypeRef = null,

    /// Named-argument name for this slot (`x = ...`), else null (positional).
    named: ?[]const u8 = null,

    /// The argument is a spread (`*arr`) feeding a vararg.
    is_spread: bool = false,

    /// The argument value is `Null`. Only the runtime callers set it.
    is_null: bool = false,

    /// Runtime class simple-name of the argument value (the class name for an
    /// Instance, else `simpleName(typeFqn)`). Only the runtime callers set it;
    /// it drives head-match, numeric widening, builtin-supertype and
    /// instance-subtype scoring.
    runtime_class: ?[]const u8 = null,

    /// Literal-kind classification for an AST literal argument (lowering).
    literal_kind: ?LiteralKind = null,

    /// Runtime `*const Value` pointer, opaque here, passed straight through to
    /// the `ApplicabilityScope` refinement callbacks. Only the runtime callers
    /// populate it.
    value: ?*const anyopaque = null,
};

// -------------------------------------------------------------------------
// Output shape.
// -------------------------------------------------------------------------

/// Where each supplied arg landed, plus which params take defaults / vararg
/// packing bounds. Only the scalar trailing-lambda / vararg fields are filled
/// in this slice; the slice fields are materialized by the per-caller adapter
/// steps (which thread a scratch buffer).
pub const Binding = struct {
    arg_to_param: []const u16 = &.{},
    default_params: []const u16 = &.{},
    vararg_param: ?u16 = null,
    vararg_lo: u16 = 0,
    vararg_hi: u16 = 0,
    trailing_lambda_param: ?u16 = null,
};

/// A ranked applicability verdict. `null` from `applicable()` == inapplicable
/// (a definite mismatch: an arity no default / vararg fixes, or a per-arg
/// disproven type). Never returned for mere lack of information.
pub const Score = struct {
    /// Sum of per-arg points, with the legacy conventions folded in: exact-head
    /// 100, numeric widen 40/30, callable-arity 90, builtin-super 75-dist,
    /// subtype 60-dist, Any 10, SAM 8, type-param 5, Unit 1, refinement +delta,
    /// and the -1 under-application penalty when defaults are used.
    points: i32,

    /// Count of args scored from proven (`ty`/`runtime_class` present) vs
    /// unknown evidence. Secondary tiebreak only; the global scanner keys on
    /// `points`.
    proven_args: u16 = 0,
    unknown_args: u16 = 0,

    /// The call supplied exactly one arg per fixed parameter, with neither
    /// defaults nor vararg packing involved.
    exact_arity: bool = false,

    /// The candidate is `@LowPriorityInOverloadResolution` / HIDDEN. Carried,
    /// not pre-applied; each caller keeps its own convention.
    low_priority: bool = false,

    /// True when this candidate is a member rather than an extension/top-level.
    is_member: bool = false,

    /// Extension-only lexicographic ranking tuple, populated only when a later
    /// caller sets extension ranking. null here.
    ext_key: ?[9]i32 = null,

    /// P2 binding side-channel the caller consumes.
    binding: Binding = .{},
};

/// Per-candidate signature view. `DeclSig` does not exist yet; this carries the
/// slices the scorer reads directly off an `ir.Func`.
pub const SigView = struct {
    /// Declared parameters (`ty`, `name`, `is_vararg`).
    params: []const Param,
    /// Default-thunk table for the candidate (`func_defaults`): `defaults[i] !=
    /// null` means param `i` has a default. Null means no defaults at all.
    defaults: ?[]const ?FuncId = null,
    /// The candidate has an IR body (a bodyless expect / native stub is never
    /// selectable).
    has_body: bool = true,
    /// `@LowPriorityInOverloadResolution` / error-level `@Deprecated`.
    low_priority: bool = false,
    /// Member (implicit-receiver) candidate rather than extension/top-level.
    is_member: bool = false,
    /// Extension / member-extension candidate.
    is_extension: bool = false,
    /// The candidate's `FuncId`, used by the extension ranking for the
    /// stable `neg_fid` tiebreak and to skip self in the `spec` count.
    fid: ?FuncId = null,
    /// Declaring package path — feeds the extension ranking's `is_user`
    /// tier (`""` or an unknown package is user code).
    package: []const u8 = "",
};

/// Runtime-value refinement callbacks and phase flags, injected by the caller.
/// The runtime callers pass `ctx = *VmHost` and wrap `refineByDeclaredArgs` /
/// the instance-subtype BFS; lowering / eager leave them null.
pub const ApplicabilityScope = struct {
    is_extension: bool = false,
    check_low_priority: bool = false,

    /// Select the runtime NAMED-ARGUMENT scoring conventions
    /// (`host_call_func.zig` `scoreNamedCandidate`): each arg's `named` binds to
    /// its distinct same-named parameter, positional args fill the rest (a
    /// vararg absorbing the arguments at its position), and every unfilled non-vararg parameter
    /// must be defaultable. Unlike the positional/member scorers, a per-arg type
    /// mismatch is NEUTRAL (scores 0) rather than disqualifying: named-parameter
    /// presence is the hard discriminator, the type score only ranks survivors.
    named: bool = false,

    /// A named call whose site supplies an implicit extension receiver (the
    /// enclosing frame's `this`) that is not among the args: the candidate's
    /// leading `this` parameter is receiver-filled rather than arg-bound.
    recv_external: bool = false,

    /// Optional caller-provided scratch for the named path's `Binding.arg_to_param`
    /// (which parameter each supplied arg bound to). Left null when the caller
    /// does not need the binding; when set, `applicable()` writes through it and
    /// points `Binding.arg_to_param` at the filled prefix.
    arg_to_param_buf: ?[]u16 = null,

    /// Select the runtime *member* per-arg + candidate scoring conventions
    /// (`host_call_member.zig`): no `$bound_ref$` callable head, a
    /// `Function`-parse failure scores 20 (not 8), a callable against a
    /// definitely-non-function concrete param disqualifies, the instance
    /// subtype tier scores `75 - min(depth, 20)` (not `60 - min(depth, 50)`),
    /// a short all-upper-or-digit head is a type parameter, the base score is
    /// 0 (no under-application `-1`), and the receiver slot (`params[0].name ==
    /// "this"`) is skipped before value scoring.
    member: bool = false,

    /// Extension ranking: fill `Score.ext_key` (mirrors `scoreExtCandidates`).
    /// Implies member per-arg scoring; the receiver is `params[0]` and is
    /// scored into the key, value args bind `params[1..]`.
    rank_extensions: bool = false,

    /// Extension receiver value shape (its `runtime_class`/`value` drive
    /// `recv_score`/`recv_match`). Required when `rank_extensions`.
    receiver: ?ArgShape = null,

    /// All candidates in the extension overload set, for the `spec`
    /// (supertype-specificity count) tier. Each entry's `params[0].ty` is the
    /// declared receiver head; `fid` skips the candidate against itself.
    all_candidates: ?[]const SigView = null,

    /// Opaque context (a `*VmHost`) threaded to the callbacks.
    ctx: ?*anyopaque = null,

    /// `refineByDeclaredArgs`: declared-generic / function-shape delta for a
    /// head-accepted (arg, param) pair. Returns the score delta, or null to
    /// disqualify the candidate.
    refine: ?*const fn (*anyopaque, *const TypeRef, *const anyopaque) ?i32 = null,

    /// Instance-subtype distance: the BFS depth from the value's runtime class
    /// to `target` through the class supertype closure, or null when the value
    /// is not an instance or `target` is not reached.
    subtype: ?*const fn (*anyopaque, *const anyopaque, []const u8) ?i32 = null,

    /// Whether a parameter written qualified (`x: a.Box`) and the argument's
    /// runtime class provably denote DIFFERENT registered classes that share a
    /// simple name (a cross-package collision). When true the exact-name tier
    /// is skipped so the sibling overload with the matching class identity
    /// wins. Null callback (lowering / eager) never conflicts.
    identity_conflict: ?*const fn (*anyopaque, *const TypeRef, *const anyopaque) bool = null,

    /// `isFunctionTypeRefResolved`: function-typed param test with typealias
    /// indirection resolved, for the member trailing-lambda gate. Null falls
    /// back to the static `isFunctionTypeRef`.
    func_type: ?*const fn (*anyopaque, *const TypeRef) bool = null,

    /// Whether a parameter type is a TYPE VARIABLE in scope for candidate
    /// `fid` — one of its own type parameters, or its owning class's. The
    /// complete `TypeRef` keeps a qualified nominal type from being
    /// reinterpreted as a same-named type variable.
    type_var: ?*const fn (*anyopaque, FuncId, *const TypeRef) bool = null,

    /// Precise runtime equivalence for alternate spellings of the same class
    /// head, such as a source `Modifier.Node` parameter and its lifted
    /// `Modifier$Node` runtime class. This callback must not use a
    /// simple-name fallback: distinct same-named classes remain distinct.
    exact_head: ?*const fn (*anyopaque, []const u8, []const u8) bool = null,

    /// Runtime member/global dispatch has erased the compile-time distinction
    /// between a constant narrowed to Byte/Short and an Int value. Those paths
    /// may retain the existing same-signedness width accommodation; factory
    /// and constructor binding leave this false so an Int variable cannot bind
    /// a Byte/Short parameter.
    erased_integer_widths: bool = false,

    /// `extReceiverSpecificity(receiver, ty_name)`: the extension `recv_match`
    /// tier.
    ext_recv_match: ?*const fn (*anyopaque, *const anyopaque, []const u8) i32 = null,

    /// `isSubtypeName(a, b)`: whether receiver head `a` is a proper subtype of
    /// `b`, for the extension `spec` tier.
    ext_is_subtype_name: ?*const fn (*anyopaque, []const u8, []const u8) bool = null,

    /// Owner rank for a member-extension nearer on the enclosing-`this` chain.
    ext_owner_rank: ?*const fn (*anyopaque, FuncId) i32 = null,

    /// `stdlib.isKnownPackage(package)`: a shipped/pack namesake; the negation
    /// (plus the empty package) is the extension `is_user` tier.
    ext_known_package: ?*const fn ([]const u8) bool = null,
};

// -------------------------------------------------------------------------
// The merged builtin-assignability relation (design §3, the UNION table).
// -------------------------------------------------------------------------

/// Map a concrete runtime/value head to the ordered list of nominal supertypes
/// it satisfies; the list position is the scoring distance. The union of the
/// three previously-divergent tables (`builtinSupersFor`, `builtinSupers`,
/// `builtinHeadAccepts`) — the `Collection`, `StringBuilder` and range rows
/// missing from one or another are added back here.
pub fn builtinSupersOf(concrete: []const u8) []const []const u8 {
    const eq = std.mem.eql;
    const s = simpleName(concrete);
    if (eq(u8, s, "List"))
        return &.{ "Collection", "Iterable", "MutableList", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "MutableList"))
        return &.{ "List", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "Collection"))
        return &.{ "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "Set"))
        return &.{ "Collection", "Iterable", "MutableSet", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "MutableSet"))
        return &.{ "Set", "Collection", "Iterable", "MutableCollection", "MutableIterable" };
    if (eq(u8, s, "Map")) return &.{"MutableMap"};
    if (eq(u8, s, "MutableMap")) return &.{"Map"};
    if (eq(u8, s, "IntRange"))
        return &.{ "IntProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, s, "LongRange"))
        return &.{ "LongProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, s, "CharRange"))
        return &.{ "CharProgression", "ClosedRange", "Iterable", "OpenEndRange" };
    if (eq(u8, s, "IntProgression") or eq(u8, s, "LongProgression") or eq(u8, s, "CharProgression"))
        return &.{"Iterable"};
    if (eq(u8, s, "String"))
        return &.{ "CharSequence", "Comparable" };
    if (eq(u8, s, "StringBuilder"))
        return &.{ "CharSequence", "Appendable" };
    return &.{};
}

// -------------------------------------------------------------------------
// Small helpers (ported from the global scorer verbatim).
// -------------------------------------------------------------------------

pub fn simpleName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Synthetic suffix the `@Composable` lowering plugin appends to a defaulted
/// parameter it moves into the body prologue (`p: T = D` becomes `p$arg: T =
/// marker()`). A source-level named argument still names the ORIGINAL `p`, so
/// binding a named call against the transformed signature must treat `p` and
/// `p$arg` as the same parameter. `$` cannot begin a source identifier, so this
/// never collides with a real parameter name.
pub const composable_arg_suffix = "$arg";

/// Whether a caller's named-argument label `arg_name` designates the parameter
/// declared as `param_name` — the identity match, or the compose-plugin's
/// defaulted-parameter rename (`param_name == arg_name ++ "$arg"`).
pub fn paramNameMatchesArg(param_name: []const u8, arg_name: []const u8) bool {
    if (std.mem.eql(u8, param_name, arg_name)) return true;
    return arg_name.len != 0 and
        param_name.len == arg_name.len + composable_arg_suffix.len and
        std.mem.startsWith(u8, param_name, arg_name) and
        std.mem.endsWith(u8, param_name, composable_arg_suffix);
}

/// The compose lowering's generated call-site markers. They are appended by the
/// AST pass rather than written in source, so a candidate that does not declare
/// them is simply not a composable target — unlike a genuine source-level named
/// argument, their absence from a signature must not disqualify the candidate.
pub fn isGeneratedComposeArg(name: []const u8) bool {
    return std.mem.eql(u8, name, "$composer") or std.mem.eql(u8, name, "$changed");
}

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// The member scorer's short-type-parameter test allows digits (`T1`, `A2`),
/// unlike the global scorer's `allAsciiUpper`.
fn allUpperOrDigit(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

/// Port of `host_call_member.zig` `isTopOrGenericType`: a maximally-unspecific
/// receiver/param head (`Any`/`Unit`/`FunctionN`/short type parameter). Drives
/// the extension `param_spec` tier.
fn isTopOrGenericType(ty_name: []const u8) bool {
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) return true;
    if (pn.len > 0 and pn.len <= 2 and allUpperOrDigit(pn)) return true;
    return false;
}

/// A concrete builtin a callable argument can never satisfy. User class
/// heads remain eligible for SAM conversion; scalars and containers do not.
fn isDefinitelyNonFunctionTypeName(pn: []const u8) bool {
    const names = [_][]const u8{
        "String",          "CharSequence", "Boolean",     "Char",       "Byte",              "Short",
        "Int",             "Long",         "Float",       "Double",     "UByte",             "UShort",
        "UInt",            "ULong",        "Number",      "Collection", "MutableCollection", "Iterable",
        "MutableIterable", "List",         "MutableList", "Set",        "MutableSet",        "Map",
        "MutableMap",      "Array",        "Sequence",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pn, n)) return true;
    }
    return false;
}

/// Function-typed param test: the caller's typealias-resolving callback when
/// present (member/extension), else the static name check.
fn scopeIsFunctionType(scope: *const ApplicabilityScope, ty: *const TypeRef) bool {
    if (scope.func_type) |cb| return cb(scope.ctx.?, ty);
    return isFunctionTypeRef(ty);
}

fn sameFid(a: ?FuncId, b: ?FuncId) bool {
    const x = a orelse return false;
    const y = b orelse return false;
    return x.int() == y.int();
}

/// A `TypeRef` denoting a Kotlin function type (mirrors `interp_ir.isFunctionType`).
pub fn isFunctionTypeRef(ty: *const TypeRef) bool {
    const n = simpleName(ty.name);
    return std.mem.startsWith(u8, n, "Function") or
        std.mem.indexOf(u8, ty.name, "->") != null;
}

fn paramHasDefault(sig: *const SigView, i: usize) bool {
    // A null `defaults` slice is the lowering adapter (`sigViewForApplicability`):
    // it cannot read the `ProgramImage`-side default-thunk table, so it carries
    // the flag on the params instead. The runtime callers always set a non-null
    // `defaults` and never reach this fallback.
    const defs = sig.defaults orelse
        return i < sig.params.len and sig.params[i].has_default;
    return i < defs.len and defs[i] != null;
}

/// Declared-generic / function-shape refinement delta. Null callback (lowering
/// / eager) contributes no delta and never disqualifies.
fn refineDelta(scope: *const ApplicabilityScope, param_ty: *const TypeRef, arg: *const ArgShape) ?i32 {
    const cb = scope.refine orelse return 0;
    const v = arg.value orelse return 0;
    return cb(scope.ctx.?, param_ty, v);
}

/// Instance-subtype BFS depth to `target`, or null (not an instance / not
/// reached / no callback).
fn subtypeDepth(scope: *const ApplicabilityScope, arg: *const ArgShape, target: []const u8) ?i32 {
    const cb = scope.subtype orelse return null;
    const v = arg.value orelse return null;
    return cb(scope.ctx.?, v, target);
}

/// Whether a qualified parameter type and the argument's runtime class provably
/// denote different registered classes sharing a simple name. False whenever
/// the callback is absent (lowering / eager) or the argument carries no value.
fn scopeIdentityConflict(scope: *const ApplicabilityScope, param_ty: *const TypeRef, arg: *const ArgShape) bool {
    const cb = scope.identity_conflict orelse return false;
    const ctx = scope.ctx orelse return false;
    const v = arg.value orelse return false;
    return cb(ctx, param_ty, v);
}

fn scopeExactHeadMatch(scope: *const ApplicabilityScope, param_head: []const u8, arg_head: []const u8) bool {
    if (std.mem.eql(u8, param_head, arg_head)) return true;
    const cb = scope.exact_head orelse return false;
    const ctx = scope.ctx orelse return false;
    return cb(ctx, param_head, arg_head);
}

/// Value-independent fallback for a caller that could not prove a runtime head
/// (lowering / eager). Never disqualifies (returns a base, never null).
fn unknownArgScore(nm: []const u8) i32 {
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (nm.len <= 2 and allAsciiUpper(nm)) return 5;
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    return 10;
}

/// Declared-type evidence for a (param, arg) pair whose runtime head is
/// unknown: the caller proved the argument's declared static head (a local /
/// parameter with a known declared type). STRICTLY ADDITIVE — a head match
/// earns the head-match score, a type-parameter-typed argument head-matches a
/// type-parameter-typed parameter (`a: T` inside `fun <T : Comparable<T>>`
/// against `minOf(a: T, b: T)`), and anything else returns null so the caller
/// falls back to the unknown base. Declared-type evidence can therefore only
/// ever ADD points for a matching candidate; it never disqualifies one.
/// The bare head for declared-type EVIDENCE comparison: the simple name,
/// with a lift-mangled scope prefix (`Outer$Name`) stripped back to the
/// source simple name — evidence compares what the declaration wrote, and
/// the mangle is a lift-uniqueness artifact, not a different type head.
fn evidenceHead(name: []const u8) []const u8 {
    const sn = std.mem.trimEnd(u8, simpleName(name), "?");
    if (std.mem.lastIndexOfScalar(u8, sn, '$')) |i| {
        if (i + 1 < sn.len) return sn[i + 1 ..];
    }
    return sn;
}

pub fn tyEvidenceScore(param_name: []const u8, arg_ty_name: []const u8, member: bool) ?i32 {
    const pn = evidenceHead(param_name);
    const an = evidenceHead(arg_ty_name);
    if (pn.len == 0 or an.len == 0) return null;
    if (std.mem.eql(u8, pn, an)) return 100;
    const p_tp = pn.len <= 2 and (if (member) allUpperOrDigit(pn) else allAsciiUpper(pn));
    const a_tp = an.len <= 2 and (if (member) allUpperOrDigit(an) else allAsciiUpper(an));
    if (p_tp and a_tp) return 100;
    return null;
}

/// A builtin numeric head (the widths `paramLitKind`-style matching folds
/// together for evidence purposes).
fn isNumericHead(pn: []const u8) bool {
    const names = [_][]const u8{
        "Int",  "Long",  "Short",  "Byte",  "Double", "Float",
        "UInt", "ULong", "UShort", "UByte", "Number",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pn, n)) return true;
    }
    return false;
}

fn signedIntHead(n: []const u8) bool {
    return std.mem.eql(u8, n, "Byte") or std.mem.eql(u8, n, "Short") or
        std.mem.eql(u8, n, "Int") or std.mem.eql(u8, n, "Long");
}

fn unsignedIntHead(n: []const u8) bool {
    return std.mem.eql(u8, n, "UByte") or std.mem.eql(u8, n, "UShort") or
        std.mem.eql(u8, n, "UInt") or std.mem.eql(u8, n, "ULong");
}

/// Two integer heads of the same signedness (both signed or both unsigned),
/// so a runtime value of one may serve a parameter of the other (klio stores
/// all widths uniformly). Excludes cross-signedness (`Int`↛`UByte`) and floats.
fn sameSignednessInt(a: []const u8, b: []const u8) bool {
    return (signedIntHead(a) and signedIntHead(b)) or
        (unsignedIntHead(a) and unsignedIntHead(b));
}

/// Literal-kind evidence for a (param, literal arg) pair: a numeric literal
/// matches any numeric parameter head, a string literal `String` /
/// `CharSequence`, and so on. Null (no conclusion) otherwise — like the
/// declared-type evidence, this only ever adds preference.
fn literalEvidenceScore(param_name: []const u8, kind: LiteralKind) ?i32 {
    const pn = std.mem.trimEnd(u8, simpleName(param_name), "?");
    const hit = switch (kind) {
        .numeric => isNumericHead(pn),
        .string => std.mem.eql(u8, pn, "String") or std.mem.eql(u8, pn, "CharSequence"),
        .boolean => std.mem.eql(u8, pn, "Boolean"),
        .char => std.mem.eql(u8, pn, "Char"),
    };
    return if (hit) 100 else null;
}

/// Lowering-time evidence bonus for ranking same-rung candidates in the
/// bare-call ladder: the sum of per-arg evidence scores — a declared-type
/// head match (100), a declared numeric head against a numeric parameter of
/// another width (80, so an exact head still outranks it), or a literal-kind
/// match (100). Zero whenever no argument carries evidence, so a call with
/// no static facts ranks exactly as before — evidence only ever ADDS
/// preference for a matching candidate, never demotes or disqualifies one.
pub fn tyEvidenceBonus(params: []const Param, args: []const ArgShape) i32 {
    return tyEvidenceBonusScoped(params, args, .{});
}

/// `tyEvidenceBonus` with the caller's scope: the hierarchy oracle lets a
/// declared head that is a SUBTYPE of the parameter head count as evidence
/// (weaker than an exact head match), so two same-arity overloads split on
/// which parameter type the argument's declared class actually reaches.
pub fn tyEvidenceBonusScoped(params: []const Param, args: []const ArgShape, scope: ApplicabilityScope) i32 {
    var total: i32 = 0;
    for (args, 0..) |*a, i| {
        if (i >= params.len) break;
        if (a.runtime_class != null) continue;
        if (a.ty) |aty| {
            if (tyEvidenceScore(params[i].ty.name, aty.name, false)) |s| {
                total += s;
            } else {
                const pn = evidenceHead(params[i].ty.name);
                const an = evidenceHead(aty.name);
                if (isNumericHead(pn) and isNumericHead(an)) {
                    total += 80;
                } else if (scope.ext_is_subtype_name) |cb| {
                    if (an.len != 0 and pn.len != 0 and !std.mem.eql(u8, pn, "Any")) {
                        if (cb(scope.ctx.?, an, pn)) total += 60;
                    }
                }
            }
            continue;
        }
        if (a.literal_kind) |k| {
            if (literalEvidenceScore(params[i].ty.name, k)) |s| total += s;
        }
    }
    return total;
}

// -------------------------------------------------------------------------
// Per-argument scoring.
// -------------------------------------------------------------------------

/// Score one (param, arg) pair. Higher is better; null disqualifies the
/// candidate. Value-dependent deltas are deferred to the scope callbacks.
/// The declared VALUE parameter types of a lowered function type, or null when
/// `ty` is not one. Encoding: `[#suspend?] [receiver?] params… ret [#markers]`.
fn fnTypeValueParamRefs(ty: *const TypeRef) ?[]const TypeRef {
    if (!std.mem.startsWith(u8, ty.name, "Function")) return null;
    const want = std.fmt.parseInt(usize, ty.name["Function".len..], 10) catch return null;
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    if (hi == 0) return null;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    hi -= 1;
    if (hi < lo) return null;
    var params = ty.args[lo..hi];
    if (params.len > want) params = params[params.len - want ..];
    return params;
}

fn builtinScalarHead(h: []const u8) bool {
    const scalars = [_][]const u8{
        "Int",  "Long",  "Short",  "Byte",   "Double",  "Float",
        "UInt", "ULong", "UShort", "UByte",  "Boolean", "Char",
        "String",
    };
    for (scalars) |sc| {
        if (std.mem.eql(u8, h, sc)) return true;
    }
    return false;
}

fn scoreArg(sig: *const SigView, param_ty: *const TypeRef, arg: *const ArgShape, scope: *const ApplicabilityScope) ?i32 {
    const nm = param_ty.name;
    const member = scope.member;
    const shape_callable = arg.lambda_arity != null or arg.func_typed or arg.is_lambda;

    // Runtime head of the argument. A caller that could not prove one
    // (lowering / eager) scores from declared-type evidence when the shape
    // carries it — additive-only, never disqualifying — else as unknown.
    const v_ty = arg.runtime_class orelse blk: {
        // AST lowering has no runtime class for a lambda literal, but its
        // callable shape is already authoritative. Keep it on the callable
        // scoring path instead of returning the generic unknown score.
        if (shape_callable) break :blk "$callable$";
        if (arg.ty) |aty| {
            if (tyEvidenceScore(nm, aty.name, member)) |s| return s;
            // Hierarchy evidence: a declared head that is a SUBTYPE of the
            // parameter head proves the candidate the same way a matching
            // head does (`calculateNodeKindSetFrom(this)` inside
            // DelegatingNode's initializer carries head `DelegatingNode`,
            // which reaches `Modifier.Node` but never `Modifier.Element` —
            // without this the two same-arity overloads tie and the wrong
            // one wins on declaration order).
            if (scope.ext_is_subtype_name) |cb| {
                const ah = evidenceHead(aty.name);
                const ph = evidenceHead(nm);
                if (ah.len != 0 and ph.len != 0 and !std.mem.eql(u8, ph, "Any")) {
                    if (cb(scope.ctx.?, ah, ph)) return 60;
                }
            }
        }
        return unknownArgScore(nm);
    };

    if (scopeExactHeadMatch(scope, nm, v_ty)) {
        // An exact or canonically-equivalent head match is rejected when the
        // parameter and runtime value provably denote different classes.
        if (!scopeIdentityConflict(scope, param_ty, arg)) {
            const d = refineDelta(scope, param_ty, arg) orelse return null;
            return 100 + d;
        }
    }
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.is_null and param_ty.nullable) return 50;

    // Numeric widening: Int -> Long, Int -> Double/Float, Long -> Double.
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;
    // Same-signedness integer cross-width (e.g. Int -> Byte/Short) is
    // applicable at a low score: klio stores every integer width uniformly, and
    // the literal coercion kotlinc validated at compile time is lost by the
    // time a plain runtime value reaches member dispatch — so `append(1)` must
    // still bind `append(byte: Byte)`. Restricted to the same signedness so a
    // signed `Int` does NOT match an unsigned `UByte` param (kotlinc forbids
    // that without `1u`). Below the exact head match (100) and the widen rules
    // above, so an exact numeric overload always wins.
    if (scope.erased_integer_widths and sameSignednessInt(nm, v_ty)) return 20;

    // A callable argument against a function-typed parameter. The member
    // scorer does not treat a `$bound_ref$` head as callable.
    const arg_arity: ?usize = if (arg.lambda_arity) |n| @as(usize, n) else null;
    const is_bound_ref = !member and std.mem.startsWith(u8, v_ty, "$bound_ref$");
    const is_callable = shape_callable or is_bound_ref;
    if (is_callable) {
        // A literal that ANNOTATES its parameters states their types. Refute
        // only on a DEFINITE mismatch — two different builtin scalars — so an
        // unannotated literal, a type parameter or a class type is untouched.
        if (arg.lambda_param_types) |declared| {
            if (fnTypeValueParamRefs(param_ty)) |expected| {
                const n = @min(declared.len, expected.len);
                var di: usize = 0;
                while (di < n) : (di += 1) {
                    const dh = evidenceHead(std.mem.trimEnd(u8, declared[di].name, "?"));
                    const eh = evidenceHead(std.mem.trimEnd(u8, expected[di].name, "?"));
                    if (dh.len == 0 or eh.len == 0) continue;
                    if (std.mem.eql(u8, dh, eh)) continue;
                    if (builtinScalarHead(dh) and builtinScalarHead(eh)) return null;
                    // A builtin scalar against a head that is neither a scalar
                    // nor a one-letter type parameter: androidx's
                    // `element: TestValueClass` against a `Char`.
                    if (builtinScalarHead(eh) and dh.len > 1 and !builtinScalarHead(dh) and
                        !std.mem.eql(u8, dh, "Any") and !std.mem.startsWith(u8, dh, "Function")) return null;
                }
            }
        }
        if (std.mem.startsWith(u8, nm, "Function")) {
            const expected = nm["Function".len..];
            if (std.fmt.parseInt(usize, expected, 10)) |want| {
                if (arg_arity) |got| {
                    // An AUTHORITATIVE arity — a lambda literal's header
                    // count, or a runtime closure whose composer pair was
                    // stripped (the count then IS the transformed
                    // literal's own header) — ranks exactly: an exact
                    // param-count match outranks the adapted shapes,
                    // because same-name overloads often differ only in
                    // their functional param's arity (`movableContentOf`
                    // takes `() -> Unit` … `(P1..P4) -> Unit`) and scoring
                    // `got == want + 1` level with `got == want` tied
                    // every such call onto an arbitrary overload. A
                    // headerless literal serving a 1-param type via
                    // implicit `it` stays applicable just below. Other
                    // runtime closure shapes keep the flat parity — their
                    // param count may include lowering-added params.
                    if (arg.lambda_is_literal) {
                        if (got == want) {
                            const d = refineDelta(scope, param_ty, arg) orelse return null;
                            return 92 + d;
                        }
                        if (got == want + 1 or (got == 0 and want == 1)) {
                            const d = refineDelta(scope, param_ty, arg) orelse return null;
                            return 90 + d;
                        }
                        return 20;
                    }
                    if (got == want or got == want + 1) {
                        const d = refineDelta(scope, param_ty, arg) orelse return null;
                        return 90 + d;
                    }
                    return 20;
                }
                return 20;
            } else |_| {
                // Member: a `Function`-head with no parseable arity scores 20.
                // Global: fall through to the SAM-conversion score below.
                if (member) return 20;
            }
        }
        // A callable can never bind a concrete builtin scalar or container.
        // Unknown user heads remain eligible because they may be fun
        // interfaces and accept SAM conversion.
        if (isDefinitelyNonFunctionTypeName(simpleName(nm))) return null;
        return 8;
    }

    // Subtype: an instance argument whose class transitively extends /
    // implements the parameter's nominal type (distance-weighted). The member
    // scorer scores `75 - min(depth, 20)`; the global scorer `60 - min(depth, 50)`.
    if (subtypeDepth(scope, arg, nm)) |depth| {
        if (member) {
            const d: i32 = if (depth > 20) 20 else depth;
            return 75 - d;
        }
        const d: i32 = if (depth > 50) 50 else depth;
        return 60 - d;
    }

    // Builtin runtime types satisfy their nominal supertypes (§3 union table).
    const builtin_supers = builtinSupersOf(v_ty);
    const nm_simple = simpleName(nm);
    for (builtin_supers, 0..) |sup, pos| {
        if (std.mem.eql(u8, sup, nm) or std.mem.eql(u8, sup, nm_simple)) {
            const dist: i32 = if (pos > 20) 20 else @intCast(pos);
            const d = refineDelta(scope, param_ty, arg) orelse return null;
            return 75 - dist + d;
        }
    }

    // Generic single-letter type-parameter — accept any (member allows digits).
    const short_typaram = if (member) allUpperOrDigit(nm) else allAsciiUpper(nm);
    var qualified_nominal = false;
    for (param_ty.args) |arg_ty| {
        if (std.mem.startsWith(u8, arg_ty.name, "#qual:")) {
            qualified_nominal = true;
            break;
        }
    }
    if (!qualified_nominal and nm.len <= 2 and short_typaram) return 5;
    // Unit param type — accept anything but rank lowest.
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    // A param typed as one of the candidate's in-scope TYPE VARIABLES (its
    // own type parameters, or its owning class's — `put(key: Key)` on
    // `ConcurrentMap<Key, Value>`) accepts anything, exactly like the
    // short-form `T` above — even when an unrelated class shares the
    // variable's name.
    if (scope.type_var) |cb| {
        if (sig.fid) |fid| {
            if (cb(scope.ctx.?, fid, param_ty)) return 5;
        }
    }
    if (scoreTraceOn()) {
        std.debug.print("[score-null] param={s} v_ty={s} arg_ty={s} fid={?d}\n", .{
            nm,
            v_ty,
            if (arg.ty) |t| t.name else "-",
            if (sig.fid) |f| f.int() else null,
        });
    }
    return null;
}

var score_trace_cached: ?bool = null;
fn scoreTraceOn() bool {
    if (score_trace_cached) |b| return b;
    const b = std.c.getenv("KLIO_SCORE_TRACE") != null;
    score_trace_cached = b;
    return b;
}

/// Source position of the extension call currently being scored. DIAGNOSTIC
/// ONLY — never read by scoring, and written only while `KLIO_EXTKEY_TRACE` is
/// set. It lives here rather than on `ApplicabilityScope` because that struct
/// is scored on the RUNTIME dispatch path, where widening it by a `?Span`
/// costs real time for a field that is dead in every non-tracing run.
///
/// Without a span an `[extkey]` row cannot be tied to a source line, and
/// several calls in one file can share a receiver/argument type shape, so the
/// rows are unattributable. That gap is what stalled the
/// `plusCollectionInference` diagnosis.
pub threadlocal var trace_call_span: ?ir.Span = null;

/// Source-visible name of the extension call currently being scored, kept
/// alongside `trace_call_span` and under the same gate. Selecting candidates
/// by NAME is what makes the trace usable across rebuilds: a `FuncId` is
/// assigned by lowering order and shifts whenever anything upstream changes,
/// so a fid recorded in one session names a different function in the next.
pub threadlocal var trace_call_name: ?[]const u8 = null;

/// Whether any `[extkey]` tracing is requested at all. Callers use this to
/// skip maintaining `trace_call_span` on the normal path.
pub fn extKeyTraceEnabled() bool {
    return std.c.getenv("KLIO_EXTKEY_TRACE") != null;
}

/// `KLIO_EXTKEY_TRACE=<name|fid>[,...]` gate; see the dump in
/// `applicableExtension`. A numeric token selects a single candidate by
/// `FuncId`; anything else selects every candidate considered for a call of
/// that source name, which is what you want when comparing the overloads that
/// compete at one site.
fn extKeyTraceWanted(fid: ?FuncId) bool {
    const want = std.mem.span(std.c.getenv("KLIO_EXTKEY_TRACE") != null orelse return false);
    var it = std.mem.tokenizeScalar(u8, want, ',');
    while (it.next()) |tok| {
        if (std.fmt.parseInt(u32, tok, 10)) |n| {
            if (fid) |f| if (n == f.int()) return true;
            continue;
        } else |_| {}
        const cn = trace_call_name orelse continue;
        if (std.mem.eql(u8, tok, cn)) return true;
    }
    return false;
}

fn argIsProven(arg: *const ArgShape) bool {
    return arg.runtime_class != null or arg.ty != null;
}

// -------------------------------------------------------------------------
// Candidate scoring (mirror of `overloadScore`).
// -------------------------------------------------------------------------

/// Score one candidate against the actual args. Returns null on a definite
/// mismatch. Reproduces `host_call_func.zig` `overloadScore`: the arity /
/// default / trailing-lambda gates and the positional per-arg scoring, with the
/// under-application `-1` folded into `points`.
/// The element `TypeRef` a vararg parameter's declared (materialized array)
/// type carries: `ByteArray` -> `Byte`, `Array<T>` -> `T`, etc. A non-array
/// declared type is returned unchanged (already an element).
pub fn varargElementRef(param_ty: *const TypeRef) TypeRef {
    const n = param_ty.name;
    const eq = std.mem.eql;
    const elem: ?[]const u8 =
        if (eq(u8, n, "ByteArray")) "Byte" else if (eq(u8, n, "ShortArray")) "Short" else if (eq(u8, n, "IntArray")) "Int" else if (eq(u8, n, "LongArray")) "Long" else if (eq(u8, n, "FloatArray")) "Float" else if (eq(u8, n, "DoubleArray")) "Double" else if (eq(u8, n, "CharArray")) "Char" else if (eq(u8, n, "BooleanArray")) "Boolean" else if (eq(u8, n, "UByteArray")) "UByte" else if (eq(u8, n, "UShortArray")) "UShort" else if (eq(u8, n, "UIntArray")) "UInt" else if (eq(u8, n, "ULongArray")) "ULong" else if ((eq(u8, n, "Array") or eq(u8, n, "Array?")) and param_ty.args.len > 0) param_ty.args[0].name else null;
    if (elem) |e| return .{ .name = e, .nullable = param_ty.nullable, .args = &.{} };
    return param_ty.*;
}

pub fn applicable(sig: *const SigView, args: []const ArgShape, scope: ApplicabilityScope) ?Score {
    if (scope.named) return applicableNamed(sig, args, scope);
    if (scope.rank_extensions) return applicableExtension(sig, args, scope);
    if (scope.member) return applicableMember(sig, args, scope);

    const params = sig.params;
    const strace = scoreTraceOn();

    // A bodyless `expect` / native / abstract stub is never selectable.
    if (!sig.has_body) {
        if (strace) std.debug.print("[app-null] fid={?d} no-body\n", .{if (sig.fid) |f| f.int() else null});
        return null;
    }

    const last_vararg = params.len > 0 and params[params.len - 1].is_vararg;

    // NON-FINAL vararg + trailing lambda: `remember(vararg keys, calculation)`
    // called as `remember(k1 … kn) { … }`. The lambda binds the final
    // function-typed parameter out of sequence, leading args fill the params
    // before the vararg, the vararg absorbs the positional middle, and any
    // params strictly between the vararg and the lambda must carry defaults
    // (Kotlin fills them only by name).
    const mid_vararg: ?usize = blk: {
        for (params, 0..) |p, pi| {
            if (p.is_vararg and pi + 1 < params.len) break :blk pi;
        }
        break :blk null;
    };
    if (mid_vararg) |vpos| {
        if (args.len > 0 and args[args.len - 1].is_lambda and
            isFunctionTypeRef(&params[params.len - 1].ty) and args.len - 1 >= vpos)
        {
            var gap_ok = true;
            var gi = vpos + 1;
            while (gi < params.len - 1) : (gi += 1) {
                if (!paramHasDefault(sig, gi)) {
                    gap_ok = false;
                    break;
                }
            }
            if (gap_ok) {
                var total: i32 = -1;
                var proven: u16 = 0;
                var unknown: u16 = 0;
                var k: usize = 0;
                while (k < vpos) : (k += 1) {
                    const sc = scoreArg(sig, &params[k].ty, &args[k], &scope) orelse return null;
                    total += sc;
                    if (argIsProven(&args[k])) proven += 1 else unknown += 1;
                }
                const elem_ty = varargElementRef(&params[vpos].ty);
                while (k < args.len - 1) : (k += 1) {
                    const sc = scoreArg(sig, &elem_ty, &args[k], &scope) orelse return null;
                    total += sc;
                    if (argIsProven(&args[k])) proven += 1 else unknown += 1;
                }
                const ls = scoreArg(sig, &params[params.len - 1].ty, &args[args.len - 1], &scope) orelse return null;
                total += ls;
                if (argIsProven(&args[args.len - 1])) proven += 1 else unknown += 1;
                return .{
                    .points = total,
                    .proven_args = proven,
                    .unknown_args = unknown,
                    .exact_arity = false,
                    .low_priority = sig.low_priority,
                    .is_member = sig.is_member,
                    .binding = .{ .trailing_lambda_param = @intCast(params.len - 1) },
                };
            }
        }
    }

    // NON-FINAL vararg, purely positional: the leading args fill the prefix,
    // the vararg absorbs every remaining positional, and every parameter
    // after it must carry a default — Kotlin fills those only by name.
    // `report("A", 1, 2, 3)` on `(title, vararg items, footer = "end")`
    // binds items=[1,2,3]; without this arm the arity check below rejected
    // the only candidate and the call fell to the value route.
    if (mid_vararg) |vpos| {
        if (args.len >= vpos and (args.len == 0 or !args[args.len - 1].is_lambda)) {
            var tail_ok = true;
            var gi = vpos + 1;
            while (gi < params.len) : (gi += 1) {
                if (!paramHasDefault(sig, gi)) {
                    tail_ok = false;
                    break;
                }
            }
            if (tail_ok) {
                var total: i32 = -1;
                var proven: u16 = 0;
                var unknown: u16 = 0;
                var k: usize = 0;
                while (k < vpos) : (k += 1) {
                    const sc = scoreArg(sig, &params[k].ty, &args[k], &scope) orelse return null;
                    total += sc;
                    if (argIsProven(&args[k])) proven += 1 else unknown += 1;
                }
                const elem_ty = varargElementRef(&params[vpos].ty);
                while (k < args.len) : (k += 1) {
                    const sc = scoreArg(sig, &elem_ty, &args[k], &scope) orelse return null;
                    total += sc;
                    if (argIsProven(&args[k])) proven += 1 else unknown += 1;
                }
                return .{
                    .points = total,
                    .proven_args = proven,
                    .unknown_args = unknown,
                    .exact_arity = false,
                    .low_priority = sig.low_priority,
                    .is_member = sig.is_member,
                    .binding = .{
                        .vararg_param = @intCast(vpos),
                        .vararg_lo = @intCast(vpos),
                        .vararg_hi = @intCast(args.len),
                    },
                };
            }
        }
    }

    if (params.len < args.len and !last_vararg) {
        if (strace) std.debug.print("[app-null] fid={?d} arity params={d} args={d}\n", .{ if (sig.fid) |f| f.int() else null, params.len, args.len });
        return null;
    }

    // Trailing-lambda rule: the last arg binds out of sequence to the last
    // function-typed parameter, provided the gap is all-defaulted. A shape
    // this convention cannot bind — a non-defaulted gap, or a lambda the
    // last parameter's type refuses — FALLS THROUGH to the plain positional
    // fill below rather than rejecting the candidate: `render({..}, {..})`
    // against `(leading, trailing, plain = null)` binds positionally with
    // the tail defaulted, and only the out-of-sequence reading fails.
    if (params.len > args.len and args.len > 0 and
        isFunctionTypeRef(&params[params.len - 1].ty) and
        args[args.len - 1].is_lambda)
    trailing: {
        const lead = args.len - 1;
        const last_param = params.len - 1;
        if (lead <= last_param) {
            var gap_defaulted = true;
            var i = lead;
            while (i < last_param) : (i += 1) {
                if (!paramHasDefault(sig, i)) {
                    gap_defaulted = false;
                    break;
                }
            }
            if (!gap_defaulted) break :trailing;
            var total: i32 = -1;
            var proven: u16 = 0;
            var unknown: u16 = 0;
            var k: usize = 0;
            while (k < lead) : (k += 1) {
                const sc = scoreArg(sig, &params[k].ty, &args[k], &scope) orelse break :trailing;
                total += sc;
                if (argIsProven(&args[k])) proven += 1 else unknown += 1;
            }
            const ls = scoreArg(sig, &params[last_param].ty, &args[lead], &scope) orelse break :trailing;
            total += ls;
            if (argIsProven(&args[lead])) proven += 1 else unknown += 1;
            return .{
                .points = total,
                .proven_args = proven,
                .unknown_args = unknown,
                .exact_arity = false,
                .low_priority = sig.low_priority,
                .is_member = sig.is_member,
                .binding = .{ .trailing_lambda_param = @intCast(last_param) },
            };
        }
    }

    // Under-applied: every unfilled parameter must carry a default or be a
    // vararg, which Kotlin materializes as an empty array. This matters after
    // an empty spread is flattened: `listOf(*emptyArray())` reaches the scorer
    // with zero scalar arguments but still binds `vararg elements`.
    if (params.len > args.len) {
        var all_defaulted = true;
        var i = args.len;
        while (i < params.len) : (i += 1) {
            if (!paramHasDefault(sig, i) and !params[i].is_vararg) {
                all_defaulted = false;
                break;
            }
        }
        if (!all_defaulted) {
            if (strace) std.debug.print("[app-null] fid={?d} gap-not-defaulted params={d} args={d}\n", .{ if (sig.fid) |f| f.int() else null, params.len, args.len });
            return null;
        }
    }

    // A vararg application is less specific than an otherwise equal fixed
    // overload. Carry the same one-point applicability penalty used for
    // defaulted under-application so every lowering/runtime scanner observes
    // the Kotlin fixed-over-vararg tiebreak.
    var total: i32 = if (params.len == args.len and !last_vararg) 0 else -1;
    var proven: u16 = 0;
    var unknown: u16 = 0;
    // A trailing vararg absorbs the args from its own position onward. Each
    // absorbed arg is a single ELEMENT (scored against the element type), UNLESS
    // it is a spread (`*arr`), which feeds the whole array (scored against the
    // array/param type). This is why a non-spread `ByteArray` cannot satisfy a
    // `vararg Byte` — it is not a `Byte` — so a same-named class constructor
    // taking `(ByteArray, …)` wins instead of the factory silently absorbing it.
    const vp: ?usize = if (last_vararg) params.len - 1 else null;
    var idx: usize = 0;
    while (idx < params.len and idx < args.len) : (idx += 1) {
        if (vp != null and idx == vp.?) break;
        if (params[idx].is_vararg) {
            // A MID-position vararg fed one packed array (the flattened
            // spread `f(*arr, content, $composer, $changed)`): this is the
            // exact shape `packVarargArgs` passes through at dispatch, so
            // scoring the array against the ELEMENT type must not refute
            // the candidate. Neutral score, counted unknown.
            const cls = args[idx].runtime_class orelse "";
            if (std.mem.endsWith(u8, cls, "Array")) {
                unknown += 1;
                continue;
            }
        }
        const sc = scoreArg(sig, &params[idx].ty, &args[idx], &scope) orelse {
            if (strace) std.debug.print("[app-null] fid={?d} arg{d} param={s} score-null\n", .{ if (sig.fid) |f| f.int() else null, idx, params[idx].ty.name });
            return null;
        };
        total += sc;
        if (argIsProven(&args[idx])) proven += 1 else unknown += 1;
    }
    if (vp) |v| {
        const elem = varargElementRef(&params[v].ty);
        var k: usize = v;
        while (k < args.len) : (k += 1) {
            const a = &args[k];
            const target: *const TypeRef = if (a.is_spread) &params[v].ty else &elem;
            const sc = scoreArg(sig, target, a, &scope) orelse return null;
            total += sc;
            if (argIsProven(a)) proven += 1 else unknown += 1;
        }
    }
    return .{
        .points = total,
        .proven_args = proven,
        .unknown_args = unknown,
        .exact_arity = params.len == args.len and !last_vararg,
        .low_priority = sig.low_priority,
        .is_member = sig.is_member,
        .binding = .{},
    };
}

// -------------------------------------------------------------------------
// Runtime MEMBER scorer (mirror of `pickMethodOverload`'s per-candidate body).
// -------------------------------------------------------------------------

/// Score one member candidate against the value args. `sig.params` includes
/// the implicit `this` slot (skipped when `params[0].name == "this"`); value
/// args score against the remaining `effective` params. The base score is 0
/// (no under-application `-1`); the caller applies the `+5` exact-arity bonus
/// and the `-1000` low-priority penalty from `Score.exact_arity`/`low_priority`.
fn applicableMember(sig: *const SigView, args: []const ArgShape, scope: ApplicabilityScope) ?Score {
    const params = sig.params;
    const skip: usize = if (params.len > 0 and std.mem.eql(u8, params[0].name, "this")) 1 else 0;
    const effective = params[skip..];

    // Trailing-lambda rule: `recv.f(a, …) { lambda }` binds the trailing
    // lambda to the LAST function-typed param with the gap all-defaulted.
    if (args.len < effective.len and args.len > 0 and effective.len > 0 and
        scopeIsFunctionType(&scope, &effective[effective.len - 1].ty) and
        args[args.len - 1].is_lambda)
    {
        const lead = args.len - 1;
        const last_param = effective.len - 1;
        var gap_defaulted = true;
        var k: usize = lead;
        while (k < last_param) : (k += 1) {
            if (!paramHasDefault(sig, skip + k)) {
                gap_defaulted = false;
                break;
            }
        }
        if (gap_defaulted) {
            var total: i32 = 0;
            var proven: u16 = 0;
            var unknown: u16 = 0;
            var j: usize = 0;
            while (j < lead) : (j += 1) {
                const sc = scoreArg(sig, &effective[j].ty, &args[j], &scope) orelse return null;
                total += sc;
                if (argIsProven(&args[j])) proven += 1 else unknown += 1;
            }
            const ls = scoreArg(sig, &effective[last_param].ty, &args[lead], &scope) orelse return null;
            total += ls;
            if (argIsProven(&args[lead])) proven += 1 else unknown += 1;
            return .{
                .points = total,
                .proven_args = proven,
                .unknown_args = unknown,
                .exact_arity = false,
                .low_priority = sig.low_priority,
                .is_member = sig.is_member,
                .binding = .{ .trailing_lambda_param = @intCast(skip + last_param) },
            };
        }
        // Gap not all-defaulted: fall through to the plain arity check (the
        // legacy loop does not `continue` here).
    }

    // Positional member varargs bind every argument from the vararg position
    // onward as an element. A spread is scored against the declared array
    // type, and zero elements materialize an empty array. Parameters after the
    // vararg cannot be supplied positionally in this branch and therefore
    // must be defaultable (a trailing lambda was handled above).
    var vararg_pos: ?usize = null;
    for (effective, 0..) |param, i| if (param.is_vararg) {
        vararg_pos = i;
        break;
    };
    if (vararg_pos) |vp| {
        var total: i32 = -1;
        var proven: u16 = 0;
        var unknown: u16 = 0;
        var i: usize = 0;
        while (i < vp and i < args.len) : (i += 1) {
            const sc = scoreArg(sig, &effective[i].ty, &args[i], &scope) orelse return null;
            total += sc;
            if (argIsProven(&args[i])) proven += 1 else unknown += 1;
        }
        while (i < vp) : (i += 1) {
            if (!paramHasDefault(sig, skip + i)) return null;
        }
        var tail = vp + 1;
        while (tail < effective.len) : (tail += 1) {
            if (!paramHasDefault(sig, skip + tail)) return null;
        }
        const elem = varargElementRef(&effective[vp].ty);
        var k = vp;
        while (k < args.len) : (k += 1) {
            const target: *const TypeRef = if (args[k].is_spread) &effective[vp].ty else &elem;
            const sc = scoreArg(sig, target, &args[k], &scope) orelse return null;
            total += sc;
            if (argIsProven(&args[k])) proven += 1 else unknown += 1;
        }
        return .{
            .points = total,
            .proven_args = proven,
            .unknown_args = unknown,
            .exact_arity = false,
            .low_priority = sig.low_priority,
            .is_member = sig.is_member,
            .binding = .{},
        };
    }

    // Over-supply with no vararg tail cannot bind (the multi-candidate member
    // path does not pack a trailing vararg here).
    if (args.len > effective.len) return null;
    // Under-application: every unfilled param must carry a default.
    if (args.len < effective.len) {
        var k: usize = args.len;
        while (k < effective.len) : (k += 1) {
            if (!paramHasDefault(sig, skip + k)) return null;
        }
    }

    var total: i32 = 0;
    var proven: u16 = 0;
    var unknown: u16 = 0;
    var i: usize = 0;
    while (i < args.len and i < effective.len) : (i += 1) {
        const sc = scoreArg(sig, &effective[i].ty, &args[i], &scope) orelse return null;
        total += sc;
        if (argIsProven(&args[i])) proven += 1 else unknown += 1;
    }
    return .{
        .points = total,
        .proven_args = proven,
        .unknown_args = unknown,
        .exact_arity = args.len == effective.len,
        .low_priority = sig.low_priority,
        .is_member = sig.is_member,
        .binding = .{},
    };
}

// -------------------------------------------------------------------------
// Runtime EXTENSION ranking (mirror of `scoreExtCandidates`'s per-candidate
// `ExtKey` build). Always returns a Score with `ext_key` filled — an
// inapplicable candidate is not dropped here, it ranks lowest via
// `ext_key[0] == 0`, exactly as the legacy loop keeps every candidate.
// -------------------------------------------------------------------------

fn applicableExtension(sig: *const SigView, args: []const ArgShape, scope: ApplicabilityScope) ?Score {
    const params = sig.params;
    const want = args.len + 1; // receiver + value args
    const recv = scope.receiver;

    // Receiver score, saturating *1000 into the numeric `score` tier.
    const recv_score: i32 = if (params.len > 0 and recv != null)
        (scoreArg(sig, &params[0].ty, &recv.?, &scope) orelse -1)
    else
        -1;
    var score: i32 = recv_score *| 1000;

    var applic: i32 = 1;
    var param_spec: i32 = 0;
    var proven: u16 = 0;
    var unknown: u16 = 0;
    // Trailing-lambda rule (same as the member scorer): `recv.f(a, …) { … }`
    // binds the trailing lambda to the LAST function-typed param, provided
    // every skipped parameter in between carries a default. Without this, a
    // lambda-only call scores the lambda against `params[1]` and marks the
    // real block parameter unfilled, so every candidate looks inapplicable
    // and the ranking decays to the noise tiers of the key.
    var lambda_param: ?usize = null;
    if (args.len > 0 and params.len > want and
        scopeIsFunctionType(&scope, &params[params.len - 1].ty) and
        args[args.len - 1].is_lambda)
    {
        var gap_defaulted = true;
        var g: usize = want - 1;
        while (g < params.len - 1) : (g += 1) {
            if (!params[g].has_default and !params[g].is_vararg) {
                gap_defaulted = false;
                break;
            }
        }
        if (gap_defaulted) lambda_param = params.len - 1;
    }
    for (args, 0..) |*a, idx| {
        const pidx = if (lambda_param != null and idx == args.len - 1) lambda_param.? else idx + 1;
        if (params.len > pidx) {
            const arg_score = scoreArg(sig, &params[pidx].ty, a, &scope);
            if (arg_score == null and !params[pidx].has_default and !params[pidx].is_vararg) applic = 0;
            score += arg_score orelse -1;
            if (!isTopOrGenericType(params[pidx].ty.name)) param_spec += 1;
            if (argIsProven(a)) proven += 1 else unknown += 1;
        }
    }
    // Every param past the supplied args must be defaulted or vararg (when
    // the trailing lambda fills the last param, its gap was checked above).
    if (want < params.len and lambda_param == null) {
        var k: usize = want;
        while (k < params.len) : (k += 1) {
            if (!params[k].has_default and !params[k].is_vararg) {
                applic = 0;
                break;
            }
        }
    }
    var has_vararg = false;
    for (params) |p| {
        if (p.is_vararg) {
            has_vararg = true;
            break;
        }
    }
    if (params.len == want and !has_vararg) score += 5;

    // Receiver specificity (`extReceiverSpecificity`).
    const recv_match: i32 = blk: {
        const cb = scope.ext_recv_match orelse break :blk 0;
        const rv = if (recv) |r| r.value else null;
        break :blk cb(scope.ctx.?, rv orelse break :blk 0, if (params.len > 0) params[0].ty.name else "");
    };

    // Subtype specificity: how many other candidates' receivers are supertypes
    // of this one.
    var spec: i32 = 0;
    if (scope.all_candidates) |cands| {
        if (scope.ext_is_subtype_name) |cb| {
            const my_recv = if (params.len > 0) params[0].ty.name else "";
            for (cands) |*o| {
                if (sameFid(sig.fid, o.fid)) continue;
                const o_recv = if (o.params.len > 0) o.params[0].ty.name else "";
                if (cb(scope.ctx.?, my_recv, o_recv)) spec += 1;
            }
        }
    }

    // Owner rank (member-extension nearer on the enclosing-`this` chain).
    const owner_rank: i32 = blk: {
        const cb = scope.ext_owner_rank orelse break :blk 0;
        const fid = sig.fid orelse break :blk 0;
        break :blk cb(scope.ctx.?, fid);
    };

    // Stable discriminator: lowest FuncId, negated so smaller ranks higher.
    const neg_fid: i32 = if (sig.fid) |fid|
        -@as(i32, @intCast(@as(u32, @intCast(fid.int())) & 0x7fff_ffff))
    else
        0;

    // A user-program extension outranks a shipped namesake of equal
    // applicability. The empty package is always user code.
    const is_user: i32 = blk: {
        if (sig.package.len == 0) break :blk 1;
        const cb = scope.ext_known_package orelse break :blk 1;
        break :blk @intFromBool(!cb(sig.package));
    };

    // Kotlin prefers the applicable overload that fills the FEWEST
    // parameters from defaults (a bare `produce { }` binds the 3-param
    // public overload, not its 5/6-param delegation targets); negated so
    // the lexicographic compare ranks fewer-defaults higher, ahead of the
    // identity component.
    const neg_defaults: i32 = -@as(i32, @intCast(params.len -| want));
    const key: [9]i32 = .{ applic, is_user, spec, recv_match, score, owner_rank, param_spec, neg_defaults, neg_fid };
    // `KLIO_EXTKEY_TRACE=<fid>,<fid>` — dump the eight-element ranking key for
    // the named candidates. Ranking is lexicographic, so the first component
    // that differs is the one that decides; reading it beats guessing which
    // term dominates.
    if (extKeyTraceWanted(sig.fid)) {
        // Name the call site. A file/line beats a file id and byte offset,
        // and the running program's source map is a global, so resolve
        // through it when it is installed and fall back to the raw span when
        // it is not (unit tests, pre-run lowering).
        var loc_buf: [256]u8 = undefined;
        const loc: []const u8 = if (trace_call_span) |cs| blk: {
            if (span_mod.active_map) |m| {
                if (m.getChecked(cs.file)) |sf| {
                    const lc = sf.lineCol(cs.start);
                    const base = if (std.mem.lastIndexOfScalar(u8, sf.path, '/')) |i| sf.path[i + 1 ..] else sf.path;
                    break :blk std.fmt.bufPrint(&loc_buf, "{s}:{d}", .{ base, lc.line }) catch "?";
                }
            }
            break :blk std.fmt.bufPrint(&loc_buf, "f{d}:{d}", .{ cs.file.int(), cs.start }) catch "?";
        } else "?:?";
        std.debug.print("[extkey] {s} {s} fid={d} key={any} recv=", .{ loc, trace_call_name orelse "?", if (sig.fid) |f| f.int() else 0, key });
        if (recv) |r| {
            if (r.ty) |t| {
                if (t.args.len > 0) std.debug.print("{s}<{s}>", .{ t.name, t.args[0].name }) else std.debug.print("{s}", .{t.name});
            } else std.debug.print("?", .{});
        } else std.debug.print("-", .{});
        std.debug.print(" args=", .{});
        for (args) |*aa| {
            if (aa.ty) |t| {
                if (t.args.len > 0) std.debug.print("{s}<{s}> ", .{ t.name, t.args[0].name }) else std.debug.print("{s} ", .{t.name});
            } else std.debug.print("? ", .{});
        }
        std.debug.print("| params=", .{});
        for (params) |*pp| std.debug.print("{s} ", .{pp.ty.name});
        std.debug.print("\n", .{});
    }
    return .{
        .points = score,
        .proven_args = proven,
        .unknown_args = unknown,
        .exact_arity = params.len == want and !has_vararg,
        .low_priority = sig.low_priority,
        .is_member = sig.is_member,
        .ext_key = key,
        .binding = .{},
    };
}

// -------------------------------------------------------------------------
// Runtime NAMED-ARGUMENT scorer (mirror of `host_call_func.zig`
// `scoreNamedCandidate`). A named/defaulted/reordered call binds each `named`
// arg to its distinct same-named parameter, positional args fill the remaining
// slots (a trailing callable binds out of sequence to the last function-typed
// param, a vararg absorbs positional arguments at its position), and every unfilled
// non-vararg parameter must be defaultable. A per-arg type mismatch scores 0
// (neutral) instead of disqualifying the candidate; only a named arg that no
// parameter accepts, a doubly-filled parameter, or an over-supplied
// non-vararg call is a hard reject. When `scope.arg_to_param_buf` is set, the
// parameter each supplied arg bound to is recorded through it.
// -------------------------------------------------------------------------

fn applicTraceReject(site: []const u8) void {
    if (comptime !@import("builtin").link_libc) return;
    if (std.c.getenv("KLIO_APPLIC_TRACE") == null) return;
    std.debug.print("[applic-reject] {s}\n", .{site});
}

fn applicableNamed(sig: *const SigView, args: []const ArgShape, scope: ApplicabilityScope) ?Score {
    const params = sig.params;
    // A bodyless declaration is only selectable when it backs a native
    // intrinsic; the caller folds that into `sig.has_body`.
    if (!sig.has_body) { applicTraceReject("named-1"); return null; }
    if (params.len > 64) { applicTraceReject("named-2"); return null; }

    var filled = [_]bool{false} ** 64;
    var total: i32 = 0;
    var proven: u16 = 0;
    var unknown: u16 = 0;
    const bind = scope.arg_to_param_buf;

    // An implicit extension receiver fills the leading `this` parameter; no
    // positional arg lands on it.
    const is_ext = params.len > 0 and std.mem.eql(u8, params[0].name, "this");
    if (is_ext and scope.recv_external) filled[0] = true;

    // Named arguments bind to their distinct same-named parameter.
    for (args, 0..) |*a, i| {
        const n = a.named orelse continue;
        var pos: ?usize = null;
        for (params, 0..) |p, pi| {
            if (paramNameMatchesArg(p.name, n)) {
                pos = pi;
                break;
            }
        }
        // A named argument no parameter accepts is a hard reject. The
        // generated `$composer`/`$changed` pair included: with the
        // pre-resolution call-threading oracle retired, a pair only ever
        // reaches a call whose RESOLVED target declares it (the lowering
        // completion) or is being probed by the member-miss completion,
        // where a candidate NOT declaring the pair is correctly not the
        // completed call's target.
        const p = pos orelse {
            if (comptime @import("builtin").link_libc) {
                if (std.c.getenv("KLIO_APPLIC_TRACE") != null) {
                    std.debug.print("[applic-reject] named-3 fid={?d} arg={s} params:", .{ if (sig.fid) |f| f.int() else null, n });
                    for (params) |*pp| std.debug.print(" {s}", .{pp.name});
                    std.debug.print("\n", .{});
                }
            }
            { applicTraceReject("named-3"); return null; }
        };
        if (filled[p]) { applicTraceReject("named-4"); return null; }
        total += scoreArg(sig, &params[p].ty, a, &scope) orelse 0;
        if (argIsProven(a)) proven += 1 else unknown += 1;
        filled[p] = true;
        if (bind) |bb| {
            if (i < bb.len) bb[i] = @intCast(p);
        }
    }

    // A trailing positional callable binds to the last function-typed
    // parameter, out of sequence. Compose lowering appends its named
    // `$composer`/`$changed` pair after the source trailing lambda; for that
    // generated shape, the last user parameter immediately before the pair is
    // still the source trailing-lambda target.
    var trailing_lambda: ?usize = null;
    var trailing_lambda_param: ?u16 = null;
    if (args.len > 0 and params.len > 0) {
        const last = args.len - 1;
        const last_named = args[last].named != null;
        const last_param = params.len - 1;
        if (!last_named and !filled[last_param] and
            scopeIsFunctionType(&scope, &params[last_param].ty) and args[last].is_lambda)
        {
            total += scoreArg(sig, &params[last_param].ty, &args[last], &scope) orelse 0;
            if (argIsProven(&args[last])) proven += 1 else unknown += 1;
            filled[last_param] = true;
            trailing_lambda = last;
            trailing_lambda_param = @intCast(last_param);
            if (bind) |bb| {
                if (last < bb.len) bb[last] = @intCast(last_param);
            }
        }
        if (trailing_lambda == null and args.len >= 3 and params.len >= 3) {
            const composer_arg = args[args.len - 2].named;
            const changed_arg = args[args.len - 1].named;
            const composer_param = params[params.len - 2].name;
            const changed_param = params[params.len - 1].name;
            const lambda_index = args.len - 3;
            const user_param = params.len - 3;
            if (composer_arg != null and changed_arg != null and
                std.mem.eql(u8, composer_arg.?, "$composer") and
                std.mem.eql(u8, changed_arg.?, "$changed") and
                paramNameMatchesArg(composer_param, "$composer") and
                paramNameMatchesArg(changed_param, "$changed") and
                args[lambda_index].named == null and
                args[lambda_index].is_lambda and
                !filled[user_param] and
                !params[user_param].is_vararg and
                scopeIsFunctionType(&scope, &params[user_param].ty))
            {
                total += scoreArg(
                    sig,
                    &params[user_param].ty,
                    &args[lambda_index],
                    &scope,
                ) orelse 0;
                if (argIsProven(&args[lambda_index]))
                    proven += 1
                else
                    unknown += 1;
                filled[user_param] = true;
                trailing_lambda = lambda_index;
                trailing_lambda_param = @intCast(user_param);
                if (bind) |bb| {
                    if (lambda_index < bb.len)
                        bb[lambda_index] = @intCast(user_param);
                }
            }
        }
    }

    // Vararg-aware positional walk. Kotlin permits parameters after a vararg;
    // when those parameters were supplied by name, every remaining positional
    // argument at the vararg position belongs to the vararg. For generated
    // slot-exact calls, retain enough trailing positional arguments to fill
    // the still-unbound, non-defaulted parameters after it.
    var vararg_pos: ?usize = null;
    for (params, 0..) |p, pi| {
        if (p.is_vararg) {
            vararg_pos = pi;
            break;
        }
    }
    var positional_left: usize = 0;
    for (args, 0..) |a, i| {
        if (a.named != null) continue;
        if (trailing_lambda != null and i == trailing_lambda.?) continue;
        positional_left += 1;
    }
    var pidx: usize = 0;
    for (args, 0..) |*a, i| {
        if (a.named != null) continue;
        if (trailing_lambda != null and i == trailing_lambda.?) continue;
        while (pidx < params.len and filled[pidx]) pidx += 1;

        if (vararg_pos) |vp| {
            if (pidx == vp) {
                var required_tail: usize = 0;
                for (params[vp + 1 ..], vp + 1..) |p, pi| {
                    if (filled[pi] or p.is_vararg or paramHasDefault(sig, pi)) continue;
                    required_tail += 1;
                }
                if (positional_left > required_tail) {
                    const elem = varargElementRef(&params[vp].ty);
                    const target: *const TypeRef = if (a.is_spread) &params[vp].ty else &elem;
                    total += scoreArg(sig, target, a, &scope) orelse 0;
                    if (argIsProven(a)) proven += 1 else unknown += 1;
                    if (bind) |bb| {
                        if (i < bb.len) bb[i] = @intCast(vp);
                    }
                    positional_left -= 1;
                    continue;
                }
                pidx = vp + 1;
                while (pidx < params.len and filled[pidx]) pidx += 1;
            }
        }

        if (pidx >= params.len) {
            if (comptime @import("builtin").link_libc) {
                if (std.c.getenv("KLIO_APPLIC_TRACE") != null) {
                    std.debug.print("[applic-reject] named-5 fid={?d} args:", .{if (sig.fid) |f| f.int() else null});
                    for (args) |*aa| std.debug.print(" {s}{s}", .{ aa.named orelse "_", if (aa.is_lambda) "(lam)" else "" });
                    std.debug.print(" params:", .{});
                    for (params) |*pp| std.debug.print(" {s}", .{pp.name});
                    std.debug.print("\n", .{});
                }
            }
            applicTraceReject("named-5");
            return null;
        }
        total += scoreArg(sig, &params[pidx].ty, a, &scope) orelse 0;
        if (argIsProven(a)) proven += 1 else unknown += 1;
        if (bind) |bb| {
            if (i < bb.len) bb[i] = @intCast(pidx);
        }
        filled[pidx] = true;
        pidx += 1;
        positional_left -= 1;
    }

    // Every unfilled non-vararg parameter must be defaultable.
    for (params, 0..) |p, pi| {
        if (filled[pi] or p.is_vararg) continue;
        if (!paramHasDefault(sig, pi)) { applicTraceReject("named-6"); return null; }
        total -= 1;
    }

    return .{
        // Kotlin prefers an otherwise equal fixed declaration for named calls
        // just as it does for positional calls.
        .points = total - @as(i32, @intFromBool(vararg_pos != null)),
        .proven_args = proven,
        .unknown_args = unknown,
        .exact_arity = false,
        .low_priority = sig.low_priority,
        .is_member = sig.is_member,
        .binding = .{
            .trailing_lambda_param = trailing_lambda_param,
            .arg_to_param = if (bind) |bb| bb[0..@min(args.len, bb.len)] else &.{},
        },
    };
}

// -------------------------------------------------------------------------
// Tests.
// -------------------------------------------------------------------------

const testing = std.testing;

fn tref(name: []const u8) TypeRef {
    return .{ .name = name, .nullable = false, .args = &.{} };
}

fn oneParam(name: []const u8) [1]Param {
    return .{.{ .name = "x", .ty = tref(name), .default = null }};
}

test {
    testing.refAllDecls(@This());
}

test "paramNameMatchesArg: identity and the compose-default rename" {
    // Identity.
    try testing.expect(paramNameMatchesArg("onReuse", "onReuse"));
    // The compose plugin renames a defaulted parameter `p` to `p$arg`; a
    // source-level named argument still names the original `p`.
    try testing.expect(paramNameMatchesArg("onReuse$arg", "onReuse"));
    try testing.expect(paramNameMatchesArg("content$arg", "content"));
    // No spurious matches: a different base, a bare suffix, or a caller name
    // that already carries the suffix must not cross-bind.
    try testing.expect(!paramNameMatchesArg("onReuse$arg", "onSet"));
    try testing.expect(!paramNameMatchesArg("onReuse", "onReuse$arg"));
    try testing.expect(!paramNameMatchesArg("$arg", ""));
    try testing.expect(!paramNameMatchesArg("onReuse", "onSet"));
    // The synthetic composer/changed named pair keeps its exact match (they
    // are never defaulted, so no `$arg` form of them exists).
    try testing.expect(paramNameMatchesArg("$composer", "$composer"));
}

test "applicableNamed: a named arg binds the compose-default-renamed parameter" {
    // `f(onReuse = x, content = y)` against the transformed signature
    // `f(onReuse$arg, content, ...)` must bind `onReuse` to `onReuse$arg`.
    const params = [_]Param{
        .{ .name = "onReuse$arg", .ty = tref("Function0"), .default = null },
        .{ .name = "content", .ty = tref("Function0"), .default = null },
    };
    const sig = SigView{ .params = &params };
    const args = [_]ArgShape{
        .{ .runtime_class = "Function0", .is_lambda = true, .named = "onReuse" },
        .{ .runtime_class = "Function0", .is_lambda = true, .named = "content" },
    };
    try testing.expect(applicable(&sig, &args, .{ .named = true }) != null);
}

test "applicable: exact head match scores 100" {
    const p = oneParam("Int");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{}).?;
    try testing.expectEqual(@as(i32, 100), sc.points);
    try testing.expect(sc.exact_arity);
}

test "applicable: a canonical nested-class head keeps exact-match refinement" {
    var dummy: u8 = 0;
    const p = oneParam("Modifier.Node");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Modifier$Node", .value = @ptrCast(&dummy) }};
    const callbacks = struct {
        fn exact(_: *anyopaque, param: []const u8, arg: []const u8) bool {
            return std.mem.eql(u8, param, "Modifier.Node") and
                std.mem.eql(u8, arg, "Modifier$Node");
        }
        fn refine(_: *anyopaque, _: *const TypeRef, _: *const anyopaque) ?i32 {
            return 6;
        }
    };
    try testing.expect(applicable(&sig, &args, .{}) == null);
    const sc = applicable(&sig, &args, .{
        .ctx = @ptrCast(&dummy),
        .exact_head = callbacks.exact,
        .refine = callbacks.refine,
    }).?;
    try testing.expectEqual(@as(i32, 106), sc.points);
}

test "applicable: erased integer-width matching is explicit runtime evidence" {
    const p = oneParam("Byte");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    try testing.expect(applicable(&sig, &args, .{}) == null);
    const sc = applicable(&sig, &args, .{ .erased_integer_widths = true }).?;
    try testing.expectEqual(@as(i32, 20), sc.points);
}

test "applicable: extra positional arg without vararg is inapplicable" {
    const p = oneParam("Int");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{ .{ .runtime_class = "Int" }, .{ .runtime_class = "Int" } };
    try testing.expect(applicable(&sig, &args, .{}) == null);
}

test "applicable: Int arg widens to Long param" {
    const p = oneParam("Long");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{}).?;
    try testing.expectEqual(@as(i32, 40), sc.points);
}

test "applicable: under-application without a default is inapplicable" {
    const p = [_]Param{
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    try testing.expect(applicable(&sig, &args, .{}) == null);
}

test "applicable: under-application with a default scores with the -1 penalty" {
    const p = [_]Param{
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    const defaults = [_]?FuncId{ null, FuncId.from(0) };
    const sig = SigView{ .params = &p, .defaults = &defaults };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{}).?;
    // 100 (exact head) - 1 (under-application) == 99.
    try testing.expectEqual(@as(i32, 99), sc.points);
    try testing.expect(!sc.exact_arity);
}

test "applicable: an empty trailing vararg is applicable" {
    var p = oneParam("Array");
    p[0].is_vararg = true;
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{};
    const sc = applicable(&sig, &args, .{}).?;
    try testing.expectEqual(@as(i32, -1), sc.points);
    try testing.expect(!sc.exact_arity);
}

test "applicable: fixed arity outranks an equally typed vararg" {
    var vararg_params = oneParam("Int");
    vararg_params[0].is_vararg = true;
    const fixed_params = oneParam("Int");
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};

    const fixed = applicable(
        &SigView{ .params = &fixed_params },
        &args,
        .{},
    ).?;
    const variadic = applicable(
        &SigView{ .params = &vararg_params },
        &args,
        .{},
    ).?;

    try testing.expectEqual(@as(i32, 100), fixed.points);
    try testing.expect(fixed.exact_arity);
    try testing.expectEqual(@as(i32, 99), variadic.points);
    try testing.expect(!variadic.exact_arity);
}

test "applicable: null defaults falls back to the param has_default flag" {
    // The lowering adapter (`sigViewForApplicability`) leaves `defaults` null
    // and carries the default on the param, so under-application still ranks.
    var p = [_]Param{
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    p[1].has_default = true;
    const sig = SigView{ .params = &p, .defaults = null };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{}).?;
    // 100 (exact head) - 1 (under-application) == 99.
    try testing.expectEqual(@as(i32, 99), sc.points);
    try testing.expect(!sc.exact_arity);
    // Without the flag the same under-application is inapplicable.
    p[1].has_default = false;
    try testing.expect(applicable(&sig, &args, .{}) == null);
}

test "builtinSupersOf: union table adds Collection and StringBuilder rows" {
    try testing.expectEqual(@as(usize, 3), builtinSupersOf("Collection").len);
    try testing.expectEqualStrings("CharSequence", builtinSupersOf("StringBuilder")[0]);
    try testing.expectEqual(@as(usize, 0), builtinSupersOf("Nope").len);
}

test "declared-type evidence: head match scores 100, mismatch stays unknown (never disqualifies)" {
    const p = oneParam("Double");
    const sig = SigView{ .params = &p };
    // Exact declared head.
    const hit = [_]ArgShape{.{ .ty = tref("Double") }};
    try testing.expectEqual(@as(i32, 100), applicable(&sig, &hit, .{}).?.points);
    // Mismatching declared head falls back to the unknown base — the
    // candidate stays applicable (additive-only rule).
    const miss = [_]ArgShape{.{ .ty = tref("String") }};
    try testing.expectEqual(@as(i32, 10), applicable(&sig, &miss, .{}).?.points);
}

test "declared-type evidence: type-param arg head-matches a type-param param" {
    const p = oneParam("T");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .ty = tref("T") }};
    try testing.expectEqual(@as(i32, 100), applicable(&sig, &args, .{}).?.points);
    // Against a concrete param the same arg is unknown, not disproven.
    const pc = oneParam("UInt");
    const sigc = SigView{ .params = &pc };
    try testing.expectEqual(@as(i32, 10), applicable(&sigc, &args, .{}).?.points);
}

test "tyEvidenceBonus: zero without evidence, promotes matching candidates only" {
    const generic = [_]Param{
        .{ .name = "a", .ty = tref("T"), .default = null },
        .{ .name = "b", .ty = tref("T"), .default = null },
    };
    const numeric = [_]Param{
        .{ .name = "a", .ty = tref("UInt"), .default = null },
        .{ .name = "b", .ty = tref("UInt"), .default = null },
    };
    // No evidence: every candidate scores zero (ranking unchanged).
    const blank = [_]ArgShape{ .{}, .{} };
    try testing.expectEqual(@as(i32, 0), tyEvidenceBonus(&generic, &blank));
    try testing.expectEqual(@as(i32, 0), tyEvidenceBonus(&numeric, &blank));
    // `T`-declared args promote the generic candidate, not the numeric one.
    const t_args = [_]ArgShape{ .{ .ty = tref("T") }, .{ .ty = tref("T") } };
    try testing.expectEqual(@as(i32, 200), tyEvidenceBonus(&generic, &t_args));
    try testing.expectEqual(@as(i32, 0), tyEvidenceBonus(&numeric, &t_args));
    // Numeric literals promote numeric params, cross-width Double decls too.
    const lit_args = [_]ArgShape{ .{ .literal_kind = .numeric }, .{ .literal_kind = .numeric } };
    try testing.expectEqual(@as(i32, 200), tyEvidenceBonus(&numeric, &lit_args));
    try testing.expectEqual(@as(i32, 0), tyEvidenceBonus(&generic, &lit_args));
    const d_args = [_]ArgShape{ .{ .ty = tref("Double") }, .{ .ty = tref("Double") } };
    try testing.expectEqual(@as(i32, 160), tyEvidenceBonus(&numeric, &d_args));
    try testing.expectEqual(@as(i32, 0), tyEvidenceBonus(&generic, &d_args));
}

test "applicable: bodyless candidate is never selectable" {
    const p = oneParam("Int");
    const sig = SigView{ .params = &p, .has_body = false };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    try testing.expect(applicable(&sig, &args, .{}) == null);
}

// --- member scorer ----------------------------------------------------------

test "applicable member: receiver slot skipped, base 0 (no under-application -1), exact_arity" {
    const p = [_]Param{
        .{ .name = "this", .ty = tref("Box"), .default = null },
        .{ .name = "x", .ty = tref("Int"), .default = null },
    };
    const sig = SigView{ .params = &p, .is_member = true };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{ .member = true }).?;
    // Exact head match; base 0 (no +5 pre-applied, no -1), exact_arity carried.
    try testing.expectEqual(@as(i32, 100), sc.points);
    try testing.expect(sc.exact_arity);
    try testing.expect(sc.is_member);
}

test "applicable member: under-application via the defaults table is applicable" {
    const p = [_]Param{
        .{ .name = "this", .ty = tref("Box"), .default = null },
        .{ .name = "x", .ty = tref("Int"), .default = null },
        .{ .name = "y", .ty = tref("Int"), .default = null },
    };
    // Defaults table is indexed by full lowered position (incl. `this`).
    const defaults = [_]?FuncId{ null, null, FuncId.from(0) };
    const sig = SigView{ .params = &p, .defaults = &defaults, .is_member = true };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{ .member = true }).?;
    // Member base is 0 (no -1); only one arg scored (100), y defaulted.
    try testing.expectEqual(@as(i32, 100), sc.points);
    try testing.expect(!sc.exact_arity);
}

test "applicable member: positional varargs accept zero or many elements" {
    const p = [_]Param{
        .{ .name = "this", .ty = tref("Folder"), .default = null },
        .{ .name = "values", .ty = tref("Int"), .default = null, .is_vararg = true },
    };
    const sig = SigView{ .params = &p, .is_member = true };
    const empty = applicable(&sig, &.{}, .{ .member = true }).?;
    try testing.expect(!empty.exact_arity);

    const many = [_]ArgShape{
        .{ .runtime_class = "Int" },
        .{ .runtime_class = "Int" },
        .{ .runtime_class = "Int" },
    };
    const scored = applicable(&sig, &many, .{ .member = true }).?;
    try testing.expectEqual(@as(i32, 299), scored.points);
    try testing.expect(!scored.exact_arity);
}

test "applicable: callable arg cannot bind a concrete non-function param" {
    const p = [_]Param{
        .{ .name = "this", .ty = tref("Logger"), .default = null },
        .{ .name = "msg", .ty = tref("String"), .default = null },
    };
    const sig = SigView{ .params = &p, .is_member = true };
    const args = [_]ArgShape{.{ .is_lambda = true, .lambda_arity = 0, .lambda_is_literal = true }};
    try testing.expect(applicable(&sig, &args, .{ .member = true }) == null);
    const gp = oneParam("String");
    const gsig = SigView{ .params = &gp };
    try testing.expect(applicable(&gsig, &args, .{}) == null);
}

var mock_subtype_depth: i32 = 3;
fn mockSubtype(_: *anyopaque, _: *const anyopaque, _: []const u8) ?i32 {
    return mock_subtype_depth;
}

test "applicable member: a class-type-param-typed param accepts an unrelated instance through the type_var callback" {
    var dummy: u8 = 0;
    // `put(key: Key)` where `Key` is the owning class's type parameter — the
    // arg's runtime class is unrelated (`Token`), which without the callback
    // is a nominal mismatch (null).
    const p = oneParam("Key");
    const sig = SigView{ .params = &p, .fid = FuncId.from(3), .is_member = true };
    const args = [_]ArgShape{.{ .runtime_class = "Token", .value = @ptrCast(&dummy) }};
    const tv = struct {
        fn cb(_: *anyopaque, fid: FuncId, ty: *const TypeRef) bool {
            return fid.int() == 3 and std.mem.eql(u8, ty.name, "Key");
        }
    }.cb;
    const without = ApplicabilityScope{ .member = true, .ctx = @ptrCast(&dummy) };
    const with = ApplicabilityScope{ .member = true, .ctx = @ptrCast(&dummy), .type_var = tv };
    try testing.expect(applicable(&sig, &args, without) == null);
    try testing.expectEqual(@as(i32, 5), applicable(&sig, &args, with).?.points);
}

test "applicable member does not reinterpret a qualified nominal as a type variable" {
    var dummy: u8 = 0;
    var qualifier = [_]TypeRef{.{
        .name = "#qual:app.Key",
        .nullable = false,
        .args = &.{},
    }};
    const p = [_]Param{.{
        .name = "value",
        .ty = .{ .name = "Key", .nullable = false, .args = qualifier[0..] },
        .default = null,
    }};
    const sig = SigView{ .params = &p, .fid = FuncId.from(3), .is_member = true };
    const args = [_]ArgShape{.{ .runtime_class = "Word", .value = @ptrCast(&dummy) }};
    const tv = struct {
        fn cb(_: *anyopaque, _: FuncId, ty: *const TypeRef) bool {
            for (ty.args) |arg_ty| {
                if (std.mem.startsWith(u8, arg_ty.name, "#qual:")) return false;
            }
            return std.mem.eql(u8, ty.name, "Key");
        }
    }.cb;
    const scope = ApplicabilityScope{
        .member = true,
        .ctx = @ptrCast(&dummy),
        .type_var = tv,
    };
    try testing.expect(applicable(&sig, &args, scope) == null);
}

test "applicable member vs global: instance subtype tier formula differs" {
    var dummy: u8 = 0;
    const p = oneParam("Bar");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Foo", .value = @ptrCast(&dummy) }};
    mock_subtype_depth = 3;
    const gscope = ApplicabilityScope{ .subtype = mockSubtype, .ctx = @ptrCast(&dummy) };
    const mscope = ApplicabilityScope{ .member = true, .subtype = mockSubtype, .ctx = @ptrCast(&dummy) };
    try testing.expectEqual(@as(i32, 57), applicable(&sig, &args, gscope).?.points); // 60 - min(3,50)
    try testing.expectEqual(@as(i32, 72), applicable(&sig, &args, mscope).?.points); // 75 - min(3,20)
}

// --- extension ranking ------------------------------------------------------

test "applicable extension: ext_key mirrors ExtKey tuple" {
    const p = [_]Param{
        .{ .name = "this", .ty = tref("Animal"), .default = null },
        .{ .name = "other", .ty = tref("Animal"), .default = null },
    };
    const sig = SigView{ .params = &p, .is_extension = true, .fid = FuncId.from(7), .package = "" };
    const recv = ArgShape{ .runtime_class = "Animal" };
    const args = [_]ArgShape{.{ .runtime_class = "Animal" }};
    const scope = ApplicabilityScope{
        .member = true,
        .rank_extensions = true,
        .is_extension = true,
        .receiver = recv,
    };
    const sc = applicable(&sig, &args, scope).?;
    const key = sc.ext_key.?;
    // { applicable, is_user, spec, recv_match, score, owner_rank, param_spec, neg_defaults, neg_fid }
    try testing.expectEqual(@as(i32, 1), key[0]); // applicable
    try testing.expectEqual(@as(i32, 1), key[1]); // is_user (empty package)
    try testing.expectEqual(@as(i32, 0), key[2]); // spec (no all_candidates)
    try testing.expectEqual(@as(i32, 0), key[3]); // recv_match (no callback)
    // recv head-match 100 * 1000 + arg head-match 100 + exact-arity 5.
    try testing.expectEqual(@as(i32, 100105), key[4]);
    try testing.expectEqual(@as(i32, 0), key[5]); // owner_rank (no callback)
    try testing.expectEqual(@as(i32, 1), key[6]); // param_spec (Animal concrete)
    try testing.expectEqual(@as(i32, 0), key[7]); // neg_defaults (exact arity)
    try testing.expectEqual(@as(i32, -7), key[8]); // neg_fid
    try testing.expect(sc.exact_arity);
}

test "applicable extension: under-applied param that is neither default nor vararg is inapplicable tier" {
    const p = [_]Param{
        .{ .name = "this", .ty = tref("Animal"), .default = null },
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    const sig = SigView{ .params = &p, .is_extension = true, .fid = FuncId.from(3) };
    const recv = ArgShape{ .runtime_class = "Animal" };
    // want = 2, params.len = 3, param b (idx 2) is neither default nor vararg.
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const scope = ApplicabilityScope{ .member = true, .rank_extensions = true, .is_extension = true, .receiver = recv };
    const sc = applicable(&sig, &args, scope).?;
    try testing.expectEqual(@as(i32, 0), sc.ext_key.?[0]); // applicable tier = 0
}

test "applicable extension: trailing lambda binds to the last function-typed param over a defaulted gap" {
    // The `produce {}` shape: f(ctx: Ctx = …, cap: Int = …, block: () -> T)
    // called with only a trailing lambda must be fully applicable, while a
    // sibling whose first param lacks a default must not be.
    const good = [_]Param{
        .{ .name = "this", .ty = tref("Scope"), .default = null },
        .{ .name = "ctx", .ty = tref("Ctx"), .default = null, .has_default = true },
        .{ .name = "cap", .ty = tref("Int"), .default = null, .has_default = true },
        .{ .name = "block", .ty = tref("Function0"), .default = null },
    };
    const bad = [_]Param{
        .{ .name = "this", .ty = tref("Scope"), .default = null },
        .{ .name = "ctx", .ty = tref("Job"), .default = null },
        .{ .name = "cap", .ty = tref("Int"), .default = null, .has_default = true },
        .{ .name = "block", .ty = tref("Function0"), .default = null },
    };
    const recv = ArgShape{ .runtime_class = "Scope" };
    const args = [_]ArgShape{.{ .runtime_class = "Function0", .func_typed = true, .is_lambda = true }};
    const scope = ApplicabilityScope{ .member = true, .rank_extensions = true, .is_extension = true, .receiver = recv };

    const good_sig = SigView{ .params = &good, .is_extension = true, .fid = FuncId.from(1) };
    const good_sc = applicable(&good_sig, &args, scope).?;
    try testing.expectEqual(@as(i32, 1), good_sc.ext_key.?[0]);

    const bad_sig = SigView{ .params = &bad, .is_extension = true, .fid = FuncId.from(2) };
    const bad_sc = applicable(&bad_sig, &args, scope).?;
    try testing.expectEqual(@as(i32, 0), bad_sc.ext_key.?[0]);
}

// --- named-argument scorer ---------------------------------------------------

test "applicable named: reordered named args bind by name and record the binding" {
    const p = [_]Param{
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    const sig = SigView{ .params = &p };
    // Call `f(b = 1, a = 2)` — supplied out of declared order.
    const args = [_]ArgShape{
        .{ .runtime_class = "Int", .named = "b" },
        .{ .runtime_class = "Int", .named = "a" },
    };
    var bind_buf: [2]u16 = undefined;
    const scope = ApplicabilityScope{ .named = true, .arg_to_param_buf = &bind_buf };
    const sc = applicable(&sig, &args, scope).?;
    // Two exact head matches; named scorer carries no exact-arity flag.
    try testing.expectEqual(@as(i32, 200), sc.points);
    try testing.expectEqual(@as(u16, 1), sc.binding.arg_to_param[0]); // b -> param 1
    try testing.expectEqual(@as(u16, 0), sc.binding.arg_to_param[1]); // a -> param 0
}

test "applicable named: an external member receiver fills the this parameter" {
    const p = [_]Param{
        .{ .name = "this", .ty = tref("Canvas"), .default = null },
        .{ .name = "color", .ty = tref("Color"), .default = null },
    };
    const sig = SigView{ .params = &p, .is_member = true };
    const args = [_]ArgShape{.{ .runtime_class = "Color", .named = "color" }};
    try testing.expect(applicable(&sig, &args, .{ .named = true }) == null);
    const sc = applicable(
        &sig,
        &args,
        .{ .named = true, .member = true, .recv_external = true },
    ).?;
    try testing.expectEqual(@as(i32, 100), sc.points);
}

test "applicable named: a typealias function parameter accepts a trailing lambda" {
    var dummy: u8 = 0;
    const p = [_]Param{
        .{ .name = "flags", .ty = tref("Int"), .default = null, .has_default = true },
        .{ .name = "block", .ty = tref("HandlerAlias"), .default = null },
    };
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .is_lambda = true, .lambda_arity = 0 }};
    const callbacks = struct {
        fn isFunc(_: *anyopaque, ty: *const TypeRef) bool {
            return std.mem.eql(u8, ty.name, "HandlerAlias");
        }
    };
    try testing.expect(applicable(&sig, &args, .{ .named = true }) == null);
    const sc = applicable(&sig, &args, .{
        .named = true,
        .ctx = @ptrCast(&dummy),
        .func_type = callbacks.isFunc,
    }).?;
    try testing.expectEqual(@as(?u16, 1), sc.binding.trailing_lambda_param);
}

test "applicable named: Compose pair preserves the source trailing lambda" {
    const short = [_]Param{
        .{ .name = "modifier", .ty = tref("Modifier"), .default = null },
        .{ .name = "$composer", .ty = tref("Composer"), .default = null },
        .{ .name = "$changed", .ty = tref("Int"), .default = null },
    };
    const content = [_]Param{
        .{ .name = "modifier", .ty = tref("Modifier"), .default = null, .has_default = true },
        .{ .name = "alignment", .ty = tref("Alignment"), .default = null, .has_default = true },
        .{ .name = "propagate", .ty = tref("Boolean"), .default = null, .has_default = true },
        .{ .name = "content", .ty = tref("Function0"), .default = null },
        .{ .name = "$composer", .ty = tref("Composer"), .default = null },
        .{ .name = "$changed", .ty = tref("Int"), .default = null },
    };
    const args = [_]ArgShape{
        .{ .runtime_class = "Function0", .func_typed = true, .is_lambda = true },
        .{ .runtime_class = "Composer", .named = "$composer" },
        .{ .runtime_class = "Int", .named = "$changed" },
    };
    var short_bind: [3]u16 = undefined;
    const short_score = applicable(
        &.{ .params = &short },
        &args,
        .{ .named = true, .arg_to_param_buf = &short_bind },
    ).?;
    var content_bind: [3]u16 = undefined;
    const content_score = applicable(
        &.{ .params = &content },
        &args,
        .{ .named = true, .arg_to_param_buf = &content_bind },
    ).?;

    try testing.expect(content_score.points > short_score.points);
    try testing.expectEqual(@as(?u16, 3), content_score.binding.trailing_lambda_param);
    try testing.expectEqualSlices(u16, &.{ 3, 4, 5 }, content_score.binding.arg_to_param);
}

test "applicable named: the generated Compose pair only binds a candidate that declares it" {
    // With the pre-resolution call-threading oracle retired, a
    // `$composer`/`$changed` pair only reaches calls whose resolved target
    // (or the member-miss completion's probe) declares it. A candidate that
    // does NOT declare the pair is therefore inapplicable to a
    // pair-carrying call — the reverse of the absorber this test used to
    // pin, whose leniency existed only for the oracle's stray appends.
    const plain = [_]Param{
        .{ .name = "enabled", .ty = tref("Boolean"), .default = null },
    };
    const composable = [_]Param{
        .{ .name = "enabled", .ty = tref("Boolean"), .default = null },
        .{ .name = "$composer", .ty = tref("Composer"), .default = null },
        .{ .name = "$changed", .ty = tref("Int"), .default = null },
    };
    const args = [_]ArgShape{
        .{ .runtime_class = "Boolean", .named = "enabled" },
        .{ .runtime_class = "Composer", .named = "$composer" },
        .{ .runtime_class = "Int", .named = "$changed" },
    };
    try testing.expect(applicable(&.{ .params = &plain }, &args, .{ .named = true }) == null);
    try testing.expect(applicable(&.{ .params = &composable }, &args, .{ .named = true }) != null);

    // A source-level named argument that names no parameter remains a hard
    // reject.
    const bogus = [_]ArgShape{
        .{ .runtime_class = "Boolean", .named = "enabled" },
        .{ .runtime_class = "Int", .named = "notAParameter" },
    };
    try testing.expect(applicable(&.{ .params = &plain }, &bogus, .{ .named = true }) == null);
}

test "applicable named: non-final vararg absorbs values before a named tail" {
    const p = [_]Param{
        .{ .name = "a", .ty = tref("T"), .default = null },
        .{ .name = "other", .ty = tref("T"), .default = null, .is_vararg = true },
        .{ .name = "comparator", .ty = tref("Comparator"), .default = null },
    };
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{
        .{ .runtime_class = "Card" },
        .{ .runtime_class = "Card" },
        .{ .runtime_class = "Card" },
        .{ .runtime_class = "Comparator", .named = "comparator" },
    };
    var bind_buf: [4]u16 = undefined;
    const scope = ApplicabilityScope{ .named = true, .arg_to_param_buf = &bind_buf };
    const sc = applicable(&sig, &args, scope).?;
    try testing.expectEqualSlices(u16, &.{ 0, 1, 1, 2 }, sc.binding.arg_to_param);
}

test "applicable named: non-final vararg leaves a required positional tail" {
    const p = [_]Param{
        .{ .name = "head", .ty = tref("Int"), .default = null },
        .{ .name = "middle", .ty = tref("Int"), .default = null, .is_vararg = true },
        .{ .name = "tail", .ty = tref("String"), .default = null },
    };
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{
        .{ .runtime_class = "Int" },
        .{ .runtime_class = "Int" },
        .{ .runtime_class = "String" },
    };
    var bind_buf: [3]u16 = undefined;
    const scope = ApplicabilityScope{ .named = true, .arg_to_param_buf = &bind_buf };
    const sc = applicable(&sig, &args, scope).?;
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, sc.binding.arg_to_param);
}

test "applicable named: a name matching no parameter is a hard reject" {
    const p = oneParam("Int");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Int", .named = "nope" }};
    try testing.expect(applicable(&sig, &args, .{ .named = true }) == null);
}

test "applicable named: a per-arg type mismatch is neutral (scores 0), not disqualifying" {
    const p = [_]Param{
        .{ .name = "x", .ty = tref("Int"), .default = null },
        .{ .name = "y", .ty = tref("String"), .default = null },
    };
    const sig = SigView{ .params = &p };
    // `y = <Int>` type-mismatches the String param but is not rejected; it
    // scores 0 and the candidate stays applicable (named presence is the
    // discriminator).
    const args = [_]ArgShape{
        .{ .runtime_class = "Int", .named = "x" },
        .{ .runtime_class = "Int", .named = "y" },
    };
    const sc = applicable(&sig, &args, .{ .named = true }).?;
    // x exact 100 + y neutral 0.
    try testing.expectEqual(@as(i32, 100), sc.points);
}

test "applicable named: unfilled non-default parameter is a reject; a default pads with -1" {
    const p = [_]Param{
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    const args = [_]ArgShape{.{ .runtime_class = "Int", .named = "a" }};
    // No default for b -> reject.
    const sig_nd = SigView{ .params = &p };
    try testing.expect(applicable(&sig_nd, &args, .{ .named = true }) == null);
    // b defaulted -> applicable with the -1 default-padding penalty.
    const defaults = [_]?FuncId{ null, FuncId.from(0) };
    const sig_d = SigView{ .params = &p, .defaults = &defaults };
    const sc = applicable(&sig_d, &args, .{ .named = true }).?;
    try testing.expectEqual(@as(i32, 99), sc.points); // 100 - 1
}

test "applicable named: defaulted trailing param stays fillable for named Int args" {
    // `Color(red = 0, green = 0, blue = 0)` against the Int factory
    // `Color(red: Int, green: Int, blue: Int, alpha: Int = 0xFF)`.
    const factory = [_]Param{
        .{ .name = "red", .ty = tref("Int"), .default = null },
        .{ .name = "green", .ty = tref("Int"), .default = null },
        .{ .name = "blue", .ty = tref("Int"), .default = null },
        .{ .name = "alpha", .ty = tref("Int"), .default = null, .has_default = true },
    };
    const args = [_]ArgShape{
        .{ .runtime_class = "Int", .named = "red" },
        .{ .runtime_class = "Int", .named = "green" },
        .{ .runtime_class = "Int", .named = "blue" },
    };
    try testing.expect(applicable(&.{ .params = &factory }, &args, .{ .named = true }) != null);
}


test "applicable: unbindable trailing-lambda reading falls through to the positional fill" {
    // `render({..}, {..})` against `(leading: (Int) -> Unit,
    // trailing: (Int, String) -> Unit, plain: ((Int) -> Int)? = null)`:
    // the out-of-sequence trailing reading needs the gap param `trailing`
    // defaulted (it is not), so the positional fill must still bind —
    // leading and trailing positionally, `plain` from its default.
    const p = [_]Param{
        .{ .name = "leading", .ty = tref("Function1"), .default = null },
        .{ .name = "trailing", .ty = tref("Function2"), .default = null },
        .{ .name = "plain", .ty = tref("Function1"), .default = null, .has_default = true },
    };
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{
        .{ .is_lambda = true, .lambda_arity = 1, .lambda_is_literal = true },
        .{ .is_lambda = true, .lambda_arity = 2, .lambda_is_literal = true },
    };
    const sc = applicable(&sig, &args, .{}).?;
    try testing.expect(sc.binding.trailing_lambda_param == null);
}
