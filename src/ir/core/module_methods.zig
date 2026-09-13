const std = @import("std");
const runtime = @import("runtime");
const applicability = @import("applicability");
const Allocator = std.mem.Allocator;
const root_ir = @import("../ir.zig");
const core_func = @import("func.zig");
const core_ids = @import("ids.zig");
const core_registry = @import("registry.zig");

const ClassId = core_ids.ClassId;
const Func = core_func.Func;
const FuncId = core_ids.FuncId;
const MethodSlotId = core_ids.MethodSlotId;
const Module = root_ir.Module;
const ModuleRegistry = core_registry.ModuleRegistry;
const TypeRef = core_ids.TypeRef;
const classTypeParamIdentity = core_ids.classTypeParamIdentity;
const funcHasImplicitThis = Module.funcHasImplicitThis;
const parseClassTypeParamIdentity = core_ids.parseClassTypeParamIdentity;
const projectionType = Module.projectionType;
const staticTypeHead = Module.staticTypeHead;
const typeRefIsDeclaredParam = Module.typeRefIsDeclaredParam;

pub fn methodDispatchKey(class: ClassId, slot: MethodSlotId) u64 {
    return (@as(u64, class.int()) << 32) | slot.int();
}

/// Concrete implementation selected for `slot` on `runtime_class`.
pub fn methodSlotTarget(self: *const Module, runtime_class: ClassId, slot: MethodSlotId) ?FuncId {
    return self.method_dispatch.get(methodDispatchKey(runtime_class, slot));
}

pub const MethodDispatchEntry = struct {
    runtime_class: ClassId,
    slot: MethodSlotId,
    target: FuncId,
};

pub fn methodDispatchEntries(self: *const Module, allocator: Allocator) Allocator.Error![]MethodDispatchEntry {
    const entries = try allocator.alloc(MethodDispatchEntry, self.method_dispatch.count());
    var it = self.method_dispatch.iterator();
    var i: usize = 0;
    while (it.next()) |entry| : (i += 1) {
        const runtime_class = ClassId.from(@intCast(entry.key_ptr.* >> 32));
        const slot = MethodSlotId.from(@truncate(entry.key_ptr.*));
        entries[i] = .{
            .runtime_class = runtime_class,
            .slot = slot,
            .target = entry.value_ptr.*,
        };
    }
    return entries;
}

pub fn registerMethodSlotTarget(
    self: *Module,
    runtime_class: ClassId,
    slot: MethodSlotId,
    target: FuncId,
) Allocator.Error!void {
    try self.method_dispatch.put(methodDispatchKey(runtime_class, slot), target);
}

pub const TypeBinding = struct {
    name: []const u8,
    ty: TypeRef,
    /// The call site wrote this type argument out. Kotlin takes an
    /// explicit argument as final and does not infer the parameter from
    /// the value arguments at all, so a later value argument may be a
    /// SUBTYPE of it without contradicting it.
    explicit: bool = false,
};

pub fn bindingType(bindings: []const TypeBinding, name: []const u8) ?TypeRef {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding.ty;
    }
    return null;
}

pub fn bindingIsExplicit(bindings: []const TypeBinding, name: []const u8) bool {
    for (bindings) |binding| {
        if (std.mem.eql(u8, binding.name, name)) return binding.explicit;
    }
    return false;
}

pub fn widenBinding(bindings: []TypeBinding, name: []const u8, ty: TypeRef) void {
    for (bindings) |*binding| {
        if (std.mem.eql(u8, binding.name, name)) binding.ty = ty;
    }
}

/// Engine helper for external consumers: substitute `ty` through a
/// solved binding set (arena-scoped result).
pub fn substituteBoundType(allocator: Allocator, ty: TypeRef, bindings: []const TypeBinding) Allocator.Error!TypeRef {
    return substituteType(allocator, ty, bindings);
}

pub fn substituteType(allocator: Allocator, ty: TypeRef, bindings: []const TypeBinding) Allocator.Error!TypeRef {
    const projection_prefix: ?[]const u8 = if (std.mem.startsWith(u8, ty.name, "out#"))
        "out#"
    else if (std.mem.startsWith(u8, ty.name, "in#"))
        "in#"
    else
        null;
    const binding_name = if (projection_prefix) |prefix| ty.name[prefix.len..] else ty.name;
    if (overrideQualifiedPath(ty) == null and
        std.mem.findScalar(u8, ty.name, '.') == null)
    {
        if (bindingType(bindings, binding_name)) |replacement| {
            var out = replacement;
            if (projection_prefix) |prefix| {
                out.name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, replacement.name });
            }
            out.nullable = out.nullable or ty.nullable;
            return out;
        }
    }
    const args = try allocator.alloc(TypeRef, ty.args.len);
    for (ty.args, args) |arg, *out| out.* = try substituteType(allocator, arg, bindings);
    return .{ .name = ty.name, .nullable = ty.nullable, .args = args };
}

pub fn callTypeParam(
    params: []const []const u8,
    name: []const u8,
) bool {
    const head = staticTypeHead(name);
    for (params) |param| {
        if (std.mem.eql(u8, param, head)) return true;
    }
    return false;
}

pub fn callTypeRefParam(
    params: []const []const u8,
    ty: TypeRef,
) bool {
    if (overrideQualifiedPath(ty) != null or
        std.mem.findScalar(u8, ty.name, '.') != null) return false;
    return callTypeParam(params, ty.name);
}

pub fn projectTypeToClass(
    self: *const Module,
    allocator: Allocator,
    actual: TypeRef,
    target: ClassId,
) Allocator.Error!?TypeRef {
    const actual_id = self.staticTypeClassId(actual) orelse return null;
    if (!self.classIdIsOrExtends(actual_id, target)) return null;
    if (actual_id.int() >= self.classes.items.len or
        target.int() >= self.classes.items.len) return null;

    const actual_class = &self.classes.items[actual_id.int()];
    const actual_args = overrideArgs(actual);
    if (actual_args.len < actual_class.type_params.len) return null;
    if (actual_id.int() == target.int()) return actual;

    const identity = try allocator.alloc(TypeBinding, actual_class.type_params.len * 2);
    for (actual_class.type_params, 0..) |param, i| {
        const identity_name = try classTypeParamIdentity(allocator, actual_id, param);
        identity[i * 2] = .{ .name = param, .ty = actual_args[i] };
        identity[i * 2 + 1] = .{ .name = identity_name, .ty = actual_args[i] };
    }
    const inherited = (try self.ancestorBindings(
        allocator,
        actual_id,
        target,
        identity,
        0,
    )) orelse return null;
    const target_class = &self.classes.items[target.int()];
    const projected_args = try allocator.alloc(TypeRef, target_class.type_params.len);
    for (target_class.type_params, 0..) |param, i| {
        projected_args[i] = bindingType(
            inherited,
            try classTypeParamIdentity(allocator, target, param),
        ) orelse return null;
    }
    return .{
        .name = target_class.fqn,
        .nullable = actual.nullable,
        .args = projected_args,
    };
}

