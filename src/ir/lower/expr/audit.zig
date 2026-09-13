//! Lowering census counters and the dump surface that reads them.

const std = @import("std");
const ast = @import("ast");
const runtime = @import("runtime");
const ir = @import("../../ir.zig");
const build = @import("../../build.zig");

const FuncBuilder = build.FuncBuilder;
const FuncId = ir.FuncId;

const static_type_mod = @import("static_type.zig");
const staticTypeClassId = static_type_mod.staticTypeClassId;

const probe_mod = @import("probe.zig");
const fqnOf = probe_mod.fqnOf;
const inReceiverContext = probe_mod.inReceiverContext;

var or_audit_checked: bool = false;
var or_audit_enabled: bool = false;

/// Compile-side half of the `KLIO_OR_AUDIT` detector, whose runtime half lives in
/// `ir/eval.zig`: logs every member-vs-global emission decision so a sweep can join
/// emit context against the runtime arm that won.
pub fn orAuditOn() bool {
    if (!or_audit_checked) {
        or_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_OR_AUDIT") catch null) |v| {
            defer a.free(v);
            or_audit_enabled = v.len != 0 and !std.mem.eql(u8, v, "0");
        }
    }
    return or_audit_enabled;
}

pub fn orEmitAudit(b: *const FuncBuilder, site: []const u8, inst: []const u8, name: []const u8) void {
    if (!orAuditOn()) return;
    std.debug.print(
        "[KLIO_OR_AUDIT] emit site={s} inst={s} name={s} recvctx={d} pkg={s} fn={s} recv={s}\n",
        .{ site, inst, name, @intFromBool(inReceiverContext(b)), b.self_package, build.currentRealFn() orelse "-", b.recvTy() orelse b.spliceRecvTy() orelse b.ownerClass() orelse "-" },
    );
}

var resolve_audit_checked: bool = false;
var resolve_audit_enabled: bool = false;

pub fn resolveAuditOn() bool {
    if (!resolve_audit_checked) {
        resolve_audit_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_RESOLVE_AUDIT") catch null) |v| {
            a.free(v);
            resolve_audit_enabled = true;
        }
    }
    return resolve_audit_enabled;
}

var resolve_strict_checked: bool = false;
var resolve_strict_enabled: bool = false;

/// Test hook: force `KLIO_RESOLVE_STRICT` on for the process, bypassing the
/// once-per-process environment read.
pub fn setResolveStrictForTest(on: bool) void {
    resolve_strict_checked = true;
    resolve_strict_enabled = on;
}

/// Test hook: undo `setResolveStrictForTest`, so a forced setting never leaks past
/// the test that installed it.
pub fn resetResolveStrictForTest() void {
    resolve_strict_checked = false;
    resolve_strict_enabled = false;
}

pub fn resolveStrictOn() bool {
    if (!resolve_strict_checked) {
        resolve_strict_checked = true;
        const a = std.heap.page_allocator;
        if (runtime.procEnvGetVar(a, "KLIO_RESOLVE_STRICT") catch null) |v| {
            defer a.free(v);
            resolve_strict_enabled = v.len != 0 and !std.mem.eql(u8, v, "0");
        }
    }
    return resolve_strict_enabled;
}

/// Audit one value-position bare reference: the index's pick against the
/// order-based `funcId` pick the runtime's bare-name closure path binds.
pub fn refAudit(b: *FuncBuilder, name: []const u8, index_pick: ?FuncId) void {
    if (!resolveAuditOn()) return;
    const heur = b.module.funcId(name);
    const divergent = index_pick != null and heur != null and index_pick.?.int() != heur.?.int();
    const idx_fqn: []const u8 = if (index_pick) |i| fqnOf(b, i) else "-";
    const heur_fqn: []const u8 = if (heur) |h| fqnOf(b, h) else "-";
    std.debug.print(
        "[KLIO_RESOLVE_AUDIT] ref name={s} pkg={s} index_fqn={s} heur_fqn={s} divergent={d}\n",
        .{ name, b.self_package, idx_fqn, heur_fqn, @intFromBool(divergent) },
    );
}

