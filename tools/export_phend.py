#!/usr/bin/env python3
"""
Export the end-of-phase DESTRUCTION STATS screen art to assets/phend/ for the
Love2D engine.

The original draws this screen from a battery of blitter sprites in the
PHASEPAL.BIN palette:

  PHEND      "PHASE" header + decorative wings + "DESTRUCTION STATS" title
  PHASENUM   the metallic phase number (1..4), a 4-frame world sprite
  PHGTXT     line 1 strip: "1. GROUND FORCES"            + baked "000%"
  PHBTXT     line 2 strip: "2. BUILDINGS / INSTALLATIONS"+ baked "000%"
  PHCTXT     line 3 strip: "3. CHOPPERS SHOT DOWN"       + baked "000"
  PHPTXT     line 4 strip: "4. RESCUES"                  + baked "00"
  PHOTXT     line 5 strip: "5." + "TOTAL SCORE" label    + baked "00"
  STATNUMS   the readout digit font: 0-9 white then 0-9 gold (20 planar frames)

The strip blitter streams are authored relative to a single origin (the engine
repositions each line at runtime), so they all decode onto the same rows and
wrap around the 384-pixel mode-X back buffer (STRIDE 96). We unwrap by rolling
x past the largest empty column gap, then split each strip at the gap between
the label text (left) and the baked number placeholder (right): only the label
is exported, the live readout is drawn with STATNUMS at runtime. The "%" glyph
is lifted from PHGTXT for the percentage lines.
"""

import json
import struct
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent
sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db
import decode_planar as dp
from PIL import Image

W = 384  # mode-X back-buffer width in pixels (STRIDE 96 * 4 planes)


def find_game_dir(hint):
    if hint:
        p = Path(hint)
        if p.exists():
            return p
        sys.exit(f"game dir not found: {hint}")
    for c in (REPO_ROOT.parent / "dos" / "seek", Path.home() / "dos" / "seek"):
        if (c / "data").exists():
            return c
    sys.exit("Could not find game directory. Pass --game-dir.")


def decode_stream(data, frame_off):
    """Decode one blitter stream into {(x, y): index}, x folded into 0..W-1."""
    data_off = struct.unpack_from("<h", data, frame_off)[0]
    ptr = frame_off + data_off
    x0, y0 = 192, 100
    cursor = y0 * db.STRIDE + (x0 >> 2)
    plane, ctrl = x0 & 3, 1
    canvas = {}
    while ptr + 4 <= len(data):
        delta, code = struct.unpack_from("<hh", data, ptr)
        ptr += 4
        cursor += delta
        act = db.classify((db.CHAIN1 if ctrl == 1 else db.CHAIN2) + code)
        cl = None
        for op in act["ops"]:
            if ptr >= len(data):
                break
            if op == "load":
                cl = data[ptr]
            elif op == "inc":
                ptr += 1
            elif op == "write":
                y, bx = divmod(cursor, db.STRIDE)
                canvas[((bx * 4 + plane) % W, y)] = cl
            elif op == "step":
                cursor += db.STRIDE
        if act["kind"] == "copy":
            ctrl = act["ctrl"]
        elif act["kind"] == "plane":
            if act["inc_on_wrap"] and plane == 3:
                cursor += 1
            plane = (plane + 1) & 3
            ctrl = 1
        elif act["kind"] == "remask":
            ctrl = 1
        elif act["kind"] == "end":
            return canvas
    return canvas


def unwrap(canvas):
    """Roll x so content is contiguous (split at the widest empty column run)."""
    cols = {x for (x, _) in canvas}
    occ = [x in cols for x in range(W)]
    best_len = best_start = run = rs = 0
    for x in range(W * 2):
        if not occ[x % W]:
            if run == 0:
                rs = x
            run += 1
            if run > best_len:
                best_len, best_start = run, rs
        else:
            run = 0
    shift = (best_start + best_len) % W
    return {((x - shift) % W, y): p for (x, y), p in canvas.items()}


def crop_box(canvas, x0, x1, y0, y1, palette):
    px = {(x, y): p for (x, y), p in canvas.items() if x0 <= x <= x1 and y0 <= y <= y1}
    if not px:
        return None
    xs = [c[0] for c in px]
    ys = [c[1] for c in px]
    a, b, c, d = min(xs), max(xs), min(ys), max(ys)
    img = Image.new("RGBA", (b - a + 1, d - c + 1), (0, 0, 0, 0))
    for (x, y), p in px.items():
        img.putpixel((x - a, y - c), (palette[p * 3] * 4, palette[p * 3 + 1] * 4,
                                      palette[p * 3 + 2] * 4, 255))
    return img


def column_clusters(canvas, gap=4):
    cols = sorted({x for (x, _) in canvas})
    if not cols:
        return []
    out, cur = [], [cols[0]]
    for x in cols[1:]:
        if x - cur[-1] <= gap:
            cur.append(x)
        else:
            out.append((cur[0], cur[-1]))
            cur = [x]
    out.append((cur[0], cur[-1]))
    return out


