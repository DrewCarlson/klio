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

test "hostBindings registers the ppm writer" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("klio.compose.ui.__composeui_writePpm") != null);
    try testing.expectEqual(@as(usize, 1), b.len());
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
