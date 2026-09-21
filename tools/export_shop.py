#!/usr/bin/env python3
"""
Export the weapon-shop sprite batteries to assets/pow/ in the shop's runtime
palette.

The POWUP / POWUPT shop screens set their VGA palette at load time: the shipped
GOVPAL.BIN is only valid for indices 0-79 and the embedded fullscreen palette is
green-shifted (see decode_fullscreen_v2), so decoding these
sprites with either gives the wrong colours. The true runtime palette is
reconstructed from our screenshot-derived assets/fullscreen/POWUP.png +
POWUPT.png (the same trick export_equip.py uses for the equip screens):

  - an index present in a backdrop -> the mode colour of that index's pixels in
    the exported PNG (accurate screenshot colours);
  - an index < 80 not otherwise found -> GOVPAL x4 (the validated menu ramp);
  - any leftover index a sprite still uses -> filled from its in-frame spatial
    neighbours so no hole shows;
  - MEASURED indices override all of the above: the backdrops map them to other
    colours than the live shop shows (button face, text shadow, button border,
    the medal), so they are read off original-game shop screenshots instead;
  - GREY_RAMPS (17-28 and 168-191) likewise, interpolated between measured
    points: the darkened level tiles (POWWGADS / POWGADST) draw in these.

Frames keep their in-container origin (a frame whose pixels start at x=3 is
exported with 3 transparent columns), so the digit "1" and the small medal line
up with their siblings when drawn at a common position.

Outputs (assets/pow/):
  powmedal_f*   awarded medal: f00 large (10 medals), f01 small (1 medal)
  pownames_f*   weapon-category labels
  powarmed_f*   LOADED label (+ the shareware notice frame)
  powfocus_f*   selection focus corners (f00)
  powwgads_f*   chopper darkened level tiles: 2 + 3 * (category * 3 + level)
                (0-based, categories in WINF order), full 40x40 boxes
  powgadst_f*   the tank's darkened level tiles
  pownums_f*    digits 0-9 (COST and the medal count)
  powgads_f*    PURCHASE / DONE: normal, disabled, grey, gold press ring;
                CHOP / TANK: normal, disabled
  weapon_info.json
                per vehicle / weapon / level: medal cost and description lines,
                parsed from data/WINF.BIN (chopper) and data/WINFT.BIN (tank)

It also re-exports the CHARSPOW font (assets/fonts/charspow.*) in the shop
palette, the shop's description font; run it after tools/export_fonts.py.

Run from the repo root (needs assets/fullscreen/POWUP.png + POWUPT.png):
  python3 tools/export_shop.py
"""

import argparse
import json
import re
import sys
from pathlib import Path

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("ERROR: pip install pillow numpy", file=sys.stderr)
    sys.exit(1)

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent
sys.path.insert(0, str(THIS_DIR))

import decode_blitter as db
import decode_planar as dp
import export_fonts
from decode_fullscreen import deinterleave_modex

FS_HEADER, PAL_SIZE = 14, 768

BACKDROPS = ["POWUP", "POWUPT"]

SPRITES = ["POWMEDAL", "POWNAMES", "POWARMED", "POWFOCUS", "POWWGADS", "POWGADST",
           "POWNUMS", "POWGADS"]

# Shop palette entries read off original-game screenshots (POWUP/POWUPT, 2x
# DOSBox captures): 16 button text, 31 the shadow under every glyph / digit /
# LOADED, 61 the digits' outer gold, 215 button border, 224 disabled button
# text; the rest is the medal (ribbon blue / white / red, gold face).
MEASURED = {
    3:   (0, 150, 223),
    5:   (0, 89, 182),
    14:  (251, 251, 81),
    15:  (251, 251, 251),
    16:  (235, 235, 235),
    31:  (0, 0, 0),
    34:  (251, 44, 65),
    36:  (235, 0, 0),
    38:  (203, 0, 0),
    49:  (231, 121, 44),
    51:  (186, 89, 20),
    56:  (251, 235, 0),
    58:  (251, 203, 12),
    60:  (251, 182, 32),
    61:  (252, 176, 40),
    172: (150, 150, 150),
    215: (73, 113, 52),
    224: (44, 44, 44),
}

