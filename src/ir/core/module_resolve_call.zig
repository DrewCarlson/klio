const std = @import("std");
const runtime = @import("runtime");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");
const m_static = @import("module_static.zig");

const ClassId = core_ids.ClassId;
const ExtensionResolution = Module.ExtensionResolution;
const ExtensionResolveCtx = Module.ExtensionResolveCtx;
const FileId = root_ir.FileId;
const Func = core_func.Func;
const FuncId = core_ids.FuncId;
const MemberCandidate = Module.MemberCandidate;
const MemberDispatch = Module.MemberDispatch;
const MemberResolution = Module.MemberResolution;
const MemberResolveCtx = Module.MemberResolveCtx;
const Module = root_ir.Module;
const Param = core_func.Param;
const TypeRef = core_ids.TypeRef;
const evidenceSubtypeCb = Module.evidenceSubtypeCb;
const extensionKeyEquivalent = Module.extensionKeyEquivalent;
const extensionKeyGreater = Module.extensionKeyGreater;
const last_in_scope_tier = Module.last_in_scope_tier;
const rankLowPriority = core_func.rankLowPriority;
const recvRefuteOn = Module.recvRefuteOn;
const staticTypeHead = Module.staticTypeHead;
const staticTypeVar = Module.staticTypeVar;
const trailingGapDefaulted = Module.trailingGapDefaulted;
const typeContainsBoundParam = Module.typeContainsBoundParam;

