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
#include <cstdarg>
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
#include <X11/cursorfont.h>
#include <X11/keysym.h>
#include <SDL_syswm.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/select.h>
#include <unistd.h>
#include <cmath>
#include <type_traits>
#define KLIO_X11 1
#endif
#if defined(KLIO_ATK)
// ATK's and GLib's declarations; the functions come from the libraries the
// accessibility bridge loads at run time (klioAtkLoad), so no cast calls
// into GObject's checks.
#define G_DISABLE_CAST_CHECKS 1
#include <atk/atk.h>
#include <dlfcn.h>
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
    // The window's semantics for assistive technologies (klio_a11y_update),
    // their ATK objects by node id (-1 for the window's frame), and whether a
    // client reads them.
    bool a11yActive = false;
    KlioA11yTree a11y;
    std::unordered_map<int, struct KlioAtkObject*> atk;
    // Drag and drop: the window's X window (XDND's drags are the shim's,
    // further down), the drag the window runs itself where it has none (a
    // Wayland window, scripted input), the drag event the program answers,
    // the files and text SDL reports dropped on a Wayland window, and a
    // release SDL hears that the window drops (the drag took the button).
    unsigned long xwin = 0;
    unsigned long xproxy = 0;  // the shim's window its XdndProxy names
    KlioDragSession drag;
    KlioDndAsk dndAsk;
    std::vector<std::string> dropFiles;
    std::string dropText;
    bool dropHasText = false;
    bool swallowRelease = false;
#if defined(KLIO_GPU)
    SDL_GLContext gl = nullptr;
    sk_sp<GrDirectContext> grContext;  // per-window GL context for the on-screen GPU
    bool gpu = false;
#endif
};

// The window joins, and leaves, the application assistive technologies
// read (the ATK bridge further down, with C linkage as the functions
// around it have).
extern "C" {
static void klioSdlA11yOpen(KlioWindow* kw);
static void klioSdlA11yClose(KlioWindow* kw);
}

#if defined(KLIO_X11)
// Drag and drop over XDND, on the shim's own X connection (further down).
extern "C" {
static void klioXdndAttach(KlioWindow* kw);
static void klioXdndDetach(KlioWindow* kw);
static bool klioXdndStart(KlioWindow* kw, const std::string& payload, int actions);
static void klioXdndAnswer(KlioWindow* kw, int kind, int action);
static bool klioXdndWatching();
static void klioXdndWaitInput(int ms);
static void klioX11Pump();
static void klioXdndTrace(const char* fmt, ...);
}
#endif

// Open windows by SDL id, for event routing. klio is single-threaded.
static std::unordered_map<Uint32, KlioWindow*>& klioSdlWindows() {
    static std::unordered_map<Uint32, KlioWindow*> m;
    return m;
}
static int klioSdlOpenCount = 0;
// The open windows hold one reference on SDL's video subsystem, taken when the
// first opens and given back when the last closes; the clipboard holds its own.
static bool klioSdlWindowsHoldVideo = false;

// The window loop's wake (klio_app_wake): an SDL event of its own type, and on
// X11, where the loop waits on its connections itself, a byte on a pipe.
static Uint32 klioSdlWakeType = 0;
#if !defined(_WIN32)
static int klioWakePipe[2] = {-1, -1};
#endif

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
        if (!klioSdlWakeType) {
            const Uint32 t = SDL_RegisterEvents(1);
            if (t != static_cast<Uint32>(-1)) klioSdlWakeType = t;
        }
#if !defined(_WIN32)
        if (klioWakePipe[0] < 0 && pipe(klioWakePipe) == 0) {
            for (const int fd : klioWakePipe) fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        }
#endif
        // Files and text other applications drop on a window.
        SDL_EventState(SDL_DROPFILE, SDL_ENABLE);
        SDL_EventState(SDL_DROPTEXT, SDL_ENABLE);
        SDL_EventState(SDL_DROPBEGIN, SDL_ENABLE);
        SDL_EventState(SDL_DROPCOMPLETE, SDL_ENABLE);
        klioSdlWindowsHoldVideo = true;
    }
#if defined(KLIO_GPU)
    // Try an on-screen GPU window (Ganesh over SDL's GL context) first; fall back to
    // the raster renderer if any GL/Skia bring-up step fails.
    if (KlioWindow* gpuWin = klioSdlOpenGpu(w, h, title)) {
        SDL_StartTextInput();
        gpuWin->id = SDL_GetWindowID(gpuWin->win);
        klioSdlWindows()[gpuWin->id] = gpuWin;
        gpuWin->a11yActive = klioA11yForced();
        klioSdlA11yOpen(gpuWin);
#if defined(KLIO_X11)
        klioXdndAttach(gpuWin);
#endif
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
    kw->a11yActive = klioA11yForced();
    klioSdlA11yOpen(kw);
#if defined(KLIO_X11)
    klioXdndAttach(kw);
#endif
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
// ---------------------------------------------------------------------------
// Accessibility: the windows' semantics through ATK, which atk-bridge serves
// to AT-SPI clients (Orca) as GTK's are, as Compose Desktop's are served
// through the Java ATK wrapper. An application object holds a frame per
// window, whose children are the semantics nodes of the window's latest
// snapshot. ATK and GLib are loaded when the first window opens, so a
// desktop without them runs the program without the bridge.

#if defined(KLIO_ATK)
// The functions the bridge calls, from the libraries loaded at run time.
struct KlioAtkApi {
    bool loaded = false;
    bool bridged = false;
    decltype(&g_type_register_static) type_register_static;
    decltype(&g_type_add_interface_static) type_add_interface_static;
    decltype(&g_object_new) object_new;
    decltype(&g_object_unref) object_unref;
    decltype(&g_object_ref) object_ref;
    decltype(&g_type_class_ref) type_class_ref;
    decltype(&g_type_class_peek_parent) type_class_peek_parent;
    decltype(&g_signal_emit_by_name) signal_emit_by_name;
    decltype(&g_main_context_iteration) main_context_iteration;
    decltype(&g_strdup) strdup_;
    decltype(&g_value_init) value_init;
    decltype(&g_value_set_double) value_set_double;
    decltype(&g_value_get_double) value_get_double;
    decltype(&g_value_unset) value_unset;
    decltype(&atk_object_get_type) object_get_type;
    decltype(&atk_util_get_type) util_get_type;
    decltype(&atk_component_get_type) component_get_type;
    decltype(&atk_action_get_type) action_get_type;
    decltype(&atk_value_get_type) value_get_type;
    decltype(&atk_editable_text_get_type) editable_text_get_type;
    decltype(&atk_text_get_type) text_get_type;
    decltype(&atk_state_set_new) state_set_new;
    decltype(&atk_state_set_add_state) state_set_add_state;
    decltype(&atk_state_set_contains_state) state_set_contains_state;
    decltype(&atk_object_notify_state_change) notify_state_change;
    decltype(&atk_object_get_n_accessible_children) get_n_children;
    decltype(&atk_object_ref_accessible_child) ref_child;
    decltype(&atk_object_get_role) get_role;
    decltype(&atk_object_get_name) get_name;
    decltype(&atk_object_ref_state_set) ref_state_set;
    decltype(&atk_action_get_n_actions) action_get_n_actions;
    decltype(&atk_action_get_name) action_get_name;
    decltype(&atk_action_do_action) action_do_action;
    decltype(&atk_editable_text_set_text_contents) set_text_contents;
    decltype(&atk_text_get_text) text_get_text;
    decltype(&atk_text_get_character_count) text_get_character_count;
    decltype(&atk_value_get_current_value) value_get_current_value;
    decltype(&atk_value_set_current_value) value_set_current_value;
    decltype(&atk_component_grab_focus) component_grab_focus;
    int (*bridge_init)(int*, char***);
};

static KlioAtkApi& klioAtk() {
    static KlioAtkApi api;
    return api;
}

#define klioAtkSym(lib, name, field) \
    ((field = reinterpret_cast<decltype(field)>(dlsym(lib, name))) != nullptr)

// Loads GLib, GObject, ATK and atk-bridge; false when a library or a
// function is missing.
static bool klioAtkLoad() {
    KlioAtkApi& a = klioAtk();
    static bool tried = false;
    if (tried) return a.loaded;
    tried = true;
    void* glib = dlopen("libglib-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    void* gobject = dlopen("libgobject-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    void* atk = dlopen("libatk-1.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    void* bridge = dlopen("libatk-bridge-2.0.so.0", RTLD_NOW | RTLD_GLOBAL);
    if (!glib || !gobject || !atk || !bridge) return false;
    bool ok = true;
    ok &= klioAtkSym(gobject, "g_type_register_static", a.type_register_static);
    ok &= klioAtkSym(gobject, "g_type_add_interface_static", a.type_add_interface_static);
    ok &= klioAtkSym(gobject, "g_object_new", a.object_new);
    ok &= klioAtkSym(gobject, "g_object_unref", a.object_unref);
    ok &= klioAtkSym(gobject, "g_object_ref", a.object_ref);
    ok &= klioAtkSym(gobject, "g_type_class_ref", a.type_class_ref);
    ok &= klioAtkSym(gobject, "g_type_class_peek_parent", a.type_class_peek_parent);
    ok &= klioAtkSym(gobject, "g_signal_emit_by_name", a.signal_emit_by_name);
    ok &= klioAtkSym(gobject, "g_value_init", a.value_init);
    ok &= klioAtkSym(gobject, "g_value_set_double", a.value_set_double);
    ok &= klioAtkSym(gobject, "g_value_get_double", a.value_get_double);
    ok &= klioAtkSym(gobject, "g_value_unset", a.value_unset);
    ok &= klioAtkSym(glib, "g_main_context_iteration", a.main_context_iteration);
    ok &= klioAtkSym(glib, "g_strdup", a.strdup_);
    ok &= klioAtkSym(atk, "atk_object_get_type", a.object_get_type);
    ok &= klioAtkSym(atk, "atk_util_get_type", a.util_get_type);
    ok &= klioAtkSym(atk, "atk_component_get_type", a.component_get_type);
    ok &= klioAtkSym(atk, "atk_action_get_type", a.action_get_type);
    ok &= klioAtkSym(atk, "atk_value_get_type", a.value_get_type);
    ok &= klioAtkSym(atk, "atk_editable_text_get_type", a.editable_text_get_type);
    ok &= klioAtkSym(atk, "atk_text_get_type", a.text_get_type);
    ok &= klioAtkSym(atk, "atk_state_set_new", a.state_set_new);
    ok &= klioAtkSym(atk, "atk_state_set_add_state", a.state_set_add_state);
    ok &= klioAtkSym(atk, "atk_state_set_contains_state", a.state_set_contains_state);
    ok &= klioAtkSym(atk, "atk_object_notify_state_change", a.notify_state_change);
    ok &= klioAtkSym(atk, "atk_object_get_n_accessible_children", a.get_n_children);
    ok &= klioAtkSym(atk, "atk_object_ref_accessible_child", a.ref_child);
    ok &= klioAtkSym(atk, "atk_object_get_role", a.get_role);
    ok &= klioAtkSym(atk, "atk_object_get_name", a.get_name);
    ok &= klioAtkSym(atk, "atk_object_ref_state_set", a.ref_state_set);
    ok &= klioAtkSym(atk, "atk_action_get_n_actions", a.action_get_n_actions);
    ok &= klioAtkSym(atk, "atk_action_get_name", a.action_get_name);
    ok &= klioAtkSym(atk, "atk_action_do_action", a.action_do_action);
    ok &= klioAtkSym(atk, "atk_editable_text_set_text_contents", a.set_text_contents);
    ok &= klioAtkSym(atk, "atk_text_get_text", a.text_get_text);
    ok &= klioAtkSym(atk, "atk_text_get_character_count", a.text_get_character_count);
    ok &= klioAtkSym(atk, "atk_value_get_current_value", a.value_get_current_value);
    ok &= klioAtkSym(atk, "atk_value_set_current_value", a.value_set_current_value);
    ok &= klioAtkSym(atk, "atk_component_grab_focus", a.component_grab_focus);
    ok &= klioAtkSym(bridge, "atk_bridge_adaptor_init", a.bridge_init);
    a.loaded = ok;
    return ok;
}

// What an object of the bridge stands for: the application, a window, or
// a semantics node of a window.
enum KlioAtkKind { KLIO_ATK_APP, KLIO_ATK_FRAME, KLIO_ATK_NODE };

struct KlioAtkObject {
    AtkObject parent;
    int kind;
    KlioWindow* kw;       // null once the window closed or the node left the tree
    int nodeId;
    int ifaces;           // the interfaces its type offers (KLIO_ATK_TEXT, ...)
    char* cache;          // the last name or text handed out (freed on the next)
};

struct KlioAtkObjectClass {
    AtkObjectClass parent;
};

static GType klioAtkObjectType(int ifaces);
static AtkObjectClass* klioAtkParentClass = nullptr;

static std::vector<KlioWindow*>& klioAtkWindows() {
    static std::vector<KlioWindow*> windows;
    return windows;
}

static KlioAtkObject* klioAtkApp() {
    static KlioAtkObject* app = nullptr;
    if (!app) {
        app = reinterpret_cast<KlioAtkObject*>(klioAtk().object_new(klioAtkObjectType(0), nullptr));
        app->kind = KLIO_ATK_APP;
        app->parent.role = ATK_ROLE_APPLICATION;
    }
    return app;
}

static const KlioA11yNode* klioAtkNode(KlioAtkObject* o) {
    return o->kind == KLIO_ATK_NODE && o->kw ? o->kw->a11y.find(o->nodeId) : nullptr;
}

static const char* klioAtkCache(KlioAtkObject* o, const std::string& s) {
    std::free(o->cache);
    o->cache = strdup(s.c_str());
    return o->cache;
}

// The object of a node (or the frame for id -1) of a window.
static AtkObject* klioAtkFor(KlioWindow* kw, int nodeId);

static const std::vector<int>* klioAtkChildIds(KlioAtkObject* o) {
    if (o->kind == KLIO_ATK_FRAME) return o->kw ? &o->kw->a11y.roots : nullptr;
    const KlioA11yNode* n = klioAtkNode(o);
    return n ? &n->children : nullptr;
}

static void klioSdlA11yActivate(KlioWindow* kw);

static const gchar* klioAtkGetName(AtkObject* obj) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    if (o->kind == KLIO_ATK_APP) return "klio";
    if (o->kind == KLIO_ATK_FRAME) return o->kw && o->kw->win ? klioAtkCache(o, SDL_GetWindowTitle(o->kw->win)) : "";
    const KlioA11yNode* n = klioAtkNode(o);
    return n ? klioAtkCache(o, n->name) : "";
}

static const gchar* klioAtkGetDescription(AtkObject* obj) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    const KlioA11yNode* n = klioAtkNode(o);
    return n && n->description != n->name ? klioAtkCache(o, n->description) : nullptr;
}

static AtkObject* klioAtkGetParent(AtkObject* obj) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    if (o->kind == KLIO_ATK_APP) return nullptr;
    if (o->kind == KLIO_ATK_FRAME) return &klioAtkApp()->parent;
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n) return nullptr;
    AtkObject* p = klioAtkFor(o->kw, n->parent >= 0 ? n->parent : -1);
    return p ? p : klioAtkFor(o->kw, -1);
}

static gint klioAtkGetNChildren(AtkObject* obj) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    if (o->kind == KLIO_ATK_APP) return static_cast<gint>(klioAtkWindows().size());
    if (o->kind == KLIO_ATK_FRAME && o->kw) klioSdlA11yActivate(o->kw);
    const std::vector<int>* ids = klioAtkChildIds(o);
    return ids ? static_cast<gint>(ids->size()) : 0;
}

static AtkObject* klioAtkRefChild(AtkObject* obj, gint i) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    AtkObject* child = nullptr;
    if (o->kind == KLIO_ATK_APP) {
        if (i >= 0 && static_cast<size_t>(i) < klioAtkWindows().size()) child = klioAtkFor(klioAtkWindows()[i], -1);
    } else {
        const std::vector<int>* ids = klioAtkChildIds(o);
        if (ids && i >= 0 && static_cast<size_t>(i) < ids->size()) child = klioAtkFor(o->kw, (*ids)[i]);
    }
    if (child) klioAtk().object_ref(child);
    return child;
}

static gint klioAtkGetIndexInParent(AtkObject* obj) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    if (o->kind == KLIO_ATK_APP) return -1;
    if (o->kind == KLIO_ATK_FRAME) {
        const auto& ws = klioAtkWindows();
        for (size_t i = 0; i < ws.size(); i++) {
            if (ws[i] == o->kw) return static_cast<gint>(i);
        }
        return -1;
    }
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n) return -1;
    const KlioA11yNode* p = n->parent >= 0 ? o->kw->a11y.find(n->parent) : nullptr;
    const std::vector<int>& siblings = p ? p->children : o->kw->a11y.roots;
    for (size_t i = 0; i < siblings.size(); i++) {
        if (siblings[i] == o->nodeId) return static_cast<gint>(i);
    }
    return -1;
}

static AtkRole klioAtkRoleOf(int role) {
    switch (role) {
        case KLIO_A11Y_ROLE_BUTTON: return ATK_ROLE_PUSH_BUTTON;
        case KLIO_A11Y_ROLE_CHECKBOX: return ATK_ROLE_CHECK_BOX;
        case KLIO_A11Y_ROLE_SWITCH: return ATK_ROLE_TOGGLE_BUTTON;
        case KLIO_A11Y_ROLE_RADIO_BUTTON: return ATK_ROLE_RADIO_BUTTON;
        case KLIO_A11Y_ROLE_TAB: return ATK_ROLE_PAGE_TAB;
        case KLIO_A11Y_ROLE_DROPDOWN: return ATK_ROLE_COMBO_BOX;
        case KLIO_A11Y_ROLE_IMAGE: return ATK_ROLE_IMAGE;
        case KLIO_A11Y_ROLE_TEXT_FIELD: return ATK_ROLE_ENTRY;
        case KLIO_A11Y_ROLE_PASSWORD_FIELD: return ATK_ROLE_PASSWORD_TEXT;
        case KLIO_A11Y_ROLE_TEXT: return ATK_ROLE_LABEL;
        case KLIO_A11Y_ROLE_SLIDER: return ATK_ROLE_SLIDER;
        case KLIO_A11Y_ROLE_PROGRESS: return ATK_ROLE_PROGRESS_BAR;
        case KLIO_A11Y_ROLE_SCROLL_AREA: return ATK_ROLE_SCROLL_PANE;
        default: return ATK_ROLE_PANEL;
    }
}

static AtkRole klioAtkGetRole(AtkObject* obj) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    if (o->kind == KLIO_ATK_APP) return ATK_ROLE_APPLICATION;
    if (o->kind == KLIO_ATK_FRAME) return ATK_ROLE_FRAME;
    const KlioA11yNode* n = klioAtkNode(o);
    return klioAtkRoleOf(n ? n->role : KLIO_A11Y_ROLE_UNKNOWN);
}

static AtkStateSet* klioAtkRefStateSet(AtkObject* obj) {
    KlioAtkApi& a = klioAtk();
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(obj);
    AtkStateSet* set = a.state_set_new();
    if (o->kind != KLIO_ATK_NODE) {
        a.state_set_add_state(set, ATK_STATE_VISIBLE);
        a.state_set_add_state(set, ATK_STATE_SHOWING);
        return set;
    }
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n) {
        a.state_set_add_state(set, ATK_STATE_DEFUNCT);
        return set;
    }
    a.state_set_add_state(set, ATK_STATE_VISIBLE);
    a.state_set_add_state(set, ATK_STATE_SHOWING);
    if (n->states & KLIO_A11Y_STATE_ENABLED) {
        a.state_set_add_state(set, ATK_STATE_ENABLED);
        a.state_set_add_state(set, ATK_STATE_SENSITIVE);
    }
    if (klioA11yOffers(n->actions, KLIO_A11Y_ACTION_FOCUS)) a.state_set_add_state(set, ATK_STATE_FOCUSABLE);
    if (n->states & KLIO_A11Y_STATE_FOCUSED) a.state_set_add_state(set, ATK_STATE_FOCUSED);
    if (n->states & KLIO_A11Y_STATE_SELECTED) a.state_set_add_state(set, ATK_STATE_SELECTED);
    if (n->states & KLIO_A11Y_STATE_CHECKABLE) a.state_set_add_state(set, ATK_STATE_CHECKABLE);
    if (n->states & KLIO_A11Y_STATE_CHECKED) {
        a.state_set_add_state(set, n->role == KLIO_A11Y_ROLE_SWITCH ? ATK_STATE_PRESSED : ATK_STATE_CHECKED);
    }
    if (n->states & KLIO_A11Y_STATE_MIXED) a.state_set_add_state(set, ATK_STATE_INDETERMINATE);
    if (n->states & KLIO_A11Y_STATE_EDITABLE) a.state_set_add_state(set, ATK_STATE_EDITABLE);
    if (n->states & (KLIO_A11Y_STATE_EXPANDED | KLIO_A11Y_STATE_COLLAPSED)) a.state_set_add_state(set, ATK_STATE_EXPANDABLE);
    if (n->states & KLIO_A11Y_STATE_EXPANDED) a.state_set_add_state(set, ATK_STATE_EXPANDED);
    return set;
}

static void klioAtkFinalize(GObject* gobj) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(gobj);
    std::free(o->cache);
    o->cache = nullptr;
    G_OBJECT_CLASS(klioAtkParentClass)->finalize(gobj);
}

