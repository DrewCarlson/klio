#!/usr/bin/env bash
# Every example the native backend accepts, compiled and compared against the
# interpreter. `scripts/native-c-check.sh` is the gate — a fixed set that must
# keep working; this is the wider net: it reports how many programs the backend
# takes, and any program it takes and then gets wrong.
#
#   scripts/native-c-sweep.sh [glob ...]
set -uo pipefail
cd "$(dirname "$0")/.."
KLIO=${KLIO:-zig-out/bin/klio}
CC=${CC:-zig cc}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ $# -gt 0 ]; then progs=("$@"); else progs=(examples/*.kt); fi

accepted=0
passed=0
refused=0
failed=0
for kt in "${progs[@]}"; do
  name=$(basename "$kt" .kt)
  cfile="$WORK/$name.c"
  if ! timeout 60 "$KLIO" transpile --native "$kt" -o "$cfile" >/dev/null 2>&1; then
    refused=$((refused + 1))
    continue
  fi
  accepted=$((accepted + 1))
  link=()
  if grep -q '#include <klio_rt.h>' "$cfile"; then
    link=(-Izig-out/include -Lzig-out/lib -lklio_rt -lzstd)
  fi
  if ! $CC -O1 -w "$cfile" "${link[@]}" -o "$WORK/$name" >"$WORK/cc.log" 2>&1; then
    failed=$((failed + 1))
    echo "  FAIL $name: C compile"
    head -3 "$WORK/cc.log" | sed 's/^/      /'
    continue
  fi
  timeout 60 "$WORK/$name" >"$WORK/native.out" 2>/dev/null
  native_rc=$?
  timeout 60 "$KLIO" run "$kt" >"$WORK/interp.out" 2>/dev/null
  interp_rc=$?
  if ! diff -u "$WORK/native.out" "$WORK/interp.out" >"$WORK/diff.log" 2>&1; then
    failed=$((failed + 1))
    echo "  FAIL $name: output differs"
    head -8 "$WORK/diff.log" | sed 's/^/      /'
    continue
  fi
  if [ "$native_rc" -ne "$interp_rc" ]; then
    failed=$((failed + 1))
    echo "  FAIL $name: exit status $native_rc, interpreter $interp_rc"
    continue
  fi
  passed=$((passed + 1))
done

echo "NATIVE C SWEEP: $accepted accepted ($passed match, $failed differ), $refused refused"
[ "$failed" -eq 0 ]
