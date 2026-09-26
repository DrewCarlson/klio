//! Host side of the Compose UI packs: windows, trays, menus, pointer, touch
//! and text input, the clipboard, the raster surfaces ui-graphics draws on, and
//! the host's locale and date formats. The Skia shim (libklio_skia) is
//! dlopened lazily so the interpreter never links libstdc++ or Skia; without it
//! rendering is headless.

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

pub fn hostBindings(allocator: std.mem.Allocator) Error!HostBindings {
    var b = HostBindings.init(allocator);
    try b.register("androidx.compose.foundation.__composeui_hostOs", hostOs);
    try b.register("androidx.compose.ui.input.key.__composeui_hostOs", hostOs);
    try b.register("androidx.compose.ui.window.__composeui_winOpen", winOpen);
    try b.register("androidx.compose.ui.window.__composeui_winOpenError", winOpenError);
    try b.register("androidx.compose.ui.window.__composeui_winSetTitle", winSetTitle);
    try b.register("androidx.compose.ui.window.__composeui_winSetSize", winSetSize);
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
    try b.register("androidx.compose.ui.window.__composeui_winSetTextInput", winSetTextInput);
    try b.register("androidx.compose.ui.window.__composeui_winSetTextInputRect", winSetTextInputRect);
    try b.register("androidx.compose.ui.window.__composeui_winEndComposition", winEndComposition);
    try b.register("androidx.compose.ui.window.__composeui_winEventText", winEventText);
    try b.register("androidx.compose.ui.window.__composeui_a11yActive", a11yActive);
    try b.register("androidx.compose.ui.window.__composeui_a11yUpdate", a11yUpdate);
    try b.register("androidx.compose.ui.window.__composeui_winSetCursor", winSetCursor);
    try b.register("androidx.compose.ui.window.__composeui_winRefreshHz", winRefreshHz);
    try b.register("androidx.compose.ui.window.__composeui_winDragStart", winDragStart);
    try b.register("androidx.compose.ui.window.__composeui_winDndAccept", winDndAccept);
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
    try b.register("androidx.compose.ui.graphics.__skia_surf_new", surfNew);
    try b.register("androidx.compose.ui.graphics.__skia_surf_save_png", surfSavePng);
    try b.register("androidx.compose.ui.graphics.__skia_surf_free", surfFree);
    try b.register("androidx.compose.ui.graphics.__skia_surf_canvas", surfCanvas);
    try b.register("androidx.compose.material3.internal.__klio_icu_date", icuDate);
    try b.register("androidx.compose.ui.platform.__composeui_openUri", openUri);
    return b;
}

/// `__composeui_openUri(uri): Boolean`: opens [uri] with the platform's
/// handler for it (`open` on macOS, the URL protocol handler on Windows,
/// `xdg-open` elsewhere); `$KLIO_URI_OPENER` names a program to run with the
/// URI instead. False when the opener could not run or reported a failure.
fn openUri(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1 or ctx.args[0] != .String) return ok(Value{ .Bool = false });
    const ug = ctx.args[0].String.borrow();
    defer ug.deinit();
    const uri = ug.get().bytes;
    var argv_buf: [3][]const u8 = undefined;
    const argv: []const []const u8 = if (runtime.envOnce("KLIO_URI_OPENER")) |opener| blk: {
        argv_buf[0] = opener;
        argv_buf[1] = uri;
        break :blk argv_buf[0..2];
    } else switch (@import("builtin").os.tag) {
        .macos => blk: {
            argv_buf[0] = "open";
            argv_buf[1] = uri;
            break :blk argv_buf[0..2];
        },
        .windows => blk: {
            argv_buf[0] = "rundll32";
            argv_buf[1] = "url.dll,FileProtocolHandler";
            argv_buf[2] = uri;
            break :blk argv_buf[0..3];
        },
        else => blk: {
            argv_buf[0] = "xdg-open";
            argv_buf[1] = uri;
            break :blk argv_buf[0..2];
        },
    };
    const a = ctx.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const r = std.process.run(a, threaded.io(), .{ .argv = argv }) catch return ok(Value{ .Bool = false });
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    const opened = switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return ok(Value{ .Bool = opened });
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

