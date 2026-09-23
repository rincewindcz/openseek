#!/usr/bin/env python3
"""
Build the openSEEK game data pack (assets/) from an original Seek and Destroy copy.

Sources, any of:
  --download          the shareware release, fetched from MIRRORS and md5-checked
  PATH to a .zip      a release archive (the shareware seeksw1.zip or similar)
  PATH to a directory a DOS installation: DATA.JAM + DATA.JAL, or the files
                      UNPACK.EXE already extracted (data/, STAGE0N/, SFX/)

The source is normalized into a temporary directory in the layout the exporters
expect (data/ lowercase, everything else uppercase), every exporter runs against
it in-process, and the result replaces --out atomically. --out gets a
manifest.json the engine checks before booting.

Progress goes to stdout as one line per step ("[3/14] export_player"); exporter
output goes to <out>.log.

Usage:
  build_pack.py --download --out ~/.local/share/love/openseek/assets
  build_pack.py ~/Downloads/seeksw1.zip --out /tmp/pack/assets
  build_pack.py ~/dos/seek --out /tmp/pack/assets
"""

import argparse
import contextlib
import hashlib
import json
import os
import shutil
import sys
import tempfile
import traceback
import urllib.request
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import export_animations
import export_equip
import export_fonts
import export_fullscreen
import export_hud
import export_love2d
import export_mainmen
import export_mission
import export_mission_text
import export_phend
import export_player
import export_projectiles
import export_screens
import export_shop
import export_sounds
import gamedata
from unjam import ArchiveError, JamArchive

PACK_SCHEMA = 2

SHAREWARE_ZIP = "seeksw1.zip"
SHAREWARE_MD5 = "0bf3fa0359bbc3186d6041f1cab8b524"
MIRRORS = [
    "https://archive.org/download/SeekAndDestroy_837/seeksw1.zip",
]

# Order matters where two steps write the same file: export_shop re-exports the
# charspow font from export_fonts in the shop palette.
STEPS = [
    (export_love2d,       ["all"]),
    (export_fullscreen,   []),
    (export_projectiles,  []),
    (export_player,       []),
    (export_hud,          []),
    (export_animations,   []),
    (export_fonts,        []),
    (export_mainmen,      []),
    (export_screens,      []),
    (export_mission,      []),
    (export_mission_text, []),
    (export_sounds,       []),
    (export_phend,        []),
    (export_shop,         []),
    (export_equip,        []),
]

GAME_TREES = ("DATA", "SFX") + tuple(f"STAGE0{m}" for m in range(5))
MAX_DEPTH  = 4


class SourceError(Exception):
    pass


def progress(text):
    print(text, flush=True)


# source discovery

def _split(path):
    return [p for p in path.replace("\\", "/").split("/") if p]


def _dir_members(root):
    """Files up to MAX_DEPTH folders below root; an install is never deeper, and
    the limit keeps a wrong pick (a home directory) from walking everything."""
    members = {}
    for folder, dirs, files in os.walk(root):
        rel = Path(folder).relative_to(root)
        if len(rel.parts) >= MAX_DEPTH:
            dirs[:] = []
        for name in files:
            members["/".join(rel.parts + (name,))] = (Path(folder) / name).read_bytes
    return members


def _zip_members(zf):
    return {info.filename: (lambda name=info.filename: zf.read(name))
            for info in zf.infolist() if not info.is_dir()}


def _find_jam(members):
    """DATA.JAM + DATA.JAL (or the OLDDATA.* pair UNPACK.EXE renames them to),
    shallowest match first."""
    by_name = {}
    for path in sorted(members, key=lambda p: len(_split(p))):
        parts = _split(path)
        key = ("/".join(parts[:-1]).upper(), parts[-1].upper())
        by_name.setdefault(key, path)
    for (folder, name), path in by_name.items():
        for stem in ("DATA", "OLDDATA"):
            if name == stem + ".JAM" and (folder, stem + ".JAL") in by_name:
                jal = by_name[(folder, stem + ".JAL")]
                return members[path](), members[jal]()
    return None


def _extracted_root(members):
    """Folder prefix under which data/STAGE00.BIN sits, shallowest first."""
    for path in sorted(members, key=lambda p: len(_split(p))):
        parts = [p.upper() for p in _split(path)]
        if parts[-2:] == ["DATA", "STAGE00.BIN"]:
            return len(parts) - 2
    return None


def game_members(members):
    """Normalized {relpath: loader} of the game trees from a raw member listing."""
    jam = _find_jam(members)
    if jam is not None:
        try:
            archive = JamArchive.from_bytes(*jam)
        except ArchiveError as exc:
            raise SourceError(f"damaged DATA.JAM: {exc}")
        members = {e.path: (lambda e=e: archive.read(e)) for e in archive.entries}
        depth = 0
    else:
        depth = _extracted_root(members)
        if depth is None:
            raise SourceError("no Seek and Destroy data found (DATA.JAM or data/STAGE00.BIN)")
    out = {}
    for path, load in members.items():
        parts = [p.upper() for p in _split(path)][depth:]
        if len(parts) < 2 or parts[0] not in GAME_TREES:
            continue
        if parts[0] == "DATA":
            if len(parts) != 2:
                continue
            parts[0] = "data"
        out["/".join(parts)] = load
    return out


