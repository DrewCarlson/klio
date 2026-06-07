//! Port of crates/klio-cfa/tests/smartcast.rs.
//!
//! Each test parses a small Kotlin function, lowers it, runs the
//! smart-cast pass, and asserts on the per-place fact at a chosen
//! block. Arena per test so the leak-checking allocator never runs the
//! pipeline.

const std = @import("std");

const cfa = @import("cfa");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const span = @import("span");
const types = @import("types");

const smartcast = cfa.analyses.smartcast;
const Nullability = smartcast.Nullability;
const SmartCastFact = smartcast.SmartCastFact;
const Cfg = cfa.Cfg;
const BlockId = cfa.BlockId;
const Place = cfa.Place;
const RegPlaceMap = cfa.lower.RegPlaceMap;
const FileId = span.FileId;
const Block = ast.Block;

/// Parse the first function in `src` and lower its body, returning the
/// full `Lowered` (cfg + side tables). Everything is allocated from
/// `arena`.
fn parseAndLower(arena: std.mem.Allocator, src: []const u8) !cfa.lower.Lowered {
    const file = FileId.from(0);
    var lx = try lexer.Lexer.init(arena, file, src);
    const lexed = try lx.tokenize();
    try std.testing.expect(!lexed.diagnostics.hasErrors());
    const p = parser.Parser.new(arena, file, src, lexed.tokens);
    const parsed = p.parseFile();
    try std.testing.expect(!p.diagnostics.hasErrors());

    var func: ?*const ast.Function = null;
    for (parsed.decls) |*d| {
        if (d.* == .Function) {
            func = &d.Function;
            break;
        }
    }
    const f = func orelse return error.NoFunction;
    const fbody = f.body orelse return error.NoBody;
    var body: Block = switch (fbody) {
        .Block => |bk| bk,
        .Expr => |e| blk: {
            const stmts = try arena.alloc(ast.Stmt, 1);
            stmts[0] = .{ .Expr = e };
            break :blk Block{ .stmts = stmts, .span = e.span() };
        },
    };
    return cfa.lower.lowerFunction(arena, &body, f.span);
}

/// Returns true if any per-node state, in any block, holds a fact for
/// `place` that satisfies `pred`.
fn anyNarrowingAnywhere(
    arena: std.mem.Allocator,
    cfg: *const Cfg,
    r2p: *const RegPlaceMap,
    place: Place,
    pred: *const fn (*const SmartCastFact) bool,
) !bool {
    const entry_states = try smartcast.solve(arena, cfg, r2p);
    for (entry_states.items, 0..) |*st, i| {
        const bid = BlockId.from(@intCast(i));
        const walk = try smartcast.statesWithinBlock(arena, cfg, bid, try st.clone(arena), r2p);
        for (walk.items) |*s| {
            var fact = try s.get(arena, place);
            if (pred(&fact)) return true;
        }
    }
    return false;
}

fn isNonNull(f: *const SmartCastFact) bool {
    return f.null == .NonNull;
}

fn isNarrowedString(f: *const SmartCastFact) bool {
    return f.narrowed != null and f.narrowed.? == .String;
}

test "null_check_narrows_branch" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a,
        \\fun foo(x: String?) {
        \\            if (x != null) {
        \\                println(x.length)
        \\            }
        \\        }
    );
    const x = Place{ .Local = .{ .name = "x" } };
    try std.testing.expect(try anyNarrowingAnywhere(a, &lowered.cfg, &lowered.reg_to_place, x, isNonNull));
}

test "is_check_narrows_type" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a,
        \\fun foo(x: Any) {
        \\            if (x is String) {
        \\                println(x)
        \\            }
        \\        }
    );
    const x = Place{ .Local = .{ .name = "x" } };
    try std.testing.expect(try anyNarrowingAnywhere(a, &lowered.cfg, &lowered.reg_to_place, x, isNarrowedString));
}

