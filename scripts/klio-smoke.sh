#!/usr/bin/env bash
# Fast klio-only smoke sweep: run every example + corpus .kt through the
# prebuilt klio binary under a memory/time guard, in parallel, and
# report which files crash, error, OOM, or time out. No cargo rebuild,
# no kotlinc — a seconds-scale signal for the crash/OOM/regression bug
# class that the kotlinc-diff parity suite is too slow to iterate on.
#
# Usage: klio-smoke.sh [dir ...]   (default: examples + the parity corpus)
# Env:   RSS_CAP_KB (default 1200000), TIMEOUT_S (default 12),
#        JOBS (default: CPU count), KLIO_BIN (default target/release/klio)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RSS_CAP_KB="${RSS_CAP_KB:-1200000}"
TIMEOUT_S="${TIMEOUT_S:-12}"
JOBS="${JOBS:-$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
KLIO_BIN="${KLIO_BIN:-$ROOT/target/release/klio}"
[ -x "$KLIO_BIN" ] || KLIO_BIN="$ROOT/target/debug/klio"
GUARD="$ROOT/scripts/klio-guard.sh"

if [ "$#" -gt 0 ]; then DIRS=("$@"); else
  DIRS=("$ROOT/examples" "$ROOT/crates/klio-parity/tests/corpus")
fi

RESULTS="$(mktemp)"
list_files() { for d in "${DIRS[@]}"; do [ -d "$d" ] && find "$d" -name '*.kt'; done; }

check_one() {
  local f="$1"
  local out rc reason
  out="$("$GUARD" "$f" "$RSS_CAP_KB" "$TIMEOUT_S" "$KLIO_BIN" 2>/tmp/.klio_smoke_err.$$ )"
  rc=$?
  reason="$(grep -oE 'reason=[^ ]+' /tmp/.klio_smoke_err.$$ | head -1 | cut -d= -f2)"
  rm -f /tmp/.klio_smoke_err.$$
  if [ "$rc" -eq 0 ]; then echo "PASS|$f"
  elif [ "${reason:-}" = "OOM(${RSS_CAP_KB}KB>${RSS_CAP_KB}KB)" ] || echo "${reason:-}" | grep -q '^OOM'; then echo "OOM|$f"
  elif echo "${reason:-}" | grep -q '^TIMEOUT'; then echo "TIMEOUT|$f"
  else echo "ERROR|$f"; fi
}
export -f check_one
export GUARD RSS_CAP_KB TIMEOUT_S KLIO_BIN

list_files | sort | xargs -P "$JOBS" -I{} bash -c 'check_one "$@"' _ {} >"$RESULTS"

total=$(wc -l <"$RESULTS" | tr -d ' ')
pass=$(grep -c '^PASS|' "$RESULTS")
echo "=== klio smoke: $pass/$total passed (cap ${RSS_CAP_KB}KB, ${TIMEOUT_S}s, ${JOBS} jobs) ==="
for cat in OOM TIMEOUT ERROR; do
  n=$(grep -c "^$cat|" "$RESULTS")
  if [ "$n" -gt 0 ]; then
    echo "--- $cat ($n) ---"
    grep "^$cat|" "$RESULTS" | cut -d'|' -f2- | sed "s|$ROOT/||"
  fi
done
rm -f "$RESULTS"
[ "$pass" -eq "$total" ]
