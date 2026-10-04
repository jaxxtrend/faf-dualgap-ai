-- All tunables for DualGap AI in one place.
--
-- Coordinates are NORMALISED (0..1 of LayoutRect, x left->right, z top->bottom)
-- and written for the LEFT team. Right-team values are produced by mirroring x
-- (x -> 1 - x), since the map is left/right symmetric.
-- Spawn anchors come from the map's ARMY_n markers; routes were measured from
-- the annotated overview (which shows exactly AREA_1).

Roles = {
    GROUND = 'GROUND',
    NAVAL  = 'NAVAL',
    AIR    = 'AIR',
    ECO    = 'ECO',
}

-- Map detection: the map name or path must contain all of these (lower case).
MapNameTokens = { 'dual', 'gap' }
-- Set true to use the Dual Gap layout on any map (testing on renamed copies).
ForceDualGapLayout = false

-- Fixed rectangle the layout is normalised against: the map's starting
-- playable area AREA_1 (x0, z0, x1, z1). Dual Gap Adaptive later grows the
-- playable area (AREA_4 ...), so the live PlayableArea must NOT be used here.
LayoutRect = { 0, 200.5, 1024, 830.5 }

-- Spawn slots of one team, sorted top -> bottom (by z). When a team has exactly
-- this many start markers the role is taken by rank, which is robust to small
-- scale errors. Otherwise the nearest Anchor wins.
SpawnSlots = {
    { role = 'AIR',    anchor = { 0.110, 0.302 } }, -- ARMY_1 / ARMY_2   (red A)
    { role = 'GROUND', anchor = { 0.136, 0.375 } }, -- ARMY_9 / ARMY_10  (orange G)
    { role = 'GROUND', anchor = { 0.180, 0.422 } }, -- ARMY_3 / ARMY_4   (orange G)
    { role = 'NAVAL',  anchor = { 0.156, 0.649 } }, -- ARMY_5 / ARMY_6   (blue N)
    { role = 'ECO',    anchor = { 0.112, 0.697 } }, -- ARMY_11 / ARMY_12 (green E)
    { role = 'AIR',    anchor = { 0.145, 0.763 } }, -- ARMY_7 / ARMY_8   (red A)
}

-- Force a role for a given army name, e.g. { ARMY_3 = 'ECO' }.
RoleOverrides = {}

-- Role for non-Dual Gap maps.
FallbackRole = 'GROUND'

-- Routes (left team, normalised). The last waypoint is an attack-move.
Routes = {
    -- North arc out of the gap, over the central land mass (upper orange arrow).
    GroundArcNorth = {
        { 0.200, 0.410 }, { 0.250, 0.395 }, { 0.330, 0.335 }, { 0.436, 0.311 }, { 0.500, 0.310 },
    },
    -- Flatter arc along the river bank (lower orange arrow).
    GroundArcSouth = {
        { 0.200, 0.410 }, { 0.270, 0.430 }, { 0.360, 0.440 }, { 0.447, 0.433 }, { 0.500, 0.430 },
    },
    -- Coast -> underwater mexes -> central basin (blue arrow).
    NavalVector = {
        { 0.190, 0.590 }, { 0.260, 0.570 }, { 0.330, 0.610 }, { 0.360, 0.665 }, { 0.405, 0.750 }, { 0.495, 0.705 },
    },
}

-- Mex ownership (DualGapMexOwnership). Base mexes: within BaseRadius of a
-- spawn. Land mexes with MidBand[1] <= nx <= MidBand[2] belong to the side's
-- GROUND players: above MidSplitZ to the upper one (slot rank 2), below to
-- the lower one (rank 3). Underwater mexes belong to the side's NAVAL player.
-- Anything else goes to the nearest spawn of the same side.
BaseRadius = 50
MidBand    = { 0.30, 0.70 }
MidSplitZ  = 0.40

