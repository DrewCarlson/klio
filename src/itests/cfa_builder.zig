//! Port of crates/klio-cfa/tests/builder.rs.
//!
//! Exercises the IR + builder by constructing canonical CFG shapes by
//! hand and asserting their printed form. The Rust tests use
//! `insta::assert_snapshot!`; here the corresponding `.snap` bodies are
//! embedded as expected strings and compared with the printer output.
//! Arena per test so the leak-checking allocator never runs the pipeline.

const std = @import("std");

const cfa = @import("cfa");
const span = @import("span");
const types = @import("types");

const CfgBuilder = cfa.CfgBuilder;
const ExprRef = cfa.ExprRef;
const FieldId = cfa.FieldId;
const Node = cfa.Node;
const Pattern = cfa.Pattern;
const Place = cfa.Place;
const SwitchArm = cfa.SwitchArm;
const Symbol = cfa.Symbol;
const Terminator = cfa.Terminator;
const EdgeKind = cfa.EdgeKind;
const BlockId = cfa.BlockId;
const printCfg = cfa.printCfg;

const Span = span.Span;
const FileId = span.FileId;
const Type = types.Type;

fn mkSpan(s: u32, e: u32) Span {
    return Span.init(FileId.from(0), s, e);
}

/// Build a `std.ArrayList(BlockId)` of `exits` for `CfgBuilder.finish`.
fn exitsOf(a: std.mem.Allocator, ids: []const BlockId) std.mem.Allocator.Error!std.ArrayList(BlockId) {
    var list: std.ArrayList(BlockId) = .empty;
    try list.appendSlice(a, ids);
    return list;
}

test "straight_line" {
    // r0 = x; r1 = y; tmp = r0; return tmp
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = CfgBuilder.init();
    const entry = try b.newBlock(a);
    const r0 = b.newReg();
    const r1 = b.newReg();
    try b.push(a, entry, .{ .Eval = .{ .reg = r0, .expr = .{ .span = mkSpan(0, 1), .ty = .Int } } });
    try b.push(a, entry, .{ .Eval = .{ .reg = r1, .expr = .{ .span = mkSpan(2, 3), .ty = .Int } } });
    try b.push(a, entry, .{ .Assign = .{
        .lhs = .{ .Local = .{ .name = "tmp" } },
        .rhs = r0,
        .span = mkSpan(4, 7),
    } });
    try b.setTerminator(a, entry, .{ .Return = r1 });
    var cfg = b.finish(a, entry, try exitsOf(a, &.{entry}), mkSpan(0, 10));

    const got = try printCfg(a, &cfg);
    const expected =
        \\cfg: entry=b0
        \\exits: b0
        \\
        \\b0:
        \\  r0 = eval @0..1 :: Int
        \\  r1 = eval @2..3 :: Int
        \\  assign tmp = r0
        \\  term: return r1
        \\
    ;
    try std.testing.expectEqualStrings(expected, got);
}

test "branch_join" {
    // if (cond) then-blk else else-blk -> join
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = CfgBuilder.init();
    const entry = try b.newBlock(a);
    const then_blk = try b.newBlock(a);
    const else_blk = try b.newBlock(a);
    const join = try b.newBlock(a);

    const cond = b.newReg();
    const rt = b.newReg();
    const rf = b.newReg();

    try b.push(a, entry, .{ .Eval = .{ .reg = cond, .expr = .{ .span = mkSpan(0, 4), .ty = .Boolean } } });
    try b.setTerminator(a, entry, .{ .Branch = .{ .cond = cond, .then_blk = then_blk, .else_blk = else_blk } });

    try b.push(a, then_blk, .{ .Assume = .{ .reg = cond, .polarity = true } });
    try b.push(a, then_blk, .{ .Eval = .{ .reg = rt, .expr = .{ .span = mkSpan(5, 6), .ty = .Int } } });
    try b.setTerminator(a, then_blk, .{ .Goto = join });

    try b.push(a, else_blk, .{ .Assume = .{ .reg = cond, .polarity = false } });
    try b.push(a, else_blk, .{ .Eval = .{ .reg = rf, .expr = .{ .span = mkSpan(7, 8), .ty = .Int } } });
    try b.setTerminator(a, else_blk, .{ .Goto = join });

    try b.setTerminator(a, join, .{ .Return = null });

    var cfg = b.finish(a, entry, try exitsOf(a, &.{join}), mkSpan(0, 12));

    const got = try printCfg(a, &cfg);
    const expected =
        \\cfg: entry=b0
        \\exits: b3
        \\
        \\b0:
        \\  r0 = eval @0..4 :: Boolean
        \\  term: branch r0 -> b1 else b2
        \\
        \\b1:
        \\  preds: b0(T)
        \\  assume r0
        \\  r1 = eval @5..6 :: Int
        \\  term: goto b3
        \\
        \\b2:
        \\  preds: b0(F)
        \\  assume !r0
        \\  r2 = eval @7..8 :: Int
        \\  term: goto b3
        \\
        \\b3:
        \\  preds: b1, b2
        \\  term: return
        \\
    ;
    try std.testing.expectEqualStrings(expected, got);
}

