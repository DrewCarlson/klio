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
const IntrinsicHost = runtime.IntrinsicHost;
const Output = runtime.Output;
const HostBindings = stdlib.HostBindings;
const Error = std.mem.Allocator.Error;

fn ok(v: Value) EvalResult {
    return .{ .ok = v };
}

/// Diagnostic: with `KLIO_RSS_LOG` set, print current RSS on each rendered frame.
/// A manual window drag then traces whether memory climbs (and settles), showing
/// whether the resize growth is heap churn or the stack high-water mark.
var rss_log_gate: enum { unknown, on, off } = .unknown;
fn rssLog() void {
    if (rss_log_gate == .unknown) {
        rss_log_gate = if (runtime.getenvSlice("KLIO_RSS_LOG") != null) .on else .off;
    }
    if (rss_log_gate != .on) return;
    const kb = runtime.currentRssKb() orelse return;
    std.debug.print("[rss] {} MB\n", .{kb / 1024});
}

pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("androidx.compose.foundation.__composeui_hostOs", hostOs);
    try b.register("klio.compose.ui.__composeui_skiaRender", skiaRender);
    try b.register("klio.compose.ui.__composeui_measureText", measureText);
    try b.register("klio.compose.ui.__composeui_winOpen", winOpen);
    try b.register("klio.compose.ui.__composeui_winRender", winRender);
    try b.register("klio.compose.ui.__composeui_winPoll", winPoll);
    try b.register("klio.compose.ui.__composeui_winClose", winClose);
    try b.register("klio.compose.ui.__composeui_winSurface", winSurfaceOf);
    try b.register("klio.compose.ui.__composeui_winPresent", winPresent);
    try b.register("klio.compose.ui.__composeui_winClear", winClear);
    // The real-engine window driver (androidx.compose.ui.window.KlioWindow)
    // declares the same host entrypoints under its own package.
    try b.register("androidx.compose.ui.window.__composeui_winOpen", winOpen);
    try b.register("androidx.compose.ui.window.__composeui_winProbe", winProbe);
    try b.register("androidx.compose.ui.window.__composeui_winSetTitle", winSetTitle);
    try b.register("androidx.compose.ui.window.__composeui_winSetSize", winSetSize);
    try b.register("androidx.compose.ui.window.__composeui_winPoll", winPoll);
    try b.register("androidx.compose.ui.window.__composeui_winClose", winClose);
    try b.register("androidx.compose.ui.window.__composeui_winSurface", winSurfaceOf);
    try b.register("androidx.compose.ui.window.__composeui_winPresent", winPresent);
    try b.register("androidx.compose.ui.window.__composeui_winClear", winClear);
    try b.register("androidx.compose.ui.window.__composeui_isHosted", isHosted);
    try b.register("androidx.compose.ui.window.__composeui_setFrameCallback", setFrameCallback);
    try b.register("androidx.compose.ui.graphics.__skia_path_op", pathOp);
    try b.register("androidx.compose.ui.graphics.__skia_surf_new", surfNew);
    try b.register("androidx.compose.ui.graphics.__skia_surf_save_png", surfSavePng);
    try b.register("androidx.compose.ui.graphics.__skia_surf_free", surfFree);
    try b.register("androidx.compose.ui.graphics.__skia_c_save", canvasSave);
    try b.register("androidx.compose.ui.graphics.__skia_c_restore", canvasRestore);
    try b.register("androidx.compose.ui.graphics.__skia_c_translate", canvasTranslate);
    try b.register("androidx.compose.ui.graphics.__skia_c_scale", canvasScale);
    try b.register("androidx.compose.ui.graphics.__skia_c_rotate", canvasRotate);
    try b.register("androidx.compose.ui.graphics.__skia_c_skew", canvasSkew);
    try b.register("androidx.compose.ui.graphics.__skia_c_clip_rect", canvasClipRect);
    try b.register("androidx.compose.ui.graphics.__skia_c_clip_path", canvasClipPath);
    try b.register("androidx.compose.ui.graphics.__skia_c_set_shader", canvasSetShader);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_rect", canvasDrawRect);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_rrect", canvasDrawRRect);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_oval", canvasDrawOval);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_circle", canvasDrawCircle);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_line", canvasDrawLine);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_path", canvasDrawPath);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_text", canvasDrawText);
    try b.register("androidx.compose.ui.graphics.__composeui_text_width", textWidth);
    try b.register("androidx.compose.ui.graphics.__composeui_font_metric", fontMetric);
    try b.register("androidx.compose.ui.graphics.__skia_c_concat", canvasConcat);
    try b.register("androidx.compose.ui.graphics.__skia_surf_pixel", surfPixel);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_text2", canvasDrawText2);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_surface", canvasDrawSurface);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_surface_rect", canvasDrawSurfaceRect);
    // The skparagraph engine, consumed by the androidx.compose.ui.text pack.
    try b.register("androidx.compose.ui.text.platform.__skia_para_new", paraNew);
    try b.register("androidx.compose.ui.text.platform.__skia_para_layout", paraLayout);
    try b.register("androidx.compose.ui.text.platform.__skia_para_metric", paraMetric);
    try b.register("androidx.compose.ui.text.platform.__skia_para_line_metric", paraLineMetric);
    try b.register("androidx.compose.ui.text.platform.__skia_para_offset_at", paraOffsetAt);
    try b.register("androidx.compose.ui.text.platform.__skia_para_box", paraBox);
    try b.register("androidx.compose.ui.text.platform.__skia_para_range_rect", paraRangeRect);
    try b.register("androidx.compose.ui.text.platform.__skia_para_range_rect_count", paraRangeRectCount);
    try b.register("androidx.compose.ui.text.platform.__skia_para_word", paraWord);
    try b.register("androidx.compose.ui.text.platform.__skia_para_line_for", paraLineFor);
    try b.register("androidx.compose.ui.text.platform.__skia_para_paint", paraPaint);
    try b.register("androidx.compose.ui.text.platform.__skia_para_free", paraFree);
    try b.register("androidx.compose.ui.text.platform.__skia_font_register", fontRegister);
    try b.register("androidx.compose.ui.text.platform.__skia_para_ph_count", paraPhCount);
    try b.register("androidx.compose.ui.text.platform.__skia_para_ph_rect", paraPhRect);
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

