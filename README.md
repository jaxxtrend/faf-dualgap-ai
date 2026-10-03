# faf-dualgap-ai

**English** · [Русский](README.ru.md)

An AI mod for **Supreme Commander: Forged Alliance Forever (FAF)** built for the **Dual Gap Adaptive v14** map (6v6).
Each bot reads its spawn and plays a role: **GROUND** (land mid), **NAVAL** (water), **AIR** (air force) or **ECO** (economy and game enders).

What it does: a strict opening build order, own-mex ownership (a fallen ally's mexes are split between the two nearest allies),
scouting with a shared team memory, waves that move in formation and air patrols along the front, a proxy base in the mid,
experimentals on role-specific triggers, one shared anti-nuke per three players, and responses to scouted game enders.

## Video
Test match with DualGap AI bots: https://youtu.be/36RrrPkwhb8

[![DualGap AI test match](https://img.youtube.com/vi/36RrrPkwhb8/hqdefault.jpg)](https://youtu.be/36RrrPkwhb8)

## Support
If you like the project and want to see where it goes next, follow and support it on [Patreon](https://www.patreon.com/c/cityzenone).

## Install
1. Copy the [`mods/DualGapAI`](mods/DualGapAI) folder to
   `%USERPROFILE%\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\`.
   The folder must be named exactly `DualGapAI`.
2. In the FAF lobby, enable the **DualGap AI** mod and put **AI: DualGap (beta)** or **AIx: DualGap (beta)** bots on Dual Gap Adaptive v14.

Roles, build order and settings are described in [mods/DualGapAI/README.md](mods/DualGapAI/README.md).
Edit build orders and production tables in [DualGapBuildOrders.lua](mods/DualGapAI/lua/AI/DualGapBuildOrders.lua),
coordinates and thresholds in [DualGapConfig.lua](mods/DualGapAI/lua/AI/DualGapConfig.lua).

## Tests
Offline, no game needed (Python 3 and `pip install lupa`):

```bash
python tests/run_tests.py
```

The tests check syntax and Lua 5.0 compatibility, import paths and cross-module references, roles and mex ownership on the real map markers,
ACU decisions and production rules, and run the whole opening in a small simulation.

`tools/map_markers.py` prints a map's markers from its `*_save.lua`, which is handy for calibrating coordinates.
