#!/usr/bin/env python3
"""
Decoder for Seek and Destroy stage asset lists.

These files (data/STAGE00.BIN – STAGE04.BIN) contain a binary list of
asset references: each entry is a short game-side filename (.bin) paired
with the full developer-side source path (.iff on an AmigaOS workstation).

The exact binary structure around the strings is not fully decoded, but
null-terminated string pairs can be reliably extracted with a scan approach.

Usage:
  decode_stage_assets.py STAGE00.BIN
  decode_stage_assets.py STAGE00.BIN --raw      # hexdump around each string pair
  decode_stage_assets.py STAGE00.BIN --csv      # output as CSV
"""

import argparse
import sys
from pathlib import Path


def scan_string_pairs(data: bytes) -> list[tuple[int, bytes, bytes]]:
    """
    Scan for pairs of null-terminated strings where the first ends in .bin
    and the second ends in .iff (developer source path).
    Returns list of (offset, bin_name, iff_path).
    """
    results = []
    i = 0
    while i < len(data) - 2:
        # Find a null-terminated string ending in .bin
        end = data.find(b"\x00", i)
        if end == -1:
            break
        candidate = data[i:end]
        if (candidate.lower().endswith(b".bin") and
                len(candidate) >= 5 and
                all(0x20 <= b < 0x7F for b in candidate)):
            # Look for the .iff source path nearby
            # There may be a few bytes between them (uint16 index, etc.)
            search_start = end + 1
            search_end   = min(search_start + 8, len(data))
            for j in range(search_start, search_end):
                iff_end = data.find(b"\x00", j)
                if iff_end == -1:
                    break
                iff_cand = data[j:iff_end]
                if (iff_cand.lower().endswith(b".iff") and
                        len(iff_cand) >= 8 and
                        all(0x20 <= b < 0x7F for b in iff_cand)):
                    results.append((i, candidate, iff_cand))
                    i = iff_end + 1
                    break
            else:
                i = end + 1
        else:
            i += 1
    return results


def main():
    ap = argparse.ArgumentParser(description="Extract asset list from Seek & Destroy stage file")
    ap.add_argument("input", help="Stage asset file (e.g. data/STAGE00.BIN)")
    ap.add_argument("--raw", action="store_true",
                    help="Show hex context around each string pair")
    ap.add_argument("--csv", action="store_true",
                    help="Output as CSV: offset, bin_name, iff_path")
    ap.add_argument("--context", type=int, default=8, metavar="N",
                    help="Bytes of hex context to show with --raw (default: 8)")
    args = ap.parse_args()

    src = Path(args.input)
    if not src.exists():
        print(f"ERROR: Not found: {src}", file=sys.stderr)
        sys.exit(1)

    data = src.read_bytes()
    pairs = scan_string_pairs(data)

    print(f"File: {src}  ({len(data)} bytes)  →  {len(pairs)} asset pairs found")

    if args.csv:
        print("offset,bin_name,iff_path")
        for off, name, path in pairs:
            print(f"{off},{name.decode()},{path.decode()}")
        return

    for off, name, path in pairs:
        if args.raw:
            ctx_start = max(0, off - args.context)
            ctx_end   = min(len(data), off + len(name) + len(path) + args.context + 8)
            hex_ctx   = data[ctx_start:ctx_end].hex()
            # Insert spaces every 2 chars for readability
            hex_ctx   = " ".join(hex_ctx[i:i+2] for i in range(0, len(hex_ctx), 2))
            print(f"\n  offset 0x{off:04x}:")
            print(f"  hex: {hex_ctx}")
        print(f"  {name.decode():<30}  ←  {path.decode()}")


if __name__ == "__main__":
    main()
