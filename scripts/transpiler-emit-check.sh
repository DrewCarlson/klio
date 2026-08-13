#!/usr/bin/env bash
# Stage-2 gate of plans/c-transpiler-plan.md: `klio transpile` emits C over
# the klio_rt per-op helpers, the result compiles and links against
# libklio_rt.a, its output matches the interpreter, and the native bodies
# actually engage (KLIO_NATIVE_TRACE).
set -euo pipefail
cd "$(dirname "$0")/.."
zig build
zig build klio-rt

check() {
    local kt="$1" name="$2"
    ./zig-out/bin/klio transpile "$kt" -o "zig-out/$name.c"
    zig cc "zig-out/$name.c" -Izig-out/include -Lzig-out/lib -lklio_rt -lzstd -o "zig-out/$name-native"
    ./zig-out/bin/klio run "$kt" > "zig-out/$name.interp.out" 2>&1
    "./zig-out/$name-native" > "zig-out/$name.native.out" 2>&1
    if ! diff -u "zig-out/$name.interp.out" "zig-out/$name.native.out"; then
        echo "$name: PARITY FAIL"
        exit 1
    fi
    if ! KLIO_NATIVE_TRACE=1 "./zig-out/$name-native" 2>&1 | grep -q '^\[native\] fn=main'; then
        echo "$name: native body never engaged"
        exit 1
    fi
    echo "$name: parity + native engagement ok"
}

check examples/hello.kt hello
check tests/transpiler/stage2.kt stage2
echo "transpiler-emit-check ok"
