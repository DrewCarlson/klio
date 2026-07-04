#!/usr/bin/env bash
# Prune stale .zig-cache entries. The cache has no GC and accumulates tens
# of GB per day of iteration (each whole-program rebuild emits a fresh
# object set); CI already wipes past 5 GB. Entries older than the cutoff
# are removed; anything still referenced is recomputed on the next build
# (zig cache entries self-validate, so partial deletion is always safe —
# the first build after a prune pays a one-time revalidation pass).
#
# Usage: prune-zig-cache.sh [days]   (default: 2)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAYS="${1:-2}"
CACHE="$ROOT/.zig-cache"
[ -d "$CACHE" ] || { echo "no cache at $CACHE"; exit 0; }

before=$(du -sh "$CACHE" | cut -f1)
find "$CACHE/o" -maxdepth 1 -type d -mtime "+$DAYS" -exec rm -rf {} + 2>/dev/null || true
find "$CACHE/h" -type f -mtime "+$DAYS" -delete 2>/dev/null || true
rm -rf "$CACHE/tmp"/* 2>/dev/null || true
after=$(du -sh "$CACHE" | cut -f1)
echo "pruned .zig-cache (> ${DAYS}d): $before -> $after"
