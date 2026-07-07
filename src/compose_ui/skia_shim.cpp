// Skia rendering shim — a thin extern-"C" surface over Skia's C++ API so the Zig
// `compose_ui` module can drive a real GPU-class rasterizer without any C++ in Zig.
// Built with system g++/libstdc++ (Skia's prebuilt libs use the old GNU string
// ABI; zig cc/libc++ will not link them). See plans/UI-RENDERING-PACKS.md.
//
// The klio.compose.ui pack records a display list of draw ops during its draw
// pass; this shim replays them onto a headless raster SkSurface and encodes PNG.
// Colors are 0xAARRGGBB (Compose's packed ARGB). Coordinates are pixels.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

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
#include "include/ports/SkFontMgr_empty.h"

namespace {

struct KlioSurface {
    sk_sp<SkSurface> surface;
    sk_sp<SkFontMgr> fontMgr;
    sk_sp<SkTypeface> typeface;
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

}  // namespace

extern "C" {

// Create a headless N32-premul raster surface, cleared transparent.
KlioSurface* klio_skia_new(int width, int height) {
    if (width <= 0 || height <= 0) return nullptr;
    auto* s = new KlioSurface();
    s->surface = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(width, height));
    if (!s->surface) {
        delete s;
        return nullptr;
    }
    // A self-contained font manager (no system fontconfig dependency); load a
    // typeface from $KLIO_SKIA_FONT or the first available system font. A miss
    // leaves typeface null and text ops no-op.
    s->fontMgr = SkFontMgr_New_Custom_Empty();
    if (s->fontMgr) {
        if (const char* env = std::getenv("KLIO_SKIA_FONT")) {
            s->typeface = s->fontMgr->makeFromFile(env, 0);
        }
        for (int i = 0; !s->typeface && kFontCandidates[i] != nullptr; ++i) {
            s->typeface = s->fontMgr->makeFromFile(kFontCandidates[i], 0);
        }
    }
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
    if (!s || !utf8 || !s->typeface) return;
    SkFont font(s->typeface, size);
    font.setEdging(SkFont::Edging::kAntiAlias);
    SkPaint p;
    fillPaint(p, argb);
    s->surface->getCanvas()->drawSimpleText(
        utf8, std::strlen(utf8), SkTextEncoding::kUTF8, x, y, font, p);
}

// Encode the surface to a PNG file. Returns 0 on success, nonzero on failure.
int klio_skia_save_png(KlioSurface* s, const char* path) {
    if (!s || !path) return 1;
    SkPixmap pm;
    if (!s->surface->peekPixels(&pm)) return 2;
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
    if (!s->surface->peekPixels(&pm)) return nullptr;
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
// Windowing — a live on-screen surface + input event loop. X11 only for now
// (enabled by -DKLIO_X11 when build.zig finds the X11 headers + lib); the raster
// surface (N32 premul == X TrueColor BGRX) is blitted with XPutImage. macOS
// (Cocoa) / Windows (Win32) get their own backends later; without a backend the
// window functions return failure so the pack falls back to headless rendering.
// ---------------------------------------------------------------------------

#if defined(KLIO_X11)

#include <sys/select.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

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
    XSelectInput(dpy, win, ExposureMask | ButtonPressMask | KeyPressMask | StructureNotifyMask);
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

// Wait up to timeoutMs for one event. Returns: 0 none/redraw, 1 click (writes
// *outX/*outY), 2 close requested.
int klio_win_poll(KlioWindow* kw, int timeoutMs, int* outX, int* outY) {
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
    if (ev.type == ButtonPress) {
        if (outX) *outX = ev.xbutton.x;
        if (outY) *outY = ev.xbutton.y;
        return 1;
    }
    if (ev.type == ClientMessage &&
        static_cast<Atom>(ev.xclient.data.l[0]) == kw->wmDelete) {
        return 2;
    }
    return 0;  // Expose / configure / key — the caller re-presents each loop.
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

#else  // no windowing backend (non-X11 build)

extern "C" {
void* klio_win_open(int, int, const char*) { return nullptr; }
void* klio_win_surface(void*) { return nullptr; }
void klio_win_present(void*) {}
int klio_win_poll(void*, int, int*, int*) { return 2; }
void klio_win_close(void*) {}
}  // extern "C"

#endif
