//! Runs Kotlin source through parse, sema, the bridge, lowering from sema
//! and the VM, over an executable miniature base, and reports what the
//! program printed. The lowering packages' tests run through it.

const std = @import("std");
const span = @import("span");
const ast = @import("ast");
const lexer = @import("lexer");
const parser = @import("parser");
const sema = @import("sema");
const ir = @import("ir");
const runtime = @import("runtime");
const interp_ir = @import("interp_ir");

pub const mini_base = @import("mini_base.zig");
pub const natives = @import("natives.zig");
pub const lower_census = @import("census.zig");
pub const pipeline = @import("pipeline.zig");

const Allocator = std.mem.Allocator;
const bridge = ir.bridge;
const lower = ir.lower_sema;

pub const Outcome = struct {
    /// Joined lines, "\n"-terminated.
    output: []const u8,
    result: enum { ok, threw, failed },
    /// Census sites in the program, lowering errors, or the uncaught throwable.
    diag: []const u8,
};

/// Parse, sema and bridge over the miniature base and a program: everything
/// before lowering.
pub const Analysis = struct {
    map: span.SourceMap,
    s: *sema.Sema,
    out: sema.output.Output,
    br: *bridge.Bridge,
    /// Where the base layer and the program layer end.
    layers: [2]bridge.Layer,

    /// The base's files are `0 .. base_files`; the program's follow.
    pub fn baseFiles(self: *const Analysis) u32 {
        return self.layers[0].files;
    }

    /// The census sites reported in files of `origin`, one per line with
    /// its reason, location and detail.
    pub fn census(self: *const Analysis, a: Allocator, origin: sema.Origin) Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (self.s.census.sites.items) |site| {
            if (site.file >= self.s.files.items.len) {
                if (origin != .base) continue;
            } else if (self.s.files.items[site.file].origin != origin) continue;
            try out.print(a, "{s}: {s} {s}\n", .{ try self.where(a, site.file, site.sp), @tagName(site.reason), site.detail });
        }
        return out.items;
    }

    /// `path:line:col` of a span in file `file`.
    pub fn where(self: *const Analysis, a: Allocator, file: u32, sp: span.Span) Allocator.Error![]const u8 {
        if (file >= self.s.files.items.len) return "<builtin>";
        const src = self.map.getChecked(sp.file) orelse return self.s.files.items[file].path;
        const lc = src.lineCol(sp.start);
        return std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ self.s.files.items[file].path, lc.line, lc.col });
    }

    /// The program's entry point, as `klio run` chooses it.
    pub fn mainSym(self: *const Analysis) Allocator.Error!?sema.Sym {
        return pipeline.mainOf(self.s);
    }
};

pub fn parseInto(a: Allocator, map: *span.SourceMap, files: *std.ArrayList(sema.SourceFile), path: []const u8, src: []const u8, origin: sema.Origin) !void {
    const id = try map.add(path, src);
    const text = map.get(id).source;
    var lx = try lexer.Lexer.init(a, id, text);
    const lexed = try lx.tokenize();
    const p = parser.Parser.new(a, id, text, lexed.tokens, lexed.strings);
    const file = try a.create(ast.KotlinFile);
    file.* = p.parseFile();
    try files.append(a, .{ .ast = file, .path = path, .origin = origin });
}

/// Parses the base (one layer) and `sources` (the next), resolves every
/// body, builds sema's records and runs the bridge. Everything lives in `a`.
pub fn analyze(a: Allocator, sources: []const []const u8) !Analysis {
    return analyzeWith(a, sources, .{});
}

/// What `analyzeWith` hands the bridge beyond the natives.
pub const AnalyzeOptions = struct {
    /// The fast paths put in front of bodies (`bridge.Options.host_tries`).
    host_tries: ?ir.resolved.HostTryResolver = null,
};

