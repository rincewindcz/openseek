#!/usr/bin/env python3
"""
Seek and Destroy - fullscreen image decoder v2
===============================================

Handles the palette problem documented in ARTICLE_2.md:

  The 768-byte block embedded in each .BIN image does NOT decode correctly as a
  standard 6-bit VGA palette.  GOVPAL.BIN is also not the answer (valid colours
  only for entries 0-79; entries 80-255 are placeholder sentinels).

Two operating modes:

  1. --dosbox-ref SCREENSHOT.PNG  (recommended)
       Extracts the actual VGA palette from a DOSBox screenshot of the same image.
       For each palette index, samples all corresponding pixels in the reference
       and takes the median colour.  Produces visually accurate output.

  2. No reference  (fallback)
       Uses the embedded block × 4, which gives correct geometry with green-shifted
       colours.  Useful for structure inspection when no reference is available.

Usage
-----
  # Accurate decode (recommended - provide a DOSBox screenshot)
  ./decode_fullscreen_v2.py data/TITLE.BIN --dosbox-ref tools/TITLE_BIN.png -o title.png

  # Fallback decode (embedded palette, wrong colours)
  ./decode_fullscreen_v2.py data/TITLE.BIN -o title_approx.png

  # Dump the extracted palette as a swatch PNG
  ./decode_fullscreen_v2.py data/TITLE.BIN --dosbox-ref ref.png --palette-out pal.png

  # Save the extracted palette as a raw 768-byte file
  ./decode_fullscreen_v2.py data/TITLE.BIN --dosbox-ref ref.png --palette-save pal.bin
"""

import argparse
import sys
from pathlib import Path
from collections import defaultdict

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("ERROR: pip install pillow numpy", file=sys.stderr)
    sys.exit(1)

HEADER_SIZE  = 14
PALETTE_SIZE = 768
PIXEL_SIZE   = 76800
WIDTH, HEIGHT = 320, 240


# ---------------------------------------------------------------------------
# Mode X planar → chunky
# ---------------------------------------------------------------------------

def decode_modex(pixel_bytes: bytes) -> np.ndarray:
    arr = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
    stride = WIDTH // 4  # 80 bytes per plane-row
    for plane in range(4):
        pdata = pixel_bytes[plane * HEIGHT * stride : (plane + 1) * HEIGHT * stride]
        for y in range(HEIGHT):
            arr[y, plane::4] = np.frombuffer(pdata[y * stride : (y + 1) * stride],
                                             dtype=np.uint8)
    return arr


# ---------------------------------------------------------------------------
# Palette extraction from DOSBox reference screenshot
# ---------------------------------------------------------------------------

def extract_palette_from_ref(arr: np.ndarray, ref_path: Path) -> np.ndarray:
    """
    Reverse-engineer the VGA palette from a DOSBox screenshot.

    For each palette index N, collect all pixels in the (scaled) reference image
    at positions where index N appears in the decoded pixel map.  Take the median
    as the palette colour.  This suppresses scaling artefacts and boundary noise.

    Returns a (256, 3) uint8 array of 8-bit RGB values.
    """
    ref = np.array(Image.open(ref_path).convert("RGB"), dtype=np.float32)
    sx = ref.shape[1] / WIDTH
    sy = ref.shape[0] / HEIGHT

    index_samples: dict[int, list] = defaultdict(list)
    for y in range(HEIGHT):
        for x in range(WIDTH):
            idx = int(arr[y, x])
            ry = min(int(y * sy), ref.shape[0] - 1)
            rx = min(int(x * sx), ref.shape[1] - 1)
            index_samples[idx].append(ref[ry, rx, :3])

    palette = np.zeros((256, 3), dtype=np.uint8)
    for idx, samples in index_samples.items():
        median = np.median(np.array(samples, dtype=np.float32), axis=0)
        palette[idx] = np.clip(np.round(median), 0, 255).astype(np.uint8)

    used = len(index_samples)
    print(f"Extracted palette from reference: {used}/256 entries sampled")
    return palette


# ---------------------------------------------------------------------------
# Embedded palette fallback (known to be wrong in colour, right in structure)
# ---------------------------------------------------------------------------