const SkSurface = anyopaque;
const SkWindow = anyopaque;

const Skia = struct {
    lib: runtime.platform.DynLib,
    new: *const fn (c_int, c_int) callconv(.c) ?*SkSurface,
    free: *const fn (?*SkSurface) callconv(.c) void,
    clear: *const fn (?*SkSurface, u32) callconv(.c) void,
    savePng: *const fn (?*SkSurface, [*:0]const u8) callconv(.c) c_int,
    freeCstr: ?FreeCstrFn,
    surfCanvas: ?SurfCanvasFn,
    icuDate: ?IcuDateFn,
    winOpen: *const fn (c_int, c_int, [*:0]const u8) callconv(.c) ?*SkWindow,
    /// Optional: mobile backends attach to an OS-provided surface layer; null on
    /// desktop, where `winOpen` creates the window.
    winAttach: ?WinAttachFn,
    winSurface: *const fn (?*SkWindow) callconv(.c) ?*SkSurface,
    winPresent: *const fn (?*SkWindow) callconv(.c) void,
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
    winSetTextInput: ?*const fn (?*SkWindow, c_int) callconv(.c) void,
    winSetTextInputRect: ?*const fn (?*SkWindow, c_int, c_int, c_int, c_int) callconv(.c) void,
    winEndComposition: ?*const fn (?*SkWindow) callconv(.c) void,
    winEventText: ?WinEventTextFn,
    systemTheme: ?*const fn () callconv(.c) c_int,
    orderEmojiPalette: ?*const fn () callconv(.c) void,
    a11yActive: ?*const fn (?*SkWindow) callconv(.c) c_int,
    a11yUpdate: ?*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void,
    winSetCursor: ?*const fn (?*SkWindow, c_int) callconv(.c) void,
    winRefreshHz: ?*const fn (?*SkWindow) callconv(.c) c_int,
    winDragStart: ?WinDragStartFn,
    winDndAccept: ?*const fn (?*SkWindow, c_int) callconv(.c) void,
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

    fn fromLib(lib: *runtime.platform.DynLib) TrayFns {
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
const WinEventTextFn = *const fn (?*SkWindow, ?[*]u8, usize) callconv(.c) usize;
const WinDragStartFn = *const fn (?*SkWindow, [*]const u8, usize, [*]const u8, usize, c_int, c_int, c_int) callconv(.c) c_int;
/// The values of one window event (src/compose_ui/window_events.h).
const win_event_values = 12;
const ResizeCbFn = *const fn (?*SkWindow, ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void, ?*anyopaque) callconv(.c) void;
const FreeCstrFn = *const fn ([*:0]u8) callconv(.c) void;
const IcuDateFn = *const fn (c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8, f64) callconv(.c) ?[*:0]u8;

// The SkCanvas* a surface draws through, for a skiko Canvas to wrap; optional
// so a stale shared library degrades to no drawing instead of failing the load.
const SurfCanvasFn = *const fn (?*SkSurface) callconv(.c) ?*anyopaque;

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
        fn get(l: *runtime.platform.DynLib, comptime name: []const u8, comptime sym: [:0]const u8) ?@FieldType(Skia, name) {
            const f = l.lookup(@FieldType(Skia, name), sym);
            if (f == null) std.debug.print("klio: the Skia shim is missing {s}; rendering is headless\n", .{sym});
            return f;
        }
    };
    const s = Skia{
        .lib = lib,
        .new = F.get(&lib, "new", "klio_skia_new") orelse return skiaLoadFail(&lib),
        .free = F.get(&lib, "free", "klio_skia_free") orelse return skiaLoadFail(&lib),
        .clear = F.get(&lib, "clear", "klio_skia_clear") orelse return skiaLoadFail(&lib),
        .savePng = F.get(&lib, "savePng", "klio_skia_save_png") orelse return skiaLoadFail(&lib),
        .freeCstr = lib.lookup(FreeCstrFn, "klio_skia_free_cstr"),
        .surfCanvas = lib.lookup(SurfCanvasFn, "klio_skia_surf_canvas"),
        .icuDate = lib.lookup(IcuDateFn, "klio_icu_date"),
        .winOpen = F.get(&lib, "winOpen", "klio_win_open") orelse return skiaLoadFail(&lib),
        .winAttach = lib.lookup(WinAttachFn, "klio_win_attach"),
        .winSurface = F.get(&lib, "winSurface", "klio_win_surface") orelse return skiaLoadFail(&lib),
        .winPresent = F.get(&lib, "winPresent", "klio_win_present") orelse return skiaLoadFail(&lib),
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
        .winSetTextInput = lib.lookup(*const fn (?*SkWindow, c_int) callconv(.c) void, "klio_win_set_text_input"),
        .winSetTextInputRect = lib.lookup(*const fn (?*SkWindow, c_int, c_int, c_int, c_int) callconv(.c) void, "klio_win_set_text_input_rect"),
        .winEndComposition = lib.lookup(*const fn (?*SkWindow) callconv(.c) void, "klio_win_end_composition"),
        .winEventText = lib.lookup(WinEventTextFn, "klio_win_event_text"),
        .systemTheme = lib.lookup(*const fn () callconv(.c) c_int, "klio_system_theme"),
        .orderEmojiPalette = lib.lookup(*const fn () callconv(.c) void, "klio_order_emoji_palette"),
        .a11yActive = lib.lookup(*const fn (?*SkWindow) callconv(.c) c_int, "klio_a11y_active"),
        .a11yUpdate = lib.lookup(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_a11y_update"),
        .winSetCursor = lib.lookup(*const fn (?*SkWindow, c_int) callconv(.c) void, "klio_win_set_cursor"),
        .winRefreshHz = lib.lookup(*const fn (?*SkWindow) callconv(.c) c_int, "klio_win_refresh_hz"),
        .winDragStart = lib.lookup(WinDragStartFn, "klio_win_drag_start"),
        .winDndAccept = lib.lookup(*const fn (?*SkWindow, c_int) callconv(.c) void, "klio_win_dnd_accept"),
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

fn skiaLoadFail(lib: *runtime.platform.DynLib) ?*Skia {
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
        .free = externSym(@FieldType(Skia, "free"), "klio_skia_free"),
        .clear = externSym(@FieldType(Skia, "clear"), "klio_skia_clear"),
        .savePng = externSym(@FieldType(Skia, "savePng"), "klio_skia_save_png"),
        .freeCstr = externSym(FreeCstrFn, "klio_skia_free_cstr"),
        .surfCanvas = externSym(SurfCanvasFn, "klio_skia_surf_canvas"),
        .icuDate = externSym(IcuDateFn, "klio_icu_date"),
        .winOpen = externSym(@FieldType(Skia, "winOpen"), "klio_win_open"),
        .winAttach = externSym(WinAttachFn, "klio_win_attach"),
        .winSurface = externSym(@FieldType(Skia, "winSurface"), "klio_win_surface"),
        .winPresent = externSym(@FieldType(Skia, "winPresent"), "klio_win_present"),
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
        .winSetTextInput = externSym(*const fn (?*SkWindow, c_int) callconv(.c) void, "klio_win_set_text_input"),
        .winSetTextInputRect = externSym(*const fn (?*SkWindow, c_int, c_int, c_int, c_int) callconv(.c) void, "klio_win_set_text_input_rect"),
        .winEndComposition = externSym(*const fn (?*SkWindow) callconv(.c) void, "klio_win_end_composition"),
        .winEventText = externSym(WinEventTextFn, "klio_win_event_text"),
        .systemTheme = externSym(*const fn () callconv(.c) c_int, "klio_system_theme"),
        .orderEmojiPalette = externSym(*const fn () callconv(.c) void, "klio_order_emoji_palette"),
        .a11yActive = externSym(*const fn (?*SkWindow) callconv(.c) c_int, "klio_a11y_active"),
        .a11yUpdate = externSym(*const fn (?*SkWindow, [*]const u8, usize) callconv(.c) void, "klio_a11y_update"),
        .winSetCursor = externSym(*const fn (?*SkWindow, c_int) callconv(.c) void, "klio_win_set_cursor"),
        .winRefreshHz = externSym(*const fn (?*SkWindow) callconv(.c) c_int, "klio_win_refresh_hz"),
        .winDragStart = externSym(WinDragStartFn, "klio_win_drag_start"),
        .winDndAccept = externSym(*const fn (?*SkWindow, c_int) callconv(.c) void, "klio_win_dnd_accept"),
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

fn openSkiaLib() ?runtime.platform.DynLib {
    if (skia_lib_override) |p| {
        if (openSkiaAt(p)) |l| return l;
    }
    if (runtime.envOnce("KLIO_SKIA_LIB")) |p| {
        if (openSkiaAt(p)) |l| return l;
    }
    if (runtime.platform.DynLib.open(skia_lib_name)) |l| return l else |_| {}
    // The install layout puts the shim in `lib/` next to the binary's `bin/`, so
    // resolving relative to the executable needs no loader-path setup.
    const exe_dir = selfExeDir() orelse return null;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&path_buf);
    for ([_][]const []const u8{ &.{ exe_dir, "..", "lib", skia_lib_name }, &.{ exe_dir, skia_lib_name } }) |parts| {
        fba.reset();
        const p = std.fs.path.join(fba.allocator(), parts) catch continue;
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
fn openSkiaAt(path: []const u8) ?runtime.platform.DynLib {
    if (runtime.platform.DynLib.open(path)) |l| return l else |_| {}
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
    const path = runtime.platform.selfExePath(&self_exe_buf) orelse return null;
    return std.fs.path.dirname(path);
}

// Windowing intrinsics: open an on-screen window, hand its surface to the
// frame's draw, and pump input events. The window handle reaches Kotlin as a Long
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

/// Registered for the duration of a `winPollEvent` so the shim's live-resize
/// observer can drive a frame while the modal drag blocks the VM's loop. The
/// render callback is a live poll argument, so it needs no separate GC root.
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

/// `__composeui_winSetTextInput(handle, enabled)`: a text field has the
/// window's keyboard, or none has; the window's input method is on only while
/// one has it.
fn winSetTextInput(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(.{ .Unit = {} });
    const skia = loadSkia() orelse return ok(.{ .Unit = {} });
    const f = skia.winSetTextInput orelse return ok(.{ .Unit = {} });
    const win = winHandle(ctx.args[0]) orelse return ok(.{ .Unit = {} });
    f(win, @intFromBool(ctx.args[1] == .Bool and ctx.args[1].Bool));
    return ok(.{ .Unit = {} });
}

/// `__composeui_winSetTextInputRect(handle, x, y, w, h)`: the focused text
/// field's cursor in the window's content, where the input method's candidate
/// window goes.
fn winSetTextInputRect(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 5) return ok(.{ .Unit = {} });
    const skia = loadSkia() orelse return ok(.{ .Unit = {} });
    const f = skia.winSetTextInputRect orelse return ok(.{ .Unit = {} });
    const win = winHandle(ctx.args[0]) orelse return ok(.{ .Unit = {} });
    f(win, @intCast(argInt(ctx.args[1])), @intCast(argInt(ctx.args[2])), @intCast(argInt(ctx.args[3])), @intCast(argInt(ctx.args[4])));
    return ok(.{ .Unit = {} });
}

/// `__composeui_winEndComposition(handle)`: the text field ended the
/// composition itself, so the input method drops its own.
fn winEndComposition(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(.{ .Unit = {} });
    const skia = loadSkia() orelse return ok(.{ .Unit = {} });
    const f = skia.winEndComposition orelse return ok(.{ .Unit = {} });
    const win = winHandle(ctx.args[0]) orelse return ok(.{ .Unit = {} });
    f(win);
    return ok(.{ .Unit = {} });
}

/// `__composeui_winEventText(handle): String`: the text of the event the
/// window's last poll returned (an input method's), "" for none.
fn winEventText(ctx: *CallCtx) Error!EvalResult {
    const a = ctx.allocator;
    const empty = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "")) };
    if (ctx.args.len < 1) return ok(empty);
    const skia = loadSkia() orelse return ok(empty);
    const f = skia.winEventText orelse return ok(empty);
    const win = winHandle(ctx.args[0]) orelse return ok(empty);
    const n = f(win, null, 0);
    if (n == 0) return ok(empty);
    empty.String.deinit();
    const buf = try a.alloc(u8, n + 1);
    defer a.free(buf);
    _ = f(win, buf.ptr, buf.len);
    return ok(Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, buf[0..n])) });
}