pub fn bindCallType(
    self: *const Module,
    allocator: Allocator,
    raw_pattern: TypeRef,
    raw_actual: TypeRef,
    params: []const []const u8,
    bindings: *std.ArrayList(TypeBinding),
    depth: u8,
) Allocator.Error!bool {
    if (depth >= 64) return false;
    const pattern_projection = projectionType(try self.staticAliasType(allocator, raw_pattern, 0));
    const actual_projection = projectionType(try self.staticAliasType(allocator, raw_actual, 0));
    if (pattern_projection.star) return true;
    const pattern = pattern_projection.ty;
    const actual = actual_projection.ty;
    const pattern_head = staticTypeHead(pattern.name);
    if (callTypeRefParam(params, pattern)) {
        if (bindingType(bindings.items, pattern_head)) |bound| {
            // `arrayOf<Base>(Derived())`: the written argument decides the
            // parameter, and the value being a subtype of it is exactly
            // what the call means. Demanding equality here rejected the
            // whole instantiation and left the receiver untyped.
            if (bindingIsExplicit(bindings.items, pattern_head)) return true;
            if (bound.eql(actual)) return true;
            // Kotlin infers the parameter from every constraint together,
            // so a constraint one side already subsumes narrows nothing:
            // `m.getOrDefault(k, Derived())` on a Map<K, Base> means
            // V=Base with the value argument a subtype of it, and
            // `listOf(Derived(), base)` means T=Base by the same rule.
            // Keep the subsuming side; genuinely unrelated constraints
            // (kotlinc would compute a common supertype) still refuse.
            const lub_off = if (std.c.getenv("KLIO_BIND_LUB")) |v|
                std.mem.eql(u8, std.mem.span(v), "0")
            else
                false;
            // `Nothing?` is the null literal's type and the bottom of the
            // lattice, so it constrains nothing but nullability: Kotlin
            // reads `listOf(null, "foo")` as `List<String?>`. Widen to the
            // other constraint and carry the nullability across, in either
            // order. Without this the pair binds nothing, the call has no
            // return type, and every use of the result is left untyped.
            if (std.mem.eql(u8, staticTypeHead(bound.name), "Nothing")) {
                var widened = actual;
                widened.nullable = widened.nullable or bound.nullable;
                widenBinding(bindings.items, pattern_head, widened);
                return true;
            }
            if (std.mem.eql(u8, staticTypeHead(actual.name), "Nothing")) {
                if (actual.nullable and !bound.nullable) {
                    var widened = bound;
                    widened.nullable = true;
                    widenBinding(bindings.items, pattern_head, widened);
                }
                return true;
            }
            const bound_plain = overrideArgs(bound).len == 0;
            const actual_plain = overrideArgs(actual).len == 0;
            if (!lub_off and bound_plain and actual_plain) {
                const bound_head = staticTypeHead(bound.name);
                const actual_head = staticTypeHead(actual.name);
                if ((!actual.nullable or bound.nullable) and
                    self.classIsOrExtends(actual_head, bound_head)) return true;
                if ((!bound.nullable or actual.nullable) and
                    self.classIsOrExtends(bound_head, actual_head))
                {
                    widenBinding(bindings.items, pattern_head, actual);
                    return true;
                }
            }
            return false;
        }
        try bindings.append(allocator, .{ .name = pattern_head, .ty = actual });
        return true;
    }

    const pattern_args = overrideArgs(pattern);
    if (pattern_args.len == 0) return true;
    var projected_actual = actual;
    if (!self.staticTypesShareClassifier(pattern, actual)) {
        // Same-head types with no class row behind the head (the
        // synthetic `Function{N}` family) bind structurally by
        // position: `Function1<Int, T>` against `Function1<Int, Int>`
        // binds `T` even though no classifier backs `Function1`.
        const same_head = std.mem.eql(u8, pattern_head, staticTypeHead(actual.name));
        if (!same_head or self.staticTypeClassId(pattern) != null) {
            const pattern_id = self.staticTypeClassId(pattern) orelse return false;
            projected_actual = (try self.projectTypeToClass(
                allocator,
                actual,
                pattern_id,
            )) orelse return false;
        }
    }
    if (projected_actual.nullable and !pattern.nullable) return false;
    const actual_args = overrideArgs(projected_actual);
    if (pattern_args.len != actual_args.len) return false;
    for (pattern_args, actual_args) |pattern_arg, actual_arg| {
        if (!try self.bindCallType(
            allocator,
            pattern_arg,
            actual_arg,
            params,
            bindings,
            depth + 1,
        )) return false;
    }
    return true;
}

pub fn returnTypeBindingsComplete(
    ty: TypeRef,
    params: []const []const u8,
    bindings: []const TypeBinding,
) bool {
    const head = staticTypeHead(ty.name);
    if (callTypeRefParam(params, ty) and bindingType(bindings, head) == null) return false;
    for (overrideArgs(ty)) |arg| {
        if (!returnTypeBindingsComplete(arg, params, bindings)) return false;
    }
    return true;
}

pub fn typeContainsBoundParam(
    ty: TypeRef,
    bounds: []const ModuleRegistry.TypeParamBound,
) bool {
    if (typeRefIsDeclaredParam(bounds, ty)) return true;
    for (overrideArgs(ty)) |arg| {
        if (typeContainsBoundParam(arg, bounds)) return true;
    }
    return false;
}

