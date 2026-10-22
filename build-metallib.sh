#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# WHAT: Build MLX's mlx.metallib into this package's .build.
# IN:   [debug|release] (default debug). VEILGARDE_FRIGATE_DIR overrides where Frigate lives.
# OUT:  mlx.metallib beside every VeilGarde binary and inside every .xctest bundle.
# PIN:  A delegate, not an implementation. Frigate owns the vendored .metal sources, so it owns the
#       compile; `swift build` has no Metal step, and without this script the first GPU op dies
#       with "Failed to load the default metallib". Run it after `swift build` (or
#       `swift build --build-tests`), because it installs into the existing .build tree.
#
#   ./build-metallib.sh [debug|release]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Frigate, the vendored MLX stack, is taken by path: VEILGARDE_FRIGATE_DIR, else a checkout beside this repo
# (https://github.com/rao-studios/Frigate). A machine's own settings, kept in a gitignored Scripts/lib.sh, come first.
[ -f "$REPO_ROOT/Scripts/lib.sh" ] && source "$REPO_ROOT/Scripts/lib.sh"
VEILGARDE_FRIGATE_DIR="${VEILGARDE_FRIGATE_DIR:-$REPO_ROOT/../Frigate}"
if [ ! -f "$VEILGARDE_FRIGATE_DIR/Package.swift" ]; then
    echo "veilgarde: no Frigate at $VEILGARDE_FRIGATE_DIR: check it out beside this repo, or set VEILGARDE_FRIGATE_DIR" >&2
    exit 69
fi
export VEILGARDE_FRIGATE_DIR="$(cd "$VEILGARDE_FRIGATE_DIR" && pwd)"
export GIT_LFS_SKIP_SMUDGE=1    # Frigate's LFS fixtures break SwiftPM checkouts otherwise
CANONICAL="$VEILGARDE_FRIGATE_DIR/scripts/build-metallib.sh"

if [ ! -x "$CANONICAL" ]; then
    echo "build-metallib: cannot find $CANONICAL" >&2
    echo "  Set VEILGARDE_FRIGATE_DIR to your Frigate checkout." >&2
    exit 1
fi

exec "$CANONICAL" "${1:-debug}" --package "$REPO_ROOT"
