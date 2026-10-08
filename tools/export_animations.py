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

THIS_DIR = Path(__file__).resolve().parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db
import decode_level
import export_love2d
import gamedata
import image


# (BIN stem, output prefix, fps, loop). The explosions play at the original's
# rate: its per-tick frame step (0x80, flak 0x48, of 512) at 70 ticks a second.
ANIMATIONS = [
    ("EXPLO32",  "explo32",  17.5, False),
    ("EXPLO64",  "explo64",  17.5, False),
    ("RDNEXPD",  "rdnexpd",  17.5, False),
    ("FLAKANI",  "flakani",  9.84, False),
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
# frame range. Each (stem, mission) pair becomes a clip "{prefix}{m}" with files
# {prefix}{m}_f{NN}.png.
MISSION_ANIMATIONS = [
    ("DUST",    "dust",    17.5, False, None),
    ("MINE",    "mine",    12, False, None),
    # The building blast of missions 1, 2 and 4, each only in its own STAGE0{m}
    # and drawn for that mission's palette (missions 0 and 3 use RDNEXPD above).
    # Clips rdnexp1 / 2 / 4, named by the `missions` table of explosion_medium
    # in data/animations.json.
    ("RDNEXPS", "rdnexp",  17.5, False, None),
    ("RDNEXPJ", "rdnexp",  17.5, False, None),
    ("RDNEXPR", "rdnexp",  17.5, False, None),
]


# The class the people on foot are spawned from in every stage (0x203b80), the
# class of the body one leaves when shot (0x2039e0), and the length of the walk
# cycle: the first pose of the sheet's rotation arc, which the engine rotates
# at runtime. The cycle advances half a frame a tick (0x203e8a), 35 a second.
WALKER_CLASS = 20
BODY_CLASS   = 35
WALK_FRAMES  = 16
WALK_FPS     = 35


def export_mission_anim(game_dir, out_dir, bin_stem, prefix, mission, keep):
    """Render a STAGE0{m} animation. Returns the written file names."""
    src      = game_dir / f"STAGE0{mission}" / (bin_stem + ".BIN")
    pal_path = game_dir / f"STAGE0{mission}" / "PAL.BIN"
    if not src.exists() or not pal_path.exists():
        return []
    names = render_sequence(src.read_bytes(), pal_path.read_bytes(), keep, out_dir, f"{prefix}{mission}")
    print(f"  STAGE0{mission}/{bin_stem}: {len(names)} frames -> {prefix}{mission}")
    return names


def render_sequence(data, palette, keep, out_dir, name):
    """Render frames of a sprite sheet on a shared canvas so a sequence (e.g. a
    walk cycle) keeps its frame-to-frame alignment. `keep` limits the frame
    range. Writes {name}_f{NN}.png and returns the file names."""
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
        img = image.new("RGBA", (w, h), (0, 0, 0, 0))
        for (x, y), p in cv.items():
            r, g, b = palette[p * 3] * 4, palette[p * 3 + 1] * 4, palette[p * 3 + 2] * 4
            img.putpixel((x - x0, y - y0), (r, g, b, 255))
        fname = f"{name}_f{len(names):02d}.png"
        img.save(out_dir / fname)
        names.append(fname)
    return names


def export_walkers(game_dir, out_dir):
    """The people on foot (POWs, crews, agents) of each mission: the sheet its
    stages name in the walker class, in the mission's palette. Clips "{stem}{m}"
    (walk cycle) and "{stem}{m}_dead" (the body, first frame of its spin)."""
    results = {}
    for m in gamedata.missions(game_dir):
        stage    = decode_level.parse_stage((game_dir / "data" / f"STAGE{m}0.BIN").read_bytes())
        pal_path = game_dir / f"STAGE0{m}" / "PAL.BIN"
        if not pal_path.exists():
            pal_path = game_dir / f"STAGE0{m}" / "PAL1.BIN"
        palette = pal_path.read_bytes()
        stem    = None
        for cls_index, suffix, count, fps, loop in (
                (WALKER_CLASS, "", WALK_FRAMES, WALK_FPS, True),
                (BODY_CLASS, "_dead", 1, 1, False)):
            cls   = stage["classes"][cls_index]
            asset = stage["assets"][cls["asset"]]
            src   = export_love2d.find_bin(game_dir, asset["file"], asset["source_dir"], m)
            stem  = stem or Path(asset["file"]).stem.lower()
            if src:
                base  = max(0, cls["frame_base"])
                name  = f"{stem}{m}{suffix}"
                names = render_sequence(src.read_bytes(), palette, range(base, base + count), out_dir, name)
                if names:
                    results[name] = (names, fps, loop)
                    print(f"  {src.parent.name}/{src.name}: {len(names)} frames -> {name}")
    return results


def export_all_mission_anims(game_dir, out_dir):
    results = {}
    for bin_stem, prefix, fps, loop, keep in MISSION_ANIMATIONS:
        for m in range(5):
            names = export_mission_anim(game_dir, out_dir, bin_stem, prefix, m, keep)
            if names:
                results[f"{prefix}{m}"] = (names, fps, loop)
    return results


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export SEEK effect animations to assets/effects/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)

    game_dir = gamedata.find_game_dir(args.game_dir)
    out_dir  = gamedata.ASSETS / "effects"
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

    # One-shot alias of FIRE used as a small-entity death explosion. The engine
    # plays death effects as "explosion_<type>", so exposing the FIRE frames under
    # explosion_fire (non-looping) makes "fire" a valid explosion in the editor.
    # It plays at the original's rate for that puff (step 0x100).
    if results.get("fire"):
        results["explosion_fire"] = (results["fire"][0], 35, False)

    print()
    print("Per-mission animations:")
    results.update(export_all_mission_anims(game_dir, out_dir))
    results.update(export_walkers(game_dir, out_dir))

    print()
    print("animations.json entries:")
    for prefix, (names, fps, loop) in results.items():
        frames = [f"effects/{n}" for n in names]
        loop_s = "true" if loop else "false"
        print(f'  "{prefix}": {{ "frames": {frames}, "fps": {fps}, "loop": {loop_s} }}')


if __name__ == "__main__":
    main()
