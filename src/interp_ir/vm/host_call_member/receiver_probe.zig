//! Receiver-shape probes: the pure `Value`/`Module` helpers, the declared-receiver
//! specificity rules, and the class-head applicability checks dispatch consults.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const applicability = @import("applicability");
const vmhost = @import("../vmhost.zig");
const host_classes = @import("../host_classes.zig");
const VmHost = vmhost.VmHost;
const overload_match = @import("../overload_match.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const Module = ir.Module;
const Func = ir.Func;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;

const applicability_probe = @import("applicability_probe.zig");
const argDefinitelyNotParamType = applicability_probe.argDefinitelyNotParamType;
const funcDefaults = applicability_probe.funcDefaults;
const instanceFunctionDistance = applicability_probe.instanceFunctionDistance;
const paramHasDefault = applicability_probe.paramHasDefault;
const stripFileMangle = applicability_probe.stripFileMangle;

const hcm = @import("../host_call_member.zig");
const simpleName = hcm.simpleName;

const member_ext_visibility = @import("member_ext_visibility.zig");
const collectClassClosure = member_ext_visibility.collectClassClosure;

const member_presence = @import("member_presence.zig");
const enclosingThisChain = member_presence.enclosingThisChain;

const reflect_anon = @import("reflect_anon.zig");
const funcAt = reflect_anon.funcAt;
const padArgsWithDefaultsFor = reflect_anon.padArgsWithDefaultsFor;

const static_tail = @import("static_tail.zig");
const missTraceWant = static_tail.missTraceWant;

const virtual_tail = @import("virtual_tail.zig");
const invokeMethodFuncId = virtual_tail.invokeMethodFuncId;

pub fn isCallable(v: *const Value) bool {
    return switch (v.*) {
        .IrClosure, .Intrinsic, .BoundMethod => true,
        else => false,
    };
}

pub fn isFunctionTypeRef(ty: *const TypeRef) bool {
    return std.mem.startsWith(u8, simpleName(ty.name), "Function") or
        std.mem.find(u8, ty.name, "->") != null;
}

/// `ty`'s name with `typealias` indirection resolved, bounded to a few hops.
pub fn resolveAliasName(self: *VmHost, name: []const u8) []const u8 {
    var cur = name;
    var hops: usize = 0;
    while (hops < 4) : (hops += 1) {
        const next = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(simpleName(cur));
        } orelse return cur;
        if (std.mem.eql(u8, next, cur)) return cur;
        cur = next;
    }
    return cur;
}

pub fn isFunctionTypeRefResolved(self: *VmHost, ty: *const TypeRef) bool {
    if (isFunctionTypeRef(ty)) return true;
    const resolved = resolveAliasName(self, ty.name);
    return std.mem.startsWith(u8, simpleName(resolved), "Function") or
        std.mem.find(u8, resolved, "->") != null;
}

/// Pack trailing positional args into a single `Value::Array` when the
/// target's last param is `vararg`. `args` is consumed and freed.
pub fn packVarargArgs(self: *VmHost, allocator: Allocator, func: *const Func, args: []Value) Allocator.Error![]Value {
    _ = self;
    if (func.params.len == 0) return args;
    const last = func.params[func.params.len - 1];
    if (!last.is_vararg) return args;
    const fixed = func.params.len - 1;
    if (args.len == func.params.len and args[args.len - 1] == .Array) return args;
    var out = try allocator.alloc(Value, func.params.len);
    var i: usize = 0;
    while (i < fixed and i < args.len) : (i += 1) out[i] = args[i];
    const rest_len = if (args.len > fixed) args.len - fixed else 0;
    var rest = try allocator.alloc(Value, rest_len);
    var j: usize = 0;
    while (fixed + j < args.len) : (j += 1) rest[j] = args[fixed + j];
    var rest_list: std.ArrayList(Value) = .empty;
    try rest_list.appendSlice(allocator, rest[0..rest_len]);
    allocator.free(rest);
    out[fixed] = runtime.ArrayData.fromBoxedList(try ObjRef(std.ArrayList(Value)).init(allocator, rest_list));
    allocator.free(args);
    return out[0 .. fixed + 1];
}

pub fn memberIsProperty(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    var start: ObjRef(ClassDef) = undefined;
    switch (receiver.*) {
        .Instance => |inst| {
            const g = inst.borrow();
            defer g.deinit();
            if (g.get().get(name) != null) return true;
            start = g.get().class.clone();
        },
        .Class => |cls| start = cls.clone(),
        else => return false,
    }
    defer start.deinit();
    const a = self.allocator;
    var stack: std.ArrayList(ObjRef(ClassDef)) = .empty;
    defer {
        for (stack.items) |s| s.deinit();
        stack.deinit(a);
    }
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(a);
    stack.append(a, start.clone()) catch return false;
    while (stack.pop()) |c| {
        defer c.deinit();
        const cg = c.borrow();
        const cd = cg.get();
        var skip = false;
        for (seen.items) |s| {
            if (std.mem.eql(u8, s, cd.name)) skip = true;
        }
        if (skip) {
            cg.deinit();
            continue;
        }
        seen.append(a, cd.name) catch {};
        for (cd.primary_params) |p| {
            if (p.property != null and std.mem.eql(u8, p.name, name)) {
                cg.deinit();
                return true;
            }
        }
        for (cd.body_properties) |p| {
            if (std.mem.eql(u8, p.name, name)) {
                cg.deinit();
                return true;
            }
        }
        if (cd.parent) |p| stack.append(a, p.clone()) catch {};
        const classes_g = self.classes.borrow();
        for (cd.supertype_names) |sn| {
            if (classes_g.get().get(sn)) |sc| stack.append(a, sc.clone()) catch {};
        }
        classes_g.deinit();
        cg.deinit();
    }
    return false;
}

