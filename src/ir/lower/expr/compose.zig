//! Compose ABI transforms: changed-bit computation and composable argument
//! threading.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const applicability = @import("applicability");
const build = @import("../../build.zig");
const compose_pass = @import("compose_pass");

const Allocator = std.mem.Allocator;
const FuncBuilder = build.FuncBuilder;
const Expr = ast.Expr;
const FuncId = ir.FuncId;
const Func = ir.Func;

const lambda_mod = @import("lambda.zig");
const fnTypeArityAlias = lambda_mod.fnTypeArityAlias;

const bare_call_mod = @import("bare_call.zig");
const allNull = bare_call_mod.allNull;

const tests_shapes_mod = @import("tests_shapes.zig");
const Module = tests_shapes_mod.Module;

/// The constructor-call half of the P12 shape repair: for each lambda
/// argument bound to a primary-constructor parameter with a declared
/// composable arity, re-shape it against that arity (inserting the implicit
/// `it` a bare-pair-shaped sink lambda dropped). Alignment mirrors
/// `ctorArgFnArities`: an unnamed trailing lambda binds the last
/// function-typed parameter; leading positionals map 1:1 when unnamed.
pub fn transformCtorComposableArgs(b: *FuncBuilder, class_id: ir.ClassId, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!void {
    if (args.len == 0) return;
    for (args) |*a| if (a.* == .Spread) return;
    if (!allNull(arg_names)) return;
    if (class_id.int() >= b.module.classes.items.len) return;
    const cls = &b.module.classes.items[class_id.int()];
    const params = cls.primary_params;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    for (args, 0..) |*arg, i| {
        const pi: ?usize = blk: {
            if (trailing_lambda and i == args.len - 1) {
                var k = params.len;
                while (k > 0) : (k -= 1) {
                    if (fnTypeArityAlias(b, params[k - 1].ty) != null) break :blk k - 1;
                }
                break :blk null;
            }
            break :blk if (i < params.len) i else null;
        };
        const p = pi orelse continue;
        const expected = params[p].composable_arity orelse continue;
        const expected_slots: u8 = expected +| params[p].composable_recv_slots;
        _ = try compose_pass.transformResolvedComposableLambda(
            b.allocator,
            @constCast(arg),
            expected_slots,
            cls.name,
            false,
        );
    }
}

/// `argFnArities` for a constructor call: the per-argument expected lambda
/// arity from the class's primary-constructor parameters. A `T.() -> R`
/// receiver-lambda parameter reports arity 0 so the lambda drops its `it` and
/// resolves bare members through the receiver bound at invocation (the same as
/// a function-call argument).
pub fn ctorArgFnArities(b: *FuncBuilder, class_id: ir.ClassId, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!?[]i16 {
    if (args.len == 0) return null;
    for (args) |*a| if (a.* == .Spread) return null;
    if (class_id.int() >= b.module.classes.items.len) return null;
    const params = b.module.classes.items[class_id.int()].primary_params;
    const out = try b.allocator.alloc(i16, args.len);
    for (out) |*o| o.* = -1;
    const trailing_lambda = args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun;
    if (trailing_lambda) {
        // An unnamed trailing lambda binds the LAST function-typed parameter
        // (intervening defaulted/named params are skipped) — find it and take
        // its arity, so `Op(desc, named = x) { member() }` still detects the
        // receiver lambda.
        var pi = params.len;
        while (pi > 0) : (pi -= 1) {
            if (fnTypeArityAlias(b, params[pi - 1].ty)) |ar| {
                out[args.len - 1] = ar;
                break;
            }
        }
    }
    // Leading positional args map 1:1 only when there are no named args.
    if (allNull(arg_names) and args.len <= params.len) {
        var i: usize = 0;
        const lead: usize = if (trailing_lambda) args.len - 1 else args.len;
        while (i < lead) : (i += 1) out[i] = fnTypeArityAlias(b, params[i].ty) orelse -1;
    }
    return out;
}

/// When an unnamed trailing lambda binds a constructor's function-typed
/// parameter that sits *after* one or more defaulted parameters (`Op("d") {…}`
/// for `Op(d: String, flag: Boolean = true, f: C.() -> Unit)`), positional
/// binding would put the lambda in the defaulted slot. Returns an arg-name
/// vector that names the trailing lambda with the function parameter so the
/// named-arg constructor path realigns it (the gap params take their defaults).
/// Null when no realignment is needed.
pub fn ctorRealignedArgNames(b: *FuncBuilder, class_id: ir.ClassId, args: []const Expr, arg_names: []const ?[]const u8) Allocator.Error!?[]?[]const u8 {
    if (args.len == 0 or !allNull(arg_names)) return null;
    if (!(args[args.len - 1] == .Lambda or args[args.len - 1] == .AnonFun)) return null;
    if (class_id.int() >= b.module.classes.items.len) return null;
    const params = b.module.classes.items[class_id.int()].primary_params;
    if (args.len > params.len) return null;
    var fn_idx: ?usize = null;
    var pi = params.len;
    while (pi > 0) : (pi -= 1) {
        if (fnTypeArityAlias(b, params[pi - 1].ty) != null) {
            fn_idx = pi - 1;
            break;
        }
    }
    const fi = fn_idx orelse return null;
    const lead = args.len - 1; // positional args preceding the trailing lambda
    if (fi <= lead) return null; // the lambda already aligns with (or past) the fn param
    // Every skipped parameter must be defaultable.
    var k = lead;
    while (k < fi) : (k += 1) if (!params[k].has_default and params[k].default == null) return null;
    const out = try b.allocator.alloc(?[]const u8, args.len);
    for (out) |*o| o.* = null;
    out[args.len - 1] = params[fi].name;
    return out;
}

/// Resolve a source-shaped call first, then retry with the hidden Compose ABI
/// only when the current function has a real threaded composer and ordinary
/// Kotlin resolution found no target. The retry must itself select a
/// declaration whose lowered signature proves the synthetic pair; this keeps
/// same-name non-composable overloads on the ordinary path.
pub fn resolveCallWithComposerAbi(
    b: *FuncBuilder,
    name: []const u8,
    caller_file: ir.FileId,
    candidates: []const FuncId,
    shapes: []const applicability.ArgShape,
    last_arg_lambda: bool,
    ctx: ir.Module.ResolveCtx,
) Allocator.Error!ir.Module.Resolution {
    const direct = try b.module.resolveCallCandidates(
        b.allocator,
        name,
        b.self_package,
        caller_file,
        candidates,
        shapes,
        last_arg_lambda,
        ctx,
    );
    if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name)) std.debug.print("[abi-direct] {s} target={?d} reason={?s} composer_in_scope={} shapes_have_pair={} nshapes={d}\n", .{ name, if (direct.target) |t| t.int() else null, if (direct.reason) |r| @tagName(r) else null, b.resolve("$composer") != null, argShapesHaveComposerPair(shapes), shapes.len });
    }
    if (direct.target != null or b.resolve("$composer") == null or
        argShapesHaveComposerPair(shapes))
    {
        return direct;
    }

    const augmented = try b.allocator.alloc(applicability.ArgShape, shapes.len + 2);
    defer b.allocator.free(augmented);
    @memcpy(augmented[0..shapes.len], shapes);
    augmented[shapes.len] = .{ .named = "$composer" };
    augmented[shapes.len + 1] = .{
        .ty = build.typeInt(),
        .named = "$changed",
        .literal_kind = .numeric,
    };

    const threaded = try b.module.resolveCallCandidates(
        b.allocator,
        name,
        b.self_package,
        caller_file,
        candidates,
        augmented,
        false,
        ctx,
    );
    if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
        if (std.mem.eql(u8, w, name)) std.debug.print("[abi-retry] {s} threaded_target={?d} reason={?s} tier={d} tier_count={d}\n", .{ name, if (threaded.target) |t| t.int() else null, if (threaded.reason) |r| @tagName(r) else null, threaded.tier, threaded.tier_count });
    }
    if (threaded.target) |target| {
        if (b.module.funcById(target)) |f| {
            if (selectedCallHasComposerAbi(b.module, target, f)) {
                b.allocator.free(direct.candidate_set);
                return threaded;
            }
        }
    }
    b.allocator.free(threaded.candidate_set);
    return direct;
}

