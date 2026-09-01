#!/usr/bin/env bash
# Build every shipped klio pack from source and install it into the repo-local
# KLIO_HOME (.klio-local/), so `scripts/klio-local.sh run ...` picks up source
# edits to pack Kotlin without rebuilding the interpreter or touching the shared
# ~/.klio. Installed packs shadow the interpreter's embedded copies.
#
# This is the pack-install half of scripts/bootstrap.sh --packs, without its
# submodule/sparse-checkout setup (assumes sources are already present): same
# source-provider skip and dependency-ordered retry so a pack that needs another
# installed first still lands.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export KLIO_HOME="$(pwd)/.klio-local"
mkdir -p "$KLIO_HOME"
KLIO="${KLIO_BIN:-zig-out/bin/klio}"
[ -x "$KLIO" ] || { echo "build klio first: zig build"; exit 1; }

# Source-provider dirs share a pack id with a sibling and would clobber the real
# (complete) pack; skip them (see scripts/bootstrap.sh).
skip_pack_dir() { case "$1" in kotlin-klio/klio-compose-runtime) return 0 ;; *) return 1 ;; esac; }

# PACK_FILTER=<comma-separated dir-basename prefixes>: build only the
# matching packs (the compose-ui gate trims to the compose closure).
pack_dirs=()
for d in kotlin-klio/*/; do
  d="${d%/}"; [ -f "$d/klio.toml" ] || continue
  skip_pack_dir "$d" && continue
  if [ -n "${PACK_FILTER:-}" ]; then
    base="${d#kotlin-klio/}"
    keep=0
    IFS=',' read -ra pfx <<< "$PACK_FILTER"
    for x in "${pfx[@]}"; do
      case "$base" in "$x"*) keep=1 ;; esac
    done
    [ $keep = 1 ] || continue
  fi
  pack_dirs+=("$d")
done
remaining=("${pack_dirs[@]}")

while [ "${#remaining[@]}" -gt 0 ]; do
  progressed=0; next=()
  for d in "${remaining[@]}"; do
    if out="$("$KLIO" pack build "$d" 2>&1)"; then
      pack_file="$(printf '%s\n' "$out" | grep -oE 'target/packs/[^ ]+\.klio-pack' | tail -1)"
      if [ -n "$pack_file" ] && "$KLIO" pack install "$pack_file" >/dev/null 2>&1; then
        echo "ok   $(basename "$d")"; progressed=1; continue
      fi
    fi
    next+=("$d")
  done
  remaining=("${next[@]}")
  [ "$progressed" -eq 0 ] && break
done
echo "---"
if [ "${#remaining[@]}" -gt 0 ]; then
  echo "FAILED (deps unmet or build error): ${remaining[*]}"
  echo "re-run '$KLIO pack build <dir>' on one to see why"
  exit 1
fi
echo "all packs installed into $KLIO_HOME/.klio/packs"
