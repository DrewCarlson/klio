#!/usr/bin/env bash
# Link the full iOS UI stack into the app and run it on the simulator: the
# interpreter (libklio) + the statically-linked Skia shim (libklio_skia.a) +
# prebuilt Skia (libskia.a + deps) + Apple frameworks. Verifies the shim's
# symbols resolve into the app (the compose_ui static-link path) and the app
# runs. Renders headless for now — the on-screen Compose surface + the compose
# packs land in later steps. Skips cleanly without the iOS toolchain / Skia.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FIXTURE="tests/fixtures/mobile_smoke/smoke.kt"
EXPECTED="tests/fixtures/mobile_smoke/smoke.expected"
BUNDLE_ID="dev.klio.headless"
OUT="${IOS_APP_OUT:-$(pwd)/zig-out/ios-ui-app}"
APP="$OUT/KlioHeadless.app"
SKIA_OUT="third_party/skia/iossim-arm64/out/Release-iosSim-arm64"

skip() { echo "SKIP ios-ui-smoke: $1"; exit 0; }
fail() { echo "FAIL ios-ui-smoke: $1"; exit 1; }

command -v xcrun >/dev/null 2>&1 || skip "xcrun not found"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || skip "iphonesimulator SDK not found"
[ -f "$SKIA_OUT/libskia.a" ] || skip "iOS Skia not fetched (scripts/fetch-skia.sh iossim arm64)"

echo "==> build interpreter lib + Skia shim for ios-sim"
zig build mobile-lib skia-lib -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseFast
LIB="$(pwd)/zig-out/lib/libklio-ios-sim.a"
ZSTD="$(pwd)/zig-out/lib/libzstd.a"
SHIM="$(pwd)/zig-out/lib/libklio_skia.a"
for f in "$LIB" "$ZSTD" "$SHIM"; do [ -f "$f" ] || fail "expected $f"; done

echo "==> assemble $APP"
rm -rf "$APP"; mkdir -p "$APP"
cp mobile/ios/AppHost/Info.plist "$APP/Info.plist"
cp "$FIXTURE" "$APP/program.kt"

echo "==> compile + link the app (interpreter + Skia)"
xcrun -sdk iphonesimulator clang \
  -arch arm64 -mios-simulator-version-min=15.0 -isysroot "$SDK" -fobjc-arc -O2 \
  mobile/ios/AppHost/main.m \
  "$LIB" "$ZSTD" "$SHIM" $SKIA_OUT/*.a \
  -lc++ \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -framework CoreGraphics -framework CoreText -framework ImageIO \
  -framework Metal -framework QuartzCore \
  -o "$APP/KlioHeadless" 2>&1 | grep -vE "was built for newer|ignoring duplicate" || true
[ -f "$APP/KlioHeadless" ] || fail "app binary did not link"

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

echo "==> install + launch"
xcrun simctl install "$DEV" "$APP"
LOG="$OUT/launch.log"
xcrun simctl launch --console-pty "$DEV" "$BUNDLE_ID" >"$LOG" 2>&1 || true
echo "--- app console ---"; cat "$LOG"; echo "-------------------"

MISS=0
while IFS= read -r line; do
  grep -Fq "$line" "$LOG" || { echo "missing: $line"; MISS=1; }
done < "$EXPECTED"
[ "$MISS" = 0 ] && echo "PASS ios-ui-smoke: UI-linked app runs (headless)" || fail "output mismatch (see $LOG)"
