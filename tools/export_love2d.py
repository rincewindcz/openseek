#!/usr/bin/env python3
"""
Export Seek and Destroy stages for the Love2D renderer in love2d/.

Stage files are data/STAGE{M}{P}.BIN where M = mission 0-4, P = phase 0-3
(loader format string "data\\stage%d%d.bin"). Mission M uses the assets and
palette of the STAGE0{M}/ directory.

Rotation-arc frames are pre-rotated copies offset by one step: frame k is
the true pose rotated clockwise by (k+1) * 360/angle_steps degrees, so
frame_base (the spawn pose) is one step off axis and carries rotation
deformities like every non-90-degree copy. The only lossless copy is the
arc's exact 90 degree frame, frame_base + (steps/4 - 1) << stride (f15 for
steps=64, f7 for steps=32). That frame is exported here and the viewer
rotates it back by -90 degrees at draw time (see LEVELS.md / SPRITES.md).
Classes with angle_steps == 1 export frame_base as-is.

Each exported frame is decoded with the exact blitter decoder into
love2d/assets/stage{M}{P}/<name>_f<N>.png, and the stage JSON gets a
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
LOVE_ASSETS = ROOT / "love2d" / "assets"


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
    out_json = LOVE_ASSETS / f"{tag}.json"
    sprite_dir = LOVE_ASSETS / tag
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
    ok, failed = 0, []
    rendered = {}  # (asset, frame) -> render info
    for ci in used_classes:
        cls = level["classes"][ci]
        asset = level["assets"][cls["asset"]]
        steps = cls["angle_steps"]
        pose = max(0, steps // 4 - 1) if steps > 1 else 0
        frame = max(0, cls["frame_base"]) + (pose << max(0, cls["frame_stride"]))
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