pub fn analyzeWith(a: Allocator, sources: []const []const u8, opts: AnalyzeOptions) !Analysis {
    var map = span.SourceMap.init(a);
    var base: std.ArrayList(sema.SourceFile) = .empty;
    for (mini_base.files) |f| try parseInto(a, &map, &base, f.path, f.source, .base);
    var program: std.ArrayList(sema.SourceFile) = .empty;
    for (sources, 0..) |src, i| {
        const path = try std.fmt.allocPrint(a, "test{d}.kt", .{i});
        try parseInto(a, &map, &program, path, src, .program);
    }
    const s = try sema.Sema.init(a);
    try s.addFiles(base.items);
    const base_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try s.addFiles(program.items);
    const program_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try s.resolveBodies(&.{ .base, .program });
    const out = try sema.output.build(s);
    const layers = [2]bridge.Layer{ base_layer, program_layer };
    // Class defs the bridge makes are read by every run; they are minted
    // outside the collected generation.
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const br = try bridge.build(a, s, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn, .host_tries = opts.host_tries, .records = out.files, .layers = &layers });
    return .{ .map = map, .s = s, .out = out, .br = br, .layers = layers };
}

/// Parses the executable base (one layer) and `sources` (the next layer),
/// resolves, bridges, lowers every body with an id and runs `main`.
pub fn run(a: Allocator, sources: []const []const u8) anyerror!Outcome {
    var an = try analyze(a, sources);
    const census = try an.census(a, .program);
    if (census.len != 0) return failed(census);
    // A body that fails records its error in the program; an error out of
    // `lowerProgram` itself means the lowering is not built, which the
    // packages' tests skip on.
    const prog = try lower.lowerProgram(a, an.s, an.br);
    if (prog.errors.items.len != 0) {
        // A construct whose package is not built yet (a stub returned
        // `Unsupported` without saying why): skipped, like an unbuilt lowering.
        for (prog.errors.items) |le| {
            if (std.mem.eql(u8, le.msg, not_lowered)) return error.Unsupported;
        }
        // A record sema does not write yet: the same, but named, so the
        // gap stays visible.
        for (prog.errors.items) |le| {
            if (!unrecorded(le.msg)) continue;
            std.debug.print("skipped: {s}: {s}\n", .{ try spanWhere(a, &an, le.span), le.msg });
            return error.Unsupported;
        }
        var diag: std.ArrayList(u8) = .empty;
        for (prog.errors.items) |le| {
            const f = an.br.m.funcs.items[le.func.int()];
            try diag.print(a, "{s}: in {s}: {s}\n", .{ try spanWhere(a, &an, le.span), f.fqn, le.msg });
        }
        return failed(diag.items);
    }
    const main_sym = (try an.mainSym()) orelse return failed("no main function\n");
    const main = an.br.funcOfOpt(main_sym) orelse return failed("main has no id\n");
    return runMain(a, &an, main);
}

/// The miniature base baked alone, as a base image holds it: bridged and
/// lowered over a sema that saw only the base.
pub const Baked = struct {
    /// The sema that baked it.
    s: *sema.Sema,
    br: *bridge.Bridge,
    /// Where the base's layer ends in the sema that baked it.
    layer: bridge.Layer,
    /// By FuncId: the bodies the bake lowered.
    lowered: std.DynamicBitSetUnmanaged,
};

pub fn bake(a: Allocator) !Baked {
    var map = span.SourceMap.init(a);
    var base: std.ArrayList(sema.SourceFile) = .empty;
    for (mini_base.files) |f| try parseInto(a, &map, &base, f.path, f.source, .base);
    const s = try sema.Sema.init(a);
    try s.addFiles(base.items);
    const layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try s.resolveBodies(&.{.base});
    const out = try sema.output.build(s);
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const br = try bridge.build(a, s, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn, .records = out.files, .layers = &.{layer} });
    const prog = try lower.lowerProgram(a, s, br);
    return .{ .s = s, .br = br, .layer = layer, .lowered = prog.lowered };
}

/// `analyze` over a baked base: a fresh sema reads the base's files and
/// then `sources`, resolves the program's bodies only, and the program
/// extends the baked bridge (`bridge.buildOver`).
pub fn analyzeOver(a: Allocator, baked: *const Baked, sources: []const []const u8) !Analysis {
    var map = span.SourceMap.init(a);
    var base: std.ArrayList(sema.SourceFile) = .empty;
    for (mini_base.files) |f| try parseInto(a, &map, &base, f.path, f.source, .base);
    var program: std.ArrayList(sema.SourceFile) = .empty;
    for (sources, 0..) |src, i| {
        const path = try std.fmt.allocPrint(a, "test{d}.kt", .{i});
        try parseInto(a, &map, &program, path, src, .program);
    }
    const s = try sema.Sema.init(a);
    try s.addFiles(base.items);
    const base_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    if (base_layer.syms != baked.layer.syms or base_layer.files != baked.layer.files) return error.BaseMismatch;
    try s.addFiles(program.items);
    const program_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try s.resolveBodies(&.{.program});
    const out = try sema.output.build(s);
    const layers = [2]bridge.Layer{ base_layer, program_layer };
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const br = try bridge.buildOver(a, s, baked.br, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn, .records = out.files, .layers = &layers });
    return .{ .map = map, .s = s, .out = out, .br = br, .layers = layers };
}

