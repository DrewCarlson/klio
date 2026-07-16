#!/usr/bin/env bash
# The klio version string, parsed from the single source of truth in
# src/cli/cli.zig. Used by release CI to name artifacts.
set -euo pipefail
cd "$(dirname "$0")/.."
sed -n 's/^pub const VERSION = "\(.*\)";$/\1/p' src/cli/cli.zig