/// Resolve an explicit-receiver top-level extension call from declaration
/// metadata: only a proven receiver and a unique innermost overload commit.
pub fn resolveExtensionCall(
    self: *const Module,
    name: []const u8,
    receiver: TypeRef,
    args: []const applicability.ArgShape,
    ctx: ExtensionResolveCtx,
) ExtensionResolution {
    for (args) |arg| {
        if (arg.is_spread) return .{};
    }
    var scratch = std.heap.ArenaAllocator.init(self.registry.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var scoped_receiver = self.resolveTypeAliasAt(
        sa,
        receiver,
        ctx.caller_file,
        ctx.caller_package,
    ) catch return .{};
    // A receiver headed by a type parameter ranks with its full bound
    // substituted, so a `T : Iterable<String>` receiver refutes `Set.minus`.
    if (scoped_receiver.args.len == 0) {
        const rhead = staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?"));
        if (runtime.envSetOnce("KLIO_HOP_TRACE")) {
            std.debug.print("[hop] {s} recv={s} nbounds={d}\n", .{ name, rhead, ctx.actual_type_param_bounds.len });
            for (ctx.actual_type_param_bounds) |b0| {
                std.debug.print("[hop]   {s} : {s} args={d}\n", .{ b0.param, b0.bound, b0.args.len });
            }
        }
        for (ctx.actual_type_param_bounds) |b| {
            if (!std.mem.eql(u8, b.param, rhead)) continue;
            if (b.args.len == 0) break;
            if (sa.alloc(TypeRef, b.args.len)) |hop_args| {
                for (b.args, hop_args) |an, *dst| {
                    dst.* = .{ .name = an, .nullable = false, .args = &.{} };
                }
                scoped_receiver = .{
                    .name = b.bound,
                    .nullable = false,
                    .args = hop_args,
                };
            } else |_| {}
            break;
        }
    }
    var ids: std.ArrayList(FuncId) = .empty;
    var tiers: std.ArrayList(u8) = .empty;
    var unknowns: std.ArrayList(bool) = .empty;
    var named_maps: std.ArrayList(?[]const usize) = .empty;
    var named_skips: std.ArrayList(bool) = .empty;
    var unknown_best_tier: u8 = 255;
    // Window delimiter for the rex trace: rows up to the next rex-call row.
    if (runtime.envSetOnce("KLIO_REX_TRACE")) {
        if (applicability.trace_call_span) |sp| {
            std.debug.print("[rex-call] {s} recv={s} rargs={d} at=f{d}:{d}\n", .{ name, scoped_receiver.name, scoped_receiver.args.len, sp.file.int(), sp.start });
        } else {
            std.debug.print("[rex-call] {s} recv={s} rargs={d}\n", .{ name, scoped_receiver.name, scoped_receiver.args.len });
        }
    }
    var candidate_it = self.bareCallCandidateIterator(name, ctx.caller_file);
    var receiver_pruned: usize = 0;
    candidate_loop: while (candidate_it.next()) |fid| {
        const f = self.funcById(fid) orelse continue;
        const ds = self.decl_sigs.get(fid.int());
        const kind = if (ds) |decl| decl.kind else f.kind;
        const is_member_extension = kind == .member_extension;
        const rex_trace = runtime.envSetOnce("KLIO_REX_TRACE");
        if (rex_trace) std.debug.print("[rex] {s} fid={d} kind={s} enter recv={s} rargs={d}\n", .{ name, fid.int(), @tagName(kind), scoped_receiver.name, scoped_receiver.args.len });
        if ((kind != .top_level_extension and !is_member_extension) or
            f.params.len == 0 or
            !std.mem.eql(u8, f.params[0].name, "this")) continue;
        // `@Deprecated(level = ERROR|HIDDEN)` is un-callable without
        // `@Suppress("DEPRECATION_ERROR")`, so it is never a static commit.
        if (f.deprecated_error and !core_func.suppress_deprecation_error) continue;
        // Ordered named arguments bind by parameter IDENTITY and may skip defaulted
        // parameters; backwards-reordered and vararg calls keep the positional rule.
        var named_map: ?[]const usize = null;
        var named_map_skips = false;
        {
            var any_named = false;
            for (args) |arg0| {
                if (arg0.named != null) {
                    any_named = true;
                    break;
                }
            }
            var vararg_decl = false;
            for (f.params[1..]) |param| {
                if (param.is_vararg) {
                    vararg_decl = true;
                    break;
                }
            }
            if (any_named and vararg_decl) {
                for (args, 0..) |arg, i| {
                    const arg_name = arg.named orelse continue;
                    const param_index = i + 1;
                    if (param_index >= f.params.len or
                        !applicability.paramNameMatchesArg(
                            f.params[param_index].name,
                            arg_name,
                        ))
                    {
                        continue :candidate_loop;
                    }
                }
            } else if (any_named) {
                const map_buf = sa.alloc(usize, args.len) catch return .{};
                var next: usize = 1;
                for (args, 0..) |arg, i| {
                    if (arg.named) |arg_name| {
                        var j = next;
                        var gap_defaulted = true;
                        const found: ?usize = while (j < f.params.len) : (j += 1) {
                            if (applicability.paramNameMatchesArg(f.params[j].name, arg_name)) break j;
                            if (!f.params[j].has_default and f.params[j].default == null)
                                gap_defaulted = false;
                        } else null;
                        const pj = found orelse continue :candidate_loop;
                        if (!gap_defaulted) continue :candidate_loop;
                        map_buf[i] = pj;
                        next = pj + 1;
                    } else {
                        // A last positional lambda fills the LAST parameter here too.
                        if (i + 1 == args.len and
                            (arg.is_lambda or arg.lambda_arity != null or arg.func_typed) and
                            next < f.params.len - 1 and
                            applicability.isFunctionTypeRef(&f.params[f.params.len - 1].ty))
                        {
                            const gap_defaulted = for (f.params[next .. f.params.len - 1]) |param| {
                                if (!param.has_default and param.default == null) break false;
                            } else true;
                            if (gap_defaulted) {
                                map_buf[i] = f.params.len - 1;
                                next = f.params.len;
                                continue;
                            }
                        }
                        if (next >= f.params.len) continue :candidate_loop;
                        map_buf[i] = next;
                        next += 1;
                    }
                }
                // Everything left unbound past the last binding must default.
                for (f.params[next..]) |param| {
                    if (!param.has_default and param.default == null)
                        continue :candidate_loop;
                }
                named_map = map_buf;
                for (map_buf, 0..) |pj, i| {
                    if (pj != i + 1) {
                        named_map_skips = true;
                        break;
                    }
                }
            }
        }
        if (is_member_extension and
            !self.memberExtensionInScope(fid, f, ds, ctx)) continue;
        const has_source_body = f.hasBody() or
            (if (ds) |decl| decl.has_body else false) or
            self.decl_ast_body.contains(fid.int()) or
            f.is_inline;
        const has_host_symbol = if (ds) |decl| decl.host_symbol != null else false;
        if (!has_source_body and !has_host_symbol) continue;
        const tier: u8 = if (is_member_extension)
            self.memberExtensionScopeTier(
                self.registry.member_ext_owner_class.get(fid) orelse continue,
                ctx,
            )
        else
            64 + @min(
                self.scopeTier(
                    f.fqn,
                    f.package,
                    name,
                    ctx.caller_package,
                    ctx.caller_file,
                ) + 1,
                191,
            );
        if (!is_member_extension and
            tier > 64 + last_in_scope_tier + 1) continue;
        if (ds) |decl| {
            switch (decl.visibility) {
                .Private => {
                    if (!is_member_extension) {
                        const decl_file = self.registry.private_fn_files.get(fid) orelse {
                            unknown_best_tier = @min(unknown_best_tier, tier);
                            continue;
                        };
                        if (decl_file.int() != ctx.caller_file.int()) continue;
                    } else {
                        // A private member extension is visible only in its
                        // declaring class's lexical family, never by inheritance.
                        const owner_name = self.registry.member_ext_owner_class.get(fid) orelse continue;
                        const owner_cid = (self.classIdByFqn(owner_name) orelse
                            self.classId(owner_name)) orelse continue;
                        const lex_name = ctx.lexical_owner orelse continue;
                        const lex_cid = (if (std.mem.findScalar(u8, lex_name, '.') != null)
                            self.classIdByFqn(lex_name)
                        else
                            self.classId(lex_name)) orelse continue;
                        if (!self.lexicalChainContains(lex_cid, owner_cid) and
                            !self.lexicalChainContains(owner_cid, lex_cid)) continue;
                    }
                },
                .Internal => {
                    if (self.internalVisibleFrom(fid, ctx.caller_file)) |visible| {
                        if (!visible) continue;
                    } else {
                        unknown_best_tier = @min(unknown_best_tier, tier);
                        continue;
                    }
                },
                .Protected => if (!is_member_extension) continue,
                .Public => {},
            }
        } else if (self.registry.private_fn_files.get(fid)) |decl_file| {
            if (decl_file.int() != ctx.caller_file.int()) continue;
        }
        var has_vararg = false;
        for (f.params[1..]) |param| {
            if (param.is_vararg) {
                has_vararg = true;
                break;
            }
        }
        if (has_vararg) {
            const required = if (ds) |decl| decl.arity.required else blk: {
                var count: usize = 0;
                for (f.params[1..]) |param| {
                    if (!param.is_vararg and !param.has_default and param.default == null) {
                        count += 1;
                    }
                }
                break :blk count;
            };
            if (args.len < required) continue;
        } else if (named_map == null) {
            if (args.len > f.params.len - 1) continue;
            // Trailing-callable rule at the ARITY gate: the last arg fills the LAST
            // param when that param is function-typed, so only the middle gap defaults.
            const trailing_call = args.len > 0 and args.len < f.params.len - 1 and
                (args[args.len - 1].is_lambda or
                    args[args.len - 1].lambda_arity != null or
                    args[args.len - 1].func_typed) and
                applicability.isFunctionTypeRef(&f.params[f.params.len - 1].ty);
            var omitted_defaults = true;
            if (trailing_call) {
                for (f.params[args.len .. f.params.len - 1]) |param| {
                    if (!param.has_default and param.default == null) {
                        omitted_defaults = false;
                        break;
                    }
                }
            } else {
                for (f.params[1 + args.len ..]) |param| {
                    if (!param.has_default and param.default == null) {
                        omitted_defaults = false;
                        break;
                    }
                }
            }
            if (!omitted_defaults) continue;
        }
        const recv_param = if (ds) |decl| decl.receiver_ty orelse f.params[0].ty else f.params[0].ty;
        const decl_file = if (self.decl_span.get(fid.int())) |decl_source|
            decl_source.file
        else
            null;
        const scoped_recv_param = self.resolveTypeAliasAt(
            sa,
            recv_param,
            decl_file,
            f.package,
        ) catch return .{};
        var compatibility = self.staticReceiverCompatibility(
            fid,
            scoped_receiver,
            scoped_recv_param,
        );
        // `KLIO_RECV_REFUTE=1` (default off): a declared receiver classifier
        // provably unrelated to the proven static receiver refutes outright.
        if (compatibility == .unknown and scoped_receiver.args.len != 0 and
            recvRefuteOn())
        {
            const rh = staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?"));
            const ph = staticTypeHead(std.mem.trimEnd(u8, scoped_recv_param.name, "?"));
            if (!std.mem.eql(u8, rh, ph) and
                self.staticBuiltinIdentity(scoped_receiver, rh) == .yes and
                self.staticBuiltinIdentity(scoped_recv_param, ph) == .yes and
                !evidenceSubtypeCb(@ptrCast(@constCast(self)), rh, ph))
            {
                compatibility = .incompatible;
            }
        }
        const declared_bounds = self.declaredTypeParamBounds(sa, fid) catch return .{};
        if (rex_trace) {
            std.debug.print("[rex] {s} fid={d} bounds={d} compat0={s}", .{ name, fid.int(), declared_bounds.len, @tagName(compatibility) });
            for (declared_bounds) |db| std.debug.print(" {s}<:{s}", .{ db.param, db.bound });
            std.debug.print("\n", .{});
        }
        if (declared_bounds.len != 0) {
            const generic_applies = self.staticGenericReceiverApplicable(
                sa,
                scoped_receiver,
                scoped_recv_param,
                declared_bounds,
                ctx.actual_type_param_bounds,
            ) catch return .{};
            if (rex_trace) std.debug.print("[rex] {s} fid={d} generic_applies={}\n", .{ name, fid.int(), generic_applies });
            if (generic_applies) {
                compatibility = .compatible;
            } else {
                // A bound HEAD the actual receiver provably fails refutes the candidate,
                // but only when both classifiers are known classes.
                var head_refuted = false;
                const recv_head_name = staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?"));
                const recv_cid: ?ClassId = if (std.mem.findScalar(u8, recv_head_name, '.') != null)
                    self.classIdByFqn(recv_head_name)
                else
                    self.classId(recv_head_name);
                if (recv_cid != null) {
                    const recv_param_head = staticTypeHead(std.mem.trimEnd(u8, scoped_recv_param.name, "?"));
                    for (declared_bounds) |db| {
                        if (!std.mem.eql(u8, db.param, recv_param_head)) continue;
                        var bh = staticTypeHead(db.bound);
                        if (std.mem.findScalar(u8, bh, '<')) |lt| bh = bh[0..lt];
                        bh = std.mem.trimEnd(u8, std.mem.trim(u8, bh, " "), "?");
                        if (std.mem.eql(u8, bh, "Any") or std.mem.eql(u8, bh, "kotlin.Any")) continue;
                        const bound_cid: ?ClassId = if (std.mem.findScalar(u8, bh, '.') != null)
                            self.classIdByFqn(bh)
                        else
                            self.classId(bh);
                        if (bound_cid == null) continue;
                        if (!self.classIdIsOrExtends(recv_cid.?, bound_cid.?)) {
                            head_refuted = true;
                            break;
                        }
                    }
                }
                if (rex_trace) std.debug.print("[rex] {s} fid={d} head_refuted={}\n", .{ name, fid.int(), head_refuted });
                if (head_refuted) {
                    compatibility = .incompatible;
                    receiver_pruned += 1;
                } else {
                    var erased_receiver = scoped_receiver;
                    erased_receiver.args = &.{};
                    var erased_param = scoped_recv_param;
                    erased_param.args = &.{};
                    compatibility = if (self.staticReceiverCompatibility(
                        null,
                        erased_receiver,
                        erased_param,
                    ) == .incompatible)
                        .incompatible
                    else
                        .unknown;
                }
            }
        } else if (compatibility == .unknown) {
            const receiver_id = self.staticTypeClassId(scoped_receiver);
            const param_id = self.staticTypeClassId(scoped_recv_param);
            const disjoint_known_classifiers = receiver_id != null and
                param_id != null and
                !self.classIdIsOrExtends(receiver_id.?, param_id.?);
            const known_classifier_path = receiver_id != null and
                param_id != null and
                self.classIdIsOrExtends(receiver_id.?, param_id.?);
            const same_known_classifier = scoped_receiver.args.len != 0 and
                scoped_recv_param.args.len != 0 and
                ((receiver_id != null and param_id != null and
                    receiver_id.? == param_id.?) or
                    (std.mem.eql(
                        u8,
                        staticTypeHead(scoped_receiver.name),
                        staticTypeHead(scoped_recv_param.name),
                    ) and
                        self.staticBuiltinIdentity(
                            scoped_receiver,
                            staticTypeHead(scoped_receiver.name),
                        ) == .yes and
                        self.staticBuiltinIdentity(
                            scoped_recv_param,
                            staticTypeHead(scoped_recv_param.name),
                        ) == .yes));
            if (disjoint_known_classifiers) {
                compatibility = .incompatible;
            } else if (known_classifier_path or same_known_classifier or
                typeContainsBoundParam(receiver, ctx.actual_type_param_bounds))
            {
                const subtype = self.staticTypeIsSubtypeWithBounds(
                    sa,
                    scoped_receiver,
                    scoped_recv_param,
                    ctx.actual_type_param_bounds,
                ) catch return .{};
                if (runtime.envSetOnce("KLIO_DISPROOF_TRACE")) {
                    std.debug.print("[disproof] {s} fid={d} recv={s}<{d}> param={s}<{d}> subtype={} recv_dis={} param_dis={}\n", .{
                        name,
                        fid.int(),
                        scoped_receiver.name,
                        scoped_receiver.args.len,
                        scoped_recv_param.name,
                        scoped_recv_param.args.len,
                        subtype,
                        self.staticTypeDisproofComplete(scoped_receiver, ctx.actual_type_param_bounds),
                        self.staticTypeDisproofComplete(scoped_recv_param, ctx.actual_type_param_bounds),
                    });
                }
                if (subtype) {
                    compatibility = .compatible;
                } else if (self.staticTypeDisproofComplete(
                    scoped_receiver,
                    ctx.actual_type_param_bounds,
                ) and
                    self.staticTypeDisproofComplete(
                        scoped_recv_param,
                        ctx.actual_type_param_bounds,
                    ))
                {
                    compatibility = .incompatible;
                    receiver_pruned += 1;
                }
            }
        }
        if (compatibility == .incompatible) continue;
        if (has_vararg) {
            // `applicability.applicable` maps the fixed/default/vararg positions below;
            // keep the extra proof conservative until it models repeated vararg slots.
            compatibility = .unknown;
        } else {
            // A trailing lambda fills the LAST parameter even across omitted DEFAULTED
            // parameters; the skipped middle must then be all-defaulted.
            const trailing_lambda_arg = args.len != 0 and
                (args[args.len - 1].is_lambda or args[args.len - 1].lambda_arity != null or
                    args[args.len - 1].func_typed) and
                trailingGapDefaulted(f.params[1..], args.len);
            for (args, 0..) |arg, ai| {
                const pi = if (named_map) |mp|
                    mp[ai]
                else if (trailing_lambda_arg and ai + 1 == args.len and
                    1 + args.len <= f.params.len)
                    f.params.len - 1
                else
                    1 + ai;
                const param = f.params[pi];
                // The receiver's instantiation constrains the callee's own type parameters
                // before any argument is judged; unbound params keep the raw path.
                var judged_param = param.ty;
                var subst_param: ?TypeRef = null;
                if (arg.ty != null and
                    self.staticTypeContainsFuncParam(fid, param.ty))
                {
                    if (self.instantiatedTypeFromReceiverPartial(
                        sa,
                        fid,
                        param.ty,
                        scoped_receiver,
                    ) catch null) |s| {
                        subst_param = s;
                        judged_param = s;
                    }
                }
                const arg_compatibility = if (subst_param != null and
                    !self.staticTypeContainsFuncParam(fid, judged_param))
                    self.staticGenericArgCompatibility(fid, arg.ty.?, judged_param, 0)
                else
                    self.staticArgCompatibility(
                        fid,
                        arg,
                        judged_param,
                        ctx.actual_type_param_bounds,
                    );
                if (rex_trace) {
                    std.debug.print("[rex-arg] {s} fid={d} param={s} arg_ty={s} -> {s} route={s}\n", .{
                        name,
                        fid.int(),
                        param.ty.name,
                        if (arg.ty) |t| t.name else "-",
                        @tagName(arg_compatibility),
                        m_static.sac_route,
                    });
                }
                if (arg_compatibility == .incompatible) {
                    compatibility = .incompatible;
                    break;
                }
                if (arg_compatibility == .unknown) compatibility = .unknown;
            }
        }
        if (compatibility == .incompatible) continue;
        if (rex_trace) std.debug.print("[rex] {s} fid={d} KEPT {s}\n", .{ name, fid.int(), @tagName(compatibility) });
        ids.append(sa, fid) catch return .{};
        tiers.append(sa, tier) catch return .{};
        unknowns.append(sa, compatibility == .unknown) catch return .{};
        named_maps.append(sa, named_map) catch return .{};
        named_skips.append(sa, named_map_skips) catch return .{};
    }
    if (ids.items.len == 0) {
        return .{ .applicable = unknown_best_tier != 255 };
    }

    var proof_receiver = scoped_receiver;
    const receiver_alias = self.staticAliasHead(proof_receiver);
    if (receiver_alias.changed and !receiver_alias.structure_lost) {
        proof_receiver.name = receiver_alias.name;
    }
    const proof_args = sa.dupe(applicability.ArgShape, args) catch return .{};
    for (proof_args) |*arg| {
        arg.named = null;
        if (arg.ty) |*ty| {
            const alias = self.staticAliasHead(ty.*);
            if (alias.changed and !alias.structure_lost) ty.name = alias.name;
        }
    }
    const sigs = sa.alloc(applicability.SigView, ids.items.len) catch return .{};
    for (ids.items, 0..) |fid, i| {
        const f = self.funcById(fid).?;
        // A named-mapped candidate presents COMPACTED parameters: each argument's
        // slot holds the parameter its name bound, not raw declaration order.
        const params = if (named_maps.items[i]) |mp| blk_cp: {
            const cp = sa.alloc(Param, mp.len + 1) catch return .{};
            cp[0] = f.params[0];
            for (mp, cp[1..]) |pj, *dst| dst.* = f.params[pj];
            break :blk_cp cp;
        } else sa.dupe(Param, f.params) catch return .{};
        if (params.len != 0) {
            const declared_receiver = if (self.decl_sigs.get(fid.int())) |decl|
                decl.receiver_ty orelse params[0].ty
            else
                params[0].ty;
            const decl_file = if (self.decl_span.get(fid.int())) |decl_source|
                decl_source.file
            else
                null;
            params[0].ty = self.resolveTypeAliasAt(
                sa,
                declared_receiver,
                decl_file,
                f.package,
            ) catch return .{};
        }
        for (params) |*param| {
            const alias = self.staticAliasHead(param.ty);
            if (alias.changed and !alias.structure_lost) param.ty.name = alias.name;
        }
        sigs[i] = .{
            .params = params,
            .has_body = true,
            .low_priority = rankLowPriority(f),
            .is_extension = true,
            .fid = fid,
            .package = f.package,
        };
    }
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .rank_extensions = true,
        .is_extension = true,
        .receiver = .{ .ty = proof_receiver },
        .all_candidates = sigs,
        .ctx = @ptrCast(@constCast(self)),
        .ext_is_subtype_name = evidenceSubtypeCb,
        .type_var = staticTypeVar,
    };

    var best_tier: u8 = 255;
    for (sigs, tiers.items) |*sig, tier| {
        const score = applicability.applicable(sig, proof_args, scope) orelse continue;
        if (score.ext_key.?[0] != 0 and tier < best_tier) best_tier = tier;
    }
    if (best_tier == 255) {
        if (runtime.envSetOnce("KLIO_REX_TRACE")) {
            if (applicability.trace_call_span) |sp| std.debug.print("[rex-exit] {s} no-applicable-tier at=f{d}:{d}\n", .{ name, sp.file.int(), sp.start });
        }
        return .{};
    }
    // A same-or-inner-tier declaration whose visibility metadata is not
    // complete cannot be compared safely with the ranked set.
    if (unknown_best_tier <= best_tier) {
        if (runtime.envSetOnce("KLIO_REX_TRACE")) {
            if (applicability.trace_call_span) |sp| std.debug.print("[rex-exit] {s} unknown-tier {d}<={d} at=f{d}:{d}\n", .{ name, unknown_best_tier, best_tier, sp.file.int(), sp.start });
        }
        return .{ .applicable = true };
    }

    var ranked_sigs: std.ArrayList(applicability.SigView) = .empty;
    var ranked_ids: std.ArrayList(FuncId) = .empty;
    var ranked_unknowns: std.ArrayList(bool) = .empty;
    for (sigs, ids.items, tiers.items, unknowns.items) |sig, fid, tier, unknown| {
        if (tier != best_tier) continue;
        ranked_sigs.append(sa, sig) catch return .{};
        ranked_ids.append(sa, fid) catch return .{};
        ranked_unknowns.append(sa, unknown) catch return .{};
    }
    var ranked_scope = scope;
    ranked_scope.all_candidates = ranked_sigs.items;

    var any_ordinary = false;
    for (ranked_sigs.items) |*sig| {
        const score = applicability.applicable(sig, proof_args, ranked_scope) orelse continue;
        if (score.ext_key.?[0] != 0 and !score.low_priority) any_ordinary = true;
    }
    var best: ?FuncId = null;
    var best_key: [9]i32 = .{std.math.minInt(i32)} ** 9;
    var best_unknown = false;
    var best_recv_param: ?TypeRef = null;
    var best_fid_for_recv: ?FuncId = null;
    var tied = false;
    var tied_ids: std.ArrayList(FuncId) = .empty;
    for (ranked_sigs.items, ranked_ids.items, ranked_unknowns.items) |*sig, fid, unknown| {
        const maybe_score = applicability.applicable(sig, proof_args, ranked_scope);
        if (maybe_score == null and runtime.envSetOnce("KLIO_REX_TRACE")) {
            if (applicability.trace_call_span) |sp| std.debug.print("[rex-key] {s} fid={d} DISQUALIFIED at=f{d}:{d}\n", .{ name, fid.int(), sp.file.int(), sp.start });
        }
        const score = maybe_score orelse continue;
        const key = score.ext_key.?;
        if (runtime.envSetOnce("KLIO_REX_TRACE")) {
            if (applicability.trace_call_span) |sp| {
                std.debug.print("[rex-key] {s} fid={d} key={any} low={} unknown={} at=f{d}:{d}\n", .{ name, fid.int(), key, score.low_priority, unknown, sp.file.int(), sp.start });
            } else {
                std.debug.print("[rex-key] {s} fid={d} key={any} low={} unknown={}\n", .{ name, fid.int(), key, score.low_priority, unknown });
            }
        }
        if (key[0] == 0 or (any_ordinary and score.low_priority)) continue;
        if (best == null or extensionKeyGreater(key, best_key)) {
            best = fid;
            best_key = key;
            best_unknown = unknown;
            best_recv_param = if (sig.params.len != 0) sig.params[0].ty else null;
            best_fid_for_recv = fid;
            tied = false;
            tied_ids.clearRetainingCapacity();
            tied_ids.append(sa, fid) catch return .{};
        } else if (extensionKeyEquivalent(key, best_key)) {
            tied = true;
            tied_ids.append(sa, fid) catch return .{};
        }
    }
    const renamed_best = if (best) |target|
        self.renamedImportDenotesFunc(
            ctx.call_name orelse name,
            ctx.caller_file,
            target,
        )
    else
        false;
    // A renamed import fixes the declaration family by exact FQN; an unknown
    // argument type does not erase that identity once an overload is selected.
    const receiver_supplies_lambda = if (best) |target|
        ranked_sigs.items.len == 1 and
            self.genericReceiverSuppliesLambdaReceiver(target, args)
    else
        false;
    // Exactly one candidate survives elimination by proof, so commit it. Guarded
    // to receivers carrying explicit type arguments; a bare head withholds.
    const sole_off = if (std.c.getenv("KLIO_SOLE_EXT")) |v|
        std.mem.eql(u8, std.mem.span(v), "0")
    else
        false;
    // A member-refuted call commits its sole survivor only when that candidate is
    // declared in the CALLER'S OWN FILE, keeping cross-file chains deferred.
    const sole_same_file = ids.items.len == 1 and blk: {
        const sp = self.decl_span.get(ids.items[0].int()) orelse break :blk false;
        break :blk sp.file.int() == ctx.caller_file.int();
    };
    const sole_survivor = !sole_off and ids.items.len == 1 and
        ranked_sigs.items.len == 1 and scoped_receiver.args.len != 0 and
        (receiver_pruned != 0 or (ctx.member_refuted and sole_same_file));
    // Widened member-refuted commit: an authoritative argument refuted the member
    // and the ext_key winner strictly beat every rival, so it commits anyway.
    var refuted_args_authoritative = true;
    for (proof_args) |pa| {
        if (pa.ty == null and pa.literal_kind == null and
            !pa.is_lambda and pa.lambda_arity == null)
        {
            refuted_args_authoritative = false;
            break;
        }
    }
    // The winner's declared receiver must RELATE to the static receiver: same
    // head, proven subtype, or the winner's own type parameter.
    const winner_recv_related = blk: {
        const brp = best_recv_param orelse break :blk false;
        var wh = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, brp.name, "?")));
        if (std.mem.startsWith(u8, wh, "out#")) wh = wh["out#".len..];
        if (std.mem.startsWith(u8, wh, "in#")) wh = wh["in#".len..];
        const bfid = best_fid_for_recv orelse break :blk false;
        if (self.funcTypeParamIndex(bfid, wh) != null) break :blk true;
        if (wh.len > 0 and wh.len <= 2 and std.ascii.isUpper(wh[0])) break :blk true;
        const rh = applicability.simpleName(staticTypeHead(std.mem.trimEnd(u8, scoped_receiver.name, "?")));
        if (rh.len == 0) break :blk false;
        if (std.mem.eql(u8, rh, wh)) break :blk true;
        if (evidenceSubtypeCb(@ptrCast(@constCast(self)), rh, wh)) break :blk true;
        for (applicability.builtinSupersOf(rh)) |sup| {
            if (std.mem.eql(u8, sup, wh)) break :blk true;
        }
        break :blk false;
    };
    const refuted_member_strict_winner = ctx.member_refuted and
        best != null and !tied and refuted_args_authoritative and
        winner_recv_related;
    if (tied or
        (best_unknown and !receiver_supplies_lambda and !renamed_best and
            !sole_survivor and !refuted_member_strict_winner))
        return .{
            .applicable = true,
            .sole_unknown = if (!tied) best else null,
            .param_rep = if (tied) self.tiedLambdaParamRep(tied_ids.items) else null,
        };
    // A winner whose named arguments skipped defaulted parameters still commits:
    // the Call carries the names. `KLIO_NAMED_COMMIT=0` demotes it to typing.
    if (best) |target| {
        for (ids.items, named_skips.items) |fid, skipped| {
            if (fid != target) continue;
            if (skipped and
                std.mem.eql(u8, runtime.envOnce("KLIO_NAMED_COMMIT") orelse "1", "0"))
                return .{ .applicable = true, .sole_unknown = target };
            break;
        }
    }
    const dispatch_owner = if (best) |target|
        (if (self.registry.member_ext_owner_class.get(target)) |owner|
            self.classIdByFqn(owner)
        else
            null)
    else
        null;
    return .{
        .target = best,
        .dispatch_owner = dispatch_owner,
        .applicable = best != null,
    };
}

