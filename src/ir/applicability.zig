//! Shared overload-resolution applicability engine.
//!
//! `applicable()` scores one candidate signature against actual arguments
//! described by `ArgShape`, folding arity, default, vararg and trailing-lambda
//! binding with the per-argument points. A null `ArgShape` field is UNKNOWN
//! evidence and never disproves a candidate; value-dependent deltas arrive
//! through the `ApplicabilityScope` callbacks.

const std = @import("std");

const ir = @import("ir");
const span_mod = @import("span");

const TypeRef = ir.TypeRef;
const Param = ir.Param;
const FuncId = ir.FuncId;

pub const LiteralKind = enum { numeric, string, boolean, char };

/// One actual argument at overload-pick time. Borrows, never allocates; a null
/// field downgrades that argument to unknown, never to disproven.
pub const ArgShape = struct {
    /// Declared static type; runtime value args leave it null for `runtime_class`.
    ty: ?TypeRef = null,

    /// `ty` came from source or declaration metadata; static resolution rejects
    /// a candidate only on authoritative evidence.
    ty_authoritative: bool = true,

    /// The argument is written `expr as Any`: its static type is exactly `Any`,
    /// which no parameter of a concrete class type accepts.
    cast_any: bool = false,

    /// The argument is callable, which gates trailing-lambda binding.
    is_lambda: bool = false,

    /// Declared parameter count of a callable argument; feeds the `FunctionN` score.
    lambda_arity: ?u8 = null,

    /// Runtime typeFqn starts with `kotlin.Function`: the callable gate for an
    /// argument carrying no `lambda_arity`.
    func_typed: bool = false,

    /// `lambda_arity` is a call-site literal's header count, so it ranks
    /// exactly; a runtime closure's count includes lowering-added slots.
    lambda_is_literal: bool = false,

    /// Declared lambda parameter types when the caller can see them.
    lambda_param_types: ?[]const TypeRef = null,

    /// Named-argument name for this slot (`x = ...`), else null (positional).
    named: ?[]const u8 = null,

    is_spread: bool = false,

    is_null: bool = false,

    /// Runtime class simple-name; only the runtime callers set it.
    runtime_class: ?[]const u8 = null,

    literal_kind: ?LiteralKind = null,

    /// Opaque runtime `*const Value`, passed to the scope callbacks.
    value: ?*const anyopaque = null,
};

/// Where each supplied arg landed, plus defaulted params and vararg bounds. The
/// per-caller adapters own the scratch buffer the slice fields point into.
pub const Binding = struct {
    arg_to_param: []const u16 = &.{},
    default_params: []const u16 = &.{},
    vararg_param: ?u16 = null,
    vararg_lo: u16 = 0,
    vararg_hi: u16 = 0,
    trailing_lambda_param: ?u16 = null,
};

/// A ranked verdict; a null `applicable()` result means a definite mismatch.
pub const Score = struct {
    /// Sum of per-arg points: exact head 100, numeric widen 40/30, callable
    /// arity 90, builtin super 75-dist, subtype 60-dist, `Any` 10, SAM 8, type
    /// parameter 5, `Unit` 1, plus -1 when defaults fill an under-application.
    points: i32,

    /// Proven versus unknown evidence counts; a secondary tiebreak only.
    proven_args: u16 = 0,
    unknown_args: u16 = 0,

    /// Exactly one arg per fixed parameter, with no defaults or vararg packing.
    exact_arity: bool = false,

    /// Carried, not pre-applied: each caller keeps its own convention.
    low_priority: bool = false,

    is_member: bool = false,

    /// Extension-only lexicographic ranking tuple; null unless `rank_extensions`.
    ext_key: ?[9]i32 = null,

    binding: Binding = .{},
};

