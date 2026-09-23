"""Column de-wrap for the animated menu titles (CREDANIM/HIANIM).

The blitter lays these frames into a 384 px Mode X row anchored at x0 = 192, so
a full-width title runs off the row and wraps back to the left edge (the "split"
visible from frame 8 on, where "HIGH SCORES" reads "RES ... HIGH SCO").
unsplit() rejoins the wrapped columns before the frame is cropped.

The titles draw in the palette of the screen they head: CREDITS.BIN and
HISCORE.BIN (identical over the title's indices 128-190).
"""

ROW_W = 384  # Mode X logical row width the blitter wraps around
X0    = 192  # fixed VRAM anchor decode_blitter renders at


def _largest_gap_shift(occupied):
    """Column shift that moves the widest run of empty columns off the seam."""
    best_len, best_start, n = 0, 0, len(occupied)
    j = 0
    while j < n:
        if not occupied[j % n]:
            k = j
            while not occupied[k % n] and k < j + n:
                k += 1
            if k - j > best_len:
                best_len, best_start = k - j, j
            j = k
        else:
            j += 1
    return (best_start + best_len) % n


def unsplit(canvas):
    """Rejoin a wrapped blitter canvas and normalize it to the origin.

    Takes {(x, y): index} as produced by decode_blitter.decode_frame (x measured
    from the x0 = 192 anchor) and returns a new canvas with columns rotated to
    close the wrap seam and the top-left corner moved to (0, 0)."""
    if not canvas:
        return canvas
    occupied = [False] * ROW_W
    for (x, _y) in canvas:
        occupied[(x + X0) % ROW_W] = True
    shift = _largest_gap_shift(occupied)
    rotated = {}
    min_x = min_y = 1 << 30
    for (x, y), idx in canvas.items():
        nx = ((x + X0) - shift) % ROW_W
        rotated[(nx, y)] = idx
        min_x = min(min_x, nx)
        min_y = min(min_y, y)
    return {(x - min_x, y - min_y): idx for (x, y), idx in rotated.items()}
