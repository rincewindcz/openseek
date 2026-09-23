"""Minimal RGBA image with PNG output, standing in for the subset of Pillow the
pack exporters use, so the converter runs on a bare Python 3 install.

Pixels are stored as RGBA bytes whatever the mode; mode only picks the PNG
color type on save ("RGB" drops alpha).
"""

import builtins
import struct
import zlib

NEAREST = 0


class _Pixels:
    __slots__ = ("img",)

    def __init__(self, img):
        self.img = img

    def __getitem__(self, xy):
        return self.img.getpixel(xy)

    def __setitem__(self, xy, color):
        self.img.putpixel(xy, color)


class Image:
    def __init__(self, mode, size, color=(0, 0, 0, 0)):
        if mode not in ("RGBA", "RGB"):
            raise ValueError(f"unsupported mode {mode}")
        self.mode = mode
        self.width, self.height = size
        self.data = bytearray(bytes(_rgba(color)) * (self.width * self.height))

    @property
    def size(self):
        return self.width, self.height

    def load(self):
        return _Pixels(self)

    def putpixel(self, xy, color):
        x, y = xy
        i = (y * self.width + x) * 4
        self.data[i:i + 4] = bytes(_rgba(color))

    def getpixel(self, xy):
        x, y = xy
        i = (y * self.width + x) * 4
        px = tuple(self.data[i:i + 4])
        return px if self.mode == "RGBA" else px[:3]

    def crop(self, box):
        left, top, right, bottom = box
        out = Image(self.mode, (right - left, bottom - top))
        row = (right - left) * 4
        for y in range(top, bottom):
            if 0 <= y < self.height and left >= 0 and right <= self.width:
                src = (y * self.width + left) * 4
                dst = (y - top) * row
                out.data[dst:dst + row] = self.data[src:src + row]
            else:
                for x in range(left, right):
                    if 0 <= x < self.width and 0 <= y < self.height:
                        out.putpixel((x - left, y - top), self.getpixel((x, y)))
        return out

    def paste(self, img, xy, mask=None):
        """Copy img at xy; with a mask, only where the mask's alpha is non-zero."""
        ox, oy = xy
        for y in range(img.height):
            ty = oy + y
            if not 0 <= ty < self.height:
                continue
            for x in range(img.width):
                tx = ox + x
                if not 0 <= tx < self.width:
                    continue
                i = (y * img.width + x) * 4
                if mask is not None and mask.data[(y * mask.width + x) * 4 + 3] == 0:
                    continue
                j = (ty * self.width + tx) * 4
                self.data[j:j + 4] = img.data[i:i + 4]

    def resize(self, size, resample=NEAREST):
        w, h = size
        out = Image(self.mode, size)
        for y in range(h):
            sy = y * self.height // h
            for x in range(w):
                sx = x * self.width // w
                i = (sy * self.width + sx) * 4
                j = (y * w + x) * 4
                out.data[j:j + 4] = self.data[i:i + 4]
        return out

    def save(self, path):
        with builtins.open(path, "wb") as f:
            f.write(encode_png(self))


def new(mode, size, color=(0, 0, 0, 0)):
    return Image(mode, size, color)


def open(path):
    with builtins.open(path, "rb") as f:
        return decode_png(f.read())


def decode_png(data):
    """Decode an 8-bit RGB or RGBA, non-interlaced PNG (what encode_png writes)."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, idat = 8, bytearray()
    while pos < len(data):
        length, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            w, h, depth, color_type, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat += body
        pos += 12 + length
    if depth != 8 or color_type not in (2, 6) or interlace:
        raise ValueError(f"unsupported PNG (depth {depth}, type {color_type})")
    bpp = 4 if color_type == 6 else 3
    raw = zlib.decompress(bytes(idat))
    stride = w * bpp
    img = Image("RGBA" if bpp == 4 else "RGB", (w, h))
    prev = bytearray(stride)
    for y in range(h):
        kind = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = row[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if kind == 1:
                row[i] = (row[i] + a) & 0xFF
            elif kind == 2:
                row[i] = (row[i] + b) & 0xFF
            elif kind == 3:
                row[i] = (row[i] + (a + b) // 2) & 0xFF
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else b if pb <= pc else c
                row[i] = (row[i] + pred) & 0xFF
        for x in range(w):
            px = row[x * bpp:x * bpp + bpp]
            j = (y * w + x) * 4
            img.data[j:j + 4] = px if bpp == 4 else px + b"\xff"
        prev = row
    return img


def _rgba(color):
    """Clamped to 0-255 like Pillow: palettes x4 can overflow (GOVPAL sentinels)."""
    if len(color) == 3:
        color = (color[0], color[1], color[2], 255)
    return tuple(0 if v < 0 else 255 if v > 255 else int(v) for v in color)


def _chunk(tag, body):
    return (struct.pack(">I", len(body)) + tag + body
            + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF))


def encode_png(img):
    w, h = img.size
    if img.mode == "RGB":
        color_type = 2
        rows = bytearray()
        for y in range(h):
            rows.append(0)
            row = img.data[y * w * 4:(y + 1) * w * 4]
            for x in range(w):
                rows += row[x * 4:x * 4 + 3]
    else:
        color_type = 6
        rows = bytearray()
        stride = w * 4
        for y in range(h):
            rows.append(0)
            rows += img.data[y * stride:(y + 1) * stride]
    header = struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header)
            + _chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + _chunk(b"IEND", b""))
