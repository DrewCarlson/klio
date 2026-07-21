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
# Usage:
#   scripts/bootstrap.sh                 # full setup + debug build
#   scripts/bootstrap.sh --release       # build with -Doptimize=ReleaseFast
#   scripts/bootstrap.sh --packs         # also install the shipped packs into ~/.klio
#   scripts/bootstrap.sh --no-skia       # skip the Skia backend (headless-only build)
#   scripts/bootstrap.sh --no-build      # set up sources only, don't compile
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

# --- options ---------------------------------------------------------------
DO_SKIA=1
DO_BUILD=1
DO_PACKS=0
BUILD_ARGS=()

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --release) BUILD_ARGS+=("-Doptimize=ReleaseFast") ;;
        --no-skia) DO_SKIA=0 ;;
        --no-build) DO_BUILD=0 ;;
        --packs) DO_PACKS=1 ;;
        -h|--help) usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
    shift
done

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
step "sparse upstream sources (kotlin stdlib, compose, androidx.collection)"
./scripts/init-kotlin-submodule.sh
./scripts/init-compose-submodule.sh
./scripts/init-androidx-collection-submodule.sh

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
if [ "$DO_BUILD" -eq 1 ]; then
    step "build (zig build ${BUILD_ARGS[*]:-})"
    zig build "${BUILD_ARGS[@]}"
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

    pack_dirs=()
    for d in kotlin-klio/*/; do
        [ -f "${d}klio.toml" ] && pack_dirs+=("${d%/}")
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
