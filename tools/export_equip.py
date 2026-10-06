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

Palette: the equip screens draw in their backdrop's palette (the first 768
bytes of EQPCHP.BIN; EQPTNK.BIN carries the same one), widgets included.

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

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))
import decode_blitter as db
import decode_planar as dp
import export_fullscreen
import gamedata
import image

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
# CHARACTERISTICS slider tracks (design px, fullscreen space): the backdrop
# bakes one 33x8 track per row at a 10px pitch, located by matching the bar
# frame's bevels against it. Fuel and armor drag; speed is derived.
TRACK_W, TRACK_H = 33, 8
CHARACTERISTICS = {
    "chopper": [
        {"char": "fuel",  "x": 163, "y": 197, "w": TRACK_W, "h": TRACK_H},
        {"char": "armor", "x": 163, "y": 207, "w": TRACK_W, "h": TRACK_H},
        {"char": "speed", "x": 163, "y": 217, "w": TRACK_W, "h": TRACK_H, "readonly": True},
    ],
    "tank": [
        {"char": "fuel",  "x": 162, "y": 181, "w": TRACK_W, "h": TRACK_H},
        {"char": "armor", "x": 162, "y": 191, "w": TRACK_W, "h": TRACK_H},
        {"char": "speed", "x": 162, "y": 201, "w": TRACK_W, "h": TRACK_H, "readonly": True},
    ],
}
BUTTONS = ["ok", "exit", "switch"]   # G2 frame pairs 0/1, 2/3, 4/5; f06 = plate


def index_map(bin_path):
    return export_fullscreen.index_map(bin_path.read_bytes())


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


def build_palette(game):
    pal = (game / "data" / "EQPCHP.BIN").read_bytes()[:768]
    return [tuple(min(v * 4, 255) for v in pal[i * 3:i * 3 + 3]) for i in range(256)]


def canvas_grid(canvas):
    """Rows of palette indices from the origin to the canvas extent, -1 = empty."""
    w = max(c[0] for c in canvas) + 1
    h = max(c[1] for c in canvas) + 1
    grid = [[-1] * w for _ in range(h)]
    for (x, y), v in canvas.items():
        grid[y][x] = v
    return grid


def save_canvas(canvas, pal, path):
    grid = canvas_grid(canvas)
    img = image.new("RGBA", (len(grid[0]), len(grid)))
    for y, row in enumerate(grid):
        for x, p in enumerate(row):
            if p >= 0:
                img.putpixel((x, y), pal[p])
    img.save(path)


def fit_track(canvas, width):
    """Squeeze the CHARACTERISTICS bar frame into the baked track slot.

    The EQP*G bar is 35 px wide but the slot baked into the backdrop is only
    TRACK_W, so drawing the frame as-is spills its right bevel onto the panel
    frame. The outer column, the right bevel and the shadow are structural and
    are kept; the surplus comes off the widest colour runs of the interior, one
    column at a time, so the red / orange / green zones stay even.
    """
    f = canvas_grid(canvas)
    h, w = len(f), len(f[0])
    if w <= width:
        return canvas
    column = lambda x: [row[x] for row in f]
    runs, keep = [], list(range(w))
    start = 1
    for x in range(2, w - 2):
        if column(x) != column(start):
            runs.append([start, x - 1])
            start = x
    runs.append([start, w - 3])
    for _ in range(w - width):
        widest = max(runs, key=lambda r: r[1] - r[0])
        keep.remove(widest[1])
        widest[1] -= 1
    return {(nx, y): f[y][x] for nx, x in enumerate(keep)
            for y in range(h) if f[y][x] >= 0}


_positions = {}


def positions_by_index(arr):
    """index -> [(x, y)] over an index map, cached per map."""
    key = id(arr)
    if key not in _positions:
        table = {}
        for y, row in enumerate(arr):
            for x, v in enumerate(row):
                table.setdefault(v, []).append((x, y))
        _positions[key] = table
    return _positions[key]


