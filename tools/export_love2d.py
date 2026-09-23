#!/usr/bin/env python3
"""
Export Seek and Destroy stages for the Love2D renderer (assets/).

Stage files are data/STAGE{M}{P}.BIN where M = mission 0-4, P = phase 0-3
(loader format string "data\\stage%d%d.bin"). Mission M uses the assets and
palette of the STAGE0{M}/ directory.

Rotation-arc frames are pre-rotated copies, one rotation step apart, with
frame 0 the exact axis-aligned pose (it lives at offset H; the +4 table
holds frames 1..n, so a container has n+1 frames). An
entity carries no angle, so its canonical pose is simply the class's
frame_base, drawn as-is with no rotation. Orientation variants of one asset
(road pieces, rocks) are separate classes pointing at different frame_base
values, so frame_base alone selects the right pose for every class.

Each exported frame is decoded with the exact blitter decoder into
assets/stage{M}{P}/<name>_f<N>.png, and the stage JSON gets a
per-class "render" entry: image name plus the top-left draw offset from
the entity position (ox, oy), derived from the engine's center anchors in
the frame header (hdr+6, hdr+8) and the decoded pixel bounding box.

Each segment additionally gets a "color" entry [r, g, b]: the value field
is the palette index the engine passes to its line drawer (0x1df450),
resolved here via the mission's PAL1.BIN with the 6-to-8-bit DAC
conversion.

Usage:
  export_love2d.py 00            # mission 0, phase 0
  export_love2d.py 00 01 02 03
  export_love2d.py all           # every stage of the missions present
  export_love2d.py all --game-dir /path/to/seek
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import decode_blitter as db
import decode_level
import gamedata

# Palette indices exported transparent per sprite file. The sand dune draws
# its crest in index 0 (black), which reads as a hole over the desert floor.
# Other sprites keep index 0: CMDRHUT's roof shading and the jeep's wheels use it.
CLEAR_INDICES = {
    "sanddune.bin": {0},
}


# Kinds that draw a unit sprite (soldiers) carry a dead pose a fixed frame offset
# past their alive frame in the same arc-pair BIN (ENEMY.BIN: alive arc 0-31,
# dead arc 32-63). Exported as a sibling {stem}_f{frame+offset}.png that the
# engine derives by name; no extra JSON field needed.
def _dead_frame_offsets():
    types = json.loads(gamedata.read_resource("data/entity_types.json"))
    return {k: v["dead_frame_offset"] for k, v in types.items()
            if isinstance(v, dict) and "dead_frame_offset" in v}


def find_bin(game_dir: Path, name: str, source_dir: int, mission: int) -> Path | None:
    candidates = []
    if source_dir >= 0:
        candidates.append(game_dir / f"STAGE{source_dir:02d}" / name.upper())
    candidates.append(game_dir / f"STAGE{mission:02d}" / name.upper())
    candidates.append(game_dir / "data" / name.upper())
    candidates += [game_dir / f"STAGE{i:02d}" / name.upper() for i in range(5)]
    for c in candidates:
        if c.exists():
            return c
    return None


def render_class_frame(bin_path: Path, frame: int, palette: bytes, clear=()):
    """Decode one frame; returns (image, ox, oy) or (None, why, None).
    (ox, oy) is the PNG top-left offset from the entity position."""
    data = bin_path.read_bytes()
    frames = db.read_frames(data)
    if frame >= len(frames):
        frame = 0
    off, end = frames[frame]
    _, _, ex = db.frame_header(data, off)
    canvas, status = db.decode_frame(data, off, end)
    if status != "ok" or not canvas:
        return None, status or "empty", None
    canvas = {xy: i for xy, i in canvas.items() if i not in clear}
    if not canvas:
        return None, "empty", None
    img = db.render(canvas, palette, scale=1)
    min_x = min(c[0] for c in canvas)
    min_y = min(c[1] for c in canvas)
    # engine draws at entity_pos - (hdr+6, hdr+8) = minus the sprite center
    return img, min_x - ex[1], min_y - ex[2]


def export_stage(game_dir: Path, mission: int, phase: int) -> None:
    tag = f"stage{mission}{phase}"
    stage_bin = game_dir / "data" / f"STAGE{mission}{phase}.BIN"
    out_json = gamedata.ASSETS / f"{tag}.json"
    sprite_dir = gamedata.ASSETS / tag
    sprite_dir.mkdir(parents=True, exist_ok=True)

    level = decode_level.parse_stage(stage_bin.read_bytes())

    pal_path = game_dir / f"STAGE{mission:02d}" / "PAL.BIN"
    if not pal_path.exists():
        pal_path = game_dir / f"STAGE{mission:02d}" / "PAL1.BIN"
    palette = pal_path.read_bytes()

    # segment value = palette color index of the line (passed to the line
    # drawer at 0x1df450); resolve via the mission's in-game palette PAL1.BIN
    pal1_path = game_dir / f"STAGE{mission:02d}" / "PAL1.BIN"
    pal1 = pal1_path.read_bytes() if pal1_path.exists() else palette
    for seg in level["segments"]:
        i = seg["value"] * 3
        seg["color"] = [(c << 2) | (c >> 4) for c in pal1[i:i + 3]]

    used_classes = sorted({e["class"] for e in level["entities"]})
    dead_offsets = _dead_frame_offsets()
    ok, failed = 0, []
    rendered = {}  # (asset, frame) -> render info
    for ci in used_classes:
        cls = level["classes"][ci]
        asset = level["assets"][cls["asset"]]
        frame = max(0, cls["frame_base"])
        key = (cls["asset"], frame)
        if key not in rendered:
            src = find_bin(game_dir, asset["file"], asset["source_dir"], mission)
            if src is None:
                failed.append((asset["file"], "file not found"))
                rendered[key] = None
            else:
                clear = CLEAR_INDICES.get(asset["file"].lower(), ())
                img, ox, oy = render_class_frame(src, frame, palette, clear)
                if img is None:
                    failed.append((f"{asset['file']} f{frame}", ox))
                    rendered[key] = None
                else:
                    stem = asset["file"].rsplit(".", 1)[0]
                    name = f"{stem}_f{frame}.png"
                    img.save(sprite_dir / name)
                    rendered[key] = {"image": name, "ox": ox, "oy": oy}
                    ok += 1
        if rendered[key]:
            cls["render"] = rendered[key]
            # Unit kinds also export their dead pose (same arc-pair BIN, frame
            # offset away). The engine derives the filename, so no JSON field.
            off = dead_offsets.get(cls.get("kind_name"))
            if off:
                dframe = frame + off
                dkey = (cls["asset"], dframe)
                if dkey not in rendered:
                    src = find_bin(game_dir, asset["file"], asset["source_dir"], mission)
                    # Only export a real dead frame; skip assets whose arc is too
                    # short (e.g. mine.bin filed as a unit kind has no dead pose).
                    n = len(db.read_frames(src.read_bytes())) if src else 0
                    dimg = render_class_frame(src, dframe, palette)[0] if dframe < n else None
                    if dimg is not None:
                        stem = asset["file"].rsplit(".", 1)[0]
                        dimg.save(sprite_dir / f"{stem}_f{dframe}.png")
                    rendered[dkey] = bool(dimg)

    out_json.write_text(json.dumps(level, indent=2))
    print(f"{tag}: {ok} class frames, {len(level['entities'])} entities "
          f"-> {out_json}")
    for name, why in failed:
        print(f"  MISSING {name}: {why} (renderer draws a placeholder)")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Export stages to assets/stageMP.json and assets/stageMP/")
    ap.add_argument("stages", nargs="*", default=["00"],
                    help="MP tags (12 = mission 1 phase 2) or 'all' (every mission present)")
    ap.add_argument("--game-dir", default=None)
    args = ap.parse_args(argv)

    game_dir = gamedata.find_game_dir(args.game_dir)
    tags = args.stages
    if tags == ["all"]:
        tags = [f"{m}{p}" for m in gamedata.missions(game_dir) for p in range(4)]
    for a in tags:
        if len(a) != 2 or not a.isdigit():
            sys.exit(f"bad stage tag {a!r}: expected MP digits, e.g. 12 = mission 1 phase 2")
        export_stage(game_dir, int(a[0]), int(a[1]))


if __name__ == "__main__":
    main()
