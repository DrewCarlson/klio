//! Native Skia backend for the `klio.compose.ui` pack.
//!
//! The compose UI layer records a display list of draw ops in pure Kotlin; this
//! module replays it onto a Skia raster surface through libklio_skia and encodes
//! a PNG. The shared library is dlopened lazily so the interpreter never links
//! libstdc++ or Skia; without it `skiaRender` returns 0.

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

var rss_log_gate: enum { unknown, on, off } = .unknown;
fn rssLog() void {
    if (rss_log_gate == .unknown) {
        rss_log_gate = if (runtime.envOnce("KLIO_RSS_LOG") != null) .on else .off;
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
    try b.register("androidx.compose.ui.window.__composeui_surfaceWidth", surfaceWidth);
    try b.register("androidx.compose.ui.window.__composeui_surfaceHeight", surfaceHeight);
    try b.register("androidx.compose.ui.window.__composeui_setInputCallback", setInputCallback);
    try b.register("androidx.compose.ui.window.__composeui_touchCount", touchCount);
    try b.register("androidx.compose.ui.window.__composeui_touchId", touchId);
    try b.register("androidx.compose.ui.window.__composeui_touchX", touchX);
    try b.register("androidx.compose.ui.window.__composeui_touchY", touchY);
    try b.register("androidx.compose.ui.window.__composeui_touchDown", touchDown);
    try b.register("androidx.compose.ui.window.__composeui_touchScrollX", touchScrollX);
    try b.register("androidx.compose.ui.window.__composeui_touchScrollY", touchScrollY);
    try b.register("androidx.compose.ui.window.__composeui_showKeyboard", showKeyboard);
    try b.register("androidx.compose.ui.window.__composeui_hideKeyboard", hideKeyboard);
    try b.register("androidx.compose.ui.window.__composeui_setTextCallback", setTextCallback);
    try b.register("androidx.compose.ui.window.__composeui_textInput", textInput);
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

const SkSurface = anyopaque;
const SkWindow = anyopaque;

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
    /// Optional: mobile backends attach to an OS-provided surface layer; null on
    /// desktop, where `winOpen` creates the window.
    winAttach: ?WinAttachFn,
    winSurface: *const fn (?*SkWindow) callconv(.c) ?*SkSurface,
    winPresent: *const fn (?*SkWindow) callconv(.c) void,
    winPoll: *const fn (?*SkWindow, c_int, *c_int, *c_int) callconv(.c) c_int,
    winClose: *const fn (?*SkWindow) callconv(.c) void,
    /// Optional: only native live-resize backends export this.
    winSetResizeCb: ?ResizeCbFn,
    winSetTitle: ?*const fn (?*SkWindow, [*:0]const u8) callconv(.c) void,
    winSetSize: ?*const fn (?*SkWindow, c_int, c_int) callconv(.c) void,
    winSetIconPng: ?*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void,
};

const WinAttachFn = *const fn (?*anyopaque, c_int, c_int, f64) callconv(.c) ?*SkWindow;
const ResizeCbFn = *const fn (?*SkWindow, ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void, ?*anyopaque) callconv(.c) void;
const PathOpFn = *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) ?[*:0]u8;
const FreeCstrFn = *const fn ([*:0]u8) callconv(.c) void;

// Canvas entry points, optional so a stale shared library degrades to no-op
// drawing instead of failing the whole Skia load.
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

/// An app host that statically links the Skia shim opts in by declaring
/// `pub const klio_skia_static`. The plain interpreter does not, so on iOS it
/// emits no shim symbol references and stays headless.
const use_static_skia = @hasDecl(@import("root"), "klio_skia_static");

const skia_lib_name = switch (@import("builtin").os.tag) {
    .macos => "libklio_skia.dylib",
    .windows => "klio_skia.dll",
    else => "libklio_skia.so",
};

