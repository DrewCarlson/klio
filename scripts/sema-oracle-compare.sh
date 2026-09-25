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
#   --dir-programs  each directory inside a given directory is one program of
#                   all its files (a multi-file example), on both sides
#   --             the rest are passed to scripts/sema-oracle-diff.py
#
# Directories are searched recursively for *.kt. Files the oracle reports as
# `[oracle-fail]` are left out of the sema run, so both sides cover the same
# programs. A file with a `// kotlinc: <flags>` line among its first 12 lines
# compiles with those flags (e.g. `-language-version 2.5`). A program whose
# imports outside `kotlin.*` are all `kotlinx.coroutines` compiles against the
# kotlinx-coroutines-core jar the pinned kotlinc ships in its lib directory; no
# other library is on the oracle's classpath.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

out=""
klio="$root/zig-out/bin/klio"
jobs=""
examples=10
json=0
triage=0
oracle_in=""
dir_programs=0
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
    --dir-programs) dir_programs=1; shift ;;
    --) shift; diff_args=("$@"); break ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# paths: the files compiled on their own, and with --dir-programs the
# directories each compiled as one program (programs.txt), whose files
# program.<n>.files lists.
files="$out/files.txt"
programs="$out/programs.txt"
: > "$files"
: > "$programs"
for input in "${inputs[@]}"; do
  if [[ -d "$input" && $dir_programs == 1 ]]; then
    find "${input%/}" -maxdepth 1 -type f -name '*.kt' | LC_ALL=C sort >> "$files"
    find "${input%/}" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort >> "$programs"
  elif [[ -d "$input" ]]; then
    find "${input%/}" -type f -name '*.kt' | LC_ALL=C sort >> "$files"
  else
    echo "$input" >> "$files"
  fi
done
nprograms=0
count=$(( $(wc -l < "$files") ))
while IFS= read -r d; do
  find "$d" -type f -name '*.kt' | LC_ALL=C sort > "$out/program.$nprograms.files"
  count=$(( count + $(wc -l < "$out/program.$nprograms.files") ))
  nprograms=$((nprograms + 1))
done < "$programs"

# The jars of the pinned kotlinc's lib directory a program's imports need:
# kotlinx-coroutines-core when every import outside `kotlin.*` is from
# `kotlinx.coroutines`.
kotlinc_lib="${SEMA_ORACLE_KOTLINC:-$root/target/parity-cache/kotlinc-2.4.20}/lib"
classpath_for() {
  local imports
  imports="$(sed -n -E 's/^[[:space:]]*import[[:space:]]+([^[:space:]]+).*/\1/p' "$@")"
  if printf '%s\n' "$imports" | grep -q '^kotlinx\.coroutines\.' &&
    ! printf '%s\n' "$imports" | grep -v -E '^(kotlin\.|kotlinx\.coroutines\.|$)' | grep -q .; then
    printf '%s' "$kotlinc_lib/kotlinx-coroutines-core-jvm.jar"
  fi
}

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
  # grouped by their flags and classpath and each group is one oracle run.
  groups="$out/oracle.groups"
  rm -rf "$groups"
  mkdir -p "$groups"
  while IFS= read -r f; do
    flags="$(head -n 12 "$f" | sed -n 's|^// kotlinc: *||p' | head -n 1)"
    cp="$(classpath_for "$f")"
    key="$(printf '%s|%s' "$flags" "$cp" | shasum | cut -c1-12)"
    printf '%s\n' "$flags" > "$groups/$key.flags"
    printf '%s\n' "$cp" > "$groups/$key.cp"
    printf '%s\n' "$f" >> "$groups/$key.files"
  done < "$files"
  # A program of several files is a group of its own, compiled together.
  for ((i = 0; i < nprograms; i++)); do
    list="$out/program.$i.files"
    # shellcheck disable=SC2046
    flags="$(for f in $(cat "$list"); do head -n 12 "$f" | sed -n 's|^// kotlinc: *||p'; done | head -n 1)"
    # shellcheck disable=SC2046
    cp="$(classpath_for $(cat "$list"))"
    printf '%s --together\n' "$flags" > "$groups/program$i.flags"
    printf '%s\n' "$cp" > "$groups/program$i.cp"
    cp "$list" "$groups/program$i.files"
  done
  : > "$oracle"
  : > "$oracle_err"
  for list in "$groups"/*.files; do
    key="$(basename "$list" .files)"
    cp="$(cat "$groups/$key.cp")"
    # shellcheck disable=SC2046
    "$root/scripts/sema-oracle.sh" ${jobs:+-j "$jobs"} ${cp:+-cp "$cp"} -o "$groups/$key.tsv" $(cat "$groups/$key.flags") $(cat "$list") 2> "$groups/$key.stderr" || true
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
# A program is compared when kotlinc compiled every file of it.
compiled_programs=()
for ((i = 0; i < nprograms; i++)); do
  if ! grep -qxF -f "$fail" "$out/program.$i.files"; then
    compiled_programs+=("$i")
    ncompiled=$(( ncompiled + $(wc -l < "$out/program.$i.files") ))
  fi
done
echo "files: $count given, $ncompiled compiled by kotlinc, $(( count - ncompiled )) left out" >&2

sema="$out/sema.tsv"
census="$out/sema.census"
t0=$(date +%s)
# shellcheck disable=SC2046
"$klio" sema --each --quiet ${jobs:+-j "$jobs"} --dump "$sema" --unresolved "$out/sema.unresolved.tsv" $(cat "$compiled") > "$census" || true
for i in ${compiled_programs[@]+"${compiled_programs[@]}"}; do
  # shellcheck disable=SC2046
  "$klio" sema --quiet --dump "$out/sema.program$i.tsv" --unresolved "$out/sema.program$i.unresolved.tsv" $(cat "$out/program.$i.files") >> "$census" || true
  cat "$out/sema.program$i.tsv" >> "$sema" 2> /dev/null || true
  cat "$out/sema.program$i.unresolved.tsv" >> "$out/sema.unresolved.tsv" 2> /dev/null || true
done
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
