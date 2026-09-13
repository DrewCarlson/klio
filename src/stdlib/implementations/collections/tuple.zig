//! `Pair` / `Triple` members.

const std = @import("std");
const runtime = @import("runtime");
const CallCtx = runtime.CallCtx;
const EvalResult = runtime.EvalResult;
const Value = runtime.Value;
const Allocator = std.mem.Allocator;
const Error = std.mem.Allocator.Error;

const common_mod = @import("common.zig");
const arityErr = common_mod.arityErr;
const display = common_mod.display;
const fmt = common_mod.fmt;
const makeList = common_mod.makeList;
const makeStringOwned = common_mod.makeStringOwned;
const makeTriple = common_mod.makeTriple;
const ok = common_mod.ok;
const typeErr = common_mod.typeErr;

// =====================================================================
// Pair / Triple members
// =====================================================================

fn recvPair(a: Allocator, args: []const Value, what: []const u8) Error!union(enum) { pair: Value, err: EvalResult } {
    if (args.len > 0 and args[0] == .Pair) return .{ .pair = args[0] };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Pair receiver", .{what})) };
}

pub fn pair_first(ctx: *CallCtx) Error!EvalResult {
    const p = switch (try recvPair(ctx.allocator, ctx.args, "Pair.first")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    const out = p.Pair.first.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn pair_second(ctx: *CallCtx) Error!EvalResult {
    const p = switch (try recvPair(ctx.allocator, ctx.args, "Pair.second")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    const out = p.Pair.second.asPtr().*;
    out.retain();
    return ok(out);
}
/// Render one value the way `toString()` would, dispatching a user override on
/// an instance. Falls back to the structural renderer for everything else.
fn displayElemH(ctx: *CallCtx, v: Value) Error!union(enum) { ok: []u8, err: EvalResult } {
    const a = ctx.allocator;
    if (v == .Instance) {
        if (try ctx.host.invokeMethod(&v, "toString", &.{}, ctx.out)) |m| {
            switch (m) {
                .ok => |sv| if (sv == .String) {
                    const g = sv.String.borrow();
                    defer g.deinit();
                    return .{ .ok = try a.dupe(u8, g.get().bytes) };
                },
                .err => return .{ .err = m },
            }
        }
    }
    return .{ .ok = try display(a, v) };
}

pub fn pair_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const p = switch (try recvPair(a, ctx.args, "Pair.toString")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    // Kotlin renders `($first, $second)`, each through its own `toString()`.
    const first = switch (try displayElemH(ctx, p.Pair.first.asPtr().*)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(first);
    const second = switch (try displayElemH(ctx, p.Pair.second.asPtr().*)) {
        .ok => |x| x,
        .err => |e| return e,
    };
    defer if (runtime.freeScratch()) a.free(second);
    const buf = try fmt(a, "({s}, {s})", .{ first, second });
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}
pub fn pair_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const p = switch (try recvPair(a, ctx.args, "Pair.toList")) {
        .pair => |v| v,
        .err => |e| return e,
    };
    return ok(try makeList(a, &.{ p.Pair.first.asPtr().*, p.Pair.second.asPtr().* }, false));
}

fn recvTriple(a: Allocator, args: []const Value, what: []const u8) Error!union(enum) { triple: Value, err: EvalResult } {
    if (args.len > 0 and args[0] == .Triple) return .{ .triple = args[0] };
    return .{ .err = typeErr(try fmt(a, "{s} requires a Triple receiver", .{what})) };
}

pub fn coll_triple_ctor(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len != 3) return arityErr("Triple expects 3 arguments");
    ctx.args[0].retain();
    ctx.args[1].retain();
    ctx.args[2].retain();
    return ok(try makeTriple(ctx.allocator, ctx.args[0], ctx.args[1], ctx.args[2]));
}
pub fn triple_first(ctx: *CallCtx) Error!EvalResult {
    const t = switch (try recvTriple(ctx.allocator, ctx.args, "Triple.first")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const out = t.Triple.first.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn triple_second(ctx: *CallCtx) Error!EvalResult {
    const t = switch (try recvTriple(ctx.allocator, ctx.args, "Triple.second")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const out = t.Triple.second.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn triple_third(ctx: *CallCtx) Error!EvalResult {
    const t = switch (try recvTriple(ctx.allocator, ctx.args, "Triple.third")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const out = t.Triple.third.asPtr().*;
    out.retain();
    return ok(out);
}
pub fn triple_to_string(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const t = switch (try recvTriple(a, ctx.args, "Triple.toString")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    const buf = try display(a, t);
    const s = try makeStringOwned(a, buf);
    if (runtime.freeScratch()) a.free(buf);
    return ok(s);
}
pub fn triple_to_list(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const t = switch (try recvTriple(a, ctx.args, "Triple.toList")) {
        .triple => |v| v,
        .err => |e| return e,
    };
    return ok(try makeList(a, &.{ t.Triple.first.asPtr().*, t.Triple.second.asPtr().*, t.Triple.third.asPtr().* }, false));
}
