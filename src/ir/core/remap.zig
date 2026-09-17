//! Renumbering of the ids a lowered function carries, for bodies lowered on
//! a shard whose lambda and constant ids were allocated locally.

const std = @import("std");
const span = @import("span");
const core_ids = @import("ids.zig");
const core_func = @import("func.zig");

const ConstId = core_ids.ConstId;
const FuncId = core_ids.FuncId;
const TypeRef = core_ids.TypeRef;

/// Ids at or past a base map through the tables; the rest are the module's own.
pub const IdMap = struct {
    func_base: u32,
    funcs: []const FuncId,
    const_base: u32,
    consts: []const ConstId,

    fn mapFunc(self: *const IdMap, id: FuncId) FuncId {
        const i = id.int();
        if (i < self.func_base) return id;
        return self.funcs[i - self.func_base];
    }

    fn mapConst(self: *const IdMap, id: ConstId) ConstId {
        const i = id.int();
        if (i < self.const_base) return id;
        return self.consts[i - self.const_base];
    }
};

/// Rewrites every FuncId and ConstId reachable from `f` in place. Single
/// pointers are not followed: they lead to the AST and the module, which the
/// function only references.
pub fn remapFunc(f: *core_func.Func, m: *const IdMap) void {
    walk(core_func.Func, f, m);
}

fn walk(comptime T: type, v: *T, m: *const IdMap) void {
    if (T == FuncId) {
        v.* = m.mapFunc(v.*);
        return;
    }
    if (T == ConstId) {
        v.* = m.mapConst(v.*);
        return;
    }
    if (T == TypeRef or T == span.Span) return;
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            inline for (st.fields) |fld| {
                if (fld.is_comptime) continue;
                walk(fld.type, &@field(v.*, fld.name), m);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) return;
            switch (v.*) {
                inline else => |*payload| walk(@TypeOf(payload.*), payload, m),
            }
        },
        .optional => |o| {
            if (v.*) |*inner| walk(o.child, inner, m);
        },
        .array => |arr| {
            for (v) |*e| walk(arr.child, e, m);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return;
                for (v.*) |*e| walk(p.child, @constCast(e), m);
            },
            else => {},
        },
        else => {},
    }
}

/// A hash of every value a lowered function carries, pointers excluded, so
/// two lowerings of one body can be compared without their addresses.
pub fn semanticHash(f: *const core_func.Func) u64 {
    var h = std.hash.Wyhash.init(0);
    hashWalk(core_func.Func, f, &h);
    return h.final();
}

fn hashWalk(comptime T: type, v: *const T, h: *std.hash.Wyhash) void {
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            inline for (st.fields) |fld| {
                if (fld.is_comptime) continue;
                hashWalk(fld.type, &@field(v.*, fld.name), h);
            }
        },
        .@"union" => |u| {
            if (u.tag_type == null) return;
            h.update(std.mem.asBytes(&@intFromEnum(std.meta.activeTag(v.*))));
            switch (v.*) {
                inline else => |*payload| hashWalk(@TypeOf(payload.*), payload, h),
            }
        },
        .optional => |o| {
            if (v.*) |*inner| {
                h.update("some");
                hashWalk(o.child, inner, h);
            } else h.update("none");
        },
        .array => |arr| for (v) |*e| hashWalk(arr.child, e, h),
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) {
                    h.update(v.*);
                    h.update("|");
                } else for (v.*) |*e| hashWalk(p.child, e, h);
            },
            else => {},
        },
        .int, .float, .bool, .@"enum" => h.update(std.mem.asBytes(v)),
        else => {},
    }
}

test "ids below the base are untouched and the rest map through the tables" {
    const funcs = [_]FuncId{ FuncId.from(40), FuncId.from(41) };
    const consts = [_]ConstId{ConstId.from(9)};
    const m = IdMap{ .func_base = 10, .funcs = &funcs, .const_base = 3, .consts = &consts };
    try std.testing.expectEqual(FuncId.from(7), m.mapFunc(FuncId.from(7)));
    try std.testing.expectEqual(FuncId.from(41), m.mapFunc(FuncId.from(11)));
    try std.testing.expectEqual(ConstId.from(2), m.mapConst(ConstId.from(2)));
    try std.testing.expectEqual(ConstId.from(9), m.mapConst(ConstId.from(3)));
}
