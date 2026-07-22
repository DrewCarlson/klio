#!/usr/bin/env bash
# Build a real iOS .app around the interpreter, install it on the simulator,
# launch it, and assert the bundled Kotlin program's output. Proves klio runs
# in-process inside a genuine app (UIApplicationMain), not just via simctl spawn.
# Skips cleanly (exit 0) when the iOS toolchain/simulator is unavailable.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FIXTURE="tests/fixtures/mobile_smoke/smoke.kt"
EXPECTED="tests/fixtures/mobile_smoke/smoke.expected"
BUNDLE_ID="dev.klio.headless"
OUT="${IOS_APP_OUT:-$(pwd)/zig-out/ios-app}"
APP="$OUT/KlioHeadless.app"

skip() { echo "SKIP ios-app-smoke: $1"; exit 0; }
fail() { echo "FAIL ios-app-smoke: $1"; exit 1; }

command -v xcrun >/dev/null 2>&1 || skip "xcrun not found"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || skip "iphonesimulator SDK not found"

echo "==> build the static interpreter library (mobile-lib) for ios-sim"
zig build mobile-lib -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseFast
LIB="$(pwd)/zig-out/lib/libklio-ios-sim.a"
ZSTD="$(pwd)/zig-out/lib/libzstd.a"
[ -f "$LIB" ] || fail "expected $LIB"
[ -f "$ZSTD" ] || fail "expected $ZSTD"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP"
cp mobile/ios/AppHost/Info.plist "$APP/Info.plist"
cp "$FIXTURE" "$APP/program.kt"

echo "==> compile + link the app binary (ObjC host + libklio)"
xcrun -sdk iphonesimulator clang \
  -arch arm64 -mios-simulator-version-min=15.0 -isysroot "$SDK" \
  -fobjc-arc -O2 \
  mobile/ios/AppHost/main.m \
  "$LIB" "$ZSTD" \
  -lc++ \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -o "$APP/KlioHeadless"

echo "==> ad-hoc codesign"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || true

DEV="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
BOOTED_HERE=0
if [ -z "$DEV" ]; then
  DEV="$(xcrun simctl list devices available | grep -m1 -E 'iPhone 1[56]' | grep -oE '[0-9A-F-]{36}' || true)"
  [ -n "$DEV" ] || skip "no available iPhone simulator"
  echo "==> booting simulator $DEV"
  xcrun simctl boot "$DEV"
  BOOTED_HERE=1
  sleep 4
fi

cleanup() {
  xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl uninstall "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true
  [ "$BOOTED_HERE" = 1 ] && xcrun simctl shutdown "$DEV" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> install"
xcrun simctl install "$DEV" "$APP"

echo "==> launch (console)"
LOG="$OUT/launch.log"
xcrun simctl launch --console-pty "$DEV" "$BUNDLE_ID" >"$LOG" 2>&1 || true
echo "--- app console ---"; cat "$LOG"; echo "-------------------"

MISS=0
while IFS= read -r line; do
  grep -Fq "$line" "$LOG" || { echo "missing expected line: $line"; MISS=1; }
done < "$EXPECTED"
[ "$MISS" = 0 ] && echo "PASS ios-app-smoke: bundled program output present" || fail "output mismatch (see $LOG)"
