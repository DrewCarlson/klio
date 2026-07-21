#!/usr/bin/env bash
# One-shot project initialization for a fresh klio clone.
#
# Takes a bare `git clone` to a working `zig-out/bin/klio`, doing every setup
# step the build depends on and nothing the build does for itself. Idempotent:
# each phase is a no-op when already satisfied, so re-running after a partial
# setup (or to pick up a moved submodule pin) is safe.
#
# Phases:
#   1. preflight        zig on PATH at the pinned version, run from a klio clone
#   2. vendored submodules   kotlinx + ktor upstream sources (regular submodules)
#   3. sparse upstreams      kotlin stdlib, compose, androidx.collection (update=none)
#   4. skia prebuilt         the Compose-UI Skia backend libs + headers (host target)
#   5. build                 zig build -> zig-out/bin/klio
#   6. packs (opt-in)        build + install the shipped library packs into ~/.klio
#
# The Compose-UI window/GPU backend is enabled automatically: macOS builds the
# Cocoa window + Metal surface (-Dcocoa -Dgpu); Linux builds the Ganesh GL/EGL
# surface (-Dgpu) when a display is attached (DISPLAY / WAYLAND_DISPLAY) and
# stays headless-raster otherwise. Pass --headless to force a headless build.
#
# Usage:
#   scripts/bootstrap.sh                 # full setup + build (auto window/GPU backend)
#   scripts/bootstrap.sh --release       # build with -Doptimize=ReleaseFast
#   scripts/bootstrap.sh --packs         # also install the shipped packs into ~/.klio
#   scripts/bootstrap.sh --headless      # build without the window/GPU backend
#   scripts/bootstrap.sh --no-skia       # skip the Skia backend entirely
#   scripts/bootstrap.sh --no-build      # set up sources only, don't compile
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

# --- options ---------------------------------------------------------------
DO_SKIA=1
DO_BUILD=1
DO_PACKS=0
DO_GPU=1
BUILD_ARGS=()

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --release) BUILD_ARGS+=("-Doptimize=ReleaseFast") ;;
        --no-skia) DO_SKIA=0 ;;
        --no-build) DO_BUILD=0 ;;
        --packs) DO_PACKS=1 ;;
        --headless|--no-gpu) DO_GPU=0 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

# Host os/arch in the naming fetch-skia.sh / build.zig use (macos-arm64, etc.).
case "$(uname -s)" in
    Linux) HOST_OS=linux ;;
    Darwin) HOST_OS=macos ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) HOST_OS=windows ;;
    *) HOST_OS=unknown ;;
esac
case "$(uname -m)" in
    x86_64|amd64) HOST_ARCH=x64 ;;
    aarch64|arm64) HOST_ARCH=arm64 ;;
    *) HOST_ARCH=unknown ;;
esac

step() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$1" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- 1. preflight ----------------------------------------------------------
step "preflight"
[ -f build.zig ] && [ -f build.zig.zon ] || die "run from a klio clone (build.zig not found)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository; clone klio with git"

command -v zig >/dev/null 2>&1 || die "zig not on PATH; install Zig 0.16.0 (https://ziglang.org/download/)"
PINNED="$(grep -oE '\.minimum_zig_version = "[^"]+"' build.zig.zon | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
ZIG_VER="$(zig version 2>/dev/null || echo unknown)"
if [ -n "$PINNED" ] && [ "$ZIG_VER" != "$PINNED" ]; then
    warn "zig $ZIG_VER found, project pins $PINNED; build may fail if they diverge"
else
    note "zig $ZIG_VER"
fi

# --- 2. vendored submodules (kotlinx + ktor) -------------------------------
# Regular submodules; the `update = none` sparse trees (kotlin, compose,
# androidx-collection, mosaic) are cleanly skipped here and populated in phase 3.
step "vendored submodules (kotlinx + ktor)"
git submodule update --init --recursive
note "done"

# --- 3. sparse upstream checkouts ------------------------------------------
step "sparse upstream sources (kotlin stdlib, compose, androidx.collection, mosaic)"
./scripts/init-kotlin-submodule.sh
./scripts/init-compose-submodule.sh
./scripts/init-androidx-collection-submodule.sh
./scripts/init-mosaic-submodule.sh

# --- 4. skia prebuilt (Compose-UI backend) ---------------------------------
if [ "$DO_SKIA" -eq 1 ]; then
    step "skia prebuilt (Compose-UI rendering backend, host target)"
    if ./scripts/fetch-skia.sh; then
        note "skia ready"
    else
        warn "skia fetch failed; the compose-UI/skia backend will be skipped (headless build still works)"
    fi
else
    step "skia prebuilt -- skipped (--no-skia)"
fi

# --- 5. build --------------------------------------------------------------
# Window/GPU backend flags for the Skia shim, chosen per platform. These options
# are only registered by build.zig when the shim is built, so pass them only when
# Skia is on and its libs are actually present (else zig errors on -Dcocoa/-Dgpu).
gpu_args=()
skia_lib="third_party/skia/${HOST_OS}-${HOST_ARCH}/out/Release-${HOST_OS}-${HOST_ARCH}/libskia.a"
[ "$HOST_OS" = windows ] && skia_lib="${skia_lib%.a}.lib"
if [ "$DO_SKIA" -eq 1 ] && [ -f "$skia_lib" ]; then
    if [ "$DO_GPU" -eq 1 ]; then
        case "$HOST_OS" in
            macos)
                # Cocoa window + Metal surface. This is also build.zig's macOS
                # default, so it is explicit-but-redundant; kept for the log line.
                gpu_args=(-Dcocoa -Dgpu)
                ;;
            linux)
                # The SDL window backend auto-links when libSDL2 is present; add
                # the Ganesh GL/EGL GPU surface only with a display attached (it
                # falls back to raster if the GL/EGL libs are missing regardless).
                if [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
                    gpu_args=(-Dgpu)
                fi
                ;;
        esac
    else
        # --headless: build.zig defaults the macOS Cocoa/Metal backend on, so
        # turn it off explicitly for an offscreen-only shim.
        case "$HOST_OS" in
            macos) gpu_args=(-Dcocoa=false -Dgpu=false) ;;
        esac
    fi
