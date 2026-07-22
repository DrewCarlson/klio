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
#include <android/asset_manager.h>
#include <android/configuration.h>
#include <android/log.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern int klio_run(int argc, const char *const *argv);
extern void klio_set_surface(void *window, int w, int h, double scale);
extern void klio_render_frame(void);
extern int klio_frame_active(void);
extern void klio_dispatch_touches(int count, const int *ids, const int *xs,
                                  const int *ys, const int *downs, int phase);
extern void klio_dispatch_scroll(int x, int y, int dx, int dy);
extern void klio_dispatch_key(int kind);

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "klio-host", __VA_ARGS__)

// ARM64 bionic requires a 64-byte-aligned TLS segment; zig emits align 8. A
// native over-aligned thread-local raises the .so's PT_TLS alignment.
__attribute__((aligned(64))) static _Thread_local volatile char klio_tls_align[64];

static float g_density = 1.0f;
static int g_started = 0;
static unsigned long g_frames = 0;

static void onFrame(long frameTimeNanos, void *data) {
    (void)frameTimeNanos; (void)data;
    klio_render_frame();
    if (++g_frames % 60 == 0) LOG("frames=%lu", g_frames);
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

static void startUi(struct android_app *app) {
    if (g_started || !app->window) return;
    g_started = 1;
    ANativeWindow *win = app->window;
    int wpx = ANativeWindow_getWidth(win);
    int hpx = ANativeWindow_getHeight(win);
    g_density = AConfiguration_getDensity(app->config) / 160.0f;
    if (g_density < 1.0f) g_density = 1.0f;
    int wp = (int)(wpx / g_density);   // points
    int hp = (int)(hpx / g_density);

    setenv("HOME", app->activity->internalDataPath, 1);
    char *base = extractAsset(app, "base.klio-image");
    char *scene = extractAsset(app, "window_scene.kt");
    if (!base || !scene) { LOG("missing assets; cannot start UI"); return; }

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

static int32_t onInput(struct android_app *app, AInputEvent *event) {
    (void)app;
    if (AInputEvent_getType(event) != AINPUT_EVENT_TYPE_MOTION) return 0;
    int32_t action = AMotionEvent_getAction(event) & AMOTION_EVENT_ACTION_MASK;
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

void android_main(struct android_app *app) {
    klio_tls_align[0] = 0;
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