/// Open and resolve the Skia shim once, searching `$KLIO_SKIA_LIB` then the bare
/// name through the loader path. The result, a failed load included, is cached.
fn loadSkia() ?*Skia {
    if (skia_state) |*s| return s;
    if (skia_tried) return null;
    skia_tried = true;

    // Mobile app hosts link the shim statically: iOS bans dlopen of a
    // runtime-written dylib, and the Android host ships no separate .so.
    if (comptime use_static_skia) return loadSkiaStatic();
    const mobile_os = @import("builtin").os.tag == .ios or
        (@import("builtin").os.tag == .linux and
            (@import("builtin").abi == .android or @import("builtin").abi == .androideabi));
    if (comptime mobile_os) return null;

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
        .winSetResizeCb = lib.lookup(ResizeCbFn, "klio_win_set_resize_cb"),
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

fn externSym(comptime T: type, comptime name: [:0]const u8) T {
    return @extern(T, .{ .name = name });
}

/// iOS resolution of the shim from statically-linked symbols, no dlopen.
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

// Bundle-mode configuration: a bundle boot installs the extracted shim's path,
// the app name and the window-icon PNG before the program runs. Written at
// set-up time, read-only during execution.

var skia_lib_override: ?[]const u8 = null;
var window_icon_png: ?[]const u8 = null;
var default_window_title: ?[:0]const u8 = null;

pub fn setSkiaLibPath(path: []const u8) void {
    skia_lib_override = path;
}

pub fn setWindowIconPng(png: []const u8) void {
    window_icon_png = png;
}

pub fn setDefaultWindowTitle(title: [:0]const u8) void {
    default_window_title = title;
}

fn openSkiaLib() ?std.DynLib {
    if (skia_lib_override) |p| {
        if (std.DynLib.open(p)) |l| return l else |_| {}
    }
    if (runtime.envOnce("KLIO_SKIA_LIB")) |p| {
        if (std.DynLib.open(p)) |l| return l else |_| {}
    }
    if (std.DynLib.open(skia_lib_name)) |l| return l else |_| {}
    // The install layout puts the shim in `lib/` next to the binary's `bin/`, so
    // resolving relative to the executable needs no loader-path setup.
    const exe_dir = selfExeDir() orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "../lib", "." }) |rel| {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ exe_dir, rel, skia_lib_name }) catch continue;
        if (std.DynLib.open(p)) |l| return l else |_| {}
    }
    return null;
}

var self_exe_buf: [std.fs.max_path_bytes]u8 = undefined;

fn selfExeDir() ?[]const u8 {
    const os = @import("builtin").os.tag;
    var len: usize = 0;
    switch (os) {
        .linux => {
            const n = std.os.linux.readlink("/proc/self/exe", &self_exe_buf, self_exe_buf.len - 1);
            if (@as(isize, @bitCast(n)) <= 0) return null;
            len = n;
        },
        .macos => {
            var l: u32 = self_exe_buf.len;
            if (std.c._NSGetExecutablePath(&self_exe_buf, &l) != 0) return null;
            len = std.mem.len(@as([*:0]const u8, @ptrCast(&self_exe_buf)));
        },
        else => return null,
    }
    const path = self_exe_buf[0..len];
    const slash = std.mem.findScalarLast(u8, path, '/') orelse return null;
    return path[0..slash];
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
    // Opt-in GPU surface when KLIO_SKIA_GPU is set and the backend was built
    // with it; on GPU init failure, fall back to raster.
    const gpu = runtime.envOnce("KLIO_SKIA_GPU") != null;
    const surface = (if (gpu) skia.newGpu(width, height) else null) orelse
        skia.new(width, height) orelse return ok(Value.newLong(0));
    defer skia.free(surface);

    const dg = ctx.args[3].String.borrow();
    defer dg.deinit();
    replay(skia, surface, dg.get().bytes);

    const a = ctx.allocator;
    const pg = ctx.args[0].String.borrow();
    defer pg.deinit();
    const path_z = std.fmt.allocPrintSentinel(a, "{s}", .{pg.get().bytes}, 0) catch return ok(Value.newLong(0));
    defer a.free(path_z);
    _ = skia.savePng(surface, path_z.ptr);

    var len: usize = 0;
    const buf = skia.encodePng(surface, &len) orelse return ok(Value.newLong(0));
    defer skia.freeBuffer(buf);
    var h: u64 = 1469598103934665603;
    for (buf[0..len]) |byte| h = (h ^ byte) *% 1099511628211;
    return ok(Value.newLong(@bitCast(h)));
}

