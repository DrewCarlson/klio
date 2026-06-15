//! Lexical environment: a scope of named bindings with a parent chain.
//!
//! `Env` is shared and interior-mutable in the runtime (the Rust type is
//! reached through `ObjRef<Env>`), so the parent link is `?ObjRef(Env)`.

const std = @import("std");
const objcell = @import("objcell.zig");
const value_mod = @import("value.zig");

const ObjRef = objcell.ObjRef;
const Value = value_mod.Value;
const RuntimeError = value_mod.RuntimeError;

/// A scope of name -> `Value` bindings plus an optional parent scope.
pub const Env = struct {
    parent: ?ObjRef(Env) = null,
    vars: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Env {
        return .{ .parent = null, .vars = std.StringHashMap(Value).init(allocator) };
    }

    pub fn withParent(allocator: std.mem.Allocator, parent: ObjRef(Env)) Env {
        return .{ .parent = parent, .vars = std.StringHashMap(Value).init(allocator) };
    }

    pub fn deinit(self: *Env) void {
        self.vars.deinit();
        if (self.parent) |p| p.deinit();
    }

    /// GC tracer: an env references its parent cell and owns one ref per bound
    /// value.
    pub fn gcTrace(self: *const Env, m: *objcell.gc.Marker) void {
        if (self.parent) |p| m.shade(&p.cell.hdr);
        var it = self.vars.valueIterator();
        while (it.next()) |v| v.gcMark(m);
    }

    /// GC finalizer (shallow): free only the binding map's spine. The bound
    /// values and the parent are independent cells swept on their own.
    pub fn gcFinalize(self: *Env, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.vars.deinit();
    }

    pub fn define(self: *Env, name: []const u8, value: Value) !void {
        try self.vars.put(name, value);
    }

    /// Remove a binding from this scope (does not touch parent scopes).
    pub fn removeLocal(self: *Env, name: []const u8) void {
        _ = self.vars.remove(name);
    }

    pub fn lookup(self: *const Env, name: []const u8) ?Value {
        if (self.vars.get(name)) |v| return v;
        const parent = self.parent orelse return null;
        const g = parent.borrow();
        defer g.deinit();
        return g.get().lookup(name);
    }

    /// Look up `name` in this scope only, skipping the parent chain.
    pub fn lookupLocal(self: *const Env, name: []const u8) ?Value {
        return self.vars.get(name);
    }

    /// True when this env is a child scope (has a parent).
    pub fn hasParent(self: *const Env) bool {
        return self.parent != null;
    }

    /// Resolve `name` ignoring any binding that lives in `stop_at`
    /// (compared by backing-cell identity).
    pub fn lookupExcluding(self: *const Env, name: []const u8, stop_at: ObjRef(Env)) ?Value {
        if (self.vars.get(name)) |v| return v;
        const parent = self.parent orelse return null;
        if (ObjRef(Env).ptrEq(parent, stop_at)) return null;
        const g = parent.borrow();
        defer g.deinit();
        return g.get().lookupExcluding(name, stop_at);
    }

    /// Collect every value bound under `name` walking inside-out.
    /// Caller owns the returned slice.
    pub fn lookupAll(self: *const Env, allocator: std.mem.Allocator, name: []const u8) ![]Value {
        var out: std.ArrayList(Value) = .empty;
        errdefer out.deinit(allocator);
        try self.lookupAllInto(allocator, name, &out);
        return out.toOwnedSlice(allocator);
    }

    fn lookupAllInto(self: *const Env, allocator: std.mem.Allocator, name: []const u8, out: *std.ArrayList(Value)) !void {
        if (self.vars.get(name)) |v| try out.append(allocator, v);
        if (self.parent) |p| {
            const g = p.borrow();
            defer g.deinit();
            try g.get().lookupAllInto(allocator, name, out);
        }
    }

    /// A value paired with the scope depth (0 = innermost) it was bound at.
    pub const DepthValue = struct { value: Value, depth: usize };

    /// Look up `name` and return the scope depth (0 = innermost) where it
    /// was found, along with the value.
    pub fn lookupWithDepth(self: *const Env, name: []const u8) ?DepthValue {
        if (self.vars.get(name)) |v| return .{ .value = v, .depth = 0 };
        const parent = self.parent orelse return null;
        const g = parent.borrow();
        defer g.deinit();
        const inner = g.get().lookupWithDepth(name) orelse return null;
        return .{ .value = inner.value, .depth = inner.depth + 1 };
    }

    /// Like `lookupAll` but pairs each value with its scope depth.
    /// Caller owns the returned slice.
    pub fn lookupAllWithDepth(self: *const Env, allocator: std.mem.Allocator, name: []const u8) ![]DepthValue {
        var out: std.ArrayList(DepthValue) = .empty;
        errdefer out.deinit(allocator);
        try self.lookupAllWithDepthInto(allocator, name, 0, &out);
        return out.toOwnedSlice(allocator);
    }

    fn lookupAllWithDepthInto(self: *const Env, allocator: std.mem.Allocator, name: []const u8, depth: usize, out: *std.ArrayList(DepthValue)) !void {
        if (self.vars.get(name)) |v| try out.append(allocator, .{ .value = v, .depth = depth });
        if (self.parent) |p| {
            const g = p.borrow();
            defer g.deinit();
            try g.get().lookupAllWithDepthInto(allocator, name, depth + 1, out);
        }
    }

    /// Assign to an existing binding, walking the parent chain. Returns
    /// `null` on success or a `RuntimeError.Unbound` data value when the
    /// name resolves nowhere (RuntimeError is data, not a Zig error).
    pub fn assign(self: *Env, name: []const u8, value: Value) ?RuntimeError {
        if (self.vars.getPtr(name)) |slot| {
            slot.* = value;
            return null;
        }
        if (self.parent) |p| {
            const g = p.borrowMut();
            defer g.deinit();
            return g.get().assign(name, value);
        }
        return .{ .Unbound = name };
    }
};

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