test "is_check_arm_carries_assume_is" {
    // when (x) { is String -> body; else -> def }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = CfgBuilder.init();
    const entry = try b.newBlock(a);
    const str_arm = try b.newBlock(a);
    const def_arm = try b.newBlock(a);
    const join = try b.newBlock(a);

    const subj = b.newReg();
    try b.push(a, entry, .{ .Eval = .{ .reg = subj, .expr = .{ .span = mkSpan(0, 1), .ty = .Any } } });

    var arms = [_]SwitchArm{.{
        .pattern = .{ .Is = .{ .ty = .String, .polarity = true } },
        .target = str_arm,
    }};
    try b.setTerminator(a, entry, .{ .Switch = .{ .reg = subj, .arms = &arms, .default = def_arm } });

    try b.push(a, str_arm, .{ .AssumeIs = .{
        .reg = subj,
        .ty = .String,
        .class_name = null,
        .polarity = true,
        .span = mkSpan(0, 1),
    } });
    try b.setTerminator(a, str_arm, .{ .Goto = join });

    try b.push(a, def_arm, .{ .AssumeIs = .{
        .reg = subj,
        .ty = .String,
        .class_name = null,
        .polarity = false,
        .span = mkSpan(0, 1),
    } });
    try b.setTerminator(a, def_arm, .{ .Goto = join });

    try b.setTerminator(a, join, .{ .Return = null });

    var cfg = b.finish(a, entry, try exitsOf(a, &.{join}), mkSpan(0, 30));

    const got = try printCfg(a, &cfg);
    const expected =
        \\cfg: entry=b0
        \\exits: b3
        \\
        \\b0:
        \\  r0 = eval @0..1 :: Any
        \\  term: switch r0 [is String -> b1] default b2
        \\
        \\b1:
        \\  preds: b0
        \\  assume r0 is String
        \\  term: goto b3
        \\
        \\b2:
        \\  preds: b0
        \\  assume r0 !is String
        \\  term: goto b3
        \\
        \\b3:
        \\  preds: b1, b2
        \\  term: return
        \\
    ;
    try std.testing.expectEqualStrings(expected, got);
}

test "loop_with_backedge" {
    // while (cond) { body }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = CfgBuilder.init();
    const entry = try b.newBlock(a);
    const head = try b.newBlock(a);
    const body = try b.newBlock(a);
    const exit = try b.newBlock(a);
    const lid = b.newLoop();

    try b.setTerminator(a, entry, .{ .Goto = head });

    const cond = b.newReg();
    try b.push(a, head, .{ .Eval = .{ .reg = cond, .expr = .{ .span = mkSpan(0, 1), .ty = .Boolean } } });
    try b.setTerminator(a, head, .{ .Branch = .{ .cond = cond, .then_blk = body, .else_blk = exit } });

    try b.push(a, body, .{ .Assume = .{ .reg = cond, .polarity = true } });
    try b.push(a, body, .{ .Backedge = .{ .loop_id = lid } });
    try b.setTerminator(a, body, .{ .Goto = head });

    try b.push(a, exit, .{ .Assume = .{ .reg = cond, .polarity = false } });
    try b.setTerminator(a, exit, .{ .Return = null });

    var cfg = b.finish(a, entry, try exitsOf(a, &.{exit}), mkSpan(0, 30));

    const got = try printCfg(a, &cfg);
    const expected =
        \\cfg: entry=b0
        \\exits: b3
        \\
        \\b0:
        \\  term: goto b1
        \\
        \\b1:
        \\  preds: b0, b2
        \\  r0 = eval @0..1 :: Boolean
        \\  term: branch r0 -> b2 else b3
        \\
        \\b2:
        \\  preds: b1(T)
        \\  assume r0
        \\  backedge l0
        \\  term: goto b1
        \\
        \\b3:
        \\  preds: b1(F)
        \\  assume !r0
        \\  term: return
        \\
    ;
    try std.testing.expectEqualStrings(expected, got);
}