/// `__skiko_systemTheme(): Int`: the system's appearance, 0 light, 1 dark, 2
/// unknown. `KLIO_SYSTEM_THEME` (light, dark or unknown) answers in its place,
/// so a run's output does not depend on the host's setting; without the Skia
/// shim it is unknown.
pub fn systemTheme(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    if (runtime.envOnce("KLIO_SYSTEM_THEME")) |forced| {
        const theme: i32 = if (std.ascii.eqlIgnoreCase(forced, "light"))
            0
        else if (std.ascii.eqlIgnoreCase(forced, "dark"))
            1
        else
            2;
        return ok(Value.newInt(theme));
    }
    const skia = loadSkia() orelse return ok(Value.newInt(2));
    const f = skia.systemTheme orelse return ok(Value.newInt(2));
    return ok(Value.newInt(f()));
}

/// `orderEmojiAndSymbolsPopup()`: opens the system's emoji and symbols
/// palette, as skiko does on macOS; elsewhere, and without the Skia shim,
/// nothing opens.
pub fn orderEmojiPalette(ctx: *CallCtx) Error!EvalResult {
    _ = ctx;
    const skia = loadSkia() orelse return ok(.{ .Unit = {} });
    if (skia.orderEmojiPalette) |f| f();
    return ok(.{ .Unit = {} });
}

