#!/usr/bin/env bash
# Resolution oracle: dumps what kotlinc resolved at every call and name site of the
# given Kotlin files (or directories, searched for *.kt), one TSV line per site.
# Format and options: tools/sema-oracle/README.md. Diff against sema's dump with
# scripts/sema-oracle-diff.py.
#
#   scripts/sema-oracle.sh [-o out.tsv] [-j N] [-cp extra.jar] <files or dirs...>
#
# Rebuilds target/sema-oracle/sema-oracle.jar when it is missing or older than
# its sources. SEMA_ORACLE_JAVA_OPTS adds JVM options.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="2.4.20"
kotlinc_home="${SEMA_ORACLE_KOTLINC:-$root/target/parity-cache/kotlinc-$version}"
jar="$root/target/sema-oracle/sema-oracle.jar"
src="$root/tools/sema-oracle"

stale=0
if [[ ! -f "$jar" || ! -f "$kotlinc_home/lib/kotlin-compiler.jar" ]]; then
  stale=1
elif [[ -n "$(find "$src/src" "$src/resources" -newer "$jar" -type f -print -quit)" ]]; then
  stale=1
fi
if [[ $stale == 1 ]]; then
  "$src/build.sh" >&2
fi

# shellcheck disable=SC2086
exec java -Xss8m -XX:+UseParallelGC ${SEMA_ORACLE_JAVA_OPTS:-} \
  -cp "$jar:$kotlinc_home/lib/kotlin-compiler.jar" klio.semaoracle.DriverKt "$@"
