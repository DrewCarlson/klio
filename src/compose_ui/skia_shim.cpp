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