/// `__composeui_measureText(text, width, size): Long`: the wrapped height in
/// ceiled px, or 0 when Skia is unavailable so the caller can estimate.
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

// Windowing intrinsics: open an on-screen window, replay a display list into it
// each frame, and pump input events. The window handle reaches Kotlin as a Long
// (the KlioWindow pointer). Each one no-ops or reports "closed" when Skia or a
// windowing backend is unavailable, so a headless build still runs.

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
    const kotlin_title = tg.get().bytes;
    const title_bytes = if (kotlin_title.len == 0)
        (default_window_title orelse kotlin_title)
    else
        kotlin_title;
    const title_z = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{title_bytes}, 0) catch return ok(Value.newLong(0));
    defer ctx.allocator.free(title_z);
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

fn winRender(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surface = skia.winSurface(win) orelse return ok(Value.newLong(0));
    const dg = ctx.args[1].String.borrow();
    defer dg.deinit();
    // Clear to opaque black before replaying so frames do not accumulate on the
    // persistent window surface; a double-buffered swapchain would otherwise show
    // a stale back buffer.
    skia.clear(surface, 0xFF000000);
    replay(skia, surface, dg.get().bytes);
    skia.winPresent(win);
    rssLog();
    return ok(Value.newLong(1));
}

/// Registered for the duration of a `winPoll` so the shim's live-resize observer
/// can drive a frame while the modal drag blocks the VM's loop. The render
/// callback is a live poll argument, so it needs no separate GC root.
const ResizeCb = struct {
    host: IntrinsicHost,
    callback: Value,
    out: Output,
};

fn resizeTrampoline(user: ?*anyopaque, w: c_int, h: c_int) callconv(.c) void {
    const rc: *ResizeCb = @ptrCast(@alignCast(user orelse return));
    var args = [_]Value{ Value.newInt(@intCast(w)), Value.newInt(@intCast(h)) };
    _ = rc.host.invokeCallable(&rc.callback, &args, rc.out) catch {};
}

/// `__composeui_winPoll(handle, timeoutMs, onResize?): Long`: wait up to
/// timeoutMs for an event and return `(type << 32) | (x << 16) | y`, where type
/// is 0 none, 1 click, 2 close. A supplied `onResize` runs during a live resize.
fn winPoll(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(2 << 32));
    const skia = loadSkia() orelse return ok(Value.newLong(2 << 32));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(2 << 32));
    const timeout: c_int = @intCast(@max(0, argInt(ctx.args[1])));
    var rc: ResizeCb = undefined;
    // The live-resize callback fires only on backends exporting the hook; SDL
    // reports resizes through winPoll's event code instead.
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

// OS-driven frame loop (mobile): the platform owns the run loop and calls
// klio_render_frame each vsync on the resident VM. `application` registers a
// per-frame render callback and returns instead of looping.

var surface_layer: ?*anyopaque = null;
var surface_w: c_int = 0;
var surface_h: c_int = 0;
var surface_scale: f64 = 1.0;

pub export fn klio_set_surface(layer: ?*anyopaque, w: c_int, h: c_int, scale: f64) void {
    surface_layer = layer;
    surface_w = w;
    surface_h = h;
    surface_scale = scale;
}

/// The resident per-frame render callback. Unlike ResizeCb it outlives the call
/// that registered it: main returns while the VM stays resident on a
/// process-lifetime arena holding the captured composition.
const FrameCb = struct {
    host: IntrinsicHost,
    callback: Value,
    out: Output,
    set: bool = false,
};
var frame_cb: FrameCb = .{ .host = undefined, .callback = undefined, .out = undefined };

var input_cb: FrameCb = .{ .host = undefined, .callback = undefined, .out = undefined };

fn isHosted(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(Value{ .Bool = surface_layer != null });
}

