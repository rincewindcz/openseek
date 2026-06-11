#!/usr/bin/env python3
"""
Export player helicopter sprites (rotor banks + body) for the Love2D engine.

Reads original game BIN files, decodes them via decode_blitter.py, and writes
PNGs to assets/player/.

Usage:
  python3 tools/export_player.py
  python3 tools/export_player.py --game-dir /path/to/dos/seek
"""

import argparse
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db


def find_game_dir(hint: str | None) -> Path:
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
        if (c / "data").exists():
            return c
    sys.exit(
        "Could not find game data directory.\n"
        "Pass --game-dir /path/to/seek (the directory containing data/ and STAGE0X/)."
    )


def export_bank(game_dir: Path, out_dir: Path, bank_name: str, palette: bytes) -> list[str]:
    """Decode all frames from a CHOP*.BIN file; return list of exported filenames."""
    src = game_dir / "data" / bank_name.upper()
    if not src.exists():
        print(f"  skip {bank_name}: not found")
        return []
    data   = src.read_bytes()
    frames = db.read_frames(data)
    names  = []
    for i, (off, end) in enumerate(frames):
        canvas, status = db.decode_frame(data, off, end)
        if status != "ok" or not canvas:
            print(f"  {bank_name} f{i}: {status}")
            continue
        _, _, ex = db.frame_header(data, off)
        img = db.render(canvas, palette, scale=1)
        fname = f"{bank_name.lower().replace('.bin','')}_f{i}.png"
        img.save(out_dir / fname)
        names.append(fname)
    print(f"  {bank_name}: {len(names)} frames -> assets/player/")
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", default=None,
                    help="Path to the original Seek and Destroy directory")
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_dir  = REPO_ROOT / "assets" / "player"
    out_dir.mkdir(parents=True, exist_ok=True)

    pal_path = game_dir / "STAGE00" / "PAL.BIN"
    if not pal_path.exists():
        pal_path = game_dir / "data" / "GOVPAL.BIN"
    palette = pal_path.read_bytes()

    banks = ["CHOPBNK1.BIN", "CHOPBNK2.BIN", "CHOPBNK3.BIN"]
    result = {}
    for b in banks:
        key = b.lower().replace(".bin", "")
        result[key] = export_bank(game_dir, out_dir, b, palette)

    # Print animations.json snippet for reference
    print()
    print("Suggested animations.json entries:")
    for key, names in result.items():
        frames = [f"player/{n}" for n in names]
        print(f'  "{key}": {{ "frames": {frames}, "fps": 12, "loop": true }}')


if __name__ == "__main__":
    main()