fn argFloat(v: Value) f32 {
    return switch (v) {
        .Float => |x| x,
        .Double => |x| @floatCast(x),
        .Int => |i| @floatFromInt(i),
        .Long => |i| @floatFromInt(i),
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// Skia backend — the rasterizer. The klio.compose.ui draw pass records a display
// list of draw ops; this replays it onto a Skia raster surface and encodes a PNG.
// ---------------------------------------------------------------------------

const SkSurface = anyopaque;
const SkWindow = anyopaque;

/// The dlopened Skia shim entry points (see src/compose_ui/skia_shim.cpp).
const Skia = struct {
    lib: std.DynLib,
    new: *const fn (c_int, c_int) callconv(.c) ?*SkSurface,
    newGpu: *const fn (c_int, c_int) callconv(.c) ?*SkSurface,
    free: *const fn (?*SkSurface) callconv(.c) void,
    clear: *const fn (?*SkSurface, u32) callconv(.c) void,
    fillRect: *const fn (?*SkSurface, f32, f32, f32, f32, u32) callconv(.c) void,
    strokeRect: *const fn (?*SkSurface, f32, f32, f32, f32, f32, u32) callconv(.c) void,
    fillRRect: *const fn (?*SkSurface, f32, f32, f32, f32, f32, f32, u32) callconv(.c) void,
    fillCircle: *const fn (?*SkSurface, f32, f32, f32, u32) callconv(.c) void,
    drawLine: *const fn (?*SkSurface, f32, f32, f32, f32, f32, u32) callconv(.c) void,
    drawText: *const fn (?*SkSurface, [*:0]const u8, f32, f32, f32, u32) callconv(.c) void,
    drawParagraph: *const fn (?*SkSurface, [*:0]const u8, f32, f32, f32, f32, u32, c_int) callconv(.c) void,
    measureParagraph: *const fn ([*:0]const u8, f32, f32) callconv(.c) f32,
    savePng: *const fn (?*SkSurface, [*:0]const u8) callconv(.c) c_int,
    encodePng: *const fn (?*SkSurface, *usize) callconv(.c) ?[*]u8,
    freeBuffer: *const fn ([*]u8) callconv(.c) void,
    // Optional graphics helpers (present in current builds; guarded so a stale
    // shared library degrades instead of failing the whole Skia load).
    pathOp: ?PathOpFn,
    freeCstr: ?FreeCstrFn,
    cSave: ?CVoidFn,
    cRestore: ?CVoidFn,
    cTranslate: ?CXYFn,
    cScale: ?CXYFn,
    cRotate: ?CRotateFn,
    cSkew: ?CXYFn,
    cClipRect: ?CClipRectFn,
    cClipPath: ?CClipPathFn,
    cSetShader: ?CSetShaderFn,
    cDrawRect: ?CDrawRectFn,
    cDrawRRect: ?CDrawRRectFn,
    cDrawOval: ?CDrawRectFn,
    cDrawCircle: ?CDrawCircleFn,
    cDrawLine: ?CDrawLineFn,
    cDrawPath: ?CDrawPathFn,
    cMeasureTextWidth: ?CMeasureTextWidthFn,
    cFontMetric: ?CFontMetricFn,
    cConcat: ?CConcatFn,
    surfPixel: ?SurfPixelFn,
    cDrawText2: ?CDrawText2Fn,
    cDrawSurface: ?CDrawSurfaceFn,
    cDrawSurfaceRect: ?CDrawSurfaceRectFn,
    paraNew: ?ParaNewFn,
    paraLayout: ?ParaLayoutFn,
    paraMetric: ?ParaMetricFn,
    paraLineMetric: ?ParaLineMetricFn,
    paraOffsetAt: ?ParaOffsetAtFn,
    paraBox: ?ParaBoxFn,
    paraRangeRect: ?ParaRangeRectFn,
    paraRangeRectCount: ?ParaRangeRectCountFn,
    paraWord: ?ParaWordFn,
    paraLineFor: ?ParaLineForFn,
    paraPaint: ?ParaPaintFn,
    paraFree: ?ParaFreeFn,
    fontRegister: ?FontRegisterFn,
    paraPhCount: ?ParaPhCountFn,
    paraPhRect: ?ParaPhRectFn,
    winOpen: *const fn (c_int, c_int, [*:0]const u8) callconv(.c) ?*SkWindow,
    /// Optional: mobile backends (iOS) attach to an OS-provided surface layer
    /// instead of creating a window. Null on desktop backends (Cocoa/SDL), where
    /// `winOpen` creates the window.
    winAttach: ?WinAttachFn,
    winSurface: *const fn (?*SkWindow) callconv(.c) ?*SkSurface,
    winPresent: *const fn (?*SkWindow) callconv(.c) void,
    winPoll: *const fn (?*SkWindow, c_int, *c_int, *c_int) callconv(.c) c_int,
    winClose: *const fn (?*SkWindow) callconv(.c) void,
    /// Optional: only the native live-resize backends (Cocoa) export this. A
    /// backend that reports resizes purely through `winPoll` (SDL) leaves it null.
    winSetResizeCb: ?ResizeCbFn,
    winSetTitle: ?*const fn (?*SkWindow, [*:0]const u8) callconv(.c) void,
    winSetSize: ?*const fn (?*SkWindow, c_int, c_int) callconv(.c) void,
    /// Optional: window icon from encoded PNG bytes (a bundle's `--icon`).
    winSetIconPng: ?*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void,
};

const WinAttachFn = *const fn (?*anyopaque, c_int, c_int, f64) callconv(.c) ?*SkWindow;
const ResizeCbFn = *const fn (?*SkWindow, ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void, ?*anyopaque) callconv(.c) void;
const PathOpFn = *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) ?[*:0]u8;
const FreeCstrFn = *const fn ([*:0]u8) callconv(.c) void;

// Canvas (SkCanvas over a surface) entry points. Optional so a stale shared
// library degrades to no-op drawing instead of failing the whole Skia load.
const CVoidFn = *const fn (?*SkSurface) callconv(.c) void;
const CXYFn = *const fn (?*SkSurface, f32, f32) callconv(.c) void;
const CRotateFn = *const fn (?*SkSurface, f32) callconv(.c) void;
const CClipRectFn = *const fn (?*SkSurface, f32, f32, f32, f32, c_int) callconv(.c) void;
const CClipPathFn = *const fn (?*SkSurface, [*:0]const u8, c_int) callconv(.c) void;
const CSetShaderFn = *const fn (?*SkSurface, [*:0]const u8) callconv(.c) void;
// The trailing (argb, style, strokeWidth, cap, join, aa) is the packed paint.
const CDrawRectFn = *const fn (?*SkSurface, f32, f32, f32, f32, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CDrawRRectFn = *const fn (?*SkSurface, f32, f32, f32, f32, f32, f32, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CDrawCircleFn = *const fn (?*SkSurface, f32, f32, f32, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CDrawLineFn = *const fn (?*SkSurface, f32, f32, f32, f32, u32, f32, c_int, c_int) callconv(.c) void;
const CDrawPathFn = *const fn (?*SkSurface, [*:0]const u8, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CMeasureTextWidthFn = *const fn ([*:0]const u8, f32) callconv(.c) f32;
const CFontMetricFn = *const fn (f32, c_int) callconv(.c) f32;
const CConcatFn = *const fn (?*SkSurface, f32, f32, f32, f32, f32, f32) callconv(.c) void;
const SurfPixelFn = *const fn (?*SkSurface, c_int, c_int) callconv(.c) u32;
const CDrawText2Fn = *const fn (?*SkSurface, [*:0]const u8, f32, f32, f32, u32, c_int) callconv(.c) void;
const CDrawSurfaceFn = *const fn (?*SkSurface, ?*SkSurface, f32, f32) callconv(.c) void;
const CDrawSurfaceRectFn = *const fn (?*SkSurface, ?*SkSurface, f32, f32, f32, f32, f32, f32, f32, f32) callconv(.c) void;
const KlioPara = anyopaque;
const ParaNewFn = *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*KlioPara;
const ParaLayoutFn = *const fn (?*KlioPara, f32) callconv(.c) void;
const ParaMetricFn = *const fn (?*KlioPara, c_int) callconv(.c) f32;
const ParaLineMetricFn = *const fn (?*KlioPara, c_int, c_int) callconv(.c) f32;
const ParaOffsetAtFn = *const fn (?*KlioPara, f32, f32) callconv(.c) c_int;
const ParaBoxFn = *const fn (?*KlioPara, c_int, c_int, c_int) callconv(.c) f32;
const ParaRangeRectFn = *const fn (?*KlioPara, c_int, c_int, c_int, c_int) callconv(.c) f32;
const ParaRangeRectCountFn = *const fn (?*KlioPara, c_int, c_int) callconv(.c) c_int;
const ParaWordFn = *const fn (?*KlioPara, c_int) callconv(.c) i64;
const ParaLineForFn = *const fn (?*KlioPara, c_int) callconv(.c) c_int;
const ParaPaintFn = *const fn (?*KlioPara, ?*SkSurface, f32, f32) callconv(.c) void;
const ParaFreeFn = *const fn (?*KlioPara) callconv(.c) void;
const FontRegisterFn = *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) i32;
const ParaPhCountFn = *const fn (?*KlioPara) callconv(.c) i32;
const ParaPhRectFn = *const fn (?*KlioPara, i32, i32) callconv(.c) f32;

var skia_state: ?Skia = null;
var skia_tried: bool = false;

/// The app host (an iOS `.app`) that statically links the Skia shim opts in by
/// declaring `pub const klio_skia_static` in its root; the plain interpreter does
/// not, so on iOS it emits no shim symbol references and stays headless.
const use_static_skia = @hasDecl(@import("root"), "klio_skia_static");

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

    // iOS bans dlopen of a runtime-written dylib, so the shim is linked
    // statically and resolved from symbols rather than a DynLib — but only when
    // the app host opts in (it links libklio_skia.a). The plain interpreter exe
    // does not, so it emits no shim references and renders headless there.
    if (comptime @import("builtin").os.tag == .ios) {
        if (comptime use_static_skia) return loadSkiaStatic();
        return null;
    }

    var lib = openSkiaLib() orelse return null;
    const F = struct {
        fn get(l: *std.DynLib, comptime name: []const u8, comptime sym: [:0]const u8) ?@FieldType(Skia, name) {
            return l.lookup(@FieldType(Skia, name), sym);
        }
    };
    const s = Skia{
        .lib = lib,
        .new = F.get(&lib, "new", "klio_skia_new") orelse return skiaLoadFail(&lib),
        .newGpu = F.get(&lib, "newGpu", "klio_skia_new_gpu") orelse return skiaLoadFail(&lib),
        .free = F.get(&lib, "free", "klio_skia_free") orelse return skiaLoadFail(&lib),
        .clear = F.get(&lib, "clear", "klio_skia_clear") orelse return skiaLoadFail(&lib),
        .fillRect = F.get(&lib, "fillRect", "klio_skia_fill_rect") orelse return skiaLoadFail(&lib),
        .strokeRect = F.get(&lib, "strokeRect", "klio_skia_stroke_rect") orelse return skiaLoadFail(&lib),
        .fillRRect = F.get(&lib, "fillRRect", "klio_skia_fill_rrect") orelse return skiaLoadFail(&lib),
        .fillCircle = F.get(&lib, "fillCircle", "klio_skia_fill_circle") orelse return skiaLoadFail(&lib),
        .drawLine = F.get(&lib, "drawLine", "klio_skia_draw_line") orelse return skiaLoadFail(&lib),
        .drawText = F.get(&lib, "drawText", "klio_skia_draw_text") orelse return skiaLoadFail(&lib),
        .drawParagraph = F.get(&lib, "drawParagraph", "klio_skia_draw_paragraph") orelse return skiaLoadFail(&lib),
        .measureParagraph = F.get(&lib, "measureParagraph", "klio_skia_measure_paragraph") orelse return skiaLoadFail(&lib),
        .savePng = F.get(&lib, "savePng", "klio_skia_save_png") orelse return skiaLoadFail(&lib),
        .encodePng = F.get(&lib, "encodePng", "klio_skia_encode_png") orelse return skiaLoadFail(&lib),
        .freeBuffer = F.get(&lib, "freeBuffer", "klio_skia_free_buffer") orelse return skiaLoadFail(&lib),
        .pathOp = lib.lookup(PathOpFn, "klio_skia_path_op"),
        .freeCstr = lib.lookup(FreeCstrFn, "klio_skia_free_cstr"),
        .cSave = lib.lookup(CVoidFn, "klio_skia_c_save"),
        .cRestore = lib.lookup(CVoidFn, "klio_skia_c_restore"),
        .cTranslate = lib.lookup(CXYFn, "klio_skia_c_translate"),
        .cScale = lib.lookup(CXYFn, "klio_skia_c_scale"),
        .cRotate = lib.lookup(CRotateFn, "klio_skia_c_rotate"),
        .cSkew = lib.lookup(CXYFn, "klio_skia_c_skew"),
        .cClipRect = lib.lookup(CClipRectFn, "klio_skia_c_clip_rect"),
        .cClipPath = lib.lookup(CClipPathFn, "klio_skia_c_clip_path"),
        .cSetShader = lib.lookup(CSetShaderFn, "klio_skia_c_set_shader"),
        .cDrawRect = lib.lookup(CDrawRectFn, "klio_skia_c_draw_rect"),
        .cDrawRRect = lib.lookup(CDrawRRectFn, "klio_skia_c_draw_rrect"),
        .cDrawOval = lib.lookup(CDrawRectFn, "klio_skia_c_draw_oval"),
        .cDrawCircle = lib.lookup(CDrawCircleFn, "klio_skia_c_draw_circle"),
        .cDrawLine = lib.lookup(CDrawLineFn, "klio_skia_c_draw_line"),
        .cDrawPath = lib.lookup(CDrawPathFn, "klio_skia_c_draw_path"),
        .cMeasureTextWidth = lib.lookup(CMeasureTextWidthFn, "klio_skia_measure_text_width"),
        .cFontMetric = lib.lookup(CFontMetricFn, "klio_skia_font_metric"),
        .cConcat = lib.lookup(CConcatFn, "klio_skia_c_concat"),
        .surfPixel = lib.lookup(SurfPixelFn, "klio_skia_surf_pixel"),
        .cDrawText2 = lib.lookup(CDrawText2Fn, "klio_skia_c_draw_text2"),
        .cDrawSurface = lib.lookup(CDrawSurfaceFn, "klio_skia_c_draw_surface"),
        .cDrawSurfaceRect = lib.lookup(CDrawSurfaceRectFn, "klio_skia_c_draw_surface_rect"),
        .paraNew = lib.lookup(ParaNewFn, "klio_skia_para_new"),
        .paraLayout = lib.lookup(ParaLayoutFn, "klio_skia_para_layout"),
        .paraMetric = lib.lookup(ParaMetricFn, "klio_skia_para_metric"),
        .paraLineMetric = lib.lookup(ParaLineMetricFn, "klio_skia_para_line_metric"),
        .paraOffsetAt = lib.lookup(ParaOffsetAtFn, "klio_skia_para_offset_at"),
        .paraBox = lib.lookup(ParaBoxFn, "klio_skia_para_box"),
        .paraRangeRect = lib.lookup(ParaRangeRectFn, "klio_skia_para_range_rect"),
        .paraRangeRectCount = lib.lookup(ParaRangeRectCountFn, "klio_skia_para_range_rect_count"),
        .paraWord = lib.lookup(ParaWordFn, "klio_skia_para_word"),
        .paraLineFor = lib.lookup(ParaLineForFn, "klio_skia_para_line_for"),
        .paraPaint = lib.lookup(ParaPaintFn, "klio_skia_para_paint"),
        .paraFree = lib.lookup(ParaFreeFn, "klio_skia_para_free"),
        .fontRegister = lib.lookup(FontRegisterFn, "klio_skia_font_register"),
        .paraPhCount = lib.lookup(ParaPhCountFn, "klio_skia_para_ph_count"),
        .paraPhRect = lib.lookup(ParaPhRectFn, "klio_skia_para_ph_rect"),
        .winOpen = F.get(&lib, "winOpen", "klio_win_open") orelse return skiaLoadFail(&lib),
        .winAttach = lib.lookup(WinAttachFn, "klio_win_attach"),
        .winSurface = F.get(&lib, "winSurface", "klio_win_surface") orelse return skiaLoadFail(&lib),
        .winPresent = F.get(&lib, "winPresent", "klio_win_present") orelse return skiaLoadFail(&lib),
        .winPoll = F.get(&lib, "winPoll", "klio_win_poll") orelse return skiaLoadFail(&lib),
        .winClose = F.get(&lib, "winClose", "klio_win_close") orelse return skiaLoadFail(&lib),
        // Optional native-live-resize hook (Cocoa only); absent on SDL builds.
        .winSetResizeCb = lib.lookup(ResizeCbFn, "klio_win_set_resize_cb"),
        // Optional (older shims lack them): recomposition-driven window params.
        .winSetTitle = lib.lookup(*const fn (?*SkWindow, [*:0]const u8) callconv(.c) void, "klio_win_set_title"),
        .winSetSize = lib.lookup(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_size"),
        .winSetIconPng = lib.lookup(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_win_set_icon_png"),
    };
    skia_state = s;
    return &skia_state.?;
}

fn skiaLoadFail(lib: *std.DynLib) ?*Skia {
    lib.close();
    return null;
}

/// Reference a statically-linked shim symbol directly. Reached only from the app
/// host (which links libklio_skia.a and opts in via `use_static_skia`), so the
/// symbol is always defined at the app link — the plain interpreter never emits
/// these references.
fn externSym(comptime T: type, comptime name: [:0]const u8) T {
    return @extern(T, .{ .name = name });
}

/// iOS resolution of the shim from statically-linked symbols (no dlopen). Mirrors
/// `loadSkia`'s field set. The shim ships with the interpreter, so every symbol
/// is present; optional fields are bound directly too.
fn loadSkiaStatic() ?*Skia {
    const s = Skia{
        .lib = undefined,
        .new = externSym(@FieldType(Skia, "new"), "klio_skia_new"),
        .newGpu = externSym(@FieldType(Skia, "newGpu"), "klio_skia_new_gpu"),
        .free = externSym(@FieldType(Skia, "free"), "klio_skia_free"),
        .clear = externSym(@FieldType(Skia, "clear"), "klio_skia_clear"),
        .fillRect = externSym(@FieldType(Skia, "fillRect"), "klio_skia_fill_rect"),
        .strokeRect = externSym(@FieldType(Skia, "strokeRect"), "klio_skia_stroke_rect"),
        .fillRRect = externSym(@FieldType(Skia, "fillRRect"), "klio_skia_fill_rrect"),
        .fillCircle = externSym(@FieldType(Skia, "fillCircle"), "klio_skia_fill_circle"),
        .drawLine = externSym(@FieldType(Skia, "drawLine"), "klio_skia_draw_line"),
        .drawText = externSym(@FieldType(Skia, "drawText"), "klio_skia_draw_text"),
        .drawParagraph = externSym(@FieldType(Skia, "drawParagraph"), "klio_skia_draw_paragraph"),
        .measureParagraph = externSym(@FieldType(Skia, "measureParagraph"), "klio_skia_measure_paragraph"),
        .savePng = externSym(@FieldType(Skia, "savePng"), "klio_skia_save_png"),
        .encodePng = externSym(@FieldType(Skia, "encodePng"), "klio_skia_encode_png"),
        .freeBuffer = externSym(@FieldType(Skia, "freeBuffer"), "klio_skia_free_buffer"),
        .pathOp = externSym(PathOpFn, "klio_skia_path_op"),
        .freeCstr = externSym(FreeCstrFn, "klio_skia_free_cstr"),
        .cSave = externSym(CVoidFn, "klio_skia_c_save"),
        .cRestore = externSym(CVoidFn, "klio_skia_c_restore"),
        .cTranslate = externSym(CXYFn, "klio_skia_c_translate"),
        .cScale = externSym(CXYFn, "klio_skia_c_scale"),
        .cRotate = externSym(CRotateFn, "klio_skia_c_rotate"),
        .cSkew = externSym(CXYFn, "klio_skia_c_skew"),
        .cClipRect = externSym(CClipRectFn, "klio_skia_c_clip_rect"),
        .cClipPath = externSym(CClipPathFn, "klio_skia_c_clip_path"),
        .cSetShader = externSym(CSetShaderFn, "klio_skia_c_set_shader"),
        .cDrawRect = externSym(CDrawRectFn, "klio_skia_c_draw_rect"),
        .cDrawRRect = externSym(CDrawRRectFn, "klio_skia_c_draw_rrect"),
        .cDrawOval = externSym(CDrawRectFn, "klio_skia_c_draw_oval"),
        .cDrawCircle = externSym(CDrawCircleFn, "klio_skia_c_draw_circle"),
        .cDrawLine = externSym(CDrawLineFn, "klio_skia_c_draw_line"),
        .cDrawPath = externSym(CDrawPathFn, "klio_skia_c_draw_path"),
        .cMeasureTextWidth = externSym(CMeasureTextWidthFn, "klio_skia_measure_text_width"),
        .cFontMetric = externSym(CFontMetricFn, "klio_skia_font_metric"),
        .cConcat = externSym(CConcatFn, "klio_skia_c_concat"),
        .surfPixel = externSym(SurfPixelFn, "klio_skia_surf_pixel"),
        .cDrawText2 = externSym(CDrawText2Fn, "klio_skia_c_draw_text2"),
        .cDrawSurface = externSym(CDrawSurfaceFn, "klio_skia_c_draw_surface"),
        .cDrawSurfaceRect = externSym(CDrawSurfaceRectFn, "klio_skia_c_draw_surface_rect"),
        .paraNew = externSym(ParaNewFn, "klio_skia_para_new"),
        .paraLayout = externSym(ParaLayoutFn, "klio_skia_para_layout"),
        .paraMetric = externSym(ParaMetricFn, "klio_skia_para_metric"),
        .paraLineMetric = externSym(ParaLineMetricFn, "klio_skia_para_line_metric"),
        .paraOffsetAt = externSym(ParaOffsetAtFn, "klio_skia_para_offset_at"),
        .paraBox = externSym(ParaBoxFn, "klio_skia_para_box"),
        .paraRangeRect = externSym(ParaRangeRectFn, "klio_skia_para_range_rect"),
        .paraRangeRectCount = externSym(ParaRangeRectCountFn, "klio_skia_para_range_rect_count"),
        .paraWord = externSym(ParaWordFn, "klio_skia_para_word"),
        .paraLineFor = externSym(ParaLineForFn, "klio_skia_para_line_for"),
        .paraPaint = externSym(ParaPaintFn, "klio_skia_para_paint"),
        .paraFree = externSym(ParaFreeFn, "klio_skia_para_free"),
        .fontRegister = externSym(FontRegisterFn, "klio_skia_font_register"),
        .paraPhCount = externSym(ParaPhCountFn, "klio_skia_para_ph_count"),
        .paraPhRect = externSym(ParaPhRectFn, "klio_skia_para_ph_rect"),
        .winOpen = externSym(@FieldType(Skia, "winOpen"), "klio_win_open"),
        .winAttach = externSym(WinAttachFn, "klio_win_attach"),
        .winSurface = externSym(@FieldType(Skia, "winSurface"), "klio_win_surface"),
        .winPresent = externSym(@FieldType(Skia, "winPresent"), "klio_win_present"),
        .winPoll = externSym(@FieldType(Skia, "winPoll"), "klio_win_poll"),
        .winClose = externSym(@FieldType(Skia, "winClose"), "klio_win_close"),
        .winSetResizeCb = externSym(ResizeCbFn, "klio_win_set_resize_cb"),
        .winSetTitle = externSym(*const fn (?*SkWindow, [*:0]const u8) callconv(.c) void, "klio_win_set_title"),
        .winSetSize = externSym(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_size"),
        .winSetIconPng = externSym(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_win_set_icon_png"),
    };
    skia_state = s;
    return &skia_state.?;
}

// ---------------------------------------------------------------------------
// Bundle-mode configuration: a bundle boot installs the extracted shim's
// path, the app name (the default window title), and the window-icon PNG
// before the program runs. All set-up-time, read-only during execution.
// ---------------------------------------------------------------------------

var skia_lib_override: ?[]const u8 = null;
var window_icon_png: ?[]const u8 = null;
var default_window_title: ?[:0]const u8 = null;

/// Load the Skia shim from this exact path (highest priority, ahead of
/// `KLIO_SKIA_LIB`). The slice must outlive the process.
pub fn setSkiaLibPath(path: []const u8) void {
    skia_lib_override = path;
}

/// PNG bytes applied as the window icon when each window opens. The
/// slice must outlive the process (a bundle's mmap qualifies).
pub fn setWindowIconPng(png: []const u8) void {
    window_icon_png = png;
}

/// Title used when the program opens a window without naming one.
pub fn setDefaultWindowTitle(title: [:0]const u8) void {
    default_window_title = title;
}

fn openSkiaLib() ?std.DynLib {
    if (skia_lib_override) |p| {
        if (std.DynLib.open(p)) |l| return l else |_| {}
    }
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
    // Opt-in GPU (Ganesh+EGL) surface when KLIO_SKIA_GPU is set and the backend was
    // built with it; otherwise (or on GPU init failure) fall back to raster.
    const gpu = runtime.getenvSlice("KLIO_SKIA_GPU") != null;
    const surface = (if (gpu) skia.newGpu(width, height) else null) orelse
        skia.new(width, height) orelse return ok(Value.newLong(0));
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

/// `__composeui_measureText(text, width, size): Long` — the wrapped height (px,
/// ceil'd) of `text` laid out to `width` at font `size`. 0 when Skia is
/// unavailable, so the caller can fall back to an estimate.
fn measureText(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3 or ctx.args[0] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const tg = ctx.args[0].String.borrow();
    defer tg.deinit();
    const text_z = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{tg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(text_z);
    const width: f32 = @floatFromInt(@max(1, argInt(ctx.args[1])));
    const size: f32 = @floatFromInt(@max(1, argInt(ctx.args[2])));
    const h = skia.measureParagraph(text_z.ptr, width, size);
    return ok(Value.newLong(@intFromFloat(@ceil(h))));
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
        } else if (std.mem.eql(u8, op, "para")) {
            const x = parseF32(it.next() orelse continue);
            const y = parseF32(it.next() orelse continue);
            const w = parseF32(it.next() orelse continue);
            const size = parseF32(it.next() orelse continue);
            const alignment: c_int = std.fmt.parseInt(c_int, it.next() orelse continue, 10) catch 0;
            const color = parseU32Hex(it.next() orelse continue);
            const s = std.mem.trimStart(u8, it.rest(), " ");
            var buf: [2048]u8 = undefined;
            const n = @min(s.len, buf.len - 1);
            @memcpy(buf[0..n], s[0..n]);
            buf[n] = 0;
            skia.drawParagraph(surface, @ptrCast(&buf), x, y, w, size, color, alignment);
        }
    }
}

// ---------------------------------------------------------------------------
// Windowing intrinsics — open an on-screen window, replay a display list into
// it each frame, and pump input events. The window handle is passed to Kotlin as
// a Long (the KlioWindow pointer). All no-op / report "closed" when Skia or a
// windowing backend is unavailable, so a headless build degrades gracefully.
// ---------------------------------------------------------------------------

/// `__composeui_winOpen(width, height, title): Long` — the window handle, or 0.
/// `__composeui_winProbe(): Long` — 1 when a windowing backend (Skia native
/// lib with a window driver) is loadable in this environment, else 0. Lets
/// `application {}` report headless without opening anything.
/// `__composeui_winSetTitle(handle, title): Long` — retitle a live window.
fn winSetTitle(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.winSetTitle orelse return ok(Value.newLong(0));
    const tg = ctx.args[1].String.borrow();
    defer tg.deinit();
    const title_z = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{tg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(title_z);
    f(win, title_z.ptr);
    return ok(Value.newLong(1));
}

/// `__composeui_winSetSize(handle, w, h): Long` — resize a live window.
fn winSetSize(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.winSetSize orelse return ok(Value.newLong(0));
    f(win, @intCast(@max(1, argInt(ctx.args[1]))), @intCast(@max(1, argInt(ctx.args[2]))));
    return ok(Value.newLong(1));
}

fn winProbe(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    _ = skia;
    return ok(Value.newLong(1));
}

fn winOpen(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3 or ctx.args[2] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const w: c_int = @intCast(@max(1, argInt(ctx.args[0])));
    const h: c_int = @intCast(@max(1, argInt(ctx.args[1])));
    const tg = ctx.args[2].String.borrow();
    defer tg.deinit();
    // A window the program leaves untitled takes the bundle's app name.
    const kotlin_title = tg.get().bytes;
    const title_bytes = if (kotlin_title.len == 0)
        (default_window_title orelse kotlin_title)
    else
        kotlin_title;
    const title_z = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{title_bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(title_z);
    // Mobile: attach to the app-provided surface layer instead of creating a
    // window (the OS owns the view). Desktop backends have no winAttach and
    // create the window via winOpen.
    var win_opt: ?*SkWindow = null;
    if (surface_layer) |layer| {
        if (skia.winAttach) |attach| win_opt = attach(layer, w, h, surface_scale);
    }
    const win = (win_opt orelse skia.winOpen(w, h, title_z.ptr)) orelse return ok(Value.newLong(0));
    if (window_icon_png) |png| {
        if (skia.winSetIconPng) |set_icon| set_icon(win, png.ptr, png.len);
    }
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(win)))));
}

/// `__composeui_winRender(handle, displayList): Long` — replay the list into the
/// window's surface and present it. Returns 1 on success, 0 otherwise.
fn winRender(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surface = skia.winSurface(win) orelse return ok(Value.newLong(0));
    const dg = ctx.args[1].String.borrow();
    defer dg.deinit();
    // Clear to opaque black before replaying so frames don't accumulate on the
    // persistent window surface (the display list draws the UI on top, and a
    // double-buffered GPU swapchain would otherwise show a stale back buffer).
    skia.clear(surface, 0xFF000000);
    replay(skia, surface, dg.get().bytes);
    skia.winPresent(win);
    rssLog();
    return ok(Value.newLong(1));
}

/// Registered for the duration of a `winPoll` so the shim's live-resize observer
/// can drive a frame while the modal drag blocks the VM's loop. Holds the render
/// callback (a live poll argument, so no separate GC root is needed) plus the host
/// handle and output to invoke it through.
const ResizeCb = struct {
    host: IntrinsicHost,
    callback: Value,
    out: Output,
};

/// C trampoline the shim calls on each live-resize step: invokes the Kotlin render
/// callback with the new (width, height) in points, which recomposes and redraws.
fn resizeTrampoline(user: ?*anyopaque, w: c_int, h: c_int) callconv(.c) void {
    const rc: *ResizeCb = @ptrCast(@alignCast(user orelse return));
    var args = [_]Value{ Value.newInt(@intCast(w)), Value.newInt(@intCast(h)) };
    _ = rc.host.invokeCallable(&rc.callback, &args, rc.out) catch {};
}

/// `__composeui_winPoll(handle, timeoutMs, onResize?): Long` — wait up to timeoutMs
/// for an event; returns `(type << 32) | (x << 16) | y` where type is 0 none, 1
/// click, 2 close. When `onResize: (Int, Int) -> Unit` is supplied it is invoked
/// during a live resize so the UI reflows in realtime.
fn winPoll(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(2 << 32));
    const skia = loadSkia() orelse return ok(Value.newLong(2 << 32));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(2 << 32));
    const timeout: c_int = @intCast(@max(0, argInt(ctx.args[1])));
    // Register the live-resize render callback (if given) for this poll only. `rc`
    // stays valid on the stack for the whole `skia.winPoll` call, and the callback
    // is a live argument so the VM keeps it rooted.
    var rc: ResizeCb = undefined;
    // The live-resize callback only fires on backends that export the hook
    // (Cocoa). SDL reports resizes through winPoll's event code, so skip it there.
    const has_cb = ctx.args.len >= 3 and ctx.args[2] != .Null and skia.winSetResizeCb != null;
    if (has_cb) {
        rc = .{ .host = ctx.host, .callback = ctx.args[2], .out = ctx.out };
        skia.winSetResizeCb.?(win, resizeTrampoline, &rc);
    }
    var x: c_int = 0;
    var y: c_int = 0;
    const t = skia.winPoll(win, timeout, &x, &y);
    if (has_cb) skia.winSetResizeCb.?(win, null, null);
    const packed_ev: i64 = (@as(i64, t) << 32) |
        (@as(i64, @intCast(std.math.clamp(x, 0, 0xFFFF))) << 16) |
        @as(i64, @intCast(std.math.clamp(y, 0, 0xFFFF)));
    return ok(Value.newLong(packed_ev));
}

// ---------------------------------------------------------------------------
// OS-driven frame loop (mobile): the platform owns the run loop and calls
// klio_render_frame each vsync on the resident VM. `application` (KlioWindow)
// registers a per-frame render callback and returns instead of looping; the app
// shell drives it (iOS CADisplayLink). See plans/MOBILE-TARGETS.md.
// ---------------------------------------------------------------------------

// The OS-provided surface layer + geometry the app installs before running the
// program. When set, winOpen attaches to it (klio_win_attach) instead of
// creating a window, and __composeui_isHosted reports true.
var surface_layer: ?*anyopaque = null;
var surface_w: c_int = 0;
var surface_h: c_int = 0;
var surface_scale: f64 = 1.0;

/// Install the app-provided surface layer (an iOS CAMetalLayer) + geometry. The
/// app shell calls this before running the program.
pub export fn klio_set_surface(layer: ?*anyopaque, w: c_int, h: c_int, scale: f64) void {
    surface_layer = layer;
    surface_w = w;
    surface_h = h;
    surface_scale = scale;
}

/// The resident per-frame render callback: the Kotlin render lambda plus the host
/// and output to invoke it through. Unlike ResizeCb this outlives the call that
/// registered it — the program's main returns while the VM stays resident, and
/// the mobile run keeps everything on a process-lifetime arena, so the captured
/// composition survives across frames.
const FrameCb = struct {
    host: IntrinsicHost,
    callback: Value,
    out: Output,
    set: bool = false,
};
var frame_cb: FrameCb = .{ .host = undefined, .callback = undefined, .out = undefined };

/// `__composeui_isHosted(): Boolean` — true when the platform owns the frame loop
/// (an app surface has been installed). `application` then registers a frame
/// callback and returns instead of running its own loop.
fn isHosted(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(Value{ .Bool = surface_layer != null });
}

/// `__composeui_setFrameCallback(cb: () -> Boolean): Long` — store the render
/// callback the platform frame source invokes each frame.
fn setFrameCallback(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    frame_cb = .{ .host = ctx.host, .callback = ctx.args[0], .out = ctx.out, .set = true };
    return ok(Value.newLong(1));
}

/// Render one frame: invoke the resident Kotlin render callback. Called by the
/// app shell's frame source (iOS CADisplayLink) on the main thread — the same
/// thread the resident VM ran main on, so it is a plain same-thread re-entry
/// (the resizeTrampoline mechanism).
pub export fn klio_render_frame() void {
    if (!frame_cb.set) return;
    var args = [_]Value{};
    _ = frame_cb.host.invokeCallable(&frame_cb.callback, &args, frame_cb.out) catch {};
}

/// `__composeui_winSurface(handle): Long` — the window's Skia surface handle,
//// The host OS, as a lowercase name. foundation's `DesktopPlatform` needs it: the
/// desktop key mapping is genuinely different per platform (macOS binds the text
/// shortcuts to Meta, Linux and Windows to Ctrl), so defaulting would give the
/// wrong bindings on a real macOS host. Upstream reads
/// `System.getProperty("os.name")`, which klio has no JVM to serve.
fn hostOs(ctx: *CallCtx) Error!EvalResult {
    const name = switch (@import("builtin").os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => "unknown",
    };
    const a = ctx.allocator;
    return ok(Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, name)) });
}

