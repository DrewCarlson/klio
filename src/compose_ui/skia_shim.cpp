// Skia rendering shim — a thin extern-"C" surface over Skia's C++ API so the Zig
// `compose_ui` module can drive a real GPU-class rasterizer without any C++ in Zig.
// Built with system g++/libstdc++ (Skia's prebuilt libs use the old GNU string
// ABI; zig cc/libc++ will not link them). See plans/UI-RENDERING-PACKS.md.
//
// The klio.compose.ui pack records a display list of draw ops during its draw
// pass; this shim replays them onto a headless raster SkSurface and encodes PNG.
// Colors are 0xAARRGGBB (Compose's packed ARGB). Coordinates are pixels.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/encode/SkPngEncoder.h"
// Font manager factory: the macOS Skia pack ships CoreText, not the custom-empty
// port (that symbol is absent), so select per platform.
#if defined(__APPLE__)
#include "include/ports/SkFontMgr_mac_ct.h"
#else
#include "include/ports/SkFontMgr_empty.h"
#endif

// Optional GPU (Ganesh + EGL) backend — off by default. When built with -DKLIO_GPU
// (and linked against libskia_ganesh_ext + libEGL), klio_skia_new_gpu returns a
// GPU-backed surface; otherwise it returns null and callers fall back to raster.
#if defined(KLIO_GPU)
#include "include/gpu/GpuTypes.h"
#include "include/gpu/ganesh/GrContextOptions.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"

// Minimal EGL surface-less context bring-up. Declared here (rather than via the
// EGL headers, which are not reliably present) since only these entry points +
// constants are needed; values are fixed by the EGL 1.5 spec.
extern "C" {
typedef void* EGLDisplay;
typedef void* EGLConfig;
typedef void* EGLContext;
typedef void* EGLSurface;
typedef int EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
EGLDisplay eglGetDisplay(void*);
EGLBoolean eglInitialize(EGLDisplay, EGLint*, EGLint*);
EGLBoolean eglChooseConfig(EGLDisplay, const EGLint*, EGLConfig*, EGLint, EGLint*);
EGLBoolean eglBindAPI(EGLenum);
EGLContext eglCreateContext(EGLDisplay, EGLConfig, EGLContext, const EGLint*);
EGLSurface eglCreatePbufferSurface(EGLDisplay, EGLConfig, const EGLint*);
EGLBoolean eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
void (*eglGetProcAddress(const char*))(void);
EGLint eglGetError(void);
}
#define KLIO_EGL_DEFAULT_DISPLAY ((void*)0)
#define KLIO_EGL_NO_CONTEXT ((void*)0)
#define KLIO_EGL_NO_SURFACE ((void*)0)
#define KLIO_EGL_NONE 0x3038
#define KLIO_EGL_SURFACE_TYPE 0x3033
#define KLIO_EGL_PBUFFER_BIT 0x0001
#define KLIO_EGL_RENDERABLE_TYPE 0x3040
#define KLIO_EGL_OPENGL_BIT 0x0008
#define KLIO_EGL_OPENGL_API 0x30A2
#define KLIO_EGL_WIDTH 0x3057
#define KLIO_EGL_HEIGHT 0x3056
#endif  // KLIO_GPU

