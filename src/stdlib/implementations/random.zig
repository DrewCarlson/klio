//! Native XorWowRandom core. The Kotlin source implementation runs the xorwow
//! step and the `nextInt(bound)` rejection loop through the interpreter, which
//! makes RNG-heavy programs pathologically slow (~tens of microseconds per
//! draw). These bindings run the same algorithm in Zig against the receiver's
//! instance fields, keeping bit-for-bit parity with `XorWowRandom`.

const std = @import("std");
const runtime = @import("runtime");

const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const InstanceData = runtime.InstanceData;
const Allocator = std.mem.Allocator;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

fn fieldI32(inst: *const InstanceData, name: []const u8) i32 {
    if (inst.get(name)) |v| {
        if (v.asI64()) |x| return @truncate(x);
    }
    return 0;
}

/// One xorwow step: mutates the six state fields in place and returns the draw,
/// identical to `XorWowRandom.nextInt()`.
fn xorwowStep(inst: *InstanceData) i32 {
    var x: u32 = @bitCast(fieldI32(inst, "x"));
    const y: u32 = @bitCast(fieldI32(inst, "y"));
    const z: u32 = @bitCast(fieldI32(inst, "z"));
    const w: u32 = @bitCast(fieldI32(inst, "w"));
    const v: u32 = @bitCast(fieldI32(inst, "v"));
    var addend: u32 = @bitCast(fieldI32(inst, "addend"));

    var t = x;
    t = t ^ (t >> 2);
    x = y;
    const new_y = z;
    const new_z = w;
    const v0 = v;
    const new_w = v0;
    t = (t ^ (t << 1)) ^ v0 ^ (v0 << 4);
    const new_v = t;
    addend +%= 362437;

    _ = inst.set("x", .{ .Int = @bitCast(x) });
    _ = inst.set("y", .{ .Int = @bitCast(new_y) });
    _ = inst.set("z", .{ .Int = @bitCast(new_z) });
    _ = inst.set("w", .{ .Int = @bitCast(new_w) });
    _ = inst.set("v", .{ .Int = @bitCast(new_v) });
    _ = inst.set("addend", .{ .Int = @bitCast(addend) });

    return @bitCast(t +% addend);
}

/// `Int.takeUpperBits(bitCount)` — the high `bitCount` bits, 0 when bitCount is 0.
fn takeUpperBits(value: i32, bit_count: i32) i32 {
    if (bit_count <= 0) return 0;
    if (bit_count >= 32) return value;
    const u: u32 = @bitCast(value);
    const shift: u5 = @intCast(32 - bit_count);
    return @bitCast(u >> shift);
}

fn nextBitsFor(inst: *InstanceData, bit_count: i32) i32 {
    return takeUpperBits(xorwowStep(inst), bit_count);
}

/// `nextInt(from, until)` over the live instance, mirroring kotlin-stdlib's
/// power-of-two / rejection-sampling split.
fn nextIntRange(inst: *InstanceData, from: i32, until: i32) i32 {
    const n: i32 = until -% from;
    if (n > 0 or n == std.math.minInt(i32)) {
        var rnd: i32 = undefined;
        if ((n & -%n) == n) {
            const bit_count: i32 = 31 - @as(i32, @clz(@as(u32, @bitCast(n))));
            rnd = nextBitsFor(inst, bit_count);
        } else {
            var v: i32 = undefined;
            while (true) {
                const bits: i32 = @bitCast(@as(u32, @bitCast(xorwowStep(inst))) >> 1);
                v = @rem(bits, n);
                if (bits -% v +% (n -% 1) >= 0) break;
            }
            rnd = v;
        }
        return from +% rnd;
    }
    while (true) {
        const rnd = xorwowStep(inst);
        if (rnd >= from and rnd < until) return rnd;
    }
}

pub fn random_next_int(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len == 0 or ctx.args[0] != .Instance) {
        return .{ .err = .{ .Type = "nextInt requires an XorWowRandom receiver" } };
    }
    const g = ctx.args[0].Instance.borrowMut();
    defer g.deinit();
    const inst = g.get();
    const rest = ctx.args[1..];
    if (rest.len == 0) return ok(.{ .Int = xorwowStep(inst) });
    if (rest.len == 1 and rest[0] == .Range) {
        // `nextInt(range: IntRange)` — `range.last + 1` can overflow, so split
        // the boundary cases exactly as kotlin-stdlib does.
        const r = rest[0].Range;
        const first: i32 = @truncate(r.start);
        const last: i32 = @truncate(r.end);
        if (first > last) return badBound(ctx.allocator, "nextInt");
        if (last < std.math.maxInt(i32)) return ok(.{ .Int = nextIntRange(inst, first, last + 1) });
        if (first > std.math.minInt(i32)) return ok(.{ .Int = nextIntRange(inst, first - 1, last) +% 1 });
        return ok(.{ .Int = xorwowStep(inst) });
    }
    if (rest.len == 1) {
        const until = rest[0].asI64() orelse return .{ .err = .{ .Type = "nextInt bound must be an Int" } };
        if (until <= 0) return badBound(ctx.allocator, "nextInt");
        return ok(.{ .Int = nextIntRange(inst, 0, @truncate(until)) });
    }
    const from = rest[0].asI64() orelse return .{ .err = .{ .Type = "nextInt from must be an Int" } };
    const until = rest[1].asI64() orelse return .{ .err = .{ .Type = "nextInt until must be an Int" } };
    if (from >= until) return badBound(ctx.allocator, "nextInt");
    return ok(.{ .Int = nextIntRange(inst, @truncate(from), @truncate(until)) });
}

pub fn random_next_bits(ctx: *CallCtx) Allocator.Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .Instance) {
        return .{ .err = .{ .Type = "nextBits requires an XorWowRandom receiver and a bit count" } };
    }
    const bit_count = ctx.args[1].asI64() orelse return .{ .err = .{ .Type = "nextBits count must be an Int" } };
    const g = ctx.args[0].Instance.borrowMut();
    defer g.deinit();
    return ok(.{ .Int = nextBitsFor(g.get(), @truncate(bit_count)) });
}

fn badBound(allocator: Allocator, comptime which: []const u8) Allocator.Error!EvalResult {
    const e = Value{ .Exception = .{
        .fqn = try runtime.strInit(allocator, "kotlin.IllegalArgumentException"),
        .message = .from(try runtime.strInit(allocator, which ++ ": bound must be positive / from < until")),
        .cause = null,
    } };
    return .{ .err = .{ .Thrown = e } };
}
