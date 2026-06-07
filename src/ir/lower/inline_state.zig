//! Process-global registries for the inline-expansion machinery: the
//! `suspend inline fun` AST table and the inline-nesting depth guard.
//! Kept apart from the main lowering module because they are pure state
//! primitives — no `FuncBuilder` or IR-side dependency.
//!
//! Rust modelled these as `thread_local!` cells set by the build driver
//! before body lowering; the port keeps the same single-build-at-a-time
//! contract with module-level state. The driver installs the tables once
//! per build, then lowers bodies serially.

const std = @import("std");
const ast = @import("ast");

const Allocator = std.mem.Allocator;
const StringSet = std.StringHashMap(void);

/// A call's shape at a candidate site: `(positional_arg_count,
/// last_arg_is_lambda)`. `null` when the caller has no shape hint.
pub const CallShape = struct {
    want: usize,
    last_is_lambda: bool,
};

/// `suspend inline fun` ASTs by simple name, set by the build driver
/// before body lowering. A `suspend inline` builder's
/// `suspendCoroutineUninterceptedOrReturn` must capture the *caller's*
/// continuation — only correct when the body is truly inlined.
/// Non-suspend inline fns keep the normal call path and klio's
/// frame-kind non-local-return mechanism, so the inline blast radius
/// stays minimal.
var inline_fn_asts: ?std.StringHashMap([]const *const ast.Function) = null;

/// Simple names that a default-imported host binding owns (e.g.
/// `kotlin.synchronized`, `kotlin.arrayOf`). Any inline fn sharing a
/// simple name with one of these must NOT shadow Kotlin's default-import
/// resolution at a bare call site; the lowerer skips inline expansion so
/// the call falls through to the normal call path.
var shadowed_inline_names: ?StringSet = null;

/// Hard ceiling on combined inline nesting (fn-body + lambda-arg
/// splices) so transitive expansion cannot recurse without bound; past
/// it, callers fall back to a normal call.
var inline_expand_depth: u32 = 0;

/// Simple names of *top-level* (file-scope) properties — `val`/`var`
/// declared outside any class. A bare reference to such a name inside a
/// method/lambda body must resolve as a global property read, not an
/// implicit `this.<name>` field access.
var top_level_prop_names: ?StringSet = null;

const INLINE_EXPAND_MAX: u32 = 8;

/// Install the set of top-level property simple names for the current
/// build, so bare-name lowering routes them to a global read instead of
/// an implicit `this.<name>` field access. Takes ownership of `names`;
/// any previously-installed set is freed.
pub fn setTopLevelPropNames(names: StringSet) void {
    if (top_level_prop_names) |*old| old.deinit();
    top_level_prop_names = names;
}

/// True when `name` is a known top-level (file-scope) property.
pub fn isTopLevelProp(name: []const u8) bool {
    if (top_level_prop_names) |*c| return c.contains(name);
    return false;
}

/// Install the suspend-inline-fn AST table for the current build. Each
/// simple name maps to all its inline overloads (declaration order) so a
/// call site can disambiguate a function-param overload from a
/// value-param one by the trailing-arg shape. Takes ownership of `m`.
pub fn setInlineFnAsts(m: std.StringHashMap([]const *const ast.Function)) void {
    if (inline_fn_asts) |*old| old.deinit();
    inline_fn_asts = m;
}

/// Install the set of simple names owned by default-imported host
/// bindings. Inline expansion is skipped for these names so the call
/// site dispatches through the binding. Takes ownership of `names`.
pub fn setShadowedInlineNames(names: StringSet) void {
    if (shadowed_inline_names) |*old| old.deinit();
    shadowed_inline_names = names;
}

fn isShadowed(name: []const u8) bool {
    if (shadowed_inline_names) |*c| return c.contains(name);
    return false;
}

fn candidatesFor(name: []const u8) ?[]const *const ast.Function {
    if (inline_fn_asts) |*c| return c.get(name);
    return null;
}

pub fn inlineFnAst(name: []const u8) ?*const ast.Function {
    return inlineFnAstFor(name, null);
}