/// Permissive receiver/param-type compatibility for extension overload pickers.
pub fn receiverCompatibleWithParam(receiver: *const Value, param_ty: *const TypeRef) bool {
    if (receiver.* == .Instance) return true;
    const pn = simpleName(param_ty.name);
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Any?") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) return true;
    if (pn.len <= 2 and pn.len > 0 and allUppercase(pn)) return true;
    return receiver.isRuntimeType(pn);
}

pub fn allUppercase(s: []const u8) bool {
    for (s) |c| {
        if (!(std.ascii.isUpper(c) or std.ascii.isDigit(c))) return false;
    }
    return true;
}

pub const builtinKindMismatch = overload_match.builtinKindMismatch;

/// Default-arg thunk slots for `method` declared on a supertype of the receiver.
pub fn inheritedMemberDefaults(self: *VmHost, allocator: Allocator, supertypes: []const []const u8, method: []const u8) Allocator.Error!?[]const ?FuncId {
    const mg = self.module.borrow();
    defer mg.deinit();
    const amd = &mg.get().registry.abstract_member_defaults;

    var queue: std.ArrayList([]const u8) = .empty;
    defer queue.deinit(allocator);
    var seen: std.StringHashMap(void) = .init(allocator);
    defer seen.deinit();
    for (supertypes) |s| try queue.append(allocator, s);

    while (queue.pop()) |cn| {
        if (seen.contains(cn)) continue;
        try seen.put(cn, {});
        const simple = simpleName(cn);
        if (amd.get(.{ .a = cn, .b = method })) |slots| {
            return try allocator.dupe(?FuncId, slots.items);
        }
        if (amd.get(.{ .a = simple, .b = method })) |slots| {
            return try allocator.dupe(?FuncId, slots.items);
        }
        const cg = self.classes.borrow();
        if (cg.get().get(cn)) |def| {
            const dg = def.borrow();
            for (dg.get().supertype_names) |sn| try queue.append(allocator, sn);
            dg.deinit();
        }
        cg.deinit();
    }
    return null;
}

/// Fake override inheriting a default: the body comes from a superclass and the
/// default from an interface, so an undersupplied call fills from that thunk.
pub fn fakeOverrideInheritedDefault(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    args: []const Value,
) Allocator.Error!?EvalResult {
    if (receiver.* != .Instance) return null;
    var stypes: std.ArrayList([]const u8) = .empty;
    defer stypes.deinit(allocator);
    {
        const g = receiver.Instance.borrow();
        const cg = g.get().class.borrow();
        for (cg.get().supertype_names) |s| stypes.append(allocator, s) catch {};
        cg.deinit();
        g.deinit();
    }
    if (stypes.items.len == 0) return null;
    const defaults = (try inheritedMemberDefaults(self, allocator, stypes.items, name)) orelse return null;
    defer allocator.free(defaults);

    const mg = self.module.borrow();
    var mg_open = true;
    defer if (mg_open) mg.deinit();
    const mod = mg.get();

    // Direct supertypes only: the shape declares the body superclass and default
    // interface side by side (`B : A(), I`); deeper, it preempts host dispatch.
    var method_fid: ?FuncId = null;
    {
        var direct: std.ArrayList([]const u8) = .empty;
        defer direct.deinit(allocator);
        {
            const g = receiver.Instance.borrow();
            const cg = g.get().class.borrow();
            for (cg.get().supertype_names) |sn| direct.append(allocator, sn) catch {};
            cg.deinit();
            g.deinit();
        }
        for (direct.items) |cn| {
            var is_iface = false;
            const fqn: []const u8 = blk: {
                const cgr = self.classes.borrow();
                defer cgr.deinit();
                if (cgr.get().get(cn)) |d| {
                    const dg = d.borrow();
                    defer dg.deinit();
                    is_iface = dg.get().is_interface;
                    break :blk dg.get().fqn;
                }
                break :blk cn;
            };
            if (is_iface) continue;
            for (mod.memberDecls(fqn, name)) |fid| {
                const f = funcAt(mod, fid) orelse continue;
                if (!f.hasBody()) continue;
                // A suspend member dispatches through the coroutine machinery.
                if (f.is_suspend) continue;
                if (defaults.len != f.params.len) continue;
                const has_this = f.params.len > 0 and std.mem.eql(u8, f.params[0].name, "this");
                const user_params = f.params.len - @intFromBool(has_this);
                if (args.len < user_params) {
                    method_fid = fid;
                    break;
                }
            }
            if (method_fid != null) break;
        }
    }
    const fid = method_fid orelse return null;
    const f = funcAt(mod, fid) orelse return null;
    var provided = try allocator.alloc(Value, 1 + args.len);
    defer allocator.free(provided);
    provided[0] = receiver.*;
    @memcpy(provided[1..], args);
    if (provided.len >= f.params.len) return null;

    const padded = switch (try padArgsWithDefaultsFor(self, allocator, mod, f.params.len, provided, defaults, f.params)) {
        .ok => |p| p,
        .err => |e| return .{ .err = e },
    };
    defer allocator.free(padded);
    // Release the module borrow: `invokeMethodFuncId` takes its own.
    mg.deinit();
    mg_open = false;
    return try invokeMethodFuncId(self, allocator, receiver, fid, padded[1..]);
}

