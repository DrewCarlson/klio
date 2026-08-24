#!/usr/bin/env bash
# Stage-4 gate of plans/c-transpiler-plan.md, parity half: every corpus
# example transpiles, compiles against libklio_rt.a, and its output matches
# the interpreter (rc + bytes). Runs JOBS examples in parallel (default 8).
# Interactive/window examples (no deterministic output) and the known
# time-only heavies are skipped — same exclusions as the corpus baseline.
# Usage: transpiler-corpus-check.sh [pattern]   (JOBS=n to override)
set -uo pipefail
cd "$(dirname "$0")/.."

pattern="${1:-examples/*.kt}"
jobs="${JOBS:-8}"
skip_re='compose_ui_dashboard|compose_ui_input|compose_ui_window|compose_window|compose_multiwindow|compose_foundation_lazy'

zig build
zig build klio-rt

out=zig-out/transpiler-corpus
rm -rf "$out"
mkdir -p "$out"
export out

check_one() {
    local kt="$1"
    local name
    name=$(basename "$kt" .kt)
    if ! timeout 600 ./zig-out/bin/klio transpile "$kt" -o "$out/$name.c" > "$out/$name.transpile.log" 2>&1; then
        echo "FAIL transpile" > "$out/$name.status"; echo "  FAIL $name (transpile)"; return
    fi
    if ! zig cc "$out/$name.c" -Izig-out/include -Lzig-out/lib -lklio_rt -lzstd -o "$out/$name" 2> "$out/$name.cc.log"; then
        echo "FAIL cc" > "$out/$name.status"; echo "  FAIL $name (cc)"; return
    fi
    # stdout compares byte-strict; stderr compares with lowering
    # `warning:` lines removed — the native binary runs its PINNED image
    # (no lowering pass), so those warnings legitimately appear only on
    # the interpreter side. Runtime errors still differ loudly (rc +
    # remaining stderr lines).
    timeout 120 ./zig-out/bin/klio run "$kt" > "$out/$name.interp.out" 2> "$out/$name.interp.err"
    local interp_rc=$?
    timeout 120 "$out/$name" > "$out/$name.native.out" 2> "$out/$name.native.err"
    local native_rc=$?
    grep -v '^warning: ' "$out/$name.interp.err" > "$out/$name.interp.err.f" || true
    grep -v '^warning: ' "$out/$name.native.err" > "$out/$name.native.err.f" || true
    if [[ $interp_rc -ne $native_rc ]] ||
        ! diff -q "$out/$name.interp.out" "$out/$name.native.out" > /dev/null ||
        ! diff -q "$out/$name.interp.err.f" "$out/$name.native.err.f" > /dev/null; then
        echo "FAIL parity" > "$out/$name.status"
        echo "  FAIL $name (parity: interp rc=$interp_rc native rc=$native_rc)"; return
    fi
    echo "PASS" > "$out/$name.status"
}
export -f check_one

ls $pattern | grep -Ev "$skip_re" | xargs -P "$jobs" -I{} bash -c 'check_one "$@"' _ {}

pass=$(grep -lx PASS "$out"/*.status 2>/dev/null | wc -l)
fail=$(grep -L '^PASS$' "$out"/*.status 2>/dev/null | wc -l)
echo "TRANSPILER CORPUS: $pass passed, $fail failed"
[[ $fail -eq 0 ]] && echo "transpiler-corpus-check ok"
exit $((fail > 0))
