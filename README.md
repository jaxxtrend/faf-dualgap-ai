# faf-dualgap-ai

**English** · [Русский](README.ru.md)

An AI mod for **Supreme Commander: Forged Alliance Forever (FAF)** built for the **Dual Gap Adaptive v14** map (6v6).
Each bot reads its spawn and plays a role: **GROUND** (land mid), **NAVAL** (water), **AIR** (air force) or **ECO** (economy and game enders).

What it does: a strict opening build order, own-mex ownership (a fallen ally's mexes are split between the two nearest allies),
scouting with a shared team memory, waves that move in formation and air patrols along the front, a proxy base in the mid,
experimentals on role-specific triggers, one shared anti-nuke per three players, and responses to scouted game enders (the whole team piles on one), mass air attacks of 250-300 planes.

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

## Match analysis (telemetry)
With the mod enabled, every game writes telemetry into the FAF game log
(`%APPDATA%\Forged Alliance Forever\logs\game_*.log`), for **every army, human players included**:
a snapshot of economy and army every minute, every own structure with coordinates every 3 minutes,
each finished structure (build order and base layout) and unit positions every 10 seconds (movement).
Watching a replay of such a game writes the same telemetry again.
In FAF, a game with a sim mod is unranked.

The quickest way: double-click `analyze.cmd` in the project folder. It prints the report of the newest match and opens its map.
The scripts must be run from the project folder (`analyze.cmd` takes care of that).

```bash
python tools/parse_match.py
```
The newest match as a short table: one row per army, automatic problem flags (late tech, mass overflow,
energy stall, idle engineers, stuck projects, power not next to factories, few mex storages...)
and the human players' build orders. The full report goes to `reports/<log>.json`.

```bash
python tools/draw_match.py
```
An interactive map (`reports/<log>.html`) with a time slider: structures at their true size, units and army trails.

```bash
python tools/batch_report.py --last 10
```
Ten matches in one table: bots by role next to human players (tech timings, economy, base layout quality,
time of first AA / shield / T3...). It is short enough to paste into a chat for analysis.

## Tests
Offline, no game needed (Python 3 and `pip install lupa`):

```bash
python tests/run_tests.py
```

The tests check syntax and Lua 5.0 compatibility, import paths and cross-module references, roles and mex ownership on the real map markers,
ACU decisions and production rules, and run the whole opening in a small simulation.

`tools/map_markers.py` prints a map's markers from its `*_save.lua`, which is handy for calibrating coordinates.
