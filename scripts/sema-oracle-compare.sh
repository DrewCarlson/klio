#!/usr/bin/env bash
# Compares sema's resolution with kotlinc's, site by site, over the same files:
# runs the oracle (scripts/sema-oracle.sh) and `klio sema --each --dump` on the
# files kotlinc compiled, then scripts/sema-oracle-diff.py on the two dumps.
#
#   scripts/sema-oracle-compare.sh [options] <file.kt | dir>...
#
# Options:
#   -o DIR          keep oracle.tsv, sema.tsv, sema.unresolved.tsv, the census
#                   and the diff in DIR
#                   (default: a temporary directory, removed afterwards)
#   --klio PATH     the klio binary (default: zig-out/bin/klio)
#   -j N            parallel jobs for both tools
#   -n N            examples per category in the diff report (default 10)
#   --json          print the diff tool's JSON summary instead of the text report
#   --triage        also sort the differences into causes
#                   (scripts/sema-oracle-triage.py)
#   --oracle TSV    reuse an oracle dump instead of running kotlinc (its
#                   companion TSV.fail lists the files it could not compile;
#                   a run with -o DIR leaves both in DIR)
#   --             the rest are passed to scripts/sema-oracle-diff.py
#
# Directories are searched recursively for *.kt. Files the oracle reports as
# `[oracle-fail]` are left out of the sema run, so both sides cover the same
# programs. A file with a `// kotlinc: <flags>` line among its first 12 lines
# compiles with those flags (e.g. `-language-version 2.5`).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

out=""
klio="$root/zig-out/bin/klio"
jobs=""
examples=10
json=0
triage=0
oracle_in=""
diff_args=()
inputs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --klio) klio="$2"; shift 2 ;;
    -j) jobs="$2"; shift 2 ;;
    -n) examples="$2"; shift 2 ;;
    --json) json=1; shift ;;
    --triage) triage=1; shift ;;
    --oracle) oracle_in="$2"; shift 2 ;;
    --) shift; diff_args=("$@"); break ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) inputs+=("$1"); shift ;;
  esac
done
if [[ ${#inputs[@]} -eq 0 ]]; then
  echo "usage: $0 [options] <file.kt | dir>..." >&2
  exit 2
fi

if [[ -z "$out" ]]; then
  out="$(mktemp -d "${TMPDIR:-/tmp}/sema-compare.XXXXXX")"
  trap 'rm -rf "$out"' EXIT
else
  mkdir -p "$out"
fi

# The same explicit, sorted file list for both tools, so both print the same
# paths.
files="$out/files.txt"
: > "$files"
for input in "${inputs[@]}"; do
  if [[ -d "$input" ]]; then
    find "${input%/}" -type f -name '*.kt' | LC_ALL=C sort >> "$files"
  else
    echo "$input" >> "$files"
  fi
done
count=$(wc -l < "$files" | tr -d ' ')

oracle="$out/oracle.tsv"
fail="$oracle.fail"
if [[ -n "$oracle_in" ]]; then
  if [[ ! "$oracle_in" -ef "$oracle" ]]; then
    cp "$oracle_in" "$oracle"
    if [[ -f "$oracle_in.fail" ]]; then cp "$oracle_in.fail" "$fail"; else : > "$fail"; fi
  fi
  [[ -f "$fail" ]] || : > "$fail"
else
  oracle_err="$out/oracle.stderr"
  t0=$(date +%s)
  # A file whose first lines carry `// kotlinc: <flags>` (a language version
  # or an -X feature flag it needs) compiles with those flags; the files are
  # grouped by their flags and each group is one oracle run.
  groups="$out/oracle.groups"
  rm -rf "$groups"
  mkdir -p "$groups"
  while IFS= read -r f; do
    flags="$(head -n 12 "$f" | sed -n 's|^// kotlinc: *||p' | head -n 1)"
    key="$(printf '%s' "$flags" | shasum | cut -c1-12)"
    printf '%s\n' "$flags" > "$groups/$key.flags"
    printf '%s\n' "$f" >> "$groups/$key.files"
  done < "$files"
  : > "$oracle"
  : > "$oracle_err"
  for list in "$groups"/*.files; do
    key="$(basename "$list" .files)"
    # shellcheck disable=SC2046
    "$root/scripts/sema-oracle.sh" ${jobs:+-j "$jobs"} -o "$groups/$key.tsv" $(cat "$groups/$key.flags") $(cat "$list") 2> "$groups/$key.stderr" || true
    cat "$groups/$key.tsv" >> "$oracle" 2> /dev/null || true
    cat "$groups/$key.stderr" >> "$oracle_err"
  done
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2n -k3,3n -k4,4 -k5,5 -o "$oracle" "$oracle"
  grep '^\[oracle-fail\]' "$oracle_err" | sed -E 's/^\[oracle-fail\] ([^:]+):.*/\1/' > "$fail" || true
  for err in "$groups"/*.stderr; do
    echo "oracle: $(tail -n 1 "$err")" >&2
  done
  echo "oracle: $(( $(date +%s) - t0 ))s" >&2
fi

compiled="$out/compiled.txt"
grep -vxF -f "$fail" "$files" > "$compiled" || true
ncompiled=$(wc -l < "$compiled" | tr -d ' ')
echo "files: $count given, $ncompiled compiled by kotlinc, $(( count - ncompiled )) left out" >&2

sema="$out/sema.tsv"
census="$out/sema.census"
t0=$(date +%s)
# shellcheck disable=SC2046
"$klio" sema --each --quiet ${jobs:+-j "$jobs"} --dump "$sema" --unresolved "$out/sema.unresolved.tsv" $(cat "$compiled") > "$census" || true
# A program the analysis did not finish (a panic) is left out of the diff
# and listed instead.
sema_fail="$out/sema.fail"
grep '^\[sema-file\] .* failed: ' "$census" | sed -E 's/^\[sema-file\] (.*) failed: .*/\1/' > "$sema_fail" || true
if [[ -s "$sema_fail" ]]; then
  echo "sema: $(wc -l < "$sema_fail" | tr -d ' ') programs failed and are left out of the diff:" >&2
  grep '^\[sema-file\] .* failed: ' "$census" | sed 's/^\[sema-file\] /  /' >&2
  awk -F '\t' 'NR == FNR { skip[$0] = 1; next } !($1 in skip)' "$sema_fail" "$oracle" > "$out/oracle.compared.tsv"
  oracle="$out/oracle.compared.tsv"
fi
echo "sema: $(grep '^\[sema\] programs=' "$census") ($(( $(date +%s) - t0 ))s)" >&2

diff_opts=(-n "$examples" --root "$PWD")
if [[ $json == 1 ]]; then diff_opts+=(--json); fi
python3 "$root/scripts/sema-oracle-diff.py" "${diff_opts[@]}" ${diff_args[@]+"${diff_args[@]}"} "$oracle" "$sema" | tee "$out/diff.txt" || true
if [[ $triage == 1 ]]; then
  echo
  python3 "$root/scripts/sema-oracle-triage.py" -n "$examples" --root "$PWD" "$oracle" "$sema" "$out/sema.unresolved.tsv" | tee "$out/triage.txt"
fi
