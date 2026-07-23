#!/usr/bin/env bash
# Headless Android smoke: cross-compile the interpreter to aarch64-linux-android,
# link a tiny native host (NDK clang, bionic libc) against libklio-android.a, and
# run a Kotlin program on the emulator via `adb shell` — asserting byte-identical
# output. Proves the interpreter runs on Android (the on-screen APK host lands in
# a later step). Skips cleanly without the NDK / an emulator.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

FIXTURE="tests/fixtures/mobile_smoke/smoke.kt"
EXPECTED="tests/fixtures/mobile_smoke/smoke.expected"
API="${ANDROID_API:-24}"

skip() { echo "SKIP android-smoke: $1"; exit 0; }
fail() { echo "FAIL android-smoke: $1"; exit 1; }

SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
[ -x "$ADB" ] || skip "adb not found ($ADB)"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$SDK"/ndk/*/ 2>/dev/null | sort | tail -1)}"
NDK="${NDK%/}"
[ -n "$NDK" ] && [ -d "$NDK" ] || skip "Android NDK not found under $SDK/ndk"
TOOL="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
CLANG="$TOOL/aarch64-linux-android${API}-clang"
[ -x "$CLANG" ] || skip "NDK clang not found ($CLANG)"

echo "==> cross-compile interpreter for aarch64-linux-android"
zig build mobile-lib -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast -Dandroid-api="$API"
LIB="$(pwd)/zig-out/lib/libklio-android.a"
ZSTD="$(pwd)/zig-out/lib/libzstd-android.a"
for f in "$LIB" "$ZSTD"; do [ -f "$f" ] || fail "expected $f"; done

echo "==> link native host (NDK clang, bionic)"
OUT="${ANDROID_OUT:-$(pwd)/zig-out/android-host}"
mkdir -p "$OUT"
# -fno-emulated-tls: a native, 64-byte-aligned thread-local in the host raises the
# executable's TLS segment alignment to what ARM64 bionic requires.
"$CLANG" -O2 -fPIE -pie -fno-emulated-tls mobile/android/host/android_main.c \
  "$LIB" "$ZSTD" -llog -lm -o "$OUT/klio-host"
[ -f "$OUT/klio-host" ] || fail "host did not link"

DEV="$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')"
[ -n "$DEV" ] || skip "no booted emulator/device (adb devices)"

echo "==> push + run on $DEV"
"$ADB" -s "$DEV" push "$OUT/klio-host" /data/local/tmp/klio-host >/dev/null
"$ADB" -s "$DEV" push "$FIXTURE" /data/local/tmp/smoke.kt >/dev/null
"$ADB" -s "$DEV" shell "chmod +x /data/local/tmp/klio-host"
GOT="$("$ADB" -s "$DEV" shell "cd /data/local/tmp && HOME=/data/local/tmp ./klio-host run smoke.kt" | tr -d '\r')"
echo "--- output ---"; echo "$GOT"; echo "--------------"

WANT="$(cat "$EXPECTED")"
if [ "$GOT" = "$WANT" ]; then
  echo "PASS android-smoke: interpreter ran on Android with byte-identical output"
else
  echo "--- expected ---"; echo "$WANT"
  fail "output mismatch"
fi
