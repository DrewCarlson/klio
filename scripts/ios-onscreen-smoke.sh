#!/usr/bin/env bash
# On-screen Compose on the iOS simulator: link the full UI stack into the app
# (interpreter + static Skia shim + prebuilt Skia + Apple frameworks), ship a
# baked base image + a windowed Compose scene, and drive it live. The app
# installs a CAMetalLayer-backed view as the render surface, runs the scene
# (which registers a per-frame callback and returns), then drives frames from
# CADisplayLink. Verifies the resident VM re-enters each vsync without crashing
# (the "frames=" heartbeat) and captures a screenshot. Skips cleanly without the
# iOS toolchain / Skia.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

BUNDLE_ID="dev.klio.onscreen"
OUT="${IOS_APP_OUT:-$(pwd)/zig-out/ios-onscreen-app}"
APP="$OUT/KlioOnscreen.app"
SKIA_OUT="third_party/skia/iossim-arm64/out/Release-iosSim-arm64"
SCENE="mobile/ios/AppHost/window_scene.kt"

skip() { echo "SKIP ios-onscreen-smoke: $1"; exit 0; }
fail() { echo "FAIL ios-onscreen-smoke: $1"; exit 1; }

command -v xcrun >/dev/null 2>&1 || skip "xcrun not found"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || skip "iphonesimulator SDK not found"
[ -f "$SKIA_OUT/libskia.a" ] || skip "iOS Skia not fetched (scripts/fetch-skia.sh iossim arm64)"

echo "==> build host klio for baking (separate prefix so zig-out stays iOS)"
HOST_PREFIX="${IOS_HOST_PREFIX:-$(pwd)/zig-out/host}"
zig build -Doptimize=ReleaseFast -p "$HOST_PREFIX"   # base image is target-portable
echo "==> build interpreter lib + Skia shim for ios-sim"
zig build mobile-lib skia-lib -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseFast
LIB="$(pwd)/zig-out/lib/libklio-ios-sim.a"
ZSTD="$(pwd)/zig-out/lib/libzstd.a"
SHIM="$(pwd)/zig-out/lib/libklio_skia.a"
HOSTKLIO="$HOST_PREFIX/bin/klio"
for f in "$LIB" "$ZSTD" "$SHIM" "$HOSTKLIO"; do [ -f "$f" ] || fail "expected $f"; done

echo "==> assemble $APP (bake the compose base image + ship the window scene)"
rm -rf "$APP"; mkdir -p "$APP"
cp mobile/ios/AppHost/Info.plist "$APP/Info.plist"
# Rewrite the bundle id + executable/name so this app coexists with the
# offscreen smoke's and the plist points at this app's binary (KlioOnscreen).
/usr/bin/sed -i '' -e "s/dev\.klio\.headless/$BUNDLE_ID/" -e "s/KlioHeadless/KlioOnscreen/g" "$APP/Info.plist"
cp "$SCENE" "$APP/window_scene.kt"
"$HOSTKLIO" bake-image "$SCENE" -o "$APP/base.klio-image" || fail "bake-image failed"

echo "==> compile + link the app (interpreter + Skia)"
xcrun -sdk iphonesimulator clang \
  -arch arm64 -mios-simulator-version-min=15.0 -isysroot "$SDK" -fobjc-arc -O2 \
  mobile/ios/AppHost/main.m \
  "$LIB" "$ZSTD" "$SHIM" $SKIA_OUT/*.a \
  -lc++ \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -framework CoreGraphics -framework CoreText -framework ImageIO \
  -framework Metal -framework QuartzCore \
  -o "$APP/KlioOnscreen" 2>&1 | grep -vE "was built for newer|ignoring duplicate" || true
[ -f "$APP/KlioOnscreen" ] || fail "app binary did not link"

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

DEV="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
BOOTED_HERE=0
if [ -z "$DEV" ]; then
  DEV="$(xcrun simctl list devices available | grep -m1 -E 'iPhone 1[56]' | grep -oE '[0-9A-F-]{36}' || true)"
  [ -n "$DEV" ] || skip "no available iPhone simulator"
  xcrun simctl boot "$DEV"; BOOTED_HERE=1; sleep 4
fi
cleanup() {
  xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
  [ "$BOOTED_HERE" = 1 ] && xcrun simctl shutdown "$DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> install + launch (app stays resident; drive frames, then screenshot)"
xcrun simctl install "$DEV" "$APP"
LOG="$OUT/launch.log"
# Launch detached (the on-screen app never exits); stream its console to LOG.
( xcrun simctl launch --console-pty "$DEV" "$BUNDLE_ID" >"$LOG" 2>&1 & echo $! >"$OUT/launch.pid" ) || true
sleep 6   # let CADisplayLink drive several seconds of frames
xcrun simctl io "$DEV" screenshot "$OUT/screen.png" >/dev/null 2>&1 || true
LP="$(cat "$OUT/launch.pid" 2>/dev/null || true)"; [ -n "$LP" ] && kill "$LP" 2>/dev/null || true

echo "--- app console (first lines) ---"; head -8 "$LOG" 2>/dev/null || true; echo "-------------------"

grep -Fq "driving CADisplayLink" "$LOG" || fail "on-screen path did not activate (no CADisplayLink) — see $LOG"
grep -Eq "frames=[0-9]+" "$LOG" || fail "no frame heartbeat — the resident VM did not render repeated frames (see $LOG)"
FRAMES="$(grep -oE 'frames=[0-9]+' "$LOG" | tail -1)"
SHOT_OK="no"
if [ -f "$OUT/screen.png" ]; then
  SZ=$(stat -f%z "$OUT/screen.png" 2>/dev/null || echo 0)
  [ "$SZ" -gt 1000 ] && SHOT_OK="yes ($SZ bytes -> $OUT/screen.png)"
fi
echo "PASS ios-onscreen-smoke: Compose drove on-screen frames ($FRAMES); screenshot=$SHOT_OK"
