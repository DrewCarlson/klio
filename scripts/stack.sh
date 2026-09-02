#!/usr/bin/env bash
# The full verification stack (plans/verification-latency-campaign.md).
# Critical path = the compose gate's validatePotentialDeadlock (~510s
# solo, GC-relaxed): it gets one whole L3 domain to itself; everything
# else overlaps it full-parallel on the other domain; litmus runs last
# alone (timing-sensitive oracle fixtures).
#
# HARD-WON RULES BAKED IN:
# - zig build with MULTIPLE top-level steps can exit 0 while a step
#   failed (observed twice); the verdict is scraped from the output.
# - Unbounded per-suite worker pools starve the compose gate's children
#   (resumeOnBackgroundThread breached its cap), so census workers are
#   bounded unless the caller overrides.
# - vpd's in-stack inflation is LLC EVICTION, not CPU: nice levels and
#   partial-domain pinning do nothing (602-653s); a whole L3 domain
#   brings it to 525s, within 15s of solo.
set -uo pipefail
cd "$(dirname "$0")/.."
# Suite worker width: the rest half shares ONE L3 domain (16 hw
# threads on the CCD-split box). Width 4 across all eight suites at
# once drops children to timeout (androidx lost 3 to DNC); width 2
# starves the heavy suites (rest chain 850s+). The balance is width 4
# in TWO WAVES of four suites each — ~16 workers resident either way.
export KLIO_ITEST_JOBS="${KLIO_ITEST_JOBS:-4}"
# Moderate GC relaxation for every interpreter child (the census suites
# are allocation-churn workloads paying the same marking tax vpd does;
# measured -8% on vpd solo at stronger settings). RSS caps unchanged.
export KLIO_GC_GROWTH="${KLIO_GC_GROWTH:-4}"
export KLIO_GC_THRESHOLD_KB="${KLIO_GC_THRESHOLD_KB:-65536}"
# Always name failing/incomplete cases — a one-in-N load DNC is
# undiagnosable from a bare count.
export KLIO_CENSUS_NAMES=1

# Green-tree memo (fail-OPEN): a stack that already ran green on this
# exact tree content is a no-op. The key covers HEAD, every non-md
# tracked change, and untracked non-md files; docs/plans edits do not
# invalidate. STACK_NO_CACHE=1 forces a run.
cache_file=.zig-cache/stack-green-key
tree_key=$( {
  git rev-parse HEAD
  git diff HEAD -- . ':!:*.md'
  git ls-files --others --exclude-standard -- . ':!:*.md' | sort | xargs -r sha256sum
} 2>/dev/null | sha256sum | cut -d' ' -f1 ) || tree_key=""
if [ -z "${STACK_NO_CACHE:-}" ] && [ -n "$tree_key" ] && [ -f "$cache_file" ]    && [ "$(cat "$cache_file" 2>/dev/null)" = "$tree_key" ]; then
  echo "stack: cached-green (tree unchanged since last green run; STACK_NO_CACHE=1 to force)"
  exit 0
fi
# Reserve CPUs for the gate's vpd child: both builds and all their
# children stay off them via taskset; the gate binary launches vpd
# itself with an explicit mask (KLIO_VPD_CPUS) overriding the
# inherited one.
pin=()
nproc=$(nproc 2>/dev/null || echo 1)
if [ "$nproc" -ge 16 ] && command -v taskset >/dev/null; then
  # Prefer a WHOLE L3 domain for vpd (EPYC CCDs have per-CCD L3): the
  # first domain is vpd's, the rest of the box is everyone else's. A
  # partial-domain split leaves vpd sharing its L3 with load and the
  # isolation does nothing (measured: +92s either way).
  l3_domains=$(cat /sys/devices/system/cpu/cpu*/cache/index3/shared_cpu_list 2>/dev/null | sort -u)
  n_domains=$(printf '%s\n' "$l3_domains" | grep -c . || echo 0)
  if [ "$n_domains" -ge 2 ]; then
    export KLIO_VPD_CPUS=$(printf '%s\n' "$l3_domains" | head -1)
    rest_cpus=$(printf '%s\n' "$l3_domains" | tail -n +2 | paste -sd, -)
    pin=(taskset -c "$rest_cpus")
  else
    export KLIO_VPD_CPUS="0-5"
    pin=(taskset -c "6-$((nproc-1))")
  fi