static void klioAtkClassInit(gpointer klass, gpointer) {
    klioAtkParentClass = reinterpret_cast<AtkObjectClass*>(klioAtk().type_class_peek_parent(klass));
    AtkObjectClass* c = reinterpret_cast<AtkObjectClass*>(klass);
    c->get_name = klioAtkGetName;
    c->get_description = klioAtkGetDescription;
    c->get_parent = klioAtkGetParent;
    c->get_n_children = klioAtkGetNChildren;
    c->ref_child = klioAtkRefChild;
    c->get_index_in_parent = klioAtkGetIndexInParent;
    c->get_role = klioAtkGetRole;
    c->ref_state_set = klioAtkRefStateSet;
    reinterpret_cast<GObjectClass*>(klass)->finalize = klioAtkFinalize;
}

// A node's action as a client asks it: queued for the program to run.
static gboolean klioAtkPerform(KlioAtkObject* o, int action, const char* text = "") {
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n || !klioA11yOffers(n->actions, action)) return FALSE;
    o->kw->events.push_back(klioA11yEv(o->nodeId, action, text));
    return TRUE;
}

// AtkComponent: where the object is, and focusing it.
static void klioAtkGetExtents(AtkComponent* c, gint* x, gint* y, gint* w, gint* h, AtkCoordType coords) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(c);
    *x = *y = *w = *h = 0;
    if (!o->kw || !o->kw->win) return;
    int wx = 0;
    int wy = 0;
    SDL_GetWindowPosition(o->kw->win, &wx, &wy);
    if (coords != ATK_XY_SCREEN) wx = wy = 0;
    if (o->kind == KLIO_ATK_FRAME) {
        *x = wx;
        *y = wy;
        *w = o->kw->w;
        *h = o->kw->h + o->kw->barH;
        return;
    }
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n) return;
    *x = wx + static_cast<gint>(n->x);
    *y = wy + o->kw->barH + static_cast<gint>(n->y);
    *w = static_cast<gint>(n->w);
    *h = static_cast<gint>(n->h);
}

static gboolean klioAtkGrabFocus(AtkComponent* c) {
    return klioAtkPerform(reinterpret_cast<KlioAtkObject*>(c), KLIO_A11Y_ACTION_FOCUS);
}

static void klioAtkComponentInit(gpointer iface, gpointer) {
    AtkComponentIface* i = reinterpret_cast<AtkComponentIface*>(iface);
    i->get_extents = klioAtkGetExtents;
    i->grab_focus = klioAtkGrabFocus;
}

// AtkAction: the node's click, long click, expand and collapse, in that order.
static const int klioAtkActionOrder[] = {KLIO_A11Y_ACTION_CLICK, KLIO_A11Y_ACTION_LONG_CLICK, KLIO_A11Y_ACTION_EXPAND,
                                         KLIO_A11Y_ACTION_COLLAPSE, KLIO_A11Y_ACTION_DISMISS};

static int klioAtkActionAt(KlioAtkObject* o, gint i) {
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n) return 0;
    gint k = 0;
    for (int action : klioAtkActionOrder) {
        if (!klioA11yOffers(n->actions, action)) continue;
        if (k++ == i) return action;
    }
    return 0;
}

static gint klioAtkGetNActions(AtkAction* a) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(a);
    gint k = 0;
    while (klioAtkActionAt(o, k) != 0) k++;
    return k;
}

static const gchar* klioAtkActionName(AtkAction* a, gint i) {
    switch (klioAtkActionAt(reinterpret_cast<KlioAtkObject*>(a), i)) {
        case KLIO_A11Y_ACTION_CLICK: return "click";
        case KLIO_A11Y_ACTION_LONG_CLICK: return "long click";
        case KLIO_A11Y_ACTION_EXPAND: return "expand";
        case KLIO_A11Y_ACTION_COLLAPSE: return "collapse";
        case KLIO_A11Y_ACTION_DISMISS: return "dismiss";
        default: return nullptr;
    }
}

static gboolean klioAtkDoAction(AtkAction* a, gint i) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(a);
    const int action = klioAtkActionAt(o, i);
    return action != 0 && klioAtkPerform(o, action);
}

static void klioAtkActionInit(gpointer iface, gpointer) {
    AtkActionIface* i = reinterpret_cast<AtkActionIface*>(iface);
    i->get_n_actions = klioAtkGetNActions;
    i->get_name = klioAtkActionName;
    i->do_action = klioAtkDoAction;
}

// AtkValue: a slider's or progress bar's value; a new one is reached a
// step at a time, as the semantics offer.
static void klioAtkValueField(AtkValue* v, GValue* out, int which) {
    const KlioA11yNode* n = klioAtkNode(reinterpret_cast<KlioAtkObject*>(v));
    klioAtk().value_init(out, G_TYPE_DOUBLE);
    klioAtk().value_set_double(out, !n ? 0.0 : which == 0 ? n->current : which == 1 ? n->min : n->max);
}

static void klioAtkGetCurrentValue(AtkValue* v, GValue* out) { klioAtkValueField(v, out, 0); }
static void klioAtkGetMinimumValue(AtkValue* v, GValue* out) { klioAtkValueField(v, out, 1); }
static void klioAtkGetMaximumValue(AtkValue* v, GValue* out) { klioAtkValueField(v, out, 2); }

static gboolean klioAtkSetCurrentValue(AtkValue* v, const GValue* value) {
    KlioAtkObject* o = reinterpret_cast<KlioAtkObject*>(v);
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n) return FALSE;
    const double target = klioAtk().value_get_double(value);
    if (target == n->current) return TRUE;
    return klioAtkPerform(o, target > n->current ? KLIO_A11Y_ACTION_INCREMENT : KLIO_A11Y_ACTION_DECREMENT);
}

static void klioAtkValueInit(gpointer iface, gpointer) {
    AtkValueIface* i = reinterpret_cast<AtkValueIface*>(iface);
    i->get_current_value = klioAtkGetCurrentValue;
    i->get_minimum_value = klioAtkGetMinimumValue;
    i->get_maximum_value = klioAtkGetMaximumValue;
    i->set_current_value = klioAtkSetCurrentValue;
}

// AtkEditableText: a text field's new text.
static void klioAtkSetTextContents(AtkEditableText* t, const gchar* text) {
    klioAtkPerform(reinterpret_cast<KlioAtkObject*>(t), KLIO_A11Y_ACTION_SET_TEXT, text ? text : "");
}

static void klioAtkEditableTextInit(gpointer iface, gpointer) {
    reinterpret_cast<AtkEditableTextIface*>(iface)->set_text_contents = klioAtkSetTextContents;
}

// AtkText: the text of a text field or of static text, by character.
static std::string klioAtkText(KlioAtkObject* o) {
    const KlioA11yNode* n = klioAtkNode(o);
    if (!n) return std::string();
    return n->role == KLIO_A11Y_ROLE_TEXT_FIELD || n->role == KLIO_A11Y_ROLE_PASSWORD_FIELD ? n->value : n->name;
}

static size_t klioUtf8Offset(const std::string& s, gint chars) {
    size_t i = 0;
    for (gint k = 0; i < s.size() && k < chars; k++) {
        i++;
        while (i < s.size() && (static_cast<unsigned char>(s[i]) & 0xC0) == 0x80) i++;
    }
    return i;
}

static gint klioUtf8Length(const std::string& s) {
    gint n = 0;
    for (unsigned char c : s) {
        if ((c & 0xC0) != 0x80) n++;
    }
    return n;
}

static gchar* klioAtkGetText(AtkText* t, gint start, gint end) {
    const std::string s = klioAtkText(reinterpret_cast<KlioAtkObject*>(t));
    const size_t from = klioUtf8Offset(s, start);
    const size_t to = end < 0 ? s.size() : klioUtf8Offset(s, end);
    return klioAtk().strdup_(s.substr(from, to > from ? to - from : 0).c_str());
}

static gint klioAtkGetCharacterCount(AtkText* t) {
    return klioUtf8Length(klioAtkText(reinterpret_cast<KlioAtkObject*>(t)));
}

static gint klioAtkGetCaretOffset(AtkText* t) { return klioAtkGetCharacterCount(t); }

static void klioAtkTextInit(gpointer iface, gpointer) {
    AtkTextIface* i = reinterpret_cast<AtkTextIface*>(iface);
    i->get_text = klioAtkGetText;
    i->get_character_count = klioAtkGetCharacterCount;
    i->get_caret_offset = klioAtkGetCaretOffset;
}

// The interfaces an object offers beyond the component and the actions, as
// GTK's accessibles differ by widget: text for static text, text and
// editable text for a field, a value for a slider or progress bar.
enum { KLIO_ATK_TEXT = 1, KLIO_ATK_EDITABLE = 2, KLIO_ATK_VALUE = 4 };

static int klioAtkInterfacesOf(int role) {
    switch (role) {
        case KLIO_A11Y_ROLE_TEXT: return KLIO_ATK_TEXT;
        case KLIO_A11Y_ROLE_TEXT_FIELD:
        case KLIO_A11Y_ROLE_PASSWORD_FIELD: return KLIO_ATK_TEXT | KLIO_ATK_EDITABLE;
        case KLIO_A11Y_ROLE_SLIDER:
        case KLIO_A11Y_ROLE_PROGRESS: return KLIO_ATK_VALUE;
        default: return 0;
    }
}

// The object type offering the interfaces `ifaces` names, one per set.
static GType klioAtkObjectType(int ifaces) {
    static GType types[8] = {};
    if (types[ifaces]) return types[ifaces];
    KlioAtkApi& a = klioAtk();
    GTypeInfo info = {};
    info.class_size = sizeof(KlioAtkObjectClass);
    info.class_init = klioAtkClassInit;
    info.instance_size = sizeof(KlioAtkObject);
    char name[32];
    std::snprintf(name, sizeof name, "KlioAtkObject%d", ifaces);
    const GType type = a.type_register_static(a.object_get_type(), name, &info, static_cast<GTypeFlags>(0));
    GInterfaceInfo component = {klioAtkComponentInit, nullptr, nullptr};
    GInterfaceInfo action = {klioAtkActionInit, nullptr, nullptr};
    GInterfaceInfo value = {klioAtkValueInit, nullptr, nullptr};
    GInterfaceInfo editable = {klioAtkEditableTextInit, nullptr, nullptr};
    GInterfaceInfo text = {klioAtkTextInit, nullptr, nullptr};
    a.type_add_interface_static(type, a.component_get_type(), &component);
    a.type_add_interface_static(type, a.action_get_type(), &action);
    if (ifaces & KLIO_ATK_VALUE) a.type_add_interface_static(type, a.value_get_type(), &value);
    if (ifaces & KLIO_ATK_EDITABLE) a.type_add_interface_static(type, a.editable_text_get_type(), &editable);
    if (ifaces & KLIO_ATK_TEXT) a.type_add_interface_static(type, a.text_get_type(), &text);
    types[ifaces] = type;
    return type;
}

static AtkObject* klioAtkGetRoot() { return &klioAtkApp()->parent; }
static const gchar* klioAtkToolkitName() { return "klio"; }
static const gchar* klioAtkToolkitVersion() { return "1"; }

// Loads ATK and starts atk-bridge once: the application object becomes
// the root AT-SPI clients reach the windows by.
static bool klioAtkStart() {
    KlioAtkApi& a = klioAtk();
    if (a.bridged) return true;
    if (!klioAtkLoad()) return false;
    AtkUtilClass* util = reinterpret_cast<AtkUtilClass*>(a.type_class_ref(a.util_get_type()));
    util->get_root = klioAtkGetRoot;
    util->get_toolkit_name = klioAtkToolkitName;
    util->get_toolkit_version = klioAtkToolkitVersion;
    klioAtkApp();
    a.bridge_init(nullptr, nullptr);
    a.bridged = true;
    return true;
}

// Answers AT-SPI clients: atk-bridge's D-Bus traffic runs on GLib's main
// context, which the window loop drives.
static void klioAtkPump() {
    if (!klioAtk().bridged) return;
    for (int i = 0; i < 64 && klioAtk().main_context_iteration(nullptr, FALSE); i++) {
    }
}
#endif  // KLIO_ATK

static void klioSdlPrintCursor();

static void klioSdlA11yActivate(KlioWindow* kw) {
    if (kw->a11yActive) return;
    kw->a11yActive = true;
    kw->events.push_back(klioA11yEv(0, 0));
}

#if defined(KLIO_ATK)
static AtkObject* klioAtkFor(KlioWindow* kw, int nodeId) {
    const auto it = kw->atk.find(nodeId);
    return it == kw->atk.end() ? nullptr : &it->second->parent;
}

static KlioAtkObject* klioAtkNew(KlioWindow* kw, int kind, int nodeId, int ifaces = 0) {
    auto* o = reinterpret_cast<KlioAtkObject*>(klioAtk().object_new(klioAtkObjectType(ifaces), nullptr));
    o->kind = kind;
    o->kw = kw;
    o->nodeId = nodeId;
    o->ifaces = ifaces;
    return o;
}

// The window joins the application AT-SPI clients read.
static void klioSdlA11yOpen(KlioWindow* kw) {
    if (!klioAtkStart()) return;
    kw->atk[-1] = klioAtkNew(kw, KLIO_ATK_FRAME, -1);
    klioAtkWindows().push_back(kw);
    klioAtk().signal_emit_by_name(klioAtkApp(), "children-changed::add",
                                  static_cast<gint>(klioAtkWindows().size() - 1), klioAtkFor(kw, -1));
}

static void klioSdlA11yClose(KlioWindow* kw) {
    auto& ws = klioAtkWindows();
    for (size_t i = 0; i < ws.size(); i++) {
        if (ws[i] != kw) continue;
        ws.erase(ws.begin() + static_cast<long>(i));
        klioAtk().signal_emit_by_name(klioAtkApp(), "children-changed::remove", static_cast<gint>(i), klioAtkFor(kw, -1));
        break;
    }
    for (auto& entry : kw->atk) {
        entry.second->kw = nullptr;
        klioAtk().object_unref(entry.second);
    }
    kw->atk.clear();
}

// The window's semantics as the program sends them: objects keep their
// identity across snapshots, and clients hear what changed.
static void klioSdlA11yUpdate(KlioWindow* kw, const char* text, size_t len) {
    KlioA11yTree next = klioParseA11y(text, len);
    if (kw->atk.empty()) {
        kw->a11y = std::move(next);
        return;
    }
    KlioAtkApi& a = klioAtk();
    const KlioA11yTree before = std::move(kw->a11y);
    std::unordered_map<int, KlioAtkObject*> objects;
    objects[-1] = kw->atk[-1];
    kw->atk.erase(-1);
    std::vector<int> added;
    for (const KlioA11yNode& n : next.nodes) {
        const auto it = kw->atk.find(n.id);
        // A node whose role now wants other interfaces is a new object.
        if (it != kw->atk.end() && it->second->ifaces == klioAtkInterfacesOf(n.role)) {
            objects[n.id] = it->second;
            kw->atk.erase(it);
        } else {
            objects[n.id] = klioAtkNew(kw, KLIO_ATK_NODE, n.id, klioAtkInterfacesOf(n.role));
            added.push_back(n.id);
        }
    }
    std::vector<KlioAtkObject*> gone;
    for (auto& entry : kw->atk) gone.push_back(entry.second);
    kw->atk = std::move(objects);
    kw->a11y = std::move(next);
    for (KlioAtkObject* o : gone) {
        const KlioA11yNode* was = before.find(o->nodeId);
        AtkObject* parent = was ? klioAtkFor(kw, was->parent >= 0 ? was->parent : -1) : nullptr;
        o->kw = nullptr;
        if (parent) a.signal_emit_by_name(parent, "children-changed::remove", -1, &o->parent);
        a.notify_state_change(&o->parent, ATK_STATE_DEFUNCT, TRUE);
        a.object_unref(o);
    }
    for (int id : added) {
        const KlioA11yNode* n = kw->a11y.find(id);
        AtkObject* parent = klioAtkFor(kw, n->parent >= 0 ? n->parent : -1);
        if (parent) {
            a.signal_emit_by_name(parent, "children-changed::add", klioAtkGetIndexInParent(klioAtkFor(kw, id)),
                                  klioAtkFor(kw, id));
        }
    }
    for (const KlioA11yNode& n : kw->a11y.nodes) {
        const KlioA11yNode* was = before.find(n.id);
        if (!was) continue;
        AtkObject* o = klioAtkFor(kw, n.id);
        const int changed = was->states ^ n.states;
        if (changed & KLIO_A11Y_STATE_CHECKED) {
            a.notify_state_change(o, n.role == KLIO_A11Y_ROLE_SWITCH ? ATK_STATE_PRESSED : ATK_STATE_CHECKED,
                                  (n.states & KLIO_A11Y_STATE_CHECKED) != 0);
        }
        if (changed & KLIO_A11Y_STATE_ENABLED) a.notify_state_change(o, ATK_STATE_ENABLED, (n.states & KLIO_A11Y_STATE_ENABLED) != 0);
        if (changed & KLIO_A11Y_STATE_EXPANDED) a.notify_state_change(o, ATK_STATE_EXPANDED, (n.states & KLIO_A11Y_STATE_EXPANDED) != 0);
        if (changed & KLIO_A11Y_STATE_FOCUSED) a.notify_state_change(o, ATK_STATE_FOCUSED, (n.states & KLIO_A11Y_STATE_FOCUSED) != 0);
        if (was->value != n.value || was->name != n.name) a.signal_emit_by_name(o, "visible-data-changed");
    }
}

// A node's name as a client reads it through ATK.
static std::string klioSdlAtkName(AtkObject* o) {
    const gchar* name = klioAtk().get_name(o);
    return name ? name : "";
}

static int klioSdlAtkRole(AtkObject* o) {
    switch (klioAtk().get_role(o)) {
        case ATK_ROLE_PUSH_BUTTON: return KLIO_A11Y_ROLE_BUTTON;
        case ATK_ROLE_CHECK_BOX: return KLIO_A11Y_ROLE_CHECKBOX;
        case ATK_ROLE_TOGGLE_BUTTON: return KLIO_A11Y_ROLE_SWITCH;
        case ATK_ROLE_RADIO_BUTTON: return KLIO_A11Y_ROLE_RADIO_BUTTON;
        case ATK_ROLE_PAGE_TAB: return KLIO_A11Y_ROLE_TAB;
        case ATK_ROLE_COMBO_BOX: return KLIO_A11Y_ROLE_DROPDOWN;
        case ATK_ROLE_IMAGE: return KLIO_A11Y_ROLE_IMAGE;
        case ATK_ROLE_ENTRY: return KLIO_A11Y_ROLE_TEXT_FIELD;
        case ATK_ROLE_PASSWORD_TEXT: return KLIO_A11Y_ROLE_PASSWORD_FIELD;
        case ATK_ROLE_LABEL: return KLIO_A11Y_ROLE_TEXT;
        case ATK_ROLE_SLIDER: return KLIO_A11Y_ROLE_SLIDER;
        case ATK_ROLE_PROGRESS_BAR: return KLIO_A11Y_ROLE_PROGRESS;
        case ATK_ROLE_SCROLL_PANE: return KLIO_A11Y_ROLE_SCROLL_AREA;
        default: return KLIO_A11Y_ROLE_GROUP;
    }
}

static void klioSdlAtkDump(AtkObject* o, int depth) {
    KlioAtkApi& a = klioAtk();
    const int role = klioSdlAtkRole(o);
    AtkStateSet* states = a.ref_state_set(o);
    std::string detail;
    switch (role) {
        case KLIO_A11Y_ROLE_CHECKBOX:
        case KLIO_A11Y_ROLE_SWITCH:
        case KLIO_A11Y_ROLE_RADIO_BUTTON:
        case KLIO_A11Y_ROLE_TAB:
            detail = a.state_set_contains_state(states, ATK_STATE_INDETERMINATE) ? "mixed"
                     : a.state_set_contains_state(states, role == KLIO_A11Y_ROLE_SWITCH ? ATK_STATE_PRESSED : ATK_STATE_CHECKED)
                         ? "checked"
                         : "unchecked";
            break;
        case KLIO_A11Y_ROLE_TEXT_FIELD:
        case KLIO_A11Y_ROLE_PASSWORD_FIELD: {
            gchar* text = a.text_get_text(reinterpret_cast<AtkText*>(o), 0, -1);
            detail = std::string("value=\"") + (text ? text : "") + "\"";
            std::free(text);
            break;
        }
        case KLIO_A11Y_ROLE_SLIDER:
        case KLIO_A11Y_ROLE_PROGRESS: {
            GValue v = G_VALUE_INIT;
            a.value_get_current_value(reinterpret_cast<AtkValue*>(o), &v);
            char buf[64];
            std::snprintf(buf, sizeof buf, "value=%g", a.value_get_double(&v));
            a.value_unset(&v);
            detail = buf;
            break;
        }
        default:
            break;
    }
    if (a.state_set_contains_state(states, ATK_STATE_FOCUSED)) detail += detail.empty() ? "focused" : " focused";
    if (!a.state_set_contains_state(states, ATK_STATE_ENABLED)) detail += detail.empty() ? "disabled" : " disabled";
    a.object_unref(states);
    std::string name = klioSdlAtkName(o);
    if (role == KLIO_A11Y_ROLE_TEXT_FIELD || role == KLIO_A11Y_ROLE_PASSWORD_FIELD || role == KLIO_A11Y_ROLE_TEXT) {
        // A label reads its text; a field its name.
        if (role == KLIO_A11Y_ROLE_TEXT && name.empty()) {
            gchar* text = a.text_get_text(reinterpret_cast<AtkText*>(o), 0, -1);
            name = text ? text : "";
            std::free(text);
        }
    }
    klioA11yDumpLine(depth, role, name, detail);
    const gint n = a.get_n_children(o);
    for (gint i = 0; i < n; i++) {
        AtkObject* child = a.ref_child(o, i);
        if (!child) continue;
        klioSdlAtkDump(child, depth + 1);
        a.object_unref(child);
    }
}