/// Like [`inlineFnAstFor`] but, when several overloads share the name,
/// prefer the one whose extension `receiver_type` matches `recv_ty` (the
/// statically-inferred receiver type of the member call).
pub fn inlineFnAstForRecv(
    name: []const u8,
    call: ?CallShape,
    recv_ty: ?[]const u8,
) ?*const ast.Function {
    return inlineFnAstForRecvExt(name, call, recv_ty, false);
}

/// As [`inlineFnAstForRecv`], with `require_receiver`: when the call is a
/// qualified member call (`recv.f(...)`) the inline target must be an
/// extension with a `this` receiver — a same-named *top-level* overload
/// is not a valid target and must not win the shape-based tie.
pub fn inlineFnAstForRecvExt(
    name: []const u8,
    call: ?CallShape,
    recv_ty: ?[]const u8,
    require_receiver: bool,
) ?*const ast.Function {
    if (isShadowed(name)) return null;
    const cands = candidatesFor(name) orelse return inlineFnAstFor(name, call);
    if (cands.len < 2) return inlineFnAstFor(name, call);

    // Determine whether overloads span different receiver types and
    // whether any candidate is a top-level (no-receiver) overload.
    var first_recv: ?[]const u8 = null;
    var have_first = false;
    var multi_recv = false;
    var has_toplevel = false;
    for (cands) |f| {
        if (f.receiver_type) |rt| {
            if (!have_first) {
                first_recv = rt.name.name;
                have_first = true;
            } else if (!eqOpt(first_recv, rt.name.name)) {
                multi_recv = true;
            }
        } else {
            has_toplevel = true;
        }
    }

    // Count the narrowed candidate subset per the rules above.
    var matched: usize = 0;
    for (cands) |f| {
        if (keepNarrowed(f, recv_ty, require_receiver, multi_recv)) matched += 1;
    }

    const narrowed = matched < cands.len and
        ((require_receiver and has_toplevel) or (multi_recv and recv_ty != null));
    if (!narrowed or matched == 0) return inlineFnAstFor(name, call);
    return pickByShapeNarrowed(cands, call, recv_ty, require_receiver, multi_recv);
}

/// Predicate mirroring the Rust narrowing filter: drop top-level
/// overloads for a member call, and (when overloads differ by receiver
/// and the call's receiver type is known) keep only matching-receiver
/// overloads.
fn keepNarrowed(
    f: *const ast.Function,
    recv_ty: ?[]const u8,
    require_receiver: bool,
    multi_recv: bool,
) bool {
    if (require_receiver and f.receiver_type == null) return false;
    if (multi_recv) {
        if (recv_ty) |rt| {
            return if (f.receiver_type) |r| std.mem.eql(u8, r.name.name, rt) else false;
        }
    }
    return true;
}

fn eqOpt(a: ?[]const u8, b: []const u8) bool {
    if (a) |x| return std.mem.eql(u8, x, b);
    return false;
}

/// Shape-based pick restricted to the narrowed candidate subset, without
/// materialising the subset into a temporary slice.
fn pickByShapeNarrowed(
    cands: []const *const ast.Function,
    call: ?CallShape,
    recv_ty: ?[]const u8,
    require_receiver: bool,
    multi_recv: bool,
) ?*const ast.Function {
    var first: ?*const ast.Function = null;
    for (cands) |f| {
        if (keepNarrowed(f, recv_ty, require_receiver, multi_recv)) {
            first = f;
            break;
        }
    }
    const shape = call orelse return first;
    // Count narrowed candidates for the `< 2` early-out.
    var n_narrowed: usize = 0;
    for (cands) |f| {
        if (keepNarrowed(f, recv_ty, require_receiver, multi_recv)) n_narrowed += 1;
    }
    if (n_narrowed < 2) return first;
    if (!shape.last_is_lambda) {
        return pickNonlambdaShapeNarrowed(cands, recv_ty, require_receiver, multi_recv) orelse first;
    }
    const lead = shape.want -| 1;
    var match: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (!keepNarrowed(f, recv_ty, require_receiver, multi_recv)) continue;
        if (fitsTrailingLambda(f, lead)) {
            match = f;
            count += 1;
        }
    }
    if (count == 1) return match;
    return first;
}

fn pickNonlambdaShapeNarrowed(
    cands: []const *const ast.Function,
    recv_ty: ?[]const u8,
    require_receiver: bool,
    multi_recv: bool,
) ?*const ast.Function {
    var only: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (!keepNarrowed(f, recv_ty, require_receiver, multi_recv)) continue;
        if (noRequiredFnParam(f)) {
            only = f;
            count += 1;
            if (count > 1) return null;
        }
    }
    if (count == 1) return only;
    return null;
}