def stage_source(source, staging):
    """Write the normalized game trees of `source` (zip or directory) to `staging`."""
    source = Path(source).expanduser()
    if source.is_dir():
        members = _dir_members(source)
        files = game_members(members)
    elif zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as zf:
            files = {k: v() for k, v in game_members(_zip_members(zf)).items()}
        files = {k: (lambda data=v: data) for k, v in files.items()}
    else:
        raise SourceError(f"not a directory or zip archive: {source}")
    for rel, load in files.items():
        dest = staging / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(load())
    if not gamedata.is_game_dir(staging):
        raise SourceError("incomplete game data: data/ or STAGE00/ missing")
    return len(files)


# download

def md5_of(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download_shareware(cache_dir):
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / SHAREWARE_ZIP
    if target.exists() and md5_of(target) == SHAREWARE_MD5:
        progress(f"download cached {target}")
        return target
    part = target.with_suffix(".part")
    errors = []
    for url in MIRRORS:
        progress(f"download {url}")
        try:
            with urllib.request.urlopen(url, timeout=60) as resp, open(part, "wb") as f:
                total = int(resp.headers.get("Content-Length") or 0)
                done, shown = 0, -1
                for block in iter(lambda: resp.read(1 << 16), b""):
                    f.write(block)
                    done += len(block)
                    pct = done * 100 // total if total else 0
                    if pct // 10 != shown:
                        shown = pct // 10
                        progress(f"download {pct}%")
        except OSError as exc:
            errors.append(f"{url}: {exc}")
            continue
        if md5_of(part) != SHAREWARE_MD5:
            errors.append(f"{url}: checksum mismatch")
            continue
        part.replace(target)
        return target
    part.unlink(missing_ok=True)
    raise SourceError("download failed:\n  " + "\n  ".join(errors))


# pack

def run_steps(game_dir, log):
    failed = []
    for i, (module, args) in enumerate(STEPS, 1):
        name = module.__name__
        progress(f"[{i}/{len(STEPS)}] {name}")
        print(f"\n=== {name}", file=log)
        try:
            with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                module.main(args + ["--game-dir", str(game_dir)])
        except SystemExit as exc:
            if exc.code not in (None, 0):
                failed.append(name)
                print(f"FAILED: {exc.code}", file=log)
        except Exception:
            failed.append(name)
            traceback.print_exc(file=log)
    return failed


def is_replaceable(out):
    return not out.exists() or (out / "manifest.json").exists() or not any(out.iterdir())


def build(source, out, origin, force=False):
    """Convert `source` into the pack at `out`; `origin` is what the manifest
    records for a later rebuild ("download" or the source path)."""
    out = Path(out).expanduser().resolve()
    if not force and not is_replaceable(out):
        raise SourceError(f"{out} exists and is not a generated pack (no manifest.json); "
                          "pass --force to replace it")
    new      = out.with_name(out.name + ".new")
    log_path = out.with_name(out.name + ".log")

    with tempfile.TemporaryDirectory(prefix="openseek-") as tmp:
        staging = Path(tmp)
        progress(f"source {source}")
        count   = stage_source(source, staging)
        found   = gamedata.missions(staging)
        edition = "registered" if found == list(range(5)) else "shareware"
        progress(f"found {count} files, {edition}, missions {found}")

        shutil.rmtree(new, ignore_errors=True)
        new.mkdir(parents=True)
        gamedata.ASSETS = new
        with open(log_path, "w") as log:
            failed = run_steps(staging, log)

    manifest = {
        "schema":   PACK_SCHEMA,
        "edition":  edition,
        "missions": found,
        "failed":   failed,
        "source":   origin,
    }
    (new / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    old = out.with_name(out.name + ".old")
    shutil.rmtree(old, ignore_errors=True)
    if out.exists():
        out.rename(old)
    new.rename(out)
    shutil.rmtree(old, ignore_errors=True)
    return failed, log_path


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the openSEEK game data pack.")
    ap.add_argument("source", nargs="?", help="game directory or release .zip")
    ap.add_argument("--download", action="store_true", help="fetch the shareware release")
    ap.add_argument("--cache", help="download directory (default: next to --out)")
    ap.add_argument("--out", required=True, help="pack directory to create or replace")
    ap.add_argument("--force", action="store_true",
                    help="replace --out even if it is not a generated pack")
    args = ap.parse_args(argv)

    if bool(args.source) == args.download:
        ap.error("pass exactly one of SOURCE or --download")
    out = Path(args.out).expanduser()
    try:
        if args.download:
            cache  = Path(args.cache).expanduser() if args.cache else out.parent / "downloads"
            source = download_shareware(cache)
            origin = "download"
        else:
            source = Path(args.source).expanduser().resolve()
            origin = str(source)
        failed, log_path = build(source, out, origin, args.force)
    except (SourceError, OSError) as exc:
        progress(f"ERROR {exc}")
        return 1
    if failed:
        progress(f"WARN failed steps: {', '.join(failed)} (see {log_path})")
    progress(f"DONE {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