/// `__composeui_a11yActive(handle): Boolean`: whether an assistive client
/// reads the window, so its semantics are worth sending.
fn a11yActive(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value{ .Bool = false });
    const skia = loadSkia() orelse return ok(Value{ .Bool = false });
    const f = skia.a11yActive orelse return ok(Value{ .Bool = false });
    const win = winHandle(ctx.args[0]) orelse return ok(Value{ .Bool = false });
    return ok(Value{ .Bool = f(win) != 0 });
}

/// `__composeui_a11yUpdate(handle, snapshot)`: the window's semantics for
/// assistive technologies (KlioWindowAccessibility.kt's snapshot).
fn a11yUpdate(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2 or ctx.args[1] != .String) return ok(.{ .Unit = {} });
    const skia = loadSkia() orelse return ok(.{ .Unit = {} });
    const f = skia.a11yUpdate orelse return ok(.{ .Unit = {} });
    const win = winHandle(ctx.args[0]) orelse return ok(.{ .Unit = {} });
    const g = ctx.args[1].String.borrow();
    defer g.deinit();
    const bytes = g.get().bytes;
    f(win, bytes.ptr, bytes.len);
    return ok(.{ .Unit = {} });
}

/// `__composeui_winSetCursor(handle, kind)`: the system cursor (the shim's
/// KLIO_CURSOR_*) the window shows over its content, as a pointer icon asks.
fn winSetCursor(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(.{ .Unit = {} });
    const skia = loadSkia() orelse return ok(.{ .Unit = {} });
    const f = skia.winSetCursor orelse return ok(.{ .Unit = {} });
    const win = winHandle(ctx.args[0]) orelse return ok(.{ .Unit = {} });
    f(win, @intCast(argInt(ctx.args[1])));
    return ok(.{ .Unit = {} });
}