pub fn enclosingCallableProperty(self: *VmHost, allocator: Allocator, name: []const u8) Allocator.Error!?Value {
    var work: std.ArrayList(Value) = .empty;
    defer work.deinit(allocator);
    {
        const chain = try enclosingThisChain(self, allocator);
        defer allocator.free(chain);
        try work.appendSlice(allocator, chain);
    }
    var seen: std.AutoHashMap(u64, void) = .init(allocator);
    defer seen.deinit();
    var i: usize = 0;
    while (i < work.items.len) : (i += 1) {
        const v = work.items[i];
        const inst = switch (v) {
            .Instance => |inst| inst,
            else => continue,
        };
        const g = inst.borrow();
        const data = g.get();
        if (seen.contains(data.identity)) {
            g.deinit();
            continue;
        }
        try seen.put(data.identity, {});
        for (data.fields.items) |f| {
            if (std.mem.eql(u8, f.name, name) and isCallable(&f.value)) {
                const found = f.value;
                g.deinit();
                return found;
            }
        }
        const outer = data.outer;
        g.deinit();
        if (outer) |o| try work.append(allocator, o);
    }
    return null;
}

/// A top type or bare type parameter: every value satisfies it, so it loses to any concrete match.
pub fn isTopOrGenericType(ty_name: []const u8) bool {
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) return true;
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) return true;
    return false;
}

/// How specifically the receiver satisfies `ty_name`, ranking Kotlin's most-specific
/// rule: larger for a closer IS-A match, `0` for a top type or bare type parameter,
/// `-1` when the receiver definitely does not satisfy a concrete `ty_name`.
pub fn extReceiverSpecificity(self: *VmHost, receiver: *const Value, ty_name: []const u8) i32 {
    if (isTopOrGenericType(ty_name)) return 0;
    const pn = std.mem.trimEnd(u8, simpleName(ty_name), "?");
    if (receiver.* == .Instance) {
        if (instanceFunctionDistance(self, receiver, pn)) |dist| {
            const d: i32 = @intCast(@min(dist, @as(usize, 50)));
            return 100 - d;
        }
        // A builtin interface reached through supertype names, not the class graph.
        if (receiverImplementsType(self, receiver, pn)) return 50;
        return -1;
    }
    if (receiver.isRuntimeType(pn)) return 100;
    const v_ty = simpleName(receiver.typeFqn());
    for (applicability.builtinSupersOf(v_ty), 0..) |s, pos| {
        if (std.mem.eql(u8, s, pn)) {
            const d: i32 = @intCast(@min(pos, @as(usize, 50)));
            return 90 - d;
        }
    }
    return -1;
}

/// Strict extension-receiver proof for the bare-name resolver's innermost-first walk:
/// a function-shape receiver proves only against a function value, a bounded type
/// parameter requires every bound, typealiases expand first, and generic arguments
/// participate where elements are known. The unproven fall to the lenient pass.
pub fn strictReceiverProven(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, ty: *const TypeRef) Allocator.Error!bool {
    // A null receiver is provably accepted only by a nullable receiver type.
    if (receiver.* == .Null) return ty.nullable;
    return strictReceiverProvenName(self, allocator, receiver, fid, ty.name, ty.args, 0);
}

pub fn strictReceiverProvenName(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, ty_name: []const u8, ty_args: []const TypeRef, fuel: u8) Allocator.Error!bool {
    if (fuel > 8) return false;
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (std.mem.startsWith(u8, pn, "Function")) {
        return receiverIsFunctionShaped(self, receiver, pn);
    }
    // Declared type parameter: unbounded accepts anything, bounded needs every bound.
    if (typeParamOf(self, fid, pn)) {
        const bounds: []const ir.ModuleRegistry.TypeParamBound = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.func_type_param_bounds.get(fid) orelse &.{};
        };
        for (bounds) |b| {
            if (!std.mem.eql(u8, b.param, pn)) continue;
            if (!try strictReceiverProvenName(self, allocator, receiver, fid, b.bound, &.{}, fuel + 1)) return false;
        }
        return true;
    }
    // A short all-uppercase head the registry does not record proves like an
    // unbounded type parameter, unless a class of that name is registered.
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) {
        const registered = blk: {
            const cg = self.classes.borrow();
            defer cg.deinit();
            break :blk cg.get().get(pn) != null;
        };
        if (!registered) return true;
    }
    // Typealias expansion: the registry records only the target's head name.
    {
        const target: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(pn);
        };
        if (target) |t| {
            if (!std.mem.eql(u8, t, pn)) {
                return strictReceiverProvenName(self, allocator, receiver, fid, t, &.{}, fuel + 1);
            }
        }
    }
    if (!receiverImplementsHead(self, receiver, pn)) return false;
    if (ty_args.len == 0) return true;
    // A user `Instance` carries no reified type arguments, so the head match is the
    // strongest provable check; `elementsProveArgs` reads builtin containers only.
    if (receiver.* == .Instance) return true;
    return elementsProveArgs(self, allocator, receiver, fid, pn, ty_args, fuel);
}

/// The lifted key for a dotted nested-class reference, or null when the name is
/// not dotted or carries no mangle entry.
pub fn mangledNestedKey(mod: *const Module, name: []const u8) ?[]const u8 {
    if (std.mem.findScalar(u8, name, '.') == null) return null;
    // Last two segments (`a.b.C.D` -> `C.D`) key the mangle table.
    var last: ?usize = null;
    var prev: ?usize = null;
    for (name, 0..) |ch, i| {
        if (ch == '.') {
            prev = last;
            last = i;
        }
    }
    const start = if (prev) |p| p + 1 else 0;
    return mod.registry.mangled_nested.get(name[start..]);
}

