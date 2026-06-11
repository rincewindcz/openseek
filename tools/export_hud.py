#!/usr/bin/env python3
"""
Export HUD sprites from the original game data to assets/hud/.

Usage:
  python3 tools/export_hud.py
  python3 tools/export_hud.py --game-dir /path/to/dos/seek
"""

import argparse
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db

# (source BIN stem relative to data/, output prefix, palette key)
# palette key: "gov" = GOVPAL.BIN (menus/HUD), "stage" = STAGE00/PAL.BIN
HUD_SPRITES = [
    ("ARMOUR",   "armour",   "gov"),
    ("FUEL",     "fuel",     "gov"),
    ("WEAPONS",  "weapons",  "gov"),
    ("SCANNER",  "scanner",  "gov"),
    ("LIVES",    "lives",    "gov"),
    ("KILLICON", "killicon", "gov"),
]


def find_game_dir(hint):
    if hint:
        p = Path(hint)
        if p.exists():
            return p
        sys.exit(f"game dir not found: {hint}")
    candidates = [
        REPO_ROOT.parent / "dos" / "seek",
        Path.home() / "dos" / "seek",
        REPO_ROOT,
    ]
    for c in candidates:
        if (c / "data").exists():
            return c
    sys.exit("Could not find game directory. Pass --game-dir.")


def export_sprite(src_path, prefix, out_dir, palette):
    data   = src_path.read_bytes()
    frames = db.read_frames(data)
    names  = []
    for i, (off, end) in enumerate(frames):
        canvas, status = db.decode_frame(data, off, end)
        if status != "ok" or not canvas:
            continue
        img   = db.render(canvas, palette, scale=1)
        fname = f"{prefix}_f{i:02d}.png"
        img.save(out_dir / fname)
        names.append(fname)
    print(f"  {src_path.name}: {len(names)} frames -> assets/hud/")
    return names


def main():
    ap = argparse.ArgumentParser(description="Export HUD sprites to assets/hud/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_dir  = REPO_ROOT / "assets" / "hud"
    out_dir.mkdir(parents=True, exist_ok=True)

    gov_pal   = (game_dir / "data" / "GOVPAL.BIN").read_bytes()
    stage_pal = (game_dir / "STAGE00" / "PAL.BIN").read_bytes()
    palettes  = { "gov": gov_pal, "stage": stage_pal }

    print(f"Game dir: {game_dir}")
    print(f"Output:   {out_dir}")
    print()

    for stem, prefix, pal_key in HUD_SPRITES:
        src = game_dir / "data" / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        export_sprite(src, prefix, out_dir, palettes[pal_key])


if __name__ == "__main__":
    main()
