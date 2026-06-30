#!/usr/bin/env python3
"""
Export Seek and Destroy bitmap fonts for the Love2D engine (assets/fonts/).

These fonts are sprite containers, one frame per glyph (frame count =
u32[0] / 4). Most are world-sprite-format and decode with the exact stage
decoder (tools/decode_blitter.py); the in-game body fonts CHARS.BIN and
CHARSPOW.BIN are the raw planar HUD class and decode with decode_planar.py.
Each font is routed to the right decoder automatically by decode_planar.is_planar.

Most glyph pixels are palette indices forming a brightness ramp the engine
tints at runtime, so we export those as a white-on-alpha intensity MASK
(rank-normalized over the index ramp, lower index = brighter) and let the
engine tint each font to any color (engine/font.lua). Fonts that carry their
real in-file colors are exported truecolor instead: OVERKILL (per stage), and
the in-game body fonts CHARS/CHARSPOW, whose glyphs hold a fixed gold-on-black
ramp (idx 16 black outline, 23-26 gold) under GOVPAL.BIN that the original HUD
draws untinted. A flat tint loses the baked outline and gradient.

Output per font:
  assets/fonts/<name>.png    one packed atlas of all glyphs
  assets/fonts/<name>.json   metrics: per-frame {x,y,w,h,ox,oy,advance}

Glyphs are keyed by frame index. The character mapping (which frame is which
letter) is added after visual inspection in the F-key gallery and stored as
"charmap" in the JSON.

Usage:
  export_fonts.py            # all fonts
  export_fonts.py phasenum gov overkill
  export_fonts.py --game-dir ~/dos/seek
"""

import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import decode_blitter as db
import decode_planar as dp

try:
    from PIL import Image
