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
    try b.register("androidx.compose.ui.input.key.__composeui_hostOs", hostOs);
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
    try b.register("androidx.compose.ui.window.__composeui_winOpenError", winOpenError);
    try b.register("androidx.compose.ui.window.__composeui_winProbe", winProbe);
    try b.register("androidx.compose.ui.window.__composeui_winSetTitle", winSetTitle);
    try b.register("androidx.compose.ui.window.__composeui_winSetSize", winSetSize);
    try b.register("androidx.compose.ui.window.__composeui_winPoll", winPoll);
    try b.register("androidx.compose.ui.window.__composeui_winPollEvent", winPollEvent);
    try b.register("androidx.compose.ui.window.__composeui_winPostEvent", winPostEvent);
    try b.register("androidx.compose.ui.window.__composeui_winSetFlag", winSetFlag);
    try b.register("androidx.compose.ui.window.__composeui_winSetPosition", winSetPosition);
    try b.register("androidx.compose.ui.window.__composeui_winPosition", winPosition);
    try b.register("androidx.compose.ui.window.__composeui_screenBounds", screenBounds);
    try b.register("androidx.compose.ui.window.__composeui_winSetFrameSize", winSetFrameSize);
    try b.register("androidx.compose.ui.window.__composeui_winFrameSize", winFrameSize);
    try b.register("androidx.compose.ui.window.__composeui_iconSurface", surfNew);
    try b.register("androidx.compose.ui.window.__composeui_iconSurfaceFree", surfFree);
    try b.register("androidx.compose.ui.window.__composeui_winSetIconSurface", winSetIconSurface);
    try b.register("androidx.compose.ui.window.__composeui_winSetMenu", winSetMenu);
    try b.register("androidx.compose.ui.window.__composeui_winSetMenuIcon", winSetMenuIcon);
    try b.register("androidx.compose.ui.window.__composeui_traySupported", traySupported);
    try b.register("androidx.compose.ui.window.__composeui_trayOpen", trayOpen);
    try b.register("androidx.compose.ui.window.__composeui_trayClose", trayClose);
    try b.register("androidx.compose.ui.window.__composeui_traySetIcon", traySetIcon);
    try b.register("androidx.compose.ui.window.__composeui_traySetTooltip", traySetTooltip);
    try b.register("androidx.compose.ui.window.__composeui_traySetMenu", traySetMenu);
    try b.register("androidx.compose.ui.window.__composeui_trayNotify", trayNotify);
    try b.register("androidx.compose.ui.window.__composeui_trayPollEvent", trayPollEvent);
    try b.register("androidx.compose.ui.window.__composeui_appWait", appWait);
    try b.register("androidx.compose.ui.window.__composeui_printErr", printErr);
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
    try b.register("klio.datatransfer.__klio_clipMode", clipMode);
    try b.register("androidx.compose.ui.text.intl.__composeui_hostLocale", hostLocale);
    try b.register("klio.datatransfer.__klio_clipChangeCount", clipChangeCount);
    try b.register("klio.datatransfer.__klio_clipText", clipText);
    try b.register("klio.datatransfer.__klio_clipSetText", clipSetText);
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
    try b.register("androidx.compose.ui.graphics.__skia_c_set_blur", canvasSetBlur);
    try b.register("androidx.compose.ui.graphics.__skia_c_set_color_filter", canvasSetColorFilter);
    try b.register("androidx.compose.ui.graphics.__skia_c_set_paint_state", canvasSetPaintState);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_rect", canvasDrawRect);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_rrect", canvasDrawRRect);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_oval", canvasDrawOval);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_circle", canvasDrawCircle);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_line", canvasDrawLine);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_path", canvasDrawPath);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_text", canvasDrawText);
    try b.register("androidx.compose.ui.graphics.__composeui_text_width", textWidth);
    try b.register("androidx.compose.ui.graphics.__composeui_font_metric", fontMetric);
    try b.register("androidx.compose.ui.graphics.__skia_surf_pixel", surfPixel);
    try b.register("androidx.compose.ui.graphics.__skia_surf_size", surfSize);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_text2", canvasDrawText2);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_surface", canvasDrawSurface);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_surface_rect", canvasDrawSurfaceRect);
    try b.register("androidx.compose.ui.graphics.__skia_c_save_layer", canvasSaveLayer);
    try b.register("androidx.compose.ui.graphics.__skia_rec_begin", recBegin);
    try b.register("androidx.compose.ui.graphics.__skia_rec_end", recEnd);
    try b.register("androidx.compose.ui.graphics.__skia_picture_free", pictureFree);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_picture", canvasDrawPicture);
    try b.register("androidx.compose.ui.graphics.__skia_c_concat44", canvasConcat44);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_context_new", rnContextNew);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_context_free", rnContextFree);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_context_set_lighting", rnContextSetLighting);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_new", rnNew);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_free", rnFree);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_set_float", rnSetFloat);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_set_color", rnSetColor);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_set_bounds", rnSetBounds);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_set_pivot", rnSetPivot);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_set_clip", rnSetClip);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_set_outline", rnSetOutline);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_set_layer_paint", rnSetLayerPaint);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_begin_recording", rnBeginRecording);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_end_recording", rnEndRecording);
    try b.register("androidx.compose.ui.graphics.layer.__skia_rn_draw_into", rnDrawInto);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_point", canvasDrawPoint);
    try b.register("androidx.compose.ui.graphics.__skia_c_set_path_effect", canvasSetPathEffect);
    try b.register("androidx.compose.ui.graphics.__skia_c_draw_vertices", canvasDrawVertices);
    try b.register("androidx.compose.ui.graphics.__skia_image_decode", imageDecode);
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
    try b.register("androidx.compose.ui.text.platform.__skia_font_register_data", fontRegisterData);
    try b.register("androidx.compose.ui.text.platform.__skia_para_ph_count", paraPhCount);
    try b.register("androidx.compose.ui.text.platform.__skia_para_ph_rect", paraPhRect);
    try b.register("androidx.compose.material3.internal.__klio_icu_date", icuDate);
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
    cSetBlur: ?CRotateFn,
    cSetColorFilter: ?CSetColorFilterFn,
    cSetPaintState: ?CSetPaintStateFn,
    cDrawRect: ?CDrawRectFn,
    cDrawRRect: ?CDrawRRectFn,
    cDrawOval: ?CDrawRectFn,
    cDrawCircle: ?CDrawCircleFn,
    cDrawLine: ?CDrawLineFn,
    cDrawPath: ?CDrawPathFn,
    cMeasureTextWidth: ?CMeasureTextWidthFn,
    cFontMetric: ?CFontMetricFn,
    surfPixel: ?SurfPixelFn,
    surfSize: ?SurfSizeFn,
    cDrawText2: ?CDrawText2Fn,
    cDrawSurface: ?CDrawSurfaceFn,
    cDrawSurfaceRect: ?CDrawSurfaceRectFn,
    cSaveLayer: ?CSaveLayerFn,
    recBegin: ?RecBeginFn,
    recEnd: ?RecEndFn,
    pictureFree: ?PictureFreeFn,
    cDrawPicture: ?CDrawPictureFn,
    cConcat44: ?CConcat44Fn,
    rn: RenderNodeFns,
    cDrawPoint: ?CDrawPointFn,
    cSetPathEffect: ?CSetShaderFn,
    cDrawVertices: ?CDrawVerticesFn,
    imageDecode: ?ImageDecodeFn,
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
    fontRegisterData: ?FontRegisterDataFn,
    paraPhCount: ?ParaPhCountFn,
    paraPhRect: ?ParaPhRectFn,
    icuDate: ?IcuDateFn,
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
    winPollEvent: ?WinPollEventFn,
    winPostEvent: ?WinPostEventFn,
    winSetFlag: ?*const fn (?*SkWindow, c_int, c_int) callconv(.c) void,
    winSetPosition: ?*const fn (?*SkWindow, c_int, c_int) callconv(.c) void,
    winGetPosition: ?*const fn (?*SkWindow, *c_int, *c_int) callconv(.c) void,
    screenBounds: ?*const fn (*c_int, *c_int, *c_int, *c_int) callconv(.c) void,
    winSetFrameSize: ?*const fn (?*SkWindow, c_int, c_int) callconv(.c) void,
    winGetFrameSize: ?*const fn (?*SkWindow, *c_int, *c_int) callconv(.c) void,
    winSetTitle: ?*const fn (?*SkWindow, [*:0]const u8) callconv(.c) void,
    winSetSize: ?*const fn (?*SkWindow, c_int, c_int) callconv(.c) void,
    winSetIconPng: ?*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void,
    winSetIconSurface: ?*const fn (?*SkWindow, ?*SkSurface) callconv(.c) void,
    winSetMenu: ?*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void,
    winSetMenuIcon: ?*const fn (?*SkWindow, c_int, ?*SkSurface) callconv(.c) void,
    winLastError: ?*const fn () callconv(.c) [*:0]const u8,
    tray: TrayFns,
    clipChangeCount: ?ClipChangeCountFn,
    clipGetText: ?ClipGetTextFn,
    clipSetText: ?ClipSetTextFn,
    hostLocale: ?HostLocaleFn,
};