Points = {
    -- Each GROUND player holds its own zone (upper / lower mid mex group).
    -- These are the map author's 'Defensive Point' markers in the mid.
    ChokeUpper    = { 0.436, 0.311 },  -- (446.5, 396.5)
    ChokeLower    = { 0.447, 0.433 },  -- (457.5, 473.5)
    -- Proxy bases (T2 shields + T2 artillery, range 115): ~100 from the
    -- enemy's mid defensive point, so the artillery reaches it.
    ProxyUpper    = { 0.464, 0.317 },  -- (475, 400)
    ProxyLower    = { 0.469, 0.434 },  -- (480, 474)
    -- Fleet gathering point: the map's 'Naval Rally Point'.
    NavalRally    = { 0.367, 0.670 },  -- (375.5, 622.5)
    Choke         = { 0.380, 0.370 }, -- fallback for non-ranked spawns
    ArtyStaging   = { 0.320, 0.385 }, -- fallback; normally 40 behind own choke
    NavalYardHint = { 0.200, 0.600 }, -- search for coastal water from here
    AirStaging    = { 0.100, 0.500 }, -- over the own-side river
    BasinCenter   = { 0.500, 0.720 },
    LandCenter    = { 0.500, 0.360 },
}

-- Air patrols fly ALONG the front (north-south), on the own side of it.
-- AirFrontX is the normal line; each point steps back by AirFrontStep (up
-- to AirFrontMaxSteps times) while known enemy AA near it reaches AAThreat.
-- The upper half of a team (slots 1-3, incl. the upper AIR player) patrols
-- AirFrontZTop, the lower half AirFrontZBottom; they overlap in the middle.
-- AirFrontZ is the whole line, for spawns without a slot.
AirFrontX         = 0.42
AirFrontZ         = { 0.26, 0.36, 0.46, 0.58, 0.70, 0.80 }
AirFrontZTop      = { 0.26, 0.36, 0.46, 0.58 }
AirFrontZBottom   = { 0.46, 0.58, 0.70, 0.80 }
AirFrontStep      = 0.04
AirFrontMaxSteps  = 4
AAThreat          = 6      -- known enemy AA units within AARadius
AARadius          = 70

