//! Field-read entry points and their fast paths: the accessor-getter serve, the
//! field-site route claims, and the plain stored-slot lookups.

const std = @import("std");
const ir = @import("ir");
const runtime = @import("runtime");
const vmhost = @import("../vmhost.zig");
const host_resolved = @import("../host_resolved.zig");
const VmHost = vmhost.VmHost;
const root = @import("../../interp_ir.zig");
const host_call_member = @import("../host_call_member.zig");
const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const ClassDef = runtime.ClassDef;
const InstanceData = runtime.InstanceData;
const Module = ir.Module;
const FuncId = ir.FuncId;
const EvalError = ir.eval.EvalError;
const EvalResult = ir.eval.EvalResult;

const host_fields = @import("../host_fields.zig");
const fldTls = host_fields.fldTls;
const getField = host_fields.getField;

const common = @import("common.zig");
const className = common.className;
const containsStr = common.containsStr;
const evalGetterTagged = common.evalGetterTagged;
const firstSupertype = common.firstSupertype;
const freeMissErr = common.freeMissErr;
const lookupPairFuncHop = common.lookupPairFuncHop;
const ok = common.ok;
const unwrapCellRead = common.unwrapCellRead;

const bound_ref = @import("bound_ref.zig");
const sgetterNameMatches = bound_ref.sgetterNameMatches;

const get_field_inner = @import("get_field_inner.zig");
const getFieldInner = get_field_inner.getFieldInner;

const ext_props = @import("ext_props.zig");
const delegatedPropRegistered = ext_props.delegatedPropRegistered;
const runtimeClassDelegatesProp = ext_props.runtimeClassDelegatesProp;

const field_cache = @import("field_cache.zig");
const fieldReadCacheGet = field_cache.fieldReadCacheGet;
const fieldWriteCacheGet = field_cache.fieldWriteCacheGet;
const storedNullIsLateinit = field_cache.storedNullIsLateinit;

pub fn getMemberField(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    // An instance lowered from sema answers a base member a native reads
    // (`Map.entries` when a host map copies or compares it) through its slot.
    if (try host_resolved.wellKnownCall(self, allocator, receiver, name, &.{}, .getter)) |r| return r;
    return unwrapCellRead(try getFieldInner(self, allocator, receiver, name, false, true, false));
}

/// `getMemberField` with imported extension properties suppressed: a class member
/// outranks an import, so on the implicit-receiver walk's first pass an outer
/// receiver's member beats an inner receiver's imported extension.
pub fn getMemberFieldNoExt(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) Allocator.Error!EvalResult {
    return unwrapCellRead(try getFieldInner(self, allocator, receiver, name, false, true, true));
}

pub const FieldSiteClaim = struct { cls: u64, route: u64 };

/// Whether a stored null is plain and not an unset `lateinit`, whose read must
/// throw. Decided from the class, so a site memo can serve nulls.
pub fn storedNullServable(self: *VmHost, receiver: *const Value, name: []const u8) bool {
    _ = self;
    if (receiver.* != .Instance) return false;
    return !storedNullIsLateinit(receiver.Instance, name);
}

/// The write-side `fieldSiteRoute`, off the write memo the store fills; anything
/// but a plain stored slot declines.
pub fn fieldWriteSiteRoute(self: *VmHost, receiver: *const Value, name: []const u8) ?FieldSiteClaim {
    if (receiver.* != .Instance) return null;
    const inst = receiver.Instance;
    const cls_id: usize = blk: {
        const g = inst.borrow();
        defer g.deinit();
        break :blk g.get().class.identity();
    };
    const name_p = host_call_member.memberNameIdentity(self, name) orelse return null;
    const hit = fieldWriteCacheGet(self, cls_id, name_p) orelse return null;
    if (hit.setter != root.ProgramImage.FieldWriteHit.NONE) return null;
    const g = inst.borrow();
    defer g.deinit();
    for (g.get().fields.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.name, hit.store_name)) continue;
        if (i > (std.math.maxInt(u64) >> 2)) return null;
        return .{ .cls = @intFromPtr(g.get().class.cell), .route = (@as(u64, @intCast(i)) << 2) | 1 };
    }
    return null;
}

