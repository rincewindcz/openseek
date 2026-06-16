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
    # Tumbling iron/metal debris thrown when metal structures are destroyed.
    ("IRONSZ",   "ironsz",   18, True),
    ("IRON2SZ",  "iron2sz",  18, True),
    ("METAL8",   "metal8",   18, True),
    ("METALRT",  "metalrt",  18, True),
    ("METALSZ",  "metalsz",  18, True),
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


# Per-mission unit / effect animations: these live in STAGE0{m}/ (not only
# STAGE00) and are rendered with that mission's own palette. `keep` limits the
# frame range (POW/NEWDUDE are multi-direction walk sheets; frames 0-15 are the
# axis-aligned walk cycle the engine rotates at runtime). Each (stem, mission)
# pair becomes a clip "{prefix}{m}" with files {prefix}{m}_f{NN}.png.
MISSION_ANIMATIONS = [
    ("DUST",    "dust",    12, False, None),
    ("MINE",    "mine",    12, False, None),
    ("POW",     "pow",     12, True,  range(0, 16)),
    ("NEWDUDE", "newdude", 12, True,  range(0, 16)),
]


def export_mission_anim(game_dir, out_dir, bin_stem, prefix, mission, keep):
    """Render a STAGE0{m} animation on a shared canvas so a sequence (e.g. a walk
    cycle) keeps its frame-to-frame alignment. Returns the written file names."""
    from PIL import Image
    src      = game_dir / f"STAGE0{mission}" / (bin_stem + ".BIN")
    pal_path = game_dir / f"STAGE0{mission}" / "PAL.BIN"
    if not src.exists() or not pal_path.exists():
        return []
    palette = pal_path.read_bytes()
    data    = src.read_bytes()
    offs    = db.read_frames(data)
    idxs    = [i for i in (keep if keep is not None else range(len(offs))) if i < len(offs)]
    canvases = []
    for i in idxs:
        canvas, status = db.decode_frame(data, offs[i][0], offs[i][1])
        canvases.append(canvas if (status == "ok" and canvas) else {})
    xs = [c[0] for cv in canvases for c in cv]
    ys = [c[1] for cv in canvases for c in cv]
    if not xs:
        return []
    x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
    w, h = x1 - x0 + 1, y1 - y0 + 1
    names = []
    for cv in canvases:
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        for (x, y), p in cv.items():
            r, g, b = palette[p * 3] * 4, palette[p * 3 + 1] * 4, palette[p * 3 + 2] * 4
            img.putpixel((x - x0, y - y0), (r, g, b, 255))
        fname = f"{prefix}{mission}_f{len(names):02d}.png"
        img.save(out_dir / fname)
        names.append(fname)
    print(f"  STAGE0{mission}/{bin_stem}: {len(names)} frames -> {prefix}{mission}")
    return names


def export_all_mission_anims(game_dir, out_dir):
    results = {}
    for bin_stem, prefix, fps, loop, keep in MISSION_ANIMATIONS:
        for m in range(5):
            names = export_mission_anim(game_dir, out_dir, bin_stem, prefix, m, keep)
            if names:
                results[f"{prefix}{m}"] = (names, fps, loop)
    return results


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
    print("Per-mission animations:")
    results.update(export_all_mission_anims(game_dir, out_dir))

    print()
    print("animations.json entries:")
    for prefix, (names, fps, loop) in results.items():
        frames = [f"effects/{n}" for n in names]
        loop_s = "true" if loop else "false"
        print(f'  "{prefix}": {{ "frames": {frames}, "fps": {fps}, "loop": {loop_s} }}')


if __name__ == "__main__":
    main()