namespace {

struct KlioSurface {
    sk_sp<SkSurface> surface;
};

// Common system font paths tried (in order) for text rendering, since the empty
// SkFontMgr ships no faces. $KLIO_SKIA_FONT overrides. A miss leaves text unpainted
// (the display list still carries the text op).
const char* const kFontCandidates[] = {
    "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "C:\\Windows\\Fonts\\consola.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
    nullptr,
};

// The bundled fallback font (Noto Sans Mono, Latin subset), embedded by build.zig
// as a byte array so text renders on hosts with no system fonts. Size 0 if the
// font asset was unavailable at build time.
extern "C" const unsigned char klio_embedded_font[];
extern "C" const unsigned int klio_embedded_font_size;

// Process-global font state, loaded once.
sk_sp<SkFontMgr> g_fontMgr;
sk_sp<SkTypeface> g_typeface;
bool g_fonts_tried = false;

void ensureFonts() {
    if (g_fonts_tried) return;
    g_fonts_tried = true;
#if defined(__APPLE__)
    g_fontMgr = SkFontMgr_New_CoreText(nullptr);
#else
    g_fontMgr = SkFontMgr_New_Custom_Empty();
#endif
    if (g_fontMgr) {
        if (const char* env = std::getenv("KLIO_SKIA_FONT")) {
            g_typeface = g_fontMgr->makeFromFile(env, 0);
        }
        // The bundled font is the default (self-contained, deterministic), used
        // unless $KLIO_SKIA_FONT overrode it above.
        if (!g_typeface && klio_embedded_font_size > 0) {
            auto data = SkData::MakeWithoutCopy(klio_embedded_font, klio_embedded_font_size);
            g_typeface = g_fontMgr->makeFromData(std::move(data));
        }
        // Last resort: a system font (only reached if the bundle is absent/failed).
        for (int i = 0; !g_typeface && kFontCandidates[i] != nullptr; ++i) {
            g_typeface = g_fontMgr->makeFromFile(kFontCandidates[i], 0);
        }
    }
}

// A wrapped paragraph's line spacing.
constexpr float kLineSpacing = 1.3f;

// Greedily word-wrap `utf8` into lines that fit `width` px at font `font`.
std::vector<std::string> wrapLines(const char* utf8, float width, const SkFont& font) {
    std::vector<std::string> lines;
    const std::string text(utf8);
    std::string cur;
    size_t i = 0;
    while (i <= text.size()) {
        const size_t sp = text.find(' ', i);
        const bool last = (sp == std::string::npos);
        const std::string word = text.substr(i, last ? std::string::npos : sp - i);
        const std::string candidate = cur.empty() ? word : cur + " " + word;
        const float w = font.measureText(candidate.c_str(), candidate.size(), SkTextEncoding::kUTF8);
        if (w > width && !cur.empty()) {
            lines.push_back(cur);
            cur = word;
        } else {
            cur = candidate;
        }
        if (last) break;
        i = sp + 1;
    }
    if (!cur.empty()) lines.push_back(cur);
    return lines;
}

inline SkColor toColor(uint32_t argb) { return static_cast<SkColor>(argb); }

inline void fillPaint(SkPaint& p, uint32_t argb) {
    p.setAntiAlias(true);
    p.setStyle(SkPaint::kFill_Style);
    p.setColor(toColor(argb));
}

inline void strokePaint(SkPaint& p, uint32_t argb, float width) {
    p.setAntiAlias(true);
    p.setStyle(SkPaint::kStroke_Style);
    p.setStrokeWidth(width);
    p.setColor(toColor(argb));
}

// Snapshot a surface's pixels: the fast peekPixels path for raster surfaces, or a
// GPU→CPU readback for Ganesh surfaces. `backing` owns the pixels when read back.
bool surfaceToPixmap(KlioSurface* s, SkPixmap& pm, SkBitmap& backing) {
    if (s->surface->peekPixels(&pm)) return true;
    if (!backing.tryAllocPixels(s->surface->imageInfo())) return false;
    if (!s->surface->readPixels(backing.pixmap(), 0, 0)) return false;
    pm = backing.pixmap();
    return true;
}

#if defined(KLIO_GPU)
sk_sp<GrDirectContext> g_grContext;
bool g_gpu_tried = false;

// Bring up a surface-less EGL desktop-GL context + a Skia GrDirectContext once.
// Leaves g_grContext null (callers fall back to raster) if any step fails.
void ensureGpu() {
    if (g_gpu_tried) return;
    g_gpu_tried = true;
    EGLDisplay dpy = eglGetDisplay(KLIO_EGL_DEFAULT_DISPLAY);
    if (!dpy) return;
    EGLint major = 0, minor = 0;
    if (!eglInitialize(dpy, &major, &minor)) return;
    const EGLint cfgAttrs[] = {
        KLIO_EGL_SURFACE_TYPE,    KLIO_EGL_PBUFFER_BIT,
        KLIO_EGL_RENDERABLE_TYPE, KLIO_EGL_OPENGL_BIT,
        KLIO_EGL_NONE};
    EGLConfig cfg = nullptr;
    EGLint n = 0;
    if (!eglChooseConfig(dpy, cfgAttrs, &cfg, 1, &n) || n < 1) return;
    if (!eglBindAPI(KLIO_EGL_OPENGL_API)) return;
    EGLContext ctx = eglCreateContext(dpy, cfg, KLIO_EGL_NO_CONTEXT, nullptr);
    if (ctx == KLIO_EGL_NO_CONTEXT) return;
    const EGLint pbAttrs[] = {KLIO_EGL_WIDTH, 1, KLIO_EGL_HEIGHT, 1, KLIO_EGL_NONE};
    EGLSurface surf = eglCreatePbufferSurface(dpy, cfg, pbAttrs);
    if (!eglMakeCurrent(dpy, surf, surf, ctx)) return;
    // Assemble the GL interface from eglGetProcAddress (the prebuilt ganesh's
    // native interface is GLX-bound; this keeps us on EGL). Desktop GL context, so
    // the GL — not GLES — assembler.
    auto iface = GrGLMakeAssembledGLInterface(
        nullptr, [](void*, const char name[]) -> GrGLFuncPtr {
            return reinterpret_cast<GrGLFuncPtr>(eglGetProcAddress(name));
        });
    if (!iface) return;
    g_grContext = GrDirectContexts::MakeGL(iface);
}
#endif  // KLIO_GPU

}  // namespace

extern "C" {

// Create a GPU (Ganesh) surface, or null if the GPU backend is unavailable (not
// built with -DKLIO_GPU, or EGL/GL bring-up failed) so the caller uses raster.
KlioSurface* klio_skia_new_gpu(int width, int height) {
#if defined(KLIO_GPU)
    if (width <= 0 || height <= 0) return nullptr;
    ensureGpu();
    if (!g_grContext) return nullptr;
    auto* s = new KlioSurface();
    s->surface = SkSurfaces::RenderTarget(
        g_grContext.get(), skgpu::Budgeted::kYes,
        SkImageInfo::MakeN32Premul(width, height), 0, nullptr);
    if (!s->surface) {
        delete s;
        return nullptr;
    }
    ensureFonts();
    return s;
#else
    (void)width;
    (void)height;
    return nullptr;
#endif
}

// Create a headless N32-premul raster surface, cleared transparent.
KlioSurface* klio_skia_new(int width, int height) {
    if (width <= 0 || height <= 0) return nullptr;
    auto* s = new KlioSurface();
    s->surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(width, height));
    if (!s->surface) {
        delete s;
        return nullptr;
    }
    ensureFonts();
    return s;
}

