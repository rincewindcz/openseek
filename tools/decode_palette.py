#!/usr/bin/env python3
"""
Decoder / viewer for Seek and Destroy VGA palette files.

Format (confirmed):
  768 bytes = 256 entries × 3 bytes (R, G, B), each value 0-63 (6-bit VGA DAC).

Usage:
  decode_palette.py GOVPAL.BIN
  decode_palette.py GOVPAL.BIN -o palette.png
  decode_palette.py GOVPAL.BIN --text          # print as CSV table
  decode_palette.py GOVPAL.BIN --swatch-size 32
"""

import argparse
import sys
from pathlib import Path
from math import ceil

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("ERROR: Pillow is required. Install with: pip install pillow", file=sys.stderr)
    sys.exit(1)

PALETTE_SIZE = 768
COLS = 16   # swatches per row in output image


def load_palette(data: bytes) -> list[tuple[int, int, int]]:
    if len(data) < PALETTE_SIZE:
        raise ValueError(f"Too short: {len(data)} bytes (need {PALETTE_SIZE})")
    return [
        (min(data[i*3]   * 4, 255),
         min(data[i*3+1] * 4, 255),
         min(data[i*3+2] * 4, 255))
        for i in range(256)
    ]


def main():
    ap = argparse.ArgumentParser(description="View/export Seek & Destroy VGA palette (.BIN)")
    ap.add_argument("input", help="768-byte palette file (e.g. GOVPAL.BIN)")
    ap.add_argument("-o", "--output", help="Output PNG path (default: input with .png)")
    ap.add_argument("--text", action="store_true",
                    help="Print palette as index, R, G, B table and exit")
    ap.add_argument("--swatch-size", type=int, default=24, metavar="PX",
                    help="Size of each colour swatch in pixels (default: 24)")
    ap.add_argument("--cols", type=int, default=COLS,
                    help=f"Swatches per row (default: {COLS})")
    args = ap.parse_args()

    src = Path(args.input)
    if not src.exists():
        print(f"ERROR: File not found: {src}", file=sys.stderr)
        sys.exit(1)

    data = src.read_bytes()
    if len(data) != PALETTE_SIZE:
        print(f"WARNING: Expected {PALETTE_SIZE} bytes, got {len(data)}.", file=sys.stderr)

    palette = load_palette(data)

    if args.text:
        print("index, R8, G8, B8, R6, G6, B6, hex")
        for i, (r, g, b) in enumerate(palette):
            r6 = data[i*3]; g6 = data[i*3+1]; b6 = data[i*3+2]
            print(f"{i:3d}, {r:3d}, {g:3d}, {b:3d},  {r6:2d}, {g6:2d}, {b6:2d},  #{r:02x}{g:02x}{b:02x}")
        return

    sw = args.swatch_size
    cols = args.cols
    rows = ceil(256 / cols)
    img = Image.new("RGB", (cols * sw, rows * sw), (0, 0, 0))
    draw = ImageDraw.Draw(img)

    for i, (r, g, b) in enumerate(palette):
        col = i % cols
        row = i // cols
        x0, y0 = col * sw, row * sw
        draw.rectangle([x0, y0, x0 + sw - 1, y0 + sw - 1], fill=(r, g, b))

    out = Path(args.output) if args.output else src.with_suffix(".png")
    img.save(out)
    print(f"Saved: {out}  ({cols}×{rows} swatches, {sw}px each)")


if __name__ == "__main__":
    main()
