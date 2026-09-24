//! Shared instance-construction pieces: the constructor guard, argument-head
//! hints, the enum-entry preset, and the anonymous-object site caches.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");
const ast = @import("ast");
const stdlib = @import("stdlib");

const root = @import("../../interp_ir.zig");
const vmhost = @import("../vmhost.zig");
const host_globals = @import("../host_globals.zig");
const host_classes = @import("../host_classes.zig");
const host_call_func = @import("../host_call_func.zig");
const host_call_member = @import("../host_call_member.zig");
const host_fields = @import("../host_fields.zig");
const host_call_value = @import("../host_call_value.zig");
const VmHost = vmhost.VmHost;
const VmIntrinsicHost = vmhost.VmIntrinsicHost;

const tables = @import("../../tables.zig");
const FF = runtime.forest.ForestField;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const ObjRef = runtime.ObjRef;
const InstanceData = runtime.InstanceData;
const ClassDef = runtime.ClassDef;
const Env = runtime.Env;
const PropertyDef = runtime.PropertyDef;
const MethodDef = runtime.MethodDef;
const SupertypeDelegate = runtime.SupertypeDelegate;
const TypeShape = runtime.TypeShape;
const StdlibFn = runtime.StdlibFn;
const CallCtx = runtime.CallCtx;
const Module = ir.Module;
const ClassId = ir.ClassId;
const FuncId = ir.FuncId;
const TypeRef = ir.TypeRef;
const EvalResult = ir.eval.EvalResult;
const EvalError = ir.eval.EvalError;
const StrPair = ir.StrPair;
const StringSet = runtime.NameHashMap(void);
const AnonMethodEntry = root.AnonMethodEntry;
const NameValue = root.NameValue;

pub fn unsupported(name: []const u8) EvalResult {
    return .{ .err = .{ .Unsupported = name } };
}

pub fn typeErr(allocator: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!EvalError {
    return .{ .Type = try std.fmt.allocPrint(allocator, fmt, args) };
}

// Breaks same-class shell recursion during secondary-ctor dispatch; lazy
// `object` re-entrancy uses the object-init state table in `host_globals.zig`.

pub threadlocal var ctor_guard: std.ArrayList([]const u8) = .empty;

/// `name`/`ordinal` for the enum-entry subclass about to be constructed;
/// Kotlin's `Enum` constructor sets them before the entry's own initializers
/// and `init` blocks run. Materialization consumes it once and fills `slot`.
pub const EnumEntryPreset = struct { class_fqn: []const u8, name: Value, ordinal: Value, slot: ?*Value = null };

pub threadlocal var enum_entry_preset: ?EnumEntryPreset = null;

/// The enum whose entries are being constructed: its companion initializes
/// only after every entry exists, so the first entry must not trigger it.
pub threadlocal var enum_under_init: ?[]const u8 = null;

pub fn setEnumUnderInit(fqn: ?[]const u8) ?[]const u8 {
    const prev = enum_under_init;
    enum_under_init = fqn;
    return prev;
}

pub fn setEnumEntryPreset(p: ?EnumEntryPreset) void {
    enum_entry_preset = p;
}

pub fn resetReceiverTls() void {
    std.debug.assert(ctor_guard.items.len == 0);
    ctor_guard.clearRetainingCapacity();
}

pub fn ctorGuardContains(name: []const u8) bool {
    for (ctor_guard.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

pub fn ctorGuardPush(name: []const u8) void {
    ctor_guard.append(std.heap.page_allocator, name) catch {};
}

pub fn ctorGuardPop() void {
    _ = ctor_guard.pop();
}

/// Static argument heads the current construction site supplied, consumed once:
/// a delegation or default thunk builds further instances and ranks on its own.
pub threadlocal var ctor_static_heads: ?[]const ?[]const u8 = null;

/// Heads live in a thread-owned buffer: the array a site hands over is freed
/// when the site returns. A site with more arguments ranks without static heads.
pub const CTOR_HEADS_MAX = 32;

pub threadlocal var ctor_static_heads_buf: [CTOR_HEADS_MAX]?[]const u8 = undefined;

pub fn setCtorArgStaticHeads(self: *VmHost, heads: []const ?[]const u8) void {
    _ = self;
    if (heads.len == 0 or heads.len > CTOR_HEADS_MAX) {
        ctor_static_heads = null;
        return;
    }
    @memcpy(ctor_static_heads_buf[0..heads.len], heads);
    ctor_static_heads = ctor_static_heads_buf[0..heads.len];
}

/// The constructor the SITE named, consumed by the construction it belongs to
/// the way the heads are: a delegation or default underneath builds its own
/// instances and must not inherit this site's answer.
///
/// The argument count travels with it. A construction the site did not emit —
/// an intrinsic route that returns before consuming, a delegation, a default
/// thunk — would otherwise take an answer meant for a different call, and the
/// count is the cheapest thing that catches it.
pub const CtorSitePick = struct { pick: u16, n_args: u32 };

pub threadlocal var ctor_site_pick: ?CtorSitePick = null;

pub fn setCtorSitePick(self: *VmHost, pick: ?u16, n_args: u32) void {
    _ = self;
    ctor_site_pick = if (pick) |p| .{ .pick = p, .n_args = n_args } else null;
}

pub fn takeCtorSitePick(n_args: usize) ?u16 {
    const v = ctor_site_pick orelse return null;
    ctor_site_pick = null;
    if (v.n_args != n_args) return null;
    return v.pick;
}

/// Forget heads left installed by a path that never took them: the slice they
/// name is freed when the site returns.
pub fn clearCtorArgStaticHeads(self: *VmHost) void {
    _ = self;
    ctor_static_heads = null;
    ctor_site_pick = null;
}

/// Type-parameter bounds of the class under construction, so a constructor
/// parameter declared as a class type parameter ranks as its bound.
pub const CtorBounds = struct { names: []const []const u8, bounds: []const []const u8 };

pub threadlocal var ctor_bounds: ?CtorBounds = null;

pub fn installCtorBounds(class_def: ObjRef(ClassDef)) ?CtorBounds {
    const prev = ctor_bounds;
    const g = class_def.borrow();
    defer g.deinit();
    const d = g.get();
    ctor_bounds = if (d.type_params.len != 0 and d.type_param_bounds.len != 0)
        .{ .names = d.type_params, .bounds = d.type_param_bounds }
    else
        null;
    return prev;
}

/// `declared` with a class type parameter replaced by the head of its bound.
pub fn boundHead(declared: []const u8) []const u8 {
    const cb = ctor_bounds orelse return declared;
    for (cb.names, 0..) |n, i| {
        if (i >= cb.bounds.len) break;
        if (std.mem.eql(u8, n, declared) and cb.bounds[i].len != 0) return cb.bounds[i];
    }
    return declared;
}

pub fn takeCtorStaticHeads() ?[]const ?[]const u8 {
    const v = ctor_static_heads;
    ctor_static_heads = null;
    return v;
}