pub fn declaredTypeParamBounds(
    self: *const Module,
    allocator: Allocator,
    fid: FuncId,
) Allocator.Error![]const ModuleRegistry.TypeParamBound {
    const params = self.registry.func_type_params.get(fid) orelse return &.{};
    const bounds = try allocator.alloc(ModuleRegistry.TypeParamBound, params.items.len);
    const explicit = self.registry.func_type_param_bounds.get(fid) orelse &.{};
    // The param list can carry a DUPLICATE name when a declaration
    // registered through both the header phase and body placement; one
    // record per NAME, or the multi-bound arms downstream refuse a
    // single-parameter declaration (`Iterable<T>.minus` read bounds=2
    // and staticGenericReceiverApplicable declined every candidate).
    var n: usize = 0;
    outer: for (params.items) |param| {
        for (bounds[0..n]) |seen| {
            if (std.mem.eql(u8, seen.param, param)) continue :outer;
        }
        bounds[n] = .{ .param = param, .bound = "kotlin.Any" };
        for (explicit) |bound| {
            if (std.mem.eql(u8, bound.param, param)) {
                bounds[n].bound = bound.bound;
                bounds[n].complete = bound.complete;
                bounds[n].head_only = bound.head_only;
                break;
            }
        }
        n += 1;
    }
    return bounds[0..n];
}

/// Instantiate the structural return type of an already-resolved call.
/// The target identity comes from the shared call resolver; this step only
/// binds its declaration-owned type parameters from explicit type
/// arguments and the statically-known argument types.
/// Whether `ty` (recursively) names any of `params` — raw source
/// spellings, the form a declared return type carries.
pub fn typeMentionsAnyParamName(ty: *const TypeRef, params: []const []const u8) bool {
    const head = staticTypeHead(std.mem.trimEnd(u8, ty.name, "?"));
    for (params) |p| {
        if (std.mem.eql(u8, head, p)) return true;
    }
    for (ty.args) |*arg| {
        if (typeMentionsAnyParamName(arg, params)) return true;
    }
    return false;
}

pub fn instantiatedCallReturnType(
    self: *const Module,
    allocator: Allocator,
    fid: FuncId,
    receiver: ?TypeRef,
    dispatch_receiver: ?TypeRef,
    args: []const applicability.ArgShape,
    explicit_type_args: []const TypeRef,
) Allocator.Error!?TypeRef {
    return self.instantiatedCallReturnTypeScoped(
        allocator,
        fid,
        receiver,
        dispatch_receiver,
        args,
        explicit_type_args,
        false,
    );
}

/// `owner_params_in_scope`: the CALLER's body is (lexically inside) the
/// target's own class, so the owner's type parameters are names the
/// caller resolves — a bare-head implicit-this projection keeps them as
/// THEMSELVES instead of erasing to `*`: `val data = createFrom(...)`
/// inside `IterableTests<T : Iterable<String>>` types `data: T`, which
/// the bound-ref channel then resolves.
/// The substitution engine's CORE: solve every callee type-parameter
/// binding one call site offers — explicit type args, the owner
/// projection, the receiver, named and positional/vararg arguments,
/// and the star erasure for what stays open. Consumers substitute
/// whatever slot they need against the result. Arena-scoped: the
/// bindings borrow `a` and the module.
pub const SolvedBindings = struct {
    bindings: []TypeBinding,
    type_params: []const []const u8,
};