fi

if [ "$DO_BUILD" -eq 1 ]; then
    step "build (zig build ${BUILD_ARGS[*]:-} ${gpu_args[*]:-})"
    if [ "$DO_GPU" -eq 0 ]; then
        note "window/GPU backend: disabled (--headless)"
    elif [ "${#gpu_args[@]}" -gt 0 ]; then
        note "window/GPU backend: ${gpu_args[*]}"
    elif [ "$DO_SKIA" -eq 1 ] && [ "$HOST_OS" = linux ]; then
        note "window/GPU backend: headless (no DISPLAY/WAYLAND_DISPLAY detected)"
    fi
    zig build "${BUILD_ARGS[@]}" "${gpu_args[@]}"
    note "built zig-out/bin/klio"
else
    step "build -- skipped (--no-build)"
fi

# --- 6. packs (opt-in) -----------------------------------------------------
# The shipped library packs (kotlinx, ktor, compose, kotlin.test) install into
# ~/.klio/packs so `klio run` sees them. They are opt-in: the embedded stdlib
# needs none of them, and CI builds + tests without them. Packs carry a `[[deps]]`
# graph, so a pack may fail to build until its deps are installed -- retry to a
# fixpoint instead of hardcoding an install order.
if [ "$DO_PACKS" -eq 1 ]; then
    step "packs (build + install shipped libraries into ~/.klio)"
    KLIO="./zig-out/bin/klio"
    [ -x "$KLIO" ] || die "packs need the klio binary; drop --no-build or build first"

    # Not every kotlin-klio/ dir is a standalone installable pack. Some are
    # source-providers for another pack and declare the same pack id, so
    # installing them clobbers the real pack. klio-compose-runtime holds the
    # upstream commonMain + klioMain that klio-compose-runtime-engine consumes
    # via ../klio-compose-runtime/...; both declare id "androidx.compose.runtime",
    # and the engine variant is the complete one. Skip the source-provider.
    skip_pack_dir() {
        case "$1" in
            kotlin-klio/klio-compose-runtime) return 0 ;;
            *) return 1 ;;
        esac
    }

    pack_dirs=()
    seen_ids=""
    for d in kotlin-klio/*/; do
        d="${d%/}"
        [ -f "$d/klio.toml" ] || continue
        skip_pack_dir "$d" && continue
        id="$(sed -nE 's/^id = "([^"]+)".*/\1/p' "$d/klio.toml" | head -1)"
        if [ -n "$id" ] && printf '%s\n' "$seen_ids" | grep -qxF "$id"; then
            warn "pack id '$id' is produced by more than one dir; install order decides the winner -- exclude one in skip_pack_dir()"
        fi
        seen_ids="${seen_ids}${id}"$'\n'
        pack_dirs+=("$d")
    done
    remaining=("${pack_dirs[@]}")

    while [ "${#remaining[@]}" -gt 0 ]; do
        progressed=0
        next=()
        for d in "${remaining[@]}"; do
            if out="$("$KLIO" pack build "$d" 2>&1)"; then
                pack_file="$(printf '%s\n' "$out" | grep -oE 'target/packs/[^ ]+\.klio-pack' | tail -1)"
                if [ -n "$pack_file" ] && "$KLIO" pack install "$pack_file" >/dev/null 2>&1; then
                    note "installed $(basename "$pack_file")"
                    progressed=1
                    continue
                fi
            fi
            next+=("$d")   # unsatisfied deps or build error; retry next round
        done
        remaining=("${next[@]}")
        [ "$progressed" -eq 0 ] && break
    done

    if [ "${#remaining[@]}" -gt 0 ]; then
        warn "these packs did not install (deps unmet or build error): ${remaining[*]}"
        warn "re-run '$KLIO pack build <dir>' on one to see why"
    fi
fi

step "bootstrap complete"
[ "$DO_BUILD" -eq 1 ] && note "try: ./zig-out/bin/klio run examples/showcase.kt"
exit 0
