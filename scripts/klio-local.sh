#!/usr/bin/env bash
# Run klio against a repo-local .klio data home (KLIO_HOME) instead of the shared
# ~/.klio, so dev pack builds/installs, the stdlib image cache, and the registry
# stay inside the (gitignored) .klio-local/ folder and never clobber another
# workstream's packs. All klio subcommands honor KLIO_HOME.
#
#   scripts/klio-local.sh run app.kt
#   scripts/klio-local.sh pack build kotlin-klio/klio-androidx-collection
#   scripts/klio-local.sh pack install target/packs/androidx.collection.klio-pack
#
# To (re)build the shipped packs from source into the local home so source edits
# take effect, run the canonical installer against this home:
#   KLIO_HOME="$PWD/.klio-local" bash scripts/bootstrap.sh --packs --no-build
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export KLIO_HOME="$(pwd)/.klio-local"
mkdir -p "$KLIO_HOME"
KLIO="${KLIO_BIN:-zig-out/bin/klio}"
[ -x "$KLIO" ] || { echo "build klio first: zig build"; exit 1; }
exec "$KLIO" "$@"
