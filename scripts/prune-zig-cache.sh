#!/usr/bin/env bash
# Prune stale .zig-cache entries. The cache has no GC and accumulates tens
# of GB per day of iteration (each whole-program rebuild emits a fresh
# object set); CI already wipes past 5 GB. Zig cache entries self-validate,
# so partial deletion is always safe — a deleted entry that was still live
# is recomputed on the next build (that recompute is the only churn).
#
# Two passes:
#   1. Age: entries older than DAYS are removed (hits do not reliably
#      refresh o/ or h/ mtimes, so age is a proxy, not truth).
#   2. Size target: if the cache still exceeds TARGET_GB, oldest o/ dirs
#      go first until it fits — but nothing younger than 6 hours is ever
#      touched, so the current session's hot set survives both passes.
#
# Usage: prune-zig-cache.sh [days] [target_gb]   (default: 2, 60)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAYS="${1:-2}"
TARGET_GB="${2:-60}"
CACHE="$ROOT/.zig-cache"
[ -d "$CACHE" ] || { echo "no cache at $CACHE"; exit 0; }

# -x: match the zig binary itself, not wrappers whose command line
# happens to contain the words (a pgrep -f self-match cost one run).
if pgrep -x zig >/dev/null 2>&1; then
  echo "refusing to prune: a zig process is running" >&2
  exit 1
fi

before=$(du -sh "$CACHE" | cut -f1)

# Pass 1: age.
find "$CACHE/o" -mindepth 1 -maxdepth 1 -type d -mtime "+$DAYS" -exec rm -rf {} + 2>/dev/null || true
find "$CACHE/h" -type f -mtime "+$DAYS" -delete 2>/dev/null || true
rm -rf "$CACHE/tmp"/* 2>/dev/null || true

# Pass 2: size target, oldest first, sparing the last 6 hours.
target_bytes=$((TARGET_GB * 1000000000))
used=$(du -sb "$CACHE/o" | cut -f1)
if [ "$used" -gt "$target_bytes" ]; then
  excess=$((used - target_bytes))
  freed=0
  while IFS=$'\t' read -r _mtime dir; do
    [ "$freed" -ge "$excess" ] && break
    sz=$(du -sb "$dir" 2>/dev/null | cut -f1) || continue
    rm -rf "$dir" 2>/dev/null || continue
    freed=$((freed + sz))
  done < <(find "$CACHE/o" -mindepth 1 -maxdepth 1 -type d -mmin +360 -printf '%T@\t%p\n' 2>/dev/null | sort -n)
fi

after=$(du -sh "$CACHE" | cut -f1)
echo "pruned .zig-cache (> ${DAYS}d, target ${TARGET_GB}G): $before -> $after"