pub fn argShapesHaveComposerPair(shapes: []const applicability.ArgShape) bool {
    if (shapes.len < 2) return false;
    const composer_name = shapes[shapes.len - 2].named orelse return false;
    const changed_name = shapes[shapes.len - 1].named orelse return false;
    return std.mem.eql(u8, composer_name, "$composer") and
        std.mem.eql(u8, changed_name, "$changed");
}

pub const SelectedCallArgs = struct {
    args: []const Expr,
    names: []const ?[]const u8,
    owned_args: ?[]Expr = null,
    owned_names: ?[]?[]const u8 = null,
    owned_composer_path: ?[]ast.Ident = null,

    fn deinit(self: *SelectedCallArgs, allocator: Allocator) void {
        if (self.owned_args) |items| allocator.free(items);
        if (self.owned_names) |items| allocator.free(items);
        if (self.owned_composer_path) |items| allocator.free(items);
        self.* = .{ .args = &.{}, .names = &.{} };
    }
};

pub fn hasThreadedComposerParams(f: *const Func) bool {
    if (f.params.len < 2) return false;
    return std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer") and
        std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed");
}

fn sameDeclSig(a: ir.Module.DeclSig, b: ir.Module.DeclSig) bool {
    if (a.kind != b.kind or
        a.arity.required != b.arity.required or
        a.arity.total != b.arity.total or
        a.arity.has_vararg != b.arity.has_vararg or
        a.sig.len != b.sig.len)
    {
        return false;
    }
    if ((a.enclosing_class == null) != (b.enclosing_class == null)) return false;
    if (a.enclosing_class) |ac| {
        if (ac.int() != b.enclosing_class.?.int()) return false;
    }
    if ((a.receiver_ty == null) != (b.receiver_ty == null)) return false;
    if (a.receiver_ty) |ar| {
        if (!ar.eql(b.receiver_ty.?)) return false;
    }
    for (a.sig, b.sig) |ap, bp| {
        if (!ap.eql(bp)) return false;
    }
    return true;
}