void klio_skia_free(KlioSurface* s) { delete s; }

void klio_skia_clear(KlioSurface* s, uint32_t argb) {
    if (s) s->surface->getCanvas()->clear(toColor(argb));
}

void klio_skia_fill_rect(KlioSurface* s, float x, float y, float w, float h, uint32_t argb) {
    if (!s) return;
    SkPaint p;
    fillPaint(p, argb);
    s->surface->getCanvas()->drawRect(SkRect::MakeXYWH(x, y, w, h), p);
}

void klio_skia_stroke_rect(KlioSurface* s, float x, float y, float w, float h, float width, uint32_t argb) {
    if (!s) return;
    SkPaint p;
    strokePaint(p, argb, width);
    // Inset by half the stroke so the outline stays inside the rect bounds.
    float half = width * 0.5f;
    s->surface->getCanvas()->drawRect(SkRect::MakeXYWH(x + half, y + half, w - width, h - width), p);
}

void klio_skia_fill_rrect(KlioSurface* s, float x, float y, float w, float h, float rx, float ry, uint32_t argb) {
    if (!s) return;
    SkPaint p;
    fillPaint(p, argb);
    s->surface->getCanvas()->drawRRect(SkRRect::MakeRectXY(SkRect::MakeXYWH(x, y, w, h), rx, ry), p);
}

void klio_skia_fill_circle(KlioSurface* s, float cx, float cy, float r, uint32_t argb) {
    if (!s) return;
    SkPaint p;
    fillPaint(p, argb);
    s->surface->getCanvas()->drawCircle(cx, cy, r, p);
}

void klio_skia_draw_line(KlioSurface* s, float x0, float y0, float x1, float y1, float width, uint32_t argb) {
    if (!s) return;
    SkPaint p;
    strokePaint(p, argb, width);
    s->surface->getCanvas()->drawLine(x0, y0, x1, y1, p);
}

// Baseline-left text. `x`,`y` is the baseline origin. No-op if no typeface.
void klio_skia_draw_text(KlioSurface* s, const char* utf8, float x, float y, float size, uint32_t argb) {
    if (!s || !utf8 || !g_typeface) return;
    SkFont font(g_typeface, size);
    font.setEdging(SkFont::Edging::kAntiAlias);
    SkPaint p;
    fillPaint(p, argb);
    s->surface->getCanvas()->drawSimpleText(
        utf8, std::strlen(utf8), SkTextEncoding::kUTF8, x, y, font, p);
}

// Lay out UTF-8 text within `width` px (word-wrapped, aligned: 0 left, 1 center,
// 2 right) and paint it with its top-left at (x, y). No-op without a font.
void klio_skia_draw_paragraph(KlioSurface* s, const char* utf8, float x, float y, float width, float size, uint32_t argb, int align) {
    if (!s || !utf8 || !g_typeface) return;
    SkFont font(g_typeface, size);
    font.setEdging(SkFont::Edging::kAntiAlias);
    SkPaint p;
    fillPaint(p, argb);
    const auto lines = wrapLines(utf8, width, font);
    float baseline = y + size;  // first line's baseline sits `size` below the top
    for (const auto& line : lines) {
        const float lw = font.measureText(line.c_str(), line.size(), SkTextEncoding::kUTF8);
        float lx = x;
        if (align == 1) lx = x + (width - lw) * 0.5f;
        else if (align == 2) lx = x + (width - lw);
        s->surface->getCanvas()->drawSimpleText(line.c_str(), line.size(), SkTextEncoding::kUTF8, lx, baseline, font, p);
        baseline += size * kLineSpacing;
    }
}

// The laid-out height (px) of `utf8` wrapped to `width` at `size`. 0 without a
// font. No surface needed, so the layout pass can call it to size a paragraph.
float klio_skia_measure_paragraph(const char* utf8, float width, float size) {
    ensureFonts();
    if (!utf8 || !g_typeface) return 0;
    SkFont font(g_typeface, size);
    const int n = static_cast<int>(wrapLines(utf8, width, font).size());
    return n * size * kLineSpacing;
}

// Encode the surface to a PNG file. Returns 0 on success, nonzero on failure.
int klio_skia_save_png(KlioSurface* s, const char* path) {
    if (!s || !path) return 1;
    SkPixmap pm;
    SkBitmap backing;
    if (!surfaceToPixmap(s, pm, backing)) return 2;
    SkFILEWStream out(path);
    if (!out.isValid()) return 3;
    SkPngEncoder::Options opts;
    return SkPngEncoder::Encode(&out, pm, opts) ? 0 : 4;
}

// Encode to a heap buffer (malloc); caller frees with klio_skia_free_buffer.
// Returns the buffer and writes its length to *out_len, or null on failure.
uint8_t* klio_skia_encode_png(KlioSurface* s, size_t* out_len) {
    if (!s || !out_len) return nullptr;
    SkPixmap pm;
    SkBitmap backing;
    if (!surfaceToPixmap(s, pm, backing)) return nullptr;
    SkDynamicMemoryWStream out;
    SkPngEncoder::Options opts;
    if (!SkPngEncoder::Encode(&out, pm, opts)) return nullptr;
    sk_sp<SkData> data = out.detachAsData();
    uint8_t* buf = static_cast<uint8_t*>(std::malloc(data->size()));
    if (!buf) return nullptr;
    std::memcpy(buf, data->data(), data->size());
    *out_len = data->size();
    return buf;
}