/// Per-site census of the static member-call gate, under `KLIO_DISPATCH_STATS`.
pub var lm_sites: [7]u64 = @splat(0);
/// Unbound member sites the checker did resolve, and why each was refused:
/// [0] map hit, [1] no such func, [2] not an extension, [3] arity mismatch. A zero
/// at [0] means the two sets do not intersect at all.
pub var lm_eager_norecv: [4]u64 = @splat(0);
pub const LmReason = enum(u8) { no_receiver_type, nullable_or_generic, no_class_id, resolver_declined, bound_static, bound_virtual, dynamic_by_design };
pub fn lmNote(comptime r: LmReason) void {
    lm_sites[@intFromEnum(r)] += 1;
}

/// Breakdown of the `no_receiver_type` bucket by receiver-expression shape, indexed
/// by `ast.Expr` tag, which decides whether the fix belongs in typeck's inference or
/// in an AST probe lowering is not consulting.
pub var lm_norecv: [@typeInfo(@typeInfo(ast.Expr).@"union".tag_type.?).@"enum".fields.len]u64 = @splat(0);

/// Whether the `no_receiver_type` breakdown is being collected. Classifying a site
/// walks same-named declarations, so it happens only when asked for. Resolved once
/// per process.
var norecv_census: ?bool = null;
pub fn norecvCensusOn() bool {
    if (norecv_census) |v| return v;
    const v = runtime.envOnce("KLIO_DISPATCH_STATS") != null;
    norecv_census = v;
    return v;
}

/// Of the `no_receiver_type` sites, how many typeck did record a type head for,
/// simply not consulted for the receiver position, versus how many it cannot answer.
pub var lm_norecv_eager: [2]u64 = @splat(0);

/// Sub-census of the `Path` shape: what kind of name the untyped receiver is, which
/// decides where the missing type has to come from.
pub const NoRecvPath = enum(u8) {
    /// A live local/parameter register whose declared type was never recorded.
    local_no_decl_type,
    /// A captured name from an enclosing scope.
    captured,
    /// A bare read of an enclosing class's property; the type is on the class.
    enclosing_member,
    /// Neither local, capture, nor member: a top-level property or unknown.
    unknown,
};
pub var lm_norecv_path: [4]u64 = @splat(0);

/// Of the locals with no recorded declared type, whether an initializer was
/// recorded at all. None means the binding form registered none (loop variable,
/// lambda parameter, destructured component, catch parameter); one that still yields
/// no type means the initializer's own type is unknown.
pub const NoRecvInit = enum(u8) { no_init_recorded, init_yields_no_type };
pub var lm_norecv_init: [2]u64 = @splat(0);

/// Why a `Call` initializer yields no type. `argDeclTypeRefLazy` has channels for a
/// local function, a function-typed parameter, and a constructor, but none for a
/// module-level function's declared return type.
pub const NoRecvCall = enum(u8) {
    /// Callee is not a plain single-name call (a member or complex callee).
    not_simple_callee,
    /// No function of that name is known.
    no_func,
    /// Several same-named functions disagree on their return type.
    ambiguous_return,
    /// Unique concrete declared return type: a channel would answer here.
    unique_concrete,
    /// Unique, but the return type names nothing resolvable to a class.
    unique_unresolvable,
};
pub var lm_norecv_call: [5]u64 = @splat(0);

/// Breakdown of the `resolver_declined` bucket: sites where lowering had a receiver
/// type and the resolver still refused to name a declaration.
pub const DeclineKind = enum(u8) {
    /// The resolver identified the declaration but withheld a dispatch commitment.
    target_known_deferred,
    /// A visible member accepts the call shape but more than one could.
    ambiguous_applicable,
    /// No visible member accepts the shape at all.
    not_applicable,
    /// A target id that no longer resolves to a function.
    target_unresolvable,
    /// A direct call carrying a `*spread` argument.
    direct_spread,
    /// A virtual slot on a `value class` owner.
    virtual_owner_value,
    /// A virtual slot on a stub (host-backed declaration-only) owner.
    virtual_owner_stub,
    /// A virtual call carrying an explicit type-argument list.
    virtual_type_args,
    /// A virtual slot whose owner declares a non-instance receiver ABI.
    virtual_owner_abi,
    /// A virtual target declaring no receiver parameter.
    virtual_no_receiver_param,
    /// A named or vararg argument list that could not be mapped onto the target's
    /// parameters.
    arg_mapping_failed,
};
pub var lm_decline: [11]u64 = @splat(0);