# Grey ramps: index -> grey level, measured from darkened level tiles (17-28
# the tank's shells tiles and the medal hook, 168-191 every other tile).
# Indices between the points of a ramp are interpolated.
GREY_RAMPS = [
    {17: 223, 18: 203, 19: 186, 21: 154, 22: 142, 23: 125, 24: 109, 25: 93,
     26: 81, 27: 60, 28: 44},
    {168: 186, 173: 142, 175: 125, 177: 109, 178: 101, 179: 93, 181: 81,
     182: 69, 183: 60, 185: 44, 186: 40, 188: 20, 189: 12, 190: 4, 191: 0},
]
# A disabled POWGADS button (the frames drawing their text in 224) shows its
# border grey rather than green.
DISABLED_TEXT   = 224
DISABLED_BORDER = {215: (60, 60, 60)}

# WINF.BIN / WINFT.BIN: "** <CATEGORY> <level> <cost>" headers, each followed
# by the description lines. The level field is unreliable (the air strike
# entries read 1, 1, 2), so levels are numbered by entry order per category.
WEAPON_INFO = {
    "chopper": ("WINF.BIN", {
        "CHAIN_GUN": "chaingun", "ROCKETS": "rockets", "AGM": "air_to_ground",
        "AIM": "air_to_air", "NAP": "napalm", "STR": "air_strike",
    }),
    "tank": ("WINFT.BIN", {
        "CHAIN_GUN": "chaingun", "FLAME_THROWER": "napalm", "SHELLS": "shells",
        "STR": "air_strike",
    }),
}
HEADER = re.compile(r"^\*\*\s+(\S+)\s+\d+\s+(\d+)\s*$")


def find_game_dir(hint):
    for c in ([Path(hint)] if hint else []) + [
            REPO_ROOT.parent / "dos" / "seek", Path.home() / "dos" / "seek"]:
        if (c / "data").exists():
            return c
    sys.exit("Could not find game directory. Pass --game-dir.")


def frames_of(data):
    dec = dp if dp.is_planar(data) else db
    out = []
    for off, end in dec.read_frames(data):
        canvas, status = dec.decode_frame(data, off, end)
        if status == "ok" and canvas:
            out.append(canvas)
    return out


def backdrop_colors(bin_path, png_path):
    """index -> mode RGB, read from a backdrop's index map and its exported PNG."""
    idx = np.asarray(deinterleave_modex(
        bin_path.read_bytes()[FS_HEADER + PAL_SIZE:])).reshape(240, 320)
    ref = np.asarray(Image.open(png_path).convert("RGB"))
    out = {}
    for i in np.unique(idx):
        cols = ref[idx == i].reshape(-1, 3)
        uniq, cnt = np.unique(cols, axis=0, return_counts=True)
        out[int(i)] = tuple(int(v) for v in uniq[cnt.argmax()])
    return out


def grey_ramps():
    """index -> RGB over each GREY_RAMPS span, linear between measured points."""
    out = {}
    for ramp in GREY_RAMPS:
        points = sorted(ramp.items())
        for (i0, v0), (i1, v1) in zip(points, points[1:]):
            for i in range(i0, i1 + 1):
                v = round(v0 + (v1 - v0) * (i - i0) / (i1 - i0))
                out[i] = (v, v, v)
    return out


def build_palette(game_dir):
    pal = [None] * 256
    merged = {}
    for stem in BACKDROPS:
        for k, v in backdrop_colors(game_dir / "data" / (stem + ".BIN"),
                                    REPO_ROOT / "assets" / "fullscreen" / (stem + ".png")).items():
            merged.setdefault(k, v)
    gov = (game_dir / "data" / "GOVPAL.BIN").read_bytes()
    for i in range(256):
        if i in merged:
            pal[i] = merged[i]
        elif i < 80:
            pal[i] = (min(gov[i * 3] * 4, 255), min(gov[i * 3 + 1] * 4, 255),
                      min(gov[i * 3 + 2] * 4, 255))
    for i, rgb in list(MEASURED.items()) + list(grey_ramps().items()):
        pal[i] = rgb
    return pal