static AtkObject* klioSdlAtkFind(AtkObject* o, const std::string& name) {
    KlioAtkApi& a = klioAtk();
    const gint n = a.get_n_children(o);
    for (gint i = 0; i < n; i++) {
        AtkObject* child = a.ref_child(o, i);
        if (!child) continue;
        if (klioSdlAtkName(child) == name) return child;
        AtkObject* found = klioSdlAtkFind(child, name);
        a.object_unref(child);
        if (found) return found;
    }
    return nullptr;
}

// Scripted input asking through ATK, as an AT-SPI client asks through
// atk-bridge.
static void klioSdlA11yScript(KlioWindow* kw, int kind, const std::string& name, const std::string& text) {
    AtkObject* frame = klioAtkFor(kw, -1);
    if (!frame) {
        std::fprintf(stderr, "klio: assistive technologies cannot read the window: ATK and atk-bridge are not installed\n");
        return;
    }
    KlioAtkApi& a = klioAtk();
    if (kind == KLIO_A11Y_SCRIPT_DUMP) {
        const gint n = a.get_n_children(frame);
        for (gint i = 0; i < n; i++) {
            AtkObject* child = a.ref_child(frame, i);
            if (!child) continue;
            klioSdlAtkDump(child, 0);
            a.object_unref(child);
        }
        return;
    }
    AtkObject* o = klioSdlAtkFind(frame, name);
    if (!o) {
        std::fprintf(stderr, "klio: no accessible node is named `%s`\n", name.c_str());
        return;
    }
    switch (kind) {
        case KLIO_A11Y_SCRIPT_PRESS:
            if (a.action_get_n_actions(reinterpret_cast<AtkAction*>(o)) > 0) a.action_do_action(reinterpret_cast<AtkAction*>(o), 0);
            break;
        case KLIO_A11Y_SCRIPT_FOCUS: a.component_grab_focus(reinterpret_cast<AtkComponent*>(o)); break;
        case KLIO_A11Y_SCRIPT_VALUE: a.set_text_contents(reinterpret_cast<AtkEditableText*>(o), text.c_str()); break;
        case KLIO_A11Y_SCRIPT_INCREMENT: {
            GValue v = G_VALUE_INIT;
            a.value_get_current_value(reinterpret_cast<AtkValue*>(o), &v);
            const double next = a.value_get_double(&v) + 1e-6;
            a.value_unset(&v);
            GValue target = G_VALUE_INIT;
            a.value_init(&target, G_TYPE_DOUBLE);
            a.value_set_double(&target, next);
            a.value_set_current_value(reinterpret_cast<AtkValue*>(o), &target);
            a.value_unset(&target);
            break;
        }
        default: break;
    }
    a.object_unref(o);
}

static bool klioSdlA11yBridged() { return klioAtk().bridged; }
#else
static void klioSdlA11yOpen(KlioWindow*) {}
static void klioSdlA11yClose(KlioWindow*) {}
static void klioSdlA11yUpdate(KlioWindow* kw, const char* text, size_t len) { kw->a11y = klioParseA11y(text, len); }
static void klioSdlA11yScript(KlioWindow*, int, const std::string&, const std::string&) {
    std::fprintf(stderr, "klio: assistive technologies cannot read the window: the shim was built without ATK's headers (libatk1.0-dev)\n");
}
static bool klioSdlA11yBridged() { return false; }
static void klioAtkPump() {}
#endif  // KLIO_ATK

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
            if (kw->swallowRelease) {
                kw->swallowRelease = false;
#if defined(KLIO_X11)
                klioXdndTrace("SDL button %s after a drag%s", down ? "down" : "up", down ? "" : ", dropped");
#endif
                if (!down) return;
            }
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
        // A drop on a Wayland window, which SDL reports only once it lands:
        // the drag enters, moves to the pointer and drops there (an X11
        // window's drags are XDND's, further down).
        case SDL_DROPBEGIN:
            kw->dropFiles.clear();
            kw->dropText.clear();
            kw->dropHasText = false;
            return;
        case SDL_DROPFILE:
            if (ev.drop.file) {
                kw->dropFiles.push_back(ev.drop.file);
                SDL_free(ev.drop.file);
            }
            return;
        case SDL_DROPTEXT:
            if (ev.drop.file) {
                kw->dropText += ev.drop.file;
                kw->dropHasText = true;
                SDL_free(ev.drop.file);
            }
            return;
        case SDL_DROPCOMPLETE: {
            int gx = 0, gy = 0, wx = 0, wy = 0;
            SDL_GetGlobalMouseState(&gx, &gy);
            SDL_GetWindowPosition(kw->win, &wx, &wy);
            const double x = gx - wx;
            const double y = gy - wy - kw->barH;
            const std::string payload = klioDndPayload(kw->dropFiles, kw->dropHasText ? &kw->dropText : nullptr);
            const int offered = KLIO_DND_ACTION_COPY;
            kw->events.push_back(klioDndEv(KLIO_DND_ENTER, x, y, offered, payload));
            kw->events.push_back(klioDndEv(KLIO_DND_OVER, x, y, offered, payload));
            kw->events.push_back(klioDndEv(KLIO_DND_DROP, x, y, offered, payload));
            kw->dropFiles.clear();
            kw->dropText.clear();
            kw->dropHasText = false;
            return;
        }
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

// The program's answer to the drag event it handled: the window's own drag
// hears it, or the XDND source waiting for it.
static void klioSdlDndAnswer(KlioWindow* kw, int action) {
    const KlioDndAsk ask = kw->dndAsk;
    kw->dndAsk = KlioDndAsk();
    if (ask.ask == KLIO_DND_ASK_SESSION) kw->drag.answer(kw->events, ask.kind, action);
#if defined(KLIO_X11)
    else if (ask.ask == KLIO_DND_ASK_REPLY) klioXdndAnswer(kw, ask.kind, action);
#endif
}

// Waits up to ms for SDL's next event. On X11 the shim's own connection,
// which carries the drags, is served as the window waits.
static int klioSdlWaitEvent(KlioWindow* kw, SDL_Event* ev, int ms) {
#if defined(KLIO_X11)
    if (klioXdndWatching()) {
        klioX11Pump();
        if (SDL_PollEvent(ev)) return 1;
        if (ms <= 0 || !kw->events.empty()) return 0;
        klioXdndWaitInput(ms);
        klioX11Pump();
        return SDL_PollEvent(ev);
    }
#endif
    (void)kw;
    return ms > 0 ? SDL_WaitEventTimeout(ev, ms) : SDL_PollEvent(ev);
}

// Waits up to timeoutMs for the window's next input event and writes its
// values to out (KLIO_EV_VALUES doubles); returns its type (window_events.h),
// or KLIO_EV_NONE when none came. SDL's queue is the process's: an event for
// another window is translated onto that window's queue.
int klio_win_poll_event(KlioWindow* kw, int timeoutMs, double* out) {
    if (!kw) return KLIO_EV_CLOSE;
    if (kw->dndAsk.kind) klioSdlDndAnswer(kw, 0);
    klioScriptTick(kw->script, kw->events);
    if (!kw->frameReport.reported) klioSdlReportFrame(kw);
    klioAtkPump();
    klioWakePosted().store(false);
    int wait = klioScriptWaitCap(timeoutMs);
    while (kw->events.empty()) {
        SDL_Event ev;
        // With the accessibility bridge up, the wait is cut into slices so
        // AT-SPI clients are answered while the window idles.
        const int slice = klioSdlA11yBridged() && wait > 20 ? 20 : wait;
        const int got = klioSdlWaitEvent(kw, &ev, slice);
        klioAtkPump();
        wait = got ? 0 : wait - slice;
        if (!got) {
            if (wait > 0) continue;
            break;
        }
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
            case SDL_DROPBEGIN:
            case SDL_DROPFILE:
            case SDL_DROPTEXT:
            case SDL_DROPCOMPLETE: wid = ev.drop.windowID; break;
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
        if (type == KLIO_EV_POINTER && kw->drag.active) {
            KlioEv e;
            e.type = type;
            for (int i = 0; i < KLIO_EV_VALUES; i++) e.v[i] = out[i];
            if (kw->drag.pointer(kw->events, e)) continue;
        }
        if (type == KLIO_EV_CURSOR_SCRIPT) {
            klioSdlPrintCursor();
            continue;
        }
        if (type == KLIO_EV_A11Y_SCRIPT) {
            const size_t at = static_cast<size_t>(out[1]);
            const size_t textAt = static_cast<size_t>(out[2]);
            if (textAt < klioScriptTexts().size()) {
                klioSdlA11yScript(kw, static_cast<int>(out[0]), klioScriptTexts()[at], klioScriptTexts()[textAt]);
            }
            continue;
        }
        if (type != KLIO_EV_MENU_PATH) {
            klioSdlShowMenus();
            kw->dndAsk.reported(type, out);
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

int klio_a11y_active(KlioWindow* kw) { return kw && kw->a11yActive ? 1 : 0; }

void klio_a11y_update(KlioWindow* kw, const char* text, size_t len) {
    if (!kw || !text) return;
    klioSdlA11yUpdate(kw, text, len);
}

static SDL_Cursor* klioSdlCursor(int kind) {
    static SDL_Cursor* cursors[4] = {};
    if (kind < 0 || kind > 3) kind = KLIO_CURSOR_DEFAULT;
    if (!cursors[kind]) {
        const SDL_SystemCursor ids[] = {SDL_SYSTEM_CURSOR_ARROW, SDL_SYSTEM_CURSOR_CROSSHAIR, SDL_SYSTEM_CURSOR_IBEAM,
                                        SDL_SYSTEM_CURSOR_HAND};
        cursors[kind] = SDL_CreateSystemCursor(ids[kind]);
    }
    return cursors[kind];
}

// The cursor over the window's content. SDL's cursor is the mouse's, so a
// window sets it as the pointer's hover over it asks.
// Wakes the window loop from any thread: SDL's wait ends on the pushed event,
// the X11 wait on the pipe.
void klio_app_wake(void) {
    if (klioWakePosted().exchange(true)) return;
    if (klioSdlWakeType) {
        SDL_Event e;
        SDL_zero(e);
        e.type = klioSdlWakeType;
        SDL_PushEvent(&e);
    }
#if !defined(_WIN32)
    if (klioWakePipe[1] >= 0) {
        const char b = 1;
        (void)!write(klioWakePipe[1], &b, 1);
    }
#endif
}

// The refresh rate of the display the window is on, in frames a second (0
// where SDL does not know it).
int klio_win_refresh_hz(KlioWindow* kw) {
    if (!kw) return 0;
    const int display = SDL_GetWindowDisplayIndex(kw->win);
    SDL_DisplayMode mode;
    if (display < 0 || SDL_GetCurrentDisplayMode(display, &mode) != 0) return 0;
    return mode.refresh_rate;
}

void klio_win_set_cursor(KlioWindow* kw, int kind) {
    if (!kw) return;
    if (SDL_Cursor* c = klioSdlCursor(kind)) SDL_SetCursor(c);
}

// The program's answer to the drag event it handled: the action it takes
// (0 for none).
void klio_win_dnd_accept(KlioWindow* kw, int action) {
    if (kw) klioSdlDndAnswer(kw, action);
}

// Starts a drag of the payload from the window: XDND's on X11, as AWT's
// XToolkit starts one (X11 drags show no image, as AWT's do not), or where
// there is none (Wayland, a scripted press) a drag the window runs itself,
// over the window and dropped in it.
int klio_win_drag_start(KlioWindow* kw, const char* payload, size_t len, const unsigned char*, size_t, int, int,
                        int actions) {
    if (!kw || !payload) return 0;
    const std::string data(payload, len);
#if defined(KLIO_X11)
    // Only a real press moves the pointer the drag follows.
    const bool pressed = (kw->buttons & (1 << (KLIO_BTN_PRIMARY - 1))) != 0;
    klioXdndTrace("drag asked from 0x%lx, buttons %d", kw->xwin, kw->buttons);
    if (pressed && klioXdndStart(kw, data, actions)) return 1;
#endif
    kw->drag.start(actions, data);
    return 1;
}

static void klioSdlPrintCursor() {
    SDL_Cursor* shown = SDL_GetCursor();
    int kind = KLIO_CURSOR_DEFAULT;
    for (int k = KLIO_CURSOR_CROSSHAIR; k <= KLIO_CURSOR_HAND; k++) {
        if (shown && shown == klioSdlCursor(k)) kind = k;
    }
    klioPrintCursor(kind);
}

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

#if defined(KLIO_X11)
// The Linux tray icon, as the desktop's AWT puts one on X11: an XEmbed icon
// window docked in the system tray (the _NET_SYSTEM_TRAY_S<screen> selection's
// owner), a left click its action, a right press its popup menu, a tooltip
// after a pause over it, and a notification as a balloon by it. There is a
// tray only while some tray manager owns the selection, as AWT's
// SystemTray.isSupported answers. libX11 is loaded when a tray or a window
// first asks for it, so a host without X11 runs without it.
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
    int (*SetSelectionOwner)(Display*, Atom, Window, Time);
    int (*ConvertSelection)(Display*, Atom, Atom, Atom, Window, Time);
    int (*Sync)(Display*, Bool);
    int (*(*SetErrorHandler)(int (*)(Display*, XErrorEvent*)))(Display*, XErrorEvent*);
    Cursor (*CreateFontCursor)(Display*, unsigned);
    int (*FreeCursor)(Display*, Cursor);
    int (*ChangeActivePointerGrab)(Display*, unsigned, Cursor, Time);
    char* (*GetAtomName)(Display*, Atom);
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
    get(x.SetSelectionOwner, "XSetSelectionOwner");
    get(x.ConvertSelection, "XConvertSelection");
    get(x.Sync, "XSync");
    get(x.SetErrorHandler, "XSetErrorHandler");
    get(x.CreateFontCursor, "XCreateFontCursor");
    get(x.FreeCursor, "XFreeCursor");
    get(x.ChangeActivePointerGrab, "XChangeActivePointerGrab");
    get(x.GetAtomName, "XGetAtomName");
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

// ---------------------------------------------------------------------------
// Drag and drop over XDND, as AWT's XToolkit runs it. Each window's
// XdndProxy names a window of the shim's own X connection, so the drags over
// it come to the shim, which reports them to the program and answers each
// position and the drop with the program's answer. A drag the program starts
// owns XdndSelection and runs the source side of the protocol under a
// pointer grab. The windows' poll serves both, so the program runs, and
// answers the drags over its own windows, while a drag goes on. Under
// Wayland SDL's drop events and the window's own drag stand in.

struct KlioXdndAtoms {
    Atom aware, proxy, enter, position, status, leave, drop, finished, selection, typeList, actionList;
    Atom copy, move, link, targets, utf8, uriList, textPlain, textPlainUtf8, textPlainUTF8, data;
};

// The drag over one of the windows.
struct KlioXdndIn {
    KlioWindow* kw = nullptr;  // the window it is over; null when none
    Window source = None;      // the dragging application's window
    Window addressed = None;   // the window the source addresses: the window's, or its proxy
    Atom want[2] = {None, None};  // the files' and the text's types still to read
    bool reading = false;
    std::chrono::steady_clock::time_point since;
    std::vector<std::string> files;
    std::string text;
    bool hasText = false;
    int x = 0;
    int y = 0;
    int offered = 0;
    bool positioned = false;  // a position waits for the data
    bool dropped = false;     // the drop waits for the data, then for the program
    bool entered = false;     // the program heard the drag enter
};

// The drag a window started.
struct KlioXdndOut {
    KlioWindow* kw = nullptr;  // the window dragging; null when none
    std::vector<std::string> files;
    std::string text;
    bool hasText = false;
    std::vector<Atom> types;
    int actions = 0;
    Window target = None;  // the XdndAware window under the pointer
    Window to = None;      // where its messages go: its proxy, or itself
    int version = 0;
    bool waiting = false;  // a position waits for its status
    bool moved = false;    // the pointer moved while it waited
    int rx = 0;
    int ry = 0;
    Time time = CurrentTime;
    bool accepted = false;
    Atom action = None;
    bool grabbed = false;
    bool dropped = false;
    std::chrono::steady_clock::time_point droppedAt;
    Cursor yes = None;
    Cursor no = None;
};

struct KlioXdnd {
    bool ready = false;
    Window root = None;
    Display* sdlDpy = nullptr;  // SDL's connection, which the windows' poll waits on with the shim's
    KlioXdndAtoms a{};
    KlioXdndIn in;
    KlioXdndOut out;
};

static KlioXdnd& klioXdnd() {
    static KlioXdnd d;
    return d;
}

static int klioX11IgnoreError(Display*, XErrorEvent*) { return 0; }

// X errors about a window that went away mid-drag are ignored, where Xlib's
// default handler would end the process.
struct KlioX11Trap {
    Display* dpy;
    int (*prev)(Display*, XErrorEvent*);
    explicit KlioX11Trap(Display* d) : dpy(d) { prev = klioX11()->SetErrorHandler(klioX11IgnoreError); }
    ~KlioX11Trap() {
        klioX11()->Sync(dpy, False);
        klioX11()->SetErrorHandler(prev);
    }
    KlioX11Trap(const KlioX11Trap&) = delete;
    KlioX11Trap& operator=(const KlioX11Trap&) = delete;
};

static bool klioXdndReady() {
    KlioXdnd& d = klioXdnd();
    if (d.ready) return true;
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy) return false;
    auto atom = [&](const char* name) { return x->InternAtom(dpy, name, False); };
    KlioXdndAtoms& a = d.a;
    a.aware = atom("XdndAware");
    a.proxy = atom("XdndProxy");
    a.enter = atom("XdndEnter");
    a.position = atom("XdndPosition");
    a.status = atom("XdndStatus");
    a.leave = atom("XdndLeave");
    a.drop = atom("XdndDrop");
    a.finished = atom("XdndFinished");
    a.selection = atom("XdndSelection");
    a.typeList = atom("XdndTypeList");
    a.actionList = atom("XdndActionList");
    a.copy = atom("XdndActionCopy");
    a.move = atom("XdndActionMove");
    a.link = atom("XdndActionLink");
    a.targets = atom("TARGETS");
    a.utf8 = atom("UTF8_STRING");
    a.uriList = atom("text/uri-list");
    a.textPlain = atom("text/plain");
    a.textPlainUtf8 = atom("text/plain;charset=utf-8");
    a.textPlainUTF8 = atom("text/plain;charset=UTF-8");
    a.data = atom("KLIO_XDND_DATA");
    d.root = x->RootWindow_(dpy, x->DefaultScreen_(dpy));
    d.ready = true;
    return true;
}

static bool klioXdndTracing() {
    static const bool on = std::getenv("KLIO_XDND_TRACE") != nullptr;
    return on;
}

// KLIO_XDND_TRACE: the windows' XDND messages, sent and heard, on stderr.
static void klioXdndTrace(const char* fmt, ...) {
    if (!klioXdndTracing()) return;
    va_list args;
    va_start(args, fmt);
    std::fputs("[xdnd] ", stderr);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    va_end(args);
}

static std::string klioX11AtomName(Atom atom) {
    if (atom == None) return "None";
    char* name = klioX11()->GetAtomName(klioX11Display(), atom);
    if (!name) return "?";
    std::string out(name);
    klioX11()->Free(name);
    return out;
}

static int klioXdndActionBit(Atom action) {
    const KlioXdndAtoms& a = klioXdnd().a;
    if (action == a.move) return KLIO_DND_ACTION_MOVE;
    if (action == a.link) return KLIO_DND_ACTION_LINK;
    return KLIO_DND_ACTION_COPY;
}

static Atom klioXdndActionAtom(int bit) {
    const KlioXdndAtoms& a = klioXdnd().a;
    switch (bit) {
        case KLIO_DND_ACTION_COPY: return a.copy;
        case KLIO_DND_ACTION_MOVE: return a.move;
        case KLIO_DND_ACTION_LINK: return a.link;
        default: return None;
    }
}

static void klioXdndSend(Window to, Window window, Atom type, long l0, long l1, long l2, long l3, long l4) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (klioXdndTracing()) {
        klioXdndTrace("send %s to 0x%lx window 0x%lx [0x%lx %ld %ld %ld %s]", klioX11AtomName(type).c_str(), to, window,
                      l0, l1, l2, l3, klioX11AtomName(static_cast<Atom>(l4)).c_str());
    }
    XEvent ev{};
    ev.xclient.type = ClientMessage;
    ev.xclient.display = dpy;
    ev.xclient.window = window;
    ev.xclient.message_type = type;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = l0;
    ev.xclient.data.l[1] = l1;
    ev.xclient.data.l[2] = l2;
    ev.xclient.data.l[3] = l3;
    ev.xclient.data.l[4] = l4;
    x->SendEvent(dpy, to, False, NoEventMask, &ev);
}

// A window property of 32-bit items (atoms, windows), or empty.
static std::vector<unsigned long> klioX11Items(Window w, Atom prop, Atom type) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    std::vector<unsigned long> out;
    Atom got = None;
    int format = 0;
    unsigned long n = 0, after = 0;
    unsigned char* data = nullptr;
    if (x->GetWindowProperty(dpy, w, prop, 0, 1024, False, type, &got, &format, &n, &after, &data) == Success && data) {
        if (format == 32) {
            const auto* items = reinterpret_cast<const unsigned long*>(data);
            out.assign(items, items + n);
        }
        x->Free(data);
    }
    return out;
}

// A property of bytes, deleted as it is read.
static std::string klioX11TakeBytes(Window w, Atom prop) {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    std::string out;
    Atom got = None;
    int format = 0;
    unsigned long n = 0, after = 0;
    unsigned char* data = nullptr;
    if (x->GetWindowProperty(dpy, w, prop, 0, 1L << 24, True, AnyPropertyType, &got, &format, &n, &after, &data) ==
            Success &&
        data) {
        if (format == 8) out.assign(reinterpret_cast<const char*>(data), n);
        x->Free(data);
    }
    return out;
}

