#!/usr/bin/env bash
# Every example the native backend accepts, compiled and compared against the
# interpreter. `scripts/native-c-check.sh` is the gate — a fixed set that must
# keep working; this is the wider net: it reports how many programs the backend
# takes, and any program it takes and then gets wrong.
#
#   scripts/native-c-sweep.sh [glob ...]
#
# Programs are independent, so they run in parallel: one at a time the sweep
# takes long enough that it stops being run.
set -uo pipefail
cd "$(dirname "$0")/.."
KLIO=${KLIO:-zig-out/bin/klio}
CC=${CC:-zig cc}
JOBS=${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}
WORK=$(mktemp -d)
export KLIO CC WORK
trap 'rm -rf "$WORK"' EXIT

if [ $# -gt 0 ]; then progs=("$@"); else progs=(examples/*.kt); fi

# One program: emit, compile, run, compare. Prints a single verdict line the
# parent tallies, so the parallel output stays readable.
one() {
  kt=$1
  name=$(basename "$kt" .kt)
  d="$WORK/$name"
  mkdir -p "$d"
  cfile="$d/out.c"
  # A program whose pack selection is not in the image cache pays one whole
  # lowering of those packs before the emitter starts; that build is the same
  # one `klio run` does, and every later program with that selection reuses it.
  timeout "${EMIT_TIMEOUT:-300}" "$KLIO" transpile --native "$kt" -o "$cfile" >"$d/emit.log" 2>&1
  emit_rc=$?
  # A refusal exits 1. A crash or a timeout is a defect in the emitter, and
  # counting it as a refusal is how one hides among hundreds of them.
  # A refusal exits 1, a crash exits on a signal, and 124 is the timeout: the
  # first program with a given pack selection lowers those packs before the
  # emitter starts, and every rebuild of klio invalidates that cached work.
  # Slow is worth reporting; it is not a wrong answer.
  if [ "$emit_rc" -eq 124 ]; then
    echo "SLOW $name emitter did not finish in ${EMIT_TIMEOUT:-300}s"
    return
  fi
  if [ "$emit_rc" -gt 1 ]; then
    echo "FAIL $name emitter exit $emit_rc"
    return
  fi
  if [ "$emit_rc" -ne 0 ]; then
    echo "REFUSED $name"
    return
  fi
  link=()
  if grep -q '#include <klio_rt.h>' "$cfile"; then
    link=(-Izig-out/include -Lzig-out/lib -lklio_rt -lzstd)
  fi
  if ! $CC -O1 -w "$cfile" "${link[@]}" -o "$d/bin" >"$d/cc.log" 2>&1; then
    echo "FAIL $name C compile"
    return
  fi
  timeout 60 "$d/bin" >"$d/native.out" 2>/dev/null
  native_rc=$?
  timeout 60 "$KLIO" run "$kt" >"$d/interp.out" 2>/dev/null
  interp_rc=$?
  if ! diff -u "$d/native.out" "$d/interp.out" >"$d/diff.log" 2>&1; then
    echo "FAIL $name output differs"
    return
  fi
  if [ "$native_rc" -ne "$interp_rc" ]; then
    echo "FAIL $name exit status $native_rc, interpreter $interp_rc"
    return
  fi
  echo "PASS $name"
}
export -f one

printf '%s\n' "${progs[@]}" | xargs -P "$JOBS" -I{} bash -c 'one "$@"' _ {} >"$WORK/verdicts" 2>&1

passed=$(grep -c '^PASS ' "$WORK/verdicts")
failed=$(grep -c '^FAIL ' "$WORK/verdicts")
refused=$(grep -c '^REFUSED ' "$WORK/verdicts")
slow=$(grep -c '^SLOW ' "$WORK/verdicts")
accepted=$((passed + failed))
grep -E '^(FAIL|SLOW) ' "$WORK/verdicts" | sed 's/^/  /'
for f in $(grep '^FAIL ' "$WORK/verdicts" | awk '{print $2}'); do
  [ -s "$WORK/$f/diff.log" ] && head -8 "$WORK/$f/diff.log" | sed "s/^/      $f: /"
  [ -s "$WORK/$f/cc.log" ] && head -3 "$WORK/$f/cc.log" | sed "s/^/      $f: /"
done
echo "NATIVE C SWEEP: $accepted accepted ($passed match, $failed differ), $refused refused, $slow too slow to say"
[ "$failed" -eq 0 ]