pub fn declineNote(k: DeclineKind) void {
    lmNote(.resolver_declined);
    if (norecvCensusOn()) lm_decline[@intFromEnum(k)] += 1;
}

/// Why a `target_known_deferred` site had to ask the extension question at all, the
/// identity being proven at every one; the variant names which reachable extension
/// the proof must refute. Counted before the proof runs.
pub const PromoBlock = enum(u8) {
    /// An extension whose receiver is a type parameter declares this name, so the
    /// index cannot say which receivers it serves.
    ext_generic_receiver,
    /// An extension on the receiver's own head declares this name.
    ext_own_head,
    /// An extension on a builtin supertype of the receiver.
    ext_builtin_super,
    /// An extension on a declared supertype of the receiver.
    ext_declared_super,
    /// The extension index could not be rebuilt.
    ext_index_stale,
};
pub var lm_promo: [6]u64 = @splat(0);

/// Why `localInitTypeRef` did or did not answer: no initializer, a constructor, no
/// derivable return type, incomplete type arguments, derived.
pub var lm_localinit: [5]u64 = @splat(0);

pub fn lowerLocalInitDump() void {
    var total: u64 = 0;
    for (lm_localinit) |n| total += n;
    if (total == 0) return;
    const names = [_][]const u8{ "no_initializer", "constructor", "no_return_type", "args_incomplete", "derived" };
    std.debug.print("[localinit] total={d}\n", .{total});
    for (names, lm_localinit) |n, c| {
        if (c != 0) std.debug.print("[localinit] {d:>10} {s}\n", .{ c, n });
    }
}

pub fn lowerPromoDump() void {
    var total: u64 = 0;
    for (lm_promo) |n| total += n;
    if (total == 0) return;
    std.debug.print("[promo-blocked] total={d}\n", .{total});
    inline for (@typeInfo(PromoBlock).@"enum".fields) |f| {
        const n = lm_promo[f.value];
        if (n != 0) std.debug.print("[promo-blocked] {d:>10} {d:>6.2}%  {s}\n", .{ n, @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total)), f.name });
    }
}

/// Breakdown of `no_class_id`: lowering has a receiver type and cannot map its head
/// to a declared class. Name resolution, not typeck.
pub const NoClassKind = enum(u8) {
    /// A dotted name that `classIdByFqn` does not know.
    fqn_unknown,
    /// A bare head that no class declares.
    simple_unknown,
    /// A bare head several classes declare, so the simple-name lookup refuses.
    simple_ambiguous,
};
pub var lm_noclass: [3]u64 = @splat(0);

/// The heads behind the `no_class_id` count, captured into a fixed buffer so the
/// dump can name them; the per-site env trace loses rows that fire before
/// diagnostics settle.
var lm_noclass_heads: [32][64]u8 = undefined;
var lm_noclass_head_lens: [32]u8 = @splat(0);
var lm_noclass_head_counts: [32]u32 = @splat(0);
var lm_noclass_head_n: usize = 0;

pub fn noteNoClassHead(head: []const u8) void {
    const n = @min(head.len, 64);
    for (lm_noclass_heads[0..lm_noclass_head_n], lm_noclass_head_lens[0..lm_noclass_head_n], 0..) |*buf, len, i| {
        if (std.mem.eql(u8, buf[0..len], head[0..n])) {
            lm_noclass_head_counts[i] += 1;
            return;
        }
    }
    if (lm_noclass_head_n >= lm_noclass_heads.len) return;
    @memcpy(lm_noclass_heads[lm_noclass_head_n][0..n], head[0..n]);
    lm_noclass_head_lens[lm_noclass_head_n] = @intCast(n);
    lm_noclass_head_counts[lm_noclass_head_n] = 1;
    lm_noclass_head_n += 1;
}

pub fn lowerNoClassDump() void {
    var total: u64 = 0;
    for (lm_noclass) |n| total += n;
    if (total == 0) return;
    std.debug.print("[no-class] total={d}\n", .{total});
    inline for (@typeInfo(NoClassKind).@"enum".fields) |f| {
        const n = lm_noclass[f.value];
        if (n != 0) std.debug.print("[no-class] {d:>10} {d:>6.2}%  {s}\n", .{ n, @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total)), f.name });
    }
    for (lm_noclass_heads[0..lm_noclass_head_n], lm_noclass_head_lens[0..lm_noclass_head_n], lm_noclass_head_counts[0..lm_noclass_head_n]) |*buf, len, count| {
        std.debug.print("[no-class-head] {d:>10}  {s}\n", .{ count, buf[0..len] });
    }
}

