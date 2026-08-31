#!/usr/bin/env bash
# Build the wide library leaf pack (plans/leaf-production-campaign.md):
# every pure-scalar body on the kotlin.* / kotlinx.* surfaces, emitted
# as a self-contained shared library the interpreter loads via
# KLIO_LEAVES. Keyed fqn#sig, bake-independent; the loader and the
# gate are fail-open, so a stale or missing artifact only loses the
# speedup, never correctness. Rebuilt from the CURRENT tree every
# invocation (~1 min): leaves compiled from other code must never
# serve this tree's bodies.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${LEAF_BIN:-zig-out/bin/klio-harness}"
OUT_DIR="${1:-.klio-local/leaves}"
mkdir -p "$OUT_DIR"
export KLIO_HOME="$PWD/.klio-local"
s=$(date +%s)
if ! KLIO_TRANSPILE_LEAVES=1 KLIO_TRANSPILE_PKGS=kotlin.,kotlinx. \
    "$BIN" transpile tests/leaf_probes/library.kt -o "$OUT_DIR/library.c" \
    >/tmp/leaf-pack-build.log 2>&1; then
  echo "build-leaf-packs: transpile FAILED (see /tmp/leaf-pack-build.log)"
  exit 1
fi
if ! zig cc -shared -fPIC "$OUT_DIR/library.c" -Izig-out/include -o "$OUT_DIR/library.so" 2>>/tmp/leaf-pack-build.log; then
  echo "build-leaf-packs: cc FAILED (see /tmp/leaf-pack-build.log)"
  exit 1
fi
e=$(date +%s)
n=$(grep -c '^static int32_t kl_' "$OUT_DIR/library.c" || echo 0)
echo "build-leaf-packs: $OUT_DIR/library.so ($n leaves) wall=$((e-s))s"
