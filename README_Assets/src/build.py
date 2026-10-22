# SPDX-License-Identifier: GPL-3.0-only
"""Builds the README's hero from HTML, rendered by the installed Google Chrome through Playwright.

    README_Assets/src/build.sh            # runs this

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts; crop_ben.png's routed result,
         VeilGarde's own golden, Tests/VeilGardeInferenceTests/Fixtures/crops/crop_ben.route.json: its 16×16
         semantic-tile probabilities and the numbers each stage gave it; and its signature's fixture,
         Tests/VeilWatermarkTests/Fixtures/crop_ben.fr.json: each tile's fragility rate and the signature's id.
Outputs: hero.png in argv[1], 2400×1260 (1200×630 at scale 2), in the style of Veil8's hero: one image's tiles
         feeding two lanes, the verdict above and the signature, through the sixteen warps, below; and README.md's
         links to it tagged ?v=<its hash>, so caches fetch a new hero.
"""

import hashlib
import json
import math
import os
import re
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
GOLDEN = os.path.join(HERE, "..", "..", "Tests", "VeilGardeInferenceTests", "Fixtures", "crops", "crop_ben.route.json")
SIGNATURE = os.path.join(HERE, "..", "..", "Tests", "VeilWatermarkTests", "Fixtures", "crop_ben.fr.json")
README = os.path.join(HERE, "..", "..", "README.md")
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# Veil8's hero colours: green for a tile that reads real, red for one that reads generated.
RED, GREEN, GOLD, LINE = (212, 98, 91), (40, 168, 131), "#c7a659", "#cbc8c0"

Y = 469              # the mosaic's centre line, as in Veil8's hero
LANES = (436, 502)   # the verdict's lane above, the signature's below
TILE = 7.5           # one 32-pixel tile of the image, drawn
GRID_X = 68          # the mosaic's left edge
LENS = (556, 618)    # the sixteen warps, on the signature's lane
REACH = 40           # the warps' half-height about the signature's lane, short of the verdict's
WORDS_END = 1040     # the stage words stop here; a short line runs on to each lane's mark at 1102


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


def mosaic(scores, fragility):
    """The 16×16 tiles, each coloured by its semantic-tile P(generated) and lit by its fragility's rank."""
    top = Y - 8 * TILE
    flat = sorted(v for row in fragility for v in row)
    rank = lambda v: flat.index(v) / max(1, len(flat) - 1)
    cells = []
    for i, row in enumerate(scores):
        for j, p in enumerate(row):
            alpha = 0.45 + 0.55 * rank(fragility[i][j]) ** 0.5
            cells.append(f'<rect x="{GRID_X + j * TILE:.1f}" y="{top + i * TILE:.1f}" width="{TILE - 1.1:.1f}" height="{TILE - 1.1:.1f}" '
                         f'rx="1" fill="{colour(p, alpha)}"/>')
    return "".join(cells)


def strand(i, lane, phase):
    """One tile row's strand from the mosaic into a lane, easing in, a slight wave fading as it arrives."""
    x0, x1 = GRID_X + 16 * TILE + 10, LENS[0]
    y0 = Y - 8 * TILE + (i + 0.5) * TILE
    points = []
    x = x0
    while x <= x1:
        t = (x - x0) / (x1 - x0)
        ease = t * t * (3 - 2 * t)
        wave = 3.2 * math.sin(2 * math.pi * (x - x0) / 150 + i * 0.7 + phase) * (1 - t)
        points.append(f"{x:.1f},{y0 + (lane - y0) * ease + wave:.1f}")
        x += 4
    return " ".join(points)