pub fn solveCallBindings(
    self: *const Module,
    a: Allocator,
    fid: FuncId,
    f: *const Func,
    receiver: ?TypeRef,
    dispatch_receiver: ?TypeRef,
    args: []const applicability.ArgShape,
    explicit_type_args: []const TypeRef,
    owner_params_in_scope: bool,
) Allocator.Error!?SolvedBindings {
    const type_params_list = self.registry.func_type_params.get(fid);
    const function_type_params: []const []const u8 = if (type_params_list) |list|
        list.items
    else
        &.{};
    if (explicit_type_args.len > function_type_params.len) return null;

    var bindings: std.ArrayList(TypeBinding) = .empty;
    for (explicit_type_args, 0..) |ty, i| {
        try bindings.append(a, .{
            .name = function_type_params[i],
            .ty = ty,
            .explicit = true,
        });
    }

    var all_type_params: std.ArrayList([]const u8) = .empty;
    try all_type_params.appendSlice(a, function_type_params);
    const decl_sig = self.decl_sigs.get(fid.int());
    const owner_id = if (decl_sig) |sig| sig.enclosing_class else null;
    if (owner_id) |owner| {
        if (owner.int() >= self.classes.items.len) return null;
        const owner_class = &self.classes.items[owner.int()];
        for (owner_class.type_params) |param| {
            try all_type_params.append(
                a,
                try classTypeParamIdentity(a, owner, param),
            );
        }
        const actual_dispatch_receiver: ?TypeRef = switch (decl_sig.?.kind) {
            .instance_method => dispatch_receiver orelse receiver,
            .member_extension => dispatch_receiver,
            else => null,
        };
        if (owner_class.type_params.len != 0 and
            actual_dispatch_receiver != null)
        {
            const actual_receiver = actual_dispatch_receiver.?;
            const projected_ok = blk2: {
                const projected = (try self.projectTypeToClass(
                    a,
                    actual_receiver,
                    owner,
                )) orelse break :blk2 false;
                const projected_args = overrideArgs(projected);
                if (projected_args.len < owner_class.type_params.len) break :blk2 false;
                for (owner_class.type_params, 0..) |param, i| {
                    try bindings.append(a, .{
                        .name = try classTypeParamIdentity(a, owner, param),
                        .ty = projected_args[i],
                    });
                }
                break :blk2 true;
            };
            // A bare receiver HEAD (an implicit `this` in a method body)
            // carries no type arguments to project — but a return that
            // never mentions the class's parameters is complete without
            // them (`findClause(...): ClauseData?` on a bare
            // SelectImplementation head). A param-mentioning return
            // erases the unknown parameters to star projections instead
            // of refusing: `iterator()` on a bare `Iterable` head yields
            // `Iterator<*>`, whose HEAD is what the initialized local
            // needs to bind its `hasNext()`/`next()`, and `*` is
            // applicability-neutral downstream. `KLIO_STAR_RET=0`
            // disables.
            if (!projected_ok) {
                // The return may reference the owner's parameters by RAW
                // name or by the class-param IDENTITY mangle (an
                // inherited interface header's `Iterator<E>` carries
                // `$class$ N i:E` in its args) — test both, or the star
                // fill skips exactly the headers the completeness check
                // then refuses (`Set.iterator` stayed underivable).
                const mentions = blk_m: {
                    if (typeMentionsAnyParamName(&f.return_ty, owner_class.type_params)) break :blk_m true;
                    for (owner_class.type_params) |param| {
                        const ident = try classTypeParamIdentity(a, owner, param);
                        if (typeMentionsAnyParamName(&f.return_ty, &.{ident})) break :blk_m true;
                    }
                    break :blk_m false;
                };
if (mentions) {
                    if (std.mem.eql(u8, runtime.envOnce("KLIO_STAR_RET") orelse "1", "0")) return null;
                    for (owner_class.type_params) |param| {
                        try bindings.append(a, .{
                            .name = try classTypeParamIdentity(a, owner, param),
                            .ty = if (owner_params_in_scope)
                                .{ .name = param, .nullable = false, .args = &.{} }
                            else
                                .{ .name = "*", .nullable = false, .args = &.{} },
                        });
                    }
                }
            }
        }
    }
    if (runtime.envSetOnce("KLIO_ICRT")) {
        std.debug.print("[icrt] fn={s} ret={s} ret_args={d} decl_sig={} kind={s} owner={} owner_tps={d} fn_tps={d} bindings={d}\n", .{
            f.fqn,
            f.return_ty.name,
            f.return_ty.args.len,
            decl_sig != null,
            if (decl_sig) |sig| @tagName(sig.kind) else "-",
            owner_id != null,
            if (owner_id) |o| (if (o.int() < self.classes.items.len) self.classes.items[o.int()].type_params.len else 999) else 0,
            function_type_params.len,
            bindings.items.len,
        });
    }
    if (runtime.envSetOnce("KLIO_ICRT")) {
        if (f.return_ty.args.len != 0) std.debug.print("[icrt2] {s} arg0={s}\n", .{ f.fqn, f.return_ty.args[0].name });
        if (owner_id) |o| {
            if (o.int() < self.classes.items.len) {
                for (self.classes.items[o.int()].type_params) |tp| std.debug.print("[icrt2] {s} owner_tp={s}\n", .{ f.fqn, tp });
            }
        }
    }
    const type_params = all_type_params.items;
    const inference_type_params = if (decl_sig != null and
        decl_sig.?.kind == .member_extension)
        function_type_params
    else
        type_params;

    const first_param: usize = @intFromBool(funcHasImplicitThis(f));
    // An extension receiver written head-only (a bare implicit `this`)
    // cannot bind the declared receiver's type parameters; the erasure
    // pass below substitutes `*` for the still-unbound ones instead of
    // refusing, exactly as the owner-projection arm above does for
    // members. A receiver WITH arguments that fails to bind is a real
    // mismatch and still refuses here.
    if (first_param != 0 and
        (decl_sig == null or decl_sig.?.kind != .instance_method))
    {
        if (receiver) |actual_receiver| {
            // Project the actual receiver onto the DECLARED head first:
            // a List<String> receiver binds an Iterable<K> pattern
            // (K := String) instead of head-mismatching into a refusal —
            // the same rule the splice window and the sibling-expected
            // solve already apply.
            var recv_eff = actual_receiver;
            if (self.staticTypeClassId(f.params[0].ty)) |dcid| {
                if (try self.projectTypeToClass(a, actual_receiver, dcid)) |projected| {
                    recv_eff = projected;
                }
            }
            if (!try self.bindCallType(
                a,
                f.params[0].ty,
                recv_eff,
                function_type_params,
                &bindings,
                0,
            )) {
                if (actual_receiver.args.len != 0 or
                    std.mem.eql(u8, runtime.envOnce("KLIO_STAR_RET") orelse "1", "0"))
                    return null;
            }
        }
    }
    const params = f.params[first_param..];
    const filled = try a.alloc(bool, params.len);
    @memset(filled, false);

    // Named arguments establish their slots before positional/vararg
    // binding, matching Kotlin's call binding order.
    for (args) |arg| {
        const name = arg.named orelse continue;
        const actual = arg.ty orelse continue;
        for (params, 0..) |param, pi| {
            if (!std.mem.eql(u8, param.name, name)) continue;
            if (filled[pi]) return null;
            if (!try self.bindCallType(
                a,
                param.ty,
                actual,
                inference_type_params,
                &bindings,
                0,
            )) {
                if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: named bind refused param={s}({s} nargs={d}) actual={s} nargs={d}\n", .{ f.fqn, param.name, param.ty.name, overrideArgs(param.ty).len, actual.name, overrideArgs(actual).len });
                return null;
            }
            filled[pi] = true;
            break;
        }
    }

    var next_param: usize = 0;
    for (args, 0..) |arg, ai| {
        if (arg.named != null) continue;
        const actual = arg.ty orelse continue;

        // A trailing callable binds to a trailing function parameter even
        // when defaulted parameters precede it.
        var pi: usize = next_param;
        if (arg.is_lambda and ai + 1 == args.len and params.len != 0 and
            std.mem.startsWith(u8, params[params.len - 1].ty.name, "Function") and
            !filled[params.len - 1])
        {
            pi = params.len - 1;
        } else {
            while (pi < params.len and filled[pi]) pi += 1;
            while (pi < params.len and params[pi].is_vararg) {
                var remaining_positional: usize = 0;
                for (args[ai..]) |tail_arg| {
                    if (tail_arg.named == null) remaining_positional += 1;
                }
                var required_tail: usize = 0;
                for (params[pi + 1 ..], pi + 1..) |tail_param, tail_i| {
                    if (!filled[tail_i] and !tail_param.is_vararg and
                        !tail_param.has_default) required_tail += 1;
                }
                if (remaining_positional > required_tail) break;
                pi += 1;
                while (pi < params.len and filled[pi]) pi += 1;
            }
        }
        if (pi >= params.len) return null;

        var actual_ty = actual;
        if (params[pi].is_vararg and arg.is_spread and
            std.mem.eql(u8, staticTypeHead(actual.name), "Array") and
            overrideArgs(actual).len == 1)
        {
            actual_ty = overrideArgs(actual)[0];
        }
        if (!try self.bindCallType(
            a,
            params[pi].ty,
            actual_ty,
            inference_type_params,
            &bindings,
            0,
        )) {
            if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: positional bind refused param={s}({s} nargs={d}) actual={s} nargs={d}\n", .{ f.fqn, params[pi].name, params[pi].ty.name, overrideArgs(params[pi].ty).len, actual_ty.name, overrideArgs(actual_ty).len });
            return null;
        }
        if (!params[pi].is_vararg) {
            filled[pi] = true;
            next_param = pi + 1;
        } else {
            next_param = pi;
        }
    }

    // A function type parameter still unbound after the receiver and every
    // argument had their chance erases to `*` rather than refusing the
    // whole return: `MutableList(3) { ... }` (a receiver-less generic
    // factory whose lambda carries no inferred type) yields
    // `MutableList<*>` — the HEAD binds the local's member calls, and `*`
    // is applicability-neutral downstream. A hard bind CONFLICT still
    // refused above; this only covers absence. A result erased to a bare
    // `*` head is refused below as before.
    if (!std.mem.eql(u8, runtime.envOnce("KLIO_STAR_RET") orelse "1", "0")) {
        for (function_type_params) |tp| {
            var bound = false;
            for (bindings.items) |bd| {
                if (std.mem.eql(u8, bd.name, tp)) {
                    bound = true;
                    break;
                }
            }
            if (!bound) try bindings.append(a, .{
                .name = tp,
                .ty = .{ .name = "*", .nullable = false, .args = &.{} },
            });
        }
    }
    return .{ .bindings = bindings.items, .type_params = type_params };
}

