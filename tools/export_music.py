#!/usr/bin/env python3
"""
Export the original music to assets/music/.

The three modules are OctaMED (MMD1) files in data/, which LOVE plays as they
are (ModPlug), so they are copied under the track names the engine asks for:

  SEEKMOD.BIN   menu.med       loaded with SEEKHMOD by 0x1f6ef0, started at boot
                               (0x20c048) and again after every phase
                               (play_mission, 0x20c9dd); stopped in play
  SEEKHMOD.BIN  hiscores.med   the end-of-run high score routine (0x1f1ae0),
                               after game over and after the ending
  SEEKEMOD.BIN  ending.med     the ending (FUN_001f2b70), after REGANIM.FLC

Both releases ship all three.

Usage:
  python3 tools/export_music.py
  python3 tools/export_music.py --game-dir ~/dos/seek
"""

import argparse
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamedata

TRACKS = {
    "SEEKMOD.BIN":  "menu",
    "SEEKHMOD.BIN": "hiscores",
    "SEEKEMOD.BIN": "ending",
}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export the original music to assets/music/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)

    game_dir = gamedata.find_game_dir(args.game_dir)
    out_dir  = gamedata.ASSETS / "music"
    out_dir.mkdir(parents=True, exist_ok=True)
    for src, track in TRACKS.items():
        path = game_dir / "data" / src
        if not path.exists():
            print(f"  SKIP {track}: missing {path}")
            continue
        shutil.copyfile(path, out_dir / f"{track}.med")
        print(f"  {track}.med: {path.stat().st_size} bytes")


if __name__ == "__main__":
    main()