const HostLocaleFn = *const fn () callconv(.c) ?[*:0]u8;

/// The Skia shim's tray icon and application-wait functions.
const TrayFns = struct {
    supported: ?*const fn () callconv(.c) c_int = null,
    open: ?*const fn () callconv(.c) ?*anyopaque = null,
    close: ?*const fn (?*anyopaque) callconv(.c) void = null,
    setIcon: ?*const fn (?*anyopaque, ?*SkSurface) callconv(.c) void = null,
    setTooltip: ?*const fn (?*anyopaque, ?[*]const u8, usize) callconv(.c) void = null,
    setMenu: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void = null,
    notify: ?*const fn (?*anyopaque, [*]const u8, usize, [*]const u8, usize, c_int) callconv(.c) void = null,
    pollEvent: ?*const fn (?*anyopaque, [*]f64) callconv(.c) c_int = null,
    appWait: ?*const fn (c_int) callconv(.c) void = null,

    fn fromLib(lib: *std.DynLib) TrayFns {
        var t: TrayFns = .{};
        inline for (.{
            .{ "supported", "klio_tray_supported" },
            .{ "open", "klio_tray_open" },
            .{ "close", "klio_tray_close" },
            .{ "setIcon", "klio_tray_set_icon" },
            .{ "setTooltip", "klio_tray_set_tooltip" },
            .{ "setMenu", "klio_tray_set_menu" },
            .{ "notify", "klio_tray_notify" },
            .{ "pollEvent", "klio_tray_poll_event" },
            .{ "appWait", "klio_app_wait" },
        }) |f| {
            @field(t, f[0]) = lib.lookup(@typeInfo(@FieldType(TrayFns, f[0])).optional.child, f[1]);
        }
        return t;
    }

    fn fromExtern() TrayFns {
        var t: TrayFns = .{};
        inline for (.{
            .{ "supported", "klio_tray_supported" },
            .{ "open", "klio_tray_open" },
            .{ "close", "klio_tray_close" },
            .{ "setIcon", "klio_tray_set_icon" },
            .{ "setTooltip", "klio_tray_set_tooltip" },
            .{ "setMenu", "klio_tray_set_menu" },
            .{ "notify", "klio_tray_notify" },
            .{ "pollEvent", "klio_tray_poll_event" },
            .{ "appWait", "klio_app_wait" },
        }) |f| {
            @field(t, f[0]) = externSym(@typeInfo(@FieldType(TrayFns, f[0])).optional.child, f[1]);
        }
        return t;
    }
};

const ClipChangeCountFn = *const fn () callconv(.c) c_longlong;
const ClipGetTextFn = *const fn (*usize) callconv(.c) ?[*]u8;
const ClipSetTextFn = *const fn (?[*]const u8, usize) callconv(.c) void;

const WinAttachFn = *const fn (?*anyopaque, c_int, c_int, f64) callconv(.c) ?*SkWindow;
const WinPollEventFn = *const fn (?*SkWindow, c_int, [*]f64) callconv(.c) c_int;
const WinPostEventFn = *const fn (?*SkWindow, c_int, [*]const f64) callconv(.c) void;
/// The values of one window event (src/compose_ui/window_events.h).
const win_event_values = 12;
const ResizeCbFn = *const fn (?*SkWindow, ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void, ?*anyopaque) callconv(.c) void;
const PathOpFn = *const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) ?[*:0]u8;
const FreeCstrFn = *const fn ([*:0]u8) callconv(.c) void;
const IcuDateFn = *const fn (c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8, f64) callconv(.c) ?[*:0]u8;

