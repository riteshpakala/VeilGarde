#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Gives the site's ask orb this Mac's Mistral key, when it holds one.

    python3 -I Docs/site/src/askkey.py                   # write Docs/site/local/ask.js from the environment or ~/.rao
    python3 -I Docs/site/src/askkey.py --model <name>    # another Mistral model than mistral-large-4
    python3 -I Docs/site/src/askkey.py --remove          # delete it

The key is read from the MISTRAL_API_KEY environment variable, else from a local key store,
~/.rao/keys/providers.json, whose MISTRAL_API_KEY entry is {value, writtenBy, ...}. It is written to
Docs/site/local/ask.js with mode 600, and only after git confirms it ignores that path. Nothing here prints the key.
Scripts/site.command runs this before it opens the site. The orb works without it too: the reader can paste a key,
which stays in that browser only.

The model is mistral-large-4 with its reasoning off: left on, Large 4 can spend its tokens reasoning and return an
empty answer (measured from a page on disk on 2026-10-18).
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parents[1]
REPO = SITE.parents[1]
OUT = SITE / "local" / "ask.js"
STORE = Path.home() / ".rao" / "keys" / "providers.json"
MODEL = "mistral-large-4"


def read_key():
    """(key, where it came from), or (None, None). The key is never printed."""
    env = os.environ.get("MISTRAL_API_KEY", "").strip()
    if env:
        return env, "the MISTRAL_API_KEY environment variable"
    try:
        entry = json.loads(STORE.read_text(encoding="utf-8")).get("MISTRAL_API_KEY") or {}
    except (OSError, ValueError, AttributeError):
        return None, None
    value = (entry.get("value") or "").strip() if isinstance(entry, dict) else ""
    return (value, f"this Mac's key store, written by {entry.get('writtenBy') or 'an app'}") if value else (None, None)


def ignored(path):
    """True when git ignores the path, so the key can never be committed from it."""
    r = subprocess.run(["git", "-C", str(REPO), "check-ignore", "-q", str(path.relative_to(REPO))],
                       capture_output=True, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
    return r.returncode == 0


def main():
    parser = argparse.ArgumentParser(description="Copy this Mac's Mistral key into Docs/site/local/ask.js (gitignored).")
    parser.add_argument("--remove", action="store_true", help="delete Docs/site/local/ask.js")
    parser.add_argument("--model", default=MODEL, help=f"the Mistral model the orb asks (default {MODEL})")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if args.remove:
        if OUT.exists():
            OUT.unlink()
        print("ask: removed Docs/site/local/ask.js")
        return 0
    key, source = read_key()
    if not key:
        if not args.quiet:
            print(f"ask: no Mistral key in the environment or {STORE}; the orb will ask for one")
        return 0
    if not ignored(OUT):
        print("ask: git does not ignore Docs/site/local/ask.js, so the key was not written; add /Docs/site/local/ to .gitignore", file=sys.stderr)
        return 1
    config = {"provider": "mistral", "model": args.model, "reasoning": "none", "key": key, "source": source}
    text = ("/* written by Docs/site/src/askkey.py from this Mac's key - local only, gitignored, never commit */\n"
            "window.VeilGardeData = window.VeilGardeData || {};\n"
            f"window.VeilGardeData.ask = {json.dumps(config)};\n")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(OUT, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(OUT, 0o600)
    if not args.quiet:
        print(f"ask: the orb uses {args.model} with the key from {source} (Docs/site/local/ask.js, gitignored, mode 600)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except OSError as e:
        print(f"ask: {e}", file=sys.stderr)
        sys.exit(1)