fi
# Structure (measured, plans/verification-latency-campaign.md): vpd
# owns one whole L3 domain (its in-stack wall is 525s there, vs 602s
# sharing L3 with load — the inflation was LLC eviction, not CPU).
# Everything else runs full-parallel on the other domain: with vpd's
# cache isolated, co-runner count no longer costs the critical path,
# so the census suites take maximum width. Litmus runs last, alone —
# its fixtures compare timing-sensitive oracle output.
gate_steps=(itest-compose_plugin_commontest)
wave1_steps=(
  itest-coroutines_commontest itest-io_commontest
  itest-androidx_collection_commontest itest-ktor_commontest
)
wave2_steps=(
  itest-datetime_commontest itest-serialization_commontest
  itest-serialization_json_commontest
  itest-atomicfu_commontest itest-check_examples
)
s=$(date +%s)
rest_log=$(mktemp)
gate_log=$(mktemp)
# Leaf pack for the census waves (plans/leaf-production-campaign.md):
# pure-scalar library bodies served natively inside the interpreter.
# FAIL-OPEN — a build failure just runs the censuses leafless (and is
# reported); correctness never depends on the artifact. The compose
# gate and litmus stay leafless (plugin-env trap; timing fixtures).
leaves_env=()
zig build klio-harness >/dev/null 2>&1 || true
if scripts/build-leaf-packs.sh >/tmp/stack-leaves.log 2>&1; then
  leaves_env=(env KLIO_LEAVES="$PWD/.klio-local/leaves/library.so")
  cat /tmp/stack-leaves.log
else
  echo "stack: leaf pack build failed — census waves run leafless"
  cat /tmp/stack-leaves.log
fi
"${pin[@]}" zig build "${gate_steps[@]}" "$@" >"$gate_log" 2>&1 &
gate_pid=$!
{
  "${pin[@]}" nice -n 10 "${leaves_env[@]}" zig build "${wave1_steps[@]}" "$@"
  w1=$?
  "${pin[@]}" nice -n 10 "${leaves_env[@]}" zig build "${wave2_steps[@]}" "$@"
  w2=$?
  [ $w1 -eq 0 ] && [ $w2 -eq 0 ]
} >"$rest_log" 2>&1 &
rest_pid=$!
wait "$rest_pid"
rest_rc=$?
# The compose-ui example family gate runs in vpd's tail window (the
# census waves have drained; vpd still owns its own domain) and stays
# ahead of litmus, which must run alone. It works in .klio-local — no
# scratch-home overlap with the census suites.
uigate_log=$(mktemp)
"${pin[@]}" scripts/compose-ui-gate.sh >"$uigate_log" 2>&1
uigate_rc=$?
litmus_out=$("${pin[@]}" zig build itest-parity_threaded_litmus "$@" 2>&1)
litmus_rc=$?
wait "$gate_pid"
gate_rc=$?
e=$(date +%s)
cat "$gate_log"
cat "$rest_log"
cat "$uigate_log"
printf '%s\n' "$litmus_out"
rc=0
[ $gate_rc -ne 0 ] && rc=1
[ $rest_rc -ne 0 ] && rc=1
[ $uigate_rc -ne 0 ] && rc=1
[ $litmus_rc -ne 0 ] && rc=1
if grep -qE "^error: '|exceeds the ceiling|transitive failure" "$gate_log" "$rest_log"; then rc=1; fi
if printf '%s\n' "$litmus_out" | grep -qE "^error: '|exceeds the ceiling|transitive failure"; then rc=1; fi
rm -f "$rest_log" "$gate_log" "$uigate_log"
if [ $rc -eq 0 ] && [ -n "$tree_key" ]; then printf '%s' "$tree_key" >"$cache_file"; fi
echo "stack: wall=$((e-s))s rc=$rc"
exit $rc