/// Per-candidate signature view over the slices the scorer reads off an `ir.Func`.
pub const SigView = struct {
    params: []const Param,
    /// Default-thunk table for the candidate (`func_defaults`): `defaults[i] !=
    /// null` means param `i` has a default. Null means no defaults at all.
    defaults: ?[]const ?FuncId = null,
    /// A bodyless expect or native stub is never selectable.
    has_body: bool = true,
    /// `@LowPriorityInOverloadResolution` / error-level `@Deprecated`.
    low_priority: bool = false,
    is_member: bool = false,
    is_extension: bool = false,
    /// Candidate `FuncId`: the `neg_fid` tiebreak and the self-skip in `spec`.
    fid: ?FuncId = null,
    /// Declaring package; `""` or an unknown package is the `is_user` tier.
    package: []const u8 = "",
};

/// Refinement callbacks and phase flags injected by the caller. The runtime
/// callers pass `ctx = *VmHost`; lowering and eager typeck leave them null.
pub const ApplicabilityScope = struct {
    is_extension: bool = false,
    check_low_priority: bool = false,

    /// Named-argument scoring: each `named` arg binds its distinct same-named
    /// parameter, positional args fill the rest, unfilled non-vararg parameters
    /// must default, and a per-arg type mismatch is neutral, not disqualifying.
    named: bool = false,

    /// The call site supplies an implicit extension receiver, filling `this`.
    recv_external: bool = false,

    /// Caller-owned scratch the named path's `Binding.arg_to_param` points into.
    arg_to_param_buf: ?[]u16 = null,

    /// Member scoring conventions: an unparseable `Function` arity scores 20, a
    /// callable against a concrete non-function param disqualifies, the subtype
    /// tier is `75 - min(depth, 20)`, the base score is 0, and the `this`
    /// receiver slot is skipped before value scoring.
    member: bool = false,

    /// Fill `Score.ext_key`; `params[0]` is the receiver, args bind `params[1..]`.
    rank_extensions: bool = false,

    /// Extension receiver shape; required when `rank_extensions`.
    receiver: ?ArgShape = null,

    /// The whole extension overload set, for the `spec` tier; `fid` skips self.
    all_candidates: ?[]const SigView = null,

    /// Opaque context (a `*VmHost`) threaded to the callbacks.
    ctx: ?*anyopaque = null,

    /// Declared-generic and function-shape delta; null disqualifies the candidate.
    refine: ?*const fn (*anyopaque, *const TypeRef, *const anyopaque) ?i32 = null,

    /// BFS depth from the value's class to `target`; null when unreached.
    subtype: ?*const fn (*anyopaque, *const anyopaque, []const u8) ?i32 = null,

    /// Whether a qualified parameter type and the argument's runtime class
    /// denote different same-named classes; true skips the exact-name tier.
    identity_conflict: ?*const fn (*anyopaque, *const TypeRef, *const anyopaque) bool = null,

    /// Function-typed param test with typealias indirection resolved.
    func_type: ?*const fn (*anyopaque, *const TypeRef) bool = null,

    /// Whether a parameter type is a type variable in scope for `fid`. The
    /// complete `TypeRef` keeps a qualified nominal from reading as one.
    type_var: ?*const fn (*anyopaque, FuncId, *const TypeRef) bool = null,

    /// Runtime equivalence of alternate spellings of one head (`Modifier.Node`
    /// and `Modifier$Node`). No simple-name fallback: same names stay distinct.
    exact_head: ?*const fn (*anyopaque, []const u8, []const u8) bool = null,

    /// Runtime dispatch cannot tell a constant narrowed to `Byte`/`Short` from
    /// an `Int`, so it allows same-signedness widths; factories leave it false.
    erased_integer_widths: bool = false,

    /// The extension `recv_match` tier: receiver specificity.
    ext_recv_match: ?*const fn (*anyopaque, *const anyopaque, []const u8) i32 = null,

    /// Whether head `a` is a proper subtype of `b`, for the extension `spec` tier.
    ext_is_subtype_name: ?*const fn (*anyopaque, []const u8, []const u8) bool = null,

    /// Owner rank for a member-extension nearer on the enclosing-`this` chain.
    ext_owner_rank: ?*const fn (*anyopaque, FuncId) i32 = null,

    /// Whether `package` is a shipped pack; its negation is the `is_user` tier.
    ext_known_package: ?*const fn ([]const u8) bool = null,
};

