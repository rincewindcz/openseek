#!/usr/bin/env python3
"""
Export the main menu's pre-rendered word sprites (MAINMEN.BIN) plus the
selection-arrow cursor to assets/mainmen/, one truecolor PNG per entry.

Usage:
  python3 tools/export_mainmen.py
  python3 tools/export_mainmen.py --game-dir /path/to/dos/seek

MAINMEN.BIN decodes cleanly with the world-blitter decoder (decode_blitter.py)
into 27 frames: 9 menu entries x 3 frames each, in on-screen order (NEW GAME,
RESUME, OPTIONS, CREDITS, HIGH SCORES, LOAD, SAVE, ORDER INFO, EXIT).

Color (solved 2026-07-01): frame 0 of each triple is the real pose and decodes
to the genuine on-screen palette indices (a dark outline at idx 142 plus the
gold ramp 15/16/21/63/89/91/92). Those indices are magenta placeholders in the
static GOVPAL.BIN, which is why an earlier pass mistook frame 0 for a bad decode
and fell back to frame 1 (a grey-ramp copy) recolored onto an invented gold
tint. The menu's real runtime palette is not reconstructable from any data/ BIN
(a runtime swap the static disassembly does not cover), but MAINMEN.BMP -- a
256-color screen capture that ships in the game root next to SHOT0..2.BMP --
embeds it exactly. We index frame 0 straight through that captured palette, so
the exported glyphs are pixel-identical to the original screen.

The arrow cursor (a solid gold right-pointing triangle next to the highlighted
entry) is not present as its own sprite file in the game data; it is cropped
directly out of MAINMEN.BMP, keyed on the same gold ramp.

HIGH SCORES is wider than the others and its final "S" wraps around the Mode X
virtual buffer (384 px = 96 bytes x 4 planes), decoding to negative x. unwrap()
adds the buffer width back so the tail rejoins the word; keep_largest_cluster()
then drops any remaining stray column cluster that isn't part of the main (by
far the largest) contiguous run.
"""

import argparse
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent

sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db

# On-screen order, matching MAINMEN.BIN's frame layout 1:1.
ENTRIES = [
    "new_game", "resume", "options", "credits", "hiscores",
    "load", "save", "order_info", "exit",
]

CLUSTER_GAP = 40   # px; real inter-word gaps in a phrase measure ~22px
MODEX_WIDTH = 384  # Mode X virtual buffer width (96 bytes x 4 planes)

# Runtime menu-palette indices that make up the gold text/arrow (dark outline
# 142 plus the gold ramp). Used to key the arrow out of the screen capture.
GOLD_INDICES = {15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
                63, 87, 88, 89, 90, 91, 92}

# Where the arrow sits in MAINMEN.BMP (native 320x240), left of NEW GAME.
ARROW_BOX = (36, 34, 56, 54)  # x0, y0, x1, y1 search window (exclusive x1/y1)


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


def unwrap(canvas, width=MODEX_WIDTH):
    return {((x + width if x < 0 else x), y): v for (x, y), v in canvas.items()}


def keep_largest_cluster(canvas, gap=CLUSTER_GAP):
    xs = sorted(set(x for x, _ in canvas))
    clusters = []
    start = prev = xs[0]
    for x in xs[1:]:
        if x - prev > gap:
            clusters.append((start, prev))
            start = x
        prev = x
    clusters.append((start, prev))
    if len(clusters) == 1:
        return canvas
    x0, x1 = max(clusters, key=lambda c: sum(1 for (x, _y) in canvas if c[0] <= x <= c[1]))
    return {(x, y): v for (x, y), v in canvas.items() if x0 <= x <= x1}


def load_bmp_palette(bmp_path):
    from PIL import Image
    pal = Image.open(bmp_path).getpalette()  # flat [r,g,b, r,g,b, ...], 8-bit
    return [tuple(pal[i * 3:i * 3 + 3]) for i in range(256)]


def render_indexed(canvas, palette):
    from PIL import Image
    xs = [x for x, _ in canvas]
    ys = [y for _, y in canvas]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    img = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1), (0, 0, 0, 0))
    for (x, y), idx in canvas.items():
        r, g, b = palette[idx]
        img.putpixel((x - x0, y - y0), (r, g, b, 255))
    return img


def export_arrow(bmp_path, palette, out_dir):
    from PIL import Image
    src = Image.open(bmp_path)
    px = src.load()
    sx0, sy0, sx1, sy1 = ARROW_BOX
    gold = {(x, y) for y in range(sy0, sy1) for x in range(sx0, sx1)
            if px[x, y] in GOLD_INDICES}
    if not gold:
        print("  skip arrow: no gold pixels found in ARROW_BOX")
        return
    xs = [x for x, _ in gold]
    ys = [y for _, y in gold]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    img = Image.new("RGBA", (x1 - x0 + 1, y1 - y0 + 1), (0, 0, 0, 0))
    for (x, y) in gold:
        r, g, b = palette[px[x, y]]
        img.putpixel((x - x0, y - y0), (r, g, b, 255))
    img.save(out_dir / "arrow.png")
    print(f"  arrow: {img.width}x{img.height} -> assets/mainmen/arrow.png")


def main():
    ap = argparse.ArgumentParser(description="Export MAINMEN word sprites to assets/mainmen/")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()

    game_dir = find_game_dir(args.game_dir)
    out_dir  = REPO_ROOT / "assets" / "mainmen"
    out_dir.mkdir(parents=True, exist_ok=True)

    bmp_path = game_dir / "MAINMENU.BMP"
    if not bmp_path.exists():
        sys.exit(f"runtime palette source not found: {bmp_path}")
    palette = load_bmp_palette(bmp_path)

    data   = (game_dir / "data" / "MAINMEN.BIN").read_bytes()
    frames = db.read_frames(data)
    if len(frames) != len(ENTRIES) * 3:
        sys.exit(f"expected {len(ENTRIES) * 3} frames, got {len(frames)}")

    print(f"Game dir: {game_dir}")
    print(f"Output:   {out_dir}\n")

    for i, entry_id in enumerate(ENTRIES):
        off, end = frames[i * 3]
        canvas, status = db.decode_frame(data, off, end)
        if status != "ok" or not canvas:
            print(f"  skip {entry_id}: {status}")
            continue
        canvas = keep_largest_cluster(unwrap(canvas))
        img = render_indexed(canvas, palette)
        fname = f"{entry_id}.png"
        img.save(out_dir / fname)
        print(f"  {entry_id}: {img.width}x{img.height} -> assets/mainmen/{fname}")

    export_arrow(bmp_path, palette, out_dir)


if __name__ == "__main__":
    main()
