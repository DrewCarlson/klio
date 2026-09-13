//! Whole-compilation scans building the oracle sets the transform consults.

const std = @import("std");
const ast = @import("ast");
const root = @import("../compose_pass.zig");

const Param = ast.Param;

const composer_param = root.composer_param;
const changed_param = root.changed_param;
const isComposable = root.isComposable;

/// Whether a call's simple callee name binds a `@Composable` function. Integration
/// supplies this from resolution, tests a fixed set.
pub const ComposableOracle = *const fn (ctx: *anyopaque, callee_name: []const u8) bool;

pub const NameSetOracle = struct {
    names: *const std.StringHashMap(void),

    pub fn isComposableCall(ctx: *anyopaque, callee_name: []const u8) bool {
        const self: *const NameSetOracle = @ptrCast(@alignCast(ctx));
        return self.names.contains(callee_name);
    }
};

/// Simple names of every `@Composable` function in the slice. Caller owns the map.
pub fn collectComposableNames(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectInto(&set, decls);
    return set;
}

fn collectInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (isComposable(f.annotations)) try set.put(f.name.name, {});
        },
        .Class => |*c| try collectInto(set, c.members),
        .Object => |*o| try collectInto(set, o.members),
        else => {},
    };
}

/// Declared value-parameter name order per composable, for named-argument position
/// mapping. An overloaded simple name records EMPTY, claiming nothing.
pub const ComposableParams = struct { names: []const []const u8 };

pub fn collectComposableParamNames(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(ComposableParams) {
    var map = std.StringHashMap(ComposableParams).init(a);
    try collectParamsInto(a, &map, decls);
    return map;
}

fn collectParamsInto(a: std.mem.Allocator, map: *std.StringHashMap(ComposableParams), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (!isComposable(f.annotations)) continue;
            if (map.contains(f.name.name)) {
                try map.put(f.name.name, .{ .names = &.{} });
                continue;
            }
            const names = try a.alloc([]const u8, f.params.len);
            for (f.params, names) |*p, *n| n.* = p.name.name;
            try map.put(f.name.name, .{ .names = names });
        },
        .Class => |*c| try collectParamsInto(a, map, c.members),
        .Object => |*o| try collectParamsInto(a, map, o.members),
        else => {},
    };
}

pub fn isComposableLambdaParam(p: *const Param) bool {
    return p.ty.function != null and isComposable(p.ty.annotations);
}

pub fn isComposableFnType(t: *const ast.TypeRef) bool {
    return t.function != null and isComposable(t.annotations);
}

pub fn stateOfComposableArity(t: *const ast.TypeRef) ?u8 {
    const head = t.name.name;
    if (!std.mem.eql(u8, head, "MutableState") and !std.mem.eql(u8, head, "State")) return null;
    if (t.type_args.len != 1) return null;
    const arg = &t.type_args[0];
    if (arg.is_star) return null;
    if (!isComposableFnType(&arg.ty)) return null;
    const f = arg.ty.function orelse return null;
    return @intCast(@min(f.params.len, 255));
}

pub fn composableFunctionRecvSlots(t: *const ast.TypeRef) u8 {
    if (!isComposableFnType(t)) return 0;
    const ft = t.function.?;
    const n = ft.context_params.len + @intFromBool(ft.receiver != null);
    return @intCast(@min(n, 255));
}

pub fn composableFunctionArity(t: *const ast.TypeRef) ?u8 {
    if (!isComposableFnType(t)) return null;
    return @intCast(@min(t.function.?.params.len, 255));
}

pub fn lambdaHasComposerParams(lam: anytype) bool {
    if (lam.params.len < 2) return false;
    return std.mem.eql(u8, lam.params[lam.params.len - 2].name, composer_param) and
        std.mem.eql(u8, lam.params[lam.params.len - 1].name, changed_param);
}

/// Decision audit under `KLIO_RESOLVE_AUDIT`: the pass's threading decision against
/// the resolved target's declared ABI. Lowering is single-threaded, so counters suffice.
pub const ComposeAudit = struct {
    threaded_agree: u64 = 0,
    /// Pair present but the target has no composer ABI, stripped at `selectedCallArgs`.
    pair_stripped: u64 = 0,
    /// No pair but the target declares the ABI, completed from the ambient composer.
    pair_completed: u64 = 0,
    /// A pass-threaded lambda that cannot fit the resolved parameter's arity: short, or
    /// more than one over, where one over is the receiver slot.
    lambda_arity_mismatch: u64 = 0,

    pub fn disagreements(a: *const ComposeAudit) u64 {
        return a.pair_stripped + a.pair_completed + a.lambda_arity_mismatch;
    }
};

var compose_audit_env: ?bool = null;

pub fn composeAuditOn() bool {
    if (compose_audit_env) |v| return v;
    const v = blk: {
        if (comptime !@import("builtin").link_libc) break :blk false;
        const raw = std.c.getenv("KLIO_RESOLVE_AUDIT") orelse break :blk false;
        const s = std.mem.span(raw);
        break :blk s.len != 0 and !std.mem.eql(u8, s, "0");
    };
    compose_audit_env = v;
    return v;
}

/// A baked-base decl was threaded when its pack was built, so its real trailing
/// content lambda sits BEFORE that synthetic pair and sink collectors look past it.
fn sinkParamCount(params: anytype) usize {
    var n = params.len;
    if (n >= 2 and std.mem.eql(u8, params[n - 2].name.name, composer_param) and
        std.mem.eql(u8, params[n - 1].name.name, changed_param)) n -= 2;
    return n;
}