/// The packed field-read route a `GetField` may claim for the receiver's class:
/// a stored slot index or getter FuncId plus a 2-bit verdict, from the
/// (class, name) memo, so a claim exists only where every earlier rung declined.
pub fn fieldSiteRoute(self: *VmHost, receiver: *const Value, name: []const u8) ?FieldSiteClaim {
    if (receiver.* != .Instance) return null;
    if (std.mem.eql(u8, name, "coroutineContext")) return null;
    const inst = receiver.Instance;
    const cls: u64 = @intCast(runtime.InstanceData.classIdentityUnlocked(inst));
    // The scoped-getter walk records its winner under the scoped name, so the
    // memo is probed as the read was written before the name is reduced.
    if (routeFromMemo(self, inst, cls, name)) |r| return r;
    // A property getter reading its own backing store carries the scoped name
    // `$sgetter$<owner>\u{1f}<prop>`. When the receiver is that owner, Kotlin's
    // virtual dispatch resolves the read to the plain property on its own class.
    if (std.mem.startsWith(u8, name, "$sgetter$")) {
        const rest = name["$sgetter$".len..];
        if (std.mem.findScalar(u8, rest, '\u{1f}')) |sep| {
            const owner = rest[0..sep];
            const prop = rest[sep + 1 ..];
            if (prop.len == 0) return null;
            const rcn = className(receiver.Instance);
            const owns = std.mem.eql(u8, rcn, owner) or blk: {
                const mg = self.module.borrow();
                defer mg.deinit();
                break :blk mg.get().classIsOrExtends(rcn, owner);
            };
            if (!owns) return null;
            return routeFromMemo(self, inst, cls, prop);
        }
    }
    return null;
}

/// The (class, name) memo's answer as a site route, or null when it holds none.
fn routeFromMemo(self: *VmHost, inst: ObjRef(InstanceData), cls: u64, name: []const u8) ?FieldSiteClaim {
    const hit = blk: {
        const name_p = host_call_member.memberNameIdentity(self, name) orelse {
            fsrDiag(self, inst, name, "no interned name");
            break :blk null;
        };
        break :blk fieldReadCacheGet(self, @intCast(cls), name_p);
    } orelse {
        fsrDiag(self, inst, name, "no (class, name) memo");
        return null;
    };
    const NONE = root.ProgramImage.FieldReadHit.NONE;
    if (hit.getter != NONE) return .{ .cls = cls, .route = (@as(u64, hit.getter) << 2) | 2 };
    if (hit.stored_idx != NONE) {
        // An outer-hop slot read packs [63:32] outer class identity (low 32
        // bits, exact for identity-counter values), [31:8] slot index,
        // [7:2] hop count, tag 3.
        if (hit.outer_hops != 0) {
            if (hit.stored_idx > 0xFFFFFF or hit.outer_hops > 63) return null;
            return .{ .cls = cls, .route = (@as(u64, @truncate(hit.outer_cls)) << 32) |
                (@as(u64, hit.stored_idx) << 8) | (@as(u64, hit.outer_hops) << 2) | 3 };
        }
        return .{ .cls = cls, .route = (@as(u64, hit.stored_idx) << 2) | 1 };
    }
    return null;
}

/// `KLIO_FSR_DIAG=<substring>`: why the field-site route declined for a name.
fn fsrDiag(self: *VmHost, inst: ObjRef(InstanceData), name: []const u8, why: []const u8) void {
    _ = self;
    const want = runtime.envOnce("KLIO_FSR_DIAG") orelse return;
    if (std.mem.find(u8, name, want) == null) return;
    const g = inst.borrow();
    defer g.deinit();
    const cg = g.get().class.borrow();
    defer cg.deinit();
    std.debug.print("[fsr] {s}.{s}: {s}\n", .{ cg.get().name, name, why });
}

pub fn runFieldGetter(self: *VmHost, allocator: Allocator, fid: FuncId, receiver: Value) Allocator.Error!EvalResult {
    return evalGetterTagged(self, allocator, fid, receiver, "site-memo");
}

/// Whether the getter behind a claimed route is a leaf expression: field reads and
/// arithmetic only, so running it is repeatable and the leaf evaluator may chain
/// through a property backed by another property.
pub fn fieldGetterIsLeaf(self: *VmHost, fid: FuncId) bool {
    const mptr: *const Module = self.module.asPtr();
    const f = mptr.funcById(fid) orelse return false;
    return f.leafExprBody() and funcRunsItsBody(self, fid);
}