/// Nominal supertypes a builtin head satisfies; list position is the distance.
pub fn builtinSupersOf(concrete: []const u8) []const []const u8 {
    const eq = std.mem.eql;
    const s = simpleName(concrete);
    // The boxed numerics are `Number`s: a runtime `Int` satisfies `Number?`.
    if (eq(u8, s, "Int") or eq(u8, s, "Long") or eq(u8, s, "Short") or eq(u8, s, "Byte") or
        eq(u8, s, "Double") or eq(u8, s, "Float"))
        return &.{ "Number", "Comparable" };
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

pub fn simpleName(name: []const u8) []const u8 {
    if (std.mem.findScalarLast(u8, name, '.')) |i| return name[i + 1 ..];
    return name;
}

/// Suffix the `@Composable` lowering appends to a defaulted parameter, so named
/// binding must treat `p` and `p$arg` as one parameter.
pub const composable_arg_suffix = "$arg";

/// Identity, or the compose rename `param_name == arg_name ++ "$arg"`.
pub fn paramNameMatchesArg(param_name: []const u8, arg_name: []const u8) bool {
    if (std.mem.eql(u8, param_name, arg_name)) return true;
    return arg_name.len != 0 and
        param_name.len == arg_name.len + composable_arg_suffix.len and
        std.mem.startsWith(u8, param_name, arg_name) and
        std.mem.endsWith(u8, param_name, composable_arg_suffix);
}

/// Compose's generated markers: their absence must not disqualify a candidate.
pub fn isGeneratedComposeArg(name: []const u8) bool {
    return std.mem.eql(u8, name, "$composer") or std.mem.eql(u8, name, "$changed");
}

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// The member scorer's short-type-parameter test, which allows digits (`T1`).
fn allUpperOrDigit(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

/// A maximally-unspecific head, which the extension `param_spec` tier counts against.
fn isTopOrGenericType(ty_name: []const u8) bool {
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) return true;
    if (pn.len > 0 and pn.len <= 2 and allUpperOrDigit(pn)) return true;
    return false;
}

/// A concrete builtin a callable can never satisfy; user heads stay SAM-eligible.
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

fn scopeIsFunctionType(scope: *const ApplicabilityScope, ty: *const TypeRef) bool {
    if (scope.func_type) |cb| return cb(scope.ctx.?, ty);
    return isFunctionTypeRef(ty);
}

fn sameFid(a: ?FuncId, b: ?FuncId) bool {
    const x = a orelse return false;
    const y = b orelse return false;
    return x.int() == y.int();
}

pub fn isFunctionTypeRef(ty: *const TypeRef) bool {
    const n = simpleName(ty.name);
    return std.mem.startsWith(u8, n, "Function") or
        std.mem.find(u8, ty.name, "->") != null;
}

fn paramHasDefault(sig: *const SigView, i: usize) bool {
    // A null `defaults` slice is the lowering adapter, which cannot read the
    // image-side thunk table and carries the flag on the params instead.
    const defs = sig.defaults orelse
        return i < sig.params.len and sig.params[i].has_default;
    return i < defs.len and defs[i] != null;
}

/// Refinement delta; a null callback contributes 0 and never disqualifies.
fn refineDelta(scope: *const ApplicabilityScope, param_ty: *const TypeRef, arg: *const ArgShape) ?i32 {
    const cb = scope.refine orelse return 0;
    const v = arg.value orelse return 0;
    return cb(scope.ctx.?, param_ty, v);
}

fn subtypeDepth(scope: *const ApplicabilityScope, arg: *const ArgShape, target: []const u8) ?i32 {
    const cb = scope.subtype orelse return null;
    const v = arg.value orelse return null;
    return cb(scope.ctx.?, v, target);
}

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

/// Fallback score when no runtime head was proven; never disqualifies.
fn unknownArgScore(nm: []const u8) i32 {
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (nm.len <= 2 and allAsciiUpper(nm)) return 5;
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    return 10;
}

/// Evidence head: the simple name, with a lift mangle (`Outer$Name`) stripped.
fn evidenceHead(name: []const u8) []const u8 {
    const sn = std.mem.trimEnd(u8, simpleName(name), "?");
    if (std.mem.findScalarLast(u8, sn, '$')) |i| {
        if (i + 1 < sn.len) return sn[i + 1 ..];
    }
    return sn;
}

/// Declared-type evidence for a (param, arg) pair: 100 for a head match or for
/// two type-parameter heads, else null so the caller falls back to unknown.
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

/// Two integer heads of one signedness; klio stores every width uniformly.
fn sameSignednessInt(a: []const u8, b: []const u8) bool {
    return (signedIntHead(a) and signedIntHead(b)) or
        (unsignedIntHead(a) and unsignedIntHead(b));
}

/// Literal-kind evidence: a numeric literal matches any numeric head, and so on.
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

/// Evidence bonus for ranking same-rung candidates: 100 per declared head or
/// literal-kind match, 80 for a numeric head of another width, 0 without evidence.
pub fn tyEvidenceBonus(params: []const Param, args: []const ArgShape) i32 {
    return tyEvidenceBonusScoped(params, args, .{});
}

/// `tyEvidenceBonus` with the caller's scope: a declared head that is a subtype
/// of the parameter head counts as weaker evidence.
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

/// The declared value parameter types of a lowered function type, or null when
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

/// Score one (param, arg) pair; higher is better, null disqualifies.
fn scoreArg(sig: *const SigView, param_ty: *const TypeRef, arg: *const ArgShape, scope: *const ApplicabilityScope) ?i32 {
    const nm = param_ty.name;
    const member = scope.member;
    const shape_callable = arg.lambda_arity != null or arg.func_typed or arg.is_lambda;

    // Runtime head; without one, declared-type evidence, else the unknown base.
    const v_ty = arg.runtime_class orelse blk: {
        // A lambda literal has no runtime class; its callable shape is authoritative.
        if (shape_callable) break :blk "$callable$";
        if (arg.ty) |aty| {
            if (tyEvidenceScore(nm, aty.name, member)) |s| return s;
            // A declared head that is a subtype of the parameter head proves
            // the candidate, splitting overloads an unknown score would tie.
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
        // Refused when parameter and value denote different same-named classes.
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
    // Cross-width integers of one signedness apply at a low score: the literal
    // coercion kotlinc validated is gone by dispatch, so `append(1)` must still
    // bind `append(byte: Byte)`. Kotlin forbids a signed `Int` against `UByte`.
    if (scope.erased_integer_widths and sameSignednessInt(nm, v_ty)) return 20;

    // The member scorer does not treat a `$bound_ref$` head as callable.
    const arg_arity: ?usize = if (arg.lambda_arity) |n| @as(usize, n) else null;
    const is_bound_ref = !member and std.mem.startsWith(u8, v_ty, "$bound_ref$");
    const is_callable = shape_callable or is_bound_ref;
    if (is_callable) {
        // A literal annotating its parameters states their types. Refute only
        // on a definite mismatch, two different builtin scalars.
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
                    // nor a type parameter.
                    if (builtinScalarHead(eh) and dh.len > 1 and !builtinScalarHead(dh) and
                        !std.mem.eql(u8, dh, "Any") and !std.mem.startsWith(u8, dh, "Function")) return null;
                }
            }
        }
        if (std.mem.startsWith(u8, nm, "Function")) {
            const expected = nm["Function".len..];
            if (std.fmt.parseInt(usize, expected, 10)) |want| {
                if (arg_arity) |got| {
                    // A literal's arity is authoritative: an exact param count
                    // outranks the adapted shapes, and a headerless literal
                    // still serves a 1-param type via `it`.
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
        // A callable cannot bind a concrete builtin scalar or container; an
        // unknown user head stays eligible as a possible fun interface.
        if (isDefinitelyNonFunctionTypeName(simpleName(nm))) return null;
        return 8;
    }

    // Instance subtype, distance-weighted: `75 - min(depth, 20)` for the member
    // scorer, `60 - min(depth, 50)` for the global one.
    if (subtypeDepth(scope, arg, nm)) |depth| {
        if (member) {
            const d: i32 = if (depth > 20) 20 else depth;
            return 75 - d;
        }
        const d: i32 = if (depth > 50) 50 else depth;
        return 60 - d;
    }

    // Builtin runtime types satisfy their nominal supertypes.
    const builtin_supers = builtinSupersOf(v_ty);
    const nm_simple = std.mem.trimEnd(u8, simpleName(nm), "?");
    for (builtin_supers, 0..) |sup, pos| {
        if (std.mem.eql(u8, sup, nm) or std.mem.eql(u8, sup, nm_simple)) {
            const dist: i32 = if (pos > 20) 20 else @intCast(pos);
            const d = refineDelta(scope, param_ty, arg) orelse return null;
            return 75 - dist + d;
        }
    }

    // A short type-parameter head accepts anything (member allows digits).
    const short_typaram = if (member) allUpperOrDigit(nm) else allAsciiUpper(nm);
    var qualified_nominal = false;
    for (param_ty.args) |arg_ty| {
        if (std.mem.startsWith(u8, arg_ty.name, "#qual:")) {
            qualified_nominal = true;
            break;
        }
    }
    if (!qualified_nominal and nm.len <= 2 and short_typaram) return 5;
    // A `Unit` param accepts anything but ranks lowest.
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    // A param typed by an in-scope type variable accepts anything, like `T`.
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

/// Source position of the extension call being scored. Diagnostic only, written
/// only under `KLIO_EXTKEY_TRACE`, and kept off the hot `ApplicabilityScope`.
pub threadlocal var trace_call_span: ?ir.Span = null;

/// Source name of the call being scored; names stay stable across rebuilds.
pub threadlocal var trace_call_name: ?[]const u8 = null;

/// Whether any `[extkey]` tracing is on, so callers can skip keeping the span.
pub fn extKeyTraceEnabled() bool {
    return std.c.getenv("KLIO_EXTKEY_TRACE") != null;
}

/// `KLIO_EXTKEY_TRACE=<name|fid>[,...]` gate: a numeric token selects one
/// candidate by `FuncId`, anything else every candidate of that call name.
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

/// The element type of a vararg parameter's materialized array type:
/// `ByteArray` to `Byte`, `Array<T>` to `T`. A non-array type is unchanged.
pub fn varargElementRef(param_ty: *const TypeRef) TypeRef {
    const n = param_ty.name;
    const eq = std.mem.eql;
    const elem: ?[]const u8 =
        if (eq(u8, n, "ByteArray")) "Byte" else if (eq(u8, n, "ShortArray")) "Short" else if (eq(u8, n, "IntArray")) "Int" else if (eq(u8, n, "LongArray")) "Long" else if (eq(u8, n, "FloatArray")) "Float" else if (eq(u8, n, "DoubleArray")) "Double" else if (eq(u8, n, "CharArray")) "Char" else if (eq(u8, n, "BooleanArray")) "Boolean" else if (eq(u8, n, "UByteArray")) "UByte" else if (eq(u8, n, "UShortArray")) "UShort" else if (eq(u8, n, "UIntArray")) "UInt" else if (eq(u8, n, "ULongArray")) "ULong" else if ((eq(u8, n, "Array") or eq(u8, n, "Array?")) and param_ty.args.len > 0) param_ty.args[0].name else null;
    if (elem) |e| return .{ .name = e, .nullable = param_ty.nullable, .args = &.{} };
    return param_ty.*;
}

/// Score one candidate against the actual args; null means a definite mismatch.
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

    // Non-final vararg plus trailing lambda: the lambda binds the final
    // function-typed param out of sequence, the vararg absorbs the positional
    // middle, and params between them must default (Kotlin fills those by name).
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

    // Non-final vararg, purely positional: the vararg absorbs every remaining
    // positional, and every parameter after it must default.
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
    // function-typed parameter when the gap is all-defaulted. A shape this
    // cannot bind falls through to the positional fill, it is not rejected.
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

    // Under-applied: every unfilled parameter must default or be a vararg.
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

    // Kotlin prefers a fixed overload to an otherwise equal vararg one.
    var total: i32 = if (params.len == args.len and !last_vararg) 0 else -1;
    var proven: u16 = 0;
    var unknown: u16 = 0;
    // A trailing vararg absorbs the args from its position onward, each against
    // the element type unless it is a spread: a `ByteArray` cannot fill `vararg Byte`.
    const vp: ?usize = if (last_vararg) params.len - 1 else null;
    var idx: usize = 0;
    while (idx < params.len and idx < args.len) : (idx += 1) {
        if (vp != null and idx == vp.?) break;
        if (params[idx].is_vararg) {
            // A mid-position vararg fed one packed array: neutral, counted unknown.
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

/// Score one member candidate; `sig.params` includes the implicit `this` slot,
/// skipped by name. Base 0: the caller applies `+5` exact-arity, `-1000` low-priority.
fn applicableMember(sig: *const SigView, args: []const ArgShape, scope: ApplicabilityScope) ?Score {
    const params = sig.params;
    const skip: usize = if (params.len > 0 and std.mem.eql(u8, params[0].name, "this")) 1 else 0;
    const effective = params[skip..];

    // A trailing lambda binds the last function-typed param over a defaulted gap.
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
        // Gap not all-defaulted: fall through to the plain arity check.
    }

    // A member vararg binds every argument from its position onward as an
    // element, a spread against the array type; later params must be defaultable.
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

    // Over-supply with no vararg tail cannot bind.
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

// Extension ranking always returns a Score: an inapplicable candidate is not
// dropped, it ranks lowest through `ext_key[0] == 0`.

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
    // A trailing lambda binds the last function-typed param over a defaulted gap.
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
    // Every param past the supplied args must default or be a vararg.
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

    const recv_match: i32 = blk: {
        const cb = scope.ext_recv_match orelse break :blk 0;
        const rv = if (recv) |r| r.value else null;
        break :blk cb(scope.ctx.?, rv orelse break :blk 0, if (params.len > 0) params[0].ty.name else "");
    };

    // Subtype specificity: how many other candidates' receivers are supertypes.
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

    // A user extension outranks a shipped namesake; an empty package is user code.
    const is_user: i32 = blk: {
        if (sig.package.len == 0) break :blk 1;
        const cb = scope.ext_known_package orelse break :blk 1;
        break :blk @intFromBool(!cb(sig.package));
    };

    // Kotlin prefers the overload filling the fewest defaults; negated to rank first.
    const neg_defaults: i32 = -@as(i32, @intCast(params.len -| want));
    const key: [9]i32 = .{ applic, is_user, spec, recv_match, score, owner_rank, param_spec, neg_defaults, neg_fid };
    // Ranking is lexicographic: the first differing component decides.
    if (extKeyTraceWanted(sig.fid)) {
        // Resolve through the installed source map, else the raw file id and offset.
        var loc_buf: [256]u8 = undefined;
        const loc: []const u8 = if (trace_call_span) |cs| blk: {
            if (span_mod.active_map) |m| {
                if (m.getChecked(cs.file)) |sf| {
                    const lc = sf.lineCol(cs.start);
                    const base = if (std.mem.findScalarLast(u8, sf.path, '/')) |i| sf.path[i + 1 ..] else sf.path;
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

// Named-argument scoring. Only a named arg no parameter accepts, a doubly filled
// parameter, or an over-supplied non-vararg call is a hard reject.

fn applicTraceReject(site: []const u8) void {
    if (comptime !@import("builtin").link_libc) return;
    if (std.c.getenv("KLIO_APPLIC_TRACE") == null) return;
    std.debug.print("[applic-reject] {s}\n", .{site});
}

fn applicableNamed(sig: *const SigView, args: []const ArgShape, scope: ApplicabilityScope) ?Score {
    const params = sig.params;
    // A bodyless declaration is selectable only when it backs a native intrinsic.
    if (!sig.has_body) { applicTraceReject("named-1"); return null; }
    if (params.len > 64) { applicTraceReject("named-2"); return null; }

    var filled = [_]bool{false} ** 64;
    var total: i32 = 0;
    var proven: u16 = 0;
    var unknown: u16 = 0;
    const bind = scope.arg_to_param_buf;

    // An implicit extension receiver fills the leading `this` parameter.
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
        // A named argument no parameter accepts is a hard reject, the generated
        // `$composer`/`$changed` pair included.
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

    // A trailing positional callable binds the last function-typed parameter out
    // of sequence; compose appends its pair after the source lambda.
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

    // Vararg-aware positional walk: Kotlin permits parameters after a vararg, so
    // reserve positionals for the still-unbound, non-defaulted params behind it.
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
        // Kotlin prefers an otherwise equal fixed declaration, as positionally.
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
    try testing.expect(paramNameMatchesArg("onReuse", "onReuse"));
    try testing.expect(paramNameMatchesArg("onReuse$arg", "onReuse"));
    try testing.expect(paramNameMatchesArg("content$arg", "content"));
    try testing.expect(!paramNameMatchesArg("onReuse$arg", "onSet"));
    try testing.expect(!paramNameMatchesArg("onReuse", "onReuse$arg"));
    try testing.expect(!paramNameMatchesArg("$arg", ""));
    try testing.expect(!paramNameMatchesArg("onReuse", "onSet"));
    // The composer/changed pair is never defaulted, so only identity matches.
    try testing.expect(paramNameMatchesArg("$composer", "$composer"));
}

test "applicableNamed: a named arg binds the compose-default-renamed parameter" {
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
    var p = [_]Param{
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    p[1].has_default = true;
    const sig = SigView{ .params = &p, .defaults = null };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{}).?;
    try testing.expectEqual(@as(i32, 99), sc.points);
    try testing.expect(!sc.exact_arity);
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
    const hit = [_]ArgShape{.{ .ty = tref("Double") }};
    try testing.expectEqual(@as(i32, 100), applicable(&sig, &hit, .{}).?.points);
    // A mismatching declared head falls back to unknown, still applicable.
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
    // No evidence: every candidate scores zero.
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
    // `Key` is the owning class's type parameter: without the callback, a mismatch.
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
    // A lambda-only call must apply over a defaulted gap; the sibling must not.
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


test "applicable named: reordered named args bind by name and record the binding" {
    const p = [_]Param{
        .{ .name = "a", .ty = tref("Int"), .default = null },
        .{ .name = "b", .ty = tref("Int"), .default = null },
    };
    const sig = SigView{ .params = &p };
    // Call `f(b = 1, a = 2)`, supplied out of declared order.
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
    // A candidate not declaring the pair is inapplicable to a pair-carrying call.
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

    // A named argument naming no parameter remains a hard reject.
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
    // `y = <Int>` mismatches the `String` param: scores 0, not rejected.
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
    const sig_nd = SigView{ .params = &p };
    try testing.expect(applicable(&sig_nd, &args, .{ .named = true }) == null);
    // b defaulted -> applicable with the -1 default-padding penalty.
    const defaults = [_]?FuncId{ null, FuncId.from(0) };
    const sig_d = SigView{ .params = &p, .defaults = &defaults };
    const sc = applicable(&sig_d, &args, .{ .named = true }).?;
    try testing.expectEqual(@as(i32, 99), sc.points); // 100 - 1
}

test "applicable named: defaulted trailing param stays fillable for named Int args" {
    // `Color(red, green, blue)` against a factory whose `alpha` defaults.
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
    // The gap param is not defaulted, so the positional fill must bind both.
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
