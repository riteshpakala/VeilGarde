#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# WHAT: Build the examples (release), put MLX's Metal library beside the binary when it is
#       missing, and run it. Arguments go to the examples program: `run.sh clean` removes Examples/.work.
# IN:   VEILGARDE_METALLIB=rebuild reinstalls mlx.metallib (after a Frigate/MLX update).
#       VEILGARDE_FRIGATE_DIR as everywhere: else a Frigate checkout beside the repo.
# PIN:  One MLX workload at a time: never beside training, the parity sweep or GPU tests.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
# Frigate, the vendored MLX stack, is taken by path: VEILGARDE_FRIGATE_DIR, else a checkout beside this repo
# (https://github.com/rao-studios/Frigate). A machine's own settings, kept in a gitignored scripts/lib.sh, come first.
[ -f "$REPO_ROOT/scripts/lib.sh" ] && source "$REPO_ROOT/scripts/lib.sh"
VEILGARDE_FRIGATE_DIR="${VEILGARDE_FRIGATE_DIR:-$REPO_ROOT/../Frigate}"
if [ ! -f "$VEILGARDE_FRIGATE_DIR/Package.swift" ]; then
    echo "veilgarde: no Frigate at $VEILGARDE_FRIGATE_DIR: check it out beside this repo, or set VEILGARDE_FRIGATE_DIR" >&2
    exit 69
fi
export VEILGARDE_FRIGATE_DIR="$(cd "$VEILGARDE_FRIGATE_DIR" && pwd)"
export GIT_LFS_SKIP_SMUDGE=1    # Frigate's LFS fixtures break SwiftPM checkouts otherwise
if [ "${1:-}" = "clean" ]; then
    rm -rf "$HERE/.work"
    echo "run.sh: removed Examples/.work" >&2
    exit 0
fi
echo "run.sh: building the examples (release)" >&2
swift build --package-path "$HERE" -c release --product VeilGardeExamples -q >&2
bin_dir="$(swift build --package-path "$HERE" -c release --show-bin-path)"
if [ ! -f "$bin_dir/mlx.metallib" ] || [ "${VEILGARDE_METALLIB:-}" = "rebuild" ]; then
    echo "run.sh: installing mlx.metallib beside the binary" >&2
    "$VEILGARDE_FRIGATE_DIR/scripts/build-metallib.sh" release --package "$HERE" > /dev/null
fi
exec "$bin_dir/VeilGardeExamples" "$@"
