#!/usr/bin/env python3
"""
Export Seek and Destroy sound effects for the Love2D engine (assets/sounds/).

The original SFX live in the game's SFX/ directory as IFF 8SVX files (Amiga
8-bit signed PCM). Each is a FORM....8SVX container with a VHDR header (sample
rate, compression) and a BODY chunk of samples. Most are uncompressed
(sCompression 0); Fibonacci-delta (sCompression 1) is also decoded.

Output:
  assets/sounds/<name>.wav   mono 8-bit PCM WAV, one per source file
  assets/sounds.json         catalog: ordered categories -> [{name,file,label,rate}]

<name> is the lowercased source filename with non-alphanumerics turned into
underscores, so BOMB.SFX -> bomb_sfx and BOMB.SPC -> bomb_spc stay distinct.

Usage:
  export_sounds.py                 # source: ~/dos/seek/SFX
  export_sounds.py /path/to/SFX    # explicit source directory
"""

import json
import os
import re
import struct
import sys

REPO      = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR   = os.path.join(REPO, "assets", "sounds")
CATALOG   = os.path.join(REPO, "assets", "sounds.json")
DEFAULT_SRC = os.path.expanduser("~/dos/seek/SFX")

FIB_DELTA = [-34, -21, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 21]

# Ordered categories and the filename-glob rules that route sounds into them.
# First matching category wins; anything unmatched lands in "misc".
CATEGORIES = [
    ("weapons", "Weapons", [
        "weapon*", "chaingun", "tankgun*", "missile*", "mine*", "mega*",
        "shell*", "flame*", "flamer*", "napalm*", "supernap*", "bomb*",
        "powshell*", "gtoair*"]),
    ("vehicle", "Vehicle", [
        "chopper*", "tank", "tank_*", "tstart*", "tcomein*", "jetstr",
        "reload"]),
    ("voice", "Voice / Callouts", [
        "mayday", "incoming", "comein*", "cleared", "returnto", "letsgeto",
        "mission*", "justinti", "overkill", "toomanyhi", "finishhi",
        "touchdow", "4seconds", "pow*", "damagecr", "warn", "noisesir"]),
    ("ui", "UI", ["click*", "select", "icons"]),
    ("explosions", "Explosions / Impacts", [
        "holexp", "kzexp", "*exp", "rico*"]),
]

FALLBACK = ("misc", "Misc")


def norm_name(filename):
    return re.sub(r"[^a-z0-9]+", "_", filename.lower()).strip("_")


def label_for(filename):
    base = re.sub(r"\.(sfx|spc|fir)$", "", filename, flags=re.IGNORECASE)
    return base.replace("_", " ").strip().upper()


def category_for(name):
    from fnmatch import fnmatch
    for key, title, rules in CATEGORIES:
        for rule in rules:
            if fnmatch(name, rule):
                return key, title
    return FALLBACK


def read_chunks(data):
    """Yield (chunk_id, chunk_bytes) for the top-level chunks inside FORM 8SVX."""
    if data[:4] != b"FORM" or data[8:12] != b"8SVX":
        return
    pos = 12
    end = len(data)
    while pos + 8 <= end:
        cid  = data[pos:pos + 4]
        size = struct.unpack_from(">I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        yield cid, body
        pos += 8 + size
        if size & 1:
            pos += 1  # chunks are word-aligned


def fib_decode(body):
    """Decode a Fibonacci-delta compressed 8SVX BODY to signed 8-bit samples."""
    if len(body) < 2:
        return b""
    out = bytearray()
    x = body[1] - 256 if body[1] >= 128 else body[1]
    for d in body[2:]:
        x = (x + FIB_DELTA[d >> 4])
        out.append(x & 0xff)
        x = (x + FIB_DELTA[d & 0x0f])
        out.append(x & 0xff)
    return bytes(out)


def decode_8svx(data):
    """Return (rate, signed_pcm_bytes) or None if not a usable 8SVX file."""
    rate, compression, samples = 8000, 0, None
    for cid, body in read_chunks(data):
        if cid == b"VHDR" and len(body) >= 16:
            rate        = struct.unpack_from(">H", body, 12)[0] or 8000
            compression = body[15]
        elif cid == b"BODY":
            samples = body
    if samples is None:
        return None
    if compression == 1:
        samples = fib_decode(samples)
    elif compression != 0:
        return None
    return rate, samples


def write_wav(path, rate, signed_pcm):
    """Write mono 8-bit PCM WAV (8-bit WAV samples are unsigned: +128 offset)."""
    pcm  = bytes((s + 128) & 0xff for s in signed_pcm)
    n    = len(pcm)
    hdr  = b"RIFF" + struct.pack("<I", 36 + n) + b"WAVE"
    hdr += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate, 1, 8)
    hdr += b"data" + struct.pack("<I", n)
    with open(path, "wb") as f:
        f.write(hdr)
        f.write(pcm)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    if not os.path.isdir(src):
        sys.exit("source directory not found: " + src)

    os.makedirs(OUT_DIR, exist_ok=True)
    buckets = {key: [] for key, _, _ in CATEGORIES}
    buckets[FALLBACK[0]] = []
    titles = {key: title for key, title, _ in CATEGORIES}
    titles[FALLBACK[0]] = FALLBACK[1]

    converted, skipped = 0, []
    for filename in sorted(os.listdir(src)):
        full = os.path.join(src, filename)
        if not os.path.isfile(full):
            continue
        with open(full, "rb") as f:
            data = f.read()
        result = decode_8svx(data)
        if result is None:
            skipped.append(filename)
            continue
        rate, samples = result
        name = norm_name(filename)
        out  = name + ".wav"
        write_wav(os.path.join(OUT_DIR, out), rate, samples)
        key, _ = category_for(name)
        buckets[key].append({
            "name":  name,
            "file":  "assets/sounds/" + out,
            "label": label_for(filename),
            "rate":  rate,
        })
        converted += 1

    catalog = []
    for key in list(titles):
        items = sorted(buckets[key], key=lambda it: it["name"])
        if items:
            catalog.append({"name": key, "title": titles[key], "items": items})

    with open(CATALOG, "w") as f:
        json.dump(catalog, f, indent=2)
        f.write("\n")

    print("converted %d sound(s) to %s" % (converted, OUT_DIR))
    for cat in catalog:
        print("  %-11s %d" % (cat["name"], len(cat["items"])))
    if skipped:
        print("skipped (not 8SVX): " + ", ".join(skipped))
    print("catalog: " + CATALOG)


if __name__ == "__main__":
    main()
