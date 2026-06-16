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

# (BIN stem, output prefix, frames to keep, source stage, output stage). The port
# draws the axis-aligned frame 0 and rotates at runtime, so the rotation-arc sets
# keep only the frame(s) the game uses instead of the whole arc: missile/shell/ffr/
# bomb -> frame 0, trace -> the axis-aligned growing streak, hole -> the settled
# crater, enemy (soldier) -> the alive + dead poses. Pickups are an item atlas
# (keep all). TRACE is 7 growth stages of 32-frame rotation arcs (224 frames);
# the axis-aligned (vertical) pose of each stage is frame 0 of its arc, so the
# growing streak the port rotates at runtime is frames 0,32,64,...,192. The source
# stage selects the STAGE0{n}/ BIN and palette; the output stage selects the
# assets/stage{NN}/ dir (usually the same, but the crater is per-mission art: each
# world ships its own HOLE4038, exported into that mission's phase-0 dir so the
# engine can pick it by mission. sgun's BULLET ships in STAGE01). Pass keep=None
# to export every frame (e.g. when inspecting an arc).
PROJECTILE_SPRITES = [
    ("MISSLE",   "missle", {0},                    0,  0),
    ("SHELL",    "shell",  {0},                    0,  0),
    ("FFR",      "ffr",    {0},                    0,  0),
    ("BOMB",     "bomb",   {0},                    0,  0),
    ("TRACE",    "trace",  set(range(0, 224, 32)), 0,  0),
    # The enemy tracer is per mission under a different BIN name (mission 3 has
    # none): STRACE/JTRACE/RTRACE, same 7-growth x 32-rotation layout as TRACE.
    ("STRACE",   "strace", set(range(0, 224, 32)), 1, 10),
    ("JTRACE",   "jtrace", set(range(0, 224, 32)), 2, 20),
    ("RTRACE",   "rtrace", set(range(0, 224, 32)), 4, 40),
    ("HOLE4038", "hole",   {16},                   0,  0),
    ("HOLE4038", "hole",   {16},                   1, 10),
    ("ENEMY",    "enemy",  {16, 32},               0,  0),
    ("PICKUPS",  "pickup", None,                   0,  0),
    ("BULLET",   "bullet", {0},                    1,  1),
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


def export_sprite(src_path, prefix, out_dir, palette, keep=None):
    data     = src_path.read_bytes()
    canvases = decode_all_frames(data)
    if not canvases:
        print(f"  {src_path.name}: no frames")
        return []

    non_empty = [c for c in canvases if c]
    if not non_empty:
        print(f"  {src_path.name}: all frames empty")
        return []

    # Bounds and frame-number padding come from the full arc so the kept frames
    # keep the same canvas/anchor and filename indices as a full export.
    x_min, y_min, x_max, y_max = shared_canvas_bounds(non_empty)
    w = x_max - x_min + 1
    h = y_max - y_min + 1

    names = []
    digits = len(str(len(canvases) - 1))
    fmt = f"{{:0{max(2, digits)}d}}"
    for i, canvas in enumerate(canvases):
        if keep is not None and i not in keep:
            continue
        img   = render_frame(canvas, palette, x_min, y_min, w, h)
        fname = f"{prefix}_f{fmt.format(i)}.png"
        img.save(out_dir / fname)
        names.append(fname)

    print(f"  {src_path.name}: {len(names)}/{len(canvases)} frames kept, canvas {w}x{h}")
    return names


def main():
    ap = argparse.ArgumentParser(description="Export projectile sprites to assets/stage0{n}/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    print(f"Game dir: {game_dir}")
    print()

    palettes = {}   # stage -> palette bytes (one PAL.BIN read per source stage)
    for stem, prefix, keep, src_stage, out_stage in PROJECTILE_SPRITES:
        stage_dir = game_dir / f"STAGE{src_stage:02d}"
        src = stage_dir / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        if src_stage not in palettes:
            palettes[src_stage] = (stage_dir / "PAL.BIN").read_bytes()
        out_dir = REPO_ROOT / "assets" / f"stage{out_stage:02d}"
        out_dir.mkdir(parents=True, exist_ok=True)
        export_sprite(src, prefix, out_dir, palettes[src_stage], keep)


if __name__ == "__main__":
    main()
