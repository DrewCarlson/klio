//! Native bindings for `kotlinx-serialization-core`.
//!
//! kotlinx-serialization's compiler plugin synthesizes a `KSerializer` for
//! every `@Serializable` class; klio's `serialization_pass` generates the
//! same declarations as ordinary Kotlin before lowering. The only host help
//! left is the LOOKUP the platform actuals need — the equivalent of
//! Kotlin/Native's `findAssociatedObject` / the JVM's reflective
//! `Companion.serializer()` call:
//!
//! - `__klsx_companionSerializer(kClass, args)` — invoke the class's
//!   companion `serializer(args...)` (the generated member), or null when
//!   the class has no companion serializer.
//! - `__klsx_isInterfaceClass(kClass)` — the `KClass.isInterface()` actual.
//!
//! Everything else in serialization-core (and the JSON format) is pure
//! Kotlin consumed straight from the upstream submodule.

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

/// `__klsx_companionSerializer(kClass, args: List<KSerializer<*>>)`: read
/// the class's `Companion` (initializing it) and call its generated
/// `serializer(...)` with the type-argument serializers. An `object`
/// carries `serializer()` on itself. Null when neither resolves.
fn companionSerializer(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len == 0) return ok(.Null);
    const cls_val = ctx.args[0];
    if (cls_val != .Class) return ok(.Null);
    var args: std.ArrayList(Value) = .empty;
    defer args.deinit(ctx.allocator);
    if (ctx.args.len > 1 and ctx.args[1] == .List) {
        const g = ctx.args[1].List.items.borrow();
        defer g.deinit();
        for (g.get().items) |v| try args.append(ctx.allocator, v);
    }
    const is_object = blk: {
        const g = cls_val.Class.borrow();
        defer g.deinit();
        break :blk g.get().is_object;
    };
    if (is_object) {
        const inst = (try ctx.host.getProperty(&cls_val, "objectInstance", ctx.out)) orelse return ok(.Null);
        if (inst != .ok) return ok(.Null);
        const r = (try ctx.host.invokeMethod(&inst.ok, "serializer", args.items, ctx.out)) orelse return ok(.Null);
        return r;
    }
    const comp = (try ctx.host.getProperty(&cls_val, "Companion", ctx.out)) orelse return ok(.Null);
    if (comp != .ok) return ok(.Null);
    if (comp.ok == .Null) return ok(.Null);
    const r = (try ctx.host.invokeMethod(&comp.ok, "serializer", args.items, ctx.out)) orelse return ok(.Null);
    return r;
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
