#!/usr/bin/env python3
"""
Package the game data converter (build_pack.py) for release, next to the game:

  build/openseek-setup.pyz   Python zipapp, runs on any python3 >= 3.8 with no
                             third-party packages (Linux, macOS; Windows with
                             the py launcher)
  build/openseek-setup.exe   PyInstaller one-file console build (--pyinstaller;
                             run on Windows, PyInstaller does not cross-compile)

Both carry the converter modules plus the repo files the exporters read
(RESOURCES), resolved at run time by gamedata.read_resource.

Usage:
  python3 tools/build_setup.py
  python3 tools/build_setup.py --pyinstaller
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
import zipapp
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
BUILD_DIR = REPO_ROOT / "build"
NAME      = "openseek-setup"

MODULES = [
    "build_pack", "gamedata", "unjam", "image",
    "decode_blitter", "decode_planar", "decode_level", "menutitle",
    "export_animations", "export_ending", "export_equip", "export_fonts",
    "export_fullscreen", "export_hud", "export_love2d", "export_mainmen",
    "export_mission", "export_mission_text", "export_music", "export_phend",
    "export_player", "export_projectiles", "export_screens", "export_shop",
    "export_sounds",
]
RESOURCES = [
    "data/entity_types.json",
    "content/fonts/main_synth",
]

MAIN = """import sys
import build_pack

sys.exit(build_pack.main())
"""


def stage(root):
    for name in MODULES:
        shutil.copy2(TOOLS_DIR / f"{name}.py", root / f"{name}.py")
    for rel in RESOURCES:
        src, dest = REPO_ROOT / rel, root / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        if src.is_dir():
            shutil.copytree(src, dest)
        else:
            shutil.copy2(src, dest)
    (root / "__main__.py").write_text(MAIN)


def build_pyz(root):
    target = BUILD_DIR / f"{NAME}.pyz"
    zipapp.create_archive(root, target, interpreter="/usr/bin/env python3", compressed=True)
    return target


def build_pyinstaller(root):
    sep = ";" if sys.platform == "win32" else ":"
    args = [sys.executable, "-m", "PyInstaller", "--onefile", "--console", "--noconfirm",
            "--name", NAME, "--distpath", str(BUILD_DIR),
            "--workpath", str(root / "pyinstaller"), "--specpath", str(root),
            "--paths", str(root)]
    for name in MODULES:
        args += ["--hidden-import", name]
    for rel in RESOURCES:
        dest = rel if (REPO_ROOT / rel).is_dir() else str(Path(rel).parent)
        args += ["--add-data", f"{root / rel}{sep}{dest}"]
    subprocess.run(args + [str(root / "__main__.py")], check=True)
    return BUILD_DIR / (NAME + (".exe" if sys.platform == "win32" else ""))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Package the game data converter.")
    ap.add_argument("--pyinstaller", action="store_true",
                    help="also build the PyInstaller one-file executable")
    args = ap.parse_args(argv)

    BUILD_DIR.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="openseek-setup-") as tmp:
        root = Path(tmp) / "app"
        root.mkdir()
        stage(root)
        print(build_pyz(root))
        if args.pyinstaller:
            print(build_pyinstaller(root))


if __name__ == "__main__":
    main()