pub fn instantiatedCallReturnTypeScoped(
    self: *const Module,
    allocator: Allocator,
    fid: FuncId,
    receiver: ?TypeRef,
    dispatch_receiver: ?TypeRef,
    args: []const applicability.ArgShape,
    explicit_type_args: []const TypeRef,
    owner_params_in_scope: bool,
) Allocator.Error!?TypeRef {
    const f = self.funcById(fid) orelse return null;
    // An unannotated source function currently carries Unit as its
    // lowering placeholder. Do not present that placeholder as static
    // receiver evidence.
    if (std.mem.eql(u8, staticTypeHead(f.return_ty.name), "Unit")) return null;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    const solved = (try self.solveCallBindings(
        a,
        fid,
        f,
        receiver,
        dispatch_receiver,
        args,
        explicit_type_args,
        owner_params_in_scope,
    )) orelse return null;
    const bindings_items = solved.bindings;
    const type_params = solved.type_params;
    if (!returnTypeBindingsComplete(f.return_ty, type_params, bindings_items)) {
        if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: bindings incomplete\n", .{f.fqn});
        return null;
    }
    const substituted = try substituteType(a, f.return_ty, bindings_items);
    // A return erased to a bare `*` head names nothing a caller can bind
    // against; it would only pollute the local's declared-type record.
    if (std.mem.eql(u8, staticTypeHead(substituted.name), "*")) {
        if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: star head\n", .{f.fqn});
        return null;
    }
    if (runtime.envSetOnce("KLIO_ICRT")) std.debug.print("[icrt] {s}: OK -> {s}\n", .{ f.fqn, substituted.name });
    return try substituted.clone(allocator);
}

/// Instantiate a declared type of extension `fid` from the ACTUAL
/// receiver: bind the declaration's receiver parameter against
/// `receiver`, then substitute into `ty`. Null when the declaration has
/// no receiver or type parameters, nothing binds, or the substitution
/// stays incomplete — the caller keeps its explicit-args answer.
/// `Iterable<T>.count(predicate: (T) -> Boolean)` on an
/// `Iterable<String>` receiver instantiates `(String) -> Boolean`.
/// The substitution engine's receiver leg, shared by both entry
/// points: solve the callee's type parameters from the ACTUAL
/// receiver against the declared one, substitute into `ty`.
/// `require_complete` demands every parameter `ty` mentions be
/// bound (the return-type contract); without it the parameters the
/// receiver proves substitute and the rest stay as written (the
/// lambda-param contract — its consumer refuses leftover bare
/// heads itself).
pub fn instantiatedTypeFromReceiverImpl(
    self: *const Module,
    allocator: Allocator,
    fid: FuncId,
    ty: TypeRef,
    receiver: TypeRef,
    require_complete: bool,
) Allocator.Error!?TypeRef {
    const f = self.funcById(fid) orelse return null;
    if (f.params.len == 0 or !std.mem.eql(u8, f.params[0].name, "this")) return null;
    const tp_list = self.registry.func_type_params.get(fid);
    const tps: []const []const u8 = if (tp_list) |list| list.items else &.{};
    if (tps.len == 0) return null;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var bindings: std.ArrayList(TypeBinding) = .empty;
    if (!try self.bindCallType(a, f.params[0].ty, receiver, tps, &bindings, 0)) return null;
    if (bindings.items.len == 0) return null;
    if (require_complete and !returnTypeBindingsComplete(ty, tps, bindings.items)) return null;
    const substituted = try substituteType(a, ty, bindings.items);
    return try substituted.clone(allocator);
}

pub fn instantiatedTypeFromReceiver(
    self: *const Module,
    allocator: Allocator,
    fid: FuncId,
    ty: TypeRef,
    receiver: TypeRef,
) Allocator.Error!?TypeRef {
    return self.instantiatedTypeFromReceiverImpl(allocator, fid, ty, receiver, true);
}

/// `instantiatedTypeFromReceiver` without the completeness requirement:
/// substitute the parameters the receiver DOES bind and leave the rest
/// as written. For a `minOfWith(comparator) { selector }` the receiver
/// binds `T` but not the return-only `R`; the lambda-param consumer
/// needs the value-param portion (`T`), and its own guard refuses any
/// entry whose head stayed a bare parameter.
pub fn instantiatedTypeFromReceiverPartial(
    self: *const Module,
    allocator: Allocator,
    fid: FuncId,
    ty: TypeRef,
    receiver: TypeRef,
) Allocator.Error!?TypeRef {
    return self.instantiatedTypeFromReceiverImpl(allocator, fid, ty, receiver, false);
}