// A path as a file URI's path, and back.
static std::string klioUriEncode(const std::string& path) {
    static const char hex[] = "0123456789ABCDEF";
    std::string out;
    for (const unsigned char c : path) {
        if (std::isalnum(c) || (c != 0 && std::strchr("-._~/!$&'()*+,;=:@", c))) {
            out += static_cast<char>(c);
        } else {
            out += '%';
            out += hex[c >> 4];
            out += hex[c & 15];
        }
    }
    return out;
}

static std::string klioUriDecode(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '%' && i + 2 < s.size() && std::isxdigit(static_cast<unsigned char>(s[i + 1])) &&
            std::isxdigit(static_cast<unsigned char>(s[i + 2]))) {
            out += static_cast<char>(std::stoi(s.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else {
            out += s[i];
        }
    }
    return out;
}

// The files of a text/uri-list: its file URIs, as paths.
static std::vector<std::string> klioXdndFiles(const std::string& list) {
    std::vector<std::string> files;
    size_t i = 0;
    while (i < list.size()) {
        const size_t end = std::min(list.find('\n', i), list.size());
        std::string line = list.substr(i, end - i);
        i = end + 1;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#' || line.compare(0, 5, "file:") != 0) continue;
        std::string path = line.substr(5);
        if (path.compare(0, 2, "//") == 0) {
            const size_t slash = path.find('/', 2);
            if (slash == std::string::npos) continue;
            path = path.substr(slash);
        }
        files.push_back(klioUriDecode(path));
    }
    return files;
}

// The window an X window is, or is the proxy of.
static KlioWindow* klioXdndWindow(Window w) {
    for (const auto& entry : klioSdlWindows()) {
        if (entry.second->xwin == w || entry.second->xproxy == w) return entry.second;
    }
    return nullptr;
}

// --- The drag over a window ------------------------------------------------

static void klioXdndInReport(int kind) {
    KlioXdndIn& in = klioXdnd().in;
    const std::string payload = klioDndPayload(in.files, in.hasText ? &in.text : nullptr);
    in.kw->events.push_back(klioDndEv(kind, in.x, in.y, in.offered, payload, KLIO_DND_ASK_REPLY));
}

// The data is all here (or no more is coming): the position and the drop
// waiting for it are reported.
static void klioXdndInReady() {
    KlioXdndIn& in = klioXdnd().in;
    if (in.positioned || (in.dropped && !in.entered)) {
        in.positioned = false;
        klioXdndInReport(in.entered ? KLIO_DND_OVER : KLIO_DND_ENTER);
        in.entered = true;
    }
    if (in.dropped) klioXdndInReport(KLIO_DND_DROP);
}

// Asks the source for the next type still to read, or reports the drag
// once none is left.
static void klioXdndInRead() {
    KlioXdnd& d = klioXdnd();
    KlioXdndIn& in = d.in;
    for (const Atom type : in.want) {
        if (type == None) continue;
        klioX11()->ConvertSelection(klioX11Display(), d.a.selection, type, d.a.data, in.kw->xproxy, CurrentTime);
        in.reading = true;
        in.since = std::chrono::steady_clock::now();
        return;
    }
    in.reading = false;
    klioXdndInReady();
}

static void klioXdndInLeave() {
    KlioXdndIn& in = klioXdnd().in;
    if (in.kw && in.entered && !in.dropped) in.kw->events.push_back(klioDndEv(KLIO_DND_EXIT, 0, 0, 0));
    in = KlioXdndIn();
}

static void klioXdndInEnter(const XClientMessageEvent& m) {
    KlioXdnd& d = klioXdnd();
    KlioWindow* kw = klioXdndWindow(m.window);
    if (!kw) return;
    klioXdndInLeave();
    KlioXdndIn& in = d.in;
    in.kw = kw;
    in.source = static_cast<Window>(m.data.l[0]);
    in.addressed = m.window;
    std::vector<unsigned long> types;
    if (m.data.l[1] & 1) {
        types = klioX11Items(in.source, d.a.typeList, XA_ATOM);
    } else {
        for (int i = 2; i <= 4; i++) {
            if (m.data.l[i]) types.push_back(static_cast<unsigned long>(m.data.l[i]));
        }
    }
    // The text in the first of these types the source offers.
    const Atom texts[] = {d.a.utf8, d.a.textPlainUtf8, d.a.textPlainUTF8, d.a.textPlain};
    for (const Atom text : texts) {
        if (in.want[1] == None && std::find(types.begin(), types.end(), text) != types.end()) in.want[1] = text;
    }
    if (std::find(types.begin(), types.end(), d.a.uriList) != types.end()) in.want[0] = d.a.uriList;
    klioXdndInRead();
}

static void klioXdndInPosition(const XClientMessageEvent& m) {
    KlioXdnd& d = klioXdnd();
    KlioXdndIn& in = d.in;
    if (!in.kw || static_cast<Window>(m.data.l[0]) != in.source || in.dropped) return;
    const int rx = static_cast<int>((m.data.l[2] >> 16) & 0xFFFF);
    const int ry = static_cast<int>(m.data.l[2] & 0xFFFF);
    int wx = 0, wy = 0;
    Window child = None;
    klioX11()->TranslateCoordinates(klioX11Display(), d.root, in.kw->xwin, rx, ry, &wx, &wy, &child);
    in.x = wx;
    in.y = wy - in.kw->barH;
    in.offered = klioXdndActionBit(static_cast<Atom>(m.data.l[4]));
    in.positioned = true;
    if (!in.reading) klioXdndInReady();
}

static void klioXdndInDrop(const XClientMessageEvent& m) {
    KlioXdndIn& in = klioXdnd().in;
    if (!in.kw || static_cast<Window>(m.data.l[0]) != in.source || in.dropped) return;
    in.dropped = true;
    in.positioned = false;
    if (!in.reading) klioXdndInReady();
}

static void klioXdndInData(const XSelectionEvent& e) {
    KlioXdnd& d = klioXdnd();
    KlioXdndIn& in = d.in;
    if (!in.kw || !in.reading) return;
    const std::string bytes = e.property != None ? klioX11TakeBytes(in.kw->xproxy, e.property) : std::string();
    klioXdndTrace("data %s: %zu bytes", klioX11AtomName(e.target).c_str(), bytes.size());
    if (e.target == in.want[0]) {
        in.files = klioXdndFiles(bytes);
        in.want[0] = None;
    } else if (e.target == in.want[1]) {
        if (e.property != None) {
            in.text = bytes;
            in.hasText = true;
        }
        in.want[1] = None;
    } else {
        return;
    }
    klioXdndInRead();
}

// The program's answer to the drag over one of the windows: the source
// hears it as the status of the position, or as the drop's end.
static void klioXdndAnswer(KlioWindow* kw, int kind, int action) {
    KlioXdnd& d = klioXdnd();
    KlioXdndIn& in = d.in;
    if (!d.ready || in.kw != kw) return;
    Display* dpy = klioX11Display();
    KlioX11Trap trap(dpy);
    const Atom atom = action ? klioXdndActionAtom(action) : None;
    if (kind == KLIO_DND_DROP) {
        if (!in.dropped) return;
        klioXdndSend(in.source, in.source, d.a.finished, static_cast<long>(in.addressed), action ? 1 : 0,
                     static_cast<long>(atom), 0, 0);
        in = KlioXdndIn();
        return;
    }
    // Once it drops, the source waits only for the drop's end.
    if (in.dropped) return;
    klioXdndSend(in.source, in.source, d.a.status, static_cast<long>(in.addressed), action ? 3 : 2, 0, 0,
                 static_cast<long>(atom));
}

// --- The drag a window started -----------------------------------------------

// XdndAware's version on a window; 0 where it has none.
static int klioXdndAware(Window w) {
    const std::vector<unsigned long> v = klioX11Items(w, klioXdnd().a.aware, XA_ATOM);
    return v.empty() ? 0 : static_cast<int>(v[0]);
}

// The window under the root point that takes XDND drags, where its messages
// go, and its version; None where no window takes them.
static Window klioXdndFindTarget(int rx, int ry, Window* to, int* version) {
    KlioXdnd& d = klioXdnd();
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    Window w = d.root;
    for (int depth = 0; depth < 32; depth++) {
        Window child = None;
        int cx = 0, cy = 0;
        if (!x->TranslateCoordinates(dpy, d.root, w, rx, ry, &cx, &cy, &child) || child == None) return None;
        w = child;
        const int v = klioXdndAware(w);
        if (v == 0) continue;
        if (v < 3) return None;
        const std::vector<unsigned long> proxy = klioX11Items(w, d.a.proxy, XA_WINDOW);
        *to = proxy.empty() || proxy[0] == None ? w : static_cast<Window>(proxy[0]);
        *version = std::min(v, 5);
        return w;
    }
    return None;
}

static void klioXdndCursor(bool accepted) {
    KlioXdndOut& out = klioXdnd().out;
    if (!out.grabbed) return;
    klioX11()->ChangeActivePointerGrab(klioX11Display(), ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                                       accepted ? out.yes : out.no, CurrentTime);
}

// The pointer at a root point: the drag leaves the window it was over for
// the one there, and tells it where it is once it answered the last time.
static void klioXdndMove(int rx, int ry) {
    KlioXdnd& d = klioXdnd();
    KlioXdndOut& out = d.out;
    out.rx = rx;
    out.ry = ry;
    Window to = None;
    int version = 0;
    const Window target = klioXdndFindTarget(rx, ry, &to, &version);
    if (target != out.target) {
        if (out.target) klioXdndSend(out.to, out.target, d.a.leave, static_cast<long>(out.kw->xproxy), 0, 0, 0, 0);
        out.target = target;
        out.to = to;
        out.version = version;
        out.waiting = false;
        out.accepted = false;
        out.action = None;
        klioXdndCursor(false);
        if (target) {
            long types[3] = {0, 0, 0};
            for (size_t i = 0; i < out.types.size() && i < 3; i++) types[i] = static_cast<long>(out.types[i]);
            const long flags = (static_cast<long>(version) << 24) | (out.types.size() > 3 ? 1 : 0);
            klioXdndSend(to, target, d.a.enter, static_cast<long>(out.kw->xproxy), flags, types[0], types[1], types[2]);
        }
    }
    if (!out.target) return;
    if (out.waiting) {
        out.moved = true;
        return;
    }
    klioXdndSend(out.to, out.target, d.a.position, static_cast<long>(out.kw->xproxy), 0,
                 (static_cast<long>(rx) << 16) | (ry & 0xFFFF), static_cast<long>(out.time),
                 static_cast<long>(klioXdndActionAtom(klioDndDefaultAction(out.actions))));
    out.waiting = true;
    out.moved = false;
}

// The pointer is the window's again: the grab ends, and the button the drag
// took is up. SDL, which saw the press, hears a release the window drops,
// and, where the pointer left the window during the drag (the grab's
// crossings are not SDL's to act on), that it left.
static void klioXdndRelease() {
    KlioXdnd& d = klioXdnd();
    KlioXdndOut& out = d.out;
    if (!out.grabbed) return;
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    x->UngrabPointer(dpy, CurrentTime);
    x->UngrabKeyboard(dpy, CurrentTime);
    out.grabbed = false;
    KlioWindow* kw = out.kw;
    kw->buttons &= ~(1 << (KLIO_BTN_PRIMARY - 1));
    kw->swallowRelease = true;
    int wx = 0, wy = 0;
    Window child = None;
    x->TranslateCoordinates(dpy, d.root, kw->xwin, out.rx, out.ry, &wx, &wy, &child);
    XEvent up{};
    up.xbutton.type = ButtonRelease;
    up.xbutton.display = dpy;
    up.xbutton.window = kw->xwin;
    up.xbutton.root = d.root;
    up.xbutton.time = out.time;
    up.xbutton.x = wx;
    up.xbutton.y = wy;
    up.xbutton.x_root = out.rx;
    up.xbutton.y_root = out.ry;
    up.xbutton.state = Button1Mask;
    up.xbutton.button = Button1;
    up.xbutton.same_screen = True;
    x->SendEvent(dpy, kw->xwin, False, ButtonReleaseMask, &up);
    int w = 0, h = 0;
    SDL_GetWindowSize(kw->win, &w, &h);
    if (wx >= 0 && wy >= 0 && wx < w && wy < h) return;
    XEvent left{};
    left.xcrossing.type = LeaveNotify;
    left.xcrossing.display = dpy;
    left.xcrossing.window = kw->xwin;
    left.xcrossing.root = d.root;
    left.xcrossing.time = out.time;
    left.xcrossing.x = wx;
    left.xcrossing.y = wy;
    left.xcrossing.x_root = out.rx;
    left.xcrossing.y_root = out.ry;
    left.xcrossing.mode = NotifyNormal;
    left.xcrossing.detail = NotifyNonlinear;
    left.xcrossing.same_screen = True;
    x->SendEvent(dpy, kw->xwin, False, LeaveWindowMask, &left);
}

// The drag ends with the action the target took (0 for none), which the
// window that started it hears.
static void klioXdndEnd(int taken, bool report = true) {
    KlioXdnd& d = klioXdnd();
    KlioXdndOut& out = d.out;
    if (!out.kw) return;
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (report) klioXdndRelease();
    if (out.grabbed) {
        x->UngrabPointer(dpy, CurrentTime);
        x->UngrabKeyboard(dpy, CurrentTime);
    }
    if (out.yes) x->FreeCursor(dpy, out.yes);
    if (out.no) x->FreeCursor(dpy, out.no);
    if (x->GetSelectionOwner(dpy, d.a.selection) == out.kw->xproxy) {
        x->SetSelectionOwner(dpy, d.a.selection, None, CurrentTime);
    }
    klioXdndTrace("drag ended, taken %d", taken);
    if (report) out.kw->events.push_back(klioDndEv(KLIO_DND_SOURCE_ENDED, 0, 0, taken));
    d.out = KlioXdndOut();
}

// The drop at the pointer's release, or the drag's end where nothing took it.
static void klioXdndDrop(bool cancelled) {
    KlioXdnd& d = klioXdnd();
    KlioXdndOut& out = d.out;
    klioXdndRelease();
    if (!cancelled && out.target && out.accepted) {
        klioXdndSend(out.to, out.target, d.a.drop, static_cast<long>(out.kw->xproxy), 0, static_cast<long>(out.time), 0, 0);
        out.dropped = true;
        out.droppedAt = std::chrono::steady_clock::now();
        return;
    }
    if (out.target) klioXdndSend(out.to, out.target, d.a.leave, static_cast<long>(out.kw->xproxy), 0, 0, 0, 0);
    klioXdndEnd(0);
}

static bool klioXdndStart(KlioWindow* kw, const std::string& payload, int actions) {
    KlioXdnd& d = klioXdnd();
    if (!d.ready || !kw->xwin || d.out.kw) return false;
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    KlioXdndOut out;
    klioDndParse(payload, out.files, out.text, out.hasText);
    if (out.files.empty() && !out.hasText) return false;
    if (!out.files.empty()) out.types.push_back(d.a.uriList);
    if (out.hasText) {
        out.types.push_back(d.a.textPlain);
        out.types.push_back(d.a.textPlainUtf8);
        out.types.push_back(d.a.utf8);
    }
    out.actions = actions;
    out.kw = kw;
    KlioX11Trap trap(dpy);
    // The press's grab is SDL's connection's: it lets go, so the drag's grab
    // takes the pointer.
    if (d.sdlDpy) {
        x->UngrabPointer(d.sdlDpy, CurrentTime);
        x->Sync(d.sdlDpy, False);
    }
    out.yes = x->CreateFontCursor(dpy, XC_hand2);
    out.no = x->CreateFontCursor(dpy, XC_circle);
    const int grab = x->GrabPointer(dpy, d.root, False, ButtonPressMask | ButtonReleaseMask | PointerMotionMask,
                                    GrabModeAsync, GrabModeAsync, None, out.no, CurrentTime);
    if (grab != GrabSuccess) {
        klioXdndTrace("drag from 0x%lx not started: the pointer grab failed (%d)", kw->xwin, grab);
        x->FreeCursor(dpy, out.yes);
        x->FreeCursor(dpy, out.no);
        return false;
    }
    x->GrabKeyboard(dpy, d.root, False, GrabModeAsync, GrabModeAsync, CurrentTime);
    out.grabbed = true;
    x->ChangeProperty(dpy, kw->xproxy, d.a.typeList, XA_ATOM, 32, PropModeReplace,
                      reinterpret_cast<const unsigned char*>(out.types.data()), static_cast<int>(out.types.size()));
    std::vector<Atom> offered;
    for (const int bit : {KLIO_DND_ACTION_COPY, KLIO_DND_ACTION_MOVE, KLIO_DND_ACTION_LINK}) {
        if (actions & bit) offered.push_back(klioXdndActionAtom(bit));
    }
    x->ChangeProperty(dpy, kw->xproxy, d.a.actionList, XA_ATOM, 32, PropModeReplace,
                      reinterpret_cast<const unsigned char*>(offered.data()), static_cast<int>(offered.size()));
    x->SetSelectionOwner(dpy, d.a.selection, kw->xproxy, CurrentTime);
    klioXdndTrace("drag started from 0x%lx, %zu types", kw->xwin, out.types.size());
    d.out = std::move(out);
    Window r = None, c = None;
    int rx = 0, ry = 0, wx = 0, wy = 0;
    unsigned mask = 0;
    if (x->QueryPointer(dpy, d.root, &r, &c, &rx, &ry, &wx, &wy, &mask)) klioXdndMove(rx, ry);
    return true;
}

// The data of the drag a window started, for a target that asks.
static void klioXdndServe(const XSelectionRequestEvent& r) {
    KlioXdnd& d = klioXdnd();
    const KlioXdndOut& out = d.out;
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    const Atom prop = r.property != None ? r.property : r.target;
    bool served = false;
    if (out.kw && r.owner == out.kw->xproxy) {
        const bool text = r.target == d.a.utf8 || r.target == d.a.textPlain || r.target == d.a.textPlainUtf8 ||
                          r.target == d.a.textPlainUTF8;
        if (r.target == d.a.targets) {
            std::vector<Atom> list = out.types;
            list.push_back(d.a.targets);
            x->ChangeProperty(dpy, r.requestor, prop, XA_ATOM, 32, PropModeReplace,
                              reinterpret_cast<const unsigned char*>(list.data()), static_cast<int>(list.size()));
            served = true;
        } else if (r.target == d.a.uriList && !out.files.empty()) {
            std::string list;
            for (const std::string& f : out.files) list += "file://" + klioUriEncode(f) + "\r\n";
            x->ChangeProperty(dpy, r.requestor, prop, r.target, 8, PropModeReplace,
                              reinterpret_cast<const unsigned char*>(list.data()), static_cast<int>(list.size()));
            served = true;
        } else if (text && out.hasText) {
            x->ChangeProperty(dpy, r.requestor, prop, r.target, 8, PropModeReplace,
                              reinterpret_cast<const unsigned char*>(out.text.data()), static_cast<int>(out.text.size()));
            served = true;
        }
    }
    XEvent n{};
    n.xselection.type = SelectionNotify;
    n.xselection.display = dpy;
    n.xselection.requestor = r.requestor;
    n.xselection.selection = r.selection;
    n.xselection.target = r.target;
    n.xselection.property = served ? prop : None;
    n.xselection.time = r.time;
    x->SendEvent(dpy, r.requestor, False, NoEventMask, &n);
    klioXdndTrace("asked for %s by 0x%lx: %s", klioX11AtomName(r.target).c_str(), r.requestor, served ? "served" : "refused");
}

// --- The shim's X connection ---------------------------------------------------

// An X event of the drags; false when it is not theirs.
static bool klioXdndEvent(const XEvent& ev) {
    KlioXdnd& d = klioXdnd();
    if (!d.ready) return false;
    KlioXdndOut& out = d.out;
    switch (ev.type) {
        case ClientMessage: {
            const XClientMessageEvent& m = ev.xclient;
            const Atom t = m.message_type;
            if (klioXdndTracing()) {
                klioXdndTrace("hear %s window 0x%lx [0x%lx %ld %ld %ld %s]", klioX11AtomName(t).c_str(), m.window,
                              m.data.l[0], m.data.l[1], m.data.l[2], m.data.l[3],
                              klioX11AtomName(static_cast<Atom>(m.data.l[4])).c_str());
            }
            if (t == d.a.enter) klioXdndInEnter(m);
            else if (t == d.a.position) klioXdndInPosition(m);
            else if (t == d.a.leave) {
                if (d.in.kw && static_cast<Window>(m.data.l[0]) == d.in.source) klioXdndInLeave();
            } else if (t == d.a.drop) klioXdndInDrop(m);
            else if (t == d.a.status) {
                if (!out.kw || static_cast<Window>(m.data.l[0]) != out.target) return true;
                out.waiting = false;
                out.accepted = (m.data.l[1] & 1) != 0;
                out.action = out.accepted ? static_cast<Atom>(m.data.l[4]) : None;
                klioXdndCursor(out.accepted);
                if (!out.dropped && out.moved) klioXdndMove(out.rx, out.ry);
            } else if (t == d.a.finished) {
                if (!out.kw || !out.dropped || static_cast<Window>(m.data.l[0]) != out.target) return true;
                int taken = out.action != None ? klioXdndActionBit(out.action) : 0;
                if (out.version >= 5) taken = (m.data.l[1] & 1) ? klioXdndActionBit(static_cast<Atom>(m.data.l[2])) : 0;
                klioXdndEnd(taken);
            } else {
                return false;
            }
            return true;
        }
        case SelectionRequest:
            if (!klioXdndWindow(ev.xselectionrequest.owner) || ev.xselectionrequest.selection != d.a.selection) {
                return false;
            }
            klioXdndServe(ev.xselectionrequest);
            return true;
        case SelectionNotify:
            if (!klioXdndWindow(ev.xselection.requestor) || ev.xselection.selection != d.a.selection) return false;
            klioXdndInData(ev.xselection);
            return true;
        case MotionNotify:
            if (!out.grabbed || ev.xmotion.window != d.root) return false;
            out.time = ev.xmotion.time;
            klioXdndMove(ev.xmotion.x_root, ev.xmotion.y_root);
            return true;
        case ButtonRelease:
            if (!out.grabbed || ev.xbutton.window != d.root) return false;
            if (ev.xbutton.button != Button1) return true;
            out.time = ev.xbutton.time;
            out.rx = ev.xbutton.x_root;
            out.ry = ev.xbutton.y_root;
            klioXdndDrop(false);
            return true;
        case ButtonPress:
            return out.grabbed && ev.xbutton.window == d.root;
        case KeyPress:
            if (!out.grabbed) return false;
            if (klioX11()->LookupKeysym(const_cast<XKeyEvent*>(&ev.xkey), 0) == XK_Escape) klioXdndDrop(true);
            return true;
        case KeyRelease:
            return out.grabbed;
        default:
            return false;
    }
}

// What a drag waits for that does not come: data a source never sends is
// taken as none, and a drop a target never ends ends as taken by none.
static void klioXdndTick() {
    KlioXdnd& d = klioXdnd();
    const auto now = std::chrono::steady_clock::now();
    if (d.in.kw && d.in.reading && now - d.in.since > std::chrono::seconds(2)) {
        d.in.want[0] = None;
        d.in.want[1] = None;
        d.in.reading = false;
        klioXdndInReady();
    }
    if (d.out.kw && d.out.dropped && now - d.out.droppedAt > std::chrono::seconds(10)) klioXdndEnd(0);
}

static void klioXdndAttach(KlioWindow* kw) {
    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(kw->win, &info) || info.subsystem != SDL_SYSWM_X11) return;
    if (!klioXdndReady()) return;
    KlioXdnd& d = klioXdnd();
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    kw->xwin = info.info.x11.window;
    d.sdlDpy = info.info.x11.display;
    KlioX11Trap trap(dpy);
    // The window's proxy: the drags over the window go to it, and it is the
    // source window of the drags the window starts. It names itself, and is
    // aware, as sources check.
    XSetWindowAttributes attrs{};
    attrs.override_redirect = True;
    kw->xproxy = x->CreateWindow(dpy, d.root, -100, -100, 1, 1, 0, 0, InputOnly, nullptr, CWOverrideRedirect, &attrs);
    const long version = 5;
    for (const Window w : {static_cast<Window>(kw->xwin), static_cast<Window>(kw->xproxy)}) {
        x->ChangeProperty(dpy, w, d.a.aware, XA_ATOM, 32, PropModeReplace, reinterpret_cast<const unsigned char*>(&version),
                          1);
        x->ChangeProperty(dpy, w, d.a.proxy, XA_WINDOW, 32, PropModeReplace,
                          reinterpret_cast<const unsigned char*>(&kw->xproxy), 1);
    }
}

