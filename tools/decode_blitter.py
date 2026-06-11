#!/usr/bin/env python3
"""Exact decoder for Seek and Destroy STAGE0X world sprites.

Reimplements the game's compiled-blitter interpreter at 0x1dbbca in SEEK.EXE
(recovered via DOSBox-X debugging and disassembly, 2026-06-10).

Stream format (little-endian, starts at frame_ptr + i16[frame_ptr]):
    repeat:
        i16 delta   -> VRAM cursor += delta
        i16 code    -> jump offset into one of two unrolled 80-pixel copy
                       chains; encodes pixel count, plane advance, or end

VRAM model: Mode X, 4 planes, 96 bytes per plane row (384 px wide buffer).
Pixels in a run are written vertically (cursor += 96 per pixel). One byte
step in plane space = 4 screen pixels horizontally. Sprites are stored
column-major: each run is one column of one plane; plane-advance rotates
the map mask (column c lands in plane (x0+c) & 3).

Jump code semantics (addresses fixed by the routine layout in SEEK.EXE):
    CHAIN1 = 0x1dbc27, CTRL1 = 0x1dbe57   (even-length run bank)
    CHAIN2 = 0x1dbe75, CTRL2 = 0x1dc0a6   (odd-length run bank, skips a
                                           trailing pad byte to keep the
                                           i16 stream word-aligned)
    target = (CHAIN1 if last bank was 1 else CHAIN2) + code
    PLANE_INC  = 0x1dbc04  advance plane mask, cursor += 1 on wrap to plane 0
    PLANE_NOINC= 0x1dbc0a  advance plane mask only
    REMASK     = 0x1dbc0e  re-emit current mask (no state change)
    END1       = 0x1dbe73, END2 = 0x1dc0c2  end of frame

Frame header (16 bytes): u16 data_off (=16), u16 height, then four u16
anchor offsets used by the engine to position the blit (ex0..ex3) and two
spare u16. Frames 16..31 of a 31-frame arc are rendered mirrored from
frames 0..15 by a twin routine at 0x1dc0c4 that subtracts instead of adds.
"""

import argparse
import struct
import sys

CHAIN1 = 0x1dbc27
CTRL1 = 0x1dbe57
CHAIN2 = 0x1dbe75
CTRL2 = 0x1dc0a6
END1 = 0x1dbe73
END2 = 0x1dc0c2
PLANE_INC = 0x1dbc04
PLANE_NOINC = 0x1dbc0a
REMASK = 0x1dbc0e
UNITS = 80
STRIDE = 96

_OFF_IN_UNIT = {0: 'load', 2: 'inc', 3: 'write', 5: 'step'}


def _chain_ops(rel, last_extra_inc):
    """Ops executed from byte offset rel inside an 80-unit copy chain."""
    ops = []
    k, o = divmod(rel, 7)
    while k < UNITS:
        for off in (0, 2, 3, 5):
            if k * 7 + off >= rel:
                ops.append(_OFF_IN_UNIT[off])
        k += 1
    if last_extra_inc:
        ops.append('inc')
    return ops


def classify(target):
    if target == END1 or target == END2:
        return {'kind': 'end', 'ops': []}
    if target == PLANE_INC:
        return {'kind': 'plane', 'inc_on_wrap': True, 'ops': []}
    if target == PLANE_NOINC:
        return {'kind': 'plane', 'inc_on_wrap': False, 'ops': []}
    if target == REMASK:
        return {'kind': 'remask', 'ops': []}
    if CHAIN1 <= target <= CTRL1:
        return {'kind': 'copy', 'ctrl': 1, 'ops': _chain_ops(target - CHAIN1, False)}
    if CHAIN2 <= target <= CTRL2:
        rel = target - CHAIN2
        if target >= CTRL2 - 1:
            return {'kind': 'copy', 'ctrl': 2, 'ops': ['inc'] if target == CTRL2 - 1 else []}
        return {'kind': 'copy', 'ctrl': 2, 'ops': _chain_ops(rel, True)}
    return {'kind': 'bad', 'target': target, 'ops': []}


def decode_frame(data, frame_off, frame_end=None, max_pairs=20000):
    """Simulate the blit. Returns (canvas {(x, y): palette_index}, status)."""
    data_off = struct.unpack_from('<h', data, frame_off)[0]
    ptr = frame_off + data_off
    x0, y0 = 192, 100
    cursor = y0 * STRIDE + (x0 >> 2)
    plane = x0 & 3
    ctrl = 1
    canvas = {}
    end = min(frame_end, len(data)) if frame_end is not None else len(data)
    for _ in range(max_pairs):
        if ptr + 4 > end:
            return canvas, f'overrun at {ptr:#x}'
        delta, code = struct.unpack_from('<hh', data, ptr)
        ptr += 4
        cursor += delta
        act = classify((CHAIN1 if ctrl == 1 else CHAIN2) + code)
        cl = None
        for op in act['ops']:
            if ptr >= end:
                return canvas, f'overrun at {ptr:#x}'
            if op == 'load':
                cl = data[ptr]
            elif op == 'inc':
                ptr += 1
            elif op == 'write':
                y, bx = divmod(cursor, STRIDE)
                canvas[(bx * 4 + plane - x0, y - y0)] = cl
            elif op == 'step':
                cursor += STRIDE
        if act['kind'] == 'copy':
            ctrl = act['ctrl']
        elif act['kind'] == 'plane':
            if act['inc_on_wrap'] and plane == 3:
                cursor += 1
            plane = (plane + 1) & 3
            ctrl = 1
        elif act['kind'] == 'remask':
            ctrl = 1
        elif act['kind'] == 'end':
            return canvas, 'ok'
        else:
            return canvas, f"bad jump target {act['target']:#x} at {ptr - 4:#x}"
    return canvas, 'runaway'


def read_frames(data):
    hdr = struct.unpack_from('<I', data, 0)[0]
    n = (hdr - 4) // 4
    if n == 0:
        return [(4, len(data))]
    offs = [struct.unpack_from('<I', data, 4 + i * 4)[0] for i in range(n)]
    return [(offs[i], offs[i + 1] if i + 1 < n else len(data)) for i in range(n)]


def frame_header(data, frame_off):
    w, h = struct.unpack_from('<HH', data, frame_off)
    ex = struct.unpack_from('<6H', data, frame_off + 4)
    return w, h, ex


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
    ap = argparse.ArgumentParser(description='Exact SEEK world-sprite decoder')
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

    import os
    base = os.path.splitext(os.path.basename(args.file))[0].lower()
    failures = 0
    for i in sel:
        fo, fe = frames[i]
        w, h, ex = frame_header(data, fo)
        canvas, status = decode_frame(data, fo, fe)
        if status != 'ok':
            failures += 1
        if args.verify:
            print(f'{base} f{i:02d} h={h} ex={ex[:4]}: {status}, {len(canvas)} px')
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
