#!/usr/bin/env python3
"""Runtime palette and de-wrap for the animated menu titles (CREDANIM/HIANIM).

CREDANIM ("CREDITS") and HIANIM ("HIGH SCORES") are world-blitter sprites, but
they render as a gold letter face over a grey 3D bevel, colors that match no
shipped palette BIN: the game assembles them in the VGA DAC at load time. The
true colors were recovered from an original-game CREDITS screenshot
(tools/reference/credits_reference.png) by aligning it against the decoded final
CREDANIM frame and sampling the color at each sprite index, then interpolating
the indices no single frame covers. CREDANIM and HIANIM share the palette (same
title styling).

The blitter lays these frames into a 384 px Mode X row anchored at x0 = 192, so
a full-width title runs off the row and wraps back to the left edge (the "split"
visible from frame 8 on, where "HIGH SCORES" reads "RES ... HIGH SCO").
unsplit() rejoins the wrapped columns before the frame is cropped.

MENUTITLE_PAL.BIN is stored as 6-bit VGA values (0-63) like every other game
palette, so decode_blitter.render (which expands entries by *4) resolves it
correctly; the colors recovered from the screenshot are 8-bit and shifted down
two bits on write.

Run this module to regenerate MENUTITLE_PAL.BIN from the reference screenshot:

    python3 tools/menutitle.py --game-dir ~/dos/seek
"""

import argparse
import sys
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db

PAL_PATH = THIS_DIR / "MENUTITLE_PAL.BIN"
REF_PATH = THIS_DIR / "reference" / "credits_reference.png"

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


def _decode_final_credanim(game_dir):
    data = (game_dir / "CREDANIM.BIN").read_bytes()
    frames = db.read_frames(data)
    off, end = frames[-1]
    canvas, status = db.decode_frame(data, off, end)
    if status != "ok":
        sys.exit(f"CREDANIM final frame decode failed: {status}")
    return unsplit(canvas)


def _used_indices(game_dir):
    """Every palette index either title animation draws across all its frames."""
    used = set()
    for name in ("CREDANIM.BIN", "HIANIM.BIN"):
        data = (game_dir / name).read_bytes()
        for off, end in db.read_frames(data):
            canvas, status = db.decode_frame(data, off, end)
            if status == "ok":
                used.update(canvas.values())
    return used


def _align(canvas, ref):
    """Find (scale, dx, dy) mapping canvas pixels onto the reference screenshot,
    scored by how consistently each index samples a single color."""
    px = ref.load()
    sw, sh = ref.size
    best = None
    for scale in (1, 2, 3, 4):
        for dy in range(-6, 10):
            for dx in range(-6, 10):
                hit = ok = 0
                seen = {}
                for (x, y), idx in canvas.items():
                    sx, sy = x * scale + dx, y * scale + dy
                    if 0 <= sx < sw and 0 <= sy < sh:
                        col = px[sx, sy]
                        bucket = seen.setdefault(idx, {})
                        bucket[col] = bucket.get(col, 0) + 1
                        hit += 1
                if not hit:
                    continue
                for bucket in seen.values():
                    ok += max(bucket.values())
                score = ok / hit
                if best is None or (score, scale) > (best[0], best[1]):
                    best = (score, scale, dx, dy)
    return best


def extract_palette(game_dir):
    """Recover the 768-byte DAC palette from the reference CREDITS screenshot."""
    from PIL import Image
    canvas = _decode_final_credanim(game_dir)
    ref = Image.open(REF_PATH).convert("RGB")
    score, scale, dx, dy = _align(canvas, ref)
    if score < 0.95:
        sys.exit(f"alignment too weak (score={score:.3f}); check reference shot")
    px = ref.load()
    sw, sh = ref.size
    samples = {}
    for (x, y), idx in canvas.items():
        sx, sy = x * scale + dx, y * scale + dy
        if 0 <= sx < sw and 0 <= sy < sh:
            bucket = samples.setdefault(idx, {})
            bucket[px[sx, sy]] = bucket.get(px[sx, sy], 0) + 1
    truth = {idx: max(b, key=b.get) for idx, b in samples.items()}
    known = sorted(truth)

    def lerp(a, b, t):
        return tuple(round(a[c] + (b[c] - a[c]) * t) for c in range(3))

    def color(i):
        # Interpolate within the sampled range; linearly extend the nearest ramp
        # segment past either end (the zoom frames use a few indices, e.g. the
        # 184-188 tail of the grey bevel, that the final frame never shows).
        if i in truth:
            return truth[i]
        if i < known[0]:
            a, b = known[0], known[1]
        elif i > known[-1]:
            a, b = known[-2], known[-1]
        else:
            a = max(k for k in known if k < i)
            b = min(k for k in known if k > i)
        return lerp(truth[a], truth[b], (i - a) / (b - a))

    pal = bytearray(768)
    for i in _used_indices(game_dir):
        r, g, b = color(i)
        pal[i * 3] = max(0, min(255, r))
        pal[i * 3 + 1] = max(0, min(255, g))
        pal[i * 3 + 2] = max(0, min(255, b))
    return bytes(pal)


def load_palette():
    return PAL_PATH.read_bytes()[:768]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game-dir", default=None,
                    help="original game dir containing CREDANIM.BIN")
    args = ap.parse_args()

    data_dir = None
    for base in (args.game_dir and Path(args.game_dir),
                 THIS_DIR.parent.parent / "dos" / "seek",
                 Path.home() / "dos" / "seek"):
        if not base:
            continue
        for c in (base / "data", base):
            if (c / "CREDANIM.BIN").exists():
                data_dir = c
                break
        if data_dir:
            break
    if data_dir is None:
        sys.exit("Could not find CREDANIM.BIN. Pass --game-dir (the seek dir).")

    pal = extract_palette(data_dir)
    # Store as 6-bit VGA (decode_blitter.render expands entries by *4).
    PAL_PATH.write_bytes(bytes(b >> 2 for b in pal))
    print(f"wrote {PAL_PATH.relative_to(THIS_DIR.parent)} ({len(pal)} bytes)")


if __name__ == "__main__":
    main()