/// Instantiate an arbitrary type owned by a resolved declaration from
/// explicit call-site type arguments. Returns null while any declaration
/// type parameter used by `ty` remains unbound.
pub fn instantiatedDeclarationType(
    self: *const Module,
    allocator: Allocator,
    fid: FuncId,
    ty: TypeRef,
    explicit_type_args: []const TypeRef,
) Allocator.Error!?TypeRef {
    const type_params_list = self.registry.func_type_params.get(fid);
    const type_params: []const []const u8 = if (type_params_list) |list|
        list.items
    else
        &.{};
    if (explicit_type_args.len > type_params.len) return null;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var bindings: std.ArrayList(TypeBinding) = .empty;
    for (explicit_type_args, 0..) |explicit, i| {
        try bindings.append(a, .{ .name = type_params[i], .ty = explicit });
    }
    if (!returnTypeBindingsComplete(ty, type_params, bindings.items)) return null;
    const substituted = try substituteType(a, ty, bindings.items);
    return try substituted.clone(allocator);
}

pub fn ancestorBindings(
    self: *const Module,
    allocator: Allocator,
    current: ClassId,
    target: ClassId,
    current_bindings: []const TypeBinding,
    depth: u8,
) Allocator.Error!?[]const TypeBinding {
    if (current.int() == target.int()) {
        var exact_count: usize = 0;
        for (current_bindings) |binding| {
            if (parseClassTypeParamIdentity(binding.name) != null) exact_count += 1;
        }
        const exact = try allocator.alloc(TypeBinding, exact_count);
        var exact_index: usize = 0;
        for (current_bindings) |binding| {
            if (parseClassTypeParamIdentity(binding.name) == null) continue;
            exact[exact_index] = binding;
            exact_index += 1;
        }
        return exact;
    }
    if (depth > 64 or current.int() >= self.classes.items.len) return null;
    const class = &self.classes.items[current.int()];
    for (class.supertypes, 0..) |super_id, edge| {
        if (super_id.int() >= self.classes.items.len) continue;
        const super = &self.classes.items[super_id.int()];
        const super_ref: ?TypeRef = if (edge < class.supertype_refs.len) class.supertype_refs[edge] else null;
        const next = try allocator.alloc(TypeBinding, super.type_params.len * 2);
        for (super.type_params, 0..) |param, i| {
            const identity_name = try classTypeParamIdentity(
                allocator,
                super_id,
                param,
            );
            const supplied: TypeRef = if (super_ref) |ref|
                (if (i < ref.args.len) ref.args[i] else .{ .name = identity_name, .nullable = false, .args = &.{} })
            else
                .{ .name = identity_name, .nullable = false, .args = &.{} };
            const supplied_ty = try substituteType(
                allocator,
                supplied,
                current_bindings,
            );
            next[i * 2] = .{ .name = param, .ty = supplied_ty };
            next[i * 2 + 1] = .{ .name = identity_name, .ty = supplied_ty };
        }
        if (try self.ancestorBindings(allocator, super_id, target, next, depth + 1)) |found| return found;
    }
    return null;
}

pub fn funcTypeParamIndex(self: *const Module, fid: FuncId, name: []const u8) ?usize {
    const params = self.registry.func_type_params.get(fid) orelse return null;
    for (params.items, 0..) |param, i| {
        if (std.mem.eql(u8, param, name)) return i;
    }
    return null;
}

/// `KLIO_OVERRIDES_TRACE=1`: report why `overridesSlot` rejected a
/// candidate. Called once per (own method, inherited slot) pair, so the
/// lookup is resolved once rather than per call.
pub fn overridesTraceOn() bool {
    const S = struct {
        var known: ?bool = null;
    };
    if (S.known) |k| return k;
    const k = runtime.envSetOnce("KLIO_OVERRIDES_TRACE");
    S.known = k;
    return k;
}

/// Class declared directly inside `scope`, matched on the full
/// `scope.name` FQN rather than on a simple name, so an unrelated class
/// sharing the simple name cannot answer.
pub fn classIdDeclaredIn(self: *const Module, scope: []const u8, name: []const u8) ?ClassId {
    for (self.classes.items) |class| {
        if (class.fqn.len != scope.len + name.len + 1) continue;
        if (std.mem.startsWith(u8, class.fqn, scope) and
            class.fqn[scope.len] == '.' and
            std.mem.eql(u8, class.fqn[scope.len + 1 ..], name))
        {
            return class.id;
        }
    }
    return null;
}

pub fn overrideTypeClassId(self: *const Module, fid: FuncId, name: []const u8) ?ClassId {
    if (self.classIdByFqn(name) orelse self.classIdByQualifiedSuffix(name)) |id| return id;
    const sig = self.decl_sigs.get(fid.int()) orelse return null;
    const owner = sig.enclosing_class orelse return null;
    if (self.classIdNestedIn(owner, applicability.simpleName(name))) |id| return id;
    if (owner.int() >= self.classes.items.len) return null;
    // An unqualified classifier written inside a nested class resolves in
    // the enclosing classes' scopes too, so widen outwards along the
    // owner's FQN instead of stopping at the owner itself. `Key` written
    // in `CoroutineContext.Element` names `CoroutineContext.Key`; without
    // this walk the two spellings of one parameter type compare unequal
    // and an override goes unrecognised.
    var scope = self.classes.items[owner.int()].fqn;
    while (true) {
        if (self.classIdDeclaredIn(scope, name)) |id| return id;
        const dot = std.mem.findScalarLast(u8, scope, '.') orelse break;
        scope = scope[0..dot];
    }
    return null;
}

pub fn overrideQualifiedPath(ty: TypeRef) ?[]const u8 {
    for (ty.args) |arg| {
        if (std.mem.startsWith(u8, arg.name, "#qual:")) return arg.name["#qual:".len..];
    }
    return null;
}

pub fn overrideArgs(ty: TypeRef) []TypeRef {
    var end = ty.args.len;
    while (end > 0 and std.mem.startsWith(u8, ty.args[end - 1].name, "#qual:")) end -= 1;
    return ty.args[0..end];
}