/// Whether two class-name strings name the same type head: literal match, mangle-
/// table canonical match, or bare head (dots and the `Outer$` lift prefix stripped).
pub fn classHeadsMatch(self: *VmHost, a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const ka = mangledClassKeyOf(self, a) orelse a;
    const kb = mangledClassKeyOf(self, b) orelse b;
    if (std.mem.eql(u8, ka, kb)) return true;
    return std.mem.eql(u8, bareHead(a), bareHead(b));
}

pub fn bareHead(name: []const u8) []const u8 {
    var sn = name;
    if (std.mem.findScalarLast(u8, sn, '.')) |i| sn = sn[i + 1 ..];
    if (std.mem.findScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
    if (std.mem.findScalarLast(u8, sn, '$')) |i| {
        if (i + 1 < sn.len) sn = sn[i + 1 ..];
    }
    return std.mem.trimEnd(u8, sn, "?");
}

/// Lifted mangle key for a dotted class name; only a table hit canonicalizes, so
/// unrelated same-simple-name classes never merge.
pub fn mangledClassKeyOf(self: *VmHost, name: []const u8) ?[]const u8 {
    const mg = self.module.borrow();
    defer mg.deinit();
    return mangledNestedKey(mg.get(), name);
}

/// Whether an extension with receiver head `ty` applies to a receiver whose static
/// type head is `static_name`; Kotlin resolves extension calls against the static
/// receiver type. Null is undecidable, and the caller proves against the runtime type.
pub fn staticReceiverApplicable(self: *VmHost, allocator: Allocator, static_name: []const u8, fid: FuncId, ty: *const TypeRef) ?bool {
    var pn = simpleName(ty.name);
    pn = std.mem.trimEnd(u8, pn, "?");
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    if (typeParamOf(self, fid, pn)) return true;
    // A receiver that is the owner class's own type parameter accepts any static hint.
    if (ir.parseClassTypeParamIdentity(std.mem.trimEnd(u8, ty.name, "?")) != null) return true;
    // A dotted nested receiver canonicalizes to its mangled key.
    {
        const mg0 = self.module.borrow();
        defer mg0.deinit();
        if (mangledNestedKey(mg0.get(), std.mem.trimEnd(u8, ty.name, "?"))) |m| pn = m;
    }
    // The short-all-uppercase heuristic applies only to a head that is not a class.
    const head_is_class = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().registry.class_super_names.get(pn) != null or mg.get().classId(pn) != null;
    };
    if (!head_is_class and pn.len > 0 and pn.len <= 2 and allUppercase(pn)) return true;
    {
        const target: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(pn);
        };
        if (target) |t| {
            if (!std.mem.eql(u8, t, pn)) pn = simpleName(t);
        }
    }
    var sn = simpleName(static_name);
    if (std.mem.findScalar(u8, sn, '<')) |lt| sn = sn[0..lt];
    sn = std.mem.trimEnd(u8, std.mem.trim(u8, sn, " "), "?");
    if (std.mem.eql(u8, sn, pn)) return true;
    _ = allocator;
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    // A dotted hint canonicalizes through the same mangle table as `pn`.
    if (mangledNestedKey(mod, std.mem.trimEnd(u8, static_name, "?"))) |m| sn = m;
    if (std.mem.eql(u8, sn, pn)) return true;
    // The scan below is O(classes); the class count in the key retires stale verdicts.
    const sra_key = blk: {
        var h = std.hash.Wyhash.init(0x53524143);
        const mp: usize = @intFromPtr(mod);
        h.update(std.mem.asBytes(&mp));
        const n: usize = mod.class_index.items.len;
        h.update(std.mem.asBytes(&n));
        h.update(sn);
        h.update(&[_]u8{0});
        h.update(pn);
        break :blk h.final();
    };
    if (sra_cache.get(sra_key)) |v| return switch (v) {
        0 => false,
        1 => true,
        else => null,
    };
    // Resolve `sn` against every class sharing that simple name. Only an unambiguous
    // resolution that still fails to reach `pn` is a definite `false`.
    var matches: usize = 0;
    var relates = false;
    for (mod.class_index.items) |entry| {
        // A lift-mangled nested class also answers for its source simple name.
        const ehead = blk: {
            const sn2 = simpleName(entry.name);
            if (std.mem.findScalarLast(u8, sn2, '$')) |i| {
                if (i + 1 < sn2.len) break :blk sn2[i + 1 ..];
            }
            break :blk sn2;
        };
        if (!(std.mem.eql(u8, simpleName(entry.name), sn) or std.mem.eql(u8, ehead, sn))) continue;
        matches += 1;
        if (std.mem.eql(u8, simpleName(entry.name), pn) or std.mem.eql(u8, entry.name, pn)) {
            relates = true;
            continue;
        }
        if (mod.registry.class_super_names.get(entry.name)) |chain| {
            for (chain) |s| {
                if (std.mem.eql(u8, simpleName(s), pn)) {
                    relates = true;
                    break;
                }
                // A dotted supertype that lifted mangled compares by canonical key.
                if (mangledNestedKey(mod, s)) |m| {
                    if (std.mem.eql(u8, m, pn)) {
                        relates = true;
                        break;
                    }
                }
            }
        }
    }
    const verdict: u8 = if (relates) 1 else if (matches != 1) 2 else 0;
    sra_cache.put(std.heap.page_allocator, sra_key, verdict) catch {};
    if (relates) return true;
    if (matches != 1) return null;
    return false;
}

/// Memoized `staticReceiverApplicable` verdicts, keyed by (module identity, class
/// count, sn, pn) and thread-local.
pub threadlocal var sra_cache: std.AutoHashMapUnmanaged(u64, u8) = .empty;

/// Drop this thread's verdicts: an in-process re-run may reuse a module address.
pub fn resetStaticApplicabilityCache() void {
    sra_cache.clearRetainingCapacity();
}