// usable with the `androidx.compose.ui.graphics.__skia_c_*` draw intrinsics
/// (the same surface type `__skia_surf_new` yields), or 0. The real ui engine's
/// `KlioCanvas` draws frames directly onto it.
fn winSurfaceOf(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surface = skia.winSurface(win) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(surface)))));
}

/// `__composeui_winPresent(handle): Long` — present the window's surface.
fn winPresent(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    skia.winPresent(win);
    return ok(Value.newLong(1));
}

/// `__composeui_winClear(handle, argb): Long` — clear the window's surface.
fn winClear(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surface = skia.winSurface(win) orelse return ok(Value.newLong(0));
    skia.clear(surface, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(argInt(ctx.args[1])))))));
    return ok(Value.newLong(1));
}

/// `__composeui_winClose(handle): Long`
fn winClose(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (winHandle(ctx.args[0])) |win| skia.winClose(win);
    return ok(Value.newLong(0));
}

fn winHandle(v: Value) ?*SkWindow {
    const h: u64 = @bitCast(argInt(v));
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

/// `androidx.compose.ui.graphics.__skia_path_op(a: String, b: String, op: Int): String?`
/// — combine two serialized path command buffers with a boolean op (SkPathOps).
/// Returns the result command buffer, or null when the op fails or no Skia
/// backend is available (the caller then leaves its path unchanged).
fn pathOp(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3 or ctx.args[0] != .String or ctx.args[1] != .String) return ok(Value.Null);
    const skia = loadSkia() orelse return ok(Value.Null);
    const op_fn = skia.pathOp orelse return ok(Value.Null);
    const free_fn = skia.freeCstr orelse return ok(Value.Null);
    const a = ctx.allocator;
    const ag = ctx.args[0].String.borrow();
    defer ag.deinit();
    const bg = ctx.args[1].String.borrow();
    defer bg.deinit();
    const az = std.fmt.allocPrintSentinel(a, "{s}", .{ag.get().bytes}, 0) catch return ok(Value.Null);
    defer a.free(az);
    const bz = std.fmt.allocPrintSentinel(a, "{s}", .{bg.get().bytes}, 0) catch return ok(Value.Null);
    defer a.free(bz);
    const op: c_int = @intCast(argInt(ctx.args[2]));
    const res = op_fn(az.ptr, bz.ptr, op) orelse return ok(Value.Null);
    defer free_fn(res);
    const owned = try a.dupe(u8, std.mem.span(res));
    return ok(Value{ .String = try runtime.strInitOwned(a, owned) });
}