def rows(scores):
    """Every tile row feeds both lanes: a strand in the row's mean colour into the verdict's lane, and a fine grey one
    into the signature's. The verdict's strands run on as one line, in the image's mean colour, to where the warps end."""
    out = []
    for i, row in enumerate(scores):
        mean = sum(row) / len(row)
        out.append(f'<polyline points="{strand(i, LANES[0], 0)}" fill="none" stroke="{colour(mean, 0.9)}" stroke-width="1.6" stroke-linecap="round"/>')
        out.append(f'<polyline points="{strand(i, LANES[1], 1.9)}" fill="none" stroke="{LINE}" stroke-width="1" stroke-opacity=".42" stroke-linecap="round"/>')
    mean = sum(p for row in scores for p in row) / sum(len(row) for row in scores)
    out.append(f'<line x1="{LENS[0] - 24}" y1="{LANES[0]}" x2="{LENS[1]}" y2="{LANES[0]}" stroke="{colour(mean, 0.9)}" stroke-width="2" stroke-linecap="round"/>')
    return "".join(out)


def lens():
    """Sixteen fine threads on the signature's lane, the sixteen homographies, each with a slight fold, fading at both ends."""
    x0, x1 = LENS
    Y = LANES[1]
    threads = []
    for i in range(16):
        x = x0 + (x1 - x0) * i / 15
        points = []
        for step in range(0, 61):
            y = Y - REACH + 2 * REACH * step / 60
            fold = 2.0 * math.sin(2 * math.pi * (y - Y) / 64 + i * 0.85)
            points.append(f"{x + fold:.1f},{y:.1f}")
        opacity = 0.14 + 0.24 * math.sin(math.pi * (i + 0.5) / 16)
        threads.append(f'<polyline points="{" ".join(points)}" fill="none" stroke="{LINE}" stroke-width="1.05" stroke-opacity="{opacity:.2f}" mask="url(#fade)"/>')
    return "".join(threads)


