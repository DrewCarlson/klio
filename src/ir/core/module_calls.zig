const std = @import("std");
const runtime = @import("runtime");
const applicability = @import("applicability");
const root_ir = @import("../ir.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");
const core_names = @import("names.zig");
const core_registry = @import("registry.zig");
const m_static = @import("module_static.zig");

const ClassId = core_ids.ClassId;
const FileId = root_ir.FileId;
const Func = core_func.Func;
const FuncId = core_ids.FuncId;
const FuncKind = core_func.FuncKind;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const ReceiverTowerEntry = core_ids.ReceiverTowerEntry;
const ResolveDeferReason = Module.ResolveDeferReason;
const StaticCompatibility = Module.StaticCompatibility;
const TypeRef = core_ids.TypeRef;
const allShapeNamesNull = core_names.allShapeNamesNull;
const anyParamVararg = Module.anyParamVararg;
const bargTraceEnv = Module.bargTraceEnv;
const callShapesHaveComposerPair = core_names.callShapesHaveComposerPair;
const dropTraceEnv = Module.dropTraceEnv;
const funcHasImplicitThis = Module.funcHasImplicitThis;
const other_package_tier = Module.other_package_tier;
const overrideArgs = Module.overrideArgs;
const rankLowPriority = core_func.rankLowPriority;
const staticTypeVar = Module.staticTypeVar;

/// Resolver verdict: `exact` commits a static target, `virtual` fixes the
/// candidate but picks the leaf at runtime, `deferred` has no static target.
pub const Confidence = enum { exact, virtual, deferred };

pub const EmitForm = enum {
    Call,
    CallMember,
    CallMemberOrGlobal,
    CallValue,
};

/// A resolved bare call; `target` is null on a pure deferral.
pub const Resolution = struct {
    target: ?FuncId,
    confidence: Confidence,
    emit_form: EmitForm,
    candidate_set: []const FuncId = &.{},
    reason: ?ResolveDeferReason = null,
    tier: u8 = 255,
    tier_count: usize = 0,
    /// The target is proven final (unique applicability, an explicit cast, an exact
    /// receiver, or eager type evidence); runtime value types never reopen it.
    target_final: bool = false,
};

/// The receiver-context bits the lowerer computes, passed in so `resolveCall`
/// stays a pure function of (call site, sig index, receiver context).
pub const ResolveCtx = struct {
    in_receiver_context: bool = false,
    unknown_receiver: bool = false,
    /// The only implicit receiver is a FUNCTION-typed extension receiver, whose
    /// member surface is closed, so the member-shadowable gates stand down.
    recv_cannot_shadow: bool = false,
    enclosing_has_member: bool = false,
    /// The body's receiver type is statically known, so `enclosing_has_member`
    /// answered the shadow question exactly; do not widen to the name universe.
    receiver_known: bool = false,
    has_type_args: bool = false,
    /// A `$composer` binding is in scope, so bare composable calls resolve against
    /// their source parameter list before lowering appends the compiler ABI pair.
    has_composer: bool = false,
    cast_pick: ?FuncId = null,
    recv_ty: ?[]const u8 = null,
    recv_type: ?TypeRef = null,
    /// Bounds for type parameters appearing in `recv_type`.
    actual_type_param_bounds: []const ModuleRegistry.TypeParamBound = &.{},
    is_value_capture: bool = false,
    /// The caller sits in a tailrec function body: a positional call to a tailrec
    /// target emits a static tail `Call`, ahead of the member-shadowable walk.
    in_tailrec_body: bool = false,
    /// A lambda argument holds a bare non-local `return`, legal only against an
    /// INLINE callee, so the member-shadowable deferral must not re-route it.
    nonlocal_return_lambda: bool = false,
    /// The class whose body lexically encloses the call. Scopes the member-extension
    /// candidates: only there is that class an implicit dispatch receiver.
    owner_class: ?[]const u8 = null,
    /// `recv_type` and `owner_class` represent every implicit callable receiver and
    /// each hierarchy is complete. Lambdas, thunks, outers and companions: false.
    receiver_scope_complete: bool = false,
    /// The implicit-receiver tower's heads, innermost first: the receivers beyond
    /// `recv_type`/`owner_class` the applicability probe must also consult.
    tower: []const ReceiverTowerEntry = &.{},
    /// `receiver_scope_complete` was proven by the TOWER, not a plain method body.
    /// A tower-unlocked static commit additionally requires a sole candidate.
    tower_scope: bool = false,
};

pub fn funcIsInline(self: *const Module, id: FuncId) bool {
    const f = self.funcById(id) orelse return false;
    return f.is_inline;
}

pub fn isNonExtFid(self: *const Module, id: FuncId) bool {
    const f = self.funcById(id) orelse return true;
    return !funcHasImplicitThis(f);
}

/// A member extension (`fun A.f()` declared in class B) needs two receivers, so
/// a bare call binds one only inside B, a subclass, or when B is an `object`.
pub fn memberExtOutOfScope(self: *const Module, id: FuncId, ctx_owner: ?[]const u8) bool {
    const f = self.funcById(id) orelse return false;
    // The declaration kind, not `f.kind`: a header stub still carries `.plain`.
    if (self.declarationKind(id, f) != .member_extension) return false;
    const owner = self.registry.member_ext_owner_class.get(id) orelse return false;
    for (self.registry.object_names.items) |o| {
        if (std.mem.eql(u8, o, owner)) return false;
    }
    const start = ctx_owner orelse return true;
    return !self.classIsOrExtends(start, owner);
}

