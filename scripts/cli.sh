#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# WHAT: Run the veilgarde CLI from a checkout: build it when a source is newer than the binary
#       (VeilGarde's or Frigate's), put MLX's Metal library beside it the first time, then hand
#       every argument to veilgarde.
# IN:   Arguments go to veilgarde unchanged.
#       VEILGARDE_CONFIG=release   build and run the release binary (default debug); use it for
#                                  anything that trains, extracts at scale or measures
#       VEILGARDE_BUILD=always     run swift build even when nothing looks newer
#       VEILGARDE_SKIP_BUILD=1     run the binary that is already built
#       VEILGARDE_METALLIB=rebuild reinstall mlx.metallib (after a Frigate/MLX update)
# PIN:  Never changes directory, so relative paths in the arguments resolve against yours. Build
#       chatter goes to stderr and veilgarde's own output to stdout, so
#       `scripts/cli.sh route x.jpg --json | jq` stays clean. The metallib is only installed when
#       it is missing (build-metallib.sh also copies it into the test bundles, which must be
#       stripped of it again before the next test build: a copy breaks the bundle's re-sign).
#
#   scripts/cli.sh doctor
#   scripts/cli.sh route photo.jpg --json
#   VEILGARDE_CONFIG=release scripts/cli.sh train warp --dataset final_mixed
#
set -euo pipefail

source_path="${BASH_SOURCE[0]}"
while [ -L "$source_path" ]; do
    target="$(readlink "$source_path")"
    case "$target" in
        /*) source_path="$target" ;;
        *) source_path="$(dirname "$source_path")/$target" ;;
    esac
done
REPO_ROOT="$(cd "$(dirname "$source_path")/.." && pwd)"
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

config="${VEILGARDE_CONFIG:-debug}"
case "$config" in
    debug | release) ;;
    *)
        echo "cli.sh: VEILGARDE_CONFIG must be debug or release, not '$config'" >&2
        exit 64
        ;;
esac

# SwiftPM's build system decides where products land (.build/out/Products/<Config> today): ask it.
bin_dir="$(swift build --package-path "$REPO_ROOT" -c "$config" --show-bin-path 2>/dev/null)"
binary="$bin_dir/veilgarde"

watched=()
for path in "$REPO_ROOT/Sources" "$REPO_ROOT/Package.swift" \
    "$VEILGARDE_FRIGATE_DIR/Sources" "$VEILGARDE_FRIGATE_DIR/Package.swift"; do
    [ -e "$path" ] && watched+=("$path")
done

needs_build() {
    [ "${VEILGARDE_BUILD:-}" = "always" ] && return 0
    [ -x "$binary" ] || return 0
    [ -n "$(find "${watched[@]}" -newer "$binary" -type f -not -name '._*' -print -quit 2>/dev/null)" ]
}

if [ -z "${VEILGARDE_SKIP_BUILD:-}" ] && needs_build; then
    echo "cli.sh: building veilgarde ($config)" >&2
    if ! swift build --package-path "$REPO_ROOT" -c "$config" --product veilgarde -q >&2; then
        echo "cli.sh: swift build -c $config failed" >&2
        exit 1
    fi
    bin_dir="$(swift build --package-path "$REPO_ROOT" -c "$config" --show-bin-path)"
    binary="$bin_dir/veilgarde"
    touch "$binary"
fi
if [ ! -x "$binary" ]; then
    echo "cli.sh: no veilgarde binary in $bin_dir" >&2
    echo "  build it first, or unset VEILGARDE_SKIP_BUILD" >&2
    exit 1
fi

if [ ! -f "$bin_dir/mlx.metallib" ] || [ "${VEILGARDE_METALLIB:-}" = "rebuild" ]; then
    echo "cli.sh: installing mlx.metallib beside the $config binary" >&2
    "$REPO_ROOT/build-metallib.sh" "$config" > /dev/null
fi

exec "$binary" "$@"
