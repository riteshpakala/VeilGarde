#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# Rebuilds the README's hero, README_Assets/hero.png, from HTML rendered by Google Chrome through
# Playwright (pip install playwright; it drives the installed Chrome), as Veil8's and Braid's heroes are.
set -euo pipefail
repo=${0:A:h:h:h}
cd "$repo"
python3 -I README_Assets/src/build.py README_Assets
