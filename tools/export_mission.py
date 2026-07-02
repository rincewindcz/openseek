#!/usr/bin/env python3
"""
Export the mission-menu widgets to assets/mission/:

  - PHGADS.BIN  the row of menu buttons (SAVE / LOAD / SHOP / PLAY / EXIT, plus
                the PHASE 01..04 selectors and their COMPLETED variant for
                later). Each button has a normal and a highlighted frame. They
                decode with the world blitter through GOVPAL's gold ramp
                (6-bit, x4) -- the same magenta-in-the-raw-file runtime range
                as the main menu, not PHASEPAL.
  - MSPHASE.BIN the big white "PHASE 0X" titles overlaid on the STAGE0X_MS
                backdrop. Two colors only: fill (idx 1 -> white) and outline
                (idx 0 -> black), matching the baked "MISSION 0X" on the
                backdrop.

The backdrops (STAGE0X_MS) and the objective-icon columns (assets/phase/
stageX_phaseY_f00.png) are already exported elsewhere and used as-is.

Usage:
  python3 tools/export_mission.py
  python3 tools/export_mission.py --game-dir /path/to/dos/seek
"""

import argparse
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent
sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db

# PHGADS frame indices: name -> (normal, highlighted).
BUTTONS = {
    "save": (21, 22), "load": (18, 19), "shop": (24, 25),
    "play": (12, 13), "exit": (9, 10),
    "phase01": (0, 1), "phase02": (3, 4), "phase03": (6, 7), "phase04": (15, 16),
}
COMPLETED = {"phase01": 2, "phase02": 5, "phase03": 8, "phase04": 17}


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


def decode(data, frames, i):
    canvas, status = db.decode_frame(data, *frames[i])
    if status != "ok" or not canvas:
        sys.exit(f"frame {i}: {status}")
    return canvas


def bbox(canvas):
    xs = [x for x, _ in canvas]
    ys = [y for _, y in canvas]
    return min(xs), max(xs), min(ys), max(ys)


def render_pal(canvas, pal):
    from PIL import Image
    x0, x1, y0, y1 = bbox(canvas)
    img = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1), (0, 0, 0, 0))
    for (x, y), idx in canvas.items():
        r = min(255, pal[idx * 3] * 4)
        g = min(255, pal[idx * 3 + 1] * 4)
        b = min(255, pal[idx * 3 + 2] * 4)
        img.putpixel((x - x0, y - y0), (r, g, b, 255))
    return img


def render_title(canvas):
    # MSPHASE: idx 1 -> white fill, idx 0 -> black outline, else transparent.
    from PIL import Image
    x0, x1, y0, y1 = bbox(canvas)
    img = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1), (0, 0, 0, 0))
    for (x, y), idx in canvas.items():
        c = (252, 252, 252, 255) if idx == 1 else (0, 0, 0, 255)
        img.putpixel((x - x0, y - y0), c)
    return img


def main():
    ap = argparse.ArgumentParser(description="Export mission-menu widgets to assets/mission/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_dir  = REPO_ROOT / "assets" / "mission"
    out_dir.mkdir(parents=True, exist_ok=True)

    govpal = (game_dir / "data" / "GOVPAL.BIN").read_bytes()[:768]

    phgads = (game_dir / "data" / "PHGADS.BIN").read_bytes()
    pf = db.read_frames(phgads)
    print(f"Game dir: {game_dir}\nOutput:   {out_dir}\n")

    for name, (norm, hi) in BUTTONS.items():
        for suffix, idx in ((".png", norm), ("_hi.png", hi)):
            img = render_pal(decode(phgads, pf, idx), govpal)
            img.save(out_dir / (name + suffix))
        print(f"  {name}: f{norm}/f{hi} -> {name}.png / {name}_hi.png")

    for name, idx in COMPLETED.items():
        img = render_pal(decode(phgads, pf, idx), govpal)
        img.save(out_dir / (name + "_done.png"))

    msphase = (game_dir / "data" / "MSPHASE.BIN").read_bytes()
    mf = db.read_frames(msphase)
    for i in range(4):
        img = render_title(decode(msphase, mf, i))
        img.save(out_dir / f"title_phase0{i + 1}.png")
        print(f"  title_phase0{i + 1}: {img.width}x{img.height}")


if __name__ == "__main__":
    main()
