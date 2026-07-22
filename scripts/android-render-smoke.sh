#!/usr/bin/env bash
# Offscreen Compose render on Android: cross-compile the interpreter, compile the
# Skia shim + link it (with prebuilt Android Skia) into the native host, bake a
# Compose base image, and render a scene to a PNG on the emulator via `adb shell`.
# Proves the Compose -> Skia pipeline on Android (the on-screen ANativeWindow
# backend + APK host land in a later step). Skips cleanly without the NDK / Skia /
# an emulator.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

SCENE="mobile/ios/AppHost/scene.kt"   # klio.compose.ui offscreen scene (shared with iOS)
API="${ANDROID_API:-24}"

skip() { echo "SKIP android-render-smoke: $1"; exit 0; }
fail() { echo "FAIL android-render-smoke: $1"; exit 1; }

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
[ -x "$ADB" ] || skip "adb not found"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/*/ 2>/dev/null | sort | tail -1)}"; NDK="${NDK%/}"
[ -n "$NDK" ] && [ -d "$NDK" ] || skip "Android NDK not found"
TOOL="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
CC="$TOOL/aarch64-linux-android${API}-clang"; CXX="$TOOL/aarch64-linux-android${API}-clang++"
[ -x "$CXX" ] || skip "NDK clang not found"
SK="third_party/skia/android-arm64"; SKO="$SK/out/Release-android-arm64"
[ -f "$SKO/libskia.a" ] || skip "Android Skia not fetched (scripts/fetch-skia.sh android arm64)"

OUT="${ANDROID_OUT:-$(pwd)/zig-out/android-render}"; mkdir -p "$OUT"

echo "==> cross-compile interpreter + host klio for baking"
zig build mobile-lib -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast -Dandroid-api="$API"
HOST_PREFIX="${ANDROID_HOST_PREFIX:-$(pwd)/zig-out/host}"
zig build -Doptimize=ReleaseFast -p "$HOST_PREFIX"   # host klio: base image is target-portable
LIB="$(pwd)/zig-out/lib/libklio-android.a"; ZSTD="$(pwd)/zig-out/lib/libzstd.a"; HOSTKLIO="$HOST_PREFIX/bin/klio"

echo "==> compile shim + link native host against Android Skia"
"$CC"  -O2 -fPIE -fno-emulated-tls -c mobile/android/host/android_main.c -o "$OUT/amain.o"
"$CXX" -std=c++17 -O2 -DNDEBUG -fPIC -I"$SK" -c src/compose_ui/skia_shim.cpp -o "$OUT/shim.o"
"$CXX" -std=c++17 -O2 -DNDEBUG -fPIC -I"$SK" -c src/compose_ui/font_data.cpp -o "$OUT/font.o"
"$CXX" -fPIE -pie -static-libstdc++ "$OUT/amain.o" "$OUT/shim.o" "$OUT/font.o" \
  "$LIB" "$ZSTD" $SKO/*.a -llog -landroid -lEGL -lGLESv2 -lm -o "$OUT/klio-host"
[ -f "$OUT/klio-host" ] || fail "host did not link"

echo "==> bake compose base image (host klio)"
"$HOSTKLIO" bake-image "$SCENE" -o "$OUT/base.klio-image" || fail "bake-image failed"

DEV="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
[ -n "$DEV" ] || skip "no booted emulator/device"

echo "==> render on $DEV"
"$ADB" -s "$DEV" push "$OUT/klio-host" /data/local/tmp/klio-host >/dev/null
"$ADB" -s "$DEV" push "$OUT/base.klio-image" /data/local/tmp/base.klio-image >/dev/null
"$ADB" -s "$DEV" push "$SCENE" /data/local/tmp/scene.kt >/dev/null
"$ADB" -s "$DEV" shell "chmod +x /data/local/tmp/klio-host"
"$ADB" -s "$DEV" shell "cd /data/local/tmp && HOME=/data/local/tmp ./klio-host run-image base.klio-image scene.kt /data/local/tmp/render.png" | tr -d '\r'
"$ADB" -s "$DEV" pull /data/local/tmp/render.png "$OUT/render.png" >/dev/null 2>&1 || true

if [ -f "$OUT/render.png" ] && [ "$(head -c8 "$OUT/render.png" | od -An -tx1 | tr -d ' \n')" = "89504e470d0a1a0a" ]; then
  echo "PASS android-render-smoke: Compose rendered a PNG on Android ($(stat -f%z "$OUT/render.png") bytes -> $OUT/render.png)"
else
  fail "no valid PNG produced (see $OUT)"
fi