/// Whether calling `fid` runs its lowered body; a symbol the link step settled on
/// a native binding, or one redirecting elsewhere, must not be interpreted.
pub fn hostModulePtr(self: *VmHost) *const Module {
    return self.module.asPtr();
}

pub fn funcRunsItsBody(self: *VmHost, fid: FuncId) bool {
    // A body the host fronts with a fast path runs only where the call asks
    // the fast path first, which the fused and leaf tiers do not.
    if (self.module.asPtrConst().resolved) |r| {
        if (fid.int() < r.func_try.len and r.func_try[fid.int()] != .none) return false;
    }
    const pg = self.prog.borrow();
    defer pg.deinit();
    return pg.get().resolvedNativeForm(fid) == null and
        pg.get().resolvedRedirects(fid).len == 0;
}

/// Kotlin's implicit receivers stack, so a bare name an object literal does not
/// own resolves against the receivers in scope where the literal was written,
/// which it closed over as `this` and `this@` captures. Only a miss gets here.
pub fn lexicalReceiverFallback(
    self: *VmHost,
    allocator: Allocator,
    receiver: *const Value,
    name: []const u8,
    r: EvalResult,
) Allocator.Error!EvalResult {
    if (r == .ok) return r;
    const e = r.err;
    if (e != .Unimplemented) return r;
    if (receiver.* != .Instance) return r;
    if (fldTls().anon_recv_depth >= 8) return r;
    const caps: []const InstanceData.Capture = blk: {
        const g = receiver.Instance.borrow();
        defer g.deinit();
        break :blk g.get().anon_captures;
    };
    if (caps.len == 0) return r;
    fldTls().anon_recv_depth += 1;
    defer fldTls().anon_recv_depth -= 1;
    for (caps) |c| {
        // Labelled receivers only; the plain `this` capture is the `outer` link.
        if (!std.mem.startsWith(u8, c.name, "this@")) continue;
        if (c.value == .Null or c.value == .Unit) continue;
        switch (try getField(self, allocator, &c.value, name)) {
            .ok => |v| {
                freeMissErr(allocator, e);
                return .{ .ok = v };
            },
            .err => |e2| {
                if (e2 == .Unimplemented) {
                    freeMissErr(allocator, e2);
                } else {
                    freeMissErr(allocator, e);
                    return .{ .err = e2 };
                }
            },
        }
    }
    return r;
}

/// For the loop JIT: the index of `name` in the receiver's instance field list,
/// only for a fully plain stored property with no custom accessor anywhere in
/// the hierarchy, so it serves direct reads and writes alike. Field order is
/// fixed per class, so it holds for any instance of the compiled-against class.
pub fn plainStoredFieldIndex(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) ?u32 {
    if (receiver.* != .Instance) return null;
    // Reject a custom accessor anywhere in the hierarchy, or a delegated
    // property: `by lazy` stores the delegate under the property's name.
    if (runtimeClassDelegatesProp(receiver.Instance, name)) return null;
    {
        var cur: ?[]const u8 = className(receiver.Instance);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(allocator);
        while (cur) |cn| {
            cur = null;
            if (containsStr(seen.items, cn)) break;
            seen.append(allocator, cn) catch return null;
            {
                const pg = self.prog.borrow();
                const hit = lookupPairFuncHop(self, pg.get().instance_prop_getters, cn, name) != null or
                    lookupPairFuncHop(self, pg.get().instance_prop_setters, cn, name) != null;
                pg.deinit();
                if (hit) return null;
            }
            if (delegatedPropRegistered(self, cn, name)) return null;
            cur = firstSupertype(self, cn);
        }
    }
    const g = receiver.Instance.borrow();
    defer g.deinit();
    const b = g.get();
    for (b.fields.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) return @intCast(i);
    }
    return null;
}

