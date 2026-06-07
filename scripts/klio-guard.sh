#!/usr/bin/env bash
# Run a single .kt through the klio binary under a hard RSS + wall-clock
# cap, killing the process the instant either limit is exceeded. A
# runaway allocation (eager materialization, swallowed-effect infinite
# loop) can therefore never exhaust system memory during development.
#
# Usage: klio-guard.sh <file.kt> [rss_cap_kb] [timeout_s] [klio_bin]
# Exit: the program's exit code, or 137 (killed) on OOM/timeout.
# Stderr trailer: "[guard] reason=<exited|OOM|TIMEOUT> exit=<n> peakRSS=<kb>KB"
set -u
FILE="${1:?usage: klio-guard.sh <file.kt> [rss_cap_kb] [timeout_s] [klio_bin]}"
CAP_KB="${2:-1500000}"
TIMEOUT_S="${3:-15}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${4:-$ROOT/target/release/klio}"
[ -x "$BIN" ] || BIN="$ROOT/target/debug/klio"

OUT="$(mktemp)"
"$BIN" run "$FILE" >"$OUT" 2>&1 &
PID=$!
PEAK=0
TICKS=0
REASON="exited"
while kill -0 "$PID" 2>/dev/null; do
  RSS=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
  if [ -n "${RSS:-}" ]; then
    [ "$RSS" -gt "$PEAK" ] && PEAK="$RSS"
    if [ "$RSS" -gt "$CAP_KB" ]; then
      kill -9 "$PID" 2>/dev/null; REASON="OOM(${RSS}KB>${CAP_KB}KB)"; break
    fi
  fi
  TICKS=$((TICKS + 1))
  if [ "$TICKS" -gt $((TIMEOUT_S * 10)) ]; then
    kill -9 "$PID" 2>/dev/null; REASON="TIMEOUT(${TIMEOUT_S}s)"; break
  fi
  sleep 0.1
done
wait "$PID" 2>/dev/null
RC=$?
cat "$OUT"
echo "[guard] reason=$REASON exit=$RC peakRSS=${PEAK}KB" >&2
rm -f "$OUT"
exit "$RC"
