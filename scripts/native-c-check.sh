#!/usr/bin/env bash
# Gate for `klio transpile --native`: every program the backend accepts must
# compile warning-clean and print exactly what the interpreter prints. A
# compiled program has no interpreter to fall back into, so a divergence here is
# a wrong answer, not a slow path.
#
#   scripts/native-c-check.sh [program.kt ...]
#
# With no arguments it checks every example the backend accepts, and reports the
# ones it refuses (that list is the backlog for widening it).
set -uo pipefail
cd "$(dirname "$0")/.."
KLIO=${KLIO:-zig-out/bin/klio}
CC=${CC:-zig cc}
WORK=${WORK:-$(mktemp -d)}
trap 'rm -rf "$WORK"' EXIT

# Explicit arguments are an exploration: a refusal there is information. The
# default set is the gate: every one of those must compile and match, so a
# refusal is a regression.
strict=1
if [ $# -gt 0 ]; then
  progs=("$@")
  strict=0
else
  progs=(examples/native_scalar_core.kt examples/native_objects.kt examples/native_strings.kt examples/native_collections.kt)
fi

pass=0
fail=0
refused=0
for kt in "${progs[@]}"; do
  name=$(basename "$kt" .kt)
  cfile="$WORK/$name.c"
  if ! "$KLIO" transpile --native "$kt" -o "$cfile" >"$WORK/emit.log" 2>&1; then
    refused=$((refused + 1))
    echo "  REFUSED $name: $(grep -m1 -oE 'refuse .*' "$WORK/emit.log" || tail -1 "$WORK/emit.log")"
    continue
  fi
  # A program that only computes needs nothing; one that allocates links the
  # runtime for its collector and object model.
  link=()
  if grep -q '#include <klio_rt.h>' "$cfile"; then
    link=(-Izig-out/include -Lzig-out/lib -lklio_rt -lzstd)
  fi
  if ! $CC -O2 -Wall -Wextra -Werror "$cfile" "${link[@]}" -o "$WORK/$name" >"$WORK/cc.log" 2>&1; then
    fail=$((fail + 1))
    echo "  FAIL $name: C compile"
    head -5 "$WORK/cc.log" | sed 's/^/      /'
    continue
  fi
  if ! diff -u <("$WORK/$name") <("$KLIO" run "$kt" 2>&1) >"$WORK/diff.log" 2>&1; then
    fail=$((fail + 1))
    echo "  FAIL $name: output differs from the interpreter"
    head -10 "$WORK/diff.log" | sed 's/^/      /'
    continue
  fi
  # A compiled program roots its references by publishing frames, and the
  # collector never scans the native stack: collecting at every safe point is
  # what proves a live reference is actually published.
  if [ ${#link[@]} -ne 0 ]; then
    if ! diff -u <(KLIO_GC_STRESS=1 "$WORK/$name") <("$KLIO" run "$kt" 2>&1) >"$WORK/gc.log" 2>&1; then
      fail=$((fail + 1))
      echo "  FAIL $name: differs under GC stress (a live reference is not rooted)"
      head -10 "$WORK/gc.log" | sed 's/^/      /'
      continue
    fi
  fi
  pass=$((pass + 1))
done

echo "NATIVE C: $pass passed, $fail failed, $refused refused"
if [ "$strict" -eq 1 ] && [ "$refused" -ne 0 ]; then
  echo "  a program in the gate set stopped compiling"
  exit 1
fi
[ "$fail" -eq 0 ]