/// The hosted surface's size in points, which the OS owns on mobile. A hosted
/// `Window` sizes itself to these so its Metal drawable matches the view.
fn surfaceWidth(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(Value.newInt(surface_w));
}
fn surfaceHeight(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(Value.newInt(surface_h));
}

/// Store the render callback the platform frame source invokes each frame. The
/// host handed to a native intrinsic dies when `main`'s activation returns, so
/// `persist()` makes a resident copy; the lambda and its composition live on the
/// run's process-lifetime arena.
fn setFrameCallback(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    frame_cb = .{ .host = ctx.host.persist(), .callback = ctx.args[0], .out = ctx.out, .set = true };
    return ok(Value.newLong(1));
}

fn setInputCallback(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    input_cb = .{ .host = ctx.host.persist(), .callback = ctx.args[0], .out = ctx.out, .set = true };
    return ok(Value.newLong(1));
}

/// True once `application` registered a hosted frame callback: the run must stay
/// resident, VM and arena alive, for the frame source to re-enter.
pub fn hostedActive() bool {
    return frame_cb.set;
}

/// Whether the resident VM still needs a frame. The frame source skips
/// re-entering while false, so a static scene costs no per-vsync re-entry.
var frame_needs_render: bool = true;

fn renderFrameBody(_: void) void {
    var args = [_]Value{};
    const res = frame_cb.host.invokeCallable(&frame_cb.callback, &args, frame_cb.out) catch {
        frame_needs_render = true; // errored: render again rather than stall
        return;
    };
    frame_needs_render = switch (res) {
        .ok => |v| v == .Bool and v.Bool,
        .err => true,
    };
}

/// Render one frame on the main thread the VM ran main on, a plain same-thread
/// re-entry. The platform callback arrives on the UI thread's small stack, so the
/// frame body runs on the persistent interpreter stack instead.
pub export fn klio_render_frame() void {
    if (!frame_cb.set) return;
    runtime.runOnPersistentBigStack(void, void, renderFrameBody, {});
}

pub export fn klio_frame_needs_render() c_int {
    return if (frame_needs_render) 1 else 0;
}

fn markFrameDirty() void {
    frame_needs_render = true;
}

/// C query: nonzero once a hosted frame callback is registered. The shell starts
/// its frame source only then, and a non-UI program exits.
pub export fn klio_frame_active() c_int {
    return if (frame_cb.set) 1 else 0;
}

/// One pointer in the current multi-touch snapshot, with a scroll delta nonzero
/// only for a Scroll event. Compose diffs whole snapshots, so the app hands over
/// every active pointer per event.
const TouchPoint = struct { id: c_int, x: c_int, y: c_int, down: bool, sdx: c_int = 0, sdy: c_int = 0 };
var touch_points: [16]TouchPoint = undefined;
var touch_count: usize = 0;

fn dispatchTouchBody(phase: c_int) void {
    var args = [_]Value{Value.newInt(phase)};
    _ = input_cb.host.invokeCallable(&input_cb.callback, &args, input_cb.out) catch {};
}

/// Route a multi-touch snapshot into the resident VM's input callback. `ids` are
/// stable per finger, `xs`/`ys` are surface points, `downs[i] != 0` means
/// pressed, and `phase` is 0 down, 1 move, 2 up, 3 cancel. The run loop services
/// touch and frame serially, so they never overlap.
pub export fn klio_dispatch_touches(
    count: c_int,
    ids: [*]const c_int,
    xs: [*]const c_int,
    ys: [*]const c_int,
    downs: [*]const c_int,
    phase: c_int,
) void {
    if (!input_cb.set) return;
    const n = @min(@as(usize, @intCast(@max(count, 0))), touch_points.len);
    touch_count = n;
    for (0..n) |i| touch_points[i] = .{ .id = ids[i], .x = xs[i], .y = ys[i], .down = downs[i] != 0 };
    runtime.runOnPersistentBigStack(c_int, void, dispatchTouchBody, phase);
    markFrameDirty();
}

