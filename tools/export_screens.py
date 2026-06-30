#!/usr/bin/env python3
"""
Export the original game's screen sprites (credits, high-score, POW rescue,
phase briefing cards, the overkill badge / kill icon, and the stage burn
effect) to assets/ for the Love2D engine.

These are not the in-game HUD gauges (see export_hud.py) nor the menu cursors;
they are the per-screen art batteries. Each group is decoded with the exact
decoder its container uses (world blitter or the raw planar HUD class, routed
automatically by decode_planar.is_planar) and rendered in that screen's own
palette:

  credanim   credits scroller      CREDITS.BIN embedded palette   -> assets/credits/
  hianim     high-score intro      HISCORE.BIN embedded palette   -> assets/hiscore/
  pownums    POW count digits      POWUP.BIN embedded palette     -> assets/pow/
  pownames   rescued weapon names  POWUP.BIN embedded palette     -> assets/pow/
  powgads    POW screen buttons    POWUP.BIN embedded palette     -> assets/pow/
  powcount   POW figure + label    POWUP.BIN embedded palette     -> assets/pow/
  powmedal   awarded medal         GOVPAL.BIN (menu palette)      -> assets/pow/
  killicon   kill tank icon        PHASEPAL.BIN                   -> assets/hud/
  okbadge    OVERKILL badge        PHASEPAL.BIN                   -> assets/hud/
  burn/burn2 stage fire animation  STAGE00 palette                -> assets/effects/
  phase1..4  objective briefing    each STAGE0{m} palette         -> assets/phase/

A palette source is either a raw 768-byte VGA palette BIN (first 768 bytes) or
a fullscreen image whose palette is embedded after a 14-byte header (POWUP /
CREDITS / HISCORE). PEOPLE.BIN and HATCH.BIN are intentionally excluded: PEOPLE
dispatches to a different (still unsolved) per-width routine, and HATCH is the
"Unavailable in Shareware Version" placeholder screen.
"""

import argparse
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db
import decode_planar as dp

FS_HEADER = 14  # fullscreen images store their palette after a 14-byte header


def find_game_dir(hint):
    if hint:
        p = Path(hint)
        if p.exists():
            return p
        sys.exit(f"game dir not found: {hint}")
    for c in (REPO_ROOT.parent / "dos" / "seek", Path.home() / "dos" / "seek", REPO_ROOT):
        if (c / "data").exists():
            return c
    sys.exit("Could not find game directory. Pass --game-dir.")


def load_palette(path, embedded):
    data = Path(path).read_bytes()
    off  = FS_HEADER if embedded else 0
    return data[off:off + 768]


def export_sprite(src_path, prefix, out_dir, palette):
    data   = src_path.read_bytes()
    dec    = dp if dp.is_planar(data) else db
    frames = dec.read_frames(data)
    names  = []
    for i, (off, end) in enumerate(frames):
        canvas, status = dec.decode_frame(data, off, end)
        if status != "ok" or not canvas:
            continue
        img   = dec.render(canvas, palette, scale=1)
        fname = f"{prefix}_f{i:02d}.png"
        img.save(out_dir / fname)
        names.append(fname)
    rel = out_dir.relative_to(REPO_ROOT)
    print(f"  {src_path.name}: {len(names)} frames -> {rel}/")
    return names


# (source BIN under data/, output prefix, out subdir, palette BIN, embedded?)
JOBS = [
    ("data/CREDANIM", "credanim", "credits", "data/CREDITS.BIN",  True),
    ("data/HIANIM",   "hianim",   "hiscore", "data/HISCORE.BIN",  True),
    ("data/POWNUMS",  "pownums",  "pow",     "data/POWUP.BIN",    True),
    ("data/POWNAMES", "pownames", "pow",     "data/POWUP.BIN",    True),
    ("data/POWGADS",  "powgads",  "pow",     "data/POWUP.BIN",    True),
    ("data/POWCOUNT", "powcount", "pow",     "data/POWUP.BIN",    True),
    ("data/POWMEDAL", "powmedal", "pow",     "data/GOVPAL.BIN",   False),
    ("data/KILLICON", "killicon", "hud",     "data/PHASEPAL.BIN", False),
    ("data/OKBADGE",  "okbadge",  "hud",     "data/PHASEPAL.BIN", False),
    ("STAGE00/BURN",  "burn",  "effects", "STAGE00/PAL.BIN", False),
    ("STAGE00/BURN2", "burn2", "effects", "STAGE00/PAL.BIN", False),
]


def stage_palette(sdir):
    for name in ("PAL.BIN", "PAL1.BIN"):
        p = sdir / name
        if p.exists():
            return p
    return None


def main():
    ap = argparse.ArgumentParser(description="Export screen sprites to assets/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    print(f"Game dir: {game_dir}\n")

    for stem, prefix, sub, pal_rel, embedded in JOBS:
        src = game_dir / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        palette = load_palette(game_dir / pal_rel, embedded)
        out_dir = REPO_ROOT / "assets" / sub
        out_dir.mkdir(parents=True, exist_ok=True)
        export_sprite(src, prefix, out_dir, palette)

    # Phase briefing cards: one objective list per phase, drawn in the stage's
    # own in-game palette. STAGE0{m}/PHASE{n}.BIN -> assets/phase/.
    out_dir = REPO_ROOT / "assets" / "phase"
    print("\nPhase briefing cards -> assets/phase/")
    for m in range(5):
        sdir    = game_dir / f"STAGE0{m}"
        pal_src = stage_palette(sdir)
        if not sdir.exists() or pal_src is None:
            continue
        palette = pal_src.read_bytes()[:768]
        for n in range(1, 5):
            src = sdir / f"PHASE{n}.BIN"
            if not src.exists():
                continue
            out_dir.mkdir(parents=True, exist_ok=True)
            export_sprite(src, f"stage{m}_phase{n}", out_dir, palette)


if __name__ == "__main__":
    main()