/// Resolve one member name against the declarations owned by the static receiver
/// class, and classify it as a direct call or a virtual method slot.
pub fn resolveMemberCall(
    self: *const Module,
    owner: ClassId,
    name: []const u8,
    args: []const applicability.ArgShape,
    ctx: MemberResolveCtx,
) MemberResolution {
    if (owner.int() >= self.classes.items.len) return .{};
    const class = &self.classes.items[owner.int()];
    var scratch = std.heap.ArenaAllocator.init(self.registry.allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var candidates: std.ArrayList(MemberCandidate) = .empty;
    var seen = std.AutoHashMap(u32, void).init(sa);
    self.collectMemberCandidates(sa, owner, name, 0, &seen, &candidates) catch return .{};
    if (candidates.items.len == 0) return .{};

    var named = false;
    for (args) |arg| {
        if (arg.named != null) {
            named = true;
            break;
        }
    }
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .named = named,
        .recv_external = named,
    };
    var best: ?FuncId = null;
    var best_score: i32 = std.math.minInt(i32);
    var tied = false;
    var unknown: ?FuncId = null;
    var unknown_count: usize = 0;
    var visibility_unknown = false;
    var any_applicable = false;
    // A `@Deprecated(level = ERROR|HIDDEN)` member is not a source-level candidate
    // while an ordinary same-name member exists; it is the last resort only.
    var any_ordinary = false;
    for (candidates.items) |candidate| {
        const cf = self.funcById(candidate.fid) orelse continue;
        if (!cf.deprecated_error) {
            any_ordinary = true;
            break;
        }
    }
    for (candidates.items) |candidate| {
        const fid = candidate.fid;
        const ds = self.decl_sigs.get(fid.int()) orelse continue;
        if (any_ordinary) {
            if (self.funcById(fid)) |cf| if (cf.deprecated_error) continue;
        }
        if (ds.kind != .instance_method) continue;
        const declared_owner = ds.enclosing_class orelse owner;
        if (ds.visibility == .Private and
            (ctx.lexical_owner == null or
                !self.lexicalChainContains(ctx.lexical_owner.?, declared_owner))) continue;
        if (ds.visibility == .Protected) {
            const lexical = ctx.lexical_owner orelse continue;
            // Kotlin exposes a protected declaration only within its declaring hierarchy,
            // and to a subclass only through a receiver from that subclass hierarchy.
            const access_owner = self.protectedAccessOwner(
                lexical,
                declared_owner,
            ) orelse continue;
            if (!self.classIdIsOrExtends(owner, access_owner)) continue;
        }
        if (ctx.private_only and ds.visibility != .Private) continue;
        const f = self.funcById(fid) orelse continue;
        // A bodyless member header listing no value parameters yet is judged by its
        // DECLARED arity; an applicable member outranks a same-named extension.
        const lists_this = f.params.len != 0 and std.mem.eql(u8, f.params[0].name, "this");
        const listed_values = f.params.len - @intFromBool(lists_this);
        if (ds.arity.total != 0 and listed_values < ds.arity.required and (!f.hasBody() or listed_values < ds.arity.total)) {
            if (args.len >= ds.arity.required and (args.len <= ds.arity.total or ds.arity.has_vararg)) {
                if (std.c.getenv("KLIO_RMC_TRACE")) |w| {
                    if (std.mem.eql(u8, std.mem.span(w), name)) std.debug.print("[rmc] {s} cand={s}#{d} STUB-UNKNOWN params={d} body={} required={d} total={d}\n", .{ name, f.fqn, fid.int(), f.params.len, f.hasBody(), ds.arity.required, ds.arity.total });
                }
                any_applicable = true;
                unknown = fid;
                unknown_count += 1;
            }
            continue;
        }
        const sig = applicability.SigView{
            .params = f.params,
            // Executability belongs to dispatch, not to overload applicability.
            .has_body = true,
            .low_priority = rankLowPriority(f),
            .is_member = true,
            .fid = fid,
            .package = f.package,
        };
        const score = applicability.applicable(&sig, args, scope) orelse continue;
        if (ds.visibility == .Internal) {
            const caller_file = ctx.caller_file orelse {
                any_applicable = true;
                visibility_unknown = true;
                continue;
            };
            if (self.internalVisibleFrom(fid, caller_file)) |visible| {
                if (!visible) continue;
            } else {
                any_applicable = true;
                visibility_unknown = true;
                continue;
            }
        }
        const rmc_verdict = self.staticMemberArgsCompatibility(
            sa,
            fid,
            f,
            args,
            ctx.actual_type_param_bounds,
            ctx.receiver_type,
        );
        if (runtime.envOnce("KLIO_RMC_TRACE")) |w| {
            if (std.mem.eql(u8, w, name))
                std.debug.print("[rmc] {s} cand={s}#{d} verdict={s} params={d} body={}\n", .{ name, f.fqn, fid.int(), @tagName(rmc_verdict), f.params.len, f.hasBody() });
        }
        switch (rmc_verdict) {
            .incompatible => continue,
            .unknown => {
                any_applicable = true;
                unknown = fid;
                unknown_count += 1;
                continue;
            },
            .compatible => {},
        }
        any_applicable = true;
        var applied = score.points + if (!named and f.params.len != 0)
            applicability.tyEvidenceBonus(f.params[1..], args)
        else
            0;
        if (score.exact_arity) applied += 5;
        if (score.low_priority) applied -= 1000;
        if (applied > best_score) {
            best = fid;
            best_score = applied;
            tied = false;
        } else if (applied == best_score) {
            // Redeclarations of one virtual family are not an overload tie: keep the
            // overriding declaration. A tie between unrelated members still defers.
            const existing = best.?;
            var family = false;
            if (self.decl_sigs.get(fid.int())) |cs| if (cs.enclosing_class) |co| {
                if (self.overridesSlot(sa, co, fid, existing) catch false) {
                    best = fid;
                    family = true;
                }
            };
            if (!family) if (self.decl_sigs.get(existing.int())) |es| if (es.enclosing_class) |eo| {
                if (self.overridesSlot(sa, eo, existing, fid) catch false) family = true;
            };
            if (!family) {
                // DIAMOND family: neither declaration overrides the other but both override
                // one slot the resolution owner inherits; keep the more specific return type.
                const cand_o = self.overridesSlot(sa, owner, fid, existing) catch false;
                const exist_o = self.overridesSlot(sa, owner, existing, fid) catch false;
                if (cand_o or exist_o) {
                    family = true;
                    const cf = self.funcById(fid);
                    const ef = self.funcById(existing);
                    if (cf != null and ef != null and
                        self.staticReceiverCompatibility(null, cf.?.return_ty, ef.?.return_ty) == .compatible and
                        self.staticReceiverCompatibility(null, ef.?.return_ty, cf.?.return_ty) != .compatible)
                    {
                        best = fid;
                    }
                }
            }
            if (!family) tied = true;
        }
    }
    if (visibility_unknown or tied or unknown_count != 0 and best != null) {
        return .{ .applicable = any_applicable };
    }
    if (best == null) {
        if (unknown_count == 1) {
            return .{ .target = unknown, .dispatch = .deferred, .applicable = true };
        }
        return .{ .applicable = any_applicable };
    }
    const target = best.?;
    const ds = self.decl_sigs.get(target.int()).?;
    // Native/expect/abstract headers identify an overload but carry no IR ABI.
    if (!ds.has_body) return .{ .target = target, .dispatch = .virtual, .applicable = true };
    if (ds.visibility == .Private) return .{ .target = target, .dispatch = .direct, .applicable = true };
    const f = self.funcById(target) orelse return .{};
    // An unclaimed classifier header carries no trustworthy final/open/interface
    // modifiers: it can still resolve the overload, but dispatch stays virtual.
    if (class.is_stub) return .{ .target = target, .dispatch = .virtual, .applicable = true };
    const declaring_class = if (ds.enclosing_class) |decl_owner|
        (if (decl_owner.int() < self.classes.items.len) &self.classes.items[decl_owner.int()] else null)
    else
        null;
    // The DECLARING class may itself be an unclaimed header when the owner's
    // bodies lower ahead of it, so an unknown declarer is treated as virtual.
    const declared_on_interface = if (declaring_class) |decl| (decl.is_interface or decl.is_stub) else true;
    // An enum class is extensible by its entries' bodies, which override
    // its `open`/`abstract` members: only a final member is bound direct.
    const closed_class = !class.is_open and !class.is_abstract and !class.is_enum;
    const direct = !class.is_interface and (closed_class or (!declared_on_interface and methodIsFinal(f)));
    if (std.c.getenv("KLIO_DISPATCH_TRACE")) |w| {
        if (std.mem.eql(u8, std.mem.span(w), name)) std.debug.print("[dispatch] {s} owner={s} iface={} open={} abstract={} stub={} decl_owner={s} decl_iface={} decl_stub={} final={} -> {s}\n", .{ name, class.fqn, class.is_interface, class.is_open, class.is_abstract, class.is_stub, if (declaring_class) |d| d.fqn else "-", declared_on_interface, if (declaring_class) |d| d.is_stub else false, methodIsFinal(f), if (direct) "direct" else "virtual" });
    }
    if (direct) {
        return .{ .target = target, .dispatch = .direct, .applicable = true };
    }
    return .{ .target = target, .dispatch = .virtual, .applicable = true };
}

