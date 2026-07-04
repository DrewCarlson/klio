#!/usr/bin/env bash
# Fetch the pinned JetBrains skia-pack prebuilt static Skia into third_party/skia.
# These are the same self-contained builds Skiko/Compose-Multiplatform link: a
# single libskia.a plus every dependency bundled (freetype2, harfbuzz, icu, png,
# jpeg, webp, skparagraph, skshaper, skunicode) and the full headers, so CPU
# raster + PNG encode + real text shaping work offline with no system deps.
#
# The libs link with system g++/libstdc++ (Skia uses the old GNU string ABI), NOT
# zig cc/libc++. See plans/UI-RENDERING-PACKS.md.
set -euo pipefail

SKIA_TAG="m150-1f14f1166a"
REPO="JetBrains/skia"
DEST="$(cd "$(dirname "$0")/.." && pwd)/third_party/skia"

# Map host os/arch to the release asset variant.
case "$(uname -s)" in
    Linux)  OS="linux" ;;
    Darwin) OS="macos" ;;
    *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

ASSET="Skia-${SKIA_TAG}-${OS}-Release-${ARCH}.zip"
URL="https://github.com/${REPO}/releases/download/${SKIA_TAG}/${ASSET}"

if [ -f "${DEST}/out/Release-${OS}-${ARCH}/libskia.a" ]; then
    echo "skia already present at ${DEST} (${OS}-${ARCH}); nothing to do"
    exit 0
fi

mkdir -p "${DEST}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "downloading ${ASSET} ..."
curl -fsSL -o "${TMP}/skia.zip" "${URL}"

echo "extracting headers + libs into ${DEST} ..."
# Only include/, modules/ (headers), and out/ (static libs) are needed; skip the
# Skia source tree in the archive.
unzip -q -o "${TMP}/skia.zip" "include/*" "modules/*" "out/*" -d "${DEST}"

echo "skia ${SKIA_TAG} (${OS}-${ARCH}) ready at ${DEST}"
