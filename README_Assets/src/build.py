# SPDX-License-Identifier: GPL-3.0-only
"""Builds the README's hero from HTML, rendered by the installed Google Chrome through Playwright.

    README_Assets/src/build.sh            # runs this

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts; crop_ben.png's routed result
         as Garde wrote it, Tests/VeilGardeInferenceTests/Fixtures/garde/crop_ben.route.json: its 16×16 tile
         probabilities, its weight map, and the numbers each stage gave it.
Outputs: hero.png in argv[1], 2400×1260 (1200×630 at scale 2), in the style of Veil8's hero.
"""

import json
import math
import os
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
GOLDEN = os.path.join(HERE, "..", "..", "Tests", "VeilGardeInferenceTests", "Fixtures", "garde", "crop_ben.route.json")
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# Veil8's hero colours: green for a tile that reads real, red for one that reads generated.
RED, GREEN, GOLD, LINE = (212, 98, 91), (40, 168, 131), "#c7a659", "#cbc8c0"

Y = 469              # the motif's centre line, as in Veil8's hero
TILE = 7.5           # one 32-pixel tile of the image, drawn
GRID_X = 68          # the mosaic's left edge
LENS = (556, 618)    # the sixteen warps
WORDS_END = 1040     # the stage numbers stop here; a short line runs on to the gold mark at 1102


def shoot(browser, page_html, path, viewport=(1200, 630), scale=2, prepare=None):
    """Writes `page_html` beside the inputs (so relative URLs resolve) and screenshots it, after the fonts load and
    `prepare` (JavaScript) has run."""
    with tempfile.NamedTemporaryFile("w", suffix=".html", dir=HERE, delete=False, encoding="utf-8") as f:
        f.write(page_html)
        name = f.name
    try:
        page = browser.new_page(device_scale_factor=scale, viewport={"width": viewport[0], "height": viewport[1]})
        page.goto("file://" + name)
        page.evaluate("document.fonts.ready.then(() => true)")
        if prepare:
            page.evaluate(prepare)
        page.wait_for_timeout(150)
        page.screenshot(path=path, full_page=True)
        page.close()
    finally:
        os.unlink(name)


def colour(p, alpha=1.0):
    """A tile's P(generated) between green (0.2) and red (0.8), the shipped model's working range."""
    t = min(1.0, max(0.0, (p - 0.2) / 0.6))
    r, g, b = (round(GREEN[k] + (RED[k] - GREEN[k]) * t) for k in range(3))
    return f"rgba({r},{g},{b},{alpha:.3f})"


def mosaic(scores, weights):
    """The 16×16 tiles, each its P(generated); the weight map sets how bright it is."""
    top = Y - 8 * TILE
    wmax = max(max(row) for row in weights)
    cells = []
    for i, row in enumerate(scores):
        for j, p in enumerate(row):
            alpha = 0.55 + 0.45 * (weights[i][j] / wmax) ** 0.5
            cells.append(f'<rect x="{GRID_X + j * TILE:.1f}" y="{top + i * TILE:.1f}" width="{TILE - 1.1:.1f}" height="{TILE - 1.1:.1f}" '
                         f'rx="1" fill="{colour(p, alpha)}"/>')
    return "".join(cells)


def rows(scores):
    """One strand per tile row, carrying the row's mean, narrowing into the centre line at the lens."""
    x0, x1 = GRID_X + 16 * TILE + 10, LENS[0]
    out = []
    for i, row in enumerate(scores):
        y0 = Y - 8 * TILE + (i + 0.5) * TILE
        points = []
        x = x0
        while x <= x1:
            t = (x - x0) / (x1 - x0)
            ease = t * t * (3 - 2 * t)
            wave = 3.2 * math.sin(2 * math.pi * (x - x0) / 150 + i * 0.7) * (1 - t)
            points.append(f"{x:.1f},{y0 + (Y - y0) * ease + wave:.1f}")
            x += 4
        mean = sum(row) / len(row)
        out.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="{colour(mean, 0.9)}" stroke-width="1.6" stroke-linecap="round"/>')
    return "".join(out)


def lens():
    """Sixteen fine threads, the sixteen homographies, each with a slight fold, fading at both ends."""
    x0, x1 = LENS
    threads = []
    for i in range(16):
        x = x0 + (x1 - x0) * i / 15
        points = []
        for step in range(0, 61):
            y = Y - 62 + 124 * step / 60
            fold = 2.0 * math.sin(2 * math.pi * (y - Y) / 64 + i * 0.85)
            points.append(f"{x + fold:.1f},{y:.1f}")
        opacity = 0.14 + 0.24 * math.sin(math.pi * (i + 0.5) / 16)
        threads.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="{LINE}" stroke-width="1.05" stroke-opacity="{opacity:.2f}" mask="url(#fade)"/>')
    return "".join(threads)