/// Whether the declared signature refuses `n_args` outright: fewer than required,
/// or more than total without a vararg. A missing `DeclSig` refuses nothing.
pub fn declArityRefuses(self: *VmHost, fid: FuncId, n_args: usize) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const sig = mg.get().decl_sigs.get(fid.int()) orelse return false;
    if (n_args < sig.arity.required) return true;
    if (n_args > sig.arity.total and !sig.arity.has_vararg) return true;
    return false;
}

/// Can the candidate take `want` positional args (receiver included)? Extra params
/// must each carry a default or be a vararg; extra args only fit a trailing vararg.
pub fn extArityApplicable(self: *VmHost, f: *const Func, want: usize) bool {
    return extArityApplicableTL(self, f, want, false);
}

/// `extArityApplicable` with Kotlin's trailing-lambda rule: a callable last argument
/// binds a function-typed last parameter, so only the gap parameters need defaults.
pub fn extArityApplicableTL(self: *VmHost, f: *const Func, want: usize, last_arg_callable: bool) bool {
    if (f.params.len == want) return true;
    if (f.params.len < want) {
        return f.params.len > 0 and f.params[f.params.len - 1].is_vararg;
    }
    const defaults = funcDefaults(self, f);
    const trailing_bind = last_arg_callable and want > 0 and
        isFunctionTypeRef(&f.params[f.params.len - 1].ty);
    const gap_from: usize = if (trailing_bind) want - 1 else want;
    const gap_to: usize = if (trailing_bind) f.params.len - 1 else f.params.len;
    var k: usize = gap_from;
    while (k < gap_to) : (k += 1) {
        if (!(f.params[k].is_vararg or paramHasDefault(defaults, k))) return false;
    }
    return true;
}

/// Is the receiver an actual function value of the declared shape? `pn` is
/// `Function` or `FunctionN`; arity is checked where the value carries one.
pub fn receiverIsFunctionShaped(self: *VmHost, receiver: *const Value, pn: []const u8) bool {
    switch (receiver.*) {
        .IrClosure, .Intrinsic, .BoundMethod => {},
        // A class extending a function type carries the erased `FunctionN` name.
        .Instance => return instanceFunctionDistance(self, receiver, pn) != null,
        else => return false,
    }
    const digits = pn["Function".len..];
    if (digits.len == 0) return true;
    const n = std.fmt.parseInt(usize, digits, 10) catch return true;
    // A parameterless lambda lowers with the implicit `it` slot, so arity 1 proves `Function0`.
    return switch (receiver.*) {
        .IrClosure => |c| blk: {
            const info = self.closures.get(@intCast(c.asPtr().id)) orelse break :blk true;
            break :blk info.n_params == n or (n == 0 and info.n_params == 1);
        },
        else => true,
    };
}

/// Whether the instance's hierarchy declares `invoke`. klio accepts such an instance
/// at a function-typed parameter, so the argument filter must not disprove it.
pub fn instanceHierarchyHasInvoke(self: *VmHost, v: *const Value) bool {
    if (v.* != .Instance) return false;
    var cls: []const u8 = undefined;
    {
        const g = v.Instance.borrow();
        const cg = g.get().class.borrow();
        cls = cg.get().name;
        cg.deinit();
        g.deinit();
    }
    const mg = self.module.borrow();
    defer mg.deinit();
    if (mg.get().registry.hierarchy_methods.get(cls)) |hm| {
        return hm.contains("invoke");
    }
    return false;
}

pub fn valueNominalFqn(v: *const Value) []const u8 {
    if (v.* != .Instance) return v.typeFqn();
    const g = v.Instance.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    return cg.get().fqn;
}

/// Whether a lambda argument's declared parameter types disprove a candidate's
/// function-typed parameter. Refutes only on a definite mismatch: two builtin
/// scalars, or a builtin scalar against a class this build declares.
pub fn closureParamsDisproveFnParam(self: *VmHost, pty: *const TypeRef, arg: *const Value) bool {
    if (arg.* != .IrClosure) return false;
    if (!std.mem.startsWith(u8, pty.name, "Function")) return false;
    const info = self.closures.get(@intCast(arg.IrClosure.asPtr().id)) orelse return false;
    const mg = self.module.borrow();
    defer mg.deinit();
    const module = if (info.module) |m| m else mg.get();
    const cf = module.funcById(info.body_func) orelse return false;
    const expected = fnTypeValueParams(pty) orelse return false;
    const skip: usize = if (cf.params.len != 0 and std.mem.eql(u8, cf.params[0].name, "this")) 1 else 0;
    if (cf.params.len <= skip) return false;
    const got = cf.params[skip..];
    const n = @min(got.len, expected.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const gh = fnParamHead(got[i].ty.name);
        const eh = fnParamHead(expected[i].name);
        if (gh.len == 0 or eh.len == 0) continue;
        if (std.mem.eql(u8, gh, eh)) continue;
        const g_scalar = scalarHeadOf(gh) != null;
        const e_scalar = scalarHeadOf(eh) != null;
        if (g_scalar and e_scalar) return true;
        if (e_scalar and knownClassHead(module, gh)) return true;
        if (g_scalar and knownClassHead(module, eh)) return true;
    }
    return false;
}

