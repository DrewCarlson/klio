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

// Process-global font state, loaded once.
sk_sp<SkFontMgr> g_fontMgr;
sk_sp<SkTypeface> g_typeface;
bool g_fonts_tried = false;

void ensureFonts() {
    if (g_fonts_tried) return;
    g_fonts_tried = true;
    g_fontMgr = SkFontMgr_New_Custom_Empty();
    if (g_fontMgr) {
        if (const char* env = std::getenv("KLIO_SKIA_FONT")) {
            g_typeface = g_fontMgr->makeFromFile(env, 0);
        }
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

#else  // no windowing backend (non-X11 build)

extern "C" {
void* klio_win_open(int, int, const char*) { return nullptr; }
void* klio_win_surface(void*) { return nullptr; }
void klio_win_present(void*) {}
int klio_win_poll(void*, int, int*, int*) { return 2; }
void klio_win_close(void*) {}
}  // extern "C"

#endif