const testing = std.testing;

test "define and lookup in a single scope" {
    var env = Env.init(testing.allocator);
    defer env.deinit();

    try env.define("x", .{ .Int = 1 });
    try testing.expect(env.lookup("x").? == .Int);
    try testing.expectEqual(@as(i32, 1), env.lookup("x").?.Int);
    try testing.expect(env.lookup("missing") == null);
}

test "lookup walks the parent chain" {
    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();
    {
        const g = parent.borrowMut();
        defer g.deinit();
        try g.get().define("outer", .{ .Int = 10 });
    }

    var child = Env.withParent(testing.allocator, parent.clone());
    defer child.deinit();
    try child.define("inner", .{ .Int = 20 });

    try testing.expectEqual(@as(i32, 20), child.lookup("inner").?.Int);
    try testing.expectEqual(@as(i32, 10), child.lookup("outer").?.Int);
    try testing.expect(child.lookup("nope") == null);
}

test "lookupLocal ignores the parent chain" {
    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();
    {
        const g = parent.borrowMut();
        defer g.deinit();
        try g.get().define("outer", .{ .Int = 10 });
    }

    var child = Env.withParent(testing.allocator, parent.clone());
    defer child.deinit();
    try child.define("inner", .{ .Int = 20 });

    try testing.expectEqual(@as(i32, 20), child.lookupLocal("inner").?.Int);
    try testing.expect(child.lookupLocal("outer") == null);
}

test "hasParent distinguishes base and child scopes" {
    var base = Env.init(testing.allocator);
    defer base.deinit();
    try testing.expect(!base.hasParent());

    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();
    var child = Env.withParent(testing.allocator, parent.clone());
    defer child.deinit();
    try testing.expect(child.hasParent());
}

