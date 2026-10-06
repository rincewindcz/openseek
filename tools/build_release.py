#!/usr/bin/env python3
"""
Build the release downloads into build/:

  openseek.love                 the game: the files git lists under ROOTS plus
                                build.json, the stamp engine/core/version.lua
                                reads (version, commit, dirty)
  openseek-setup.pyz            the converter zipapp (build_setup.py)
  openseek-<id>-win64.zip       --windows: openseek.exe (LOVE fused with the
                                .love, carrying the game icon), the LOVE DLLs
                                and license, the converter zipapp with the
                                Python that runs it (python/), LICENSE, README

The version is the git tag on HEAD, if any; <id> is that tag, else the commit.
The Windows zip is built from the official LOVE and embeddable Python
downloads, fetched once into build/cache and checked against pinned hashes, so
it needs no Windows machine.

Usage:
  python3 tools/build_release.py
  python3 tools/build_release.py --windows
  python3 tools/build_release.py --love PATH [--replay-upload]   # the .love alone
"""

import argparse
import hashlib
import json
import math
import struct
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

import build_setup
import image

REPO_ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = REPO_ROOT / "build"
CACHE_DIR = BUILD_DIR / "cache"
NAME      = "openseek"
ROOTS     = ["main.lua", "conf.lua", "engine", "lib", "data", "content"]
ICON      = REPO_ROOT / "content" / "icon" / "openseek.png"

LOVE_WIN64          = "love-11.5-win64"
LOVE_WIN64_URL      = f"https://github.com/love2d/love/releases/download/11.5/{LOVE_WIN64}.zip"
LOVE_WIN64_SHA256   = "ba6e56be2685e53c817749c4a5007f51137136fe5a3ab64920508babc2e74369"
PYTHON_WIN64_URL    = "https://www.python.org/ftp/python/3.12.7/python-3.12.7-embed-amd64.zip"
PYTHON_WIN64_SHA256 = "0d57bb6cb078b74d23dbfe91f77d6780d45bed328911609f1f7ee2ba1606bf44"


def git(*args):
    """Output of a git command in the repo, or None when it fails."""
    run = subprocess.run(["git", *args], cwd=REPO_ROOT, capture_output=True, text=True)
    return run.stdout.strip() if run.returncode == 0 else None


def stamp():
    commit = git("rev-parse", "--short=7", "HEAD")
    if commit is None:
        sys.exit("build_release: not a git checkout")
    info = {"commit": commit, "dirty": bool(git("status", "--porcelain", "--", *ROOTS))}
    version = git("describe", "--tags", "--exact-match", "HEAD")
    if version:
        info["version"] = version
    return info


def build_love(target, info):
    """The tracked and the new files under ROOTS; ignored and excluded ones stay out."""
    files = git("ls-files", "-co", "--exclude-standard", "--", *ROOTS).splitlines()
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
        for rel in sorted(files):
            if (REPO_ROOT / rel).is_file():
                zf.write(REPO_ROOT / rel, rel)
        zf.writestr("build.json", json.dumps(info, indent=2) + "\n")
    return target


def cached(url, sha256):
    """The download at url, fetched once into build/cache."""
    target = CACHE_DIR / url.rsplit("/", 1)[1]
    if not target.exists():
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        print(f"download {url}")
        part = target.with_suffix(".part")
        with urllib.request.urlopen(url, timeout=60) as resp:
            part.write_bytes(resp.read())
        part.replace(target)
    if hashlib.sha256(target.read_bytes()).hexdigest() != sha256:
        sys.exit(f"build_release: {target} does not match the pinned checksum")
    return target