/// `__composeui_winRefreshHz(handle): Int`: the refresh rate of the display
/// the window is on, in frames a second; 0 where the platform does not say.
fn winRefreshHz(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value{ .Int = 0 });
    const skia = loadSkia() orelse return ok(Value{ .Int = 0 });
    const f = skia.winRefreshHz orelse return ok(Value{ .Int = 0 });
    const win = winHandle(ctx.args[0]) orelse return ok(Value{ .Int = 0 });
    return ok(Value{ .Int = @intCast(f(win)) });
}

/// `__composeui_winDragStart(handle, payload, png, offsetX, offsetY, actions):
/// Boolean`: starts a platform drag from the window (KlioWindowDragAndDrop.kt).
fn winDragStart(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 6 or ctx.args[1] != .String) return ok(Value{ .Bool = false });
    const skia = loadSkia() orelse return ok(Value{ .Bool = false });
    const f = skia.winDragStart orelse return ok(Value{ .Bool = false });
    const win = winHandle(ctx.args[0]) orelse return ok(Value{ .Bool = false });
    const g = ctx.args[1].String.borrow();
    defer g.deinit();
    const payload = g.get().bytes;
    var png: []const u8 = &.{};
    var png_guard: ?@TypeOf(ctx.args[2].Array.storage().scalars.borrow()) = null;
    defer if (png_guard) |pg| pg.deinit();
    if (ctx.args[2] == .Array) switch (ctx.args[2].Array.storage()) {
        .scalars => |pb| {
            png_guard = pb.borrow();
            png = png_guard.?.get().bytes.items;
        },
        .boxed => {},
    };
    const started = f(win, payload.ptr, payload.len, png.ptr, png.len, @intCast(argInt(ctx.args[3])), @intCast(argInt(ctx.args[4])), @intCast(argInt(ctx.args[5])));
    return ok(Value{ .Bool = started != 0 });
}