def hero(browser, golden):
    scores, weights = golden["patch_scores"], golden["weight_map"]
    tiles = sum(len(r) for r in scores)
    above = sum(1 for r in scores for p in r if p > 0.5)
    stages = [("vote", f"{golden['sensor_raw_p']:.2f}"), ("sensor", f"{golden['sensor_p']:.2f}"),
              ("base", f"{golden['route_diagnostics']['warp_p']:.2f}"), ("stack", f"{golden['verdict']['weighted']['score']:.4f}")]
    words = "".join(f'<span class="stage"><small>{name}</small> {value}</span>' for name, value in stages)
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 57.5px; top: 52px; width: 72px; }}
.caption {{ position: absolute; left: 143.5px; top: 72px; letter-spacing: .3em; font-size: 16.5px; color: #8b8a84; font-variant-numeric: lining-nums; }}
.title {{ position: absolute; left: 34px; top: 132px; padding-left: 40px; font-size: 168px; line-height: 1; font-weight: 500; letter-spacing: -.005em;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; padding-right: 30px; }}
.sub {{ position: absolute; left: 65.5px; top: 326px; font-size: 42px; color: #9b9991; font-variant-numeric: lining-nums; }}
svg {{ position: absolute; left: 0; top: 0; }}
.words {{ position: absolute; left: {LENS[1] + 22}px; top: {Y - 21}px; height: 40px; white-space: nowrap; font-size: 27px; line-height: 40px;
          color: {LINE}; font-variant-numeric: lining-nums; -webkit-mask-image: linear-gradient(90deg, rgba(0,0,0,.5) 0%, #000 22%); }}
.stage {{ margin-right: 16px; }}
.stage small {{ font-size: 16px; color: #8b8a84; letter-spacing: .04em; margin-right: 1px; }}
.legend {{ position: absolute; left: 66px; top: 543px; width: 1050px; display: flex; gap: 32px; align-items: baseline; font-size: 24px; color: #8b8a84;
           font-variant-numeric: lining-nums; white-space: nowrap; }}
.legend b {{ font-weight: 400; color: #e9e7e0; }}
.dot {{ display: inline-block; width: 13px; height: 13px; border-radius: 50%; margin-right: 10px; transform: translateY(-1px); }}
.squares {{ display: inline-flex; gap: 2px; margin-right: 10px; transform: translateY(-1px); }}
.squares i {{ display: inline-block; width: 7px; height: 13px; border-radius: 1px; }}
.threads {{ display: inline-block; width: 15px; height: 17px; margin-right: 10px; transform: translateY(2px); }}
.tag {{ margin-left: auto; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">A DETECTOR FOR AI-GENERATED IMAGES</div>
<div class="title">VeilGarde</div>
<div class="sub">every tile, sixteen warps, one verdict</div>
<svg width="1200" height="630">
  <defs>
    <linearGradient id="fade-y" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="0.3" stop-color="#fff"/>
      <stop offset="0.7" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <mask id="fade" maskUnits="userSpaceOnUse" x="0" y="{Y - 70}" width="1200" height="140">
      <rect x="0" y="{Y - 62}" width="1200" height="124" fill="url(#fade-y)"/></mask>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{LINE}" stop-opacity="0.10"/><stop offset="1" stop-color="{LINE}" stop-opacity="0"/></radialGradient>
  </defs>
  {mosaic(scores, weights)}
  {rows(scores)}
  <ellipse cx="{sum(LENS) / 2}" cy="{Y}" rx="58" ry="70" fill="url(#glow)"/>
  {lens()}
  <line id="tail" x1="{WORDS_END}" y1="{Y}" x2="1092" y2="{Y}" stroke="{LINE}" stroke-width="3" stroke-linecap="round"/>
  <circle cx="1102" cy="{Y}" r="9.5" fill="none" stroke="{GOLD}" stroke-width="2.4"/>
  <circle cx="1102" cy="{Y}" r="4" fill="{GOLD}"/>
</svg>
<div class="words">{words}</div>
<div class="legend">
  <span><i class="squares"><i style="background:{colour(0.2)}"></i><i style="background:{colour(0.5)}"></i><i style="background:{colour(0.8)}"></i></i><b>Tiles</b> · {above} of {tiles} generated</span>
  <span><svg class="threads" viewBox="0 0 15 17" style="position:static"><path d="M2 1 V16 M5.7 1 V16 M9.3 1 V16 M13 1 V16" stroke="{LINE}" stroke-width="1.2" stroke-opacity=".7"/></svg><b>Warps</b> · 16 each</span>
  <span><i class="dot" style="background:{GOLD}"></i><b>Verdict</b> · 3 stages</span>
  <span class="tag">did a camera make this?</span>
</div>
</body></html>"""
    # Drop stages from the front until the last, the verdict, ends short of the gold mark, then run the line from it into the mark.
    fit = f"""(() => {{ const w = document.querySelector('.words'); const limit = {WORDS_END};
        while (w.getBoundingClientRect().right > limit && w.children.length > 1) w.firstElementChild.remove();
        const last = w.lastElementChild ? w.lastElementChild.getBoundingClientRect().right : w.getBoundingClientRect().left;
        document.getElementById('tail').setAttribute('x1', String(Math.round(last + 4))); }})()"""
    shoot(browser, page, os.path.join(OUT, "hero.png"), prepare=fit)


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(GOLDEN, encoding="utf-8") as f:
        golden = json.load(f)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        hero(browser, golden)
        browser.close()
    path = os.path.join(OUT, "hero.png")
    with Image.open(path) as im:
        print(f"hero.png: {im.size[0]}×{im.size[1]}, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
