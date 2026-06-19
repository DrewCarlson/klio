#!/usr/bin/env bash
# Cross-runtime CPU + memory comparison. For each workload, run klio / node /
# python and report wall time and peak RSS (sampled from /proc).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
klio="${KLIO_BIN:-$here/../../zig-out/bin/klio}"

run() {  # name cmd...
  local name="$1"; shift
  timeout 180 "$@" >/tmp/mc.out 2>/tmp/mc.err &
  local p=$! hwm=0
  local start; start=$(date +%s%N)
  while kill -0 "$p" 2>/dev/null; do
    local v; v=$(awk '/VmHWM/{print $2}' "/proc/$p/status" 2>/dev/null)
    [ -n "${v:-}" ] && [ "$v" -gt "$hwm" ] && hwm=$v
  done
  wait "$p"; local rc=$?
  local end; end=$(date +%s%N)
  local ms=$(( (end - start) / 1000000 ))
  if [ $rc -ne 0 ]; then printf "  %-8s FAILED (rc=%d)\n" "$name" "$rc"; sed 's/^/      /' /tmp/mc.err | head -3; return; fi
  printf "  %-8s %7d ms   %6d MB\n" "$name" "$ms" "$((hwm/1024))"
}

for w in numeric collections strings; do
  echo "== $w =="
  case "$w" in
    collections) kf=collections.kt; jf=collections.js; pf=collections_w.py;;
    strings)     kf=strings.kt;     jf=strings.js;     pf=strings_w.py;;
    numeric)     kf=numeric.kt;     jf=numeric.js;     pf=numeric_w.py;;
  esac
  run klio   env KLIO_RECLAIM=gc "$klio" run "$here/klio/$kf"
  run node   node "$here/node/$jf"
  run python python3 "$here/py/$pf"
done
