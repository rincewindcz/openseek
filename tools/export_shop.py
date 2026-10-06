#!/usr/bin/env python3
"""
Export the weapon-shop sprite batteries to assets/pow/ in the shop's runtime
palette.

The shop draws in the palette of its POWUP / POWUPT backdrop (the first 768
bytes of the fullscreen BIN; the two agree on every index the sprites use).
GOVPAL.BIN is only valid for indices 0-79, so decoding these sprites with it
gives the wrong colours. The one runtime change: a disabled POWGADS button
(a frame drawing its text in index 224) shows grey text and border.

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

Usage:
  python3 tools/export_shop.py --game-dir /path/to/seek
"""

import argparse
import json
import re
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

import decode_blitter as db
import decode_planar as dp
import export_fonts
import gamedata
import image

BACKDROP = "POWUP"

SPRITES = ["POWMEDAL", "POWNAMES", "POWARMED", "POWFOCUS", "POWWGADS", "POWGADST",
           "POWNUMS", "POWGADS"]

# A disabled POWGADS button (the frames drawing their text in 224) shows grey
# text and border instead of the green face.
DISABLED_TEXT = 224
DISABLED      = {224: (44, 44, 44), 215: (60, 60, 60)}

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


def frames_of(data):
    dec = dp if dp.is_planar(data) else db
    out = []
    for off, end in dec.read_frames(data):
        canvas, status = dec.decode_frame(data, off, end)
        if status == "ok" and canvas:
            out.append(canvas)
    return out


def build_palette(game_dir):
    pal = (game_dir / "data" / (BACKDROP + ".BIN")).read_bytes()[:768]
    return [tuple(min(v * 4, 255) for v in pal[i * 3:i * 3 + 3]) for i in range(256)]


def render(canvas, pal):
    if DISABLED_TEXT in canvas.values():
        pal = list(pal)
        for i, rgb in DISABLED.items():
            pal[i] = rgb
    xs = [c[0] for c in canvas]
    ys = [c[1] for c in canvas]
    x0, y0 = min(0, min(xs)), min(0, min(ys))
    img = image.new("RGBA", (max(xs) - x0 + 1, max(ys) - y0 + 1))
    for (x, y), i in canvas.items():
        if i is not None:
            img.putpixel((x - x0, y - y0), pal[i])
    return img


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
    gamedata.write_text(out_dir / "weapon_info.json", json.dumps(info, indent=2))
    print("  WINF/WINFT -> assets/pow/weapon_info.json")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export shop sprites to assets/pow/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)
    game_dir = gamedata.find_game_dir(args.game_dir)
    print(f"Game dir: {game_dir}")

    pal = build_palette(game_dir)
    out_dir = gamedata.ASSETS / "pow"
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