def hero(browser, golden, signature):
    member = {m["name"]: m for m in golden["stack"]}
    combiner = next(r for r in golden["revisions"] if r["name"] == "combiner")
    scores = member["semantic-tiles"]["grid"]
    cols = signature["cols"]
    fragility = [signature["fr"][r * cols:(r + 1) * cols] for r in range(signature["rows"])]
    tiles = sum(len(r) for r in scores)
    above = sum(1 for r in scores for p in r if p > 0.5)
    verdict = golden["verdict"]
    stages = [("base", f"{member['camera']['p']:.2f}"), ("stack", f"{combiner['p']:.4f}"),
              ("verdict", verdict["prediction"])]
    marks = [("fr", f"{tiles} tiles"), ("bits", "4 a tile"), ("vw1", signature["cid"][:8])]
    words = "".join(f'<span class="stage"><small>{name}</small> {value}</span>' for name, value in stages)
    words2 = "".join(f'<span class="stage"><small>{name}</small> {value}</span>' for name, value in marks)
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
.words {{ position: absolute; left: {LENS[1] + 22}px; height: 40px; white-space: nowrap; font-size: 27px; line-height: 40px;
          color: {LINE}; font-variant-numeric: lining-nums; -webkit-mask-image: linear-gradient(90deg, rgba(0,0,0,.5) 0%, #000 22%); }}
#w1 {{ top: {LANES[0] - 21}px; }} #w2 {{ top: {LANES[1] - 21}px; font-size: 23px; color: #a9a69d; }}
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
<div class="caption">AN AI-IMAGE DETECTOR AND A WATERMARK</div>
<div class="title">VeilGarde</div>
<div class="sub">one verdict, and a signature that survives a crop</div>
<svg width="1200" height="630">
  <defs>
    <linearGradient id="fade-y" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="0.3" stop-color="#fff"/>
      <stop offset="0.7" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <mask id="fade" maskUnits="userSpaceOnUse" x="0" y="{LANES[1] - REACH - 8}" width="1200" height="{2 * REACH + 16}">
      <rect x="0" y="{LANES[1] - REACH}" width="1200" height="{2 * REACH}" fill="url(#fade-y)"/></mask>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="{LINE}" stop-opacity="0.10"/><stop offset="1" stop-color="{LINE}" stop-opacity="0"/></radialGradient>
  </defs>
  {mosaic(scores, fragility)}
  {rows(scores)}
  <ellipse cx="{sum(LENS) / 2}" cy="{LANES[1]}" rx="58" ry="{REACH + 8}" fill="url(#glow)"/>
  {lens()}
  <line id="tail1" x1="{WORDS_END}" y1="{LANES[0]}" x2="1092" y2="{LANES[0]}" stroke="{LINE}" stroke-width="3" stroke-linecap="round"/>
  <circle cx="1102" cy="{LANES[0]}" r="9.5" fill="none" stroke="{GOLD}" stroke-width="2.4"/>
  <circle cx="1102" cy="{LANES[0]}" r="4" fill="{GOLD}"/>
  <line id="tail2" x1="{WORDS_END}" y1="{LANES[1]}" x2="1093" y2="{LANES[1]}" stroke="{LINE}" stroke-width="2" stroke-linecap="round" stroke-opacity=".7"/>
  <rect x="1094" y="{LANES[1] - 8}" width="16" height="16" rx="2" fill="none" stroke="{LINE}" stroke-width="2"/>
  <rect x="1099" y="{LANES[1] - 3}" width="6" height="6" rx="1" fill="{LINE}"/>
</svg>
<div class="words" id="w1">{words}</div>
<div class="words" id="w2">{words2}</div>
<div class="legend">
  <span><i class="squares"><i style="background:{colour(0.2)}"></i><i style="background:{colour(0.5)}"></i><i style="background:{colour(0.8)}"></i></i><b>Tiles</b> · {above} of {tiles} read generated</span>
  <span><i class="dot" style="background:{GOLD}"></i><b>Verdict</b> · base, then stack</span>
  <span><svg class="threads" viewBox="0 0 15 17" style="position:static"><path d="M2 1 V16 M5.7 1 V16 M9.3 1 V16 M13 1 V16" stroke="{LINE}" stroke-width="1.2" stroke-opacity=".7"/></svg><b>Signature</b> · 16 warps</span>
  <span class="tag">two lanes</span>
</div>
</body></html>"""
    # On each lane, drop words from the front until the last ends short of the lane's mark, then run the line from it into the mark.
    fit = f"""(() => {{ for (const [id, tail] of [['w1', 'tail1'], ['w2', 'tail2']]) {{ const w = document.getElementById(id); const limit = {WORDS_END};
        while (w.getBoundingClientRect().right > limit && w.children.length > 1) w.firstElementChild.remove();
        const last = w.lastElementChild ? w.lastElementChild.getBoundingClientRect().right : w.getBoundingClientRect().left;
        document.getElementById(tail).setAttribute('x1', String(Math.round(last + 4))); }} }})()"""
    shoot(browser, page, os.path.join(OUT, "hero.png"), prepare=fit)


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(GOLDEN, encoding="utf-8") as f:
        golden = json.load(f)
    with open(SIGNATURE, encoding="utf-8") as f:
        signature = json.load(f)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        hero(browser, golden, signature)
        browser.close()
    path = os.path.join(OUT, "hero.png")
    with Image.open(path) as im:
        print(f"hero.png: {im.size[0]}×{im.size[1]}, {os.path.getsize(path) // 1024} KB")
    # The README links the hero with its hash as a query, so a new hero is a new URL and no cache keeps the old one.
    with open(path, "rb") as f:
        version = hashlib.sha256(f.read()).hexdigest()[:8]
    with open(README, encoding="utf-8") as f:
        text = f.read()
    tagged = re.sub(r"README_Assets/hero\.png(\?v=[0-9a-f]+)?", f"README_Assets/hero.png?v={version}", text)
    if tagged != text:
        with open(README, "w", encoding="utf-8") as f:
            f.write(tagged)
    print(f"README.md: hero.png?v={version}")


if __name__ == "__main__":
    main()