except ImportError:
    print("ERROR: Pillow is required. Install with: pip install pillow", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "fonts"
ATLAS_WIDTH = 512
GLYPH_PAD = 1
BLIT_ORIGIN_Y = 100  # decode_frame anchors the blit at y0 = 100

# Full sets (endchars/hichars/hichars2/keysfont/savechar) are ASCII-indexed:
# frame index == codepoint (verified: 48='0', 65='A', 32=space). They carry no
# explicit charmap and the engine treats a null charmap as ASCII identity.
# Word fonts (gov/overkill) hold one sequence of word/letter glyphs drawn left
# to right rather than an addressable character set.
#
# name -> { src: path under the game dir, mode: "mask"|"truecolor", pal,
#           charmap: per-frame char string (frame i -> charmap[i]),
#           word: True for sequence-only fonts }
FONTS = {
    "chars":    {"src": "data/CHARS.BIN",     "mode": "truecolor",
                 "pal": "data/GOVPAL.BIN"},
    "charspow": {"src": "data/CHARSPOW.BIN",  "mode": "truecolor",
                 "pal": "data/GOVPAL.BIN"},
    "phasenum": {"src": "data/PHASENUM.BIN", "mode": "mask", "charmap": "1234"},
    "gov":      {"src": "data/GOV.BIN",       "mode": "mask", "word": True},
    "gov2":     {"src": "data/GOV2.BIN",      "mode": "mask", "word": True},
    "endchars": {"src": "data/ENDCHARS.BIN",  "mode": "mask",
                 "pal": "STAGE00/PAL.BIN", "key": [255, 0, 255]},
    "hichars":  {"src": "data/HICHARS.BIN",   "mode": "mask"},
    "hichars2": {"src": "data/HICHARS2.BIN",  "mode": "mask"},
    "keysfont": {"src": "data/KEYSFONT.BIN",  "mode": "mask"},
    "savechar": {"src": "data/SAVECHAR.BIN",  "mode": "mask"},
    "overkill": {"src": "STAGE00/OVERKILL.BIN", "mode": "truecolor",
                 "pal": "STAGE00/PAL.BIN", "word": True},
}

# darkest ramp index still renders at this intensity, so shaded edges stay visible
MIN_INTENSITY = 0.45


def find_game_dir(override: str | None) -> Path:
    candidates = []
    if override:
        candidates.append(Path(override).expanduser())
    candidates += [ROOT, Path("~/dos/seek").expanduser()]
    for c in candidates:
        if (c / "data" / "PHASENUM.BIN").exists():
            return c
    print("ERROR: could not find the game files (data/PHASENUM.BIN). "
          "Pass --game-dir.", file=sys.stderr)
    sys.exit(1)


def load_palette(path: Path):
    p = path.read_bytes()
    return [((p[i*3] << 2) | (p[i*3] >> 4),
             (p[i*3+1] << 2) | (p[i*3+1] >> 4),
             (p[i*3+2] << 2) | (p[i*3+2] >> 4)) for i in range(256)]


def decode_glyphs(data: bytes):
    """Return [(canvas dict, min_x, min_y, w, h)] per frame, skipping empties."""
    dec = dp if dp.is_planar(data) else db
    glyphs = []
    for off, end in dec.read_frames(data):
        canvas, status = dec.decode_frame(data, off, end)
        if not canvas or status != "ok":
            glyphs.append(None)
            continue
        xs = [c[0] for c in canvas]
        ys = [c[1] for c in canvas]
        glyphs.append((canvas, min(xs), min(ys), max(xs) - min(xs) + 1,
                       max(ys) - min(ys) + 1))
    return glyphs


def mask_ramp(glyphs, palette, key):
    """Per-index mask intensity. With a palette, derive it from real luminance
    (brightest used index -> 1.0) and drop key-colored (transparent) pixels;
    that handles 2-tone fonts (e.g. ENDCHARS: white glyph + magenta key) the
    raw index rank would invert. Without a palette, rank-normalize the index
    ramp (lowest -> 1.0, highest -> MIN). Returns (ramp, keyset)."""
    used = sorted({p for g in glyphs if g for p in g[0].values()})
    if palette:
        keyset = {i for i in used if key and palette[i] == tuple(key)}
        lums = {i: 0.299 * palette[i][0] + 0.587 * palette[i][1]
                   + 0.114 * palette[i][2]
                for i in used if i not in keyset}
        mx = max(lums.values()) if lums else 1.0
        ramp = {i: max(MIN_INTENSITY, lum / (mx or 1.0)) for i, lum in lums.items()}
        return ramp, keyset
    if len(used) <= 1:
        return {i: 1.0 for i in used}, set()
    span = len(used) - 1
    return ({idx: 1.0 - (rank / span) * (1.0 - MIN_INTENSITY)
             for rank, idx in enumerate(used)}, set())


def render_glyph(glyph, mode, ramp, keyset, palette):
    canvas, min_x, min_y, w, h = glyph
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    for (x, y), idx in canvas.items():
        if mode == "truecolor":
            r, g, b = palette[idx]
        else:
            if idx in keyset:
                continue
            v = int(round(ramp.get(idx, 1.0) * 255))
            r = g = b = v
        px[x - min_x, y - min_y] = (r, g, b, 255)
    return img


def pack(images):
    """Shelf-pack [(key, img, min_x, min_y)] into one atlas. Returns (atlas, meta)."""
    items = sorted(images, key=lambda it: -it[1].height)
    x = y = row_h = 0
    placed = {}
    for key, img, min_x, min_y in items:
        if x + img.width + GLYPH_PAD > ATLAS_WIDTH:
            x = 0
            y += row_h + GLYPH_PAD
            row_h = 0
        placed[key] = (x, y, img, min_x, min_y)
        x += img.width + GLYPH_PAD
        row_h = max(row_h, img.height)
    atlas_h = y + row_h
    atlas = Image.new("RGBA", (ATLAS_WIDTH, atlas_h), (0, 0, 0, 0))
    meta = {}
    for key, (gx, gy, img, min_x, min_y) in placed.items():
        atlas.paste(img, (gx, gy), img)
        meta[key] = {"x": gx, "y": gy, "w": img.width, "h": img.height,
                     "ox": min_x, "oy": min_y}
    return atlas, meta


def export_font(name, cfg, game_dir):
    src = game_dir / cfg["src"]
    if not src.exists():
        print(f"  SKIP {name}: missing {src}")
        return
    data = src.read_bytes()
    glyphs = decode_glyphs(data)
    palette = load_palette(game_dir / cfg["pal"]) if cfg.get("pal") else None
    if cfg["mode"] == "truecolor":
        ramp, keyset = {}, set()
    else:
        ramp, keyset = mask_ramp(glyphs, palette, cfg.get("key"))

    images = []
    for i, g in enumerate(glyphs):
        if not g:
            continue
        img = render_glyph(g, cfg["mode"], ramp, keyset, palette)
        images.append((str(i), img, g[1], g[2]))
    if not images:
        print(f"  SKIP {name}: no decodable glyphs")
        return

    atlas, glyph_meta = pack(images)

    oy_min = min(m["oy"] for m in glyph_meta.values())
    line_height = max(m["oy"] - oy_min + m["h"] for m in glyph_meta.values())
    glyphs_out = {}
    for key, m in glyph_meta.items():
        glyphs_out[key] = {
            "x": m["x"], "y": m["y"], "w": m["w"], "h": m["h"],
            "ox": m["ox"], "oy": m["oy"] - oy_min,
            "advance": m["w"] + 1,
        }

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    atlas.save(OUT_DIR / f"{name}.png")
    meta = {
        "name": name,
        "image": f"{name}.png",
        "mode": cfg["mode"],
        "line_height": line_height,
        "glyphs": glyphs_out,
        "charmap": cfg.get("charmap", None),
        "word": cfg.get("word", False),
    }
    (OUT_DIR / f"{name}.json").write_text(json.dumps(meta, indent=2))
    print(f"  {name}: {len(glyphs_out)} glyphs, atlas "
          f"{atlas.width}x{atlas.height}, line {line_height}px ({cfg['mode']})")


def main():
    ap = argparse.ArgumentParser(description="Export Seek & Destroy bitmap fonts")
    ap.add_argument("fonts", nargs="*", help="font names (default: all)")
    ap.add_argument("--game-dir", help="path to the extracted game files")
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    print(f"Game dir: {game_dir}")
    names = args.fonts or list(FONTS)
    for name in names:
        cfg = FONTS.get(name)
        if not cfg:
            print(f"  unknown font: {name}")
            continue
        export_font(name, cfg, game_dir)


if __name__ == "__main__":
    main()
