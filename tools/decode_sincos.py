#!/usr/bin/env python3
"""
Decoder for Seek and Destroy trigonometric lookup tables.

FORMAT (confirmed):
  2048 bytes (SINCOS.BIN)  = 256 entries × 8 bytes
  8192 bytes (SINCOS4.BIN) = 1024 entries × 8 bytes

  Each entry: int32 LE sin_value, int32 LE cos_value
  Scale: 512 = 1.0  (fixed-point, multiply by 1/512 to get float)
  Angular coverage: full 360°

Usage:
  decode_sincos.py SINCOS.BIN
  decode_sincos.py SINCOS4.BIN --csv
  decode_sincos.py SINCOS.BIN --plot      # requires matplotlib
  decode_sincos.py SINCOS.BIN --check     # verify values against math.sin/cos
"""

import argparse
import math
import struct
import sys
from pathlib import Path

ENTRY_SIZE = 8    # 2 × int32
SCALE = 512.0


def parse_table(data: bytes) -> list[tuple[int, int]]:
    n = len(data) // ENTRY_SIZE
    return [struct.unpack_from("<ii", data, i * ENTRY_SIZE) for i in range(n)]


def main():
    ap = argparse.ArgumentParser(description="Decode Seek & Destroy sin/cos lookup table")
    ap.add_argument("input", help="SINCOS.BIN or SINCOS4.BIN")
    ap.add_argument("--csv", action="store_true",
                    help="Print as CSV: index, angle_deg, sin_raw, cos_raw, sin_f, cos_f")
    ap.add_argument("--check", action="store_true",
                    help="Verify table against math.sin/cos and report max error")
    ap.add_argument("--plot", action="store_true",
                    help="Plot sin and cos curves (requires matplotlib)")
    ap.add_argument("--scale", type=float, default=SCALE,
                    help=f"Fixed-point scale factor (default: {SCALE})")
    args = ap.parse_args()

    src = Path(args.input)
    if not src.exists():
        print(f"ERROR: Not found: {src}", file=sys.stderr)
        sys.exit(1)

    data = src.read_bytes()
    entries = parse_table(data)
    n = len(entries)
    scale = args.scale
    angle_step = 360.0 / n

    print(f"File:    {src}  ({len(data)} bytes)")
    print(f"Entries: {n}")
    print(f"Scale:   {scale}  (1.0 = {scale})")
    print(f"Step:    {angle_step:.4f}° per entry")

    if args.csv:
        print("index,angle_deg,sin_raw,cos_raw,sin_float,cos_float")
        for i, (sv, cv) in enumerate(entries):
            angle = i * angle_step
            print(f"{i},{angle:.4f},{sv},{cv},{sv/scale:.6f},{cv/scale:.6f}")
        return

    if args.check:
        max_sin_err = 0.0
        max_cos_err = 0.0
        for i, (sv, cv) in enumerate(entries):
            angle_rad = math.radians(i * angle_step)
            sin_expected = math.sin(angle_rad)
            cos_expected = math.cos(angle_rad)
            sin_got = sv / scale
            cos_got = cv / scale
            max_sin_err = max(max_sin_err, abs(sin_got - sin_expected))
            max_cos_err = max(max_cos_err, abs(cos_got - cos_expected))
        print(f"Max sin error: {max_sin_err:.6f}")
        print(f"Max cos error: {max_cos_err:.6f}")
        print(f"(Expected ~{1/scale:.6f} = 1/{scale:.0f} due to integer rounding)")
        return

    if args.plot:
        try:
            import matplotlib.pyplot as plt
        except ImportError:
            print("ERROR: matplotlib not installed. pip install matplotlib", file=sys.stderr)
            sys.exit(1)
        angles = [i * angle_step for i in range(n)]
        sins   = [sv / scale for sv, _ in entries]
        coss   = [cv / scale for _, cv in entries]
        plt.figure(figsize=(12, 4))
        plt.plot(angles, sins, label="sin")
        plt.plot(angles, coss, label="cos")
        plt.axhline(0, color="black", linewidth=0.5)
        plt.xlabel("Angle (degrees)")
        plt.ylabel("Value")
        plt.title(f"{src.name} - {n} entries, scale={scale}")
        plt.legend()
        plt.tight_layout()
        out = src.with_suffix(".png")
        plt.savefig(out)
        print(f"Saved plot: {out}")
        plt.show()
        return

    # Default: print a short summary
    print("\nFirst 8 entries:")
    print(f"{'idx':>5}  {'angle':>8}  {'sin_raw':>8}  {'cos_raw':>8}  {'sin_f':>8}  {'cos_f':>8}")
    for i in range(min(8, n)):
        sv, cv = entries[i]
        angle = i * angle_step
        print(f"{i:5d}  {angle:8.3f}°  {sv:8d}  {cv:8d}  {sv/scale:8.4f}  {cv/scale:8.4f}")


if __name__ == "__main__":
    main()