def embedded_palette(raw: bytes) -> np.ndarray:
    """
    Decode the embedded 768-byte block as 6-bit VGA × 4.

    NOTE: This does NOT produce correct colours.  The encoding of this block is
    unresolved as of the current investigation (see ARTICLE_2.md).  The output
    has correct geometry and plausible luminance but is green-shifted.
    """
    arr = np.frombuffer(raw[:PALETTE_SIZE], dtype=np.uint8).reshape(256, 3)
    return np.clip(arr.astype(np.int32) * 4, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# Palette swatch output
# ---------------------------------------------------------------------------

def save_palette_swatch(palette: np.ndarray, path: Path, swatch: int = 24) -> None:
    img = Image.new("RGB", (16 * swatch, 16 * swatch))
    px = img.load()
    for i in range(256):
        row, col = divmod(i, 16)
        r, g, b = int(palette[i, 0]), int(palette[i, 1]), int(palette[i, 2])
        for dy in range(swatch):
            for dx in range(swatch):
                px[col * swatch + dx, row * swatch + dy] = (r, g, b)
    img.save(path)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Decode a Seek & Destroy fullscreen image (.BIN)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("input", help="Path to .BIN file (e.g. data/TITLE.BIN)")
    ap.add_argument("-o", "--output", help="Output PNG path (default: input stem + .png)")

    g = ap.add_argument_group("palette")
    g.add_argument(
        "--dosbox-ref",
        metavar="REF.PNG",
        help="DOSBox screenshot of this image for accurate palette extraction (recommended)",
    )
    g.add_argument(
        "--palette-out",
        metavar="SWATCH.PNG",
        help="Save the resolved palette as a 16×16 swatch PNG",
    )
    g.add_argument(
        "--palette-save",
        metavar="PAL.BIN",
        help="Save the resolved palette as a raw 768-byte file (6-bit values, × 4 / 4)",
    )

    ap.add_argument("--scale", type=int, default=1, metavar="N",
                    help="Integer upscale factor for output image (default 1)")
    ap.add_argument("--raw", action="store_true",
                    help="Skip Mode X deinterleaving (treat pixels as chunky)")
    args = ap.parse_args()

    # ---- load ---------------------------------------------------------------
    src = Path(args.input)
    if not src.exists():
        print(f"ERROR: {src} not found", file=sys.stderr)
        sys.exit(1)

    data = src.read_bytes()
    expected = HEADER_SIZE + PALETTE_SIZE + PIXEL_SIZE
    if len(data) != expected:
        print(f"WARNING: expected {expected} bytes, got {len(data)}", file=sys.stderr)

    pixel_bytes = data[HEADER_SIZE + PALETTE_SIZE : HEADER_SIZE + PALETTE_SIZE + PIXEL_SIZE]

    # ---- decode pixels ------------------------------------------------------
    if args.raw:
        arr = np.frombuffer(pixel_bytes, dtype=np.uint8).reshape(HEIGHT, WIDTH)
        print("Pixel mode: raw (no Mode X deinterleaving)")
    else:
        arr = decode_modex(pixel_bytes)
        print("Pixel mode: Mode X planar")

    # ---- resolve palette ----------------------------------------------------
    if args.dosbox_ref:
        ref_path = Path(args.dosbox_ref)
        if not ref_path.exists():
            print(f"ERROR: reference image {ref_path} not found", file=sys.stderr)
            sys.exit(1)
        palette = extract_palette_from_ref(arr, ref_path)
        palette_source = f"DOSBox reference: {ref_path.name}"
    else:
        palette = embedded_palette(data[HEADER_SIZE:])
        palette_source = "embedded block × 4 (APPROXIMATE - colours will be wrong)"

    print(f"Palette source: {palette_source}")

    # ---- optional palette outputs -------------------------------------------
    if args.palette_out:
        out = Path(args.palette_out)
        save_palette_swatch(palette, out)
        print(f"Palette swatch saved: {out}")

    if args.palette_save:
        # Save as raw 768-byte file: values divided back to 6-bit range
        raw_pal = (palette.astype(np.float32) / 4.0).clip(0, 63).round().astype(np.uint8)
        Path(args.palette_save).write_bytes(raw_pal.tobytes())
        print(f"Raw palette saved: {args.palette_save}")

    # ---- render -------------------------------------------------------------
    rgb = palette[arr]
    img = Image.fromarray(rgb.reshape(HEIGHT, WIDTH, 3))

    if args.scale > 1:
        img = img.resize((WIDTH * args.scale, HEIGHT * args.scale), Image.NEAREST)

    out = Path(args.output) if args.output else src.with_suffix(".png")
    img.save(out)
    print(f"Saved: {out}  ({img.width}×{img.height})")


if __name__ == "__main__":
    main()
