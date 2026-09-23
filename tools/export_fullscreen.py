#!/usr/bin/env python3
"""
Export the original game's fullscreen images (title, menus, briefing
backdrops, shop / equip screens, endings) to assets/fullscreen/.

Layout of a fullscreen BIN:

  0      768   palette, 256 x RGB, 6-bit VGA (x4 to 8-bit, as the DOSBox DAC)
  768    4     u16 4, u16 0
  772    n     u16 n (10 or 16, counting itself), u16 width 320,
               u16 height 240, u16 160, u16 120[, 6 more bytes]
  772+n  76800 pixels, Mode X: plane p holds the columns with x % 4 == p,
               row-major, 80 bytes per row

Every BIN under data/ and STAGE0N/ with this header is exported, so the set
follows the edition (the shareware carries its own advert screens).
data/NAME.BIN -> NAME.png, STAGE0N/NAME.BIN -> STAGE0N_NAME.png.

Usage:
  export_fullscreen.py --game-dir /path/to/seek
"""

import argparse
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gamedata
import image

PAL_SIZE = 768


def parse(data):
    """(palette, width, height, pixel offset) of a fullscreen image, else None."""
    if len(data) < PAL_SIZE + 10:
        return None
    kind, _, header, width, height = struct.unpack_from("<5H", data, PAL_SIZE)
    pixels = PAL_SIZE + 4 + header
    if kind != 4 or width != 320 or height != 240 or len(data) != pixels + width * height:
        return None
    return data[:PAL_SIZE], width, height, pixels


def decode(data):
    """RGB image of a fullscreen BIN, or None if it is not one."""
    parsed = parse(data)
    if parsed is None:
        return None
    palette, width, height, off = parsed
    colors = [bytes(min(v * 4, 255) for v in palette[i * 3:i * 3 + 3]) + b"\xff"
              for i in range(256)]
    img = image.new("RGB", (width, height))
    plane_size = width // 4 * height
    stride = width // 4
    out = img.data
    for plane in range(4):
        base = off + plane * plane_size
        for y in range(height):
            row = base + y * stride
            for xi in range(stride):
                j = (y * width + xi * 4 + plane) * 4
                out[j:j + 4] = colors[data[row + xi]]
    return img


def index_map(data):
    """Row-major palette indices of a fullscreen BIN (list of rows)."""
    _, width, height, off = parse(data)
    plane_size = width // 4 * height
    stride = width // 4
    rows = [[0] * width for _ in range(height)]
    for plane in range(4):
        base = off + plane * plane_size
        for y in range(height):
            row = rows[y]
            src = base + y * stride
            for xi in range(stride):
                row[xi * 4 + plane] = data[src + xi]
    return rows


def sources(game_dir):
    yield from sorted((game_dir / "data").glob("*.BIN"))
    for m in range(5):
        sdir = game_dir / f"STAGE0{m}"
        if sdir.is_dir():
            yield from sorted(sdir.glob("*.BIN"))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export fullscreen images to assets/fullscreen/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)

    game_dir = gamedata.find_game_dir(args.game_dir)
    out_dir  = gamedata.ASSETS / "fullscreen"
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Game dir: {game_dir}\nOutput:   {out_dir}\n")

    for src in sources(game_dir):
        img = decode(src.read_bytes())
        if img is None:
            continue
        folder = src.parent.name
        name = src.stem if folder == "data" else f"{folder}_{src.stem}"
        img.save(out_dir / f"{name}.png")
        print(f"  {src.relative_to(game_dir)} -> {name}.png")


if __name__ == "__main__":
    main()
