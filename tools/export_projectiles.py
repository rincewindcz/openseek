#!/usr/bin/env python3
"""
Export projectile sprites from STAGE00/ to assets/stage00/.

Usage:
  python3 tools/export_projectiles.py
  python3 tools/export_projectiles.py --game-dir /path/to/dos/seek
"""

import argparse
import sys
from pathlib import Path
from PIL import Image

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db

PROJECTILE_SPRITES = [
    ("MISSLE",   "missle"),
    ("SHELL",    "shell"),
    ("FFR",      "ffr"),
    ("BOMB",     "bomb"),
    ("TRACE",    "trace"),
    ("HOLE4038", "hole"),
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
        if (c / "STAGE00").exists():
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


def render_frame(canvas, palette, x_min, y_min, w, h):
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


def export_sprite(src_path, prefix, out_dir, palette):
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
    digits = len(str(len(canvases) - 1))
    fmt = f"{{:0{max(2, digits)}d}}"
    for i, canvas in enumerate(canvases):
        img   = render_frame(canvas, palette, x_min, y_min, w, h)
        fname = f"{prefix}_f{fmt.format(i)}.png"
        img.save(out_dir / fname)
        names.append(fname)

    print(f"  {src_path.name}: {len(names)} frames, canvas {w}x{h}")
    return names


def main():
    ap = argparse.ArgumentParser(description="Export projectile sprites to assets/stage00/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_dir  = REPO_ROOT / "assets" / "stage00"
    out_dir.mkdir(parents=True, exist_ok=True)

    pal_path = game_dir / "STAGE00" / "PAL.BIN"
    palette  = pal_path.read_bytes()
    print(f"Game dir: {game_dir}")
    print(f"Palette:  {pal_path}")
    print(f"Output:   {out_dir}")
    print()

    for stem, prefix in PROJECTILE_SPRITES:
        src = game_dir / "STAGE00" / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        export_sprite(src, prefix, out_dir, palette)


if __name__ == "__main__":
    main()
