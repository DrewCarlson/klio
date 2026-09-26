// Skia rendering shim — a thin extern-"C" surface over Skia's C++ API so the Zig
// `compose_ui` module can drive a real GPU-class rasterizer without any C++ in Zig.
// Built with system g++/libstdc++ (Skia's prebuilt libs use the old GNU string
// ABI; zig cc/libc++ will not link them). See plans/open-campaigns.md.
//
// It owns the raster surfaces ui-graphics draws on and the platform windows,
// trays and menus; skiko's own C glue, linked in beside it, draws the frame.
// Colors are 0xAARRGGBB (Compose's packed ARGB). Coordinates are pixels.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <string>
#include <unordered_map>
#include <algorithm>
#include <cctype>
#include <vector>

#include "window_events.h"

#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImage.h"
#include "include/core/SkImageInfo.h"
#include "include/core/SkBlurTypes.h"
#include "include/core/SkMaskFilter.h"
#include "include/core/SkColorFilter.h"
#include "include/core/SkBlendMode.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPicture.h"
#include "include/core/SkPictureRecorder.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkRRect.h"
#include "include/core/SkRect.h"
#include "include/core/SkStream.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTypeface.h"
#include "include/codec/SkCodec.h"
#include "include/codec/SkPngDecoder.h"
#include "include/encode/SkPngEncoder.h"
#include "include/effects/SkGradient.h"
#include "include/effects/SkImageFilters.h"
#include "include/effects/Sk1DPathEffect.h"
#include "include/effects/SkCornerPathEffect.h"
#include "include/effects/SkDashPathEffect.h"
#include "include/pathops/SkPathOps.h"
#include "include/core/SkM44.h"
#include "include/core/SkVertices.h"
#include "modules/skparagraph/include/DartTypes.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#include "modules/skparagraph/include/TypefaceFontProvider.h"
#include "modules/skunicode/include/SkUnicode_icu.h"
// The platform's font manager, as skiko's FontMgrDefaultFactory makes it:
// CoreText, DirectWrite, fontconfig with FreeType, or Android's. The macOS
// Skia pack has no custom-empty port, so only the others fall back to it.
#include "FontMgrDefaultFactory.hh"
#if !defined(__APPLE__)
#include "include/ports/SkFontMgr_empty.h"
#endif

// Windowing-backend capability marker, baked into the shim's data section so
// `klio bundle` can read it by a byte scan (works for the host and for a
// cross-target shim) and fail fast when a windowed Compose UI program would
// otherwise ship against the stub backend — which cannot open a window and
// exits silently. The values track the backend #if selection further down.
#if defined(KLIO_SDL)
extern "C" const char klio_win_backend_tag[] = "klio-win-backend:sdl";
#elif defined(_WIN32)
extern "C" const char klio_win_backend_tag[] = "klio-win-backend:win32";
#elif defined(__APPLE__) && defined(KLIO_COCOA)
extern "C" const char klio_win_backend_tag[] = "klio-win-backend:cocoa";
#else
extern "C" const char klio_win_backend_tag[] = "klio-win-backend:stub";
#endif

// Optional GPU (Ganesh) window surfaces, off by default: built with -DKLIO_GPU,
// the SDL window draws through a GL context; otherwise it draws on a raster
// surface.
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
#endif  // KLIO_GPU

