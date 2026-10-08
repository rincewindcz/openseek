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

  credanim   menu CREDITS option    CREDITS.BIN palette           -> assets/credits/
  hianim     menu HIGH SCORES opt.   HISCORE.BIN palette           -> assets/hiscore/
  powcount   POW figure + label      GOVPAL.BIN                    -> assets/pow/
  killicon   kill tank icon          PHASEPAL.BIN                  -> assets/hud/
  okbadge    OVERKILL badge          PHASEPAL.BIN                  -> assets/hud/
  burn/burn2 stage fire animation    STAGE00 palette               -> assets/effects/
  phase1..4  objective briefing      each STAGE0{m} MS.BIN palette -> assets/phase/

CREDANIM ("CREDITS") and HIANIM ("HIGH SCORES") are the animated titles of
the credits and high-score screens, drawn in those screens' fullscreen
palettes onto their fixed frame box (see menutitle.py). POWCOUNT uses only the
gold ramp and draws in GOVPAL like the other in-game fonts; the shop sprites that
need the POWUP/POWUPT palette (POWNAMES, POWMEDAL, POWARMED, POWFOCUS,
POWWGADS, POWNUMS, POWGADS) are exported by tools/export_shop.py instead. A
palette source is the first 768 bytes of a palette BIN or of a fullscreen
image. PEOPLE.BIN and HATCH.BIN are excluded: PEOPLE dispatches to a different (still unsolved) per-width routine,
and HATCH is the "Unavailable in Shareware Version" placeholder screen.
"""

import argparse
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db
import decode_planar as dp
import gamedata
import menutitle

def load_palette(path):
    return Path(path).read_bytes()[:768]


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
    print(f"  {src_path.name}: {len(names)} frames -> {out_dir}/")
    return names


# (source BIN under data/, output prefix, out subdir, palette BIN)
# CREDANIM/HIANIM are handled separately (see export_titles): they render onto
# the frame box.
# The shop sprites drawn in the POWUP/POWUPT runtime palette (POWNAMES,
# POWMEDAL, POWARMED, POWFOCUS, POWWGADS, POWNUMS, POWGADS) are exported by
# tools/export_shop.py, not here: GOVPAL only covers indices 0-79 and
# mis-colours their icon bodies, medal, button faces and shadows. POWCOUNT uses
# only the gold ramp and stays on GOVPAL.
JOBS = [
    ("data/POWCOUNT", "powcount", "pow",     "data/GOVPAL.BIN"),
    ("data/KILLICON", "killicon", "hud",     "data/PHASEPAL.BIN"),
    ("data/OKBADGE",  "okbadge",  "hud",     "data/PHASEPAL.BIN"),
    ("STAGE00/BURN",  "burn",     "effects", "STAGE00/PAL.BIN"),
    ("STAGE00/BURN2", "burn2",    "effects", "STAGE00/PAL.BIN"),
]


def briefing_palette(sdir):
    """The palette the phase cards are shown under: the briefing picture's own
    (MS.BIN), which is on screen with them. The in-game palette agrees with it
    on the cards' indices for missions 0 and 1, nearly for 2 and 4, and not at
    all for the night mission, whose cards sit at 69..147."""
    for name in ("MS.BIN", "PAL.BIN", "PAL1.BIN"):
        p = sdir / name
        if p.exists():
            return p
    return None


def export_titles(game_dir):
    """CREDANIM / HIANIM: the animated CREDITS and HIGH SCORES menu titles.

    Rendered in their screen's palette onto the fixed frame box from the frame
    header (see menutitle.py), so all frames of a title share one canvas."""
    print("Menu titles -> assets/credits, assets/hiscore/")
    for stem, prefix, sub, screen in (("CREDANIM", "credanim", "credits", "CREDITS"),
                                      ("HIANIM",   "hianim",   "hiscore", "HISCORE")):
        src = game_dir / "data" / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        palette = load_palette(game_dir / "data" / (screen + ".BIN"))
        out_dir = gamedata.ASSETS / sub
        out_dir.mkdir(parents=True, exist_ok=True)
        data  = src.read_bytes()
        count = 0
        for i, (off, end) in enumerate(db.read_frames(data)):
            canvas, status = db.decode_frame(data, off, end)
            if status != "ok" or not canvas:
                continue
            img = db.render(menutitle.to_box(canvas), palette, scale=1,
                            box=menutitle.box_size(data, off))
            img.save(out_dir / f"{prefix}_f{i:02d}.png")
            count += 1
        print(f"  {src.name}: {count} frames -> {out_dir}/")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export screen sprites to assets/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)

    game_dir = gamedata.find_game_dir(args.game_dir)
    print(f"Game dir: {game_dir}\n")

    export_titles(game_dir)
    print()

    for stem, prefix, sub, pal_rel in JOBS:
        src = game_dir / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        palette = load_palette(game_dir / pal_rel)
        out_dir = gamedata.ASSETS / sub
        out_dir.mkdir(parents=True, exist_ok=True)
        export_sprite(src, prefix, out_dir, palette)

    # Phase briefing cards: one objective list per phase, drawn in the palette
    # of the briefing picture they sit on. STAGE0{m}/PHASE{n}.BIN -> assets/phase/.
    out_dir = gamedata.ASSETS / "phase"
    print("\nPhase briefing cards -> assets/phase/")
    for m in range(5):
        sdir    = game_dir / f"STAGE0{m}"
        pal_src = briefing_palette(sdir)
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