/// `run` over a freshly baked base: the program extends it and only the
/// program's bodies lower.
pub fn runOver(a: Allocator, sources: []const []const u8) anyerror!Outcome {
    const baked = try bake(a);
    var an = try analyzeOver(a, &baked, sources);
    const census = try an.census(a, .program);
    if (census.len != 0) return failed(census);
    const prog = try lower.lowerProgramOver(a, an.s, an.br, baked.lowered);
    if (prog.errors.items.len != 0) {
        var diag: std.ArrayList(u8) = .empty;
        for (prog.errors.items) |le| {
            const f = an.br.m.funcs.items[le.func.int()];
            try diag.print(a, "{s}: in {s}: {s}\n", .{ try spanWhere(a, &an, le.span), f.fqn, le.msg });
        }
        return failed(diag.items);
    }
    const main_sym = (try an.mainSym()) orelse return failed("no main function\n");
    const main = an.br.funcOfOpt(main_sym) orelse return failed("main has no id\n");
    return runMain(a, &an, main);
}

/// `runOver` with the baked base serialized and read back, as a run over
/// a cached base image reads it (`pipeline.base_image`).
pub fn runOverImage(a: Allocator, sources: []const []const u8) anyerror!Outcome {
    const baked = try bake(a);
    const bytes = try pipeline.base_image.encode(a, a, baked.s, baked.br, &baked.lowered, baked.layer.syms);
    var map = span.SourceMap.init(a);
    var base: std.ArrayList(sema.SourceFile) = .empty;
    for (mini_base.files) |f| try parseInto(a, &map, &base, f.path, f.source, .base);
    var program: std.ArrayList(sema.SourceFile) = .empty;
    for (sources, 0..) |src, i| {
        const path = try std.fmt.allocPrint(a, "test{d}.kt", .{i});
        try parseInto(a, &map, &program, path, src, .program);
    }
    const s = try sema.Sema.init(a);
    try s.addFiles(base.items);
    const base_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    const saved_perm = runtime.gc.alloc_perm;
    runtime.gc.alloc_perm = true;
    defer runtime.gc.alloc_perm = saved_perm;
    const loaded = try pipeline.base_image.decode(a, bytes, s, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn });
    try s.addFiles(program.items);
    const program_layer: bridge.Layer = .{ .syms = @intCast(s.syms.count()), .files = @intCast(s.files.items.len) };
    try s.resolveBodies(&.{.program});
    const out = try sema.output.build(s);
    const layers = [2]bridge.Layer{ base_layer, program_layer };
    const br = try bridge.buildOver(a, s, loaded.br, .{ .natives = natives.resolve, .host_fns = interp_ir.hostMemberFn, .records = out.files, .layers = &layers });
    var an: Analysis = .{ .map = map, .s = s, .out = out, .br = br, .layers = layers };
    const census = try an.census(a, .program);
    if (census.len != 0) return failed(census);
    const prog = try lower.lowerProgramOver(a, s, br, loaded.lowered);
    if (prog.errors.items.len != 0) {
        var diag: std.ArrayList(u8) = .empty;
        for (prog.errors.items) |le| {
            const f = br.m.funcs.items[le.func.int()];
            try diag.print(a, "{s}: in {s}: {s}\n", .{ try spanWhere(a, &an, le.span), f.fqn, le.msg });
        }
        return failed(diag.items);
    }
    const main_sym = (try an.mainSym()) orelse return failed("no main function\n");
    const main = br.funcOfOpt(main_sym) orelse return failed("main has no id\n");
    return runMain(a, &an, main);
}

