#!/usr/bin/env bash
# A/B one lowering change across the examples corpus from a SINGLE binary.
#
#   scripts/examples-ab.sh KLIO_SOME_GATE[=0] [more gates...]
#
# Runs every example twice — once as built, once with the named gates set to
# the value given (default `0`) — and reports the examples whose output
# differs. A lowering change that is meant to be behaviour-preserving should
# produce no output at all.
#
# Why one binary rather than two checkouts: a second build plus a second
# worktree costs more than the run itself, and rebuilding `klio-harness` while
# a two-binary comparison is in flight silently compares different binaries.
# Gate the change on a `KLIO_*` variable that defaults ON and it stays as a
# documented diagnostic afterwards.
#
# EXCLUDED below: examples that never terminate. Each blocks on a window or
# event loop at ~0% CPU and is not a regression — they hang identically at
# older commits. Left in, each one costs 2x the timeout for zero signal, and
# twelve of them turn a ten-minute comparison into a three-hour one.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

BIN=${BIN:-zig-out/bin/klio-harness}
TIMEOUT=${TIMEOUT:-60}

NEVER_TERMINATES="compose_foundation compose_foundation_draw \
compose_foundation_lazy compose_layout compose_material3 \
compose_material3_text compose_multiwindow compose_ui_dashboard \
compose_ui_input compose_ui_window compose_window select_on_timeout_loses"
# One line, space separated: the membership test below matches on surrounding
# SPACES, so a newline-separated list silently matches nothing.

if [ $# -eq 0 ]; then
  echo "usage: $0 KLIO_GATE[=value] [more gates...]" >&2
  exit 2
fi

ENVARGS=()
for g in "$@"; do
  case "$g" in
    *=*) ENVARGS+=("$g") ;;
    *) ENVARGS+=("$g=0") ;;
  esac
done

diffs=0
checked=0
for f in examples/*.kt; do
  b=$(basename "$f" .kt)
  case " $NEVER_TERMINATES " in *" $b "*) continue ;; esac
  on=$(timeout "$TIMEOUT" "$BIN" run "$f" 2>&1)
  off=$(timeout "$TIMEOUT" env "${ENVARGS[@]}" "$BIN" run "$f" 2>&1)
  checked=$((checked + 1))
  if [ "$on" != "$off" ]; then
    echo "AB-DIFF $b"
    diffs=$((diffs + 1))
  fi
done
echo "== examples A/B: $checked compared, $diffs differing"
# `serial_names` differs on a warm pack cache and agrees cold. Re-check any
# reported diff with two fresh HOME dirs before believing it.