/// The declared value parameter types of a lowered function type. Encoding:
/// `[#suspend?] [receiver?] params… ret [#markers]`.
pub fn fnTypeValueParams(ty: *const TypeRef) ?[]const TypeRef {
    const want = std.fmt.parseInt(usize, ty.name["Function".len..], 10) catch return null;
    var hi: usize = ty.args.len;
    while (hi > 0 and ty.args[hi - 1].name.len != 0 and ty.args[hi - 1].name[0] == '#') hi -= 1;
    if (hi == 0) return null;
    var lo: usize = 0;
    if (lo < hi and std.mem.eql(u8, ty.args[lo].name, "#suspend")) lo += 1;
    hi -= 1;
    if (hi < lo) return null;
    var params = ty.args[lo..hi];
    if (params.len > want) params = params[params.len - want ..];
    return params;
}

pub fn fnParamHead(name: []const u8) []const u8 {
    var h = simpleName(std.mem.trimEnd(u8, name, "?"));
    if (std.mem.findScalar(u8, h, '<')) |lt| h = h[0..lt];
    return h;
}

pub fn scalarHeadOf(h: []const u8) ?[]const u8 {
    const scalars = [_][]const u8{
        "Int",  "Long",  "Short",  "Byte",   "Double",  "Float",
        "UInt", "ULong", "UShort", "UByte",  "Boolean", "Char",
        "String",
    };
    for (scalars) |sc| {
        if (std.mem.eql(u8, h, sc)) return sc;
    }
    return null;
}

/// Whether `h` names a class this build declares; a shorter or unresolvable head is a type parameter.
pub fn knownClassHead(module: *const Module, h: []const u8) bool {
    if (h.len <= 1) return false;
    if (std.mem.eql(u8, h, "Any")) return false;
    if (std.mem.startsWith(u8, h, "Function")) return false;
    return module.classId(h) != null;
}

/// Whether a positional argument's value is definitely excluded by the candidate's
/// declared parameter type. Kotlin applicability covers arguments, not just the receiver.
pub fn candidateArgsDisproven(self: *VmHost, f: *const Func, args: []const Value) bool {
    if (f.params.len <= 1 or args.len == 0) return false;
    // A single trailing vararg adjudicates each remaining arg against its element
    // type. A non-final vararg repositions everything after it: decline.
    var vararg_trailing = false;
    for (f.params, 0..) |*pp, pi| {
        if (pp.is_vararg) {
            if (pi + 1 != f.params.len) return false;
            vararg_trailing = true;
        }
    }
    if (vararg_trailing) {
        const lead = f.params.len - 2; // params[0] is `this`
        for (args, 0..) |*a, ai| {
            const pty = if (ai < lead) &f.params[ai + 1].ty else &f.params[f.params.len - 1].ty;
            if (std.mem.startsWith(u8, pty.name, "Function") and instanceHierarchyHasInvoke(self, a)) continue;
            if (argDefinitelyNotParamType(self, pty, a)) {
                if (missTraceWant(f.name)) {
                    std.debug.print("[extfb]  vararg arg#{d} {s} rejects {s}\n", .{ ai, pty.name, valueNominalFqn(a) });
                }
                return true;
            }
        }
        return false;
    }
    var n = args.len;
    // Trailing-lambda binding leaves only the positional prefix to adjudicate.
    if (isCallable(&args[args.len - 1]) and
        isFunctionTypeRef(&f.params[f.params.len - 1].ty) and
        args.len < f.params.len - 1)
    {
        n = args.len - 1;
    }
    for (args[0..n], 0..) |*a, i| {
        if (i + 1 >= f.params.len) break;
        const pty = &f.params[i + 1].ty;
        if (std.mem.startsWith(u8, pty.name, "Function") and instanceHierarchyHasInvoke(self, a)) continue;
        if (argDefinitelyNotParamType(self, pty, a)) {
            if (missTraceWant(f.name)) {
                std.debug.print("[extfb]  arg#{d} {s} rejects {s}\n", .{ i, pty.name, valueNominalFqn(a) });
            }
            return true;
        }
    }
    return false;
}

/// A type-parameter receiver constrains dispatch by its declared bound: a receiver
/// whose hierarchy provably excludes the bound head is not applicable.
pub fn receiverViolatesTypeParamBound(self: *VmHost, fid: FuncId, param_ty: *const TypeRef, receiver: *const Value) bool {
    const pn0 = std.mem.trimEnd(u8, simpleName(param_ty.name), "?");
    if (!typeParamOf(self, fid, pn0)) return false;
    const bounds: []const ir.ModuleRegistry.TypeParamBound = blk: {
        const mg = self.module.borrow();
        defer mg.deinit();
        break :blk mg.get().registry.func_type_param_bounds.get(fid) orelse return false;
    };
    for (bounds) |b| {
        if (!std.mem.eql(u8, b.param, pn0)) continue;
        var bn = simpleName(b.bound);
        if (std.mem.findScalar(u8, bn, '<')) |lt| bn = bn[0..lt];
        bn = std.mem.trimEnd(u8, std.mem.trim(u8, bn, " "), "?");
        if (std.mem.eql(u8, bn, "Any")) continue;
        // A bound that is itself a type parameter names no class and cannot be decided.
        if (typeParamOf(self, fid, bn)) continue;
        // Decidable when the receiver's full type is known; an erased callable
        // against a functional-interface bound stays undecided (SAM conversion).
        const decidable = switch (receiver.*) {
            .Null, .IrClosure, .Intrinsic, .BoundMethod => false,
            else => true,
        };
        if (decidable and !receiverImplementsHead(self, receiver, bn)) return true;
    }
    return false;
}

pub fn typeParamOf(self: *VmHost, fid: FuncId, pn: []const u8) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const tps = mg.get().registry.func_type_params.get(fid) orelse return false;
    for (tps.items) |tp| {
        if (std.mem.eql(u8, tp, pn)) return true;
    }
    return false;
}

