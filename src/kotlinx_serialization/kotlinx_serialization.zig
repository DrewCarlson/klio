//! Native bindings for `kotlinx-serialization-core`.
//!
//! kotlinx-serialization's compiler plugin synthesizes a `KSerializer` for every
//! `@Serializable` class; klio's `serialization_pass` generates the same
//! declarations as ordinary Kotlin before lowering. The only host help left is
//! the lookup the platform actuals need, the equivalent of Kotlin/Native's
//! `findAssociatedObject`: `__klsx_companionSerializer(kClass, args)` invokes the
//! class's generated companion `serializer(args...)`, and
//! `__klsx_isInterfaceClass(kClass)` is the `KClass.isInterface()` actual.

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const ClassDef = runtime.ClassDef;
const ObjRef = runtime.ObjRef;
const HostBindings = stdlib.HostBindings;

const Error = std.mem.Allocator.Error;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("kotlinx.serialization.__klsx_companionSerializer", companionSerializer);
    try b.register("kotlinx.serialization.__klsx_isInterfaceClass", isInterfaceClass);
    return b;
}

fn classOf(v: *const Value) ?ObjRef(ClassDef) {
    return switch (v.*) {
        .Class => |c| c.clone(),
        .Instance => |inst| blk: {
            const g = inst.borrow();
            const c = g.get().class.clone();
            g.deinit();
            break :blk c;
        },
        else => null,
    };
}

/// The serializer a class's companion (or an object itself) generates, with
/// the type-argument serializers. The VM answers the call from its tables
/// (`ir.resolved.HostOp.generated_serializer`) before this body runs, so
/// a host without them finds none.
fn companionSerializer(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(.Null);
}

fn isInterfaceClass(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(.{ .Bool = false });
    const cls_ref = classOf(&ctx.args[0]) orelse return ok(.{ .Bool = false });
    defer cls_ref.deinit();
    return ok(.{ .Bool = cls_ref.asPtr().is_interface });
}

test "hostBindings registers the two lookup intrinsics" {
    var b = try hostBindings(std.testing.allocator);
    defer b.deinit();
    try std.testing.expect(b.resolve("kotlinx.serialization.__klsx_companionSerializer") != null);
    try std.testing.expect(b.resolve("kotlinx.serialization.__klsx_isInterfaceClass") != null);
}
