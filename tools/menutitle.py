"""Frame box mapping for the animated menu titles (CREDANIM/HIANIM).

Each frame header declares a fixed box (u16 width at +2, u16 height at +4,
then half-width / half-height centering offsets): 316x28 for HIANIM, 140x20
for CREDANIM. The stream's first delta is relative to the box's top-left
corner, so every frame of the animation shares the same box and the engine
centers the box, not the art, on screen.

decode_blitter renders at a fixed anchor x0 = 192 in a 384 px Mode X row, so
the right part of a box wider than 192 px runs past the row end and comes back
at raw x < 0, one row lower (the VRAM cursor is linear). to_box() undoes that
wrap. The HIGH SCORES frames from 15 on add speed-line wings at both box edges,
so the art is not one contiguous run of columns and no gap heuristic can find
the seam.

The titles draw in the palette of the screen they head: CREDITS.BIN and
HISCORE.BIN (identical over the title's indices 128-190).
"""

import struct

ROW_W = 384  # Mode X logical row width the blitter wraps around


def box_size(data, frame_off):
    """(width, height) of the frame box declared in the frame header."""
    return struct.unpack_from('<HH', data, frame_off + 2)


def to_box(canvas):
    """Map a decode_blitter canvas (x measured from the x0 = 192 anchor) to box
    coordinates, with the box's top-left corner at (0, 0)."""
    return {(x % ROW_W, y - 1 if x < 0 else y): idx for (x, y), idx in canvas.items()}