// Canvas entry points, optional so a stale shared library degrades to no-op
// drawing instead of failing the whole Skia load.
const CVoidFn = *const fn (?*SkSurface) callconv(.c) void;
const CXYFn = *const fn (?*SkSurface, f32, f32) callconv(.c) void;
const CRotateFn = *const fn (?*SkSurface, f32) callconv(.c) void;
const CClipRectFn = *const fn (?*SkSurface, f32, f32, f32, f32, c_int) callconv(.c) void;
const CClipPathFn = *const fn (?*SkSurface, [*:0]const u8, c_int) callconv(.c) void;
const CSetShaderFn = *const fn (?*SkSurface, [*:0]const u8) callconv(.c) void;
// A color filter spec (see skia_shim.cpp's Spec).
const CSetColorFilterFn = *const fn (?*SkSurface, [*:0]const u8) callconv(.c) void;
// (blendMode, imageAlpha, strokeMiter)
const CSetPaintStateFn = *const fn (?*SkSurface, c_int, f32, f32) callconv(.c) void;
// The trailing (argb, style, strokeWidth, cap, join, aa) is the packed paint.
const CDrawRectFn = *const fn (?*SkSurface, f32, f32, f32, f32, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CDrawRRectFn = *const fn (?*SkSurface, f32, f32, f32, f32, f32, f32, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CDrawCircleFn = *const fn (?*SkSurface, f32, f32, f32, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CDrawLineFn = *const fn (?*SkSurface, f32, f32, f32, f32, u32, f32, c_int, c_int) callconv(.c) void;
const CDrawPathFn = *const fn (?*SkSurface, [*:0]const u8, u32, c_int, f32, c_int, c_int, c_int) callconv(.c) void;
const CMeasureTextWidthFn = *const fn ([*:0]const u8, f32) callconv(.c) f32;
const CFontMetricFn = *const fn (f32, c_int) callconv(.c) f32;
const SurfPixelFn = *const fn (?*SkSurface, c_int, c_int) callconv(.c) u32;
const SurfSizeFn = *const fn (?*SkSurface, c_int) callconv(.c) c_int;
const CDrawText2Fn = *const fn (?*SkSurface, [*:0]const u8, f32, f32, f32, u32, c_int) callconv(.c) void;
const CDrawSurfaceFn = *const fn (?*SkSurface, ?*SkSurface, f32, f32, c_int) callconv(.c) void;
const CDrawSurfaceRectFn = *const fn (?*SkSurface, ?*SkSurface, f32, f32, f32, f32, f32, f32, f32, f32, c_int) callconv(.c) void;
// (l, t, r, b, hasBounds, alpha, blendMode, imageFilterSpec)
const CSaveLayerFn = *const fn (?*SkSurface, f32, f32, f32, f32, c_int, f32, c_int, [*:0]const u8) callconv(.c) void;
const SkPicture = anyopaque;
// (left, top, right, bottom) of the recording's bounds.
const RecBeginFn = *const fn (f32, f32, f32, f32) callconv(.c) ?*SkSurface;
const RecEndFn = *const fn (?*SkSurface) callconv(.c) ?*SkPicture;
const PictureFreeFn = *const fn (?*SkPicture) callconv(.c) void;
const CDrawPictureFn = *const fn (?*SkSurface, ?*SkPicture) callconv(.c) void;
// A Compose Matrix's 16 values, column-major.
const CConcat44Fn = *const fn (?*SkSurface, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32) callconv(.c) void;

/// Graphics layer nodes (skiko's RenderNode, `klio_rn_*` in skia_shim.cpp).
/// Each is optional so a shim without them draws layers as nothing.
const RenderNodeFns = struct {
    contextNew: ?*const fn (c_int) callconv(.c) ?*anyopaque = null,
    contextFree: ?*const fn (?*anyopaque) callconv(.c) void = null,
    contextSetLighting: ?*const fn (?*anyopaque, f32, f32, f32, f32, f32, f32) callconv(.c) void = null,
    new: ?*const fn (?*anyopaque) callconv(.c) ?*anyopaque = null,
    free: ?*const fn (?*anyopaque) callconv(.c) void = null,
    setFloat: ?*const fn (?*anyopaque, c_int, f32) callconv(.c) void = null,
    setColor: ?*const fn (?*anyopaque, c_int, u32) callconv(.c) void = null,
    setBounds: ?*const fn (?*anyopaque, f32, f32, f32, f32) callconv(.c) void = null,
    setPivot: ?*const fn (?*anyopaque, f32, f32) callconv(.c) void = null,
    setClip: ?*const fn (?*anyopaque, c_int) callconv(.c) void = null,
    // (kind, l, t, r, b, the 8 corner radii, path)
    setOutline: ?*const fn (?*anyopaque, c_int, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, f32, ?[*:0]const u8) callconv(.c) void = null,
    // (has, alpha, blendMode, colorFilterSpec, imageFilterSpec)
    setLayerPaint: ?*const fn (?*anyopaque, c_int, f32, c_int, [*:0]const u8, [*:0]const u8) callconv(.c) void = null,
    beginRecording: ?*const fn (?*anyopaque) callconv(.c) ?*SkSurface = null,
    endRecording: ?*const fn (?*anyopaque, ?*SkSurface) callconv(.c) void = null,
    drawInto: ?*const fn (?*anyopaque, ?*SkSurface) callconv(.c) void = null,

    const names = .{
        .{ "contextNew", "klio_rn_context_new" },
        .{ "contextFree", "klio_rn_context_free" },
        .{ "contextSetLighting", "klio_rn_context_set_lighting" },
        .{ "new", "klio_rn_new" },
        .{ "free", "klio_rn_free" },
        .{ "setFloat", "klio_rn_set_float" },
        .{ "setColor", "klio_rn_set_color" },
        .{ "setBounds", "klio_rn_set_bounds" },
        .{ "setPivot", "klio_rn_set_pivot" },
        .{ "setClip", "klio_rn_set_clip" },
        .{ "setOutline", "klio_rn_set_outline" },
        .{ "setLayerPaint", "klio_rn_set_layer_paint" },
        .{ "beginRecording", "klio_rn_begin_recording" },
        .{ "endRecording", "klio_rn_end_recording" },
        .{ "drawInto", "klio_rn_draw_into" },
    };

    fn fromLib(lib: anytype) RenderNodeFns {
        var r: RenderNodeFns = .{};
        inline for (names) |n| {
            const T = @typeInfo(@FieldType(RenderNodeFns, n[0])).optional.child;
            @field(r, n[0]) = lib.lookup(T, n[1]);
        }
        return r;
    }

    fn fromExtern() RenderNodeFns {
        var r: RenderNodeFns = .{};
        inline for (names) |n| {
            const T = @typeInfo(@FieldType(RenderNodeFns, n[0])).optional.child;
            @field(r, n[0]) = externSym(T, n[1]);
        }
        return r;
    }
};
// (x, y, argb, strokeWidth, cap, aa)
const CDrawPointFn = *const fn (?*SkSurface, f32, f32, u32, f32, c_int, c_int) callconv(.c) void;
// (mode, positions, texCoords, colors, indices, blendMode, argb): the arrays as number text.
const CDrawVerticesFn = *const fn (?*SkSurface, c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*:0]const u8, c_int, u32) callconv(.c) void;
const ImageDecodeFn = *const fn ([*]const u8, usize) callconv(.c) ?*SkSurface;
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
const FontRegisterDataFn = *const fn ([*]const u8, usize, [*:0]const u8) callconv(.c) i32;
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
            const f = l.lookup(@FieldType(Skia, name), sym);
            if (f == null) std.debug.print("klio: the Skia shim is missing {s}; rendering is headless\n", .{sym});
            return f;
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
        .cSetBlur = lib.lookup(CRotateFn, "klio_skia_c_set_blur"),
        .cSetColorFilter = lib.lookup(CSetColorFilterFn, "klio_skia_c_set_color_filter"),
        .cSetPaintState = lib.lookup(CSetPaintStateFn, "klio_skia_c_set_paint_state"),
        .cDrawRect = lib.lookup(CDrawRectFn, "klio_skia_c_draw_rect"),
        .cDrawRRect = lib.lookup(CDrawRRectFn, "klio_skia_c_draw_rrect"),
        .cDrawOval = lib.lookup(CDrawRectFn, "klio_skia_c_draw_oval"),
        .cDrawCircle = lib.lookup(CDrawCircleFn, "klio_skia_c_draw_circle"),
        .cDrawLine = lib.lookup(CDrawLineFn, "klio_skia_c_draw_line"),
        .cDrawPath = lib.lookup(CDrawPathFn, "klio_skia_c_draw_path"),
        .cMeasureTextWidth = lib.lookup(CMeasureTextWidthFn, "klio_skia_measure_text_width"),
        .cFontMetric = lib.lookup(CFontMetricFn, "klio_skia_font_metric"),
        .surfPixel = lib.lookup(SurfPixelFn, "klio_skia_surf_pixel"),
        .surfSize = lib.lookup(SurfSizeFn, "klio_skia_surf_size"),
        .cDrawText2 = lib.lookup(CDrawText2Fn, "klio_skia_c_draw_text2"),
        .cDrawSurface = lib.lookup(CDrawSurfaceFn, "klio_skia_c_draw_surface"),
        .cDrawSurfaceRect = lib.lookup(CDrawSurfaceRectFn, "klio_skia_c_draw_surface_rect"),
        .cSaveLayer = lib.lookup(CSaveLayerFn, "klio_skia_c_save_layer"),
        .recBegin = lib.lookup(RecBeginFn, "klio_skia_rec_begin_bounds"),
        .recEnd = lib.lookup(RecEndFn, "klio_skia_rec_end"),
        .pictureFree = lib.lookup(PictureFreeFn, "klio_skia_picture_free"),
        .cDrawPicture = lib.lookup(CDrawPictureFn, "klio_skia_c_draw_picture"),
        .cConcat44 = lib.lookup(CConcat44Fn, "klio_skia_c_concat44"),
        .rn = RenderNodeFns.fromLib(&lib),
        .cDrawPoint = lib.lookup(CDrawPointFn, "klio_skia_c_draw_point"),
        .cSetPathEffect = lib.lookup(CSetShaderFn, "klio_skia_c_set_path_effect"),
        .cDrawVertices = lib.lookup(CDrawVerticesFn, "klio_skia_c_draw_vertices"),
        .imageDecode = lib.lookup(ImageDecodeFn, "klio_skia_image_decode"),
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
        .fontRegisterData = lib.lookup(FontRegisterDataFn, "klio_skia_font_register_data"),
        .paraPhCount = lib.lookup(ParaPhCountFn, "klio_skia_para_ph_count"),
        .paraPhRect = lib.lookup(ParaPhRectFn, "klio_skia_para_ph_rect"),
        .icuDate = lib.lookup(IcuDateFn, "klio_icu_date"),
        .winOpen = F.get(&lib, "winOpen", "klio_win_open") orelse return skiaLoadFail(&lib),
        .winAttach = lib.lookup(WinAttachFn, "klio_win_attach"),
        .winSurface = F.get(&lib, "winSurface", "klio_win_surface") orelse return skiaLoadFail(&lib),
        .winPresent = F.get(&lib, "winPresent", "klio_win_present") orelse return skiaLoadFail(&lib),
        .winPoll = F.get(&lib, "winPoll", "klio_win_poll") orelse return skiaLoadFail(&lib),
        .winClose = F.get(&lib, "winClose", "klio_win_close") orelse return skiaLoadFail(&lib),
        .winSetResizeCb = lib.lookup(ResizeCbFn, "klio_win_set_resize_cb"),
        .winPollEvent = lib.lookup(WinPollEventFn, "klio_win_poll_event"),
        .winPostEvent = lib.lookup(WinPostEventFn, "klio_win_post_event"),
        .winSetFlag = lib.lookup(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_flag"),
        .winSetPosition = lib.lookup(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_position"),
        .winGetPosition = lib.lookup(*const fn (?*SkWindow, *c_int, *c_int) callconv(.c) void, "klio_win_get_position"),
        .screenBounds = lib.lookup(*const fn (*c_int, *c_int, *c_int, *c_int) callconv(.c) void, "klio_win_screen_bounds"),
        .winSetFrameSize = lib.lookup(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_frame_size"),
        .winGetFrameSize = lib.lookup(*const fn (?*SkWindow, *c_int, *c_int) callconv(.c) void, "klio_win_get_frame_size"),
        .winSetTitle = lib.lookup(*const fn (?*SkWindow, [*:0]const u8) callconv(.c) void, "klio_win_set_title"),
        .winSetSize = lib.lookup(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_size"),
        .winSetIconPng = lib.lookup(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_win_set_icon_png"),
        .winSetIconSurface = lib.lookup(*const fn (?*SkWindow, ?*SkSurface) callconv(.c) void, "klio_win_set_icon_surface"),
        .winSetMenu = lib.lookup(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_win_set_menu"),
        .winSetMenuIcon = lib.lookup(*const fn (?*SkWindow, c_int, ?*SkSurface) callconv(.c) void, "klio_win_set_menu_icon"),
        .winLastError = lib.lookup(*const fn () callconv(.c) [*:0]const u8, "klio_win_last_error"),
        .tray = TrayFns.fromLib(&lib),
        .clipChangeCount = lib.lookup(ClipChangeCountFn, "klio_clip_change_count"),
        .clipGetText = lib.lookup(ClipGetTextFn, "klio_clip_get_text"),
        .clipSetText = lib.lookup(ClipSetTextFn, "klio_clip_set_text"),
        .hostLocale = lib.lookup(HostLocaleFn, "klio_host_locale"),
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
        .cSetBlur = externSym(CRotateFn, "klio_skia_c_set_blur"),
        .cSetColorFilter = externSym(CSetColorFilterFn, "klio_skia_c_set_color_filter"),
        .cSetPaintState = externSym(CSetPaintStateFn, "klio_skia_c_set_paint_state"),
        .cDrawRect = externSym(CDrawRectFn, "klio_skia_c_draw_rect"),
        .cDrawRRect = externSym(CDrawRRectFn, "klio_skia_c_draw_rrect"),
        .cDrawOval = externSym(CDrawRectFn, "klio_skia_c_draw_oval"),
        .cDrawCircle = externSym(CDrawCircleFn, "klio_skia_c_draw_circle"),
        .cDrawLine = externSym(CDrawLineFn, "klio_skia_c_draw_line"),
        .cDrawPath = externSym(CDrawPathFn, "klio_skia_c_draw_path"),
        .cMeasureTextWidth = externSym(CMeasureTextWidthFn, "klio_skia_measure_text_width"),
        .cFontMetric = externSym(CFontMetricFn, "klio_skia_font_metric"),
        .surfPixel = externSym(SurfPixelFn, "klio_skia_surf_pixel"),
        .surfSize = externSym(SurfSizeFn, "klio_skia_surf_size"),
        .cDrawText2 = externSym(CDrawText2Fn, "klio_skia_c_draw_text2"),
        .cDrawSurface = externSym(CDrawSurfaceFn, "klio_skia_c_draw_surface"),
        .cDrawSurfaceRect = externSym(CDrawSurfaceRectFn, "klio_skia_c_draw_surface_rect"),
        .cSaveLayer = externSym(CSaveLayerFn, "klio_skia_c_save_layer"),
        .recBegin = externSym(RecBeginFn, "klio_skia_rec_begin_bounds"),
        .recEnd = externSym(RecEndFn, "klio_skia_rec_end"),
        .pictureFree = externSym(PictureFreeFn, "klio_skia_picture_free"),
        .cDrawPicture = externSym(CDrawPictureFn, "klio_skia_c_draw_picture"),
        .cConcat44 = externSym(CConcat44Fn, "klio_skia_c_concat44"),
        .rn = RenderNodeFns.fromExtern(),
        .cDrawPoint = externSym(CDrawPointFn, "klio_skia_c_draw_point"),
        .cSetPathEffect = externSym(CSetShaderFn, "klio_skia_c_set_path_effect"),
        .cDrawVertices = externSym(CDrawVerticesFn, "klio_skia_c_draw_vertices"),
        .imageDecode = externSym(ImageDecodeFn, "klio_skia_image_decode"),
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
        .fontRegisterData = externSym(FontRegisterDataFn, "klio_skia_font_register_data"),
        .paraPhCount = externSym(ParaPhCountFn, "klio_skia_para_ph_count"),
        .paraPhRect = externSym(ParaPhRectFn, "klio_skia_para_ph_rect"),
        .icuDate = externSym(IcuDateFn, "klio_icu_date"),
        .winOpen = externSym(@FieldType(Skia, "winOpen"), "klio_win_open"),
        .winAttach = externSym(WinAttachFn, "klio_win_attach"),
        .winSurface = externSym(@FieldType(Skia, "winSurface"), "klio_win_surface"),
        .winPresent = externSym(@FieldType(Skia, "winPresent"), "klio_win_present"),
        .winPoll = externSym(@FieldType(Skia, "winPoll"), "klio_win_poll"),
        .winClose = externSym(@FieldType(Skia, "winClose"), "klio_win_close"),
        .winSetResizeCb = externSym(ResizeCbFn, "klio_win_set_resize_cb"),
        .winPollEvent = externSym(WinPollEventFn, "klio_win_poll_event"),
        .winPostEvent = externSym(WinPostEventFn, "klio_win_post_event"),
        .winSetFlag = externSym(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_flag"),
        .winSetPosition = externSym(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_position"),
        .winGetPosition = externSym(*const fn (?*SkWindow, *c_int, *c_int) callconv(.c) void, "klio_win_get_position"),
        .screenBounds = externSym(*const fn (*c_int, *c_int, *c_int, *c_int) callconv(.c) void, "klio_win_screen_bounds"),
        .winSetFrameSize = externSym(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_frame_size"),
        .winGetFrameSize = externSym(*const fn (?*SkWindow, *c_int, *c_int) callconv(.c) void, "klio_win_get_frame_size"),
        .winSetTitle = externSym(*const fn (?*SkWindow, [*:0]const u8) callconv(.c) void, "klio_win_set_title"),
        .winSetSize = externSym(*const fn (?*SkWindow, c_int, c_int) callconv(.c) void, "klio_win_set_size"),
        .winSetIconPng = externSym(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_win_set_icon_png"),
        .winSetIconSurface = externSym(*const fn (?*SkWindow, ?*SkSurface) callconv(.c) void, "klio_win_set_icon_surface"),
        .winSetMenu = externSym(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_win_set_menu"),
        .winSetMenuIcon = externSym(*const fn (?*SkWindow, c_int, ?*SkSurface) callconv(.c) void, "klio_win_set_menu_icon"),
        .winLastError = externSym(*const fn () callconv(.c) [*:0]const u8, "klio_win_last_error"),
        .tray = TrayFns.fromExtern(),
        .clipChangeCount = externSym(ClipChangeCountFn, "klio_clip_change_count"),
        .clipGetText = externSym(ClipGetTextFn, "klio_clip_get_text"),
        .clipSetText = externSym(ClipSetTextFn, "klio_clip_set_text"),
        .hostLocale = externSym(HostLocaleFn, "klio_host_locale"),
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
        if (openSkiaAt(p)) |l| return l;
    }
    if (runtime.envOnce("KLIO_SKIA_LIB")) |p| {
        if (openSkiaAt(p)) |l| return l;
    }
    if (std.DynLib.open(skia_lib_name)) |l| return l else |_| {}
    // The install layout puts the shim in `lib/` next to the binary's `bin/`, so
    // resolving relative to the executable needs no loader-path setup.
    const exe_dir = selfExeDir() orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "../lib", "." }) |rel| {
        const p = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}", .{ exe_dir, rel, skia_lib_name }) catch continue;
        if (openSkiaAt(p)) |l| return l;
    }
    return null;
}

/// A symbol of the loaded Skia shim by name (skiko's glue natives), or null
/// without the shim or the symbol. A statically linked shim answers null.
pub fn skiaSymbol(name: [:0]const u8) ?*anyopaque {
    const s = loadSkia() orelse return null;
    if (comptime use_static_skia) return null;
    return s.lib.lookup(*anyopaque, name);
}

/// Opens the shim at `path`. A shim that is there but does not load (a
/// symbol the loader cannot bind, a library it needs) says why on standard
/// error; with no shim at all rendering stays headless without a word.
fn openSkiaAt(path: []const u8) ?std.DynLib {
    if (std.DynLib.open(path)) |l| return l else |_| {}
    const os = @import("builtin").os.tag;
    if (comptime os != .linux and os != .macos) return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    if (std.c.access(z, 0) != 0) return null;
    // DynLib.open keeps only an error code; opening again recovers the
    // loader's reason.
    if (std.c.dlopen(z, .{ .LAZY = true })) |h| {
        _ = std.c.dlclose(h);
        return null;
    }
    const why: []const u8 = if (std.c.dlerror()) |e| std.mem.span(e) else "unknown loader error";
    std.debug.print("klio: the Skia shim at {s} did not load ({s}); rendering is headless\n", .{ path, why });
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

/// Sets a window's icon from a surface the painter was drawn on.
fn winSetIconSurface(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    const f = skia.winSetIconSurface orelse return ok(Value.newLong(0));
    f(win, surf);
    return ok(Value.newLong(1));
}

/// Sets a window's menu bar from its entries (window_events.h's spec); an
/// empty spec removes it.
fn winSetMenu(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.winSetMenu orelse return ok(Value.newLong(0));
    const g = ctx.args[1].String.borrow();
    defer g.deinit();
    const bytes = g.get().bytes;
    f(win, bytes.ptr, bytes.len);
    return ok(Value.newLong(1));
}

/// Sets the icon of a window's menu item from a surface its painter was
/// drawn on.
fn winSetMenuIcon(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[2]) orelse return ok(Value.newLong(0));
    const f = skia.winSetMenuIcon orelse return ok(Value.newLong(0));
    f(win, @intCast(argInt(ctx.args[1])), surf);
    return ok(Value.newLong(1));
}

// A tray icon's bindings: the handle is the shim's tray as a Long.

fn trayArg(v: Value) ?*anyopaque {
    const h: u64 = @bitCast(argInt(v));
    if (h == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(h)));
}

fn traySupported(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const skia = loadSkia() orelse return ok(Value{ .Bool = false });
    const f = skia.tray.supported orelse return ok(Value{ .Bool = false });
    return ok(Value{ .Bool = f() != 0 });
}

fn trayOpen(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.tray.open orelse return ok(Value.newLong(0));
    const tray = f() orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(tray)))));
}

fn trayClose(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.tray.close orelse return ok(Value.newLong(0));
    f(trayArg(ctx.args[0]) orelse return ok(Value.newLong(0)));
    return ok(Value.newLong(1));
}

fn traySetIcon(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.tray.setIcon orelse return ok(Value.newLong(0));
    const tray = trayArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    f(tray, surfArg(ctx.args[1]) orelse return ok(Value.newLong(0)));
    return ok(Value.newLong(1));
}

fn traySetTooltip(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.tray.setTooltip orelse return ok(Value.newLong(0));
    const tray = trayArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    if (ctx.args[1] != .String) {
        f(tray, null, 0);
        return ok(Value.newLong(1));
    }
    const g = ctx.args[1].String.borrow();
    defer g.deinit();
    const bytes = g.get().bytes;
    f(tray, bytes.ptr, bytes.len);
    return ok(Value.newLong(1));
}

fn traySetMenu(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.tray.setMenu orelse return ok(Value.newLong(0));
    const tray = trayArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const g = ctx.args[1].String.borrow();
    defer g.deinit();
    const bytes = g.get().bytes;
    f(tray, bytes.ptr, bytes.len);
    return ok(Value.newLong(1));
}

fn trayNotify(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 4 or ctx.args[1] != .String or ctx.args[2] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.tray.notify orelse return ok(Value.newLong(0));
    const tray = trayArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const tg = ctx.args[1].String.borrow();
    defer tg.deinit();
    const mg = ctx.args[2].String.borrow();
    defer mg.deinit();
    const title = tg.get().bytes;
    const message = mg.get().bytes;
    f(tray, title.ptr, title.len, message.ptr, message.len, @intCast(argInt(ctx.args[3])));
    return ok(Value.newLong(1));
}

/// A tray's next event, its values written into the DoubleArray (as a
/// window's poll writes them); KLIO_EV_NONE when it has none.
fn trayPollEvent(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .Array) return ok(Value.newInt(0));
    const skia = loadSkia() orelse return ok(Value.newInt(0));
    const f = skia.tray.pollEvent orelse return ok(Value.newInt(0));
    const tray = trayArg(ctx.args[0]) orelse return ok(Value.newInt(0));
    var values = [_]f64{0} ** win_event_values;
    const kind = f(tray, &values);
    const arr = ctx.args[1].Array;
    const n = @min(arr.len(), win_event_values);
    for (0..n) |i| arr.set(ctx.allocator, i, Value{ .Double = values[i] });
    return ok(Value.newInt(kind));
}

/// Runs the platform's events for up to the timeout while no window polls
/// them; without the shim, sleeps.
fn appWait(ctx: *CallCtx) Error!EvalResult {
    const ms: i64 = if (ctx.args.len > 0) @max(0, argInt(ctx.args[0])) else 0;
    if (loadSkia()) |skia| {
        if (skia.tray.appWait) |f| {
            f(@intCast(@min(ms, std.math.maxInt(c_int))));
            return ok(Value.newLong(1));
        }
    }
    runtime.clockSleepMillis(ms);
    return ok(Value.newLong(0));
}

/// Writes a line on standard error, as the desktop's System.err.println.
fn printErr(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .String) return ok(Value.newLong(0));
    const g = ctx.args[0].String.borrow();
    defer g.deinit();
    std.debug.print("{s}\n", .{g.get().bytes});
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

/// Why the last window open failed, for the program's error.
var win_open_error: []const u8 = "";
var win_open_error_buf: [512]u8 = undefined;

fn winOpenError(ctx: *CallCtx) Error!EvalResult {
    return ok(.{ .String = try runtime.strInit(ctx.allocator, win_open_error) });
}

fn winOpen(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3 or ctx.args[2] != .String) return ok(Value.newLong(0));
    const skia = loadSkia() orelse {
        win_open_error = "no Skia shim is loaded (build it with `zig build skia-lib`)";
        return ok(Value.newLong(0));
    };
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
    const win = (win_opt orelse skia.winOpen(w, h, title_z.ptr)) orelse {
        const why: []const u8 = if (skia.winLastError) |f| std.mem.span(f()) else "";
        win_open_error = if (why.len == 0)
            "the Skia shim could not open a window"
        else
            std.fmt.bufPrint(&win_open_error_buf, "{s}", .{why}) catch why[0..@min(why.len, win_open_error_buf.len)];
        return ok(Value.newLong(0));
    };
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

/// `__composeui_winPollEvent(handle, timeoutMs, onResize?, out: DoubleArray): Int`:
/// wait up to timeoutMs for the window's next input event, write its values
/// into `out` and return its type (window_events.h's KLIO_EV_*): 0 none, 2
/// close. A supplied `onResize` runs during a live resize.
fn winPollEvent(ctx: *CallCtx) Error!EvalResult {
    const closed = Value.newInt(2);
    if (ctx.args.len < 4 or ctx.args[3] != .Array) return ok(closed);
    const skia = loadSkia() orelse return ok(closed);
    const poll = skia.winPollEvent orelse return ok(closed);
    const win = winHandle(ctx.args[0]) orelse return ok(closed);
    const timeout: c_int = @intCast(@max(0, argInt(ctx.args[1])));
    var rc: ResizeCb = undefined;
    const has_cb = ctx.args[2] != .Null and skia.winSetResizeCb != null;
    if (has_cb) {
        rc = .{ .host = ctx.host, .callback = ctx.args[2], .out = ctx.out };
        skia.winSetResizeCb.?(win, resizeTrampoline, &rc);
    }
    var values = [_]f64{0} ** win_event_values;
    const t = poll(win, timeout, &values);
    if (has_cb) skia.winSetResizeCb.?(win, null, null);
    const arr = ctx.args[3].Array;
    const n = @min(arr.len(), win_event_values);
    for (0..n) |i| arr.set(ctx.allocator, i, Value{ .Double = values[i] });
    return ok(Value.newInt(t));
}

/// `__composeui_winPostEvent(handle, type, values: DoubleArray)`: queue an
/// event on the window as if its platform had sent it.
fn winPostEvent(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3 or ctx.args[2] != .Array) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const post = skia.winPostEvent orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    var values = [_]f64{0} ** win_event_values;
    const arr = ctx.args[2].Array;
    const n = @min(arr.len(), win_event_values);
    for (0..n) |i| values[i] = arr.get(i).asF64() orelse 0;
    post(win, @intCast(argInt(ctx.args[1])), &values);
    return ok(Value.newLong(1));
}

/// `__composeui_winSetFlag(handle, which, value)`: set one of a window's
/// KLIO_WIN_* properties (window_events.h).
fn winSetFlag(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.winSetFlag orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    f(win, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2])));
    return ok(Value.newLong(1));
}

