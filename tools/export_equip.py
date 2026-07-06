#!/usr/bin/env python3
"""
Export the vehicle equip screens' widget art to assets/equip/ for the Love2D
engine.

The equip screens (EQPCHP.BIN / EQPTNK.BIN fullscreen backdrops, already
exported to assets/fullscreen/) bake the whole static GUI: the weapon bay
boxes, one row per weapon, the level-pip boxes, the CHARACTERISTICS bars and
the OK / EXIT / TANK|CHOP buttons. The dynamic art lives in sibling
containers:

  EQPCHPG  / EQPTNKG   every weapon-name row in 3 states per weapon:
                       f+0 normal (owned), f+1 selected (gold text, the
                       loaded-in-this-bay state), f+2 darkened (not owned).
                       The trailing frames are the CHARACTERISTICS bar fills
                       (unused here; the baked bars are kept).
  EQPCHPG2 / EQPTNKG2  the OK / EXIT / TANK|CHOP buttons (normal + pressed)
                       plus a blank button plate (used to hide the vehicle
                       switch on tank-only phases).
  EQPNUMS              gold 5x6 digits 0-9 (planar).

Palette: the widget sprites index a region the embedded fullscreen palette
leaves wrong (the game sets it at runtime, like MAINMEN). The runtime palette
is reconstructed in two parts. Indices 0-79 are GOVPAL verbatim: the equip
UI's gold header ramp (24-27), the grey text ramp (64-74), black outline (16)
match it exactly. Indices 80+ (the screen plates / bevels / photo shades) are
sampled from our own assets/fullscreen/EQP*.png exports: per index, the mode
color over pixels whose 3x3 index neighborhood is uniform (interior pixels,
immune to the capture's downscale blur), falling back to the median over all
its pixels for thin features. Both screens contribute; every index the
widgets use is covered.

The backdrops are also re-rendered here (320x240) from their index maps
through the reconstructed palette: the assets/fullscreen/ PNGs are
screenshot-derived (per-index color variance from the capture downscale), so
widgets pasted over them would seam; rendering both from one palette makes
the widget states land pixel-identical on the baked art.

Layout: each row/button frame is template-matched against the backdrop index
map (exact match with a tiny tolerance), giving the design-space position of
every widget; positions are grouped into bays and written to layout.json.
Bay 1 (always CHAIN-GUN) is baked in a unique selected look with no gadget
frame; its rect and pip block are located by scanning for its 247-background
run and the lit-pip pattern. Level pips (4x8 boxes at a 5px pitch, lit gold /
empty grey) are cropped straight out of the backdrop.
"""

import json
import sys
from pathlib import Path

THIS_DIR  = Path(__file__).resolve().parent
REPO_ROOT = THIS_DIR.parent
sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db
import decode_planar as dp
from decode_fullscreen import deinterleave_modex

try:
    from PIL import Image
    import numpy as np
except ImportError:
    sys.exit("pip install pillow numpy")

MATCH_TOLERANCE = 4     # max mismatching pixels for a template hit
PIP_PITCH       = 5     # pip box pitch (4 px box + 1 px shadow)
PIP_W, PIP_H    = 4, 8

# widget container weapon order (frame triples: normal / selected / dark)
WEAPONS = {
    "chopper": ["chaingun", "rockets", "air_to_ground", "air_to_air",
                "napalm", "air_strike",
                "mega_missile", "super_napalm", "bomb"],
    "tank":    ["chaingun", "shells", "flame_thrower", "air_strike",
                "power_shell", "ground_to_air", "mine"],
}
SPECIALS = {
    "chopper": {"mega_missile", "super_napalm", "bomb"},
    "tank":    {"power_shell", "ground_to_air", "mine"},
}
SCREENS = {
    "chopper": ("EQPCHP", "EQPCHPG", "EQPCHPG2"),
    "tank":    ("EQPTNK", "EQPTNKG", "EQPTNKG2"),
}
BUTTONS = ["ok", "exit", "switch"]   # G2 frame pairs 0/1, 2/3, 4/5; f06 = plate


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


def index_map(bin_path):
    data = bin_path.read_bytes()
    return np.asarray(deinterleave_modex(data[14 + 768:]))


def blitter_frames(bin_path):
    data = bin_path.read_bytes()
    out = []
    for fo, fe in db.read_frames(data):
        canvas, status = db.decode_frame(data, fo, fe)
        out.append(canvas if status == "ok" else {})
    return out


def planar_frames(bin_path):
    data = bin_path.read_bytes()
    out = []
    for fo, fe in dp.read_frames(data):
        canvas, status = dp.decode_frame(data, fo, fe)
        out.append(canvas if status == "ok" else {})
    return out