test "try_catch_finally_edges" {
    // try { body } catch (e: T) { handler } finally { fin }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = CfgBuilder.init();
    const entry = try b.newBlock(a);
    const body = try b.newBlock(a);
    const handler = try b.newBlock(a);
    const fin = try b.newBlock(a);
    const after = try b.newBlock(a);

    try b.setTerminator(a, entry, .{ .Goto = body });

    const r0 = b.newReg();
    try b.push(a, body, .{ .Eval = .{ .reg = r0, .expr = .{ .span = mkSpan(0, 5), .ty = .Int } } });
    try b.setTerminator(a, body, .{ .Goto = fin });
    try b.addEdge(a, body, handler, .{ .Exception = .{ .ty = .String } });

    const r1 = b.newReg();
    try b.push(a, handler, .{ .Eval = .{ .reg = r1, .expr = .{ .span = mkSpan(6, 9), .ty = .Int } } });
    try b.setTerminator(a, handler, .{ .Goto = fin });

    try b.setTerminator(a, fin, .{ .Goto = after });
    try b.addEdge(a, fin, after, .FinallyExit);

    try b.setTerminator(a, after, .{ .Return = null });

    var cfg = b.finish(a, entry, try exitsOf(a, &.{after}), mkSpan(0, 40));

    const got = try printCfg(a, &cfg);
    const expected =
        \\cfg: entry=b0
        \\exits: b4
        \\
        \\b0:
        \\  term: goto b1
        \\
        \\b1:
        \\  preds: b0
        \\  r0 = eval @0..5 :: Int
        \\  term: goto b3
        \\
        \\b2:
        \\  preds: b1(throw String)
        \\  r1 = eval @6..9 :: Int
        \\  term: goto b3
        \\
        \\b3:
        \\  preds: b1, b2
        \\  term: goto b4
        \\
        \\b4:
        \\  preds: b3, b3(finally-exit)
        \\  term: return
        \\
    ;
    try std.testing.expectEqualStrings(expected, got);
}

test "field_place_path" {
    // p.x.y = r0
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var b = CfgBuilder.init();
    const entry = try b.newBlock(a);
    const r0 = b.newReg();
    try b.push(a, entry, .{ .Eval = .{ .reg = r0, .expr = .{ .span = mkSpan(0, 1), .ty = .Int } } });

    const inner = try a.create(Place);
    inner.* = .{ .Local = .{ .name = "p" } };
    const mid = try a.create(Place);
    mid.* = .{ .Field = .{ .receiver = inner, .field = .{ .name = "x" } } };
    const place: Place = .{ .Field = .{ .receiver = mid, .field = .{ .name = "y" } } };

    try b.push(a, entry, .{ .Assign = .{ .lhs = place, .rhs = r0, .span = mkSpan(2, 9) } });
    try b.setTerminator(a, entry, .{ .Return = null });
    var cfg = b.finish(a, entry, try exitsOf(a, &.{entry}), mkSpan(0, 10));

    const got = try printCfg(a, &cfg);
    const expected =
        \\cfg: entry=b0
        \\exits: b0
        \\
        \\b0:
        \\  r0 = eval @0..1 :: Int
        \\  assign p.x.y = r0
        \\  term: return
        \\
    ;
    try std.testing.expectEqualStrings(expected, got);
}