/// `__composeui_winSetPosition(handle, x, y)`: move the window frame's
/// top-left to (x, y) on the screen.
fn winSetPosition(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.winSetPosition orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    f(win, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2])));
    return ok(Value.newLong(1));
}

/// `__composeui_winPosition(handle): Long`: the window frame's top-left, x in
/// the high 32 bits and y in the low.
fn winPosition(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.winGetPosition orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    var x: c_int = 0;
    var y: c_int = 0;
    f(win, &x, &y);
    return ok(Value.newLong(packPoint(x, y)));
}

/// `__composeui_winSetFrameSize(handle, w, h)`: resize the window's frame,
/// title bar and border included.
fn winSetFrameSize(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 3) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.winSetFrameSize orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    f(win, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2])));
    return ok(Value.newLong(1));
}

/// `__composeui_winFrameSize(handle): Long`: the window frame's width in the
/// high 32 bits and height in the low.
fn winFrameSize(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.winGetFrameSize orelse return ok(Value.newLong(0));
    const win = winHandle(ctx.args[0]) orelse return ok(Value.newLong(0));
    var w: c_int = 0;
    var h: c_int = 0;
    f(win, &w, &h);
    return ok(Value.newLong(packPoint(w, h)));
}

fn packPoint(x: c_int, y: c_int) i64 {
    return (@as(i64, x) << 32) | @as(i64, @as(u32, @bitCast(y)));
}