/// The `direct` vs `virtual` choice for an already-identified target. Assuming
/// `virtual` is wrong for a final or private method: it has no vtable slot.
pub fn dispatchForTarget(self: *const Module, owner: ClassId, target: FuncId) ?MemberDispatch {
    if (owner.int() >= self.classes.items.len) return null;
    const class = &self.classes.items[owner.int()];
    const ds = self.decl_sigs.get(target.int()) orelse return null;
    if (!ds.has_body) return .virtual;
    if (ds.visibility == .Private) return .direct;
    const f = self.funcById(target) orelse return null;
    // An unclaimed classifier header reads every modifier false whether the class
    // is closed or merely unlowered, so answer virtual rather than direct.
    if (class.is_stub) return .virtual;
    const declaring_class = if (ds.enclosing_class) |decl_owner|
        (if (decl_owner.int() < self.classes.items.len) &self.classes.items[decl_owner.int()] else null)
    else
        null;
    const declared_on_interface = if (declaring_class) |decl| (decl.is_interface or decl.is_stub) else true;
    if (!class.is_interface and ((!class.is_open and !class.is_abstract and !class.is_enum) or (!declared_on_interface and methodIsFinal(f)))) {
        return .direct;
    }
    return .virtual;
}

pub fn methodIsFinal(f: *const Func) bool {
    if (f.is_open) return false;
    if (f.is_override and !f.is_final) return false;
    return true;
}

