#!/usr/bin/env python3
"""
Level decoder for Seek and Destroy (SAFARI Software).

Parses data/STAGE0X.BIN into JSON. The format was recovered from the stage
loader at 0x1f5860 in SEEK.EXE (see LEVELS.md for the full specification).
All four retail stage files parse to the exact byte boundary.

There is no tilemap: a stage is a flat-colored 4096x4096 px world populated
by entity instances (scenery and actives are both sprite objects).

Usage:
  decode_level.py data/STAGE00.BIN                 # JSON to stdout
  decode_level.py data/STAGE00.BIN --out s0.json
  decode_level.py data/STAGE00.BIN --summary
"""

import argparse
import json
import struct
import sys
from pathlib import Path

WORLD_SIZE = 4096  # world coords are masked to 0..4095 px at runtime

# Known class kind values, from the per-kind init switch at 0x1f5f49
# (jump table 0x1f5818) and the class table contents of STAGE00.
KIND_NAMES = {
    0: "scenery",
    1: "structure",
    2: "tree",
    3: "enemy_helicopter",
    4: "effect_or_projectile",
    5: "flak_turret",
    6: "tank",
    7: "soldier_aggressive",
    8: "soldier",
    9: "powerup_marker",
    10: "truck",
    11: "civilian",
    12: "scenery",
    15: "ground_decal",
    16: "radar",
}


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.off = 0

    def u16(self) -> int:
        v = struct.unpack_from("<H", self.data, self.off)[0]
        self.off += 2
        return v

    def i16(self) -> int:
        v = struct.unpack_from("<h", self.data, self.off)[0]
        self.off += 2
        return v

    def bytes(self, n: int) -> bytes:
        v = self.data[self.off:self.off + n]
        self.off += n
        return v

    def cstr(self, n: int) -> str:
        return self.bytes(n).rstrip(b"\0").decode("ascii", errors="replace")


def parse_class(rec: bytes, index: int) -> dict:
    f = struct.unpack_from("<16h", rec)
    # Sprite frame composition (frame select code at 0x1ffd90):
    #   rot = ((entity_angle + camera_angle) >> (frame_shift+2)) & (angle_steps-1)
    #   if rot >= angle_steps/2: draw mirrored with rot -= angle_steps/2
    #   file_frame = frame_base + anim_frame + (rot << frame_stride)
    # Entity angle is 0 at spawn, so the canonical pose is file frame
    # `frame_base` (orientation variants of one asset are separate classes
    # with different frame_base, e.g. the metalrt road pieces).
    cls = {
        "index": index,
        "asset": f[2],            # +0x04 index into the asset list
        "frame_base": f[3],       # +0x06 base frame in the sprite BIN
        "frame_stride": f[4],     # +0x08 rot index shift (frames per pose)
        "angle_steps": f[5],      # +0x0a rotation steps (32/64; 1 = static)
        "flags": f[7],            # +0x0e copied to entity +0x52
        "hit_points": f[8],       # +0x10
        "kind": f[11],            # +0x16 entity behaviour class (init switch)
        "frame_shift": struct.unpack_from("<h", rec, 0x1c)[0],  # angle >> shift
        "parent_class": struct.unpack_from("<h", rec, 0x30)[0], # entity linking
        "raw": rec.hex(),
    }
    cls["kind_name"] = KIND_NAMES.get(cls["kind"], f"unknown_{cls['kind']}")
    return cls


def parse_route(rec: bytes) -> dict:
    # 202 bytes: 50 x i16 x-coords, 50 x i16 y-coords, 1 trailing u16.
    # A route shorter than 50 points is terminated by x == -1.
    xs = struct.unpack_from("<50h", rec, 0)
    ys = struct.unpack_from("<50h", rec, 100)
    trailer = struct.unpack_from("<H", rec, 200)[0]
    points = []
    for x, y in zip(xs, ys):
        if x == -1:
            break
        points.append({"x": x, "y": y})
    return {"points": points, "trailer": trailer}


def parse_stage(data: bytes) -> dict:
    r = Reader(data)
    header = [r.u16(), r.u16()]

    assets = []
    for i in range(r.u16()):
        src_dir = r.i16()  # stage dir number; -2 = loaded elsewhere (shared)
        name = r.cstr(r.u16())
        source_path = r.cstr(r.u16())
        assets.append({
            "index": i,
            "file": name,
            "source_dir": src_dir,
            "dev_path": source_path,
        })

    name = r.cstr(r.u16())
    unknown_word = r.u16()
    globals_ = [r.u16() for _ in range(6)]

    n_classes = r.u16()
    class_len = r.u16()
    classes = [parse_class(r.bytes(class_len), i) for i in range(n_classes)]

    route_len = r.u16()
    routes = [parse_route(r.bytes(route_len)) for _ in range(10)]

    entities = []
    for _ in range(r.u16()):
        cls, x, y, route = struct.unpack_from("<hiih", r.data, r.off)
        r.off += 12
        ent = {"class": cls, "x": x, "y": y}
        if route != -1:
            ent["route"] = route
        entities.append(ent)

    segments = []
    for _ in range(r.u16()):
        x1, y1, x2, y2, val = struct.unpack_from("<5h", r.data, r.off)
        r.off += 10
        segments.append({"x1": x1, "y1": y1, "x2": x2, "y2": y2, "value": val})

    leftover = len(data) - r.off
    if leftover:
        print(f"WARNING: {leftover} unparsed bytes at end of file", file=sys.stderr)

    return {
        "world_size": WORLD_SIZE,
        "header": header,
        "name": name,
        "unknown_word": unknown_word,
        "globals": globals_,
        "assets": assets,
        "classes": classes,
        "routes": routes,
        "entities": entities,
        "segments": segments,
    }


def summarize(stage: dict) -> str:
    from collections import Counter
    counts = Counter(e["class"] for e in stage["entities"])
    lines = [
        f"world: {stage['world_size']}x{stage['world_size']} px, "
        f"{len(stage['assets'])} assets, {len(stage['classes'])} classes, "
        f"{len(stage['entities'])} entities, {len(stage['segments'])} segments",
        "entity classes by count:",
    ]
    for cls, n in counts.most_common():
        c = stage["classes"][cls]
        asset = stage["assets"][c["asset"]]["file"]
        lines.append(f"  class {cls:3d} x{n:5d}  {asset:<14} kind={c['kind_name']}")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="Decode Seek & Destroy stage file to JSON")
    ap.add_argument("input", help="stage file (data/STAGE0X.BIN)")
    ap.add_argument("--out", help="write JSON to this file instead of stdout")
    ap.add_argument("--summary", action="store_true", help="print a summary instead of JSON")
    args = ap.parse_args()

    data = Path(args.input).read_bytes()
    stage = parse_stage(data)

    if args.summary:
        print(summarize(stage))
        return

    text = json.dumps(stage, indent=2)
    if args.out:
        Path(args.out).write_text(text)
        print(f"wrote {args.out} ({len(stage['entities'])} entities)", file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    main()