/// `__composeui_screenBounds(which): Int`: the main screen's area for windows,
/// which 0 x, 1 y, 2 width, 3 height; 0 without a windowing backend.
fn screenBounds(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newInt(0));
    const skia = loadSkia() orelse return ok(Value.newInt(0));
    const f = skia.screenBounds orelse return ok(Value.newInt(0));
    var b: [4]c_int = .{ 0, 0, 0, 0 };
    f(&b[0], &b[1], &b[2], &b[3]);
    const which = argInt(ctx.args[0]);
    if (which < 0 or which > 3) return ok(Value.newInt(0));
    return ok(Value.newInt(b[@intCast(which)]));
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

/// The resident callbacks are held only here once `main` returns, so they are
/// a collection root of their own.
var callbacks_rooted = std.atomic.Value(bool).init(false);

fn markCallbacks(m: *runtime.gc.Marker) void {
    for ([_]*const FrameCb{ &frame_cb, &input_cb, &text_cb }) |cb| {
        if (cb.set) cb.callback.gcMark(m);
    }
}

/// Store `cb` in the resident slot `slot`, rooting the slots first.
fn keepCallback(slot: *FrameCb, cb: FrameCb) void {
    if (!callbacks_rooted.swap(true, .monotonic)) runtime.gc.registerRoot(markCallbacks);
    slot.* = cb;
}

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
    keepCallback(&frame_cb, .{ .host = ctx.host.persist(), .callback = ctx.args[0], .out = ctx.out, .set = true });
    return ok(Value.newLong(1));
}

