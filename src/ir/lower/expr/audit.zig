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

/// Compile-side half of the `KLIO_OR_AUDIT` detector (the runtime half
/// lives in `ir/eval.zig`): logs every member-vs-global emission decision
/// so a corpus sweep can join emit context against the runtime arm that
/// actually won.
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

/// Test hook: force KLIO_RESOLVE_STRICT on for the current process,
/// bypassing the once-per-process environment read, so an in-process
/// integration test can pin strict mode's verdict on a specific
/// program.
pub fn setResolveStrictForTest(on: bool) void {
    resolve_strict_checked = true;
    resolve_strict_enabled = on;
}

/// Test hook: undo `setResolveStrictForTest` — the next strict-mode
/// read consults the environment again, so a forced setting never
/// leaks past the test that installed it (including under a
/// KLIO_RESOLVE_STRICT=1 suite run).
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

/// Audit one value-position bare reference: the index's pick against
/// the order-based `funcId` pick the runtime's bare-name closure path
/// binds. A divergence where both resolve is the index correcting (or,
/// unexplained, mis-binding) the reference target; the corpus sweep
/// proves zero unexplained before the FQN emission is trusted.
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

/// Per-site census of the static member-call gate (`KLIO_DISPATCH_STATS`),
/// so the coverage of static binding is a number rather than an impression.
pub var lm_sites: [7]u64 = @splat(0);
/// `KLIO_DISPATCH_STATS`: unbound member sites the checker DID resolve, and
/// why each was refused. [0] map hit, [1] no such func, [2] not an
/// extension, [3] arity mismatch. A zero at [0] means the two sets — what
/// the checker answered and what lowering could not bind — do not intersect
/// at all, which is a different problem from a guard being too strict.
pub var lm_eager_norecv: [4]u64 = @splat(0);
pub const LmReason = enum(u8) { no_receiver_type, nullable_or_generic, no_class_id, resolver_declined, bound_static, bound_virtual, dynamic_by_design };
pub fn lmNote(comptime r: LmReason) void {
    lm_sites[@intFromEnum(r)] += 1;
}

/// Breakdown of the `no_receiver_type` bucket by the SHAPE of the receiver
/// expression, indexed by its `ast.Expr` tag. The bucket is ~73% of all member
/// call sites, so "lowering has no receiver type" is the whole static-dispatch
/// problem; which expressions those are decides whether the fix belongs in
/// typeck's inference, in an AST probe lowering is not consulting, or nowhere.
pub var lm_norecv: [@typeInfo(@typeInfo(ast.Expr).@"union".tag_type.?).@"enum".fields.len]u64 = @splat(0);

/// Whether the `no_receiver_type` breakdown is being collected. Classifying a
/// site walks same-named declarations, which is real lowering-time work, so it
/// happens only when the census is asked for. Resolved once per process.
var norecv_census: ?bool = null;
pub fn norecvCensusOn() bool {
    if (norecv_census) |v| return v;
    const v = runtime.envOnce("KLIO_DISPATCH_STATS") != null;
    norecv_census = v;
    return v;
}

/// Of the `no_receiver_type` sites, how many typeck DID record a type head for
/// (it is simply not consulted for the receiver position) versus how many it
/// has no answer for at all.
pub var lm_norecv_eager: [2]u64 = @splat(0);

/// Sub-census of the `Path` shape (the largest `no_receiver_type` bucket):
/// what KIND of name the untyped receiver is, which decides where the missing
/// type has to come from.
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

/// Of the locals with no recorded declared type, whether an initializer
/// expression was recorded for the name at all. No initializer means the
/// binding form never registered one (loop variable, lambda parameter,
/// destructured component, catch parameter); an initializer that still yields
/// no type means the initializer's own type is unknown.
pub const NoRecvInit = enum(u8) { no_init_recorded, init_yields_no_type };
pub var lm_norecv_init: [2]u64 = @splat(0);

/// Why a `Call` initializer yields no type. `argDeclTypeRefLazy` has channels
/// for a local function, a function-typed parameter, and a constructor, but
/// none for a module-level function's DECLARED return type, so this measures
/// what such a channel would be worth and how often it could not be trusted.
pub const NoRecvCall = enum(u8) {
    /// Callee is not a plain single-name call (a member or complex callee).
    not_simple_callee,
    /// No function of that name is known.
    no_func,
    /// Several same-named functions disagree on their return type.
    ambiguous_return,
    /// Unique concrete declared return type: a channel would answer here.
    unique_concrete,
    /// Unique, but the return type names nothing resolvable to a class — a
    /// type parameter or an unknown head, which the declaration alone does not
    /// fix.
    unique_unresolvable,
};
pub var lm_norecv_call: [5]u64 = @splat(0);

/// Breakdown of the `resolver_declined` bucket — sites where lowering DID have
/// a receiver type and the resolver still refused to name a declaration. It is
/// the second-largest bucket and, unlike `no_receiver_type`, needs nothing from
/// typeck, so it is the cheapest remaining coverage to reason about.
pub const DeclineKind = enum(u8) {
    /// The resolver identified the declaration but withheld a dispatch
    /// commitment. The identity is already proven here.
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
    /// A named or vararg argument list that could not be mapped onto the
    /// target's parameters.
    arg_mapping_failed,
};
pub var lm_decline: [11]u64 = @splat(0);

pub fn declineNote(k: DeclineKind) void {
    lmNote(.resolver_declined);
    if (norecvCensusOn()) lm_decline[@intFromEnum(k)] += 1;
}

/// Why a `target_known_deferred` site had to ASK the extension question at
/// all — the identity is proven at every one of these. Most go on to be
/// promoted by the proof; the variant names which reachable extension the
/// proof then has to refute. Counted before the proof runs, so this total
/// is larger than `resolver_declined`.
pub const PromoBlock = enum(u8) {
    /// An extension whose receiver is a TYPE PARAMETER declares this name, so
    /// the index cannot say which receivers it serves. The blunt one.
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

/// Why `localInitTypeRef` did or did not answer: no initializer, a constructor,
/// no derivable return type, incomplete type arguments, derived.
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

/// Breakdown of `no_class_id` — lowering HAS a receiver type and cannot map its
/// head to a declared class. Nothing here needs typeck; it is name resolution.
pub const NoClassKind = enum(u8) {
    /// A dotted name that `classIdByFqn` does not know.
    fqn_unknown,
    /// A bare head that no class declares.
    simple_unknown,
    /// A bare head that SEVERAL classes declare, so the simple-name lookup
    /// refuses to pick — the ambiguity a fully qualified answer would settle.
    simple_ambiguous,
};
pub var lm_noclass: [3]u64 = @splat(0);

/// The heads behind the `no_class_id` count, captured at the site into a
/// fixed buffer so the dump can name them — the per-site env trace loses
/// rows that fire before diagnostics settle, and a count with no names sent
/// a whole scoping pass guessing.
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

/// Classify a `Call` expression against the strict condition a return-type
/// channel would need: the name must identify one function whose declared

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

/// Report the static member-call gate's per-site coverage. Called at the end
/// of a run alongside the executed-dispatch census.
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