// ---------------------------------------------------------------------------
// Canvas intrinsics — a real androidx.compose.ui.graphics.Canvas actual draws
// through these onto an offscreen surface (handle = the KlioSurface pointer as
// a Long). All no-op when Skia / the canvas entry points are unavailable.
// ---------------------------------------------------------------------------

fn surfArg(v: Value) ?*SkSurface {
    const h: u64 = @bitCast(argInt(v));
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

fn argU32(v: Value) u32 {
    return @bitCast(@as(i32, @truncate(argInt(v))));
}

/// `__skia_surf_new(width, height): Long` — a raster surface handle, or 0.
fn surfNew(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const w: c_int = @intCast(@max(0, argInt(ctx.args[0])));
    const h: c_int = @intCast(@max(0, argInt(ctx.args[1])));
    const surf = skia.new(w, h) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(surf)))));
}

/// `__skia_surf_save_png(handle, path): Long` — 1 on success.
fn surfSavePng(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const pg = ctx.args[1].String.borrow();
    defer pg.deinit();
    const path_z = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{pg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(path_z);
    // klio_skia_save_png returns 0 on success (a C-style error code).
    return ok(Value.newLong(if (skia.savePng(surf, path_z.ptr) == 0) 1 else 0));
}

/// `__skia_surf_free(handle): Long`
fn surfFree(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (surfArg(ctx.args[0])) |surf| skia.free(surf);
    return ok(Value.newLong(0));
}

/// `__skia_surf_pixel(handle, x, y): Long` — one pixel as ARGB (0 when out of
/// range, unreadable, or headless).
fn surfPixel(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.surfPixel orelse return ok(Value.newLong(0));
    const x: c_int = @intCast(argInt(ctx.args[1]));
    const y: c_int = @intCast(argInt(ctx.args[2]));
    return ok(Value.newLong(@intCast(f(surf, x, y))));
}

/// `__skia_c_draw_surface(dst, src, x, y): Long` — blit src's contents at (x, y).
fn canvasDrawSurface(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 4) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const dst = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const src = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    if (skia.cDrawSurface) |f| f(dst, src, argFloat(ctx.args[2]), argFloat(ctx.args[3]));
    return ok(Value.newLong(0));
}

