#!/usr/bin/env bash
# Stage-4 gate of plans/c-transpiler-plan.md (git history), parity half: every corpus
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

# ReleaseFast on both sides: the gate compares the interpreter's output against
# a compiled native binary under a wall-clock cap, and a debug interpreter runs
# the compose examples for minutes — they timed out without ever being compared.
zig build -Doptimize=ReleaseFast
zig build klio-rt -Doptimize=ReleaseFast

out=zig-out/transpiler-corpus
rm -rf "$out"
mkdir -p "$out"
export out

# A killed run measured nothing, so it is reported as TIMEOUT — naming the
# phase, the limit, and the command that reproduces it alone. Reported as a
# plain failure it reads as a wrong answer, and a slow machine then looks like
# a broken transpiler (a 6-way parallel run once reported 23 of them).
# An example that needs a pack feature or a language flag says so in a
# `Run with:` line; both sides need it, or the program fails to build and the
# gate reports a wrong answer where there is none.
run_flags() {
    sed -n '1,12p' "$1" | sed -n 's/.*Run with:.*//p' > /dev/null
    sed -n '1,12p' "$1" | grep -o -- '--feature [^ ]*\|--feature=[^ ]*\|--language=[^ ]*' | tr '\n' ' '
}

check_one() {
    local kt="$1"
    local name rc
    name=$(basename "$kt" .kt)
    local flags
    read -r -a flags <<< "$(run_flags "$kt")"
    timeout 600 ./zig-out/bin/klio transpile "${flags[@]}" "$kt" -o "$out/$name.c" > "$out/$name.transpile.log" 2>&1
    rc=$?
    if [ $rc = 124 ]; then
        echo "TIMEOUT transpile" > "$out/$name.status"
        echo "  TIMEOUT $name (transpile, 600s) — rerun: ./zig-out/bin/klio transpile $kt -o /tmp/$name.c"
        return
    fi
    if [ $rc != 0 ]; then
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
    timeout 120 ./zig-out/bin/klio run "${flags[@]}" "$kt" > "$out/$name.interp.out" 2> "$out/$name.interp.err"
    local interp_rc=$?
    timeout 120 "$out/$name" > "$out/$name.native.out" 2> "$out/$name.native.err"
    local native_rc=$?
    if [ $interp_rc = 124 ] || [ $native_rc = 124 ]; then
        local side="interpreter"
        [ $native_rc = 124 ] && side="native binary"
        [ $interp_rc = 124 ] && [ $native_rc = 124 ] && side="both sides"
        echo "TIMEOUT run" > "$out/$name.status"
        echo "  TIMEOUT $name ($side, 120s) — rerun: ./zig-out/bin/klio run $kt   /   $out/$name"
        return
    fi
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
export -f check_one run_flags

ls $pattern | grep -Ev "$skip_re" | xargs -P "$jobs" -I{} bash -c 'check_one "$@"' _ {}

pass=$(grep -lx PASS "$out"/*.status 2>/dev/null | wc -l)
timedout_files=$(grep -l '^TIMEOUT' "$out"/*.status 2>/dev/null)
timedout=$(printf '%s\n' "$timedout_files" | grep -c . )
fail=$(($(grep -L '^PASS$' "$out"/*.status 2>/dev/null | wc -l) - timedout))
if [[ $timedout -gt 0 ]]; then
    echo "TIMED OUT ($timedout): $(printf '%s\n' "$timedout_files" | sed 's|.*/||;s|\.status||' | tr '\n' ' ')"
    echo "  a timeout measured nothing — rerun those alone (JOBS=1) before reading them as failures"
fi
echo "TRANSPILER CORPUS: $pass passed, $fail failed, $timedout timed out"
[[ $fail -eq 0 && $timedout -eq 0 ]] && echo "transpiler-corpus-check ok"
exit $(( (fail + timedout) > 0 ))