/// Runs `sources` over a base read back from its image and expects it to
/// print `want`.
pub fn expectOutputOverImage(sources: []const []const u8, want: []const u8) !void {
    var mem = ir.eval.hand.TestMemory.init();
    defer mem.deinit();
    const o = try runOverImage(mem.allocator(), sources);
    if (o.result != .ok) {
        std.debug.print("program over the base image {s}:\n{s}output so far:\n{s}\n", .{ @tagName(o.result), o.diag, o.output });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(want, o.output);
}

/// Runs `sources` over the whole base and over a baked one, and expects
/// both to print `want`.
pub fn expectOutputOver(sources: []const []const u8, want: []const u8) !void {
    try expectOutput(sources, want);
    var mem = ir.eval.hand.TestMemory.init();
    defer mem.deinit();
    const o = try runOver(mem.allocator(), sources);
    if (o.result != .ok) {
        std.debug.print("program over the baked base {s}:\n{s}output so far:\n{s}\n", .{ @tagName(o.result), o.diag, o.output });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(want, o.output);
    // And with the base read back from its image.
    try expectOutputOverImage(sources, want);
}

/// What `body.lowerBody` records for a construct a package's stub declined.
const not_lowered = "this construct is not lowered";

/// What `body.lowerBody` records for a node missing the record it needs:
/// `node N has no <kind> record`.
fn unrecorded(msg: []const u8) bool {
    return std.mem.startsWith(u8, msg, "node ") and std.mem.endsWith(u8, msg, " record") and std.mem.indexOf(u8, msg, " has no ") != null;
}

fn failed(diag: []const u8) Outcome {
    return .{ .output = "", .result = .failed, .diag = diag };
}

/// `path:line:col` of a span, found by its source file.
fn spanWhere(a: Allocator, an: *const Analysis, sp: span.Span) Allocator.Error![]const u8 {
    const src = an.map.getChecked(sp.file) orelse return "<unknown>";
    const lc = src.lineCol(sp.start);
    return std.fmt.allocPrint(a, "{s}:{d}:{d}", .{ src.path, lc.line, lc.col });
}

const MainCtx = struct { main: ir.FuncId, outcome: *?interp_ir.CallOutcome };

fn callMain(ctx: MainCtx, vm: *interp_ir.Vm) Allocator.Error!void {
    ctx.outcome.* = try vm.callMain(ctx.main);
}

fn runMain(a: Allocator, an: *Analysis, main: ir.FuncId) !Outcome {
    // Each program is its own run: the process-global caches keyed by the
    // addresses of a finished run's IR must not answer for this one's.
    interp_ir.resetRunGlobalCaches();
    defer interp_ir.resetRunGlobalCaches();
    // The sources' positions, which the CLI's run has too: a stack trace
    // and a lambda's class name read them.
    const saved_map = span.active_map;
    span.active_map = &an.map;
    defer span.active_map = saved_map;
    const module_ref = try runtime.ObjRef(ir.Module).init(a, an.br.m.*);
    var vm = try interp_ir.Vm.new(a, module_ref);
    defer vm.deinit();
    var cap = runtime.CaptureOutput.init(a);
    var outcome: ?interp_ir.CallOutcome = null;
    const prep = try vm.runCalls(cap.output(), MainCtx, .{ .main = main, .outcome = &outcome }, callMain);
    var text: std.ArrayList(u8) = .empty;
    for (cap.lines.items) |line| {
        try text.appendSlice(a, line);
        try text.append(a, '\n');
    }
    try text.appendSlice(a, cap.partial.items);
    if (prep) |e| return .{ .output = text.items, .result = .failed, .diag = try vmErrorText(a, e) };
    const o = outcome orelse return .{ .output = text.items, .result = .failed, .diag = "main did not run\n" };
    return switch (o) {
        .ok => .{ .output = text.items, .result = .ok, .diag = "" },
        .threw => |v| .{ .output = text.items, .result = .threw, .diag = try throwableClass(a, an, v) },
        .failed => |msg| {
            // An instruction whose arm the VM package has not filled: the
            // pipeline is not built yet, which the packages' tests skip on.
            if (std.mem.endsWith(u8, msg, " is not implemented")) return error.Unsupported;
            return .{ .output = text.items, .result = .failed, .diag = msg };
        },
    };
}

fn vmErrorText(a: Allocator, e: interp_ir.VmError) Allocator.Error![]const u8 {
    return switch (e) {
        .InvalidMain => "invalid main\n",
        .Eval => |msg| std.fmt.allocPrint(a, "{s}\n", .{msg}),
    };
}

/// The class of an uncaught throwable, by its id.
fn throwableClass(a: Allocator, an: *const Analysis, v: runtime.Value) Allocator.Error![]const u8 {
    const r = an.br.m.resolved orelse return "uncaught";
    const cid = ir.resolved.classOf(r, &v) orelse return std.fmt.allocPrint(a, "uncaught {s}", .{@tagName(std.meta.activeTag(v))});
    return an.br.m.classes.items[cid.int()].fqn;
}

/// `run`, then expects `result == .ok`, no census site, and `want` exactly.
pub fn expectOutput(sources: []const []const u8, want: []const u8) !void {
    var mem = ir.eval.hand.TestMemory.init();
    defer mem.deinit();
    const o = try run(mem.allocator(), sources);
    if (o.result != .ok) {
        std.debug.print("program {s}:\n{s}output so far:\n{s}\n", .{ @tagName(o.result), o.diag, o.output });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(want, o.output);
}

/// `run`, then expects an uncaught throwable of class `class_fqn`.
pub fn expectThrows(sources: []const []const u8, class_fqn: []const u8) !void {
    var mem = ir.eval.hand.TestMemory.init();
    defer mem.deinit();
    const o = try run(mem.allocator(), sources);
    if (o.result != .threw) {
        std.debug.print("program {s}, expected {s} thrown:\n{s}output so far:\n{s}\n", .{ @tagName(o.result), class_fqn, o.diag, o.output });
        return error.TestUnexpectedResult;
    }
    try std.testing.expectEqualStrings(class_fqn, o.diag);
}

test "the miniature base resolves with no census site" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const an = try analyze(a, &.{"fun main() {}"});
    const base = try an.census(a, .base);
    if (base.len != 0) std.debug.print("{s}", .{base});
    try std.testing.expectEqualStrings("", base);
    try std.testing.expectEqualStrings("", try an.census(a, .program));
    try std.testing.expectEqual(@as(u32, 0), an.out.orphans);
}

test "every bodyless function of the base is a native or an operator lowering binds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const an = try analyze(a, &.{"fun main() {}"});
    const s = an.s;
    const r = an.br.m.resolved.?;
    var missing: std.ArrayList(u8) = .empty;
    for (an.br.origin, 0..) |origin, i| {
        const d = switch (origin) {
            .decl, .getter => |d| d,
            else => continue,
        };
        const fl = s.syms.flags(d);
        if (fl.has_body or fl.synthetic) continue;
        if (s.syms.kind(d) == .property) {
            if (an.br.fieldOf(d) != null) continue;
        } else if (fl.operator or fl.infix or isOperatorName(s.str(s.syms.name(d)))) continue;
        if (r.func_native[i] != .none) continue;
        try missing.print(a, "{s}\n", .{an.br.m.funcs.items[i].fqn});
    }
    if (missing.items.len != 0) std.debug.print("unbound:\n{s}", .{missing.items});
    try std.testing.expectEqualStrings("", missing.items);
}

/// Operators lowering binds from its primitive table, written without the
/// `operator` modifier (`inv`, `unaryMinus` has it).
fn isOperatorName(n: []const u8) bool {
    return std.mem.eql(u8, n, "inv");
}

/// Skips while the lowering is not built.
fn skipUnbuilt(err: anyerror) anyerror {
    return if (err == error.Unsupported) error.SkipZigTest else err;
}

test "hello world runs end to end" {
    expectOutput(&.{"fun main() { println(\"hi\") }"}, "hi\n") catch |e| return skipUnbuilt(e);
}

test "an uncaught throwable is reported by its class" {
    expectThrows(&.{"fun main() { throw IllegalStateException(\"no\") }"}, "kotlin.IllegalStateException") catch |e| return skipUnbuilt(e);
}

test "main taking the program's arguments receives them" {
    expectOutput(&.{"fun main(args: Array<String>) { println(args.size) }"}, "0\n") catch |e| return skipUnbuilt(e);
}

test "a program without main is reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const an = try analyze(arena.allocator(), &.{"fun notMain() {}"});
    try std.testing.expect((try an.mainSym()) == null);
    const in_projected = try analyze(arena.allocator(), &.{"fun main(args: Array<in String>) {}\nfun main(x: Int) {}"});
    try std.testing.expect((try in_projected.mainSym()) == null);
}

