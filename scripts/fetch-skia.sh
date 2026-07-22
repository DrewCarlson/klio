#!/usr/bin/env bash
# Fetch the pinned JetBrains skia-pack prebuilt static Skia for a target os/arch
# into third_party/skia/<os>-<arch>/. These are the same self-contained builds
# Skiko/Compose-Multiplatform link: a single libskia + every dependency bundled
# (freetype2, harfbuzz, icu, png, jpeg, webp, skparagraph, skshaper, skunicode)
# and the full headers, so CPU raster + PNG encode + real text shaping work
# offline. See plans/UI-RENDERING-PACKS.md.
#
# Usage:
#   scripts/fetch-skia.sh                 # host os/arch
#   scripts/fetch-skia.sh macos arm64     # a specific target (for cross builds)
#   KLIO_SKIA_OS=windows KLIO_SKIA_ARCH=x64 scripts/fetch-skia.sh
#
# Each target extracts to its own dir so several can coexist (cross-compilation):
#   third_party/skia/<os>-<arch>/{include,modules,out/Release-<os>-<arch>}
#
# C++ ABI per OS (the shim must be built with a matching compiler — build.zig
# handles this): linux = GNU libstdc++ (.a), macos = LLVM libc++ (.a),
# windows = MSVC (.lib).
set -euo pipefail

SKIA_TAG="m150-1f14f1166a"
REPO="JetBrains/skia"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/third_party/skia"

OS="${1:-${KLIO_SKIA_OS:-}}"
ARCH="${2:-${KLIO_SKIA_ARCH:-}}"

if [ -z "${OS}" ]; then
    case "$(uname -s)" in
        Linux) OS="linux" ;;
        Darwin) OS="macos" ;;
        MINGW*|MSYS*|CYGWIN*|Windows_NT) OS="windows" ;;
        *) echo "cannot detect OS from '$(uname -s)'; pass one: linux|macos|windows" >&2; exit 1 ;;
    esac
fi
if [ -z "${ARCH}" ]; then
    case "$(uname -m)" in
        x86_64|amd64) ARCH="x64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo "cannot detect arch from '$(uname -m)'; pass one: x64|arm64" >&2; exit 1 ;;
    esac
fi

# Map the logical OS to the skia-pack asset token (camelCase `iosSim` for the
# iOS simulator) and to the local directory name. iOS builds are arm64-only.
ASSET_OS="${OS}"; DIR_OS="${OS}"
case "${OS}" in
    linux|macos|windows|android) ;;
    ios) ASSET_OS="ios"; DIR_OS="ios" ;;
    iossim|ios-sim|iosSim) OS="iossim"; ASSET_OS="iosSim"; DIR_OS="iossim" ;;
    *) echo "os must be linux|macos|windows|ios|iossim|android (got '${OS}')" >&2; exit 1 ;;
esac
case "${ARCH}" in x64|arm64) ;; *) echo "arch must be x64|arm64 (got '${ARCH}')" >&2; exit 1 ;; esac

DEST="${ROOT}/${DIR_OS}-${ARCH}"
ASSET="Skia-${SKIA_TAG}-${ASSET_OS}-Release-${ARCH}.zip"
URL="https://github.com/${REPO}/releases/download/${SKIA_TAG}/${ASSET}"
EXT="a"; [ "${OS}" = "windows" ] && EXT="lib"
MAIN="${DEST}/out/Release-${ASSET_OS}-${ARCH}/libskia.${EXT}"
# The prebuilt's public module headers (skunicode/skparagraph/skresources/svg/
# skottie) transitively `#include "src/..."` internal headers, so the archive's
# headers-only src/ tree is required to compile the shim. Use one such header as
# the completeness sentinel: a checkout with libskia but no src/ is incomplete.
SENTINEL="${DEST}/src/base/SkUTF.h"

if [ -f "${MAIN}" ] && [ -f "${SENTINEL}" ]; then
    echo "skia already present for ${OS}-${ARCH} at ${DEST}; nothing to do"
    exit 0
fi

mkdir -p "${DEST}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "downloading ${ASSET} ..."
curl -fsSL -o "${TMP}/skia.zip" "${URL}"

echo "extracting headers + libs into ${DEST} ..."
# include/ + modules/ (public headers), out/ (the static libs), and src/ (the
# archive's headers-only internal tree, ~1.4MB — no .cpp). src/ is required:
# the module public headers `#include "src/..."` internal headers, so a checkout
# without it fails to compile the shim ('src/base/SkUTF.h' file not found).
unzip -q -o "${TMP}/skia.zip" "include/*" "modules/*" "out/*" "src/*" -d "${DEST}"

echo "skia ${SKIA_TAG} (${OS}-${ARCH}) ready at ${DEST}"
