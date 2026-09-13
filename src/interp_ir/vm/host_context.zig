//! Context-parameter resolution stack: a thread-local stack of in-scope values from
//! `context(...)` and implicit receivers, read nearest-first by runtime type.
//! Typeck enforces the ambiguity and absence rules.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const VmHost = @import("vmhost.zig").VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const TypeRef = ir.TypeRef;

/// In-scope context values, innermost last; resolution never crosses a thread.
threadlocal var stack: std.ArrayListUnmanaged(Value) = .empty;

/// Latched once the module declares a context parameter, so hot dispatch skips the push.
threadlocal var active: bool = false;

pub fn ctxActivate(_: *VmHost, on: bool) void {
    if (on) active = true;
}

pub fn ctxIsActive(_: *VmHost) bool {
    return active;
}

pub fn ctxStackLen(_: *VmHost) usize {
    return stack.items.len;
}

pub fn ctxPush(self: *VmHost, v: Value) Allocator.Error!void {
    v.retain();
    try stack.append(self.allocator, v);
}

pub fn ctxStackTruncate(self: *VmHost, mark: usize) void {
    while (stack.items.len > mark) {
        const v = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        if (runtime.reclaimEnabled()) v.release(self.allocator);
    }
}

/// Nearest in-scope context value whose runtime type is a subtype of `ty_name`, or null
/// when none is. `erased` (a generic context type or `*` argument) takes the innermost.
pub fn ctxResolve(self: *VmHost, ty_name: []const u8, erased: bool) ?Value {
    const want = TypeRef{ .name = ty_name, .nullable = false, .args = &.{} };
    var i = stack.items.len;
    while (i > 0) {
        i -= 1;
        const v = stack.items[i];
        if (erased) return v;
        if (self.instanceOf(&v, want)) return v;
    }
    // Not a `context(...)` value: fall back to the innermost enclosing or spliced
    // receiver of that type.
    var chain = ir.eval.enclosingChainIter();
    while (chain.next()) |v| {
        if (erased) return v;
        if (self.instanceOf(&v, want)) return v;
    }
    return null;
}
