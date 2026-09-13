//! Argument/parameter type probing and overload scoring: the shared applicability
//! engine's member and extension adapters, `argDefinitelyNotParamType`, and
//! `pickMethodOverload`.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const stdlib = @import("stdlib");
const applicability = @import("applicability");
const vmhost = @import("../vmhost.zig");
const ClassTable = @import("../../build.zig").ClassTable;
const VmHost = vmhost.VmHost;
const trace = @import("../trace.zig");
const overload_match = @import("../overload_match.zig");
const host_call_func = @import("../host_call_func.zig");
const compose = @import("../compose.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;

const binding_probe = @import("binding_probe.zig");
const isBoundReference = binding_probe.isBoundReference;

const ext_fallback = @import("ext_fallback.zig");
const enclosingChainClassOrder = ext_fallback.enclosingChainClassOrder;
const isSubtypeName = ext_fallback.isSubtypeName;

const flat_call = @import("flat_call.zig");
const prependReceiver = flat_call.prependReceiver;

const hcm = @import("../host_call_member.zig");
const cacheGen = hcm.cacheGen;
const callFuncRec = hcm.callFuncRec;
const checkFuncInRange = hcm.checkFuncInRange;
const checkOverloadUnique = hcm.checkOverloadUnique;
const classDisplayName = hcm.classDisplayName;
const simpleName = hcm.simpleName;

const member_ext_visibility = @import("member_ext_visibility.zig");
const isMemberExt = member_ext_visibility.isMemberExt;

const receiver_probe = @import("receiver_probe.zig");
const allUppercase = receiver_probe.allUppercase;
const applicTypeVarCbM = receiver_probe.applicTypeVarCbM;
const builtinKindMismatch = receiver_probe.builtinKindMismatch;
const extReceiverSpecificity = receiver_probe.extReceiverSpecificity;
const isCallable = receiver_probe.isCallable;
const isFunctionTypeRef = receiver_probe.isFunctionTypeRef;
const isFunctionTypeRefResolved = receiver_probe.isFunctionTypeRefResolved;
const mangledClassKeyOf = receiver_probe.mangledClassKeyOf;
const paramTypeIsTypeVar = receiver_probe.paramTypeIsTypeVar;
const resolveAliasName = receiver_probe.resolveAliasName;

const reflect_anon = @import("reflect_anon.zig");
const funcAt = reflect_anon.funcAt;

const static_tail = @import("static_tail.zig");
const missTraceWant = static_tail.missTraceWant;

// -------------------------------------------------------------------------
// Overload scoring + method/extension selection.
// -------------------------------------------------------------------------

/// Direct dispatch of a lowering-resolved member extension. Both Kotlin
/// receivers are explicit: `dispatch_receiver` is the declaring class/object
/// instance and `receiver` is the extension receiver.
pub fn invokeMemberExtFuncId(
    self: *VmHost,
    allocator: Allocator,
    dispatch_receiver: *const Value,
    receiver: *const Value,
    fid: FuncId,
    args: []const Value,
) Allocator.Error!EvalResult {
    const all = try prependReceiver(allocator, receiver, args);
    defer if (runtime.freeScratch()) allocator.free(all);
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    if (funcAt(mod, fid) == null) {
        return .{ .err = .{ .Type = "resolved member target is missing" } };
    }
    ir.eval.pushEnclosing(dispatch_receiver);
    defer ir.eval.popEnclosing();
    return try callFuncRec(self, allocator, mod, fid, all);
}

/// Distance from an instance's runtime class to `target` along the
/// supertype graph, or `null` when unreachable.
/// `instanceSubtypeDistance` for a target that may be an erased function
/// name: the lowering names a receiver form `R.(P) -> T` by its value
/// parameters alone (`Function{p}`), while a class extending the same
/// type written `(R, P) -> T` records `Function{p+1}`; both spell one
/// Kotlin type, so the receiver-form name also accepts the wider tag.
pub fn instanceFunctionDistance(self: *VmHost, arg: *const Value, target: []const u8) ?usize {
    if (instanceSubtypeDistance(self, arg, target)) |d| return d;
    const prefix: []const u8 = if (std.mem.startsWith(u8, target, "SuspendFunction"))
        "SuspendFunction"
    else if (std.mem.startsWith(u8, target, "Function"))
        "Function"
    else
        return null;
    const digits = target[prefix.len..];
    if (digits.len == 0) return null;
    const n = std.fmt.parseInt(usize, digits, 10) catch return null;
    var buf: [32]u8 = undefined;
    const wider = std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, n + 1 }) catch return null;
    return instanceSubtypeDistance(self, arg, wider);
}

pub fn instanceSubtypeDistance(self: *VmHost, arg: *const Value, target: []const u8) ?usize {
    const inst = switch (arg.*) {
        .Instance => |i| i,
        else => return null,
    };
    const a = self.allocator;
    const Entry = struct { name: []const u8, depth: usize };
    var queue: std.ArrayList(Entry) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        queue.append(a, .{ .name = cg.get().name, .depth = 0 }) catch return null;
        cg.deinit();
        g.deinit();
    }
    var head: usize = 0;
    // Compare SOURCE simple names on both sides. A nested class lifts to a
    // flat `Outer$Name`, which is what a subclass records as its supertype,
    // while a parameter declared `Outer.Name` lowers its head to the bare
    // `Name` — so a raw simple-name compare never matches the two, and every
    // instance of a lifted nested type failed to prove its own supertype
    // (`Modifier.Node` against a `SuspendingPointerInputModifierNodeImpl`).
    const tn = classDisplayName(target);
    while (head < queue.items.len) : (head += 1) {
        const e = queue.items[head];
        if (seen.contains(e.name)) continue;
        seen.put(e.name, {}) catch {};
        if (std.mem.eql(u8, classDisplayName(e.name), tn)) return e.depth;
        const cg = self.classes.borrow();
        const e_key = mangledClassKeyOf(self, e.name) orelse e.name;
        if (cg.get().get(e.name) orelse cg.get().get(e_key)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, .{ .name = sn, .depth = e.depth + 1 }) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}

// -------------------------------------------------------------------------
// Shared applicability engine — member / extension adapters.
//
// `pickMethodOverload` and `scoreExtCandidates` select through the shared
// `applicable()` engine. These adapters project a runtime value into an
// `ArgShape`, a `Func` into a `SigView`, and wrap the value-dependent
// refinement / subtype / extension-ranking callbacks the engine invokes.
// -------------------------------------------------------------------------

/// `ArgShape` for one runtime value, in the MEMBER scorer's conventions:
/// `lambda_arity` from an `IrClosure` only (never `Function`/`Class`), and
/// `is_lambda` from `isCallable` (the trailing-lambda gate), not the broader
/// `valueIsCallable`.
pub fn shapeOfValueMember(self: *VmHost, v: *const Value) applicability.ArgShape {
    var arity_authoritative = false;
    const arity: ?u8 = switch (v.*) {
        .IrClosure => |c| blk: {
            const info = self.closures.get(@intCast(c.asPtr().id)) orelse break :blk null;
            const up = host_call_func.closureUserParamsChecked(self, info);
            arity_authoritative = up.stripped;
            break :blk std.math.cast(u8, up.n);
        },
        .Instance => blk: {
            const cli = host_call_func.composableLambdaBlockArity(self, v) orelse break :blk null;
            arity_authoritative = cli.authoritative;
            break :blk cli.n;
        },
        else => null,
    };
    return .{
        .runtime_class = overload_match.runtimeHead(v),
        .is_null = v.* == .Null,
        .is_lambda = isCallable(v),
        .lambda_arity = arity,
        .lambda_is_literal = arity_authoritative,
        .func_typed = std.mem.startsWith(u8, v.typeFqn(), "kotlin.Function"),
        .value = @ptrCast(v),
    };
}

/// Per-candidate `SigView` for the shared scorer, read off the `Func`.
pub fn sigViewOfMember(self: *VmHost, f: *const Func, is_ext: bool) applicability.SigView {
    const params = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk host_call_func.boundedParams(mg.get(), f.id, f) orelse f.params;
    };
    return .{
        .params = params,
        .defaults = funcDefaults(self, f),
        .has_body = f.hasBody(),
        .low_priority = f.low_priority,
        .is_member = !is_ext,
        .is_extension = is_ext,
        .fid = f.id,
        .package = f.package,
    };
}

