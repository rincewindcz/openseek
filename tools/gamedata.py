"""Paths shared by the exporters: the pack output root, the game directory and
the shipped repo files they read (from a checkout, a PyInstaller bundle or the
zipapp).

ASSETS is read at call time (gamedata.ASSETS), so build_pack.py can point every
exporter at another output root before running them.
"""

import sys
import zipfile
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = Path(getattr(sys, "_MEIPASS", TOOLS_DIR.parent))
ASSETS    = REPO_ROOT / "assets"

DEFAULT_GAME_DIRS = (
    REPO_ROOT.parent / "dos" / "seek",
    Path.home() / "dos" / "seek",
)


def _zipapp():
    """The .pyz this module runs from, or None (source tree, PyInstaller)."""
    return TOOLS_DIR if zipfile.is_zipfile(TOOLS_DIR) else None


def write_text(path, text):
    """Write a pack text file with LF line endings on every platform, so a pack
    is the same bytes wherever it is built."""
    with open(path, "w", newline="\n") as f:
        f.write(text)


def read_resource(rel):
    """Bytes of a shipped repo file (data/..., content/...), from the source
    tree, the PyInstaller bundle or the zipapp."""
    archive = _zipapp()
    if archive:
        with zipfile.ZipFile(archive) as zf:
            return zf.read(rel)
    return (REPO_ROOT / rel).read_bytes()


def list_resources(folder, suffix):
    """Sorted repo-relative paths of the shipped files in folder ending in suffix."""
    archive = _zipapp()
    if archive:
        with zipfile.ZipFile(archive) as zf:
            names = [n for n in zf.namelist()
                     if n.startswith(folder.rstrip("/") + "/") and n.endswith(suffix)]
        return sorted(names)
    return sorted(str(p.relative_to(REPO_ROOT)) for p in (REPO_ROOT / folder).glob("*" + suffix))


def is_game_dir(path):
    return (path / "data").is_dir() and (path / "STAGE00").is_dir()


def find_game_dir(hint=None):
    """Extracted game directory with data/ and STAGE00/ (the build_pack layout)."""
    if hint:
        p = Path(hint).expanduser()
        if is_game_dir(p):
            return p
        sys.exit(f"not an extracted game directory (needs data/ and STAGE00/): {hint}")
    for c in DEFAULT_GAME_DIRS:
        if is_game_dir(c):
            return c
    sys.exit("Could not find the game directory. Pass --game-dir.")


def missions(game_dir):
    """Missions whose first stage is present: 0-1 in the shareware, 0-4 registered."""
    return [m for m in range(5) if (game_dir / "data" / f"STAGE{m}0.BIN").exists()]
