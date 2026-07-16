#!/usr/bin/env bash
# Build a static, -fPIC libSDL2 for the RELEASE Skia shim into
# third_party/sdl/<os>-<arch>/. The released shim links SDL2 statically so
# end users need no SDL2 install (zlib license — static linking explicitly
# permitted, no source obligations); statically-linked SDL still dlopens
# the host's X11/Wayland/audio client libraries at runtime, so one Linux
# shim covers both display servers. Dev builds keep dynamic SDL2 (the
# detectSdl path in build.zig) — only release CI needs this.
#
# Usage:
#   scripts/fetch-sdl.sh          # host os/arch (linux only for now)
#
# Requires the usual SDL build dependencies on the builder image
# (gcc/make; X11/Wayland dev headers improve runtime coverage but SDL
# loads them dynamically, so their absence only disables that backend).
#
# Output: third_party/sdl/<os>-<arch>/{include/SDL2,lib/libSDL2.a}
# Consumed by `zig build skia-lib -Dsdl-static`.
set -euo pipefail

SDL_VERSION="2.30.11"
URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL_VERSION}/SDL2-${SDL_VERSION}.tar.gz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/third_party/sdl"

case "$(uname -s)" in
    Linux) OS="linux" ;;
    *) echo "static SDL2 is a linux release concern; other OSes use native window backends" >&2; exit 1 ;;
esac
case "$(uname -m)" in
    x86_64|amd64) ARCH="x64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "cannot detect arch from '$(uname -m)'" >&2; exit 1 ;;
esac

DEST="${ROOT}/${OS}-${ARCH}"
MAIN="${DEST}/lib/libSDL2.a"

if [ -f "${MAIN}" ]; then
    echo "static SDL2 already present at ${DEST}; nothing to do"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "fetching SDL2 ${SDL_VERSION}..."
curl -fsSL "${URL}" -o "${TMP}/sdl.tar.gz"
tar -xzf "${TMP}/sdl.tar.gz" -C "${TMP}"

SRC="${TMP}/SDL2-${SDL_VERSION}"
BUILD="${TMP}/build"
mkdir -p "${BUILD}"
cd "${BUILD}"

# Static only, -fPIC (the shim is a shared library). The video/audio
# client libraries stay runtime-dlopened (SDL's default loadso path), so
# the static archive carries no X11/Wayland link dependency.
"${SRC}/configure" \
    --prefix="${DEST}" \
    --disable-shared --enable-static \
    --with-pic \
    >/dev/null

make -j"$(nproc)" >/dev/null
make install >/dev/null

echo "static SDL2 ready: ${MAIN}"