namespace {

// A drawing target: a raster or GPU surface, or a picture being recorded. While
// a recording is open its canvas takes the draws, and the handle has no pixels.
struct KlioSurface {
    sk_sp<SkSurface> surface;
    std::unique_ptr<SkPictureRecorder> recorder;
    SkCanvas* recording = nullptr;
};


// The canvas a handle's draws go to.
SkCanvas* canvasOf(KlioSurface* s) {
    if (!s) return nullptr;
    if (s->recording) return s->recording;
    return s->surface ? s->surface->getCanvas() : nullptr;
}

// Common system font paths tried (in order) for text rendering, since the empty
// SkFontMgr ships no faces. $KLIO_SKIA_FONT overrides. A miss leaves text
// unpainted.
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
    g_fontMgr = SkFontMgrSkikoDefault();
#if !defined(__APPLE__)
    // A platform skiko has no font manager for keeps only the bundled face.
    if (!g_fontMgr) g_fontMgr = SkFontMgr_New_Custom_Empty();
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


// The fonts a generic family names on this platform, in skiko's order
// (PlatformFont.skiko.kt's GenericFontFamiliesMapping); another name stands
// for itself.
std::vector<SkString> familyAliases(const std::string& family) {
    struct Generic { const char* name; std::vector<const char*> aliases; };
#if defined(__APPLE__)
    static const Generic kGeneric[] = {
        {"sans-serif", {".AppleSystemUIFont", "Helvetica Neue", "Helvetica"}},
        {"serif", {".AppleSystemUIFontSerif", "Times", "Times New Roman"}},
        {"monospace", {".AppleSystemUIFontMonospaced", "Menlo", "Courier"}},
        {"cursive", {"Apple Chancery", "Snell Roundhand"}},
    };
#elif defined(_WIN32)
    static const Generic kGeneric[] = {
        {"sans-serif", {"Segoe UI", "Arial"}},
        {"serif", {"Times New Roman"}},
        {"monospace", {"Consolas"}},
        {"cursive", {"Comic Sans MS"}},
    };
#else
    static const Generic kGeneric[] = {
        {"sans-serif", {"Noto Sans", "DejaVu Sans", "Arial"}},
        {"serif", {"Noto Serif", "DejaVu Serif", "Times New Roman"}},
        {"monospace", {"Noto Sans Mono", "DejaVu Sans Mono", "Consolas"}},
        {"cursive", {"Comic Sans MS"}},
    };
#endif
    std::vector<SkString> out;
    if (family.empty() || family == "-") return out;
    // The spec lists names separated by '|', each percent-encoded.
    size_t start = 0;
    while (start <= family.size()) {
        size_t bar = family.find('|', start);
        const std::string enc = family.substr(start, bar == std::string::npos ? std::string::npos : bar - start);
        std::string name;
        for (size_t i = 0; i < enc.size(); ++i) {
            if (enc[i] == '%' && i + 2 < enc.size()) {
                const std::string hex = enc.substr(i + 1, 2);
                name.push_back(static_cast<char>(strtol(hex.c_str(), nullptr, 16)));
                i += 2;
            } else {
                name.push_back(enc[i]);
            }
        }
        bool generic = false;
        for (const auto& g : kGeneric) {
            if (name == g.name) {
                for (const char* a : g.aliases) out.push_back(SkString(a));
                generic = true;
                break;
            }
        }
        if (!generic && !name.empty()) out.push_back(SkString(name.c_str()));
        if (bar == std::string::npos) break;
        start = bar + 1;
    }
    return out;
}

inline SkColor toColor(uint32_t argb) { return static_cast<SkColor>(argb); }





// Snapshot a surface's pixels: the fast peekPixels path for raster surfaces, or a
// GPU→CPU readback for Ganesh surfaces. `backing` owns the pixels when read back.
bool surfaceToPixmap(KlioSurface* s, SkPixmap& pm, SkBitmap& backing) {
    if (!s->surface) return false;
    if (s->surface->peekPixels(&pm)) return true;
    if (!backing.tryAllocPixels(s->surface->imageInfo())) return false;
    if (!s->surface->readPixels(backing.pixmap(), 0, 0)) return false;
    pm = backing.pixmap();
    return true;
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
    if (auto* c = canvasOf(s)) c->clear(toColor(argb));
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

// The canvas a surface's draws go to, as the SkCanvas* a skiko Canvas wraps;
// null for none. The surface owns it.
SkCanvas* klio_skia_surf_canvas(KlioSurface* s) { return canvasOf(s); }

// A surface's width (which 0) or height (which 1); 0 for none.
int klio_skia_surf_size(KlioSurface* s, int which) {
    if (!s || !s->surface) return 0;
    return which == 0 ? s->surface->width() : s->surface->height();
}

}  // extern "C"

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#elif defined(_WIN32)
#include <windows.h>
#endif

extern "C" {

// Frees a C string the shim returned (the clipboard's text, a locale name).
void klio_skia_free_cstr(char* s) { std::free(s); }

// The system's appearance, as skiko reads it: 0 light, 1 dark, 2 unknown.
// macOS answers by its interface style and Windows by whether apps use the
// light theme; elsewhere it is unknown.
int klio_system_theme(void) {
#if defined(__APPLE__) && TARGET_OS_OSX
    CFPropertyListRef style =
        CFPreferencesCopyAppValue(CFSTR("AppleInterfaceStyle"), kCFPreferencesAnyApplication);
    if (!style) return 0;
    const bool dark = CFGetTypeID(style) == CFStringGetTypeID() &&
                      CFStringCompare(static_cast<CFStringRef>(style), CFSTR("Dark"), 0) == kCFCompareEqualTo;
    CFRelease(style);
    return dark ? 1 : 0;
#elif defined(_WIN32)
    DWORD light = 1;
    DWORD size = sizeof(light);
    const LSTATUS status = RegGetValueW(HKEY_CURRENT_USER,
                                        L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                                        L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &light, &size);
    if (status != ERROR_SUCCESS) return 2;
    return light == 0 ? 1 : 0;
#else
    return 2;
#endif
}

}  // extern "C"

// ---------------------------------------------------------------------------
// Windowing — a live on-screen surface + input event loop, one backend per OS
// behind the same C ABI (open / surface / present / poll / close):
//   SDL    (-DKLIO_SDL)   — Linux (and any SDL2 platform); raster (N32 premul ==
//                           SDL ARGB8888) uploaded to a streaming texture. SDL
//                           picks X11 or Wayland at runtime, so one backend covers
//                           the broad Linux desktop matrix.
//   Win32  (_WIN32)       — StretchDIBits blit.
//   Cocoa  (-DKLIO_COCOA) — a Metal layer, or CALayer contents from a CGImage.
// Without a backend the window functions return failure and the pack falls back to
// headless rendering.
// ---------------------------------------------------------------------------

// Debug: $KLIO_SKIA_DUMP writes a presented frame to that PNG path, the first
// one or the $KLIO_SKIA_DUMP_AT-th, so a window's render (a GPU one included,
// and a drawn menu bar with its open menus) can be inspected without
// on-screen capture. A path with %d writes every frame, numbered from 1.
// Why the last klio_win_open returned null, which the program reports.
static std::string g_klioWinError;

[[maybe_unused]] static void klioWinFailed(const std::string& why) {
    g_klioWinError = why;
}

extern "C" const char* klio_win_last_error(void) {
    return g_klioWinError.c_str();
}

[[maybe_unused]] static void klioPresentDump(KlioSurface* surface) {
    const char* dump = std::getenv("KLIO_SKIA_DUMP");
    if (!dump || !surface) return;
    static int presents = 0;
    ++presents;
    std::string numbered;
    const char* path = dump;
    if (const char* mark = std::strstr(dump, "%d")) {
        numbered = std::string(dump, mark) + std::to_string(presents) + (mark + 2);
        path = numbered.c_str();
    } else {
        const char* at = std::getenv("KLIO_SKIA_DUMP_AT");
        if (presents != (at ? std::atoi(at) : 1)) return;
    }
    const int rc = klio_skia_save_png(surface, path);
    if (std::getenv("KLIO_SKIA_VERBOSE"))
        fprintf(stderr, "[klio-skia] present %d dump rc=%d -> %s\n", presents, rc, path);
}

#if defined(KLIO_SDL)

// The shim is a shared library with no main(); tell SDL not to redefine main.
#define SDL_MAIN_HANDLED
#include <SDL.h>
#if defined(__linux__) && __has_include(<X11/Xlib.h>)
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <dlfcn.h>
#include <sys/select.h>
#include <cmath>
#include <type_traits>
#define KLIO_X11_TRAY 1
#endif

// One routed event held for a window other than the one that polled: SDL's
// event queue is process-global, so a poll on window A may pull window B's
// event — it is parked on B and delivered by B's next poll.
struct KlioPendingEv {
    int type;
    int a;
    int b;
};

// An open panel of an SDL window's drawn menu bar: the menu it lists, where it
// is, its items and the one hovered.
struct KlioSdlMenuPanel {
    int menu = -1;
    float x = 0;
    float y = 0;
    float w = 0;
    float h = 0;
    std::vector<int> items;
    int hover = -1;
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
    std::deque<KlioEv> events;         // klio_win_poll_event's queue
    int buttons = 0;                   // the mouse buttons held, one bit per KLIO_BTN_* - 1
    KlioScriptState script;            // its progress through the scripted input
    int barH = 0;                      // the menu bar's height over the content
    KlioSurface* frame = nullptr;      // the whole window: the bar, the content, the menus
    unsigned menuShown = 0;            // the menu state the window last showed
    struct KlioMenuUi* menu = nullptr;  // its menu bar, which the window draws
    KlioFrameReport frameReport;       // the frame and placement last reported
    bool textInput = false;            // a text field has the keyboard (klio_win_set_text_input)
    bool composing = false;            // the input method is composing
    SDL_Rect imeRect = {0, 0, 0, 0};   // the text cursor, in the content
    std::string eventText;             // the text of the event last polled
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
// The open windows hold one reference on SDL's video subsystem, taken when the
// first opens and given back when the last closes; the clipboard holds its own.
static bool klioSdlWindowsHoldVideo = false;

static void klioSdlReleaseVideo() {
    if (!klioSdlWindowsHoldVideo) return;
    klioSdlWindowsHoldVideo = false;
    SDL_QuitSubSystem(SDL_INIT_VIDEO);
}

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
    if (kw->frame) {
        klio_skia_free(kw->frame);
        kw->frame = nullptr;
    }
    // The content is what the menu bar leaves of the window.
    kw->surface = klio_skia_new(w, std::max(1, h - kw->barH));
    if (!kw->surface) return false;
    if (kw->barH > 0) {
        kw->frame = klio_skia_new(w, h);
        if (!kw->frame) return false;
    }
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
    if (!klioSdlWindowsHoldVideo) {
#if SDL_VERSION_ATLEAST(2, 0, 22)
        // A composition longer than SDL_TEXTEDITING's 32 bytes arrives whole.
        SDL_SetHint(SDL_HINT_IME_SUPPORT_EXTENDED_TEXT, "1");
#endif
        if (SDL_InitSubSystem(SDL_INIT_VIDEO) != 0) {
            klioWinFailed(std::string("SDL could not start its video subsystem: ") + SDL_GetError());
            return nullptr;
        }
        klioSdlWindowsHoldVideo = true;
    }
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
    if (!win) {
        klioWinFailed(std::string("SDL could not create a window: ") + SDL_GetError());
        return nullptr;
    }
    // Prefer an accelerated renderer; fall back to software if none is available.
    SDL_Renderer* r = SDL_CreateRenderer(win, -1, SDL_RENDERER_ACCELERATED);
    if (!r) r = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!r) {
        klioWinFailed(std::string("SDL could not create a renderer: ") + SDL_GetError());
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

// Set the window icon from encoded PNG bytes (a bundle's `--icon`). The PNG
// decodes through Skia's codec into RGBA and hands SDL a borrowed-pixel
// surface; SDL copies it, so both are released before returning.
void klio_win_set_icon_png(KlioWindow* kw, const unsigned char* png, size_t len) {
    if (!kw || !kw->win || !png || len == 0) return;
    sk_sp<SkData> data = SkData::MakeWithoutCopy(png, len);
    std::unique_ptr<SkCodec> codec = SkPngDecoder::Decode(data, nullptr);
    if (!codec) return;
    SkImageInfo info = codec->getInfo()
                           .makeColorType(kRGBA_8888_SkColorType)
                           .makeAlphaType(kUnpremul_SkAlphaType);
    SkBitmap bm;
    if (!bm.tryAllocPixels(info)) return;
    if (codec->getPixels(info, bm.getPixels(), bm.rowBytes()) != SkCodec::kSuccess) return;
    SDL_Surface* surf = SDL_CreateRGBSurfaceWithFormatFrom(
        bm.getPixels(), info.width(), info.height(), 32,
        static_cast<int>(bm.rowBytes()), SDL_PIXELFORMAT_RGBA32);
    if (!surf) return;
    SDL_SetWindowIcon(kw->win, surf);
    SDL_FreeSurface(surf);
}

// A window's icon (Compose's Window(icon)) from a drawn surface.
void klio_win_set_icon_surface(KlioWindow* kw, KlioSurface* s) {
    if (!kw || !s) return;
    size_t len = 0;
    uint8_t* png = klio_skia_encode_png(s, &len);
    if (!png) return;
    klio_win_set_icon_png(kw, png, len);
    klio_skia_free_buffer(png);
}

// Resize the native window; the surface follows via the routed
// SIZE_CHANGED event (or immediately, so a frame drawn before the event
// lands still targets the new extent).
void klio_win_set_size(KlioWindow* kw, int w, int h) {
    if (!kw || !kw->win || w <= 0 || h <= 0) return;
    SDL_SetWindowSize(kw->win, w, h);
    if (w != kw->w || h != kw->h) klioSdlSizeTo(kw, w, h);
}

static void klioSdlPaintFrame(KlioWindow* kw);
static unsigned klioMenuVersion(const KlioMenuUi& ui);

// The surface the caller draws the frame on before presenting.
KlioSurface* klio_win_surface(KlioWindow* kw) { return kw ? kw->surface : nullptr; }

// Shows the raster window: the content as last drawn, under the bar and the
// open menus. N32 premul (BGRA byte order on little-endian) matches
// SDL_PIXELFORMAT_ARGB8888.
static void klioSdlShow(KlioWindow* kw) {
    if (!kw->tex || !kw->surface) return;
    KlioSurface* shown = kw->surface;
    if (kw->barH > 0 && kw->frame) {
        klioSdlPaintFrame(kw);
        shown = kw->frame;
    }
    if (kw->menu) kw->menuShown = klioMenuVersion(*kw->menu);
    klioPresentDump(shown);
    SkPixmap pm;
    if (!shown->surface->peekPixels(&pm)) return;
    SDL_UpdateTexture(kw->tex, nullptr, pm.addr(), static_cast<int>(pm.rowBytes()));
    SDL_RenderClear(kw->renderer);
    SDL_RenderCopy(kw->renderer, kw->tex, nullptr, nullptr);
    SDL_RenderPresent(kw->renderer);
}

// Presents what the caller drew on the window's surface.
void klio_win_present(KlioWindow* kw) {
    if (!kw || !kw->surface) return;
#if defined(KLIO_GPU)
    if (kw->gpu) {
        if (kw->grContext) kw->grContext->flushAndSubmit(kw->surface->surface.get());
        klioPresentDump(kw->surface);
        SDL_GL_SwapWindow(kw->win);
        return;
    }
#endif
    klioSdlShow(kw);
}

// Shows the windows whose menus changed since they were last shown: the
// content has not changed, so the program draws nothing new for them.
static void klioSdlShowMenus() {
    for (auto& entry : klioSdlWindows()) {
        KlioWindow* w = entry.second;
        if (w->menu && klioMenuVersion(*w->menu) != w->menuShown) klioSdlShow(w);
    }
}


// The modifiers the desktop reports, from SDL's.
static int klioSdlMods(Uint16 mod) {
    int m = 0;
    if (mod & KMOD_SHIFT) m |= KLIO_MOD_SHIFT;
    if (mod & KMOD_CTRL) m |= KLIO_MOD_CTRL;
    if (mod & KMOD_ALT) m |= KLIO_MOD_ALT;
    if (mod & KMOD_GUI) m |= KLIO_MOD_META;
    if (mod & KMOD_MODE) m |= KLIO_MOD_ALT_GRAPH;
    if (mod & KMOD_CAPS) m |= KLIO_MOD_CAPS_LOCK;
    if (mod & KMOD_NUM) m |= KLIO_MOD_NUM_LOCK;
    return m;
}

static int klioSdlButton(Uint8 b) {
    switch (b) {
        case SDL_BUTTON_LEFT: return KLIO_BTN_PRIMARY;
        case SDL_BUTTON_RIGHT: return KLIO_BTN_SECONDARY;
        case SDL_BUTTON_MIDDLE: return KLIO_BTN_TERTIARY;
        case SDL_BUTTON_X1: return KLIO_BTN_BACK;
        case SDL_BUTTON_X2: return KLIO_BTN_FORWARD;
        default: return KLIO_BTN_NONE;
    }
}

// An SDL key as AWT's key code and location, as the desktop's X11 toolkit
// numbers the key.
static void klioSdlKey(SDL_Keycode k, int* vk, int* loc) {
    *loc = KLIO_LOC_STANDARD;
    if (k >= SDLK_a && k <= SDLK_z) {
        *vk = VKK_A + (k - SDLK_a);
        return;
    }
    if (k >= SDLK_0 && k <= SDLK_9) {
        *vk = VKK_0 + (k - SDLK_0);
        return;
    }
    if (k >= SDLK_F1 && k <= SDLK_F12) {
        *vk = klioVkFunction(1 + (k - SDLK_F1));
        return;
    }
    if (k >= SDLK_F13 && k <= SDLK_F24) {
        *vk = klioVkFunction(13 + (k - SDLK_F13));
        return;
    }
    if (k >= SDLK_KP_1 && k <= SDLK_KP_9) {
        *vk = VKK_NUMPAD0 + 1 + (k - SDLK_KP_1);
        *loc = KLIO_LOC_NUMPAD;
        return;
    }
    switch (k) {
        case SDLK_RETURN: *vk = VKK_ENTER; return;
        case SDLK_ESCAPE: *vk = VKK_ESCAPE; return;
        case SDLK_BACKSPACE: *vk = VKK_BACK_SPACE; return;
        case SDLK_TAB: *vk = VKK_TAB; return;
        case SDLK_SPACE: *vk = VKK_SPACE; return;
        case SDLK_MINUS: *vk = VKK_MINUS; return;
        case SDLK_EQUALS: *vk = VKK_EQUALS; return;
        case SDLK_LEFTBRACKET: *vk = VKK_OPEN_BRACKET; return;
        case SDLK_RIGHTBRACKET: *vk = VKK_CLOSE_BRACKET; return;
        case SDLK_BACKSLASH: *vk = VKK_BACK_SLASH; return;
        case SDLK_SEMICOLON: *vk = VKK_SEMICOLON; return;
        case SDLK_QUOTE: *vk = VKK_QUOTE; return;
        case SDLK_BACKQUOTE: *vk = VKK_BACK_QUOTE; return;
        case SDLK_COMMA: *vk = VKK_COMMA; return;
        case SDLK_PERIOD: *vk = VKK_PERIOD; return;
        case SDLK_SLASH: *vk = VKK_SLASH; return;
        case SDLK_CAPSLOCK: *vk = VKK_CAPS_LOCK; return;
        case SDLK_PRINTSCREEN: *vk = VKK_PRINTSCREEN; return;
        case SDLK_SCROLLLOCK: *vk = VKK_SCROLL_LOCK; return;
        case SDLK_PAUSE: *vk = VKK_PAUSE; return;
        case SDLK_INSERT: *vk = VKK_INSERT; return;
        case SDLK_HOME: *vk = VKK_HOME; return;
        case SDLK_PAGEUP: *vk = VKK_PAGE_UP; return;
        case SDLK_DELETE: *vk = VKK_DELETE; return;
        case SDLK_END: *vk = VKK_END; return;
        case SDLK_PAGEDOWN: *vk = VKK_PAGE_DOWN; return;
        case SDLK_RIGHT: *vk = VKK_RIGHT; return;
        case SDLK_LEFT: *vk = VKK_LEFT; return;
        case SDLK_DOWN: *vk = VKK_DOWN; return;
        case SDLK_UP: *vk = VKK_UP; return;
        case SDLK_NUMLOCKCLEAR: *vk = VKK_NUM_LOCK; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_KP_DIVIDE: *vk = VKK_DIVIDE; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_KP_MULTIPLY: *vk = VKK_MULTIPLY; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_KP_MINUS: *vk = VKK_SUBTRACT; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_KP_PLUS: *vk = VKK_ADD; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_KP_ENTER: *vk = VKK_ENTER; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_KP_0: *vk = VKK_NUMPAD0; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_KP_PERIOD: *vk = VKK_DECIMAL; *loc = KLIO_LOC_NUMPAD; return;
        case SDLK_LCTRL: *vk = VKK_CONTROL; *loc = KLIO_LOC_LEFT; return;
        case SDLK_RCTRL: *vk = VKK_CONTROL; *loc = KLIO_LOC_RIGHT; return;
        case SDLK_LSHIFT: *vk = VKK_SHIFT; *loc = KLIO_LOC_LEFT; return;
        case SDLK_RSHIFT: *vk = VKK_SHIFT; *loc = KLIO_LOC_RIGHT; return;
        case SDLK_LALT: *vk = VKK_ALT; *loc = KLIO_LOC_LEFT; return;
        case SDLK_RALT: *vk = VKK_ALT; *loc = KLIO_LOC_RIGHT; return;
        case SDLK_LGUI: *vk = VKK_WINDOWS; *loc = KLIO_LOC_LEFT; return;
        case SDLK_RGUI: *vk = VKK_WINDOWS; *loc = KLIO_LOC_RIGHT; return;
        case SDLK_MODE: *vk = VKK_ALT_GRAPH; return;
        case SDLK_APPLICATION: *vk = VKK_CONTEXT_MENU; return;
        case SDLK_HELP: *vk = VKK_HELP; return;
        default: *vk = VKK_UNDEFINED; return;
    }
}

// The character a key types unshifted, or none: SDL names a printable key by
// it; letters take the case Shift and Caps Lock give them.
static unsigned klioSdlKeyChar(SDL_Keycode k, Uint16 mod) {
    if (k >= SDLK_a && k <= SDLK_z) {
        const bool upper = ((mod & KMOD_SHIFT) != 0) != ((mod & KMOD_CAPS) != 0);
        return static_cast<unsigned>(upper ? k - 32 : k);
    }
    if (k >= 0x20 && k < 0x7F) return static_cast<unsigned>(k);
    return 0;
}

// The window frame's top-left on the screen: SDL places the client area, the
// desktop the frame around it.
static void klioSdlTopLeft(KlioWindow* kw, int* x, int* y) {
    SDL_GetWindowPosition(kw->win, x, y);
    int top = 0;
    int left = 0;
    if (SDL_GetWindowBordersSize(kw->win, &top, &left, nullptr, nullptr) == 0) {
        *x -= left;
        *y -= top;
    }
}

static void klioSdlReportFrame(KlioWindow* kw) {
    const Uint32 flags = SDL_GetWindowFlags(kw->win);
    int placement = KLIO_PLACEMENT_FLOATING;
    if ((flags & SDL_WINDOW_FULLSCREEN_DESKTOP) == SDL_WINDOW_FULLSCREEN_DESKTOP) placement = KLIO_PLACEMENT_FULLSCREEN;
    else if (flags & SDL_WINDOW_MAXIMIZED) placement = KLIO_PLACEMENT_MAXIMIZED;
    int x = 0;
    int y = 0;
    klioSdlTopLeft(kw, &x, &y);
    klioReportFrame(kw->frameReport, kw->events, x, y, placement, (flags & SDL_WINDOW_MINIMIZED) != 0);
}


// A menu bar's or a popup menu's state: its entries, the panels open, the
// hovered items, and where a chosen item goes. An SDL window's menu bar and a
// Linux tray's menu are both drawn from one.
struct KlioMenuUi {
    std::vector<KlioMenuEntry> entries;
    std::vector<KlioSdlMenuPanel> panels;  // the open menus, the outermost first
    std::unordered_map<int, sk_sp<SkImage>> icons;  // item icons by id
    int barH = 0;       // the bar's height; 0 for a popup menu
    int w = 0;          // the space the panels are kept in
    int h = 0;
    std::deque<KlioEv>* queue = nullptr;  // where KLIO_EV_MENU goes
    float anchorX = 0;  // a popup menu's place, for scripted choices
    float anchorY = 0;
    unsigned version = 0;  // counts the changes the bar and panels show
    std::deque<KlioEv>& events() { return *queue; }
};

static unsigned klioMenuVersion(const KlioMenuUi& ui) { return ui.version; }

// The menu bar an SDL window draws itself, as the desktop's Swing JMenuBar
// is drawn on Linux: the menus on a bar above the content, which the bar's
// height takes from the window's content area, a menu's items in a panel
// under it, and a submenu's in a panel beside its item. The panels take the
// mouse and the keys while one is open; F10 or Alt with a menu's mnemonic
// opens one. A chosen item is queued as KLIO_EV_MENU, as a native menu's is.
static const int KLIO_MENU_BAR_H = 24;
static const float KLIO_MENU_ITEM_H = 22.0f;
static const float KLIO_MENU_SEPARATOR_H = 9.0f;
static const float KLIO_MENU_TEXT_SIZE = 13.0f;
static const float KLIO_MENU_GUTTER = 24.0f;       // the check mark's or icon's column
static const float KLIO_MENU_BAR_PAD = 10.0f;
static const uint32_t KLIO_MENU_BAR_BG = 0xFFEEEEEE;
static const uint32_t KLIO_MENU_PANEL_BG = 0xFFFFFFFF;
static const uint32_t KLIO_MENU_BORDER = 0xFFB0B0B0;
static const uint32_t KLIO_MENU_TEXT = 0xFF1E1E1E;
static const uint32_t KLIO_MENU_DISABLED = 0xFF9A9A9A;
static const uint32_t KLIO_MENU_SHORTCUT = 0xFF6A6A6A;
static const uint32_t KLIO_MENU_SELECTED_BG = 0xFF3D7BD6;
static const uint32_t KLIO_MENU_SELECTED_TEXT = 0xFFFFFFFF;

// A sans typeface for menus when the system has one, else the bundled font.
static sk_sp<SkTypeface> klioMenuTypeface() {
    static sk_sp<SkTypeface> face;
    static bool tried = false;
    if (tried) return face;
    tried = true;
    ensureFonts();
    static const char* const kSans[] = {
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        nullptr,
    };
    if (g_fontMgr) {
        for (const SkString& name : familyAliases("sans-serif")) {
            if (face) break;
            face = g_fontMgr->matchFamilyStyle(name.c_str(), SkFontStyle::Normal());
        }
        for (int i = 0; !face && kSans[i]; i++) face = g_fontMgr->makeFromFile(kSans[i], 0);
    }
    if (!face) face = g_typeface;
    return face;
}

static SkFont klioMenuFont() {
    SkFont font(klioMenuTypeface(), KLIO_MENU_TEXT_SIZE);
    font.setEdging(SkFont::Edging::kAntiAlias);
    return font;
}

static float klioMenuTextWidth(const std::string& s) {
    if (s.empty()) return 0;
    SkFont font = klioMenuFont();
    return font.measureText(s.data(), s.size(), SkTextEncoding::kUTF8);
}

static void klioMenuDrawText(SkCanvas* c, const std::string& s, float x, float top, float h, uint32_t argb) {
    if (s.empty()) return;
    SkFont font = klioMenuFont();
    SkFontMetrics m;
    font.getMetrics(&m);
    const float baseline = top + (h - (m.fDescent - m.fAscent)) / 2 - m.fAscent;
    SkPaint p;
    p.setAntiAlias(true);
    p.setColor(argb);
    c->drawSimpleText(s.data(), s.size(), SkTextEncoding::kUTF8, x, baseline, font, p);
}

static void klioMenuFill(SkCanvas* c, float x, float y, float w, float h, uint32_t argb) {
    SkPaint p;
    p.setColor(argb);
    c->drawRect(SkRect::MakeXYWH(x, y, w, h), p);
}

// A shortcut as the desktop's Linux menus show it: "Ctrl+Shift+N".
static std::string klioMenuShortcutText(int vk, int mods) {
    if (vk == 0) return std::string();
    std::string t;
    if (mods & KLIO_MOD_META) t += "Meta+";
    if (mods & KLIO_MOD_CTRL) t += "Ctrl+";
    if (mods & KLIO_MOD_ALT) t += "Alt+";
    if (mods & KLIO_MOD_SHIFT) t += "Shift+";
    char buf[16];
    if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) {
        t += static_cast<char>(vk);
        return t;
    }
    if (vk >= 112 && vk <= 123) {
        std::snprintf(buf, sizeof buf, "F%d", vk - 111);
        return t + buf;
    }
    switch (vk) {
        case 10: return t + "Enter";
        case 8: return t + "Backspace";
        case 9: return t + "Tab";
        case 27: return t + "Escape";
        case 32: return t + "Space";
        case 127: return t + "Delete";
        case 37: return t + "Left";
        case 38: return t + "Up";
        case 39: return t + "Right";
        case 40: return t + "Down";
        case 36: return t + "Home";
        case 35: return t + "End";
        case 33: return t + "Page Up";
        case 34: return t + "Page Down";
        case 44: return t + "Comma";
        case 45: return t + "Minus";
        case 46: return t + "Period";
        case 47: return t + "Slash";
        case 59: return t + "Semicolon";
        case 61: return t + "Equals";
        default:
            std::snprintf(buf, sizeof buf, "0x%x", vk);
            return t + buf;
    }
}

// The direct children of the entry at `parent` (-1: the bar's menus).
static std::vector<int> klioMenuChildren(const std::vector<KlioMenuEntry>& entries, int parent) {
    std::vector<int> out;
    const int depth = parent < 0 ? 0 : entries[static_cast<size_t>(parent)].depth + 1;
    for (size_t i = static_cast<size_t>(parent + 1); i < entries.size(); i++) {
        if (entries[i].depth < depth) break;
        if (entries[i].depth == depth) out.push_back(static_cast<int>(i));
    }
    return out;
}

static float klioMenuBarItemX(KlioMenuUi& ui, int barIndex) {
    float x = 0;
    for (int i : klioMenuChildren(ui.entries, -1)) {
        if (i == barIndex) return x;
        x += klioMenuTextWidth(ui.entries[static_cast<size_t>(i)].text) + 2 * KLIO_MENU_BAR_PAD;
    }
    return x;
}

static float klioMenuItemHeight(const KlioMenuEntry& e) {
    return e.kind == 's' ? KLIO_MENU_SEPARATOR_H : KLIO_MENU_ITEM_H;
}

// Opens the panel listing the menu at `menu`, at depth `depth` (0: under the
// bar), placed at (x, y) and kept inside the window. A submenu that does not
// fit right of its parent opens left of it (ending at `leftOf`) when that
// fits, as Swing's do.
static void klioMenuOpen(KlioMenuUi& ui, size_t depth, int menu, float x, float y, float leftOf = -1) {
    ui.panels.resize(depth);
    KlioSdlMenuPanel panel;
    panel.menu = menu;
    panel.items = klioMenuChildren(ui.entries, menu);
    float textW = 0;
    float keyW = 0;
    float h = 2;
    for (int i : panel.items) {
        const KlioMenuEntry& e = ui.entries[static_cast<size_t>(i)];
        textW = std::max(textW, klioMenuTextWidth(e.text));
        keyW = std::max(keyW, klioMenuTextWidth(klioMenuShortcutText(e.keycode, e.mods)));
        h += klioMenuItemHeight(e);
    }
    panel.w = KLIO_MENU_GUTTER + textW + (keyW > 0 ? 24 + keyW : 0) + 28;
    panel.h = h;
    if (leftOf >= 0 && x + panel.w > ui.w && leftOf - panel.w >= 0) x = leftOf - panel.w;
    panel.x = std::max(0.0f, std::min(x, static_cast<float>(ui.w) - panel.w));
    panel.y = std::max(0.0f, std::min(y, static_cast<float>(ui.h) - panel.h));
    panel.hover = -1;
    ui.panels.push_back(panel);
    ui.version++;
}

static void klioMenuCloseAll(KlioMenuUi& ui) {
    if (ui.panels.empty()) return;
    ui.panels.clear();
    ui.version++;
}

// The top of a panel's item at `slot`.
static float klioMenuItemTop(KlioMenuUi& ui, const KlioSdlMenuPanel& p, size_t slot) {
    float y = p.y + 1;
    for (size_t k = 0; k < slot; k++) y += klioMenuItemHeight(ui.entries[static_cast<size_t>(p.items[k])]);
    return y;
}

// Whether the entry and every menu it is in can be chosen.
static bool klioMenuEnabled(KlioMenuUi& ui, int index) {
    const auto& entries = ui.entries;
    if (!entries[static_cast<size_t>(index)].enabled) return false;
    int depth = entries[static_cast<size_t>(index)].depth;
    for (int i = index - 1; i >= 0 && depth > 0; i--) {
        if (entries[static_cast<size_t>(i)].depth == depth - 1) {
            if (!entries[static_cast<size_t>(i)].enabled) return false;
            depth--;
        }
    }
    return true;
}

// Hovers the panel's item at `slot`, opening its submenu beside it.
static void klioMenuHover(KlioMenuUi& ui, size_t panel, int slot) {
    KlioSdlMenuPanel& p = ui.panels[panel];
    if (p.hover != slot || ui.panels.size() != panel + 1) ui.version++;
    p.hover = slot;
    ui.panels.resize(panel + 1);
    if (slot < 0) return;
    const int index = p.items[static_cast<size_t>(slot)];
    const KlioMenuEntry& e = ui.entries[static_cast<size_t>(index)];
    if (e.kind == 'm' && klioMenuEnabled(ui, index)) {
        const float top = klioMenuItemTop(ui, p, static_cast<size_t>(slot));
        klioMenuOpen(ui, panel + 1, index, p.x + p.w - 2, top - 1, p.x + 2);
    }
}

// Chooses an item: its id queued as KLIO_EV_MENU, the panels closed.
static void klioMenuChoose(KlioMenuUi& ui, int index) {
    const KlioMenuEntry& e = ui.entries[static_cast<size_t>(index)];
    if (e.kind == 'm' || e.kind == 's' || !klioMenuEnabled(ui, index)) return;
    klioMenuCloseAll(ui);
    ui.events().push_back(klioSimpleEv(KLIO_EV_MENU, e.id));
}

// The bar menu under x on the bar, or -1.
static int klioMenuBarHit(KlioMenuUi& ui, float x) {
    float left = 0;
    for (int i : klioMenuChildren(ui.entries, -1)) {
        const float w = klioMenuTextWidth(ui.entries[static_cast<size_t>(i)].text) + 2 * KLIO_MENU_BAR_PAD;
        if (x >= left && x < left + w) return i;
        left += w;
    }
    return -1;
}

static void klioMenuOpenBar(KlioMenuUi& ui, int barIndex) {
    if (!klioMenuEnabled(ui, barIndex)) return;
    klioMenuOpen(ui, 0, barIndex, klioMenuBarItemX(ui, barIndex), static_cast<float>(ui.barH));
}

// A mouse event on a window with a menu bar, in window coordinates: whether
// the menus took it.
static bool klioMenuPointer(KlioMenuUi& ui, int kind, float x, float y) {
    if (ui.barH == 0 && ui.panels.empty()) return false;
    // The panels, deepest first.
    for (size_t pi = ui.panels.size(); pi-- > 0;) {
        KlioSdlMenuPanel& p = ui.panels[pi];
        if (x < p.x || x >= p.x + p.w || y < p.y || y >= p.y + p.h) continue;
        int slot = -1;
        for (size_t k = 0; k < p.items.size(); k++) {
            const float top = klioMenuItemTop(ui, p, k);
            if (y >= top && y < top + klioMenuItemHeight(ui.entries[static_cast<size_t>(p.items[k])])) {
                slot = static_cast<int>(k);
                break;
            }
        }
        if (kind == KLIO_PTR_MOVE && slot != p.hover) klioMenuHover(ui, pi, slot);
        if (kind == KLIO_PTR_RELEASE && slot >= 0) klioMenuChoose(ui, p.items[static_cast<size_t>(slot)]);
        return true;
    }
    if (y < ui.barH) {
        const int hit = klioMenuBarHit(ui, x);
        const bool open = !ui.panels.empty();
        if (kind == KLIO_PTR_PRESS) {
            if (open && hit >= 0 && ui.panels[0].menu == hit) klioMenuCloseAll(ui);
            else if (hit >= 0) klioMenuOpenBar(ui, hit);
            else klioMenuCloseAll(ui);
        } else if (kind == KLIO_PTR_MOVE && open && hit >= 0 && ui.panels[0].menu != hit) {
            klioMenuOpenBar(ui, hit);
        }
        return true;
    }
    if (!ui.panels.empty()) {
        // A press outside the open menus closes them and goes no further.
        if (kind == KLIO_PTR_PRESS) klioMenuCloseAll(ui);
        return kind != KLIO_PTR_MOVE && kind != KLIO_PTR_ENTER && kind != KLIO_PTR_EXIT;
    }
    return false;
}

// Moves a panel's hover by `step` past separators.
static void klioMenuStep(KlioMenuUi& ui, size_t pi, int step) {
    KlioSdlMenuPanel& p = ui.panels[pi];
    const int n = static_cast<int>(p.items.size());
    if (n == 0) return;
    int slot = p.hover;
    for (int k = 0; k < n; k++) {
        slot = slot < 0 ? (step > 0 ? 0 : n - 1) : (slot + step + n) % n;
        if (ui.entries[static_cast<size_t>(p.items[static_cast<size_t>(slot)])].kind != 's') break;
    }
    p.hover = slot;
    ui.panels.resize(pi + 1);
}

// A key on a window with a menu bar: whether the menus took it.
static bool klioMenuKey(KlioMenuUi& ui, SDL_Keycode sym, Uint16 mod, bool down) {
    if (ui.barH == 0 && ui.panels.empty()) return false;
    // A popup menu has no bar to move along.
    const std::vector<int> bar = ui.barH > 0 ? klioMenuChildren(ui.entries, -1) : std::vector<int>();
    if (ui.panels.empty()) {
        if (!down) return false;
        if (sym == SDLK_F10 && bar.size() > 0) {
            klioMenuOpenBar(ui, bar[0]);
            return true;
        }
        if ((mod & KMOD_ALT) && sym < 128 && std::isalnum(static_cast<int>(sym))) {
            for (int i : bar) {
                const int m = ui.entries[static_cast<size_t>(i)].mnemonic;
                if (m > 0 && m < 128 && std::tolower(m) == std::tolower(static_cast<int>(sym))) {
                    klioMenuOpenBar(ui, i);
                    return true;
                }
            }
        }
        return false;
    }
    if (!down) return true;
    const size_t last = ui.panels.size() - 1;
    KlioSdlMenuPanel& p = ui.panels[last];
    auto barPos = [&]() {
        for (size_t k = 0; k < bar.size(); k++) {
            if (bar[k] == ui.panels[0].menu) return static_cast<int>(k);
        }
        return 0;
    };
    switch (sym) {
        case SDLK_ESCAPE:
            if (last > 0) ui.panels.resize(last);
            else klioMenuCloseAll(ui);
            return true;
        case SDLK_DOWN:
            klioMenuStep(ui, last, 1);
            return true;
        case SDLK_UP:
            klioMenuStep(ui, last, -1);
            return true;
        case SDLK_RIGHT:
            if (p.hover >= 0) {
                const int index = p.items[static_cast<size_t>(p.hover)];
                if (ui.entries[static_cast<size_t>(index)].kind == 'm') {
                    klioMenuHover(ui, last, p.hover);
                    if (ui.panels.size() > last + 1) klioMenuStep(ui, last + 1, 1);
                    return true;
                }
            }
            if (!bar.empty()) klioMenuOpenBar(ui, bar[static_cast<size_t>((barPos() + 1) % static_cast<int>(bar.size()))]);
            return true;
        case SDLK_LEFT:
            if (last > 0) ui.panels.resize(last);
            else if (!bar.empty()) klioMenuOpenBar(ui, bar[static_cast<size_t>((barPos() + static_cast<int>(bar.size()) - 1) % static_cast<int>(bar.size()))]);
            return true;
        case SDLK_RETURN:
        case SDLK_KP_ENTER:
        case SDLK_SPACE:
            if (p.hover >= 0) {
                const int index = p.items[static_cast<size_t>(p.hover)];
                if (ui.entries[static_cast<size_t>(index)].kind == 'm') {
                    klioMenuHover(ui, last, p.hover);
                    if (ui.panels.size() > last + 1) klioMenuStep(ui, last + 1, 1);
                } else {
                    klioMenuChoose(ui, index);
                }
            }
            return true;
        default:
            if (sym < 128 && std::isalnum(static_cast<int>(sym))) {
                for (size_t k = 0; k < p.items.size(); k++) {
                    const KlioMenuEntry& e = ui.entries[static_cast<size_t>(p.items[k])];
                    if (e.mnemonic > 0 && e.mnemonic < 128 && std::tolower(e.mnemonic) == std::tolower(static_cast<int>(sym))) {
                        if (e.kind == 'm') {
                            klioMenuHover(ui, last, static_cast<int>(k));
                        } else {
                            klioMenuChoose(ui, p.items[k]);
                        }
                        break;
                    }
                }
            }
            return true;
    }
}

// Draws the bar (when the UI has one) and the open panels, the canvas's
// origin at (ox, oy) of the UI's space.
static void klioMenuPaintOn(KlioMenuUi& ui, SkCanvas* c, float ox, float oy) {
    c->save();
    c->translate(-ox, -oy);
    if (ui.barH > 0) klioMenuFill(c, 0, static_cast<float>(ui.barH - 1), static_cast<float>(ui.w), 1, KLIO_MENU_BORDER);
    const int open = ui.panels.empty() ? -1 : ui.panels[0].menu;
    float x = 0;
    for (int i : (ui.barH > 0 ? klioMenuChildren(ui.entries, -1) : std::vector<int>())) {
        const KlioMenuEntry& e = ui.entries[static_cast<size_t>(i)];
        const float w = klioMenuTextWidth(e.text) + 2 * KLIO_MENU_BAR_PAD;
        const bool selected = i == open;
        if (selected) klioMenuFill(c, x, 0, w, static_cast<float>(ui.barH - 1), KLIO_MENU_SELECTED_BG);
        const uint32_t color = !klioMenuEnabled(ui, i) ? KLIO_MENU_DISABLED : selected ? KLIO_MENU_SELECTED_TEXT : KLIO_MENU_TEXT;
        klioMenuDrawText(c, e.text, x + KLIO_MENU_BAR_PAD, 0, static_cast<float>(ui.barH - 1), color);
        x += w;
    }
    for (const KlioSdlMenuPanel& p : ui.panels) {
        klioMenuFill(c, p.x, p.y, p.w, p.h, KLIO_MENU_BORDER);
        klioMenuFill(c, p.x + 1, p.y + 1, p.w - 2, p.h - 2, KLIO_MENU_PANEL_BG);
        for (size_t k = 0; k < p.items.size(); k++) {
            const int index = p.items[k];
            const KlioMenuEntry& e = ui.entries[static_cast<size_t>(index)];
            const float top = klioMenuItemTop(ui, p, k);
            if (e.kind == 's') {
                klioMenuFill(c, p.x + 4, top + KLIO_MENU_SEPARATOR_H / 2, p.w - 8, 1, 0xFFDDDDDD);
                continue;
            }
            const bool enabled = klioMenuEnabled(ui, index);
            const bool selected = static_cast<int>(k) == p.hover && enabled;
            if (selected) klioMenuFill(c, p.x + 1, top, p.w - 2, KLIO_MENU_ITEM_H, KLIO_MENU_SELECTED_BG);
            const uint32_t color = !enabled ? KLIO_MENU_DISABLED : selected ? KLIO_MENU_SELECTED_TEXT : KLIO_MENU_TEXT;
            auto icon = ui.icons.find(e.id);
            if (icon != ui.icons.end() && icon->second) {
                c->drawImageRect(icon->second, SkRect::MakeXYWH(p.x + 4, top + 3, 16, 16),
                                 SkSamplingOptions(SkFilterMode::kLinear));
            } else if ((e.kind == 'c' || e.kind == 'r') && e.state) {
                SkPaint mark;
                mark.setAntiAlias(true);
                mark.setColor(color);
                if (e.kind == 'r') {
                    c->drawCircle(p.x + 12, top + KLIO_MENU_ITEM_H / 2, 3.5f, mark);
                } else {
                    mark.setStyle(SkPaint::kStroke_Style);
                    mark.setStrokeWidth(1.8f);
                    SkPath check = SkPathBuilder()
                                       .moveTo(p.x + 7, top + 11)
                                       .lineTo(p.x + 11, top + 15)
                                       .lineTo(p.x + 17, top + 7)
                                       .detach();
                    c->drawPath(check, mark);
                }
            }
            klioMenuDrawText(c, e.text, p.x + KLIO_MENU_GUTTER, top, KLIO_MENU_ITEM_H, color);
            const std::string key = klioMenuShortcutText(e.keycode, e.mods);
            if (!key.empty()) {
                klioMenuDrawText(c, key, p.x + p.w - 12 - klioMenuTextWidth(key), top, KLIO_MENU_ITEM_H,
                                 selected ? KLIO_MENU_SELECTED_TEXT : enabled ? KLIO_MENU_SHORTCUT : KLIO_MENU_DISABLED);
            }
            if (e.kind == 'm') {
                SkPaint arrow;
                arrow.setAntiAlias(true);
                arrow.setColor(color);
                SkPath tri = SkPathBuilder()
                                 .moveTo(p.x + p.w - 12, top + 7)
                                 .lineTo(p.x + p.w - 8, top + KLIO_MENU_ITEM_H / 2)
                                 .lineTo(p.x + p.w - 12, top + KLIO_MENU_ITEM_H - 7)
                                 .close()
                                 .detach();
                c->drawPath(tri, arrow);
            }
        }
    }
    c->restore();
}

// Opens the menus along a path of titles, as clicks on them do, and chooses
// the item at its end unless `show` (then the menus are left open).
static void klioMenuPath(KlioMenuUi& ui, const std::string& path, bool show) {
    const int index = klioMenuFindPath(ui.entries, path);
    if (index < 0) return;
    // The menus the item is in, outermost first.
    std::vector<int> chain;
    int depth = ui.entries[static_cast<size_t>(index)].depth;
    for (int i = index - 1; i >= 0 && depth > 0; i--) {
        if (ui.entries[static_cast<size_t>(i)].depth == depth - 1) {
            chain.insert(chain.begin(), i);
            depth--;
        }
    }
    // A bar's menus open from the bar; a popup menu opens its root at its anchor.
    const bool bar = ui.barH > 0;
    const bool isBarMenu = bar && ui.entries[static_cast<size_t>(index)].depth == 0;
    if (isBarMenu) chain.push_back(index);
    size_t from = 0;
    if (bar) {
        if (chain.empty() || !klioMenuEnabled(ui, chain[0])) return;
        klioMenuOpenBar(ui, chain[0]);
        from = 1;
    } else {
        klioMenuOpen(ui, 0, -1, ui.anchorX, ui.anchorY);
    }
    for (size_t k = from; k < chain.size(); k++) {
        const size_t panel = bar ? k - 1 : k;
        KlioSdlMenuPanel& p = ui.panels[panel];
        for (size_t s = 0; s < p.items.size(); s++) {
            if (p.items[s] == chain[k]) {
                klioMenuHover(ui, panel, static_cast<int>(s));
                break;
            }
        }
        if (ui.panels.size() <= panel + 1) return;  // a disabled submenu does not open
    }
    if (isBarMenu) return;
    KlioSdlMenuPanel& last = ui.panels.back();
    for (size_t s = 0; s < last.items.size(); s++) {
        if (last.items[s] == index) last.hover = static_cast<int>(s);
    }
    if (!show) {
        if (klioMenuEnabled(ui, index)) klioMenuChoose(ui, index);
        else klioMenuCloseAll(ui);
    }
}

// The window's pixels: the bar, the content under it, and the open menus.
static void klioSdlPaintFrame(KlioWindow* kw) {
    if (!kw->frame || !kw->frame->surface || !kw->surface || !kw->surface->surface || !kw->menu) return;
    SkCanvas* c = kw->frame->surface->getCanvas();
    c->clear(KLIO_MENU_BAR_BG);
    kw->surface->surface->draw(c, 0, static_cast<float>(kw->barH));
    klioMenuPaintOn(*kw->menu, c, 0, 0);
}

// Translates one SDL event into the events of its window.
// The input method's composing text, while a text field has the keyboard; an
// empty one ends the composition.
static void klioSdlCompose(KlioWindow* kw, const char* text) {
    if (!kw->textInput || (kw->menu && !kw->menu->panels.empty())) return;
    if (!text[0] && !kw->composing) return;
    kw->composing = text[0] != 0;
    kw->events.push_back(klioImeEv("", text));
}

// Drops the input method's composition without committing it.
static void klioSdlClearComposition() {
#if SDL_VERSION_ATLEAST(2, 0, 22)
    SDL_ClearComposition();
#else
    SDL_StopTextInput();
    SDL_StartTextInput();
#endif
}

// Places the input method's candidate window at the window's text cursor.
static void klioSdlPlaceIme(KlioWindow* kw) {
    if (!kw->textInput || SDL_GetKeyboardFocus() != kw->win) return;
    SDL_Rect r = kw->imeRect;
    SDL_SetTextInputRect(&r);
}

static void klioSdlTranslate(KlioWindow* kw, const SDL_Event& ev) {
    switch (ev.type) {
        case SDL_WINDOWEVENT: {
            int mx = 0;
            int my = 0;
            switch (ev.window.event) {
                case SDL_WINDOWEVENT_CLOSE:
                    kw->events.push_back(klioSimpleEv(KLIO_EV_CLOSE));
                    return;
                case SDL_WINDOWEVENT_SIZE_CHANGED: {
                    const int nw = ev.window.data1;
                    const int nh = ev.window.data2;
                    if (nw > 0 && nh > 0 && (nw != kw->w || nh != kw->h)) {
                        klioSdlSizeTo(kw, nw, nh);
                        if (kw->menu) {
                            klioMenuCloseAll(*kw->menu);
                            kw->menu->w = nw;
                            kw->menu->h = nh;
                        }
                        kw->events.push_back(klioSimpleEv(KLIO_EV_RESIZE, nw, nh - kw->barH));
                    }
                    return;
                }
                case SDL_WINDOWEVENT_ENTER:
                    SDL_GetMouseState(&mx, &my);
                    kw->events.push_back(klioPointerEv(KLIO_PTR_ENTER, mx, my - kw->barH, KLIO_BTN_NONE, kw->buttons,
                                                       klioSdlMods(SDL_GetModState())));
                    return;
                case SDL_WINDOWEVENT_LEAVE:
                    SDL_GetMouseState(&mx, &my);
                    kw->events.push_back(klioPointerEv(KLIO_PTR_EXIT, mx, my - kw->barH, KLIO_BTN_NONE, kw->buttons,
                                                       klioSdlMods(SDL_GetModState())));
                    return;
                case SDL_WINDOWEVENT_FOCUS_GAINED:
                    if (!klioScriptDrivesFocus()) kw->events.push_back(klioSimpleEv(KLIO_EV_FOCUS, 1));
                    klioSdlPlaceIme(kw);
                    return;
                case SDL_WINDOWEVENT_FOCUS_LOST:
                    if (!klioScriptDrivesFocus()) kw->events.push_back(klioSimpleEv(KLIO_EV_FOCUS, 0));
                    return;
                case SDL_WINDOWEVENT_MOVED:
                case SDL_WINDOWEVENT_MINIMIZED:
                case SDL_WINDOWEVENT_MAXIMIZED:
                case SDL_WINDOWEVENT_RESTORED:
                    klioSdlReportFrame(kw);
                    return;
                default:
                    return;
            }
        }
        case SDL_MOUSEBUTTONDOWN:
        case SDL_MOUSEBUTTONUP: {
            const int button = klioSdlButton(ev.button.button);
            if (button == KLIO_BTN_NONE) return;
            const bool down = ev.type == SDL_MOUSEBUTTONDOWN;
            if (kw->buttons == 0 || !down) {
                if (kw->menu && klioMenuPointer(*kw->menu, down ? KLIO_PTR_PRESS : KLIO_PTR_RELEASE, ev.button.x, ev.button.y)) return;
            }
            if (down) {
                kw->buttons |= 1 << (button - 1);
            } else {
                if (!(kw->buttons & (1 << (button - 1)))) return;
                kw->buttons &= ~(1 << (button - 1));
            }
            // A drag goes on outside the window until its buttons are released.
            SDL_CaptureMouse(kw->buttons != 0 ? SDL_TRUE : SDL_FALSE);
            kw->events.push_back(klioPointerEv(down ? KLIO_PTR_PRESS : KLIO_PTR_RELEASE, ev.button.x,
                                               ev.button.y - kw->barH, button, kw->buttons,
                                               klioSdlMods(SDL_GetModState())));
            return;
        }
        case SDL_MOUSEMOTION:
            if (kw->buttons == 0 && kw->menu && klioMenuPointer(*kw->menu, KLIO_PTR_MOVE, ev.motion.x, ev.motion.y)) return;
            kw->events.push_back(klioPointerEv(KLIO_PTR_MOVE, ev.motion.x, ev.motion.y - kw->barH, KLIO_BTN_NONE,
                                               kw->buttons, klioSdlMods(SDL_GetModState())));
            return;
        case SDL_MOUSEWHEEL: {
            int mx = 0;
            int my = 0;
            SDL_GetMouseState(&mx, &my);
            // AWT's wheel rotation is positive away from the user; SDL's is not.
            const double flip = ev.wheel.direction == SDL_MOUSEWHEEL_FLIPPED ? -1.0 : 1.0;
            if ((kw->menu && !kw->menu->panels.empty()) || my < kw->barH) return;
            kw->events.push_back(klioPointerEv(KLIO_PTR_SCROLL, mx, my - kw->barH, KLIO_BTN_NONE, kw->buttons,
                                               klioSdlMods(SDL_GetModState()),
                                               flip * ev.wheel.preciseX, -flip * ev.wheel.preciseY));
            return;
        }
        case SDL_KEYDOWN:
        case SDL_KEYUP: {
            if (kw->menu && klioMenuKey(*kw->menu, ev.key.keysym.sym, ev.key.keysym.mod, ev.type == SDL_KEYDOWN)) return;
            int vk = 0;
            int loc = KLIO_LOC_STANDARD;
            klioSdlKey(ev.key.keysym.sym, &vk, &loc);
            const unsigned c = klioSdlKeyChar(ev.key.keysym.sym, ev.key.keysym.mod);
            kw->events.push_back(klioKeyEv(ev.type == SDL_KEYDOWN, vk, loc, klioAwtKeyChar(vk, c),
                                           klioSdlMods(ev.key.keysym.mod)));
            return;
        }
        case SDL_TEXTINPUT:
            if (kw->menu && !kw->menu->panels.empty()) return;
            // The end of a composition is the input method's commit; other
            // text is what the keys typed.
            if (kw->composing) {
                kw->composing = false;
                kw->events.push_back(klioImeEv(ev.text.text, ""));
                return;
            }
            klioPushText(kw->events, ev.text.text);
            return;
        case SDL_TEXTEDITING:
            klioSdlCompose(kw, ev.edit.text);
            return;
#if SDL_VERSION_ATLEAST(2, 0, 22)
        case SDL_TEXTEDITING_EXT:
            klioSdlCompose(kw, ev.editExt.text);
            SDL_free(ev.editExt.text);
            return;
#endif
        default:
            return;
    }
}

// Waits up to timeoutMs for the window's next input event and writes its
// values to out (KLIO_EV_VALUES doubles); returns its type (window_events.h),
// or KLIO_EV_NONE when none came. SDL's queue is the process's: an event for
// another window is translated onto that window's queue.
int klio_win_poll_event(KlioWindow* kw, int timeoutMs, double* out) {
    if (!kw) return KLIO_EV_CLOSE;
    klioScriptTick(kw->script, kw->events);
    if (!kw->frameReport.reported) klioSdlReportFrame(kw);
    int wait = timeoutMs;
    while (kw->events.empty()) {
        SDL_Event ev;
        const int got = wait > 0 ? SDL_WaitEventTimeout(&ev, wait) : SDL_PollEvent(&ev);
        wait = 0;
        if (!got) break;
        if (ev.type == SDL_QUIT) {
            kw->events.push_back(klioSimpleEv(KLIO_EV_CLOSE));
            break;
        }
        Uint32 wid;
        switch (ev.type) {
            case SDL_WINDOWEVENT: wid = ev.window.windowID; break;
            case SDL_MOUSEBUTTONDOWN:
            case SDL_MOUSEBUTTONUP: wid = ev.button.windowID; break;
            case SDL_MOUSEMOTION: wid = ev.motion.windowID; break;
            case SDL_MOUSEWHEEL: wid = ev.wheel.windowID; break;
            case SDL_TEXTINPUT: wid = ev.text.windowID; break;
            case SDL_TEXTEDITING: wid = ev.edit.windowID; break;
#if SDL_VERSION_ATLEAST(2, 0, 22)
            case SDL_TEXTEDITING_EXT: wid = ev.editExt.windowID; break;
#endif
            case SDL_KEYDOWN:
            case SDL_KEYUP: wid = ev.key.windowID; break;
            default: wid = kw->id; break;
        }
        auto it = klioSdlWindows().find(wid);
        if (it == klioSdlWindows().end()) continue;  // a closed window's straggler
        klioSdlTranslate(it->second, ev);
    }
    for (;;) {
        const int type = klioPopEv(kw->events, out, &kw->eventText);
        if (type != KLIO_EV_MENU_PATH) {
            klioSdlShowMenus();
            return type;
        }
        const size_t at = static_cast<size_t>(out[0]);
        if (at >= klioScriptTexts().size()) continue;
        if (kw->menu) klioMenuPath(*kw->menu, klioScriptTexts()[at], out[1] != 0);
    }
}

// A text field has the keyboard, or none has: while one has it the input
// method composes into it. SDL's text input, which delivers the characters
// keys type, stays on either way.
void klio_win_set_text_input(KlioWindow* kw, int enabled) {
    if (!kw) return;
    kw->textInput = enabled != 0;
    if (kw->textInput) {
        klioSdlPlaceIme(kw);
    } else if (kw->composing) {
        kw->composing = false;
        klioSdlClearComposition();
    }
}

// The text field's cursor, in the window's content, where the input method
// places its candidate window.
void klio_win_set_text_input_rect(KlioWindow* kw, int x, int y, int w, int h) {
    if (!kw) return;
    kw->imeRect = {x, y + kw->barH, w, h};
    klioSdlPlaceIme(kw);
}

// The text field ended the composition itself: the input method drops it.
void klio_win_end_composition(KlioWindow* kw) {
    if (!kw || !kw->composing) return;
    kw->composing = false;
    klioSdlClearComposition();
}

// The text of the event klio_win_poll_event last returned.
size_t klio_win_event_text(KlioWindow* kw, char* buf, size_t cap) {
    return kw ? klioCopyEventText(kw->eventText, buf, cap) : 0;
}

// Only macOS has an emoji and symbols palette to open.
void klio_order_emoji_palette(void) {}

// A window's menu bar: SDL has no native menus, so the window draws the bar
// and its menus itself, and the bar's height comes out of the content, whose
// new size is reported as a resize.
void klio_win_set_menu(KlioWindow* kw, const char* spec, size_t len) {
    if (!kw) return;
    if (!kw->menu) {
        kw->menu = new KlioMenuUi();
        kw->menu->queue = &kw->events;
    }
    KlioMenuUi& ui = *kw->menu;
    ui.entries = klioParseMenu(spec, len);
    ui.version++;
    klioDumpMenuEntries(ui.entries);
    // Open menus close: the new entries may have moved their items.
    klioMenuCloseAll(ui);
    const int barH = ui.entries.empty() ? 0 : KLIO_MENU_BAR_H;
    for (auto it = ui.icons.begin(); it != ui.icons.end();) {
        bool kept = false;
        for (const KlioMenuEntry& e : ui.entries) kept = kept || e.id == it->first;
        it = kept ? std::next(it) : ui.icons.erase(it);
    }
    ui.w = kw->w;
    ui.h = kw->h;
    if (barH == kw->barH) return;
#if defined(KLIO_GPU)
    if (kw->gpu) {
        static bool told = false;
        if (!told) {
            std::fprintf(stderr, "klio: a MenuBar is not drawn in a GPU SDL window; build the Skia shim without -Dgpu to show it\n");
            told = true;
        }
        return;
    }
#endif
    kw->barH = barH;
    ui.barH = barH;
    klioSdlSizeTo(kw, kw->w, kw->h);
    kw->events.push_back(klioSimpleEv(KLIO_EV_RESIZE, kw->w, kw->h - kw->barH));
}

void klio_win_set_menu_icon(KlioWindow* kw, int id, KlioSurface* s) {
    if (!kw || !kw->menu || !s || !s->surface) return;
    kw->menu->icons[id] = s->surface->makeImageSnapshot();
}

#if defined(KLIO_X11_TRAY)
// The Linux tray icon, as the desktop's AWT puts one on X11: an XEmbed icon
// window docked in the system tray (the _NET_SYSTEM_TRAY_S<screen> selection's
// owner), a left click its action, a right press its popup menu, a tooltip
// after a pause over it, and a notification as a balloon by it. There is a
// tray only while some tray manager owns the selection, as AWT's
// SystemTray.isSupported answers. libX11 is loaded when a tray is first
// asked for, so a host without X11 runs without it.
struct KlioX11 {
    void* lib = nullptr;
    Display* (*OpenDisplay)(const char*);
    int (*DefaultScreen_)(Display*);
    Window (*RootWindow_)(Display*, int);
    Atom (*InternAtom)(Display*, const char*, Bool);
    Window (*GetSelectionOwner)(Display*, Atom);
    Window (*CreateWindow)(Display*, Window, int, int, unsigned, unsigned, unsigned, int, unsigned, Visual*,
                           unsigned long, XSetWindowAttributes*);
    int (*DestroyWindow)(Display*, Window);
    int (*MapRaised)(Display*, Window);
    int (*MapWindow)(Display*, Window);
    int (*UnmapWindow)(Display*, Window);
    int (*MoveResizeWindow)(Display*, Window, int, int, unsigned, unsigned);
    int (*SelectInput)(Display*, Window, long);
    int (*ChangeProperty)(Display*, Window, Atom, Atom, int, int, const unsigned char*, int);
    Status (*SendEvent)(Display*, Window, Bool, long, XEvent*);
    int (*Flush)(Display*);
    int (*Pending)(Display*);
    int (*NextEvent)(Display*, XEvent*);
    XImage* (*CreateImage)(Display*, Visual*, unsigned, int, int, char*, unsigned, unsigned, int, int);
    int (*PutImage)(Display*, Drawable, GC, XImage*, int, int, int, int, unsigned, unsigned);
    GC (*CreateGC)(Display*, Drawable, unsigned long, XGCValues*);
    int (*FreeGC)(Display*, GC);
    int (*GrabPointer)(Display*, Window, Bool, unsigned, int, int, Window, Cursor, Time);
    int (*UngrabPointer)(Display*, Time);
    int (*GrabKeyboard)(Display*, Window, Bool, int, int, Time);
    int (*UngrabKeyboard)(Display*, Time);
    Status (*MatchVisualInfo)(Display*, int, int, int, XVisualInfo*);
    Colormap (*CreateColormap)(Display*, Window, Visual*, int);
    Visual* (*DefaultVisual_)(Display*, int);
    int (*DefaultDepth_)(Display*, int);
    Bool (*QueryPointer)(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned*);
    int (*GetWindowProperty)(Display*, Window, Atom, long, long, Bool, Atom, Atom*, int*, unsigned long*,
                             unsigned long*, unsigned char**);
    int (*Free)(void*);
    int (*ConnectionNumber_)(Display*);
    KeySym (*LookupKeysym)(XKeyEvent*, int);
    int (*DisplayWidth_)(Display*, int);
    int (*DisplayHeight_)(Display*, int);
    Bool (*TranslateCoordinates)(Display*, Window, Window, int, int, int*, int*, Window*);
    void (*SetWMNormalHints)(Display*, Window, XSizeHints*);
};

static KlioX11* klioX11() {
    static KlioX11 x;
    static int state = 0;  // 0 untried, 1 loaded, -1 unavailable
    if (state == 1) return &x;
    if (state == -1) return nullptr;
    state = -1;
    x.lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
    if (!x.lib) return nullptr;
    bool ok = true;
    auto get = [&](auto& fn, const char* name) {
        fn = reinterpret_cast<std::remove_reference_t<decltype(fn)>>(dlsym(x.lib, name));
        if (!fn) ok = false;
    };
    get(x.OpenDisplay, "XOpenDisplay");
    get(x.DefaultScreen_, "XDefaultScreen");
    get(x.RootWindow_, "XRootWindow");
    get(x.InternAtom, "XInternAtom");
    get(x.GetSelectionOwner, "XGetSelectionOwner");
    get(x.CreateWindow, "XCreateWindow");
    get(x.DestroyWindow, "XDestroyWindow");
    get(x.MapRaised, "XMapRaised");
    get(x.MapWindow, "XMapWindow");
    get(x.UnmapWindow, "XUnmapWindow");
    get(x.MoveResizeWindow, "XMoveResizeWindow");
    get(x.SelectInput, "XSelectInput");
    get(x.ChangeProperty, "XChangeProperty");
    get(x.SendEvent, "XSendEvent");
    get(x.Flush, "XFlush");
    get(x.Pending, "XPending");
    get(x.NextEvent, "XNextEvent");
    get(x.CreateImage, "XCreateImage");
    get(x.PutImage, "XPutImage");
    get(x.CreateGC, "XCreateGC");
    get(x.FreeGC, "XFreeGC");
    get(x.GrabPointer, "XGrabPointer");
    get(x.UngrabPointer, "XUngrabPointer");
    get(x.GrabKeyboard, "XGrabKeyboard");
    get(x.UngrabKeyboard, "XUngrabKeyboard");
    get(x.MatchVisualInfo, "XMatchVisualInfo");
    get(x.CreateColormap, "XCreateColormap");
    get(x.DefaultVisual_, "XDefaultVisual");
    get(x.DefaultDepth_, "XDefaultDepth");
    get(x.QueryPointer, "XQueryPointer");
    get(x.GetWindowProperty, "XGetWindowProperty");
    get(x.Free, "XFree");
    get(x.ConnectionNumber_, "XConnectionNumber");
    get(x.LookupKeysym, "XLookupKeysym");
    get(x.DisplayWidth_, "XDisplayWidth");
    get(x.DisplayHeight_, "XDisplayHeight");
    get(x.TranslateCoordinates, "XTranslateCoordinates");
    get(x.SetWMNormalHints, "XSetWMNormalHints");
    if (!ok) return nullptr;
    state = 1;
    return &x;
}

// The one X connection the trays share, opened when first asked for.
static Display* klioX11Display() {
    static Display* dpy = nullptr;
    static bool tried = false;
    if (tried) return dpy;
    tried = true;
    KlioX11* x = klioX11();
    if (x && std::getenv("DISPLAY")) dpy = x->OpenDisplay(nullptr);
    return dpy;
}

static Window klioX11TrayManager(Display* dpy) {
    KlioX11* x = klioX11();
    char name[64];
    std::snprintf(name, sizeof name, "_NET_SYSTEM_TRAY_S%d", x->DefaultScreen_(dpy));
    return x->GetSelectionOwner(dpy, x->InternAtom(dpy, name, False));
}

// A window drawn from a Skia raster surface: the tray icon, its menu, its
// tooltip and its balloon.
struct KlioX11Surface {
    Window win = 0;
    Visual* visual = nullptr;
    int depth = 24;
    int w = 0;
    int h = 0;
};

static void klioX11Show(KlioX11Surface& s, SkSurface* pixels, uint32_t under) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy || !s.win || !pixels) return;
    const int w = pixels->width();
    const int h = pixels->height();
    // X wants its own copy: BGRA, premultiplied with a 32-bit visual, flattened
    // over `under` without one.
    char* data = static_cast<char*>(std::malloc(static_cast<size_t>(w) * static_cast<size_t>(h) * 4));
    if (!data) return;
    SkImageInfo info = SkImageInfo::Make(w, h, kBGRA_8888_SkColorType, kPremul_SkAlphaType);
    if (s.depth != 32) {
        sk_sp<SkSurface> flat = SkSurfaces::Raster(info);
        flat->getCanvas()->clear(under);
        pixels->draw(flat->getCanvas(), 0, 0);
        flat->readPixels(info, data, static_cast<size_t>(w) * 4, 0, 0);
    } else {
        pixels->readPixels(info, data, static_cast<size_t>(w) * 4, 0, 0);
    }
    XImage* image = x->CreateImage(dpy, s.visual, static_cast<unsigned>(s.depth), ZPixmap, 0, data,
                                   static_cast<unsigned>(w), static_cast<unsigned>(h), 32, w * 4);
    if (!image) {
        std::free(data);
        return;
    }
    GC gc = x->CreateGC(dpy, s.win, 0, nullptr);
    x->PutImage(dpy, s.win, gc, image, 0, 0, 0, 0, static_cast<unsigned>(w), static_cast<unsigned>(h));
    x->FreeGC(dpy, gc);
    image->f.destroy_image(image);  // frees `data` with it
    x->Flush(dpy);
}