test "a file's main taking the arguments runs over its parameterless one" {
    expectOutput(&.{
        \\fun main() { println("no arguments") }
        \\fun main(args: Array<String>) { println("arguments " + args.size) }
    }, "arguments 0\n") catch |e| return skipUnbuilt(e);
    expectOutput(&.{
        \\fun main(vararg args: String?) { println("vararg") }
        \\fun main() { println("no arguments") }
    }, "vararg\n") catch |e| return skipUnbuilt(e);
    expectOutput(&.{
        \\fun main(x: Int) { println("not an entry point") }
        \\fun main() { println("no arguments") }
    }, "no arguments\n") catch |e| return skipUnbuilt(e);
}

test "a main that does not return Unit is no entry point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // kotlinc 2.4.20 compiles each, and the JVM launcher finds no main to
    // run: "Main method not found", or "Main method must return a value of
    // type void" for a `main(String[])` returning something.
    const not_entries = [_][]const u8{
        "fun main() = run { println(\"ran\"); 1 }",
        "fun main(): Nothing = throw IllegalStateException(\"x\")",
        "fun main(): Unit? { println(\"n\"); return null }",
        "fun main(vararg args: String): Int { println(\"v\"); return 0 }",
        "fun main(args: Array<String>): Int { println(\"a\"); return 0 }\nfun main() { println(\"p\") }",
        "fun <T> main() { println(\"g\") }",
    };
    for (not_entries) |src| {
        const an = try analyze(a, &.{src});
        if ((try an.mainSym()) != null) {
            std.debug.print("an entry point: {s}\n", .{src});
            return error.TestUnexpectedResult;
        }
    }
}

