#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Rebuilds the README's phase 1 audio plate, Docs/README_Assets/plate-phase1-audio.png, from HTML rendered by
# Google Chrome through Playwright (pip install playwright; it drives the installed Chrome), as the hero is.
set -euo pipefail
repo=${0:A:h:h:h:h}
cd "$repo"
python3 -I Docs/README_Assets/src/build-plate-phase1-audio.py Docs/README_Assets