// An override-redirect window (a menu, a tooltip, a balloon) at (px, py).
static void klioX11Popup(KlioX11Surface& s, int px, int py, int w, int h) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy) return;
    if (!s.win) {
        const int screen = x->DefaultScreen_(dpy);
        XSetWindowAttributes a = {};
        a.override_redirect = True;
        a.event_mask = ExposureMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | KeyPressMask;
        s.visual = x->DefaultVisual_(dpy, screen);
        s.depth = x->DefaultDepth_(dpy, screen);
        s.win = x->CreateWindow(dpy, x->RootWindow_(dpy, screen), px, py, static_cast<unsigned>(std::max(1, w)),
                                static_cast<unsigned>(std::max(1, h)), 0, CopyFromParent, InputOutput,
                                CopyFromParent, CWOverrideRedirect | CWEventMask, &a);
    }
    x->MoveResizeWindow(dpy, s.win, px, py, static_cast<unsigned>(std::max(1, w)), static_cast<unsigned>(std::max(1, h)));
    x->MapRaised(dpy, s.win);
    s.w = w;
    s.h = h;
}

static void klioX11Hide(KlioX11Surface& s) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy || !s.win) return;
    x->UnmapWindow(dpy, s.win);
    x->Flush(dpy);
}

static void klioX11Destroy(KlioX11Surface& s) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy || !s.win) return;
    x->DestroyWindow(dpy, s.win);
    x->Flush(dpy);
    s.win = 0;
}

struct KlioTray {
    KlioX11Surface icon;
    KlioX11Surface menuWin;
    KlioX11Surface tipWin;
    KlioX11Surface balloonWin;
    sk_sp<SkImage> image;
    std::string tooltip;
    KlioMenuUi menu;
    std::deque<KlioEv> events;
    KlioScriptState script;
    bool hovering = false;
    std::chrono::steady_clock::time_point hoverSince;
    bool tipShown = false;
    std::chrono::steady_clock::time_point balloonUntil;
    bool balloonShown = false;
    float menuX = 0;  // the menu window's origin in the screen, the panels' space
    float menuY = 0;
};

static std::vector<KlioTray*>& klioTrays() {
    static std::vector<KlioTray*> trays;
    return trays;
}

static const uint32_t KLIO_TRAY_UNDER = 0xFFD8D8D8;
static const int KLIO_TRAY_ICON_SIZE = 24;

static void klioTrayDrawIcon(KlioTray* t) {
    if (!t->icon.win || t->icon.w <= 0 || t->icon.h <= 0) return;
    sk_sp<SkSurface> s = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(t->icon.w, t->icon.h));
    if (!s) return;
    s->getCanvas()->clear(SK_ColorTRANSPARENT);
    if (t->image) {
        s->getCanvas()->drawImageRect(t->image, SkRect::MakeWH(t->icon.w, t->icon.h),
                                      SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear));
    }
    klioX11Show(t->icon, s.get(), KLIO_TRAY_UNDER);
}

// The popup menu's window: the union of the open panels, redrawn.
static void klioTrayShowMenu(KlioTray* t) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy) return;
    if (t->menu.panels.empty()) {
        if (t->menuWin.win) {
            x->UngrabPointer(dpy, CurrentTime);
            x->UngrabKeyboard(dpy, CurrentTime);
            klioX11Hide(t->menuWin);
        }
        return;
    }
    float l = 1e9f, tp = 1e9f, r = -1e9f, b = -1e9f;
    for (const KlioSdlMenuPanel& p : t->menu.panels) {
        l = std::min(l, p.x);
        tp = std::min(tp, p.y);
        r = std::max(r, p.x + p.w);
        b = std::max(b, p.y + p.h);
    }
    const int w = static_cast<int>(std::ceil(r - l));
    const int h = static_cast<int>(std::ceil(b - tp));
    const bool fresh = !t->menuWin.win;
    klioX11Popup(t->menuWin, static_cast<int>(l), static_cast<int>(tp), w, h);
    t->menuX = l;
    t->menuY = tp;
    sk_sp<SkSurface> s = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(w, h));
    if (!s) return;
    s->getCanvas()->clear(SK_ColorTRANSPARENT);
    klioMenuPaintOn(t->menu, s->getCanvas(), l, tp);
    klioX11Show(t->menuWin, s.get(), KLIO_MENU_PANEL_BG);
    if (fresh || true) {
        x->GrabPointer(dpy, t->menuWin.win, True, ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                       GrabModeAsync, GrabModeAsync, None, None, CurrentTime);
        x->GrabKeyboard(dpy, t->menuWin.win, True, GrabModeAsync, GrabModeAsync, CurrentTime);
    }
}

// A text box by the given point: the tooltip, or a balloon's title and message.
static void klioTrayShowText(KlioX11Surface& win, int px, int py, const std::string& title, const std::string& text,
                             uint32_t bg) {
    const float pad = 6;
    const float tw = std::max(klioMenuTextWidth(title), klioMenuTextWidth(text));
    const int lines = title.empty() ? 1 : 2;
    const int w = static_cast<int>(tw + 2 * pad) + 1;
    const int h = static_cast<int>(lines * 18 + 2 * pad - 4);
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy) return;
    const int screen = x->DefaultScreen_(dpy);
    const int sw = x->DisplayWidth_(dpy, screen);
    const int sh = x->DisplayHeight_(dpy, screen);
    const int ox = std::max(0, std::min(px, sw - w));
    const int oy = std::max(0, std::min(py, sh - h));
    klioX11Popup(win, ox, oy, w, h);
    sk_sp<SkSurface> s = SkSurfaces::Raster(SkImageInfo::MakeN32Premul(w, h));
    if (!s) return;
    SkCanvas* c = s->getCanvas();
    c->clear(KLIO_MENU_BORDER);
    klioMenuFill(c, 1, 1, static_cast<float>(w - 2), static_cast<float>(h - 2), bg);
    float top = pad - 2;
    if (!title.empty()) {
        klioMenuDrawText(c, title, pad, top, 18, KLIO_MENU_TEXT);
        top += 18;
    }
    klioMenuDrawText(c, text, pad, top, 18, KLIO_MENU_TEXT);
    klioX11Show(win, s.get(), bg);
}

// The icon's top-left and size on the screen.
static void klioTrayIconRect(KlioTray* t, int* rx, int* ry) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    *rx = 0;
    *ry = 0;
    if (!x || !dpy || !t->icon.win) return;
    Window child;
    x->TranslateCoordinates(dpy, t->icon.win, x->RootWindow_(dpy, x->DefaultScreen_(dpy)), 0, 0, rx, ry, &child);
}

static void klioTrayOpenMenuAt(KlioTray* t, int rx, int ry) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy || t->menu.entries.empty()) return;
    const int screen = x->DefaultScreen_(dpy);
    t->menu.w = x->DisplayWidth_(dpy, screen);
    t->menu.h = x->DisplayHeight_(dpy, screen);
    t->menu.anchorX = static_cast<float>(rx);
    t->menu.anchorY = static_cast<float>(ry);
    klioMenuOpen(t->menu, 0, -1, static_cast<float>(rx), static_cast<float>(ry));
}

static SDL_Keycode klioX11KeyToSdl(KeySym k) {
    switch (k) {
        case XK_Escape: return SDLK_ESCAPE;
        case XK_Up: return SDLK_UP;
        case XK_Down: return SDLK_DOWN;
        case XK_Left: return SDLK_LEFT;
        case XK_Right: return SDLK_RIGHT;
        case XK_Return: return SDLK_RETURN;
        case XK_KP_Enter: return SDLK_KP_ENTER;
        case XK_space: return SDLK_SPACE;
        default:
            if (k < 128) return static_cast<SDL_Keycode>(std::tolower(static_cast<int>(k)));
            return SDLK_UNKNOWN;
    }
}