void klio_skia_free_buffer(uint8_t* buf) { std::free(buf); }

}  // extern "C"

// ---------------------------------------------------------------------------
// Windowing — a live on-screen surface + input event loop, one backend per OS
// behind the same C ABI (open / surface / present / poll / close):
//   X11    (-DKLIO_X11)   — verified; raster (N32 premul == X BGRX) via XPutImage.
//   Win32  (_WIN32)       — StretchDIBits blit; written, not run-verified here.
//   Cocoa  (-DKLIO_COCOA) — CALayer contents from a CGImage; written as
//                           Objective-C++, not compiled/run-verified here.
// Without a backend the window functions return failure and the pack falls back to
// headless rendering.
// ---------------------------------------------------------------------------

#if defined(KLIO_X11)

#include <sys/select.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>

struct KlioWindow {
    Display* dpy;
    Window win;
    GC gc;
    Atom wmDelete;
    int w;
    int h;
    KlioSurface* surface;
};

extern "C" {

KlioWindow* klio_win_open(int w, int h, const char* title) {
    if (w <= 0 || h <= 0) return nullptr;
    Display* dpy = XOpenDisplay(nullptr);
    if (!dpy) return nullptr;
    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);
    Window win = XCreateSimpleWindow(dpy, root, 0, 0, static_cast<unsigned>(w),
                                     static_cast<unsigned>(h), 0,
                                     BlackPixel(dpy, screen), BlackPixel(dpy, screen));
    if (title) XStoreName(dpy, win, title);
    XSelectInput(dpy, win,
                 ExposureMask | ButtonPressMask | PointerMotionMask | KeyPressMask |
                     StructureNotifyMask);
    Atom wmDelete = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
    XSetWMProtocols(dpy, win, &wmDelete, 1);
    XMapWindow(dpy, win);
    GC gc = XCreateGC(dpy, win, 0, nullptr);
    XFlush(dpy);

    auto* kw = new KlioWindow{dpy, win, gc, wmDelete, w, h, nullptr};
    kw->surface = klio_skia_new(w, h);
    if (!kw->surface) {
        XCloseDisplay(dpy);
        delete kw;
        return nullptr;
    }
    return kw;
}

// The surface the caller replays the display list onto before presenting.
KlioSurface* klio_win_surface(KlioWindow* kw) { return kw ? kw->surface : nullptr; }

// Blit the surface to the window.
void klio_win_present(KlioWindow* kw) {
    if (!kw || !kw->surface) return;
    SkPixmap pm;
    if (!kw->surface->surface->peekPixels(&pm)) return;
    Visual* visual = DefaultVisual(kw->dpy, DefaultScreen(kw->dpy));
    XImage* img = XCreateImage(kw->dpy, visual, 24, ZPixmap, 0,
                               const_cast<char*>(static_cast<const char*>(pm.addr())),
                               static_cast<unsigned>(kw->w), static_cast<unsigned>(kw->h),
                               32, static_cast<int>(pm.rowBytes()));
    if (!img) return;
    XPutImage(kw->dpy, kw->win, kw->gc, img, 0, 0, 0, 0,
              static_cast<unsigned>(kw->w), static_cast<unsigned>(kw->h));
    img->data = nullptr;  // Skia owns the pixels; don't let XDestroyImage free them.
    XDestroyImage(img);
    XFlush(kw->dpy);
}

// Wait up to timeoutMs for one event. Returns an event type and writes two
// type-dependent values into *outA/*outB:
//   0 none/redraw
//   1 click     — outA=x, outB=y
//   2 close
//   3 key       — outA=char (ASCII, 0 if non-printable), outB=keysym
//   4 move      — outA=x, outB=y (pointer position)
//   5 resize    — outA=width, outB=height (the surface is recreated to match)
int klio_win_poll(KlioWindow* kw, int timeoutMs, int* outA, int* outB) {
    if (!kw) return 2;
    if (!XPending(kw->dpy)) {
        int fd = ConnectionNumber(kw->dpy);
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(fd, &fds);
        struct timeval tv;
        tv.tv_sec = timeoutMs / 1000;
        tv.tv_usec = (timeoutMs % 1000) * 1000;
        select(fd + 1, &fds, nullptr, nullptr, &tv);
        if (!XPending(kw->dpy)) return 0;
    }
    XEvent ev;
    XNextEvent(kw->dpy, &ev);
    switch (ev.type) {
        case ButtonPress:
            if (outA) *outA = ev.xbutton.x;
            if (outB) *outB = ev.xbutton.y;
            return 1;
        case ClientMessage:
            if (static_cast<Atom>(ev.xclient.data.l[0]) == kw->wmDelete) return 2;
            return 0;
        case KeyPress: {
            char buf[8];
            KeySym ks = 0;
            int n = XLookupString(&ev.xkey, buf, sizeof(buf), &ks, nullptr);
            if (outA) *outA = (n > 0) ? static_cast<unsigned char>(buf[0]) : 0;
            if (outB) *outB = static_cast<int>(ks);
            return 3;
        }
        case MotionNotify:
            if (outA) *outA = ev.xmotion.x;
            if (outB) *outB = ev.xmotion.y;
            return 4;
        case ConfigureNotify: {
            const int nw = ev.xconfigure.width;
            const int nh = ev.xconfigure.height;
            if ((nw != kw->w || nh != kw->h) && nw > 0 && nh > 0) {
                // The surface is sized to the window; recreate it to match so the
                // next present blits at the new size.
                if (kw->surface) klio_skia_free(kw->surface);
                kw->surface = klio_skia_new(nw, nh);
                kw->w = nw;
                kw->h = nh;
                if (outA) *outA = nw;
                if (outB) *outB = nh;
                return 5;
            }
            return 0;
        }
        default:
            return 0;  // Expose etc. — the caller re-presents each loop.
    }
}