/// `__skia_c_draw_surface_rect(dst, src, sl, st, sr, sb, dl, dt, dr, db): Long`
/// — map src's (sl,st,sr,sb) onto dst's (dl,dt,dr,db).
fn canvasDrawSurfaceRect(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 10) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const dst = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const src = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    if (skia.cDrawSurfaceRect) |f| f(
        dst,
        src,
        argFloat(ctx.args[2]),
        argFloat(ctx.args[3]),
        argFloat(ctx.args[4]),
        argFloat(ctx.args[5]),
        argFloat(ctx.args[6]),
        argFloat(ctx.args[7]),
        argFloat(ctx.args[8]),
        argFloat(ctx.args[9]),
    );
    return ok(Value.newLong(0));
}

/// `__skia_para_new(textUtf8, spec): Long` — build a styled paragraph; 0 when
/// no Skia backend / no font is available (callers fall back to stub metrics).
fn paraNew(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .String or ctx.args[1] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.paraNew orelse return ok(Value.newLong(0));
    const tg = ctx.args[0].String.borrow();
    defer tg.deinit();
    const sg = ctx.args[1].String.borrow();
    defer sg.deinit();
    const txt = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{tg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(txt);
    const spec = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{sg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(spec);
    const para = f(txt.ptr, spec.ptr) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(para)))));
}