// Runs the X events of the trays' windows.
static void klioTrayPump() {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy) return;
    while (x->Pending(dpy)) {
        XEvent ev;
        x->NextEvent(dpy, &ev);
        for (KlioTray* t : klioTrays()) {
            const Window w = ev.xany.window;
            if (w == t->icon.win) {
                switch (ev.type) {
                    case Expose:
                        klioTrayDrawIcon(t);
                        break;
                    case ConfigureNotify:
                        if (ev.xconfigure.width != t->icon.w || ev.xconfigure.height != t->icon.h) {
                            t->icon.w = ev.xconfigure.width;
                            t->icon.h = ev.xconfigure.height;
                            klioTrayDrawIcon(t);
                        }
                        break;
                    case EnterNotify:
                        t->hovering = true;
                        t->hoverSince = std::chrono::steady_clock::now();
                        break;
                    case LeaveNotify:
                        t->hovering = false;
                        if (t->tipShown) klioX11Hide(t->tipWin);
                        t->tipShown = false;
                        break;
                    case ButtonPress:
                        t->hovering = false;
                        if (t->tipShown) klioX11Hide(t->tipWin);
                        t->tipShown = false;
                        if (ev.xbutton.button == Button3) {
                            klioTrayOpenMenuAt(t, ev.xbutton.x_root, ev.xbutton.y_root);
                            klioTrayShowMenu(t);
                        }
                        break;
                    case ButtonRelease:
                        // A click of the first button is the tray's action.
                        if (ev.xbutton.button == Button1 && ev.xbutton.x >= 0 && ev.xbutton.y >= 0 &&
                            ev.xbutton.x < t->icon.w && ev.xbutton.y < t->icon.h) {
                            t->events.push_back(klioSimpleEv(KLIO_EV_TRAY_ACTION));
                        }
                        break;
                }
            } else if (w == t->menuWin.win) {
                const float mx = static_cast<float>(ev.type == MotionNotify ? ev.xmotion.x_root : ev.xbutton.x_root);
                const float my = static_cast<float>(ev.type == MotionNotify ? ev.xmotion.y_root : ev.xbutton.y_root);
                switch (ev.type) {
                    case MotionNotify:
                        klioMenuPointer(t->menu, KLIO_PTR_MOVE, mx, my);
                        klioTrayShowMenu(t);
                        break;
                    case ButtonPress:
                        klioMenuPointer(t->menu, KLIO_PTR_PRESS, mx, my);
                        klioTrayShowMenu(t);
                        break;
                    case ButtonRelease:
                        klioMenuPointer(t->menu, KLIO_PTR_RELEASE, mx, my);
                        klioTrayShowMenu(t);
                        break;
                    case KeyPress:
                        klioMenuKey(t->menu, klioX11KeyToSdl(x->LookupKeysym(&ev.xkey, 0)), 0, true);
                        klioTrayShowMenu(t);
                        break;
                    case Expose:
                        klioTrayShowMenu(t);
                        break;
                }
            } else if (w == t->balloonWin.win && ev.type == ButtonPress) {
                klioX11Hide(t->balloonWin);
                t->balloonShown = false;
            }
        }
    }
    // A pause over an icon shows its tooltip; a balloon goes after its time.
    const auto now = std::chrono::steady_clock::now();
    for (KlioTray* t : klioTrays()) {
        if (t->hovering && !t->tipShown && !t->tooltip.empty() &&
            now - t->hoverSince > std::chrono::milliseconds(750)) {
            Window root, child;
            int rx = 0, ry = 0, wx = 0, wy = 0;
            unsigned mask = 0;
            x->QueryPointer(dpy, t->icon.win, &root, &child, &rx, &ry, &wx, &wy, &mask);
            klioTrayShowText(t->tipWin, rx + 12, ry + 16, "", t->tooltip, 0xFFFFFFE1);
            t->tipShown = true;
        }
        if (t->balloonShown && now > t->balloonUntil) {
            klioX11Hide(t->balloonWin);
            t->balloonShown = false;
        }
    }
}

int klio_tray_supported(void) {
    Display* dpy = klioX11Display();
    return dpy && klioX11TrayManager(dpy) != 0 ? 1 : 0;
}

void* klio_tray_open(void) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy) return nullptr;
    const Window manager = klioX11TrayManager(dpy);
    if (!manager) return nullptr;
    const int screen = x->DefaultScreen_(dpy);
    auto* t = new KlioTray();
    t->menu.queue = &t->events;
    // The tray's own visual when it offers a 32-bit one, for the icon's alpha.
    Visual* visual = x->DefaultVisual_(dpy, screen);
    int depth = x->DefaultDepth_(dpy, screen);
    Colormap cmap = 0;
    Atom type = 0;
    int format = 0;
    unsigned long count = 0, after = 0;
    unsigned char* data = nullptr;
    const Atom visualAtom = x->InternAtom(dpy, "_NET_SYSTEM_TRAY_VISUAL", False);
    if (x->GetWindowProperty(dpy, manager, visualAtom, 0, 1, False, XA_VISUALID, &type, &format, &count, &after,
                             &data) == Success && data && count == 1) {
        const VisualID id = static_cast<VisualID>(*reinterpret_cast<unsigned long*>(data));
        XVisualInfo vi;
        if (x->MatchVisualInfo(dpy, screen, 32, TrueColor, &vi) && vi.visualid == id) {
            visual = vi.visual;
            depth = 32;
        }
    }
    if (data) x->Free(data);
    XSetWindowAttributes a = {};
    unsigned long mask = CWEventMask | CWBorderPixel;
    a.event_mask = ExposureMask | ButtonPressMask | ButtonReleaseMask | EnterWindowMask | LeaveWindowMask |
                   StructureNotifyMask;
    a.border_pixel = 0;
    if (depth == 32) {
        cmap = x->CreateColormap(dpy, x->RootWindow_(dpy, screen), visual, AllocNone);
        a.colormap = cmap;
        a.background_pixel = 0;
        mask |= CWColormap | CWBackPixel;
    } else {
        a.background_pixmap = ParentRelative;
        mask |= CWBackPixmap;
    }
    t->icon.visual = visual;
    t->icon.depth = depth;
    // AWT's X11 tray icon size. A tray host sizes the icon from its size
    // hints (GtkSocket-based ones give an icon without them one pixel).
    t->icon.w = KLIO_TRAY_ICON_SIZE;
    t->icon.h = KLIO_TRAY_ICON_SIZE;
    t->icon.win = x->CreateWindow(dpy, x->RootWindow_(dpy, screen), 0, 0, KLIO_TRAY_ICON_SIZE,
                                  KLIO_TRAY_ICON_SIZE, 0, depth, InputOutput, visual, mask, &a);
    XSizeHints hints = {};
    hints.flags = PMinSize | PBaseSize;
    hints.min_width = hints.base_width = KLIO_TRAY_ICON_SIZE;
    hints.min_height = hints.base_height = KLIO_TRAY_ICON_SIZE;
    x->SetWMNormalHints(dpy, t->icon.win, &hints);
    // XEmbed: version 0, mapped.
    const long info[2] = {0, 1};
    const Atom xembed = x->InternAtom(dpy, "_XEMBED_INFO", False);
    x->ChangeProperty(dpy, t->icon.win, xembed, xembed, 32, PropModeReplace,
                      reinterpret_cast<const unsigned char*>(info), 2);
    // Ask the tray to dock it.
    XEvent ev = {};
    ev.xclient.type = ClientMessage;
    ev.xclient.window = manager;
    ev.xclient.message_type = x->InternAtom(dpy, "_NET_SYSTEM_TRAY_OPCODE", False);
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = CurrentTime;
    ev.xclient.data.l[1] = 0;  // SYSTEM_TRAY_REQUEST_DOCK
    ev.xclient.data.l[2] = static_cast<long>(t->icon.win);
    x->SendEvent(dpy, manager, False, NoEventMask, &ev);
    x->Flush(dpy);
    klioTrays().push_back(t);
    return t;
}

void klio_tray_close(void* h) {
    auto* t = static_cast<KlioTray*>(h);
    if (!t) return;
    auto& trays = klioTrays();
    trays.erase(std::remove(trays.begin(), trays.end(), t), trays.end());
    t->menu.panels.clear();
    klioTrayShowMenu(t);
    klioX11Destroy(t->menuWin);
    klioX11Destroy(t->tipWin);
    klioX11Destroy(t->balloonWin);
    klioX11Destroy(t->icon);
    delete t;
}

void klio_tray_set_icon(void* h, KlioSurface* s) {
    auto* t = static_cast<KlioTray*>(h);
    if (!t || !s || !s->surface) return;
    t->image = s->surface->makeImageSnapshot();
    klioTrayDrawIcon(t);
}

void klio_tray_set_tooltip(void* h, const char* utf8, size_t len) {
    auto* t = static_cast<KlioTray*>(h);
    if (!t) return;
    t->tooltip = utf8 ? std::string(utf8, len) : std::string();
}

void klio_tray_set_menu(void* h, const char* spec, size_t len) {
    auto* t = static_cast<KlioTray*>(h);
    if (!t) return;
    t->menu.entries = klioParseMenu(spec, len);
    t->menu.panels.clear();
    klioTrayShowMenu(t);
    if (std::getenv("KLIO_MENU_DUMP")) {
        std::fprintf(stderr, "[menu] tray menu\n");
        std::vector<KlioMenuEntry> shifted = t->menu.entries;
        for (KlioMenuEntry& e : shifted) e.depth += 0;
        for (const KlioMenuEntry& e : shifted) {
            std::string line(static_cast<size_t>(e.depth) * 2, ' ');
            line += e.kind == 's' ? std::string("---") : e.text;
            if (e.kind != 's' && !e.enabled) line += " [disabled]";
            if (e.state) line += " [on]";
            std::fprintf(stderr, "[menu] %s\n", line.c_str());
        }
    }
}

// A notification from the tray: a balloon by its icon for ten seconds, as
// AWT's X11 tray icon shows displayMessage.
void klio_tray_notify(void* h, const char* title, size_t tlen, const char* message, size_t mlen, int type) {
    auto* t = static_cast<KlioTray*>(h);
    if (!t) return;
    const std::string ts = title ? std::string(title, tlen) : std::string();
    const std::string ms = message ? std::string(message, mlen) : std::string();
    if (std::getenv("KLIO_MENU_DUMP")) {
        std::fprintf(stderr, "[menu] tray notification %d: %s / %s\n", type, ts.c_str(), ms.c_str());
    }
    int rx = 0, ry = 0;
    klioTrayIconRect(t, &rx, &ry);
    klioTrayShowText(t->balloonWin, rx, ry + t->icon.h + 4, ts, ms, 0xFFFFFFE1);
    t->balloonShown = true;
    t->balloonUntil = std::chrono::steady_clock::now() + std::chrono::seconds(10);
}

int klio_tray_poll_event(void* h, double* out) {
    auto* t = static_cast<KlioTray*>(h);
    if (!t) return KLIO_EV_NONE;
    klioTrayPump();
    klioScriptTick(t->script, t->events, true);
    for (;;) {
        const int type = klioPopEv(t->events, out);
        if (type != KLIO_EV_MENU_PATH) return type;
        const size_t at = static_cast<size_t>(out[0]);
        if (at >= klioScriptTexts().size()) continue;
        int rx = 0, ry = 0;
        klioTrayIconRect(t, &rx, &ry);
        KlioX11* x = klioX11();
        Display* dpy = klioX11Display();
        if (x && dpy) {
            const int screen = x->DefaultScreen_(dpy);
            t->menu.w = x->DisplayWidth_(dpy, screen);
            t->menu.h = x->DisplayHeight_(dpy, screen);
        }
        t->menu.anchorX = static_cast<float>(rx);
        t->menu.anchorY = static_cast<float>(ry + t->icon.h);
        klioMenuPath(t->menu, klioScriptTexts()[at], out[1] != 0);
        klioTrayShowMenu(t);
    }
}

// Waits for the trays' X events for up to the timeout.
void klio_app_wait(int timeoutMs) {
    KlioX11* x = klioX11();
    Display* dpy = klioTrays().empty() ? nullptr : klioX11Display();
    if (!x || !dpy) {
        if (timeoutMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
        return;
    }
    if (x->Pending(dpy)) return;
    const int fd = x->ConnectionNumber_(dpy);
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    select(fd + 1, &set, nullptr, nullptr, &tv);
}
#else
// No tray icons: the desktop's Tray says so on standard error.
int klio_tray_supported(void) { return 0; }
void* klio_tray_open(void) { return nullptr; }
void klio_tray_close(void*) {}
void klio_tray_set_icon(void*, void*) {}
void klio_tray_set_tooltip(void*, const char*, size_t) {}
void klio_tray_set_menu(void*, const char*, size_t) {}
void klio_tray_notify(void*, const char*, size_t, const char*, size_t, int) {}
int klio_tray_poll_event(void*, double*) { return KLIO_EV_NONE; }
void klio_app_wait(int timeoutMs) {
    if (timeoutMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
}
#endif  // KLIO_X11_TRAY


// Queues an event on the window as if its platform had sent it (the values as
// klio_win_poll_event reports them), for programs that drive a window's input.
void klio_win_post_event(KlioWindow* kw, int type, const double* values) {
    if (!kw || !values) return;
    KlioEv e;
    e.type = type;
    for (int i = 0; i < KLIO_EV_VALUES; i++) e.v[i] = values[i];
    kw->events.push_back(e);
}

// Sets one of a window's KLIO_WIN_* properties.
void klio_win_set_flag(KlioWindow* kw, int which, int value) {
    if (!kw || !kw->win) return;
    const SDL_bool on = value ? SDL_TRUE : SDL_FALSE;
    switch (which) {
        case KLIO_WIN_RESIZABLE: SDL_SetWindowResizable(kw->win, on); break;
        case KLIO_WIN_DECORATED: SDL_SetWindowBordered(kw->win, on); break;
        case KLIO_WIN_ALWAYS_ON_TOP: SDL_SetWindowAlwaysOnTop(kw->win, on); break;
        case KLIO_WIN_VISIBLE:
            if (value) SDL_ShowWindow(kw->win);
            else SDL_HideWindow(kw->win);
            break;
        case KLIO_WIN_MINIMIZED:
            if (value) SDL_MinimizeWindow(kw->win);
            else SDL_RestoreWindow(kw->win);
            break;
        case KLIO_WIN_PLACEMENT:
            if (value == KLIO_PLACEMENT_FULLSCREEN) {
                SDL_SetWindowFullscreen(kw->win, SDL_WINDOW_FULLSCREEN_DESKTOP);
            } else {
                SDL_SetWindowFullscreen(kw->win, 0);
                if (value == KLIO_PLACEMENT_MAXIMIZED) SDL_MaximizeWindow(kw->win);
                else SDL_RestoreWindow(kw->win);
            }
            break;
        case KLIO_WIN_FRONT:
            SDL_RaiseWindow(kw->win);
            break;
        case KLIO_WIN_TRANSPARENT:
            if (value) {
                static bool told = false;
                if (!told) {
                    std::fprintf(stderr, "klio: SDL2 windows have no per-pixel transparency; a transparent window shows its unpainted pixels black\n");
                    told = true;
                }
            }
            break;
        default:
            break;
    }
}

// Moves the window frame's top-left to (x, y) on the screen.
void klio_win_set_position(KlioWindow* kw, int x, int y) {
    if (!kw || !kw->win) return;
    int top = 0;
    int left = 0;
    SDL_GetWindowBordersSize(kw->win, &top, &left, nullptr, nullptr);
    SDL_SetWindowPosition(kw->win, x + left, y + top);
    // The window manager may place it later; a later move is reported then.
    const Uint32 flags = SDL_GetWindowFlags(kw->win);
    int placement = KLIO_PLACEMENT_FLOATING;
    if ((flags & SDL_WINDOW_FULLSCREEN_DESKTOP) == SDL_WINDOW_FULLSCREEN_DESKTOP) placement = KLIO_PLACEMENT_FULLSCREEN;
    else if (flags & SDL_WINDOW_MAXIMIZED) placement = KLIO_PLACEMENT_MAXIMIZED;
    klioBaselineMove(kw->frameReport, kw->events, x, y, x, y, placement, (flags & SDL_WINDOW_MINIMIZED) != 0);
}

void klio_win_get_position(KlioWindow* kw, int* x, int* y) {
    if (!kw || !kw->win || !x || !y) return;
    klioSdlTopLeft(kw, x, y);
}

// Resizes the window's frame, its border included: SDL sizes the client area.
void klio_win_set_frame_size(KlioWindow* kw, int w, int h) {
    if (!kw || !kw->win || w <= 0 || h <= 0) return;
    int top = 0, left = 0, bottom = 0, right = 0;
    SDL_GetWindowBordersSize(kw->win, &top, &left, &bottom, &right);
    SDL_SetWindowSize(kw->win, w - left - right, h - top - bottom);
}

void klio_win_get_frame_size(KlioWindow* kw, int* w, int* h) {
    if (!kw || !kw->win || !w || !h) return;
    int top = 0, left = 0, bottom = 0, right = 0;
    SDL_GetWindowBordersSize(kw->win, &top, &left, &bottom, &right);
    SDL_GetWindowSize(kw->win, w, h);
    *w += left + right;
    *h += top + bottom;
}

// The primary display's area for windows.
void klio_win_screen_bounds(int* x, int* y, int* w, int* h) {
    if (!x || !y || !w || !h) return;
    SDL_Rect r = {0, 0, 0, 0};
    if (SDL_WasInit(SDL_INIT_VIDEO) == 0 || SDL_GetDisplayUsableBounds(0, &r) != 0) r = {0, 0, 0, 0};
    *x = r.x;
    *y = r.y;
    *w = r.w;
    *h = r.h;
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
        if (last) klioSdlReleaseVideo();
        delete kw;
        return;
    }
#endif
    if (kw->frame) klio_skia_free(kw->frame);
    delete kw->menu;
    if (kw->tex) SDL_DestroyTexture(kw->tex);
    if (kw->renderer) SDL_DestroyRenderer(kw->renderer);
    if (kw->win) SDL_DestroyWindow(kw->win);
    if (last) klioSdlReleaseVideo();
    delete kw;
}

// The host clipboard, as text: a count that moves whenever any application
// changes it (-1 when the host has none), its text as malloc'd UTF-8 that
// klio_skia_free_cstr frees (null when it holds no text), and replacing its
// contents with a text (null empties it).
// SDL has no change count, so the shim keeps one: it moves when the
// clipboard's text differs from the text it last saw.
static bool klioSdlClipReady() {
    static int ready = -1;
    if (ready < 0) {
        SDL_SetMainReady();
        ready = SDL_InitSubSystem(SDL_INIT_VIDEO) == 0 ? 1 : 0;
    }
    return ready == 1;
}

static std::string& klioSdlClipSeen() {
    static std::string seen;
    return seen;
}

static long long klioSdlClipCount = 0;

static std::string klioSdlClipNow() {
    if (!SDL_HasClipboardText()) return std::string();
    char* t = SDL_GetClipboardText();
    std::string s = t ? t : "";
    if (t) SDL_free(t);
    return s;
}

long long klio_clip_change_count(void) {
    if (!klioSdlClipReady()) return -1;
    const std::string now = klioSdlClipNow();
    if (now != klioSdlClipSeen()) {
        klioSdlClipSeen() = now;
        ++klioSdlClipCount;
    }
    return klioSdlClipCount;
}

char* klio_clip_get_text(size_t* len) {
    if (!klioSdlClipReady() || !SDL_HasClipboardText()) return nullptr;
    const std::string now = klioSdlClipNow();
    char* out = static_cast<char*>(std::malloc(now.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, now.data(), now.size());
    out[now.size()] = 0;
    if (len) *len = now.size();
    return out;
}

void klio_clip_set_text(const char* utf8, size_t len) {
    if (!klioSdlClipReady()) return;
    const std::string text = utf8 ? std::string(utf8, len) : std::string();
    SDL_SetClipboardText(text.c_str());
    if (text != klioSdlClipSeen()) {
        klioSdlClipSeen() = text;
        ++klioSdlClipCount;
    }
}

// The runtime reads the host's locale from its POSIX locale name.
char* klio_host_locale(void) { return nullptr; }

}  // extern "C"

#elif defined(_WIN32)

// Win32 backend. The N32-premul surface (BGRA) matches a 32bpp top-down BI_RGB
// DIB, so present is a StretchDIBits blit. Events arrive through the window proc;
// each poll pumps the queue and returns the first translated event. Compile-checked
// via a Windows cross target; not run-verified.
#include <windows.h>
#include <imm.h>
#include <shellapi.h>

struct KlioWindow {
    HWND hwnd;
    int w;
    int h;
    KlioSurface* surface;
    int evType;
    int evA;
    int evB;
    bool hasEv;
    std::deque<KlioEv> events;  // klio_win_poll_event's queue
    int buttons = 0;            // the mouse buttons held, one bit per KLIO_BTN_* - 1
    bool pointerInside = false;
    unsigned highSurrogate = 0;
    KlioScriptState script;     // its progress through the scripted input
    KlioFrameReport frameReport;
    bool resizable = true;
    bool decorated = true;
    LONG_PTR savedStyle = 0;    // the style and frame fullscreen replaced
    RECT savedRect = {0, 0, 0, 0};
    HICON icon = nullptr;       // the icon klio_win_set_icon_png made
    HMENU menu = nullptr;       // the menu bar klio_win_set_menu made
    std::vector<KlioMenuEntry> menuEntries;
    std::vector<HBITMAP> menuBitmaps;  // its items' icons
    bool layered = false;       // transparent: presented with its alpha
    bool textInput = false;     // a text field has the keyboard (klio_win_set_text_input)
    bool composing = false;     // the input method is composing
    RECT imeRect = {0, 0, 0, 0};  // the text cursor, in the client area
    std::string eventText;      // the text of the event last polled
};

// A menu item's command: its entry's index past this base.
static const int KLIO_MENU_COMMAND_BASE = 0x100;

static void klioWinReportFrame(KlioWindow* kw) {
    RECT r;
    GetWindowRect(kw->hwnd, &r);
    WINDOWPLACEMENT wp = {};
    wp.length = sizeof(wp);
    GetWindowPlacement(kw->hwnd, &wp);
    int placement = KLIO_PLACEMENT_FLOATING;
    if (kw->savedStyle != 0) placement = KLIO_PLACEMENT_FULLSCREEN;
    else if (wp.showCmd == SW_SHOWMAXIMIZED) placement = KLIO_PLACEMENT_MAXIMIZED;
    klioReportFrame(kw->frameReport, kw->events, r.left, r.top, placement, IsIconic(kw->hwnd) != 0);
}

// The modifiers the desktop reports, from the keyboard's state.
static int klioWinMods() {
    int m = 0;
    if (GetKeyState(VK_SHIFT) & 0x8000) m |= KLIO_MOD_SHIFT;
    if (GetKeyState(VK_CONTROL) & 0x8000) m |= KLIO_MOD_CTRL;
    if (GetKeyState(VK_MENU) & 0x8000) m |= KLIO_MOD_ALT;
    if ((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) m |= KLIO_MOD_META;
    if (GetKeyState(VK_CAPITAL) & 1) m |= KLIO_MOD_CAPS_LOCK;
    if (GetKeyState(VK_NUMLOCK) & 1) m |= KLIO_MOD_NUM_LOCK;
    if (GetKeyState(VK_SCROLL) & 1) m |= KLIO_MOD_SCROLL_LOCK;
    return m;
}

// A Windows virtual key as AWT's key code and location, as the desktop's
// Windows toolkit numbers it. Letters, digits, the function keys and the
// keypad share AWT's codes.
static void klioWinKey(WPARAM vkIn, LPARAM lParam, int* vk, int* loc) {
    const int k = static_cast<int>(vkIn);
    const bool extended = (lParam & (1 << 24)) != 0;
    const UINT scan = (lParam >> 16) & 0xFF;
    *loc = KLIO_LOC_STANDARD;
    if ((k >= 'A' && k <= 'Z') || (k >= '0' && k <= '9')) {
        *vk = k;
        return;
    }
    if (k >= VK_F1 && k <= VK_F24) {
        *vk = klioVkFunction(1 + (k - VK_F1));
        return;
    }
    if (k >= VK_NUMPAD0 && k <= VK_DIVIDE) {
        *vk = VKK_NUMPAD0 + (k - VK_NUMPAD0);
        *loc = KLIO_LOC_NUMPAD;
        return;
    }
    switch (k) {
        case VK_BACK: *vk = VKK_BACK_SPACE; return;
        case VK_TAB: *vk = VKK_TAB; return;
        case VK_RETURN: *vk = VKK_ENTER; if (extended) *loc = KLIO_LOC_NUMPAD; return;
        case VK_SHIFT: *vk = VKK_SHIFT; *loc = scan == 0x36 ? KLIO_LOC_RIGHT : KLIO_LOC_LEFT; return;
        case VK_CONTROL: *vk = VKK_CONTROL; *loc = extended ? KLIO_LOC_RIGHT : KLIO_LOC_LEFT; return;
        case VK_MENU: *vk = VKK_ALT; *loc = extended ? KLIO_LOC_RIGHT : KLIO_LOC_LEFT; return;
        case VK_PAUSE: *vk = VKK_PAUSE; return;
        case VK_CAPITAL: *vk = VKK_CAPS_LOCK; return;
        case VK_ESCAPE: *vk = VKK_ESCAPE; return;
        case VK_SPACE: *vk = VKK_SPACE; return;
        case VK_PRIOR: *vk = VKK_PAGE_UP; return;
        case VK_NEXT: *vk = VKK_PAGE_DOWN; return;
        case VK_END: *vk = VKK_END; return;
        case VK_HOME: *vk = VKK_HOME; return;
        case VK_LEFT: *vk = VKK_LEFT; return;
        case VK_UP: *vk = VKK_UP; return;
        case VK_RIGHT: *vk = VKK_RIGHT; return;
        case VK_DOWN: *vk = VKK_DOWN; return;
        case VK_SNAPSHOT: *vk = VKK_PRINTSCREEN; return;
        case VK_INSERT: *vk = VKK_INSERT; return;
        case VK_DELETE: *vk = VKK_DELETE; return;
        case VK_HELP: *vk = VKK_HELP; return;
        case VK_LWIN: *vk = VKK_WINDOWS; *loc = KLIO_LOC_LEFT; return;
        case VK_RWIN: *vk = VKK_WINDOWS; *loc = KLIO_LOC_RIGHT; return;
        case VK_APPS: *vk = VKK_CONTEXT_MENU; return;
        case VK_NUMLOCK: *vk = VKK_NUM_LOCK; *loc = KLIO_LOC_NUMPAD; return;
        case VK_SCROLL: *vk = VKK_SCROLL_LOCK; return;
        case VK_OEM_1: *vk = VKK_SEMICOLON; return;
        case VK_OEM_PLUS: *vk = VKK_EQUALS; return;
        case VK_OEM_COMMA: *vk = VKK_COMMA; return;
        case VK_OEM_MINUS: *vk = VKK_MINUS; return;
        case VK_OEM_PERIOD: *vk = VKK_PERIOD; return;
        case VK_OEM_2: *vk = VKK_SLASH; return;
        case VK_OEM_3: *vk = VKK_BACK_QUOTE; return;
        case VK_OEM_4: *vk = VKK_OPEN_BRACKET; return;
        case VK_OEM_5: *vk = VKK_BACK_SLASH; return;
        case VK_OEM_6: *vk = VKK_CLOSE_BRACKET; return;
        case VK_OEM_7: *vk = VKK_QUOTE; return;
        default: *vk = VKK_UNDEFINED; return;
    }
}

// The window's input as klio_win_poll_event's events.
static void klioWinTranslate(KlioWindow* kw, UINT msg, WPARAM wParam, LPARAM lParam) {
    const double x = static_cast<short>(LOWORD(lParam));
    const double y = static_cast<short>(HIWORD(lParam));
    int button = KLIO_BTN_NONE;
    bool down = false;
    switch (msg) {
        case WM_LBUTTONDOWN: button = KLIO_BTN_PRIMARY; down = true; break;
        case WM_LBUTTONUP: button = KLIO_BTN_PRIMARY; break;
        case WM_RBUTTONDOWN: button = KLIO_BTN_SECONDARY; down = true; break;
        case WM_RBUTTONUP: button = KLIO_BTN_SECONDARY; break;
        case WM_MBUTTONDOWN: button = KLIO_BTN_TERTIARY; down = true; break;
        case WM_MBUTTONUP: button = KLIO_BTN_TERTIARY; break;
        case WM_XBUTTONDOWN:
        case WM_XBUTTONUP:
            button = HIWORD(wParam) == XBUTTON1 ? KLIO_BTN_BACK : KLIO_BTN_FORWARD;
            down = msg == WM_XBUTTONDOWN;
            break;
        case WM_MOUSEMOVE: {
            if (!kw->pointerInside) {
                // Moves into the window enter it; its leaving is reported once asked for.
                kw->pointerInside = true;
                TRACKMOUSEEVENT tme = {};
                tme.cbSize = sizeof(tme);
                tme.dwFlags = TME_LEAVE;
                tme.hwndTrack = kw->hwnd;
                TrackMouseEvent(&tme);
                kw->events.push_back(klioPointerEv(KLIO_PTR_ENTER, x, y, KLIO_BTN_NONE, kw->buttons, klioWinMods()));
            }
            kw->events.push_back(klioPointerEv(KLIO_PTR_MOVE, x, y, KLIO_BTN_NONE, kw->buttons, klioWinMods()));
            return;
        }
        case WM_MOUSELEAVE: {
            kw->pointerInside = false;
            POINT p;
            GetCursorPos(&p);
            ScreenToClient(kw->hwnd, &p);
            kw->events.push_back(klioPointerEv(KLIO_PTR_EXIT, p.x, p.y, KLIO_BTN_NONE, kw->buttons, klioWinMods()));
            return;
        }
        case WM_MOUSEWHEEL:
        case WM_MOUSEHWHEEL: {
            // The wheel's position is on the screen; its rotation, in notches of
            // 120, is positive away from the user, the opposite of AWT's.
            POINT p = {static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam))};
            ScreenToClient(kw->hwnd, &p);
            const double notches = GET_WHEEL_DELTA_WPARAM(wParam) / 120.0;
            const bool horizontal = msg == WM_MOUSEHWHEEL;
            kw->events.push_back(klioPointerEv(KLIO_PTR_SCROLL, p.x, p.y, KLIO_BTN_NONE, kw->buttons,
                                               klioWinMods(), horizontal ? notches : 0,
                                               horizontal ? 0 : -notches));
            return;
        }
        case WM_KEYDOWN:
        case WM_SYSKEYDOWN:
        case WM_KEYUP:
        case WM_SYSKEYUP: {
            // A key the input method takes is its, as AWT drops it.
            if (wParam == VK_PROCESSKEY) return;
            int vk = 0;
            int loc = KLIO_LOC_STANDARD;
            klioWinKey(wParam, lParam, &vk, &loc);
            const unsigned c = MapVirtualKeyW(static_cast<UINT>(wParam), MAPVK_VK_TO_CHAR) & 0x7FFF;
            const bool pressed = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
            kw->events.push_back(klioKeyEv(pressed, vk, loc, klioAwtKeyChar(vk, c), klioWinMods()));
            return;
        }
        case WM_CHAR: {
            // UTF-16 units: a high surrogate waits for its low one.
            const unsigned unit = static_cast<unsigned>(wParam);
            if (unit >= 0xD800 && unit <= 0xDBFF) {
                kw->highSurrogate = unit;
                return;
            }
            unsigned cp = unit;
            if (unit >= 0xDC00 && unit <= 0xDFFF && kw->highSurrogate) {
                cp = 0x10000 + ((kw->highSurrogate - 0xD800) << 10) + (unit - 0xDC00);
            }
            kw->highSurrogate = 0;
            if (!klioIsPrintable(cp)) return;
            KlioEv e;
            e.type = KLIO_EV_TEXT;
            e.v[0] = 1;
            e.v[1] = cp;
            kw->events.push_back(e);
            return;
        }
        case WM_COMMAND: {
            // A menu item chosen (not an accelerator's or a control's command).
            if (lParam != 0 || HIWORD(wParam) != 0) return;
            const int index = static_cast<int>(LOWORD(wParam)) - KLIO_MENU_COMMAND_BASE;
            if (index < 0 || static_cast<size_t>(index) >= kw->menuEntries.size()) return;
            kw->events.push_back(klioSimpleEv(KLIO_EV_MENU, kw->menuEntries[static_cast<size_t>(index)].id));
            return;
        }
        case WM_MOVE:
            klioWinReportFrame(kw);
            return;
        case WM_SETFOCUS:
            if (!klioScriptDrivesFocus()) kw->events.push_back(klioSimpleEv(KLIO_EV_FOCUS, 1));
            return;
        case WM_KILLFOCUS:
            if (!klioScriptDrivesFocus()) kw->events.push_back(klioSimpleEv(KLIO_EV_FOCUS, 0));
            return;
        default:
            return;
    }
    // A button press or release; the window keeps the mouse while one is held.
    const int bit = 1 << (button - 1);
    if (down) {
        kw->buttons |= bit;
        SetCapture(kw->hwnd);
    } else {
        if (!(kw->buttons & bit)) return;
        kw->buttons &= ~bit;
        if (kw->buttons == 0) ReleaseCapture();
    }
    kw->events.push_back(klioPointerEv(down ? KLIO_PTR_PRESS : KLIO_PTR_RELEASE, x, y, button,
                                       kw->buttons, klioWinMods()));
}

