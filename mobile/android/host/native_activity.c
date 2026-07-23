// On-screen Android app host for the KLIO interpreter (NativeActivity, no Java).
//
// android_native_app_glue gives us an ANativeWindow (from the activity's surface)
// and the input queue. On window-ready we install the surface, run the windowed
// Compose scene (which registers a per-frame callback and returns), then drive
// frames from AChoreographer (the CADisplayLink analogue). Touches forward into
// the resident VM's pointer processor. The interpreter + Skia shim + Skia are
// linked into this one .so; the base image + scene ship as APK assets.
#include <android_native_app_glue.h>
#include <android/native_window.h>
#include <android/choreographer.h>
#include <android/input.h>
#include <android/keycodes.h>
#include <android/asset_manager.h>
#include <android/configuration.h>
#include <android/log.h>
#include <sys/system_properties.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

extern int klio_run(int argc, const char *const *argv);
extern void klio_set_surface(void *window, int w, int h, double scale);
extern void klio_render_frame(void);
extern int klio_frame_active(void);
extern void klio_dispatch_touches(int count, const int *ids, const int *xs,
                                  const int *ys, const int *downs, int phase);
extern void klio_dispatch_scroll(int x, int y, int dx, int dy);
extern void klio_dispatch_text(const char *bytes, int len);
extern void klio_dispatch_key(int kind);
extern void klio_set_keyboard_handler(void (*show)(void), void (*hide)(void));

// JNI bridge for the soft keyboard (native_activity has no Java) — defined in
// jni_input.c. show/hide toggle the IME; key events resolve to Unicode text.
void klio_jni_init(struct android_app *app);
void klio_jni_show_keyboard(void);
void klio_jni_hide_keyboard(void);
int klio_jni_key_unicode(int keyCode, int metaState, int deviceId);

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "klio-host", __VA_ARGS__)

// ARM64 bionic requires a 64-byte-aligned TLS segment; zig emits align 8. A
// native over-aligned thread-local raises the .so's PT_TLS alignment.
__attribute__((aligned(64))) static _Thread_local volatile char klio_tls_align[64];

static float g_density = 1.0f;
static int g_started = 0;
static int g_selftest = 0;
static unsigned long g_frames = 0;

static long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000000000L + ts.tv_nsec;
}

// Shim-recorded boundary timestamps (src/compose_ui/skia_shim.cpp), used to split
// the frame into recompose+layout / draw / swap.
extern long klio_perf_surface_ns, klio_perf_present_ns, klio_perf_swap_ns;

// Rolling per-60-frame timing: render = time inside klio_render_frame (VM
// recompose + draw + eglSwapBuffers); gap = wall time between frame callbacks;
// compose/draw/swap = the shim-boundary split of render.
static long g_render_ns = 0, g_gap_ns = 0, g_last_cb_ns = 0;
static long g_compose_ns = 0, g_draw_ns = 0, g_swap_ns = 0;
static long g_input_ns = 0, g_input_count = 0;   // input-callback cost per 60 frames

static void onFrame(long frameTimeNanos, void *data) {
    (void)frameTimeNanos; (void)data;
    long t0 = now_ns();
    if (g_last_cb_ns) g_gap_ns += t0 - g_last_cb_ns;
    g_last_cb_ns = t0;
    klio_render_frame();
    g_render_ns += now_ns() - t0;
    if (klio_perf_surface_ns > t0) {           // a window drew this frame
        g_compose_ns += klio_perf_surface_ns - t0;
        g_draw_ns += klio_perf_present_ns - klio_perf_surface_ns;
        g_swap_ns += klio_perf_swap_ns;
    }
    if (++g_frames % 60 == 0) {
        LOG("frames=%lu render=%.1fms (compose=%.1f draw=%.1f swap=%.1f) gap=%.1fms (%.0ffps) input=%.1fms/%ldev",
            g_frames, g_render_ns / 60.0 / 1e6,
            g_compose_ns / 60.0 / 1e6, g_draw_ns / 60.0 / 1e6, g_swap_ns / 60.0 / 1e6,
            g_gap_ns / 60.0 / 1e6, g_gap_ns > 0 ? 60.0 * 1e9 / (double)g_gap_ns : 0.0,
            g_input_ns / 60.0 / 1e6, g_input_count);
        g_render_ns = g_gap_ns = g_compose_ns = g_draw_ns = g_swap_ns = 0;
        g_input_ns = g_input_count = 0;
    }
    // Headless input self-test (`adb shell setprop debug.klio.selftest 1`): the
    // emulator screenshot path has no gesture injection into a NativeActivity
    // surface, so synthesize input once the UI is running — a scroll slides the
    // scene's bar, two pressed pointers draw a circle each, and a text/key event
    // exercises the IME bridge. Proves scroll + multi-touch + keyboard end to end
    // (event -> resident VM -> pointer/text processor).
    if (g_selftest) {
        if (g_frames == 120) { LOG("selftest scroll dy=300"); klio_dispatch_scroll(200, 400, 0, 300); }
        if (g_frames == 180) {
            int ids[2] = {101, 202}, xs[2] = {110, 290}, ys[2] = {130, 130}, downs[2] = {1, 1};
            LOG("selftest touch: 2 pointers");
            klio_dispatch_touches(2, ids, xs, ys, downs, 0);
        }
        if (g_frames == 220) { LOG("selftest text: 'K'"); klio_dispatch_text("K", 1); }
        if (g_frames == 260) {
            // Prove the JNI keyboard bridge: KeyCharacterMap resolves keycode 'A'
            // (29) to Unicode, and the IME pops via InputMethodManager.
            int u = klio_jni_key_unicode(29 /*AKEYCODE_A*/, 0, -1 /*virtual*/);
            LOG("selftest key_unicode(A)=%d ('%c')", u, u > 31 && u < 127 ? (char)u : '?');
            LOG("selftest show keyboard");
            klio_jni_show_keyboard();
        }
    }
    AChoreographer_postFrameCallback(AChoreographer_getInstance(), onFrame, NULL);
}