fn paraArg(v: Value) ?*KlioPara {
    const h = argInt(v);
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(@as(u64, @bitCast(h)))));
}

fn paraLayout(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (skia.paraLayout) |f| if (paraArg(ctx.args[0])) |p| f(p, argFloat(ctx.args[1]));
    return ok(Value.newLong(0));
}

fn paraMetric(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(.{ .Float = 0 });
    const skia = loadSkia() orelse return ok(.{ .Float = 0 });
    const f = skia.paraMetric orelse return ok(.{ .Float = 0 });
    const p = paraArg(ctx.args[0]) orelse return ok(.{ .Float = 0 });
    return ok(.{ .Float = f(p, @intCast(argInt(ctx.args[1]))) });
}

fn paraLineMetric(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(.{ .Float = 0 });
    const skia = loadSkia() orelse return ok(.{ .Float = 0 });
    const f = skia.paraLineMetric orelse return ok(.{ .Float = 0 });
    const p = paraArg(ctx.args[0]) orelse return ok(.{ .Float = 0 });
    return ok(.{ .Float = f(p, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2]))) });
}

fn paraOffsetAt(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newInt(0));
    const skia = loadSkia() orelse return ok(Value.newInt(0));
    const f = skia.paraOffsetAt orelse return ok(Value.newInt(0));
    const p = paraArg(ctx.args[0]) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(f(p, argFloat(ctx.args[1]), argFloat(ctx.args[2]))));
}

