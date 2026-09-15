#!/usr/bin/env python3
"""
Export the weapon-shop sprite batteries to assets/pow/ in the shop's runtime
palette.

The POWUP / POWUPT shop screens set their VGA palette at load time: the shipped
GOVPAL.BIN is only valid for indices 0-79 and the embedded fullscreen palette is
green-shifted (see decode_fullscreen_v2), so decoding these
sprites with either gives the wrong colours. The true runtime palette is
reconstructed from our screenshot-derived assets/fullscreen/POWUP.png +
POWUPT.png (the same trick export_equip.py uses for the equip screens):

  - an index present in a backdrop -> the mode colour of that index's pixels in
    the exported PNG (accurate screenshot colours);
  - the POWWGADS icon-body indices (168-191) are absent from the backdrops (the
    backdrops bake the icons at other indices), so they are recovered by aligning
    each 40x40 POWWGADS icon tile onto its matching backdrop box and reading the
    colour under each index;
  - an index < 80 not otherwise found -> GOVPAL x4 (the validated menu ramp);
  - any leftover index a sprite still uses -> filled from its in-frame spatial
    neighbours so no hole shows.

Outputs (assets/pow/, overwriting the GOVPAL-decoded ones):
  powmedal_f*   awarded medal (the icon shown in the shop purse)
  pownames_f*   weapon-category labels
  powarmed_f*   LOADED label (+ the shareware notice frame)
  powfocus_f*   selection focus ring
  powwgads_f*   weapon level icons

Run from the repo root (needs assets/fullscreen/POWUP.png + POWUPT.png):
  python3 tools/export_shop.py
"""

import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("ERROR: pip install pillow numpy", file=sys.stderr)
    sys.exit(1)

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent
sys.path.insert(0, str(THIS_DIR))

import decode_blitter as db
import decode_planar as dp
from decode_fullscreen import deinterleave_modex

FS_HEADER, PAL_SIZE = 14, 768

# Shop box grid (design px), shared by both backdrops: box 40x40, three columns
# per side, three rows (the tank screen uses only the first two rows).
COLS = [8, 53, 98, 181, 226, 271]
ROWS = {"POWUP.png": [65, 119, 173], "POWUPT.png": [65, 119]}

SPRITES = ["POWMEDAL", "POWNAMES", "POWARMED", "POWFOCUS", "POWWGADS"]


def find_game_dir(hint):
    for c in ([Path(hint)] if hint else []) + [
            REPO_ROOT.parent / "dos" / "seek", Path.home() / "dos" / "seek"]:
        if (c / "data").exists():
            return c
    sys.exit("Could not find game directory. Pass --game-dir.")


def frames_of(data):
    dec = dp if dp.is_planar(data) else db
    out = []
    for off, end in dec.read_frames(data):
        canvas, status = dec.decode_frame(data, off, end)
        if status == "ok" and canvas:
            out.append(canvas)
    return out


def backdrop_colors(bin_path, png_path):
    """index -> mode RGB, read from a backdrop's index map and its exported PNG."""
    idx = np.asarray(deinterleave_modex(
        bin_path.read_bytes()[FS_HEADER + PAL_SIZE:])).reshape(240, 320)
    ref = np.asarray(Image.open(png_path).convert("RGB"))
    out = {}
    for i in np.unique(idx):
        cols = ref[idx == i].reshape(-1, 3)
        uniq, cnt = np.unique(cols, axis=0, return_counts=True)
        out[int(i)] = tuple(int(v) for v in uniq[cnt.argmax()])
    return out


def tile_of(canvas):
    """Normalise a blit canvas to a 40x40 index array (-1 = unwritten)."""
    xs = [c[0] for c in canvas]
    ys = [c[1] for c in canvas]
    x0, y0 = min(xs), min(ys)
    arr = np.full((40, 40), -1, int)
    for (x, y), i in canvas.items():
        yy, xx = y - y0, x - x0
        if 0 <= yy < 40 and 0 <= xx < 40 and i is not None:
            arr[yy, xx] = i
    return arr