// Copy an APK asset to the app's internal storage and return a malloc'd path (the
// interpreter's run-image reads files, not asset streams).
static char *extractAsset(struct android_app *app, const char *name) {
    AAssetManager *mgr = app->activity->assetManager;
    AAsset *asset = AAssetManager_open(mgr, name, AASSET_MODE_BUFFER);
    if (!asset) { LOG("asset not found: %s", name); return NULL; }
    off_t len = AAsset_getLength(asset);
    const void *buf = AAsset_getBuffer(asset);
    const char *dir = app->activity->internalDataPath;
    char *path = malloc(strlen(dir) + strlen(name) + 2);
    sprintf(path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    if (f) { fwrite(buf, 1, (size_t)len, f); fclose(f); }
    AAsset_close(asset);
    return path;
}

static void captureStderr(struct android_app *app) {
    const char *dir = app->activity->internalDataPath;
    char path[1024];
    snprintf(path, sizeof(path), "%s/klio_stderr.log", dir);
    if (freopen(path, "w", stderr)) setvbuf(stderr, NULL, _IONBF, 0);
}

static void startUi(struct android_app *app) {
    if (g_started || !app->window) return;
    g_started = 1;
    char prop[PROP_VALUE_MAX] = {0};
    if (__system_property_get("debug.klio.selftest", prop) > 0 && prop[0] != '0')
        g_selftest = 1;
    ANativeWindow *win = app->window;
    int wpx = ANativeWindow_getWidth(win);
    int hpx = ANativeWindow_getHeight(win);
    g_density = AConfiguration_getDensity(app->config) / 160.0f;
    if (g_density < 1.0f) g_density = 1.0f;
    int wp = (int)(wpx / g_density);   // points
    int hp = (int)(hpx / g_density);

    setenv("HOME", app->activity->internalDataPath, 1);
    captureStderr(app);
    char *base = extractAsset(app, "base.klio-image");
    char *scene = extractAsset(app, "window_scene.kt");
    if (!base || !scene) { LOG("missing assets; cannot start UI"); return; }

    // Let the resident VM drive the soft keyboard for Compose text fields.
    klio_set_keyboard_handler(klio_jni_show_keyboard, klio_jni_hide_keyboard);

    klio_set_surface((void *)win, wp, hp, (double)g_density);
    const char *argv[] = {"run-image", base, scene};
    int rc = klio_run(3, argv);
    LOG("on-screen: run-image rc=%d frame_active=%d", rc, klio_frame_active());
    if (klio_frame_active()) {
        AChoreographer_postFrameCallback(AChoreographer_getInstance(), onFrame, NULL);
    }
}

static void onCmd(struct android_app *app, int32_t cmd) {
    if (cmd == APP_CMD_INIT_WINDOW) startUi(app);
}

// A mouse wheel / trackpad notch is ~1.0 scroll unit; scale to a per-step point
// delta so a notch slides content a comfortable amount (matches the iOS pan feel).
#define SCROLL_STEP_PX 60.0f

static int32_t onInputImpl(struct android_app *app, AInputEvent *event) {
    (void)app;
    int type = AInputEvent_getType(event);

    // Hardware / soft keyboard: forward key-down as text (Unicode via the JNI
    // KeyCharacterMap) or an edit key (backspace / IME action).
    if (type == AINPUT_EVENT_TYPE_KEY) {
        if (AKeyEvent_getAction(event) != AKEY_EVENT_ACTION_DOWN) return 1;
        int32_t code = AKeyEvent_getKeyCode(event);
        if (code == AKEYCODE_DEL) { klio_dispatch_key(1); return 1; }
        if (code == AKEYCODE_ENTER || code == AKEYCODE_NUMPAD_ENTER) { klio_dispatch_key(2); return 1; }
        int uni = klio_jni_key_unicode(code, AKeyEvent_getMetaState(event), AInputEvent_getDeviceId(event));
        if (g_selftest) LOG("key: code=%d uni=%d", code, uni);
        if (uni > 0) {
            char buf[5];
            int len = 0;
            if (uni < 0x80) { buf[len++] = (char)uni; }
            else if (uni < 0x800) { buf[len++] = (char)(0xC0 | (uni >> 6)); buf[len++] = (char)(0x80 | (uni & 0x3F)); }
            else if (uni < 0x10000) { buf[len++] = (char)(0xE0 | (uni >> 12)); buf[len++] = (char)(0x80 | ((uni >> 6) & 0x3F)); buf[len++] = (char)(0x80 | (uni & 0x3F)); }
            else { buf[len++] = (char)(0xF0 | (uni >> 18)); buf[len++] = (char)(0x80 | ((uni >> 12) & 0x3F)); buf[len++] = (char)(0x80 | ((uni >> 6) & 0x3F)); buf[len++] = (char)(0x80 | (uni & 0x3F)); }
            klio_dispatch_text(buf, len);
        }
        return 1;
    }

    if (type != AINPUT_EVENT_TYPE_MOTION) return 0;
    int32_t action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;

    // Indirect scroll (mouse wheel / trackpad) -> Compose Scroll events.
    if (action == AMOTION_EVENT_ACTION_SCROLL) {
        float vs = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_VSCROLL, 0);
        float hs = AMotionEvent_getAxisValue(event, AMOTION_EVENT_AXIS_HSCROLL, 0);
        int x = (int)(AMotionEvent_getX(event, 0) / g_density);
        int y = (int)(AMotionEvent_getY(event, 0) / g_density);
        klio_dispatch_scroll(x, y, (int)(hs * SCROLL_STEP_PX), (int)(vs * SCROLL_STEP_PX));
        return 1;
    }

    size_t count = AMotionEvent_getPointerCount(event);
    int ids[16], xs[16], ys[16], downs[16];
    int n = 0;
    int down = !(action == AMOTION_EVENT_ACTION_UP || action == AMOTION_EVENT_ACTION_CANCEL);
    for (size_t i = 0; i < count && n < 16; i++) {
        ids[n] = AMotionEvent_getPointerId(event, i);
        xs[n] = (int)(AMotionEvent_getX(event, i) / g_density);   // pixels -> points
        ys[n] = (int)(AMotionEvent_getY(event, i) / g_density);
        downs[n] = down ? 1 : 0;
        n++;
    }
    int phase = (action == AMOTION_EVENT_ACTION_DOWN || action == AMOTION_EVENT_ACTION_POINTER_DOWN) ? 0
              : (action == AMOTION_EVENT_ACTION_MOVE) ? 1
              : (action == AMOTION_EVENT_ACTION_UP || action == AMOTION_EVENT_ACTION_POINTER_UP) ? 2
              : 3;
    klio_dispatch_touches(n, ids, xs, ys, downs, phase);
    return 1;
}

static int32_t onInput(struct android_app *app, AInputEvent *event) {
    long i0 = now_ns();
    int32_t r = onInputImpl(app, event);
    g_input_ns += now_ns() - i0;
    g_input_count++;
    return r;
}

void android_main(struct android_app *app) {
    klio_tls_align[0] = 0;
    klio_jni_init(app);
    app->onAppCmd = onCmd;
    app->onInputEvent = onInput;

    // If the window is already up (fast path), start now; otherwise onCmd handles it.
    if (app->window) startUi(app);

    while (1) {
        int events;
        struct android_poll_source *source;
        while (ALooper_pollOnce(-1, NULL, &events, (void **)&source) >= 0) {
            if (source) source->process(app, source);
            if (app->destroyRequested) return;
        }
    }
}