void klio_win_close(KlioWindow* kw) {
    if (!kw) return;
    if (kw->surface) klio_skia_free(kw->surface);
    XFreeGC(kw->dpy, kw->gc);
    XDestroyWindow(kw->dpy, kw->win);
    XCloseDisplay(kw->dpy);
    delete kw;
}

}  // extern "C"

#elif defined(_WIN32)

// Win32 backend. The N32-premul surface (BGRA) matches a 32bpp top-down BI_RGB
// DIB, so present is a StretchDIBits blit. Events arrive through the window proc;
// each poll pumps the queue and returns the first translated event. Compile-checked
// via a Windows cross target; not run-verified.
#include <windows.h>

struct KlioWindow {
    HWND hwnd;
    int w;
    int h;
    KlioSurface* surface;
    int evType;
    int evA;
    int evB;
    bool hasEv;
};

static LRESULT CALLBACK klioWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* kw = reinterpret_cast<KlioWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (kw) {
        switch (msg) {
            case WM_LBUTTONDOWN:
                kw->evType = 1;
                kw->evA = LOWORD(lParam);
                kw->evB = HIWORD(lParam);
                kw->hasEv = true;
                return 0;
            case WM_CLOSE:
                kw->evType = 2;
                kw->hasEv = true;
                return 0;
            case WM_CHAR:
                kw->evType = 3;
                kw->evA = static_cast<int>(wParam);
                kw->evB = static_cast<int>(wParam);
                kw->hasEv = true;
                return 0;
            case WM_MOUSEMOVE:
                kw->evType = 4;
                kw->evA = LOWORD(lParam);
                kw->evB = HIWORD(lParam);
                kw->hasEv = true;
                return 0;
            case WM_SIZE: {
                const int nw = LOWORD(lParam);
                const int nh = HIWORD(lParam);
                if ((nw != kw->w || nh != kw->h) && nw > 0 && nh > 0) {
                    if (kw->surface) klio_skia_free(kw->surface);
                    kw->surface = klio_skia_new(nw, nh);
                    kw->w = nw;
                    kw->h = nh;
                    kw->evType = 5;
                    kw->evA = nw;
                    kw->evB = nh;
                    kw->hasEv = true;
                }
                return 0;
            }
        }
    }
    return DefWindowProc(hwnd, msg, wParam, lParam);
}

extern "C" {

KlioWindow* klio_win_open(int w, int h, const char* title) {
    if (w <= 0 || h <= 0) return nullptr;
    HINSTANCE inst = GetModuleHandle(nullptr);
    static const char* kClass = "KlioWindowClass";
    static bool registered = false;
    if (!registered) {
        WNDCLASSA wc = {};
        wc.lpfnWndProc = klioWndProc;
        wc.hInstance = inst;
        wc.lpszClassName = kClass;
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        RegisterClassA(&wc);
        registered = true;
    }
    RECT r = {0, 0, w, h};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);  // client area == w x h
    HWND hwnd = CreateWindowA(kClass, title ? title : "klio", WS_OVERLAPPEDWINDOW,
                              CW_USEDEFAULT, CW_USEDEFAULT, r.right - r.left,
                              r.bottom - r.top, nullptr, nullptr, inst, nullptr);
    if (!hwnd) return nullptr;
    auto* kw = new KlioWindow{hwnd, w, h, nullptr, 0, 0, 0, false};
    kw->surface = klio_skia_new(w, h);
    if (!kw->surface) {
        DestroyWindow(hwnd);
        delete kw;
        return nullptr;
    }
    SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(kw));
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    return kw;
}

KlioSurface* klio_win_surface(KlioWindow* kw) { return kw ? kw->surface : nullptr; }

void klio_win_present(KlioWindow* kw) {
    if (!kw || !kw->surface) return;
    SkPixmap pm;
    if (!kw->surface->surface->peekPixels(&pm)) return;
    HDC hdc = GetDC(kw->hwnd);
    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = kw->w;
    bmi.bmiHeader.biHeight = -kw->h;  // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    StretchDIBits(hdc, 0, 0, kw->w, kw->h, 0, 0, kw->w, kw->h, pm.addr(), &bmi,
                  DIB_RGB_COLORS, SRCCOPY);
    ReleaseDC(kw->hwnd, hdc);
}

int klio_win_poll(KlioWindow* kw, int timeoutMs, int* outA, int* outB) {
    if (!kw) return 2;
    kw->hasEv = false;
    MSG msg;
    if (!PeekMessage(&msg, nullptr, 0, 0, PM_NOREMOVE)) {
        MsgWaitForMultipleObjects(0, nullptr, FALSE, static_cast<DWORD>(timeoutMs), QS_ALLINPUT);
    }
    while (PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
        if (kw->hasEv) {
            if (outA) *outA = kw->evA;
            if (outB) *outB = kw->evB;
            return kw->evType;
        }
    }
    return 0;
}