// The input method's composition string of the kind asked for (GCS_RESULTSTR,
// GCS_COMPSTR), as UTF-8.
static std::string klioWinImeString(HIMC himc, DWORD kind) {
    const LONG bytes = ImmGetCompositionStringW(himc, kind, nullptr, 0);
    if (bytes <= 0) return std::string();
    std::wstring w(static_cast<size_t>(bytes) / sizeof(wchar_t), L'\0');
    ImmGetCompositionStringW(himc, kind, &w[0], static_cast<DWORD>(bytes));
    const int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), &out[0], n, nullptr, nullptr);
    return out;
}

// Places the input method's composition and candidate windows at the text cursor.
static void klioWinPlaceIme(KlioWindow* kw) {
    HIMC himc = ImmGetContext(kw->hwnd);
    if (!himc) return;
    const RECT& r = kw->imeRect;
    COMPOSITIONFORM comp = {};
    comp.dwStyle = CFS_POINT;
    comp.ptCurrentPos.x = r.left;
    comp.ptCurrentPos.y = r.top;
    ImmSetCompositionWindow(himc, &comp);
    CANDIDATEFORM cand = {};
    cand.dwIndex = 0;
    cand.dwStyle = CFS_EXCLUDE;
    cand.ptCurrentPos.x = r.left;
    cand.ptCurrentPos.y = r.bottom;
    cand.rcArea = r;
    ImmSetCandidateWindow(himc, &cand);
    ImmReleaseContext(kw->hwnd, himc);
}

// The input method's messages while a text field has the keyboard: the field
// shows the composition itself, so the input method's own composition window
// stays hidden, and what it composes and commits is queued as KLIO_EV_IME.
// True when the message was handled.
static bool klioWinIme(KlioWindow* kw, UINT msg, LPARAM lParam) {
    if (!kw->textInput) return false;
    switch (msg) {
        case WM_IME_STARTCOMPOSITION:
            klioWinPlaceIme(kw);
            return true;
        case WM_IME_COMPOSITION: {
            HIMC himc = ImmGetContext(kw->hwnd);
            if (!himc) return true;
            const std::string committed =
                (lParam & GCS_RESULTSTR) ? klioWinImeString(himc, GCS_RESULTSTR) : std::string();
            const std::string composing =
                (lParam & GCS_COMPSTR) ? klioWinImeString(himc, GCS_COMPSTR) : std::string();
            ImmReleaseContext(kw->hwnd, himc);
            if (committed.empty() && composing.empty() && !kw->composing) return true;
            kw->composing = !composing.empty();
            kw->events.push_back(klioImeEv(committed.c_str(), composing.c_str()));
            return true;
        }
        case WM_IME_ENDCOMPOSITION:
            if (kw->composing) {
                kw->composing = false;
                kw->events.push_back(klioImeEv("", ""));
            }
            return true;
        default:
            return false;
    }
}

static LRESULT CALLBACK klioWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* kw = reinterpret_cast<KlioWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (kw) klioWinTranslate(kw, msg, wParam, lParam);
    if (kw && klioWinIme(kw, msg, lParam)) return 0;
    if (kw && msg == WM_IME_SETCONTEXT && kw->textInput) {
        return DefWindowProc(hwnd, msg, wParam, lParam & ~static_cast<LPARAM>(ISC_SHOWUICOMPOSITIONWINDOW));
    }
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
                kw->events.push_back(klioSimpleEv(KLIO_EV_CLOSE));
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
                klioWinReportFrame(kw);
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
                    kw->events.push_back(klioSimpleEv(KLIO_EV_RESIZE, nw, nh));
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
    if (!hwnd) {
        klioWinFailed("Windows could not create a window (error " + std::to_string(GetLastError()) + ")");
        return nullptr;
    }
    auto* kw = new KlioWindow{hwnd, w, h, nullptr, 0, 0, 0, false, {}, 0, false, 0};
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

// Presents a transparent window: a layered window takes its frame's
// premultiplied BGRA pixels, alpha included, as N32 on Windows lays them out.
static void klioWinPresentLayered(KlioWindow* kw, const SkPixmap& pm) {
    HDC screen = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = kw->w;
    bmi.bmiHeader.biHeight = -kw->h;  // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP bmp = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (bmp && bits) {
        for (int y = 0; y < kw->h; y++) {
            std::memcpy(static_cast<char*>(bits) + static_cast<size_t>(y) * kw->w * 4,
                        static_cast<const char*>(pm.addr()) + static_cast<size_t>(y) * pm.rowBytes(),
                        static_cast<size_t>(kw->w) * 4);
        }
        HGDIOBJ old = SelectObject(mem, bmp);
        RECT r;
        GetWindowRect(kw->hwnd, &r);
        POINT dst = {r.left, r.top};
        SIZE size = {kw->w, kw->h};
        POINT src = {0, 0};
        BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
        UpdateLayeredWindow(kw->hwnd, screen, &dst, &size, mem, &src, 0, &blend, ULW_ALPHA);
        SelectObject(mem, old);
    }
    if (bmp) DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
}

void klio_win_present(KlioWindow* kw) {
    if (!kw || !kw->surface) return;
    klioPresentDump(kw->surface);
    SkPixmap pm;
    if (!kw->surface->surface->peekPixels(&pm)) return;
    if (kw->layered) {
        klioWinPresentLayered(kw, pm);
        return;
    }
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


// Waits up to timeoutMs for the window's next input event and writes its
// values to out (KLIO_EV_VALUES doubles); returns its type (window_events.h),
// or KLIO_EV_NONE when none came. The window proc translates each message.
static int klioWinPop(KlioWindow* kw, double* out);

int klio_win_poll_event(KlioWindow* kw, int timeoutMs, double* out) {
    if (!kw) return KLIO_EV_CLOSE;
    klioScriptTick(kw->script, kw->events);
    if (!kw->frameReport.reported) klioWinReportFrame(kw);
    if (!kw->events.empty()) return klioWinPop(kw, out);
    MSG msg;
    if (!PeekMessage(&msg, nullptr, 0, 0, PM_NOREMOVE)) {
        MsgWaitForMultipleObjects(0, nullptr, FALSE, static_cast<DWORD>(timeoutMs), QS_ALLINPUT);
    }
    while (kw->events.empty() && PeekMessage(&msg, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    return klioWinPop(kw, out);
}

// The window's next event, a scripted menu choice performed on the way.
static int klioWinPop(KlioWindow* kw, double* out) {
    for (;;) {
        const int type = klioPopEv(kw->events, out, &kw->eventText);
        if (type != KLIO_EV_MENU_PATH) return type;
        const size_t at = static_cast<size_t>(out[0]);
        // A native menu is not left open: menushow is the drawn menus'.
        if (at >= klioScriptTexts().size() || out[1] != 0) continue;
        // Chosen as a click chooses it: its command through the window.
        const int index = klioMenuFindPath(kw->menuEntries, klioScriptTexts()[at]);
        if (index < 0 || klioMenuEnabledItem(kw->menuEntries, klioScriptTexts()[at]) < 0) continue;
        SendMessageW(kw->hwnd, WM_COMMAND, MAKEWPARAM(KLIO_MENU_COMMAND_BASE + index, 0), 0);
    }
}

static std::wstring klioWiden(const std::string& s) {
    if (s.empty()) return std::wstring();
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
    return w;
}

// A shortcut as the desktop's Windows menus show it: "Ctrl+Shift+S".
static std::string klioWinShortcutText(int vk, int mods) {
    std::string t;
    if (mods & KLIO_MOD_META) t += "Meta+";
    if (mods & KLIO_MOD_CTRL) t += "Ctrl+";
    if (mods & KLIO_MOD_ALT) t += "Alt+";
    if (mods & KLIO_MOD_SHIFT) t += "Shift+";
    char buf[16];
    if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) {
        t += static_cast<char>(vk);
        return t;
    }
    if (vk >= 112 && vk <= 123) {
        std::snprintf(buf, sizeof buf, "F%d", vk - 111);
        return t + buf;
    }
    switch (vk) {
        case 10: return t + "Enter";
        case 8: return t + "Backspace";
        case 9: return t + "Tab";
        case 27: return t + "Escape";
        case 32: return t + "Space";
        case 127: return t + "Delete";
        case 37: return t + "Left";
        case 38: return t + "Up";
        case 39: return t + "Right";
        case 40: return t + "Down";
        case 36: return t + "Home";
        case 35: return t + "End";
        case 33: return t + "Page Up";
        case 34: return t + "Page Down";
        case 44: return t + "Comma";
        case 45: return t + "Minus";
        case 46: return t + "Period";
        case 47: return t + "Slash";
        case 59: return t + "Semicolon";
        case 61: return t + "Equals";
        default:
            std::snprintf(buf, sizeof buf, "0x%x", vk);
            return t + buf;
    }
}

// An item's text for a Win32 menu: '&' doubled, the mnemonic's first
// occurrence marked, and the shortcut after a tab.
static std::wstring klioWinMenuText(const KlioMenuEntry& e) {
    std::string t;
    bool marked = false;
    for (const char ch : e.text) {
        if (!marked && e.mnemonic > 0 && e.mnemonic < 128 &&
            std::tolower(static_cast<unsigned char>(ch)) == std::tolower(e.mnemonic)) {
            t += '&';
            marked = true;
        }
        if (ch == '&') t += '&';
        t += ch;
    }
    if (e.keycode != 0) {
        t += '\t';
        t += klioWinShortcutText(e.keycode, e.mods);
    }
    return klioWiden(t);
}

// Sets the window's menu bar from its entries (window_events.h), or removes
// it for an empty spec. The bar takes its height from the client area, as the
// desktop's JMenuBar takes it from the content.
void klio_win_set_menu(KlioWindow* kw, const char* spec, size_t len) {
    if (!kw) return;
    kw->menuEntries = klioParseMenu(spec, len);
    HMENU bar = nullptr;
    if (!kw->menuEntries.empty()) {
        bar = CreateMenu();
        std::vector<HMENU> stack = {bar};
        for (size_t i = 0; i < kw->menuEntries.size(); i++) {
            const KlioMenuEntry& e = kw->menuEntries[i];
            if (e.depth < 0 || static_cast<size_t>(e.depth) >= stack.size()) continue;
            stack.resize(static_cast<size_t>(e.depth) + 1);
            HMENU parent = stack.back();
            if (e.kind == 's') {
                AppendMenuW(parent, MF_SEPARATOR, 0, nullptr);
                continue;
            }
            const std::wstring text = klioWinMenuText(e);
            UINT flags = MF_STRING | (e.enabled ? MF_ENABLED : MF_GRAYED);
            if (e.kind == 'm') {
                HMENU sub = CreatePopupMenu();
                AppendMenuW(parent, flags | MF_POPUP, reinterpret_cast<UINT_PTR>(sub), text.c_str());
                stack.push_back(sub);
                continue;
            }
            if (e.state) flags |= MF_CHECKED;
            const UINT command = static_cast<UINT>(KLIO_MENU_COMMAND_BASE + static_cast<int>(i));
            AppendMenuW(parent, flags, command, text.c_str());
            if (e.kind == 'r') {
                MENUITEMINFOW mii = {};
                mii.cbSize = sizeof(mii);
                mii.fMask = MIIM_FTYPE;
                mii.fType = MFT_STRING | MFT_RADIOCHECK;
                SetMenuItemInfoW(parent, command, FALSE, &mii);
            }
        }
    }
    HMENU old = kw->menu;
    SetMenu(kw->hwnd, bar);
    kw->menu = bar;
    if (old) DestroyMenu(old);
    for (HBITMAP b : kw->menuBitmaps) DeleteObject(b);
    kw->menuBitmaps.clear();
    DrawMenuBar(kw->hwnd);
    klioDumpMenuEntries(kw->menuEntries);
}

// A tray icon: a notification area icon whose messages come to a message-only
// window, its popup menu, and the events of its action and menu.
struct KlioTray {
    HWND hwnd = nullptr;
    NOTIFYICONDATAW nid = {};
    HMENU menu = nullptr;
    HICON icon = nullptr;
    std::vector<KlioMenuEntry> menuEntries;
    std::deque<KlioEv> events;
    KlioScriptState script;
};

static const UINT KLIO_TRAY_CALLBACK = WM_APP + 1;

static LRESULT CALLBACK klioTrayProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* tray = reinterpret_cast<KlioTray*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (tray && msg == KLIO_TRAY_CALLBACK) {
        switch (LOWORD(lParam)) {
            case WM_LBUTTONDBLCLK:
                // The desktop's action: a double click.
                tray->events.push_back(klioSimpleEv(KLIO_EV_TRAY_ACTION));
                return 0;
            case WM_RBUTTONUP:
            case WM_CONTEXTMENU:
                if (tray->menu) {
                    POINT p;
                    GetCursorPos(&p);
                    SetForegroundWindow(hwnd);
                    TrackPopupMenu(tray->menu, TPM_RIGHTBUTTON, p.x, p.y, 0, hwnd, nullptr);
                    PostMessageW(hwnd, WM_NULL, 0, 0);
                }
                return 0;
        }
    }
    if (tray && msg == WM_COMMAND && lParam == 0 && HIWORD(wParam) == 0) {
        const int index = static_cast<int>(LOWORD(wParam)) - KLIO_MENU_COMMAND_BASE;
        if (index >= 0 && static_cast<size_t>(index) < tray->menuEntries.size()) {
            tray->events.push_back(klioSimpleEv(KLIO_EV_MENU, tray->menuEntries[static_cast<size_t>(index)].id));
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

int klio_tray_supported(void) { return 1; }

void* klio_tray_open(void) {
    static bool registered = false;
    if (!registered) {
        WNDCLASSW wc = {};
        wc.lpfnWndProc = klioTrayProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"KlioTray";
        RegisterClassW(&wc);
        registered = true;
    }
    auto* tray = new KlioTray();
    tray->hwnd = CreateWindowExW(0, L"KlioTray", L"klio tray", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
    if (!tray->hwnd) {
        delete tray;
        return nullptr;
    }
    SetWindowLongPtrW(tray->hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(tray));
    tray->nid.cbSize = sizeof(tray->nid);
    tray->nid.hWnd = tray->hwnd;
    tray->nid.uID = 1;
    tray->nid.uFlags = NIF_MESSAGE;
    tray->nid.uCallbackMessage = KLIO_TRAY_CALLBACK;
    Shell_NotifyIconW(NIM_ADD, &tray->nid);
    return tray;
}

void klio_tray_close(void* t) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return;
    Shell_NotifyIconW(NIM_DELETE, &tray->nid);
    if (tray->menu) DestroyMenu(tray->menu);
    if (tray->icon) DestroyIcon(tray->icon);
    DestroyWindow(tray->hwnd);
    delete tray;
}

static HICON klioWinIconFromPng(const unsigned char* png, size_t len);

void klio_tray_set_icon(void* t, KlioSurface* s) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray || !s) return;
    size_t len = 0;
    uint8_t* png = klio_skia_encode_png(s, &len);
    if (!png) return;
    HICON icon = klioWinIconFromPng(png, len);
    klio_skia_free_buffer(png);
    if (!icon) return;
    tray->nid.uFlags = NIF_ICON;
    tray->nid.hIcon = icon;
    Shell_NotifyIconW(NIM_MODIFY, &tray->nid);
    if (tray->icon) DestroyIcon(tray->icon);
    tray->icon = icon;
}

void klio_tray_set_tooltip(void* t, const char* utf8, size_t len) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return;
    const std::wstring tip = utf8 ? klioWiden(std::string(utf8, len)) : std::wstring();
    wcsncpy(tray->nid.szTip, tip.c_str(), sizeof(tray->nid.szTip) / sizeof(wchar_t) - 1);
    tray->nid.szTip[sizeof(tray->nid.szTip) / sizeof(wchar_t) - 1] = 0;
    tray->nid.uFlags = NIF_TIP | NIF_SHOWTIP;
    Shell_NotifyIconW(NIM_MODIFY, &tray->nid);
}

void klio_tray_set_menu(void* t, const char* spec, size_t len) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return;
    tray->menuEntries = klioParseMenu(spec, len);
    if (tray->menu) DestroyMenu(tray->menu);
    tray->menu = nullptr;
    if (tray->menuEntries.empty()) return;
    tray->menu = CreatePopupMenu();
    std::vector<HMENU> stack = {tray->menu};
    for (size_t i = 0; i < tray->menuEntries.size(); i++) {
        const KlioMenuEntry& e = tray->menuEntries[i];
        if (e.depth < 0 || static_cast<size_t>(e.depth) >= stack.size()) continue;
        stack.resize(static_cast<size_t>(e.depth) + 1);
        HMENU parent = stack.back();
        if (e.kind == 's') {
            AppendMenuW(parent, MF_SEPARATOR, 0, nullptr);
            continue;
        }
        const std::wstring text = klioWinMenuText(e);
        UINT flags = MF_STRING | (e.enabled ? MF_ENABLED : MF_GRAYED);
        if (e.kind == 'm') {
            HMENU sub = CreatePopupMenu();
            AppendMenuW(parent, flags | MF_POPUP, reinterpret_cast<UINT_PTR>(sub), text.c_str());
            stack.push_back(sub);
            continue;
        }
        if (e.state) flags |= MF_CHECKED;
        AppendMenuW(parent, flags, static_cast<UINT>(KLIO_MENU_COMMAND_BASE + static_cast<int>(i)), text.c_str());
    }
    klioDumpMenuEntries(tray->menuEntries);
}

// A notification from the tray: the icon's balloon, as the desktop's
// TrayIcon.displayMessage shows it.
void klio_tray_notify(void* t, const char* title, size_t tlen, const char* message, size_t mlen, int type) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return;
    const std::wstring ts = title ? klioWiden(std::string(title, tlen)) : std::wstring();
    const std::wstring ms = message ? klioWiden(std::string(message, mlen)) : std::wstring();
    wcsncpy(tray->nid.szInfoTitle, ts.c_str(), sizeof(tray->nid.szInfoTitle) / sizeof(wchar_t) - 1);
    tray->nid.szInfoTitle[sizeof(tray->nid.szInfoTitle) / sizeof(wchar_t) - 1] = 0;
    wcsncpy(tray->nid.szInfo, ms.c_str(), sizeof(tray->nid.szInfo) / sizeof(wchar_t) - 1);
    tray->nid.szInfo[sizeof(tray->nid.szInfo) / sizeof(wchar_t) - 1] = 0;
    switch (type) {
        case 1: tray->nid.dwInfoFlags = NIIF_INFO; break;
        case 2: tray->nid.dwInfoFlags = NIIF_WARNING; break;
        case 3: tray->nid.dwInfoFlags = NIIF_ERROR; break;
        default: tray->nid.dwInfoFlags = NIIF_NONE; break;
    }
    tray->nid.uFlags = NIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &tray->nid);
}

int klio_tray_poll_event(void* t, double* out) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return KLIO_EV_NONE;
    klioScriptTick(tray->script, tray->events, true);
    for (;;) {
        const int type = klioPopEv(tray->events, out);
        if (type != KLIO_EV_MENU_PATH) return type;
        const size_t at = static_cast<size_t>(out[0]);
        if (at >= klioScriptTexts().size()) continue;
        const int index = klioMenuFindPath(tray->menuEntries, klioScriptTexts()[at]);
        if (index < 0 || klioMenuEnabledItem(tray->menuEntries, klioScriptTexts()[at]) < 0) continue;
        SendMessageW(tray->hwnd, WM_COMMAND, MAKEWPARAM(KLIO_MENU_COMMAND_BASE + index, 0), 0);
    }
}

// Runs the thread's messages for up to the timeout, while no window's poll
// runs them (an application with only a tray).
void klio_app_wait(int timeoutMs) {
    MSG msg;
    if (!PeekMessageW(&msg, nullptr, 0, 0, PM_NOREMOVE)) {
        MsgWaitForMultipleObjects(0, nullptr, FALSE, static_cast<DWORD>(timeoutMs), QS_ALLINPUT);
    }
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

// Sets the icon of the menu item with the id from a drawn surface: its
// premultiplied pixels as a 32-bit bitmap, which menus draw with their alpha.
void klio_win_set_menu_icon(KlioWindow* kw, int id, KlioSurface* s) {
    if (!kw || !kw->menu || !s || !s->surface) return;
    int index = -1;
    for (size_t i = 0; i < kw->menuEntries.size(); i++) {
        if (kw->menuEntries[i].id == id && kw->menuEntries[i].kind != 'm') index = static_cast<int>(i);
    }
    if (index < 0) return;
    const int w = s->surface->width();
    const int h = s->surface->height();
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HDC dc = GetDC(nullptr);
    HBITMAP bitmap = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, dc);
    if (!bitmap || !bits) return;
    const SkImageInfo info = SkImageInfo::Make(w, h, kBGRA_8888_SkColorType, kPremul_SkAlphaType);
    if (!s->surface->readPixels(info, bits, static_cast<size_t>(w) * 4, 0, 0)) {
        DeleteObject(bitmap);
        return;
    }
    MENUITEMINFOW mii = {};
    mii.cbSize = sizeof(mii);
    mii.fMask = MIIM_BITMAP;
    mii.hbmpItem = bitmap;
    SetMenuItemInfoW(kw->menu, static_cast<UINT>(KLIO_MENU_COMMAND_BASE + index), FALSE, &mii);
    kw->menuBitmaps.push_back(bitmap);
    DrawMenuBar(kw->hwnd);
}

// Queues an event on the window as if its platform had sent it (the values as
// klio_win_poll_event reports them), for programs that drive a window's input.
void klio_win_post_event(KlioWindow* kw, int type, const double* values) {
    if (!kw || !values) return;
    KlioEv e;
    e.type = type;
    for (int i = 0; i < KLIO_EV_VALUES; i++) e.v[i] = values[i];
    kw->events.push_back(e);
}