def build_palette(maps, pngs, gov):
    """GOVPAL for indices 0-79, backdrop-sampled colors for 80+."""
    pal = [None] * 256
    for i in range(80):   # GOVPAL entries 80+ are placeholder sentinels
        pal[i] = (min(gov[i * 3] * 4, 255), min(gov[i * 3 + 1] * 4, 255),
                  min(gov[i * 3 + 2] * 4, 255))
    for arr, png_path in zip(maps, pngs):
        ref = np.asarray(Image.open(png_path).convert("RGB"))
        interior = np.ones(arr.shape, dtype=bool)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                interior &= np.roll(np.roll(arr, dy, axis=0), dx, axis=1) == arr
        interior[0, :] = interior[-1, :] = False
        interior[:, 0] = interior[:, -1] = False
        for idx in np.unique(arr):
            if pal[idx] is not None:
                continue
            m  = arr == idx
            mi = m & interior
            if mi.sum() >= 8:
                cols = ref[mi].reshape(-1, 3)
                uniq, counts = np.unique(cols, axis=0, return_counts=True)
                pal[idx] = tuple(int(v) for v in uniq[counts.argmax()])
            else:
                pal[idx] = tuple(int(v) for v in
                                 np.median(ref[m].reshape(-1, 3), axis=0))
    return pal


def canvas_arr(canvas):
    xs = [c[0] for c in canvas]
    ys = [c[1] for c in canvas]
    f = np.full((max(ys) + 1, max(xs) + 1), -1, dtype=np.int16)
    for (x, y), v in canvas.items():
        f[y, x] = v
    return f


def save_canvas(canvas, pal, path):
    f = canvas_arr(canvas)
    h, w = f.shape
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for y in range(h):
        for x in range(w):
            p = f[y, x]
            if p >= 0:
                img.putpixel((x, y), (*(pal[p] or (255, 0, 255)), 255))
    img.save(path)


def find_all(frame, arr, tolerance=MATCH_TOLERANCE):
    """All (x, y) where the frame matches the index map within tolerance."""
    from numpy.lib.stride_tricks import sliding_window_view
    f = canvas_arr(frame)
    h, w = f.shape
    win  = sliding_window_view(arr, (h, w))
    errs = ((win != f) & (f >= 0)).sum(axis=(2, 3))
    ys, xs = np.where(errs <= tolerance)
    return sorted(zip(xs.tolist(), ys.tolist()), key=lambda p: (p[1], p[0]))


def find_pips(arr, y, x_from, x_to):
    """The x of the first pip box (border index 24 lit or 69 empty) on row y."""
    for x in range(x_from, x_to):
        col = arr[y:y + PIP_H, x]
        if np.all((col == 69) | (col == 70)) or np.all((col == 24) | (col == 26)):
            # require a full triple to reject stray matches
            b2 = arr[y, x + PIP_PITCH:x + PIP_PITCH + PIP_W]
            if np.all((b2 == 69) | (b2 == 24)):
                return x
    return None


def find_bay1_row(arr):
    """Bay 1's baked CHAIN-GUN row: the wide 247-background run, top-left."""
    region = arr[36:110, 0:140]
    ys, xs = np.where(region == 247)
    if len(xs) == 0:
        return None
    x0, x1 = int(xs.min()), int(xs.max())
    y0, y1 = int(ys.min()) + 36, int(ys.max()) + 36
    return {"x": x0, "y": y0, "w": x1 - x0 + 1, "h": y1 - y0 + 1}


def crop_pips(arr, pal, x, y, out_dir):
    """Crop the lit and empty pip boxes (bay 1 shows one lit + two empty)."""
    for name, px in (("pip_lit", x), ("pip_empty", x + PIP_PITCH)):
        img = Image.new("RGBA", (PIP_W, PIP_H), (0, 0, 0, 0))
        for dy in range(PIP_H):
            for dx in range(PIP_W):
                p = int(arr[y + dy, px + dx])
                img.putpixel((dx, dy), (*(pal[p] or (255, 0, 255)), 255))
        img.save(out_dir / f"{name}.png")


def save_backdrop(arr, pal, path):
    h, w = arr.shape
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = pal[int(arr[y, x])] or (255, 0, 255)
    img.save(path)