void klio_win_close(KlioWindow* kw) {
    if (!kw) return;
    if (kw->surface) klio_skia_free(kw->surface);
    DestroyWindow(kw->hwnd);
    delete kw;
}

}  // extern "C"

#elif defined(__APPLE__) && defined(KLIO_COCOA)

// Cocoa backend (compiled as Objective-C++ — build.zig adds -x objective-c++ on
// macOS with -DKLIO_COCOA). Two present paths behind one C ABI:
//   raster — an N32 surface blitted to the view's layer as a CGImage.
//   Metal  — (-DKLIO_METAL, via -Dgpu) a CAMetalLayer whose per-frame drawable is
//            wrapped as a Ganesh GPU surface; Skia renders on the GPU and the
//            drawable is presented through the Metal command queue.
#import <Cocoa/Cocoa.h>
#include <cstdio>

#if defined(KLIO_METAL)
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "include/core/SkColorSpace.h"
#include "include/gpu/GpuTypes.h"
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrTypes.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendContext.h"
#include "include/gpu/ganesh/mtl/GrMtlBackendSurface.h"
#include "include/gpu/ganesh/mtl/GrMtlDirectContext.h"
#include "include/gpu/ganesh/mtl/GrMtlTypes.h"
#include "include/gpu/ganesh/mtl/SkSurfaceMetal.h"
#include "include/ports/SkCFObject.h"
#endif

struct KlioWindow {
    NSWindow* window;
    NSView* view;
    int w;
    int h;
    KlioSurface* surface;
    // Live-resize render callback (set by the app around a poll). When present, the
    // resize notification observer drives a fresh frame during the modal drag.
    void (*resizeCb)(void*, int, int);
    void* resizeCtx;
    id resizeObserver;
#if defined(KLIO_METAL)
    CAMetalLayer* metalLayer;  // nil when the raster path is in use
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    sk_sp<GrDirectContext> grContext;
    GrMTLHandle drawable;  // this frame's CAMetalDrawable (retained until present)
    CGFloat backingScale;  // points -> pixels; the drawable is sized in pixels and
                           // the canvas is scaled by this so draws stay in points
#endif
};

#if defined(KLIO_METAL)
// Bring up a Metal device + Ganesh context and attach a CAMetalLayer to the view.
// Returns true when the GPU path is live; false leaves the window on raster.
static bool klioMetalInit(KlioWindow* kw, int w, int h) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();  // +1 (non-ARC)
    if (!device) return false;
    id<MTLCommandQueue> queue = [device newCommandQueue];  // +1
    if (!queue) {
        [device release];
        return false;
    }
    CGFloat scale = [kw->window backingScaleFactor];
    if (scale < 1.0) scale = 1.0;
    kw->backingScale = scale;
    CAMetalLayer* layer = [[CAMetalLayer layer] retain];  // own our ref
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;  // Skia renders into the drawable's texture
    // Render at the display's backing scale: the drawable is sized in physical
    // pixels (w*scale) and the canvas is scaled by `scale` (in klio_win_surface) so
    // the UI draws in points but rasterizes crisply on Retina.
    layer.contentsScale = scale;
    layer.drawableSize = CGSizeMake(w * scale, h * scale);
    layer.opaque = YES;
    // Layer-backed view + an autoresizing Metal sublayer: during a live resize
    // AppKit resizes the backing layer and Core Animation scales the last presented
    // drawable to fill (live visual feedback while the modal resize loop blocks the
    // VM); the VM re-renders at the new drawableSize when its loop resumes.
    layer.frame = NSMakeRect(0, 0, w, h);
    layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [kw->view setWantsLayer:YES];
    [kw->view.layer addSublayer:layer];

    GrMtlBackendContext backend = {};
    backend.fDevice.retain((GrMTLHandle)device);
    backend.fQueue.retain((GrMTLHandle)queue);
    sk_sp<GrDirectContext> ctx = GrDirectContexts::MakeMetal(backend);
    if (!ctx) {
        [layer release];
        [queue release];
        [device release];
        return false;
    }
    kw->device = device;
    kw->queue = queue;
    kw->metalLayer = layer;
    kw->grContext = ctx;
    kw->drawable = nullptr;
    // The GPU window never goes through klio_skia_new, so load the typeface here or
    // text draws are silently skipped (g_typeface stays null).
    ensureFonts();
    if (std::getenv("KLIO_SKIA_VERBOSE"))
        fprintf(stderr, "[klio-skia] window backend: Metal (GPU)\n");
    return true;
}
#endif  // KLIO_METAL

// Minimal main menu so the window behaves like a real app: Quit (Cmd-Q). Window
// close is left to the app to wire if it wants it. Once per process.
static void klioSetupMenu(const char* title) {
    static bool done = false;
    if (done) return;
    done = true;
    NSString* name = title ? [NSString stringWithUTF8String:title] : @"klio";
    NSMenu* menuBar = [[NSMenu alloc] init];
    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appItem];
    [NSApp setMainMenu:menuBar];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", name]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [appMenu release];
    [appItem release];
    [menuBar release];
}

// Resize the Metal drawable to a new point size at the current backing scale.
static void klioApplyMetalResize(KlioWindow* kw, int nw, int nh) {
#if defined(KLIO_METAL)
    if (!(kw->grContext && kw->metalLayer)) return;
    CGFloat scale = [kw->window backingScaleFactor];
    if (scale < 1.0) scale = 1.0;
    kw->backingScale = scale;
    kw->metalLayer.contentsScale = scale;
    kw->metalLayer.drawableSize = CGSizeMake(nw * scale, nh * scale);
#else
    (void)kw;
    (void)nw;
    (void)nh;
#endif
}