fn setInputCallback(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    keepCallback(&input_cb, .{ .host = ctx.host.persist(), .callback = ctx.args[0], .out = ctx.out, .set = true });
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
    keepCallback(&text_cb, .{ .host = ctx.host.persist(), .callback = ctx.args[0], .out = ctx.out, .set = true });
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

// The clipboard klio.datatransfer's systemClipboard() answers with, as
// KLIO_CLIPBOARD picks it: unset or "system" the host's (none when the host
// has no clipboard the shim reaches), "private" one of the program's own that
// nothing outside it reads or changes, "none" no clipboard, as a headless
// desktop has.
pub const ClipboardMode = enum(i32) { none = 0, system = 1, private = 2 };

pub fn clipboardModeFor(setting: ?[]const u8, host_has_clipboard: bool) ClipboardMode {
    if (setting) |s| {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "private")) return .private;
    }
    return if (host_has_clipboard) .system else .none;
}

fn hostClipboard() ?*Skia {
    const skia = loadSkia() orelse return null;
    const count = skia.clipChangeCount orelse return null;
    if (skia.clipGetText == null or skia.clipSetText == null) return null;
    if (count() < 0) return null;
    return skia;
}

fn clipMode(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const setting = runtime.envOnce("KLIO_CLIPBOARD");
    const host = if (setting != null and !std.mem.eql(u8, setting.?, "system")) false else hostClipboard() != null;
    return ok(Value.newInt(@intFromEnum(clipboardModeFor(setting, host))));
}

fn clipChangeCount(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const skia = hostClipboard() orelse return ok(Value.newLong(-1));
    return ok(Value.newLong(skia.clipChangeCount.?()));
}

fn clipText(ctx: *CallCtx) Error!EvalResult {
    const skia = hostClipboard() orelse return ok(Value.Null);
    var len: usize = 0;
    const text = skia.clipGetText.?(&len) orelse return ok(Value.Null);
    defer if (skia.freeCstr) |free_fn| free_fn(@ptrCast(text));
    const a = ctx.allocator;
    const owned = try a.dupe(u8, text[0..len]);
    return ok(Value{ .String = try runtime.strInitOwned(a, owned) });
}

fn clipSetText(ctx: *CallCtx) Error!EvalResult {
    const skia = hostClipboard() orelse return ok(Value.newLong(0));
    const set = skia.clipSetText.?;
    if (ctx.args.len < 1 or ctx.args[0] != .String) {
        set(null, 0);
        return ok(Value.newLong(1));
    }
    const g = ctx.args[0].String.borrow();
    defer g.deinit();
    const bytes = g.get().bytes;
    set(bytes.ptr, bytes.len);
    return ok(Value.newLong(1));
}

/// The host's default locale as a language tag, as the JVM takes its default:
/// `KLIO_LOCALE` when set (the JVM's -Duser.language and -Duser.country);
/// else the platform's, from the Skia shim on macOS (the first preferred
/// language with the current region), iOS and Windows (the user's UI
/// language); else LC_ALL, LC_MESSAGES or LANG, read as the JVM reads a
/// POSIX locale name.
pub fn hostLocale(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    if (runtime.envOnce("KLIO_LOCALE")) |tag| {
        if (tag.len > 0) return ok(Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, tag)) });
    }
    if (loadSkia()) |skia| {
        if (skia.hostLocale) |f| {
            if (f()) |tag| {
                defer if (skia.freeCstr) |free_fn| free_fn(tag);
                const s = std.mem.span(tag);
                if (s.len > 0) return ok(Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, s)) });
            }
        }
    }
    const name = runtime.envOnce("LC_ALL") orelse runtime.envOnce("LC_MESSAGES") orelse runtime.envOnce("LANG");
    var buf: [64]u8 = undefined;
    const tag = posixLocaleTag(name, &buf);
    return ok(Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, tag)) });
}

/// A POSIX locale name (`language_COUNTRY.encoding@modifier`) as a language
/// tag. No name, an empty one, C and POSIX (with any encoding) read as
/// en_US, as the JVM reads them.
pub fn posixLocaleTag(name: ?[]const u8, buf: []u8) []const u8 {
    var n = name orelse "";
    if (n.len == 0) n = "C";
    // The encoding and modifier go.
    if (std.mem.indexOfAny(u8, n, ".@")) |i| n = n[0..i];
    if (n.len == 0 or std.mem.eql(u8, n, "C") or std.mem.eql(u8, n, "POSIX")) n = "en_US";
    if (n.len > buf.len) return "en-US";
    @memcpy(buf[0..n.len], n);
    for (buf[0..n.len]) |*c| {
        if (c.* == '_') c.* = '-';
    }
    return buf[0..n.len];
}

fn textInput(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    return ok(Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, staged_text[0..staged_text_len])) });
}

/// The host OS, as a lowercase name. foundation's `DesktopPlatform` needs it:
/// macOS binds the text shortcuts to Meta while Linux and Windows bind Ctrl.
pub fn hostOs(ctx: *CallCtx) Error!EvalResult {
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

/// A date question for the host's ICU (`klio_icu_date` in icu_shim.cpp):
/// (op, languageTag, a, b, millis). Null when ICU cannot answer or no Skia
/// backend is present.
fn icuDate(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 5) return ok(Value.Null);
    for (ctx.args[1..4]) |arg| if (arg != .String) return ok(Value.Null);
    const skia = loadSkia() orelse return ok(Value.Null);
    const date_fn = skia.icuDate orelse return ok(Value.Null);
    const free_fn = skia.freeCstr orelse return ok(Value.Null);
    const a = ctx.allocator;
    var z: [3][:0]u8 = undefined;
    for (0..3) |i| {
        const g = ctx.args[1 + i].String.borrow();
        defer g.deinit();
        z[i] = try a.dupeZ(u8, g.get().bytes);
    }
    defer for (z) |s| a.free(s);
    const millis: f64 = @floatFromInt(argInt(ctx.args[4]));
    const res = date_fn(@intCast(argInt(ctx.args[0])), z[0].ptr, z[1].ptr, z[2].ptr, millis) orelse return ok(Value.Null);
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

/// Register a font's bytes (a ByteArray) under a family name: true when they
/// load as a typeface.
fn fontRegisterData(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[0] != .Array) return ok(Value{ .Bool = false });
    const skia = loadSkia() orelse return ok(Value{ .Bool = false });
    const f = skia.fontRegisterData orelse return ok(Value{ .Bool = false });
    const family = (try specArg(ctx.allocator, ctx.args[1])) orelse return ok(Value{ .Bool = false });
    defer ctx.allocator.free(family);
    const arr = ctx.args[0].Array;
    const bytes = try ctx.allocator.alloc(u8, arr.len());
    defer ctx.allocator.free(bytes);
    for (bytes, 0..) |*b, i| b.* = switch (arr.get(i)) {
        .Byte => |x| @bitCast(x),
        else => 0,
    };
    return ok(Value{ .Bool = f(bytes.ptr, bytes.len, family.ptr) != 0 });
}

/// A surface's width (which 0) or height (which 1).
fn surfSize(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newInt(0));
    const skia = loadSkia() orelse return ok(Value.newInt(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newInt(0));
    const f = skia.surfSize orelse return ok(Value.newInt(0));
    return ok(Value.newInt(f(surf, @intCast(argInt(ctx.args[1])))));
}

/// Canvas.drawImage: (dst, src, x, y, sampling), sampling as the paint's
/// filter quality maps (0 nearest, 1 linear, 2 linear + nearest mipmap, 3 cubic).
fn canvasDrawSurface(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 5) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const dst = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const src = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    if (skia.cDrawSurface) |f| f(dst, src, argFloat(ctx.args[2]), argFloat(ctx.args[3]), @intCast(argInt(ctx.args[4])));
    return ok(Value.newLong(0));
}

/// A string argument as a sentinel-terminated copy; null when it is not a
/// string. The caller frees it.
fn specArg(allocator: std.mem.Allocator, v: Value) !?[:0]u8 {
    if (v != .String) return null;
    const g = v.String.borrow();
    defer g.deinit();
    return try allocator.dupeZ(u8, g.get().bytes);
}

/// Canvas.saveLayer: (handle, l, t, r, b, hasBounds, alpha, blendMode,
/// imageFilterSpec); the pending color filter joins the layer's paint.
fn canvasSaveLayer(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 9) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    const filter = (try specArg(ctx.allocator, a[8])) orelse return ok(Value.newLong(0));
    defer ctx.allocator.free(filter);
    if (skia.cSaveLayer) |f| f(
        surf,
        argFloat(a[1]),
        argFloat(a[2]),
        argFloat(a[3]),
        argFloat(a[4]),
        @intCast(argInt(a[5])),
        argFloat(a[6]),
        @intCast(argInt(a[7])),
        filter.ptr,
    );
    return ok(Value.newLong(0));
}

/// Arm the next draws' path effect spec; an empty spec clears it.
fn canvasSetPathEffect(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cSetPathEffect orelse return ok(Value.newLong(0));
    const spec = (try specArg(ctx.allocator, ctx.args[1])) orelse return ok(Value.newLong(0));
    defer ctx.allocator.free(spec);
    f(surf, spec.ptr);
    return ok(Value.newLong(0));
}