def fill_holes(rgba):
    """Fill any still-transparent-but-written pixel (unknown palette index,
    tagged with alpha 1) from its opaque 8-neighbours, iterating to stable."""
    arr = np.asarray(rgba).copy()
    for _ in range(8):
        holes = np.argwhere(arr[:, :, 3] == 1)
        if len(holes) == 0:
            break
        for y, x in holes:
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < arr.shape[0] and 0 <= nx < arr.shape[1] and arr[ny, nx, 3] == 255:
                    arr[y, x] = arr[ny, nx]
                    break
    arr[arr[:, :, 3] == 1] = 0
    return Image.fromarray(arr, "RGBA")


def render(canvas, pal):
    if DISABLED_TEXT in canvas.values():
        pal = list(pal)
        for i, rgb in DISABLED_BORDER.items():
            pal[i] = rgb
    xs = [c[0] for c in canvas]
    ys = [c[1] for c in canvas]
    x0, y0 = min(0, min(xs)), min(0, min(ys))
    w, h = max(xs) - x0 + 1, max(ys) - y0 + 1
    arr = np.zeros((h, w, 4), np.uint8)
    for (x, y), i in canvas.items():
        if i is None:
            continue
        c = pal[i]
        arr[y - y0, x - x0] = (c[0], c[1], c[2], 255) if c else (0, 0, 0, 1)  # alpha 1 = hole
    return fill_holes(Image.fromarray(arr, "RGBA"))


def parse_weapon_info(path, categories):
    """weapon -> [{cost, lines}] in level order. Lines are upper-cased: the
    shop prints them in capitals."""
    out, current = {}, None
    for raw in path.read_bytes().decode("latin-1").splitlines():
        line = raw.rstrip()
        m = HEADER.match(line)
        if m:
            weapon  = categories.get(m.group(1))
            current = None
            if weapon:
                current = {"cost": int(m.group(2)), "lines": []}
                out.setdefault(weapon, []).append(current)
        elif current is not None and line:
            current["lines"].append(line.upper())
    return out


def export_weapon_info(game_dir, out_dir):
    info = {}
    for vehicle, (name, categories) in WEAPON_INFO.items():
        src = game_dir / "data" / name
        if not src.exists():
            print(f"  skip {name}: not found")
            continue
        info[vehicle] = parse_weapon_info(src, categories)
    (out_dir / "weapon_info.json").write_text(json.dumps(info, indent=2))
    print("  WINF/WINFT -> assets/pow/weapon_info.json")


def main():
    ap = argparse.ArgumentParser(description="Export shop sprites to assets/pow/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()
    game_dir = find_game_dir(args.game_dir)
    print(f"Game dir: {game_dir}")

    for stem in BACKDROPS:
        if not (REPO_ROOT / "assets" / "fullscreen" / (stem + ".png")).exists():
            sys.exit(f"missing assets/fullscreen/{stem}.png (run the fullscreen export first)")

    pal = build_palette(game_dir)
    out_dir = REPO_ROOT / "assets" / "pow"
    out_dir.mkdir(parents=True, exist_ok=True)

    for stem in SPRITES:
        src = game_dir / "data" / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        n = 0
        for i, canvas in enumerate(frames_of(src.read_bytes())):
            render(canvas, pal).save(out_dir / f"{stem.lower()}_f{i:02d}.png")
            n += 1
        print(f"  {stem}: {n} frames -> assets/pow/{stem.lower()}_f*.png")

    export_weapon_info(game_dir, out_dir)
    export_fonts.export_font("charspow", export_fonts.FONTS["charspow"], game_dir, palette=pal)


if __name__ == "__main__":
    main()
