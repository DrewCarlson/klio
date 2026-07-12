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
#include <memory>
#include <sstream>
#include <string>
#include <string>
#include <unordered_map>
#include <vector>

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/encode/SkPngEncoder.h"
#include "include/effects/SkGradient.h"
#include "include/pathops/SkPathOps.h"
#include "modules/skparagraph/include/DartTypes.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skparagraph/include/TypefaceFontProvider.h"
#include "modules/skunicode/include/SkUnicode_icu.h"
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
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrContextOptions.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLAssembleInterface.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
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

// Styled run: `flags` bit0 = synthetic bold (embolden; advances unchanged),
// bit1 = synthetic italic (skew), bit2 = underline, bit3 = strikethrough.
// Backs per-span AnnotatedString painting off the single bundled typeface.
void klio_skia_c_draw_text2(KlioSurface* s, const char* utf8, float x, float y, float size, uint32_t argb, int flags) {
    if (!s || !utf8 || !g_typeface) return;
    SkFont font(g_typeface, size);
    font.setEdging(SkFont::Edging::kAntiAlias);
    if (flags & 1) font.setEmbolden(true);
    if (flags & 2) font.setSkewX(-0.25f);
    SkPaint p;
    fillPaint(p, argb);
    const size_t len = std::strlen(utf8);
    SkCanvas* canvas = s->surface->getCanvas();
    canvas->drawSimpleText(utf8, len, SkTextEncoding::kUTF8, x, y, font, p);
    if (flags & (4 | 8)) {
        const float w = font.measureText(utf8, len, SkTextEncoding::kUTF8);
        SkPaint line;
        strokePaint(line, argb, size * 0.06f < 1.0f ? 1.0f : size * 0.06f);
        if (flags & 4) {
            const float uy = y + size * 0.12f;
            canvas->drawLine(x, uy, x + w, uy, line);
        }
        if (flags & 8) {
            const float sy2 = y - size * 0.28f;
            canvas->drawLine(x, sy2, x + w, sy2, line);
        }
    }
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

// The advance width (px) of a single unwrapped run `utf8` at `size`. 0 without a
// font. The real Paragraph engine wraps in Kotlin off this measurement.
float klio_skia_measure_text_width(const char* utf8, float size) {
    ensureFonts();
    if (!utf8 || !g_typeface) return 0;
    SkFont font(g_typeface, size);
    return font.measureText(utf8, std::strlen(utf8), SkTextEncoding::kUTF8);
}

// Font vertical metrics (px) at `size`: ascent is negative (above baseline),
// descent positive (below), leading the recommended extra line gap. `which`
// selects one so a single-value intrinsic can read each. 0 without a font.
float klio_skia_font_metric(float size, int which) {
    ensureFonts();
    if (!g_typeface) return 0;
    SkFont font(g_typeface, size);
    SkFontMetrics m;
    font.getMetrics(&m);
    switch (which) {
        case 0: return m.fAscent;   // negative
        case 1: return m.fDescent;  // positive
        case 2: return m.fLeading;
        default: return 0;
    }
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

// One pixel as ARGB (unpremultiplied), or 0 when out of range / unreadable.
// Backs ImageBitmap.readPixels; per-pixel readback keeps the ABI scalar-only.
uint32_t klio_skia_surf_pixel(KlioSurface* s, int x, int y) {
    if (!s) return 0;
    SkPixmap pm;
    SkBitmap backing;
    if (!surfaceToPixmap(s, pm, backing)) return 0;
    if (x < 0 || y < 0 || x >= pm.width() || y >= pm.height()) return 0;
    return static_cast<uint32_t>(pm.getColor(x, y));
}

// Blit `src`'s current contents onto `dst`: the plain form places the snapshot
// at (x, y); the rect form maps `src`'s (sl,st,sr,sb) onto `dst`'s (dl,dt,dr,db)
// with bilinear sampling. Backs Canvas.drawImage / drawImageRect.
void klio_skia_c_draw_surface(KlioSurface* dst, KlioSurface* src, float x, float y) {
    if (!dst || !src) return;
    sk_sp<SkImage> img = src->surface->makeImageSnapshot();
    if (!img) return;
    dst->surface->getCanvas()->drawImage(img, x, y, SkSamplingOptions(SkFilterMode::kLinear), nullptr);
}

void klio_skia_c_draw_surface_rect(
    KlioSurface* dst, KlioSurface* src,
    float sl, float st, float sr, float sb,
    float dl, float dt, float dr, float db) {
    if (!dst || !src) return;
    sk_sp<SkImage> img = src->surface->makeImageSnapshot();
    if (!img) return;
    dst->surface->getCanvas()->drawImageRect(
        img,
        SkRect::MakeLTRB(sl, st, sr, sb),
        SkRect::MakeLTRB(dl, dt, dr, db),
        SkSamplingOptions(SkFilterMode::kLinear),
        nullptr,
        SkCanvas::kStrict_SrcRectConstraint);
}

}  // extern "C"

// ---------------------------------------------------------------------------
// skparagraph text engine. A paragraph is built from UTF-16 text plus a
// serialized run spec, laid out at a width, then queried/painted through a
// handle. All indices at this API are UTF-16 code units (the text is added
// as std::u16string, so skparagraph's own ranges are UTF-16 — compose /
// AnnotatedString offsets pass straight through).
//
// Spec format (one op per line):
//   p <sizePx> <align 0..3 l/c/r/j> <maxLines (0 = unlimited)> <ellipsis 0/1>
//     <dir 0 ltr / 1 rtl> <weight 100..900> <italic 0/1> <deco bits: 1
//     underline | 4 line-through> <argb>
//   r <startU16> <endU16> <sizePx> <weight> <italic> <deco> <argb> <family>
// Runs are consecutive, non-overlapping, and FULLY resolved (the Kotlin side
// folds span overlap); `family` is `-` for the default face.
// ---------------------------------------------------------------------------

namespace {

std::u16string utf8ToUtf16(const char* s) {
    std::u16string out;
    const unsigned char* p = reinterpret_cast<const unsigned char*>(s);
    while (*p) {
        uint32_t cp = 0;
        int extra = 0;
        if (*p < 0x80) {
            cp = *p;
        } else if ((*p >> 5) == 0x6) {
            cp = *p & 0x1F;
            extra = 1;
        } else if ((*p >> 4) == 0xE) {
            cp = *p & 0x0F;
            extra = 2;
        } else if ((*p >> 3) == 0x1E) {
            cp = *p & 0x07;
            extra = 3;
        } else {
            ++p;
            continue;
        }
        ++p;
        for (int i = 0; i < extra; ++i) {
            if ((*p & 0xC0) != 0x80) break;
            cp = (cp << 6) | (*p & 0x3F);
            ++p;
        }
        if (cp >= 0x10000) {
            cp -= 0x10000;
            out.push_back(static_cast<char16_t>(0xD800 + (cp >> 10)));
            out.push_back(static_cast<char16_t>(0xDC00 + (cp & 0x3FF)));
        } else {
            out.push_back(static_cast<char16_t>(cp));
        }
    }
    return out;
}

sk_sp<skia::textlayout::FontCollection> g_paraFonts;
sk_sp<skia::textlayout::TypefaceFontProvider> g_paraProvider;
sk_sp<SkUnicode> g_paraUnicode;
bool g_para_tried = false;

// The paragraph font collection: the bundled/env typeface registered under
// its own family name plus the generic aliases compose programs use, and set
// as the collection default so an unknown family falls back to it.
void ensureParaFonts() {
    if (g_para_tried) return;
    g_para_tried = true;
    ensureFonts();
    if (!g_typeface) return;
    auto provider = sk_make_sp<skia::textlayout::TypefaceFontProvider>();
    provider->registerTypeface(g_typeface, SkString("klio"));
    provider->registerTypeface(g_typeface, SkString("sans-serif"));
    provider->registerTypeface(g_typeface, SkString("serif"));
    provider->registerTypeface(g_typeface, SkString("monospace"));
    provider->registerTypeface(g_typeface, SkString("cursive"));
    auto fonts = sk_make_sp<skia::textlayout::FontCollection>();
    fonts->setDefaultFontManager(provider, "klio");
    g_paraUnicode = SkUnicodes::ICU::Make();
    if (!g_paraUnicode) return;
    g_paraProvider = provider;
    g_paraFonts = fonts;
}

// Load a font FILE and register its typeface under `family` in the paragraph
// font provider, so a run spec naming that family shapes with the real face.
// Returns 1 on success. The collection's paragraph cache is cleared so
// already-consulted family lookups re-resolve.
extern "C" int32_t klio_skia_font_register(const char* path, const char* family) {
    ensureParaFonts();
    if (!g_paraProvider || !g_paraFonts || !g_fontMgr) return 0;
    sk_sp<SkTypeface> tf = g_fontMgr->makeFromFile(path, 0);
    if (!tf) return 0;
    g_paraProvider->registerTypeface(tf, SkString(family));
    g_paraFonts->clearCaches();
    return 1;
}

skia::textlayout::TextStyle runStyle(float size, int weight, int italic, int deco, uint32_t argb, const char* family) {
    skia::textlayout::TextStyle ts;
    ts.setColor(toColor(argb));
    ts.setFontSize(size);
    ts.setFontStyle(SkFontStyle(weight, SkFontStyle::kNormal_Width,
                                italic != 0 ? SkFontStyle::kItalic_Slant : SkFontStyle::kUpright_Slant));
    ts.setDecoration(static_cast<skia::textlayout::TextDecoration>(deco));
    ts.setDecorationColor(toColor(argb));
    std::vector<SkString> fams;
    if (family && family[0] != '\0' && !(family[0] == '-' && family[1] == '\0')) fams.push_back(SkString(family));
    fams.push_back(SkString("klio"));
    ts.setFontFamilies(fams);
    return ts;
}

}  // namespace

struct KlioPara {
    std::unique_ptr<skia::textlayout::Paragraph> para;
    std::vector<skia::textlayout::LineMetrics> lines;
    void refreshLines() {
        lines.clear();
        para->getLineMetrics(lines);
    }
};

extern "C" {

KlioPara* klio_skia_para_new(const char* utf8, const char* spec) {
    const bool ptrace = std::getenv("KLIO_PARA_TRACE") != nullptr;
    if (ptrace) std::fprintf(stderr, "[para] new enter\n");
    ensureParaFonts();
    if (ptrace) std::fprintf(stderr, "[para] fonts=%d unicode=%d\n", g_paraFonts ? 1 : 0, g_paraUnicode ? 1 : 0);
    if (!utf8 || !spec || !g_paraFonts) return nullptr;
    const std::u16string text = utf8ToUtf16(utf8);
    if (ptrace) std::fprintf(stderr, "[para] u16len=%zu sizeof(ps)=%zu sizeof(ts)=%zu\n", text.size(), sizeof(skia::textlayout::ParagraphStyle), sizeof(skia::textlayout::TextStyle));

    skia::textlayout::ParagraphStyle ps;
    skia::textlayout::TextStyle base;
    struct Run { size_t s, e; skia::textlayout::TextStyle ts; };
    std::vector<Run> runs;

    std::istringstream in(spec);
    std::string line;
    while (std::getline(in, line)) {
        std::istringstream ls(line);
        std::string op;
        ls >> op;
        if (op == "p") {
            float size = 14;
            int align = 0, maxLines = 0, ellipsis = 0, dir = 0, weight = 400, italic = 0, deco = 0;
            unsigned long long argb = 0xFF000000ULL;
            float letterSp = 0, lineH = 0;
            ls >> size >> align >> maxLines >> ellipsis >> dir >> weight >> italic >> deco >> argb >> letterSp >> lineH;
            ps.setTextAlign(static_cast<skia::textlayout::TextAlign>(align));
            ps.setTextDirection(dir != 0 ? skia::textlayout::TextDirection::kRtl
                                         : skia::textlayout::TextDirection::kLtr);
            if (maxLines > 0) ps.setMaxLines(static_cast<size_t>(maxLines));
            if (ellipsis != 0) ps.setEllipsis(std::u16string(u"…"));
            base = runStyle(size, weight, italic, deco, static_cast<uint32_t>(argb), nullptr);
            if (letterSp != 0) base.setLetterSpacing(letterSp);
            if (lineH > 0 && size > 0) {
                base.setHeight(lineH / size);
                base.setHeightOverride(true);
            }
            ps.setTextStyle(base);
        } else if (op == "r") {
            size_t s = 0, e = 0;
            float size = 14;
            int weight = 400, italic = 0, deco = 0;
            unsigned long long argb = 0xFF000000ULL;
            std::string fam;
            float letterSp = 0, lineH = 0;
            ls >> s >> e >> size >> weight >> italic >> deco >> argb >> fam >> letterSp >> lineH;
            if (e > text.size()) e = text.size();
            if (s >= e) continue;
            auto ts = runStyle(size, weight, italic, deco, static_cast<uint32_t>(argb), fam.c_str());
            if (letterSp != 0) ts.setLetterSpacing(letterSp);
            if (lineH > 0 && size > 0) {
                ts.setHeight(lineH / size);
                ts.setHeightOverride(true);
            }
            runs.push_back(Run{s, e, ts});
        }
    }

    if (ptrace) std::fprintf(stderr, "[para] spec parsed, runs=%zu\n", runs.size());
    auto builder = skia::textlayout::ParagraphBuilder::make(ps, g_paraFonts, g_paraUnicode);
    if (ptrace) std::fprintf(stderr, "[para] builder=%d\n", builder ? 1 : 0);
    if (!builder) return nullptr;
    if (runs.empty()) {
        builder->addText(text);
    } else {
        size_t cursor = 0;
        for (const auto& r : runs) {
            if (r.s > cursor) builder->addText(text.substr(cursor, r.s - cursor));
            builder->pushStyle(r.ts);
            builder->addText(text.substr(r.s, r.e - r.s));
            builder->pop();
            cursor = r.e;
        }
        if (cursor < text.size()) builder->addText(text.substr(cursor));
    }
    if (ptrace) std::fprintf(stderr, "[para] text added\n");
    auto para = builder->Build();
    if (ptrace) std::fprintf(stderr, "[para] built=%d\n", para ? 1 : 0);
    if (!para) return nullptr;
    auto* out = new KlioPara();
    out->para = std::move(para);
    return out;
}

void klio_skia_para_layout(KlioPara* p, float width) {
    if (!p) return;
    p->para->layout(width);
    p->refreshLines();
}

// which: 0 height, 1 maxIntrinsicWidth, 2 minIntrinsicWidth, 3 longestLine,
// 4 lineCount, 5 didExceedMaxLines, 6 alphabeticBaseline (first line),
// 7 ideographicBaseline.
float klio_skia_para_metric(KlioPara* p, int which) {
    if (!p) return 0;
    switch (which) {
        case 0: return p->para->getHeight();
        case 1: return p->para->getMaxIntrinsicWidth();
        case 2: return p->para->getMinIntrinsicWidth();
        case 3: return p->para->getLongestLine();
        case 4: return static_cast<float>(p->para->lineNumber());
        case 5: return p->para->didExceedMaxLines() ? 1.0f : 0.0f;
        case 6: return p->para->getAlphabeticBaseline();
        case 7: return p->para->getIdeographicBaseline();
        default: return 0;
    }
}

// which: 0 top, 1 bottom, 2 baseline, 3 left, 4 width, 5 startU16,
// 6 endU16 (excluding trailing whitespace), 7 endU16 (including newline),
// 8 endU16 (raw), 9 hardBreak.
float klio_skia_para_line_metric(KlioPara* p, int line, int which) {
    if (!p || line < 0 || static_cast<size_t>(line) >= p->lines.size()) return 0;
    const auto& m = p->lines[static_cast<size_t>(line)];
    switch (which) {
        case 0: return static_cast<float>(m.fBaseline - m.fAscent);
        case 1: return static_cast<float>(m.fBaseline + m.fDescent);
        case 2: return static_cast<float>(m.fBaseline);
        case 3: return static_cast<float>(m.fLeft);
        case 4: return static_cast<float>(m.fWidth);
        case 5: return static_cast<float>(m.fStartIndex);
        case 6: return static_cast<float>(m.fEndExcludingWhitespaces);
        case 7: return static_cast<float>(m.fEndIncludingNewline);
        case 8: return static_cast<float>(m.fEndIndex);
        case 9: return m.fHardBreak ? 1.0f : 0.0f;
        default: return 0;
    }
}

int klio_skia_para_offset_at(KlioPara* p, float x, float y) {
    if (!p) return 0;
    return p->para->getGlyphPositionAtCoordinate(x, y).position;
}

// Union box of [startU16, endU16), tight height: which 0 l, 1 t, 2 r, 3 b;
// which 4 = box count (for emptiness checks).
float klio_skia_para_box(KlioPara* p, int s, int e, int which) {
    if (!p || e <= s) return 0;
    auto boxes = p->para->getRectsForRange(static_cast<unsigned>(s), static_cast<unsigned>(e),
                                           skia::textlayout::RectHeightStyle::kTight,
                                           skia::textlayout::RectWidthStyle::kTight);
    if (which == 4) return static_cast<float>(boxes.size());
    if (boxes.empty()) return 0;
    SkRect u = boxes[0].rect;
    for (size_t i = 1; i < boxes.size(); ++i) u.join(boxes[i].rect);
    switch (which) {
        case 0: return u.fLeft;
        case 1: return u.fTop;
        case 2: return u.fRight;
        case 3: return u.fBottom;
        default: return 0;
    }
}

// The i-th box of [startU16, endU16) (max-height style, for selection
// geometry): which 0 l, 1 t, 2 r, 3 b, 4 direction (0 ltr / 1 rtl).
float klio_skia_para_range_rect(KlioPara* p, int s, int e, int idx, int which) {
    if (!p || e <= s || idx < 0) return 0;
    auto boxes = p->para->getRectsForRange(static_cast<unsigned>(s), static_cast<unsigned>(e),
                                           skia::textlayout::RectHeightStyle::kMax,
                                           skia::textlayout::RectWidthStyle::kTight);
    if (static_cast<size_t>(idx) >= boxes.size()) return 0;
    const auto& b = boxes[static_cast<size_t>(idx)];
    switch (which) {
        case 0: return b.rect.fLeft;
        case 1: return b.rect.fTop;
        case 2: return b.rect.fRight;
        case 3: return b.rect.fBottom;
        case 4: return b.direction == skia::textlayout::TextDirection::kRtl ? 1.0f : 0.0f;
        default: return 0;
    }
}

int klio_skia_para_range_rect_count(KlioPara* p, int s, int e) {
    if (!p || e <= s) return 0;
    auto boxes = p->para->getRectsForRange(static_cast<unsigned>(s), static_cast<unsigned>(e),
                                           skia::textlayout::RectHeightStyle::kMax,
                                           skia::textlayout::RectWidthStyle::kTight);
    return static_cast<int>(boxes.size());
}

// Word containing the glyph at `offset`, packed ((start << 32) | end).
long long klio_skia_para_word(KlioPara* p, int offset) {
    if (!p) return 0;
    auto r = p->para->getWordBoundary(static_cast<unsigned>(offset));
    return (static_cast<long long>(r.start) << 32) | static_cast<long long>(r.end);
}

int klio_skia_para_line_for(KlioPara* p, int offset) {
    if (!p) return 0;
    const int n = p->para->getLineNumberAtUTF16Offset(static_cast<size_t>(offset));
    return n < 0 ? static_cast<int>(p->lines.size()) - 1 : n;
}

void klio_skia_para_paint(KlioPara* p, KlioSurface* s, float x, float y) {
    if (!p || !s) return;
    p->para->paint(s->surface->getCanvas(), x, y);
}

void klio_skia_para_free(KlioPara* p) { delete p; }

}  // extern "C"

// ---------------------------------------------------------------------------
// Path boolean ops. SkPath <-> a serialized command buffer (one op per line):
//   m x y | l x y | q x1 y1 x2 y2 | c x1 y1 x2 y2 x3 y3 | z
// ---------------------------------------------------------------------------
namespace {

SkPath klioBuildPath(const char* cmds) {
    SkPathBuilder b;
    if (!cmds) return b.detach();
    const char* p = cmds;
    while (*p) {
        while (*p == '\n' || *p == '\r' || *p == ' ' || *p == '\t') p++;
        if (!*p) break;
        const char verb = *p++;
        int n = 0;
        switch (verb) {
            case 'm': case 'l': n = 2; break;
            case 'q': n = 4; break;
            case 'c': n = 6; break;
            default: n = 0; break;  // 'z' and unknown carry no coordinates
        }
        float v[6] = {0, 0, 0, 0, 0, 0};
        for (int i = 0; i < n; i++) v[i] = std::strtof(p, const_cast<char**>(&p));
        switch (verb) {
            case 'm': b.moveTo(v[0], v[1]); break;
            case 'l': b.lineTo(v[0], v[1]); break;
            case 'q': b.quadTo(v[0], v[1], v[2], v[3]); break;
            case 'c': b.cubicTo(v[0], v[1], v[2], v[3], v[4], v[5]); break;
            case 'z': b.close(); break;
            default: break;
        }
        while (*p && *p != '\n') p++;
    }
    return b.detach();
}

std::string klioSerializePath(const SkPath& path) {
    std::string out;
    char buf[160];
    SkPath::Iter iter(path, false);
    SkPoint pts[4];
    SkPath::Verb verb;
    while ((verb = iter.next(pts)) != SkPath::kDone_Verb) {
        switch (verb) {
            case SkPath::kMove_Verb:
                std::snprintf(buf, sizeof(buf), "m %g %g\n", pts[0].fX, pts[0].fY);
                out += buf;
                break;
            case SkPath::kLine_Verb:
                std::snprintf(buf, sizeof(buf), "l %g %g\n", pts[1].fX, pts[1].fY);
                out += buf;
                break;
            case SkPath::kQuad_Verb:
                std::snprintf(buf, sizeof(buf), "q %g %g %g %g\n", pts[1].fX, pts[1].fY, pts[2].fX, pts[2].fY);
                out += buf;
                break;
            case SkPath::kConic_Verb: {
                // Boolean ops rarely emit conics; approximate as quads so the
                // klio-side buffer stays move/line/quad/cubic only.
                SkPoint quads[5];
                const int cnt = SkPath::ConvertConicToQuads(pts[0], pts[1], pts[2], iter.conicWeight(), quads, 1);
                for (int i = 0; i < cnt; i++) {
                    std::snprintf(buf, sizeof(buf), "q %g %g %g %g\n",
                                  quads[2 * i + 1].fX, quads[2 * i + 1].fY,
                                  quads[2 * i + 2].fX, quads[2 * i + 2].fY);
                    out += buf;
                }
                break;
            }
            case SkPath::kCubic_Verb:
                std::snprintf(buf, sizeof(buf), "c %g %g %g %g %g %g\n",
                              pts[1].fX, pts[1].fY, pts[2].fX, pts[2].fY, pts[3].fX, pts[3].fY);
                out += buf;
                break;
            case SkPath::kClose_Verb:
                out += "z\n";
                break;
            default:
                break;
        }
    }
    return out;
}

}  // namespace

extern "C" {

// Apply a boolean op to two serialized paths. op: 0 difference, 1 intersect,
// 2 union, 3 xor, 4 reverse-difference (matching PathOperation). Returns a
// malloc'd result buffer (free via klio_skia_free_cstr), or null on failure.
char* klio_skia_path_op(const char* a, const char* b, int op) {
    if (op < 0 || op > 4) return nullptr;
    SkPath result;
    const SkPath pa = klioBuildPath(a);
    const SkPath pb = klioBuildPath(b);
    if (!Op(pa, pb, static_cast<SkPathOp>(op), &result)) return nullptr;
    const std::string s = klioSerializePath(result);
    char* out = static_cast<char*>(std::malloc(s.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

// Whether the serialized path is convex.
int klio_skia_path_convex(const char* cmds) {
    return klioBuildPath(cmds).isConvex() ? 1 : 0;
}

void klio_skia_free_cstr(char* s) { std::free(s); }

}  // extern "C"

// ---------------------------------------------------------------------------
// Canvas surface. The real androidx.compose.ui.graphics.Canvas actual drives an
// SkCanvas on a KlioSurface: save/restore + transforms, clips, and shape/path
// draws with a full paint (style / stroke width / cap / join / antialias).
// Colours arrive with alpha already folded in, so this layer only carries the
// geometric paint state.
// ---------------------------------------------------------------------------
namespace {

// A shader parsed from klio's serialized gradient text, applied to the next
// draw's paint. A gradient brush sets this before the draw and clears it after.
static thread_local sk_sp<SkShader> g_pendingShader;

static SkTileMode tileModeFrom(int m) {
    switch (m) {
        case 1: return SkTileMode::kRepeat;
        case 2: return SkTileMode::kMirror;
        case 3: return SkTileMode::kDecal;
        default: return SkTileMode::kClamp;
    }
}

// Text: "L|fromX,fromY|toX,toY|tile|argb0,pos0;argb1,pos1;…" (L linear, R radial:
// "R|cx,cy|radius|tile|stops…"). Returns null on a malformed string.
static sk_sp<SkShader> makeShaderFromText(const char* text) {
    if (!text || !*text) return nullptr;
    std::string s(text);
    std::vector<std::string> parts;
    size_t start = 0;
    while (true) {
        size_t bar = s.find('|', start);
        parts.push_back(s.substr(start, bar == std::string::npos ? std::string::npos : bar - start));
        if (bar == std::string::npos) break;
        start = bar + 1;
    }
    if (parts.size() < 5) return nullptr;
    const bool linear = parts[0] == "L";
    std::vector<SkColor4f> colors;
    std::vector<SkScalar> pos;
    {
        std::string& stops = parts[4];
        size_t p = 0;
        while (p < stops.size()) {
            size_t semi = stops.find(';', p);
            std::string tok = stops.substr(p, semi == std::string::npos ? std::string::npos : semi - p);
            if (!tok.empty()) {
                size_t comma = tok.find(',');
                if (comma != std::string::npos) {
                    uint32_t argb = (uint32_t)strtoul(tok.substr(0, comma).c_str(), nullptr, 10);
                    float sp = strtof(tok.substr(comma + 1).c_str(), nullptr);
                    colors.push_back(SkColor4f::FromColor(toColor(argb)));
                    pos.push_back(sp);
                }
            }
            if (semi == std::string::npos) break;
            p = semi + 1;
        }
    }
    if (colors.size() < 2) return nullptr;
    const int tile = atoi(parts[3].c_str());
    SkGradient::Colors gc(SkSpan<const SkColor4f>(colors.data(), colors.size()),
                          SkSpan<const SkScalar>(pos.data(), pos.size()),
                          tileModeFrom(tile), nullptr);
    SkGradient grad(gc, SkGradient::Interpolation{});
    if (linear) {
        float fx = 0, fy = 0, tx = 0, ty = 0;
        sscanf(parts[1].c_str(), "%f,%f", &fx, &fy);
        sscanf(parts[2].c_str(), "%f,%f", &tx, &ty);
        SkPoint pts[2] = {{fx, fy}, {tx, ty}};
        return SkShaders::LinearGradient(pts, grad, nullptr);
    } else {
        float cx = 0, cy = 0, radius = 0;
        sscanf(parts[1].c_str(), "%f,%f", &cx, &cy);
        radius = strtof(parts[2].c_str(), nullptr);
        return SkShaders::RadialGradient(SkPoint{cx, cy}, radius, grad, nullptr);
    }
}

extern "C" void klio_skia_c_set_shader(KlioSurface* /*s*/, const char* text) {
    g_pendingShader = makeShaderFromText(text);
}

SkPaint klioCanvasPaint(uint32_t argb, int style, float strokeWidth, int cap, int join, int aa) {
    SkPaint p;
    p.setAntiAlias(aa != 0);
    p.setColor(toColor(argb));
    if (g_pendingShader) p.setShader(g_pendingShader);
    if (style == 1) {  // Stroke (0 = Fill; compose has no separate FillAndStroke)
        p.setStyle(SkPaint::kStroke_Style);
        p.setStrokeWidth(strokeWidth);
        p.setStrokeCap(cap == 1 ? SkPaint::kRound_Cap : cap == 2 ? SkPaint::kSquare_Cap
                                                                 : SkPaint::kButt_Cap);
        p.setStrokeJoin(join == 1 ? SkPaint::kRound_Join : join == 2 ? SkPaint::kBevel_Join
                                                                     : SkPaint::kMiter_Join);
    } else {
        p.setStyle(SkPaint::kFill_Style);
    }
    return p;
}

SkCanvas* klioCanvasOf(KlioSurface* s) { return s ? s->surface->getCanvas() : nullptr; }

}  // namespace

extern "C" {

void klio_skia_c_save(KlioSurface* s) { if (auto* c = klioCanvasOf(s)) c->save(); }
void klio_skia_c_restore(KlioSurface* s) { if (auto* c = klioCanvasOf(s)) c->restore(); }
void klio_skia_c_translate(KlioSurface* s, float dx, float dy) { if (auto* c = klioCanvasOf(s)) c->translate(dx, dy); }
void klio_skia_c_scale(KlioSurface* s, float sx, float sy) { if (auto* c = klioCanvasOf(s)) c->scale(sx, sy); }
void klio_skia_c_rotate(KlioSurface* s, float deg) { if (auto* c = klioCanvasOf(s)) c->rotate(deg); }
void klio_skia_c_skew(KlioSurface* s, float sx, float sy) { if (auto* c = klioCanvasOf(s)) c->skew(sx, sy); }

// Concat a 2D affine transform (Compose Matrix's affine components: scaleX,
// skewX, transX, skewY, scaleY, transY) onto the canvas.
void klio_skia_c_concat(KlioSurface* s, float sx, float kx, float tx, float ky, float sy, float ty) {
    if (auto* c = klioCanvasOf(s)) {
        SkMatrix m;
        m.setAll(sx, kx, tx, ky, sy, ty, 0, 0, 1);
        c->concat(m);
    }
}

// clipOp: 0 difference, 1 intersect (matching ClipOp).
void klio_skia_c_clip_rect(KlioSurface* s, float l, float t, float r, float b, int clipOp) {
    if (auto* c = klioCanvasOf(s))
        c->clipRect(SkRect::MakeLTRB(l, t, r, b),
                    clipOp == 0 ? SkClipOp::kDifference : SkClipOp::kIntersect, true);
}
void klio_skia_c_clip_path(KlioSurface* s, const char* pathText, int clipOp) {
    if (auto* c = klioCanvasOf(s))
        c->clipPath(klioBuildPath(pathText),
                    clipOp == 0 ? SkClipOp::kDifference : SkClipOp::kIntersect, true);
}

void klio_skia_c_draw_rect(KlioSurface* s, float l, float t, float r, float b,
                           uint32_t argb, int style, float sw, int cap, int join, int aa) {
    if (auto* c = klioCanvasOf(s))
        c->drawRect(SkRect::MakeLTRB(l, t, r, b), klioCanvasPaint(argb, style, sw, cap, join, aa));
}
void klio_skia_c_draw_rrect(KlioSurface* s, float l, float t, float r, float b, float rx, float ry,
                            uint32_t argb, int style, float sw, int cap, int join, int aa) {
    if (auto* c = klioCanvasOf(s))
        c->drawRRect(SkRRect::MakeRectXY(SkRect::MakeLTRB(l, t, r, b), rx, ry),
                     klioCanvasPaint(argb, style, sw, cap, join, aa));
}
void klio_skia_c_draw_oval(KlioSurface* s, float l, float t, float r, float b,
                           uint32_t argb, int style, float sw, int cap, int join, int aa) {
    if (auto* c = klioCanvasOf(s))
        c->drawOval(SkRect::MakeLTRB(l, t, r, b), klioCanvasPaint(argb, style, sw, cap, join, aa));
}
void klio_skia_c_draw_circle(KlioSurface* s, float cx, float cy, float rad,
                             uint32_t argb, int style, float sw, int cap, int join, int aa) {
    if (auto* c = klioCanvasOf(s))
        c->drawCircle(cx, cy, rad, klioCanvasPaint(argb, style, sw, cap, join, aa));
}
void klio_skia_c_draw_line(KlioSurface* s, float x0, float y0, float x1, float y1,
                           uint32_t argb, float sw, int cap, int aa) {
    if (auto* c = klioCanvasOf(s))
        c->drawLine(x0, y0, x1, y1, klioCanvasPaint(argb, 1, sw, cap, 0, aa));
}
void klio_skia_c_draw_path(KlioSurface* s, const char* pathText,
                           uint32_t argb, int style, float sw, int cap, int join, int aa) {
    if (auto* c = klioCanvasOf(s))
        c->drawPath(klioBuildPath(pathText), klioCanvasPaint(argb, style, sw, cap, join, aa));
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Windowing — a live on-screen surface + input event loop, one backend per OS
// behind the same C ABI (open / surface / present / poll / close):
//   SDL    (-DKLIO_SDL)   — Linux (and any SDL2 platform); raster (N32 premul ==
//                           SDL ARGB8888) uploaded to a streaming texture. SDL
//                           picks X11 or Wayland at runtime, so one backend covers
//                           the broad Linux desktop matrix.
//   Win32  (_WIN32)       — StretchDIBits blit; written, not run-verified here.
//   Cocoa  (-DKLIO_COCOA) — CALayer contents from a CGImage; written as
//                           Objective-C++, not compiled/run-verified here.
// Without a backend the window functions return failure and the pack falls back to
// headless rendering.
// ---------------------------------------------------------------------------

#if defined(KLIO_SDL)

// The shim is a shared library with no main(); tell SDL not to redefine main.
#define SDL_MAIN_HANDLED
#include <SDL.h>

// One routed event held for a window other than the one that polled: SDL's
// event queue is process-global, so a poll on window A may pull window B's
// event — it is parked on B and delivered by B's next poll.
struct KlioPendingEv {
    int type;
    int a;
    int b;
};

struct KlioWindow {
    SDL_Window* win = nullptr;
    SDL_Renderer* renderer = nullptr;  // raster present path (null in GPU mode)
    SDL_Texture* tex = nullptr;        // raster present path
    KlioSurface* surface = nullptr;
    int w = 0;
    int h = 0;
    Uint32 id = 0;                     // SDL window id (event routing key)
    std::vector<KlioPendingEv> pending;
    size_t pendingHead = 0;
#if defined(KLIO_GPU)
    SDL_GLContext gl = nullptr;
    sk_sp<GrDirectContext> grContext;  // per-window GL context for the on-screen GPU
    bool gpu = false;
#endif
};

// Open windows by SDL id, for event routing. klio is single-threaded.
static std::unordered_map<Uint32, KlioWindow*>& klioSdlWindows() {
    static std::unordered_map<Uint32, KlioWindow*> m;
    return m;
}
static int klioSdlOpenCount = 0;

extern "C" void klio_win_close(KlioWindow* kw);  // used by the open error paths

namespace {

// (Re)create the raster surface + streaming texture at w x h. Called on open and
// on every window resize so present always blits at the current window size.
bool klioSdlSizeRaster(KlioWindow* kw, int w, int h) {
    if (kw->surface) {
        klio_skia_free(kw->surface);
        kw->surface = nullptr;
    }
    if (kw->tex) {
        SDL_DestroyTexture(kw->tex);
        kw->tex = nullptr;
    }
    kw->surface = klio_skia_new(w, h);
    if (!kw->surface) return false;
    kw->tex = SDL_CreateTexture(kw->renderer, SDL_PIXELFORMAT_ARGB8888,
                                SDL_TEXTUREACCESS_STREAMING, w, h);
    if (!kw->tex) return false;
    SDL_SetTextureBlendMode(kw->tex, SDL_BLENDMODE_NONE);
    kw->w = w;
    kw->h = h;
    return true;
}

#if defined(KLIO_GPU)
constexpr unsigned kGlRgba8 = 0x8058;  // GL_RGBA8

// (Re)wrap the window's default GL framebuffer (FBO 0) as a GPU-backed surface at
// w x h. Called on open and on every resize (the default framebuffer resizes with
// the window; this just re-wraps it at the new size).
bool klioSdlSizeGpu(KlioWindow* kw, int w, int h) {
    if (kw->surface) {
        klio_skia_free(kw->surface);
        kw->surface = nullptr;
    }
    if (!kw->grContext) return false;
    GrGLFramebufferInfo fbInfo;
    fbInfo.fFBOID = 0;
    fbInfo.fFormat = kGlRgba8;
    GrBackendRenderTarget rt = GrBackendRenderTargets::MakeGL(w, h, 0, 8, fbInfo);
    SkSurfaceProps props;
    auto* s = new KlioSurface();
    s->surface = SkSurfaces::WrapBackendRenderTarget(
        kw->grContext.get(), rt, kBottomLeft_GrSurfaceOrigin, kRGBA_8888_SkColorType,
        nullptr, &props);
    if (!s->surface) {
        delete s;
        return false;
    }
    kw->surface = s;
    kw->w = w;
    kw->h = h;
    ensureFonts();
    return true;
}

// Try to open an on-screen GPU window: SDL GL context + a Skia GrDirectContext
// assembled from SDL's GL loader, wrapping the window framebuffer. Returns null on
// any failure so the caller falls back to the raster renderer.
KlioWindow* klioSdlOpenGpu(int w, int h, const char* title) {
    const bool dbg = std::getenv("KLIO_COMPOSE_DEBUG") != nullptr;
    // Compatibility profile keeps the legacy glGetString(GL_EXTENSIONS) query valid
    // (a core profile returns null there), which Skia's extension setup can use.
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_COMPATIBILITY);
    SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_Window* win = SDL_CreateWindow(
        title ? title : "klio", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, w, h,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE | SDL_WINDOW_OPENGL);
    if (!win) {
        if (dbg) std::fprintf(stderr, "[klio-compose] GPU CreateWindow failed: %s\n", SDL_GetError());
        return nullptr;
    }
    SDL_GLContext gl = SDL_GL_CreateContext(win);
    if (!gl) {
        if (dbg) std::fprintf(stderr, "[klio-compose] GPU CreateContext failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(win);
        return nullptr;
    }
    SDL_GL_MakeCurrent(win, gl);
    SDL_GL_SetSwapInterval(1);
    if (dbg) {
        using GetStringFn = const unsigned char* (*)(unsigned);
        auto glGetString = reinterpret_cast<GetStringFn>(SDL_GL_GetProcAddress("glGetString"));
        const unsigned char* r = glGetString ? glGetString(0x1F01 /*GL_RENDERER*/) : nullptr;
        const unsigned char* v = glGetString ? glGetString(0x1F02 /*GL_VERSION*/) : nullptr;
        std::fprintf(stderr, "[klio-compose] GPU window: GL renderer = %s | version = %s\n",
                     r ? reinterpret_cast<const char*>(r) : "(unknown)",
                     v ? reinterpret_cast<const char*>(v) : "(unknown)");
    }
    // SDL uses GLX on X11, so the native (GLX) interface resolves the modern
    // extension-enumeration path correctly. Fall back to assembling from SDL's
    // loader if the native interface is unavailable.
    sk_sp<const GrGLInterface> iface = GrGLMakeNativeInterface();
    if (!iface) {
        iface = GrGLMakeAssembledGLInterface(
            nullptr, [](void*, const char name[]) -> GrGLFuncPtr {
                return reinterpret_cast<GrGLFuncPtr>(SDL_GL_GetProcAddress(name));
            });
    }
    sk_sp<GrDirectContext> ctx = iface ? GrDirectContexts::MakeGL(iface) : nullptr;
    if (!ctx) {
        if (dbg) std::fprintf(stderr, "[klio-compose] GPU GrContext failed (iface=%s)\n",
                              iface ? "ok" : "null");
        SDL_GL_DeleteContext(gl);
        SDL_DestroyWindow(win);
        return nullptr;
    }
    auto* kw = new KlioWindow();
    kw->win = win;
    kw->gl = gl;
    kw->grContext = ctx;
    kw->gpu = true;
    int dw = w, dh = h;
    SDL_GL_GetDrawableSize(win, &dw, &dh);
    if (!klioSdlSizeGpu(kw, dw, dh)) {
        if (dbg) std::fprintf(stderr, "[klio-compose] GPU surface wrap failed (%dx%d)\n", dw, dh);
        klio_win_close(kw);
        return nullptr;
    }
    if (dbg) std::fprintf(stderr, "[klio-compose] GPU window ready (%dx%d)\n", dw, dh);
    return kw;
}
#endif  // KLIO_GPU

// (Re)size to w x h through whichever present path this window uses.
bool klioSdlSizeTo(KlioWindow* kw, int w, int h) {
#if defined(KLIO_GPU)
    if (kw->gpu) return klioSdlSizeGpu(kw, w, h);
#endif
    return klioSdlSizeRaster(kw, w, h);
}

}  // namespace

extern "C" {

KlioWindow* klio_win_open(int w, int h, const char* title) {
    if (w <= 0 || h <= 0) return nullptr;
    SDL_SetMainReady();
    if (SDL_WasInit(SDL_INIT_VIDEO) == 0 && SDL_InitSubSystem(SDL_INIT_VIDEO) != 0)
        return nullptr;
#if defined(KLIO_GPU)
    // Try an on-screen GPU window (Ganesh over SDL's GL context) first; fall back to
    // the raster renderer if any GL/Skia bring-up step fails.
    if (KlioWindow* gpuWin = klioSdlOpenGpu(w, h, title)) {
        SDL_StartTextInput();
        gpuWin->id = SDL_GetWindowID(gpuWin->win);
        klioSdlWindows()[gpuWin->id] = gpuWin;
        ++klioSdlOpenCount;
        return gpuWin;
    }
#endif
    SDL_Window* win = SDL_CreateWindow(title ? title : "klio", SDL_WINDOWPOS_CENTERED,
                                       SDL_WINDOWPOS_CENTERED, w, h,
                                       SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);
    if (!win) return nullptr;
    // Prefer an accelerated renderer; fall back to software if none is available.
    SDL_Renderer* r = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!r) r = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!r) {
        SDL_DestroyWindow(win);
        return nullptr;
    }
    auto* kw = new KlioWindow();
    kw->win = win;
    kw->renderer = r;
    kw->w = w;
    kw->h = h;
    if (!klioSdlSizeRaster(kw, w, h)) {
        klio_win_close(kw);
        return nullptr;
    }
    SDL_StartTextInput();  // deliver typed characters as SDL_TEXTINPUT events
    kw->id = SDL_GetWindowID(win);
    klioSdlWindows()[kw->id] = kw;
    ++klioSdlOpenCount;
    return kw;
}

// Update the native title (recomposition-driven window parameters).
void klio_win_set_title(KlioWindow* kw, const char* title) {
    if (!kw || !kw->win || !title) return;
    SDL_SetWindowTitle(kw->win, title);
}

// Resize the native window; the surface follows via the routed
// SIZE_CHANGED event (or immediately, so a frame drawn before the event
// lands still targets the new extent).
void klio_win_set_size(KlioWindow* kw, int w, int h) {
    if (!kw || !kw->win || w <= 0 || h <= 0) return;
    SDL_SetWindowSize(kw->win, w, h);
    if (w != kw->w || h != kw->h) klioSdlSizeTo(kw, w, h);
}

// The surface the caller replays the display list onto before presenting.
KlioSurface* klio_win_surface(KlioWindow* kw) { return kw ? kw->surface : nullptr; }

// Upload the raster surface to the texture and present it. N32 premul (BGRA byte
// order on little-endian) matches SDL_PIXELFORMAT_ARGB8888.
void klio_win_present(KlioWindow* kw) {
    if (!kw || !kw->surface) return;
#if defined(KLIO_GPU)
    if (kw->gpu) {
        if (kw->grContext) kw->grContext->flushAndSubmit(kw->surface->surface.get());
        SDL_GL_SwapWindow(kw->win);
        return;
    }
#endif
    if (!kw->tex) return;
    SkPixmap pm;
    if (!kw->surface->surface->peekPixels(&pm)) return;
    SDL_UpdateTexture(kw->tex, nullptr, pm.addr(), static_cast<int>(pm.rowBytes()));
    SDL_RenderClear(kw->renderer);
    SDL_RenderCopy(kw->renderer, kw->tex, nullptr, nullptr);
    SDL_RenderPresent(kw->renderer);
}

// Wait up to timeoutMs for one event (poll when timeoutMs <= 0, so the caller can
// drain a backlog non-blocking). Returns an event type and writes two type-
// dependent values into *outA/*outB:
//   0 none/redraw
//   1 click     — outA=x, outB=y
//   2 close
//   3 key       — outA=char (ASCII, 0 if non-printable), outB=keysym (X11-style)
//   4 move      — outA=x, outB=y (pointer position)
//   5 resize    — outA=width, outB=height (the surface is recreated to match)
// Classify one SDL event against its TARGET window (which may not be the
// polling one): the poll contract's (type, a, b). Resize applies the
// surface change to the target.
static int klioSdlClassify(KlioWindow* kw, const SDL_Event& ev, int* outA, int* outB) {
    switch (ev.type) {
        case SDL_WINDOWEVENT:
            if (ev.window.event == SDL_WINDOWEVENT_CLOSE) return 2;
            if (ev.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
                const int nw = ev.window.data1;
                const int nh = ev.window.data2;
                if (nw > 0 && nh > 0 && (nw != kw->w || nh != kw->h)) {
                    klioSdlSizeTo(kw, nw, nh);
                    if (outA) *outA = nw;
                    if (outB) *outB = nh;
                    return 5;
                }
            }
            return 0;  // Exposed / focus / etc. — the caller re-presents each loop.
        case SDL_MOUSEBUTTONDOWN:
            if (ev.button.button != SDL_BUTTON_LEFT) return 0;
            if (outA) *outA = ev.button.x;
            if (outB) *outB = ev.button.y;
            return 1;
        case SDL_MOUSEMOTION:
            if (outA) *outA = ev.motion.x;
            if (outB) *outB = ev.motion.y;
            return 4;
        case SDL_TEXTINPUT: {
            // A typed printable character (honours shift/layout). Non-ASCII bytes
            // are ignored for now (the interim ui-core is ASCII-only).
            const unsigned char c = static_cast<unsigned char>(ev.text.text[0]);
            if (c < 32 || c > 126) return 0;
            if (outA) *outA = c;
            if (outB) *outB = 0;
            return 3;
        }
        case SDL_KEYDOWN: {
            // Only the editing keys the ui-core handles; printable characters
            // arrive via SDL_TEXTINPUT, so ignore their key-down to avoid doubling.
            // Report X11-style keysyms so the pack's key handling stays unchanged.
            int ch = 0;
            int keysym = 0;
            switch (ev.key.keysym.sym) {
                case SDLK_BACKSPACE: ch = 8; keysym = 0xff08; break;
                case SDLK_DELETE:    ch = 0; keysym = 0xffff; break;
                default: return 0;
            }
            if (outA) *outA = ch;
            if (outB) *outB = keysym;
            return 3;
        }
        default:
            return 0;
    }
}

int klio_win_poll(KlioWindow* kw, int timeoutMs, int* outA, int* outB) {
    if (!kw) return 2;
    // Deliver events routed here by another window's earlier poll first.
    if (kw->pendingHead < kw->pending.size()) {
        const KlioPendingEv pe = kw->pending[kw->pendingHead++];
        if (kw->pendingHead == kw->pending.size()) {
            kw->pending.clear();
            kw->pendingHead = 0;
        }
        if (outA) *outA = pe.a;
        if (outB) *outB = pe.b;
        return pe.type;
    }
    SDL_Event ev;
    const int got = (timeoutMs > 0) ? SDL_WaitEventTimeout(&ev, timeoutMs)
                                    : SDL_PollEvent(&ev);
    if (!got) return 0;
    if (ev.type == SDL_QUIT) return 2;  // app-level quit: the poller reports close
    // SDL's queue is process-global: route by the event's window id, parking
    // another window's event on that window for its own next poll.
    Uint32 wid;
    switch (ev.type) {
        case SDL_WINDOWEVENT: wid = ev.window.windowID; break;
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP: wid = ev.button.windowID; break;
        case SDL_MOUSEMOTION: wid = ev.motion.windowID; break;
        case SDL_TEXTINPUT: wid = ev.text.windowID; break;
        case SDL_KEYDOWN:
        case SDL_KEYUP: wid = ev.key.windowID; break;
        default: wid = kw->id; break;
    }
    KlioWindow* target = kw;
    if (wid != kw->id) {
        auto it = klioSdlWindows().find(wid);
        if (it == klioSdlWindows().end()) return 0;  // a closed window's straggler
        target = it->second;
    }
    int a = 0;
    int b = 0;
    const int type = klioSdlClassify(target, ev, &a, &b);
    if (target == kw) {
        if (outA) *outA = a;
        if (outB) *outB = b;
        return type;
    }
    if (type != 0) target->pending.push_back({type, a, b});
    return 0;
}

void klio_win_close(KlioWindow* kw) {
    if (!kw) return;
    klioSdlWindows().erase(kw->id);
    // The VIDEO subsystem is shared by every open window: quit it only
    // when the last one closes.
    const bool last = (--klioSdlOpenCount) <= 0;
    if (kw->surface) klio_skia_free(kw->surface);
#if defined(KLIO_GPU)
    if (kw->gpu) {
        // Release GPU resources (surface freed above) before the GL context.
        kw->grContext.reset();
        if (kw->gl) SDL_GL_DeleteContext(kw->gl);
        if (kw->win) SDL_DestroyWindow(kw->win);
        if (last) SDL_QuitSubSystem(SDL_INIT_VIDEO);
        delete kw;
        return;
    }
#endif
    if (kw->tex) SDL_DestroyTexture(kw->tex);
    if (kw->renderer) SDL_DestroyRenderer(kw->renderer);
    if (kw->win) SDL_DestroyWindow(kw->win);
    if (last) SDL_QuitSubSystem(SDL_INIT_VIDEO);
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

void klio_win_set_title(KlioWindow* kw, const char* title) {
    if (!kw || !title) return;
    SetWindowTextA(kw->hwnd, title);
}

void klio_win_set_size(KlioWindow* kw, int w, int h) {
    if (!kw || w <= 0 || h <= 0) return;
    RECT r = {0, 0, w, h};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    SetWindowPos(kw->hwnd, nullptr, 0, 0, r.right - r.left, r.bottom - r.top,
                 SWP_NOMOVE | SWP_NOZORDER);
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

void klio_win_set_title(KlioWindow* kw, const char* title) {
    if (!kw || !kw->window || !title) return;
    @autoreleasepool {
        [kw->window setTitle:[NSString stringWithUTF8String:title]];
    }
}

void klio_win_set_size(KlioWindow* kw, int w, int h) {
    if (!kw || !kw->window || w <= 0 || h <= 0) return;
    @autoreleasepool {
        [kw->window setContentSize:NSMakeSize(w, h)];
    }
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
void klio_win_set_title(void*, const char*) {}
void klio_win_set_size(void*, int, int) {}
}  // extern "C"

#endif

// gradient shader support
