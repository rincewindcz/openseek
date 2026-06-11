#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path
import math

try:
    from PIL import Image
    import numpy as np
except ImportError:
    print("ERROR: Pillow and numpy are required. Install with: pip install pillow numpy", file=sys.stderr)
    sys.exit(1)

HEADER_SIZE  = 14
PALETTE_SIZE = 768
PIXEL_SIZE   = 76800
WIDTH  = 320
HEIGHT = 240

CHANNEL_ORDERS = {
    "rgb": (0, 1, 2),
    "rbg": (0, 2, 1),
    "grb": (1, 0, 2),
    "gbr": (1, 2, 0),
    "brg": (2, 0, 1),
    "bgr": (2, 1, 0),
}


def scale_value(v, mode, gamma=2.2, inv_gamma=False):
    if mode == "none":
        out = v
    elif mode == "vga":
        out = min(v * 4, 255)
    elif mode == "vga_accurate":
        out = (v << 2) | (v >> 4)
    elif mode == "full":
        out = int(v * 255 / 63)
    elif mode == "gamma":
        f = v / 63.0
        if inv_gamma:
            f = pow(f, gamma)
        else:
            f = pow(f, 1 / gamma)
        out = int(f * 255)
    elif mode == "auto_gamma":
        # detect range automatically
        if v > 63:
            f = v / 255.0
        else:
            f = v / 63.0

        if inv_gamma:
            f = pow(f, gamma)
        else:
            f = pow(f, 1 / gamma)

        out = int(f * 255)
    elif mode == "masked_vga":
        v = v & 0x3F
        return (v << 2) | (v >> 4)
    else:
        raise ValueError(mode)

    return max(0, min(255, out))


def load_palette_interleaved(data, scale_mode, order, gamma, inv_gamma, gains):
    palette = []
    for i in range(256):
        base = i * 3
        vals = [data[base], data[base+1], data[base+2]]
        r, g, b = vals[order[0]], vals[order[1]], vals[order[2]]

        r = scale_value(r, scale_mode, gamma, inv_gamma) * gains[0]
        g = scale_value(g, scale_mode, gamma, inv_gamma) * gains[1]
        b = scale_value(b, scale_mode, gamma, inv_gamma) * gains[2]

        palette.append((int(min(r,255)), int(min(g,255)), int(min(b,255))))
    return palette


def load_palette_planar(data, scale_mode, gamma, inv_gamma, gains):
    r_plane = data[0:256]
    g_plane = data[256:512]
    b_plane = data[512:768]

    palette = []
    for i in range(256):
        r = scale_value(r_plane[i], scale_mode, gamma, inv_gamma) * gains[0]
        g = scale_value(g_plane[i], scale_mode, gamma, inv_gamma) * gains[1]
        b = scale_value(b_plane[i], scale_mode, gamma, inv_gamma) * gains[2]

        palette.append((int(min(r,255)), int(min(g,255)), int(min(b,255))))
    return palette


def deinterleave_modex(pixel_bytes):
    arr = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
    plane_size = WIDTH // 4 * HEIGHT

    for plane in range(4):
        pdata = pixel_bytes[plane * plane_size : (plane + 1) * plane_size]
        row_stride = WIDTH // 4
        for y in range(HEIGHT):
            for xi in range(row_stride):
                arr[y, xi * 4 + plane] = pdata[y * row_stride + xi]

    return arr


def chunky_to_image(arr, palette):
    rgb = np.array([palette[p] for row in arr for p in row], dtype=np.uint8)
    return Image.fromarray(rgb.reshape(HEIGHT, WIDTH, 3))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("-o", "--output")
    ap.add_argument("--palette")
    ap.add_argument("--raw", action="store_true")

    ap.add_argument("--palette-layout", choices=["interleaved","planar"], default="interleaved")
    ap.add_argument("--palette-order", choices=list(CHANNEL_ORDERS.keys()), default="rgb")
    ap.add_argument("--palette-offset", type=int, default=0)

    ap.add_argument("--palette-scale",
        choices=["none","vga","vga_accurate","full","gamma","auto_gamma","masked_vga"], default="vga")

    ap.add_argument("--palette-gamma", type=float, default=2.2)
    ap.add_argument("--palette-inv-gamma", action="store_true")

    ap.add_argument("--gain-r", type=float, default=1.0)
    ap.add_argument("--gain-g", type=float, default=1.0)
    ap.add_argument("--gain-b", type=float, default=1.0)

    ap.add_argument("--palette-bruteforce", action="store_true")

    args = ap.parse_args()

    data = Path(args.input).read_bytes()

    pal_bytes = data[HEADER_SIZE:HEADER_SIZE+PALETTE_SIZE]
    pixel_data = data[HEADER_SIZE+PALETTE_SIZE:HEADER_SIZE+PALETTE_SIZE+PIXEL_SIZE]

    if args.palette:
        pal_bytes = Path(args.palette).read_bytes()

    if args.palette_offset:
        pal_bytes = pal_bytes[args.palette_offset:]

    gains = (args.gain_r, args.gain_g, args.gain_b)

    if args.raw:
        arr = np.frombuffer(pixel_data, dtype=np.uint8).reshape(HEIGHT, WIDTH)
    else:
        arr = deinterleave_modex(pixel_data)

    # -------- BRUTE FORCE --------
    if args.palette_bruteforce:
        scales = ["vga","vga_accurate","full","gamma","auto_gamma","masked_vga"]
        layouts = ["interleaved","planar"]
        gammas = [1.8, 2.0, 2.2, 2.4]
        offsets = [0,1,2]

        base = Path(args.input).stem

        for off in offsets:
            pb = pal_bytes[off:]
            if len(pb) < PALETTE_SIZE:
                continue

            for layout in layouts:
                for scale in scales:
                    for g in gammas:
                        for name, order in CHANNEL_ORDERS.items():
                            try:
                                if layout == "interleaved":
                                    pal = load_palette_interleaved(pb, scale, order, g, False, gains)
                                else:
                                    pal = load_palette_planar(pb, scale, g, False, gains)

                                img = chunky_to_image(arr, pal)
                                out = f"{base}_bf_{layout}_o{off}_{scale}_g{g}_{name}.png"
                                img.save(out)
                                print(out)

                            except Exception:
                                pass

        return

    # -------- NORMAL --------
    if args.palette_layout == "interleaved":
        palette = load_palette_interleaved(
            pal_bytes,
            args.palette_scale,
            CHANNEL_ORDERS[args.palette_order],
            args.palette_gamma,
            args.palette_inv_gamma,
            gains
        )
    else:
        palette = load_palette_planar(
            pal_bytes,
            args.palette_scale,
            args.palette_gamma,
            args.palette_inv_gamma,
            gains
        )

    img = chunky_to_image(arr, palette)

    out = args.output or Path(args.input).with_suffix(".png")
    img.save(out)

    print("Saved:", out)


if __name__ == "__main__":
    main()