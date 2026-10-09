#!/usr/bin/env python3
"""
Export the registered release's ending sequence to assets/ending/.

The ending (FUN_001f2b70 @ 0x1f2b70, run when the last stage is cleared) plays
the CD's REGANIM.FLC, starts SEEKEMOD.BIN (export_music.py), then shows six
pictures (FIN01..03, VIC1..3) with story text typed over them in ENDCHARS. The text and its layout
are compiled into SEEK.EXE: each line is a call to the typewriter routine
0x1f26f0 with the string address, x and y. The strings sit in the LE data
object at a fixed distance from their load address (EXE_DELTA), so they are
read from the executable at the addresses the code passes.

VIC3 has two endings: the one the original shows, and an alternate the original
only reveals while scancode 0x29 is held as VIC3 opens (its first three lines
20 px higher, then the "WHY?" text).

Output:
  assets/ending/ending.json   slides: picture, lines {text, x, y} (tab = pause),
                              alternate_lines (VIC3), prompt position; the
                              prompt text
  assets/ending/reganim.flc   the CD's ending animation, copied when present
  assets/fonts/endstory.*     ENDCHARS in the slides' palette: white face,
                              near-black drop shadow

The shareware release has its own, shorter ending (DEMO01-03, DEMOOVER): the
same typewriter and font, four pictures, then a register pitch and three
advertising screenshots. The pitch and screenshots are not exported; the engine
adds its own closing lines from data/ending.json (extra_lines). Its strings sit
in a differently based data object (SHAREWARE_DELTA). No animation, no
alternate ending.

Usage:
  python3 tools/export_ending.py
  python3 tools/export_ending.py --game-dir ~/dos/seek
"""

import argparse
import json
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export_fonts
import gamedata

# Load address minus file offset of the strings in the registered SEEK.EXE.
EXE_DELTA = 0x1bb400

# The picture names the ending loads, checked before trusting the offsets.
ANCHORS = {0x21d4e4: "data\\fin01.bin", 0x21d97c: "data\\vic3.bin"}

PROMPT = 0x21d5d0
PROMPT_POS = (48, 200)
LAST_PROMPT_POS = (48, 232)

# (picture, [(string address, x, y)]) in play order.
SLIDES = [
    ("FIN01", [(0x21d4f4, 8, 40), (0x21d518, 8, 50), (0x21d53c, 8, 60),
               (0x21d564, 8, 70), (0x21d58c, 8, 80), (0x21d5ac, 8, 90)]),
    ("FIN02", [(0x21d5fc, 8, 40), (0x21d624, 8, 50), (0x21d648, 8, 60),
               (0x21d66c, 8, 70), (0x21d690, 8, 80)]),
    ("FIN03", [(0x21d6b0, 8, 40), (0x21d6d4, 8, 50), (0x21d6f8, 8, 60)]),
    ("VIC1",  [(0x21d730, 8, 40), (0x21d754, 8, 50), (0x21d77c, 8, 60),
               (0x21d79c, 8, 70), (0x21d7c0, 8, 80), (0x21d7e4, 8, 90),
               (0x21d808, 8, 100)]),
    ("VIC2",  [(0x21d830, 8, 40), (0x21d858, 8, 50), (0x21d878, 8, 60),
               (0x21d89c, 8, 70), (0x21d8c4, 8, 80), (0x21d8e8, 8, 90),
               (0x21d90c, 8, 100), (0x21d930, 8, 110), (0x21d954, 8, 120)]),
]

LAST_PICTURE = "VIC3"
LAST_OPENING = [(0x21d98c, 8, 40), (0x21d9b0, 8, 50), (0x21d9d8, 8, 60)]
LAST_LINES = [(0x21dbac, 8, 80), (0x21dbd0, 8, 90), (0x21dbf8, 8, 100),
              (0x21dc20, 88, 120)]
ALTERNATE_SHIFT = -20
ALTERNATE_LINES = [(0x21d9f8, 8, 60), (0x21da1c, 8, 70), (0x21da40, 8, 80),
                   (0x21da64, 8, 90), (0x21da84, 120, 110), (0x21da94, 8, 130),
                   (0x21dab8, 8, 140), (0x21dae0, 8, 150), (0x21db04, 8, 160),
                   (0x21db2c, 8, 170), (0x21db54, 8, 180), (0x21db78, 8, 190),
                   (0x21db98, 8, 210)]

