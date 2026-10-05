# faf-dualgap-ai

**English** · [Русский](README.ru.md)

An AI mod for **Supreme Commander: Forged Alliance Forever (FAF)** built for the **Dual Gap Adaptive v14** map (6v6).
Each bot reads its spawn and plays a role: **GROUND** (land mid), **NAVAL** (water), **AIR** (air force) or **ECO** (economy and game enders).

The bots play like a team, not like twelve strangers:
- **Team play.** Adaptive roles (a fallen player's job passes to the ally who takes its mexes), help calls, base anti-air by AIR,
  a shared anti-nuke per three players.
- **Game enders.** Plans like a player's: usually one nuke first, then artillery or a T4; the whole team piles on a scouted enemy game ender.
- **Air.** Mass bomber strikes under fighter cover (ACU first, then game enders, anti-nukes, T3 economy), escorted Czar / Ahwassa
  raids along the map edges at the enemy ECO commander, every free fighter on an enemy air T4.
- **Land and navy.** Waves that push through the mid instead of standing around, fleets that regroup instead of feeding ships one by one,
  destroyers helping ground at the mid.
- **Commanders.** They hide in their own water, spread out on a nuke launch, step out of the base when no anti-nuke is loaded,
  and take cover under anti-air when an air T4 comes in.
- **Base and economy.** A player-like base with tight adjacency, base mexes T2 → storages → T3, and spending that grows with the income.

The standard AI plays with fog of war: it reacts only to what its team has seen or has on radar.
What changed in version 2: [CHANGELOG.md](CHANGELOG.md).

## Video
DualGap AI v2 demo match: https://youtu.be/qkAYdtKiQqw

[![DualGap AI v2 demo match](https://img.youtube.com/vi/qkAYdtKiQqw/hqdefault.jpg)](https://youtu.be/qkAYdtKiQqw)

## Support
If you like the project and want to see where it goes next, follow and support it on [Patreon](https://www.patreon.com/c/cityzenone).

## Install
1. Get the mod one of two ways:
   - from the **FAF mod vault**: find **DualGap AI** (version 2) in the FAF client and install it;
   - or by hand: copy the [`mods/DualGapAI`](mods/DualGapAI) folder to
     `%USERPROFILE%\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\`.
     The folder must be named exactly `DualGapAI`.
2. In the FAF lobby, open **Mods** and enable **DualGap AI**, then put **AI: DualGap (beta)** or **AIx: DualGap (beta)** bots on Dual Gap Adaptive v14.
   The bots appear in the AI list only while the mod is enabled.

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

```bash
python tools/draw_base.py ARMY_6
```
One army's base at 10, 21, 30, 42 and 60 minutes (`reports/<log>_<army>_base.html`) and what touches what (adjacency),
to compare a bot's base with a player's.

## Tests
Offline, no game needed (Python 3 and `pip install lupa`):

```bash
python tests/run_tests.py
```

The tests check syntax and Lua 5.0 compatibility, import paths and cross-module references, roles and mex ownership on the real map markers,
ACU decisions and production rules, and run the whole opening in a small simulation.

`tools/map_markers.py` prints a map's markers from its `*_save.lua`, which is handy for calibrating coordinates.