def recover_icon_colors(game_dir):
    """POWWGADS icon-body indices: align each 40x40 icon tile to the best
    backdrop box (with a small offset search) and read the colour under each
    index. Returns index -> most-voted RGB."""
    boxes = []
    for png, rows in ROWS.items():
        ref = np.asarray(Image.open(REPO_ROOT / "assets" / "fullscreen" / png).convert("RGB"))
        for y in rows:
            for x in COLS:
                boxes.append(ref[y - 4:y + 44, x - 4:x + 44].copy())  # 4px pad for the offset search
    from collections import defaultdict
    votes = defaultdict(lambda: defaultdict(int))
    for canvas in frames_of((game_dir / "data" / "POWWGADS.BIN").read_bytes()):
        if len(canvas) < 1000:      # only the full 40x40 icon tiles align to a box
            continue
        arr = tile_of(canvas)
        best = None
        for tile in boxes:
            for dy in range(9):
                for dx in range(9):
                    sub = tile[dy:dy + 40, dx:dx + 40]
                    score = 0
                    for i in np.unique(arr):
                        if i < 0:
                            continue
                        cols = sub[arr == i].reshape(-1, 3)
                        _, cnt = np.unique(cols, axis=0, return_counts=True)
                        score += int(cnt.sum() - cnt.max())
                    if best is None or score < best[0]:
                        best = (score, sub.copy())
        sub = best[1]
        for i in np.unique(arr):
            if i < 0:
                continue
            cols = sub[arr == i].reshape(-1, 3)
            uniq, cnt = np.unique(cols, axis=0, return_counts=True)
            votes[int(i)][tuple(int(v) for v in uniq[cnt.argmax()])] += int(cnt.max())
    return {i: max(v.items(), key=lambda kv: kv[1])[0] for i, v in votes.items()}


def build_palette(game_dir):
    pal = [None] * 256
    merged = backdrop_colors(game_dir / "data" / "POWUP.BIN",
                             REPO_ROOT / "assets" / "fullscreen" / "POWUP.png")
    for k, v in backdrop_colors(game_dir / "data" / "POWUPT.BIN",
                                REPO_ROOT / "assets" / "fullscreen" / "POWUPT.png").items():
        merged.setdefault(k, v)
    icons = recover_icon_colors(game_dir)
    gov   = (game_dir / "data" / "GOVPAL.BIN").read_bytes()
    for i in range(256):
        if i in merged:
            pal[i] = merged[i]
        elif i in icons:
            pal[i] = icons[i]
        elif i < 80:
            pal[i] = (min(gov[i * 3] * 4, 255), min(gov[i * 3 + 1] * 4, 255),
                      min(gov[i * 3 + 2] * 4, 255))
    return pal


def fill_holes(rgba):
    """Fill any still-transparent-but-written pixel (unknown palette index,
    tagged with alpha 1) from its opaque 8-neighbours, iterating to stable."""
    arr = np.asarray(rgba).copy()
    for _ in range(8):
        holes = np.argwhere(arr[:, :, 3] == 1)
        if len(holes) == 0:
            break
        for y, x in holes:
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < arr.shape[0] and 0 <= nx < arr.shape[1] and arr[ny, nx, 3] == 255:
                    arr[y, x] = arr[ny, nx]
                    break
    arr[arr[:, :, 3] == 1] = 0
    return Image.fromarray(arr, "RGBA")


def render(canvas, pal):
    xs = [c[0] for c in canvas]
    ys = [c[1] for c in canvas]
    x0, y0 = min(xs), min(ys)
    w, h = max(xs) - x0 + 1, max(ys) - y0 + 1
    arr = np.zeros((h, w, 4), np.uint8)
    for (x, y), i in canvas.items():
        if i is None:
            continue
        c = pal[i]
        arr[y - y0, x - x0] = (c[0], c[1], c[2], 255) if c else (0, 0, 0, 1)  # alpha 1 = hole
    return fill_holes(Image.fromarray(arr, "RGBA"))


def main():
    ap = argparse.ArgumentParser(description="Export shop sprites to assets/pow/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()
    game_dir = find_game_dir(args.game_dir)
    print(f"Game dir: {game_dir}")

    for png in ROWS:
        if not (REPO_ROOT / "assets" / "fullscreen" / png).exists():
            sys.exit(f"missing assets/fullscreen/{png} (run the fullscreen export first)")

    pal = build_palette(game_dir)
    out_dir = REPO_ROOT / "assets" / "pow"
    out_dir.mkdir(parents=True, exist_ok=True)

    for stem in SPRITES:
        src = game_dir / "data" / (stem + ".BIN")
        if not src.exists():
            print(f"  skip {stem}: not found")
            continue
        n = 0
        for i, canvas in enumerate(frames_of(src.read_bytes())):
            render(canvas, pal).save(out_dir / f"{stem.lower()}_f{i:02d}.png")
            n += 1
        print(f"  {stem}: {n} frames -> assets/pow/{stem.lower()}_f*.png")


if __name__ == "__main__":
    main()