/// Route a discrete wheel or trackpad scroll in as one unpressed pointer with a
/// scroll delta, phase 4. Touch-drag scrolling needs none of this.
pub export fn klio_dispatch_scroll(x: c_int, y: c_int, dx: c_int, dy: c_int) void {
    if (!input_cb.set) return;
    touch_count = 1;
    touch_points[0] = .{ .id = 0, .x = x, .y = y, .down = false, .sdx = dx, .sdy = dy };
    runtime.runOnPersistentBigStack(c_int, void, dispatchTouchBody, 4);
    markFrameDirty();
}

fn touchIndex(ctx: *CallCtx) ?usize {
    if (ctx.args.len < 1) return null;
    const i: i64 = ctx.args[0].asI64() orelse return null;
    if (i < 0 or @as(usize, @intCast(i)) >= touch_count) return null;
    return @intCast(i);
}

fn touchCount(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    return ok(Value.newInt(@intCast(touch_count)));
}
fn touchId(ctx: *CallCtx) Error!EvalResult {
    const i = touchIndex(ctx) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(touch_points[i].id));
}
fn touchX(ctx: *CallCtx) Error!EvalResult {
    const i = touchIndex(ctx) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(touch_points[i].x));
}
fn touchY(ctx: *CallCtx) Error!EvalResult {
    const i = touchIndex(ctx) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(touch_points[i].y));
}
fn touchDown(ctx: *CallCtx) Error!EvalResult {
    const i = touchIndex(ctx) orelse return ok(Value{ .Bool = false });
    return ok(Value{ .Bool = touch_points[i].down });
}
fn touchScrollX(ctx: *CallCtx) Error!EvalResult {
    const i = touchIndex(ctx) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(touch_points[i].sdx));
}
fn touchScrollY(ctx: *CallCtx) Error!EvalResult {
    const i = touchIndex(ctx) orelse return ok(Value.newInt(0));
    return ok(Value.newInt(touch_points[i].sdy));
}

const KbFn = *const fn () callconv(.c) void;
var keyboard_show_fn: ?KbFn = null;
var keyboard_hide_fn: ?KbFn = null;

pub export fn klio_set_keyboard_handler(show: ?KbFn, hide: ?KbFn) void {
    keyboard_show_fn = show;
    keyboard_hide_fn = hide;
}

fn showKeyboard(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    if (keyboard_show_fn) |f| f();
    return ok(Value.newLong(1));
}
fn hideKeyboard(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    if (keyboard_hide_fn) |f| f();
    return ok(Value.newLong(1));
}

/// The resident text-input callback and its staged text. Same persisted-host
/// residency contract as `frame_cb`.
var text_cb: FrameCb = .{ .host = undefined, .callback = undefined, .out = undefined };
var staged_text: [512]u8 = undefined;
var staged_text_len: usize = 0;

fn setTextCallback(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    text_cb = .{ .host = ctx.host.persist(), .callback = ctx.args[0], .out = ctx.out, .set = true };
    return ok(Value.newLong(1));
}

fn dispatchTextBody(kind: c_int) void {
    var args = [_]Value{Value.newInt(kind)};
    _ = text_cb.host.invokeCallable(&text_cb.callback, &args, text_cb.out) catch {};
}

pub export fn klio_dispatch_text(bytes: [*]const u8, len: c_int) void {
    if (!text_cb.set) return;
    const n = @min(@as(usize, @intCast(@max(len, 0))), staged_text.len);
    @memcpy(staged_text[0..n], bytes[0..n]);
    staged_text_len = n;
    runtime.runOnPersistentBigStack(c_int, void, dispatchTextBody, 0);
    markFrameDirty();
}

/// A key edit with no text payload: 1=backspace, 2=ime action (enter/done).
pub export fn klio_dispatch_key(kind: c_int) void {
    if (!text_cb.set) return;
    staged_text_len = 0;
    runtime.runOnPersistentBigStack(c_int, void, dispatchTextBody, kind);
    markFrameDirty();
}

fn textInput(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    return ok(Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, staged_text[0..staged_text_len])) });
}

/// The host OS, as a lowercase name. foundation's `DesktopPlatform` needs it:
/// macOS binds the text shortcuts to Meta while Linux and Windows bind Ctrl.
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

