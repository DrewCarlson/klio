#!/usr/bin/env bash
# Headless mobile-runtime smoke: build the interpreter for a mobile target, run a
# deterministic Kotlin program on the simulator/emulator, and assert its output
# matches the desktop baseline. Skips cleanly (exit 0) when the platform's device
# tooling is unavailable, so it is safe to run anywhere.
#
# Usage:
#   scripts/mobile-smoke.sh          # ios simulator (default)
#   scripts/mobile-smoke.sh ios
#   scripts/mobile-smoke.sh android  # android emulator (pending)
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

PLATFORM="${1:-ios}"
FIXTURE="tests/fixtures/mobile_smoke/smoke.kt"
EXPECTED="tests/fixtures/mobile_smoke/smoke.expected"

skip() { echo "SKIP mobile-smoke ($PLATFORM): $1"; exit 0; }
fail() { echo "FAIL mobile-smoke ($PLATFORM): $1"; exit 1; }

case "$PLATFORM" in
ios)
  command -v xcrun >/dev/null 2>&1 || skip "xcrun not found"
  echo "==> build klio for aarch64-ios-simulator"
  zig build -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseFast
  BIN="$PWD/zig-out/bin/klio-ios-sim"
  [ -x "$BIN" ] || fail "expected $BIN"

  DEV="$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
  BOOTED_HERE=0
  if [ -z "$DEV" ]; then
    DEV="$(xcrun simctl list devices available | grep -m1 -E 'iPhone 1[56]' | grep -oE '[0-9A-F-]{36}' || true)"
    [ -n "$DEV" ] || skip "no available iPhone simulator"
    echo "==> booting simulator $DEV"
    xcrun simctl boot "$DEV"
    BOOTED_HERE=1
    # settle
    for _ in $(seq 1 20); do
      xcrun simctl list devices booted | grep -q "$DEV" && break
      sleep 0.5
    done
  fi

  echo "==> run on simulator $DEV"
  OUT="$(xcrun simctl spawn "$DEV" "$BIN" run "$PWD/$FIXTURE" 2>&1)" || {
    [ "$BOOTED_HERE" = 1 ] && xcrun simctl shutdown "$DEV" >/dev/null 2>&1 || true
    fail "interpreter exited nonzero:
$OUT"
  }
  [ "$BOOTED_HERE" = 1 ] && xcrun simctl shutdown "$DEV" >/dev/null 2>&1 || true

  if diff <(printf '%s\n' "$OUT") "$EXPECTED" >/dev/null; then
    echo "PASS mobile-smoke (ios): output matches baseline"
  else
    echo "--- expected ---"; cat "$EXPECTED"
    echo "--- got ---"; printf '%s\n' "$OUT"
    fail "output mismatch vs $EXPECTED"
  fi
  ;;
android)
  skip "android emulator smoke not wired yet"
  ;;
*)
  fail "unknown platform '$PLATFORM' (expected: ios | android)"
  ;;
esac
