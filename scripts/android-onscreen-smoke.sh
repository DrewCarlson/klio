#!/usr/bin/env bash
# On-screen Compose on the Android emulator: build the interpreter + the Android
# Skia shim (EGL/GLES Ganesh backend) + a NativeActivity host into one .so,
# package a manual APK (aapt2 / zipalign / apksigner, no Gradle), install it, and
# drive it live. The app installs the activity's ANativeWindow as the render
# surface, runs a windowed Compose scene, and drives frames from AChoreographer.
# Verifies the resident VM renders repeated frames (the "frames=" heartbeat) and
# captures a screenshot. Skips cleanly without the NDK / Skia / SDK / an emulator.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

PKG="dev.klio.onscreen"
API="${ANDROID_API:-24}"
SCENE="mobile/ios/AppHost/window_scene.kt"

skip() { echo "SKIP android-onscreen-smoke: $1"; exit 0; }
fail() { echo "FAIL android-onscreen-smoke: $1"; exit 1; }

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
[ -x "$ADB" ] || skip "adb not found"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/*/ 2>/dev/null | sort | tail -1)}"; NDK="${NDK%/}"
[ -n "$NDK" ] && [ -d "$NDK" ] || skip "Android NDK not found"
BT="$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort | tail -1)"; BT="${BT%/}"
[ -x "$BT/aapt2" ] || skip "build-tools (aapt2) not found"
PLAT="$(ls -d "$SDK"/platforms/*/ 2>/dev/null | sort | tail -1)"; PLAT="${PLAT%/}"
[ -f "$PLAT/android.jar" ] || skip "android platform not found"
SK="third_party/skia/android-arm64"; SKO="$SK/out/Release-android-arm64"
[ -f "$SKO/libskia.a" ] || skip "Android Skia not fetched (scripts/fetch-skia.sh android arm64)"
command -v keytool >/dev/null 2>&1 || skip "keytool not found"

TOOL="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
CC="$TOOL/aarch64-linux-android${API}-clang"; CXX="$TOOL/aarch64-linux-android${API}-clang++"
GLUE="$NDK/sources/android/native_app_glue"
OUT="${ANDROID_OUT:-$(pwd)/zig-out/android-onscreen}"; mkdir -p "$OUT"

echo "==> cross-compile interpreter + host klio for baking"
zig build mobile-lib -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast -Dandroid-api="$API"
HOST_PREFIX="${ANDROID_HOST_PREFIX:-$(pwd)/zig-out/host}"
zig build -Doptimize=ReleaseFast -p "$HOST_PREFIX"
LIB="$(pwd)/zig-out/lib/libklio-android.a"; ZSTD="$(pwd)/zig-out/lib/libzstd.a"; HOSTKLIO="$HOST_PREFIX/bin/klio"

echo "==> compile shim (EGL/GLES backend) + native host, link the .so"
"$CC"  -O2 -fPIC -fno-emulated-tls -I"$GLUE" -c mobile/android/host/native_activity.c -o "$OUT/nact.o"
"$CC"  -O2 -fPIC -I"$GLUE" -c "$GLUE/android_native_app_glue.c" -o "$OUT/glue.o"
"$CXX" -std=c++17 -O2 -DNDEBUG -DKLIO_ANDROID -fPIC -I"$SK" -c src/compose_ui/skia_shim.cpp -o "$OUT/shim.o"
"$CXX" -std=c++17 -O2 -DNDEBUG -DKLIO_ANDROID -fPIC -I"$SK" -c src/compose_ui/font_data.cpp -o "$OUT/font.o"
"$CXX" -shared -fPIC -static-libstdc++ -o "$OUT/libklio_android.so" \
  "$OUT/nact.o" "$OUT/glue.o" "$OUT/shim.o" "$OUT/font.o" \
  "$LIB" "$ZSTD" $SKO/*.a -llog -landroid -lEGL -lGLESv2 -lm -u ANativeActivity_onCreate
[ -f "$OUT/libklio_android.so" ] || fail "native lib did not link"

echo "==> assemble APK (aapt2 + zipalign + apksigner)"
STAGE="$OUT/stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/lib/arm64-v8a" "$STAGE/assets"
"$HOSTKLIO" bake-image "$SCENE" -o "$STAGE/assets/base.klio-image" || fail "bake-image failed"
cp "$SCENE" "$STAGE/assets/window_scene.kt"
cp "$OUT/libklio_android.so" "$STAGE/lib/arm64-v8a/libklio_android.so"
KS="$OUT/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -alias k -storepass android -keypass android \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Klio Debug,O=Klio,C=US" >/dev/null 2>&1
"$BT/aapt2" link --manifest mobile/android/host/AndroidManifest.xml -I "$PLAT/android.jar" \
  --min-sdk-version "$API" --target-sdk-version 34 -o "$OUT/base.apk"
( cd "$STAGE" && zip -0 -q "$OUT/base.apk" lib/arm64-v8a/libklio_android.so \
    && zip -q "$OUT/base.apk" assets/base.klio-image assets/window_scene.kt )
"$BT/zipalign" -f -p 4 "$OUT/base.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android --out "$OUT/klio-onscreen.apk" "$OUT/aligned.apk"

DEV="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
[ -n "$DEV" ] || skip "no booted emulator/device"

echo "==> install + launch on $DEV"
"$ADB" -s "$DEV" install -r -g "$OUT/klio-onscreen.apk" >/dev/null 2>&1 || fail "install failed"
"$ADB" -s "$DEV" logcat -c >/dev/null 2>&1 || true
"$ADB" -s "$DEV" shell am start -n "$PKG/android.app.NativeActivity" >/dev/null 2>&1
sleep 6
"$ADB" -s "$DEV" exec-out screencap -p > "$OUT/screen.png" 2>/dev/null || true
LOG="$("$ADB" -s "$DEV" logcat -d -s klio-host 2>/dev/null)"
echo "--- klio-host log ---"; echo "$LOG" | grep -E "run-image|frames=" | tail -6; echo "---------------------"
"$ADB" -s "$DEV" shell am force-stop "$PKG" >/dev/null 2>&1 || true

echo "$LOG" | grep -q "frame_active=1" || fail "on-screen path did not activate (see logcat)"
FRAMES="$(echo "$LOG" | grep -oE 'frames=[0-9]+' | tail -1)"; FRAME_N="${FRAMES#frames=}"
[ "${FRAME_N:-0}" -gt 120 ] || fail "frame loop did not advance past the injected UI ($FRAMES)"
SHOT="no"; [ -f "$OUT/screen.png" ] && [ "$(stat -f%z "$OUT/screen.png")" -gt 1000 ] && SHOT="yes ($OUT/screen.png)"
echo "PASS android-onscreen-smoke: Compose drove on-screen frames ($FRAMES); screenshot=$SHOT"