/// Declared parameter count of a sink's `@Composable` lambda parameter, null when zero.
/// A header-less `{ … }` bound to a `@Composable (P) -> Unit` sink keeps its implicit
/// `it` slot ahead of `$composer`/`$changed`.
fn sinkContentReach(params: anytype) ?u8 {
    const n = sinkParamCount(params);
    if (n == 0) return null;
    const lp = &params[n - 1];
    if (lp.ty.function == null or !isComposable(lp.ty.annotations)) return null;
    var required: u8 = 0;
    for (params[0 .. n - 1]) |*p| {
        if (p.default == null and !p.is_vararg) required += 1;
    }
    return required + 1;
}

fn putMinReach(set: *std.StringHashMap(u8), name: []const u8, reach: u8) std.mem.Allocator.Error!void {
    const gop = try set.getOrPut(name);
    if (!gop.found_existing or reach < gop.value_ptr.*) gop.value_ptr.* = reach;
}

pub fn collectSinkContentReachInto(set: *std.StringHashMap(u8), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (sinkContentReach(f.params)) |r| try putMinReach(set, f.name.name, r);
        },
        .Class => |*c| {
            if (sinkContentReach(c.primary_params)) |r| try putMinReach(set, c.name.name, r);
            try collectSinkContentReachInto(set, c.members);
        },
        .Object => |*o| try collectSinkContentReachInto(set, o.members),
        else => {},
    };
}

pub fn collectInlineFnNames(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectInlineFnNamesInto(&set, decls);
    return set;
}

pub fn collectInlineFnNamesInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            if (f.is_inline) try set.put(f.name.name, {});
        },
        .Class => |*c| try collectInlineFnNamesInto(set, c.members),
        .Object => |*o| try collectInlineFnNamesInto(set, o.members),
        else => {},
    };
}

/// Stdlib inline HOFs: the stdlib lowers from a baked image, so its `inline` modifiers
/// are outside the collected AST universe.
const stdlib_inline_hofs = [_][]const u8{
    "let",          "run",            "with",               "apply",       "also",
    "takeIf",       "takeUnless",     "repeat",             "use",         "synchronized",
    "forEach",      "forEachIndexed", "onEach",             "map",         "mapIndexed",
    "mapNotNull",   "filter",         "filterNot",          "flatMap",     "fold",
    "sumOf",        "count",          "any",                "all",         "none",
    "first",        "firstOrNull",    "last",               "lastOrNull",  "find",
    "indexOfFirst", "indexOfLast",    "groupBy",            "associateBy", "associateWith",
    "getOrElse",    "getOrPut",       "buildString",        "buildList",   "buildSet",
    "buildMap",     "maxOf",          "minOf",              "runCatching", "withLock",
    "measureTime",  "fastForEach",    "fastForEachIndexed", "fastMap",     "fastAny",
    "fastFilter",   "fastGroupBy",    "fastFirstOrNull",    "trace",       "sortedBy",
    "joinToString", "removeIf",       "partition",          "single",      "singleOrNull",
};

/// A lambda argument keeps the composable scope when the callee inlines it.
pub fn calleeInlinesLambda(name: []const u8) bool {
    if (root.active_inline_fns) |ifns| {
        if (ifns.contains(name)) return true;
    }
    for (stdlib_inline_hofs) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    // Compose runtime `inline` HOFs, outside the collected AST universe. Their lambdas
    // stay raw: wrapping reshapes the call and the overload pick drops the content.
    for (compose_inline_hofs) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

const compose_inline_hofs = [_][]const u8{
    "ComposeNode", "ReusableComposeNode", "key", "ReusableContent", "ReusableContentHost",
};

/// Calls whose trailing calculation produces their result value, so an expected
/// composable type flows into the lambda's result expression.
pub fn callPropagatesExpectedValue(name: []const u8) bool {
    return std.mem.eql(u8, name, "remember") or
        std.mem.eql(u8, name, "rememberSaveable") or
        std.mem.eql(u8, name, "rememberRetained");
}

/// The `@Composable` annotation sits on the property declaration or on its `get()`.
fn isComposableGetterProp(p: *const ast.Property) bool {
    if (isComposable(p.annotations)) return true;
    if (p.getter) |g| return isComposable(g.annotations);
    return false;
}

/// Caller owns the map.
pub fn collectComposableGetterProps(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectComposableGetterPropsInto(&set, decls);
    return set;
}

pub fn collectComposableGetterPropsInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Property => |p| {
            if (isComposableGetterProp(p)) try set.put(p.name.name, {});
        },
        .Class => |*c| try collectComposableGetterPropsInto(set, c.members),
        .Object => |*o| try collectComposableGetterPropsInto(set, o.members),
        else => {},
    };
}

/// Functions and constructors declaring a `@Composable`-typed lambda parameter, so a
/// lambda bound to one is itself transformed. Caller owns the map.
pub fn collectComposableLambdaSinks(
    a: std.mem.Allocator,
    decls: []const ast.Decl,
) std.mem.Allocator.Error!std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(a);
    try collectSinksInto(&set, decls);
    return set;
}

fn collectSinksInto(set: *std.StringHashMap(void), decls: []const ast.Decl) std.mem.Allocator.Error!void {
    for (decls) |*d| switch (d.*) {
        .Function => |*f| {
            for (f.params) |*p| if (isComposableLambdaParam(p)) {
                try set.put(f.name.name, {});
                break;
            };
        },
        .Class => |*c| {
            // A class whose primary constructor takes a `@Composable` lambda is a sink too.
            for (c.primary_params) |*p| {
                if (p.ty.function != null and isComposable(p.ty.annotations)) {
                    try set.put(c.name.name, {});
                    break;
                }
            }
            try collectSinksInto(set, c.members);
        },
        .Object => |*o| try collectSinksInto(set, o.members),
        else => {},
    };
}