fn fitsTrailingLambda(f: *const ast.Function, lead: usize) bool {
    const n = f.params.len;
    if (n == 0) return false;
    if (f.params[n - 1].ty.function == null) return false;
    const leading = f.params[0 .. n - 1];
    var required: usize = 0;
    for (leading) |p| {
        if (p.default == null and !p.is_vararg) required += 1;
    }
    const last_lead_vararg = leading.len != 0 and leading[leading.len - 1].is_vararg;
    return lead >= required and (lead <= leading.len or last_lead_vararg);
}

/// Disambiguate a call whose last argument is *not* a lambda among
/// same-name overloads. When exactly one overload has *no* required
/// function-typed parameter, it is the applicable one. Returns `null`
/// (defer to first-declared) when the filter is not decisive.
fn pickNonlambdaShape(cands: []const *const ast.Function) ?*const ast.Function {
    var only: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (noRequiredFnParam(f)) {
            only = f;
            count += 1;
            if (count > 1) return null;
        }
    }
    if (count == 1) return only;
    return null;
}

fn noRequiredFnParam(f: *const ast.Function) bool {
    for (f.params) |p| {
        if (p.ty.function != null and p.default == null and !p.is_noinline) return false;
    }
    return true;
}

/// Resolve the inline overload of `name` for a call whose shape is
/// `call = (positional_arg_count, last_arg_is_lambda)`.
///
/// Deliberately conservative: returns the first-declared overload in
/// every case *except* a trailing-lambda call for which exactly one
/// arity-fitting overload has a function-typed last parameter — then that
/// overload wins.
pub fn inlineFnAstFor(name: []const u8, call: ?CallShape) ?*const ast.Function {
    if (isShadowed(name)) return null;
    const cands = candidatesFor(name) orelse return null;
    const first: ?*const ast.Function = if (cands.len > 0) cands[0] else null;
    const shape = call orelse return first;
    if (cands.len < 2) return first;
    if (!shape.last_is_lambda) return pickNonlambdaShape(cands) orelse first;
    const lead = shape.want -| 1;
    var match: ?*const ast.Function = null;
    var count: usize = 0;
    for (cands) |f| {
        if (fitsTrailingLambda(f, lead)) {
            match = f;
            count += 1;
        }
    }
    if (count == 1) return match;
    return first;
}

pub fn inlineExpandEnter() bool {
    if (inline_expand_depth >= INLINE_EXPAND_MAX) return false;
    inline_expand_depth += 1;
    return true;
}

pub fn inlineExpandLeave() void {
    inline_expand_depth -|= 1;
}

/// Release any installed tables. Used by tests and by a build driver
/// tearing down between builds.
pub fn resetForTest() void {
    if (inline_fn_asts) |*m| {
        m.deinit();
        inline_fn_asts = null;
    }
    if (shadowed_inline_names) |*s| {
        s.deinit();
        shadowed_inline_names = null;
    }
    if (top_level_prop_names) |*s| {
        s.deinit();
        top_level_prop_names = null;
    }
    inline_expand_depth = 0;
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "top-level prop names round-trip" {
    defer resetForTest();
    var names = StringSet.init(testing.allocator);
    try names.put("LOGGER", {});
    setTopLevelPropNames(names);
    try testing.expect(isTopLevelProp("LOGGER"));
    try testing.expect(!isTopLevelProp("other"));
}

test "shadowed name suppresses inline lookup" {
    defer resetForTest();
    var shadowed = StringSet.init(testing.allocator);
    try shadowed.put("synchronized", {});
    setShadowedInlineNames(shadowed);
    try testing.expect(inlineFnAst("synchronized") == null);
}

test "inline expand depth guard caps at max" {
    defer resetForTest();
    var entered: u32 = 0;
    while (inlineExpandEnter()) entered += 1;
    try testing.expectEqual(INLINE_EXPAND_MAX, entered);
    // Past the ceiling, further enters fail until we leave.
    try testing.expect(!inlineExpandEnter());
    inlineExpandLeave();
    try testing.expect(inlineExpandEnter());
}