def downscale(icon, size):
    """Rows of (r, g, b, a) of the square icon at size x size: an area average,
    colors weighted by alpha."""
    ratio = icon.width / size
    spans = []
    for i in range(size):
        low, high = i * ratio, (i + 1) * ratio
        spans.append([(j, min(high, j + 1) - max(low, j))
                      for j in range(int(low), min(icon.width, math.ceil(high)))])
    rows = []
    for span_y in spans:
        row = []
        for span_x in spans:
            red = green = blue = alpha = 0.0
            for y, weight_y in span_y:
                for x, weight_x in span_x:
                    at = (y * icon.width + x) * 4
                    weight = weight_y * weight_x * icon.data[at + 3]
                    red   += icon.data[at] * weight
                    green += icon.data[at + 1] * weight
                    blue  += icon.data[at + 2] * weight
                    alpha += weight
            if alpha > 0:
                row.append((round(red / alpha), round(green / alpha), round(blue / alpha),
                            round(alpha / (ratio * ratio))))
            else:
                row.append((0, 0, 0, 0))
        rows.append(row)
    return rows


def icon_dib(icon, template):
    """The icon as the icon bitmap template is: 32-bit BGRA rows bottom-up,
    then the 1-bit transparency mask, under the template's header."""
    width, _, _, bits, compression = struct.unpack_from("<iiHHI", template, 4)
    if bits != 32 or compression != 0:
        sys.exit("build_release: unexpected icon format in the LOVE runtime")
    rows   = downscale(icon, width)[::-1]
    pixels = b"".join(bytes((b, g, r, a)) for row in rows for r, g, b, a in row)
    mask   = bytearray()
    for row in rows:
        line = bytearray((width + 31) // 32 * 4)
        for x, pixel in enumerate(row):
            if pixel[3] == 0:
                line[x // 8] |= 0x80 >> (x % 8)
        mask += line
    return template[:40] + pixels + bytes(mask)


def set_icon(exe, love_ico, icon):
    """love.exe holds the bitmaps of love.ico verbatim. Each is replaced in
    place by the game icon at the same size, which leaves the file's structure
    as it was."""
    for i in range(struct.unpack_from("<H", love_ico, 4)[0]):
        size, offset = struct.unpack_from("<II", love_ico, 6 + 16 * i + 8)
        old = love_ico[offset:offset + size]
        new = icon_dib(icon, old)
        if exe.count(old) != 1 or len(new) != len(old):
            sys.exit("build_release: the LOVE icon is not where it was in love.exe")
        exe = exe.replace(old, new)
    return exe


def build_windows(love_file, setup_file, info):
    target = BUILD_DIR / f"{NAME}-{info.get('version') or info['commit']}-win64.zip"
    with zipfile.ZipFile(cached(LOVE_WIN64_URL, LOVE_WIN64_SHA256)) as runtime, \
         zipfile.ZipFile(cached(PYTHON_WIN64_URL, PYTHON_WIN64_SHA256)) as python, \
         zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
        def read(name):
            return runtime.read(f"{LOVE_WIN64}/{name}")
        exe = set_icon(read("love.exe"), read("love.ico"), image.open(ICON))
        zf.writestr(f"{NAME}/{NAME}.exe", exe + love_file.read_bytes())
        for entry in runtime.namelist():
            if entry.endswith(".dll"):
                zf.writestr(f"{NAME}/{Path(entry).name}", runtime.read(entry))
        zf.writestr(f"{NAME}/LOVE-LICENSE.txt", read("license.txt"))
        zf.write(setup_file, f"{NAME}/{setup_file.name}")
        for entry in python.namelist():
            zf.writestr(f"{NAME}/python/{entry}", python.read(entry))
        zf.write(REPO_ROOT / "LICENSE", f"{NAME}/LICENSE.txt")
        zf.write(REPO_ROOT / "README.md", f"{NAME}/README.md")
    return target


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the release downloads.")
    ap.add_argument("--windows", action="store_true", help="also build the Windows zip")
    ap.add_argument("--love", type=Path, metavar="PATH",
                    help="write only the .love, to PATH")
    ap.add_argument("--replay-upload", action="store_true",
                    help="stamp replay_upload (web test builds)")
    args = ap.parse_args(argv)

    info = stamp()
    if args.replay_upload:
        info["replay_upload"] = True
    if args.love:
        print(build_love(args.love, info))
        return
    love_file = build_love(BUILD_DIR / f"{NAME}.love", info)
    print(love_file)
    build_setup.main([])
    if args.windows:
        print(build_windows(love_file, BUILD_DIR / f"{build_setup.NAME}.pyz", info))


if __name__ == "__main__":
    main()
