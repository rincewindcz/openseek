#!/usr/bin/env python3
"""
Export the original per-phase mission descriptions to data/mission_text.json.

The originals live as plain ASCII in the game's MT0.BIN .. MT4.BIN (one file per
mission, opened as data\\mt%d.bin by mission_select_menu @ 0x203250). Each file
holds four phase blocks at a fixed 18-line stride; within a block the text is one
or more paragraphs separated by blank lines (typically an objective paragraph
followed by an enemy/threat paragraph, though some blocks merge them).

Output keys are stage<M><P> (M = mission 0-4, P = phase 0-3), matching the
stage_name parse in engine/missionmenu.lua. Each value is a list of paragraphs
with the original wording preserved (whitespace normalized, hand-wrapped line
breaks collapsed so the menu can re-wrap to its own column width).

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
    # Group consecutive non-empty lines into paragraphs; join each with single
    # spaces and collapse runs of whitespace.
    paras, cur = [], []
    for line in lines:
        s = line.strip()
        if s:
            cur.append(s)
        elif cur:
            paras.append(re.sub(r"\s+", " ", " ".join(cur)))
            cur = []
    if cur:
        paras.append(re.sub(r"\s+", " ", " ".join(cur)))
    return paras


def parse_mission(data):
    lines = re.split(r"\r\n|\r|\n", data.decode("latin-1"))
    blocks = []
    for p in range(PHASES):
        window = lines[p * BLOCK_LINES:(p + 1) * BLOCK_LINES]
        blocks.append(parse_block(window))
    return blocks


def main():
    ap = argparse.ArgumentParser(description="Export original mission text to data/mission_text.json")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_path = REPO_ROOT / "data" / "mission_text.json"

    result = {}
    for m in range(MISSIONS):
        data = (game_dir / "data" / f"MT{m}.BIN").read_bytes()
        for p, paras in enumerate(parse_mission(data)):
            key = f"stage{m}{p}"
            result[key] = {"paragraphs": paras}
            head = (paras[0] if paras else "").lower()[:44]
            print(f"  {key}: {len(paras)} para(s)  \"{head}...\"")

    out_path.write_text(json.dumps(result, indent=2) + "\n")
    print(f"\nGame dir: {game_dir}\nWrote:    {out_path} ({len(result)} stages)")


if __name__ == "__main__":
    main()
