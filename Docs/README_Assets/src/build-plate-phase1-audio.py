# SPDX-License-Identifier: GPL-3.0-only
"""Builds a plate for the README, Docs/README_Assets/plate-phase1-audio.png: the watermark on sound's phase 1,
a clip drawn as its spectrogram and the mark signing that picture unchanged, rendered by Google Chrome through
Playwright, in the hero's own style.

    Docs/README_Assets/src/build-plate-phase1-audio.sh       # runs this

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts; the two profiles' pinned
         signatures, Tests/VeilGardeAudioTests/Fixtures/raos_theme_30s_8s.music.fr.json and
         say_samantha_12s.speech.fr.json: each tile's fragility rate, the signature's id and the round trip's
         measured SNRs, held exactly by ResidualTests' sibling, VeilGardeAudioTests.
Outputs: plate-phase1-audio.png in argv[1], 2400×1260 (1200×630 at scale 2), two lanes, music and speech, each a
         clip's spectrogram tiles lit by fragility, signed, and carried back to sound.
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
FIXTURES = os.path.join(HERE, "..", "..", "..", "Tests", "VeilGardeAudioTests", "Fixtures")
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

GOLD, LINE, LOW = "#c7a659", "#cbc8c0", (58, 61, 66)
GOLD_RGB = (199, 166, 89)

LANES = [
    {"file": "raos_theme_30s_8s.music.fr.json", "label": "MUSIC", "rate": "44.1 kHz", "y": 236},
    {"file": "say_samantha_12s.speech.fr.json", "label": "SPEECH", "rate": "16 kHz", "y": 416},
]
MOSAIC_X, MOSAIC_W, LANE_H = 196, 330, 150
SIGN_X = 586
WORDS_X = 650


def shoot(browser, page_html, path, viewport=(1200, 630), scale=2, prepare=None):
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


def ramp(rank):
    r, g, b = (round(LOW[k] + (GOLD_RGB[k] - LOW[k]) * rank) for k in range(3))
    return f"rgb({r},{g},{b})"


def mosaic(fr, rows, cols, x0, y0, w, h):
    """The profile's tile rows and columns, each lit by its own fragility's rank among the clip's tiles."""
    tile_w, tile_h = w / cols, h / rows
    flat = sorted(fr)
    rank = lambda v: flat.index(v) / max(1, len(flat) - 1)
    cells = []
    for r in range(rows):
        for c in range(cols):
            v = fr[r * cols + c]
            cells.append(f'<rect x="{x0 + c * tile_w:.1f}" y="{y0 + r * tile_h:.1f}" width="{tile_w - 0.6:.1f}" '
                         f'height="{tile_h - 0.6:.1f}" rx="0.6" fill="{ramp(rank(v))}"/>')
    return "".join(cells)


def lane(fixture, label, rate, y):
    rows, cols = fixture["rows"], fixture["cols"]
    fr = fixture["fr"]
    snr = fixture["measured"]
    mid = y + LANE_H / 2
    parts = [
        f'<text x="66" y="{mid - 8:.1f}" class="lane-label">{label}</text>',
        f'<text x="66" y="{mid + 18:.1f}" class="lane-rate">{rate}</text>',
        f'<text x="66" y="{mid + 40:.1f}" class="lane-grid">{rows}×{cols} tiles</text>',
        mosaic(fr, rows, cols, MOSAIC_X, y, MOSAIC_W, LANE_H),
        f'<line x1="{MOSAIC_X + MOSAIC_W + 14}" y1="{mid:.1f}" x2="{SIGN_X - 10}" y2="{mid:.1f}" '
        f'stroke="{LINE}" stroke-width="1.6" stroke-opacity=".6" stroke-dasharray="1.2 5"/>',
        f'<rect x="{SIGN_X - 8}" y="{mid - 8:.1f}" width="16" height="16" rx="2" fill="none" stroke="{GOLD}" stroke-width="2"/>',
        f'<rect x="{SIGN_X - 3}" y="{mid - 3:.1f}" width="6" height="6" rx="1" fill="{GOLD}"/>',
        f'<line x1="{SIGN_X + 10}" y1="{mid:.1f}" x2="{WORDS_X - 6}" y2="{mid:.1f}" stroke="{LINE}" stroke-width="1.4" stroke-opacity=".6"/>',
    ]
    words = (f'<span class="stage"><small>cid</small> {fixture["cid"][:10]}</span>'
             f'<span class="stage"><small>bits</small> {fixture["bits"]}</span>'
             f'<span class="stage"><small>round trip</small> {snr["exactSNR"]:.0f} dB exact · {snr["imageSNR"]:.0f} dB from the picture</span>')
    return "".join(parts), words, mid