static void klioXdndDetach(KlioWindow* kw) {
    KlioXdnd& d = klioXdnd();
    if (!d.ready) return;
    KlioX11Trap trap(klioX11Display());
    if (d.in.kw == kw) d.in = KlioXdndIn();
    if (d.out.kw == kw) {
        if (d.out.target && !d.out.dropped) {
            klioXdndSend(d.out.to, d.out.target, d.a.leave, static_cast<long>(kw->xproxy), 0, 0, 0, 0);
        }
        klioXdndEnd(0, false);
    }
    if (kw->xproxy) klioX11()->DestroyWindow(klioX11Display(), kw->xproxy);
    kw->xproxy = 0;
}

// Whether the windows' poll serves the shim's X connection as it waits.
static bool klioXdndWatching() { return klioXdnd().ready; }

// Waits up to ms for either connection, SDL's or the shim's, to have input,
// or for the loop's wake.
static void klioXdndWaitInput(int ms) {
    KlioXdnd& d = klioXdnd();
    KlioX11* x = klioX11();
    const int ours = x->ConnectionNumber_(klioX11Display());
    const int sdls = d.sdlDpy ? x->ConnectionNumber_(d.sdlDpy) : -1;
    const int wake = klioWakePipe[0];
    fd_set set;
    FD_ZERO(&set);
    FD_SET(ours, &set);
    if (sdls >= 0) FD_SET(sdls, &set);
    if (wake >= 0) FD_SET(wake, &set);
    timeval tv;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    select(std::max({ours, sdls, wake}) + 1, &set, nullptr, nullptr, &tv);
    if (wake >= 0 && FD_ISSET(wake, &set)) {
        char drain[64];
        while (read(wake, drain, sizeof drain) > 0) {
        }
    }
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

// An X event of the trays' windows.
static void klioTrayEvent(XEvent& ev) {
    KlioX11* x = klioX11();
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
static void klioTrayTick() {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
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

// Runs the X events of the shim's connection: the drags' and the trays'.
static void klioX11Pump() {
    KlioX11* x = klioX11();
    Display* dpy = klioX11Display();
    if (!x || !dpy) return;
    if (x->Pending(dpy)) {
        KlioX11Trap trap(dpy);
        while (x->Pending(dpy)) {
            XEvent ev;
            x->NextEvent(dpy, &ev);
            if (!klioXdndEvent(ev)) klioTrayEvent(ev);
        }
    }
    if (klioXdnd().in.kw || klioXdnd().out.kw) {
        KlioX11Trap trap(dpy);
        klioXdndTick();
    }
    klioTrayTick();
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
    klioX11Pump();
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
    timeoutMs = klioScriptWaitCap(timeoutMs);
    KlioX11* x = klioX11();
    Display* dpy = klioTrays().empty() ? nullptr : klioX11Display();
    if (!x || !dpy) {
        if (timeoutMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
        return;
    }
    if (x->Pending(dpy)) return;
    const int fd = x->ConnectionNumber_(dpy);
    const int wake = klioWakePipe[0];
    klioWakePosted().store(false);
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    if (wake >= 0) FD_SET(wake, &set);
    timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    select(std::max(fd, wake) + 1, &set, nullptr, nullptr, &tv);
    if (wake >= 0 && FD_ISSET(wake, &set)) {
        char drain[64];
        while (read(wake, drain, sizeof drain) > 0) {
        }
    }
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
    timeoutMs = klioScriptWaitCap(timeoutMs);
    if (timeoutMs > 0) std::this_thread::sleep_for(std::chrono::milliseconds(timeoutMs));
}
#endif  // KLIO_X11


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
    klioSdlA11yClose(kw);
#if defined(KLIO_X11)
    klioXdndDetach(kw);
#endif
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
#include <ole2.h>
#include <shellapi.h>
#include <shlobj.h>
#include <uiautomation.h>

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
    // The window's semantics for assistive technologies (klio_a11y_update),
    // their UI Automation providers by node id, and whether a client reads them.
    bool a11yActive = false;
    KlioA11yTree a11y;
    std::unordered_map<int, class KlioUiaNode*> uiaNodes;
    class KlioUiaRoot* uiaRoot = nullptr;
    int cursorKind = 0;         // the cursor over the client area (KLIO_CURSOR_*)
    // Drag and drop: the drag the window runs itself (scripted input), the
    // action the program takes of the drag over it, and the window's OLE
    // drop target.
    KlioDragSession drag;
    KlioDndAsk dndAsk;
    int dndAccepted = 0;
    class KlioDropTarget* dropTarget = nullptr;
};

static HCURSOR klioWinCursor(int kind) {
    switch (kind) {
        case KLIO_CURSOR_CROSSHAIR: return LoadCursor(nullptr, IDC_CROSS);
        case KLIO_CURSOR_TEXT: return LoadCursor(nullptr, IDC_IBEAM);
        case KLIO_CURSOR_HAND: return LoadCursor(nullptr, IDC_HAND);
        default: return LoadCursor(nullptr, IDC_ARROW);
    }
}

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

// ---------------------------------------------------------------------------
// Accessibility: the window's semantics as UI Automation providers, as
// Compose Desktop's ComposeSceneAccessible offers them through AWT's (the
// Java Access Bridge). The window answers WM_GETOBJECT with a fragment root
// whose fragments are the semantics nodes of the latest snapshot; a client
// reading it asks the program to send them. The providers live on the
// window's thread and are called there (ProviderOptions_UseComThreading).

class KlioUiaRoot;

// UI Automation's HeadingLevel1, which mingw's headers do not declare.
constexpr long kKlioUiaHeadingLevel1 = 80051;

static std::wstring klioWide(const std::string& s) {
    if (s.empty()) return std::wstring();
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &w[0], n);
    return w;
}

static std::string klioNarrow(const wchar_t* w) {
    if (!w || !*w) return std::string();
    const int len = static_cast<int>(wcslen(w));
    const int n = WideCharToMultiByte(CP_UTF8, 0, w, len, nullptr, 0, nullptr, nullptr);
    std::string s(static_cast<size_t>(n), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, len, &s[0], n, nullptr, nullptr);
    return s;
}

static void klioWinA11yActivate(KlioWindow* kw);
static IRawElementProviderFragment* klioWinUiaNode(KlioWindow* kw, int nodeId);
static KlioUiaRoot* klioWinUiaRoot(KlioWindow* kw);

// A node's rectangle in the client area, on the screen.
static UiaRect klioWinA11yScreenRect(KlioWindow* kw, const KlioA11yNode& n) {
    POINT origin = {0, 0};
    ClientToScreen(kw->hwnd, &origin);
    return UiaRect{origin.x + n.x, origin.y + n.y, n.w, n.h};
}

// One semantics node as UI Automation exposes it: its control type, name
// and state read from the window's latest snapshot, and the patterns its
// actions give it, each queued as KLIO_EV_A11Y for the program to run.
class KlioUiaNode final : public IRawElementProviderSimple,
                          public IRawElementProviderFragment,
                          public IInvokeProvider,
                          public IToggleProvider,
                          public IValueProvider,
                          public IRangeValueProvider,
                          public IExpandCollapseProvider {
  public:
    KlioUiaNode(KlioWindow* kw, int nodeId) : kw_(kw), nodeId_(nodeId) {}

    // The window closed or the node left the tree: the provider answers
    // UIA_E_ELEMENTNOTAVAILABLE from then on.
    void detach() { kw_ = nullptr; }
    int nodeId() const { return nodeId_; }

    const KlioA11yNode* node() const { return kw_ ? kw_->a11y.find(nodeId_) : nullptr; }

    // IUnknown
    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return static_cast<ULONG>(n);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *out = static_cast<IRawElementProviderSimple*>(this);
        } else if (riid == __uuidof(IRawElementProviderFragment)) {
            *out = static_cast<IRawElementProviderFragment*>(this);
        } else if (riid == __uuidof(IInvokeProvider)) {
            *out = static_cast<IInvokeProvider*>(this);
        } else if (riid == __uuidof(IToggleProvider)) {
            *out = static_cast<IToggleProvider*>(this);
        } else if (riid == __uuidof(IValueProvider)) {
            *out = static_cast<IValueProvider*>(this);
        } else if (riid == __uuidof(IRangeValueProvider)) {
            *out = static_cast<IRangeValueProvider*>(this);
        } else if (riid == __uuidof(IExpandCollapseProvider)) {
            *out = static_cast<IExpandCollapseProvider*>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }

    // IRawElementProviderSimple
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* out) override {
        if (!out) return E_POINTER;
        *out = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        bool has = false;
        switch (pattern) {
            case UIA_InvokePatternId:
                has = klioA11yOffers(n->actions, KLIO_A11Y_ACTION_CLICK) && !(n->states & KLIO_A11Y_STATE_CHECKABLE);
                break;
            case UIA_TogglePatternId: has = (n->states & KLIO_A11Y_STATE_CHECKABLE) != 0; break;
            case UIA_ValuePatternId:
                has = n->role == KLIO_A11Y_ROLE_TEXT_FIELD || n->role == KLIO_A11Y_ROLE_PASSWORD_FIELD;
                break;
            case UIA_RangeValuePatternId:
                has = n->role == KLIO_A11Y_ROLE_SLIDER || n->role == KLIO_A11Y_ROLE_PROGRESS;
                break;
            case UIA_ExpandCollapsePatternId:
                has = (n->states & (KLIO_A11Y_STATE_EXPANDED | KLIO_A11Y_STATE_COLLAPSED)) != 0;
                break;
            default: break;
        }
        if (!has) return S_OK;
        return QueryInterface(pattern == UIA_InvokePatternId ? __uuidof(IInvokeProvider)
                              : pattern == UIA_TogglePatternId ? __uuidof(IToggleProvider)
                              : pattern == UIA_ValuePatternId ? __uuidof(IValueProvider)
                              : pattern == UIA_RangeValuePatternId ? __uuidof(IRangeValueProvider)
                                                                   : __uuidof(IExpandCollapseProvider),
                              reinterpret_cast<void**>(out));
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT* out) override {
        if (!out) return E_POINTER;
        VariantInit(out);
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        switch (property) {
            case UIA_ControlTypePropertyId:
                out->vt = VT_I4;
                out->lVal = controlType(*n);
                break;
            case UIA_NamePropertyId:
                if (!n->name.empty()) {
                    out->vt = VT_BSTR;
                    out->bstrVal = SysAllocString(klioWide(n->name).c_str());
                }
                break;
            case UIA_HelpTextPropertyId:
                if (!n->description.empty() && n->description != n->name) {
                    out->vt = VT_BSTR;
                    out->bstrVal = SysAllocString(klioWide(n->description).c_str());
                }
                break;
            case UIA_AutomationIdPropertyId:
                out->vt = VT_BSTR;
                out->bstrVal = SysAllocString(std::to_wstring(n->id).c_str());
                break;
            case UIA_IsEnabledPropertyId:
                out->vt = VT_BOOL;
                out->boolVal = (n->states & KLIO_A11Y_STATE_ENABLED) ? VARIANT_TRUE : VARIANT_FALSE;
                break;
            case UIA_HasKeyboardFocusPropertyId:
                out->vt = VT_BOOL;
                out->boolVal = (n->states & KLIO_A11Y_STATE_FOCUSED) ? VARIANT_TRUE : VARIANT_FALSE;
                break;
            case UIA_IsKeyboardFocusablePropertyId:
                out->vt = VT_BOOL;
                out->boolVal = klioA11yOffers(n->actions, KLIO_A11Y_ACTION_FOCUS) ? VARIANT_TRUE : VARIANT_FALSE;
                break;
            case UIA_IsPasswordPropertyId:
                out->vt = VT_BOOL;
                out->boolVal = n->role == KLIO_A11Y_ROLE_PASSWORD_FIELD ? VARIANT_TRUE : VARIANT_FALSE;
                break;
            case UIA_HeadingLevelPropertyId:
                if (n->states & KLIO_A11Y_STATE_HEADING) {
                    out->vt = VT_I4;
                    out->lVal = kKlioUiaHeadingLevel1;
                }
                break;
            default: break;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return S_OK;
    }

    // IRawElementProviderFragment
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment** out) override;
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY** out) override {
        if (!out) return E_POINTER;
        int ids[2] = {UiaAppendRuntimeId, nodeId_};
        *out = SafeArrayCreateVector(VT_I4, 0, 2);
        if (!*out) return E_OUTOFMEMORY;
        for (LONG i = 0; i < 2; i++) SafeArrayPutElement(*out, &i, &ids[i]);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect* out) override {
        if (!out) return E_POINTER;
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = klioWinA11yScreenRect(kw_, *n);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override { return perform(KLIO_A11Y_ACTION_FOCUS); }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot** out) override;

    // IInvokeProvider
    HRESULT STDMETHODCALLTYPE Invoke() override { return perform(KLIO_A11Y_ACTION_CLICK); }

    // IToggleProvider
    HRESULT STDMETHODCALLTYPE Toggle() override { return perform(KLIO_A11Y_ACTION_CLICK); }
    HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState* out) override {
        if (!out) return E_POINTER;
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = (n->states & KLIO_A11Y_STATE_MIXED)     ? ToggleState_Indeterminate
               : (n->states & KLIO_A11Y_STATE_CHECKED) ? ToggleState_On
                                                       : ToggleState_Off;
        return S_OK;
    }

    // IValueProvider
    HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR value) override {
        return perform(KLIO_A11Y_ACTION_SET_TEXT, klioNarrow(value));
    }
    HRESULT STDMETHODCALLTYPE get_Value(BSTR* out) override {
        if (!out) return E_POINTER;
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = SysAllocString(klioWide(n->value).c_str());
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL* out) override {
        if (!out) return E_POINTER;
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        const bool range = n->role == KLIO_A11Y_ROLE_SLIDER || n->role == KLIO_A11Y_ROLE_PROGRESS;
        *out = !klioA11yOffers(n->actions, range ? KLIO_A11Y_ACTION_INCREMENT : KLIO_A11Y_ACTION_SET_TEXT);
        return S_OK;
    }

    // IRangeValueProvider: a value is reached a step at a time, as the
    // semantics offer (the increment and decrement actions).
    HRESULT STDMETHODCALLTYPE SetValue(double value) override {
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        if (value == n->current) return S_OK;
        return perform(value > n->current ? KLIO_A11Y_ACTION_INCREMENT : KLIO_A11Y_ACTION_DECREMENT);
    }
    HRESULT STDMETHODCALLTYPE get_Value(double* out) override { return rangeField(out, 0); }
    HRESULT STDMETHODCALLTYPE get_Maximum(double* out) override { return rangeField(out, 1); }
    HRESULT STDMETHODCALLTYPE get_Minimum(double* out) override { return rangeField(out, 2); }
    HRESULT STDMETHODCALLTYPE get_LargeChange(double* out) override { return rangeField(out, 3); }
    HRESULT STDMETHODCALLTYPE get_SmallChange(double* out) override { return rangeField(out, 3); }

    // IExpandCollapseProvider
    HRESULT STDMETHODCALLTYPE Expand() override { return perform(KLIO_A11Y_ACTION_EXPAND); }
    HRESULT STDMETHODCALLTYPE Collapse() override { return perform(KLIO_A11Y_ACTION_COLLAPSE); }
    HRESULT STDMETHODCALLTYPE get_ExpandCollapseState(ExpandCollapseState* out) override {
        if (!out) return E_POINTER;
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = (n->states & KLIO_A11Y_STATE_EXPANDED) ? ExpandCollapseState_Expanded : ExpandCollapseState_Collapsed;
        return S_OK;
    }

    static long controlType(const KlioA11yNode& n) {
        switch (n.role) {
            case KLIO_A11Y_ROLE_BUTTON: return UIA_ButtonControlTypeId;
            case KLIO_A11Y_ROLE_CHECKBOX:
            case KLIO_A11Y_ROLE_SWITCH: return UIA_CheckBoxControlTypeId;
            case KLIO_A11Y_ROLE_RADIO_BUTTON: return UIA_RadioButtonControlTypeId;
            case KLIO_A11Y_ROLE_TAB: return UIA_TabItemControlTypeId;
            case KLIO_A11Y_ROLE_DROPDOWN: return UIA_ComboBoxControlTypeId;
            case KLIO_A11Y_ROLE_IMAGE: return UIA_ImageControlTypeId;
            case KLIO_A11Y_ROLE_TEXT_FIELD:
            case KLIO_A11Y_ROLE_PASSWORD_FIELD: return UIA_EditControlTypeId;
            case KLIO_A11Y_ROLE_TEXT: return UIA_TextControlTypeId;
            case KLIO_A11Y_ROLE_SLIDER: return UIA_SliderControlTypeId;
            case KLIO_A11Y_ROLE_PROGRESS: return UIA_ProgressBarControlTypeId;
            case KLIO_A11Y_ROLE_SCROLL_AREA: return UIA_PaneControlTypeId;
            default: return UIA_GroupControlTypeId;
        }
    }

  private:
    HRESULT perform(int action, const std::string& text = std::string()) {
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!klioA11yOffers(n->actions, action)) return UIA_E_INVALIDOPERATION;
        kw_->events.push_back(klioA11yEv(nodeId_, action, text.c_str()));
        return S_OK;
    }

    HRESULT rangeField(double* out, int which) {
        if (!out) return E_POINTER;
        const KlioA11yNode* n = node();
        if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = which == 0 ? n->current : which == 1 ? n->max : which == 2 ? n->min : (n->max - n->min) / 10.0;
        return S_OK;
    }

    LONG refs_ = 1;
    KlioWindow* kw_;
    int nodeId_;
};

// The window as UI Automation's fragment root: the host window's provider
// underneath, the semantics roots as its children.
class KlioUiaRoot final : public IRawElementProviderSimple,
                          public IRawElementProviderFragment,
                          public IRawElementProviderFragmentRoot {
  public:
    explicit KlioUiaRoot(KlioWindow* kw) : kw_(kw) {}
    void detach() { kw_ = nullptr; }

    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return static_cast<ULONG>(n);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *out = static_cast<IRawElementProviderSimple*>(this);
        } else if (riid == __uuidof(IRawElementProviderFragment)) {
            *out = static_cast<IRawElementProviderFragment*>(this);
        } else if (riid == __uuidof(IRawElementProviderFragmentRoot)) {
            *out = static_cast<IRawElementProviderFragmentRoot*>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* out) override {
        if (!out) return E_POINTER;
        *out = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID, IUnknown** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID, VARIANT* out) override {
        if (!out) return E_POINTER;
        VariantInit(out);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!kw_) return UIA_E_ELEMENTNOTAVAILABLE;
        return UiaHostProviderFromHwnd(kw_->hwnd, out);
    }

    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!kw_ || kw_->a11y.roots.empty()) return S_OK;
        if (direction == NavigateDirection_FirstChild) *out = klioWinUiaNode(kw_, kw_->a11y.roots.front());
        else if (direction == NavigateDirection_LastChild) *out = klioWinUiaNode(kw_, kw_->a11y.roots.back());
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect* out) override {
        if (!out) return E_POINTER;
        *out = UiaRect{0, 0, 0, 0};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override { return S_OK; }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot** out) override {
        if (!out) return E_POINTER;
        *out = this;
        AddRef();
        return S_OK;
    }

    // IRawElementProviderFragmentRoot
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y, IRawElementProviderFragment** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!kw_) return S_OK;
        // The last node in document order under the point is the innermost.
        for (auto it = kw_->a11y.nodes.rbegin(); it != kw_->a11y.nodes.rend(); ++it) {
            const UiaRect r = klioWinA11yScreenRect(kw_, *it);
            if (x >= r.left && y >= r.top && x < r.left + r.width && y < r.top + r.height) {
                *out = klioWinUiaNode(kw_, it->id);
                return S_OK;
            }
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment** out) override {
        if (!out) return E_POINTER;
        *out = kw_ ? klioWinUiaNode(kw_, kw_->a11y.focused()) : nullptr;
        return S_OK;
    }

  private:
    LONG refs_ = 1;
    KlioWindow* kw_;
};