// Live-resize notification handler. With a render callback set (during a poll), it
// resizes the drawable and drives a fresh frame so the UI reflows in realtime while
// the modal resize loop blocks the VM's own loop. Without a callback it does nothing
// and the poll loop handles the resize on drag end (the non-live path).
static void klioWinResized(KlioWindow* kw) {
    if (!kw || !kw->resizeCb) return;
    const int nw = static_cast<int>([kw->view bounds].size.width);
    const int nh = static_cast<int>([kw->view bounds].size.height);
    if (nw <= 0 || nh <= 0 || (nw == kw->w && nh == kw->h)) return;
    klioApplyMetalResize(kw, nw, nh);
    kw->w = nw;
    kw->h = nh;
    kw->resizeCb(kw->resizeCtx, nw, nh);
}

extern "C" {

// Set (or clear, with null) the live-resize render callback. The app sets it around
// a poll so the callback value stays live for the call's duration.
void klio_win_set_resize_cb(KlioWindow* kw, void (*cb)(void*, int, int), void* ctx) {
    if (!kw) return;
    kw->resizeCb = cb;
    kw->resizeCtx = ctx;
}

KlioWindow* klio_win_open(int w, int h, const char* title) {
    if (w <= 0 || h <= 0) return nullptr;
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        klioSetupMenu(title);
        NSRect frame = NSMakeRect(0, 0, w, h);
        NSWindow* window = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (!window) return nullptr;
        [window setReleasedWhenClosed:NO];  // we own its lifetime (non-ARC)
        if (title) [window setTitle:[NSString stringWithUTF8String:title]];
        NSView* view = [window contentView];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        auto* kw = new KlioWindow();
        kw->window = window;
        kw->view = view;
        kw->w = w;
        kw->h = h;
        kw->surface = nullptr;
        kw->resizeCb = nullptr;
        kw->resizeCtx = nullptr;
        // Fires during a live resize (the modal drag) — reflows the UI in realtime
        // when a render callback is registered for the current poll.
        kw->resizeObserver = [[[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidResizeNotification
                        object:window
                         queue:nil
                    usingBlock:^(NSNotification* note) { (void)note; klioWinResized(kw); }] retain];
#if defined(KLIO_METAL)
        kw->metalLayer = nil;
        kw->device = nil;
        kw->queue = nil;
        kw->drawable = nullptr;
        if (klioMetalInit(kw, w, h)) return kw;  // GPU path; surface is per-frame
#endif
        // Raster fallback: a layer-backed view presented from a CGImage.
        [view setWantsLayer:YES];
        kw->surface = klio_skia_new(w, h);
        if (!kw->surface) {
            [window close];
            delete kw;
            return nullptr;
        }
        if (std::getenv("KLIO_SKIA_VERBOSE"))
            fprintf(stderr, "[klio-skia] window backend: raster (CPU)\n");
        return kw;
    }
}

KlioSurface* klio_win_surface(KlioWindow* kw) {
    if (!kw) return nullptr;
#if defined(KLIO_METAL)
    if (kw->grContext && kw->metalLayer) {
        // Wrap the layer's next drawable as a fresh GPU surface. Drop the previous
        // frame's surface/drawable if they were never presented.
        if (kw->surface) {
            klio_skia_free(kw->surface);
            kw->surface = nullptr;
        }
        if (kw->drawable) {
            CFRelease(kw->drawable);
            kw->drawable = nullptr;
        }
        // Acquire this frame's drawable and wrap its texture as a Ganesh render
        // target. (Managing the drawable directly, rather than WrapCAMetalLayer,
        // because that helper does not hand back the drawable to present here.)
        id<CAMetalDrawable> d = [kw->metalLayer nextDrawable];
        const int pw = static_cast<int>(kw->metalLayer.drawableSize.width);
        const int ph = static_cast<int>(kw->metalLayer.drawableSize.height);
        sk_sp<SkSurface> surf;
        if (d && d.texture) {
            GrMtlTextureInfo texInfo;
            texInfo.fTexture.retain((GrMTLHandle)d.texture);
            GrBackendRenderTarget backendRT = GrBackendRenderTargets::MakeMtl(pw, ph, texInfo);
            surf = SkSurfaces::WrapBackendRenderTarget(
                kw->grContext.get(), backendRT, kTopLeft_GrSurfaceOrigin,
                kBGRA_8888_SkColorType, nullptr, nullptr);
        }
        if (!surf) return nullptr;
        // The drawable is sized in physical pixels; scale the canvas by the backing
        // factor so the display list (in points) rasterizes at full resolution.
        if (kw->backingScale != 1.0)
            surf->getCanvas()->scale(kw->backingScale, kw->backingScale);
        kw->drawable = (GrMTLHandle)CFRetain((CFTypeRef)d);  // hold until present
        kw->surface = new KlioSurface();
        kw->surface->surface = surf;
        return kw->surface;
    }
#endif
    return kw->surface;
}

void klio_win_present(KlioWindow* kw) {
    if (!kw) return;
#if defined(KLIO_METAL)
    if (kw->grContext && kw->metalLayer) {
        if (!kw->surface || !kw->drawable) return;
        kw->grContext->flushAndSubmit(kw->surface->surface.get(), GrSyncCpu::kNo);
        // Debug: $KLIO_SKIA_DUMP reads back the first rendered GPU frame to a PNG so
        // the on-GPU render can be inspected without on-screen capture.
        if (const char* dump = std::getenv("KLIO_SKIA_DUMP")) {
            static bool dumped = false;
            if (!dumped) {
                dumped = true;
                const int rc = klio_skia_save_png(kw->surface, dump);
                if (std::getenv("KLIO_SKIA_VERBOSE"))
                    fprintf(stderr, "[klio-skia] present dump rc=%d -> %s\n", rc, dump);
            }
        }
        @autoreleasepool {
            id<CAMetalDrawable> d = (id<CAMetalDrawable>)kw->drawable;
            id<MTLCommandBuffer> cmd = [kw->queue commandBuffer];
            [cmd presentDrawable:d];
            [cmd commit];
        }
        klio_skia_free(kw->surface);
        kw->surface = nullptr;
        CFRelease(kw->drawable);
        kw->drawable = nullptr;
        return;
    }
#endif
    if (!kw->surface) return;
    SkPixmap pm;
    if (!kw->surface->surface->peekPixels(&pm)) return;
    @autoreleasepool {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        // N32 premul is BGRA little-endian → 32BE | premul | byteorder32Little.
        CGBitmapInfo info = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
        CGContextRef ctx = CGBitmapContextCreate(const_cast<void*>(pm.addr()), kw->w, kw->h, 8,
                                                 pm.rowBytes(), cs, info);
        CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : nullptr;
        if (img) {
            kw->view.layer.contents = (id)img;  // non-ARC: CGImageRef -> id
            CGImageRelease(img);
        }
        if (ctx) CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    }
}

int klio_win_poll(KlioWindow* kw, int timeoutMs, int* outA, int* outB) {
    if (!kw) return 2;
    @autoreleasepool {
        NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0];
        NSEvent* ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                         untilDate:until
                                            inMode:NSDefaultRunLoopMode
                                           dequeue:YES];
        if (!ev) return 0;
        // Content-view coordinates, top-left origin (flip y).
        NSPoint p = [kw->view convertPoint:[ev locationInWindow] fromView:nil];
        const int px = static_cast<int>(p.x);
        const int py = static_cast<int>(kw->h - p.y);
        int type = 0;
        switch ([ev type]) {
            case NSEventTypeLeftMouseDown:
                if (outA) *outA = px;
                if (outB) *outB = py;
                type = 1;
                break;
            case NSEventTypeMouseMoved:
            case NSEventTypeLeftMouseDragged:
                if (outA) *outA = px;
                if (outB) *outB = py;
                type = 4;
                break;
            case NSEventTypeKeyDown: {
                NSString* chars = [ev characters];
                const int c = [chars length] > 0 ? [chars characterAtIndex:0] : 0;
                if (outA) *outA = c;
                if (outB) *outB = [ev keyCode];
                type = 3;
                break;
            }
            default:
                break;
        }
        [NSApp sendEvent:ev];
        // A closed window is no longer visible.
        if (![kw->window isVisible]) return 2;
        // A resized content view: resize the drawable (Metal) or the raster surface.
        const int nw = static_cast<int>([kw->view bounds].size.width);
        const int nh = static_cast<int>([kw->view bounds].size.height);
        if (type == 0 && (nw != kw->w || nh != kw->h) && nw > 0 && nh > 0) {
#if defined(KLIO_METAL)
            if (kw->grContext && kw->metalLayer) {
                CGFloat scale = [kw->window backingScaleFactor];
                if (scale < 1.0) scale = 1.0;
                kw->backingScale = scale;
                kw->metalLayer.contentsScale = scale;
                kw->metalLayer.frame = NSMakeRect(0, 0, nw, nh);
                kw->metalLayer.drawableSize = CGSizeMake(nw * scale, nh * scale);
            } else
#endif
            {
                if (kw->surface) klio_skia_free(kw->surface);
                kw->surface = klio_skia_new(nw, nh);
            }
            kw->w = nw;
            kw->h = nh;
            if (outA) *outA = nw;
            if (outB) *outB = nh;
            return 5;
        }
        return type;
    }
}

void klio_win_close(KlioWindow* kw) {
    if (!kw) return;
    if (kw->resizeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:kw->resizeObserver];
        [kw->resizeObserver release];
        kw->resizeObserver = nil;
    }
    if (kw->surface) klio_skia_free(kw->surface);
#if defined(KLIO_METAL)
    if (kw->drawable) {
        CFRelease(kw->drawable);
        kw->drawable = nullptr;
    }
    kw->grContext.reset();
    if (kw->metalLayer) {
        [kw->metalLayer release];
        kw->metalLayer = nil;
    }
    if (kw->queue) {
        [kw->queue release];
        kw->queue = nil;
    }
    if (kw->device) {
        [kw->device release];
        kw->device = nil;
    }
#endif
    @autoreleasepool {
        [kw->window close];
    }
    delete kw;
}

}  // extern "C"

#else  // no windowing backend

extern "C" {
void* klio_win_open(int, int, const char*) { return nullptr; }
void* klio_win_surface(void*) { return nullptr; }
void klio_win_present(void*) {}
int klio_win_poll(void*, int, int*, int*) { return 2; }
void klio_win_close(void*) {}
}  // extern "C"

#endif
