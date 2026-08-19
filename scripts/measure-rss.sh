#!/usr/bin/env bash
# Peak-RSS sampler for one command. Use this instead of hand-rolling a
# `pgrep` + `while kill -0` loop.
#
#   scripts/measure-rss.sh [--interval S] [--max-wall S] -- <cmd> [args...]
#
# Prints, on one line:
#   PEAK_KB=<n> RC=<rc> WALL=<s>
#
# WHY THIS EXISTS. The obvious inline version is wrong in a way that does
# not show up until hours later:
#
#   ( <cmd> ) &                                   # child in background
#   TP=$(pgrep -f "<name>" | head -1)             # BUG 1: self-match
#   while kill -0 $TP; do ...; sleep 10; done     # BUG 2: unbounded
#
# `pgrep -f` matches on the full command line, and the *wrapper's own*
# command line contains the pattern — so TP is the wrapper's PID, `kill -0`
# tests whether it is alive (always true), and the loop spins forever at
# 0% CPU with only a `sleep` child. Three of these leaked in one session,
# two of them for sixteen hours, because a silent no-output run reads as
# "the measurement failed, move on" rather than "something is still running".
#
# This script removes both failure modes by construction:
#   - the child's PID comes from `$!`, so no name matching happens at all;
#   - the sampling loop is bounded by --max-wall (default 900s) AND exits
#     when the child does, so it can never outlive its work;
#   - an EXIT trap kills the child and the sampler on any path out,
#     including Ctrl-C and a harness timeout.
#
# For `zig build itest-*` you usually do not need this: the build runner
# already prints `MaxRSS:` per run step. Use `--summary all` and read that.
set -uo pipefail

INTERVAL=5
MAX_WALL=900

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --max-wall) MAX_WALL="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "usage: $0 [--interval S] [--max-wall S] -- <cmd> [args...]" >&2; exit 2 ;;
  esac
done
if [ $# -eq 0 ]; then
  echo "usage: $0 [--interval S] [--max-wall S] -- <cmd> [args...]" >&2
  exit 2
fi

CHILD=""
cleanup() {
  if [ -n "$CHILD" ] && kill -0 "$CHILD" 2>/dev/null; then
    pkill -P "$CHILD" 2>/dev/null
    kill -9 "$CHILD" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

t0=$(date +%s)
"$@" &
CHILD=$!            # the only source of truth for the PID — never pgrep

PEAK=0
elapsed=0
while [ "$elapsed" -lt "$MAX_WALL" ]; do
  kill -0 "$CHILD" 2>/dev/null || break
  # Sum RSS across the child and its descendants: the work often happens in
  # a spawned test binary, not the shell we launched.
  cur=$(ps -o rss= --ppid "$CHILD" -p "$CHILD" 2>/dev/null \
        | awk '{s+=$1} END {print s+0}')
  [ "${cur:-0}" -gt "$PEAK" ] && PEAK=$cur
  sleep "$INTERVAL"
  elapsed=$(( $(date +%s) - t0 ))
done

if kill -0 "$CHILD" 2>/dev/null; then
  echo "measure-rss: child still running at --max-wall=${MAX_WALL}s; killing" >&2
  cleanup
  CHILD=""
  echo "PEAK_KB=$PEAK RC=timeout WALL=$(( $(date +%s) - t0 ))"
  exit 124
fi

wait "$CHILD"; rc=$?
CHILD=""
echo "PEAK_KB=$PEAK RC=$rc WALL=$(( $(date +%s) - t0 ))"
exit "$rc"