test "a main returning Unit through an alias, or suspending, is the entry point" {
    expectOutput(&.{
        \\typealias U = Unit
        \\fun main(): U { println("u") }
    }, "u\n") catch |e| return skipUnbuilt(e);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "suspend fun main() { println(\"s\") }",
        "suspend fun main(args: Array<String>) { println(\"sa\") }\nfun main() { println(\"p\") }",
    }) |src| {
        const an = try analyze(a, &.{src});
        const main = (try an.mainSym()) orelse return error.TestUnexpectedResult;
        try std.testing.expect(an.s.syms.flags(main).suspend_);
    }
}

test "a file is initialized before its main runs and when another file calls into it" {
    expectOutput(&.{
        \\val greeting = run { println("main file init"); "hi" }
        \\fun main() {
        \\    println("main")
        \\    println(bar())
        \\    println(greeting)
        \\    println(touched)
        \\    println(fib(10))
        \\}
        \\fun fib(n: Int): Int = if (n < 2) n else fib(n - 1) + fib(n - 2)
        ,
        \\var touched = false
        \\val y = foo()
        \\private fun foo(): Int {
        \\    println("lib file init")
        \\    touched = true
        \\    return 42
        \\}
        \\fun bar() = 117
    }, "main file init\nmain\nlib file init\n117\nhi\ntrue\n55\n") catch |e| return skipUnbuilt(e);
}

test "of several files declaring main, the last given runs" {
    expectOutput(&.{
        "fun main() { println(\"first\") }",
        "package other\nfun main(args: Array<out String>?) { println(\"second\") }",
    }, "second\n") catch |e| return skipUnbuilt(e);
    expectOutput(&.{
        "package other\nfun main(args: Array<String>) { println(\"first\") }",
        "fun main() { println(\"second\") }",
    }, "second\n") catch |e| return skipUnbuilt(e);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(mini_base);
    std.testing.refAllDecls(natives);
    std.testing.refAllDecls(lower_census);
    std.testing.refAllDecls(pipeline);
    _ = @import("tests/vm.zig");
    _ = @import("tests/bridge.zig");
    _ = @import("tests/spine.zig");
    _ = @import("tests/calls.zig");
    _ = @import("tests/control.zig");
    _ = @import("tests/classes.zig");
    _ = @import("tests/inline.zig");
    _ = @import("tests/over.zig");
    _ = @import("tests/compose.zig");
    _ = @import("tests/image.zig");
}