// The provider of a node of the latest snapshot, with a reference for the
// caller; null for none.
static IRawElementProviderFragment* klioWinUiaNode(KlioWindow* kw, int nodeId) {
    const auto it = kw->uiaNodes.find(nodeId);
    if (it == kw->uiaNodes.end()) return nullptr;
    it->second->AddRef();
    return static_cast<IRawElementProviderFragment*>(it->second);
}

static KlioUiaRoot* klioWinUiaRoot(KlioWindow* kw) {
    if (!kw->uiaRoot) kw->uiaRoot = new KlioUiaRoot(kw);
    return kw->uiaRoot;
}

HRESULT KlioUiaNode::Navigate(NavigateDirection direction, IRawElementProviderFragment** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    const KlioA11yNode* n = node();
    if (!n) return UIA_E_ELEMENTNOTAVAILABLE;
    switch (direction) {
        case NavigateDirection_Parent:
            if (n->parent >= 0 && kw_->a11y.find(n->parent)) {
                *out = klioWinUiaNode(kw_, n->parent);
            } else {
                KlioUiaRoot* root = klioWinUiaRoot(kw_);
                root->AddRef();
                *out = static_cast<IRawElementProviderFragment*>(root);
            }
            return S_OK;
        case NavigateDirection_FirstChild:
            if (!n->children.empty()) *out = klioWinUiaNode(kw_, n->children.front());
            return S_OK;
        case NavigateDirection_LastChild:
            if (!n->children.empty()) *out = klioWinUiaNode(kw_, n->children.back());
            return S_OK;
        case NavigateDirection_NextSibling:
        case NavigateDirection_PreviousSibling: {
            const KlioA11yNode* parent = n->parent >= 0 ? kw_->a11y.find(n->parent) : nullptr;
            const std::vector<int>& siblings = parent ? parent->children : kw_->a11y.roots;
            for (size_t i = 0; i < siblings.size(); i++) {
                if (siblings[i] != nodeId_) continue;
                if (direction == NavigateDirection_NextSibling && i + 1 < siblings.size()) {
                    *out = klioWinUiaNode(kw_, siblings[i + 1]);
                } else if (direction == NavigateDirection_PreviousSibling && i > 0) {
                    *out = klioWinUiaNode(kw_, siblings[i - 1]);
                }
                break;
            }
            return S_OK;
        }
        default:
            return S_OK;
    }
}

HRESULT KlioUiaNode::get_FragmentRoot(IRawElementProviderFragmentRoot** out) {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (!kw_) return UIA_E_ELEMENTNOTAVAILABLE;
    KlioUiaRoot* root = klioWinUiaRoot(kw_);
    root->AddRef();
    *out = static_cast<IRawElementProviderFragmentRoot*>(root);
    return S_OK;
}

static void klioWinA11yActivate(KlioWindow* kw) {
    if (kw->a11yActive) return;
    kw->a11yActive = true;
    kw->events.push_back(klioA11yEv(0, 0));
}

// The window's providers let go: the window is closing.
static void klioWinA11yRelease(KlioWindow* kw) {
    for (auto& entry : kw->uiaNodes) {
        entry.second->detach();
        entry.second->Release();
    }
    kw->uiaNodes.clear();
    if (kw->uiaRoot) {
        kw->uiaRoot->detach();
        UiaDisconnectProvider(static_cast<IRawElementProviderSimple*>(kw->uiaRoot));
        kw->uiaRoot->Release();
        kw->uiaRoot = nullptr;
    }
}

// A node's name as a client reads it through the provider.
static std::string klioWinUiaName(IRawElementProviderSimple* p) {
    VARIANT v;
    p->GetPropertyValue(UIA_NamePropertyId, &v);
    std::string name = v.vt == VT_BSTR ? klioNarrow(v.bstrVal) : std::string();
    VariantClear(&v);
    return name;
}

static int klioWinUiaRole(IRawElementProviderSimple* p) {
    VARIANT v;
    p->GetPropertyValue(UIA_ControlTypePropertyId, &v);
    const long type = v.vt == VT_I4 ? v.lVal : 0;
    VariantClear(&v);
    VARIANT pw;
    p->GetPropertyValue(UIA_IsPasswordPropertyId, &pw);
    const bool password = pw.vt == VT_BOOL && pw.boolVal == VARIANT_TRUE;
    switch (type) {
        case UIA_ButtonControlTypeId: return KLIO_A11Y_ROLE_BUTTON;
        case UIA_CheckBoxControlTypeId: return KLIO_A11Y_ROLE_CHECKBOX;
        case UIA_RadioButtonControlTypeId: return KLIO_A11Y_ROLE_RADIO_BUTTON;
        case UIA_TabItemControlTypeId: return KLIO_A11Y_ROLE_TAB;
        case UIA_ComboBoxControlTypeId: return KLIO_A11Y_ROLE_DROPDOWN;
        case UIA_ImageControlTypeId: return KLIO_A11Y_ROLE_IMAGE;
        case UIA_EditControlTypeId: return password ? KLIO_A11Y_ROLE_PASSWORD_FIELD : KLIO_A11Y_ROLE_TEXT_FIELD;
        case UIA_TextControlTypeId: return KLIO_A11Y_ROLE_TEXT;
        case UIA_SliderControlTypeId: return KLIO_A11Y_ROLE_SLIDER;
        case UIA_ProgressBarControlTypeId: return KLIO_A11Y_ROLE_PROGRESS;
        case UIA_PaneControlTypeId: return KLIO_A11Y_ROLE_SCROLL_AREA;
        default: return KLIO_A11Y_ROLE_GROUP;
    }
}

// The providers' children, through Navigate as UI Automation walks them.
static std::vector<IRawElementProviderFragment*> klioWinUiaChildren(IRawElementProviderFragment* f) {
    std::vector<IRawElementProviderFragment*> out;
    IRawElementProviderFragment* child = nullptr;
    f->Navigate(NavigateDirection_FirstChild, &child);
    while (child) {
        out.push_back(child);
        IRawElementProviderFragment* next = nullptr;
        child->Navigate(NavigateDirection_NextSibling, &next);
        child = next;
    }
    return out;
}

static void klioWinUiaDump(IRawElementProviderFragment* f, int depth) {
    IRawElementProviderSimple* p = nullptr;
    f->QueryInterface(__uuidof(IRawElementProviderSimple), reinterpret_cast<void**>(&p));
    const int role = klioWinUiaRole(p);
    std::string detail;
    IUnknown* pattern = nullptr;
    if (p->GetPatternProvider(UIA_TogglePatternId, &pattern) == S_OK && pattern) {
        ToggleState state = ToggleState_Off;
        static_cast<IToggleProvider*>(pattern)->get_ToggleState(&state);
        detail = state == ToggleState_Indeterminate ? "mixed" : state == ToggleState_On ? "checked" : "unchecked";
        pattern->Release();
    } else if (p->GetPatternProvider(UIA_ValuePatternId, &pattern) == S_OK && pattern) {
        BSTR value = nullptr;
        static_cast<IValueProvider*>(pattern)->get_Value(&value);
        detail = "value=\"" + klioNarrow(value) + "\"";
        SysFreeString(value);
        pattern->Release();
    } else if (p->GetPatternProvider(UIA_RangeValuePatternId, &pattern) == S_OK && pattern) {
        double value = 0;
        static_cast<IRangeValueProvider*>(pattern)->get_Value(&value);
        char buf[64];
        std::snprintf(buf, sizeof buf, "value=%g", value);
        detail = buf;
        pattern->Release();
    }
    VARIANT v;
    p->GetPropertyValue(UIA_HasKeyboardFocusPropertyId, &v);
    if (v.vt == VT_BOOL && v.boolVal == VARIANT_TRUE) detail += detail.empty() ? "focused" : " focused";
    p->GetPropertyValue(UIA_IsEnabledPropertyId, &v);
    if (v.vt == VT_BOOL && v.boolVal != VARIANT_TRUE) detail += detail.empty() ? "disabled" : " disabled";
    klioA11yDumpLine(depth, role, klioWinUiaName(p), detail);
    p->Release();
    for (IRawElementProviderFragment* child : klioWinUiaChildren(f)) {
        klioWinUiaDump(child, depth + 1);
        child->Release();
    }
}

static IRawElementProviderFragment* klioWinUiaFind(IRawElementProviderFragment* f, const std::string& name) {
    for (IRawElementProviderFragment* child : klioWinUiaChildren(f)) {
        IRawElementProviderSimple* p = nullptr;
        child->QueryInterface(__uuidof(IRawElementProviderSimple), reinterpret_cast<void**>(&p));
        const bool match = klioWinUiaName(p) == name;
        p->Release();
        if (match) return child;
        IRawElementProviderFragment* found = klioWinUiaFind(child, name);
        child->Release();
        if (found) return found;
    }
    return nullptr;
}

// Scripted input asking through the window's UI Automation providers, as a
// client asks.
static void klioWinA11yScript(KlioWindow* kw, int kind, const std::string& name, const std::string& text) {
    KlioUiaRoot* root = klioWinUiaRoot(kw);
    if (kind == KLIO_A11Y_SCRIPT_DUMP) {
        for (IRawElementProviderFragment* child : klioWinUiaChildren(root)) {
            klioWinUiaDump(child, 0);
            child->Release();
        }
        return;
    }
    IRawElementProviderFragment* f = klioWinUiaFind(root, name);
    if (!f) {
        std::fprintf(stderr, "klio: no accessible node is named `%s`\n", name.c_str());
        return;
    }
    KlioUiaNode* node = static_cast<KlioUiaNode*>(f);
    switch (kind) {
        case KLIO_A11Y_SCRIPT_PRESS: {
            ToggleState state;
            if (node->get_ToggleState(&state) == S_OK && (node->node()->states & KLIO_A11Y_STATE_CHECKABLE)) {
                node->Toggle();
            } else {
                node->Invoke();
            }
            break;
        }
        case KLIO_A11Y_SCRIPT_FOCUS: node->SetFocus(); break;
        case KLIO_A11Y_SCRIPT_VALUE: node->SetValue(klioWide(text).c_str()); break;
        case KLIO_A11Y_SCRIPT_INCREMENT: {
            double value = 0;
            node->get_Value(&value);
            node->SetValue(value + 1e-6);
            break;
        }
        default: break;
    }
    f->Release();
}

// Whether an assistive client reads the window.
static int klioWinA11yIsActive(KlioWindow* kw) { return kw && kw->a11yActive ? 1 : 0; }

static void klioWinUiaRaiseProperty(KlioUiaNode* node, PROPERTYID property, VARIANT before, VARIANT after) {
    UiaRaiseAutomationPropertyChangedEvent(static_cast<IRawElementProviderSimple*>(node), property, before, after);
    VariantClear(&before);
    VariantClear(&after);
}

static VARIANT klioWinBstr(const std::string& s) {
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_BSTR;
    v.bstrVal = SysAllocString(klioWide(s).c_str());
    return v;
}

static VARIANT klioWinI4(long n) {
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_I4;
    v.lVal = n;
    return v;
}

static VARIANT klioWinR8(double d) {
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_R8;
    v.dblVal = d;
    return v;
}

static long klioWinToggle(int states) {
    return (states & KLIO_A11Y_STATE_MIXED) ? ToggleState_Indeterminate
           : (states & KLIO_A11Y_STATE_CHECKED) ? ToggleState_On
                                                : ToggleState_Off;
}

// The window's semantics as the program sends them: providers keep their
// identity across snapshots, and listening clients hear what changed.
static void klioWinA11yUpdate(KlioWindow* kw, const char* text, size_t len) {
    KlioA11yTree next = klioParseA11y(text, len);
    const bool listening = UiaClientsAreListening() != FALSE;
    bool structure = next.nodes.size() != kw->a11y.nodes.size();
    std::vector<std::pair<KlioUiaNode*, KlioA11yNode>> changed;
    std::unordered_map<int, KlioUiaNode*> nodes;
    for (const KlioA11yNode& n : next.nodes) {
        const auto it = kw->uiaNodes.find(n.id);
        if (it != kw->uiaNodes.end()) {
            nodes[n.id] = it->second;
            kw->uiaNodes.erase(it);
            const KlioA11yNode* before = kw->a11y.find(n.id);
            if (before) {
                changed.push_back({nodes[n.id], *before});
                if (before->children != n.children) structure = true;
            }
        } else {
            nodes[n.id] = new KlioUiaNode(kw, n.id);
            structure = true;
        }
    }
    for (auto& gone : kw->uiaNodes) {
        gone.second->detach();
        gone.second->Release();
        structure = true;
    }
    kw->uiaNodes = std::move(nodes);
    const int focusedBefore = kw->a11y.focused();
    kw->a11y = std::move(next);
    if (!listening) return;
    for (auto& entry : changed) {
        KlioUiaNode* node = entry.first;
        const KlioA11yNode& before = entry.second;
        const KlioA11yNode* now = node->node();
        if (!now) continue;
        if (before.name != now->name) klioWinUiaRaiseProperty(node, UIA_NamePropertyId, klioWinBstr(before.name), klioWinBstr(now->name));
        if (before.value != now->value) klioWinUiaRaiseProperty(node, UIA_ValueValuePropertyId, klioWinBstr(before.value), klioWinBstr(now->value));
        if (klioWinToggle(before.states) != klioWinToggle(now->states)) {
            klioWinUiaRaiseProperty(node, UIA_ToggleToggleStatePropertyId, klioWinI4(klioWinToggle(before.states)),
                                    klioWinI4(klioWinToggle(now->states)));
        }
        if (before.current != now->current) {
            klioWinUiaRaiseProperty(node, UIA_RangeValueValuePropertyId, klioWinR8(before.current), klioWinR8(now->current));
        }
    }
    if (structure) {
        UiaRaiseStructureChangedEvent(static_cast<IRawElementProviderSimple*>(klioWinUiaRoot(kw)),
                                      StructureChangeType_ChildrenInvalidated, nullptr, 0);
    }
    const int focused = kw->a11y.focused();
    if (focused != focusedBefore && focused >= 0) {
        const auto it = kw->uiaNodes.find(focused);
        if (it != kw->uiaNodes.end()) {
            UiaRaiseAutomationEvent(static_cast<IRawElementProviderSimple*>(it->second), UIA_AutomationFocusChangedEventId);
        }
    }
}

// ---------------------------------------------------------------------------
// Drag and drop through OLE, as AWT's is on Windows: the window is a drop
// target whose events carry the dragged files and text to the program, and
// a drag the program starts runs DoDragDrop with them.

static int klioWinDndActions(DWORD effects) {
    int a = 0;
    if (effects & DROPEFFECT_COPY) a |= KLIO_DND_ACTION_COPY;
    if (effects & DROPEFFECT_MOVE) a |= KLIO_DND_ACTION_MOVE;
    if (effects & DROPEFFECT_LINK) a |= KLIO_DND_ACTION_LINK;
    return a;
}

static DWORD klioWinDropEffect(int action) {
    switch (action) {
        case KLIO_DND_ACTION_COPY: return DROPEFFECT_COPY;
        case KLIO_DND_ACTION_MOVE: return DROPEFFECT_MOVE;
        case KLIO_DND_ACTION_LINK: return DROPEFFECT_LINK;
        default: return DROPEFFECT_NONE;
    }
}

// The files and text a data object offers, as a drag payload.
static std::string klioWinDndPayload(IDataObject* data) {
    std::vector<std::string> files;
    FORMATETC drop = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    STGMEDIUM medium = {};
    if (data->GetData(&drop, &medium) == S_OK) {
        HDROP hdrop = static_cast<HDROP>(GlobalLock(medium.hGlobal));
        if (hdrop) {
            const UINT n = DragQueryFileW(hdrop, 0xFFFFFFFF, nullptr, 0);
            for (UINT i = 0; i < n; i++) {
                const UINT len = DragQueryFileW(hdrop, i, nullptr, 0);
                std::wstring path(len + 1, L'\0');
                DragQueryFileW(hdrop, i, &path[0], len + 1);
                path.resize(len);
                files.push_back(klioNarrow(path.c_str()));
            }
            GlobalUnlock(medium.hGlobal);
        }
        ReleaseStgMedium(&medium);
    }
    std::string text;
    bool hasText = false;
    FORMATETC unicode = {CF_UNICODETEXT, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
    if (data->GetData(&unicode, &medium) == S_OK) {
        const wchar_t* w = static_cast<const wchar_t*>(GlobalLock(medium.hGlobal));
        if (w) {
            text = klioNarrow(w);
            hasText = true;
            GlobalUnlock(medium.hGlobal);
        }
        ReleaseStgMedium(&medium);
    }
    return klioDndPayload(files, hasText ? &text : nullptr);
}

// Whether the program is running a drag of its own: OLE's DoDragDrop holds
// the program's thread until it drops.
static bool klioWinDragging = false;

// The window as OLE's drop target: a drag over it is queued for the program,
// and OLE hears the program's latest answer. While the program drags itself
// it cannot answer until the drop, so its own windows take the drag's
// default action and the program hears the drag once DoDragDrop returns.
class KlioDropTarget final : public IDropTarget {
  public:
    explicit KlioDropTarget(KlioWindow* kw) : kw_(kw) {}
    void detach() { kw_ = nullptr; }

    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return static_cast<ULONG>(n);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDropTarget)) {
            *out = static_cast<IDropTarget*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD, POINTL pt, DWORD* effect) override {
        if (!kw_) return E_UNEXPECTED;
        payload_ = klioWinDndPayload(data);
        offered_ = klioWinDndActions(*effect);
        kw_->dndAccepted = 0;
        queue(KLIO_DND_ENTER, pt);
        *effect = answer(*effect);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragOver(DWORD, POINTL pt, DWORD* effect) override {
        if (!kw_) return E_UNEXPECTED;
        if (pt.x != last_.x || pt.y != last_.y) queue(KLIO_DND_OVER, pt);
        *effect = answer(*effect);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DragLeave() override {
        if (kw_) kw_->events.push_back(klioDndEv(KLIO_DND_EXIT, 0, 0, 0));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD, POINTL pt, DWORD* effect) override {
        if (!kw_) return E_UNEXPECTED;
        payload_ = klioWinDndPayload(data);
        queue(KLIO_DND_DROP, pt);
        *effect = answer(*effect);
        return S_OK;
    }

  private:
    DWORD answer(DWORD offered) const {
        if (klioWinDragging) return klioWinDropEffect(klioDndDefaultAction(klioWinDndActions(offered)));
        return klioWinDropEffect(kw_->dndAccepted);
    }

    void queue(int kind, POINTL pt) {
        last_ = pt;
        POINT client = {pt.x, pt.y};
        ScreenToClient(kw_->hwnd, &client);
        kw_->events.push_back(klioDndEv(kind, client.x, client.y, offered_, payload_));
    }

    LONG refs_ = 1;
    KlioWindow* kw_;
    std::string payload_;
    int offered_ = 0;
    POINTL last_ = {-1, -1};
};

// The data a drag the window starts offers: its files (CF_HDROP) and text
// (CF_UNICODETEXT).
class KlioDataObject final : public IDataObject {
  public:
    KlioDataObject(std::vector<std::string> files, bool hasText, std::string text)
        : files_(std::move(files)), hasText_(hasText), text_(std::move(text)) {}

    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return static_cast<ULONG>(n);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDataObject)) {
            *out = static_cast<IDataObject*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format, STGMEDIUM* medium) override {
        if (!format || !medium) return E_INVALIDARG;
        if (QueryGetData(format) != S_OK) return DV_E_FORMATETC;
        HGLOBAL global = nullptr;
        if (format->cfFormat == CF_UNICODETEXT) {
            const std::wstring w = klioWide(text_);
            global = GlobalAlloc(GMEM_MOVEABLE, (w.size() + 1) * sizeof(wchar_t));
            if (!global) return E_OUTOFMEMORY;
            std::memcpy(GlobalLock(global), w.c_str(), (w.size() + 1) * sizeof(wchar_t));
            GlobalUnlock(global);
        } else {
            // DROPFILES and the paths, each NUL-terminated, ending in an empty one.
            std::wstring paths;
            for (const std::string& f : files_) {
                paths += klioWide(f);
                paths += L'\0';
            }
            paths += L'\0';
            global = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, sizeof(DROPFILES) + paths.size() * sizeof(wchar_t));
            if (!global) return E_OUTOFMEMORY;
            auto* drop = static_cast<DROPFILES*>(GlobalLock(global));
            drop->pFiles = sizeof(DROPFILES);
            drop->fWide = TRUE;
            std::memcpy(reinterpret_cast<char*>(drop) + sizeof(DROPFILES), paths.data(), paths.size() * sizeof(wchar_t));
            GlobalUnlock(global);
        }
        medium->tymed = TYMED_HGLOBAL;
        medium->hGlobal = global;
        medium->pUnkForRelease = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override {
        if (!format || !(format->tymed & TYMED_HGLOBAL) || format->dwAspect != DVASPECT_CONTENT) return DV_E_FORMATETC;
        if (format->cfFormat == CF_UNICODETEXT && hasText_) return S_OK;
        if (format->cfFormat == CF_HDROP && !files_.empty()) return S_OK;
        return DV_E_FORMATETC;
    }
    HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC* out) override {
        if (out) out->ptd = nullptr;
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD direction, IEnumFORMATETC** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (direction != DATADIR_GET) return E_NOTIMPL;
        FORMATETC formats[2];
        UINT n = 0;
        if (!files_.empty()) formats[n++] = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        if (hasText_) formats[n++] = {CF_UNICODETEXT, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
        return SHCreateStdEnumFmtEtc(n, formats, out);
    }
    HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }

  private:
    LONG refs_ = 1;
    std::vector<std::string> files_;
    bool hasText_;
    std::string text_;
};