/// `ApplicabilityScope.refine`: wraps `refineByDeclaredArgs`.
pub fn applicRefineCbM(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return overload_match.refineByDeclaredArgs(self, param_ty, v);
}

/// `ApplicabilityScope.identity_conflict`: cross-package class-identity disproof
/// for member overloads (same shared exact-name tier as the global scorer).
pub fn applicIdentityConflictCbM(ctx: *anyopaque, param_ty: *const TypeRef, value: *const anyopaque) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    const r = overload_match.crossPackageIdentityConflict(self, param_ty, v);
    if (r and runtime.envOnce("KLIO_APPLIC_TRACE") != null)
        std.debug.print("[applic-idconf] ty={s} arg={s}\n", .{ param_ty.name, v.typeFqn() });
    return r;
}

pub fn applicExactHeadCbM(ctx: *anyopaque, param_head: []const u8, arg_head: []const u8) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const key = mangledClassKeyOf(self, param_head) orelse return false;
    return std.mem.eql(u8, key, arg_head);
}

/// `ApplicabilityScope.subtype`: the member instance-subtype BFS
/// (`instanceSubtypeDistance`, simple-name matched — unlike the global BFS).
pub fn applicSubtypeCbM(ctx: *anyopaque, value: *const anyopaque, target: []const u8) ?i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const arg: *const Value = @ptrCast(@alignCast(value));
    if (arg.* != .Instance) return null;
    const dist = instanceSubtypeDistance(self, arg, target) orelse {
        if (runtime.envOnce("KLIO_APPLIC_TRACE") != null)
            blk2: {
                const g2 = arg.Instance.borrow();
                defer g2.deinit();
                const cg2 = g2.get().class.borrow();
                defer cg2.deinit();
                std.debug.print("[applic-subtype-miss] target={s} arg_cls={s}\n", .{ target, cg2.get().fqn });
                break :blk2;
            }
        return null;
    };
    return @intCast(@min(dist, @as(usize, std.math.maxInt(i32))));
}

/// `ApplicabilityScope.func_type`: `isFunctionTypeRefResolved`.
pub fn applicFuncTypeCbM(ctx: *anyopaque, ty: *const TypeRef) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    return isFunctionTypeRefResolved(self, ty);
}

/// `ApplicabilityScope.ext_recv_match`: `extReceiverSpecificity`.
pub fn applicExtRecvMatchCb(ctx: *anyopaque, value: *const anyopaque, ty_name: []const u8) i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const v: *const Value = @ptrCast(@alignCast(value));
    return extReceiverSpecificity(self, v, ty_name);
}

/// `ApplicabilityScope.ext_is_subtype_name`: `isSubtypeName`.
pub fn applicExtSubtypeNameCb(ctx: *anyopaque, a: []const u8, b: []const u8) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    return isSubtypeName(self, self.allocator, a, b);
}

/// `ApplicabilityScope.ext_owner_rank`: member-extension enclosing-chain rank.
pub fn applicExtOwnerRankCb(ctx: *anyopaque, fid: FuncId) i32 {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    const owner: []const u8 = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        const mod = mg.get();
        if (!isMemberExt(mod, fid)) return 0;
        break :blk mod.registry.member_ext_owner_class.get(fid) orelse return 0;
    };
    var chain = enclosingChainClassOrder(self, self.allocator) catch return 0;
    defer chain.deinit(self.allocator);
    for (chain.items, 0..) |co, pos| {
        const matches = if (std.mem.findScalar(u8, owner, '.') != null)
            std.mem.eql(u8, co, owner)
        else
            std.mem.eql(u8, simpleName(co), owner);
        if (matches) {
            return @as(i32, @intCast(chain.items.len)) - @as(i32, @intCast(pos));
        }
    }
    return 0;
}

/// Whether the range's own `contains(element)` member takes this argument:
/// the element kind of the range (Char for a Char range, an integral value
/// otherwise). Any other argument (`10L in 1..10`, `"s" in 0..1`) resolves
/// to an extension `contains`, which a user declaration may provide, so the
/// host member yields to the extension tiers.
pub fn rangeContainsArgKindMatches(kind: runtime.RangeKind, arg: *const Value) bool {
    return switch (kind) {
        .Char => arg.* == .Char,
        .Int => arg.* == .Int or arg.* == .Short or arg.* == .Byte,
        .Long => arg.* == .Long or arg.* == .Int or arg.* == .Short or arg.* == .Byte,
        .UInt => arg.* == .UInt or arg.* == .UShort or arg.* == .UByte,
        .ULong => arg.* == .ULong or arg.* == .UInt or arg.* == .UShort or arg.* == .UByte,
    };
}

/// `ApplicabilityScope.ext_known_package`: `stdlib.isKnownPackage`.
pub fn applicKnownPackageCb(pkg: []const u8) bool {
    return stdlib.isKnownPackage(pkg);
}

pub fn appliedMemberScore(pts: i32, exact_arity: bool, low_priority: bool) i32 {
    var s = pts;
    if (exact_arity) s += 5;
    if (low_priority) s -= 1000;
    return s;
}

/// Default-arg thunk slots recorded for `f` (indexed by lowered-param
/// position, including the implicit `this` slot), or `null` when none.
pub fn funcDefaults(self: *VmHost, f: *const Func) ?[]const ?FuncId {
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().func_defaults.get(@intFromEnum(f.id));
}

pub fn runtimeMemberApplicability(
    self: *VmHost,
    allocator: Allocator,
    f: *const Func,
    args: []const Value,
    arg_names: ?[]const ?[]const u8,
    named: bool,
) Allocator.Error!?applicability.Score {
    // [6] not [24]: safety builds 0xAA-fill the whole declared array per
    // entry; >6 args fall to the heap branch below (rare).
    var shapes_buf: [6]applicability.ArgShape = undefined;
    const shapes = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else
        try allocator.alloc(applicability.ArgShape, args.len);
    defer if (args.len > shapes_buf.len) allocator.free(shapes);
    for (args, 0..) |*arg, i| {
        shapes[i] = shapeOfValueMember(self, arg);
        if (named) {
            shapes[i].named = if (arg_names) |names|
                if (i < names.len) names[i] else null
            else
                null;
        }
    }
    const sig = sigViewOfMember(self, f, false);
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .named = named,
        .recv_external = named and f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this"),
        .ctx = @ptrCast(self),
        .refine = applicRefineCbM,
        .subtype = applicSubtypeCbM,
        .func_type = applicFuncTypeCbM,
        .identity_conflict = applicIdentityConflictCbM,
        .type_var = applicTypeVarCbM,
        .exact_head = applicExactHeadCbM,
        .erased_integer_widths = true,
    };
    return applicability.applicable(&sig, shapes, scope);
}

/// Whether the parameter at lowered position `idx` (with the implicit
/// `this` offset already folded in) is satisfiable by a defaulted slot.
pub fn paramHasDefault(defaults: ?[]const ?FuncId, idx: usize) bool {
    const d = defaults orelse return false;
    if (idx >= d.len) return false;
    return d[idx] != null;
}