/// The zero a declared backing-field property of the class or an ancestor holds
/// before its initializer runs; null without one, so a `lateinit` read fails.
pub fn declaredBackingZero(self: *VmHost, receiver: *const Value, name: []const u8) ?Value {
    var cur: ?[]const u8 = className(receiver.Instance);
    var depth: usize = 0;
    while (cur) |cn| {
        depth += 1;
        if (depth > 64) break; // cycle guard, as the other hierarchy walks use
        const cg = self.classes.borrow();
        const def = cg.get().get(cn);
        if (def == null) {
            cg.deinit();
            break;
        }
        const dg = def.?.borrow();
        for (dg.get().body_properties) |bp| {
            if (!std.mem.eql(u8, bp.name, name)) continue;
            const backed = bp.has_backing and !bp.is_lateinit and !bp.is_abstract and
                bp.delegate == null and bp.getter == null;
            const zero: ?Value = if (backed) (bp.primitive_zero orelse Value.Null) else null;
            dg.deinit();
            cg.deinit();
            return zero;
        }
        const parent_name: ?[]const u8 = if (dg.get().parent) |p| blk: {
            const pg = p.borrow();
            defer pg.deinit();
            break :blk pg.get().name;
        } else null;
        dg.deinit();
        cg.deinit();
        cur = parent_name;
    }
    return null;
}

pub fn isScalarTypeName(n: []const u8) bool {
    const names = [_][]const u8{ "Int", "Long", "Double", "Float", "Boolean", "Byte", "Short", "Char" };
    for (names) |s| if (std.mem.eql(u8, n, s)) return true;
    return false;
}

/// `plainStoredFieldIndex` restricted to a non-nullable scalar field, which the
/// loop JIT requires before inlining a method that also writes a field: such a
/// read never deopts, so re-running the call cannot double an applied write.
pub fn plainStoredScalarFieldNN(self: *VmHost, allocator: Allocator, receiver: *const Value, name: []const u8) ?u32 {
    const idx = plainStoredFieldIndex(self, allocator, receiver, name) orelse return null;
    var cur: ?[]const u8 = className(receiver.Instance);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    while (cur) |cn| {
        cur = null;
        if (containsStr(seen.items, cn)) break;
        seen.append(allocator, cn) catch return null;
        const cg = self.classes.borrow();
        const def = cg.get().get(cn);
        if (def) |d| {
            const dg = d.borrow();
            defer dg.deinit();
            for (dg.get().primary_params) |p| {
                if (p.property != null and std.mem.eql(u8, p.name, name)) {
                    const nn = if (p.declared_shape) |sh| (!sh.nullable and isScalarTypeName(sh.name)) else false;
                    cg.deinit();
                    return if (nn) idx else null;
                }
            }
            for (dg.get().body_properties) |p| {
                if (std.mem.eql(u8, p.name, name)) {
                    // Non-nullable scalar by declaration or by a primitive
                    // literal initializer; `primitive_zero` covers neither.
                    const nn = p.scalar_nn or p.primitive_zero != null;
                    cg.deinit();
                    return if (nn) idx else null;
                }
            }
        }
        cg.deinit();
        cur = firstSupertype(self, cn);
    }
    return null;
}

/// Frees a discarded field-miss message: `getFieldInner` allocates a
/// `Vm::get_field ...` string the fallbacks drop while probing the next receiver,
/// and the prefix keeps static literals unfreed.
pub fn freeFieldMiss(allocator: Allocator, e: EvalError) void {
    if (!runtime.freeScratch()) return;
    if (e == .Unimplemented and std.mem.startsWith(u8, e.Unimplemented, "Vm::get_field")) {
        allocator.free(e.Unimplemented);
    }
}

/// Properties a builtin receiver declares as members, unlike stdlib extension
/// properties such as `indices`, which a user extension may shadow.
pub fn builtinMemberProperty(receiver: *const Value, name: []const u8) bool {
    return switch (receiver.*) {
        .Array => std.mem.eql(u8, name, "size"),
        .List, .Set => std.mem.eql(u8, name, "size"),
        .Map => std.mem.eql(u8, name, "size") or
            std.mem.eql(u8, name, "keys") or
            std.mem.eql(u8, name, "values") or
            std.mem.eql(u8, name, "entries"),
        .String => std.mem.eql(u8, name, "length"),
        else => false,
    };
}

/// Fills the companion-or-self memo; its copy is retained for the class's life.
pub fn fillCompanionReadMemo(cls: ObjRef(ClassDef), v: Value) void {
    const g = cls.borrow();
    defer g.deinit();
    const d = @constCast(g.get());
    if (d.companion_read_state.load(.monotonic) != 0) return;
    if (runtime.reclaimEnabled()) v.retain();
    d.companion_read_value = v;
    d.companion_read_state.store(2, .release);
}
