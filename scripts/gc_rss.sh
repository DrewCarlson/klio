#!/usr/bin/env bash
# Run a program under the tracing GC and report peak RSS, to gauge whether
# memory stays bounded under sustained allocation churn (the flat-RSS goal).
# Usage: scripts/gc_rss.sh <file.kt> [THRESHOLD_KB]
set -u
f="$1"; thresh="${2:-256}"
bin=./zig-out/bin/klio
peak() {
  # /usr/bin/time -l reports "maximum resident set size" in bytes on macOS.
  { /usr/bin/time -l "$@" >/dev/null; } 2>&1 | awk '/maximum resident/ {print int($1/1024/1024)" MB"}'
}
echo "arena   : $(peak $bin run "$f")"
echo "gc(${thresh}KB): $(KLIO_RECLAIM=gc KLIO_GC_THRESHOLD_KB=$thresh peak $bin run "$f")"
echo "free    : $(KLIO_RECLAIM=free peak $bin run "$f")"