fn winSurfaceOf(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surface = skia.winSurface(win) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(surface)))));
}

fn winPresent(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    skia.winPresent(win);
    return ok(Value.newLong(1));
}

fn winClear(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surface = skia.winSurface(win) orelse return ok(Value.newLong(0));
    skia.clear(surface, @bitCast(@as(u32, @truncate(@as(u64, @bitCast(argInt(ctx.args[1])))))));
    return ok(Value.newLong(1));
}

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

/// Combine two serialized path command buffers with a boolean op. Null when the
/// op fails or no Skia backend is available, leaving the caller's path unchanged.
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

// Canvas intrinsics: a Canvas actual draws through these onto an offscreen
// surface, the handle being a KlioSurface pointer as a Long.

fn surfArg(v: Value) ?*SkSurface {
    const h: u64 = @bitCast(argInt(v));
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

fn argU32(v: Value) u32 {
    return @bitCast(@as(i32, @truncate(argInt(v))));
}

fn surfNew(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const w: c_int = @intCast(@max(0, argInt(ctx.args[0])));
    const h: c_int = @intCast(@max(0, argInt(ctx.args[1])));
    const surf = skia.new(w, h) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(surf)))));
}

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

fn surfFree(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (surfArg(ctx.args[0])) |surf| skia.free(surf);
    return ok(Value.newLong(0));
}

fn surfPixel(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.surfPixel orelse return ok(Value.newLong(0));
    const x: c_int = @intCast(argInt(ctx.args[1]));
    const y: c_int = @intCast(argInt(ctx.args[2]));
    return ok(Value.newLong(@intCast(f(surf, x, y))));
}

fn canvasDrawSurface(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 4) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const dst = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const src = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    if (skia.cDrawSurface) |f| f(dst, src, argFloat(ctx.args[2]), argFloat(ctx.args[3]));
    return ok(Value.newLong(0));
}

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

/// Build a styled paragraph, or 0 when no Skia backend or font is available, so
/// callers fall back to stub metrics.
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

/// Arm the next draw's gradient shader; empty text clears it.
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
    if (runtime.envOnce("KLIO_DRAW_TRACE") != null and ctx.args.len >= 11) {
        std.debug.print("[draw] rect surf={d} x={d:.1} y={d:.1} w={d:.1} h={d:.1} color={x:0>8}\n", .{
            argInt(ctx.args[0]), argFloat(ctx.args[1]), argFloat(ctx.args[2]),
            argFloat(ctx.args[3]), argFloat(ctx.args[4]), argU32(ctx.args[5]),
        });
    }
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

fn canvasDrawLine(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 9) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (skia.cDrawLine) |f| f(surf, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argU32(a[5]), argFloat(a[6]), @intCast(argInt(a[7])), @intCast(argInt(a[8])));
    return ok(Value.newLong(0));
}

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

/// A styled run at a baseline origin; flags are bit0 bold, bit1 italic, bit2
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

/// A font vertical metric: which=0 ascent (negative), 1 descent (positive),
/// 2 leading.
fn fontMetric(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(.{ .Float = 0 });
    const skia = loadSkia() orelse return ok(.{ .Float = 0 });
    const f = skia.cFontMetric orelse return ok(.{ .Float = 0 });
    return ok(.{ .Float = f(argFloat(ctx.args[0]), @intCast(argInt(ctx.args[1]))) });
}

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
    try testing.expectEqual(@as(usize, 77), b.len());
}

test "skiaRender guards arg shapes and no-ops without the library" {
    // The Skia shared library is absent in the unit-test environment, so this
    // exercises the arg-shape guards without needing the .so.
    const a = testing.allocator;
    var host: TestHost = .{};
    var path = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "/tmp/klio_skia_test.png")) };
    defer path.String.deinit();
    var list = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "clear FF000000\nrect 0 0 4 4 FFFFFFFF\n")) };
    defer list.String.deinit();
    const short = [_]Value{path};
    var ctx0 = host.ctx(&short);
    try testing.expectEqual(@as(i64, 0), (try skiaRender(&ctx0)).ok.Long);
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
