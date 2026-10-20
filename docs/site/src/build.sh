#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# WHAT: Rebuilds the site's data and checks every page, in order.
#   1. data/run.js, data/index.js and data/files/<group>.js from git, the change set, ledger.json and trail.json
#      (src/build.py; its parser runs --self-test first)
#   2. every page from file://, in Chrome, light and dark, desktop and 390 px, with the self-check and the ask
#      orb's stand-in test (src/check.py)
# Arguments go to check.py, such as --prose.
set -euo pipefail
cd "$(dirname "$0")/../../.."
python3 -I docs/site/src/build.py --self-test > /dev/null || python3 -I docs/site/src/build.py --self-test
python3 -I docs/site/src/build.py
python3 -I docs/site/src/check.py "$@"
