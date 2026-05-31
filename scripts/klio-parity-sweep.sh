#!/usr/bin/env bash
# Fast parity loop. Builds the sweep binary once, then diffs every corpus +
# examples .kt against kotlinc's cached stdout, in parallel across all cores.
#
# kotlinc and java run only for files whose (staged) source changed since the
# last run — the expected-output cache is keyed by kotlinc version + staged
# content, NOT by klio, so it survives interpreter rebuilds. A warm run after
# an interpreter change therefore spawns neither kotlinc nor java.
#
# Usage: klio-parity-sweep.sh [corpus|examples|all]   (default: all)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cargo build --release -p klio-parity --bin klio-parity ${CARGO_QUIET:+-q}
exec "$ROOT/target/release/klio-parity" --sweep "${1:-all}"