/// Conservative type-incompatibility check for a single instance arg
/// against a user-class parameter. Returns `true` only when we can
/// prove the argument's class is not the parameter type nor any of its
/// supertypes; primitives, builtins, and generics are never adjudicated
/// here (they are scored elsewhere). A function-typed parameter is
/// definite against a plain data value: kotlinc drops such a candidate
/// (String is no Function subtype), so a member `url(block: (T) -> Unit)`
/// can't pre-empt the same-named `url(urlString: String)` extension.
/// Whether an instance can stand in for a function-typed parameter:
/// it carries a SAM-conversion target, or its supertype closure names a
/// `Function*` type (kotlinc: assignability needs the type relation — a
/// class merely declaring an `invoke` member is not a Function subtype).
/// Whether the instance's class hierarchy names a function type as a
/// supertype (an erased `FunctionN` / `SuspendFunctionN`), i.e. the class
/// was declared `class A : (Int) -> Unit`. This is stricter than
/// `instanceHasInvokeSurface`, which is true for any class merely
/// declaring an `invoke` member (a compose `MovableContent`, a
/// `ComposableLambdaImpl`); only a genuine function-type subtype should be
/// invoked as a bare value in `CallValueOrMember`.
pub fn instanceExtendsFunctionType(self: *VmHost, v: *const Value) bool {
    if (v.* != .Instance) return false;
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    {
        const g = v.Instance.borrow();
        const cg = g.get().class.borrow();
        queue.append(a, cg.get().name) catch {};
        cg.deinit();
        g.deinit();
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const name = queue.items[head];
        if (seen.contains(name)) continue;
        seen.put(name, {}) catch {};
        if (std.mem.startsWith(u8, name, "Function") or std.mem.startsWith(u8, name, "SuspendFunction")) {
            const rest = if (std.mem.startsWith(u8, name, "SuspendFunction")) name["SuspendFunction".len..] else name["Function".len..];
            if (rest.len != 0 and blk: {
                for (rest) |ch| if (ch < '0' or ch > '9') break :blk false;
                break :blk true;
            }) return true;
        }
        const cg = self.classes.borrow();
        if (cg.get().get(name)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

pub fn instanceHasInvokeSurface(self: *VmHost, v: *const Value) bool {
    // A class declaring `operator fun invoke` is function-like whatever its
    // nominal supertypes: a memo-wrapped ComposableLambdaImpl (22 invoke
    // overloads, no Function* supertype in common code) satisfies a
    // function-typed parameter exactly like a lambda. This runs under
    // callers holding module borrows (some exclusive), so it may only read
    // the instance's own class chain — ClassDef method tables. Pack-loaded
    // classes keep their methods in the lowered registry and their
    // ClassDef.methods EMPTY: an empty chain means the member surface is
    // UNKNOWN here, and a disproof needs knowledge — report the invoke
    // surface as possible so the candidate survives to real dispatch.
    {
        const g = v.Instance.borrow();
        defer g.deinit();
        // A pack-loaded ComposableLambdaImpl keeps its invoke overloads in
        // the lowered module, which this fn must NOT borrow (callers hold
        // exclusive module borrows — a consult deadlocks); the wrapper's
        // class identity answers directly.
        {
            const cg0 = g.get().class.borrow();
            defer cg0.deinit();
            if (std.mem.find(u8, cg0.get().fqn, "ComposableLambda") != null) return true;
        }
        var cls: ?ObjRef(runtime.ClassDef) = g.get().class.clone();
        while (cls) |c| {
            const cg = c.borrow();
            for (cg.get().methods) |m| {
                if (std.mem.eql(u8, m.name, "invoke")) {
                    cg.deinit();
                    c.deinit();
                    return true;
                }
            }
            const parent = if (cg.get().parent) |p| p.clone() else null;
            cg.deinit();
            c.deinit();
            cls = parent;
        }
    }
    {
        const g = v.Instance.borrow();
        defer g.deinit();
        if (g.get().get("__sam_target__") != null) return true;
        // A `recv::method` / `::prop` callable reference is a synthetic
        // instance carrying `__bound_name__`; it dispatches through the
        // call_value path, so it satisfies a function-typed parameter.
        if (g.get().get("__bound_name__") != null) return true;
    }
    var start: []const u8 = undefined;
    {
        const g = v.Instance.borrow();
        const cg = g.get().class.borrow();
        start = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, start) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        if (std.mem.startsWith(u8, simpleName(cur), "Function")) return true;
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    return false;
}

/// Definite receiver disproof for the lenient extension pass: an
/// instance whose known hierarchy excludes the declared receiver class
/// (`argDefinitelyNotParamType`), or a class value against a concrete
/// receiver class — a `KClass` is never an instance of `Pipeline`, so
/// `Pipeline.execute` is not a candidate at that receiver (kotlinc drops
/// it outright).
/// The owner simple name of a companion-object type name (`kotlin.Char.Companion`
/// → `Char`), or null when the name does not head a companion.
pub fn companionOwnerName(name: []const u8) ?[]const u8 {
    const suffix = ".Companion";
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const head = name[0 .. name.len - suffix.len];
    if (head.len == 0) return null;
    return simpleName(head);
}

/// A companion-object receiver type (`X.Companion`) is owner-specific: the
/// runtime companion instance's class fqn names its own owner, so a candidate
/// declared on a DIFFERENT owner's companion is inapplicable. Without this
/// every `T.Companion.f()` extension in scope survives the lenient pass and the
/// first-declared one wins (`String.serializer()` binding
/// `Char.Companion.serializer`).
pub fn companionOwnerMismatch(self: *VmHost, param_name: []const u8, receiver: *const Value) bool {
    const want = companionOwnerName(param_name) orelse return false;
    const g = receiver.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    if (companionOwnerName(cg.get().fqn)) |got| return !std.mem.eql(u8, want, got);
    // A NAMED companion (`companion object Named`) carries no `.Companion`
    // fqn segment; the registry maps the owner to its companion class.
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.companion_singletons.get(want)) |cn| {
        if (std.mem.eql(u8, cn, cg.get().name)) return false;
    }
    // The receiver is not `want`'s companion under either naming, so a
    // `want.Companion` receiver type cannot bind it.
    return true;
}

/// Whether the ClassDef `d` (or any supertype / resolved interface of it)
/// is named `want`, walking the instance's REAL class rather than a
/// name-keyed registry that collides across packs.
pub fn classDefIsA(d: *const ClassDef, want: []const u8) bool {
    return classDefIsAImpl(d, want, 0);
}

pub fn classDefIsAImpl(d: *const ClassDef, want: []const u8, depth: u32) bool {
    if (depth > 24) return false;
    if (std.mem.eql(u8, d.name, want) or std.mem.eql(u8, d.fqn, want) or
        std.mem.eql(u8, simpleName(d.fqn), want)) return true;
    for (d.supertype_names) |sn| {
        if (std.mem.eql(u8, sn, want) or std.mem.eql(u8, simpleName(sn), want)) return true;
    }
    for (d.interfaces) |iface| {
        const fg = iface.borrow();
        defer fg.deinit();
        if (classDefIsAImpl(fg.get(), want, depth + 1)) return true;
    }
    return false;
}

pub fn receiverDefinitelyNotParam(self: *VmHost, param_ty: *const TypeRef, receiver: *const Value) bool {
    if (receiver.* == .Instance and companionOwnerMismatch(self, param_ty.name, receiver)) return true;
    // `fun Unit.f()` applies to `Unit` alone. An interpreted instance is never
    // `Unit`, so such an extension must not survive as a lenient candidate for
    // it — `Unit.serializer()` otherwise answered `PlainObject.serializer()`.
    if (receiver.* == .Instance and !param_ty.nullable and
        std.mem.eql(u8, simpleName(param_ty.name), "Unit")) return true;
    if (argDefinitelyNotParamType(self, param_ty, receiver)) return true;
    // A function value implements only the Function* surface (plus
    // Any/type variables): a NOMINAL receiver type it does not satisfy
    // is definite. Without this a sole lenient extension survivor like
    // `Comparable<T>.compareTo` binds a lambda receiver, and its body's
    // member re-dispatch loops back to the same pick forever (two
    // lambdas compared through a pack's same-named member).
    // A `receiver::method` reference is a function value too, even though it
    // is carried as a synthetic Instance: `source::produce` satisfies
    // `(() -> T).asFlow()` and nothing else, so `Iterable<T>.asFlow()` must
    // not survive beside it.
    const callable_like = switch (receiver.*) {
        .IrClosure, .BoundMethod => true,
        .Instance => isBoundReference(receiver),
        else => false,
    };
    if (callable_like) {
        {
            const pn = simpleName(param_ty.name);
            if (param_ty.nullable) return false;
            if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return false;
            if (pn.len <= 2 and allUppercase(pn)) return false;
            // Any function-shaped type name stays a candidate for a
            // callable receiver: `Function*`, suspend forms, and the
            // lowered `<function>` marker (`startCoroutineCancellable`
            // on `(suspend () -> Unit)`).
            if (std.mem.find(u8, pn, "Function") != null) return false;
            if (std.mem.find(u8, pn, "->") != null) return false;
            if (std.mem.startsWith(u8, pn, "suspend")) return false;
            if (std.mem.eql(u8, pn, "<function>")) return false;
            if (receiver.isRuntimeType(pn)) return false;
            // A `fun interface` (SAM) receiver type: a lambda serves it
            // (`emitAll` on a FlowCollector-shaped collector lambda), so
            // it is never definite. A plain interface (`Comparable`) or
            // class is: kotlinc converts lambdas only to fun interfaces.
            // An UNKNOWN name (no registered ClassDef) stays a candidate.
            {
                const cg = self.classes.borrow();
                defer cg.deinit();
                if (cg.get().get(pn)) |def| {
                    const dg = def.borrow();
                    defer dg.deinit();
                    if (dg.get().is_fun_interface) return false;
                } else {
                    return false;
                }
            }
            return true;
        }
    }
    if (receiver.* == .Class) {
        const pn = param_ty.name;
        if (param_ty.nullable) return false;
        // A companion-owner mismatch is definite through the class value too:
        // `Foo.f()` may bind `fun Foo.Companion.f()`, never another owner's.
        if (companionOwnerName(pn)) |want| {
            const g = receiver.Class.borrow();
            defer g.deinit();
            return !std.mem.eql(u8, want, g.get().name) and
                !std.mem.eql(u8, want, simpleName(g.get().fqn));
        }
        if (std.mem.eql(u8, pn, "Any")) return false;
        // A class value is never `Unit`. Without this every `fun Unit.f()`
        // extension in scope stays a lenient survivor for `X.f()`
        // (`Unit.serializer()` answered `Foo.serializer()`).
        if (std.mem.eql(u8, pn, "Unit")) return true;
        if (std.mem.startsWith(u8, pn, "Function")) return true;
        if (pn.len <= 2 and allUppercase(pn)) return false;
        // A class value IS a `KClass` / `KClassifier`. The reflection heads it
        // reports must not be disproven merely because the stdlib registers a
        // ClassDef under that name — that dropped every `KClass<T>.f()`
        // extension (`isInterface`, `serializerOrNull`) from the candidate set.
        if (receiver.isRuntimeType(simpleName(pn))) return false;
        const cg = self.classes.borrow();
        defer cg.deinit();
        return cg.get().get(simpleName(pn)) != null;
    }
    return false;
}

/// Parameter-type names that can never bind a function-typed argument.
/// Conservative: the builtin value types, `String`/`CharSequence`, and the
/// concrete container types — none of which is ever a function type or a
/// typealias to one. This lets a trailing-lambda call drop a same-named
/// collection-typed member (`removeAll(elements: Collection)`) so the
/// predicate extension (`removeAll(predicate: (T) -> Boolean)`) binds.
pub fn isDefinitelyNonFunctionTypeName(pn: []const u8) bool {
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

/// Nominal interfaces klio models a Kotlin array as satisfying (so the stdlib
/// `Array<T>.first()` / iteration extensions bind). An array vs one of these is
/// NOT a definite type mismatch, unlike an array vs an arbitrary user interface.
pub fn isArrayRelatedIface(pn: []const u8) bool {
    const set = [_][]const u8{
        "Iterable",  "MutableIterable", "Collection",   "MutableCollection",
        "Sequence",  "Comparable",      "CharSequence", "Serializable",
        "Cloneable",
    };
    for (set) |s| {
        if (std.mem.eql(u8, pn, s)) return true;
    }
    return false;
}

/// The Kotlin type name of a scalar runtime value's kind, or null for
/// non-scalars. Used to compare a scalar argument against a value class's
/// underlying representation.
pub fn scalarKindName(arg: *const Value) ?[]const u8 {
    return switch (arg.*) {
        .Bool => "Boolean",
        .Char => "Char",
        .Byte => "Byte",
        .Short => "Short",
        .Int => "Int",
        .Long => "Long",
        .Float => "Float",
        .Double => "Double",
        .UByte => "UByte",
        .UShort => "UShort",
        .UInt => "UInt",
        .ULong => "ULong",
        .String => "String",
        else => null,
    };
}

pub fn isScalarKindName(n: []const u8) bool {
    const set = [_][]const u8{
        "Boolean", "Char",  "Byte",   "Short", "Int",   "Long",   "Float",
        "Double",  "UByte", "UShort", "UInt",  "ULong", "String",
    };
    for (set) |s| {
        if (std.mem.eql(u8, n, s)) return true;
    }
    return false;
}

/// The source-level name behind a file-collision mangle (`X$f12` -> `X`).
/// Nested-lift names (`Outer$Name`) keep their shape: the stripped suffix
/// must be `$f` followed by digits only.
pub fn stripFileMangle(n: []const u8) []const u8 {
    const i = std.mem.findScalarLast(u8, n, '$') orelse return n;
    if (i + 2 >= n.len or n[i + 1] != 'f') return n;
    for (n[i + 2 ..]) |c| {
        if (c < '0' or c > '9') return n;
    }
    return n[0..i];
}

/// Whether the class table registers any file-mangled variant of `name`
/// (`name$f<digits>`). A private/internal classifier whose simple name
/// collides across files registers ONLY under its mangled name, so a
/// declared type spelled with the source name still names a known class.
pub fn anyFileMangledVariant(classes: *const ClassTable, name: []const u8) bool {
    var it = classes.keyIterator();
    while (it.next()) |k| {
        const kn = k.*;
        if (kn.len > name.len + 2 and std.mem.startsWith(u8, kn, name) and
            kn[name.len] == '$' and stripFileMangle(kn).len == name.len) return true;
    }
    return false;
}

/// Memo key for `argDefinitelyNotParamType`: the adjudication is a pure
/// function of (param type, arg's runtime TYPE) for scalars, callables,
/// Null, and Instances (whose arm reads only the class and its static
/// hierarchy). Container/tuple/range args adjudicate their CONTENTS, so
/// they stay unmemoized (null key).
pub fn admArgKey(arg: *const Value) ?usize {
    return switch (arg.*) {
        .Instance => |i| @intFromPtr(i.asPtrConst().class.asPtrConst()),
        .List, .Set, .Map, .Array, .Sequence, .Range, .Pair, .Triple, .MapEntry => null,
        else => (@as(usize, @intFromEnum(std.meta.activeTag(arg.*))) << 1) | 1,
    };
}

pub const TlAdmEntry = struct { ty: usize = 0, akey: usize = 0, gen: u32 = 0, verdict: u8 = 0 };
pub threadlocal var tl_adm_cache: [4096]TlAdmEntry = @splat(.{});

/// Per-call front for the type-disproof adjudicator: overload resolution
/// consults it per (candidate param, arg) on every dispatch that walks
/// candidates, and the uncached ladder pays alias/class-registry string
/// probes plus a heap-allocating supertype BFS each time — measured as the
/// dominant string-eql source on recompose-heavy workloads.
pub fn argDefinitelyNotParamType(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) bool {
    const akey = admArgKey(arg) orelse return argDefinitelyNotParamTypeUncached(self, param_ty, arg);
    const ty = @intFromPtr(param_ty);
    const h = (@as(u64, @intCast(ty)) *% 0x9E3779B97F4A7C15) ^ @as(u64, @intCast(akey));
    const e = &tl_adm_cache[@as(usize, @intCast((h ^ (h >> 17)) & (tl_adm_cache.len - 1)))];
    const gen = cacheGen();
    if (e.verdict != 0 and e.ty == ty and e.akey == akey and e.gen == gen) return e.verdict == 2;
    const v = argDefinitelyNotParamTypeUncached(self, param_ty, arg);
    e.* = .{ .ty = ty, .akey = akey, .gen = gen, .verdict = if (v) 2 else 1 };
    return v;
}

pub fn argDefinitelyNotParamTypeUncached(self: *VmHost, param_ty: *const TypeRef, arg: *const Value) bool {
    var pn = param_ty.name;
    // A QUALIFIED function-type head (`kotlin.Function1`) must reach the
    // Function arm below, not the qualified-name early-out: the callable
    // disproof is head-shaped and package-independent.
    if (std.mem.findScalar(u8, pn, '.') != null and
        std.mem.startsWith(u8, simpleName(pn), "Function"))
    {
        pn = simpleName(pn);
    }
    // A qualified reference (`Owner.Pocket`) names a lifted nested/inner
    // class whose registered name the supertype walk cannot relate;
    // decline to adjudicate.
    if (std.mem.findScalar(u8, pn, '.') != null) return false;
    // A typealiased param type also adjudicates under its expansion. But the
    // alias table is keyed by SIMPLE NAME globally, so a file-private
    // `typealias` in one module shadows an unrelated real class of the same
    // name in another (compose foundation's `internal typealias NodeList =
    // MutableIntList` vs kotlinx.coroutines' real `class NodeList`). Adjudicate
    // the arg against BOTH the original name and the expansion — a match on
    // either is not a definite mismatch, so an ambiguous name never refutes a
    // value that satisfies one of its readings.
    const orig = pn;
    pn = resolveAliasName(self, pn);
    if (std.mem.findScalar(u8, pn, '.') != null) return false;

    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return false;
    // A nullable parameter (`TypeInfo?`) accepts `null` — that is never a
    // definite mismatch — but a non-null argument must still match the
    // underlying type, so a `User` does not satisfy `typeInfo: TypeInfo?`
    // (which would otherwise let the engine's `respond(message, typeInfo)`
    // shadow the reified `respond(status, message)` for `respond(Created,
    // user)`). Adjudicate the non-null case against the underlying type below.
    if (param_ty.nullable and arg.* == .Null) return false;
    if (pn.len <= 2 and allUppercase(pn)) return false;
    // A callable argument definitely does not satisfy a primitive/String
    // parameter: `logger.trace { … }` must drop the member `trace(String)`
    // so the inline `Logger.trace(message: () -> String)` extension binds
    // (kotlinc resolves the extension; the member is inapplicable). The same
    // holds for any REGISTERED class that is not a `fun interface`: no SAM
    // conversion exists, so a lambda never satisfies `FlowCollector` — the
    // member `collect(FlowCollector)` stands aside for the extension
    // `collect(action)` exactly as kotlinc binds it. A head naming no
    // registered class (a typealias of a function type) stays non-definite.
    if (isCallable(arg)) {
        if (runtime.envOnce("KLIO_ADM_TRACE") != null) {
            const cg2 = self.classes.borrow();
            defer cg2.deinit();
            std.debug.print("[adm] callable-vs pn={s} orig={s} reg={}\n", .{ pn, orig, cg2.get().get(pn) != null });
        }
        if (isDefinitelyNonFunctionTypeName(pn)) return true;
        if (!std.mem.startsWith(u8, pn, "Function") and
            !std.mem.eql(u8, pn, "Any") and !std.mem.eql(u8, pn, "Unit"))
        {
            const cg = self.classes.borrow();
            defer cg.deinit();
            if (cg.get().get(pn) orelse cg.get().get(orig)) |d| {
                const dg = d.borrow();
                defer dg.deinit();
                if (!dg.get().is_fun_interface) return true;
            }
        }
    }
    if (std.mem.startsWith(u8, pn, "Function")) {
        // Callables and Null stay non-definite; a value kind that PLAINLY
        // carries no invoke surface is definite — a `List` is not a
        // predicate, so `removeAll(listOf(2, 4))` must fall past a
        // subclass's lone `removeAll(predicate)` to the inherited
        // `removeAll(Collection)` (SmallPersistentVector under
        // SnapshotStateList was the live case). Kinds that CAN be invoked
        // without being tagged callable — a `Class` constructor reference
        // fed to a factory param, a bound member — stay non-definite
        // (`FixupList.createAndInsertNode`'s factory broke on the broad
        // form of this arm).
        return switch (arg.*) {
            .String, .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong => true,
            .List, .Map, .Set, .Array, .Range, .Sequence, .Pair, .Triple, .MapEntry => true,
            .Instance => !instanceHasInvokeSurface(self, arg),
            else => false,
        };
    }
    // A Pair/Triple argument adjudicates its components against the declared
    // generic arguments: `appendAll(vararg values: Pair<String, String>)`
    // must decline a `Pair<String, List<String>>` so the sibling
    // `Pair<String, Iterable<String>>` overload binds, exactly as kotlinc
    // picks.
    if (arg.* == .Pair and std.mem.eql(u8, pn, "Pair") and param_ty.args.len == 2) {
        if (argDefinitelyNotParamType(self, &param_ty.args[0], arg.Pair.first.asPtr())) return true;
        if (argDefinitelyNotParamType(self, &param_ty.args[1], arg.Pair.second.asPtr())) return true;
        return false;
    }
    if (arg.* == .Triple and std.mem.eql(u8, pn, "Triple") and param_ty.args.len == 3) {
        if (argDefinitelyNotParamType(self, &param_ty.args[0], arg.Triple.first.asPtr())) return true;
        if (argDefinitelyNotParamType(self, &param_ty.args[1], arg.Triple.second.asPtr())) return true;
        if (argDefinitelyNotParamType(self, &param_ty.args[2], arg.Triple.third.asPtr())) return true;
        return false;
    }
    // A List argument adjudicates its RANGE content against a concrete
    // declared element range type: Kotlin generics are invariant, so a
    // List of LongRanges never binds `List<IntRange>` — RangesTest's
    // private `assertEquals(List<IntRange>, List<LongRange>)` delegates
    // to kotlin.test's on its mapped args instead of recursing into
    // itself. Progressions and non-range elements stay non-definite.
    if (arg.* == .List and param_ty.args.len == 1 and
        (std.mem.eql(u8, pn, "List") or std.mem.eql(u8, pn, "MutableList") or
            std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "Iterable")))
    {
        const want: ?runtime.RangeKind = blk: {
            const en = std.mem.trimEnd(u8, param_ty.args[0].name, "?");
            if (std.mem.eql(u8, en, "IntRange")) break :blk .Int;
            if (std.mem.eql(u8, en, "LongRange")) break :blk .Long;
            if (std.mem.eql(u8, en, "CharRange")) break :blk .Char;
            break :blk null;
        };
        if (want) |wk| {
            const g = arg.List.items.borrow();
            defer g.deinit();
            for (g.get().items) |*e| {
                if (e.* != .Range) break;
                if (e.Range.progression) continue;
                if (e.Range.kind != wk) return true;
            }
        }
    }
    // A container/tuple value never satisfies a scalar or String parameter
    // head (an `Array` head stays out: vararg packing hands pre-packed
    // arrays through here).
    if (overload_match.builtinParamKind(pn)) |pk| {
        if (pk != .array) switch (arg.*) {
            .List, .Map, .Set, .Sequence, .Pair, .Triple, .MapEntry => return true,
            else => {},
        };
    }
    // Builtin value-kind disproof: a String argument can never bind an
    // Int parameter (kotlinc does not consider the candidate at all, so
    // the receiver walk must fall through to an outer receiver instead
    // of executing it). Same-kind pairs stay non-definite — a lowered
    // literal may carry a narrower tag than the declared type (`f(5)`
    // binding `f(n: Long)`).
    if (builtinKindMismatch(pn, arg)) return true;
    // A range/progression argument (`0..3`) is definitely not a scalar or array
    // builtin parameter (Int/Long/String/Array/…). Without this, a class that
    // overrides one overload — `get(Int, Int)` — of a method whose other
    // overloads are inherited interface defaults — `get(IntRange, IntRange)` —
    // captures a range-indexed call: the lone own candidate matches on arity, so
    // the hierarchy walk never reaches the inherited range overload. Refuting the
    // scalar param lets the walk fall through to it.
    if (arg.* == .Range and overload_match.builtinParamKind(pn) != null) return true;
    // Builtin container/range-family parameter heads: a scalar/String/
    // Bool/Char argument definitely does not satisfy them (a String is
    // never a `List<IntRange>`), and a container argument whose element
    // knowledge provably contradicts the declared generic arguments is
    // definite too (`List<LongRange>` offered to `List<IntRange>`). A
    // packed `Array` stays non-definite through `valueDefinitelyNot`
    // (pre-packed varargs), as does a wrong-kind range (already decided
    // above for scalar heads, and by the element walk here).
    const container_or_range_head = overload_match.isContainerOrRangeHead(pn);
    if (container_or_range_head) {
        switch (arg.*) {
            .String, .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong => return true,
            .List, .Set, .Map, .Range => return overload_match.valueDefinitelyNot(self, param_ty, arg),
            // An Array satisfies no non-array container head (an
            // `Array<Pair>` is never a `Map`, so `putAll(pairs)` inside the
            // stdlib `plusAssign` drops the builder's member `putAll(Map)`
            // and the `Array<out Pair>` extension binds). The array-modeled
            // interfaces (`Iterable`/`Collection`/...) and array-named
            // params stay non-definite, same as the nominal arm below.
            .Array => return std.mem.find(u8, pn, "Array") == null and !isArrayRelatedIface(pn),
            // An Instance falls through to the hierarchy walk below: a
            // user class that never reaches the container head in its
            // supertype closure is definite (a `RangesSpecifier` is not a
            // `List<IntRange>`), while an implementing class stays a
            // candidate.
            .Instance => {},
            else => return false,
        }
    }
    // Only adjudicate when the parameter names a known user class, or a
    // builtin container/range head an Instance was offered to (above).
    if (!container_or_range_head) {
        const cg = self.classes.borrow();
        defer cg.deinit();
        if (cg.get().get(pn) == null and cg.get().get(orig) == null and
            !anyFileMangledVariant(cg.get(), pn)) return false;
    }
    const inst = switch (arg.*) {
        .Instance => |i| i,
        // A Kotlin array satisfies no NOMINAL user/pack interface, so an
        // `Array`/`XxxArray` argument offered such a parameter is a definite
        // mismatch — decline the lone member `Buffer.readTo(RawSink, Long)` so
        // the extension `Source.readTo(ByteArray, startIndex, endIndex)` binds.
        // EXCEPT the collection interfaces klio DOES model arrays against
        // (`Iterable`/`Collection`/`Sequence`, which back `Array.first()` and
        // friends) and any array-named param — those stay non-definite.
        .Array => return std.mem.find(u8, pn, "Array") == null and !isArrayRelatedIface(pn),
        // A SCALAR against a known user class: definite — except a VALUE
        // class whose underlying representation has the SAME kind, since
        // value-class instances circulate unboxed (a Long could be an `Sz`
        // over Long, but an Int could not). Without the definite arm, a
        // private `Sz.compareTo` member-extension shadows the Int
        // intrinsic inside its OWN body and the dispatch loops.
        .Bool, .Char, .Byte, .Short, .Int, .Long, .Float, .Double, .UByte, .UShort, .UInt, .ULong, .String => {
            // The scalar may satisfy the param NOMINALLY (a String is a
            // CharSequence/Comparable, an Int is a Number): non-definite.
            if (arg.isRuntimeType(pn)) return false;
            // A param naming a DIFFERENT scalar kind stays non-definite
            // too: kotlinc widens integer literals at the call site
            // (`fromEpochMilliseconds(0)` binds the Long param), which
            // the runtime tag cannot see.
            if (isScalarKindName(pn)) return false;
            const cg = self.classes.borrow();
            defer cg.deinit();
            const def = cg.get().get(pn) orelse cg.get().get(orig) orelse return false;
            var dg = def.borrow();
            if (!dg.get().is_value) {
                dg.deinit();
                return true;
            }
            // Chase the value class's underlying declared type (through
            // nested value classes) to a scalar kind name; an unknown or
            // generic underlying stays a candidate.
            var hops: u8 = 0;
            while (hops < 4) : (hops += 1) {
                const params = dg.get().primary_params;
                if (params.len == 0) {
                    dg.deinit();
                    return false;
                }
                const dt_raw = params[0].declared_type orelse {
                    dg.deinit();
                    return false;
                };
                const dt = std.mem.trimEnd(u8, simpleName(dt_raw), "?");
                dg.deinit();
                if (scalarKindName(arg)) |kn| {
                    if (isScalarKindName(dt)) return !std.mem.eql(u8, dt, kn);
                }
                const inner = cg.get().get(dt) orelse return false;
                dg = inner.borrow();
                if (!dg.get().is_value) {
                    dg.deinit();
                    return false;
                }
            }
            dg.deinit();
            return false;
        },
        else => return false,
    };
    var start: []const u8 = undefined;
    var start_fqn: []const u8 = "";
    {
        const g = inst.borrow();
        const cg = g.get().class.borrow();
        start = cg.get().name;
        start_fqn = cg.get().fqn;
        // The arg's own class must be known so its supertype closure is
        // complete; otherwise we cannot be definite.
        const known = blk: {
            const ccg = self.classes.borrow();
            defer ccg.deinit();
            break :blk ccg.get().get(start) != null;
        };
        cg.deinit();
        g.deinit();
        if (!known) return false;
    }
    // Positive proof from the instance's OWN ClassDef, which carries the
    // real supertype names and resolved interface handles. This is immune
    // to the simple-name registry collision that defeats the name-keyed
    // `class_super_names` lookup below (a receiver kotlinx.io.Buffer vs an
    // unrelated okio Buffer both key "Buffer"): a Buffer really IS a Sink.
    {
        const g = inst.borrow();
        const cd = g.get().class.clone();
        g.deinit();
        defer cd.deinit();
        const dg = cd.borrow();
        const isa = classDefIsA(dg.get(), pn) or classDefIsA(dg.get(), orig);
        dg.deinit();
        if (isa) return false;
    }
    // The lowering-recorded transitive chain includes interface links the
    // runtime classes map never registers (interfaces are not instantiated),
    // so it decides cases the BFS below would silently truncate: a companion
    // implementing Plugin through the BaseApplicationPlugin interface IS-A
    // Plugin.
    {
        const mg = self.module.borrow();
        defer mg.deinit();
        // Prefer the fqn-keyed chain: a simple name that collides across
        // packs (a receiver kotlinx.io.Buffer vs an unrelated okio Buffer)
        // would otherwise read the wrong class's supers and miss Sink.
        const chain_by_fqn = if (start_fqn.len != 0) mg.get().registry.class_super_names.get(start_fqn) else null;
        if (chain_by_fqn orelse mg.get().registry.class_super_names.get(start)) |chain|
        {
            const tailMatch = struct {
                fn m(cur: []const u8, want: []const u8) bool {
                    if (std.mem.eql(u8, cur, want)) return true;
                    if (std.mem.eql(u8, stripFileMangle(cur), want)) return true;
                    return cur.len > want.len and cur[cur.len - want.len - 1] == '$' and
                        std.mem.endsWith(u8, cur, want);
                }
            }.m;
            // Positive proof only: a chain may itself truncate at a pack
            // boundary, so its silence never upgrades to definite mismatch.
            if (tailMatch(start, pn) or tailMatch(start, orig)) return false;
            for (chain) |sup| {
                if (tailMatch(sup, pn) or tailMatch(sup, orig)) return false;
            }
        }
    }
    const a = self.allocator;
    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(a);
    var seen: std.StringHashMap(void) = .init(a);
    defer seen.deinit();
    queue.append(a, start) catch return false;
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        // arg IS-A param type (under either reading of an aliased name). A
        // chain entry may carry a file-collision mangle (`X$f12`) the
        // declared type's source spelling does not — compare its source
        // name too.
        if (std.mem.eql(u8, cur, pn) or std.mem.eql(u8, cur, orig)) return false;
        const cur_src = stripFileMangle(cur);
        if (cur_src.ptr != cur.ptr and
            (std.mem.eql(u8, cur_src, pn) or std.mem.eql(u8, cur_src, orig))) return false;
        // A lifted nested/inner class is registered under `Outer$Name`;
        // a type reference written `Outer.Name` collapses to `Name`, so
        // match the mangled tail too.
        if ((cur.len > pn.len and cur[cur.len - pn.len - 1] == '$' and
            std.mem.endsWith(u8, cur, pn)) or
            (cur.len > orig.len and cur[cur.len - orig.len - 1] == '$' and
                std.mem.endsWith(u8, cur, orig))) return false;
        if (seen.contains(cur)) continue;
        seen.put(cur, {}) catch {};
        const cg = self.classes.borrow();
        if (cg.get().get(cur)) |d| {
            const dg = d.borrow();
            for (dg.get().supertype_names) |sn| queue.append(a, sn) catch {};
            dg.deinit();
        }
        cg.deinit();
    }
    if (runtime.envOnce("KLIO_ADM_TRACE") != null) {
        std.debug.print("[adm] definite-mismatch pn={s} orig={s} start={s} walked={d}\n", .{ pn, orig, start, queue.items.len });
    }
    return true;
}

/// Pick the best-scoring method overload from `candidates` for `args`.
/// Each candidate's slot 0 is the implicit `this` receiver, so value
/// arguments score against params 1..n.
/// Whether the runtime class chain of an Instance value declares an
/// `invoke` member, answered from an ALREADY-BORROWED module's registry
/// (pack classes keep their methods there; their ClassDef tables stay
/// empty). Callers without a live borrow pass null and keep the
/// conservative disproof.
pub fn classChainHasInvokeIn(mod: *const Module, v: *const Value) bool {
    if (v.* != .Instance) return false;
    const cls_name: []const u8 = blk: {
        const g = v.Instance.borrow();
        defer g.deinit();
        const cg = g.get().class.borrow();
        defer cg.deinit();
        break :blk cg.get().name;
    };
    const reg = &mod.registry;
    var cur: ?[]const u8 = cls_name;
    var hops: usize = 0;
    while (cur) |cn| : (hops += 1) {
        if (hops > 32) break;
        if (reg.hierarchy_methods.get(cn)) |methods| {
            if (methods.contains("invoke")) return true;
        }
        const chain = reg.class_super_names.get(cn) orelse break;
        if (chain.len == 0) break;
        var sn = chain[0];
        if (std.mem.findScalarLast(u8, sn, '.')) |i| sn = sn[i + 1 ..];
        cur = sn;
    }
    return false;
}

/// Whether the call's ARG COUNT leaves exactly one of the collected
/// same-name candidates able to bind: every other candidate has a plain
/// (no-vararg) parameter list whose arity can never accept `n_args`. The
/// arg count is folded into every method-cache key, so a pick forced this
/// way is a pure function of the RELAXED key too — the single-candidate
/// cacheability gate widens to it (`addAll(Collection)` beside
/// `addAll(index, Collection)` re-walked on every call because the
/// name-level candidate count read as ambiguous). A candidate with
/// defaults or a vararg counts as viable at any arity (conservative), and
/// a pass-threaded composable pair bails outright — its effective arity
/// consults the ambient composer, which no key folds.
pub fn pickArityForced(self: *VmHost, candidates: []const Func, n_args: usize) bool {
    var viable: usize = 0;
    for (candidates) |*f| {
        const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        const effective = f.params[skip..];
        if (effective.len >= 2 and
            std.mem.eql(u8, effective[effective.len - 1].name, "$changed") and
            std.mem.eql(u8, effective[effective.len - 2].name, "$composer")) return false;
        var has_vararg = false;
        for (effective) |*p| {
            if (p.is_vararg) has_vararg = true;
        }
        const viable_c = has_vararg or effective.len == n_args or
            (effective.len > n_args and funcDefaults(self, f) != null);
        if (viable_c) {
            viable += 1;
            if (viable > 1) return false;
        }
    }
    return viable == 1;
}

/// Whether every argument's shape is fully discriminated by the RELAXED
/// signature fold at the level the applicability tests consult: value
/// tags, Instance class identities, closure bodies, primitive array
/// kinds, and container KINDS (the tests are nominal/kind-level — they
/// never inspect elements). Object arrays and every other value shape
/// stay out: the fold cannot tell them apart as finely as a test might.
pub fn argsRelaxedAdjudicable(args: []const Value) bool {
    for (args) |*a| {
        switch (a.*) {
            .Int, .Long, .Double, .Float, .Short, .Byte, .Char, .Bool, .UInt, .ULong, .UShort, .UByte, .Instance, .String, .Unit, .IrClosure, .Null, .Result, .List, .Set, .Map => {},
            .Array => |arr| {
                if (arr.primKind() == null) return false;
            },
            else => return false,
        }
    }
    return true;
}

pub fn pickMethodOverload(self: *VmHost, mod_opt: ?*const Module, candidates: []const Func, args_in: []const Value) ?Func {
    if (candidates.len == 0) return null;
    const args = args_in;
    if (candidates.len == 1) {
        // Even a lone same-named member must be *applicable*. By arity:
        // when fewer args are supplied than it declares and an unsupplied
        // parameter is neither defaulted nor a vararg, it can't bind
        // (dispatch would pad the slot with Unit). Decline so an
        // applicable extension overload wins — e.g. `buffer.readTo(bytes)`
        // falls through the member `Buffer.readTo(RawSink, byteCount: Long)`
        // to the extension `Source.readTo(ByteArray, startIndex = 0,
        // endIndex = size)`.
        const f = candidates[0];
        const skip: usize = if (f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this")) 1 else 0;
        var effective = f.params[skip..];
        var eff_args = args_in;
        // A pass-threaded composable MEMBER carries a trailing ($composer,
        // $changed) pair the call site appended positionally
        // (`consumer.Varargs(0, 1, 2, 3, $composer, $changed)` with
        // `Varargs(vararg ints, $composer, $changed)`): judge the USER shape
        // pair-trimmed — the mid-vararg check otherwise refuses on the
        // undefaulted pair params. Only when the tail VALUES look like the
        // pair (a Composer instance + the changed Int).
        if (effective.len >= 2 and
            std.mem.eql(u8, effective[effective.len - 1].name, "$changed") and
            std.mem.eql(u8, effective[effective.len - 2].name, "$composer"))
        {
            if (eff_args.len >= 2 and eff_args[eff_args.len - 1] == .Int and
                eff_args[eff_args.len - 2] == .Instance)
            {
                effective = effective[0 .. effective.len - 2];
                eff_args = eff_args[0 .. eff_args.len - 2];
            } else if (compose.currentComposer() != null) {
                // Pairless call in composition: the dispatch completes the
                // pair from the ambient composer; judge the user shape.
                effective = effective[0 .. effective.len - 2];
            }
        }
        // Non-final vararg (a vararg before trailing defaulted / named-only
        // params): the prefix binds positionally, the vararg consumes the
        // remaining positional eff_args, and the post-vararg params take their
        // defaults. The naive eff_args[i]-vs-effective[i] pairing below would
        // wrongly type-check a vararg-bound arg against a post-vararg param
        // (e.g. `report("A", 1, 2)` checking `2` against `footer: String`).
        var nf_vararg: ?usize = null;
        for (effective, 0..) |*p, k| {
            if (p.is_vararg) {
                if (k + 1 < effective.len) nf_vararg = k;
                break;
            }
        }
        if (nf_vararg) |vp| {
            const defaults = funcDefaults(self, &f);
            // Prefix params not supplied positionally must be defaulted.
            if (eff_args.len < vp) {
                var k: usize = eff_args.len;
                while (k < vp) : (k += 1) {
                    if (!paramHasDefault(defaults, skip + k)) return null;
                }
            }
            // Post-vararg params can't be reached positionally → must default.
            var k: usize = vp + 1;
            while (k < effective.len) : (k += 1) {
                if (!paramHasDefault(defaults, skip + k)) return null;
            }
            // Prefix eff_args against prefix params; the rest against the vararg
            // element type. A param typed as an in-scope type variable is
            // never adjudicated nominally.
            var i: usize = 0;
            while (i < eff_args.len and i < vp) : (i += 1) {
                if (argDefinitelyNotParamType(self, &effective[i].ty, &eff_args[i]) and
                    !paramTypeIsTypeVar(self, &f, &effective[i].ty)) return null;
            }
            var j: usize = vp;
            while (j < eff_args.len) : (j += 1) {
                if (argDefinitelyNotParamType(self, &effective[vp].ty, &eff_args[j]) and
                    !paramTypeIsTypeVar(self, &f, &effective[vp].ty)) return null;
            }
            return f;
        }
        // Over-supply with no vararg tail can't bind: decline so an
        // applicable top-level/extension overload wins — e.g. the stdlib
        // `buildString { … }` inside an extension on a class that declares
        // its own zero-arg `buildString()` member (`URLBuilder.authority`).
        if (eff_args.len > effective.len and
            (effective.len == 0 or !effective[effective.len - 1].is_vararg))
        {
            if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=oversupply eff_args={d} params={d}\n", .{ f.name, eff_args.len, effective.len });
            return null;
        }
        if (eff_args.len < effective.len) {
            const defaults = funcDefaults(self, &f);
            // Trailing-lambda rule: a final callable arg binds the LAST
            // parameter when that parameter is function-typed; only the GAP
            // parameters between it and the lead positional eff_args need
            // defaults. `observe(readObserver) { block }` on
            // `(readObserver = null, writeObserver = null, block)` is
            // applicable -- block is filled by the lambda, writeObserver by
            // its default.
            const trailing_bind = eff_args.len > 0 and
                isFunctionTypeRef(&effective[effective.len - 1].ty) and
                isCallable(&eff_args[eff_args.len - 1]);
            const first_unfilled = if (trailing_bind) eff_args.len - 1 else eff_args.len;
            const last_checked = if (trailing_bind) effective.len - 1 else effective.len;
            var k: usize = first_unfilled;
            while (k < last_checked) : (k += 1) {
                if (!(effective[k].is_vararg or paramHasDefault(defaults, skip + k))) {
                    if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=undersupply param#{d}\n", .{ f.name, k });
                    return null;
                }
            }
        }
        // By type: a definite argument-type mismatch must fall through so
        // the hierarchy walk continues to the real target. A param typed as
        // an in-scope type variable (the function's own, or the owning
        // class's) is never adjudicated nominally. Under the trailing-lambda
        // rule (undersupplied call whose final callable arg binds the LAST
        // function-typed param), the final arg adjudicates against that last
        // param, not the positional slot the defaulted gap left behind —
        // `build { … }` on `build(flag: Boolean = false, builder: () -> T)`
        // must judge the lambda against `builder`, not `flag`.
        const tail_lambda_bind = eff_args.len > 0 and eff_args.len < effective.len and
            isFunctionTypeRef(&effective[effective.len - 1].ty) and
            isCallable(&eff_args[eff_args.len - 1]);
        var i: usize = 0;
        while (i < eff_args.len and i < effective.len) : (i += 1) {
            const pi = if (tail_lambda_bind and i == eff_args.len - 1) effective.len - 1 else i;
            // A LONE member whose function-typed parameter meets an Instance
            // argument whose class chain declares `invoke` stays applicable:
            // a memo-wrapped ComposableLambdaImpl keeps its invoke overloads
            // in the pack registry, which the borrow-free disproof cannot
            // see, so `setContent(content)` was dropped on its only
            // candidate. Answered from the caller's live module borrow; an
            // invoke-less instance (a JobNode against a CompletionHandler
            // parameter) still declines so the extension wins.
            if (eff_args[i] == .Instance and std.mem.startsWith(u8, effective[pi].ty.name, "Function")) {
                if (mod_opt) |m| {
                    if (classChainHasInvokeIn(m, &eff_args[i])) continue;
                }
            }
            if (argDefinitelyNotParamType(self, &effective[pi].ty, &eff_args[i]) and
                !paramTypeIsTypeVar(self, &f, &effective[pi].ty))
            {
                if (missTraceWant(f.name)) std.debug.print("[pmo] `{s}` decline=arg-type param#{d} ty={s} arg={s}\n", .{ f.name, pi, effective[pi].ty.name, @tagName(std.meta.activeTag(eff_args[i])) });
                return null;
            }
        }
        return f;
    }
    // [6] not [24]: safety builds 0xAA-fill the whole declared array per
    // entry; >6 args fall to the heap branch below (rare).
    var shapes_buf: [6]applicability.ArgShape = undefined;
    var shapes_heap: ?[]applicability.ArgShape = null;
    defer if (shapes_heap) |h| self.allocator.free(h);
    const shapes: []applicability.ArgShape = if (args.len <= shapes_buf.len)
        shapes_buf[0..args.len]
    else blk: {
        const h = self.allocator.alloc(applicability.ArgShape, args.len) catch return null;
        shapes_heap = h;
        break :blk h;
    };
    for (args, 0..) |*a, i| shapes[i] = shapeOfValueMember(self, a);
    if (candidates.len > 0 and missTraceWant(candidates[0].name)) {
        for (shapes, 0..) |sh, i| {
            var cn: []const u8 = "-";
            if (args[i] == .IrClosure) {
                if (self.closures.get(@intCast(args[i].IrClosure.asPtr().id))) |info| {
                    { const mg2 = self.module.borrow(); defer mg2.deinit(); if (funcAt(mg2.get(), info.body_func)) |cf| cn = cf.fqn; }
                }
            }
            std.debug.print("[pmo-shape] #{d} tag={s} rc={s} lambda={} arity={?d} functyped={} fqn={s} closure={s}\n", .{ i, @tagName(std.meta.activeTag(args[i])), sh.runtime_class orelse "-", sh.is_lambda, sh.lambda_arity, sh.func_typed, args[i].typeFqn(), cn });
        }
    }
    const scope = applicability.ApplicabilityScope{
        .member = true,
        .ctx = @ptrCast(self),
        .refine = applicRefineCbM,
        .subtype = applicSubtypeCbM,
        .func_type = applicFuncTypeCbM,
        .identity_conflict = applicIdentityConflictCbM,
        .type_var = applicTypeVarCbM,
        .exact_head = applicExactHeadCbM,
        .erased_integer_widths = true,
    };

    var best: ?Func = null;
    var best_score: i32 = std.math.minInt(i32);
    // Track candidates that scored equal to the current best, for the
    // overload-uniqueness invariant (KLIO_TRACE_INVARIANTS). Only populated
    // when the gate is on; otherwise stays empty and costs nothing.
    const check_inv = trace.invariantsEnabled();
    var tied: std.ArrayList(Func) = .empty;
    defer tied.deinit(self.allocator);
    for (candidates) |f| {
        var sig = sigViewOfMember(self, &f, false);
        const applic = applicability.applicable(&sig, shapes, scope) orelse {
            if (missTraceWant(f.name)) {
                std.debug.print("[pmo-multi] `{s}`#{d} inapplicable params:", .{ f.name, f.id.int() });
                for (f.params) |p| std.debug.print(" {s}:{s}", .{ p.name, p.ty.name });
                std.debug.print("\n", .{});
            }
            continue;
        };
        // The `+5` exact-arity bonus and `-1000` low-priority penalty are the
        // member caller's tiebreaks, applied from the returned `Score`.
        const score = appliedMemberScore(applic.points, applic.exact_arity, applic.low_priority);
        if (missTraceWant(f.name)) {
            std.debug.print("[pmo-multi] `{s}`#{d} score={d} params:", .{ f.name, f.id.int(), score });
            for (f.params) |p| std.debug.print(" {s}:{s}", .{ p.name, p.ty.name });
            std.debug.print("\n", .{});
        }
        if (check_inv and score == best_score) tied.append(self.allocator, f) catch {};
        if (score > best_score) {
            best_score = score;
            best = f;
            if (check_inv) {
                tied.clearRetainingCapacity();
                tied.append(self.allocator, f) catch {};
            }
        }
    }
    if (check_inv) {
        if (best) |w| {
            const name: []const u8 = if (candidates.len > 0) candidates[0].name else "";
            checkOverloadUnique(name, &w, tied.items);
            checkFuncInRange(self, "pickMethodOverload", w.id);
        }
    }
    return best;
}
