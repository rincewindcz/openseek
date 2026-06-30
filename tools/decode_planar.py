#!/usr/bin/env python3
"""Exact decoder for Seek and Destroy HUD / menu planar sprites.

Reimplements the raw Mode X planar copy in the height-dispatched HUD blitter
battery at 0x1d8180 in SEEK.EXE (the routine the dispatcher at 0x1d8650 selects
by sprite width >> 2). Unlike the world sprites (decode_blitter.py) these carry
no run-length coding: the body is exactly width*rows palette bytes, stored plane
by plane in Mode X column order.

This is the class the earlier heuristics could not place: cursors (DPOINT,
SELPOINT, MPOINT, HPOINT, INPOINT), focus rings (FOCUS, INFOCUS, SELFOCUS,
PHFOCUS, POWFOCUS), the aiming reticle (SIGHTS), the equipment digits (EQPNUMS)
and the in-game fonts (CHARS, CHARSPOW).

Frame header (the engine reads width/rows here, see 0x1d81d3 / 0x1d81f4):
    i16  data_off   offset from frame start to the pixel stream
    u16  width      pixels across, always a multiple of 4 (Mode X plane width)
    u16  rows       pixels down
    ...             anchor words, up to data_off

Stream (width*rows bytes): four planes; within a plane, `rows` rows of
`width >> 2` bytes; byte b of row y in plane p paints screen pixel
(b*4 + p, y). Index 0 is the transparent background and is dropped, matching
decode_blitter's canvas (drawn pixels only).
"""

import argparse
import os
import struct
import sys

from decode_blitter import read_frames


def frame_header(data, frame_off):
    data_off, width, rows = struct.unpack_from('<hHH', data, frame_off)
    return width, rows, data_off


def is_planar(data):
    """True when every frame is an exact width*rows raw planar body. Lets the
    exporters route a file to this decoder vs. the world-sprite one."""
    try:
        frames = read_frames(data)
    except struct.error:
        return False
    for off, end in frames:
        if off + 6 > len(data):
            return False
        width, rows, data_off = frame_header(data, off)
        if width % 4 or data_off < 6:
            return False
        if (end - (off + data_off)) != width * rows:
            return False
    return True


def decode_frame(data, frame_off, frame_end=None):
    """Simulate the planar copy. Returns (canvas {(x, y): palette_index}, status)."""
    width, rows, data_off = frame_header(data, frame_off)
    if width % 4:
        return {}, f'width {width} not a multiple of 4'
    stream = frame_off + data_off
    hq = width >> 2
    total = rows * width
    end = min(frame_end, len(data)) if frame_end is not None else len(data)
    if stream + total > end:
        return {}, f'truncated: need {total} bytes at {stream:#x}'
    canvas = {}
    sp = stream
    for plane in range(4):
        for y in range(rows):
            for b in range(hq):
                idx = data[sp]
                sp += 1
                if idx:
                    canvas[(b * 4 + plane, y)] = idx
    return canvas, 'ok'


def render(canvas, palette, scale=4):
    from PIL import Image
    if not canvas:
        return None
    xs = [c[0] for c in canvas]
    ys = [c[1] for c in canvas]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    img = Image.new('RGBA', (x1 - x0 + 1, y1 - y0 + 1), (0, 0, 0, 0))
    for (x, y), p in canvas.items():
        r, g, b = palette[p * 3] * 4, palette[p * 3 + 1] * 4, palette[p * 3 + 2] * 4
        img.putpixel((x - x0, y - y0), (r, g, b, 255))
    if scale > 1:
        img = img.resize((img.width * scale, img.height * scale), Image.NEAREST)
    return img


def main():
    ap = argparse.ArgumentParser(description='Exact SEEK HUD/menu planar sprite decoder')
    ap.add_argument('file')
    ap.add_argument('--frame', default='all', help='frame index or "all"')
    ap.add_argument('--palette', default=None, help='768-byte VGA palette')
    ap.add_argument('--out', default='.', help='output directory')
    ap.add_argument('--scale', type=int, default=4)
    ap.add_argument('--verify', action='store_true', help='parse only, no PNG')
    args = ap.parse_args()

    data = open(args.file, 'rb').read()
    frames = read_frames(data)
    sel = range(len(frames)) if args.frame == 'all' else [int(args.frame)]
    palette = open(args.palette, 'rb').read() if args.palette else None

    base = os.path.splitext(os.path.basename(args.file))[0].lower()
    failures = 0
    for i in sel:
        fo, fe = frames[i]
        w, rows, _ = frame_header(data, fo)
        canvas, status = decode_frame(data, fo, fe)
        if status != 'ok':
            failures += 1
        if args.verify:
            print(f'{base} f{i:02d} {w}x{rows}: {status}, {len(canvas)} px')
            continue
        if palette and canvas and status == 'ok':
            img = render(canvas, palette, args.scale)
            out = os.path.join(args.out, f'{base}_f{i:02d}.png')
            img.save(out)
            print(f'{base} f{i:02d}: {status}, {len(canvas)} px -> {out}')
        else:
            print(f'{base} f{i:02d}: {status}, {len(canvas)} px')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