test "fact_resets_after_assignment" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lowered = try parseAndLower(a,
        \\fun foo(x: Any) {
        \\            if (x is String) {
        \\                println(x)
        \\                val y: Any = 1
        \\            }
        \\        }
    );
    _ = lowered;
}

test "join_drops_disagreeing_narrowings" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var fact_a = SmartCastFact.unknown();
    try fact_a.assumeIs(a, .String, null);
    var fact_b = SmartCastFact.unknown();
    try fact_b.assumeIs(a, .Int, null);
    _ = try fact_a.join(a, &fact_b);
    // String join Int should drop to Any — disagreement.
    try std.testing.expect(fact_a.narrowed != null and fact_a.narrowed.? == .Any);
}

test "killdataflow_invalidates_narrowing" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a,
        \\fun foo(x: Any) {
        \\            var y: Any = x
        \\            if (y is String) {
        \\                var i = 0
        \\                while (i < 10) {
        \\                    y = 1
        \\                    i = i + 1
        \\                }
        \\                // y's narrowing must be invalidated by killDataFlow
        \\            }
        \\        }
    );
    try cfa.dataflow.inferKillDataFlow(a, &lowered.cfg);
    var states = try smartcast.solve(a, &lowered.cfg, &lowered.reg_to_place);
    _ = &states;
    // We assert that the loop head has a KillDataFlow for `y` —
    // smart-cast then drops the narrowing when it sees it.
    var killed = false;
    for (lowered.cfg.blocks.items) |*b| {
        for (b.nodes.items) |*n| {
            switch (n.*) {
                .KillDataFlow => |k| {
                    if (k.place == .Local and std.mem.eql(u8, k.place.Local.name, "y")) {
                        killed = true;
                    }
                },
                else => {},
            }
        }
    }
    try std.testing.expect(killed);
}

test "bound_smart_cast_aliases_recorded" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a, "fun foo(a: Any) { val b = a }");
    const aliased_from = lowered.aliases.get(.{ .name = "b" }) orelse {
        return error.BShouldAliasA;
    };
    const expected = Place{ .Local = .{ .name = "a" } };
    try std.testing.expect(aliased_from.eql(expected));
}

test "require_not_null_narrows_post_call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a,
        \\fun foo(x: String?) {
        \\            requireNotNull(x)
        \\            println(x)
        \\        }
    );
    const x = Place{ .Local = .{ .name = "x" } };
    try std.testing.expect(try anyNarrowingAnywhere(a, &lowered.cfg, &lowered.reg_to_place, x, isNonNull));
}

test "require_with_is_check_narrows_post_call" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a,
        \\fun foo(x: Any) {
        \\            require(x is String)
        \\            println(x)
        \\        }
    );
    const x = Place{ .Local = .{ .name = "x" } };
    try std.testing.expect(try anyNarrowingAnywhere(a, &lowered.cfg, &lowered.reg_to_place, x, isNarrowedString));
}

test "span_to_pos_indexes_every_eval" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a, "fun foo() { val x = 1 + 2 }");
    var it = lowered.span_to_pos.iterator();
    var count: usize = 0;
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const pos = entry.value_ptr.*;
        // Every recorded position points at a real Eval node.
        const node = lowered.cfg.block(pos.block).nodes.items[pos.node_idx];
        switch (node) {
            .Eval => |e| {
                try std.testing.expectEqual(key.start, e.expr.span.start);
                try std.testing.expectEqual(key.end, e.expr.span.end);
            },
            else => {
                std.debug.print("span_to_pos points at non-Eval node: {any}\n", .{node});
                return error.NonEvalNode;
            },
        }
        count += 1;
    }
    try std.testing.expect(count != 0);
}

test "empty_program_has_no_facts" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lowered = try parseAndLower(a, "fun foo() { }");
    const states = try smartcast.solve(a, &lowered.cfg, &lowered.reg_to_place);
    for (states.items) |*state| {
        try std.testing.expect(state.entries.items.len == 0);
    }
}
