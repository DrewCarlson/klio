//! Differential base-image harness over `examples/*.kt` and
//! `tests/fixtures/coroutine_smoke/*.kt`: every program runs over the base
//! image the data home caches and over a base analyzed and lowered afresh
//! (`KLIO_SEMA_IMAGE=0`), and the outcomes must be identical. The e2e corpus
//! gate owns the output itself.

const std = @import("std");
const runtime = @import("runtime");
const klio_child = @import("klio_child");

const EXAMPLES = "examples";
const SMOKE_DIR = "tests/fixtures/coroutine_smoke";
const MODES = [_]klio_child.Mode{ .image, .cold };

fn interactive(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n >= 12) break;
        if (std.mem.find(u8, line, "corpus: interactive") != null) return true;
    }
    return false;
}

const Program = struct { path: []const u8, args: []const []const u8 };

/// The corpus's non-interactive programs, each with its `Run with:` flags.
fn corpus(a: std.mem.Allocator, io: std.Io) ![]Program {
    var out: std.ArrayList(Program) = .empty;
    for ([_][]const u8{ EXAMPLES, SMOKE_DIR }) |dir| {
        for (try klio_child.collectKt(a, io, dir)) |path| {
            const src = std.Io.Dir.cwd().readFileAlloc(io, path, a, .unlimited) catch continue;
            if (interactive(src)) continue;
            try out.append(a, .{ .path = path, .args = try klio_child.runArgs(a, src) });
        }
    }
    return out.items;
}

const Outcome = struct {
    ok: bool,
    text: []const u8,

    fn eql(x: Outcome, y: Outcome) bool {
        return x.ok == y.ok and std.mem.eql(u8, x.text, y.text);
    }
};

fn runOne(a: std.mem.Allocator, p: Program, mode: klio_child.Mode) !Outcome {
    return switch (try klio_child.run(a, &.{p.path}, .{ .mode = mode, .args = p.args })) {
        .ok => |o| .{ .ok = true, .text = o },
        .err => |e| .{ .ok = false, .text = e },
    };
}

const Shared = struct {
    programs: []const Program,
    next: std.atomic.Value(usize) = .init(0),
    failures: std.atomic.Value(usize) = .init(0),
    lock: runtime.SpinMutex = .{},
};

fn worker(sh: *Shared) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    while (true) {
        const i = sh.next.fetchAdd(1, .monotonic);
        if (i >= sh.programs.len) return;
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const p = sh.programs[i];
        const diverged = compareModes(a, sh, p) catch |e| blk: {
            sh.lock.lock();
            defer sh.lock.unlock();
            std.debug.print("differential FAIL {s}: {s}\n", .{ p.path, @errorName(e) });
            break :blk true;
        };
        if (diverged) _ = sh.failures.fetchAdd(1, .monotonic);
    }
}

fn compareModes(a: std.mem.Allocator, sh: *Shared, p: Program) !bool {
    const base = try runOne(a, p, MODES[0]);
    const cold = try runOne(a, p, MODES[1]);
    if (base.eql(cold)) return false;
    sh.lock.lock();
    defer sh.lock.unlock();
    std.debug.print(
        "differential DIVERGENCE {s}:\n  [{s}] {s}\n  [{s}] {s}\n",
        .{ p.path, @tagName(MODES[0]), base.text, @tagName(MODES[1]), cold.text },
    );
    return true;
}

test "examples + coroutine smoke are byte-identical over the base image and a fresh base" {
    var list_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer list_arena.deinit();
    const la = list_arena.allocator();
    var threaded: std.Io.Threaded = .init(la, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const programs = try corpus(la, io);
    if (programs.len == 0) {
        std.debug.print("differential: empty corpus; skipping\n", .{});
        return error.SkipZigTest;
    }
    // Installs the packs before the workers start when no home was named.
    _ = try klio_child.home(la);

    var sh: Shared = .{ .programs = programs };
    const cores = std.Thread.getCpuCount() catch 4;
    const n = std.math.clamp(cores / 2, 1, 8);
    const threads = try la.alloc(std.Thread, n);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, worker, .{&sh});
    for (threads) |t| t.join();
    const failures = sh.failures.load(.monotonic);
    if (klio_child.verbose()) std.debug.print("differential: {d} programs, {d} diverged\n", .{ programs.len, failures });
    if (failures != 0) {
        std.debug.print("differential: {d} program(s) diverged between the base image and a fresh base\n", .{failures});
        return error.ImageVsColdDivergence;
    }
}

// A run that changed the cached base would make an output depend on which
// programs ran before it.
test "corpus outputs are independent of program order" {
    var list_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer list_arena.deinit();
    const la = list_arena.allocator();
    var threaded: std.Io.Threaded = .init(la, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const all = try corpus(la, io);
    if (all.len == 0) return error.SkipZigTest;

    // Leakage shows up against any surrounding programs, so a deterministic
    // sample suffices. Every pack-using program stays: those bases carry the
    // most state.
    var sampled: std.ArrayList(Program) = .empty;
    {
        var plain: std.ArrayList(Program) = .empty;
        for (all) |p| {
            const src = std.Io.Dir.cwd().readFileAlloc(io, p.path, la, .unlimited) catch continue;
            if (usesPack(src)) try sampled.append(la, p) else try plain.append(la, p);
        }
        const max_plain = 12;
        const stride = @max(plain.items.len / max_plain, 1);
        var i: usize = 0;
        while (i < plain.items.len) : (i += stride) try sampled.append(la, plain.items[i]);
    }

    const Recorded = struct { program: Program, mode: klio_child.Mode, outcome: Outcome };
    var recorded: std.ArrayList(Recorded) = .empty;

    var run_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer run_arena.deinit();

    // Forward pass: record every outcome. Only a run over the base image
    // shares state with the runs before it.
    for (sampled.items) |p| {
        if (klio_child.verbose()) std.debug.print("differential order FWD {s}\n", .{p.path});
        for ([_]klio_child.Mode{.image}) |mode| {
            _ = run_arena.reset(.retain_capacity);
            const o = try runOne(run_arena.allocator(), p, mode);
            try recorded.append(la, .{ .program = p, .mode = mode, .outcome = .{ .ok = o.ok, .text = try la.dupe(u8, o.text) } });
        }
    }

    var failures: usize = 0;
    var idx: usize = recorded.items.len;
    while (idx > 0) {
        idx -= 1;
        const rec = recorded.items[idx];
        if (klio_child.verbose()) std.debug.print("differential order REV {s} [{s}]\n", .{ rec.program.path, @tagName(rec.mode) });
        _ = run_arena.reset(.retain_capacity);
        const o = try runOne(run_arena.allocator(), rec.program, rec.mode);
        if (!o.eql(rec.outcome)) {
            failures += 1;
            std.debug.print(
                "differential ORDER DIVERGENCE {s} [{s}]:\n  forward: {s}\n  reverse: {s}\n",
                .{ rec.program.path, @tagName(rec.mode), rec.outcome.text, o.text },
            );
        }
    }
    if (failures != 0) return error.OrderDependentOutput;
}

/// Whether the program imports a library a pack provides.
fn usesPack(src: []const u8) bool {
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r\n");
        if (!std.mem.startsWith(u8, line, "import ")) continue;
        const path = std.mem.trim(u8, line["import ".len..], " \t");
        if (!std.mem.startsWith(u8, path, "kotlin.") and !std.mem.startsWith(u8, path, "java.")) return true;
    }
    return false;
}
