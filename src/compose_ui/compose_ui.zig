//! Native Skia backend for the `klio.compose.ui` pack.
//!
//! The compose UI layer composes into a LayoutNode tree and records a display
//! list of draw ops in pure Kotlin (klioMain). This module replays that list onto
//! a real Skia raster surface through libklio_skia (built by build.zig with the
//! platform C++ toolchain) and encodes a PNG. The shared library is dlopened
//! lazily so the interpreter never links libstdc++/Skia; a build without the Skia
//! libs simply has no renderer here (skiaRender returns 0).

const std = @import("std");
const runtime = @import("runtime");
const stdlib = @import("stdlib");

const Value = runtime.Value;
const EvalResult = runtime.EvalResult;
const CallCtx = runtime.CallCtx;
const HostBindings = stdlib.HostBindings;
const Error = std.mem.Allocator.Error;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("klio.compose.ui.__composeui_skiaRender", skiaRender);
    return b;
}

fn argInt(v: Value) i64 {
    return switch (v) {
        .Int => |i| i,
        .Long => |i| i,
        .Short => |i| @intCast(i),
        .Byte => |i| @intCast(i),
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Skia backend — the rasterizer. The klio.compose.ui draw pass records a display
// list of draw ops; this replays it onto a Skia raster surface and encodes a PNG.
// ---------------------------------------------------------------------------

const SkSurface = anyopaque;

/// The dlopened Skia shim entry points (see src/compose_ui/skia_shim.cpp).
const Skia = struct {
    lib: std.DynLib,
    new: *const fn (c_int, c_int) callconv(.c) ?*SkSurface,
    free: *const fn (?*SkSurface) callconv(.c) void,
    clear: *const fn (?*SkSurface, u32) callconv(.c) void,
    fillRect: *const fn (?*SkSurface, f32, f32, f32, f32, u32) callconv(.c) void,
    strokeRect: *const fn (?*SkSurface, f32, f32, f32, f32, f32, u32) callconv(.c) void,
    fillRRect: *const fn (?*SkSurface, f32, f32, f32, f32, f32, f32, u32) callconv(.c) void,
    fillCircle: *const fn (?*SkSurface, f32, f32, f32, u32) callconv(.c) void,
    drawLine: *const fn (?*SkSurface, f32, f32, f32, f32, f32, u32) callconv(.c) void,
    drawText: *const fn (?*SkSurface, [*:0]const u8, f32, f32, f32, u32) callconv(.c) void,
    savePng: *const fn (?*SkSurface, [*:0]const u8) callconv(.c) c_int,
    encodePng: *const fn (?*SkSurface, *usize) callconv(.c) ?[*]u8,
    freeBuffer: *const fn ([*]u8) callconv(.c) void,
};

var skia_state: ?Skia = null;
var skia_tried: bool = false;

/// The platform shared-library file name build.zig installs.
const skia_lib_name = switch (@import("builtin").os.tag) {
    .macos => "libklio_skia.dylib",
    .windows => "klio_skia.dll",
    else => "libklio_skia.so",
};

/// Open + resolve the Skia shim once. Search order: `$KLIO_SKIA_LIB` (a full
/// path), then the bare name via the loader path (zig-out/lib on `LD_LIBRARY_PATH`
/// / rpath / a system install). Cached (including a failed load) for the process.
fn loadSkia() ?*Skia {
    if (skia_state) |*s| return s;
    if (skia_tried) return null;
    skia_tried = true;

    var lib = openSkiaLib() orelse return null;
    const F = struct {
        fn get(l: *std.DynLib, comptime name: []const u8, comptime sym: [:0]const u8) ?@FieldType(Skia, name) {
            return l.lookup(@FieldType(Skia, name), sym);
        }
    };
    const s = Skia{
        .lib = lib,
        .new = F.get(&lib, "new", "klio_skia_new") orelse return skiaLoadFail(&lib),
        .free = F.get(&lib, "free", "klio_skia_free") orelse return skiaLoadFail(&lib),
        .clear = F.get(&lib, "clear", "klio_skia_clear") orelse return skiaLoadFail(&lib),
        .fillRect = F.get(&lib, "fillRect", "klio_skia_fill_rect") orelse return skiaLoadFail(&lib),
        .strokeRect = F.get(&lib, "strokeRect", "klio_skia_stroke_rect") orelse return skiaLoadFail(&lib),
        .fillRRect = F.get(&lib, "fillRRect", "klio_skia_fill_rrect") orelse return skiaLoadFail(&lib),
        .fillCircle = F.get(&lib, "fillCircle", "klio_skia_fill_circle") orelse return skiaLoadFail(&lib),
        .drawLine = F.get(&lib, "drawLine", "klio_skia_draw_line") orelse return skiaLoadFail(&lib),
        .drawText = F.get(&lib, "drawText", "klio_skia_draw_text") orelse return skiaLoadFail(&lib),
        .savePng = F.get(&lib, "savePng", "klio_skia_save_png") orelse return skiaLoadFail(&lib),
        .encodePng = F.get(&lib, "encodePng", "klio_skia_encode_png") orelse return skiaLoadFail(&lib),
        .freeBuffer = F.get(&lib, "freeBuffer", "klio_skia_free_buffer") orelse return skiaLoadFail(&lib),
    };
    skia_state = s;
    return &skia_state.?;
}

fn skiaLoadFail(lib: *std.DynLib) ?*Skia {
    lib.close();
    return null;
}

fn openSkiaLib() ?std.DynLib {
    if (runtime.getenvSlice("KLIO_SKIA_LIB")) |p| {
        if (std.DynLib.open(p)) |l| return l else |_| {}
    }
    if (std.DynLib.open(skia_lib_name)) |l| return l else |_| {}
    return null;
}

fn parseU32Hex(s: []const u8) u32 {
    return std.fmt.parseInt(u32, s, 16) catch 0;
}

fn parseF32(s: []const u8) f32 {
    return std.fmt.parseFloat(f32, s) catch 0;
}

/// `__composeui_skiaRender(path, width, height, displayList): Long`
///
/// `displayList` is newline-separated draw ops replayed onto a Skia raster
/// surface; colors are 8-hex-digit ARGB. Ops:
///   clear AARRGGBB
///   rect   x y w h AARRGGBB
///   srect  x y w h strokeWidth AARRGGBB
///   rrect  x y w h rx ry AARRGGBB
///   circle cx cy r AARRGGBB
///   line   x0 y0 x1 y1 strokeWidth AARRGGBB
///   text   x y size AARRGGBB <utf8 text to end of line>
/// Writes a PNG to `path` and returns an FNV-1a checksum of the encoded bytes
/// (0 if Skia is unavailable or the render failed).
fn skiaRender(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 4) return ok(Value.newLong(0));
    if (ctx.args[0] != .String or ctx.args[3] != .String) return ok(Value.newLong(0));

    const skia = loadSkia() orelse return ok(Value.newLong(0));

    const width: c_int = @intCast(@max(1, argInt(ctx.args[1])));
    const height: c_int = @intCast(@max(1, argInt(ctx.args[2])));
    const surface = skia.new(width, height) orelse return ok(Value.newLong(0));
    defer skia.free(surface);

    const dg = ctx.args[3].String.borrow();
    defer dg.deinit();
    replay(skia, surface, dg.get().bytes);

    // Write the PNG (best-effort) via a null-terminated path.
    const a = ctx.allocator;
    const pg = ctx.args[0].String.borrow();
    defer pg.deinit();
    const path_z = std.fmt.allocPrintSentinel(a, "{s}", .{pg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer a.free(path_z);
    _ = skia.savePng(surface, path_z.ptr);

    // Checksum the encoded bytes for a deterministic test assertion.
    var len: usize = 0;
    const buf = skia.encodePng(surface, &len) orelse return ok(Value.newLong(0));
    defer skia.freeBuffer(buf);
    var h: u64 = 1469598103934665603;
    for (buf[0..len]) |byte| h = (h ^ byte) *% 1099511628211;
    return ok(Value.newLong(@bitCast(h)));
}

fn replay(skia: *Skia, surface: *SkSurface, list: []const u8) void {
    var lines = std.mem.splitScalar(u8, list, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
        const op = it.next() orelse continue;
        if (std.mem.eql(u8, op, "clear")) {
            skia.clear(surface, parseU32Hex(it.next() orelse continue));
        } else if (std.mem.eql(u8, op, "rect")) {
            const x = parseF32(it.next() orelse continue);
            const y = parseF32(it.next() orelse continue);
            const w = parseF32(it.next() orelse continue);
            const hh = parseF32(it.next() orelse continue);
            skia.fillRect(surface, x, y, w, hh, parseU32Hex(it.next() orelse continue));
        } else if (std.mem.eql(u8, op, "srect")) {
            const x = parseF32(it.next() orelse continue);
            const y = parseF32(it.next() orelse continue);
            const w = parseF32(it.next() orelse continue);
            const hh = parseF32(it.next() orelse continue);
            const sw = parseF32(it.next() orelse continue);
            skia.strokeRect(surface, x, y, w, hh, sw, parseU32Hex(it.next() orelse continue));
        } else if (std.mem.eql(u8, op, "rrect")) {
            const x = parseF32(it.next() orelse continue);
            const y = parseF32(it.next() orelse continue);
            const w = parseF32(it.next() orelse continue);
            const hh = parseF32(it.next() orelse continue);
            const rx = parseF32(it.next() orelse continue);
            const ry = parseF32(it.next() orelse continue);
            skia.fillRRect(surface, x, y, w, hh, rx, ry, parseU32Hex(it.next() orelse continue));
        } else if (std.mem.eql(u8, op, "circle")) {
            const cx = parseF32(it.next() orelse continue);
            const cy = parseF32(it.next() orelse continue);
            const r = parseF32(it.next() orelse continue);
            skia.fillCircle(surface, cx, cy, r, parseU32Hex(it.next() orelse continue));
        } else if (std.mem.eql(u8, op, "line")) {
            const x0 = parseF32(it.next() orelse continue);
            const y0 = parseF32(it.next() orelse continue);
            const x1 = parseF32(it.next() orelse continue);
            const y1 = parseF32(it.next() orelse continue);
            const sw = parseF32(it.next() orelse continue);
            skia.drawLine(surface, x0, y0, x1, y1, sw, parseU32Hex(it.next() orelse continue));
        } else if (std.mem.eql(u8, op, "text")) {
            const x = parseF32(it.next() orelse continue);
            const y = parseF32(it.next() orelse continue);
            const size = parseF32(it.next() orelse continue);
            const color = parseU32Hex(it.next() orelse continue);
            // The remainder of the line is the (possibly space-containing) text.
            const s = std.mem.trimStart(u8, it.rest(), " ");
            var buf: [256]u8 = undefined;
            const n = @min(s.len, buf.len - 1);
            @memcpy(buf[0..n], s[0..n]);
            buf[n] = 0;
            skia.drawText(surface, @ptrCast(&buf), x, y, size, color);
        }
    }
}

const testing = std.testing;

test "hostBindings registers the skia render sink" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("klio.compose.ui.__composeui_skiaRender") != null);
    try testing.expectEqual(@as(usize, 1), b.len());
}

test "skiaRender guards arg shapes and no-ops without the library" {
    // The Skia shared library is not present in the unit-test environment, so
    // loadSkia() fails and skiaRender returns 0 — this exercises the arg-shape
    // guards + the display-list entry without needing the .so.
    const a = testing.allocator;
    var host: TestHost = .{};
    var path = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "/tmp/klio_skia_test.png")) };
    defer path.String.deinit();
    var list = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "clear FF000000\nrect 0 0 4 4 FFFFFFFF\n")) };
    defer list.String.deinit();
    // Too few args -> 0.
    const short = [_]Value{path};
    var ctx0 = host.ctx(&short);
    try testing.expectEqual(@as(i64, 0), (try skiaRender(&ctx0)).ok.Long);
    // Well-formed call: 0 when the lib is absent (unit tests), any value when present.
    const args = [_]Value{ path, Value.newInt(4), Value.newInt(4), list };
    var ctx = host.ctx(&args);
    _ = (try skiaRender(&ctx)).ok.Long;
}

const TestHost = struct {
    fn ctx(self: *TestHost, args: []const Value) CallCtx {
        _ = self;
        return .{
            .args = args,
            .out = undefined,
            .host = undefined,
            .allocator = testing.allocator,
        };
    }
};

test {
    testing.refAllDecls(@This());
}
