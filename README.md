# About openSEEK game

openSEEK is an open-source recreation of the game Seek & Destroy originally developed by SAFARI Software and Vision. It aims to provide a modern and accessible version of the game, while using the original game's assets and mechanics as a foundation.

The engine is built using Lua and the Love2D framework and it's not a direct copy of the original game, but rather a reimagined version that captures the essence of Seek & Destroy while introducing new features and improvements. 

> [!NOTE]
> openSEEK source code is licensed under the MIT License. You are free to use, modify, and distribute it as you wish.

# Notable features of openSEEK include:
* support for arbitrary screen resolutions and aspect ratios
* customizable controls and input methods
* new visual effects
* in-game level editor for exploring original levels and creating new ones (in development)
* multiplayer support for cooperative and network gameplay (in development)
* many little but cute QoL improvements
* unlocks few new vehicles and weapons that were not present in the original game (in development)
* playable on Linux, Windows, and macOS. Also supports Android and web

> [!IMPORTANT]
> openSEEK does *not* provide any copyrighted assets. You must have your own copy of the original game.

# TL;DR, show me the game already!

<br/>
<div align="center">
    <img src="screenshots/seek_1.png" alt="Seek & Destroy Gameplay" width="800">
    <br/>
    <img src="screenshots/seek_2.png" alt="Seek & Destroy Snow Mission" width="800">
    <br/>
    <img src="screenshots/seek_3.png" alt="Seek & Destroy Split-Screen Co-op" width="800">
    <br/>
    <img src="screenshots/seek_4.png" alt="Seek & Destroy Gameplay 2" width="800">
</div>

# Game data

openSEEK converts the original game files on your machine on first launch:

* **DOWNLOAD SHAREWARE** fetches the freely distributable Seek & Destroy v1.0 shareware release (missions 1 and 2) and converts it.
* **USE MY COPY** converts your own DOS installation (the folder with `DATA.JAM`, or the files already unpacked) or a release `.zip`. Type or paste the path, or drop the folder onto the window. The full version unlocks all five missions.

The converter ships next to the game as `openseek-setup.pyz`. The Windows download brings the Python that runs it; elsewhere it needs Python 3.8+ and nothing else. The converted data lives in the LOVE save directory, not in the game folder.

From a source checkout the same converter runs directly:

```sh
python3 tools/build_pack.py --download --out assets      # shareware
python3 tools/build_pack.py ~/dos/seek --out assets      # your own copy
love .
```