# The shareware ending: SEEK.EXE's story strings (load address - file offset),
# a story-only subset of its picture sequence. Addresses are object offsets
# from the code (mov edx, offset) plus the data object base 0x70000.
SHAREWARE_DELTA = 0xe600
SHAREWARE_ANCHORS = {0x70614: "IN THE END, THE SABOTAGE OF THE ENEMY",
                     0x70660: "data\\demoover.bin"}
SHAREWARE_PROMPT = 0x70558
SHAREWARE_SLIDES = [
    ("DEMO01",   [(0x704f4, 8, 40), (0x70500, 8, 60), (0x70528, 8, 70), (0x7054c, 8, 80)]),
    ("DEMO02",   [(0x70584, 8, 50), (0x705ac, 8, 60), (0x705d0, 8, 70), (0x705f4, 8, 80)]),
    ("DEMO03",   [(0x70614, 8, 50), (0x7063c, 8, 60)]),
    ("DEMOOVER", [(0x70674, 8, 40), (0x70688, 8, 50), (0x706b4, 8, 60), (0x706e0, 8, 70)]),
]

FONT = ("endstory", {"src": "data/ENDCHARS.BIN", "mode": "truecolor",
                     "pal": ["data/FIN01.BIN", "data/DEMO01.BIN"]})


def read_string(exe, address, delta=EXE_DELTA):
    start = address - delta
    end = exe.index(b"\0", start)
    return exe[start:end].decode("latin-1")


def lines(exe, table, dy=0, delta=EXE_DELTA):
    return [{"text": read_string(exe, a, delta), "x": x, "y": y + dy} for a, x, y in table]


def build(exe):
    slides = [{"picture": pic, "lines": lines(exe, table),
               "prompt": {"x": PROMPT_POS[0], "y": PROMPT_POS[1]}}
              for pic, table in SLIDES]
    slides.append({
        "picture": LAST_PICTURE,
        "lines": lines(exe, LAST_OPENING) + lines(exe, LAST_LINES),
        "alternate_lines": lines(exe, LAST_OPENING, ALTERNATE_SHIFT)
                           + lines(exe, ALTERNATE_LINES),
        "prompt": {"x": LAST_PROMPT_POS[0], "y": LAST_PROMPT_POS[1]},
    })
    return {"prompt": read_string(exe, PROMPT), "slides": slides}


def build_shareware(exe):
    slides = [{"picture": pic, "lines": lines(exe, table, delta=SHAREWARE_DELTA),
               "prompt": {"x": PROMPT_POS[0], "y": PROMPT_POS[1]}}
              for pic, table in SHAREWARE_SLIDES]
    return {"prompt": read_string(exe, SHAREWARE_PROMPT, SHAREWARE_DELTA), "slides": slides}


def matches(exe, anchors, delta):
    try:
        return all(read_string(exe, a, delta) == s for a, s in anchors.items())
    except (ValueError, IndexError):
        return False


def find_file(game_dir, name):
    """A top-level file of the installation, matched case-insensitively."""
    for p in game_dir.iterdir():
        if p.is_file() and p.name.upper() == name:
            return p
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export the ending sequence to assets/ending/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)

    game_dir = gamedata.find_game_dir(args.game_dir)
    exe_path = find_file(game_dir, "SEEK.EXE")
    if not exe_path:
        print("  SKIP: no SEEK.EXE")
        return
    exe = exe_path.read_bytes()
    if matches(exe, ANCHORS, EXE_DELTA):
        build_story = build
    elif matches(exe, SHAREWARE_ANCHORS, SHAREWARE_DELTA):
        build_story = build_shareware
    else:
        print("  SKIP: SEEK.EXE has no ending text at a known release's offsets")
        return

    out_dir = gamedata.ASSETS / "ending"
    out_dir.mkdir(parents=True, exist_ok=True)
    data = build_story(exe)
    gamedata.write_text(out_dir / "ending.json", json.dumps(data, indent=2) + "\n")
    print(f"  ending.json: {len(data['slides'])} slides")

    flc = find_file(game_dir, "REGANIM.FLC")
    if flc:
        shutil.copyfile(flc, out_dir / "reganim.flc")
        print(f"  reganim.flc: {flc.stat().st_size} bytes")
    else:
        print("  no REGANIM.FLC (CD release only): the ending starts with the pictures")

    export_fonts.export_font(FONT[0], FONT[1], game_dir)


if __name__ == "__main__":
    main()