// The text field ended the composition itself: the input method drops it.
void klio_win_end_composition(KlioWindow* kw) {
    if (!kw || !kw->composing) return;
    kw->composing = false;
    HIMC himc = ImmGetContext(kw->hwnd);
    if (!himc) return;
    ImmNotifyIME(himc, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
    ImmReleaseContext(kw->hwnd, himc);
}

// A text field has the keyboard, or none has: the window has the input method
// only while one has it, as AWT enables input methods for a text component.
void klio_win_set_text_input(KlioWindow* kw, int enabled) {
    if (!kw) return;
    const bool on = enabled != 0;
    if (!on && kw->composing) klio_win_end_composition(kw);
    kw->textInput = on;
    ImmAssociateContextEx(kw->hwnd, nullptr, on ? IACE_DEFAULT : 0);
    if (on) klioWinPlaceIme(kw);
}

// The text field's cursor, in the window's client area, where the input
// method places its candidate window.
void klio_win_set_text_input_rect(KlioWindow* kw, int x, int y, int w, int h) {
    if (!kw) return;
    kw->imeRect = {x, y, x + w, y + h};
    if (kw->textInput) klioWinPlaceIme(kw);
}

// The text of the event klio_win_poll_event last returned.
size_t klio_win_event_text(KlioWindow* kw, char* buf, size_t cap) {
    return kw ? klioCopyEventText(kw->eventText, buf, cap) : 0;
}

// Only macOS has an emoji and symbols palette to open; Windows' emoji panel
// is the user's (Win+.) and types through the input method.
void klio_order_emoji_palette(void) {}

// The window style its KLIO_WIN_* properties give.
static LONG_PTR klioWinStyle(KlioWindow* kw, LONG_PTR style) {
    style &= ~(WS_OVERLAPPEDWINDOW | WS_POPUP);
    if (kw->decorated) {
        style |= WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        if (kw->resizable) style |= WS_THICKFRAME | WS_MAXIMIZEBOX;
    } else {
        style |= WS_POPUP;
        if (kw->resizable) style |= WS_THICKFRAME;
    }
    return style;
}

// Sets one of a window's KLIO_WIN_* properties.
void klio_win_set_flag(KlioWindow* kw, int which, int value) {
    if (!kw) return;
    HWND h = kw->hwnd;
    switch (which) {
        case KLIO_WIN_RESIZABLE:
        case KLIO_WIN_DECORATED: {
            if (which == KLIO_WIN_RESIZABLE) kw->resizable = value != 0;
            else kw->decorated = value != 0;
            // A new style keeps the client area's size.
            RECT client;
            GetClientRect(h, &client);
            const LONG_PTR style = klioWinStyle(kw, GetWindowLongPtr(h, GWL_STYLE));
            SetWindowLongPtr(h, GWL_STYLE, style);
            RECT r = client;
            AdjustWindowRect(&r, static_cast<DWORD>(style), FALSE);
            SetWindowPos(h, nullptr, 0, 0, r.right - r.left, r.bottom - r.top,
                         SWP_NOMOVE | SWP_NOZORDER | SWP_FRAMECHANGED);
            break;
        }
        case KLIO_WIN_ALWAYS_ON_TOP:
            SetWindowPos(h, value ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
            break;
        case KLIO_WIN_VISIBLE:
            ShowWindow(h, value ? SW_SHOW : SW_HIDE);
            break;
        case KLIO_WIN_MINIMIZED:
            ShowWindow(h, value ? SW_MINIMIZE : SW_RESTORE);
            break;
        case KLIO_WIN_PLACEMENT:
            if (value == KLIO_PLACEMENT_FULLSCREEN) {
                if (kw->savedStyle != 0) break;
                // Fullscreen: no frame, over the whole monitor.
                kw->savedStyle = GetWindowLongPtr(h, GWL_STYLE);
                GetWindowRect(h, &kw->savedRect);
                MONITORINFO mi = {};
                mi.cbSize = sizeof(mi);
                GetMonitorInfo(MonitorFromWindow(h, MONITOR_DEFAULTTONEAREST), &mi);
                SetWindowLongPtr(h, GWL_STYLE, (kw->savedStyle & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
                SetWindowPos(h, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                             mi.rcMonitor.right - mi.rcMonitor.left, mi.rcMonitor.bottom - mi.rcMonitor.top,
                             SWP_FRAMECHANGED);
            } else {
                if (kw->savedStyle != 0) {
                    SetWindowLongPtr(h, GWL_STYLE, kw->savedStyle);
                    const RECT r = kw->savedRect;
                    SetWindowPos(h, nullptr, r.left, r.top, r.right - r.left, r.bottom - r.top,
                                 SWP_NOZORDER | SWP_FRAMECHANGED);
                    kw->savedStyle = 0;
                }
                ShowWindow(h, value == KLIO_PLACEMENT_MAXIMIZED ? SW_MAXIMIZE : SW_RESTORE);
            }
            klioWinReportFrame(kw);
            break;
        case KLIO_WIN_FRONT:
            BringWindowToTop(h);
            SetForegroundWindow(h);
            break;
        case KLIO_WIN_TRANSPARENT: {
            const LONG_PTR ex = GetWindowLongPtr(h, GWL_EXSTYLE);
            SetWindowLongPtr(h, GWL_EXSTYLE, value ? (ex | WS_EX_LAYERED) : (ex & ~static_cast<LONG_PTR>(WS_EX_LAYERED)));
            kw->layered = value != 0;
            break;
        }
        default:
            break;
    }
}

// Moves the window frame's top-left to (x, y) on the screen.
void klio_win_set_position(KlioWindow* kw, int x, int y) {
    if (!kw) return;
    SetWindowPos(kw->hwnd, nullptr, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER);
    RECT r;
    GetWindowRect(kw->hwnd, &r);
    WINDOWPLACEMENT wp = {};
    wp.length = sizeof(wp);
    GetWindowPlacement(kw->hwnd, &wp);
    int placement = KLIO_PLACEMENT_FLOATING;
    if (kw->savedStyle != 0) placement = KLIO_PLACEMENT_FULLSCREEN;
    else if (wp.showCmd == SW_SHOWMAXIMIZED) placement = KLIO_PLACEMENT_MAXIMIZED;
    klioBaselineMove(kw->frameReport, kw->events, x, y, r.left, r.top, placement, IsIconic(kw->hwnd) != 0);
}

void klio_win_get_position(KlioWindow* kw, int* x, int* y) {
    if (!kw || !x || !y) return;
    RECT r;
    GetWindowRect(kw->hwnd, &r);
    *x = r.left;
    *y = r.top;
}

// Resizes the window's frame, its title bar and border included.
void klio_win_set_frame_size(KlioWindow* kw, int w, int h) {
    if (!kw || w <= 0 || h <= 0) return;
    SetWindowPos(kw->hwnd, nullptr, 0, 0, w, h, SWP_NOMOVE | SWP_NOZORDER);
}

void klio_win_get_frame_size(KlioWindow* kw, int* w, int* h) {
    if (!kw || !w || !h) return;
    RECT r;
    GetWindowRect(kw->hwnd, &r);
    *w = r.right - r.left;
    *h = r.bottom - r.top;
}

// The primary monitor's area for windows (without the taskbar).
void klio_win_screen_bounds(int* x, int* y, int* w, int* h) {
    if (!x || !y || !w || !h) return;
    RECT r = {0, 0, 0, 0};
    SystemParametersInfoA(SPI_GETWORKAREA, 0, &r, 0);
    *x = r.left;
    *y = r.top;
    *w = r.right - r.left;
    *h = r.bottom - r.top;
}

void klio_win_set_title(KlioWindow* kw, const char* title) {
    if (!kw || !title) return;
    SetWindowTextA(kw->hwnd, title);
}

// PNG bytes as a 32-bit icon with its alpha, or null.
static HICON klioWinIconFromPng(const unsigned char* png, size_t len) {
    if (!png || len == 0) return nullptr;
    sk_sp<SkData> data = SkData::MakeWithoutCopy(png, len);
    std::unique_ptr<SkCodec> codec = SkPngDecoder::Decode(data, nullptr);
    if (!codec) return nullptr;
    const SkImageInfo info = codec->getInfo()
                                 .makeColorType(kBGRA_8888_SkColorType)
                                 .makeAlphaType(kUnpremul_SkAlphaType);
    const int w = info.width();
    const int h = info.height();
    if (w <= 0 || h <= 0) return nullptr;
    BITMAPV5HEADER bi = {};
    bi.bV5Size = sizeof(bi);
    bi.bV5Width = w;
    bi.bV5Height = -h;  // top-down
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;
    void* bits = nullptr;
    HDC dc = GetDC(nullptr);
    HBITMAP color = CreateDIBSection(dc, reinterpret_cast<BITMAPINFO*>(&bi), DIB_RGB_COLORS, &bits, nullptr, 0);
    ReleaseDC(nullptr, dc);
    if (!color || !bits) return nullptr;
    if (codec->getPixels(info, bits, static_cast<size_t>(w) * 4) != SkCodec::kSuccess) {
        DeleteObject(color);
        return nullptr;
    }
    HBITMAP mask = CreateBitmap(w, h, 1, 1, nullptr);
    ICONINFO ii = {};
    ii.fIcon = TRUE;
    ii.hbmColor = color;
    ii.hbmMask = mask;
    HICON icon = CreateIconIndirect(&ii);
    DeleteObject(color);
    DeleteObject(mask);
    return icon;
}

// The window's icon (the title bar's and the taskbar's) from PNG bytes.
void klio_win_set_icon_png(KlioWindow* kw, const unsigned char* png, size_t len) {
    if (!kw) return;
    HICON icon = klioWinIconFromPng(png, len);
    if (!icon) return;
    SendMessageW(kw->hwnd, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(icon));
    SendMessageW(kw->hwnd, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(icon));
    if (kw->icon) DestroyIcon(kw->icon);
    kw->icon = icon;
}

// A window's icon (Compose's Window(icon)) from a drawn surface.
void klio_win_set_icon_surface(KlioWindow* kw, KlioSurface* s) {
    if (!kw || !s) return;
    size_t len = 0;
    uint8_t* png = klio_skia_encode_png(s, &len);
    if (!png) return;
    klio_win_set_icon_png(kw, png, len);
    klio_skia_free_buffer(png);
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
    if (kw->icon) DestroyIcon(kw->icon);
    if (kw->menu) DestroyMenu(kw->menu);
    for (HBITMAP b : kw->menuBitmaps) DeleteObject(b);
    delete kw;
}

// The host clipboard, as text: a count that moves whenever any application
// changes it (-1 when the host has none), its text as malloc'd UTF-8 that
// klio_skia_free_cstr frees (null when it holds no text), and replacing its
// contents with a text (null empties it).
// The text is CF_UNICODETEXT, whose lines end in CR LF where the program's
// end in LF, as the desktop translates them. Setting it needs a window to own
// the clipboard: a message-only one.
static HWND klioWinClipOwner() {
    static HWND owner = nullptr;
    if (!owner) {
        owner = CreateWindowExW(0, L"STATIC", L"klio clipboard", 0, 0, 0, 0, 0, HWND_MESSAGE,
                                nullptr, GetModuleHandleW(nullptr), nullptr);
    }
    return owner;
}

// Another process may hold the clipboard open for a moment.
static bool klioWinOpenClip() {
    for (int i = 0; i < 20; i++) {
        if (OpenClipboard(klioWinClipOwner())) return true;
        Sleep(5);
    }
    return false;
}

long long klio_clip_change_count(void) {
    return static_cast<long long>(GetClipboardSequenceNumber());
}

char* klio_clip_get_text(size_t* len) {
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT) || !klioWinOpenClip()) return nullptr;
    std::string text;
    bool got = false;
    HANDLE h = GetClipboardData(CF_UNICODETEXT);
    if (h) {
        const wchar_t* w = static_cast<const wchar_t*>(GlobalLock(h));
        if (w) {
            const int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
            if (n > 0) {
                std::string raw(static_cast<size_t>(n), '\0');
                WideCharToMultiByte(CP_UTF8, 0, w, -1, &raw[0], n, nullptr, nullptr);
                raw.resize(static_cast<size_t>(n - 1));
                text.reserve(raw.size());
                for (size_t i = 0; i < raw.size(); i++) {
                    if (raw[i] == '\r' && i + 1 < raw.size() && raw[i + 1] == '\n') continue;
                    text.push_back(raw[i]);
                }
                got = true;
            }
            GlobalUnlock(h);
        }
    }
    CloseClipboard();
    if (!got) return nullptr;
    char* out = static_cast<char*>(std::malloc(text.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, text.data(), text.size());
    out[text.size()] = 0;
    if (len) *len = text.size();
    return out;
}

void klio_clip_set_text(const char* utf8, size_t len) {
    if (!klioWinOpenClip()) return;
    EmptyClipboard();
    if (utf8) {
        std::string text;
        text.reserve(len);
        for (size_t i = 0; i < len; i++) {
            if (utf8[i] == '\n' && (i == 0 || utf8[i - 1] != '\r')) text.push_back('\r');
            text.push_back(utf8[i]);
        }
        const int n = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
        HGLOBAL g = GlobalAlloc(GMEM_MOVEABLE, (static_cast<size_t>(n) + 1) * sizeof(wchar_t));
        if (g) {
            wchar_t* w = static_cast<wchar_t*>(GlobalLock(g));
            if (n > 0) MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), w, n);
            w[n] = 0;
            GlobalUnlock(g);
            if (!SetClipboardData(CF_UNICODETEXT, g)) GlobalFree(g);
        }
    }
    CloseClipboard();
}

// The host's default locale as a language tag, malloc'd (klio_skia_free_cstr
// frees it), as the JVM takes it on Windows: the user's UI language.
char* klio_host_locale(void) {
    wchar_t name[LOCALE_NAME_MAX_LENGTH];
    const LCID lcid = MAKELCID(GetUserDefaultUILanguage(), SORT_DEFAULT);
    if (LCIDToLocaleName(lcid, name, LOCALE_NAME_MAX_LENGTH, 0) == 0) return nullptr;
    const int n = WideCharToMultiByte(CP_UTF8, 0, name, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return nullptr;
    char* out = static_cast<char*>(std::malloc(static_cast<size_t>(n)));
    if (!out) return nullptr;
    WideCharToMultiByte(CP_UTF8, 0, name, -1, out, n, nullptr, nullptr);
    return out;
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
    // klio_win_poll_event's queue and the input state it is translated with.
    std::deque<KlioEv> events;
    id focusObservers[2];
    NSTrackingArea* tracking;
    int buttons;        // the mouse buttons held, one bit per KLIO_BTN_* - 1
    bool closeRequested;  // the close button was pressed (the legacy poll's close)
    KlioScriptState script;  // its progress through the scripted input
    KlioFrameReport frameReport;
    id delegate;        // KlioWindowDelegate: the close button asks, it does not close
    bool resizable;
    // The window's menu bar: the application's main menu while it is key.
    NSMenu* mainMenu;
    id menuTarget;      // KlioMenuTarget: its items' action
    std::vector<KlioMenuEntry> menuEntries;
    // The input method, while a text field has the keyboard (klio_win_set_text_input).
    bool textInput;
    NSString* marked;   // the text it is composing (retained), or nil
    NSRect imeRect;     // the text cursor, in the content (top-left origin)
    bool inKey;         // a key press is with the input method
    bool keyTaken;      // the input method took the press
    std::string typed;  // what the press typed, when the input method passed it on
    std::string eventText;  // the text of the event last polled
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

// The application's name, for its menu.
static NSString*& klioAppName() {
    static NSString* name = nil;
    return name;
}

// The main menu while no window with a menu bar is key.
static NSMenu*& klioDefaultMainMenu() {
    static NSMenu* menu = nil;
    return menu;
}

// A main menu's first item: the application menu with Quit (Cmd-Q).
static void klioAddAppMenu(NSMenu* menuBar) {
    NSMenuItem* appItem = [[NSMenuItem alloc] init];
    [menuBar addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", klioAppName() ?: @"klio"]
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    [appItem setSubmenu:appMenu];
    [appMenu release];
    [appItem release];
}

// Minimal main menu so the window behaves like a real app: Quit (Cmd-Q). Window
// close is left to the app to wire if it wants it. Once per process.
static void klioSetupMenu(const char* title) {
    static bool done = false;
    if (done) return;
    done = true;
    klioAppName() = [(title ? [NSString stringWithUTF8String:title] : @"klio") retain];
    NSMenu* menuBar = [[NSMenu alloc] init];
    klioAddAppMenu(menuBar);
    [NSApp setMainMenu:menuBar];
    klioDefaultMainMenu() = menuBar;  // kept
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

extern "C" void klio_win_close(KlioWindow* kw);  // used by the open error path

// A window that takes the keyboard undecorated too (a borderless NSWindow
// would not become key).
@interface KlioNSWindow : NSWindow
@end

@implementation KlioNSWindow
- (BOOL)canBecomeKeyWindow {
    return YES;
}
- (BOOL)canBecomeMainWindow {
    return YES;
}
@end

static NSString* klioPlainString(id s) {
    return [s isKindOfClass:[NSAttributedString class]] ? [(NSAttributedString*)s string] : (NSString*)s;
}

static void klioCocoaSetMarked(KlioWindow* kw, NSString* text) {
    [kw->marked release];
    kw->marked = [text length] > 0 ? [text copy] : nil;
}

// The window's content view, the input method's client as AWT's view is.
// While a text field has the keyboard a key press goes to the input method
// first: what it composes and commits is queued as KLIO_EV_IME, and a press
// it passes on reaches the program as the key and the character it typed.
@interface KlioContentView : NSView <NSTextInputClient>
@property(nonatomic, assign) KlioWindow* kw;
@end

@implementation KlioContentView
- (BOOL)acceptsFirstResponder {
    return YES;
}
- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    KlioWindow* kw = _kw;
    if (!kw || !kw->textInput) return;
    NSString* text = klioPlainString(string);
    // One character a key typed with nothing composing is the key's own, as
    // AWT delivers it (the press then reaches the program, even after the
    // input method committed something before it); anything else is the
    // input method's commit.
    if (kw->inKey && !kw->marked && [text length] == 1) {
        kw->typed = [text UTF8String];
        kw->keyTaken = false;
        return;
    }
    klioCocoaSetMarked(kw, nil);
    kw->events.push_back(klioImeEv([text UTF8String], ""));
    kw->keyTaken = true;
}
- (void)doCommandBySelector:(SEL)selector {
    (void)selector;
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)selectedRange;
    (void)replacementRange;
    KlioWindow* kw = _kw;
    if (!kw || !kw->textInput) return;
    NSString* text = klioPlainString(string);
    const bool was = kw->marked != nil;
    klioCocoaSetMarked(kw, text);
    if (was || kw->marked) kw->events.push_back(klioImeEv("", [text UTF8String]));
    kw->keyTaken = true;
}
- (void)unmarkText {
    KlioWindow* kw = _kw;
    if (!kw || !kw->marked) return;
    NSString* text = [[kw->marked retain] autorelease];
    klioCocoaSetMarked(kw, nil);
    kw->events.push_back(klioImeEv([text UTF8String], ""));
}
- (NSRange)selectedRange {
    return NSMakeRange(_kw && _kw->marked ? [_kw->marked length] : 0, 0);
}
- (NSRange)markedRange {
    return _kw && _kw->marked ? NSMakeRange(0, [_kw->marked length]) : NSMakeRange(NSNotFound, 0);
}
- (BOOL)hasMarkedText {
    return _kw && _kw->marked != nil;
}
- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range;
    (void)actualRange;
    return nil;
}
- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range;
    (void)actualRange;
    KlioWindow* kw = _kw;
    if (!kw) return NSZeroRect;
    const NSRect r = kw->imeRect;
    const NSRect inView = NSMakeRect(r.origin.x, kw->h - r.origin.y - r.size.height, r.size.width, r.size.height);
    return [[self window] convertRectToScreen:[self convertRect:inView toView:nil]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    (void)point;
    return NSNotFound;
}
@end

// The close button asks the program, as a desktop window's does: the window
// stays open until the program closes it.
@interface KlioWindowDelegate : NSObject <NSWindowDelegate>
@property(nonatomic, assign) KlioWindow* kw;
@end

@implementation KlioWindowDelegate
- (BOOL)windowShouldClose:(NSWindow*)sender {
    (void)sender;
    if (_kw) {
        _kw->closeRequested = true;
        _kw->events.push_back(klioSimpleEv(KLIO_EV_CLOSE));
    }
    return NO;
}
@end

// A menu item's action: the item's id queued on its window, as
// KLIO_EV_MENU.
@interface KlioMenuTarget : NSObject
@property(nonatomic, assign) KlioWindow* kw;
- (void)klioMenuAction:(id)sender;
@end

@implementation KlioMenuTarget
- (void)klioMenuAction:(id)sender {
    if (!_kw) return;
    _kw->events.push_back(klioSimpleEv(KLIO_EV_MENU, static_cast<double>([(NSMenuItem*)sender tag])));
}
@end

// An AWT key code as a menu item's key equivalent, or "" for none.
static NSString* klioKeyEquivalent(int vk) {
    unichar c = 0;
    if (vk >= 'A' && vk <= 'Z') c = static_cast<unichar>(vk - 'A' + 'a');
    else if (vk >= '0' && vk <= '9') c = static_cast<unichar>(vk);
    else if (vk >= 112 && vk <= 123) c = static_cast<unichar>(NSF1FunctionKey + (vk - 112));
    else {
        switch (vk) {
            case 10: c = '\r'; break;
            case 8: c = 0x08; break;
            case 9: c = '\t'; break;
            case 27: c = 0x1B; break;
            case 32: c = ' '; break;
            case 127: c = NSDeleteFunctionKey; break;
            case 44: c = ','; break;
            case 45: c = '-'; break;
            case 46: c = '.'; break;
            case 47: c = '/'; break;
            case 59: c = ';'; break;
            case 61: c = '='; break;
            case 91: c = '['; break;
            case 92: c = '\\'; break;
            case 93: c = ']'; break;
            case 192: c = '`'; break;
            case 222: c = '\''; break;
            case 37: c = NSLeftArrowFunctionKey; break;
            case 38: c = NSUpArrowFunctionKey; break;
            case 39: c = NSRightArrowFunctionKey; break;
            case 40: c = NSDownArrowFunctionKey; break;
            case 36: c = NSHomeFunctionKey; break;
            case 35: c = NSEndFunctionKey; break;
            case 33: c = NSPageUpFunctionKey; break;
            case 34: c = NSPageDownFunctionKey; break;
            default: return @"";
        }
    }
    return [NSString stringWithCharacters:&c length:1];
}

static NSEventModifierFlags klioMenuModifierMask(int mods) {
    NSEventModifierFlags mask = 0;
    if (mods & KLIO_MOD_SHIFT) mask |= NSEventModifierFlagShift;
    if (mods & KLIO_MOD_CTRL) mask |= NSEventModifierFlagControl;
    if (mods & KLIO_MOD_ALT) mask |= NSEventModifierFlagOption;
    if (mods & KLIO_MOD_META) mask |= NSEventModifierFlagCommand;
    return mask;
}

static NSString* klioNSString(const std::string& s) {
    NSString* str = [[[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] autorelease];
    return str ?: @"";
}

// The window's main menu from its entries: the application menu, then its
// menus, as AWT's screen menu bar shows a frame's JMenuBar. Mnemonics have
// no place in macOS menus.
static void klioFillCocoaMenu(NSMenu* root, const std::vector<KlioMenuEntry>& entries, id target);

static NSMenu* klioBuildCocoaMenu(KlioWindow* kw) {
    NSMenu* bar = [[NSMenu alloc] init];
    [bar setAutoenablesItems:NO];
    klioAddAppMenu(bar);
    klioFillCocoaMenu(bar, kw->menuEntries, kw->menuTarget);
    return bar;
}

// Adds the entries' menus and items to a menu, their actions to the target.
static void klioFillCocoaMenu(NSMenu* root, const std::vector<KlioMenuEntry>& entries, id target) {
    std::vector<NSMenu*> stack = {root};
    for (const KlioMenuEntry& e : entries) {
        if (e.depth < 0 || static_cast<size_t>(e.depth) >= stack.size()) continue;
        stack.resize(static_cast<size_t>(e.depth) + 1);
        NSMenu* parent = stack.back();
        if (e.kind == 's') {
            [parent addItem:[NSMenuItem separatorItem]];
            continue;
        }
        NSMenuItem* item = [[[NSMenuItem alloc] initWithTitle:klioNSString(e.text)
                                                       action:nil
                                                keyEquivalent:@""] autorelease];
        [item setTag:e.id];
        [item setEnabled:e.enabled];
        if (e.kind == 'm') {
            NSMenu* sub = [[[NSMenu alloc] initWithTitle:klioNSString(e.text)] autorelease];
            [sub setAutoenablesItems:NO];
            [item setSubmenu:sub];
            [parent addItem:item];
            stack.push_back(sub);
            continue;
        }
        [item setTarget:target];
        [item setAction:@selector(klioMenuAction:)];
        if (e.kind == 'c' || e.kind == 'r') {
            [item setState:e.state ? NSControlStateValueOn : NSControlStateValueOff];
        }
        if (e.keycode != 0) {
            NSString* key = klioKeyEquivalent(e.keycode);
            if ([key length] > 0) {
                [item setKeyEquivalent:key];
                [item setKeyEquivalentModifierMask:klioMenuModifierMask(e.mods)];
            }
        }
        [parent addItem:item];
    }
}

// Debug: $KLIO_MENU_DUMP prints a window's native menu bar on stderr each
// time it is set, as the platform holds it.
static void klioDumpCocoaMenu(NSMenu* menu, int depth) {
    for (NSMenuItem* item in [menu itemArray]) {
        std::string line(static_cast<size_t>(depth) * 2, ' ');
        if ([item isSeparatorItem]) {
            fprintf(stderr, "[menu] %s---\n", line.c_str());
            continue;
        }
        line += [[item title] UTF8String];
        if (![item isEnabled]) line += " [disabled]";
        if ([item state] == NSControlStateValueOn) line += " [on]";
        if ([[item keyEquivalent] length] > 0) {
            const NSEventModifierFlags m = [item keyEquivalentModifierMask];
            line += " [key ";
            if (m & NSEventModifierFlagControl) line += "ctrl+";
            if (m & NSEventModifierFlagOption) line += "alt+";
            if (m & NSEventModifierFlagShift) line += "shift+";
            if (m & NSEventModifierFlagCommand) line += "cmd+";
            const unichar k = [[item keyEquivalent] characterAtIndex:0];
            char buf[16];
            if (k >= 0x20 && k < 0x7F) snprintf(buf, sizeof buf, "%c", static_cast<char>(k));
            else snprintf(buf, sizeof buf, "U+%04X", k);
            line += buf;
            line += "]";
        }
        fprintf(stderr, "[menu] %s\n", line.c_str());
        if ([item submenu]) klioDumpCocoaMenu([item submenu], depth + 1);
    }
}

// The menu item with the id, anywhere under the menu.
static NSMenuItem* klioCocoaMenuItem(NSMenu* menu, int id) {
    for (NSMenuItem* item in [menu itemArray]) {
        if ([item isSeparatorItem]) continue;
        if ([item submenu]) {
            if (NSMenuItem* found = klioCocoaMenuItem([item submenu], id)) return found;
        } else if ([item tag] == id && [item action] == @selector(klioMenuAction:)) {
            return item;
        }
    }
    return nil;
}

// Chooses the item at a path of titles as a click on it does: through its
// menu's action, when it and the menus it is in are enabled.
static void klioCocoaPerformPath(NSMenu* root, const std::vector<KlioMenuEntry>& entries, const std::string& path) {
    if (!root) return;
    const int index = klioMenuFindPath(entries, path);
    if (index < 0) return;
    NSMenuItem* item = klioCocoaMenuItem(root, entries[static_cast<size_t>(index)].id);
    if (!item) return;
    for (NSMenu* menu = [item menu]; menu && [menu supermenu]; menu = [menu supermenu]) {
        NSMenu* super = [menu supermenu];
        const NSInteger at = [super indexOfItemWithSubmenu:menu];
        if (at >= 0 && ![[super itemAtIndex:at] isEnabled]) return;
    }
    if (![item isEnabled]) return;
    NSMenu* menu = [item menu];
    [menu performActionForItemAtIndex:[menu indexOfItem:item]];
}

static void klioCocoaPerformMenuPath(KlioWindow* kw, const std::string& path) {
    klioCocoaPerformPath(kw->mainMenu, kw->menuEntries, path);
}

// The main screen's height, for AppKit's bottom-left screen coordinates to
// become the desktop's top-left ones.
static CGFloat klioMainScreenHeight() {
    NSScreen* main = [[NSScreen screens] firstObject];
    return main ? [main frame].size.height : 0;
}

// The window frame's top-left, in points from the main screen's top-left.
static void klioCocoaTopLeft(KlioWindow* kw, int* x, int* y) {
    const NSRect f = [kw->window frame];
    *x = static_cast<int>(f.origin.x);
    *y = static_cast<int>(klioMainScreenHeight() - (f.origin.y + f.size.height));
}

static int klioCocoaPlacement(KlioWindow* kw) {
    if ([kw->window styleMask] & NSWindowStyleMaskFullScreen) return KLIO_PLACEMENT_FULLSCREEN;
    if ([kw->window isZoomed]) return KLIO_PLACEMENT_MAXIMIZED;
    return KLIO_PLACEMENT_FLOATING;
}

// The open windows by their NSWindow: AppKit's event queue is the process's, so
// an event is translated for the window it happened in.
static std::vector<KlioWindow*>& klioCocoaWindows() {
    static std::vector<KlioWindow*> windows;
    return windows;
}

static KlioWindow* klioCocoaWindowOf(NSWindow* window) {
    if (!window) return nullptr;
    for (KlioWindow* kw : klioCocoaWindows()) {
        if (kw->window == window) return kw;
    }
    return nullptr;
}

// The modifiers the desktop reports, from AppKit's flags: Fn is not one.
static int klioCocoaMods(NSEventModifierFlags f) {
    int m = 0;
    if (f & NSEventModifierFlagShift) m |= KLIO_MOD_SHIFT;
    if (f & NSEventModifierFlagControl) m |= KLIO_MOD_CTRL;
    if (f & NSEventModifierFlagOption) m |= KLIO_MOD_ALT;
    if (f & NSEventModifierFlagCommand) m |= KLIO_MOD_META;
    if (f & NSEventModifierFlagCapsLock) m |= KLIO_MOD_CAPS_LOCK;
    return m;
}

// A mouse event's button: AppKit numbers them left 0, right 1, middle 2, then
// back 3 and forward 4.
static int klioCocoaButton(NSEvent* ev) {
    switch ([ev buttonNumber]) {
        case 0: return KLIO_BTN_PRIMARY;
        case 1: return KLIO_BTN_SECONDARY;
        case 2: return KLIO_BTN_TERTIARY;
        case 3: return KLIO_BTN_BACK;
        case 4: return KLIO_BTN_FORWARD;
        default: return KLIO_BTN_NONE;
    }
}

// Which device-dependent flag a modifier key's own state is in: the left and
// right keys of a pair are told apart (NX_DEVICE*KEYMASK).
static NSEventModifierFlags klioCocoaKeyFlag(unsigned short code) {
    switch (code) {
        case 0x38: return 0x02;      // left shift
        case 0x3C: return 0x04;      // right shift
        case 0x3B: return 0x01;      // left control
        case 0x3E: return 0x2000;    // right control
        case 0x3A: return 0x20;      // left option
        case 0x3D: return 0x40;      // right option
        case 0x37: return 0x08;      // left command
        case 0x36: return 0x10;      // right command
        case 0x39: return NSEventModifierFlagCapsLock;
        default: return 0;
    }
}

// Translates one AppKit event into the events of the window it happened in.
// Clears *forward for the events AppKit must not also handle (keys, which it
// would answer with a beep; a Command shortcut goes to the menu first).
static void klioCocoaTranslate(NSEvent* ev, bool* forward) {
    const NSEventType type = [ev type];
    KlioWindow* kw = klioCocoaWindowOf([ev window]);
    if (!kw) return;
    const int mods = klioCocoaMods([ev modifierFlags]);
    switch (type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeRightMouseDown:
        case NSEventTypeOtherMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseUp:
        case NSEventTypeOtherMouseUp:
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged:
        case NSEventTypeOtherMouseDragged:
        case NSEventTypeMouseEntered:
        case NSEventTypeMouseExited:
        case NSEventTypeScrollWheel: {
            // Content-view coordinates, top-left origin, whole points as AWT's.
            const NSPoint p = [kw->view convertPoint:[ev locationInWindow] fromView:nil];
            const double x = static_cast<int>(p.x);
            const double y = static_cast<int>(kw->h - p.y);
            const bool inside = x >= 0 && y >= 0 && x < kw->w && y < kw->h;
            if (type == NSEventTypeLeftMouseDown || type == NSEventTypeRightMouseDown ||
                type == NSEventTypeOtherMouseDown) {
                const int button = klioCocoaButton(ev);
                if (!inside || button == KLIO_BTN_NONE) return;  // the title bar's
                kw->buttons |= 1 << (button - 1);
                kw->events.push_back(klioPointerEv(KLIO_PTR_PRESS, x, y, button, kw->buttons, mods));
            } else if (type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp ||
                       type == NSEventTypeOtherMouseUp) {
                const int button = klioCocoaButton(ev);
                if (button == KLIO_BTN_NONE || !(kw->buttons & (1 << (button - 1)))) return;
                kw->buttons &= ~(1 << (button - 1));
                kw->events.push_back(klioPointerEv(KLIO_PTR_RELEASE, x, y, button, kw->buttons, mods));
            } else if (type == NSEventTypeMouseEntered) {
                kw->events.push_back(klioPointerEv(KLIO_PTR_ENTER, x, y, KLIO_BTN_NONE, kw->buttons, mods));
            } else if (type == NSEventTypeMouseExited) {
                kw->events.push_back(klioPointerEv(KLIO_PTR_EXIT, x, y, KLIO_BTN_NONE, kw->buttons, mods));
            } else if (type == NSEventTypeScrollWheel) {
                if (!inside) return;
                // AWT's wheel rotation runs opposite to AppKit's deltas.
                kw->events.push_back(klioPointerEv(KLIO_PTR_SCROLL, x, y, KLIO_BTN_NONE, kw->buttons,
                                                   mods, -[ev deltaX], -[ev deltaY]));
            } else {
                // A drag goes on outside the window; a hover stops at its edge.
                if (!inside && kw->buttons == 0) return;
                kw->events.push_back(klioPointerEv(KLIO_PTR_MOVE, x, y, KLIO_BTN_NONE, kw->buttons, mods));
            }
            return;
        }
        case NSEventTypeKeyDown:
        case NSEventTypeKeyUp: {
            *forward = false;
            const bool down = type == NSEventTypeKeyDown;
            // The application menu's shortcuts (Quit) go through AppKit; a
            // window menu bar's reach the program with the key, which matches
            // them as the desktop does.
            if (down && ([ev modifierFlags] & NSEventModifierFlagCommand)) {
                NSMenu* app = [[NSApp mainMenu] numberOfItems] > 0 ? [[[NSApp mainMenu] itemAtIndex:0] submenu] : nil;
                if (app && [app performKeyEquivalent:ev]) return;
            }
            int vk = 0;
            int loc = KLIO_LOC_STANDARD;
            klioMacKey([ev keyCode], &vk, &loc);
            NSString* chars = [ev characters];
            const unsigned c = [chars length] > 0 ? [chars characterAtIndex:0] : 0;
            // While a text field has the keyboard the input method sees a press
            // first; one it composes or commits with is its, as AWT's view
            // passes on only a press that leaves nothing composing.
            if (down && kw->textInput && !([ev modifierFlags] & NSEventModifierFlagCommand)) {
                kw->inKey = true;
                kw->keyTaken = false;
                kw->typed.clear();
                [[kw->view inputContext] handleEvent:ev];
                kw->inKey = false;
                if (kw->marked || kw->keyTaken) return;
                kw->events.push_back(klioKeyEv(down, vk, loc, klioAwtKeyChar(vk, c), mods));
                if (!kw->typed.empty()) klioPushText(kw->events, kw->typed.c_str());
                return;
            }
            kw->events.push_back(klioKeyEv(down, vk, loc, klioAwtKeyChar(vk, c), mods));
            // The characters a press types, unless Command makes it a shortcut;
            // a function key's character (AppKit's private-use range) types nothing.
            if (down && !([ev modifierFlags] & NSEventModifierFlagCommand) && [chars length] > 0 &&
                !(c >= 0xF700 && c <= 0xF8FF)) {
                klioPushText(kw->events, [chars UTF8String]);
            }
            return;
        }
        case NSEventTypeFlagsChanged: {
            *forward = false;
            const unsigned short code = [ev keyCode];
            const NSEventModifierFlags flag = klioCocoaKeyFlag(code);
            if (flag == 0) return;
            int vk = 0;
            int loc = KLIO_LOC_STANDARD;
            klioMacKey(code, &vk, &loc);
            const bool down = ([ev modifierFlags] & flag) != 0;
            kw->events.push_back(klioKeyEv(down, vk, loc, KLIO_CHAR_UNDEFINED, mods));
            return;
        }
        default:
            return;
    }
}

// Reports a moved window, a changed placement, and a content size changed
// without a live resize callback, as a resize with the drawable or surface
// resized to it.
static void klioCocoaCheckWindow(KlioWindow* kw) {
    int x = 0;
    int y = 0;
    klioCocoaTopLeft(kw, &x, &y);
    klioReportFrame(kw->frameReport, kw->events, x, y, klioCocoaPlacement(kw), [kw->window isMiniaturized]);
    if ([kw->window isMiniaturized]) return;
    const int nw = static_cast<int>([kw->view bounds].size.width);
    const int nh = static_cast<int>([kw->view bounds].size.height);
    if ((nw == kw->w && nh == kw->h) || nw <= 0 || nh <= 0) return;
#if defined(KLIO_METAL)
    if (kw->grContext && kw->metalLayer) {
        klioApplyMetalResize(kw, nw, nh);
        kw->metalLayer.frame = NSMakeRect(0, 0, nw, nh);
    } else
#endif
    {
        if (kw->surface) klio_skia_free(kw->surface);
        kw->surface = klio_skia_new(nw, nh);
    }
    kw->w = nw;
    kw->h = nh;
    kw->events.push_back(klioSimpleEv(KLIO_EV_RESIZE, nw, nh));
}

extern "C" {

// Waits up to timeoutMs for the window's next input event and writes its
// values to out (KLIO_EV_VALUES doubles); returns its type (window_events.h),
// or KLIO_EV_NONE when none came. Every event AppKit has ready is translated
// for the window it belongs to before the first is returned.
// The window's next event, a scripted menu choice performed on the way.
static int klioCocoaPop(KlioWindow* kw, double* out) {
    for (;;) {
        const int type = klioPopEv(kw->events, out, &kw->eventText);
        if (type != KLIO_EV_MENU_PATH) return type;
        const size_t at = static_cast<size_t>(out[0]);
        // A native menu is not left open: menushow is the drawn menus'.
        if (at < klioScriptTexts().size() && out[1] == 0) klioCocoaPerformMenuPath(kw, klioScriptTexts()[at]);
    }
}

int klio_win_poll_event(KlioWindow* kw, int timeoutMs, double* out) {
    if (!kw) return KLIO_EV_CLOSE;
    klioScriptTick(kw->script, kw->events);
    if (!kw->events.empty()) return klioCocoaPop(kw, out);
    @autoreleasepool {
        NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0];
        while (kw->events.empty()) {
            NSEvent* ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                             untilDate:until
                                                inMode:NSDefaultRunLoopMode
                                               dequeue:YES];
            if (!ev) break;
            until = [NSDate distantPast];
            bool forward = true;
            klioCocoaTranslate(ev, &forward);
            if (forward) [NSApp sendEvent:ev];
            for (KlioWindow* w : klioCocoaWindows()) klioCocoaCheckWindow(w);
        }
        klioCocoaCheckWindow(kw);
    }
    return klioCocoaPop(kw, out);
}

// Queues an event on the window as if its platform had sent it (the values as
// klio_win_poll_event reports them), for programs that drive a window's input.
void klio_win_post_event(KlioWindow* kw, int type, const double* values) {
    if (!kw || !values) return;
    KlioEv e;
    e.type = type;
    for (int i = 0; i < KLIO_EV_VALUES; i++) e.v[i] = values[i];
    kw->events.push_back(e);
}

// Drops the input method's composition without committing it.
static void klioCocoaDropComposition(KlioWindow* kw) {
    if (!kw->marked) return;
    klioCocoaSetMarked(kw, nil);
    [[kw->view inputContext] discardMarkedText];
}

// A text field has the keyboard, or none has: while one has it key presses go
// through the input method.
void klio_win_set_text_input(KlioWindow* kw, int enabled) {
    if (!kw) return;
    @autoreleasepool {
        kw->textInput = enabled != 0;
        if (!kw->textInput) klioCocoaDropComposition(kw);
    }
}

// The text field's cursor, in the window's content, where the input method
// places its candidate window.
void klio_win_set_text_input_rect(KlioWindow* kw, int x, int y, int w, int h) {
    if (!kw) return;
    kw->imeRect = NSMakeRect(x, y, w, h);
    @autoreleasepool {
        [[kw->view inputContext] invalidateCharacterCoordinates];
    }
}

// The text field ended the composition itself: the input method drops it.
void klio_win_end_composition(KlioWindow* kw) {
    if (!kw) return;
    @autoreleasepool {
        klioCocoaDropComposition(kw);
    }
}

// The system's emoji and symbols palette, as skiko opens it on macOS; what it
// picks reaches the focused field through the key window's input method.
void klio_order_emoji_palette(void) {
    @autoreleasepool {
        [NSApp orderFrontCharacterPalette:nil];
    }
}

// The text of the event klio_win_poll_event last returned.
size_t klio_win_event_text(KlioWindow* kw, char* buf, size_t cap) {
    return kw ? klioCopyEventText(kw->eventText, buf, cap) : 0;
}

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

// The app icon (Dock + Cmd-Tab) from encoded PNG bytes; NSImage decodes PNG
// natively. Written alongside the rest of the Cocoa backend, unverified here.
// A macOS window has no icon of its own (the Dock's is the application's),
// so a window's icon changes nothing, as on the desktop.
void klio_win_set_icon_surface(KlioWindow*, KlioSurface*) {}

void klio_win_set_icon_png(KlioWindow* kw, const unsigned char* png, size_t len) {
    (void)kw;
    if (!png || len == 0) return;
    @autoreleasepool {
        NSData* data = [NSData dataWithBytes:png length:len];
        NSImage* img = [[NSImage alloc] initWithData:data];
        if (img) [NSApp setApplicationIconImage:img];
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
        NSWindow* window = [[KlioNSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        if (!window) {
            klioWinFailed("AppKit could not create a window");
            return nullptr;
        }
        [window setReleasedWhenClosed:NO];  // we own its lifetime (non-ARC)
        if (title) [window setTitle:[NSString stringWithUTF8String:title]];
        KlioContentView* view = [[KlioContentView alloc] initWithFrame:frame];
        [window setContentView:view];
        [view release];  // the window holds it
        [window makeFirstResponder:view];
        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        auto* kw = new KlioWindow();
        kw->window = window;
        kw->view = view;
        view.kw = kw;
        kw->w = w;
        kw->h = h;
        kw->surface = nullptr;
        kw->resizeCb = nullptr;
        kw->resizeCtx = nullptr;
        kw->buttons = 0;
        kw->closeRequested = false;
        kw->resizable = true;
        klioCocoaWindows().push_back(kw);
        KlioWindowDelegate* delegate = [[KlioWindowDelegate alloc] init];
        delegate.kw = kw;
        [window setDelegate:delegate];
        kw->delegate = delegate;
        // The platform's default place: cascaded from the top-left, as AWT's
        // location by platform puts a frame.
        static NSPoint cascade = NSZeroPoint;
        if (NSEqualPoints(cascade, NSZeroPoint)) {
            NSScreen* screen = [NSScreen mainScreen];
            const NSRect visible = screen ? [screen visibleFrame] : NSMakeRect(0, 0, 0, 0);
            cascade = NSMakePoint(visible.origin.x, visible.origin.y + visible.size.height);
        }
        cascade = [window cascadeTopLeftFromPoint:cascade];
        // Moves over the window, and its enters and exits, reach the event queue.
        [window setAcceptsMouseMovedEvents:YES];
        kw->tracking = [[NSTrackingArea alloc]
            initWithRect:NSZeroRect
                 options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                          NSTrackingInVisibleRect)
                   owner:view
                userInfo:nil];
        [view addTrackingArea:kw->tracking];
        // The window gaining and losing the keyboard focus.
        kw->focusObservers[0] = [[[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidBecomeKeyNotification
                        object:window
                         queue:nil
                    usingBlock:^(NSNotification* note) {
                        (void)note;
                        if (!klioScriptDrivesFocus()) kw->events.push_back(klioSimpleEv(KLIO_EV_FOCUS, 1));
                        NSMenu* menu = kw->mainMenu ?: klioDefaultMainMenu();
                        if (menu) [NSApp setMainMenu:menu];
                    }] retain];
        kw->focusObservers[1] = [[[NSNotificationCenter defaultCenter]
            addObserverForName:NSWindowDidResignKeyNotification
                        object:window
                         queue:nil
                    usingBlock:^(NSNotification* note) {
                        (void)note;
                        if (!klioScriptDrivesFocus()) kw->events.push_back(klioSimpleEv(KLIO_EV_FOCUS, 0));
                    }] retain];
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
            klio_win_close(kw);
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
        // Idempotent within a frame: the frame acquires the surface once, then
        // clears + draws into it (winClear re-requests it), then presents (which
        // frees it). Return the live surface so the drawing code never sees a
        // freed one; only wrap a fresh drawable when there is no current surface.
        if (kw->surface) return kw->surface;
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
        // factor so the frame (in points) rasterizes at full resolution.
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
        klioPresentDump(kw->surface);
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
    klioPresentDump(kw->surface);
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


// Sets one of a window's KLIO_WIN_* properties: whether the user can resize
// it, whether it has a title bar and border, whether it floats above other
// windows, whether it shows, whether it is minimized, its placement.
void klio_win_set_flag(KlioWindow* kw, int which, int value) {
    if (!kw || !kw->window) return;
    @autoreleasepool {
        NSWindow* w = kw->window;
        switch (which) {
            case KLIO_WIN_RESIZABLE:
                kw->resizable = value != 0;
                if (value) [w setStyleMask:[w styleMask] | NSWindowStyleMaskResizable];
                else [w setStyleMask:[w styleMask] & ~NSWindowStyleMaskResizable];
                break;
            case KLIO_WIN_DECORATED: {
                NSWindowStyleMask mask = value
                    ? (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
                    : NSWindowStyleMaskBorderless;
                if (kw->resizable) mask |= NSWindowStyleMaskResizable;
                // A new style mask keeps the window's frame, not its content size.
                const NSRect content = [w contentRectForFrameRect:[w frame]];
                [w setStyleMask:mask];
                [w setFrame:[w frameRectForContentRect:content] display:YES];
                break;
            }
            case KLIO_WIN_ALWAYS_ON_TOP:
                [w setLevel:value ? NSFloatingWindowLevel : NSNormalWindowLevel];
                break;
            case KLIO_WIN_VISIBLE:
                if (value) [w makeKeyAndOrderFront:nil];
                else [w orderOut:nil];
                break;
            case KLIO_WIN_MINIMIZED:
                if (value) [w miniaturize:nil];
                else [w deminiaturize:nil];
                break;
            case KLIO_WIN_PLACEMENT: {
                const int now = klioCocoaPlacement(kw);
                if (now == value) break;
                if (now == KLIO_PLACEMENT_FULLSCREEN || value == KLIO_PLACEMENT_FULLSCREEN) {
                    [w toggleFullScreen:nil];
                }
                if (value == KLIO_PLACEMENT_MAXIMIZED && ![w isZoomed]) [w zoom:nil];
                if (value == KLIO_PLACEMENT_FLOATING && [w isZoomed]) [w zoom:nil];
                break;
            }
            case KLIO_WIN_FRONT:
                [NSApp activateIgnoringOtherApps:YES];
                [w makeKeyAndOrderFront:nil];
                break;
            case KLIO_WIN_TRANSPARENT:
                [w setOpaque:value ? NO : YES];
                [w setBackgroundColor:value ? [NSColor clearColor] : [NSColor windowBackgroundColor]];
                kw->view.layer.opaque = value ? NO : YES;
#if defined(KLIO_METAL)
                if (kw->metalLayer) kw->metalLayer.opaque = value ? NO : YES;
#endif
                break;
            default:
                break;
        }
    }
}

// Moves the window frame's top-left to (x, y), in points from the main
// screen's top-left.
void klio_win_set_position(KlioWindow* kw, int x, int y) {
    if (!kw || !kw->window) return;
    @autoreleasepool {
        [kw->window setFrameTopLeftPoint:NSMakePoint(x, klioMainScreenHeight() - y)];
        int nx = 0;
        int ny = 0;
        klioCocoaTopLeft(kw, &nx, &ny);
        klioBaselineMove(kw->frameReport, kw->events, x, y, nx, ny, klioCocoaPlacement(kw),
                         [kw->window isMiniaturized]);
    }
}

void klio_win_get_position(KlioWindow* kw, int* x, int* y) {
    if (!kw || !kw->window || !x || !y) return;
    klioCocoaTopLeft(kw, x, y);
}

// Resizes the window's frame, title bar and border included, keeping its
// top-left where it is.
void klio_win_set_frame_size(KlioWindow* kw, int w, int h) {
    if (!kw || !kw->window || w <= 0 || h <= 0) return;
    @autoreleasepool {
        const NSRect f = [kw->window frame];
        const CGFloat top = f.origin.y + f.size.height;
        [kw->window setFrame:NSMakeRect(f.origin.x, top - h, w, h) display:YES];
    }
}

void klio_win_get_frame_size(KlioWindow* kw, int* w, int* h) {
    if (!kw || !kw->window || !w || !h) return;
    const NSRect f = [kw->window frame];
    *w = static_cast<int>(f.size.width);
    *h = static_cast<int>(f.size.height);
}

// The main screen's area for windows (without the menu bar and the Dock), in
// points from its top-left.
void klio_win_screen_bounds(int* x, int* y, int* w, int* h) {
    if (!x || !y || !w || !h) return;
    @autoreleasepool {
        NSScreen* screen = [NSScreen mainScreen];
        if (!screen) {
            *x = *y = *w = *h = 0;
            return;
        }
        const NSRect v = [screen visibleFrame];
        *x = static_cast<int>(v.origin.x);
        *y = static_cast<int>(klioMainScreenHeight() - (v.origin.y + v.size.height));
        *w = static_cast<int>(v.size.width);
        *h = static_cast<int>(v.size.height);
    }
}

void klio_win_close(KlioWindow* kw) {
    if (!kw) return;
    if (kw->delegate) {
        [kw->window setDelegate:nil];
        [kw->delegate release];
        kw->delegate = nil;
    }
    if ([kw->view isKindOfClass:[KlioContentView class]]) ((KlioContentView*)kw->view).kw = nullptr;
    klioCocoaSetMarked(kw, nil);
    auto& windows = klioCocoaWindows();
    for (size_t i = 0; i < windows.size(); i++) {
        if (windows[i] == kw) {
            windows.erase(windows.begin() + static_cast<long>(i));
            break;
        }
    }
    if (kw->resizeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:kw->resizeObserver];
        [kw->resizeObserver release];
        kw->resizeObserver = nil;
    }
    for (id& observer : kw->focusObservers) {
        if (observer) {
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
            [observer release];
            observer = nil;
        }
    }
    if (kw->tracking) {
        [kw->view removeTrackingArea:kw->tracking];
        [kw->tracking release];
        kw->tracking = nil;
    }
    if (kw->mainMenu) {
        if ([NSApp mainMenu] == kw->mainMenu && klioDefaultMainMenu()) [NSApp setMainMenu:klioDefaultMainMenu()];
        [kw->mainMenu release];
        kw->mainMenu = nil;
    }
    if (kw->menuTarget) {
        [kw->menuTarget release];
        kw->menuTarget = nil;
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

// A tray icon: a status item in the menu bar, its menu, and the events of its
// action and menu, which the program polls.
struct KlioTray {
    NSStatusItem* item = nil;
    NSMenu* menu = nil;  // nil while the menu has no items
    id target = nil;     // KlioTrayTarget
    std::deque<KlioEv> events;
    std::vector<KlioMenuEntry> menuEntries;
    KlioScriptState script;
};

// A tray's clicks and menu choices: a left click shows its menu, a right one
// is its action, as the desktop's macOS tray icon has them.
@interface KlioTrayTarget : NSObject
@property(nonatomic, assign) KlioTray* tray;
- (void)klioMenuAction:(id)sender;
- (void)klioTrayClicked:(id)sender;
@end

@implementation KlioTrayTarget
- (void)klioMenuAction:(id)sender {
    if (!_tray) return;
    _tray->events.push_back(klioSimpleEv(KLIO_EV_MENU, static_cast<double>([(NSMenuItem*)sender tag])));
}
- (void)klioTrayClicked:(id)sender {
    (void)sender;
    if (!_tray) return;
    NSEvent* ev = [NSApp currentEvent];
    const bool right = [ev type] == NSEventTypeRightMouseUp ||
                       ([ev modifierFlags] & NSEventModifierFlagControl);
    if (right) {
        _tray->events.push_back(klioSimpleEv(KLIO_EV_TRAY_ACTION));
        return;
    }
    if (_tray->menu) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [_tray->item popUpStatusItemMenu:_tray->menu];
#pragma clang diagnostic pop
    }
}
@end

int klio_tray_supported(void) { return 1; }

void* klio_tray_open(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        klioSetupMenu(nullptr);
        auto* tray = new KlioTray();
        tray->item = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength] retain];
        KlioTrayTarget* target = [[KlioTrayTarget alloc] init];
        target.tray = tray;
        tray->target = target;
        NSStatusBarButton* button = [tray->item button];
        [button setTarget:target];
        [button setAction:@selector(klioTrayClicked:)];
        [button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];
        return tray;
    }
}

void klio_tray_close(void* t) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return;
    @autoreleasepool {
        [[NSStatusBar systemStatusBar] removeStatusItem:tray->item];
        [tray->item release];
        if (tray->menu) [tray->menu release];
        ((KlioTrayTarget*)tray->target).tray = nullptr;
        [tray->target release];
    }
    delete tray;
}

// The tray's icon from a drawn surface, at the menu bar's 22 points.
void klio_tray_set_icon(void* t, KlioSurface* s) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray || !s) return;
    @autoreleasepool {
        size_t len = 0;
        uint8_t* png = klio_skia_encode_png(s, &len);
        if (!png) return;
        NSImage* image = [[[NSImage alloc] initWithData:[NSData dataWithBytes:png length:len]] autorelease];
        klio_skia_free_buffer(png);
        if (!image) return;
        [image setSize:NSMakeSize(22, 22)];
        [[tray->item button] setImage:image];
    }
}

void klio_tray_set_tooltip(void* t, const char* utf8, size_t len) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return;
    @autoreleasepool {
        [[tray->item button] setToolTip:utf8 ? klioNSString(std::string(utf8, len)) : nil];
    }
}

