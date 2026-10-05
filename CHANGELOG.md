# Changelog

## v2 — `faf-v1` → `faf-v2`

Version 2 of DualGap AI (mod_info `version = 2`, uid
`417a9232-d0c8-4914-8381-60fa52118f40`). 57 commits, built from rounds of
real 12-bot matches: play, read the bots' decision log, fix, repeat.

### Team play and roles
- **Adaptive roles.** When a player is defeated, its heir (the ally that takes
  over its mexes) also takes over its duties: game ender, navy, air, base
  anti-air. Enemy ECO targets follow the role to its new holder.
- **Help calls.** A base under attack calls for help; land waves, fleets and
  bombers of nearby allies answer it.
- **Base anti-air is AIR's job** for its whole group of three bases (smaller
  rings at the allies' bases). If the AIR player is out, its heir takes it over.
- **Group anti-nuke.** It is started by the member with the most resources;
  the others assist it.
- **Outnumbered team fortifies.** A team with fewer players left builds a ring
  of T2 point defences.
- **Callouts.** One callout per enemy T4 type; the stock distress thread no
  longer grabs DualGap units.

### Game enders
- **Game ender plans like a player's.** ECO picks a random plan and builds it
  step by step: usually one nuke silo first, then artillery or a T4. Four
  nukes is a rare option.
- **Plans move on.** Air T4s count as built even when they are shot down, so
  the plan goes on to nukes and artillery instead of rebuilding them forever.
  Destroyed silos and artillery are rebuilt.
- **Nukes.**
  - Salvos are sized to saturate the known anti-nukes.
  - Nukes go for the heart of the economy and keep hitting one point; without
    targets they fall back to an enemy base with no anti-nuke.
  - Silos pause loading on low energy.
  - Reaction to Yolona Oss.
- **Artillery** names Yolona Oss and Paragon as targets; Novax satellites hit
  the enemy ECO commander first.
- **Whole team on enemy game enders.** Air strikes them, land waves leave
  early through the weaker mid lane, fleets sail to the water next to them.

### Air
- **Bomber targets:** enemy ACU on land (assassination) > game ender >
  anti-nuke (when we own a nuke) > T3 power and mass fabricators > T2/T3
  artillery, shields and factories. No more bombing mexes or moving armies.
- **Mass attacks.** The air force goes in as one strike under fighter cover:
  from 140 free planes, or 40 free bombers, or 30 planes on a game ender.
- **Follow-ups.** When their target dies, bombers go on to an ACU, game ender,
  T3 economy or T4 nearby instead of flying home over it.
- **Air T4 operations.** A Czar / Ahwassa / Soul Ripper gathers an escort,
  flies the map-edge routes at its own pace (fighters ahead, bombers tucked
  behind) and goes for the enemy ECO commander; bombers dive in with it.
- **Fighters.**
  - Patrol lines along the ridges behind the own mid; they cover the mid.
  - Sweep the enemy front when they clearly outnumber its fighters.
  - Enemy air T4s are intercepted first, by every free fighter, wherever they
    are in our half; their escort no longer soaks up the interceptors.
- **Defence against T4s.** Bombers strike enemy T4s (land and sea) in our half.
- **Gunships** fight armies at the front, follow the land wave and help
  allies; they hover behind the front instead of flying home.
- **Scouting.** No scouts before minute 10.
  - AIR scouts in packs of 5–10, at most one pack every 5 minutes.
  - NAVAL scouts circle over its own ships.
  - ECO scouts only just before its game ender attack.
  - GROUND builds none.
- **Parking.** Planes wait over their own base, not over the river.

### Land
- **Waves push.** They go through the mid to the enemy bases and walk on when
  nothing is scouted. They never turn back for targets behind them.
- **Gathering.** A big army counts as gathered around the rally point, so
  waves leave with everything instead of 20 at a time.
- **Stuck waves** (no progress, no enemy around) walk on without the formation.
- **Forward factories** for GROUND and NAVAL; generators no longer wall off the
  mid lane around them.
- **Land experimentals.** They are built in front of the base so they can walk
  out, and go with a T3 escort.
- **Siege.** A moving front and a siege camp.

### Navy
- **Mid support.** NAVAL sends T2 destroyers and a cruiser to the water below
  the mid to help GROUND.
- **Regrouping.** A fleet that fell back waits until it is clearly stronger
  than what it ran from; no more sailing out again with one more ship.
- **Big fleets** count as gathered; fleets attack game enders at full size.
- **Hunting submerged ACUs.**
  - Torpedo bombers, subs and GROUND yards hunt them.
  - Hunt mode starts only for a really hiding ACU (rear, deep, a minute under).
  - Lost enemy ACUs are searched from clues: their last spot, shore structures,
    deep water.

### Commanders
- **Hiding spot.** Hidden ACUs stay in their own base's water, under the
  team's anti-nuke and fleet, never out in the central basin. They may stand
  close together (not on one spot).
- **Nuke launch, hidden ACUs.** They spread out only while an enemy nuke is in
  the air and no loaded anti-nuke covers them. The launch is taken from the
  public "strategic launch detected" announcement (hook on
  `Unit.NukeCreatedAtUnit`), never the target.
- **Nuke launch, base ACUs.** AIR and ECO ACUs step out of the dense base to
  its least built-up edge under the same condition.
- **Enemy air experimental.** AIR and ECO ACUs take refuge at the best-defended
  spot of the base (T3 AA, shields).
- **Threats seen only.** ACUs react only to enemy air and artillery they can
  see: no peeking into the fog.
- **Fixes.**
  - An ACU no longer follows its own carrier into battle.
  - An ACU no longer flips between land and water under torpedo bombers.
  - An ACU moves away from an enemy fleet with a cooldown.
- **Torpedo cover.** Torpedo guards and base torpedo launchers protect hiding
  ACUs.

### Base and economy
- **Player-like layout.**
  - The first factory goes against the hydrocarbon plant.
  - Power is built in tight adjacency blocks.
  - Mex blocks are reserved: storage crosses around mexes, T2 fabricators in
    their corners.
  - Game enders and shields stand against the power block; new air factories
    join the factory/power block.
- **Power.** T1 power only around the base factories and only while no T2/T3
  engineer is free; T2/T3 power goes next to the game enders first.
- **Mex upgrades.** Base mexes go T2, get their storages, then T3. Contested
  mexes out of the base don't hold it back; two T2 upgrades at once with
  banked mass.
- **Spending the income.**
  - Extra production factories grow with mass income (3–8).
  - Idle engineers assist busy factories and factory upgrades; parallel
    factory upgrades.
  - Banked mass lifts the experimental throttle.
- **Factories.**
  - Lagging factories keep producing until they are picked for an upgrade.
  - Upgrades also run during the opening, on spare income.
  - Support factories are built straight at HQ tech.
- **Engineers.**
  - They skip mexes under a known enemy army.
  - They drop an assist after 40 s and look for work again.
  - Dropped projects release their crews' orders.
  - Projects with no spot for their building give up.
- **Other structures.** Radars and sonars; base shields for every role; lost
  base structures are rebuilt; T3 AA rings by tech.

### Tools
- **DGSTAT telemetry** for all armies (snapshots, layout, builds, moves,
  defeats, waves).
- **Match tools:** `tools/parse_match.py`, `tools/draw_match.py`,
  `tools/batch_report.py`, `tools/draw_base.py` (base layout and adjacency
  report), `analyze.cmd`.

### Release
- **Cleanup.** Dead code removed (old game ender caps, unused helpers, builder
  conditions and config keys).
- **Mod info.** `mod_info.lua` version 2, new uid; author `jaxxtrend`.