/// Hierarchy oracle for the applicability engine: walks `class_super_names` by
/// evidence head, lift-mangling stripped. Interfaces and classes both.
pub fn evidenceSubtypeCb(ctx: *anyopaque, sub: []const u8, super: []const u8) bool {
    const self: *const Module = @ptrCast(@alignCast(ctx));
    if (std.mem.eql(u8, sub, super)) return true;
    var cur_buf: [32][]const u8 = undefined;
    var stack_len: usize = 0;
    cur_buf[stack_len] = sub;
    stack_len += 1;
    var seen_buf: [128][]const u8 = undefined;
    var seen_len: usize = 0;
    while (stack_len != 0) {
        stack_len -= 1;
        const cur = cur_buf[stack_len];
        var already = false;
        for (seen_buf[0..seen_len]) |s2| {
            if (std.mem.eql(u8, s2, cur)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        if (seen_len < seen_buf.len) {
            seen_buf[seen_len] = cur;
            seen_len += 1;
        }
        const chain = self.registry.class_super_names.get(cur) orelse
            (if (self.registry.mangled_nested.get(cur)) |m| self.registry.class_super_names.get(m) else null) orelse
            continue;
        for (chain) |sup_raw| {
            var sn = sup_raw;
            if (std.mem.findScalarLast(u8, sn, '.')) |i| sn = sn[i + 1 ..];
            if (std.mem.findScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
            if (std.mem.findScalarLast(u8, sn, '$')) |i| {
                if (i + 1 < sn.len) sn = sn[i + 1 ..];
            }
            if (std.mem.eql(u8, sn, super)) return true;
            if (stack_len < cur_buf.len) {
                cur_buf[stack_len] = sn;
                stack_len += 1;
            }
        }
    }
    return false;
}

/// Whether `owner` or its hierarchy declares a member called `name`. Gates the
/// receiver-implausibility rule: with no competitor the extension must stand.
pub fn ownerDeclaresMember(self: *const Module, owner: []const u8, name: []const u8) bool {
    if (self.registry.hierarchy_methods.get(owner)) |set| {
        if (set.contains(name)) return true;
    }
    const simple = applicability.simpleName(owner);
    if (!std.mem.eql(u8, simple, owner)) {
        if (self.registry.hierarchy_methods.get(simple)) |set2| {
            if (set2.contains(name)) return true;
        }
    }
    return false;
}

/// Whether an extension candidate's declared receiver could be supplied by the
/// statically known receiver chains. An unresolvable head keeps the candidate.
pub fn extReceiverPlausible(self: *const Module, id: FuncId, f: *const Func, owner: ?[]const u8) bool {
    const dbg = if (runtime.envOnce("KLIO_EXT_TRACE")) |w| std.mem.eql(u8, w, f.name) else false;
    if (dbg) std.debug.print("[extplaus] fid={d} fqn={s} recv_ty={s} owner={?s}\n", .{ id.int(), f.fqn, if (f.params.len != 0) f.params[0].ty.name else "-", owner });
    if (f.params.len == 0) return true;
    var head = applicability.simpleName(f.params[0].ty.name);
    head = std.mem.trimEnd(u8, head, "?");
    if (std.mem.findScalar(u8, head, '<')) |lt| head = head[0..lt];
    if (head.len == 0 or std.mem.eql(u8, head, "Any")) return true;
    if (std.mem.startsWith(u8, head, "Function")) return true;
    if (self.registry.func_type_params.get(id)) |tps| {
        for (tps.items) |tp| {
            if (std.mem.eql(u8, tp, head)) return true;
        }
    }
    // The head must name a class this build knows, or nothing is provable.
    if (self.classId(head) == null and !self.registry.class_super_names.contains(head)) return true;
    var owner_cur: ?[]const u8 = owner orelse return false;
    var hops: usize = 0;
    while (owner_cur) |oc| : (hops += 1) {
        if (hops > 16) break;
        const oc_head = applicability.simpleName(oc);
        if (std.mem.findScalar(u8, oc_head, '$') != null) {
            // A lifted nested class's mangled tail still names it.
            if (std.mem.endsWith(u8, oc_head, head)) return true;
        }
        if (std.mem.eql(u8, oc_head, head)) return true;
        if (self.registry.class_super_names.get(oc)) |chain| {
            for (chain) |sup| {
                var sn = applicability.simpleName(sup);
                if (std.mem.findScalar(u8, sn, '<')) |lt2| sn = sn[0..lt2];
                sn = std.mem.trimEnd(u8, sn, "?");
                if (std.mem.eql(u8, sn, head)) return true;
            }
        } else {
            // Unknown chain: cannot disprove.
            return true;
        }
        owner_cur = self.registry.enclosing_class.get(oc);
    }
    return false;
}

pub fn declSigScore(self: *const Module, fid: FuncId, args: []const applicability.ArgShape) ?applicability.Score {
    const sv = self.sigViewForApplicability(fid, callShapesHaveComposerPair(args)) orelse return .{ .points = 0 };
    const named = !allShapeNamesNull(args);
    return applicability.applicable(&sv, args, .{
        .named = named,
        .recv_external = named,
    });
}

pub fn declSigCompatible(self: *const Module, fid: FuncId, args: []const applicability.ArgShape) bool {
    return self.declSigScore(fid, args) != null;
}

pub const ApplicableBarePick = struct {
    target: ?FuncId = null,
    tier: u8 = 255,
    score: applicability.Score = .{ .points = std.math.minInt(i32) },
    unique: bool = false,
    static_complete: bool = false,
    tier_candidates: usize = 0,
};

pub fn bareScoreGreater(a: applicability.Score, b: applicability.Score) bool {
    if (a.points != b.points) return a.points > b.points;
    if (a.exact_arity != b.exact_arity) return a.exact_arity;
    if (a.proven_args != b.proven_args) return a.proven_args > b.proven_args;
    return a.unknown_args < b.unknown_args;
}

pub fn bareScoreEqual(a: applicability.Score, b: applicability.Score) bool {
    return a.points == b.points and
        a.exact_arity == b.exact_arity and
        a.proven_args == b.proven_args and
        a.unknown_args == b.unknown_args;
}

/// Judge applicability's argument-to-parameter mapping against the identity-aware
/// static type proof. Additive eager heads rank candidates but never reject one.
pub fn staticBareArgsCompatibility(
    self: *const Module,
    fid: FuncId,
    sig: applicability.SigView,
    args: []const applicability.ArgShape,
    score: applicability.Score,
    actual_bounds: []const ModuleRegistry.TypeParamBound,
) StaticCompatibility {
    var result: StaticCompatibility = .compatible;
    var vararg_pos: ?usize = null;
    for (sig.params, 0..) |param, i| {
        if (param.is_vararg) {
            vararg_pos = i;
            break;
        }
    }
    for (args, 0..) |arg_in, i| {
        const param_index: usize = if (score.binding.arg_to_param.len > i)
            score.binding.arg_to_param[i]
        else if (score.binding.trailing_lambda_param) |trailing|
            if (i + 1 == args.len) trailing else if (vararg_pos) |vp|
                if (i >= vp) vp else i
            else
                i
        else if (vararg_pos) |vp|
            if (i >= vp) vp else i
        else
            i;
        if (param_index >= sig.params.len) return .unknown;

        var arg = arg_in;
        if (!arg.ty_authoritative) arg.ty = null;
        var param_ty = if (self.decl_sigs.get(fid.int())) |decl|
            if (param_index < decl.sig.len)
                decl.sig[param_index]
            else
                sig.params[param_index].ty
        else
            sig.params[param_index].ty;
        if (sig.params[param_index].is_vararg and !arg.is_spread) {
            param_ty = applicability.varargElementRef(&param_ty);
        }
        const compatibility = self.staticArgCompatibility(
            fid,
            arg,
            param_ty,
            actual_bounds,
        );
        if (bargTraceEnv()) |w| {
            if (self.funcById(fid)) |bf| {
                if (std.mem.eql(u8, w, bf.name)) {
                    std.debug.print("[barg] {s}#{d} arg{d} param={s} arg_ty={s} lam={} -> {s} route={s}\n", .{
                        bf.name,
                        fid.int(),
                        i,
                        param_ty.name,
                        if (arg.ty) |t| t.name else "-",
                        arg.is_lambda,
                        @tagName(compatibility),
                        m_static.sac_route,
                    });
                }
            }
        }
        if (compatibility == .incompatible) return .incompatible;
        if (compatibility == .unknown) result = .unknown;
    }
    return result;
}

/// Rank one receiverless or receiver-formed candidate group. Scope selection
/// happens after applicability: an inapplicable near tier hides nothing.
pub fn applicableBarePick(
    self: *const Module,
    name: []const u8,
    candidates: []const FuncId,
    args: []const applicability.ArgShape,
    caller_pkg: []const u8,
    caller_file: FileId,
    ctx: ResolveCtx,
    receiver_formed: bool,
) ApplicableBarePick {
    const named = !allShapeNamesNull(args);
    const include_compiler_abi = !ctx.has_composer or callShapesHaveComposerPair(args);
    var arg_to_param = [_]u16{0} ** 64;
    const scope = applicability.ApplicabilityScope{
        .named = named,
        .recv_external = named,
        .arg_to_param_buf = if (named) &arg_to_param else null,
        .ctx = @ptrCast(@constCast(self)),
        .ext_is_subtype_name = evidenceSubtypeCb,
        .type_var = staticTypeVar,
    };
    var best = ApplicableBarePick{};
    const drop_trace = blk: {
        const w = dropTraceEnv() orelse break :blk false;
        break :blk std.mem.eql(u8, w, name);
    };
    for (candidates) |id| {
        const f = self.funcById(id) orelse continue;
        const kind = self.declarationKind(id, f);
        const is_receiver_formed = kind != .plain;
        if (is_receiver_formed != receiver_formed or rankLowPriority(f)) {
            if (drop_trace) std.debug.print("[drop] {s}#{d} form={} lowpri={}\n", .{ name, id.int(), is_receiver_formed != receiver_formed, rankLowPriority(f) });
            continue;
        }
        if (receiver_formed) {
            if (self.memberExtOutOfScope(id, ctx.owner_class)) continue;
            if (ctx.receiver_known and
                !self.extReceiverPlausible(id, f, ctx.owner_class)) continue;
            // The enclosing extension body's own receiver head is evidence too.
            if (kind == .top_level_extension) {
                if (ctx.recv_ty) |rt0| {
                    var rh = applicability.simpleName(std.mem.trimEnd(u8, rt0, "?"));
                    if (std.mem.findScalar(u8, rh, '<')) |lt| rh = rh[0..lt];
                    var plausible = self.extReceiverPlausible(id, f, rh);
                    if (!plausible and ctx.owner_class != null) plausible = self.extReceiverPlausible(id, f, ctx.owner_class);
                    if (!plausible) {
                        for (ctx.tower) |entry| {
                            if (self.extReceiverPlausible(id, f, entry.head)) {
                                plausible = true;
                                break;
                            }
                        }
                    }
                    if (!plausible) {
                        if (drop_trace) std.debug.print("[drop] {s}#{d} ext-recv-implausible-body\n", .{ name, id.int() });
                        continue;
                    }
                }
            }
            // In a receiver lambda the receiver types are not known in the method-body
            // sense, so an unrelated extension can outrank the owner's own member.
            if (!ctx.receiver_known and ctx.recv_ty != null and ctx.owner_class != null and
                self.ownerDeclaresMember(ctx.owner_class.?, name))
            {
                const inner_head = blk_ih: {
                    var h = applicability.simpleName(std.mem.trimEnd(u8, ctx.recv_ty.?, "?"));
                    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
                    break :blk_ih h;
                };
                var plausible = self.extReceiverPlausible(id, f, inner_head);
                if (!plausible) plausible = self.extReceiverPlausible(id, f, ctx.owner_class);
                if (!plausible) {
                    for (ctx.tower) |entry| {
                        if (self.extReceiverPlausible(id, f, entry.head)) {
                            plausible = true;
                            break;
                        }
                    }
                }
                if (!plausible) {
                    if (drop_trace) std.debug.print("[drop] {s}#{d} ext-recv-implausible\n", .{ name, id.int() });
                    continue;
                }
            }
        }
        const sig = self.sigViewForApplicability(id, include_compiler_abi) orelse {
            if (drop_trace) std.debug.print("[drop] {s}#{d} no-sigview\n", .{ name, id.int() });
            continue;
        };
        const score = applicability.applicable(&sig, args, scope) orelse {
            if (drop_trace) std.debug.print("[drop] {s}#{d} inapplicable-shape\n", .{ name, id.int() });
            continue;
        };
        if (drop_trace) std.debug.print("[keep] {s}#{d} params={d} args={d} recv_formed={} at={?d}\n", .{ name, id.int(), sig.params.len, args.len, receiver_formed, if (applicability.trace_call_span) |sp| sp.start else null });
        // Declared-type evidence disproves a receiver-formed candidate exactly as it
        // does a plain one.
        const static_compatibility = self.staticBareArgsCompatibility(
            id,
            sig,
            args,
            score,
            ctx.actual_type_param_bounds,
        );
        if (static_compatibility == .incompatible) {
            if (drop_trace) std.debug.print("[drop] {s}#{d} static-incompatible\n", .{ name, id.int() });
            continue;
        }
        const tier: u8 = if (kind == .member_extension or kind == .instance_method)
            0
        else
            self.scopeTier(f.fqn, f.package, name, caller_pkg, caller_file);
        if (receiver_formed and tier >= other_package_tier) continue;
        if (tier < best.tier) {
            best = .{
                .target = id,
                .tier = tier,
                .score = score,
                .unique = true,
                .static_complete = static_compatibility == .compatible,
                .tier_candidates = 1,
            };
        } else if (tier == best.tier) {
            best.tier_candidates += 1;
            if (best.target == null or bareScoreGreater(score, best.score)) {
                best.target = id;
                best.score = score;
                best.unique = true;
                best.static_complete = static_compatibility == .compatible;
            } else if (bareScoreEqual(score, best.score)) {
                best.unique = false;
            }
        }
    }
    return best;
}

/// The in-scope candidate set (scopeTier <= `tier`) in sig-index order, allocated
/// from `alloc`. Carried on the virtual and deferred forms.
pub fn candidateSet(
    self: *const Module,
    alloc: std.mem.Allocator,
    name: []const u8,
    candidates: []const FuncId,
    caller_pkg: []const u8,
    caller_file: FileId,
    tier: u8,
) std.mem.Allocator.Error![]const FuncId {
    if (tier == 255) return &.{};
    var list: std.ArrayList(FuncId) = .empty;
    for (candidates) |id| {
        const f = self.funcById(id) orelse continue;
        if (self.bareCallTier(f, name, caller_pkg, caller_file) <= tier)
            try list.append(alloc, id);
    }
    return list.toOwnedSlice(alloc);
}

/// `KLIO_BCC_WHY=1`: report why the scoped bare-call candidate set came back empty.
pub fn bccWhyOn() bool {
    const S = struct {
        var known: ?bool = null;
    };
    if (S.known) |k| return k;
    const k = runtime.envSetOnce("KLIO_BCC_WHY");
    S.known = k;
    return k;
}

/// The package/import-scoped callable set for a deferred bare call. `null`: no
/// complete rankable declaration set; empty: rankable but none visible here.
pub fn boundedCallCandidates(
    self: *const Module,
    alloc: std.mem.Allocator,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
    user_arg_count: usize,
) std.mem.Allocator.Error!?[]const FuncId {
    const candidates = try self.bareCallCandidates(alloc, name, caller_file);
    defer alloc.free(candidates);
    const dbg = bccWhyOn();
    if (candidates.len == 0) {
        if (dbg) std.debug.print("[bcc] {s} no-candidates\n", .{name});
        return null;
    }
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    const first_tier = self.lowestVisibleGlobalTier(
        name,
        candidates,
        caller_pkg,
        caller_file,
    );
    if (first_tier == 255) {
        if (dbg) std.debug.print("[bcc] {s} no-visible-tier n={d}\n", .{ name, candidates.len });
        return null;
    }
    if (first_tier >= other_package_tier) {
        if (dbg) std.debug.print("[bcc] {s} other-package-tier n={d}\n", .{ name, candidates.len });
        return try alloc.alloc(FuncId, 0);
    }
    var list: std.ArrayList(FuncId) = .empty;
    var any_arity_match = false;
    for (candidates) |id| {
        const f = self.funcById(id) orelse continue;
        if (self.declarationKind(id, f) != .plain) continue;
        if (self.bareCallTier(f, name, caller_pkg, caller_file) >= other_package_tier) continue;
        try list.append(alloc, id);
        if (self.globalArityCanBind(id, f, user_arg_count)) any_arity_match = true;
    }
    if (!any_arity_match) {
        if (dbg) std.debug.print("[bcc] {s} no-arity-match n={d} kept={d}\n", .{ name, candidates.len, list.items.len });
        list.deinit(alloc);
        return null;
    }
    return @as(?[]const FuncId, try list.toOwnedSlice(alloc));
}

/// The scoped overload set for a bare call with a spread argument; only `vararg`
/// declarations survive. A non-null empty slice means no vararg target in tier.
pub fn boundedSpreadCandidates(
    self: *const Module,
    alloc: std.mem.Allocator,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
) std.mem.Allocator.Error!?[]const FuncId {
    const candidates = try self.bareCallCandidates(alloc, name, caller_file);
    defer alloc.free(candidates);
    if (candidates.len == 0) return null;
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    const tier = self.lowestVisibleGlobalTier(
        name,
        candidates,
        caller_pkg,
        caller_file,
    );
    if (tier == 255) return null;
    if (tier >= other_package_tier) return try alloc.alloc(FuncId, 0);

    var list: std.ArrayList(FuncId) = .empty;
    for (candidates) |id| {
        const f = self.funcById(id) orelse continue;
        if (self.declarationKind(id, f) != .plain) continue;
        if (self.bareCallTier(f, name, caller_pkg, caller_file) > tier) continue;
        if (!self.declarationHasVararg(id, f)) continue;
        try list.append(alloc, id);
    }
    return @as(?[]const FuncId, try list.toOwnedSlice(alloc));
}

/// The declaration kind from the canonical record: while a header is registered
/// the placeholder `Func.kind` may still read `.plain` for an extension.
pub fn declarationKind(self: *const Module, id: FuncId, f: *const Func) FuncKind {
    if (self.decl_sigs.get(id.int())) |ds| {
        // A stub registered plain but declaring a receiver is an extension.
        if (ds.kind == .plain and ds.receiver_ty != null) return .top_level_extension;
        return ds.kind;
    }
    if (f.kind == .plain and f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this")) return .top_level_extension;
    return f.kind;
}

pub fn declarationHasVararg(self: *const Module, id: FuncId, f: *const Func) bool {
    if (self.decl_sigs.get(id.int())) |ds| return ds.arity.has_vararg;
    if (self.stubDeclArity(id)) |arity| return arity.has_vararg;
    return anyParamVararg(f);
}

/// Whether declaration metadata proves a receiverless call count can bind.
pub fn globalArityCanBind(self: *const Module, id: FuncId, f: *const Func, want: usize) bool {
    // The compose pass appends ($composer, $changed); call sites lower with USER
    // argument counts, so the pair never counts toward the required arity.
    const has_pair = f.params.len >= 2 and
        std.mem.eql(u8, f.params[f.params.len - 1].name, "$changed") and
        std.mem.eql(u8, f.params[f.params.len - 2].name, "$composer");
    if (!has_pair) {
        if (self.decl_sigs.get(id.int())) |ds| {
            if (want < ds.arity.required) return false;
            return ds.arity.has_vararg or want <= ds.arity.total;
        }
    }
    const counted = if (has_pair) f.params[0 .. f.params.len - 2] else f.params;
    var required: usize = 0;
    var total: usize = f.params.len;
    var has_vararg = false;
    for (counted) |p| {
        if (p.is_vararg) {
            has_vararg = true;
        } else if (!p.has_default) {
            required += 1;
        }
    }
    _ = &total;
    if (want < required) return false;
    return has_vararg or want <= total;
}

/// The best visible tier among receiverless package-scope functions only: members
/// and extensions belong to the receiver leg of `CallMemberOrGlobal`.
pub fn lowestVisibleGlobalTier(
    self: *const Module,
    name: []const u8,
    candidates: []const FuncId,
    caller_pkg: []const u8,
    caller_file: FileId,
) u8 {
    var best: u8 = 255;
    for (candidates) |id| {
        const f = self.funcById(id) orelse continue;
        if (self.declarationKind(id, f) != .plain) continue;
        if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
        const t = self.bareCallTier(f, name, caller_pkg, caller_file);
        if (t < best) best = t;
    }
    return best;
}

/// The lowest scope tier among the rankable (body, or stub with a declared
/// arity record) candidates named `name`, or 255 when none exists.
pub fn lowestVisibleTier(
    self: *const Module,
    name: []const u8,
    candidates: []const FuncId,
    caller_pkg: []const u8,
    caller_file: FileId,
) u8 {
    var best: u8 = 255;
    for (candidates) |id| {
        const f = self.funcById(id) orelse continue;
        if (!f.hasBody() and self.stubDeclArity(id) == null) continue;
        const t = self.bareCallTier(f, name, caller_pkg, caller_file);
        if (t < best) best = t;
    }
    return best;
}

/// Resolve a bare `name` call: a proven implicit-receiver extension first, then
/// the first tier with an applicable receiverless declaration, then a fallback.
pub fn resolveCall(
    self: *const Module,
    alloc: std.mem.Allocator,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
    args: []const applicability.ArgShape,
    last_arg_lambda: bool,
    ctx: ResolveCtx,
) std.mem.Allocator.Error!Resolution {
    const candidates = try self.bareCallCandidates(alloc, name, caller_file);
    defer alloc.free(candidates);
    return self.resolveCallCandidates(
        alloc,
        name,
        caller_pkg_in,
        caller_file,
        candidates,
        args,
        last_arg_lambda,
        ctx,
    );
}

/// Resolve from a candidate set already enumerated for this source name.
pub fn resolveCallCandidates(
    self: *const Module,
    alloc: std.mem.Allocator,
    name: []const u8,
    caller_pkg_in: []const u8,
    caller_file: FileId,
    candidates: []const FuncId,
    args: []const applicability.ArgShape,
    last_arg_lambda: bool,
    ctx: ResolveCtx,
) std.mem.Allocator.Error!Resolution {
    const caller_pkg = self.packageOfFile(caller_file) orelse caller_pkg_in;
    // The symbol index supplies diagnostic classification and the fallback tier.
    var ires = self.resolveBareCallIndexed(name, caller_pkg, caller_file, args.len, last_arg_lambda);
    if (ctx.cast_pick != null) {
        switch (ires.outcome) {
            .deferred => |r| {
                if (r == .ambiguous_tier or r == .type_overload)
                    ires.outcome = .{ .deferred = .cast_disambiguated };
            },
            .resolved => {},
        }
    }
    var reason: ?ResolveDeferReason = switch (ires.outcome) {
        .resolved => null,
        .deferred => |r| r,
    };

    var target = ctx.cast_pick;
    var tier: u8 = if (target) |id|
        self.bareCallTierOf(id, name, caller_pkg, caller_file) orelse 255
    else
        255;
    var receiver_matched = false;
    var receiver_extension_applicable = false;
    var target_final = ctx.cast_pick != null;

    if (target == null) {
        const receiver = ctx.recv_type orelse if (ctx.recv_ty) |head|
            TypeRef{ .name = head, .nullable = false, .args = &.{} }
        else
            null;
        if (receiver) |recv| {
            var implicit_owners_buf: [2][]const u8 = undefined;
            var implicit_owners_len: usize = 0;
            implicit_owners_buf[implicit_owners_len] = recv.name;
            implicit_owners_len += 1;
            if (ctx.owner_class) |owner| {
                if (!std.mem.eql(u8, owner, recv.name)) {
                    implicit_owners_buf[implicit_owners_len] = owner;
                    implicit_owners_len += 1;
                }
            }
            const ext = self.resolveExtensionCall(name, recv, args, .{
                .caller_file = caller_file,
                .caller_package = caller_pkg,
                .implicit_dispatch_owners = implicit_owners_buf[0..implicit_owners_len],
                .lexical_owner = ctx.owner_class,
                .call_name = name,
                .actual_type_param_bounds = ctx.actual_type_param_bounds,
            });
            receiver_extension_applicable = ext.applicable;
            if (dropTraceEnv()) |w| {
                if (std.mem.eql(u8, w, name)) std.debug.print("[rcc] {s} ext.target={?d} applicable={} args={d}\n", .{ name, if (ext.target) |t| t.int() else null, ext.applicable, args.len });
            }
            if (ext.target) |id| {
                target = id;
                receiver_matched = true;
                if (self.funcById(id)) |f| {
                    const kind = self.declarationKind(id, f);
                    tier = if (kind == .member_extension or kind == .instance_method)
                        0
                    else
                        self.bareCallTier(f, name, caller_pkg, caller_file);
                }
            }
        }
    }

    if (target == null) {
        const global = self.applicableBarePick(
            name,
            candidates,
            args,
            caller_pkg,
            caller_file,
            ctx,
            false,
        );
        target = global.target;
        tier = global.tier;
        target_final = global.target != null and global.unique and
            (global.static_complete or global.tier_candidates == 1);
    }
    if (target == null and ctx.in_receiver_context and
        !receiver_extension_applicable)
    {
        const receiver_formed = self.applicableBarePick(
            name,
            candidates,
            args,
            caller_pkg,
            caller_file,
            ctx,
            true,
        );
        target = receiver_formed.target;
        tier = receiver_formed.tier;
        target_final = receiver_formed.target != null and
            receiver_formed.unique and receiver_formed.tier_candidates == 1;
    }
    if (target != null) reason = null;
    if (tier == 255) {
        tier = if (ires.tier != 255)
            ires.tier
        else
            self.lowestVisibleTier(name, candidates, caller_pkg, caller_file);
    }
    if (runtime.envOnce("KLIO_EXT_TRACE")) |w| {
        if (std.mem.eql(u8, w, name)) std.debug.print(
            "[rescall] {s} target={?d} recv_match={} recv_applicable={} tier={d} owner={?s}\n",
            .{
                name,
                if (target) |id| id.int() else null,
                receiver_matched,
                receiver_extension_applicable,
                tier,
                ctx.owner_class,
            },
        );
    }

    var res = try self.emitFormFor(
        alloc,
        name,
        caller_pkg,
        caller_file,
        target,
        receiver_matched,
        tier,
        reason,
        ires.tier_count,
        candidates,
        args,
        ctx,
    );
    if (res.emit_form == .Call) {
        res.target_final = res.target != null and
            (target_final or receiver_matched);
    }
    return res;
}

/// Whether the committed target is itself `tailrec`, making this call a tail call.
pub fn calleeIsTailrec(self: *const Module, id: FuncId, name: []const u8) bool {
    _ = name;
    if (self.funcById(id)) |f| {
        if (f.is_tailrec) return true;
    }
    return false;
}

/// Whether a statically known implicit receiver has an applicable member or
/// extension named `name`; null unless the receiver scope is provably complete.
pub fn knownReceiverApplicability(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
    args: []const applicability.ArgShape,
    ctx: ResolveCtx,
    include_extensions: bool,
) ?bool {
    if (!ctx.receiver_scope_complete) return null;
    var receivers: [8]TypeRef = undefined;
    var receiver_complete: [8]bool = undefined;
    var receiver_bounds: [8][]const ModuleRegistry.TypeParamBound = undefined;
    var owner_args: [32]TypeRef = undefined;
    var tower_args: [6][32]TypeRef = undefined;
    var receiver_count: usize = 0;
    if (ctx.recv_type orelse if (ctx.recv_ty) |head|
        TypeRef{ .name = head, .nullable = false, .args = &.{} }
    else
        null) |receiver|
    {
        receivers[receiver_count] = receiver;
        receiver_bounds[receiver_count] = ctx.actual_type_param_bounds;
        receiver_complete[receiver_count] = self.staticTypeClassId(receiver) != null and
            self.staticTypeProofComplete(receiver, ctx.actual_type_param_bounds);
        receiver_count += 1;
    }
    if (ctx.owner_class) |owner_name| {
        var owner_receiver = TypeRef{ .name = owner_name, .nullable = false, .args = &.{} };
        const owner_id = self.staticTypeClassId(owner_receiver);
        var owner_complete = false;
        var owner_has_type_params = false;
        var owner_bounds: []const ModuleRegistry.TypeParamBound = &.{};
        if (owner_id) |id| {
            if (id.int() < self.classes.items.len) {
                const class = &self.classes.items[id.int()];
                owner_has_type_params = class.type_params.len != 0;
                if (class.type_params.len <= owner_args.len) {
                    for (class.type_params, 0..) |param, i| {
                        owner_args[i] = .{ .name = param, .nullable = false, .args = &.{} };
                    }
                    owner_receiver = .{
                        .name = class.fqn,
                        .nullable = false,
                        .args = owner_args[0..class.type_params.len],
                    };
                    owner_bounds = self.registry.class_type_param_bounds.get(class.fqn) orelse &.{};
                    owner_complete = self.staticTypeProofComplete(owner_receiver, owner_bounds);
                }
            }
        }
        const duplicate = owner_complete and !owner_has_type_params and
            receiver_count != 0 and blk: {
            const receiver = receivers[0];
            if (!receiver_complete[0] or receiver.nullable or
                self.staticTypeClassId(receiver).? != owner_id.?)
            {
                break :blk false;
            }
            const receiver_args = overrideArgs(receiver);
            const dispatch_args = overrideArgs(owner_receiver);
            if (receiver_args.len != dispatch_args.len) break :blk false;
            for (receiver_args, dispatch_args) |receiver_arg, dispatch_arg| {
                if (!receiver_arg.eql(dispatch_arg)) break :blk false;
            }
            break :blk true;
        };
        if (!duplicate) {
            receivers[receiver_count] = owner_receiver;
            receiver_complete[receiver_count] = owner_complete;
            receiver_bounds[receiver_count] = owner_bounds;
            receiver_count += 1;
        }
    }
    // Tower receivers beyond recv/owner, each symbolically instantiated. An
    // unresolvable head or an overflow marks the scope incomplete: abstain.
    var tower_incomplete = false;
    var tower_slot: usize = 0;
    for (ctx.tower) |tower_entry| {
        var tref = TypeRef{ .name = tower_entry.head, .nullable = false, .args = &.{} };
        const tid = self.staticTypeClassId(tref) orelse {
            tower_incomplete = true;
            continue;
        };
        var dup = false;
        var i: usize = 0;
        while (i < receiver_count) : (i += 1) {
            if (self.staticTypeClassId(receivers[i])) |seen_id| {
                if (seen_id.int() == tid.int()) {
                    dup = true;
                    break;
                }
            }
        }
        if (dup) continue;
        if (receiver_count >= receivers.len or tower_slot >= tower_args.len) {
            tower_incomplete = true;
            break;
        }
        var complete = false;
        var bounds: []const ModuleRegistry.TypeParamBound = &.{};
        if (tid.int() < self.classes.items.len) {
            const class = &self.classes.items[tid.int()];
            if (class.type_params.len <= tower_args[tower_slot].len) {
                for (class.type_params, 0..) |param, k| {
                    tower_args[tower_slot][k] = .{ .name = param, .nullable = false, .args = &.{} };
                }
                tref = .{
                    .name = class.fqn,
                    .nullable = false,
                    .args = tower_args[tower_slot][0..class.type_params.len],
                };
                bounds = self.registry.class_type_param_bounds.get(class.fqn) orelse &.{};
                complete = self.staticTypeProofComplete(tref, bounds);
            }
        }
        receivers[receiver_count] = tref;
        receiver_complete[receiver_count] = complete;
        receiver_bounds[receiver_count] = bounds;
        receiver_count += 1;
        tower_slot += 1;
    }
    if (receiver_count == 0) return null;
    var has_incomplete_receiver = tower_incomplete;
    const lexical_owner: ?ClassId = if (ctx.owner_class) |lexical|
        self.staticTypeClassId(.{ .name = lexical, .nullable = false, .args = &.{} })
    else
        null;
    for (
        receivers[0..receiver_count],
        receiver_complete[0..receiver_count],
        receiver_bounds[0..receiver_count],
    ) |receiver, complete, bounds| {
        if (!complete) {
            has_incomplete_receiver = true;
            continue;
        }
        const owner = self.staticTypeClassId(receiver).?;
        if (self.resolveMemberCall(owner, name, args, .{
            .caller_file = caller_file,
            .lexical_owner = lexical_owner,
            .actual_type_param_bounds = bounds,
            .receiver_type = receiver,
        }).applicable) return true;
    }
    if (!include_extensions) {
        if (has_incomplete_receiver) return null;
        return false;
    }
    // The static extension resolver declines named and spread shapes, so they
    // cannot prove a negative; keep the receiver walk.
    for (args) |arg| {
        if (arg.named != null or arg.is_spread) return null;
    }
    for (
        receivers[0..receiver_count],
        receiver_complete[0..receiver_count],
        receiver_bounds[0..receiver_count],
    ) |receiver, complete, bounds| {
        if (!complete) continue;
        if (self.resolveExtensionCall(name, receiver, args, .{
            .caller_file = caller_file,
            .caller_package = caller_pkg,
            .lexical_owner = ctx.owner_class,
            .call_name = name,
            .actual_type_param_bounds = bounds,
        }).applicable) return true;
    }
    if (has_incomplete_receiver) return null;
    return false;
}

pub fn knownReceiverCallableApplicable(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
    args: []const applicability.ArgShape,
    ctx: ResolveCtx,
) ?bool {
    return self.knownReceiverApplicability(
        name,
        caller_pkg,
        caller_file,
        args,
        ctx,
        true,
    );
}

pub fn knownReceiverMemberApplicable(
    self: *const Module,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
    args: []const applicability.ArgShape,
    ctx: ResolveCtx,
) ?bool {
    return self.knownReceiverApplicability(
        name,
        caller_pkg,
        caller_file,
        args,
        ctx,
        false,
    );
}

/// Whether a tower-unlocked commit is argument-PROVEN: the target judges
/// `.compatible` and every competitor is inapplicable or `.incompatible`.
pub fn towerPickProven(
    self: *const Module,
    target: FuncId,
    candidates: []const FuncId,
    args: []const applicability.ArgShape,
    bounds: []const ModuleRegistry.TypeParamBound,
) bool {
    // `.compatible` means only not refuted, so a proof additionally demands every
    // argument carry an authoritative shape.
    for (args) |arg| {
        if (arg.literal_kind == null and (arg.ty == null or !arg.ty_authoritative)) return false;
    }
    var saw_target = false;
    for (candidates) |cand| {
        const is_target = cand.int() == target.int();
        if (is_target) saw_target = true;
        const sv = self.sigViewForApplicability(cand, callShapesHaveComposerPair(args)) orelse {
            if (is_target) return false;
            continue;
        };
        const named = !allShapeNamesNull(args);
        const score = applicability.applicable(&sv, args, .{
            .named = named,
            .recv_external = named,
        }) orelse {
            if (is_target) return false;
            continue;
        };
        const compat = self.staticBareArgsCompatibility(cand, sv, args, score, bounds);
        if (is_target) {
            if (compat != .compatible) return false;
        } else if (compat != .incompatible) {
            return false;
        }
    }
    return saw_target;
}

/// The member-vs-global decision: `Call` is exact, `CallMember` and
/// `CallMemberOrGlobal` virtual or deferred by target, `CallValue` deferred.
pub fn emitFormFor(
    self: *const Module,
    alloc: std.mem.Allocator,
    name: []const u8,
    caller_pkg: []const u8,
    caller_file: FileId,
    target: ?FuncId,
    receiver_matched: bool,
    tier: u8,
    reason: ?ResolveDeferReason,
    tier_count: usize,
    candidates: []const FuncId,
    args: []const applicability.ArgShape,
    ctx: ResolveCtx,
) std.mem.Allocator.Error!Resolution {
    const known_receiver_applicable = self.knownReceiverCallableApplicable(
        name,
        caller_pkg,
        caller_file,
        args,
        ctx,
    );
    const receiver_shadowable = known_receiver_applicable orelse
        ((ctx.in_receiver_context or ctx.unknown_receiver) and !ctx.recv_cannot_shadow);
    const member_shadowable = receiver_shadowable or ctx.enclosing_has_member or
        (known_receiver_applicable == null and !ctx.receiver_known and
            !ctx.recv_cannot_shadow and
            self.registry.class_member_names.contains(name));
    const cast_static = if (ctx.cast_pick) |cp| (if (target) |t| cp.int() == t.int() else false) else false;
    if (target) |t| {
        const is_ext = if (self.funcById(t)) |f| funcHasImplicitThis(f) else false;
        if (is_ext) {
            const renamed_target = receiver_matched and
                self.renamedImportDenotesFunc(name, caller_file, t);
            const extension_receiver_shadowable = if (renamed_target) blk: {
                const known_member_applicable = self.knownReceiverMemberApplicable(
                    name,
                    caller_pkg,
                    caller_file,
                    args,
                    ctx,
                );
                break :blk (known_member_applicable orelse
                    ((ctx.in_receiver_context or ctx.unknown_receiver) and
                        !ctx.recv_cannot_shadow)) or
                    ctx.enclosing_has_member or
                    (known_member_applicable == null and !ctx.receiver_known and
                        !ctx.recv_cannot_shadow and
                        self.registry.class_member_names.contains(name));
            } else member_shadowable;
            // In a receiver context a member of the implicit receiver could shadow the
            // extension. Unlike the non-extension gate, a cast or type args do not suppress it.
            if (ctx.in_receiver_context and extension_receiver_shadowable) {
                const cs = try self.candidateSet(
                    alloc,
                    name,
                    candidates,
                    caller_pkg,
                    caller_file,
                    tier,
                );
                return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            // A renamed import fixes an identity the alias cannot recover at runtime.
            if (cast_static or renamed_target) {
                return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            // The innermost receiver provably cannot take this extension: it must come
            // from an OUTER implicit receiver only the runtime walk can supply.
            if (known_receiver_applicable == false) {
                const cs = try self.candidateSet(
                    alloc,
                    name,
                    candidates,
                    caller_pkg,
                    caller_file,
                    tier,
                );
                return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            return .{ .target = t, .confidence = .virtual, .emit_form = .CallMember, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        // A positional tail call to a tailrec target emits a static `Call` ahead of the
        // member-shadowable gate; a tail call is never redispatched.
        if (ctx.in_tailrec_body and self.calleeIsTailrec(t, name) and allShapeNamesNull(args)) {
            return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        // Non-extension: the member-shadowable gate, suppressed by the static forms.
        const static_ok = cast_static or ctx.has_type_args or
            (ctx.nonlocal_return_lambda and self.funcIsInline(t));
        const shadow = ctx.in_receiver_context and member_shadowable and !static_ok;
        if (runtime.envOnce("KLIO_EF_TRACE")) |w| {
            if (std.mem.eql(u8, w, name)) std.debug.print("[ef] {s} t={d} inline={} nlr={} recvctx={} shadowable={} shadow={} file={d}\n", .{ name, t.int(), self.funcIsInline(t), ctx.nonlocal_return_lambda, ctx.in_receiver_context, member_shadowable, shadow, caller_file.int() });
        }
        if (!shadow) {
            // A tower-unlocked commit also stands down for a VALUE CAPTURE: an outer local
            // fn sits in a capture cell no tier sees, and Kotlin binds it over every global.
            if (ctx.tower_scope and (ctx.is_value_capture or
                (candidates.len > 1 and
                    !self.towerPickProven(t, candidates, args, ctx.actual_type_param_bounds))))
            {
                const cs = try self.candidateSet(
                    alloc,
                    name,
                    candidates,
                    caller_pkg,
                    caller_file,
                    tier,
                );
                return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
            }
            return .{ .target = t, .confidence = .exact, .emit_form = .Call, .reason = reason, .tier = tier, .tier_count = tier_count };
        }
        const cs = try self.candidateSet(
            alloc,
            name,
            candidates,
            caller_pkg,
            caller_file,
            tier,
        );
        return .{ .target = t, .confidence = .virtual, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
    }
    if (ctx.is_value_capture) {
        return .{ .target = null, .confidence = .deferred, .emit_form = .CallValue, .reason = reason, .tier = tier, .tier_count = tier_count };
    }
    if (ctx.in_receiver_context) {
        const cs = try self.candidateSet(
            alloc,
            name,
            candidates,
            caller_pkg,
            caller_file,
            tier,
        );
        return .{ .target = null, .confidence = .deferred, .emit_form = .CallMemberOrGlobal, .candidate_set = cs, .reason = reason, .tier = tier, .tier_count = tier_count };
    }
    return .{ .target = null, .confidence = .deferred, .emit_form = .CallValue, .reason = reason, .tier = tier, .tier_count = tier_count };
}
