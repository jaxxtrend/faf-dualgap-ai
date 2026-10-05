# DualGap AI (FAF, Dual Gap Adaptive v14)

**English** · [Русский](README.ru.md)

An AI whose role comes from its spawn point: `GROUND`, `NAVAL`, `AIR`, `ECO`.

## Install
1. Copy the `DualGapAI` folder to `%USERPROFILE%\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\`.
   The folder must be named exactly `DualGapAI`: FAF mounts the mod as `/mods/DualGapAI/`, and every import inside the mod uses that path.
2. In the FAF lobby, enable the **DualGap AI** mod and put **AI: DualGap (beta)** (or **AIx: DualGap (beta)**, the cheating version) in the AI slots.

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
   - first factory: 10 T1 engineers → T2 → 5 T2 engineers → T3 → 10 T3 engineers;
   - T1 engineers 1–3 and 6–8 reclaim (trees, rocks, wrecks), 4–5 build the hydro, 9–10 help;
     then those four build 3 energy storages next to the hydro and go assist the ACU.
2. **After the opening**, every idle engineer takes the first task that fits: urgent projects (anti-nuke) → with banked mass,
   more factories and assisting factory upgrades and busy factories → own mex (never one under a known enemy army) → power if short →
   other projects (shields, proxy, base anti-air, experimentals) → rebuild what the base lost → mass storages around T2 mexes →
   mass fabricators when energy overflows → the role's factories → reclaim (the base, then the own half of the mid when no known
   enemy army is there) → assist a factory or a build. An assist is dropped after 40 s and the engineer looks for work again;
   a project that finds no spot for its building gives up for a while and frees its crew.
   Factories build from their role's `Production` table. T1 units are only built on a T1 factory and capped, so there is no T1 spam after the upgrade.
3. **Grid.** Power generators go right next to air factories (the adjacency bonus cuts their energy cost), then next to mass fabricators,
   then next to other factories; T3 mass fabricators go next to T3 power. Every T2 mex gets 4 mass storages around it,
   and only then goes to T3. The T3 upgrades start once every base mex is T2 (mexes out of the base don't hold them back).
4. **Mexes:** each bot builds only its own (8 at base plus a zone: the upper and lower GROUND split the mid, NAVAL takes the underwater ones).
   A fallen player's mexes are split in half between the two nearest living allies.
5. **End of the T2 phase** is 10 minutes after the first T2 factory. GROUND and NAVAL ACUs go to maximum depth in the rear.
   If there are many torpedo bombers and little other air around, the ACU stays on land and builds in base.
   If there are many bombers, it hides at depth.

Start factories: GROUND — land, AIR — air, ECO and NAVAL — air (all factories build engineers in FAF).

## Scouting, endgame, army
- **Scouting.** No scouts before minute 10 (everyone knows the start positions). Scouting is AIR's job: it keeps 10 scouts
  and sends them in packs of 5 (10 after minute 25), at most one pack every 5 minutes - the bases are full of AA, single scouts die before they see anything.
  A pack flies over the enemy bases, their experimental build spots, the water, the enemy's deepest water and the front.
  NAVAL keeps 2 scouts circling over its leading ships to widen the fleet's sight. ECO builds 5 only when its game ender is
  75% done (or its air T4 is about to go in) and sends them over the enemy ECO base. GROUND builds none.
  A T3 air factory builds spy planes instead of T1 scouts.
  The bot only reacts to what the team has actually seen: a structure seen at least once, or a unit in sight, on radar or on sonar.
- **Team callouts.** Like human players, the bots ping the map and write in team chat: an enemy nuke or other game ender spotted
  (and whether it is still being built), an enemy experimental, "attacking the upper/lower mid", "enemy at my wall", "fleet moving out",
  "air strike going in here", "building anti-nuke here". The same callout repeats at most once a minute.
- **Experimentals.** AIR — after 50 T3 fighters. GROUND — when its own mid is pushed (5+ own units there and no known enemy structures left)
  or an enemy experimental has been scouted. NAVAL — the same for the water. Land experimentals go up in front of the base, toward
  the mid choke, so they can walk out; others on the map's "Protected Experimental Construction" markers next to the base; naval
  experimentals on the water. At the start of its strategic phase ECO randomly picks a game ender
  plan and builds it step by step like a player: usually one nuke silo first (its missile loads while the next device goes up),
  then 3 T3 artillery and a T4 artillery, or T4 air; "four nukes" is one rare all-in plan. A step counts as done once that many
  were built: shot-down air T4s don't send the plan back to them, it moves on; destroyed silos and artillery are rebuilt.
- **Responses to scouting.** Enemy nuke spotted → anti-nuke right away (one per group of three spawns, at the group's centre, started by the member with the most resources at that moment while the others' engineers help build it;
  a second one at 2+ nukes). Without enemy nukes the anti-nuke goes up after the first T3 power generator.
  The anti-nuke is first in the project queue, so ECO's game ender can't hold it up. Enemy T3/T4 artillery spotted → the heavy shield ring grows from 3 to 5.
  Bombers and air experimentals go for an enemy ACU on land first (assassination), then a game ender, then the enemy anti-nuke
  while the team owns a nuke, then T3 power generators and mass fabricators, then T2/T3 artillery, shields and factories - the one
  with the least AA around. They never bomb mexes or moving armies (they miss them). When their target dies, bombers go on to an
  ACU, game ender, T3 economy or experimental nearby (up to 3 times) instead of flying home over it.
  Bombers and torpedo bombers wait over the own base, behind the start (under its AA), not over the river. Gunships have their
  own job: an ally base calling for help, else known enemy army near the front or near the land wave that is out; with nothing
  to shoot they hover behind the front.
  Own nuke and anti-nuke missiles load automatically. Nukes are rare, so they go for the heart: the point with the most enemy mass in the blast,
  doubled near the enemy ECO base, plus game enders and an ACU on land. The bot hits that same point with every loaded missile (all loaded
  missiles land together) until 5 went in or the point is destroyed - an anti-nuke usually stops the first one or two. With known anti-nukes over the point it waits (up to 4 min) until one missile more than them is loaded and fires them together. A point that held
  out is skipped for 5 minutes and ECO builds T3 artillery to knock out the enemy anti-nukes. ECO's long-range guns prefer the enemy ECO base.
  Nuke silos pause loading while energy is short.
- **Helping allies, fortifying.** A base with a big enemy army at it calls for help: neighbours send their ready land units and
  fleets there and AIR its bombers at the attackers. A team down in players rings its bases with T2 point defences. The game
  swings instead of being decided by the first player lost.
- **Mass air attack.** AIR keeps its planes together (fighters on the patrol line) until it has ~140 aircraft - 250-300 for two AIR
  players - or 40 free bombers, then sends everything but a home guard at one strategic target (the bomber targets above).
  Fighters clear the sky, bombers and gunships follow right behind; the other AIR player joins the same target.
  Small bomber raids happen only early, before ~70 aircraft.
- **Navy helps the mid.** NAVAL sends its first 3 T2 destroyers and a cruiser to the water right below the lower mid choke;
  they patrol from there to the centre, shelling enemy land units at the shore for GROUND (5 destroyers, on to the water by
  the enemy mid, once the water is pushed).
- **Air T4 operation.** A finished own air experimental (Czar, Ahwassa, Soul Ripper) gathers at the air staging point for
  40 s while both AIR players send 80% of their free fighters and all free bombers to guard it. Then
  it goes for the enemy ECO's commander (on land; else the heart of the enemy ECO base) and the bombers dive in on the
  target once the T4 is within 140 of it. On the march the fighters are held on a screen 30 ahead of the T4 and the bombers
  20 behind it, renewed every 5 s: nobody races ahead, the escort meets enemy fighters and ground AA fire before the T4 does.
  The group flies round the map edge, not over the mid and its AA (routes drawn by a player): to an upper base along the
  north edge, to a lower base along the south edge under the basin, turning up into the base from below. Novax satellites also go for the enemy ECO commander first when it is seen and unshielded.
- **Base layout like a player's.** The first factory goes against the base's hydrocarbon spot; an air factory gets power on
  every side (aircraft need no exit lane); generators are placed against factories, shields, nukes / artillery / anti-nukes,
  mass fabricators, else against other generators - one compact block; no new T1 generators once T2/T3 engineers exist; the
  mex storage crosses get T2 mass fabricators in their corners once T3 power is up; resource spots stay free.
  The base is laid out in zones: the mex blocks (3 around every mass spot) take only the mex, storages and T2 fabs; T1 power
  goes only against factories; T2/T3 power against game enders, anti-nukes and gates first, then factories, shields, T3 fabs,
  then the power block; game enders (artillery, nukes, Mavor) go against the T3 power block or another game ender, so their
  power wraps around them; shields stand against a generator or factory at their ring point; new air factories go against a
  generator by the factories (or another air factory): factories and power make one block.
- **Adaptive roles.** A defeated player's role passes to the ally that took over its mexes (the nearest one), on top of its own,
  and on down the line: whoever took over ECO enters the strategic phase and builds the game ender, a NAVAL heir builds yards
  and the navy's ships and keeps destroyers at the mid, an AIR heir runs the air attacks, the T4 escort and the base AA. The
  heir says so in team chat. Enemy ECO targets (nukes, ECO's guns, the air T4 operation) follow the enemy ECO role the same way.
- **Everyone on a game ender.** A scouted enemy game ender is the whole team's target: AIR strikes it once 30+ planes are home and free, land waves
  leave with a smaller size (fleets at full size) and take the less defended mid lane to it, fleets sail to the water next to it, nukes and artillery
  already put it first.
- **Banked mass gets spent.** With mass storage 60%+ full, a bot builds more structures at once, factories go over their unit caps,
  more T3 engineers are kept, and 3 to 8 more production factories go up (one more per 100 mass/s of income); idle engineers
  assist the busy factories (up to 4 each) and the experimental under construction gets a full crew.
  Up to 2 factory upgrades run at once (4 with banked mass) and idle engineers assist them; a factory behind its HQ keeps producing
  until it is picked for its upgrade. New factories are built straight as T2/T3 support factories once the HQ has that tech.
  Enemy Yolona Oss spotted → every base stacks 6 anti-nukes, and idle engineers assist them so interceptors load faster.
  Artillery (T2 at the proxy, T3, T4) and Novax satellites (anywhere on the map) pick targets by priority: game enders (T3/T4 artillery, nukes, Yolona Oss, Paragon, the Novax satellite centre and any other experimental structure) → the enemy anti-nuke while we own a nuke →
  the ACU if it is in sight, not underwater and not under a shield → T3 mexes → T3 power → factories. Long-range guns (T3/T4 artillery,
  satellites) don't waste shells on T1/T2 mexes; the T2 proxy artillery does hit them. Structures are hit by ground fire on their spot,
  so a structure seen earlier is still hit; a T2 gun with an enemy army in range and nothing better than eco to shoot fires on its own
  at the army.
  A target under enemy shields that are up is worth 1 + 2×(shields) times less, so the guns hit something unshielded instead of pounding a shield.
  Targets are re-picked every 10 seconds, so an ACU walking into range becomes the target at once.
- **Radar and sonar.** Every base gets a radar toward the enemy, upgraded to T2 at T2 and to Omni at T3 when the economy allows.
  GROUND also puts a forward radar behind its mid defensive point, NAVAL a sonar next to its yard (upgraded to T2). Lost ones are rebuilt.
- **Base shields.** Every base gets two T2 shields over its core at T2 and a ring of 3 heavy shields at T3 (5 once enemy artillery is scouted).
  Lost shields are rebuilt; shields climb their upgrade chain when the economy allows.
- **Realistic building.** A bot has at most 3 new structures going up at a time (an expensive one counts double; mexes and storages
  are free, power is free while energy is nearly gone, the anti-nuke always may start). Other engineers assist what is being built.
- **Base upkeep.** Every structure near the start is remembered by its spot; when one is destroyed, an engineer rebuilds it there
  (an upgraded one from the bottom of its chain). Mexes, factories, AA, shields, anti-nuke and artillery are rebuilt by their own planners.
- **Base anti-air** is the AIR player's job: it builds it around every base of its group of three (its own first) - one T1 AA from the
  start, three T2 flak at T2 and a full ring of 8 T3 SAMs at T3 at its own base (1 / 2 / 4 at the allies' bases), and rebuilds lost ones. No other role builds base AA
  (with a human AIR player, the human does). Once the AIR player is out of the game, the ally that took over its mexes takes over
  the base AA of the group (and so on down the line).
- **Mid.** Each GROUND fortifies the map author's defensive point in its zone. Short walls stand only in front of the point defences, so the gaps stay open.
  At T2 the ACU takes the engineering upgrade, builds a proxy base with T2 engineers (2 T2 shields and 3 T2 artillery ~100 from the enemy's mid defensive point)
  and holds the mid. Once the mid is pushed, the GROUND ACU goes to help the navy.
- **Army.** Units mass behind the own wall (waves of 10/16/20 by tech, an experimental counts as 10) and leave in formation (AttackFormation);
  a big army counts as gathered around the rally point, so it leaves with everything. If the enemy comes at the wall, they leave earlier.
  A wave goes through the enemy mid to its bases; with nothing scouted it walks on (enemy mid, its base, the other bases) and it never
  turns back for a target behind it. A wave that stands still with no enemy around walks on without the formation.
  The fleet gathers at the naval rally point and sails in formation in groups of 6/8/10. If a clearly stronger fleet has been scouted
  ahead, it waits or falls back, and after falling back it sails again only 1.2× stronger than what it ran from.
  Experimentals don't walk inside the wave: each keeps 40 from the wave and from the other experimentals, so a dying one doesn't kill its neighbours.
- **Forward bases.** After the first T2 factory GROUND puts 2 land factories 40 behind its mid point and NAVAL 2 naval yards
  on the water short of the naval rally point, so new units reach the front sooner. Lost ones are rebuilt.
- **Experimentals with an escort.** A wave with a T4 leaves only with at least 8 other units. Another T4 gets a full engineer crew only
  while there are 15 T3 units (land for GROUND, ships for NAVAL) per T4 alive or mass is banked; otherwise one engineer builds it slowly
  and the economy goes to the factories.
- **Air.** Patrols run along the front (north to south, on the own side). The upper half of the team (including the upper AIR player) patrols the upper part of the front,
  the lower half the lower part; the two stretches overlap a little in the middle. A point with a lot of scouted enemy AA steps back.
  The lines follow the ridges behind the own mid (about a quarter of the map from the own edge), well back from the centre.
  Known enemy aircraft behind the front, in the player's own stretch, are intercepted by the nearest fighters (at least 4, 2 per enemy), which then return to the patrol.
  Fighters also cover the mid: enemy planes over the own half near allied units (GROUND waves, NAVAL ships, mid defences) are
  intercepted too, 3 fighters per bomber, gunship or air T4. An enemy air experimental anywhere in the own half is handled first and
  gets every free fighter (up to 80), counting only the fighters sent at the T4 itself, so its escort can't soak them up.
  With 25+ free fighters and 1.5× the known enemy fighters, AIR sweeps the enemy's side of the front for 90 s.
  An enemy land or sea experimental in the own half gets an immediate bomber strike with an escort (torpedo bombers join against a ship).
  Bombers mass at the staging point. On a strike the escort fighters leave first (1.2× the known enemy fighters at the target and on the way)
  and tie up the enemy fighter wall on the direct line. The bombers leave 6 seconds later on a flank route, on the side with less AA.
  The strike waits only while the free escort is below 0.8× the known enemy fighters. Air experimentals pick different targets so they don't crash onto each other.
- **Hidden ACUs.** An ACU hides in the deepest water of its own base (within 130 of its start, under the team's anti-nuke and
  fleet), never out in the central basin. Hidden ACUs may stand close, 30 apart. Only when an enemy nuke has been launched
  (the public "strategic launch detected" announcement, no target) and no loaded own anti-nuke covers them, they spread out to 70
  so one missile can't catch two. Torpedo bombers with nothing to strike patrol over the team's hidden ACUs, up to 4 per ACU from each bot.
- **Base ACUs (AIR / ECO).** On an enemy nuke launch with no loaded anti-nuke over the base, the ACU steps out of the dense base to its
  least built-up edge until the missile has landed. A known enemy air experimental within 220 sends it to the best-defended spot of
  the base (T3 SAMs, shields) until the T4 is gone.
- **Defence follows the front.** Every base with water nearby gets 3 torpedo launchers there. Once GROUND has pushed its mid it fortifies
  the enemy mid point (T2 point defence, AA, shield) and its waves gather there; 4 minutes later it sets up a siege camp 100 from the enemy
  base (shields, 4 T2 artillery, AA). NAVAL puts torpedo launchers at the enemy naval rally once the water is pushed. Lost pieces are rebuilt.
- **Bombers vs AA.** A bomber group may fly into more known AA the bigger it is (AA limit + size / 2), so it no longer circles at home
  waiting for an undefended target.
- **Hunting a hidden ACU.** An enemy ACU seen under water is remembered at its last spot for 5 minutes. Meanwhile AIR, ECO and NAVAL
  build torpedo bombers (on any air factory tech), NAVAL and GROUND build subs, torpedo bombers and fleets go for it in groups of two or more,
  and GROUND builds 2 naval yards to help the navy (also once its mid is pushed).
- **Search.** If the team has known nothing about the enemy for 90 seconds (usually the last ACU hiding underwater), search mode starts:
  torpedo bombers and spy planes with sonar sweep the enemy's deepest water, fleets sail there even two ships at a time,
  land waves walk the enemy bases. Torpedo bombers attack a submerged ACU once it is found.
- **ACU underwater.** A known enemy land experimental near the GROUND / NAVAL ACU sends it underwater, where land T4s can't hurt it.
  Underwater only warships are a danger: a known fleet close by makes it move to another deep spot in its own water (or home).
  While hiding it builds 2 torpedo launchers around the spot and 2 T3 SAMs on the nearest shore, then helps a naval yard
  (never a carrier) or an experimental under construction within 150 of the spot. An ACU that stayed on land for torpedo
  bombers keeps to it for a minute. The ACU reacts only to enemy air and artillery it can see.
- **Placement.** Building sizes come from the skirt (8 cells for a factory, not the 5-cell footprint), so grid buildings really touch.
  Other structures keep 2-cell gaps, nothing is placed in front of factory exits,
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
| `lua/AI/DualGapIntel.lua` | the team's shared scouting memory, scout control, search mode when the enemy is lost |
| `lua/AI/DualGapComms.lua` | team pings and team chat callouts |
| `lua/AI/DualGapProjects.lua` | engineer crews: experimentals, ECO game ender, shared anti-nuke, shields, proxy base, base anti-air, nuke, artillery and satellite targeting |
| `lua/AI/DualGapRoleManager.lua`, `DualGapRoutes.lua`, `DualGapUtils.lua`, `DualGapInit.lua` | roles, routes, utilities, startup |

## Differences from the original spec
- **The spec's role coordinates don't match the map layout.** The spec puts ECO deep in the rear centre, but the spawns form columns along the edges.
  So the role comes from the spawn's position within its team, not from fixed rectangles in 1024×1024 coordinates.
- The spec had bugs, now fixed: `platoon:GetGetCommander()` doesn't exist; `GetNumUnitsAroundPoint` without `'Enemy'` also counted own artillery;
  `ExecuteQueuedMovement` mutated the shared route table; the safety loop stopped after the first retreat.
- Going underwater (end of the T2 phase, low HP, enemy artillery or many bombers) applies to GROUND and NAVAL only. Per the spec, ECO and AIR never leave the base and fall back to the start on low HP; inside the base they only move to dodge a nuke or an air T4.
- Builder files carry a `DualGap` prefix so the mod doesn't shadow FAF's stock files of the same name.

## What to check in game
The offline tests (`python tests/run_tests.py`) check syntax, Lua 5.0 compatibility, import paths and cross-module references.
They also check roles and mex ownership on the real map markers, the water decisions and production rules,
and run the whole opening in a small simulation. They don't run the engine itself. In a match, check:
- structure placement: a simple spiral around the base, with power next to the factory and storages next to the hydro;
- threat thresholds and production caps, which were chosen by eye;
- ground arcs and proxy bases: the mid defensive points and the naval rally come from the map markers, while the arcs and proxies were measured from a screenshot to within about 2–3% of the map size.