def export_screen(vehicle, game, pal, maps, out):
    back_stem, g_stem, g2_stem = SCREENS[vehicle]
    arr     = maps[vehicle]
    rows    = blitter_frames(game / "data" / f"{g_stem}.BIN")
    buttons = blitter_frames(game / "data" / f"{g2_stem}.BIN")
    weapons = WEAPONS[vehicle]
    layout  = {"backdrop": f"{vehicle}_backdrop.png",
               "bays": [], "specials": [], "buttons": {}}
    save_backdrop(arr, pal, out / f"{vehicle}_backdrop.png")

    # Row art: 3 states per weapon.
    for wi, weapon in enumerate(weapons):
        for si, state in enumerate(("normal", "sel", "dark")):
            name = f"{vehicle}_row_{weapon}_{state}.png"
            save_canvas(rows[wi * 3 + si], pal, out / name)

    # Positions: the backdrop bakes each row in an arbitrary state (the tank
    # screen mixes normal and selected), so match all three per weapon.
    row_w = {w: canvas_arr(rows[wi * 3]).shape[1] for wi, w in enumerate(weapons)}
    hits = {w: [] for w in weapons}
    for wi, weapon in enumerate(weapons):
        for si in range(3):
            hits[weapon] += find_all(rows[wi * 3 + si], arr)

    # Bay 1: the fixed chain-gun row. The tank screen bakes the selected
    # gadget frame; the chopper screen bakes unique art located by its
    # 247-background run.
    bay1 = ({"x": hits["chaingun"][0][0], "y": hits["chaingun"][0][1],
             "w": row_w["chaingun"]} if hits["chaingun"] else find_bay1_row(arr))
    if bay1:
        pip_x = find_pips(arr, bay1["y"], bay1["x"] + bay1["w"],
                          bay1["x"] + bay1["w"] + 12)
        layout["bays"].append({"fixed": "chaingun", "x": bay1["x"], "y": bay1["y"],
                               "pips_x": pip_x, "pips_y": bay1["y"]})
        if pip_x is not None and not (out / "pip_lit.png").exists():
            crop_pips(arr, pal, pip_x, bay1["y"], out)

    # Group bay rows by column + vertical band, fill unmatched rows / specials
    # from the 10 px row pitch (the tank backdrop lacks a baked MINE row).
    bay_order  = [w for w in weapons if w != "chaingun" and w not in SPECIALS[vehicle]]
    spec_order = [w for w in weapons if w in SPECIALS[vehicle]]
    groups = {}
    spec_anchor = None
    for weapon in weapons:
        for x, y in hits[weapon]:
            if weapon == "chaingun":
                continue
            if weapon in SPECIALS[vehicle]:
                if spec_anchor is None:
                    spec_anchor = (x, y - 10 * spec_order.index(weapon))
            else:
                groups.setdefault((x, y // 100), {})[weapon] = (x, y)
    for key in sorted(groups, key=lambda k: (k[1], k[0])):
        found = groups[key]
        ax, ay = next(iter(found.values()))
        a_weapon = next(iter(found))
        y0 = ay - 10 * bay_order.index(a_weapon)
        bay = []
        for i, weapon in enumerate(bay_order):
            x, y = found.get(weapon, (ax, y0 + 10 * i))
            pip_x = find_pips(arr, y, x + row_w[weapon], x + row_w[weapon] + 10)
            bay.append({"weapon": weapon, "x": x, "y": y,
                        "pips_x": pip_x, "pips_y": y})
        layout["bays"].append({"rows": bay})
    if spec_anchor:
        sx, sy = spec_anchor
        for i, weapon in enumerate(spec_order):
            layout["specials"].append({"weapon": weapon, "x": sx, "y": sy + 10 * i})

    # Buttons: normal / pressed pairs + the blank plate; the normal frame is
    # the baked one, giving the position.
    for bi, name in enumerate(BUTTONS):
        up, down = buttons[bi * 2], buttons[bi * 2 + 1]
        hits = find_all(up, arr)
        if not hits:
            hits = find_all(down, arr)
        save_canvas(up, pal, out / f"{vehicle}_btn_{name}_up.png")
        save_canvas(down, pal, out / f"{vehicle}_btn_{name}_down.png")
        if hits:
            layout["buttons"][name] = {"x": hits[0][0], "y": hits[0][1]}
    if len(buttons) > 6 and buttons[6]:
        save_canvas(buttons[6], pal, out / f"{vehicle}_btn_plate.png")

    n_rows = sum(len(b.get("rows", [])) for b in layout["bays"])
    print(f"  {vehicle}: {len(layout['bays'])} bays ({n_rows} rows), "
          f"{len(layout['specials'])} specials, {len(layout['buttons'])} buttons")
    return layout


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args()
    game = find_game_dir(args.game_dir)
    out  = REPO_ROOT / "assets" / "equip"
    out.mkdir(parents=True, exist_ok=True)
    print(f"Game dir: {game}\n -> {out.relative_to(REPO_ROOT)}/")

    maps, pngs = {}, []
    for vehicle, (back_stem, _g, _g2) in SCREENS.items():
        png = REPO_ROOT / "assets" / "fullscreen" / f"{back_stem}.png"
        if not png.exists():
            sys.exit(f"missing {png} (run the fullscreen export first)")
        maps[vehicle] = index_map(game / "data" / f"{back_stem}.BIN")
        pngs.append(png)

    pal = build_palette([maps["chopper"], maps["tank"]], pngs,
                        (game / "data" / "GOVPAL.BIN").read_bytes())

    layout = {}
    for vehicle in SCREENS:
        layout[vehicle] = export_screen(vehicle, game, pal, maps, out)

    # EQPNUMS: gold 5x6 digits 0-9 (unused by the engine yet, kept for later).
    for i, canvas in enumerate(planar_frames(game / "data" / "EQPNUMS.BIN")):
        save_canvas(canvas, pal, out / f"digit_f{i:02d}.png")
    print("  digit_f00..09.png")

    (out / "layout.json").write_text(json.dumps(layout, indent=2) + "\n")
    print("  layout.json")


if __name__ == "__main__":
    main()
