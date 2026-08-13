#!/usr/bin/env bash
# Stage-4 gate of plans/c-transpiler-plan.md, parity half: every corpus
# example transpiles, compiles against libklio_rt.a, and its output matches
# the interpreter. Interactive/window examples (no deterministic output) and
# the known time-only heavies are skipped — same exclusions as the corpus
# baseline. Usage: transpiler-corpus-check.sh [pattern]
set -uo pipefail
cd "$(dirname "$0")/.."

pattern="${1:-examples/*.kt}"
skip_re='compose_ui_dashboard|compose_ui_input|compose_ui_window|compose_window|compose_multiwindow|compose_foundation_lazy'

zig build
zig build klio-rt

out=zig-out/transpiler-corpus
mkdir -p "$out"
pass=0; fail=0; skipped=0; failed_names=()
for kt in $pattern; do
    name=$(basename "$kt" .kt)
    if [[ "$name" =~ $skip_re ]]; then skipped=$((skipped+1)); continue; fi
    if ! timeout 120 ./zig-out/bin/klio transpile "$kt" -o "$out/$name.c" > "$out/$name.transpile.log" 2>&1; then
        echo "  FAIL $name (transpile)"; fail=$((fail+1)); failed_names+=("$name"); continue
    fi
    if ! zig cc "$out/$name.c" -Izig-out/include -Lzig-out/lib -lklio_rt -lzstd -o "$out/$name" 2> "$out/$name.cc.log"; then
        echo "  FAIL $name (cc)"; fail=$((fail+1)); failed_names+=("$name"); continue
    fi
    timeout 120 ./zig-out/bin/klio run "$kt" > "$out/$name.interp.out" 2>&1
    interp_rc=$?
    timeout 120 "$out/$name" > "$out/$name.native.out" 2>&1
    native_rc=$?
    if [[ $interp_rc -ne $native_rc ]] || ! diff -q "$out/$name.interp.out" "$out/$name.native.out" > /dev/null; then
        echo "  FAIL $name (parity: interp rc=$interp_rc native rc=$native_rc)"
        fail=$((fail+1)); failed_names+=("$name"); continue
    fi
    pass=$((pass+1))
done
echo "TRANSPILER CORPUS: $pass passed, $fail failed, $skipped skipped"
[[ $fail -eq 0 ]] && echo "transpiler-corpus-check ok"
exit $((fail > 0))