// The drag the window starts: it drops when the primary button is released
// and is cancelled by Escape, with the platform's cursors.
class KlioDropSource final : public IDropSource {
  public:
    ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(InterlockedIncrement(&refs_)); }
    ULONG STDMETHODCALLTYPE Release() override {
        const LONG n = InterlockedDecrement(&refs_);
        if (n == 0) delete this;
        return static_cast<ULONG>(n);
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IDropSource)) {
            *out = static_cast<IDropSource*>(this);
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE QueryContinueDrag(BOOL escape, DWORD keys) override {
        if (escape) return DRAGDROP_S_CANCEL;
        if (!(keys & MK_LBUTTON)) return DRAGDROP_S_DROP;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GiveFeedback(DWORD) override { return DRAGDROP_S_USEDEFAULTCURSORS; }

  private:
    LONG refs_ = 1;
};

static LRESULT CALLBACK klioWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* kw = reinterpret_cast<KlioWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    if (kw) klioWinTranslate(kw, msg, wParam, lParam);
    if (kw && klioWinIme(kw, msg, lParam)) return 0;
    // The client area shows the cursor its content asks for.
    if (kw && msg == WM_SETCURSOR && LOWORD(lParam) == HTCLIENT) {
        SetCursor(klioWinCursor(kw->cursorKind));
        return TRUE;
    }
    // An assistive client asks for the window's UI Automation root.
    if (kw && msg == WM_GETOBJECT && static_cast<long>(lParam) == static_cast<long>(UiaRootObjectId)) {
        klioWinA11yActivate(kw);
        return UiaReturnRawElementProvider(hwnd, wParam, lParam,
                                           static_cast<IRawElementProviderSimple*>(klioWinUiaRoot(kw)));
    }
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

// The thread the windows run on, which a wake posts to.
static DWORD klioWinUiThread = 0;

KlioWindow* klio_win_open(int w, int h, const char* title) {
    if (w <= 0 || h <= 0) return nullptr;
    klioWinUiThread = GetCurrentThreadId();
    // UI Automation calls the window's providers through its COM apartment,
    // and OLE's drag and drop needs the thread's OLE.
    OleInitialize(nullptr);
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
    kw->a11yActive = klioA11yForced();
    kw->dropTarget = new KlioDropTarget(kw);
    RegisterDragDrop(hwnd, kw->dropTarget);
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
    if (kw->dndAsk.kind) klioDndAnswer(kw, 0);
    klioScriptTick(kw->script, kw->events);
    if (!kw->frameReport.reported) klioWinReportFrame(kw);
    if (!kw->events.empty()) return klioWinPop(kw, out);
    klioWakePosted().store(false);
    MSG msg;
    if (!PeekMessage(&msg, nullptr, 0, 0, PM_NOREMOVE)) {
        MsgWaitForMultipleObjects(0, nullptr, FALSE, static_cast<DWORD>(klioScriptWaitCap(timeoutMs)), QS_ALLINPUT);
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
        if (type == KLIO_EV_POINTER && kw->drag.active) {
            KlioEv e;
            e.type = type;
            for (int i = 0; i < KLIO_EV_VALUES; i++) e.v[i] = out[i];
            if (kw->drag.pointer(kw->events, e)) continue;
        }
        if (type == KLIO_EV_CURSOR_SCRIPT) {
            klioPrintCursor(kw->cursorKind);
            continue;
        }
        if (type == KLIO_EV_A11Y_SCRIPT) {
            const size_t at = static_cast<size_t>(out[1]);
            const size_t textAt = static_cast<size_t>(out[2]);
            if (textAt < klioScriptTexts().size()) {
                klioWinA11yScript(kw, static_cast<int>(out[0]), klioScriptTexts()[at], klioScriptTexts()[textAt]);
            }
            continue;
        }
        if (type != KLIO_EV_MENU_PATH) {
            kw->dndAsk.reported(type, out);
            return type;
        }
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
    timeoutMs = klioScriptWaitCap(timeoutMs);
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

int klio_a11y_active(KlioWindow* kw) { return klioWinA11yIsActive(kw); }

// The program's answer to the drag event it handled: the action it takes
// (0 for none). OLE asks for the latest answer itself.
void klio_win_dnd_accept(KlioWindow* kw, int action) {
    if (kw) klioDndAnswer(kw, action);
}

// Starts a drag of the payload from the window: OLE's DoDragDrop, which
// returns when it drops or is cancelled, or, from a scripted press, a drag
// the window runs itself. The decoration is not shown: OLE's cursors are.
int klio_win_drag_start(KlioWindow* kw, const char* payload, size_t len, const unsigned char*, size_t, int, int,
                        int actions) {
    if (!kw || !payload) return 0;
    const std::string data(payload, len);
    if (!(kw->buttons & (1 << (KLIO_BTN_PRIMARY - 1)))) {
        kw->drag.start(actions, data);
        return 1;
    }
    std::vector<std::string> files;
    std::string text;
    bool hasText = false;
    klioDndParse(data, files, text, hasText);
    if (files.empty() && !hasText) return 0;
    auto* object = new KlioDataObject(std::move(files), hasText, std::move(text));
    auto* source = new KlioDropSource();
    DWORD allowed = 0;
    if (actions & KLIO_DND_ACTION_COPY) allowed |= DROPEFFECT_COPY;
    if (actions & KLIO_DND_ACTION_MOVE) allowed |= DROPEFFECT_MOVE;
    if (actions & KLIO_DND_ACTION_LINK) allowed |= DROPEFFECT_LINK;
    DWORD effect = DROPEFFECT_NONE;
    klioWinDragging = true;
    const HRESULT hr = DoDragDrop(object, source, allowed, &effect);
    klioWinDragging = false;
    object->Release();
    source->Release();
    kw->events.push_back(klioDndEv(KLIO_DND_SOURCE_ENDED, 0, 0, hr == DRAGDROP_S_DROP ? klioWinDndActions(effect) : 0));
    // The drag took the release, as it does from AWT's view: the content sees
    // the button up from its next event.
    kw->buttons &= ~(1 << (KLIO_BTN_PRIMARY - 1));
    return 1;
}

// The cursor over the window's client area: WM_SETCURSOR's from now on, and
// at once while the pointer is over it.
// Wakes the window loop from any thread: a message posted to its thread ends
// its wait.
void klio_app_wake(void) {
    if (!klioWinUiThread || klioWakePosted().exchange(true)) return;
    PostThreadMessageW(klioWinUiThread, WM_APP + 0x2F, 0, 0);
}

// The refresh rate of the monitor the window is on, in frames a second.
int klio_win_refresh_hz(KlioWindow* kw) {
    if (!kw || !kw->hwnd) return 0;
    MONITORINFOEXW info = {};
    info.cbSize = sizeof(info);
    if (!GetMonitorInfoW(MonitorFromWindow(kw->hwnd, MONITOR_DEFAULTTONEAREST), &info)) return 0;
    DEVMODEW mode = {};
    mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsW(info.szDevice, ENUM_CURRENT_SETTINGS, &mode)) return 0;
    // 0 and 1 mean the hardware's default rate.
    return mode.dmDisplayFrequency > 1 ? static_cast<int>(mode.dmDisplayFrequency) : 0;
}

void klio_win_set_cursor(KlioWindow* kw, int kind) {
    if (!kw || kw->cursorKind == kind) return;
    kw->cursorKind = kind;
    if (kw->pointerInside) SetCursor(klioWinCursor(kind));
}

void klio_a11y_update(KlioWindow* kw, const char* text, size_t len) {
    if (!kw || !text) return;
    klioWinA11yUpdate(kw, text, len);
}

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
    UiaReturnRawElementProvider(kw->hwnd, 0, 0, nullptr);
    klioWinA11yRelease(kw);
    if (kw->dropTarget) {
        RevokeDragDrop(kw->hwnd);
        kw->dropTarget->detach();
        kw->dropTarget->Release();
        kw->dropTarget = nullptr;
    }
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
#include <cstdarg>
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
    // The window's semantics for assistive technologies (klio_a11y_update),
    // their elements by node id, and whether a client reads them.
    bool a11yActive;
    KlioA11yTree a11y;
    NSMutableDictionary* a11yElements;
    NSCursor* cursor;   // the cursor over the content (retained), nil for the arrow
    // Drag and drop: the drag the window runs itself (scripted input), the
    // action the program takes of the drag over it, where that drag last
    // was, the actions the window's own platform drag offers, and the last
    // mouse press or drag (retained), which a platform drag starts from.
    KlioDragSession drag;
    KlioDndAsk dndAsk;
    int dndAccepted;
    NSPoint dndAt;
    int dragActions;
    NSEvent* lastMouseEvent;
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

// An assistive client started reading the window: the program sends its
// semantics from the next frame on.
static void klioCocoaA11yActivate(KlioWindow* kw) {
    if (kw->a11yActive) return;
    kw->a11yActive = true;
    kw->events.push_back(klioA11yEv(0, 0));
}

static NSString* klioNSString(const std::string& s) {
    NSString* str = [[[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] autorelease];
    return str ?: @"";
}

// A semantics node as NSAccessibility exposes it, as Compose Desktop's
// ComposeAccessible exposes one through AWT: its role, name and value read
// from the window's latest snapshot, and the actions a client performs
// queued as KLIO_EV_A11Y for the program to run.
@interface KlioA11yElement : NSAccessibilityElement
@property(nonatomic, assign) KlioWindow* kw;
@property(nonatomic, assign) int nodeId;
@end

static id klioCocoaA11yElementFor(KlioWindow* kw, int nodeId) {
    return kw && kw->a11yElements ? [kw->a11yElements objectForKey:@(nodeId)] : nil;
}

static NSArray* klioCocoaA11yElements(KlioWindow* kw, const std::vector<int>& ids) {
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:ids.size()];
    for (int nodeId : ids) {
        id e = klioCocoaA11yElementFor(kw, nodeId);
        if (e) [out addObject:e];
    }
    return out;
}

// A node's rectangle in the window's content, on the screen.
static NSRect klioCocoaA11yScreenRect(KlioWindow* kw, const KlioA11yNode& n) {
    const NSRect inView = NSMakeRect(n.x, kw->h - n.y - n.h, n.w, n.h);
    return [kw->window convertRectToScreen:[kw->view convertRect:inView toView:nil]];
}

@implementation KlioA11yElement
- (const KlioA11yNode*)node {
    return _kw ? _kw->a11y.find(_nodeId) : nullptr;
}
- (void)perform:(int)action text:(const char*)text {
    if (_kw) _kw->events.push_back(klioA11yEv(_nodeId, action, text));
}
- (BOOL)offers:(int)action {
    const KlioA11yNode* n = [self node];
    return n && klioA11yOffers(n->actions, action);
}
- (BOOL)isAccessibilityElement {
    return YES;
}
- (NSAccessibilityRole)accessibilityRole {
    const KlioA11yNode* n = [self node];
    switch (n ? n->role : KLIO_A11Y_ROLE_UNKNOWN) {
        case KLIO_A11Y_ROLE_BUTTON: return NSAccessibilityButtonRole;
        case KLIO_A11Y_ROLE_CHECKBOX:
        case KLIO_A11Y_ROLE_SWITCH: return NSAccessibilityCheckBoxRole;
        case KLIO_A11Y_ROLE_RADIO_BUTTON:
        case KLIO_A11Y_ROLE_TAB: return NSAccessibilityRadioButtonRole;
        case KLIO_A11Y_ROLE_DROPDOWN: return NSAccessibilityPopUpButtonRole;
        case KLIO_A11Y_ROLE_IMAGE: return NSAccessibilityImageRole;
        case KLIO_A11Y_ROLE_TEXT_FIELD:
        case KLIO_A11Y_ROLE_PASSWORD_FIELD: return NSAccessibilityTextFieldRole;
        case KLIO_A11Y_ROLE_TEXT: return NSAccessibilityStaticTextRole;
        case KLIO_A11Y_ROLE_SLIDER: return NSAccessibilitySliderRole;
        case KLIO_A11Y_ROLE_PROGRESS: return NSAccessibilityProgressIndicatorRole;
        case KLIO_A11Y_ROLE_SCROLL_AREA: return NSAccessibilityScrollAreaRole;
        default: return NSAccessibilityGroupRole;
    }
}
- (NSAccessibilitySubrole)accessibilitySubrole {
    const KlioA11yNode* n = [self node];
    switch (n ? n->role : KLIO_A11Y_ROLE_UNKNOWN) {
        case KLIO_A11Y_ROLE_SWITCH: return NSAccessibilitySwitchSubrole;
        case KLIO_A11Y_ROLE_TAB: return NSAccessibilityTabButtonSubrole;
        case KLIO_A11Y_ROLE_PASSWORD_FIELD: return NSAccessibilitySecureTextFieldSubrole;
        default: return nil;
    }
}
- (NSString*)accessibilityLabel {
    const KlioA11yNode* n = [self node];
    // Static text is read by its value.
    if (!n || n->role == KLIO_A11Y_ROLE_TEXT || n->name.empty()) return nil;
    return klioNSString(n->name);
}
- (id)accessibilityValue {
    const KlioA11yNode* n = [self node];
    if (!n) return nil;
    switch (n->role) {
        case KLIO_A11Y_ROLE_TEXT: return klioNSString(n->name);
        case KLIO_A11Y_ROLE_TEXT_FIELD:
        case KLIO_A11Y_ROLE_PASSWORD_FIELD: return klioNSString(n->value);
        case KLIO_A11Y_ROLE_SLIDER:
        case KLIO_A11Y_ROLE_PROGRESS: return @(n->current);
        default: break;
    }
    if (n->states & KLIO_A11Y_STATE_CHECKABLE) {
        return @((n->states & KLIO_A11Y_STATE_MIXED) ? 2 : (n->states & KLIO_A11Y_STATE_CHECKED) ? 1 : 0);
    }
    return n->value.empty() ? nil : klioNSString(n->value);
}
- (id)accessibilityMinValue {
    const KlioA11yNode* n = [self node];
    return n ? @(n->min) : nil;
}
- (id)accessibilityMaxValue {
    const KlioA11yNode* n = [self node];
    return n ? @(n->max) : nil;
}
- (NSString*)accessibilityHelp {
    const KlioA11yNode* n = [self node];
    return n && !n->description.empty() && n->description != n->name ? klioNSString(n->description) : nil;
}
- (NSRect)accessibilityFrame {
    const KlioA11yNode* n = [self node];
    return n ? klioCocoaA11yScreenRect(_kw, *n) : NSZeroRect;
}
- (id)accessibilityParent {
    const KlioA11yNode* n = [self node];
    if (!n) return nil;
    id parent = n->parent >= 0 ? klioCocoaA11yElementFor(_kw, n->parent) : nil;
    return parent ? parent : _kw->view;
}
- (NSArray*)accessibilityChildren {
    const KlioA11yNode* n = [self node];
    return n ? klioCocoaA11yElements(_kw, n->children) : @[];
}
- (BOOL)isAccessibilityEnabled {
    const KlioA11yNode* n = [self node];
    return n && (n->states & KLIO_A11Y_STATE_ENABLED);
}
- (BOOL)isAccessibilityFocused {
    const KlioA11yNode* n = [self node];
    return n && (n->states & KLIO_A11Y_STATE_FOCUSED);
}
- (BOOL)isAccessibilitySelected {
    const KlioA11yNode* n = [self node];
    return n && (n->states & KLIO_A11Y_STATE_SELECTED);
}
- (BOOL)isAccessibilityExpanded {
    const KlioA11yNode* n = [self node];
    return n && (n->states & KLIO_A11Y_STATE_EXPANDED);
}
- (BOOL)accessibilityPerformPress {
    if (![self offers:KLIO_A11Y_ACTION_CLICK]) return NO;
    [self perform:KLIO_A11Y_ACTION_CLICK text:""];
    return YES;
}
- (BOOL)accessibilityPerformIncrement {
    if (![self offers:KLIO_A11Y_ACTION_INCREMENT]) return NO;
    [self perform:KLIO_A11Y_ACTION_INCREMENT text:""];
    return YES;
}
- (BOOL)accessibilityPerformDecrement {
    if (![self offers:KLIO_A11Y_ACTION_DECREMENT]) return NO;
    [self perform:KLIO_A11Y_ACTION_DECREMENT text:""];
    return YES;
}
- (BOOL)accessibilityPerformCancel {
    if (![self offers:KLIO_A11Y_ACTION_DISMISS]) return NO;
    [self perform:KLIO_A11Y_ACTION_DISMISS text:""];
    return YES;
}
- (BOOL)accessibilityPerformShowMenu {
    if (![self offers:KLIO_A11Y_ACTION_LONG_CLICK]) return NO;
    [self perform:KLIO_A11Y_ACTION_LONG_CLICK text:""];
    return YES;
}
- (void)setAccessibilityFocused:(BOOL)focused {
    if (focused && [self offers:KLIO_A11Y_ACTION_FOCUS]) [self perform:KLIO_A11Y_ACTION_FOCUS text:""];
}
- (void)setAccessibilityValue:(id)value {
    if (![self offers:KLIO_A11Y_ACTION_SET_TEXT] || ![value isKindOfClass:[NSString class]]) return;
    [self perform:KLIO_A11Y_ACTION_SET_TEXT text:[(NSString*)value UTF8String]];
}
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector == @selector(accessibilityPerformPress)) return [self offers:KLIO_A11Y_ACTION_CLICK];
    if (selector == @selector(accessibilityPerformIncrement)) return [self offers:KLIO_A11Y_ACTION_INCREMENT];
    if (selector == @selector(accessibilityPerformDecrement)) return [self offers:KLIO_A11Y_ACTION_DECREMENT];
    if (selector == @selector(accessibilityPerformCancel)) return [self offers:KLIO_A11Y_ACTION_DISMISS];
    if (selector == @selector(accessibilityPerformShowMenu)) return [self offers:KLIO_A11Y_ACTION_LONG_CLICK];
    if (selector == @selector(setAccessibilityFocused:)) return [self offers:KLIO_A11Y_ACTION_FOCUS];
    if (selector == @selector(setAccessibilityValue:)) return [self offers:KLIO_A11Y_ACTION_SET_TEXT];
    return [super isAccessibilitySelectorAllowed:selector];
}
@end

// The window's content view, the input method's client as AWT's view is.
// While a text field has the keyboard a key press goes to the input method
// first: what it composes and commits is queued as KLIO_EV_IME, and a press
// it passes on reaches the program as the key and the character it typed.
static NSDragOperation klioCocoaDragOperation(int action) {
    switch (action) {
        case KLIO_DND_ACTION_COPY: return NSDragOperationCopy;
        case KLIO_DND_ACTION_MOVE: return NSDragOperationMove;
        case KLIO_DND_ACTION_LINK: return NSDragOperationLink;
        default: return NSDragOperationNone;
    }
}