/// Canvas.drawVertices: (handle, mode, positions, texCoords, colors, indices,
/// blendMode, argb), the arrays as whitespace-separated number text.
fn canvasDrawVertices(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 8) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cDrawVertices orelse return ok(Value.newLong(0));
    const a = ctx.args;
    var texts: [4][:0]u8 = undefined;
    var n: usize = 0;
    defer for (texts[0..n]) |t| ctx.allocator.free(t);
    for (a[2..6]) |v| {
        texts[n] = (try specArg(ctx.allocator, v)) orelse return ok(Value.newLong(0));
        n += 1;
    }
    f(surf, @intCast(argInt(a[1])), texts[0].ptr, texts[1].ptr, texts[2].ptr, texts[3].ptr, @intCast(argInt(a[6])), argU32(a[7]));
    return ok(Value.newLong(0));
}

/// Decode an encoded image (a ByteArray) into a new surface of its size: the
/// surface's handle, or 0 when the bytes do not decode or there is no Skia.
fn imageDecode(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .Array) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.imageDecode orelse return ok(Value.newLong(0));
    const arr = ctx.args[0].Array;
    const bytes = try ctx.allocator.alloc(u8, arr.len());
    defer ctx.allocator.free(bytes);
    for (bytes, 0..) |*b, i| b.* = switch (arr.get(i)) {
        .Byte => |x| @bitCast(x),
        else => 0,
    };
    return ok(handleOf(f(bytes.ptr, bytes.len)));
}

/// Begin recording a picture over (left, top, right, bottom): returns a handle
/// that draws like a surface's, or 0 without the Skia backend.
fn recBegin(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 4) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.recBegin orelse return ok(Value.newLong(0));
    const a = ctx.args;
    const h = f(argFloat(a[0]), argFloat(a[1]), argFloat(a[2]), argFloat(a[3])) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(h)))));
}

/// Concat a Compose Matrix (its 16 values) onto the canvas, perspective included.
fn canvasConcat44(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 17) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cConcat44 orelse return ok(Value.newLong(0));
    var m: [16]f32 = undefined;
    for (&m, ctx.args[1..17]) |*d, v| d.* = argFloat(v);
    f(surf, m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11], m[12], m[13], m[14], m[15]);
    return ok(Value.newLong(0));
}

// Graphics layer nodes. A node or context handle is its pointer as a Long; 0
// without the Skia backend, which every entry point then answers with 0.

fn handleOf(p: ?*anyopaque) Value {
    return Value.newLong(if (p) |q| @bitCast(@as(u64, @intFromPtr(q))) else 0);
}

fn rnFns(ctx: *CallCtx, min_args: usize) ?*RenderNodeFns {
    if (ctx.args.len < min_args) return null;
    const skia = loadSkia() orelse return null;
    return &skia.rn;
}

fn rnContextNew(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 1) orelse return ok(Value.newLong(0));
    const f = rn.contextNew orelse return ok(Value.newLong(0));
    return ok(handleOf(f(@intCast(argInt(ctx.args[0])))));
}

fn rnContextFree(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 1) orelse return ok(Value.newLong(0));
    if (rn.contextFree) |f| if (surfArg(ctx.args[0])) |p| f(p);
    return ok(Value.newLong(0));
}

fn rnContextSetLighting(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 7) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (rn.contextSetLighting) |f| f(p, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]), argFloat(a[5]), argFloat(a[6]));
    return ok(Value.newLong(0));
}

fn rnNew(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 1) orelse return ok(Value.newLong(0));
    const context = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = rn.new orelse return ok(Value.newLong(0));
    return ok(handleOf(f(context)));
}

fn rnFree(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 1) orelse return ok(Value.newLong(0));
    if (rn.free) |f| if (surfArg(ctx.args[0])) |p| f(p);
    return ok(Value.newLong(0));
}

fn rnSetFloat(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 3) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    if (rn.setFloat) |f| f(p, @intCast(argInt(ctx.args[1])), argFloat(ctx.args[2]));
    return ok(Value.newLong(0));
}

fn rnSetColor(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 3) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    if (rn.setColor) |f| f(p, @intCast(argInt(ctx.args[1])), argU32(ctx.args[2]));
    return ok(Value.newLong(0));
}

fn rnSetBounds(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 5) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const a = ctx.args;
    if (rn.setBounds) |f| f(p, argFloat(a[1]), argFloat(a[2]), argFloat(a[3]), argFloat(a[4]));
    return ok(Value.newLong(0));
}

fn rnSetPivot(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 3) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    if (rn.setPivot) |f| f(p, argFloat(ctx.args[1]), argFloat(ctx.args[2]));
    return ok(Value.newLong(0));
}

fn rnSetClip(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 2) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    if (rn.setClip) |f| f(p, @intCast(argInt(ctx.args[1])));
    return ok(Value.newLong(0));
}

/// (node, kind, l, t, r, b, 8 corner radii, path): the outline a node clips to
/// and casts its shadow from.
fn rnSetOutline(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 15) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = rn.setOutline orelse return ok(Value.newLong(0));
    const a = ctx.args;
    var path: ?[:0]u8 = null;
    defer if (path) |t| ctx.allocator.free(t);
    if (a[14] == .String) {
        const g = a[14].String.borrow();
        defer g.deinit();
        path = try ctx.allocator.dupeZ(u8, g.get().bytes);
    }
    var v: [12]f32 = undefined;
    for (&v, a[2..14]) |*d, x| d.* = argFloat(x);
    f(p, @intCast(argInt(a[1])), v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], if (path) |t| t.ptr else null);
    return ok(Value.newLong(0));
}

fn rnSetLayerPaint(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 6) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = rn.setLayerPaint orelse return ok(Value.newLong(0));
    const a = ctx.args;
    const color_filter = (try specArg(ctx.allocator, a[4])) orelse return ok(Value.newLong(0));
    defer ctx.allocator.free(color_filter);
    const image_filter = (try specArg(ctx.allocator, a[5])) orelse return ok(Value.newLong(0));
    defer ctx.allocator.free(image_filter);
    f(p, @intCast(argInt(a[1])), argFloat(a[2]), @intCast(argInt(a[3])), color_filter.ptr, image_filter.ptr);
    return ok(Value.newLong(0));
}

fn rnBeginRecording(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 1) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = rn.beginRecording orelse return ok(Value.newLong(0));
    return ok(handleOf(f(p)));
}

fn rnEndRecording(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 2) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    if (rn.endRecording) |f| f(p, surfArg(ctx.args[1]));
    return ok(Value.newLong(0));
}

fn rnDrawInto(ctx: *CallCtx) Error!EvalResult {
    const rn = rnFns(ctx, 2) orelse return ok(Value.newLong(0));
    const p = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    if (rn.drawInto) |f| f(p, surf);
    return ok(Value.newLong(0));
}

/// Draw a point the stroke width across, round or square by the cap.
fn canvasDrawPoint(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 7) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cDrawPoint orelse return ok(Value.newLong(0));
    const a = ctx.args;
    f(surf, argFloat(a[1]), argFloat(a[2]), argU32(a[3]), argFloat(a[4]), @intCast(argInt(a[5])), @intCast(argInt(a[6])));
    return ok(Value.newLong(0));
}

/// End a recording, freeing its handle: returns the picture's handle.
fn recEnd(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const rec = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.recEnd orelse return ok(Value.newLong(0));
    const p = f(rec) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(p)))));
}

fn pictureFree(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (surfArg(ctx.args[0])) |p| if (skia.pictureFree) |f| f(p);
    return ok(Value.newLong(0));
}

fn canvasDrawPicture(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const pic = surfArg(ctx.args[1]) orelse return ok(Value.newLong(0));
    if (skia.cDrawPicture) |f| f(surf, pic);
    return ok(Value.newLong(0));
}

fn canvasDrawSurfaceRect(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 11) return ok(Value.newLong(0));
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
        @intCast(argInt(ctx.args[10])),
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

/// Arm the next draw's blur by its sigma; zero clears it.
fn canvasSetBlur(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 2) if (surfArg(ctx.args[0])) |s| if (skia.cSetBlur) |f| f(s, argFloat(ctx.args[1]));
    return ok(Value.newLong(0));
}

/// Arm the next draws' color filter spec; an empty spec clears it.
fn canvasSetColorFilter(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len < 2) return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const f = skia.cSetColorFilter orelse return ok(Value.newLong(0));
    const spec = (try specArg(ctx.allocator, ctx.args[1])) orelse return ok(Value.newLong(0));
    defer ctx.allocator.free(spec);
    f(surf, spec.ptr);
    return ok(Value.newLong(0));
}