def find_all(frame, arr, tolerance=MATCH_TOLERANCE):
    """All (x, y) where the frame matches the index map within tolerance.

    A hit mismatches at most `tolerance` pixels, so it matches at least one of
    tolerance + 1 anchor pixels exactly: candidates come from those anchors."""
    f = canvas_grid(frame)
    h, w = len(f), len(f[0])
    H, W = len(arr), len(arr[0])
    pixels = [(x, y, v) for y, row in enumerate(f) for x, v in enumerate(row) if v >= 0]
    step = max(1, len(pixels) // (tolerance + 1))
    anchors = pixels[::step][:tolerance + 1]
    table = positions_by_index(arr)
    candidates = set()
    for ax, ay, v in anchors:
        for x, y in table.get(v, ()):
            ox, oy = x - ax, y - ay
            if 0 <= ox <= W - w and 0 <= oy <= H - h:
                candidates.add((ox, oy))
    hits = []
    for ox, oy in candidates:
        errors = 0
        for x, y, v in pixels:
            if arr[oy + y][ox + x] != v:
                errors += 1
                if errors > tolerance:
                    break
        else:
            hits.append((ox, oy))
    return sorted(hits, key=lambda p: (p[1], p[0]))


def find_pips(arr, y, x_from, x_to):
    """The x of the first pip box (border index 24 lit or 69 empty) on row y."""
    for x in range(x_from, x_to):
        col = [arr[y + dy][x] for dy in range(PIP_H)]
        if all(v in (69, 70) for v in col) or all(v in (24, 26) for v in col):
            # require a full triple to reject stray matches
            b2 = arr[y][x + PIP_PITCH:x + PIP_PITCH + PIP_W]
            if all(v in (69, 24) for v in b2):
                return x
    return None


def find_bay1_row(arr):
    """Bay 1's baked CHAIN-GUN row: the wide 247-background run, top-left."""
    points = [(x, y) for y in range(36, 110) for x in range(140) if arr[y][x] == 247]
    if not points:
        return None
    x0, x1 = min(p[0] for p in points), max(p[0] for p in points)
    y0, y1 = min(p[1] for p in points), max(p[1] for p in points)
    return {"x": x0, "y": y0, "w": x1 - x0 + 1, "h": y1 - y0 + 1}


def crop_pips(arr, pal, x, y, out_dir):
    """Crop the lit and empty pip boxes (bay 1 shows one lit + two empty)."""
    for name, px in (("pip_lit", x), ("pip_empty", x + PIP_PITCH)):
        img = image.new("RGBA", (PIP_W, PIP_H))
        for dy in range(PIP_H):
            for dx in range(PIP_W):
                img.putpixel((dx, dy), pal[arr[y + dy][px + dx]])
        img.save(out_dir / f"{name}.png")


def export_screen(vehicle, game, pal, maps, out):
    back_stem, g_stem, g2_stem = SCREENS[vehicle]
    arr     = maps[vehicle]
    rows    = blitter_frames(game / "data" / f"{g_stem}.BIN")
    buttons = blitter_frames(game / "data" / f"{g2_stem}.BIN")
    weapons = WEAPONS[vehicle]
    # The engine draws the correctly-decoded full-screen backdrop
    # (assets/fullscreen/EQP*.png); the widget overlays below sit on top of it, so
    # no separate re-rendered backdrop is emitted here.
    layout  = {"backdrop": f"{back_stem}.png",
               "bays": [], "specials": [], "buttons": {},
               "characteristics": CHARACTERISTICS[vehicle]}

    # Row art: 3 states per weapon.
    for wi, weapon in enumerate(weapons):
        for si, state in enumerate(("normal", "sel", "dark")):
            name = f"{vehicle}_row_{weapon}_{state}.png"
            save_canvas(rows[wi * 3 + si], pal, out / name)

    # Positions: the backdrop bakes each row in an arbitrary state (the tank
    # screen mixes normal and selected), so match all three per weapon.
    row_w = {w: len(canvas_grid(rows[wi * 3])[0]) for wi, w in enumerate(weapons)}
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
    # from the 10 px row pitch. A row the backdrop does not bake gets
    # "baked": false so the engine draws its normal frame too: the tank
    # backdrop has no MINE row (it bakes a stale SHELL label in its place).
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
                        "pips_x": pip_x, "pips_y": y,
                        "baked": weapon in found})
        layout["bays"].append({"rows": bay})
    if spec_anchor:
        sx, sy = spec_anchor
        for i, weapon in enumerate(spec_order):
            layout["specials"].append({"weapon": weapon, "x": sx, "y": sy + 10 * i,
                                       "baked": bool(hits[weapon])})

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


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)
    game = gamedata.find_game_dir(args.game_dir)
    out  = gamedata.ASSETS / "equip"
    out.mkdir(parents=True, exist_ok=True)
    print(f"Game dir: {game}\n -> {out}/")

    maps = {vehicle: index_map(game / "data" / f"{back_stem}.BIN")
            for vehicle, (back_stem, _g, _g2) in SCREENS.items()}
    pal = build_palette(game)

    layout = {}
    for vehicle in SCREENS:
        layout[vehicle] = export_screen(vehicle, game, pal, maps, out)

    # EQPNUMS: gold 5x6 digits 0-9 (unused by the engine yet, kept for later).
    for i, canvas in enumerate(planar_frames(game / "data" / "EQPNUMS.BIN")):
        save_canvas(canvas, pal, out / f"digit_f{i:02d}.png")
    print("  digit_f00..09.png")

    # CHARACTERISTICS slider art: EQPTNKF f3 knob + EQPTNKG f21 colored track.
    knob = planar_frames(game / "data" / "EQPTNKF.BIN")
    if len(knob) > 3 and knob[3]:
        save_canvas(knob[3], pal, out / "slider_knob.png")
        print("  slider_knob.png")
    track = blitter_frames(game / "data" / "EQPTNKG.BIN")
    if len(track) > 21 and track[21]:
        save_canvas(fit_track(track[21], TRACK_W), pal, out / "slider_track.png")
        print("  slider_track.png")

    gamedata.write_text(out / "layout.json", json.dumps(layout, indent=2) + "\n")
    print("  layout.json")


if __name__ == "__main__":
    main()