# strip stem -> (out filename, value kind, kill-icon frame, percentage line?)
LINES = [
    ("PHGTXT", "ground",   "ground",   0, True),
    ("PHBTXT", "buildings","buildings",1, True),
    ("PHCTXT", "choppers", "choppers", 2, False),
    ("PHPTXT", "rescues",  "rescues",  3, False),
]


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()
    game = find_game_dir(args.game_dir)
    pal = (game / "data" / "PHASEPAL.BIN").read_bytes()[:768]
    out = REPO_ROOT / "assets" / "phend"
    out.mkdir(parents=True, exist_ok=True)
    print(f"Game dir: {game}\n -> {out.relative_to(REPO_ROOT)}/")

    layout = {"lines": []}

    # Header (PHEND) and phase numbers (PHASENUM, world-table 4 frames).
    head = unwrap(decode_stream((game / "data" / "PHEND.BIN").read_bytes(), 4))
    xs = [c[0] for c in head]; ys = [c[1] for c in head]
    crop_box(head, min(xs), max(xs), min(ys), max(ys), pal).save(out / "header.png")
    print("  header.png")

    pn = (game / "data" / "PHASENUM.BIN").read_bytes()
    for i, (off, _end) in enumerate(db.read_frames(pn)):
        c = decode_stream(pn, off)
        xs = [p[0] for p in c]; ys = [p[1] for p in c]
        crop_box(c, min(xs), max(xs), min(ys), max(ys), pal).save(out / f"phase_f{i}.png")
    print("  phase_f0..3.png")

    # STATNUMS readout digit font (planar): 0-9 white (f00-09), 0-9 gold (f10-19).
    sn = (game / "data" / "STATNUMS.BIN").read_bytes()
    for i, (off, end) in enumerate(dp.read_frames(sn)):
        canvas, _ = dp.decode_frame(sn, off, end)
        dp.render(canvas, pal, scale=1).save(out / f"digit_f{i:02d}.png")
    print("  digit_f00..19.png")

    # The percentage lines: label-only crop + a lifted "%" glyph.
    pct_saved = False
    for stem, name, icon_value, icon_frame, is_pct in LINES:
        strip = unwrap(decode_stream((game / "data" / (stem + ".BIN")).read_bytes(), 4))
        words = column_clusters(strip, gap=10)
        label = words[0]            # leftmost run = label text
        ys = [y for (x, _y), _p in [] for y in []]  # placeholder
        # label-only crop
        ys = [y for (x, y) in strip if label[0] <= x <= label[1]]
        crop_box(strip, label[0], label[1], min(ys), max(ys), pal).save(out / f"label_{name}.png")
        layout["lines"].append({
            "name": name, "label": f"label_{name}.png",
            "value": icon_value, "icon_frame": icon_frame, "pct": is_pct,
        })
        if is_pct and not pct_saved:
            # the baked number cluster is "0 0 0 %"; the rightmost sub-cluster is %.
            num = words[-1]
            sub = column_clusters({(x, y): p for (x, y), p in strip.items()
                                   if num[0] <= x <= num[1]}, gap=2)
            px0, px1 = sub[-1]
            pys = [y for (x, y) in strip if px0 <= x <= px1]
            crop_box(strip, px0, px1, min(pys), max(pys), pal).save(out / "pct.png")
            pct_saved = True
        print(f"  label_{name}.png")

    # PHOTXT: "5." marker (top row) + "TOTAL SCORE" label (bottom row).
    o = unwrap(decode_stream((game / "data" / "PHOTXT.BIN").read_bytes(), 4))
    ys = sorted({y for (_x, y) in o})
    split_y = ys[0] + (ys[-1] - ys[0]) // 2
    words = column_clusters({(x, y): p for (x, y), p in o.items() if y <= split_y}, gap=10)
    five = words[0]
    fys = [y for (x, y) in o if five[0] <= x <= five[1] and y <= split_y]
    crop_box(o, five[0], five[1], min(fys), max(fys), pal).save(out / "label_total5.png")
    bot = {(x, y): p for (x, y), p in o.items() if y > split_y}
    bxs = [c[0] for c in bot]; bys = [c[1] for c in bot]
    crop_box(o, min(bxs), max(bxs), min(bys), max(bys), pal).save(out / "label_totalscore.png")
    layout["lines"].append({
        "name": "okrating", "label": "label_total5.png",
        "value": "okrating", "icon_frame": None, "pct": False, "ok_badge": True,
    })
    print("  label_total5.png  label_totalscore.png")

    (out / "layout.json").write_text(json.dumps(layout, indent=2) + "\n")
    print("  layout.json")


if __name__ == "__main__":
    main()