/// Whether the declaration selected during lowering has the transformed
/// Compose call ABI. A reserved declaration header retains the source
/// parameter list while its body-carrying sibling owns the synthetic tail, so
/// match that sibling by the canonical declaration signature rather than by
/// simple name.
pub fn selectedCallHasComposerAbi(module: *const Module, func_id: FuncId, f: *const Func) bool {
    if (hasThreadedComposerParams(f)) return true;
    for (f.annotation_names) |ann| {
        if (std.mem.eql(u8, ann, "Composable") or std.mem.endsWith(u8, ann, ".Composable")) return true;
    }
    const selected_sig = module.decl_sigs.get(func_id.int()) orelse return false;
    for (module.funcsBySimpleName(f.name)) |candidate_id| {
        if (candidate_id.int() == func_id.int()) continue;
        const candidate = module.funcById(candidate_id) orelse continue;
        if (!hasThreadedComposerParams(candidate)) continue;
        if (!std.mem.eql(u8, candidate.fqn, f.fqn)) continue;
        const candidate_sig = module.decl_sigs.get(candidate_id.int()) orelse continue;
        if (sameDeclSig(selected_sig, candidate_sig)) return true;
    }
    return false;
}

pub fn selectedCallArgs(module: *const Module, func_id: FuncId, args: []const Expr, names: []const ?[]const u8) SelectedCallArgs {
    if (args.len < 2 or names.len != args.len) return .{ .args = args, .names = names };
    const composer_name = names[names.len - 2] orelse return .{ .args = args, .names = names };
    const changed_name = names[names.len - 1] orelse return .{ .args = args, .names = names };
    if (!std.mem.eql(u8, composer_name, "$composer") or
        !std.mem.eql(u8, changed_name, "$changed"))
    {
        return .{ .args = args, .names = names };
    }
    const f = module.funcById(func_id) orelse return .{ .args = args, .names = names };
    if (selectedCallHasComposerAbi(module, func_id, f)) {
        compose_pass.compose_audit.threaded_agree += 1;
        return .{ .args = args, .names = names };
    }
    compose_pass.compose_audit.pair_stripped += 1;
    if (compose_pass.composeAuditOn()) {
        std.debug.print(
            "[KLIO_RESOLVE_AUDIT] compose pair-stripped target={s}#{d}\n",
            .{ f.fqn, func_id.int() },
        );
    }
    return .{
        .args = args[0 .. args.len - 2],
        .names = names[0 .. names.len - 2],
    };
}

