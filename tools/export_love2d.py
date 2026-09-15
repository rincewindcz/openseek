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
  export_love2d.py all           # all 20 stages
"""

import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import decode_blitter as db

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "assets"

# Kinds that draw a unit sprite (soldiers) carry a dead pose a fixed frame offset
# past their alive frame in the same arc-pair BIN (ENEMY.BIN: alive arc 0-31,
# dead arc 32-63). Exported as a sibling {stem}_f{frame+offset}.png that the
# engine derives by name; no extra JSON field needed.
def _dead_frame_offsets():
    import json as _json
    types = _json.loads((ROOT / "data" / "entity_types.json").read_text())
    return {k: v["dead_frame_offset"] for k, v in types.items()
            if isinstance(v, dict) and "dead_frame_offset" in v}


def find_bin(name: str, source_dir: int, mission: int) -> Path | None:
    candidates = []
    if source_dir >= 0:
        candidates.append(ROOT / f"STAGE{source_dir:02d}" / name.upper())
    candidates.append(ROOT / f"STAGE{mission:02d}" / name.upper())
    candidates.append(ROOT / "data" / name.upper())
    candidates += [ROOT / f"STAGE{i:02d}" / name.upper() for i in range(5)]
    for c in candidates:
        if c.exists():
            return c
    return None


def render_class_frame(bin_path: Path, frame: int, palette: bytes):
    """Decode one frame; returns (PIL image, ox, oy) or (None, why, None).
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
    img = db.render(canvas, palette, scale=1)
    min_x = min(c[0] for c in canvas)
    min_y = min(c[1] for c in canvas)
    # engine draws at entity_pos - (hdr+6, hdr+8) = minus the sprite center
    return img, min_x - ex[1], min_y - ex[2]


def export_stage(mission: int, phase: int) -> None:
    tag = f"stage{mission}{phase}"
    stage_bin = ROOT / "data" / f"STAGE{mission}{phase}.BIN"
    out_json = ASSETS / f"{tag}.json"
    sprite_dir = ASSETS / tag
    sprite_dir.mkdir(parents=True, exist_ok=True)

    import decode_level
    level = decode_level.parse_stage(stage_bin.read_bytes())

    pal_path = ROOT / f"STAGE{mission:02d}" / "PAL.BIN"
    if not pal_path.exists():
        pal_path = ROOT / f"STAGE{mission:02d}" / "PAL1.BIN"
    palette = pal_path.read_bytes()

    # segment value = palette color index of the line (passed to the line
    # drawer at 0x1df450); resolve via the mission's in-game palette PAL1.BIN
    pal1_path = ROOT / f"STAGE{mission:02d}" / "PAL1.BIN"
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
            src = find_bin(asset["file"], asset["source_dir"], mission)
            if src is None:
                failed.append((asset["file"], "file not found"))
                rendered[key] = None
            else:
                img, ox, oy = render_class_frame(src, frame, palette)
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
                    src = find_bin(asset["file"], asset["source_dir"], mission)
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
          f"-> {out_json.relative_to(ROOT)}")
    for name, why in failed:
        print(f"  MISSING {name}: {why} (renderer draws a placeholder)")


if __name__ == "__main__":
    args = sys.argv[1:] or ["00"]
    if args == ["all"]:
        args = [f"{m}{p}" for m in range(5) for p in range(4)]
    for a in args:
        if len(a) != 2 or not a.isdigit():
            sys.exit(f"bad stage tag {a!r}: expected MP digits, e.g. 12 = mission 1 phase 2")
        export_stage(int(a[0]), int(a[1]))