pub fn overrideTypeEql(
    self: *const Module,
    candidate: FuncId,
    base: FuncId,
    candidate_ty: TypeRef,
    base_ty: TypeRef,
) bool {
    const candidate_tp = self.funcTypeParamIndex(candidate, candidate_ty.name);
    const base_tp = self.funcTypeParamIndex(base, base_ty.name);
    if (candidate_tp != null or base_tp != null) return candidate_tp != null and candidate_tp == base_tp;
    const candidate_qualified = overrideQualifiedPath(candidate_ty);
    const base_qualified = overrideQualifiedPath(base_ty);
    if (!std.mem.eql(u8, candidate_ty.name, base_ty.name) or
        candidate_qualified != null or base_qualified != null)
    {
        const candidate_class = self.overrideTypeClassId(
            candidate,
            candidate_qualified orelse candidate_ty.name,
        ) orelse return false;
        const base_class = self.overrideTypeClassId(
            base,
            base_qualified orelse base_ty.name,
        ) orelse return false;
        if (candidate_class.int() != base_class.int()) return false;
    }
    const candidate_args = overrideArgs(candidate_ty);
    const base_args = overrideArgs(base_ty);
    if (candidate_ty.nullable != base_ty.nullable or candidate_args.len != base_args.len) return false;
    for (candidate_args, base_args) |ca, ba| {
        if (!self.overrideTypeEql(candidate, base, ca, ba)) return false;
    }
    return true;
}

pub fn overridesSlot(
    self: *const Module,
    allocator: Allocator,
    owner: ClassId,
    candidate: FuncId,
    base: FuncId,
) Allocator.Error!bool {
    const dbg = overridesTraceOn();
    const candidate_func = self.funcById(candidate) orelse return false;
    const base_func = self.funcById(base) orelse return false;
    if (dbg) std.debug.print("[ovr] cand={d} base={d} name={s}/{s} is_override={}\n", .{
        candidate.int(), base.int(), candidate_func.name, base_func.name, candidate_func.is_override,
    });
    if (!candidate_func.is_override or !std.mem.eql(u8, candidate_func.name, base_func.name)) return false;
    const candidate_sig = self.decl_sigs.get(candidate.int()) orelse {
        if (dbg) std.debug.print("[ovr]   no candidate sig\n", .{});
        return false;
    };
    const base_sig = self.decl_sigs.get(base.int()) orelse {
        if (dbg) std.debug.print("[ovr]   no base sig\n", .{});
        return false;
    };
    if (candidate_sig.kind != .instance_method or base_sig.kind != .instance_method) {
        if (dbg) std.debug.print("[ovr]   kind {s}/{s}\n", .{ @tagName(candidate_sig.kind), @tagName(base_sig.kind) });
        return false;
    }
    if (candidate_sig.is_suspend != base_sig.is_suspend or candidate_sig.sig.len != base_sig.sig.len) {
        if (dbg) std.debug.print("[ovr]   siglen {d}/{d}\n", .{ candidate_sig.sig.len, base_sig.sig.len });
        return false;
    }
    const base_owner = base_sig.enclosing_class orelse {
        if (dbg) std.debug.print("[ovr]   no base owner\n", .{});
        return false;
    };

    const owner_class = &self.classes.items[owner.int()];
    const identity = try allocator.alloc(TypeBinding, owner_class.type_params.len * 2);
    for (owner_class.type_params, 0..) |param, i| {
        const identity_name = try classTypeParamIdentity(
            allocator,
            owner,
            param,
        );
        const identity_ty = TypeRef{
            .name = identity_name,
            .nullable = false,
            .args = &.{},
        };
        identity[i * 2] = .{ .name = param, .ty = identity_ty };
        identity[i * 2 + 1] = .{ .name = identity_name, .ty = identity_ty };
    }
    const bindings = (try self.ancestorBindings(allocator, owner, base_owner, identity, 0)) orelse {
        if (dbg) std.debug.print("[ovr]   no ancestor bindings owner={s} base_owner={s}\n", .{
            self.classes.items[owner.int()].fqn, self.classes.items[base_owner.int()].fqn,
        });
        return false;
    };
    for (candidate_sig.sig, base_sig.sig) |candidate_ty, raw_base_ty| {
        const base_ty = try substituteType(allocator, raw_base_ty, bindings);
        if (!self.overrideTypeEql(candidate, base, candidate_ty, base_ty)) {
            if (dbg) std.debug.print("[ovr]   type mismatch {s} vs {s}\n", .{ candidate_ty.name, base_ty.name });
            return false;
        }
    }
    if (dbg) std.debug.print("[ovr]   OK\n", .{});
    return true;
}

pub fn mergeInheritedMethod(
    self: *const Module,
    allocator: Allocator,
    map: *std.AutoHashMap(u32, FuncId),
    slot: u32,
    incoming: FuncId,
) Allocator.Error!void {
    const gop = try map.getOrPut(slot);
    if (!gop.found_existing) {
        gop.value_ptr.* = incoming;
        return;
    }
    const existing = gop.value_ptr.*;
    if (existing.int() == incoming.int()) return;

    gop.value_ptr.* = try self.preferredMethodSlotTarget(allocator, existing, incoming);
    if (std.c.getenv("KLIO_SLOT_TRACE")) |want| {
        const w = std.mem.span(want);
        const chosen = gop.value_ptr.*;
        const en = if (self.funcById(existing)) |f| f.name else "?";
        if (std.mem.eql(u8, w, "*") or std.mem.eql(u8, w, en)) {
            std.debug.print(
                "[slot-merge] slot={d} existing={d} incoming={d} -> {d} ({s})\n",
                .{ slot, existing.int(), incoming.int(), chosen.int(), en },
            );
        }
    }
}

