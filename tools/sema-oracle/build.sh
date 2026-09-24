#!/usr/bin/env bash
# Builds target/sema-oracle/sema-oracle.jar (the FIR plugin and its driver) with the
# pinned kotlinc. The jar runs against lib/kotlin-compiler.jar of the same dist.
# Installs the pinned kotlinc into target/parity-cache when it is missing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
version="2.4.20"
kotlinc_home="${SEMA_ORACLE_KOTLINC:-$root/target/parity-cache/kotlinc-$version}"
out="$root/target/sema-oracle"

if [[ ! -x "$kotlinc_home/bin/kotlinc" ]]; then
  if [[ -n "${SEMA_ORACLE_KOTLINC:-}" ]]; then
    echo "sema-oracle: no kotlinc at $kotlinc_home" >&2
    exit 1
  fi
  echo "sema-oracle: installing kotlinc $version into $kotlinc_home" >&2
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/kotlinc.zip" \
    "https://github.com/JetBrains/kotlin/releases/download/v$version/kotlin-compiler-$version.zip"
  unzip -q "$tmp/kotlinc.zip" -d "$tmp"
  mkdir -p "$(dirname "$kotlinc_home")"
  mv "$tmp/kotlinc" "$kotlinc_home"
fi

rm -rf "$out/classes"
mkdir -p "$out/classes"
"$kotlinc_home/bin/kotlinc" \
  -cp "$kotlinc_home/lib/kotlin-compiler.jar" \
  -d "$out/classes" \
  -jvm-target 21 \
  -no-reflect \
  -opt-in=org.jetbrains.kotlin.compiler.plugin.ExperimentalCompilerApi \
  -Xsuppress-version-warnings \
  -nowarn \
  "$here"/src/*.kt
cp -R "$here/resources/." "$out/classes/"
( cd "$out/classes" && jar --create --file "$out/sema-oracle.jar.tmp" --main-class klio.semaoracle.DriverKt . )
mv "$out/sema-oracle.jar.tmp" "$out/sema-oracle.jar"
echo "$out/sema-oracle.jar"