pub fn internalVisibleFrom(
    self: *const Module,
    fid: FuncId,
    caller_file: FileId,
) ?bool {
    const caller_module = self.registry.file_modules.get(caller_file);
    const decl_file = if (self.decl_span.get(fid.int())) |decl|
        decl.file
    else
        self.registry.private_fn_files.get(fid) orelse return null;
    const declaration_module = self.registry.file_modules.get(decl_file);
    if (caller_module == null or declaration_module == null) return null;
    return caller_module.? == declaration_module.?;
}

/// Rebuild the owner-scoped index from serialized declaration records: pack
/// images do not serialize this derived table.
pub fn rebuildMemberNameIndex(self: *Module, allocator: Allocator) Allocator.Error!void {
    var old_it = self.member_name_index.valueIterator();
    while (old_it.next()) |list| list.deinit(allocator);
    self.member_name_index.clearRetainingCapacity();
    var sig_it = self.decl_sigs.iterator();
    while (sig_it.next()) |entry| {
        const owner = entry.value_ptr.enclosing_class orelse continue;
        if (owner.int() >= self.classes.items.len) continue;
        const fid = FuncId.from(entry.key_ptr.*);
        const f = self.funcById(fid) orelse continue;
        try self.registerMemberDecl(allocator, self.classes.items[owner.int()].fqn, f.name, fid);
    }
}