/// Arm the next draws' blend mode, an image draw's alpha and the stroke miter
/// limit, (mode, alpha, miter); a negative mode resets them.
fn canvasSetPaintState(ctx: *CallCtx) Error!EvalResult {
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    if (ctx.args.len >= 4) if (surfArg(ctx.args[0])) |s| if (skia.cSetPaintState) |f|
        f(s, @intCast(argInt(ctx.args[1])), argFloat(ctx.args[2]), argFloat(ctx.args[3]));
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

const testing = std.testing;

test "a resident callback is marked by the callbacks' root" {
    const a = std.testing.allocator;
    const saved = text_cb;
    defer text_cb = saved;
    const callback = try runtime.strInit(a, "callback");
    defer callback.deinit();
    text_cb = .{ .host = undefined, .callback = .{ .String = callback }, .out = undefined, .set = true };
    var m: runtime.gc.Marker = .{ .epoch = 93, .arena = a };
    defer m.grey.deinit(a);
    markCallbacks(&m);
    try std.testing.expectEqual(@as(usize, 93), callback.cell.hdr.gc_mark);
}

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
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_set_blur") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_set_color_filter") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_draw_text") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__composeui_text_width") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__composeui_font_metric") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_save_layer") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_rec_begin") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_rec_end") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_picture_free") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_draw_picture") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_concat44") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.layer.__skia_rn_new") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.layer.__skia_rn_set_outline") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.layer.__skia_rn_draw_into") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_draw_point") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_set_paint_state") != null);
    try testing.expect(b.resolve("androidx.compose.material3.internal.__klio_icu_date") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_set_path_effect") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_c_draw_vertices") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_image_decode") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_surf_size") != null);
    try testing.expect(b.resolve("androidx.compose.ui.text.platform.__skia_font_register_data") != null);
    try testing.expect(b.resolve("androidx.compose.ui.input.key.__composeui_hostOs") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winPollEvent") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winPostEvent") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winSetFlag") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_screenBounds") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winFrameSize") != null);
    try testing.expect(b.resolve("klio.datatransfer.__klio_clipMode") != null);
    try testing.expect(b.resolve("klio.datatransfer.__klio_clipChangeCount") != null);
    try testing.expect(b.resolve("klio.datatransfer.__klio_clipText") != null);
    try testing.expect(b.resolve("klio.datatransfer.__klio_clipSetText") != null);
    try testing.expect(b.resolve("androidx.compose.ui.text.intl.__composeui_hostLocale") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winSetIconSurface") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winSetMenu") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_trayPollEvent") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_appWait") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winOpenError") != null);
    try testing.expectEqual(@as(usize, 137), b.len());
}

test "a window that cannot open says why" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    win_open_error = "SDL could not create a window: no display";
    var ctx: CallCtx = undefined;
    ctx.allocator = arena.allocator();
    ctx.args = &.{};
    const r = try winOpenError(&ctx);
    const g = r.ok.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("SDL could not create a window: no display", g.get().bytes);
    win_open_error = "";
}

test "a POSIX locale name reads as the JVM reads it" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("de-DE", posixLocaleTag("de_DE.UTF-8", &buf));
    try testing.expectEqualStrings("sr-RS", posixLocaleTag("sr_RS@latin", &buf));
    try testing.expectEqualStrings("fr", posixLocaleTag("fr", &buf));
    try testing.expectEqualStrings("en-US", posixLocaleTag("C.UTF-8", &buf));
    try testing.expectEqualStrings("en-US", posixLocaleTag("POSIX", &buf));
    try testing.expectEqualStrings("en-US", posixLocaleTag("", &buf));
    try testing.expectEqualStrings("en-US", posixLocaleTag(null, &buf));
    var small: [2]u8 = undefined;
    try testing.expectEqualStrings("en-US", posixLocaleTag("de_DE", &small));
}

test "KLIO_CLIPBOARD picks the host's clipboard, the program's own, or none" {
    try testing.expectEqual(ClipboardMode.system, clipboardModeFor(null, true));
    try testing.expectEqual(ClipboardMode.system, clipboardModeFor("system", true));
    // A host without a clipboard has none, as a headless desktop has.
    try testing.expectEqual(ClipboardMode.none, clipboardModeFor(null, false));
    try testing.expectEqual(ClipboardMode.none, clipboardModeFor("system", false));
    try testing.expectEqual(ClipboardMode.private, clipboardModeFor("private", true));
    try testing.expectEqual(ClipboardMode.private, clipboardModeFor("private", false));
    try testing.expectEqual(ClipboardMode.none, clipboardModeFor("none", true));
    // An unknown setting leaves the host's.
    try testing.expectEqual(ClipboardMode.system, clipboardModeFor("other", true));
}

test "the clipboard bindings answer no clipboard without the library" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c0 = host.ctx(&none);
    // The Skia shim is absent in the unit-test environment.
    if (loadSkia() == null) {
        try testing.expectEqual(@as(i64, -1), (try clipChangeCount(&c0)).ok.Long);
        try testing.expect((try clipText(&c0)).ok == .Null);
        try testing.expectEqual(@as(i64, 0), (try clipSetText(&c0)).ok.Long);
    }
}

test "the ICU date and paint state bindings answer null or 0 for short args" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c0 = host.ctx(&none);
    try testing.expect((try icuDate(&c0)).ok == .Null);
    try testing.expectEqual(@as(i64, 0), (try canvasSetPaintState(&c0)).ok.Long);
    // A non-string locale, pattern or text answers null before any ICU call.
    const wrong = [_]Value{ Value.newInt(0), Value.newInt(1), Value.newInt(2), Value.newInt(3), Value.newLong(0) };
    var c1 = host.ctx(&wrong);
    try testing.expect((try icuDate(&c1)).ok == .Null);
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

test "a window position packs x high and y low, negatives kept" {
    const v = packPoint(-5, -7);
    try testing.expectEqual(@as(i32, -5), @as(i32, @truncate(v >> 32)));
    try testing.expectEqual(@as(i32, -7), @as(i32, @truncate(v)));
    try testing.expectEqual(@as(i64, (3 << 32) | 4), packPoint(3, 4));
}

test "window control bindings answer 0 for short args" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c0 = host.ctx(&none);
    try testing.expectEqual(@as(i64, 0), (try winSetFlag(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try winSetPosition(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try winPosition(&c0)).ok.Long);
    try testing.expectEqual(@as(i32, 0), (try screenBounds(&c0)).ok.Int);
    try testing.expectEqual(@as(i64, 0), (try winSetFrameSize(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try winFrameSize(&c0)).ok.Long);
}

test "window event bindings report a closed window for short args or no event array" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c0 = host.ctx(&none);
    try testing.expectEqual(@as(i32, 2), (try winPollEvent(&c0)).ok.Int);
    try testing.expectEqual(@as(i64, 0), (try winPostEvent(&c0)).ok.Long);
    // The values must come in a DoubleArray.
    const no_array = [_]Value{ Value.newLong(0), Value.newInt(0), .Null, Value.newInt(3) };
    var c1 = host.ctx(&no_array);
    try testing.expectEqual(@as(i32, 2), (try winPollEvent(&c1)).ok.Int);
}

test "picture recording and layer bindings answer 0 for short args or a null handle" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c0 = host.ctx(&none);
    try testing.expectEqual(@as(i64, 0), (try recBegin(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try recEnd(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try canvasSaveLayer(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try canvasDrawPicture(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try pictureFree(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try canvasConcat44(&c0)).ok.Long);
    inline for (.{ rnContextNew, rnContextFree, rnContextSetLighting, rnNew, rnFree, rnSetFloat, rnSetColor, rnSetBounds, rnSetPivot, rnSetClip, rnSetOutline, rnSetLayerPaint, rnBeginRecording, rnEndRecording, rnDrawInto }) |f| {
        try testing.expectEqual(@as(i64, 0), (try f(&c0)).ok.Long);
    }
    try testing.expectEqual(@as(i64, 0), (try canvasDrawPoint(&c0)).ok.Long);
    // Two floats were a recording's size; the bounds take four.
    const size_only = [_]Value{ .{ .Float = 10 }, .{ .Float = 10 } };
    var c2 = host.ctx(&size_only);
    try testing.expectEqual(@as(i64, 0), (try recBegin(&c2)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try canvasSetPathEffect(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try canvasDrawVertices(&c0)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try imageDecode(&c0)).ok.Long);
    // Bytes that are not a ByteArray decode to nothing.
    const not_bytes = [_]Value{Value.newInt(7)};
    var c4 = host.ctx(&not_bytes);
    try testing.expectEqual(@as(i64, 0), (try imageDecode(&c4)).ok.Long);
    try testing.expect(!(try fontRegisterData(&c4)).ok.Bool);
    // A null node answers 0 without reaching the library.
    var zeros: [15]Value = undefined;
    for (&zeros) |*v| v.* = Value.newLong(0);
    var c3 = host.ctx(&zeros);
    try testing.expectEqual(@as(i64, 0), (try rnSetOutline(&c3)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try rnBeginRecording(&c3)).ok.Long);
    const null_handle = [_]Value{Value.newLong(0)};
    var c1 = host.ctx(&null_handle);
    try testing.expectEqual(@as(i64, 0), (try recEnd(&c1)).ok.Long);
    try testing.expectEqual(@as(i64, 0), (try pictureFree(&c1)).ok.Long);
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