fn paraBox(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 4) return ok(.{ .Float = 0 });
    const skia = loadSkia() orelse return ok(.{ .Float = 0 });
    const f = skia.paraBox orelse return ok(.{ .Float = 0 });
    const p = paraArg(ctx.args[0]) orelse return ok(.{ .Float = 0 });
    return ok(.{ .Float = f(p, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2])), @intCast(argInt(ctx.args[3]))) });
}

fn paraRangeRect(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 5) return ok(.{ .Float = 0 });
    const skia = loadSkia() orelse return ok(.{ .Float = 0 });
    const f = skia.paraRangeRect orelse return ok(.{ .Float = 0 });
    const p = paraArg(ctx.args[0]) orelse return ok(.{ .Float = 0 });
    return ok(.{ .Float = f(p, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2])), @intCast(argInt(ctx.args[3])), @intCast(argInt(ctx.args[4]))) });
}

fn paraRangeRectCount(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newInt(0));
    const skia = loadSkia() orelse return ok(Value.newInt(0));
    const f = skia.paraRangeRectCount orelse return ok(Value.newInt(0));
    const p = paraArg(ctx.args[0]) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(f(p, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2])))));
}

fn paraWord(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.paraWord orelse return ok(Value.newLong(0));
    const p = paraArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(f(p, @intCast(argInt(ctx.args[1])))));
}

fn paraLineFor(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newInt(0));
    const skia = loadSkia() orelse return ok(Value.newInt(0));
    const f = skia.paraLineFor orelse return ok(Value.newInt(0));
    const p = paraArg(ctx.args[0]) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(f(p, @intCast(argInt(ctx.args[1])))));
}

fn paraPaint(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 4) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.paraPaint orelse return ok(Value.newLong(0));
    const p = paraArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    f(p, surf, argFloat(ctx.args[2]), argFloat(ctx.args[3]));
    return ok(Value.newLong(0));
}

fn paraFree(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (skia.paraFree) |f| if (paraArg(ctx.args[0])) |p| f(p);
    return ok(Value.newLong(0));
}

fn fontRegister(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .String or ctx.args[1] != .String) return ok(Value{ .Bool = false });
    const skia = loadSkia() orelse return ok(Value{ .Bool = false });
    const f = skia.fontRegister orelse return ok(Value{ .Bool = false });
    const pg = ctx.args[0].String.borrow();
    defer pg.deinit();
    const fg = ctx.args[1].String.borrow();
    defer fg.deinit();
    const path = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{pg.get().bytes}, 0) catch return ok(Value{ .Bool = false });
    defer ctx.allocator.free(path);
    const fam = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{fg.get().bytes}, 0) catch return ok(Value{ .Bool = false });
    defer ctx.allocator.free(fam);
    return ok(Value{ .Bool = f(path.ptr, fam.ptr) != 0 });
}

fn paraPhCount(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.paraPhCount orelse return ok(Value.newLong(0));
    const p = paraArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(f(p)));
}

fn paraPhRect(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value{ .Float = 0 });
    const skia = loadSkia() orelse return ok(Value{ .Float = 0 });
    const f = skia.paraPhRect orelse return ok(Value{ .Float = 0 });
    const p = paraArg(ctx.args[0]) orelse return ok(Value{ .Float = 0 });
    const i = ctx.args[1].asI64() orelse 0;
    const w = ctx.args[2].asI64() orelse 0;
    return ok(Value{ .Float = f(p, @intCast(i), @intCast(w)) });
}

fn canvasSave(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 1) if (surfArg(ctx.args[0])) |s| if (skia.cSave) |f| f(s);
    return ok(Value.newLong(0));
}

fn canvasRestore(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 1) if (surfArg(ctx.args[0])) |s| if (skia.cRestore) |f| f(s);
    return ok(Value.newLong(0));
}

fn canvasTranslate(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 3) if (surfArg(ctx.args[0])) |s| if (skia.cTranslate) |f|
        f(s, argFloat(ctx.args[1]), argFloat(ctx.args[2]));
    return ok(Value.newLong(0));
}