def plate(browser, fixtures):
    svg_parts, words_blocks = [], []
    for spec, fixture in fixtures:
        svg, words, mid = lane(fixture, spec["label"], spec["rate"], spec["y"])
        svg_parts.append(svg)
        words_blocks.append((words, mid))
    words_html = "".join(f'<div class="words" style="top:{mid - 13:.1f}px">{w}</div>' for w, mid in words_blocks)
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 57.5px; top: 34px; width: 72px; }}
.caption {{ position: absolute; left: 143.5px; top: 54px; letter-spacing: .3em; font-size: 16.5px; color: #8b8a84; font-variant-numeric: lining-nums; }}
.title {{ position: absolute; left: 66px; top: 100px; padding-bottom: 24px; font-size: 54px; line-height: 1; font-weight: 500; letter-spacing: -.005em;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; }}
.sub {{ position: absolute; left: 67px; top: 174px; font-size: 22px; color: #9b9991; font-variant-numeric: lining-nums; }}
svg {{ position: absolute; left: 0; top: 0; }}
.lane-label {{ font-size: 20px; letter-spacing: .08em; fill: #e9e7e0; font-style: normal; font-variant-numeric: lining-nums; }}
.lane-rate {{ font-size: 15px; fill: #8b8a84; font-style: normal; font-variant-numeric: lining-nums; }}
.lane-grid {{ font-size: 14px; fill: #726f68; font-style: normal; font-variant-numeric: lining-nums; }}
.words {{ position: absolute; left: {WORDS_X}px; width: {1200 - WORDS_X - 66}px; font-size: 18px; line-height: 26px;
          color: {LINE}; font-variant-numeric: lining-nums; }}
.stage {{ margin-right: 18px; }}
.stage small {{ font-size: 13px; color: #8b8a84; letter-spacing: .04em; margin-right: 1px; }}
.legend {{ position: absolute; left: 66px; top: 574px; width: 1068px; display: flex; gap: 32px; align-items: baseline; font-size: 18px; color: #8b8a84;
           font-variant-numeric: lining-nums; white-space: nowrap; }}
.legend b {{ font-weight: 400; color: #e9e7e0; }}
.ramp {{ display: inline-block; width: 42px; height: 10px; border-radius: 2px; margin-right: 10px; transform: translateY(1px);
         background: linear-gradient(90deg, rgb({LOW[0]},{LOW[1]},{LOW[2]}) 0%, {GOLD} 100%); }}
.sq {{ display: inline-block; width: 11px; height: 11px; border-radius: 2px; border: 2px solid {GOLD}; margin-right: 10px; transform: translateY(1px); }}
.tag {{ margin-left: auto; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">THE WATERMARK'S SECOND CARRIER</div>
<div class="title">a clip, drawn as its spectrogram</div>
<div class="sub">phase 1 (2026-11-08) &middot; the mark signs that picture, unchanged</div>
<svg width="1200" height="630">{"".join(svg_parts)}</svg>
{words_html}
<div class="legend">
  <span><i class="ramp"></i><b>Fragility</b> &middot; a tile's rank among the clip's own</span>
  <span><i class="sq"></i><b>Signature</b> &middot; read off the tiles, added to none</span>
  <span class="tag">two profiles, not yet merged</span>
</div>
</body></html>"""
    shoot(browser, page, os.path.join(OUT, "plate-phase1-audio.png"))


def main():
    import json
    os.makedirs(OUT, exist_ok=True)
    fixtures = []
    for spec in LANES:
        with open(os.path.join(FIXTURES, spec["file"]), encoding="utf-8") as f:
            fixtures.append((spec, json.load(f)))
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        plate(browser, fixtures)
        browser.close()
    path = os.path.join(OUT, "plate-phase1-audio.png")
    from PIL import Image
    with Image.open(path) as im:
        print(f"plate-phase1-audio.png: {im.size[0]}×{im.size[1]}, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
