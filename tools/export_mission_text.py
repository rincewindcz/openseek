#!/usr/bin/env python3
"""
Export the original per-phase mission descriptions to assets/mission_text.json.

The originals live as plain ASCII in the game's MT0.BIN .. MT4.BIN (one file per
mission, opened as data\\mt%d.bin by mission_select_menu @ 0x203250). Each file
holds four phase blocks at a fixed 18-line stride, and within a block the text is
a fixed grid of three 6-line box slots (line offsets 0, 6, 12). Each slot is one
briefing paragraph aligned to its objective box; a slot may be blank, and slots
are NOT separated by blank lines (adjacent slots often run together), so grouping
by blank lines wrongly merges them. Paragraphs are parsed by slot offset instead.

Output keys are stage<M><P> (M = mission 0-4, P = phase 0-3), matching the
stage_name parse in engine/ui/mission_menu.lua. Each value is a list of paragraph
objects { "slot": 0-2, "text": ... }; the slot fixes the paragraph's vertical box
so mission_menu.lua can align it even when the matching box art is blank. Original
wording is preserved (whitespace normalized, hand-wrapped line breaks collapsed so
the menu can re-wrap to its own column width).

Usage:
  python3 tools/export_mission_text.py
  python3 tools/export_mission_text.py --game-dir /path/to/dos/seek
"""

import argparse
import json
import re
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

MISSIONS = 5
PHASES = 4
BLOCK_LINES = 18  # fixed per-phase stride within each MT file
SLOTS = 3         # box slots per phase block
SLOT_LINES = BLOCK_LINES // SLOTS  # 6 lines per box slot


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


def parse_block(lines):
    # Split the block into its fixed 6-line box slots; each non-blank slot is one
    # paragraph carrying its slot index, joined with single spaces.
    paras = []
    for slot in range(SLOTS):
        window = lines[slot * SLOT_LINES:(slot + 1) * SLOT_LINES]
        text = re.sub(r"\s+", " ", " ".join(l.strip() for l in window if l.strip())).strip()
        if text:
            paras.append({"slot": slot, "text": text})
    return paras


def parse_mission(data):
    lines = re.split(r"\r\n|\r|\n", data.decode("latin-1"))
    blocks = []
    for p in range(PHASES):
        window = lines[p * BLOCK_LINES:(p + 1) * BLOCK_LINES]
        blocks.append(parse_block(window))
    return blocks


def main():
    ap = argparse.ArgumentParser(description="Export original mission text to assets/mission_text.json")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_path = REPO_ROOT / "assets" / "mission_text.json"

    result = {}
    for m in range(MISSIONS):
        data = (game_dir / "data" / f"MT{m}.BIN").read_bytes()
        for p, paras in enumerate(parse_mission(data)):
            key = f"stage{m}{p}"
            result[key] = {"paragraphs": paras}
            head = (paras[0]["text"] if paras else "").lower()[:44]
            slots = ",".join(str(p["slot"]) for p in paras)
            print(f"  {key}: {len(paras)} para(s) slots[{slots}]  \"{head}...\"")

    out_path.write_text(json.dumps(result, indent=2) + "\n")
    print(f"\nGame dir: {game_dir}\nWrote:    {out_path} ({len(result)} stages)")


if __name__ == "__main__":
    main()
