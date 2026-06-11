#!/usr/bin/env python3
"""
Export in-game effect animations from STAGE00 BIN files to assets/effects/.

Usage:
  python3 tools/export_animations.py
  python3 tools/export_animations.py --game-dir /path/to/dos/seek
"""

import argparse
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db


# (BIN stem, output prefix, fps, loop)
ANIMATIONS = [
    ("EXPLO32",  "explo32",  14, False),
    ("EXPLO64",  "explo64",  10, False),
    ("RDNEXPD",  "rdnexpd",  12, False),
    ("FLAKANI",  "flakani",  12, False),
    ("FIRE",     "fire",      8, True),
    ("SMOKE",    "smoke",     8, False),
    ("SMOKE2",   "smoke2",    8, False),
    ("MISSSMK0", "misssmk0", 10, False),
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
    sys.exit(
        "Could not find game directory.\n"
        "Pass --game-dir /path/to/seek (the directory containing STAGE00/)."
    )


def export_anim(game_dir, out_dir, bin_stem, prefix, palette):
    src = game_dir / "STAGE00" / (bin_stem + ".BIN")
    if not src.exists():
        print(f"  skip {bin_stem}: not found at {src}")
        return []
    data   = src.read_bytes()
    frames = db.read_frames(data)
    names  = []
    for i, (off, end) in enumerate(frames):
        canvas, status = db.decode_frame(data, off, end)
        if status not in ("ok",):
            print(f"  {bin_stem} f{i}: {status} (skipped)")
            continue
        if not canvas:
            continue
        img   = db.render(canvas, palette, scale=1)
        fname = f"{prefix}_f{i:02d}.png"
        img.save(out_dir / fname)
        names.append(fname)
    print(f"  {bin_stem}: {len(names)} frames -> assets/effects/")
    return names


def main():
    ap = argparse.ArgumentParser(description="Export SEEK effect animations to assets/effects/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_dir  = REPO_ROOT / "assets" / "effects"
    out_dir.mkdir(parents=True, exist_ok=True)

    pal_path = game_dir / "STAGE00" / "PAL.BIN"
    if not pal_path.exists():
        sys.exit(f"Palette not found at {pal_path}")
    palette = pal_path.read_bytes()

    print(f"Game dir: {game_dir}")
    print(f"Output:   {out_dir}")
    print()

    results = {}
    for bin_stem, prefix, fps, loop in ANIMATIONS:
        names = export_anim(game_dir, out_dir, bin_stem, prefix, palette)
        results[prefix] = (names, fps, loop)

    print()
    print("animations.json entries:")
    for prefix, (names, fps, loop) in results.items():
        frames = [f"effects/{n}" for n in names]
        loop_s = "true" if loop else "false"
        print(f'  "{prefix}": {{ "frames": {frames}, "fps": {fps}, "loop": {loop_s} }}')


if __name__ == "__main__":
    main()