void klio_tray_set_menu(void* t, const char* spec, size_t len) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return;
    @autoreleasepool {
        tray->menuEntries = klioParseMenu(spec, len);
        if (tray->menu) [tray->menu release];
        tray->menu = nil;
        if (!tray->menuEntries.empty()) {
            tray->menu = [[NSMenu alloc] init];
            [tray->menu setAutoenablesItems:NO];
            klioFillCocoaMenu(tray->menu, tray->menuEntries, tray->target);
            if (std::getenv("KLIO_MENU_DUMP")) {
                fprintf(stderr, "[menu] tray menu\n");
                klioDumpCocoaMenu(tray->menu, 0);
            }
        }
    }
}

// A notification from the tray, as the desktop's shows one through the user
// notification center; a process without an application bundle has no
// center, and shows none, as the desktop's does.
void klio_tray_notify(void* t, const char* title, size_t tlen, const char* message, size_t mlen, int type) {
    if (!t) return;
    const std::string ts = title ? std::string(title, tlen) : std::string();
    const std::string ms = message ? std::string(message, mlen) : std::string();
    if (std::getenv("KLIO_MENU_DUMP")) {
        fprintf(stderr, "[menu] tray notification %d: %s / %s\n", type, ts.c_str(), ms.c_str());
    }
    @autoreleasepool {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (![[NSBundle mainBundle] bundleIdentifier]) return;
        NSUserNotificationCenter* center = [NSUserNotificationCenter defaultUserNotificationCenter];
        if (!center) return;
        NSUserNotification* note = [[[NSUserNotification alloc] init] autorelease];
        [note setTitle:klioNSString(ts)];
        [note setInformativeText:klioNSString(ms)];
        [center deliverNotification:note];
#pragma clang diagnostic pop
    }
}