@interface KlioContentView : NSView <NSTextInputClient, NSDraggingSource>
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
// A drag over the content: its position, the actions it offers and the
// data it carries, queued for the program, which decides whether the window
// takes it; AppKit hears the program's latest answer.
- (NSDragOperation)klioDrag:(id<NSDraggingInfo>)info kind:(int)kind {
    KlioWindow* kw = _kw;
    if (!kw) return NSDragOperationNone;
    const NSPoint p = [self convertPoint:[info draggingLocation] fromView:nil];
    const NSPoint at = NSMakePoint(static_cast<int>(p.x), static_cast<int>(kw->h - p.y));
    if (kind == KLIO_DND_OVER && NSEqualPoints(at, kw->dndAt)) return klioCocoaDragOperation(kw->dndAccepted);
    kw->dndAt = at;
    const NSDragOperation offered = [info draggingSourceOperationMask];
    int actions = 0;
    if (offered & NSDragOperationCopy) actions |= KLIO_DND_ACTION_COPY;
    if (offered & NSDragOperationMove) actions |= KLIO_DND_ACTION_MOVE;
    if (offered & NSDragOperationLink) actions |= KLIO_DND_ACTION_LINK;
    NSPasteboard* pb = [info draggingPasteboard];
    std::vector<std::string> files;
    for (NSURL* url in [pb readObjectsForClasses:@[ [NSURL class] ]
                                          options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}]) {
        if ([url path]) files.push_back([[url path] UTF8String]);
    }
    NSString* text = [pb stringForType:NSPasteboardTypeString];
    const std::string str = text ? [text UTF8String] : "";
    if (kind == KLIO_DND_ENTER) kw->dndAccepted = 0;
    kw->events.push_back(klioDndEv(kind, at.x, at.y, actions, klioDndPayload(files, text ? &str : nullptr)));
    return klioCocoaDragOperation(kw->dndAccepted);
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    return [self klioDrag:info kind:KLIO_DND_ENTER];
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info {
    return [self klioDrag:info kind:KLIO_DND_OVER];
}
- (void)draggingExited:(id<NSDraggingInfo>)info {
    (void)info;
    if (_kw) _kw->events.push_back(klioDndEv(KLIO_DND_EXIT, 0, 0, 0));
}
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    if (!_kw || _kw->dndAccepted == 0) return NO;
    [self klioDrag:info kind:KLIO_DND_DROP];
    return YES;
}
// The window's own platform drag: the actions it offers, and its end.
- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
    (void)session;
    (void)context;
    const int a = _kw ? _kw->dragActions : 0;
    NSDragOperation mask = NSDragOperationNone;
    if (a & KLIO_DND_ACTION_COPY) mask |= NSDragOperationCopy;
    if (a & KLIO_DND_ACTION_MOVE) mask |= NSDragOperationMove;
    if (a & KLIO_DND_ACTION_LINK) mask |= NSDragOperationLink;
    return mask;
}
- (void)draggingSession:(NSDraggingSession*)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
    (void)session;
    (void)point;
    if (!_kw) return;
    int taken = 0;
    if (operation & NSDragOperationCopy) taken = KLIO_DND_ACTION_COPY;
    else if (operation & NSDragOperationMove) taken = KLIO_DND_ACTION_MOVE;
    else if (operation & NSDragOperationLink) taken = KLIO_DND_ACTION_LINK;
    _kw->events.push_back(klioDndEv(KLIO_DND_SOURCE_ENDED, 0, 0, taken));
    // The session took the release, as it does from AWT's view: the content
    // sees the button up from its next event.
    _kw->buttons &= ~(1 << (KLIO_BTN_PRIMARY - 1));
}
// The cursor the content asks for, over the whole content.
- (void)resetCursorRects {
    KlioWindow* kw = _kw;
    [self addCursorRect:[self visibleRect] cursor:(kw && kw->cursor ? kw->cursor : [NSCursor arrowCursor])];
}
// The window's semantics, exposed to assistive clients: a client reading
// them asks the program to send them.
- (NSArray*)accessibilityChildren {
    KlioWindow* kw = _kw;
    if (!kw) return @[];
    klioCocoaA11yActivate(kw);
    return klioCocoaA11yElements(kw, kw->a11y.roots);
}
- (id)accessibilityHitTest:(NSPoint)point {
    KlioWindow* kw = _kw;
    if (!kw) return self;
    klioCocoaA11yActivate(kw);
    // The last node in document order under the point is the innermost.
    for (auto it = kw->a11y.nodes.rbegin(); it != kw->a11y.nodes.rend(); ++it) {
        if (NSPointInRect(point, klioCocoaA11yScreenRect(kw, *it))) {
            id e = klioCocoaA11yElementFor(kw, it->id);
            if (e) return e;
        }
    }
    return self;
}
- (id)accessibilityFocusedUIElement {
    KlioWindow* kw = _kw;
    if (!kw) return self;
    klioCocoaA11yActivate(kw);
    id e = klioCocoaA11yElementFor(kw, kw->a11y.focused());
    return e ? e : self;
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
            if (type == NSEventTypeLeftMouseDown || type == NSEventTypeLeftMouseDragged) {
                // A platform drag the program starts starts from this press.
                [kw->lastMouseEvent release];
                kw->lastMouseEvent = [ev retain];
            }
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
static void klioCocoaA11yScript(KlioWindow* kw, int kind, const std::string& name, const std::string& text);

static void klioCocoaPrintCursor(KlioWindow* kw);

static int klioCocoaPop(KlioWindow* kw, double* out) {
    for (;;) {
        const int type = klioPopEv(kw->events, out, &kw->eventText);
        if (type == KLIO_EV_POINTER && kw->drag.active) {
            KlioEv e;
            e.type = type;
            for (int i = 0; i < KLIO_EV_VALUES; i++) e.v[i] = out[i];
            if (kw->drag.pointer(kw->events, e)) continue;
        }
        if (type == KLIO_EV_CURSOR_SCRIPT) {
            klioCocoaPrintCursor(kw);
            continue;
        }
        if (type == KLIO_EV_A11Y_SCRIPT) {
            const size_t at = static_cast<size_t>(out[1]);
            const size_t textAt = static_cast<size_t>(out[2]);
            if (textAt < klioScriptTexts().size()) {
                klioCocoaA11yScript(kw, static_cast<int>(out[0]), klioScriptTexts()[at], klioScriptTexts()[textAt]);
            }
            continue;
        }
        if (type != KLIO_EV_MENU_PATH) {
            kw->dndAsk.reported(type, out);
            return type;
        }
        const size_t at = static_cast<size_t>(out[0]);
        // A native menu is not left open: menushow is the drawn menus'.
        if (at < klioScriptTexts().size() && out[1] == 0) klioCocoaPerformMenuPath(kw, klioScriptTexts()[at]);
    }
}

int klio_win_poll_event(KlioWindow* kw, int timeoutMs, double* out) {
    if (!kw) return KLIO_EV_CLOSE;
    if (kw->dndAsk.kind) klioDndAnswer(kw, 0);
    klioScriptTick(kw->script, kw->events);
    if (!kw->events.empty()) return klioCocoaPop(kw, out);
    klioWakePosted().store(false);
    @autoreleasepool {
        NSDate* until = [NSDate dateWithTimeIntervalSinceNow:klioScriptWaitCap(timeoutMs) / 1000.0];
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

// A node's role as NSAccessibility reports it, read back to klio's.
static int klioCocoaA11yRoleOf(id el) {
    NSString* role = [el accessibilityRole];
    NSString* sub = [el accessibilitySubrole];
    if ([role isEqualToString:NSAccessibilityButtonRole]) return KLIO_A11Y_ROLE_BUTTON;
    if ([role isEqualToString:NSAccessibilityCheckBoxRole]) {
        return [sub isEqualToString:NSAccessibilitySwitchSubrole] ? KLIO_A11Y_ROLE_SWITCH : KLIO_A11Y_ROLE_CHECKBOX;
    }
    if ([role isEqualToString:NSAccessibilityRadioButtonRole]) {
        return [sub isEqualToString:NSAccessibilityTabButtonSubrole] ? KLIO_A11Y_ROLE_TAB : KLIO_A11Y_ROLE_RADIO_BUTTON;
    }
    if ([role isEqualToString:NSAccessibilityPopUpButtonRole]) return KLIO_A11Y_ROLE_DROPDOWN;
    if ([role isEqualToString:NSAccessibilityImageRole]) return KLIO_A11Y_ROLE_IMAGE;
    if ([role isEqualToString:NSAccessibilityTextFieldRole]) {
        return [sub isEqualToString:NSAccessibilitySecureTextFieldSubrole] ? KLIO_A11Y_ROLE_PASSWORD_FIELD
                                                                           : KLIO_A11Y_ROLE_TEXT_FIELD;
    }
    if ([role isEqualToString:NSAccessibilityStaticTextRole]) return KLIO_A11Y_ROLE_TEXT;
    if ([role isEqualToString:NSAccessibilitySliderRole]) return KLIO_A11Y_ROLE_SLIDER;
    if ([role isEqualToString:NSAccessibilityProgressIndicatorRole]) return KLIO_A11Y_ROLE_PROGRESS;
    if ([role isEqualToString:NSAccessibilityScrollAreaRole]) return KLIO_A11Y_ROLE_SCROLL_AREA;
    return KLIO_A11Y_ROLE_GROUP;
}

static std::string klioCocoaString(id v) {
    return [v isKindOfClass:[NSString class]] ? std::string([(NSString*)v UTF8String]) : std::string();
}

// A node's name as a client reads it: static text's value, else its label.
static std::string klioCocoaA11yName(id el) {
    if (klioCocoaA11yRoleOf(el) == KLIO_A11Y_ROLE_TEXT) return klioCocoaString([el accessibilityValue]);
    return klioCocoaString([el accessibilityLabel]);
}

static void klioCocoaA11yDump(id el, int depth) {
    const int role = klioCocoaA11yRoleOf(el);
    std::string detail;
    id value = [el accessibilityValue];
    switch (role) {
        case KLIO_A11Y_ROLE_CHECKBOX:
        case KLIO_A11Y_ROLE_SWITCH:
        case KLIO_A11Y_ROLE_RADIO_BUTTON:
        case KLIO_A11Y_ROLE_TAB: {
            const int v = [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value intValue] : 0;
            detail = v == 2 ? "mixed" : v == 1 ? "checked" : "unchecked";
            break;
        }
        case KLIO_A11Y_ROLE_TEXT_FIELD:
        case KLIO_A11Y_ROLE_PASSWORD_FIELD:
            detail = "value=\"" + klioCocoaString(value) + "\"";
            break;
        case KLIO_A11Y_ROLE_SLIDER:
        case KLIO_A11Y_ROLE_PROGRESS: {
            char buf[64];
            std::snprintf(buf, sizeof buf, "value=%g", [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value doubleValue] : 0.0);
            detail = buf;
            break;
        }
        default:
            break;
    }
    if ([el isAccessibilityFocused]) detail += detail.empty() ? "focused" : " focused";
    if (![el isAccessibilityEnabled]) detail += detail.empty() ? "disabled" : " disabled";
    klioA11yDumpLine(depth, role, klioCocoaA11yName(el), detail);
    for (id child in [el accessibilityChildren]) klioCocoaA11yDump(child, depth + 1);
}

static id klioCocoaA11yFind(NSArray* elements, const std::string& name) {
    for (id el in elements) {
        if (klioCocoaA11yName(el) == name) return el;
        id found = klioCocoaA11yFind([el accessibilityChildren], name);
        if (found) return found;
    }
    return nil;
}

// Scripted input asking through NSAccessibility, as an assistive client asks.
static void klioCocoaA11yScript(KlioWindow* kw, int kind, const std::string& name, const std::string& text) {
    @autoreleasepool {
        NSArray* roots = [kw->view accessibilityChildren];
        if (kind == KLIO_A11Y_SCRIPT_DUMP) {
            for (id el in roots) klioCocoaA11yDump(el, 0);
            return;
        }
        id el = klioCocoaA11yFind(roots, name);
        if (!el) {
            std::fprintf(stderr, "klio: no accessible node is named `%s`\n", name.c_str());
            return;
        }
        switch (kind) {
            case KLIO_A11Y_SCRIPT_PRESS: [el accessibilityPerformPress]; break;
            case KLIO_A11Y_SCRIPT_FOCUS: [el setAccessibilityFocused:YES]; break;
            case KLIO_A11Y_SCRIPT_VALUE: [el setAccessibilityValue:klioNSString(text)]; break;
            case KLIO_A11Y_SCRIPT_INCREMENT: [el accessibilityPerformIncrement]; break;
            default: break;
        }
    }
}

// Whether an assistive client reads the window.
int klio_a11y_active(KlioWindow* kw) {
    return kw && kw->a11yActive ? 1 : 0;
}

static NSCursor* klioCocoaCursor(int kind) {
    switch (kind) {
        case KLIO_CURSOR_CROSSHAIR: return [NSCursor crosshairCursor];
        case KLIO_CURSOR_TEXT: return [NSCursor IBeamCursor];
        case KLIO_CURSOR_HAND: return [NSCursor pointingHandCursor];
        default: return [NSCursor arrowCursor];
    }
}

// The cursor over the window's content: its cursor rect's from now on, and
// at once while the pointer is over the content.
// Wakes the window loop from any thread: an application-defined event ends
// its wait, and no window takes it.
void klio_app_wake(void) {
    if (klioWakePosted().exchange(true)) return;
    @autoreleasepool {
        NSEvent* e = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                        location:NSZeroPoint
                                   modifierFlags:0
                                       timestamp:0
                                    windowNumber:0
                                         context:nil
                                         subtype:0
                                           data1:0
                                           data2:0];
        [NSApp postEvent:e atStart:NO];
    }
}

// The refresh rate of the display the window is on (a ProMotion display's
// highest), in frames a second.
int klio_win_refresh_hz(KlioWindow* kw) {
    if (!kw) return 0;
    @autoreleasepool {
        NSScreen* screen = [kw->window screen] ?: [NSScreen mainScreen];
        if (!screen) return 0;
        if (@available(macOS 12.0, *)) return static_cast<int>([screen maximumFramesPerSecond]);
        return 60;
    }
}

void klio_win_set_cursor(KlioWindow* kw, int kind) {
    if (!kw) return;
    @autoreleasepool {
        NSCursor* cursor = klioCocoaCursor(kind);
        if (cursor == kw->cursor) return;
        [kw->cursor release];
        kw->cursor = [cursor retain];
        [kw->window invalidateCursorRectsForView:kw->view];
        const NSPoint p = [kw->view convertPoint:[kw->window mouseLocationOutsideOfEventStream] fromView:nil];
        if ([kw->window isKeyWindow] && NSPointInRect(p, [kw->view bounds])) [cursor set];
    }
}

// The program's answer to the drag event it handled: the action it takes
// (0 for none). AppKit asks for the latest answer itself.
void klio_win_dnd_accept(KlioWindow* kw, int action) {
    if (kw) klioDndAnswer(kw, action);
}

// Starts a drag of the payload from the window: AppKit's dragging session
// from the last press, with the decoration under the pointer, or, from a
// scripted press, a drag the window runs itself.
int klio_win_drag_start(KlioWindow* kw, const char* payload, size_t len, const unsigned char* png, size_t pngLen,
                        int ox, int oy, int actions) {
    if (!kw || !payload) return 0;
    const std::string data(payload, len);
    if (!(kw->buttons & (1 << (KLIO_BTN_PRIMARY - 1))) || !kw->lastMouseEvent) {
        kw->drag.start(actions, data);
        return 1;
    }
    @autoreleasepool {
        std::vector<std::string> files;
        std::string text;
        bool hasText = false;
        klioDndParse(data, files, text, hasText);
        NSMutableArray* items = [NSMutableArray array];
        NSImage* image = png && pngLen ? [[[NSImage alloc] initWithData:[NSData dataWithBytes:png length:pngLen]] autorelease] : nil;
        const NSPoint p = [kw->view convertPoint:[kw->lastMouseEvent locationInWindow] fromView:nil];
        const NSSize size = image ? [image size] : NSMakeSize(1, 1);
        const NSRect frame = NSMakeRect(p.x - ox, p.y - (size.height - oy), size.width, size.height);
        auto add = [&](id<NSPasteboardWriting> writer) {
            NSDraggingItem* item = [[[NSDraggingItem alloc] initWithPasteboardWriter:writer] autorelease];
            [item setDraggingFrame:frame contents:[items count] == 0 ? image : nil];
            [items addObject:item];
        };
        for (const std::string& f : files) add([NSURL fileURLWithPath:klioNSString(f)]);
        if (hasText) {
            NSPasteboardItem* item = [[[NSPasteboardItem alloc] init] autorelease];
            [item setString:klioNSString(text) forType:NSPasteboardTypeString];
            add(item);
        }
        if ([items count] == 0) return 0;
        kw->dragActions = actions;
        [kw->view beginDraggingSessionWithItems:items event:kw->lastMouseEvent source:(id<NSDraggingSource>)kw->view];
    }
    return 1;
}

static void klioCocoaPrintCursor(KlioWindow* kw) {
    NSCursor* shown = kw->cursor ? kw->cursor : [NSCursor arrowCursor];
    int kind = KLIO_CURSOR_DEFAULT;
    for (int k = KLIO_CURSOR_CROSSHAIR; k <= KLIO_CURSOR_HAND; k++) {
        if (shown == klioCocoaCursor(k)) kind = k;
    }
    klioPrintCursor(kind);
}

// The window's semantics as the program sends them: elements keep their
// identity across snapshots, and clients hear what changed.
void klio_a11y_update(KlioWindow* kw, const char* text, size_t len) {
    if (!kw || !text) return;
    @autoreleasepool {
        KlioA11yTree next = klioParseA11y(text, len);
        NSMutableDictionary* elements = [[NSMutableDictionary alloc] init];
        std::vector<int> changedValues;
        bool layout = next.nodes.size() != kw->a11y.nodes.size();
        for (const KlioA11yNode& n : next.nodes) {
            KlioA11yElement* e = klioCocoaA11yElementFor(kw, n.id);
            if (e) {
                [elements setObject:e forKey:@(n.id)];
                const KlioA11yNode* before = kw->a11y.find(n.id);
                if (before && (before->value != n.value || before->name != n.name || before->states != n.states ||
                               before->current != n.current)) {
                    changedValues.push_back(n.id);
                }
                if (before && (before->x != n.x || before->y != n.y || before->w != n.w || before->h != n.h ||
                               before->children != n.children)) {
                    layout = true;
                }
            } else {
                e = [[KlioA11yElement alloc] init];
                e.kw = kw;
                e.nodeId = n.id;
                [elements setObject:e forKey:@(n.id)];
                [e release];
                layout = true;
            }
        }
        for (NSNumber* key in kw->a11yElements) {
            if (![elements objectForKey:key]) {
                KlioA11yElement* gone = [kw->a11yElements objectForKey:key];
                gone.kw = nullptr;
                NSAccessibilityPostNotification(gone, NSAccessibilityUIElementDestroyedNotification);
            }
        }
        const int focusedBefore = kw->a11y.focused();
        [kw->a11yElements release];
        kw->a11yElements = elements;
        kw->a11y = std::move(next);
        for (int nodeId : changedValues) {
            id e = klioCocoaA11yElementFor(kw, nodeId);
            if (e) NSAccessibilityPostNotification(e, NSAccessibilityValueChangedNotification);
        }
        if (layout) NSAccessibilityPostNotification(kw->view, NSAccessibilityLayoutChangedNotification);
        const int focused = kw->a11y.focused();
        if (focused != focusedBefore && focused >= 0) {
            id e = klioCocoaA11yElementFor(kw, focused);
            if (e) NSAccessibilityPostNotification(e, NSAccessibilityFocusedUIElementChangedNotification);
        }
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
        [view registerForDraggedTypes:@[ NSPasteboardTypeFileURL, NSPasteboardTypeString ]];
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
        kw->a11yActive = klioA11yForced();
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
        // The frame is drawn outside any run loop pass, so the drawable
        // nextDrawable autoreleases is released here: a drawable left in the
        // thread's pool keeps its layer, and its textures, alive.
        sk_sp<SkSurface> surf;
        id<CAMetalDrawable> d = nil;
        @autoreleasepool {
            d = [kw->metalLayer nextDrawable];
            const int pw = static_cast<int>(kw->metalLayer.drawableSize.width);
            const int ph = static_cast<int>(kw->metalLayer.drawableSize.height);
            if (d && d.texture) {
                GrMtlTextureInfo texInfo;
                texInfo.fTexture.retain((GrMTLHandle)d.texture);
                GrBackendRenderTarget backendRT = GrBackendRenderTargets::MakeMtl(pw, ph, texInfo);
                surf = SkSurfaces::WrapBackendRenderTarget(
                    kw->grContext.get(), backendRT, kTopLeft_GrSurfaceOrigin,
                    kBGRA_8888_SkColorType, nullptr, nullptr);
            }
            if (surf) kw->drawable = (GrMTLHandle)CFRetain((CFTypeRef)d);  // hold until present
        }
        if (!surf) return nullptr;
        // The drawable is sized in physical pixels; scale the canvas by the backing
        // factor so the frame (in points) rasterizes at full resolution.
        if (kw->backingScale != 1.0)
            surf->getCanvas()->scale(kw->backingScale, kw->backingScale);
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
        // Skia's Metal backend makes its command buffers and encoders as it
        // flushes; the frame is outside any run loop pass, so they are
        // released here.
        @autoreleasepool {
            kw->grContext->flushAndSubmit(kw->surface->surface.get(), GrSyncCpu::kNo);
            klioPresentDump(kw->surface);
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
    for (NSNumber* key in kw->a11yElements) ((KlioA11yElement*)[kw->a11yElements objectForKey:key]).kw = nullptr;
    [kw->a11yElements release];
    kw->a11yElements = nil;
    [kw->cursor release];
    kw->cursor = nil;
    [kw->lastMouseEvent release];
    kw->lastMouseEvent = nil;
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
    @autoreleasepool {
        kw->grContext.reset();
    }
    if (kw->metalLayer) {
        // The view's layer holds it as a sublayer, with its drawables.
        [kw->metalLayer removeFromSuperlayer];
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
    // The window is not released when it closes (setReleasedWhenClosed:NO):
    // its view and layers go with the reference this window holds.
    @autoreleasepool {
        [kw->window close];
        [kw->window release];
    }
    kw->window = nil;
    kw->view = nil;
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
    timeoutMs = klioScriptWaitCap(timeoutMs);
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
#include <cstdarg>
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
int klio_a11y_active(void*) { return 0; }
void klio_a11y_update(void*, const char*, size_t) {}
int klio_win_refresh_hz(void*) { return 0; }
void klio_app_wake(void) {}
void klio_win_set_cursor(void*, int) {}
void klio_win_dnd_accept(void*, int) {}
int klio_win_drag_start(void*, const char*, size_t, const unsigned char*, size_t, int, int, int) { return 0; }
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
    timeoutMs = klioScriptWaitCap(timeoutMs);
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
int klio_a11y_active(void*) { return 0; }
void klio_a11y_update(void*, const char*, size_t) {}
int klio_win_refresh_hz(void*) { return 0; }
void klio_app_wake(void) {}
void klio_win_set_cursor(void*, int) {}
void klio_win_dnd_accept(void*, int) {}
int klio_win_drag_start(void*, const char*, size_t, const unsigned char*, size_t, int, int, int) { return 0; }
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
    timeoutMs = klioScriptWaitCap(timeoutMs);
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
int klio_a11y_active(void*) { return 0; }
void klio_a11y_update(void*, const char*, size_t) {}
int klio_win_refresh_hz(void*) { return 0; }
void klio_app_wake(void) {}
void klio_win_set_cursor(void*, int) {}
void klio_win_dnd_accept(void*, int) {}
int klio_win_drag_start(void*, const char*, size_t, const unsigned char*, size_t, int, int, int) { return 0; }
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
    timeoutMs = klioScriptWaitCap(timeoutMs);
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
