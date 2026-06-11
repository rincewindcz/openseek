#!/usr/bin/env python3
"""
Decoder for Seek and Destroy character font files.

FORMAT (structure confirmed, per-glyph bitmap format unverified):
  1024 bytes  - offset table: 256 × uint32 LE (absolute file offsets)
                All offsets are uniformly spaced 80 bytes apart.
  20480 bytes - glyph bitmaps: 256 × 80 bytes each

Each glyph is 80 bytes. Most likely interpretation: 8×10 raw pixels
(one byte = one palette index). Other sizes to try: 10×8, 5×16, 4×20.

Usage:
  decode_font.py CHARS.BIN
  decode_font.py CHARS.BIN --palette ../data/GOVPAL.BIN
  decode_font.py CHARS.BIN --glyph-width 8 --glyph-height 10
  decode_font.py CHARS.BIN --char 65           # render single char ('A')
  decode_font.py CHARS.BIN --text              # print offset table
  decode_font.py CHARS.BIN --all               # full character sheet (default)
"""

import argparse
import struct
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("ERROR: Pillow is required. Install with: pip install pillow", file=sys.stderr)
    sys.exit(1)

OFFSET_TABLE_BYTES = 256 * 4   # 1024
NUM_GLYPHS = 256
GLYPH_STRIDE = 80              # bytes per glyph (confirmed from offset table spacing)


def load_palette(data: bytes) -> list[tuple[int, int, int]]:
    return [
        (min(data[i*3]   * 4, 255),
         min(data[i*3+1] * 4, 255),
         min(data[i*3+2] * 4, 255))
        for i in range(256)
    ]


def default_palette() -> list[tuple[int, int, int]]:
    return [(i, i, i) for i in range(256)]


def load_offsets(data: bytes) -> list[int]:
    return [struct.unpack_from("<I", data, i * 4)[0] for i in range(NUM_GLYPHS)]


def render_glyph(glyph_bytes: bytes, gw: int, gh: int,
                 palette: list, scale: int = 1) -> Image.Image:
    img = Image.new("RGBA", (gw, gh), (0, 0, 0, 0))
    px = img.load()
    for yi in range(gh):
        for xi in range(gw):
            idx = yi * gw + xi
            if idx < len(glyph_bytes):
                p = glyph_bytes[idx]
                r, g, b = palette[p]
                px[xi, yi] = (r, g, b, 255 if p != 0 else 0)
    if scale > 1:
        img = img.resize((gw * scale, gh * scale), Image.NEAREST)
    return img


def main():
    ap = argparse.ArgumentParser(description="Decode Seek & Destroy font file (.BIN)")
    ap.add_argument("input", help="Font .BIN file (e.g. CHARS.BIN)")
    ap.add_argument("-o", "--output", help="Output PNG path")
    ap.add_argument("--palette", help="768-byte VGA palette file")
    ap.add_argument("--glyph-width",  type=int, default=8,  metavar="W",
                    help="Glyph width in pixels (default: 8)")
    ap.add_argument("--glyph-height", type=int, default=10, metavar="H",
                    help="Glyph height in pixels (default: 10)")
    ap.add_argument("--char", type=int, default=None, metavar="N",
                    help="Render only character index N (0–255)")
    ap.add_argument("--all", action="store_true", default=True,
                    help="Render full character sheet (default)")
    ap.add_argument("--text", action="store_true",
                    help="Print offset table and exit")
    ap.add_argument("--scale", type=int, default=3, metavar="N",
                    help="Scale each glyph N× (default: 3)")
    ap.add_argument("--cols", type=int, default=16,
                    help="Glyphs per row in sheet (default: 16)")
    ap.add_argument("--glyph-stride", type=int, default=GLYPH_STRIDE,
                    help=f"Bytes per glyph in file (default: {GLYPH_STRIDE})")
    args = ap.parse_args()

    src = Path(args.input)
    if not src.exists():
        print(f"ERROR: Not found: {src}", file=sys.stderr)
        sys.exit(1)

    data = src.read_bytes()
    print(f"File: {src}  ({len(data)} bytes)")

    offsets = load_offsets(data)

    if args.text:
        print("index  offset  spacing")
        for i, off in enumerate(offsets):
            spacing = offsets[i+1] - off if i < 255 else len(data) - off
            print(f"  {i:3d}    {off:6d}   {spacing}")
        return

    # Verify offset spacing
    spacings = set(offsets[i+1] - offsets[i] for i in range(255))
    print(f"Offset spacings: {spacings}  (should be uniformly {args.glyph_stride})")

    if args.palette:
        pal_data = Path(args.palette).read_bytes()
        palette = load_palette(pal_data)
        print(f"Palette: {args.palette}")
    else:
        palette = default_palette()
        print("Palette: greyscale fallback")

    gw = args.glyph_width
    gh = args.glyph_height
    stride = args.glyph_stride

    if gw * gh != stride:
        print(f"WARNING: {gw}×{gh} = {gw*gh} ≠ stride {stride}. "
              "Glyph dimensions don't fill stride exactly.", file=sys.stderr)

    if args.char is not None:
        idx = args.char
        off = offsets[idx]
        glyph_bytes = data[off : off + stride]
        img = render_glyph(glyph_bytes, gw, gh, palette, args.scale)
        char_repr = chr(idx) if 32 <= idx < 127 else f"\\x{idx:02x}"
        out = Path(args.output) if args.output else src.with_name(f"{src.stem}_char{idx}.png")
        img.save(out)
        print(f"Saved char {idx} ({char_repr!r}): {out}")
        return

    # Full character sheet
    cell_w = gw * args.scale
    cell_h = gh * args.scale
    cols = args.cols
    rows = (NUM_GLYPHS + cols - 1) // cols
    sheet = Image.new("RGBA", (cols * cell_w, rows * cell_h), (20, 20, 20, 255))

    for idx in range(NUM_GLYPHS):
        off = offsets[idx]
        glyph_bytes = data[off : off + stride]
        glyph_img = render_glyph(glyph_bytes, gw, gh, palette, args.scale)
        cx = (idx % cols) * cell_w
        cy = (idx // cols) * cell_h
        sheet.paste(glyph_img, (cx, cy), glyph_img)

    out = Path(args.output) if args.output else src.with_suffix(".png")
    sheet.save(out)
    print(f"Saved character sheet: {out}  "
          f"({NUM_GLYPHS} glyphs, {gw}×{gh} each, {args.scale}× scale)")


if __name__ == "__main__":
    main()
