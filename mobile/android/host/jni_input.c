// JNI bridge for keyboard input on the NativeActivity host.
//
// A NativeActivity has no Java of its own, so the soft keyboard (InputMethodManager)
// and Unicode key resolution (KeyCharacterMap) are reached through JNI on the
// activity object the glue hands us. android_main runs on the glue's native
// thread; we attach it to the JVM once and cache the framework handles. show/hide
// drive the IME when a Compose text field focuses; key events resolve to Unicode
// via the device's KeyCharacterMap (hardware keys and soft-keyboard keys both
// arrive as native key events).
#include <android_native_app_glue.h>
#include <android/log.h>
#include <jni.h>

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "klio-host", __VA_ARGS__)

static JavaVM *g_vm = NULL;
static JNIEnv *g_env = NULL;      // valid on the glue thread (the only caller)
static jobject g_activity = NULL; // global ref to the NativeActivity
static jobject g_imm = NULL;      // global ref to the InputMethodManager
static jclass g_kcmClass = NULL;  // global ref to android.view.KeyCharacterMap
static jmethodID g_kcmLoad = NULL, g_kcmGet = NULL;
static jmethodID g_showSoftInput = NULL, g_hideSoftInput = NULL, g_getWindowToken = NULL;
static jmethodID g_toggleSoftInput = NULL;

static jobject decorView(JNIEnv *env) {
    jclass actClass = (*env)->GetObjectClass(env, g_activity);
    jmethodID getWindow = (*env)->GetMethodID(env, actClass, "getWindow", "()Landroid/view/Window;");
    jobject window = (*env)->CallObjectMethod(env, g_activity, getWindow);
    jclass winClass = (*env)->GetObjectClass(env, window);
    jmethodID getDecor = (*env)->GetMethodID(env, winClass, "getDecorView", "()Landroid/view/View;");
    return (*env)->CallObjectMethod(env, window, getDecor);
}

void klio_jni_init(struct android_app *app) {
    g_vm = app->activity->vm;
    if ((*g_vm)->AttachCurrentThread(g_vm, &g_env, NULL) != JNI_OK) { g_env = NULL; return; }
    JNIEnv *env = g_env;
    g_activity = (*env)->NewGlobalRef(env, app->activity->clazz);

    // imm = activity.getSystemService(Context.INPUT_METHOD_SERVICE)
    jclass actClass = (*env)->GetObjectClass(env, g_activity);
    jclass ctxClass = (*env)->FindClass(env, "android/content/Context");
    jfieldID imsField = (*env)->GetStaticFieldID(env, ctxClass, "INPUT_METHOD_SERVICE", "Ljava/lang/String;");
    jstring imsName = (*env)->GetStaticObjectField(env, ctxClass, imsField);
    jmethodID getSvc = (*env)->GetMethodID(env, actClass, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;");
    jobject imm = (*env)->CallObjectMethod(env, g_activity, getSvc, imsName);
    g_imm = (*env)->NewGlobalRef(env, imm);
    jclass immClass = (*env)->GetObjectClass(env, imm);
    g_showSoftInput = (*env)->GetMethodID(env, immClass, "showSoftInput", "(Landroid/view/View;I)Z");
    g_hideSoftInput = (*env)->GetMethodID(env, immClass, "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z");
    g_toggleSoftInput = (*env)->GetMethodID(env, immClass, "toggleSoftInput", "(II)V");

    jclass viewClass = (*env)->FindClass(env, "android/view/View");
    g_getWindowToken = (*env)->GetMethodID(env, viewClass, "getWindowToken", "()Landroid/os/IBinder;");

    jclass kcm = (*env)->FindClass(env, "android/view/KeyCharacterMap");
    g_kcmClass = (*env)->NewGlobalRef(env, kcm);
    g_kcmLoad = (*env)->GetStaticMethodID(env, kcm, "load", "(I)Landroid/view/KeyCharacterMap;");
    g_kcmGet = (*env)->GetMethodID(env, kcm, "get", "(II)I");

    (*env)->ExceptionClear(env);
    LOG("jni: keyboard bridge ready (imm=%p)", (void *)g_imm);
}

// SHOW_FORCED shows the IME even though the decor view is not itself a text
// editor — the resident VM already owns the text state; the IME is just a key
// source, its edits routed back through native key events.
void klio_jni_show_keyboard(void) {
    if (!g_env) return;
    JNIEnv *env = g_env;
    jobject decor = decorView(env);
    jboolean shown = (*env)->CallBooleanMethod(env, g_imm, g_showSoftInput, decor, 2 /*SHOW_FORCED*/);
    // The decor view is not itself a text editor, so showSoftInput can be refused;
    // toggleSoftInput(SHOW_FORCED) forces the IME up regardless.
    if (!shown && g_toggleSoftInput)
        (*env)->CallVoidMethod(env, g_imm, g_toggleSoftInput, 2 /*SHOW_FORCED*/, 0);
    (*env)->ExceptionClear(env);
}

void klio_jni_hide_keyboard(void) {
    if (!g_env) return;
    JNIEnv *env = g_env;
    jobject decor = decorView(env);
    jobject token = (*env)->CallObjectMethod(env, decor, g_getWindowToken);
    (*env)->CallBooleanMethod(env, g_imm, g_hideSoftInput, token, 0);
    (*env)->ExceptionClear(env);
}

// Resolve a native key event to a Unicode code point via the device's key map.
// Returns 0 for non-printing keys (the caller handles backspace / enter itself).
int klio_jni_key_unicode(int keyCode, int metaState, int deviceId) {
    if (!g_env || !g_kcmClass) return 0;
    JNIEnv *env = g_env;
    jobject kcm = (*env)->CallStaticObjectMethod(env, g_kcmClass, g_kcmLoad, deviceId);
    if (!kcm) { (*env)->ExceptionClear(env); return 0; }
    jint ch = (*env)->CallIntMethod(env, kcm, g_kcmGet, keyCode, metaState);
    (*env)->DeleteLocalRef(env, kcm);
    (*env)->ExceptionClear(env);
    return (int)ch;
}
