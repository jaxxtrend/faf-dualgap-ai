# DualGap AI (FAF, Dual Gap Adaptive v14)

**English** · [Русский](README.ru.md)

An AI whose role comes from its spawn point: `GROUND`, `NAVAL`, `AIR`, `ECO`.

## Install
1. Copy the `DualGapAI` folder to `%USERPROFILE%\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\`.
   The folder must be named exactly `DualGapAI`: FAF mounts the mod as `/mods/DualGapAI/`, and every import inside the mod uses that path.
2. In the FAF lobby, enable the **DualGap AI** mod and put **AI: DualGap** (or **AIx: DualGap**, the cheating version) in the AI slots.

## Roles on Dual Gap Adaptive v14 (from the map markers)
| Slot | Role | Slot | Role |
|---|---|---|---|
| ARMY_1 | AIR | ARMY_2 | AIR |
| ARMY_9 | GROUND | ARMY_10 | GROUND |
| ARMY_3 | GROUND | ARMY_4 | GROUND |
| ARMY_5 | NAVAL | ARMY_6 | NAVAL |
| ARMY_11 | ECO | ARMY_12 | ECO |
| ARMY_7 | AIR | ARMY_8 | AIR |

Coordinates are measured against the `AREA_1` rectangle (0, 200.5 → 1024, 830.5), the map's starting playable area.
It stays fixed when the adaptive map expands its playable area.

## How roles are assigned
All `ARMY_N` start markers are split into the left and right team and sorted top to bottom.
With 6 spawns per team, the role goes by position: AIR, GROUND, GROUND, NAVAL, ECO, AIR (as in the map layout).
Otherwise the nearest anchor from `DualGapConfig.SpawnSlots` wins.
`game.log` gets a `DualGap: ARMY_n side=... role=...` line per slot, which is handy for checking and calibrating coordinates.
To force a role, set `RoleOverrides = { ARMY_3 = 'ECO' }` in `lua/AI/DualGapConfig.lua`.

## How the bot builds
FAF's stock builders are not used: the stock brain gets a single placeholder and builds nothing on its own.
The ACU, engineers and factories are driven by the mod's modules:

1. **Opening build order** ([DualGapBuildOrders.lua](lua/AI/DualGapBuildOrders.lua), strictly in order):
   - ACU: the role's start factory → 2 mexes → 2 power generators → 6 mexes → 2 power generators → mexes upgraded to T2 one at a time
     (GROUND and NAVAL start the upgrades and leave right away, the others assist);
   - first factory: scout → 10 T1 engineers → T2 → 5 T2 engineers → scouts up to 3 (air factory only) → T3 → 10 T3 engineers;
   - T1 engineers 1–3 and 6–8 reclaim (trees, rocks, wrecks), 4–5 build the hydro, 9–10 help;
     then those four build 3 energy storages next to the hydro and go assist the ACU.
2. **After the opening**, every idle engineer takes the first task that fits: projects (experimentals, anti-nuke, shields, proxy) → own mex →
   power if short → the role's factories → reclaim → assist a factory or a build. Factories build from their role's `Production` table.
   T1 units are only built on a T1 factory and capped, so there is no T1 spam after the upgrade.
3. **Mexes:** each bot builds only its own (8 at base plus a zone: the upper and lower GROUND split the mid, NAVAL takes the underwater ones).
   A fallen player's mexes are split in half between the two nearest living allies.
4. **End of the T2 phase** is 10 minutes after the first T2 factory. GROUND and NAVAL ACUs go to maximum depth in the rear.
   If there are many torpedo bombers and little other air around, the ACU stays on land and builds in base.
   If there are many bombers, it hides at depth.

Start factories: GROUND — land, AIR — air, ECO and NAVAL — air (all factories build engineers in FAF).

## Scouting, endgame, army
- **Scouting.** Every factory's first unit is a scout, and each role keeps a stock of scouts all game (`Keep`).
  Planes fly over the enemy bases, the water and the front; land scouts stand ahead of the own wall.
  The bot only reacts to what the team has actually seen: a structure seen at least once, or a unit in sight or on radar.
- **Experimentals.** AIR — after 50 T3 fighters. GROUND — when its own mid is pushed (5+ own units there and no known enemy structures left)
  or an enemy experimental has been scouted. NAVAL — the same for the water. They are built on the map's "Protected Experimental Construction"
  markers next to the base; naval experimentals on the water. At the start of its strategic phase ECO randomly picks a game ender
  (T3 artillery, nuke, T4 artillery or T4 air) and keeps building it.
- **Responses to scouting.** Enemy nuke spotted → anti-nuke (one per group of three spawns, at the group's centre, built by ECO > NAVAL > AIR > GROUND;
  a second one at 2+ nukes). Without enemy nukes the anti-nuke goes up after the T2 phase ends. Enemy T3/T4 artillery spotted → 2 heavy shields per base (except GROUND).
  Bombers and air experimentals hit scouted game enders first, picking the one with the least AA around.
  Own nuke and anti-nuke missiles load automatically. Nukes hit scouted targets not covered by an enemy anti-nuke.
  Artillery picks scouted targets within its range on its own.
- **Mid.** Each GROUND fortifies the map author's defensive point in its zone. Short walls stand only in front of the point defences, so the gaps stay open.
  At T2 the ACU takes the engineering upgrade, builds a proxy base with T2 engineers (2 T2 shields and 3 T2 artillery ~100 from the enemy's mid defensive point)
  and holds the mid. Once the mid is pushed, the GROUND ACU goes to help the navy.
- **Army.** Units mass behind the own wall (waves of 10/16/20 by tech, an experimental counts as 10) and leave in formation (AttackFormation).
  If the enemy comes at the wall, they leave earlier. The fleet gathers at the naval rally point and sails in formation in groups of 6/8/10.
  If a clearly stronger fleet has been scouted ahead, it waits or falls back.
- **Air.** Patrols run along the front (north to south, on the own side). A point with a lot of scouted enemy AA steps back.
- **ACU underwater.** Helps a naval factory or an experimental under construction within 150 of its hiding spot.
- **Placement.** Structures keep 2-cell gaps, nothing is placed in front of factory exits,
  and power generators never go on a factory's exit side. This keeps units from getting stuck in the base.

## Files
| File | What it does |
|---|---|
| `lua/AI/DualGapBuildOrders.lua` | build orders and production tables: edit here |
| `lua/AI/DualGapConfig.lua` | coordinates, mex zones, threat thresholds, timings |
| `lua/AI/DualGapEngineers.lua` | ACU opening, T1 engineer roles, general engineer tasks, reclaim |
| `lua/AI/DualGapFactories.lua` | first factory opening, production, factory upgrades, T2 phase clock |
| `lua/AI/DualGapMexOwnership.lua` | mex ownership and splitting a fallen player's mexes |
| `lua/AI/DualGapACUBehaviors.lua` | overcharge; GROUND: own zone and fortifications; NAVAL: yards; water and threats |
| `lua/AI/DualGapArmy.lua` | massing and formations, waves, artillery, fleet, front patrols, air strikes |
| `lua/AI/DualGapEconomy.lua` | mex upgrades, RAS for ECO |
| `lua/AI/DualGapIntel.lua` | the team's shared scouting memory, scout control |
| `lua/AI/DualGapProjects.lua` | engineer crews: experimentals, ECO game ender, shared anti-nuke, shields, proxy base, nuke and artillery fire |
| `lua/AI/DualGapRoleManager.lua`, `DualGapRoutes.lua`, `DualGapUtils.lua`, `DualGapInit.lua` | roles, routes, utilities, startup |

## Differences from the original spec
- **The spec's role coordinates don't match the map layout.** The spec puts ECO deep in the rear centre, but the spawns form columns along the edges.
  So the role comes from the spawn's position within its team, not from fixed rectangles in 1024×1024 coordinates.
- The spec had bugs, now fixed: `platoon:GetGetCommander()` doesn't exist; `GetNumUnitsAroundPoint` without `'Enemy'` also counted own artillery;
  `ExecuteQueuedMovement` mutated the shared route table; the safety loop stopped after the first retreat.
- Going underwater (end of the T2 phase, low HP, enemy artillery or many bombers) applies to GROUND and NAVAL only. Per the spec, ECO and AIR never leave the base and fall back to the start on low HP.
- Builder files carry a `DualGap` prefix so the mod doesn't shadow FAF's stock files of the same name.

## What to check in game
The offline tests (`python tests/run_tests.py`) check syntax, Lua 5.0 compatibility, import paths and cross-module references.
They also check roles and mex ownership on the real map markers, the water decisions and production rules,
and run the whole opening in a small simulation. They don't run the engine itself. In a match, check:
- structure placement: a simple spiral around the base, with power next to the factory and storages next to the hydro;
- threat thresholds and production caps, which were chosen by eye;
- ground arcs and proxy bases: the mid defensive points and the naval rally come from the map markers, while the arcs and proxies were measured from a screenshot to within about 2–3% of the map size.
