//! Native bindings for the `klio.compose.ui` pack — the offscreen rendering
//! sink for the Compose UI core.
//!
//! The compose UI layer composes into a LayoutNode tree and rasterizes it into a
//! software pixel buffer in pure Kotlin (klioMain). This module is the host-side
//! backend the plan calls for: "a headless/offscreen surface that dumps a
//! PNG/pixel buffer makes the UI testable deterministically." It encodes the
//! rasterized buffer into a real P6 (binary) PPM image — a standard, viewable
//! format — writes it to disk (best-effort), and returns a checksum of the
//! encoded bytes so a deterministic test can assert the render without depending
//! on the file. A native Skia/skiko binding would slot in here as a richer
//! DrawScope backend; PPM is the "pure software rasterizer for a first cut".

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
    try b.register("klio.compose.ui.__composeui_writePpm", writePpm);
    try b.register("klio.compose.ui.__composeui_skiaRender", skiaRender);
    return b;
}

// ---------------------------------------------------------------------------
// Skia backend — the real rasterizer. The klio.compose.ui draw pass records a
// display list of draw ops; this replays it onto a Skia raster surface through
// libklio_skia (built by build.zig with the platform C++ toolchain) and encodes
// a PNG. The shared library is dlopened lazily so the interpreter never links
// libstdc++/Skia; a build without the Skia libs simply has no renderer here.
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
        }
        // `text` needs a bundled font (empty SkFontMgr = no faces); skipped until
        // one is embedded, so it is intentionally unhandled here for now.
    }
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

/// The rendering palette: color index (as emitted by the klioMain PixelCanvas)
/// to an RGB triple. Index 0 is the empty/background cell.
const palette = [10][3]u8{
    .{ 24, 24, 28 }, // 0 transparent / empty
    .{ 0, 0, 0 }, // 1 black
    .{ 240, 240, 240 }, // 2 white
    .{ 220, 60, 60 }, // 3 red
    .{ 60, 200, 90 }, // 4 green
    .{ 70, 110, 235 }, // 5 blue
    .{ 235, 220, 70 }, // 6 yellow
    .{ 70, 210, 210 }, // 7 cyan
    .{ 210, 70, 210 }, // 8 magenta
    .{ 130, 130, 138 }, // 9 gray
};

fn paletteFor(hex: u8) [3]u8 {
    const idx: usize = switch (hex) {
        '0'...'9' => hex - '0',
        'a'...'f' => 10 + (hex - 'a'),
        'A'...'F' => 10 + (hex - 'A'),
        else => 0,
    };
    if (idx < palette.len) return palette[idx];
    return palette[0];
}

/// `__composeui_writePpm(path, width, height, hexData, scale): Long`
///
/// `hexData` is `width*height` hex digits, one color index per pixel (row-major).
/// Encodes a P6 PPM scaled by `scale` (each cell becomes a scale x scale block),
/// writes it to `path` (best-effort — a failure is ignored), and returns an
/// FNV-1a checksum of the full encoded byte stream (deterministic per pixels +
/// scale, so a corpus test can assert the render).
fn writePpm(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 5) return ok(Value.newLong(0));
    if (ctx.args[0] != .String or ctx.args[3] != .String) return ok(Value.newLong(0));

    const pg = ctx.args[0].String.borrow();
    defer pg.deinit();
    const path = pg.get().bytes;

    const width: usize = @intCast(@max(0, argInt(ctx.args[1])));
    const height: usize = @intCast(@max(0, argInt(ctx.args[2])));
    const scale: usize = @intCast(@max(1, argInt(ctx.args[4])));

    const hg = ctx.args[3].String.borrow();
    defer hg.deinit();
    const hex = hg.get().bytes;
    if (hex.len < width * height or width == 0 or height == 0) return ok(Value.newLong(0));

    const a = ctx.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);

    const ow = width * scale;
    const oh = height * scale;
    var hdr: [64]u8 = undefined;
    // 64 bytes is ample for "P6\n<w> <h>\n255\n"; the format cannot overflow it.
    const header = std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ ow, oh }) catch unreachable;
    try buf.appendSlice(a, header);

    var row: usize = 0;
    while (row < height) : (row += 1) {
        var sy: usize = 0;
        while (sy < scale) : (sy += 1) {
            var col: usize = 0;
            while (col < width) : (col += 1) {
                const rgb = paletteFor(hex[row * width + col]);
                var sx: usize = 0;
                while (sx < scale) : (sx += 1) {
                    try buf.appendSlice(a, &rgb);
                }
            }
        }
    }

    // Best-effort write of the real image file (a failure is non-fatal — the
    // checksum below still proves the render encoded).
    {
        var threaded: std.Io.Threaded = .init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items }) catch {};
    }

    // FNV-1a over the encoded bytes — deterministic proof the render happened.
    var h: u64 = 1469598103934665603;
    for (buf.items) |byte| {
        h = (h ^ byte) *% 1099511628211;
    }
    return ok(Value.newLong(@bitCast(h)));
}

const testing = std.testing;

test "hostBindings registers the render sinks" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("klio.compose.ui.__composeui_writePpm") != null);
    try testing.expect(b.resolve("klio.compose.ui.__composeui_skiaRender") != null);
    try testing.expectEqual(@as(usize, 2), b.len());
}

test "writePpm encodes a deterministic checksum" {
    const a = testing.allocator;
    var host: TestHost = .{};
    var path = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "/tmp/klio_compose_ui_test.ppm")) };
    defer path.String.deinit();
    var hex = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "1234")) };
    defer hex.String.deinit();
    const args = [_]Value{ path, Value.newInt(2), Value.newInt(2), hex, Value.newInt(2) };
    var ctx = host.ctx(&args);
    const c1 = (try writePpm(&ctx)).ok.Long;
    var ctx2 = host.ctx(&args);
    const c2 = (try writePpm(&ctx2)).ok.Long;
    try testing.expectEqual(c1, c2);
    try testing.expect(c1 != 0);
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