pub fn hasComposerArgPair(names: []const ?[]const u8) bool {
    if (names.len < 2) return false;
    const composer_name = names[names.len - 2] orelse return false;
    const changed_name = names[names.len - 1] orelse return false;
    return std.mem.eql(u8, composer_name, "$composer") and
        std.mem.eql(u8, changed_name, "$changed");
}

/// Complete the exact selected Compose ABI from the current lowered scope.
/// The AST pass normally supplies this pair, but a cross-pack caller may have
/// been transformed before the callee joined its simple-name oracle. The
/// selected declaration and the synthesized `$composer` binding are direct
/// evidence, so emission can still produce the same static call.
pub fn selectedCallArgsForBuilder(
    b: *FuncBuilder,
    func_id: FuncId,
    args: []const Expr,
    names: []const ?[]const u8,
    call_span: ast.Span,
    trailing_lambda: bool,
) Allocator.Error!SelectedCallArgs {
    var selected = selectedCallArgs(b.module, func_id, args, names);
    const f = b.module.funcById(func_id) orelse return selected;
    if (!hasComposerArgPair(selected.names)) {
        const has_abi = selectedCallHasComposerAbi(b.module, func_id, f);
        const composer = b.resolve("$composer");
        if (runtime.envOnce("KLIO_BARE_TRACE")) |w| {
            if (std.mem.eql(u8, w, f.name)) {
                std.debug.print(
                    "[compose-abi] {s}#{d} caller={s} has_abi={} composer={} args={d}\n",
                    .{
                        f.fqn,
                        func_id.int(),
                        build.currentRealFn() orelse "-",
                        has_abi,
                        composer != null,
                        args.len,
                    },
                );
            }
        }
        if (has_abi and composer != null) {
            compose_pass.compose_audit.pair_completed += 1;
            if (compose_pass.composeAuditOn()) {
                std.debug.print(
                    "[KLIO_RESOLVE_AUDIT] compose pair-completed target={s}#{d} caller={s}\n",
                    .{ f.fqn, func_id.int(), build.currentRealFn() orelse "-" },
                );
            }
            const completed_args = try b.allocator.alloc(Expr, selected.args.len + 2);
            errdefer b.allocator.free(completed_args);
            @memcpy(completed_args[0..selected.args.len], selected.args);
            const composer_path = try b.allocator.alloc(ast.Ident, 1);
            errdefer b.allocator.free(composer_path);
            composer_path[0] = .{ .name = "$composer", .span = call_span };
            completed_args[selected.args.len] = .{ .Path = .{ .segments = composer_path, .span = call_span } };
            completed_args[selected.args.len + 1] = try composeChangedBits(b, f, selected.args, selected.names, trailing_lambda, call_span);

            const completed_names = try b.allocator.alloc(?[]const u8, selected.names.len + 2);
            errdefer b.allocator.free(completed_names);
            @memcpy(completed_names[0..selected.names.len], selected.names);
            completed_names[selected.names.len] = "$composer";
            completed_names[selected.names.len + 1] = "$changed";

            selected.owned_args = completed_args;
            selected.owned_names = completed_names;
            selected.owned_composer_path = composer_path;
            selected.args = completed_args;
            selected.names = completed_names;
        }
    }
    try transformSelectedComposableArgs(b, f, selected.args, selected.names, trailing_lambda);
    return selected;
}

