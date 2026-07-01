//! Shared overload-resolution applicability engine.
//!
//! One `applicable()` function scores a single candidate signature against a
//! list of actual arguments described by `ArgShape`. Each caller (lowering
//! ladder, runtime global/member scorers, eager typeck) populates the
//! `ArgShape` fields it can prove at its phase and leaves the rest null; the
//! scorer folds arity / default / vararg / trailing-lambda binding and the
//! per-argument point values in one place.
//!
//! This first slice reproduces the runtime *global* scorer
//! (`host_call_func.zig` `overloadScore` / `overloadScoreArg` /
//! `builtinSupersFor`) verbatim, reading from `ArgShape` instead of a
//! `*const Value`. The two runtime deltas that depend on the live value
//! (declared-generic-argument / function-shape refinement, and instance
//! subtype distance) are supplied by the caller through the `ApplicabilityScope`
//! callbacks; when a callback is null (lowering / eager) the argument is treated
//! as UNKNOWN — it contributes its base points and is never disproven.

const std = @import("std");

const ir = @import("ir");

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

    /// The call supplied exactly one arg per parameter (no defaults used).
    exact_arity: bool = false,

    /// The candidate is `@LowPriorityInOverloadResolution` / HIDDEN. Carried,
    /// not pre-applied; each caller keeps its own convention.
    low_priority: bool = false,

    /// True when this candidate is a member rather than an extension/top-level.
    is_member: bool = false,

    /// Extension-only lexicographic ranking tuple, populated only when a later
    /// caller sets extension ranking. null here.
    ext_key: ?[8]i32 = null,

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
};

/// Runtime-value refinement callbacks and phase flags, injected by the caller.
/// The runtime callers pass `ctx = *VmHost` and wrap `refineByDeclaredArgs` /
/// the instance-subtype BFS; lowering / eager leave them null.
pub const ApplicabilityScope = struct {
    is_extension: bool = false,
    check_low_priority: bool = false,

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

fn allAsciiUpper(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isUpper(c)) return false;
    }
    return true;
}

/// A `TypeRef` denoting a Kotlin function type (mirrors `interp_ir.isFunctionType`).
fn isFunctionTypeRef(ty: *const TypeRef) bool {
    const n = simpleName(ty.name);
    return std.mem.startsWith(u8, n, "Function") or
        std.mem.indexOf(u8, ty.name, "->") != null;
}