pub fn lowerDeclineDump() void {
    var total: u64 = 0;
    for (lm_decline) |n| total += n;
    if (total == 0) return;
    std.debug.print("[decline] total={d}\n", .{total});
    inline for (@typeInfo(DeclineKind).@"enum".fields) |f| {
        const n = lm_decline[f.value];
        if (n != 0) std.debug.print("[decline] {d:>10} {d:>6.2}%  {s}\n", .{ n, @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total)), f.name });
    }
}

/// Classify a `Call` expression against the strict condition a return-type channel
/// would need: the name must identify one function whose declared

pub fn classifyCallReturn(b: *FuncBuilder, e: *const ast.Expr) NoRecvCall {
    if (e.* != .Call) return .not_simple_callee;
    const callee = e.Call.callee;
    if (callee.* != .Path or callee.Path.segments.len != 1) return .not_simple_callee;
    const nm = callee.Path.segments[0].name;
    const fids = b.module.funcsBySimpleName(nm);
    if (fids.len == 0) return .no_func;
    var seen: ?ir.TypeRef = null;
    for (fids) |fid| {
        const f = b.module.funcById(fid) orelse continue;
        if (f.kind != .plain) continue;
        if (seen) |prev| {
            if (!std.mem.eql(u8, prev.name, f.return_ty.name)) return .ambiguous_return;
        } else seen = f.return_ty;
    }
    const ret = seen orelse return .no_func;
    return if (staticTypeClassId(b, ret) != null) .unique_concrete else .unique_unresolvable;
}

pub fn lowerNoRecvDump() void {
    var total: u64 = 0;
    for (lm_norecv) |n| total += n;
    if (total == 0) return;
    std.debug.print("[no-recv] total={d}\n", .{total});
    inline for (@typeInfo(@typeInfo(ast.Expr).@"union".tag_type.?).@"enum".fields) |f| {
        const n = lm_norecv[f.value];
        if (n != 0) std.debug.print("[no-recv] {d:>10} {d:>6.2}%  {s}\n", .{ n, @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total)), f.name });
    }
    std.debug.print("[no-recv] eager-has-head={d} eager-no-head={d}\n", .{ lm_norecv_eager[0], lm_norecv_eager[1] });
    inline for (@typeInfo(NoRecvPath).@"enum".fields) |f| {
        const n = lm_norecv_path[f.value];
        if (n != 0) std.debug.print("[no-recv-path] {d:>10}  {s}\n", .{ n, f.name });
    }
    inline for (@typeInfo(NoRecvInit).@"enum".fields) |f| {
        const n = lm_norecv_init[f.value];
        if (n != 0) std.debug.print("[no-recv-init] {d:>10}  {s}\n", .{ n, f.name });
    }
    inline for (@typeInfo(NoRecvCall).@"enum".fields) |f| {
        const n = lm_norecv_call[f.value];
        if (n != 0) std.debug.print("[no-recv-call] {d:>10}  {s}\n", .{ n, f.name });
    }
}

/// Report the static member-call gate's per-site coverage, at the end of a run
/// alongside the executed-dispatch census.
pub fn lowerSitesDump() void {
    var total: u64 = 0;
    for (lm_sites) |n| total += n;
    if (total == 0) return;
    std.debug.print("[lower-sites] total={d}\n", .{total});
    inline for (@typeInfo(LmReason).@"enum".fields) |f| {
        const n = lm_sites[f.value];
        if (n != 0) std.debug.print("[lower-sites] {d:>10} {d:>6.2}%  {s}\n", .{ n, @as(f64, @floatFromInt(n)) * 100.0 / @as(f64, @floatFromInt(total)), f.name });
    }
    {
        const e = lm_eager_norecv;
        std.debug.print("[eager-norecv] hits={d} nofunc={d} not_ext={d} arity={d}\n", .{ e[0], e[1], e[2], e[3] });
    }
}