/// Whether a declared parameter type names a type variable in scope: one of the
/// function's own type parameters, or the owning class's for an instance method.
/// It never names a nominal class, so argument adjudication must not read it as one.
pub fn paramTypeIsTypeVar(self: *VmHost, f: *const Func, ty: *const TypeRef) bool {
    return fidTypeVar(self, f.id, ty);
}

/// `paramTypeIsTypeVar` keyed by `FuncId`, the applicability engine's callback shape.
pub fn fidTypeVar(self: *VmHost, fid: FuncId, ty: *const TypeRef) bool {
    const mg = self.module.borrow();
    defer mg.deinit();
    const mod = mg.get();
    for (ty.args) |arg| {
        if (std.mem.startsWith(u8, arg.name, "#qual:")) return false;
    }
    const raw = std.mem.trimEnd(u8, ty.name, "?");
    if (ir.parseClassTypeParamIdentity(raw)) |identity| {
        const sig = mod.decl_sigs.get(fid.int()) orelse return false;
        if (sig.enclosing_class == null or
            sig.enclosing_class.?.int() != identity.owner.int() or
            identity.owner.int() >= mod.classes.items.len)
        {
            return false;
        }
        const owner = &mod.classes.items[identity.owner.int()];
        const bounds = mod.registry.class_type_param_bounds.get(owner.fqn) orelse
            return false;
        for (bounds) |bound| {
            if (std.mem.eql(u8, bound.param, identity.param)) return true;
        }
        return false;
    }
    return typeParamOf(self, fid, raw);
}

pub fn applicTypeVarCbM(ctx: *anyopaque, fid: FuncId, ty: *const TypeRef) bool {
    const self: *VmHost = @ptrCast(@alignCast(ctx));
    return fidTypeVar(self, fid, ty);
}

/// Generic-argument proof over the receiver's elements: only builtin containers
/// carry element knowledge, and an empty one proves through its recorded head.
pub fn elementsProveArgs(self: *VmHost, allocator: Allocator, receiver: *const Value, fid: FuncId, pn: []const u8, ty_args: []const TypeRef, fuel: u8) Allocator.Error!bool {
    if (std.mem.eql(u8, pn, "Map") or std.mem.eql(u8, pn, "MutableMap")) {
        if (receiver.* != .Map or ty_args.len < 2) return false;
        const g = receiver.Map.entries.borrow();
        defer g.deinit();
        const entries = g.get().pairs.items;
        if (entries.len == 0) {
            return overload_match.declaredElemProves(self, &ty_args[0], receiver.Map.declared_key) and
                overload_match.declaredElemProves(self, &ty_args[1], receiver.Map.declared_value);
        }
        for (entries) |*e| {
            if (!try elementSatisfies(self, allocator, &e.key, fid, &ty_args[0], fuel)) return false;
            if (!try elementSatisfies(self, allocator, &e.value, fid, &ty_args[1], fuel)) return false;
        }
        return true;
    }
    const items: ?runtime.ValueList = switch (receiver.*) {
        .List => |l| if (isListHead(pn)) l.items else null,
        .Set => |st| if (isSetHead(pn)) st.items else null,
        .Array => |arr| if (std.mem.eql(u8, pn, "Array")) arr.boxedList() else null,
        else => null,
    };
    const list = items orelse return false;
    if (ty_args.len < 1) return false;
    const declared_elem: ?[]const u8 = switch (receiver.*) {
        .List => |l| l.declared_elem,
        .Set => |st| st.declared_elem,
        else => null,
    };
    const g = list.borrow();
    defer g.deinit();
    const elems = g.get().items;
    if (elems.len == 0) return overload_match.declaredElemProves(self, &ty_args[0], declared_elem);
    for (elems) |*e| {
        if (!try elementSatisfies(self, allocator, e, fid, &ty_args[0], fuel)) return false;
    }
    return true;
}

pub fn isListHead(pn: []const u8) bool {
    return std.mem.eql(u8, pn, "List") or std.mem.eql(u8, pn, "MutableList") or
        std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "MutableCollection") or
        std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "MutableIterable");
}

pub fn isSetHead(pn: []const u8) bool {
    return std.mem.eql(u8, pn, "Set") or std.mem.eql(u8, pn, "MutableSet") or
        std.mem.eql(u8, pn, "Collection") or std.mem.eql(u8, pn, "MutableCollection") or
        std.mem.eql(u8, pn, "Iterable") or std.mem.eql(u8, pn, "MutableIterable");
}

/// One element against one declared generic argument; a star projection or type
/// parameter accepts anything, and a nullable argument accepts `null`.
pub fn elementSatisfies(self: *VmHost, allocator: Allocator, elem: *const Value, fid: FuncId, arg: *const TypeRef, fuel: u8) Allocator.Error!bool {
    if (std.mem.eql(u8, arg.name, "*")) return true;
    var head = arg.name;
    if (std.mem.startsWith(u8, head, "in#")) head = head["in#".len..];
    if (std.mem.startsWith(u8, head, "out#")) head = head["out#".len..];
    if (arg.nullable and elem.* == .Null) return true;
    if (elem.* == .Null) return false;
    return strictReceiverProvenName(self, allocator, elem, fid, head, arg.args, fuel + 1);
}

pub fn headNamesRegisteredClass(self: *VmHost, head: []const u8) bool {
    const cg = self.classes.borrow();
    defer cg.deinit();
    return cg.get().get(head) != null;
}

