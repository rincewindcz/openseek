#!/usr/bin/env python3
"""
Export player sprites (chopper + tank) to assets/player/.

Each animation group uses a shared canvas size (max bounding box across all
frames) so all frames can be drawn from the same center anchor.

Usage:
  python3 tools/export_player.py
  python3 tools/export_player.py --game-dir /path/to/dos/seek
"""

import argparse
import sys
from pathlib import Path
from PIL import Image

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db

# (BIN stem in data/, output prefix, frames to keep, palette). The chopper
# pitch/bank/drop and rotor sets are state/spin animations (keep all); tanktop is
# a rotation arc and the port draws its axis-aligned frame 0 runtime-rotated, so
# keep only frame 0. palette None uses the default stage palette; the alternate
# choppers index a different palette region and take VSELECT (the vehicle-select
# screen's palette, stored first in the file) instead.
VSELECT = "VSELECT"

PLAYER_SPRITES = [
    ("CHOPPIT1", "choppit1", None, None),
    ("CHOPBNK1", "chopbnk1", None, None),
    ("CHOPDRP1", "chopdrp1", None, None),
    # Alternate player choppers (CHOP*2 blue / CHOP*3 desert): shipped but never
    # selectable in the original; exposed as playable skins (same pitch/bank/drop
    # layout). Their pixels live in the 224-255 palette region, which only resolves
    # to sane liveries under the VSELECT palette.
    ("CHOPPIT2", "choppit2", None, VSELECT),
    ("CHOPBNK2", "chopbnk2", None, VSELECT),
    ("CHOPDRP2", "chopdrp2", None, VSELECT),
    ("CHOPPIT3", "choppit3", None, VSELECT),
    ("CHOPBNK3", "chopbnk3", None, VSELECT),
    ("CHOPDRP3", "chopdrp3", None, VSELECT),
    ("BLADE",    "blade",    None, None),
    ("BLADEB",   "bladeb",   None, None),
    ("BLADEP",   "bladep",   None, None),
    ("TANKBGRN", "tankbgrn", None, None),
    ("TANKTOP",  "tanktop",  {0},  None),
    ("CHOPSHAD", "chopshad", None, None),
    ("TANKSHAD", "tankshad", None, None),
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


def decode_all_frames(data):
    frame_offsets = db.read_frames(data)
    canvases = []
    for off, end in frame_offsets:
        canvas, status = db.decode_frame(data, off, end)
        canvases.append(canvas if (status == "ok" and canvas) else {})
    return canvases


def shared_canvas_bounds(canvases):
    x_min = y_min = float("inf")
    x_max = y_max = float("-inf")
    for canvas in canvases:
        for (x, y) in canvas:
            if x < x_min: x_min = x
            if x > x_max: x_max = x
            if y < y_min: y_min = y
            if y > y_max: y_max = y
    if x_min == float("inf"):
        return 0, 0, 1, 1
    return int(x_min), int(y_min), int(x_max), int(y_max)


def render_frame_on_canvas(canvas, palette, x_min, y_min, w, h):
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for (x, y), p in canvas.items():
        r = palette[p * 3]     * 4
        g = palette[p * 3 + 1] * 4
        b = palette[p * 3 + 2] * 4
        px = int(x) - x_min
        py = int(y) - y_min
        if 0 <= px < w and 0 <= py < h:
            img.putpixel((px, py), (r, g, b, 255))
    return img


def export_sprite_group(src_path, prefix, out_dir, palette, keep=None):
    data     = src_path.read_bytes()
    canvases = decode_all_frames(data)
    if not canvases:
        print(f"  {src_path.name}: no frames")
        return []

    non_empty = [c for c in canvases if c]
    if not non_empty:
        print(f"  {src_path.name}: all frames empty")
        return []

    x_min, y_min, x_max, y_max = shared_canvas_bounds(non_empty)
    w = x_max - x_min + 1
    h = y_max - y_min + 1

    names = []
    for i, canvas in enumerate(canvases):
        if keep is not None and i not in keep:
            continue
        img   = render_frame_on_canvas(canvas, palette, x_min, y_min, w, h)
        fname = f"{prefix}_f{i:02d}.png"
        img.save(out_dir / fname)
        names.append(fname)

    print(f"  {src_path.name}: {len(names)}/{len(canvases)} frames kept, canvas {w}x{h} -> assets/player/")
    return names


def main():
    ap = argparse.ArgumentParser(description="Export player sprites to assets/player/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_dir  = REPO_ROOT / "assets" / "player"
    out_dir.mkdir(parents=True, exist_ok=True)

    pal_path = game_dir / "STAGE00" / "PAL.BIN"
    if not pal_path.exists():
        pal_path = game_dir / "data" / "GOVPAL.BIN"
    palette = pal_path.read_bytes()
    # The vehicle-select screen palette stores its 768 bytes first in the file.
    vselect = (game_dir / "data" / "VSELECT.BIN").read_bytes()[:768]
    print(f"Game dir: {game_dir}")
    print(f"Palette:  {pal_path.name}")
    print(f"Output:   {out_dir}")
    print()

    for stem, prefix, keep, pal_name in PLAYER_SPRITES:
        src = game_dir / "data" / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        pal = vselect if pal_name == VSELECT else palette
        export_sprite_group(src, prefix, out_dir, pal, keep)


if __name__ == "__main__":
    main()