/// The `$changed` value for a lowering-completed composable call: per-arg
/// certainty bits at the RESOLVED callee's triple positions (3 bits per
/// value param above the forced bit, kotlinc's layout). A literal argument
/// is STATIC (`0b110 << 3i`, a compile-time constant of the site); a bare
/// forward of one of the caller's own value params recombines the caller's
/// live `$dirty` triple into the callee position, so the callee's guarded
/// probe (`if ($changed and (0b110 << 3i) == 0)`) skips and its slot is
/// never taken — the drop from klio's 22 slots to kotlinc's 18 on the
/// checkboxLike anchor. Everything else claims nothing.
fn composeChangedBits(
    b: *FuncBuilder,
    f: *const Func,
    args: []const Expr,
    names: []const ?[]const u8,
    trailing_lambda: bool,
    call_span: ast.Span,
) Allocator.Error!Expr {
    var const_bits: i64 = 0;
    var dyn: ?Expr = null;
    const caller_dirty = b.resolve("$dirty") != null;
    const recv_off: usize = if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
    var user_param_end = f.params.len;
    if (f.params.len >= 2 and std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer")) user_param_end -= 2;
    var next_param: usize = recv_off;
    for (args, 0..) |*arg, arg_index| {
        var param_index: ?usize = null;
        if (trailing_lambda and arg_index + 1 == args.len and user_param_end != 0) {
            param_index = user_param_end - 1;
        } else if (arg_index < names.len and names[arg_index] != null) {
            for (f.params, 0..) |param, i| {
                if (applicability.paramNameMatchesArg(param.name, names[arg_index].?)) {
                    param_index = i;
                    break;
                }
            }
        } else {
            param_index = next_param;
        }
        const pi = param_index orelse continue;
        next_param = @max(next_param, pi + 1);
        if (pi < recv_off or pi >= user_param_end) continue;
        const triple = pi - recv_off;
        if (triple >= 9) continue;
        const callee_param = &f.params[pi];
        if (callee_param.is_vararg) continue;
        switch (arg.*) {
            .IntLit, .BoolLit, .CharLit, .FloatLit, .NullLit => {
                const_bits |= @as(i64, 6) << @intCast(3 * triple);
            },
            // `$composer.cache(false, { … })` — the plugin's memo of a
            // ZERO-capture lambda: the cached instance never invalidates,
            // so the argument is static exactly like kotlinc's lifted
            // singleton lambda; the callee's changedInstance probe (and
            // its slot) is unnecessary.
            .Call => |cc| {
                if (cc.callee.* == .Member and std.mem.eql(u8, cc.callee.Member.name.name, "cache") and
                    cc.args.len >= 1 and cc.args[0] == .BoolLit and !cc.args[0].BoolLit.value)
                {
                    const_bits |= @as(i64, 6) << @intCast(3 * triple);
                }
            },
            .Path => |p| fwd: {
                if (p.segments.len != 1) break :fwd;
                // A lifted memo singleton is a permanent instance — static.
                if (std.mem.startsWith(u8, p.segments[0].name, "$klio$memo$")) {
                    const_bits |= @as(i64, 6) << @intCast(3 * triple);
                    break :fwd;
                }
                if (!caller_dirty) break :fwd;
                const nm = p.segments[0].name;
                // A DEFAULTED caller param was renamed `p$arg` by the plugin
                // and the body reads the prologue local `p` — its triple is
                // still live (the probe reads the resolved value; a taken
                // default sets the same-bit), so it forwards like any other.
                var renamed_default = false;
                const j = for (b.compose_value_params, 0..) |*cp2, k| {
                    if (std.mem.eql(u8, cp2.name.name, nm)) break k;
                    if (cp2.name.name.len == nm.len + 4 and
                        std.mem.startsWith(u8, cp2.name.name, nm) and
                        std.mem.endsWith(u8, cp2.name.name, "$arg"))
                    {
                        renamed_default = true;
                        break k;
                    }
                } else break :fwd;
                if (j >= 9) break :fwd;
                const cp = &b.compose_value_params[j];
                if (cp.is_vararg) break :fwd;
                // A body local shadowing the param name would misattribute
                // the triple; only a binding that is still the parameter's
                // own (or its defaults-prologue local) may recombine.
                if (!renamed_default and !b.isParam(nm)) break :fwd;
                const sp = call_span;
                const dirty_ref = try composeBitsPath(b.allocator, "$dirty", sp);
                var term: Expr = undefined;
                if (j == triple) {
                    term = try composeBitsCall1(b.allocator, dirty_ref, "and", composeBitsInt(@as(i64, 6) << @intCast(3 * triple), sp), sp);
                } else {
                    const shifted = try composeBitsCall1(b.allocator, dirty_ref, "shr", composeBitsInt(3 * @as(i64, @intCast(j)), sp), sp);
                    const masked = try composeBitsCall1(b.allocator, shifted, "and", composeBitsInt(6, sp), sp);
                    term = try composeBitsCall1(b.allocator, masked, "shl", composeBitsInt(3 * @as(i64, @intCast(triple)), sp), sp);
                }
                dyn = if (dyn) |acc| try composeBitsCall1(b.allocator, acc, "or", term, sp) else term;
            },
            else => {},
        }
    }
    if (dyn) |d| {
        if (const_bits == 0) return d;
        return try composeBitsCall1(b.allocator, d, "or", composeBitsInt(const_bits, call_span), call_span);
    }
    return composeBitsInt(const_bits, call_span);
}

fn composeBitsInt(v: i64, sp: ast.Span) Expr {
    return .{ .IntLit = .{ .value = v, .kind = .Int, .span = sp } };
}

fn composeBitsPath(alloc: Allocator, nm: []const u8, sp: ast.Span) Allocator.Error!Expr {
    const segs = try alloc.alloc(ast.Ident, 1);
    segs[0] = .{ .name = nm, .span = sp };
    return .{ .Path = .{ .segments = segs, .span = sp } };
}

fn composeBitsCall1(alloc: Allocator, recv: Expr, nm: []const u8, a0: Expr, sp: ast.Span) Allocator.Error!Expr {
    const recv_p = try alloc.create(Expr);
    recv_p.* = recv;
    const cargs = try alloc.alloc(Expr, 1);
    cargs[0] = a0;
    const cnames = try alloc.alloc(?[]const u8, 1);
    cnames[0] = null;
    const callee = try alloc.create(Expr);
    callee.* = .{ .Member = .{
        .receiver = recv_p,
        .name = .{ .name = nm, .span = sp },
        .safe = false,
        .span = sp,
    } };
    return .{ .Call = .{
        .callee = callee,
        .args = cargs,
        .arg_names = cnames,
        .type_args = &.{},
        .is_infix = false,
        .has_trailing_lambda = false,
        .span = sp,
    } };
}

fn transformSelectedComposableArgs(
    b: *FuncBuilder,
    f: *const Func,
    args: []const Expr,
    names: []const ?[]const u8,
    trailing_lambda: bool,
) Allocator.Error!void {
    if (b.resolve("$composer") == null or args.len == 0) return;
    const occupied = try b.allocator.alloc(bool, f.params.len);
    defer b.allocator.free(occupied);
    @memset(occupied, false);
    var next_param: usize = 0;
    if (f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) {
        occupied[0] = true;
        next_param = 1;
    }
    const user_arg_end = if (hasComposerArgPair(names)) args.len - 2 else args.len;
    var user_param_end = f.params.len;
    if (hasThreadedComposerParams(f)) user_param_end -= 2;
    for (args, 0..) |_, arg_index| {
        var param_index: ?usize = null;
        if (trailing_lambda and arg_index + 1 == user_arg_end and user_param_end != 0) {
            param_index = user_param_end - 1;
        } else if (arg_index < names.len) {
            if (names[arg_index]) |arg_name| {
                for (f.params, 0..) |param, i| {
                    if (applicability.paramNameMatchesArg(param.name, arg_name)) {
                        param_index = i;
                        break;
                    }
                }
            }
        }
        if (param_index == null) {
            while (next_param < f.params.len and occupied[next_param]) next_param += 1;
            if (next_param < f.params.len) {
                param_index = next_param;
                next_param += 1;
            }
        }
        const pi = param_index orelse continue;
        occupied[pi] = true;
        const expected = f.params[pi].composable_arity orelse {
            if (runtime.envOnce("KLIO_BARE_TRACE")) |want| {
                if (std.mem.eql(u8, want, f.name)) {
                    std.debug.print(
                        "[compose-param] {s}#{d} arg={d} param={s} composable=false\n",
                        .{ f.fqn, f.id.int(), arg_index, f.params[pi].name },
                    );
                }
            }
            continue;
        };
        if (runtime.envOnce("KLIO_BARE_TRACE")) |want| {
            if (std.mem.eql(u8, want, f.name)) {
                std.debug.print(
                    "[compose-param] {s}#{d} arg={d} param={s} composable=true arity={d}\n",
                    .{ f.fqn, f.id.int(), arg_index, f.params[pi].name, expected },
                );
            }
        }
        // The synthetic slot count comes from the RESOLVED parameter: its
        // declared arity plus, for a non-inline sink, the receiver/context
        // slots the value protocol flattens in front (an inline sink
        // splices with the receiver bound as `this`, no slot).
        const expected_slots: u8 = if (f.is_inline)
            expected
        else
            expected +| f.params[pi].composable_recv_slots;
        _ = try compose_pass.transformResolvedComposableLambda(
            b.allocator,
            @constCast(&args[arg_index]),
            expected_slots,
            f.name,
            f.is_inline,
        );
    }
}