/// Point a slot left naming a bodyless interface declaration at the bodied
/// implementation the class holds for the same member under another slot.
/// A redeclared interface member owns a slot of its own —
/// `MutableList.remove` redeclares `MutableCollection.remove` — while the
/// implementing body arrives through a different supertype edge keyed by
/// the base declaration's slot (`AbstractMutableCollection.remove`), so
/// nothing else connects the two and the redeclaration's slot dispatches
/// into an unexecutable header. Class-owned bodyless declarations are left
/// alone: those are host-linked members, not unmet requirements.
pub fn unifyRedeclaredSlots(
    self: *const Module,
    allocator: Allocator,
    map: *std.AutoHashMap(u32, FuncId),
) Allocator.Error!void {
    if (map.count() < 2) return;
    var it = map.iterator();
    while (it.next()) |entry| {
        const target = entry.value_ptr.*;
        const sig = self.decl_sigs.get(target.int()) orelse continue;
        if (sig.has_body) continue;
        const owner = sig.enclosing_class orelse continue;
        if (owner.int() >= self.classes.items.len or
            !self.classes.items[owner.int()].is_interface) continue;
        var candidates = map.iterator();
        while (candidates.next()) |cand| {
            const impl = cand.value_ptr.*;
            if (impl.int() == target.int()) continue;
            const impl_sig = self.decl_sigs.get(impl.int()) orelse continue;
            if (!impl_sig.has_body) continue;
            if (try self.overridesSlot(allocator, owner, target, FuncId.from(cand.key_ptr.*))) {
                entry.value_ptr.* = impl;
                break;
            }
        }
    }
}

/// Choose the more-specific implementation of one inherited virtual slot.
/// Runtime-defined classes use the same rule when merging the already-linked
/// slot tables of their declared supertypes.
pub fn preferredMethodSlotTarget(
    self: *const Module,
    allocator: Allocator,
    existing: FuncId,
    incoming: FuncId,
) Allocator.Error!FuncId {
    if (existing.int() == incoming.int()) return existing;

    if (self.decl_sigs.get(existing.int())) |sig| {
        if (sig.enclosing_class) |owner| {
            if (try self.overridesSlot(allocator, owner, existing, incoming)) return existing;
        }
    }
    if (self.decl_sigs.get(incoming.int())) |sig| {
        if (sig.enclosing_class) |owner| {
            if (try self.overridesSlot(allocator, owner, incoming, existing)) {
                return incoming;
            }
        }
    }
    return existing;
}

pub fn linkMethodClass(
    self: *Module,
    allocator: Allocator,
    maps: []std.AutoHashMap(u32, FuncId),
    state: []u8,
    cid: ClassId,
) Allocator.Error!void {
    if (cid.int() >= self.classes.items.len or state[cid.int()] == 2) return;
    if (state[cid.int()] == 1) return;
    state[cid.int()] = 1;
    const class = &self.classes.items[cid.int()];
    for (class.supertypes) |super_id| {
        try self.linkMethodClass(allocator, maps, state, super_id);
        if (super_id.int() >= maps.len) continue;
        var inherited = maps[super_id.int()].iterator();
        while (inherited.next()) |entry| {
            try self.mergeInheritedMethod(
                allocator,
                &maps[cid.int()],
                entry.key_ptr.*,
                entry.value_ptr.*,
            );
        }
    }

    // `Class.methods` contains executable bodies only; abstract/interface
    // headers are deliberately absent. Slots are declaration metadata, so
    // enumerate the canonical declaration table instead.
    var own_methods: std.ArrayList(FuncId) = .empty;
    defer own_methods.deinit(allocator);
    var decl_it = self.decl_sigs.iterator();
    while (decl_it.next()) |entry| {
        const decl_owner = entry.value_ptr.enclosing_class orelse continue;
        if (decl_owner.int() != cid.int() or entry.value_ptr.kind != .instance_method) continue;
        try own_methods.append(allocator, FuncId.from(entry.key_ptr.*));
    }
    std.mem.sort(FuncId, own_methods.items, {}, struct {
        fn lessThan(_: void, lhs: FuncId, rhs: FuncId) bool {
            return lhs.int() < rhs.int();
        }
    }.lessThan);
    for (own_methods.items) |fid| {
        const sig = self.decl_sigs.get(fid.int()) orelse continue;
        if (sig.kind != .instance_method or sig.visibility == .Private) continue;
        const inherited_count = maps[cid.int()].count();
        if (inherited_count != 0) {
            const slots = try allocator.alloc(u32, inherited_count);
            defer allocator.free(slots);
            var slot_it = maps[cid.int()].keyIterator();
            var i: usize = 0;
            while (slot_it.next()) |slot| : (i += 1) slots[i] = slot.*;
            for (slots) |slot| {
                const base = FuncId.from(slot);
                if (try self.overridesSlot(allocator, cid, fid, base)) try maps[cid.int()].put(slot, fid);
            }
        }
        try maps[cid.int()].put(MethodSlotId.fromFunc(fid).int(), fid);
    }
    try self.unifyRedeclaredSlots(allocator, &maps[cid.int()]);
    state[cid.int()] = 2;
}

/// Build every `(runtime class, virtual slot) -> implementation` entry once
/// after class and member headers are complete. Generic substitutions are
/// composed along resolved `ClassId` inheritance edges; runtime dispatch is
/// consequently numeric and performs no overload or name resolution.
pub fn linkMethodSlots(self: *Module, allocator: Allocator) Allocator.Error!void {
    self.method_dispatch.clearRetainingCapacity();
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const maps = try sa.alloc(std.AutoHashMap(u32, FuncId), self.classes.items.len);
    for (maps) |*map| map.* = std.AutoHashMap(u32, FuncId).init(sa);
    const state = try sa.alloc(u8, self.classes.items.len);
    @memset(state, 0);
    for (self.classes.items) |class| try self.linkMethodClass(sa, maps, state, class.id);
    for (maps, 0..) |*map, raw_cid| {
        var it = map.iterator();
        while (it.next()) |entry| {
            try self.method_dispatch.put(
                methodDispatchKey(ClassId.from(@intCast(raw_cid)), MethodSlotId.from(entry.key_ptr.*)),
                entry.value_ptr.*,
            );
            if (std.c.getenv("KLIO_SLOT_DUMP")) |want| {
                const w = std.mem.span(want);
                const fid = entry.value_ptr.*;
                const fname = if (self.funcById(fid)) |f| f.name else "?";
                if (std.mem.eql(u8, w, fname)) {
                    const owner = if (self.decl_sigs.get(fid.int())) |s| s.enclosing_class else null;
                    std.debug.print("[slot-dump] class={s} slot={d} -> fid={d} owner={s}\n", .{
                        self.classes.items[raw_cid].fqn,
                        entry.key_ptr.*,
                        fid.int(),
                        if (owner) |o| self.classes.items[o.int()].fqn else "?",
                    });
                }
            }
        }
    }
}