/// `__composeui_winDndAccept(handle, action)`: the action the program now
/// takes of the drag over the window (0 for none).
fn winDndAccept(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 2) return ok(.{ .Unit = {} });
    const skia = loadSkia() orelse return ok(.{ .Unit = {} });
    const f = skia.winDndAccept orelse return ok(.{ .Unit = {} });
    const win = winHandle(ctx.args[0]) orelse return ok(.{ .Unit = {} });
    f(win, @intCast(argInt(ctx.args[1])));
    return ok(.{ .Unit = {} });
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
    rssLog();
    return ok(Value.newLong(1));
}

var rss_log_gate: enum { unknown, on, off } = .unknown;

/// `KLIO_RSS_LOG`: the process's RSS after each presented frame.
fn rssLog() void {
    if (rss_log_gate == .unknown) {
        rss_log_gate = if (runtime.envOnce("KLIO_RSS_LOG") != null) .on else .off;
    }
    if (rss_log_gate != .on) return;
    const kb = runtime.currentRssKb() orelse return;
    std.debug.print("[rss] {} MB\n", .{kb / 1024});
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

/// A surface's width (which 0) or height (which 1).
/// `__skia_surf_canvas(handle)`: the SkCanvas* the surface's draws go to, for
/// a skiko Canvas to wrap; 0 without a Skia backend.
fn surfCanvas(ctx: *CallCtx) Error!EvalResult {
    if (ctx.args.len < 1) return ok(Value.newLong(0));
    const skia = loadSkia() orelse return ok(Value.newLong(0));
    const f = skia.surfCanvas orelse return ok(Value.newLong(0));
    const surf = surfArg(ctx.args[0]) orelse return ok(Value.newLong(0));
    const canvas = f(surf) orelse return ok(Value.newLong(0));
    return ok(Value.newLong(@bitCast(@as(u64, @intFromPtr(canvas)))));
}

// Graphics layer nodes. A node or context handle is its pointer as a Long; 0
// without the Skia backend, which every entry point then answers with 0.

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

test "hostBindings registers the surface and windowing sinks" {
    var b = try hostBindings(testing.allocator);
    defer b.deinit();
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winOpen") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winSurface") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winPresent") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winClose") != null);
    try testing.expect(b.resolve("androidx.compose.ui.platform.__composeui_openUri") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_surf_new") != null);
    try testing.expect(b.resolve("androidx.compose.ui.graphics.__skia_surf_canvas") != null);
    try testing.expect(b.resolve("androidx.compose.material3.internal.__klio_icu_date") != null);
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
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winSetTextInput") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winEventText") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_a11yUpdate") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winSetCursor") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winRefreshHz") != null);
    try testing.expect(b.resolve("androidx.compose.ui.window.__composeui_winDragStart") != null);
    try testing.expectEqual(@as(usize, 70), b.len());
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

