#!/usr/bin/env bash
# Stage-1 gate of plans/c-transpiler-plan.md: a plain C host drives the
# klio runtime end to end through the C ABI static library.
set -euo pipefail
cd "$(dirname "$0")/.."
zig build klio-rt
zig cc tests/transpiler/boot.c -Izig-out/include -Lzig-out/lib -lklio_rt -lzstd -o zig-out/boot
out=$(./zig-out/boot examples/hello.kt)
echo "$out"
echo "$out" | grep -q '^2$' && echo "boot-check ok"