-- Massing: units gather behind their own wall until the wave is this big
-- (by the player's highest factory tech), or until the enemy comes close.
WaveSize = { 10, 16, 20 }
NavalFleetSize = { 6, 8, 10 }
-- An experimental counts as this many units toward a wave.
ExperimentalWaveWeight = 10

-- Experimental (T4) phase, non-ECO roles.
AirT4MinFighters  = 50     -- T3 air superiority fighters alive
PushCheckRadius   = 80     -- "pushed" = no known enemy structures there and
PushOwnUnits      = 5      --            at least this many own units there

-- Scouting: units kept alive per role (any factory tech), see BuildOrders.Keep.
ScoutRepathSeconds = 60

-- Behaviour numbers.
-- End of the T2 phase: this long after this player's first T2 factory.
T2PhaseLength          = 600
-- Enemy air near the ACU (radius AirThreatRadius) after the T2 phase:
--   >= BomberThreat bombers/gunships          -> hide at max depth in the rear
--   >= TorpThreat torpedo bombers, < FewAir other aircraft -> stay on land and build
AirThreatRadius        = 200
BomberThreat           = 8
TorpThreat             = 6
FewAir                 = 4
-- Reclaim: engineers look for props within this radius of the base.
ReclaimRadius          = 120
ReclaimMinValue        = 10     -- ignore clusters worth less (mass + energy/10)
OverchargeRange        = 25
OverchargeEnergyRatio  = 0.3
ACURetreatHealth       = 0.35
StratArtyScanRadius    = 1000
DeepWaterDepth         = 3

GroundWaveSize   = 8
ArtyWaveSize     = 6
NavalWaveSize    = 5
AirStrikeSize    = 8
EcoStrategicMassIncome = 100    -- mass/sec before ECO goes all-in on T3/T4
EcoStrategicShare      = 0.8    -- share of engineers sent to strategic builds
MaxConcurrentUpgrades  = 3

-- Experimentals walk apart: a dying T4 explodes and hurts whatever stands
-- next to it. Each one keeps this distance from the wave and from the others.
T4Spacing = 40

-- Mid reclaim: engineers also reclaim wrecks in the own half of the mid
-- (both mid defensive points of the side), if a cell there is worth at least
-- MidReclaimMinValue and no known enemy army stands within MidReclaimSafeRadius.
MidReclaimRadius     = 70
MidReclaimMinValue   = 80
MidReclaimSafeRadius = 50

-- Fighters leave the front patrol to intercept known enemy aircraft behind
-- the front line: at least InterceptMin fighters, InterceptPerEnemy per enemy.
InterceptMin       = 4
InterceptPerEnemy  = 2
InterceptSeconds   = 30

-- Bomber strikes: fighters escort them and engage the enemy fighters on the
-- direct line, the bombers fly a flank route (BomberFlankShare of the strike
-- distance to the side) and leave BomberDelay seconds after the escort.
-- The escort is EscortRatio x the known enemy fighters around the target
-- and on the way; a strike waits only while fewer than EscortLaunchRatio x
-- that many fighters are free (people go in at rough parity too).
EscortRatio        = 1.2
EscortLaunchRatio  = 0.8
EscortIgnore       = 2      -- this few known enemy fighters: go even without an escort
EscortMin          = 4
BomberFlankShare   = 0.35
BomberDelay        = 6
StrikeTimeout      = 150

-- Anti-air around each base, by the player's top factory tech: one T1 AA
-- from the start, three T2 flak at T2, a full ring of T3 SAMs at T3.
-- Points sit on a circle around the start (the first one toward the
-- enemy); lost ones are rebuilt.
BaseAA = {
    { count = 1, radius = 18 },
    { count = 3, radius = 28 },
    { count = 8, radius = 40 },
}

-- Engineers and the economy. The opening roles of the first T1 engineers
-- are temporary: reclaimers turn into general engineers ReclaimRoleSeconds
-- after they appear (at once when energy runs dry), ACU assistants once the
-- ACU's opening is done or it leaves the base. Energy below EnergyStall
-- (stored share) makes power every engineer's first job. Projects other
-- than the top priority (anti-nuke) hold at most ProjectCrewShare of the
-- engineers, and only after own mexes and power are taken care of.
ReclaimRoleSeconds = 240
EnergyStall        = 0.1
ProjectCrewShare   = 0.5

-- Hidden ACUs keep HideSpacing apart (one nuke must not catch two), and
-- each gets up to TorpGuardsPerACU of its team's torpedo bombers patrolling
-- over it (from every bot that has them) when they have nothing to strike.
HideSpacing      = 150
TorpGuardsPerACU = 4

-- Bombers go for the target with the least known AA; a group may accept
-- AAThreat + its size / BomberAAPerUnit known AA units at the target, so a
-- big group doesn't wait forever for an undefended target.
BomberAAPerUnit = 2

-- Base torpedo defence: a base with water within BaseTorpedoRange gets
-- BaseTorpedoes torpedo launchers there (T2 once the player has T2).
BaseTorpedoRange = 100
BaseTorpedoes    = 3

-- The defence moves with the front. GROUND: once its mid is pushed, a
-- forward line (T2 point defence, AA, shield) at the enemy's mid point;
-- SiegeDelay seconds later a siege camp SiegeDistance from the enemy base
-- (shields, T2 artillery, AA). Waves gather behind the furthest line.
-- NAVAL: once the water is pushed, torpedo launchers at the enemy's naval
-- rally point. Lost pieces are rebuilt.
SiegeDelay    = 240
SiegeDistance = 100

-- Forward production. After the first T2 factory GROUND puts
-- ForwardFactories land factories ForwardLandBack behind its mid point, and
-- NAVAL puts ForwardFactories naval yards on the water ForwardNavalBack
-- short of the naval rally point, so new units reach the front sooner.
-- Lost ones are rebuilt; they upgrade like other support factories.
ForwardFactories = 2
ForwardLandBack  = 40
ForwardNavalBack = 40

-- Experimentals never go alone: a wave with a T4 leaves only with at least
-- T4EscortMin other units, and another T4 gets a full engineer crew only
-- while the player has T3PerT4 T3 combat units (land for GROUND, ships for
-- NAVAL) per T4 alive; otherwise one engineer keeps it going slowly and the
-- economy stays with the factories.
T4EscortMin = 8
T3PerT4     = 15

-- Intel structures. Every base: a radar BaseRadarRadius toward the enemy,
-- upgraded to T2 at T2 and to Omni at T3 (when the economy allows). GROUND:
-- a forward radar MidRadarBack behind its mid defensive point. NAVAL: a
-- sonar next to its yard, upgraded to T2 at T2. Lost ones are rebuilt.
BaseRadarRadius = 22
MidRadarBack    = 15

-- Shields over the base core (factories and power), every role: at T2 two
-- T2 shields, at T3 a ring of heavy shields (more once enemy T3/T4
-- artillery is scouted). Lost ones are rebuilt; shields also climb their
-- upgrade chain when the economy allows.
BaseShields = {
    [2] = { count = 2, radius = 8 },
    [3] = { count = 3, radius = 14 },
}
BaseShieldsVsArty = { count = 5, radius = 16 }

-- Base upkeep: structures within UpkeepRadius of the start are remembered
-- and rebuilt on the same spot when destroyed (DualGapEngineers).
UpkeepRadius = 90

-- Mex storages: four mass storages around every own mex once it is T2; a
-- mex only goes to T3 when no free storage spot is left around it.
-- Mass fabricators (T3) go next to T3 power when energy overflows.
MassFabEnergySurplus = 1500     -- energy/s trend needed before a fabricator

-- Stalemate: if the team has known nothing about the enemy (no structure,
-- no unit) for this long, it starts searching the enemy's deep water.
StaleSeconds = 90
-- An enemy ACU seen under water is hunted at its last known spot this long.
SubACUMemory = 300
-- Lost ACU: an enemy player is still in the game (the scoreboard shows it)
-- but almost nothing of theirs is left (at most ACULostMaxStructures known
-- structures, walls aside) and their ACU has not been seen for
-- ACULostSeconds (and the game is past ACULostMinTime). The team hunts it:
-- last seen spot, their structures by the water (guards of a hiding spot),
-- then the enemy's deep water spots one after another.
ACULostSeconds       = 120
ACULostMinTime       = 900
ACULostMaxStructures = 6

-- Game enders ECO keeps building, at most this many of a kind alive
-- (nil = no limit).
GameEnderMax = { NukeSilo = 4, StratArtyT3 = 4, ArtilleryT4 = 2 }
-- When ECO has built the cap of its game ender it switches to the next one
-- it can build, in this order: artillery knocks out the enemy anti-nukes,
-- then the nukes finish the job.
GameEnderNext = { 'StratArtyT3', 'ArtilleryT4', 'NukeSilo', 'AirT4' }

-- Mass air attack. AIR keeps its planes together until it has AirMassSize
-- aircraft (two AIR players: 250-300 for the team), then sends everything
-- but AirMassHomeShare of the fighters at one strategic target: the
-- fighters clear the sky, the bombers follow right behind them. The other
-- AIR player joins the same target if it has AirMassJoinShare of that.
-- An enemy game ender is everyone's target: AIR goes for it as soon as it
-- has AirEnderStrikeMin aircraft, land waves and fleets head there too.
AirMassSize        = 140
AirMassHomeShare   = 0.15
AirMassJoinShare   = 0.5
AirMassCooldown    = 180
AirEnderStrikeMin  = 40
AirMassTimeout     = 240
-- Small bomber raids only while AIR has fewer than this many aircraft;
-- after that the bombers are kept for the mass attack.
AirRaidMaxAir      = 70
-- Land waves leave with this share of the usual size when an enemy game
-- ender is known (everybody piles on it).
EnderWaveShare     = 0.6

-- Banked mass: with the mass storage at least MassBankedRatio full, a
-- player builds BankedExtraBuilds more structures at once, factories may
-- go BankedCapMul x over their unit caps and BankedExtraEngineers more T3
-- engineers are kept: nobody sits on full storage.
MassBankedRatio      = 0.6
BankedExtraBuilds    = 3
BankedCapMul         = 2
BankedExtraEngineers = 6

-- Nuke silos stop loading missiles while energy is short (a silo that
-- already holds a missile pauses below SiloPauseEnergy stored, resumes
-- above SiloResumeEnergy).
SiloPauseEnergy  = 0.1
SiloResumeEnergy = 0.4

-- Nukes are rare: they go for the heart of the enemy. The bot picks one
-- point - the most enemy mass within NukeRadius, doubled near the enemy ECO
-- base, plus game enders and an ACU on land - and keeps hitting that point
-- with every loaded missile (an anti-nuke usually stops the first one or
-- two) until NukeShotsPerTarget missiles went in or the mass there fell
-- below a third. A point that held out is skipped for NukeBlockedSeconds
-- and the bot builds T3 artillery to knock out the enemy anti-nukes.
-- Points worth less than NukeMinValue mass (and not an ender / ACU) are
-- not worth a missile.
NukeRadius         = 30
NukeMinValue       = 8000
NukeShotsPerTarget = 5
NukeBlockedSeconds = 300
-- Long-range guns of ECO prefer targets near the enemy ECO base (x this).
EcoVsEcoBonus = 1.5

-- Enemy Yolona Oss scouted: every base puts up YolonaAntiNukes anti-nukes
-- and idle engineers assist them (faster interceptor missiles) until each
-- holds SMDAmmoWanted missiles; up to SMDHelpers engineers per anti-nuke.
YolonaAntiNukes = 6
SMDAmmoWanted   = 4
SMDHelpers      = 4

-- Realistic building: at most MaxConcurrentBuilds new structures under
-- construction per player (mexes and storages don't count; one costing
-- ExpensiveMass or more counts double; top-priority projects such as the
-- anti-nuke always may start). Engineers that can't start something new
-- assist what is already being built.
MaxConcurrentBuilds = 3
ExpensiveMass       = 2500

-- ACU and water. A known enemy land experimental within T4DangerRadius of
-- the GROUND / NAVAL ACU sends it underwater (land T4s can't hurt it
-- there). Underwater, known enemy warships within NavalDangerRadius worth
-- NavalDangerStrength (T1 = 1, T2 = 3, T3 = 8, T4 = 20) make it move to
-- another deep spot at least NavalEvadeDistance away (or home, on land).
-- While hiding it guards its spot with HideTorpedoes torpedo launchers and
-- HideSAMs T3 SAMs on the nearest shore.
T4DangerRadius      = 120
NavalDangerRadius   = 90
NavalDangerStrength = 3
NavalEvadeDistance  = 150
HideTorpedoes       = 2
HideSAMs            = 2

-- Telemetry (DualGapStats): a DGSTAT snapshot line in the game log every
-- StatsInterval seconds, the full structure layout every
-- StatsLayoutInterval seconds. Read by tools/parse_match.py & co.
StatsEnabled        = true
StatsInterval       = 60
StatsLayoutInterval = 180
-- Recorder (all armies, humans too): finished structures and unit
-- positions every StatsMoveInterval seconds.
StatsMoveInterval   = 10

-- Team chat and map pings (DualGapComms): the same alert is repeated no more
-- often than this.
PingCooldown = 60