test "the ICU date bindings answer null for short args" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c0 = host.ctx(&none);
    try testing.expect((try icuDate(&c0)).ok == .Null);
    // A non-string locale, pattern or text answers null before any ICU call.
    const wrong = [_]Value{ Value.newInt(0), Value.newInt(1), Value.newInt(2), Value.newInt(3), Value.newLong(0) };
    var c1 = host.ctx(&wrong);
    try testing.expect((try icuDate(&c1)).ok == .Null);
}

test "openUri runs the opener with the URI and reports whether it opened" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = testing.allocator;
    var host: TestHost = .{};
    const none = [_]Value{};
    var c0 = host.ctx(&none);
    try testing.expect(!(try openUri(&c0)).ok.Bool);
    var uri = Value{ .String = try runtime.strInitOwned(a, try a.dupe(u8, "https://example.com/a")) };
    defer uri.String.deinit();
    const args = [_]Value{uri};
    runtime.envSetForTest("KLIO_URI_OPENER", "true");
    var c1 = host.ctx(&args);
    try testing.expect((try openUri(&c1)).ok.Bool);
    runtime.envSetForTest("KLIO_URI_OPENER", "false");
    var c2 = host.ctx(&args);
    try testing.expect(!(try openUri(&c2)).ok.Bool);
    runtime.envSetForTest("KLIO_URI_OPENER", "/nonexistent/klio-uri-opener");
    var c3 = host.ctx(&args);
    try testing.expect(!(try openUri(&c3)).ok.Bool);
}

test "systemTheme answers KLIO_SYSTEM_THEME in the host's place" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c = host.ctx(&none);
    defer runtime.envResetForTest("KLIO_SYSTEM_THEME");
    runtime.envSetForTest("KLIO_SYSTEM_THEME", "light");
    try testing.expectEqual(@as(i32, 0), (try systemTheme(&c)).ok.Int);
    runtime.envSetForTest("KLIO_SYSTEM_THEME", "Dark");
    try testing.expectEqual(@as(i32, 1), (try systemTheme(&c)).ok.Int);
    runtime.envSetForTest("KLIO_SYSTEM_THEME", "unknown");
    try testing.expectEqual(@as(i32, 2), (try systemTheme(&c)).ok.Int);
}

test "the text input bindings do nothing for short args, and event text is empty" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c = host.ctx(&none);
    try testing.expect((try winSetTextInput(&c)).ok == .Unit);
    try testing.expect((try winSetTextInputRect(&c)).ok == .Unit);
    try testing.expect((try winEndComposition(&c)).ok == .Unit);
    const text = (try winEventText(&c)).ok;
    defer text.String.deinit();
    const g = text.String.borrow();
    defer g.deinit();
    try testing.expectEqualStrings("", g.get().bytes);
}

test "the accessibility bindings are inactive and do nothing for short args" {
    var host: TestHost = .{};
    const none = [_]Value{};
    var c = host.ctx(&none);
    try testing.expect(!(try a11yActive(&c)).ok.Bool);
    try testing.expect((try a11yUpdate(&c)).ok == .Unit);
    try testing.expect((try winSetCursor(&c)).ok == .Unit);
    try testing.expectEqual(@as(i32, 0), (try winRefreshHz(&c)).ok.Int);
    try testing.expect(!(try winDragStart(&c)).ok.Bool);
    try testing.expect((try winDndAccept(&c)).ok == .Unit);
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