fn canvasScale(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 3) if (surfArg(ctx.args[0])) |s| if (skia.cScale) |f|
        f(s, argFloat(ctx.args[1]), argFloat(ctx.args[2]));
    return ok(Value.newLong(0));
}

fn canvasRotate(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 2) if (surfArg(ctx.args[0])) |s| if (skia.cRotate) |f|
        f(s, argFloat(ctx.args[1]));
    return ok(Value.newLong(0));
}

fn canvasSkew(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 3) if (surfArg(ctx.args[0])) |s| if (skia.cSkew) |f|
        f(s, argFloat(ctx.args[1]), argFloat(ctx.args[2]));
    return ok(Value.newLong(0));
}

fn canvasClipRect(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 6) if (surfArg(ctx.args[0])) |s| if (skia.cClipRect) |f|
        f(s, argFloat(ctx.args[1]), argFloat(ctx.args[2]), argFloat(ctx.args[3]), argFloat(ctx.args[4]), @intCast(argInt(ctx.args[5])));
    return ok(Value.newLong(0));
}

fn canvasClipPath(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 3 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cClipPath orelse return ok(Value.newLong(0));
    const pg = ctx.args[1].String.borrow();
    defer pg.deinit();
    const txt = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{pg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(txt);
    f(surf, txt.ptr, @intCast(argInt(ctx.args[2])));
    return ok(Value.newLong(0));
}

/// `__skia_c_set_shader(handle, gradientText)` — arm the next draw's gradient
/// shader (empty text clears it). The Canvas actual sets it around a brush draw.
fn canvasSetShader(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cSetShader orelse return ok(Value.newLong(0));
    const pg = ctx.args[1].String.borrow();
    defer pg.deinit();
    const txt = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{pg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(txt);
    f(surf, txt.ptr);
    return ok(Value.newLong(0));
}

/// The trailing paint args are (argb, style, strokeWidth, cap, join, aa).
fn canvasDrawRect(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 11) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (skia.cDrawRect) |f| f(surf, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argU32(a[5]), @intCast(argInt(a[6])), argFloat(a[7]), @intCast(argInt(a[8])), @intCast(argInt(a[9])), @intCast(argInt(a[10])));
    return ok(Value.newLong(0));
}

fn canvasDrawOval(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 11) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (skia.cDrawOval) |f| f(surf, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argU32(a[5]), @intCast(argInt(a[6])), argFloat(a[7]), @intCast(argInt(a[8])), @intCast(argInt(a[9])), @intCast(argInt(a[10])));
    return ok(Value.newLong(0));
}

fn canvasDrawRRect(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 13) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (skia.cDrawRRect) |f| f(surf, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argFloat(a[5]), argFloat(a[6]), argU32(a[7]), @intCast(argInt(a[8])), argFloat(a[9]), @intCast(argInt(a[10])), @intCast(argInt(a[11])), @intCast(argInt(a[12])));
    return ok(Value.newLong(0));
}

fn canvasDrawCircle(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 10) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (skia.cDrawCircle) |f| f(surf, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argU32(a[4]), @intCast(argInt(a[5])), argFloat(a[6]), @intCast(argInt(a[7])), @intCast(argInt(a[8])), @intCast(argInt(a[9])));
    return ok(Value.newLong(0));
}

/// `__skia_c_draw_line(handle, x0, y0, x1, y1, argb, strokeWidth, cap, aa)`
fn canvasDrawLine(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 9) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (skia.cDrawLine) |f| f(surf, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argU32(a[5]), argFloat(a[6]), @intCast(argInt(a[7])), @intCast(argInt(a[8])));
    return ok(Value.newLong(0));
}

/// `__skia_c_draw_path(handle, pathText, argb, style, strokeWidth, cap, join, aa)`
fn canvasDrawPath(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 8 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cDrawPath orelse return ok(Value.newLong(0));
    const pg = ctx.args[1].String.borrow();
    defer pg.deinit();
    const txt = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{pg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(txt);
    const a = ctx.args;
    f(surf, txt.ptr, argU32(a[2]), @intCast(argInt(a[3])), argFloat(a[4]), @intCast(argInt(a[5])), @intCast(argInt(a[6])), @intCast(argInt(a[7])));
    return ok(Value.newLong(0));
}

/// `__skia_c_draw_text(handle, text, x, y, sizePx, argb)` — draw a single text
/// run with its baseline origin at (x, y) onto the surface's canvas, honouring
/// the canvas's current transform/clip. The real Paragraph engine positions each
/// wrapped line and calls this per line.
fn canvasDrawText(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 6 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const tg = ctx.args[1].String.borrow();
    defer tg.deinit();
    const txt = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{tg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(txt);
    const a = ctx.args;
    skia.drawText(surf, txt.ptr, argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argU32(a[5]));
    return ok(Value.newLong(0));
}

/// `__skia_c_draw_text2(handle, text, x, y, sizePx, argb, flags): Long` — a
/// styled run at a baseline origin: flags bit0 bold, bit1 italic, bit2
/// underline, bit3 strikethrough.
fn canvasDrawText2(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 7 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cDrawText2 orelse return ok(Value.newLong(0));
    const tg = ctx.args[1].String.borrow();
    defer tg.deinit();
    const txt = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{tg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(txt);
    const a = ctx.args;
    f(surf, txt.ptr, argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argU32(a[5]), @intCast(argInt(a[6])));
    return ok(Value.newLong(0));
}

/// `__composeui_text_width(text, sizePx): Float` — the advance width of a single
/// unwrapped run at the given pixel size (the wrap pass measures candidate runs).
fn textWidth(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .String) return ok(.{ .Float = 0 });
    const skia = loadSkia() orelse return ok(.{ .Float = 0 });
    const f = skia.cMeasureTextWidth orelse return ok(.{ .Float = 0 });
    const tg = ctx.args[0].String.borrow();
    defer tg.deinit();
    const txt = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{tg.get().bytes}, 0) catch return ok(.{ .Float = 0 });
    defer ctx.allocator.free(txt);
    return ok(.{ .Float = f(txt.ptr, argFloat(ctx.args[1])) });
}

/// `__composeui_font_metric(sizePx, which): Float` — a font vertical metric at
/// the given size: which=0 ascent (negative), 1 descent (positive), 2 leading.
fn fontMetric(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(.{ .Float = 0 });
    const skia = loadSkia() orelse return ok(.{ .Float = 0 });
    const f = skia.cFontMetric orelse return ok(.{ .Float = 0 });
    return ok(.{ .Float = f(argFloat(ctx.args[0]), @intCast(argInt(ctx.args[1]))) });
}

/// `__skia_c_concat(handle, sx, kx, tx, ky, sy, ty)` — concat a 2D affine
/// transform (Compose Matrix's affine components) onto the canvas.
fn canvasConcat(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 7) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cConcat orelse return ok(Value.newLong(0));
    const a = ctx.args;
    f(surf, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argFloat(a[5]), argFloat(a[6]));
    return ok(Value.newLong(0));
}

const testing = std.testing;

test "hostBindings registers the skia render + windowing sinks" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("klio.compose.ui.__composeui_skiaRender") != null);
    try testing.expect(b.resolve("klio.compose.ui.__composeui_measureText") != null);
    try testing.expect(b.resolve("klio.compose.ui.__composeui_winOpen") != null);
    try testing.expect(b.resolve("klio.compose.ui.__composeui_winRender") != null);
    try testing.expect(b.resolve("klio.compose.ui.__composeui_winPoll") != null);
    try testing.expect(b.resolve("klio.compose.ui.__composeui_winClose") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_path_op") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_surf_new") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_draw_path") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_set_shader") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_draw_text") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__composeui_text_width") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__composeui_font_metric") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_concat") != null);
    try testing.expectEqual(@as(usize, 61), b.len());
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