test "removeLocal drops only the local binding" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try env.define("x", .{ .Int = 1 });
    env.removeLocal("x");
    try testing.expect(env.lookup("x") == null);
    // Removing a missing name is harmless.
    env.removeLocal("y");
}

test "lookupExcluding skips a stop-at scope" {
    const prelude = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer prelude.deinit();
    {
        const g = prelude.borrowMut();
        defer g.deinit();
        try g.get().define("name", .{ .Int = 99 });
    }

    // A child whose parent is the prelude: the prelude binding is excluded.
    var child = Env.withParent(testing.allocator, prelude.clone());
    defer child.deinit();
    try testing.expect(child.lookupExcluding("name", prelude) == null);

    // A local binding shadows the excluded parent and is returned.
    try child.define("name", .{ .Int = 7 });
    try testing.expectEqual(@as(i32, 7), child.lookupExcluding("name", prelude).?.Int);
}

test "lookupAll collects inside-out" {
    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();
    {
        const g = parent.borrowMut();
        defer g.deinit();
        try g.get().define("this", .{ .Int = 1 });
    }

    var child = Env.withParent(testing.allocator, parent.clone());
    defer child.deinit();
    try child.define("this", .{ .Int = 2 });

    const all = try child.lookupAll(testing.allocator, "this");
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(@as(i32, 2), all[0].Int);
    try testing.expectEqual(@as(i32, 1), all[1].Int);
}

test "lookupWithDepth reports the binding depth" {
    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();
    {
        const g = parent.borrowMut();
        defer g.deinit();
        try g.get().define("x", .{ .Int = 10 });
    }

    var child = Env.withParent(testing.allocator, parent.clone());
    defer child.deinit();
    try child.define("y", .{ .Int = 20 });

    const fy = child.lookupWithDepth("y").?;
    try testing.expectEqual(@as(usize, 0), fy.depth);
    try testing.expectEqual(@as(i32, 20), fy.value.Int);

    const fx = child.lookupWithDepth("x").?;
    try testing.expectEqual(@as(usize, 1), fx.depth);
    try testing.expectEqual(@as(i32, 10), fx.value.Int);

    try testing.expect(child.lookupWithDepth("z") == null);
}

test "lookupAllWithDepth pairs values with depth" {
    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();
    {
        const g = parent.borrowMut();
        defer g.deinit();
        try g.get().define("this", .{ .Int = 1 });
    }

    var child = Env.withParent(testing.allocator, parent.clone());
    defer child.deinit();
    try child.define("this", .{ .Int = 2 });

    const all = try child.lookupAllWithDepth(testing.allocator, "this");
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(@as(usize, 0), all[0].depth);
    try testing.expectEqual(@as(i32, 2), all[0].value.Int);
    try testing.expectEqual(@as(usize, 1), all[1].depth);
    try testing.expectEqual(@as(i32, 1), all[1].value.Int);
}

test "assign updates an existing binding and walks parents" {
    const parent = try ObjRef(Env).init(testing.allocator, Env.init(testing.allocator));
    defer parent.deinit();
    {
        const g = parent.borrowMut();
        defer g.deinit();
        try g.get().define("outer", .{ .Int = 1 });
    }

    var child = Env.withParent(testing.allocator, parent.clone());
    defer child.deinit();
    try child.define("inner", .{ .Int = 2 });

    try testing.expect(child.assign("inner", .{ .Int = 22 }) == null);
    try testing.expectEqual(@as(i32, 22), child.lookup("inner").?.Int);

    try testing.expect(child.assign("outer", .{ .Int = 11 }) == null);
    try testing.expectEqual(@as(i32, 11), child.lookup("outer").?.Int);
}

test "assign to an unbound name yields a RuntimeError" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    const err = env.assign("ghost", .{ .Int = 1 }).?;
    try testing.expect(err == .Unbound);
    try testing.expectEqualStrings("ghost", err.Unbound);
}