/// Head-name check against the receiver's runtime type: the class hierarchy for an
/// Instance, the runtime type-name sets otherwise. Callers handle generics and shapes.
pub fn receiverImplementsHead(self: *VmHost, receiver: *const Value, pn: []const u8) bool {
    switch (receiver.*) {
        .Instance => |inst| {
            const a = self.allocator;
            var queue: std.ArrayList([]const u8) = .empty;
            defer queue.deinit(a);
            var seen: std.StringHashMap(void) = .init(a);
            defer seen.deinit();
            {
                const g = inst.borrow();
                const cg = g.get().class.borrow();
                // Kotlin declares `Enum<E> : Comparable<E>`, so every enum entry
                // satisfies a `Comparable` bound without declaring the supertype.
                const is_enum = cg.get().is_enum;
                cg.deinit();
                g.deinit();
                if (is_enum and (std.mem.eql(u8, pn, "Comparable") or std.mem.eql(u8, pn, "Enum"))) return true;
            }
            {
                const g = inst.borrow();
                const cg = g.get().class.borrow();
                queue.append(a, cg.get().name) catch {};
                cg.deinit();
                g.deinit();
            }
            while (queue.pop()) |c| {
                if (seen.contains(c)) continue;
                seen.put(c, {}) catch {};
                const sn = simpleName(c);
                if (std.mem.eql(u8, sn, pn)) return true;
                // A file-collision mangle (`X$f12`) satisfies its source spelling.
                if (std.mem.eql(u8, stripFileMangle(sn), pn)) return true;
                // A lifted nested class registers mangled (`Modifier$Node`), so a bare head matches the `$` tail.
                if (sn.len > pn.len and sn[sn.len - pn.len - 1] == '$' and
                    std.mem.endsWith(u8, sn, pn)) return true;
                const cg = self.classes.borrow();
                if (cg.get().get(c)) |d| {
                    const dg = d.borrow();
                    for (dg.get().supertype_names) |sup| queue.append(a, sup) catch {};
                    dg.deinit();
                }
                cg.deinit();
            }
            // `instanceOf` is the authoritative subtype answer, the same one `is`
            // uses; the name walk sees only simple-name ClassTable entries.
            return host_classes.instanceOf(self, receiver, .{ .name = pn, .nullable = false, .args = &.{} });
        },
        else => return receiver.isRuntimeType(pn),
    }
}

/// Lenient check: does the receiver's runtime type satisfy `ty_name`?
pub fn receiverImplementsType(self: *VmHost, receiver: *const Value, ty_name: []const u8) bool {
    var pn = simpleName(ty_name);
    pn = std.mem.trimEnd(u8, pn, "?");
    // Expand typealiases so an extension declared on an alias of Unit accepts a
    // Unit receiver; the fuel bound guards a self-referential entry.
    var alias_fuel: u8 = 4;
    while (alias_fuel > 0) : (alias_fuel -= 1) {
        const target: ?[]const u8 = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().registry.type_aliases.get(pn);
        };
        const t = target orelse break;
        if (std.mem.eql(u8, t, pn)) break;
        pn = std.mem.trimEnd(u8, simpleName(t), "?");
    }
    if (std.mem.eql(u8, pn, "Any") or std.mem.eql(u8, pn, "Unit")) return true;
    // A function type, or the `<function>` marker for a receiver written
    // `T.() -> R`, is satisfied by any callable value.
    if (std.mem.startsWith(u8, pn, "Function") or std.mem.eql(u8, pn, "<function>")) return true;
    // A short all-caps head is a type parameter that any receiver satisfies, unless
    // the program declares a class of that name.
    if (pn.len > 0 and pn.len <= 2 and allUppercase(pn)) {
        const declared = blk: {
            const mg = self.module.borrow();
            defer mg.deinit();
            break :blk mg.get().classId(pn) != null;
        };
        if (!declared) return true;
    }
    switch (receiver.*) {
        .Instance => |inst| {
            const a = self.allocator;
            var queue: std.ArrayList([]const u8) = .empty;
            defer queue.deinit(a);
            var seen: std.StringHashMap(void) = .init(a);
            defer seen.deinit();
            {
                const g = inst.borrow();
                const cg = g.get().class.borrow();
                queue.append(a, cg.get().name) catch {};
                cg.deinit();
                g.deinit();
            }
            while (queue.pop()) |c| {
                if (seen.contains(c)) continue;
                seen.put(c, {}) catch {};
                const sn = simpleName(c);
                if (std.mem.eql(u8, sn, pn)) return true;
                // A lifted nested class registers mangled (`Modifier$Node`), so a bare head matches the `$` tail.
                if (sn.len > pn.len and sn[sn.len - pn.len - 1] == '$' and
                    std.mem.endsWith(u8, sn, pn)) return true;
                const cg = self.classes.borrow();
                if (cg.get().get(c)) |d| {
                    const dg = d.borrow();
                    for (dg.get().supertype_names) |s| queue.append(a, s) catch {};
                    dg.deinit();
                }
                cg.deinit();
            }
            return false;
        },
        else => return receiver.isRuntimeType(pn),
    }
}

pub fn receiverImplementsOwnerIdentity(
    self: *VmHost,
    receiver: *const Value,
    owner: []const u8,
) bool {
    if (std.mem.findScalar(u8, owner, '.') == null) {
        return receiverImplementsType(self, receiver, owner);
    }
    if (receiver.* != .Instance) return false;
    var closure: std.ArrayList(*const ClassDef) = .empty;
    defer closure.deinit(self.allocator);
    var seen: std.ArrayList(*const ClassDef) = .empty;
    defer seen.deinit(self.allocator);
    {
        const instance = receiver.Instance.borrow();
        collectClassClosure(
            instance.get().class.asPtr(),
            &closure,
            &seen,
            self.allocator,
        );
        instance.deinit();
    }
    for (closure.items) |class| {
        if (std.mem.eql(u8, class.fqn, owner)) return true;
    }
    return false;
}
