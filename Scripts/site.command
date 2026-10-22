#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
# WHAT: Open VeilGarde's site, the change explorer and its chapters in Docs/site, in the default browser.
#       Double-click it in Finder, or run Scripts/site.command from anywhere.
# PIN:  The site is plain HTML read from file://, so nothing is built or served. Docs/site/src/build.sh
#       regenerates its data and checks every page. The one thing this writes is Docs/site/local/ask.js, the
#       ask orb's Mistral key copied from this Mac, which git ignores.
set -euo pipefail
cd "$(dirname "$0")/.."
page="Docs/site/index.html"
if [[ ! -f "$page" ]]; then
  echo "site.command: no $page under $(pwd)" >&2
  exit 1
fi
# The ask orb uses this Mac's Mistral key, when it holds one, copied to a gitignored file.
python3 -I Docs/site/src/askkey.py || true
open "$page"
echo "opened $(pwd)/$page"