fn paramHasDefault(sig: *const SigView, i: usize) bool {
    const defs = sig.defaults orelse return false;
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

/// Value-independent fallback for a caller that could not prove a runtime head
/// (lowering / eager). Never disqualifies (returns a base, never null).
fn unknownArgScore(nm: []const u8) i32 {
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (nm.len <= 2 and allAsciiUpper(nm)) return 5;
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    return 10;
}

// -------------------------------------------------------------------------
// Per-argument scoring (mirror of `overloadScoreArg`).
// -------------------------------------------------------------------------

/// Score one (param, arg) pair. Higher is better; null disqualifies the
/// candidate. Reproduces `host_call_func.zig` `overloadScoreArg` reading from
/// `ArgShape`, deferring value-dependent deltas to the scope callbacks.
fn scoreArg(param_ty: *const TypeRef, arg: *const ArgShape, scope: *const ApplicabilityScope) ?i32 {
    const nm = param_ty.name;

    // Runtime head of the argument. A caller that could not prove one
    // (lowering / eager) scores the arg as unknown.
    const v_ty = arg.runtime_class orelse return unknownArgScore(nm);

    if (std.mem.eql(u8, nm, v_ty)) {
        const d = refineDelta(scope, param_ty, arg) orelse return null;
        return 100 + d;
    }
    if (std.mem.eql(u8, nm, "Any") or std.mem.eql(u8, nm, "Any?")) return 10;
    if (arg.is_null and param_ty.nullable) return 50;

    // Numeric widening: Int -> Long, Int -> Double/Float, Long -> Double.
    if (std.mem.eql(u8, nm, "Long") and std.mem.eql(u8, v_ty, "Int")) return 40;
    if ((std.mem.eql(u8, nm, "Double") or std.mem.eql(u8, nm, "Float")) and std.mem.eql(u8, v_ty, "Int")) return 30;
    if (std.mem.eql(u8, nm, "Double") and std.mem.eql(u8, v_ty, "Long")) return 30;

    // A callable argument against a function-typed parameter.
    const arg_arity: ?usize = if (arg.lambda_arity) |n| @as(usize, n) else null;
    const is_bound_ref = std.mem.startsWith(u8, v_ty, "$bound_ref$");
    const is_callable = arg_arity != null or is_bound_ref or arg.func_typed;
    if (is_callable) {
        if (std.mem.startsWith(u8, nm, "Function")) {
            const expected = nm["Function".len..];
            if (std.fmt.parseInt(usize, expected, 10)) |want| {
                if (arg_arity) |got| {
                    if (got == want or got == want + 1) {
                        const d = refineDelta(scope, param_ty, arg) orelse return null;
                        return 90 + d;
                    }
                    return 20;
                }
                return 20;
            } else |_| {}
        }
        return 8;
    }

    // Subtype: an instance argument whose class transitively extends /
    // implements the parameter's nominal type (distance-weighted).
    if (subtypeDepth(scope, arg, nm)) |depth| {
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

    // Generic single-letter type-parameter — accept any.
    if (nm.len <= 2 and allAsciiUpper(nm)) return 5;
    // Unit param type — accept anything but rank lowest.
    if (std.mem.eql(u8, nm, "Unit")) return 1;
    return null;
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
pub fn applicable(sig: *const SigView, args: []const ArgShape, scope: ApplicabilityScope) ?Score {
    const params = sig.params;

    // A bodyless `expect` / native / abstract stub is never selectable.
    if (!sig.has_body) return null;

    const last_vararg = params.len > 0 and params[params.len - 1].is_vararg;
    if (params.len < args.len and !last_vararg) return null;

    // Trailing-lambda rule: the last arg binds out of sequence to the last
    // function-typed parameter, provided the gap is all-defaulted.
    if (params.len > args.len and args.len > 0 and
        isFunctionTypeRef(&params[params.len - 1].ty) and
        args[args.len - 1].is_lambda)
    {
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
            if (!gap_defaulted) return null;
            var total: i32 = -1;
            var proven: u16 = 0;
            var unknown: u16 = 0;
            var k: usize = 0;
            while (k < lead) : (k += 1) {
                const sc = scoreArg(&params[k].ty, &args[k], &scope) orelse return null;
                total += sc;
                if (argIsProven(&args[k])) proven += 1 else unknown += 1;
            }
            const ls = scoreArg(&params[last_param].ty, &args[lead], &scope) orelse return null;
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

    // Under-applied: every unfilled parameter must carry a default.
    if (params.len > args.len) {
        var all_defaulted = true;
        var i = args.len;
        while (i < params.len) : (i += 1) {
            if (!paramHasDefault(sig, i)) {
                all_defaulted = false;
                break;
            }
        }
        if (!all_defaulted) return null;
    }

    var total: i32 = if (params.len == args.len) 0 else -1;
    var proven: u16 = 0;
    var unknown: u16 = 0;
    var idx: usize = 0;
    while (idx < params.len and idx < args.len) : (idx += 1) {
        const sc = scoreArg(&params[idx].ty, &args[idx], &scope) orelse return null;
        total += sc;
        if (argIsProven(&args[idx])) proven += 1 else unknown += 1;
    }
    return .{
        .points = total,
        .proven_args = proven,
        .unknown_args = unknown,
        .exact_arity = params.len == args.len,
        .low_priority = sig.low_priority,
        .is_member = sig.is_member,
        .binding = .{},
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

test "applicable: exact head match scores 100" {
    const p = oneParam("Int");
    const sig = SigView{ .params = &p };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    const sc = applicable(&sig, &args, .{}).?;
    try testing.expectEqual(@as(i32, 100), sc.points);
    try testing.expect(sc.exact_arity);
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

test "builtinSupersOf: union table adds Collection and StringBuilder rows" {
    try testing.expectEqual(@as(usize, 3), builtinSupersOf("Collection").len);
    try testing.expectEqualStrings("CharSequence", builtinSupersOf("StringBuilder")[0]);
    try testing.expectEqual(@as(usize, 0), builtinSupersOf("Nope").len);
}

test "applicable: bodyless candidate is never selectable" {
    const p = oneParam("Int");
    const sig = SigView{ .params = &p, .has_body = false };
    const args = [_]ArgShape{.{ .runtime_class = "Int" }};
    try testing.expect(applicable(&sig, &args, .{}) == null);
}
