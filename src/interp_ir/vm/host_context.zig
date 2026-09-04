//! Context-parameter resolution stack for the VM.
//!
//! A thread-local stack of in-scope context values (introduced by the
//! stdlib `context(...)` scope function and by implicit receivers). A
//! contextual declaration's body loads each of its context parameters
//! from the nearest compatible value on this stack (`CtxLoad`), and
//! `contextOf<T>()` reads it directly. Resolution is nearest-first by the
//! value's runtime type; the static ambiguity/absence rules are enforced
//! separately by typeck.
//!
//! Free functions over `*VmHost`, aliased as `VmHost` methods by
//! `vmhost.zig` and invoked by the generic IR evaluator.

const std = @import("std");

const ir = @import("ir");
const runtime = @import("runtime");

const VmHost = @import("vmhost.zig").VmHost;

const Allocator = std.mem.Allocator;
const Value = runtime.Value;
const TypeRef = ir.TypeRef;

/// In-scope context values, innermost last. Thread-local: context
/// resolution never crosses a thread boundary in the shipped surface.
threadlocal var stack: std.ArrayListUnmanaged(Value) = .empty;

/// Latched once the running module declares any context parameter. Lets
/// hot receiver-lambda dispatch skip the context-stack push in the common
/// (non-contextual) case without borrowing the module handle per call.
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

/// Nearest in-scope context value whose runtime type is a subtype of
/// `ty_name`. `erased` (a generic context-parameter type, or a `*` type
/// argument) returns the innermost value unconditionally. Returns null
/// when nothing compatible is in scope.
pub fn ctxResolve(self: *VmHost, ty_name: []const u8, erased: bool) ?Value {
    const want = TypeRef{ .name = ty_name, .nullable = false, .args = &.{} };
    var i = stack.items.len;
    while (i > 0) {
        i -= 1;
        const v = stack.items[i];
        if (erased) return v;
        if (self.instanceOf(&v, want)) return v;
    }
    // Not a `context(...)` scope value: the innermost enclosing receiver or
    // spliced receiver-lambda subject of that type (`with(3) { context("u")
    // { f(true) } }` reads 3 for the Int context).
    var chain = ir.eval.enclosingChainIter();
    while (chain.next()) |v| {
        if (erased) return v;
        if (self.instanceOf(&v, want)) return v;
    }
    return null;
}