int klio_tray_poll_event(void* t, double* out) {
    auto* tray = static_cast<KlioTray*>(t);
    if (!tray) return KLIO_EV_NONE;
    klioScriptTick(tray->script, tray->events, true);
    for (;;) {
        const int type = klioPopEv(tray->events, out);
        if (type != KLIO_EV_MENU_PATH) return type;
        const size_t at = static_cast<size_t>(out[0]);
        if (at < klioScriptTexts().size()) klioCocoaPerformPath(tray->menu, tray->menuEntries, klioScriptTexts()[at]);
    }
}

// Runs the application's events for up to the timeout, while no window's
// poll runs them (an application with only a tray).
void klio_app_wait(int timeoutMs) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSDate* until = [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0];
        for (;;) {
            NSEvent* ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                                             untilDate:until
                                                inMode:NSDefaultRunLoopMode
                                               dequeue:YES];
            if (!ev) break;
            [NSApp sendEvent:ev];
            until = [NSDate distantPast];
        }
    }
}

// Sets the window's menu bar from its entries (window_events.h), or removes
// it for an empty spec: the application's main menu while the window is key,
// as the desktop's screen menu bar is.
void klio_win_set_menu(KlioWindow* kw, const char* spec, size_t len) {
    if (!kw) return;
    @autoreleasepool {
        kw->menuEntries = klioParseMenu(spec, len);
        if (!kw->menuTarget) {
            KlioMenuTarget* target = [[KlioMenuTarget alloc] init];
            target.kw = kw;
            kw->menuTarget = target;
        }
        NSMenu* old = kw->mainMenu;
        kw->mainMenu = kw->menuEntries.empty() ? nil : klioBuildCocoaMenu(kw);
        if ([kw->window isKeyWindow]) {
            NSMenu* menu = kw->mainMenu ?: klioDefaultMainMenu();
            if (menu) [NSApp setMainMenu:menu];
        }
        if (old) [old release];
        if (std::getenv("KLIO_MENU_DUMP") && kw->mainMenu) {
            fprintf(stderr, "[menu] menu bar\n");
            NSArray* items = [kw->mainMenu itemArray];
            for (NSUInteger i = 1; i < [items count]; i++) {
                NSMenuItem* item = items[i];
                std::string line = [[item title] UTF8String];
                if (![item isEnabled]) line += " [disabled]";
                fprintf(stderr, "[menu] %s\n", line.c_str());
                if ([item submenu]) klioDumpCocoaMenu([item submenu], 1);
            }
        }
    }
}

// Sets the icon of the menu item with the id from a drawn surface.
void klio_win_set_menu_icon(KlioWindow* kw, int id, KlioSurface* s) {
    if (!kw || !kw->mainMenu || !s) return;
    @autoreleasepool {
        NSMenuItem* item = klioCocoaMenuItem(kw->mainMenu, id);
        if (!item) return;
        size_t len = 0;
        uint8_t* png = klio_skia_encode_png(s, &len);
        if (!png) return;
        NSImage* image = [[[NSImage alloc] initWithData:[NSData dataWithBytes:png length:len]] autorelease];
        klio_skia_free_buffer(png);
        if (!image) return;
        [image setSize:NSMakeSize(16, 16)];
        [item setImage:image];
        if (std::getenv("KLIO_MENU_DUMP")) {
            fprintf(stderr, "[menu] icon of %s: %dx%d pixels\n", [[item title] UTF8String],
                    klio_skia_surf_size(s, 0), klio_skia_surf_size(s, 1));
        }
    }
}

// The host clipboard, as text: a count that moves whenever any application
// changes it (-1 when the host has none), its text as malloc'd UTF-8 that
// klio_skia_free_cstr frees (null when it holds no text), and replacing its
// contents with a text (null empties it).
// An NSString as malloc'd UTF-8, with its length.
static char* klioCopyUtf8(NSString* s, size_t* len) {
    if (!s) return nullptr;
    NSData* d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nullptr;
    const size_t n = [d length];
    char* out = static_cast<char*>(std::malloc(n + 1));
    if (!out) return nullptr;
    std::memcpy(out, [d bytes], n);
    out[n] = 0;
    if (len) *len = n;
    return out;
}

long long klio_clip_change_count(void) {
    @autoreleasepool {
        return static_cast<long long>([[NSPasteboard generalPasteboard] changeCount]);
    }
}

char* klio_clip_get_text(size_t* len) {
    @autoreleasepool {
        NSString* s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        return klioCopyUtf8(s, len);
    }
}

void klio_clip_set_text(const char* utf8, size_t len) {
    @autoreleasepool {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        if (!utf8) return;
        NSString* s = [[[NSString alloc] initWithBytes:utf8 length:len encoding:NSUTF8StringEncoding] autorelease];
        if (s) [pb setString:s forType:NSPasteboardTypeString];
    }
}

// The host's default locale as a language tag, malloc'd (klio_skia_free_cstr
// frees it), as the JVM takes it on Apple platforms: the first of the user's
// preferred languages, with the current locale's region when it has none.
char* klio_host_locale(void) {
    @autoreleasepool {
        NSArray<NSString*>* languages = [NSLocale preferredLanguages];
        NSString* tag = languages.count > 0 ? languages[0] : @"en";
        NSArray<NSString*>* parts = [tag componentsSeparatedByString:@"-"];
        const bool noRegion = parts.count == 1 || (parts.count == 2 && [parts[1] length] == 4);
        if (noRegion) {
            NSString* region = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
            if (region.length > 0) tag = [NSString stringWithFormat:@"%@-%@", tag, region];
        }
        return klioCopyUtf8(tag, nullptr);
    }
}

}  // extern "C"

#elif defined(__APPLE__) && defined(KLIO_UIKIT)

// iOS backend (compiled as Objective-C++). The OS owns the view and the run
// loop, so the shim ATTACHES to an app-provided CAMetalLayer (from a UIView)
// rather than creating a window, and the app's CADisplayLink drives frames by
// calling the runtime's render entry, which calls klio_win_surface/present
// here. Same Ganesh-Metal path as the macOS Cocoa+Metal backend.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <cstdio>
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

struct KlioWindow {
    CAMetalLayer* metalLayer;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    sk_sp<GrDirectContext> grContext;
    GrMTLHandle drawable;   // this frame's CAMetalDrawable, held until present
    CGFloat backingScale;   // points -> pixels
    int w;
    int h;
    KlioSurface* surface;
};

extern "C" {

// Attach to an app-provided CAMetalLayer. `w`/`h` are in points, `scale` is the
// screen's contentsScale (UIScreen.scale). Brings up a Metal device + Ganesh
// context rendering into the layer's drawables. Null on failure.
KlioWindow* klio_win_attach(void* caMetalLayer, int w, int h, double scale) {
    if (!caMetalLayer) return nullptr;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return nullptr;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) { [device release]; return nullptr; }
    CGFloat s = scale < 1.0 ? 1.0 : scale;
    CAMetalLayer* layer = (__bridge CAMetalLayer*)caMetalLayer;
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = NO;
    layer.contentsScale = s;
    layer.drawableSize = CGSizeMake(w * s, h * s);
    layer.opaque = YES;

    GrMtlBackendContext backend = {};
    backend.fDevice.retain((GrMTLHandle)(__bridge void*)device);
    backend.fQueue.retain((GrMTLHandle)(__bridge void*)queue);
    sk_sp<GrDirectContext> ctx = GrDirectContexts::MakeMetal(backend);
    if (!ctx) { [queue release]; [device release]; return nullptr; }

    KlioWindow* kw = new KlioWindow();
    kw->metalLayer = [layer retain];
    kw->device = device;
    kw->queue = queue;
    kw->grContext = ctx;
    kw->drawable = nullptr;
    kw->backingScale = s;
    kw->w = w;
    kw->h = h;
    kw->surface = nullptr;
    // The GPU surface never goes through klio_skia_new, so load the typeface
    // here or text draws are silently skipped.
    ensureFonts();
    if (std::getenv("KLIO_SKIA_VERBOSE"))
        fprintf(stderr, "[klio-skia] ios backend: Metal (GPU)\n");
    return kw;
}

KlioSurface* klio_win_surface(KlioWindow* kw) {
    if (!kw || !kw->grContext || !kw->metalLayer) return nullptr;
    // Idempotent within a frame: a frame acquires the surface once (winSurface),
    // then clears + draws into that same surface (winClear re-requests it), and
    // finally presents (which frees it). Freeing + re-acquiring here instead
    // would hand the drawing code a dangling surface.
    if (kw->surface) return kw->surface;
    if (kw->drawable) { CFRelease(kw->drawable); kw->drawable = nullptr; }
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
    if (kw->backingScale != 1.0)
        surf->getCanvas()->scale(kw->backingScale, kw->backingScale);
    kw->drawable = (GrMTLHandle)CFRetain((CFTypeRef)d);
    kw->surface = new KlioSurface();
    kw->surface->surface = surf;
    return kw->surface;
}

void klio_win_present(KlioWindow* kw) {
    if (!kw || !kw->grContext || !kw->metalLayer) return;
    if (!kw->surface || !kw->drawable) return;
    kw->grContext->flushAndSubmit(kw->surface->surface.get(), GrSyncCpu::kNo);
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
}

void klio_win_close(KlioWindow* kw) {
    if (!kw) return;
    if (kw->surface) klio_skia_free(kw->surface);
    if (kw->drawable) { CFRelease(kw->drawable); kw->drawable = nullptr; }
    kw->grContext.reset();
    if (kw->metalLayer) { [kw->metalLayer release]; kw->metalLayer = nil; }
    if (kw->queue) { [kw->queue release]; kw->queue = nil; }
    if (kw->device) { [kw->device release]; kw->device = nil; }
    delete kw;
}

// The OS owns the run loop on iOS: no shim-side window creation or event poll.
// These satisfy the C ABI the interpreter resolves; input arrives via the app's
// UITouch handling, not a poll.
KlioWindow* klio_win_open(int, int, const char*) {
    klioWinFailed("iOS gives an application its window; it cannot open another");
    return nullptr;
}
int klio_win_poll_event(void*, int, double*) { return KLIO_EV_NONE; }
void klio_win_post_event(void*, int, const double*) {}
void klio_win_set_text_input(void*, int) {}
void klio_win_set_text_input_rect(void*, int, int, int, int) {}
void klio_win_end_composition(void*) {}
void klio_order_emoji_palette(void) {}
size_t klio_win_event_text(void*, char* buf, size_t cap) {
    if (buf && cap > 0) buf[0] = 0;
    return 0;
}
void klio_win_set_flag(void*, int, int) {}
void klio_win_set_position(void*, int, int) {}
void klio_win_get_position(void*, int* x, int* y) { if (x) *x = 0; if (y) *y = 0; }
void klio_win_set_frame_size(void*, int, int) {}
void klio_win_get_frame_size(void*, int* w, int* h) { if (w) *w = 0; if (h) *h = 0; }
void klio_win_screen_bounds(int* x, int* y, int* w, int* h) { if (x) *x = 0; if (y) *y = 0; if (w) *w = 0; if (h) *h = 0; }
void klio_win_set_title(KlioWindow*, const char*) {}
void klio_win_set_size(KlioWindow* kw, int w, int h) { if (kw) { kw->w = w; kw->h = h; } }
void klio_win_set_icon_png(KlioWindow*, const unsigned char*, size_t) {}
void klio_win_set_icon_surface(KlioWindow*, KlioSurface*) {}
void klio_win_set_menu(KlioWindow*, const char*, size_t) {}
void klio_win_set_menu_icon(KlioWindow*, int, KlioSurface*) {}

// No tray icons: the desktop's Tray says so on standard error.
int klio_tray_supported(void) { return 0; }
void* klio_tray_open(void) { return nullptr; }
void klio_tray_close(void*) {}
void klio_tray_set_icon(void*, void*) {}
void klio_tray_set_tooltip(void*, const char*, size_t) {}
void klio_tray_set_menu(void*, const char*, size_t) {}
void klio_tray_notify(void*, const char*, size_t, const char*, size_t, int) {}
int klio_tray_poll_event(void*, double*) { return KLIO_EV_NONE; }
void klio_app_wait(int timeoutMs) {
    if (timeoutMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
}
void klio_win_set_resize_cb(KlioWindow*, void (*)(void*, int, int), void*) {}

// The host clipboard, as text: a count that moves whenever any application
// changes it (-1 when the host has none), its text as malloc'd UTF-8 that
// klio_skia_free_cstr frees (null when it holds no text), and replacing its
// contents with a text (null empties it).
// An NSString as malloc'd UTF-8, with its length.
static char* klioCopyUtf8(NSString* s, size_t* len) {
    if (!s) return nullptr;
    NSData* d = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return nullptr;
    const size_t n = [d length];
    char* out = static_cast<char*>(std::malloc(n + 1));
    if (!out) return nullptr;
    std::memcpy(out, [d bytes], n);
    out[n] = 0;
    if (len) *len = n;
    return out;
}

long long klio_clip_change_count(void) {
    @autoreleasepool {
        return static_cast<long long>([UIPasteboard generalPasteboard].changeCount);
    }
}

char* klio_clip_get_text(size_t* len) {
    @autoreleasepool {
        return klioCopyUtf8([UIPasteboard generalPasteboard].string, len);
    }
}

void klio_clip_set_text(const char* utf8, size_t len) {
    @autoreleasepool {
        UIPasteboard* pb = [UIPasteboard generalPasteboard];
        NSString* s = utf8 ? [[[NSString alloc] initWithBytes:utf8 length:len encoding:NSUTF8StringEncoding] autorelease] : nil;
        if (s) pb.string = s;
        else pb.items = @[];
    }
}

// The host's default locale as a language tag, malloc'd (klio_skia_free_cstr
// frees it), as the JVM takes it on Apple platforms: the first of the user's
// preferred languages, with the current locale's region when it has none.
char* klio_host_locale(void) {
    @autoreleasepool {
        NSArray<NSString*>* languages = [NSLocale preferredLanguages];
        NSString* tag = languages.count > 0 ? languages[0] : @"en";
        NSArray<NSString*>* parts = [tag componentsSeparatedByString:@"-"];
        const bool noRegion = parts.count == 1 || (parts.count == 2 && [parts[1] length] == 4);
        if (noRegion) {
            NSString* region = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
            if (region.length > 0) tag = [NSString stringWithFormat:@"%@-%@", tag, region];
        }
        return klioCopyUtf8(tag, nullptr);
    }
}

}  // extern "C"

#elif defined(KLIO_ANDROID)

// Android backend: attach to an app-provided ANativeWindow (from a
// NativeActivity's SurfaceView), bring up an EGL context + a GLES-backed Ganesh
// surface, and let the app's Choreographer drive frames — the GLES analogue of
// the iOS Cocoa/Metal path. The OS owns the view + run loop, so there is no
// shim-side window creation or event poll.
#include <android/native_window.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <time.h>
#include "include/gpu/ganesh/GrBackendSurface.h"
#include "include/gpu/ganesh/GrDirectContext.h"
#include "include/gpu/ganesh/GrTypes.h"
#include "include/gpu/ganesh/SkSurfaceGanesh.h"
#include "include/gpu/ganesh/gl/GrGLBackendSurface.h"
#include "include/gpu/ganesh/gl/GrGLDirectContext.h"
#include "include/gpu/ganesh/gl/GrGLInterface.h"
#include "include/gpu/ganesh/gl/GrGLTypes.h"
#include "include/gpu/ganesh/gl/egl/GrGLMakeEGLInterface.h"

struct KlioWindow {
    ANativeWindow* nwin;
    EGLDisplay display;
    EGLContext context;
    EGLSurface eglSurface;
    sk_sp<GrDirectContext> grContext;
    KlioSurface* surface;   // this frame's wrapped GL framebuffer, freed at present
    double scale;           // points -> pixels
    int w;                  // points
    int h;
};

extern "C" {

// Frame-time perf split for the native host: monotonic timestamps captured at
// the shim boundaries. renderWindowFrame runs recompose+layout, then calls
// klio_win_surface, then records the draw, then klio_win_present (flush+swap).
// So surface-frameStart = recompose+layout, present-surface = draw, and
// klio_perf_swap_ns = the eglSwapBuffers wait.
long klio_perf_surface_ns = 0;
long klio_perf_present_ns = 0;
long klio_perf_swap_ns = 0;
long klio_perf_surface_calls = 0;   // ground-truth: winSurface acquisitions
static long klio_now_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000000000L + ts.tv_nsec;
}

// Attach to an ANativeWindow. `w`/`h` are in points, `scale` the display density.
KlioWindow* klio_win_attach(void* nativeWindow, int w, int h, double scale) {
    ANativeWindow* nwin = static_cast<ANativeWindow*>(nativeWindow);
    if (!nwin) return nullptr;
    EGLDisplay dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (dpy == EGL_NO_DISPLAY) return nullptr;
    if (!eglInitialize(dpy, nullptr, nullptr)) return nullptr;
    const EGLint cfgAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_STENCIL_SIZE, 8,
        EGL_NONE,
    };
    EGLConfig cfg;
    EGLint num = 0;
    if (!eglChooseConfig(dpy, cfgAttribs, &cfg, 1, &num) || num < 1) return nullptr;
    const EGLint ctxAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctxAttribs);
    if (ctx == EGL_NO_CONTEXT) return nullptr;
    EGLSurface surf = eglCreateWindowSurface(dpy, cfg, nwin, nullptr);
    if (surf == EGL_NO_SURFACE) { eglDestroyContext(dpy, ctx); return nullptr; }
    if (!eglMakeCurrent(dpy, surf, surf, ctx)) {
        eglDestroySurface(dpy, surf);
        eglDestroyContext(dpy, ctx);
        return nullptr;
    }
    sk_sp<const GrGLInterface> iface = GrGLInterfaces::MakeEGL();
    sk_sp<GrDirectContext> grCtx = GrDirectContexts::MakeGL(iface);
    if (!grCtx) {
        eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(dpy, surf);
        eglDestroyContext(dpy, ctx);
        return nullptr;
    }
    KlioWindow* kw = new KlioWindow();
    kw->nwin = nwin;
    kw->display = dpy;
    kw->context = ctx;
    kw->eglSurface = surf;
    kw->grContext = grCtx;
    kw->surface = nullptr;
    kw->scale = scale < 1.0 ? 1.0 : scale;
    kw->w = w;
    kw->h = h;
    ensureFonts();
    if (std::getenv("KLIO_SKIA_VERBOSE"))
        fprintf(stderr, "[klio-skia] android backend: GLES (Ganesh)\n");
    return kw;
}

KlioSurface* klio_win_surface(KlioWindow* kw) {
    if (!kw || !kw->grContext) return nullptr;
    // Idempotent within a frame: acquire once, clear + draw into it, then present
    // (which frees it). Wrap the window's default framebuffer (FBO 0).
    if (kw->surface) return kw->surface;
    klio_perf_surface_ns = klio_now_ns();
    klio_perf_surface_calls++;
    EGLint pw = 0, ph = 0;
    eglQuerySurface(kw->display, kw->eglSurface, EGL_WIDTH, &pw);
    eglQuerySurface(kw->display, kw->eglSurface, EGL_HEIGHT, &ph);
    GrGLFramebufferInfo fbInfo;
    fbInfo.fFBOID = 0;
    fbInfo.fFormat = GL_RGBA8;
    GrBackendRenderTarget backendRT = GrBackendRenderTargets::MakeGL(pw, ph, 0, 8, fbInfo);
    sk_sp<SkSurface> surf = SkSurfaces::WrapBackendRenderTarget(
        kw->grContext.get(), backendRT, kBottomLeft_GrSurfaceOrigin,
        kRGBA_8888_SkColorType, nullptr, nullptr);
    if (!surf) return nullptr;
    // The framebuffer is sized in physical pixels; scale so the frame (in
    // points) rasterizes at full resolution.
    if (kw->scale != 1.0) surf->getCanvas()->scale(kw->scale, kw->scale);
    kw->surface = new KlioSurface();
    kw->surface->surface = surf;
    return kw->surface;
}

void klio_win_present(KlioWindow* kw) {
    if (!kw || !kw->grContext || !kw->surface) return;
    klio_perf_present_ns = klio_now_ns();
    kw->grContext->flushAndSubmit(kw->surface->surface.get(), GrSyncCpu::kNo);
    long swap0 = klio_now_ns();
    eglSwapBuffers(kw->display, kw->eglSurface);
    klio_perf_swap_ns = klio_now_ns() - swap0;
    klio_skia_free(kw->surface);
    kw->surface = nullptr;
}

void klio_win_close(KlioWindow* kw) {
    if (!kw) return;
    if (kw->surface) klio_skia_free(kw->surface);
    kw->grContext.reset();
    if (kw->display != EGL_NO_DISPLAY) {
        eglMakeCurrent(kw->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (kw->eglSurface != EGL_NO_SURFACE) eglDestroySurface(kw->display, kw->eglSurface);
        if (kw->context != EGL_NO_CONTEXT) eglDestroyContext(kw->display, kw->context);
    }
    delete kw;
}

// The OS owns the run loop on Android: no shim-side window creation or poll.
KlioWindow* klio_win_open(int, int, const char*) {
    klioWinFailed("Android gives an application its window; it cannot open another");
    return nullptr;
}
int klio_win_poll_event(void*, int, double*) { return KLIO_EV_NONE; }
void klio_win_post_event(void*, int, const double*) {}
void klio_win_set_text_input(void*, int) {}
void klio_win_set_text_input_rect(void*, int, int, int, int) {}
void klio_win_end_composition(void*) {}
void klio_order_emoji_palette(void) {}
size_t klio_win_event_text(void*, char* buf, size_t cap) {
    if (buf && cap > 0) buf[0] = 0;
    return 0;
}
void klio_win_set_flag(void*, int, int) {}
void klio_win_set_position(void*, int, int) {}
void klio_win_get_position(void*, int* x, int* y) { if (x) *x = 0; if (y) *y = 0; }
void klio_win_set_frame_size(void*, int, int) {}
void klio_win_get_frame_size(void*, int* w, int* h) { if (w) *w = 0; if (h) *h = 0; }
void klio_win_screen_bounds(int* x, int* y, int* w, int* h) { if (x) *x = 0; if (y) *y = 0; if (w) *w = 0; if (h) *h = 0; }
void klio_win_set_title(KlioWindow*, const char*) {}
void klio_win_set_size(KlioWindow* kw, int w, int h) { if (kw) { kw->w = w; kw->h = h; } }
void klio_win_set_icon_png(KlioWindow*, const unsigned char*, size_t) {}
void klio_win_set_icon_surface(KlioWindow*, KlioSurface*) {}
void klio_win_set_menu(KlioWindow*, const char*, size_t) {}
void klio_win_set_menu_icon(KlioWindow*, int, KlioSurface*) {}

// No tray icons: the desktop's Tray says so on standard error.
int klio_tray_supported(void) { return 0; }
void* klio_tray_open(void) { return nullptr; }
void klio_tray_close(void*) {}
void klio_tray_set_icon(void*, void*) {}
void klio_tray_set_tooltip(void*, const char*, size_t) {}
void klio_tray_set_menu(void*, const char*, size_t) {}
void klio_tray_notify(void*, const char*, size_t, const char*, size_t, int) {}
int klio_tray_poll_event(void*, double*) { return KLIO_EV_NONE; }
void klio_app_wait(int timeoutMs) {
    if (timeoutMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
}
void klio_win_set_resize_cb(KlioWindow*, void (*)(void*, int, int), void*) {}
// No clipboard reaches the shim on Android.
long long klio_clip_change_count(void) { return -1; }
char* klio_clip_get_text(size_t*) { return nullptr; }
void klio_clip_set_text(const char*, size_t) {}
char* klio_host_locale(void) { return nullptr; }

}  // extern "C"

#else  // no windowing backend (offscreen/raster only)

extern "C" {
void* klio_win_open(int, int, const char*) {
    klioWinFailed("this Skia shim was built without a window backend (on Linux, install libsdl2-dev and rebuild it)");
    return nullptr;
}
void* klio_win_attach(void*, int, int, double) { return nullptr; }
void* klio_win_surface(void*) { return nullptr; }
void klio_win_present(void*) {}
int klio_win_poll_event(void*, int, double*) { return KLIO_EV_CLOSE; }
void klio_win_post_event(void*, int, const double*) {}
void klio_win_set_text_input(void*, int) {}
void klio_win_set_text_input_rect(void*, int, int, int, int) {}
void klio_win_end_composition(void*) {}
void klio_order_emoji_palette(void) {}
size_t klio_win_event_text(void*, char* buf, size_t cap) {
    if (buf && cap > 0) buf[0] = 0;
    return 0;
}
void klio_win_set_flag(void*, int, int) {}
void klio_win_set_position(void*, int, int) {}
void klio_win_get_position(void*, int* x, int* y) { if (x) *x = 0; if (y) *y = 0; }
void klio_win_set_frame_size(void*, int, int) {}
void klio_win_get_frame_size(void*, int* w, int* h) { if (w) *w = 0; if (h) *h = 0; }
void klio_win_screen_bounds(int* x, int* y, int* w, int* h) { if (x) *x = 0; if (y) *y = 0; if (w) *w = 0; if (h) *h = 0; }
void klio_win_close(void*) {}
void klio_win_set_title(void*, const char*) {}
void klio_win_set_size(void*, int, int) {}
void klio_win_set_icon_png(void*, const unsigned char*, size_t) {}
void klio_win_set_icon_surface(void*, void*) {}
void klio_win_set_menu(void*, const char*, size_t) {}
void klio_win_set_menu_icon(void*, int, void*) {}

// No tray icons: the desktop's Tray says so on standard error.
int klio_tray_supported(void) { return 0; }
void* klio_tray_open(void) { return nullptr; }
void klio_tray_close(void*) {}
void klio_tray_set_icon(void*, void*) {}
void klio_tray_set_tooltip(void*, const char*, size_t) {}
void klio_tray_set_menu(void*, const char*, size_t) {}
void klio_tray_notify(void*, const char*, size_t, const char*, size_t, int) {}
int klio_tray_poll_event(void*, double*) { return KLIO_EV_NONE; }
void klio_app_wait(int timeoutMs) {
    if (timeoutMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
}
void klio_win_set_resize_cb(void*, void (*)(void*, int, int), void*) {}
long long klio_clip_change_count(void) { return -1; }
char* klio_clip_get_text(size_t*) { return nullptr; }
void klio_clip_set_text(const char*, size_t) {}
char* klio_host_locale(void) { return nullptr; }
}  // extern "C"

#endif

// gradient shader support
